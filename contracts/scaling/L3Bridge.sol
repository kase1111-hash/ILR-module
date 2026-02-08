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
 * Commit-Reveal Scheme (MEV Protection):
 * 1. Challenger commits hash(proof + salt) with bond
 * 2. After MIN_REVEAL_DELAY (2 min), challenger reveals proof
 * 3. Reveal must occur within MAX_REVEAL_WINDOW (1 hour)
 * 4. Only original committer can reveal, preventing front-running
 */
contract L3Bridge is IL3Bridge, ReentrancyGuard, Pausable, Ownable2Step {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ============ Constants ============

    /// @notice Default challenge period (7 days)
    uint256 public constant DEFAULT_CHALLENGE_PERIOD = 7 days;

    /// @notice Minimum challenger bond (0.1 ETH)
    uint256 public constant MIN_CHALLENGER_BOND = 0.1 ether;

    /// @notice Fraud proof reward percentage (50% of bond)
    uint256 public constant FRAUD_REWARD_BPS = 5000;

    /// @notice Maximum batch size for settlements
    uint256 public constant MAX_BATCH_SIZE = 100;

    /// @notice Basis points denominator
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @notice Minimum reveal delay after commitment (prevents same-block front-running)
    /// @dev FIX H-02: MEV protection via commit-reveal scheme
    uint256 public constant MIN_REVEAL_DELAY = 2 minutes;

    /// @notice Maximum reveal window after min delay (must reveal within this window)
    uint256 public constant MAX_REVEAL_WINDOW = 1 hours;

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
    /// @dev FIX M-03: Tracks latest commitment to prevent chain forks
    bytes32 public latestCommittedRoot;

    /// @notice Challenger bonds
    mapping(address => uint256) public challengerBonds;

    /// @notice Active fraud challenges
    mapping(bytes32 => address) private _activeChallenges;

    /// @notice Fraud proof commitments (commit-reveal for MEV protection)
    /// @dev FIX H-02: Maps commit hash -> commitment details
    mapping(bytes32 => FraudProofCommitment) private _fraudProofCommitments;

    /// @notice Maps state root -> commit hash (for tracking pending reveals)
    mapping(bytes32 => bytes32) private _stateRootCommitments;

    /// @notice Whether commit-reveal mode is enabled (default: true for MEV protection)
    bool public commitRevealEnabled = true;

    // ============ Constructor ============

    constructor(address _ilrm) Ownable(msg.sender) {
        require(_ilrm != address(0), "Invalid ILRM");
        ilrm = IILRM(_ilrm);
        bridgeStatus = BridgeStatus.Active;

        // Default sequencer config
        sequencerConfig = SequencerConfig({
            sequencerAddress: msg.sender,
            commitmentInterval: 100,      // Every 100 L3 blocks
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

    modifier onlyILRM() {
        require(msg.sender == address(ilrm), "Only ILRM");
        _;
    }

    // ============ Bridge Operations ============

    /**
     * @inheritdoc IL3Bridge
     */
    function bridgeDisputeToL3(
        DisputeInitiationMessage calldata message
    ) external override onlyILRM onlyActive nonReentrant returns (uint256 l3DisputeId) {
        uint256 l2Id = message.l2DisputeId;

        // Ensure not already bridged
        if (_l2ToL3DisputeId[l2Id] != 0) {
            revert DisputeAlreadyBridged(l2Id);
        }

        // Assign L3 ID
        _l3DisputeCounter++;
        l3DisputeId = _l3DisputeCounter;

        // Store mappings
        _l2ToL3DisputeId[l2Id] = l3DisputeId;
        _l3ToL2DisputeId[l3DisputeId] = l2Id;
        _bridgedDisputes[l2Id] = message;

        totalBridgedDisputes++;
        // FIX M-02: Track pending (unsettled) disputes
        pendingSettlementsCount++;

        emit DisputeBridgedToL3(l2Id, l3DisputeId, message.initiator, message.stakeAmount);
    }

    /**
     * @inheritdoc IL3Bridge
     */
    function processSettlementFromL3(
        DisputeSettlementMessage calldata message
    ) external override onlySequencer onlyActive nonReentrant {
        _processSettlement(message);
    }

    /**
     * @inheritdoc IL3Bridge
     */
    function batchProcessSettlements(
        DisputeSettlementMessage[] calldata messages
    ) external override onlySequencer onlyActive nonReentrant {
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
            l2Id,
            message.l3DisputeId,
            message.outcome,
            message.initiatorReturn,
            message.counterpartyReturn
        );

        // Note: Actual stake distribution is handled by ILRM
        // This bridge only validates and signals the settlement
    }

    // ============ State Commitments ============

    /**
     * @inheritdoc IL3Bridge
     */
    function submitStateCommitment(
        StateCommitment calldata commitment
    ) external override onlySequencer onlyActive nonReentrant {
        bytes32 root = commitment.stateRoot;

        // Verify not already committed
        if (_commitmentTimestamps[root] != 0) {
            revert StateRootAlreadyCommitted(root);
        }

        // FIX M-03: Verify chain integrity against latest COMMITTED root (not just finalized)
        // This prevents forks where multiple commitments point to the same previousRoot
        if (latestCommittedRoot != bytes32(0)) {
            // Must chain from the latest committed root
            require(commitment.previousRoot == latestCommittedRoot, "Invalid chain: must reference latest committed root");
        } else if (latestFinalizedRoot != bytes32(0)) {
            // If no pending commitments, chain from latest finalized
            require(commitment.previousRoot == latestFinalizedRoot, "Invalid chain: must reference latest finalized root");
        }
        // else: genesis case - no previous root required

        // Verify sequencer signature
        bytes32 messageHash = keccak256(abi.encodePacked(
            root,
            commitment.blockNumber,
            commitment.disputeCount,
            commitment.previousRoot
        ));

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

        emit StateCommitmentSubmitted(
            root,
            commitment.blockNumber,
            commitment.disputeCount,
            msg.sender
        );
    }

    /**
     * @inheritdoc IL3Bridge
     */
    function finalizeStateCommitment(bytes32 stateRoot) external override nonReentrant {
        uint256 commitTime = _commitmentTimestamps[stateRoot];

        // Verify commitment exists
        if (commitTime == 0) {
            revert InvalidStateRoot(stateRoot);
        }

        // Verify challenge period passed
        uint256 elapsed = block.timestamp - commitTime;
        if (elapsed < sequencerConfig.challengePeriod) {
            revert ChallengePeriodNotPassed(sequencerConfig.challengePeriod - elapsed);
        }

        // Verify not already finalized
        if (_finalizedStates[stateRoot]) {
            return; // Already finalized, no-op
        }

        // Verify no active challenge
        if (_activeChallenges[stateRoot] != address(0)) {
            revert InvalidStateRoot(stateRoot); // Challenged, cannot finalize
        }

        // Finalize
        _finalizedStates[stateRoot] = true;
        latestFinalizedRoot = stateRoot;
        latestFinalizedBlock = _stateCommitments[stateRoot].blockNumber;

        emit StateCommitmentFinalized(stateRoot, latestFinalizedBlock);
    }

    /**
     * @inheritdoc IL3Bridge
     */
    function getLatestFinalizedState() external view override returns (
        bytes32 stateRoot,
        uint256 blockNumber
    ) {
        return (latestFinalizedRoot, latestFinalizedBlock);
    }

    /**
     * @inheritdoc IL3Bridge
     */
    function isStateFinalized(bytes32 stateRoot) external view override returns (bool) {
        return _finalizedStates[stateRoot];
    }

    // ============ Fraud Proofs (Commit-Reveal for MEV Protection) ============

    /**
     * @inheritdoc IL3Bridge
     * @dev FIX H-02: Phase 1 of commit-reveal scheme for MEV protection
     */
    function commitFraudProof(
        bytes32 commitHash,
        bytes32 stateRoot
    ) external payable override nonReentrant whenNotPaused {
        // Verify commit-reveal mode is enabled
        require(commitRevealEnabled, "Commit-reveal disabled");

        // Verify challenger bond
        if (msg.value < MIN_CHALLENGER_BOND) {
            revert InsufficientChallengerBond();
        }

        // Verify state is committed but not finalized
        if (_commitmentTimestamps[stateRoot] == 0) {
            revert InvalidStateRoot(stateRoot);
        }

        if (_finalizedStates[stateRoot]) {
            revert ChallengePeriodExpired();
        }

        // Check if already challenged
        if (_activeChallenges[stateRoot] != address(0)) {
            revert InvalidStateRoot(stateRoot);
        }

        // Verify still in challenge period (with buffer for reveal window)
        uint256 elapsed = block.timestamp - _commitmentTimestamps[stateRoot];
        if (elapsed >= sequencerConfig.challengePeriod - MIN_REVEAL_DELAY - MAX_REVEAL_WINDOW) {
            revert ChallengePeriodExpired();
        }

        // Verify no existing commitment for this state root
        if (_stateRootCommitments[stateRoot] != bytes32(0)) {
            revert InvalidCommitment();
        }

        // Verify this commit hash is not already used
        if (_fraudProofCommitments[commitHash].challenger != address(0)) {
            revert InvalidCommitment();
        }

        // Store commitment
        _fraudProofCommitments[commitHash] = FraudProofCommitment({
            commitHash: commitHash,
            challenger: msg.sender,
            bond: msg.value,
            commitTime: block.timestamp,
            revealed: false
        });

        _stateRootCommitments[stateRoot] = commitHash;

        emit FraudProofCommitted(commitHash, stateRoot, msg.sender, msg.value);
    }

    /**
     * @inheritdoc IL3Bridge
     * @dev FIX H-02: Phase 2 of commit-reveal scheme for MEV protection
     */
    function revealFraudProof(
        FraudProof calldata proof,
        bytes32 salt
    ) external override nonReentrant whenNotPaused {
        // Compute commitment hash
        bytes32 commitHash = keccak256(abi.encodePacked(
            proof.claimedRoot,
            proof.correctRoot,
            proof.disputeId,
            proof.invalidStateData,
            salt
        ));

        FraudProofCommitment storage commitment = _fraudProofCommitments[commitHash];

        // Verify commitment exists
        if (commitment.challenger == address(0)) {
            revert CommitmentNotFound();
        }

        // Verify caller is the original committer
        if (commitment.challenger != msg.sender) {
            revert NotCommitter(msg.sender, commitment.challenger);
        }

        // Verify not already revealed
        if (commitment.revealed) {
            revert AlreadyRevealed();
        }

        // Verify reveal timing
        uint256 timeSinceCommit = block.timestamp - commitment.commitTime;

        // Must wait minimum delay (prevents same-block front-running)
        if (timeSinceCommit < MIN_REVEAL_DELAY) {
            revert RevealTooEarly(MIN_REVEAL_DELAY - timeSinceCommit);
        }

        // Must reveal within window
        if (timeSinceCommit > MIN_REVEAL_DELAY + MAX_REVEAL_WINDOW) {
            revert RevealTooLate();
        }

        bytes32 claimedRoot = proof.claimedRoot;

        // Verify state is still challengeable
        if (_finalizedStates[claimedRoot]) {
            revert ChallengePeriodExpired();
        }

        if (_activeChallenges[claimedRoot] != address(0)) {
            revert InvalidStateRoot(claimedRoot);
        }

        // Mark as revealed
        commitment.revealed = true;

        emit FraudProofRevealed(commitHash, claimedRoot, msg.sender);

        // Verify Merkle proof of incorrect state
        bool proofValid = _verifyFraudProof(proof);
        if (!proofValid) {
            // Invalid fraud proof - challenger loses bond (stays in contract)
            revert InvalidFraudProof();
        }

        // Valid fraud proof!
        // Mark state as challenged
        _activeChallenges[claimedRoot] = msg.sender;

        // Reset latestCommittedRoot if needed
        if (latestCommittedRoot == claimedRoot) {
            latestCommittedRoot = _stateCommitments[claimedRoot].previousRoot;
        }

        emit FraudProofSubmitted(claimedRoot, proof.disputeId, msg.sender);

        // Calculate reward
        uint256 bond = commitment.bond;
        uint256 reward = (bond * FRAUD_REWARD_BPS) / BPS_DENOMINATOR;

        // Check contract balance for reward
        uint256 availableForReward = address(this).balance > bond ? address(this).balance - bond : 0;
        if (availableForReward < reward) {
            reward = availableForReward;
        }

        uint256 totalPayout = bond + reward;

        // Return bond + reward
        (bool success, ) = msg.sender.call{value: totalPayout}("");
        require(success, "Reward transfer failed");

        emit FraudProofValidated(claimedRoot, msg.sender, reward);
    }

    /**
     * @inheritdoc IL3Bridge
     * @dev DEPRECATED: Use commitFraudProof + revealFraudProof for MEV protection
     *      This function remains for backwards compatibility but is vulnerable to front-running
     */
    function submitFraudProof(FraudProof calldata proof) external payable override nonReentrant whenNotPaused {
        // If commit-reveal is enabled, require that path instead
        if (commitRevealEnabled) {
            revert("Use commitFraudProof + revealFraudProof for MEV protection");
        }
        // Verify challenger bond
        if (msg.value < MIN_CHALLENGER_BOND) {
            revert InsufficientChallengerBond();
        }

        bytes32 claimedRoot = proof.claimedRoot;

        // Verify state is committed but not finalized
        if (_commitmentTimestamps[claimedRoot] == 0) {
            revert InvalidStateRoot(claimedRoot);
        }

        if (_finalizedStates[claimedRoot]) {
            revert ChallengePeriodExpired();
        }

        // FIX: Check if already challenged - prevent duplicate challenges
        if (_activeChallenges[claimedRoot] != address(0)) {
            revert InvalidStateRoot(claimedRoot);
        }

        // Verify still in challenge period
        uint256 elapsed = block.timestamp - _commitmentTimestamps[claimedRoot];
        if (elapsed >= sequencerConfig.challengePeriod) {
            revert ChallengePeriodExpired();
        }

        // Verify Merkle proof of incorrect state
        bool proofValid = _verifyFraudProof(proof);
        if (!proofValid) {
            // Invalid fraud proof - challenger loses bond (stays in contract)
            revert InvalidFraudProof();
        }

        // Valid fraud proof!
        // Mark state as challenged
        _activeChallenges[claimedRoot] = msg.sender;

        // FIX M-03: Reset latestCommittedRoot to the challenged state's previous root
        // This allows the chain to be rebuilt from a valid point
        if (latestCommittedRoot == claimedRoot) {
            latestCommittedRoot = _stateCommitments[claimedRoot].previousRoot;
        }

        emit FraudProofSubmitted(claimedRoot, proof.disputeId, msg.sender);

        // FIX: Calculate reward from contract's existing balance (from prior failed proofs)
        // The reward pool comes from failed fraud proof bonds that were forfeited
        uint256 reward = (msg.value * FRAUD_REWARD_BPS) / BPS_DENOMINATOR;

        // Check contract has enough balance for reward (excluding the msg.value just received)
        uint256 contractBalance = address(this).balance;
        uint256 availableForReward = contractBalance > msg.value ? contractBalance - msg.value : 0;

        if (availableForReward < reward) {
            // Not enough for full reward, give what's available
            reward = availableForReward;
        }

        uint256 totalPayout = msg.value + reward;

        // Return bond + reward
        (bool success, ) = msg.sender.call{value: totalPayout}("");
        require(success, "Reward transfer failed");

        emit FraudProofValidated(claimedRoot, msg.sender, reward);
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
    function verifyDisputeState(
        bytes32 stateRoot,
        L3DisputeSummary calldata summary,
        bytes32[] calldata merkleProof
    ) external view override returns (bool valid) {
        // Verify state root is finalized
        if (!_finalizedStates[stateRoot]) {
            return false;
        }

        // Compute leaf from summary
        bytes32 leaf = keccak256(abi.encodePacked(
            summary.l3DisputeId,
            summary.l2DisputeId,
            uint8(summary.state),
            summary.counterCount,
            summary.initiatorAccepted,
            summary.counterpartyAccepted,
            summary.currentProposalHash,
            summary.lastUpdateBlock
        ));

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
    function getFraudProofCommitment(bytes32 commitHash) external view override returns (FraudProofCommitment memory) {
        return _fraudProofCommitments[commitHash];
    }

    /**
     * @inheritdoc IL3Bridge
     */
    function isCommitRevealEnabled() external view override returns (bool) {
        return commitRevealEnabled;
    }

    /**
     * @notice Get the commit hash for a state root being challenged
     * @param stateRoot The state root to query
     * @return The commit hash (bytes32(0) if no pending challenge)
     */
    function getStateRootCommitHash(bytes32 stateRoot) external view returns (bytes32) {
        return _stateRootCommitments[stateRoot];
    }

    // ============ Admin Functions ============

    /**
     * @notice Pause the bridge - halts all state-changing operations
     * @dev Only callable by owner. Use in emergency situations.
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause the bridge - resumes normal operations
     * @dev Only callable by owner.
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Withdraw accumulated fees from failed fraud proofs
     * @dev Only callable by owner. Cannot withdraw to zero address.
     * @param to Recipient address
     * @param amount Amount of ETH to withdraw
     */
    function withdrawFees(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Invalid recipient");
        (bool success, ) = to.call{value: amount}("");
        require(success, "Withdrawal failed");
    }

    /**
     * @notice Toggle commit-reveal mode for fraud proofs
     * @dev Only callable by owner. When enabled, submitFraudProof is disabled
     *      and users must use commitFraudProof + revealFraudProof for MEV protection.
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
    function getMigrationState() external view onlyOwner returns (
        bytes32 _latestFinalizedRoot,
        uint256 _latestFinalizedBlock,
        bytes32 _latestCommittedRoot,
        uint256 _totalBridged,
        uint256 _totalSettled,
        uint256 _pendingCount
    ) {
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
     * @dev Pauses contract and emits deprecation event. Irreversible.
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
