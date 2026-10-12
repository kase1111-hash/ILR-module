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
        Pending, // Dispute in progress
        AcceptedProposal, // Both parties accepted LLM proposal
        TimeoutWithBurn, // Timeout reached, stakes partially burned
        DefaultLicenseApplied // Counterparty failed to stake
    }

    // ============ Structs ============

    /// @notice Fallback license terms applied on timeout/default
    struct FallbackLicense {
        bytes32 termsHash; // IPFS hash or on-chain reference to license terms
        uint256 termDuration; // Time-limited grant in seconds
        uint256 royaltyCapBps; // Maximum royalty in basis points (e.g., 500 = 5%)
        bool nonExclusive; // Must be true per spec
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
        FallbackLicense fallbackLicense;
        uint256 counterCount;
    }

    // ============ Events ============

    /// @notice Emitted when a dispute is initiated
    event DisputeInitiated(
        uint256 indexed disputeId, address indexed initiator, address indexed counterparty, bytes32 evidenceHash
    );

    /// @notice Emitted when counterparty deposits matching stake
    event StakeDeposited(uint256 indexed disputeId, address indexed depositor, uint256 amount);

    /// @notice Emitted when oracle submits LLM proposal
    event ProposalSubmitted(uint256 indexed disputeId, string proposal);

    /// @notice Emitted only if an oracle relays a proposal over a live one in the same round; all acceptances of the
    ///         previous proposal are void. NatLangChainOracle voids the live proposal first (ProposalVoided), so its
    ///         replacements emit only ProposalSubmitted.
    event ProposalSuperseded(
        uint256 indexed disputeId, uint256 indexed round, bytes32 previousProposalHash, bytes32 newProposalHash
    );

    /// @notice Emitted when a party accepts the proposal
    event AcceptanceSignaled(uint256 indexed disputeId, address indexed party);

    /// @notice Emitted when a counter-proposal is submitted
    event CounterProposed(uint256 indexed disputeId, address indexed party, uint256 counterNumber);

    /// @notice Emitted when stakes are burned on timeout
    event StakesBurned(uint256 indexed disputeId, uint256 burnAmount);

    /// @notice Emitted when fallback license is applied
    event DefaultLicenseApplied(uint256 indexed disputeId);

    /// @notice Emitted when dispute is fully resolved
    event DisputeResolved(uint256 indexed disputeId, DisputeOutcome outcome);

    /// @notice Emitted when tokens are deposited to reserves for incentives
    event TokenReservesDeposited(address indexed depositor, uint256 amount);

    /// @notice Emitted when harassment score is updated
    event HarassmentScoreUpdated(address indexed participant, uint256 oldScore, uint256 newScore);

    /// @notice Emitted when treasury is withdrawn (L-02)
    event TreasuryWithdrawn(address indexed recipient, uint256 amount);

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
    function initiateVoluntaryRequest(address counterparty, bytes32 evidenceHash) external payable;

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
    function submitLLMProposal(uint256 disputeId, string calldata proposal, bytes calldata signature) external;

    /**
     * @notice Accept the current LLM proposal
     * @dev Accepts whatever proposal is live when the tx executes; prefer acceptProposalWithHash.
     *      Dispute resolves when both parties accept.
     * @param disputeId The dispute to accept
     */
    function acceptProposal(uint256 disputeId) external;

    /**
     * @notice Accept the live LLM proposal only if it is the one the caller reviewed
     * @dev Reverts "Proposal changed" unless keccak256(live proposal) == proposalHash. That covers voided, replaced
     *      and later-round text (with no live proposal it reverts "No proposal yet"). Clients should prefer it over
     *      acceptProposal. Identical text in a later round is accepted (same terms).
     *      Dispute resolves when both parties accept.
     * @param disputeId The dispute to accept
     * @param proposalHash keccak256 of the proposal text being accepted
     */
    function acceptProposalWithHash(uint256 disputeId, bytes32 proposalHash) external;

    /**
     * @notice Submit a counter-proposal with updated evidence
     * @dev Fee increases exponentially; max 3 counters (Invariant 4). Reverts "Timeout passed" after the
     *      resolution deadline, so a counter cannot revive a timed-out dispute.
     * @param disputeId The dispute to counter
     * @param newEvidenceHash Updated evidence bundle hash
     */
    function counterPropose(uint256 disputeId, bytes32 newEvidenceHash) external payable;

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
     * @return The full dispute struct
     */
    function disputes(uint256 disputeId) external view returns (Dispute memory);

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

    // ============ Treasury Stake Subsidies ============

    /// @notice Treasury-funded portion of a counterparty stake, escrowed in ILRM
    struct StakeSubsidy {
        address funder; // Treasury that funded the subsidy (repaid on resolution)
        uint256 amount; // Subsidized portion of the counterparty stake
    }

    /// @notice Emitted when the owner changes the treasury allowed to fund stake subsidies
    event SubsidyTreasuryUpdated(address indexed previousTreasury, address indexed newTreasury);

    /// @notice Emitted when part (or all) of a counterparty stake is funded by a treasury
    event StakeSubsidized(
        uint256 indexed disputeId, address indexed counterparty, address indexed funder, uint256 amount
    );

    /// @notice Emitted when the funder's pro-rata share of the counterparty payout is repaid on resolution
    event SubsidyReturned(uint256 indexed disputeId, address indexed funder, uint256 amount);

    /**
     * @notice Counterparty deposits the matching stake with part of it funded by the subsidy treasury
     * @dev Counterparty-only, same checks as depositStake. Stakes exactly initiatorStake (stakes stay
     *      symmetric): the treasury funds min(maxSubsidy, initiatorStake, treasury caps) straight into
     *      ILRM escrow and the caller pays the rest. The caller needs an ERC20 allowance to ILRM for the
     *      top-up, which also bounds what it can be charged. Atomic: if the treasury grants nothing or
     *      the top-up cannot be pulled, the whole call reverts and nothing is reserved.
     *      The subsidy is never paid to the caller's wallet; on resolution the funder is repaid its
     *      pro-rata share of the counterparty payout.
     * @param disputeId The dispute to stake into
     * @param maxSubsidy Maximum amount the caller asks the treasury to fund
     */
    function depositStakeWithSubsidy(uint256 disputeId, uint256 maxSubsidy) external;

    /**
     * @notice Get the treasury subsidy recorded for a dispute's counterparty stake
     * @param disputeId The dispute to query
     * @return funder Treasury that funded the subsidy (address(0) if none)
     * @return amount Subsidized portion of the counterparty stake (0 if none)
     */
    function stakeSubsidy(uint256 disputeId) external view returns (address funder, uint256 amount);
}

/**
 * @title ISubsidyTreasury - Funder of defensive stake subsidies
 * @notice Implemented by the treasury that ILRM.depositStakeWithSubsidy draws on
 */
interface ISubsidyTreasury {
    /// @notice Called only by ILRM while staking. Grants up to maxAmount, approves ILRM for exactly the returned amount.
    function fundStakeSubsidy(uint256 disputeId, address participant, uint256 maxAmount)
        external
        returns (uint256 subsidyAmount);
}
