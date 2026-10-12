// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "./interfaces/IOracle.sol";

/**
 * @title NatLangChainOracle
 * @notice Trusted off-chain executor that bridges LLM proposals to its dispute contract
 * @dev Implements EIP-712 signature verification for proposal authenticity. The dispute contract (ILRM or
 *      MultiPartyILRM) is read and written only through IOracleConsumer.
 *
 * The Oracle is responsible for:
 * - Receiving proposal requests from ILRM
 * - Coordinating with off-chain LLM Engine
 * - Signing and submitting verified proposals
 * - Ensuring proposal integrity via cryptographic signatures
 */
/**
 * FIX L-NEW-01: Added Ownable2Step for two-step ownership transfer
 * Consistent with I-02 fix applied to other contracts
 */
contract NatLangChainOracle is IOracle, Ownable2Step {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ============ Constants ============

    /// @notice EIP-712 domain separator (cached for gas efficiency)
    bytes32 private immutable _CACHED_DOMAIN_SEPARATOR;

    /// @notice FIX M-05: Store original chain ID to detect forks
    uint256 private immutable _CACHED_CHAIN_ID;

    /**
     * @notice EIP-712 typehash for proposals
     * @dev round = ILRM Dispute.counterCount and evidenceHash = ILRM Dispute.evidenceHash at signing time,
     *      so a counter-proposal or a reset (which bumps the nonce) changes the digest.
     */
    bytes32 public constant PROPOSAL_TYPEHASH =
        keccak256("Proposal(uint256 disputeId,uint256 round,bytes32 evidenceHash,bytes32 proposalHash,uint256 nonce)");

    // ============ State Variables ============

    /// @notice The IOracleConsumer (ILRM or MultiPartyILRM) this oracle serves
    address public override ilrmContract;

    /// @notice Registered oracle operators
    mapping(address => bool) private _isOracle;

    /// @notice Oracle public key hashes for verification
    mapping(address => bytes32) public override oraclePublicKeyHash;

    /// @notice Nonce per dispute to prevent replay attacks
    mapping(uint256 => uint256) public proposalNonces;

    /**
     * @notice Advisory work-queue flag for off-chain operators: a proposal is wanted for the dispute
     * @dev Set by requestProposal and by a reset; cleared by a relay (submitProposal) or by cancelPendingRequest.
     *      Gates nothing: submitProposal does not require it. It can stay true after a dispute times out.
     */
    mapping(uint256 => bool) public pendingRequests;

    /**
     * @notice Proposal admitted per negotiation round: disputeId => round => proposal hash
     * @dev round is the dispute's ILRM counterCount. Zero means the round is still open. Each round admits
     *      exactly one proposal; only the owner's resetProposal re-opens a filled slot of the current round.
     */
    mapping(uint256 => mapping(uint256 => bytes32)) public roundProposals;

    // ============ Events ============

    /// @notice Emitted when a proposal is requested
    event ProposalRequested(uint256 indexed disputeId, bytes32 evidenceHash, uint256 timestamp);

    /// @notice Emitted when proposal is submitted to ILRM
    event ProposalSubmittedToILRM(uint256 indexed disputeId, bytes32 proposalHash, address indexed oracle);

    /// @notice Emitted when a round's proposal slot is filled; nonce is the one the signature consumed
    event ProposalRoundFilled(uint256 indexed disputeId, uint256 indexed round, bytes32 proposalHash, uint256 nonce);

    /// @notice Emitted when the owner voids a round's live proposal and re-opens the slot for one replacement
    event ProposalRoundReopened(uint256 indexed disputeId, uint256 indexed round, bytes32 voidedProposalHash);

    /// @notice Emitted when the owner withdraws the advisory pending-request flag of a dispute
    event ProposalRequestCancelled(uint256 indexed disputeId);

    // ============ Errors ============

    error NotILRM(address caller);
    error NotOracle(address caller);
    error InvalidSignature();
    error ProposalAlreadyProcessed(uint256 disputeId, uint256 round);
    error NoRequestPending(uint256 disputeId);
    error InvalidAddress();
    error NoProposalToReset(uint256 disputeId);
    error NoPendingRequest(uint256 disputeId);
    error DisputeAlreadyResolved(uint256 disputeId);
    error ILRMNotSet();
    error ResolutionDeadlinePassed(uint256 disputeId, uint256 deadline);
    error ProposalMismatch(uint256 disputeId, uint256 round, bytes32 liveProposalHash);

    // ============ Constructor ============

    constructor() Ownable(msg.sender) {
        // FIX M-05: Cache chain ID to detect forks
        _CACHED_CHAIN_ID = block.chainid;
        _CACHED_DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("NatLangChainOracle"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );

        // FIX M-07: Remove auto-registration of deployer as oracle
        // Owner must explicitly register oracles after deployment
        // This prevents issues if deployer key is a temporary deployment wallet
    }

    // ============ Domain Separator ============

    /**
     * @notice Get the EIP-712 domain separator
     * @dev FIX M-05: Computes dynamically if chain ID changed (fork detection)
     * @return The domain separator for the current chain
     */
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        if (block.chainid == _CACHED_CHAIN_ID) {
            return _CACHED_DOMAIN_SEPARATOR;
        }
        // Chain forked - compute new domain separator
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("NatLangChainOracle"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }

    // ============ Modifiers ============

    modifier onlyILRM() {
        if (msg.sender != ilrmContract) revert NotILRM(msg.sender);
        _;
    }

    modifier onlyOracle() {
        if (!_isOracle[msg.sender]) revert NotOracle(msg.sender);
        _;
    }

    // ============ Core Functions ============

    /**
     * @inheritdoc IOracle
     * @dev Sets the advisory pending flag. Makes no external calls (ILRM calls it with a gas cap).
     */
    function requestProposal(uint256 disputeId, bytes32 evidenceHash) external override onlyILRM {
        pendingRequests[disputeId] = true;

        emit ProposalRequested(disputeId, evidenceHash, block.timestamp);
        emit DisputeProcessed(disputeId, evidenceHash, bytes32(0));
    }

    /**
     * @inheritdoc IOracle
     * @dev Called by oracle operator after LLM processing. Admits at most one proposal per round
     *      (ILRM counterCount); every round opened by counterPropose accepts a new proposal without admin action.
     */
    function submitProposal(uint256 disputeId, string calldata proposal, bytes calldata signature)
        external
        override
        onlyOracle
    {
        if (ilrmContract == address(0)) revert ILRMNotSet();

        (uint256 round, bytes32 evidenceHash) = _roundContext(disputeId);
        if (roundProposals[disputeId][round] != bytes32(0)) {
            revert ProposalAlreadyProcessed(disputeId, round);
        }

        bytes32 proposalHash = keccak256(bytes(proposal));

        // FIX C-02: Signature is REQUIRED, not optional
        // Empty signature must revert - no bypass allowed
        if (signature.length == 0) {
            revert InvalidSignature();
        }
        uint256 nonce = proposalNonces[disputeId];
        if (!_isOracle[_digest(disputeId, round, evidenceHash, proposalHash, nonce).recover(signature)]) {
            revert InvalidSignature();
        }

        // Fill this round's slot before the external call; any ILRM revert rolls it back
        roundProposals[disputeId][round] = proposalHash;
        pendingRequests[disputeId] = false;

        // No re-entry: the consumer calls back only verifySignature (view, STATICCALL); submitProposal is
        // onlyOracle; this round's slot is already filled; the consumer's submitLLMProposal is nonReentrant.
        IOracleConsumer(ilrmContract).submitLLMProposal(disputeId, proposal, signature);

        // Consume the nonce only after ILRM has re-verified the signature via verifySignature(),
        // which hashes the current nonce; bumping it earlier makes that check always fail.
        // slither-disable-next-line reentrancy-no-eth
        proposalNonces[disputeId] = nonce + 1;

        emit ProposalSubmittedToILRM(disputeId, proposalHash, msg.sender);
        emit ProposalRoundFilled(disputeId, round, proposalHash, nonce);
        emit DisputeProcessed(disputeId, evidenceHash, proposalHash);
    }

    /**
     * @inheritdoc IOracle
     * @dev Verifies against the dispute's current round, evidence and nonce. Returns false while no ILRM is set.
     */
    function verifySignature(uint256 disputeId, bytes32 proposalHash, bytes calldata signature)
        public
        view
        override
        returns (bool valid)
    {
        if (ilrmContract == address(0)) return false;
        return _isOracle[proposalDigest(disputeId, proposalHash).recover(signature)];
    }

    /**
     * @notice Verify signature with explicit signer check
     * @dev Verifies against the dispute's current round, evidence and nonce. Returns false while no ILRM is set.
     * @param disputeId The dispute ID
     * @param proposalHash Hash of the proposal
     * @param signature Signature to verify
     * @param expectedSigner Expected signer address
     * @return valid True if signature is valid from expected signer
     */
    function verifySignatureFrom(
        uint256 disputeId,
        bytes32 proposalHash,
        bytes calldata signature,
        address expectedSigner
    ) external view returns (bool valid) {
        if (!_isOracle[expectedSigner] || ilrmContract == address(0)) return false;
        return proposalDigest(disputeId, proposalHash).recover(signature) == expectedSigner;
    }

    // ============ View Functions ============

    /**
     * @inheritdoc IOracle
     */
    function isOracle(address account) external view override returns (bool) {
        return _isOracle[account];
    }

    /**
     * @notice Check if a proposal request is pending
     * @dev Advisory work-queue flag: set by requestProposal and by a reset, cleared by a relay or a cancel.
     *      Gates nothing, and can stay true after a dispute times out.
     * @param disputeId The dispute ID
     * @return True if request is pending
     */
    function isPending(uint256 disputeId) external view returns (bool) {
        return pendingRequests[disputeId];
    }

    /**
     * @notice Get the current nonce for a dispute
     * @param disputeId The dispute ID
     * @return Current nonce
     */
    function getNonce(uint256 disputeId) external view returns (uint256) {
        return proposalNonces[disputeId];
    }

    /**
     * @notice The EIP-712 digest an operator must sign right now to propose `proposalHash` for a dispute
     * @dev Uses the live context: the consumer's counterCount (round), evidenceHash and the current nonce
     * @param disputeId The dispute ID
     * @param proposalHash keccak256 of the proposal text
     * @return The EIP-712 digest
     */
    function proposalDigest(uint256 disputeId, bytes32 proposalHash) public view returns (bytes32) {
        if (ilrmContract == address(0)) revert ILRMNotSet();
        (uint256 round, bytes32 evidenceHash) = _roundContext(disputeId);
        return _digest(disputeId, round, evidenceHash, proposalHash, proposalNonces[disputeId]);
    }

    /**
     * @notice The signing context of a dispute's current round
     * @param disputeId The dispute ID
     * @return round The dispute's counterCount in the consumer
     * @return evidenceHash The dispute's current evidenceHash in the consumer
     * @return nonce The nonce the next signature must use
     * @return open True if the current round has no proposal yet
     */
    function proposalContext(uint256 disputeId)
        external
        view
        returns (uint256 round, bytes32 evidenceHash, uint256 nonce, bool open)
    {
        if (ilrmContract == address(0)) revert ILRMNotSet();
        (round, evidenceHash) = _roundContext(disputeId);
        nonce = proposalNonces[disputeId];
        open = roundProposals[disputeId][round] == bytes32(0);
    }

    /**
     * @notice The proposal admitted in the dispute's current round (zero if none)
     * @dev Kept for ABI compatibility; returns zero while no ILRM is set
     * @param disputeId The dispute ID
     * @return The current round's proposal hash
     */
    function processedProposals(uint256 disputeId) external view returns (bytes32) {
        if (ilrmContract == address(0)) return bytes32(0);
        (uint256 round,) = _roundContext(disputeId);
        return roundProposals[disputeId][round];
    }

    // ============ Admin Functions ============

    /**
     * @notice Set the dispute contract this oracle serves
     * @dev The consumer must implement IOracleConsumer (ILRM or MultiPartyILRM) and must have been deployed with
     *      this Oracle as its oracle. Re-pointing to a different consumer whose dispute IDs overlap is unsupported:
     *      round slots and nonces are keyed by disputeId only, so a slot the old consumer filled blocks
     *      submitProposal for the new consumer's dispute with the same ID in that round. resetProposal reads the
     *      new consumer, so it clears such a slot only while it is the slot of that dispute's current round and the
     *      dispute is unresolved and at or before its resolution deadline (an ID the new consumer never created has
     *      start time 0, so its deadline has long passed and the reset reverts); the consumer's void hook also
     *      reverts if it holds a different live proposal. Give a consumer with overlapping dispute IDs a fresh
     *      Oracle instead.
     * @param _ilrm New consumer address
     */
    function setILRM(address _ilrm) external onlyOwner {
        if (_ilrm == address(0)) revert InvalidAddress();
        ilrmContract = _ilrm;
    }

    /**
     * @notice Register a new oracle operator
     * @param oracle Oracle address
     * @param publicKeyHash Hash of oracle's public key
     */
    function registerOracle(address oracle, bytes32 publicKeyHash) external onlyOwner {
        if (oracle == address(0)) revert InvalidAddress();
        _isOracle[oracle] = true;
        oraclePublicKeyHash[oracle] = publicKeyHash;
        emit OracleRegistered(oracle, publicKeyHash);
    }

    /**
     * @notice Revoke an oracle operator
     * @param oracle Oracle address to revoke
     */
    function revokeOracle(address oracle) external onlyOwner {
        _isOracle[oracle] = false;
        oraclePublicKeyHash[oracle] = bytes32(0);
    }

    // ============ Recovery Functions ============

    /// @notice Emitted when a proposal is reset for re-submission
    event ProposalReset(uint256 indexed disputeId, bytes32 oldProposalHash, string reason);

    /**
     * @notice Owner recovery: void the live proposal of the dispute's CURRENT round and allow exactly one
     *         replacement
     * @dev FIX HIGH: Provides recovery mechanism for malicious/incorrect proposals.
     *      Voids the proposal in the consumer in the same transaction (IOracleConsumer.voidLLMProposal clears the
     *      text and every acceptance), re-opens the round's slot and bumps the nonce, so every signature made
     *      before the reset is dead. Reverts after the consumer's resolution deadline (let enforceTimeout run).
     *      Acts on whatever proposal is live when it executes: behind a timelock, prefer resetProposalExact.
     *      Not needed between rounds: counterPropose opens a new round.
     *      Revoke a compromised operator BEFORE resetting.
     * @param disputeId The dispute ID to reset
     * @param reason Human-readable reason for the reset
     */
    function resetProposal(uint256 disputeId, string calldata reason) external onlyOwner {
        _resetProposal(disputeId, false, 0, bytes32(0), reason);
    }

    /**
     * @notice Pinned owner recovery: like resetProposal, but only voids the named proposal of the named round
     * @dev Safe to queue behind a timelock: if a counter-proposal or another proposal has landed by execution time,
     *      it reverts ProposalMismatch instead of voiding a proposal nobody reviewed.
     * @param disputeId The dispute ID to reset
     * @param expectedRound The round (consumer counterCount) the proposal was admitted in
     * @param expectedProposalHash keccak256 of the proposal text to void (Oracle.roundProposals)
     * @param reason Human-readable reason for the reset
     */
    function resetProposalExact(
        uint256 disputeId,
        uint256 expectedRound,
        bytes32 expectedProposalHash,
        string calldata reason
    ) external onlyOwner {
        _resetProposal(disputeId, true, expectedRound, expectedProposalHash, reason);
    }

    /**
     * @notice Withdraw the advisory pending-request flag of a dispute
     * @dev Advisory only: it does not block submitProposal. Revoke operators to stop proposals.
     * @param disputeId The dispute ID to cancel
     */
    function cancelPendingRequest(uint256 disputeId) external onlyOwner {
        if (!pendingRequests[disputeId]) revert NoPendingRequest(disputeId);
        pendingRequests[disputeId] = false;
        emit ProposalRequestCancelled(disputeId);
    }

    /**
     * @notice Update oracle's public key hash
     * @param oracle Oracle address
     * @param publicKeyHash New public key hash
     */
    function updateOracleKey(address oracle, bytes32 publicKeyHash) external onlyOwner {
        if (!_isOracle[oracle]) revert NotOracle(oracle);
        oraclePublicKeyHash[oracle] = publicKeyHash;
        emit OracleRegistered(oracle, publicKeyHash);
    }

    // ============ Internal Functions ============

    /**
     * @dev Shared body of resetProposal and resetProposalExact. Checks, then effects, then the consumer's void hook
     *      as the LAST statement: a revert there (e.g. the consumer holds a different live proposal) rolls the
     *      whole reset back, so the Oracle slot and the consumer's proposal are always voided together.
     */
    function _resetProposal(
        uint256 disputeId,
        bool pinned,
        uint256 expectedRound,
        bytes32 expectedProposalHash,
        string calldata reason
    ) internal {
        if (ilrmContract == address(0)) revert ILRMNotSet();

        (uint256 round,, bool resolved, uint256 deadline) = _consumerContext(disputeId);
        if (resolved) revert DisputeAlreadyResolved(disputeId);

        // Only the current round's live proposal can be voided; earlier rounds were already cleared by
        // counterPropose, and an empty round has nothing to reset
        bytes32 oldHash = roundProposals[disputeId][round];
        if (oldHash == bytes32(0)) revert NoProposalToReset(disputeId);
        if (pinned && (round != expectedRound || oldHash != expectedProposalHash)) {
            revert ProposalMismatch(disputeId, round, oldHash);
        }
        // After the deadline no replacement could land; only enforceTimeout may change the dispute
        if (block.timestamp > deadline) revert ResolutionDeadlinePassed(disputeId, deadline);

        // Re-open this round's slot for one replacement and kill every pre-reset signature
        roundProposals[disputeId][round] = bytes32(0);
        pendingRequests[disputeId] = true;
        proposalNonces[disputeId]++;

        emit ProposalReset(disputeId, oldHash, reason);
        emit ProposalRoundReopened(disputeId, round, oldHash);

        // Void the text and every acceptance in the consumer (compare-and-clear). Last statement: no state
        // writes or events follow, and the consumer's hook is oracle-only and nonReentrant.
        IOracleConsumer(ilrmContract).voidLLMProposal(disputeId, oldHash);
    }

    /**
     * @dev The consumer's full oracle context (STATICCALL). Returns the whole tuple so the external call's
     *      return values are never partially discarded.
     */
    function _consumerContext(uint256 disputeId)
        internal
        view
        returns (uint256 round, bytes32 evidenceHash, bool resolved, uint256 deadline)
    {
        return IOracleConsumer(ilrmContract).oracleContext(disputeId);
    }

    /// @dev The dispute's current round (consumer counterCount) and evidence hash
    function _roundContext(uint256 disputeId) internal view returns (uint256 round, bytes32 evidenceHash) {
        (round, evidenceHash,,) = _consumerContext(disputeId);
    }

    /// @dev EIP-712 digest of a Proposal(disputeId, round, evidenceHash, proposalHash, nonce)
    function _digest(uint256 disputeId, uint256 round, bytes32 evidenceHash, bytes32 proposalHash, uint256 nonce)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR(),
                keccak256(abi.encode(PROPOSAL_TYPEHASH, disputeId, round, evidenceHash, proposalHash, nonce))
            )
        );
    }
}
