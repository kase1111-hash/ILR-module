// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "../interfaces/IL3Bridge.sol";
import "../interfaces/IILRM.sol";

/**
 * @title L3Bridge
 * @notice Bridge contract connecting L2 ILRM to App-Specific L3 Rollup
 * @dev Enables high-throughput dispute handling via dedicated rollup
 *
 * Key Features:
 * - State commitment with challenge period (optimistic rollup model)
 * - Merkle proof verification for dispute states
 * - Fraud proof system for invalid state challenges
 * - Batched settlements for gas efficiency
 * - Sequencer-based ordering with decentralization path
 * - FIX I-02: Two-step ownership transfer via Ownable2Step
 * - FIX H-02: Commit-reveal scheme for MEV protection on fraud proofs
 *
 * Security Model:
 * - Challenge period allows fraud proof submission
 * - Challenger bond prevents spam
 * - State roots link to previous for chain integrity
 * - Sequencer signature verification
 * - Commit-reveal prevents MEV front-running of fraud proofs
 *
 * Commit-Reveal Fraud Proofs (MEV protection without challenge griefing):
 * 1. The challenger commits
 *    commitHash = keccak256(abi.encode(FRAUD_PROOF_COMMIT_TYPEHASH, block.chainid, address(bridge),
 *                 challenger, keccak256(abi.encode(proof)), salt))
 *    against a state root with a bond >= MIN_CHALLENGER_BOND (see computeFraudProofCommitHash).
 *    The hash binds the challenger, so a copied hash or a copied reveal is useless to anyone else.
 * 2. Any number of commitments may be open against the same root. They are keyed by
 *    (challenger, commitHash), so nobody can occupy, squat or block another challenger's commitment.
 * 3. After MIN_REVEAL_DELAY (2 min) and within MAX_REVEAL_WINDOW (1 hour) the same challenger reveals.
 *    The reveal only acts on the root the bond was posted against.
 * 4. Every bond ends in exactly one outcome:
 *    - Won: valid proof on a canonical, unchallenged root -> bond + FRAUD_PROOF_REWARD
 *    - Refunded: valid proof, but the root was already rejected or orphaned -> bond only
 *    - Forfeited: invalid or mismatched proof, or never revealed (forfeitExpiredCommitment) -> bond kept
 *    Pending bonds are escrowed (totalEscrowedBonds) and never fund rewards or fee withdrawals.
 * 5. Each root's challenge deadline is snapshotted at submission. Commits close once
 *    block.timestamp + MIN_REVEAL_DELAY + MAX_REVEAL_WINDOW >= deadline, so no reveal window can still
 *    be open when the root becomes finalizable.
 *
 * Chain Model:
 * - Every submitted root gets a 1-based height on the canonical chain.
 * - Roots finalize strictly in chain order (height latestFinalizedHeight + 1).
 * - A successful challenge on any canonical root rolls the committed head back to that root's parent.
 *   The root and all its descendants become non-canonical and can never finalize; the sequencer rebuilds
 *   from the parent.
 *
 * Pause Semantics:
 * - pause() freezes finalization only. Commits, reveals, forfeits and legacy submissions stay open,
 *   so a pause can never be used to run out a challenge window.
 * - Bridging, settlements and state commitments are gated by bridgeStatus (onlyActive).
 *
 * Roles:
 * - Owner: configuration, roles, pause, withdrawal of free (non-escrowed) balance
 * - Sequencer: state commitments and settlements
 * - ILRM or owner-authorized dispute bridgers: bridgeDisputeToL3 / bridgeDisputeBatchToL3
 * - Sequencer or owner-authorized settlement relayers: batchProcessSettlements
 */
