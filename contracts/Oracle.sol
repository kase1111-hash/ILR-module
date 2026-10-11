// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "./interfaces/IOracle.sol";
import "./interfaces/IILRM.sol";

/**
 * @title NatLangChainOracle
 * @notice Trusted off-chain executor that bridges LLM proposals to ILRM
 * @dev Implements EIP-712 signature verification for proposal authenticity
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

    /// @notice The ILRM contract this oracle serves
    address public override ilrmContract;

    /// @notice Registered oracle operators
    mapping(address => bool) private _isOracle;

    /// @notice Oracle public key hashes for verification
    mapping(address => bytes32) public override oraclePublicKeyHash;

    /// @notice Nonce per dispute to prevent replay attacks
    mapping(uint256 => uint256) public proposalNonces;

    /// @notice Pending proposal requests
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
     * @dev Called by ILRM when dispute enters Active state
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

        // No re-entry: ILRM calls back only verifySignature (view, STATICCALL); submitProposal is onlyOracle;
        // this round's slot is already filled; ILRM.submitLLMProposal is nonReentrant.
        IILRM(ilrmContract).submitLLMProposal(disputeId, proposal, signature);

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
     * @dev Uses the live context: ILRM counterCount (round), ILRM evidenceHash and the current nonce
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
     * @return round The dispute's ILRM counterCount
     * @return evidenceHash The dispute's current ILRM evidenceHash
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
     * @notice Set the ILRM contract address
     * @dev Re-pointing to a different ILRM whose dispute IDs overlap is unsupported (round slots and nonces are
     *      keyed by disputeId only); use resetProposal to clear a stale slot.
     * @param _ilrm New ILRM address
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
     *      Bumps the nonce, so every signature made before the reset is dead. The voided text stays in ILRM, and
     *      stays acceptable, until the replacement lands. ILRM then supersedes it and clears both acceptances.
     *      Not needed between rounds: counterPropose opens a new round.
     *      Revoke a compromised operator BEFORE resetting.
     * @param disputeId The dispute ID to reset
     * @param reason Human-readable reason for the reset
     */
    function resetProposal(uint256 disputeId, string calldata reason) external onlyOwner {
        if (ilrmContract == address(0)) revert ILRMNotSet();

        IILRM.Dispute memory d = IILRM(ilrmContract).disputes(disputeId);
        if (d.resolved) revert DisputeAlreadyResolved(disputeId);

        // Only the current round's live proposal can be voided; earlier rounds were already cleared by
        // counterPropose, and an empty round has nothing to reset
        uint256 round = d.counterCount;
        bytes32 oldHash = roundProposals[disputeId][round];
        if (oldHash == bytes32(0)) revert NoProposalToReset(disputeId);

        // Re-open this round's slot for one replacement
        roundProposals[disputeId][round] = bytes32(0);
        pendingRequests[disputeId] = true;

        // Increment nonce to invalidate any old signatures
        proposalNonces[disputeId]++;

        emit ProposalReset(disputeId, oldHash, reason);
        emit ProposalRoundReopened(disputeId, round, oldHash);
    }

    /**
     * @notice Emergency cancel a pending request
     * @dev Prevents disputes from being stuck if oracle is unavailable
     * @param disputeId The dispute ID to cancel
     */
    function cancelPendingRequest(uint256 disputeId) external onlyOwner {
        if (!pendingRequests[disputeId]) revert NoPendingRequest(disputeId);
        pendingRequests[disputeId] = false;
        emit ProposalRequested(disputeId, bytes32(0), 0); // Emit with zero values to indicate cancellation
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
     * @dev The dispute's current round (ILRM counterCount) and evidence hash, read through the IILRM.disputes view
     *      (STATICCALL). Fields are accessed by name only.
     */
    function _roundContext(uint256 disputeId) internal view returns (uint256 round, bytes32 evidenceHash) {
        IILRM.Dispute memory d = IILRM(ilrmContract).disputes(disputeId);
        return (d.counterCount, d.evidenceHash);
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
