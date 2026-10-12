// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/**
 * @title IMultiPartyILRM - Multi-Party IP & Licensing Reconciliation Module Interface
 * @notice Interface for multi-party dispute resolution (3+ parties)
 * @dev Extends ILRM concepts for N-party disputes with quorum-based acceptance
 *
 * Key differences from standard ILRM:
 * - Dynamic party array instead of initiator/counterparty
 * - Quorum-based acceptance (configurable, default unanimous)
 * - Per-party stake tracking
 * - Proportional resolution
 */
interface IMultiPartyILRM {
    // ============ Enums ============

    /// @notice Possible outcomes for a multi-party dispute
    enum MultiPartyOutcome {
        Pending, // Dispute in progress
        QuorumAccepted, // Quorum of parties accepted proposal
        TimeoutWithBurn, // Timeout reached, stakes proportionally burned
        Cancelled, // Dispute cancelled (all parties agree)
        PartialResolution // Some parties resolved, others in fallback
    }

    /// @notice Quorum type for acceptance
    enum QuorumType {
        Unanimous, // All parties must accept (default)
        SuperMajority, // 2/3 of parties (67%)
        SimpleMajority, // More than half (51%)
        Custom // Custom threshold set at creation
    }

    // ============ Structs ============

    /// @notice Fallback license terms (same as ILRM)
    struct FallbackLicense {
        bytes32 termsHash;
        uint256 duration;
        uint256 royaltyCap;
        bool nonExclusive;
    }

    /// @notice Party information in a dispute
    struct PartyInfo {
        address partyAddress;
        uint256 stake;
        bool hasStaked;
        bool hasAccepted;
        bool hasRejected;
        bytes32 evidenceHash; // Optional per-party evidence
        uint256 joinedAt;
    }

    /// @notice Multi-party dispute configuration
    struct DisputeConfig {
        QuorumType quorumType;
        uint256 customQuorumBps; // Custom quorum in basis points (e.g., 7500 = 75%)
        uint256 minParties; // Minimum parties required to proceed
        uint256 maxParties; // Maximum allowed parties
        uint256 stakeWindow; // Time for parties to stake
        uint256 resolutionTimeout; // Time to reach resolution
        bool allowLateJoin; // Can parties join after initiation?
    }

    /// @notice Full multi-party dispute state
    struct MultiPartyDispute {
        uint256 id;
        address initiator;
        uint256 baseStake;
        uint256 totalStaked;
        uint256 startTime;
        bytes32 evidenceHash; // Aggregated evidence hash
        string llmProposal;
        uint256 acceptanceCount;
        uint256 rejectionCount;
        bool resolved;
        MultiPartyOutcome outcome;
        FallbackLicense fallbackLicense;
        uint256 counterCount;
        DisputeConfig config;
    }

    // ============ Events ============

    /// @notice Emitted when multi-party dispute is created
    event MultiPartyDisputeCreated(
        uint256 indexed disputeId, address indexed initiator, uint256 partyCount, QuorumType quorumType
    );

    /// @notice Emitted when a party joins the dispute
    event PartyJoined(uint256 indexed disputeId, address indexed party, uint256 partyIndex);

    /// @notice Emitted when a party stakes
    event PartyStaked(uint256 indexed disputeId, address indexed party, uint256 amount);

    /// @notice Emitted when a party accepts
    event PartyAccepted(
        uint256 indexed disputeId, address indexed party, uint256 acceptanceCount, uint256 requiredForQuorum
    );

    /// @notice Emitted when a party rejects
    event PartyRejected(uint256 indexed disputeId, address indexed party, uint256 rejectionCount);

    /// @notice Emitted when quorum is reached
    event QuorumReached(uint256 indexed disputeId, uint256 acceptanceCount, uint256 totalParties);

    /// @notice Emitted when dispute is resolved
    event MultiPartyResolved(uint256 indexed disputeId, MultiPartyOutcome outcome, uint256 burnAmount);

    /// @notice Emitted when evidence is aggregated
    event EvidenceAggregated(uint256 indexed disputeId, address indexed party, bytes32 newAggregateHash);

    /// @notice Emitted when the oracle submits an LLM proposal (same signature as IILRM)
    event ProposalSubmitted(uint256 indexed disputeId, string proposal);

    /// @notice Emitted only if an oracle relays a proposal over a live one in the same round; every vote on the
    ///         previous proposal is void (same signature as IILRM)
    event ProposalSuperseded(
        uint256 indexed disputeId, uint256 indexed round, bytes32 previousProposalHash, bytes32 newProposalHash
    );