contract L3Bridge is IL3Bridge, ReentrancyGuard, Pausable, Ownable2Step {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ============ Constants ============

    /// @notice Default challenge period (7 days)
    uint256 public constant DEFAULT_CHALLENGE_PERIOD = 7 days;

    /// @notice Minimum challenger bond (0.1 ETH)
    uint256 public constant MIN_CHALLENGER_BOND = 0.1 ether;

    /// @notice Fraud proof reward percentage (50% of the minimum bond)
    uint256 public constant FRAUD_REWARD_BPS = 5000;

    /// @notice Maximum batch size for settlements and dispute bridging
    uint256 public constant MAX_BATCH_SIZE = 100;

    /// @notice Basis points denominator
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Minimum reveal delay after commitment (prevents same-block front-running)
    /// @dev FIX H-02: MEV protection via commit-reveal scheme
    uint256 public constant MIN_REVEAL_DELAY = 2 minutes;

    /// @notice Maximum reveal window after min delay (must reveal within this window)
    uint256 public constant MAX_REVEAL_WINDOW = 1 hours;

    /// @notice Domain-separated type hash for fraud-proof commitments
    bytes32 public constant FRAUD_PROOF_COMMIT_TYPEHASH = keccak256(
        "L3Bridge.FraudProofCommit(uint256 chainId,address bridge,address challenger,bytes32 proofHash,bytes32 salt)"
    );

    /// @notice Fixed reward for a winning fraud proof (0.05 ETH), paid only from free balance
    uint256 public constant FRAUD_PROOF_REWARD = (MIN_CHALLENGER_BOND * FRAUD_REWARD_BPS) / BPS_DENOMINATOR;

    // ============ State Variables ============

    /// @notice Connected ILRM contract
    IILRM public ilrm;

    /// @notice Current bridge status
    BridgeStatus public bridgeStatus;

    /// @notice Sequencer configuration
    SequencerConfig public sequencerConfig;

    /// @notice L2 to L3 dispute ID mapping
    mapping(uint256 => uint256) private _l2ToL3DisputeId;

    /// @notice L3 to L2 dispute ID mapping
    mapping(uint256 => uint256) private _l3ToL2DisputeId;

    /// @notice Bridged dispute data
    mapping(uint256 => DisputeInitiationMessage) private _bridgedDisputes;

    /// @notice State commitments by root
    mapping(bytes32 => StateCommitment) private _stateCommitments;

    /// @notice State commitment timestamps (for challenge period)
    mapping(bytes32 => uint256) private _commitmentTimestamps;

    /// @notice Finalized state roots
    mapping(bytes32 => bool) private _finalizedStates;

    /// @notice Latest finalized state root
    bytes32 public latestFinalizedRoot;

    /// @notice Latest finalized block number
    uint256 public latestFinalizedBlock;

    /// @notice Pending settlements by L2 dispute ID
    mapping(uint256 => DisputeSettlementMessage) private _pendingSettlements;

    /// @notice Settled disputes
    mapping(uint256 => bool) private _settledDisputes;

    /// @notice L3 dispute counter
    uint256 private _l3DisputeCounter;

    /// @notice Total bridged disputes
    uint256 public totalBridgedDisputes;

    /// @notice Total processed settlements
    uint256 public totalSettlements;

    /// @notice Pending settlements count (bridged but not yet settled)
    /// @dev FIX M-02: Now properly tracked when disputes are bridged/settled
    uint256 public pendingSettlementsCount;

    /// @notice Latest committed (but possibly unfinalized) state root
    /// @dev FIX M-03: Tracks latest commitment to prevent chain forks; rolled back to the parent of a
    ///      rejected root
    bytes32 public latestCommittedRoot;

    /// @notice Escrowed bond total per challenger (sum of that challenger's Pending commitments)
    mapping(address => uint256) public challengerBonds;

    /// @notice Active fraud challenges (state root -> winning challenger)
    mapping(bytes32 => address) private _activeChallenges;

    /// @notice Fraud proof commitments (commit-reveal for MEV protection)
    /// @dev Keyed by challenger, then commit hash; any number may be open per state root
    mapping(address => mapping(bytes32 => FraudProofCommitment)) private _fraudProofCommitments;

    /// @notice Whether commit-reveal mode is enabled (default: true for MEV protection)
    bool public commitRevealEnabled = true;

    /// @notice Challenge deadline per state root, snapshotted at submission
    mapping(bytes32 => uint256) private _challengeDeadlines;

    /// @notice 1-based chain height per submitted state root
    mapping(bytes32 => uint256) private _rootHeights;

    /// @notice Canonical state root at each height (valid up to latestCommittedHeight)
    mapping(uint256 => bytes32) private _canonicalRootAt;

    /// @notice Height of the committed chain head
    uint256 public latestCommittedHeight;

    /// @notice Height of the latest finalized root
    uint256 public latestFinalizedHeight;

    /// @notice Total of all Pending fraud-proof bonds held in escrow
    uint256 public totalEscrowedBonds;

    /// @notice Accounts (besides the ILRM) allowed to bridge disputes to L3
    mapping(address => bool) public disputeBridgers;

    /// @notice Accounts (besides the sequencer) allowed to relay settlement batches
    mapping(address => bool) public settlementRelayers;

    // ============ Constructor ============

    constructor(address _ilrm) Ownable(msg.sender) {
        require(_ilrm != address(0), "Invalid ILRM");
        ilrm = IILRM(_ilrm);
        bridgeStatus = BridgeStatus.Active;

        // Default sequencer config
        sequencerConfig = SequencerConfig({
            sequencerAddress: msg.sender,
            commitmentInterval: 100, // Every 100 L3 blocks
            challengePeriod: DEFAULT_CHALLENGE_PERIOD,
            minBatchSize: 1,
            maxBatchSize: MAX_BATCH_SIZE
        });
    }

    // ============ Modifiers ============

    modifier onlyActive() {
        if (bridgeStatus != BridgeStatus.Active) revert BridgeNotActive();
        _;
    }

    modifier onlySequencer() {
        if (msg.sender != sequencerConfig.sequencerAddress) {
            revert NotSequencer(msg.sender);
        }
        _;
    }

    modifier onlyDisputeBridger() {
        if (msg.sender != address(ilrm) && !disputeBridgers[msg.sender]) revert NotAuthorizedBridger(msg.sender);
        _;
    }

    modifier onlySequencerOrRelayer() {
        if (msg.sender != sequencerConfig.sequencerAddress && !settlementRelayers[msg.sender]) {
            revert NotSequencer(msg.sender);
        }
        _;
    }

    // ============ Bridge Operations ============

    /**
     * @inheritdoc IL3Bridge
     */
    function bridgeDisputeToL3(DisputeInitiationMessage calldata message)
        external
        override
        onlyDisputeBridger
        onlyActive
        nonReentrant
        returns (uint256 l3DisputeId)
    {
        // Ensure not already bridged
        if (_l2ToL3DisputeId[message.l2DisputeId] != 0) {
            revert DisputeAlreadyBridged(message.l2DisputeId);
        }

        l3DisputeId = _bridgeDispute(message);
    }

    /**
     * @inheritdoc IL3Bridge
     */
    function bridgeDisputeBatchToL3(DisputeInitiationMessage[] calldata messages)
        external
        override
        onlyDisputeBridger
        onlyActive
        nonReentrant
        returns (uint256[] memory l3DisputeIds)
    {
        uint256 len = messages.length;
        if (len > MAX_BATCH_SIZE) {
            revert BatchSizeExceeded(len, MAX_BATCH_SIZE);
        }

        l3DisputeIds = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            uint256 l2Id = messages[i].l2DisputeId;
            uint256 existing = _l2ToL3DisputeId[l2Id];
            if (existing != 0) {
                // Already bridged (possibly earlier in this batch): skip instead of failing the batch
                emit DisputeBridgeSkipped(l2Id, existing);
            } else {
                l3DisputeIds[i] = _bridgeDispute(messages[i]);
            }
        }
    }

    /**
     * @notice Assign an L3 ID to a not-yet-bridged dispute and record it
     */
    function _bridgeDispute(DisputeInitiationMessage calldata m) internal returns (uint256 l3Id) {
        uint256 l2Id = m.l2DisputeId;

        // Assign L3 ID
        l3Id = ++_l3DisputeCounter;

        // Store mappings
        _l2ToL3DisputeId[l2Id] = l3Id;
        _l3ToL2DisputeId[l3Id] = l2Id;
        _bridgedDisputes[l2Id] = m;

        totalBridgedDisputes++;
        // FIX M-02: Track pending (unsettled) disputes
        pendingSettlementsCount++;

        emit DisputeBridgedToL3(l2Id, l3Id, m.initiator, m.stakeAmount);
    }

    /**
     * @inheritdoc IL3Bridge
     */
    function processSettlementFromL3(DisputeSettlementMessage calldata message)
        external
        override
        onlySequencer
        onlyActive
        nonReentrant
    {
        _processSettlement(message);
    }

    /**
     * @inheritdoc IL3Bridge
     */
    function batchProcessSettlements(DisputeSettlementMessage[] calldata messages)
        external
        override
        onlySequencerOrRelayer
        onlyActive
        nonReentrant
    {
        if (messages.length > MAX_BATCH_SIZE) {
            revert BatchSizeExceeded(messages.length, MAX_BATCH_SIZE);
        }

        for (uint256 i = 0; i < messages.length; i++) {
            _processSettlement(messages[i]);
        }
    }

    /**
     * @notice Internal settlement processing
     */
    function _processSettlement(DisputeSettlementMessage calldata message) internal {
        uint256 l2Id = message.l2DisputeId;

        // Verify dispute was bridged
        if (_l2ToL3DisputeId[l2Id] == 0) {
            revert DisputeNotBridged(l2Id);
        }

        // Verify L3 ID matches
        if (_l2ToL3DisputeId[l2Id] != message.l3DisputeId) {
            revert InvalidSettlement(l2Id);
        }

        // Verify not already settled
        if (_settledDisputes[l2Id]) {
            revert InvalidSettlement(l2Id);
        }

        // Verify state proof is from finalized root
        if (!_finalizedStates[message.stateProof] && message.stateProof != bytes32(0)) {
            // For immediate settlements, proof can be bytes32(0) with sequencer signature
            // For delayed settlements, must reference finalized state
            revert InvalidStateRoot(message.stateProof);
        }

        // Mark as settled
        _settledDisputes[l2Id] = true;
        totalSettlements++;
        // FIX M-02: Decrement pending count when settled
        if (pendingSettlementsCount > 0) {
            pendingSettlementsCount--;
        }

        emit DisputeSettledFromL3(
            l2Id, message.l3DisputeId, message.outcome, message.initiatorReturn, message.counterpartyReturn
        );

        // Note: Actual stake distribution is handled by ILRM
        // This bridge only validates and signals the settlement
    }

    // ============ State Commitments ============

    /**
     * @inheritdoc IL3Bridge
     */
    function submitStateCommitment(StateCommitment calldata commitment)
        external
        override
        onlySequencer
        onlyActive
        nonReentrant
    {
        bytes32 root = commitment.stateRoot;

        // The zero root is reserved (it means "no root" throughout the bridge)
        if (root == bytes32(0)) {
            revert InvalidStateRoot(root);
        }

        // Verify not already committed
        if (_commitmentTimestamps[root] != 0) {
            revert StateRootAlreadyCommitted(root);
        }

        // FIX M-03: Verify chain integrity against latest COMMITTED root (not just finalized)
        // This prevents forks where multiple commitments point to the same previousRoot
        if (latestCommittedRoot != bytes32(0)) {
            // Must chain from the latest committed root
            require(
                commitment.previousRoot == latestCommittedRoot, "Invalid chain: must reference latest committed root"
            );
        } else if (latestFinalizedRoot != bytes32(0)) {
            // If no pending commitments, chain from latest finalized
            require(
                commitment.previousRoot == latestFinalizedRoot, "Invalid chain: must reference latest finalized root"
            );
        }
        // else: genesis case - no previous root required

        // Verify sequencer signature
        bytes32 messageHash =
            keccak256(abi.encodePacked(root, commitment.blockNumber, commitment.disputeCount, commitment.previousRoot));

        bytes32 ethSignedHash = messageHash.toEthSignedMessageHash();
        address signer = ethSignedHash.recover(commitment.sequencerSignature);

        if (signer != sequencerConfig.sequencerAddress) {
            revert InvalidSequencerSignature();
        }

        // Store commitment
        _stateCommitments[root] = commitment;
        _commitmentTimestamps[root] = block.timestamp;
        // FIX M-03: Track latest committed root for chain integrity
        latestCommittedRoot = root;

        // Place the root on the canonical chain and snapshot its challenge deadline
        uint256 height = latestCommittedHeight + 1;
        _rootHeights[root] = height;
        _canonicalRootAt[height] = root;
        latestCommittedHeight = height;
        _challengeDeadlines[root] = block.timestamp + sequencerConfig.challengePeriod;

        emit StateCommitmentSubmitted(root, commitment.blockNumber, commitment.disputeCount, msg.sender);
    }

    /**
     * @inheritdoc IL3Bridge
     * @dev Frozen while paused. Roots finalize strictly in chain order and only while canonical.
     */
    function finalizeStateCommitment(bytes32 stateRoot) external override nonReentrant whenNotPaused {
        // Verify commitment exists
        if (_commitmentTimestamps[stateRoot] == 0) {
            revert InvalidStateRoot(stateRoot);
        }

        // Verify challenge period passed (deadline snapshotted at submission)
        uint256 deadline = _challengeDeadlines[stateRoot];
        if (block.timestamp < deadline) {
            revert ChallengePeriodNotPassed(deadline - block.timestamp);
        }

        // Verify not already finalized
        if (_finalizedStates[stateRoot]) {
            return; // Already finalized, no-op
        }

        // Verify no active challenge
        if (_activeChallenges[stateRoot] != address(0)) {
            revert InvalidStateRoot(stateRoot); // Challenged, cannot finalize
        }

        // A root orphaned by a challenge on an ancestor can never finalize
        if (!_isCanonical(stateRoot)) {
            revert StateRootNotCanonical(stateRoot);
        }

        // Finalize strictly in chain order
        uint256 height = _rootHeights[stateRoot];
        if (height != latestFinalizedHeight + 1) {
            revert ParentNotFinalized(_stateCommitments[stateRoot].previousRoot);
        }

        // Finalize
        _finalizedStates[stateRoot] = true;
        latestFinalizedRoot = stateRoot;
        latestFinalizedHeight = height;
        latestFinalizedBlock = _stateCommitments[stateRoot].blockNumber;

        emit StateCommitmentFinalized(stateRoot, latestFinalizedBlock);
    }

    /**
     * @inheritdoc IL3Bridge
     */
    function getLatestFinalizedState() external view override returns (bytes32 stateRoot, uint256 blockNumber) {
        return (latestFinalizedRoot, latestFinalizedBlock);
    }

    /**
     * @inheritdoc IL3Bridge
     */
    function isStateFinalized(bytes32 stateRoot) external view override returns (bool) {
        return _finalizedStates[stateRoot];
    }

    /**
     * @notice Whether a root is on the current canonical chain (at or below the committed head)
     */
    function _isCanonical(bytes32 root) internal view returns (bool) {
        uint256 h = _rootHeights[root];
        return h != 0 && h <= latestCommittedHeight && _canonicalRootAt[h] == root;
    }

    // ============ Fraud Proofs (Commit-Reveal for MEV Protection) ============

    /**
     * @inheritdoc IL3Bridge
     * @dev FIX H-02: Phase 1 of commit-reveal scheme for MEV protection. Never paused.
     */
    function commitFraudProof(bytes32 commitHash, bytes32 stateRoot) external payable override nonReentrant {
        // Verify commit-reveal mode is enabled
        require(commitRevealEnabled, "Commit-reveal disabled");

        // Verify challenger bond
        if (msg.value < MIN_CHALLENGER_BOND) {
            revert InsufficientChallengerBond();
        }

        if (commitHash == bytes32(0)) {
            revert InvalidCommitment();
        }

        // Committed, not finalized, not already rejected, still canonical
        _requireChallengeable(stateRoot);

        // A reveal window opened now must close before the root becomes finalizable
        if (block.timestamp + MIN_REVEAL_DELAY + MAX_REVEAL_WINDOW >= _challengeDeadlines[stateRoot]) {
            revert ChallengePeriodExpired();
        }

        // Commitments are per challenger: only the challenger's own earlier use of this hash can collide
        FraudProofCommitment storage commitment = _fraudProofCommitments[msg.sender][commitHash];
        if (commitment.status != CommitmentStatus.None) {
            revert InvalidCommitment();
        }

        commitment.commitHash = commitHash;
        commitment.stateRoot = stateRoot;
        commitment.challenger = msg.sender;
        commitment.status = CommitmentStatus.Pending;
        commitment.bond = msg.value;
        commitment.commitTime = block.timestamp;

        totalEscrowedBonds += msg.value;
        challengerBonds[msg.sender] += msg.value;

        emit FraudProofCommitted(commitHash, stateRoot, msg.sender, msg.value);
    }

    /**
     * @inheritdoc IL3Bridge
     * @dev FIX H-02: Phase 2 of commit-reveal scheme for MEV protection. Never paused.
     */
    function revealFraudProof(FraudProof calldata proof, bytes32 salt) external override nonReentrant {
        // The hash binds msg.sender: a copied proof + salt does not match anyone else's commitment
        bytes32 commitHash = _commitHashFor(msg.sender, proof, salt);
        FraudProofCommitment storage commitment = _fraudProofCommitments[msg.sender][commitHash];

        if (commitment.status == CommitmentStatus.None) {
            revert CommitmentNotFound();
        }
        if (commitment.status != CommitmentStatus.Pending) {
            revert AlreadyRevealed();
        }

        uint256 timeSinceCommit = block.timestamp - commitment.commitTime;

        // Must wait minimum delay (prevents same-block front-running)
        if (timeSinceCommit < MIN_REVEAL_DELAY) {
            revert RevealTooEarly(MIN_REVEAL_DELAY - timeSinceCommit);
        }

        // Must reveal within window
        if (timeSinceCommit > MIN_REVEAL_DELAY + MAX_REVEAL_WINDOW) {
            revert RevealTooLate();
        }

        bytes32 root = commitment.stateRoot;
        emit FraudProofRevealed(commitHash, root, msg.sender);

        // The reveal only acts on the root the bond was posted against; an invalid proof forfeits the bond
        if (proof.claimedRoot != root || !_verifyFraudProof(proof)) {
            _forfeit(commitment);
            return;
        }

        // Valid proof, but the root was already rejected or orphaned by a rejected ancestor
        if (_activeChallenges[root] != address(0) || _finalizedStates[root] || !_isCanonical(root)) {
            _refund(commitment);
            return;
        }

        _win(commitment, proof.disputeId);
    }

    /**
     * @inheritdoc IL3Bridge
     * @dev Permissionless and never paused
     */
    function forfeitExpiredCommitment(address challenger, bytes32 commitHash) external override nonReentrant {
        FraudProofCommitment storage commitment = _fraudProofCommitments[challenger][commitHash];

        if (commitment.status == CommitmentStatus.None) {
            revert CommitmentNotFound();
        }
        if (commitment.status != CommitmentStatus.Pending) {
            revert AlreadyRevealed();
        }

        uint256 expiry = commitment.commitTime + MIN_REVEAL_DELAY + MAX_REVEAL_WINDOW;
        if (block.timestamp <= expiry) {
            revert CommitmentNotExpired(expiry - block.timestamp + 1);
        }

        _forfeit(commitment);
    }

    /**
     * @inheritdoc IL3Bridge
     * @dev DEPRECATED: Use commitFraudProof + revealFraudProof for MEV protection
     *      This function remains for backwards compatibility but is vulnerable to front-running
     */
    function submitFraudProof(FraudProof calldata proof) external payable override nonReentrant {
        // If commit-reveal is enabled, require that path instead
        if (commitRevealEnabled) {
            revert("Use commitFraudProof + revealFraudProof for MEV protection");
        }
        // Verify challenger bond
        if (msg.value < MIN_CHALLENGER_BOND) {
            revert InsufficientChallengerBond();
        }

        bytes32 claimedRoot = proof.claimedRoot;

        // Committed, not finalized, not already rejected, still canonical
        _requireChallengeable(claimedRoot);

        // Verify still in challenge period
        if (block.timestamp >= _challengeDeadlines[claimedRoot]) {
            revert ChallengePeriodExpired();
        }

        // Verify Merkle proof of incorrect state (nothing is escrowed on this path)
        if (!_verifyFraudProof(proof)) {
            revert InvalidFraudProof();
        }

        // Reward comes only from free balance (never from escrowed bonds or this call's own bond)
        uint256 reward = _min(FRAUD_PROOF_REWARD, _freeBalanceExcluding(msg.value));

        _recordSuccessfulChallenge(claimedRoot, proof.disputeId, msg.sender);

        emit FraudProofValidated(claimedRoot, msg.sender, reward);

        // Return bond + reward
        _sendValue(msg.sender, msg.value + reward);
    }

    /**
     * @notice Revert unless the root can currently be challenged
     */
    function _requireChallengeable(bytes32 root) internal view {
        // Verify state is committed (every committed root has a nonzero height) but not finalized
        if (_rootHeights[root] == 0) {
            revert InvalidStateRoot(root);
        }
        if (_finalizedStates[root]) {
            revert ChallengePeriodExpired();
        }
        // Check if already challenged - prevent duplicate challenges
        if (_activeChallenges[root] != address(0)) {
            revert InvalidStateRoot(root);
        }
        // Roots orphaned by a rejected ancestor are already dead
        if (!_isCanonical(root)) {
            revert StateRootNotCanonical(root);
        }
    }

    /**
     * @notice Forfeit a Pending commitment: its bond leaves escrow and stays in the bridge as free balance
     */
    function _forfeit(FraudProofCommitment storage commitment) internal {
        commitment.status = CommitmentStatus.Forfeited;
        uint256 bond = commitment.bond;
        address challenger = commitment.challenger;
        _releaseEscrow(challenger, bond);

        emit FraudProofForfeited(commitment.commitHash, commitment.stateRoot, challenger, bond);
    }

    /**
     * @notice Refund a valid reveal whose root was already rejected or orphaned (caller is the challenger)
     */
    function _refund(FraudProofCommitment storage commitment) internal {
        commitment.status = CommitmentStatus.Refunded;
        uint256 bond = commitment.bond;
        _releaseEscrow(msg.sender, bond);

        emit FraudProofRefunded(commitment.commitHash, commitment.stateRoot, msg.sender, bond);

        _sendValue(msg.sender, bond);
    }

    /**
     * @notice Settle a winning reveal (caller is the challenger): reject the root, pay bond + reward
     */
    function _win(FraudProofCommitment storage commitment, uint256 disputeId) internal {
        uint256 bond = commitment.bond;
        // Computed while the winner's own bond is still escrowed, so it can never pay out escrow
        uint256 reward = _min(FRAUD_PROOF_REWARD, freeBalance());
        bytes32 root = commitment.stateRoot;

        commitment.status = CommitmentStatus.Won;
        _releaseEscrow(msg.sender, bond);

        _recordSuccessfulChallenge(root, disputeId, msg.sender);

        emit FraudProofValidated(root, msg.sender, reward);

        // Return bond + reward
        _sendValue(msg.sender, bond + reward);
    }

    /**
     * @notice Reject a canonical root and roll the committed chain head back to its parent
     * @dev Every descendant becomes non-canonical, so none of them can be finalized
     */
    function _recordSuccessfulChallenge(bytes32 root, uint256 disputeId, address challenger) internal {
        _activeChallenges[root] = challenger;

        // The root is canonical here, so its parent is the canonical root one height below
        uint256 height = _rootHeights[root];
        bytes32 newHead = _stateCommitments[root].previousRoot;
        latestCommittedRoot = newHead;
        latestCommittedHeight = height - 1;

        emit CommittedChainRolledBack(root, newHead, height - 1);
        emit FraudProofSubmitted(root, disputeId, challenger);
    }

    /**
     * @notice Remove a bond from escrow accounting
     */
    function _releaseEscrow(address challenger, uint256 amount) internal {
        totalEscrowedBonds -= amount;
        challengerBonds[challenger] -= amount;
    }

    /**
     * @notice Free balance excluding an amount received in the current call
     */
    function _freeBalanceExcluding(uint256 excluded) internal view returns (uint256) {
        uint256 locked = totalEscrowedBonds + excluded;
        uint256 balance = address(this).balance;
        return balance > locked ? balance - locked : 0;
    }

    /**
     * @notice Send ETH, reverting on failure
     */
    function _sendValue(address to, uint256 amount) internal {
        (bool success,) = to.call{value: amount}("");
        require(success, "Reward transfer failed");
    }

    /**
     * @notice Smaller of two values
     */
    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /**
     * @notice Domain-separated, challenger-bound commitment hash
     */
    function _commitHashFor(address challenger, FraudProof calldata proof, bytes32 salt)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                FRAUD_PROOF_COMMIT_TYPEHASH,
                block.chainid,
                address(this),
                challenger,
                keccak256(abi.encode(proof)),
                salt
            )
        );
    }

    /**
     * @notice Internal fraud proof verification
     */
    function _verifyFraudProof(FraudProof calldata proof) internal pure returns (bool) {
        // Verify the Merkle proof shows the claimed state is incorrect
        // This is a simplified implementation - production would need
        // full state transition verification

        // Compute expected leaf from dispute data
        bytes32 leaf = keccak256(proof.invalidStateData);

        // Verify proof path
        bytes32 computed = leaf;
        for (uint256 i = 0; i < proof.merkleProof.length; i++) {
            bytes32 proofElement = proof.merkleProof[i];
            if (computed < proofElement) {
                computed = keccak256(abi.encodePacked(computed, proofElement));
            } else {
                computed = keccak256(abi.encodePacked(proofElement, computed));
            }
        }

        // If computed root matches claimed but differs from correct, fraud is proven
        return computed == proof.claimedRoot && proof.claimedRoot != proof.correctRoot;
    }

    /**
     * @inheritdoc IL3Bridge
     */
    function verifyDisputeState(bytes32 stateRoot, L3DisputeSummary calldata summary, bytes32[] calldata merkleProof)
        external
        view
        override
        returns (bool valid)
    {
        // Verify state root is finalized
        if (!_finalizedStates[stateRoot]) {
            return false;
        }

        // Compute leaf from summary
        bytes32 leaf = keccak256(
            abi.encodePacked(
                summary.l3DisputeId,
                summary.l2DisputeId,
                uint8(summary.state),
                summary.counterCount,
                summary.initiatorAccepted,
                summary.counterpartyAccepted,
                summary.currentProposalHash,
                summary.lastUpdateBlock
            )
        );

        // Verify Merkle proof
        bytes32 computed = leaf;
        for (uint256 i = 0; i < merkleProof.length; i++) {
            bytes32 proofElement = merkleProof[i];
            if (computed < proofElement) {
                computed = keccak256(abi.encodePacked(computed, proofElement));
            } else {
                computed = keccak256(abi.encodePacked(proofElement, computed));
            }
        }

        return computed == stateRoot;
    }

    // ============ Configuration ============

    /**
     * @inheritdoc IL3Bridge
     */
    function updateSequencerConfig(SequencerConfig calldata config) external override onlyOwner {
        require(config.sequencerAddress != address(0), "Invalid sequencer");
        require(config.challengePeriod >= 1 days, "Challenge period too short");
        require(config.maxBatchSize <= MAX_BATCH_SIZE, "Batch size too large");

        address oldSequencer = sequencerConfig.sequencerAddress;
        sequencerConfig = config;

        if (oldSequencer != config.sequencerAddress) {
            emit SequencerUpdated(oldSequencer, config.sequencerAddress);
        }
    }

    /**
     * @inheritdoc IL3Bridge
     */
    function getSequencerConfig() external view override returns (SequencerConfig memory) {
        return sequencerConfig;
    }

    /**
     * @inheritdoc IL3Bridge
     */
    function setBridgeStatus(BridgeStatus status) external override onlyOwner {
        BridgeStatus oldStatus = bridgeStatus;
        bridgeStatus = status;
        emit BridgeStatusChanged(oldStatus, status);
    }

    /**
     * @inheritdoc IL3Bridge
     */
    function getBridgeStatus() external view override returns (BridgeStatus) {
        return bridgeStatus;
    }

    /**
     * @notice Update ILRM contract address
     * @dev Only callable by owner. Cannot set to zero address.
     * @param _ilrm New ILRM contract address
     */
    function setILRM(address _ilrm) external onlyOwner {
        require(_ilrm != address(0), "Invalid ILRM");
        ilrm = IILRM(_ilrm);
    }

    /**
     * @notice Grant or revoke the dispute-bridger role (e.g. for L3DisputeBatcher)
     * @param account Account to update
     * @param authorized Whether the account may call bridgeDisputeToL3 / bridgeDisputeBatchToL3
     */
    function setDisputeBridger(address account, bool authorized) external onlyOwner {
        require(account != address(0), "Invalid bridger");
        disputeBridgers[account] = authorized;
        emit DisputeBridgerUpdated(account, authorized);
    }

    /**
     * @notice Grant or revoke the settlement-relayer role (e.g. for L3DisputeBatcher)
     * @param account Account to update
     * @param authorized Whether the account may call batchProcessSettlements
     */
    function setSettlementRelayer(address account, bool authorized) external onlyOwner {
        require(account != address(0), "Invalid relayer");
        settlementRelayers[account] = authorized;
        emit SettlementRelayerUpdated(account, authorized);
    }

    // ============ View Functions ============

    /**
     * @inheritdoc IL3Bridge
     */
    function getL3DisputeId(uint256 l2DisputeId) external view override returns (uint256) {
        return _l2ToL3DisputeId[l2DisputeId];
    }

    /**
     * @inheritdoc IL3Bridge
     */
    function getL2DisputeId(uint256 l3DisputeId) external view override returns (uint256) {
        return _l3ToL2DisputeId[l3DisputeId];
    }

    /**
     * @inheritdoc IL3Bridge
     */
    function isDisputeBridged(uint256 l2DisputeId) external view override returns (bool) {
        return _l2ToL3DisputeId[l2DisputeId] != 0;
    }

    /**
     * @inheritdoc IL3Bridge
     */
    function getPendingSettlementsCount() external view override returns (uint256) {
        return pendingSettlementsCount;
    }

    /**
     * @inheritdoc IL3Bridge
     */
    function getStateCommitment(bytes32 stateRoot) external view override returns (StateCommitment memory) {
        return _stateCommitments[stateRoot];
    }

    /**
     * @inheritdoc IL3Bridge
     */
    function getTotalBridgedDisputes() external view override returns (uint256) {
        return totalBridgedDisputes;
    }

    /**
     * @inheritdoc IL3Bridge
     */
    function getTotalSettlements() external view override returns (uint256) {
        return totalSettlements;
    }

    /**
     * @notice Get bridged dispute data
     * @param l2DisputeId The L2 dispute ID to query
     * @return The dispute initiation message containing all bridged data
     */
    function getBridgedDispute(uint256 l2DisputeId) external view returns (DisputeInitiationMessage memory) {
        return _bridgedDisputes[l2DisputeId];
    }

    /**
     * @notice Check if dispute is settled
     * @param l2DisputeId The L2 dispute ID to check
     * @return True if the dispute has been settled
     */
    function isDisputeSettled(uint256 l2DisputeId) external view returns (bool) {
        return _settledDisputes[l2DisputeId];
    }

    /**
     * @notice Get commitment timestamp for a state root
     * @param stateRoot The state root to query
     * @return The timestamp when the state was committed (0 if not committed)
     */
    function getCommitmentTimestamp(bytes32 stateRoot) external view returns (uint256) {
        return _commitmentTimestamps[stateRoot];
    }

    /**
     * @notice Get the challenge deadline of a state root (snapshotted at submission)
     * @param stateRoot The state root to query
     * @return The timestamp from which the root may be finalized (0 if not committed)
     */
    function getChallengeDeadline(bytes32 stateRoot) external view returns (uint256) {
        return _challengeDeadlines[stateRoot];
    }

    /**
     * @notice Get the 1-based chain height a state root was submitted at
     * @param stateRoot The state root to query
     * @return The height (0 if not committed)
     */
    function getRootHeight(bytes32 stateRoot) external view returns (uint256) {
        return _rootHeights[stateRoot];
    }

    /**
     * @notice Whether a state root is on the current canonical chain
     * @param stateRoot The state root to query
     * @return False if never committed, or orphaned by a rejected ancestor (or rejected itself)
     */
    function isStateCanonical(bytes32 stateRoot) external view returns (bool) {
        return _isCanonical(stateRoot);
    }

    /**
     * @notice Balance not reserved for escrowed bonds (funds rewards and fee withdrawals)
     * @return The free balance
     */
    function freeBalance() public view returns (uint256) {
        uint256 balance = address(this).balance;
        return balance > totalEscrowedBonds ? balance - totalEscrowedBonds : 0;
    }

    /**
     * @notice Get active challenge for a state root
     * @param stateRoot The state root to query
     * @return The address of the challenger (address(0) if no active challenge)
     */
    function getActiveChallenger(bytes32 stateRoot) external view returns (address) {
        return _activeChallenges[stateRoot];
    }

    /**
     * @inheritdoc IL3Bridge
     */
    function getFraudProofCommitment(address challenger, bytes32 commitHash)
        external
        view
        override
        returns (FraudProofCommitment memory)
    {
        return _fraudProofCommitments[challenger][commitHash];
    }

    /**
     * @inheritdoc IL3Bridge
     */
    function computeFraudProofCommitHash(address challenger, FraudProof calldata proof, bytes32 salt)
        external
        view
        override
        returns (bytes32)
    {
        return _commitHashFor(challenger, proof, salt);
    }

    /**
     * @inheritdoc IL3Bridge
     */
    function isCommitRevealEnabled() external view override returns (bool) {
        return commitRevealEnabled;
    }

    // ============ Admin Functions ============

    /**
     * @notice Pause the bridge - freezes state-root finalization
     * @dev Only callable by owner. Challenges (commit, reveal, forfeit, legacy submit) are never paused,
     *      so a pause cannot be used to run out a challenge window. Bridging and settlements are gated
     *      by bridgeStatus instead.
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause the bridge - resumes finalization
     * @dev Only callable by owner.
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Withdraw accumulated fees (forfeited bonds and donations)
     * @dev Only callable by owner. Cannot withdraw to zero address, and never touches escrowed bonds.
     * @param to Recipient address
     * @param amount Amount of ETH to withdraw (at most freeBalance())
     */
    function withdrawFees(address to, uint256 amount) external onlyOwner nonReentrant {
        require(to != address(0), "Invalid recipient");
        uint256 available = freeBalance();
        if (amount > available) {
            revert InsufficientFreeBalance(amount, available);
        }

        emit FeesWithdrawn(to, amount);

        (bool success,) = to.call{value: amount}("");
        require(success, "Withdrawal failed");
    }

    /**
     * @notice Toggle commit-reveal mode for fraud proofs
     * @dev Only callable by owner. When enabled, submitFraudProof is disabled
     *      and users must use commitFraudProof + revealFraudProof for MEV protection.
     *      Disabling only blocks new commits; existing commitments can still be revealed or forfeited.
     * @param enabled Whether commit-reveal mode should be enabled
     */
    function setCommitRevealEnabled(bool enabled) external onlyOwner {
        commitRevealEnabled = enabled;
    }

    // ============ Migration Helpers (FIX I-04) ============

    /**
     * @notice Get all critical state for migration to a new contract version
     * @dev Only callable by owner. Returns state needed for migration.
     * @return _latestFinalizedRoot Latest finalized state root
     * @return _latestFinalizedBlock Block number of latest finalized state
     * @return _latestCommittedRoot Latest committed (possibly unfinalized) root
     * @return _totalBridged Total disputes bridged
     * @return _totalSettled Total disputes settled
     * @return _pendingCount Current pending count
     */
    function getMigrationState()
        external
        view
        onlyOwner
        returns (
            bytes32 _latestFinalizedRoot,
            uint256 _latestFinalizedBlock,
            bytes32 _latestCommittedRoot,
            uint256 _totalBridged,
            uint256 _totalSettled,
            uint256 _pendingCount
        )
    {
        return (
            latestFinalizedRoot,
            latestFinalizedBlock,
            latestCommittedRoot,
            totalBridgedDisputes,
            totalSettlements,
            pendingSettlementsCount
        );
    }

    /**
     * @notice Deprecate this contract in favor of a new version
     * @dev Pauses contract (freezing finalization) and emits deprecation event. Irreversible.
     * @param newContract Address of the new contract version
     */
    function deprecate(address newContract) external onlyOwner {
        require(newContract != address(0), "Invalid new contract");
        _pause();
        bridgeStatus = BridgeStatus.Deprecated;
        emit BridgeStatusChanged(BridgeStatus.Active, BridgeStatus.Deprecated);
    }

    /// @notice Accept ETH for fraud proof rewards
    receive() external payable {}
}
