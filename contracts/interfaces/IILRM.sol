// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/**
 * @title IILRM - IP & Licensing Reconciliation Module Interface
 * @notice Interface for the core ILRM dispute resolution contract
 * @dev Implements the NatLangChain Protocol Specification v1.1
 */
interface IILRM {
    // ============ Enums ============

    /// @notice Possible outcomes for a dispute
    enum DisputeOutcome {
        Pending,              // Dispute in progress
        AcceptedProposal,     // Both parties accepted LLM proposal
        TimeoutWithBurn,      // Timeout reached, stakes partially burned
        DefaultLicenseApplied // Counterparty failed to stake
    }

    // ============ Structs ============

    /// @notice Fallback license terms applied on timeout/default
    struct FallbackLicense {
        bytes32 termsHash;     // IPFS hash or on-chain reference to license terms
        uint256 duration;      // Time-limited grant in seconds
        uint256 royaltyCap;    // Maximum royalty in basis points (e.g., 500 = 5%)
        bool nonExclusive;     // Must be true per spec
    }

    /// @notice Full dispute state
    struct Dispute {
        address initiator;
        address counterparty;
        uint256 initiatorStake;
        uint256 counterpartyStake;
        uint256 startTime;
        bytes32 evidenceHash;
        string llmProposal;
        bool initiatorAccepted;
        bool counterpartyAccepted;
        bool resolved;
        DisputeOutcome outcome;
        FallbackLicense fallback;
        uint256 counterCount;
    }

    // ============ Events ============

    /// @notice Emitted when a dispute is initiated
    event DisputeInitiated(
        uint256 indexed disputeId,
        address indexed initiator,
        address indexed counterparty,
        bytes32 evidenceHash
    );

    /// @notice Emitted when counterparty deposits matching stake
    event StakeDeposited(
        uint256 indexed disputeId,
        address indexed depositor,
        uint256 amount
    );

    /// @notice Emitted when oracle submits LLM proposal
    event ProposalSubmitted(
        uint256 indexed disputeId,
        string proposal
    );

    /// @notice Emitted when a party accepts the proposal
    event AcceptanceSignaled(
        uint256 indexed disputeId,
        address indexed party
    );

    /// @notice Emitted when a counter-proposal is submitted
    event CounterProposed(
        uint256 indexed disputeId,
        address indexed party,
        uint256 counterNumber
    );

    /// @notice Emitted when stakes are burned on timeout
    event StakesBurned(
        uint256 indexed disputeId,
        uint256 burnAmount
    );

    /// @notice Emitted when fallback license is applied
    event DefaultLicenseApplied(uint256 indexed disputeId);

    /// @notice Emitted when dispute is fully resolved
    event DisputeResolved(
        uint256 indexed disputeId,
        DisputeOutcome outcome
    );

    /// @notice Emitted when tokens are deposited to reserves for incentives
    event TokenReservesDeposited(
        address indexed depositor,
        uint256 amount
    );

    /// @notice Emitted when harassment score is updated
    event HarassmentScoreUpdated(
        address indexed participant,
        uint256 oldScore,
        uint256 newScore
    );

    /// @notice Emitted when treasury is withdrawn (L-02)
    event TreasuryWithdrawn(
        address indexed recipient,
        uint256 amount
    );

    /// @notice Emitted when ZK identity is registered for a dispute
    event ZKIdentityRegistered(
        uint256 indexed disputeId,
        bytes32 indexed identityHash,
        bool isInitiator
    );

    /// @notice Emitted when ZK proof is used for acceptance
    event ZKProofAcceptance(
        uint256 indexed disputeId,
        bytes32 indexed identityHash
    );

    /// @notice Emitted when identity verifier is updated
    event IdentityVerifierUpdated(
        address indexed oldVerifier,
        address indexed newVerifier
    );

    // ============ Core Functions ============

    /**
     * @notice Initiate a breach/drift dispute (adversarial flow)
     * @dev Initiator MUST stake first (Invariant 3: Initiator Risk Precedence)
     * @param counterparty The opposing party
     * @param stakeAmount Base stake amount (may be escalated)
     * @param evidenceHash Hash of canonicalized evidence bundle
     * @param fallbackTerms Fallback license applied on timeout
     * @return disputeId The unique dispute identifier
     */
    function initiateBreachDispute(
        address counterparty,
        uint256 stakeAmount,
        bytes32 evidenceHash,
        FallbackLicense calldata fallbackTerms
    ) external returns (uint256 disputeId);

    /**
     * @notice Initiate a voluntary reconciliation request (non-adversarial)
     * @dev Burns fee immediately; counterparty can ignore for free (Invariant 2)
     * @param counterparty The party being requested
     * @param evidenceHash Hash of canonicalized evidence bundle
     */
    function initiateVoluntaryRequest(
        address counterparty,
        bytes32 evidenceHash
    ) external payable;

    /**
     * @notice Counterparty deposits matching stake within stake window
     * @param disputeId The dispute to stake into
     */
    function depositStake(uint256 disputeId) external;

    /**
     * @notice Oracle submits LLM-generated proposal
     * @dev Only callable by registered oracle
     * @param disputeId The dispute receiving the proposal
     * @param proposal JSON-encoded reconciliation proposal
     * @param signature Oracle signature for verification
     */
    function submitLLMProposal(
        uint256 disputeId,
        string calldata proposal,
        bytes calldata signature
    ) external;

    /**
     * @notice Accept the current LLM proposal
     * @dev Dispute resolves when both parties accept
     * @param disputeId The dispute to accept
     */
    function acceptProposal(uint256 disputeId) external;

    /**
     * @notice Submit a counter-proposal with updated evidence
     * @dev Fee increases exponentially; max 3 counters (Invariant 4)
     * @param disputeId The dispute to counter
     * @param newEvidenceHash Updated evidence bundle hash
     */
    function counterPropose(
        uint256 disputeId,
        bytes32 newEvidenceHash
    ) external payable;

    /**
     * @notice Enforce timeout resolution after T_resolution expires
     * @dev Anyone can call; applies burn + fallback license
     * @param disputeId The timed-out dispute
     */
    function enforceTimeout(uint256 disputeId) external;

    // ============ View Functions ============

    /**
     * @notice Get dispute details
     * @param disputeId The dispute to query
     * @return The dispute struct
     */
    function disputes(uint256 disputeId) external view returns (
        address initiator,
        address counterparty,
        uint256 initiatorStake,
        uint256 counterpartyStake,
        uint256 startTime,
        bytes32 evidenceHash,
        string memory llmProposal,
        bool initiatorAccepted,
        bool counterpartyAccepted,
        bool resolved,
        DisputeOutcome outcome,
        FallbackLicense memory fallbackLicense,
        uint256 counterCount
    );

    /**
     * @notice Get total dispute count
     * @return Total number of disputes created
     */
    function disputeCounter() external view returns (uint256);

    /**
     * @notice Alias for disputeCounter
     * @return Total number of disputes created
     */
    function getDisputeCount() external view returns (uint256);

    // ============ ZK Identity Functions ============

    /**
     * @notice Get the ZK identity hash for a party in a dispute
     * @param disputeId The dispute ID
     * @param isInitiator True for initiator, false for counterparty
     * @return The identity hash (0 if not registered)
     */
    function getZKIdentity(
        uint256 disputeId,
        bool isInitiator
    ) external view returns (bytes32);

    /**
     * @notice Check if ZK identity mode is enabled for a dispute
     * @param disputeId The dispute ID
     * @return True if ZK mode is enabled
     */
    function isZKModeEnabled(uint256 disputeId) external view returns (bool);
}