    /// @notice Emitted when a counter-proposal opens a new round (same signature as IILRM)
    event CounterProposed(uint256 indexed disputeId, address indexed party, uint256 counterNumber);

    // ============ Core Functions ============

    /**
     * @notice Create a new multi-party dispute
     * @param parties Initial list of party addresses
     * @param baseStake Required stake per party
     * @param evidenceHash Initial evidence hash
     * @param fallbackTerms Fallback license on timeout
     * @param config Dispute configuration
     * @return disputeId The unique dispute identifier
     */
    function createMultiPartyDispute(
        address[] calldata parties,
        uint256 baseStake,
        bytes32 evidenceHash,
        FallbackLicense calldata fallbackTerms,
        DisputeConfig calldata config
    ) external returns (uint256 disputeId);

    /**
     * @notice Join an existing dispute (if allowLateJoin is true)
     * @param disputeId The dispute to join
     */
    function joinDispute(uint256 disputeId) external;

    /**
     * @notice Deposit stake to participate in dispute
     * @param disputeId The dispute ID
     */
    function depositStake(uint256 disputeId) external;

    /**
     * @notice Submit evidence for the dispute
     * @dev Oracle signatures bind the aggregate evidence hash, so evidence changes are limited: staked parties only,
     *      at or before the resolution deadline, never while a proposal is live, and once per party per round
     *      (counterPropose opens a new round).
     * @param disputeId The dispute ID
     * @param evidenceHash Party's evidence hash
     */
    function submitEvidence(uint256 disputeId, bytes32 evidenceHash) external;

    /**
     * @notice Accept the LLM proposal
     * @dev Accepts whatever proposal is live when the tx executes; prefer acceptProposalWithHash
     * @param disputeId The dispute ID
     */
    function acceptProposal(uint256 disputeId) external;

    /**
     * @notice Accept the live LLM proposal only if it is the one the caller reviewed
     * @dev Reverts "Proposal changed" unless keccak256(live proposal) == proposalHash
     * @param disputeId The dispute ID
     * @param proposalHash keccak256 of the proposal text being accepted
     */
    function acceptProposalWithHash(uint256 disputeId, bytes32 proposalHash) external;

    /**
     * @notice Reject the LLM proposal
     * @dev Reverts "Timeout passed" after the resolution deadline (only enforceTimeout may change the dispute then)
     * @param disputeId The dispute ID
     */
    function rejectProposal(uint256 disputeId) external;

    /**
     * @notice Submit counter-proposal (triggers new LLM round)
     * @dev Requires every party staked; reverts "Timeout passed" after the resolution deadline
     * @param disputeId The dispute ID
     * @param newEvidenceHash Updated evidence
     */
    function counterPropose(uint256 disputeId, bytes32 newEvidenceHash) external payable;

    /**
     * @notice Enforce timeout resolution
     * @param disputeId The timed-out dispute
     */
    function enforceTimeout(uint256 disputeId) external;

    // ============ View Functions ============

    /**
     * @notice Get dispute details
     * @param disputeId The dispute ID
     * @return dispute The dispute state
     */
    function getDispute(uint256 disputeId) external view returns (MultiPartyDispute memory dispute);

    /**
     * @notice Get all parties in a dispute
     * @param disputeId The dispute ID
     * @return parties Array of party info
     */
    function getParties(uint256 disputeId) external view returns (PartyInfo[] memory parties);

    /**
     * @notice Get a specific party's info
     * @param disputeId The dispute ID
     * @param party The party address
     * @return info Party information
     */
    function getPartyInfo(uint256 disputeId, address party) external view returns (PartyInfo memory info);

    /**
     * @notice Check if quorum has been reached
     * @param disputeId The dispute ID
     * @return reached True if quorum reached
     * @return current Current acceptance count
     * @return required Required for quorum
     */
    function checkQuorum(uint256 disputeId) external view returns (bool reached, uint256 current, uint256 required);

    /**
     * @notice Get required acceptances for quorum
     * @param disputeId The dispute ID
     * @return required Number of acceptances needed
     */
    function getQuorumRequirement(uint256 disputeId) external view returns (uint256 required);

    /**
     * @notice Check if address is party to dispute
     * @param disputeId The dispute ID
     * @param account The address to check
     * @return isParty True if account is a party
     */
    function isParty(uint256 disputeId, address account) external view returns (bool isParty);

    /**
     * @notice Get total dispute count
     * @return count Total disputes created
     */
    function disputeCount() external view returns (uint256 count);
}
