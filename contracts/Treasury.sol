// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "./interfaces/IILRM.sol";

/**
 * @title NatLangChainTreasury
 * @notice Treasury contract for ILRM protocol - holds protocol tokens (deposits and subsidy repayments) and funds
 *         defensive subsidies
 * @dev Implements the Treasury described in Treasury.md
 *
 * Key Features:
 * - Holds protocol tokens deposited via deposit() and the subsidy repayments ILRM sends back as plain ERC20
 *   transfers on resolution (see below); ILRM burns go to 0xdEaD and never reach this contract
 * - Subsidizes defensive stakes for low-resource counterparties
 * - Anti-Sybil protections (single subsidy per (ILRM, dispute), rolling caps, harassment scores)
 * - Owner-administered parameters (Ownable2Step; intended owner: GovernanceTimelock): the owner can update
 *   the caps, minReserve and harassment scores, pause, and emergency-withdraw any token or ETH balance
 * - Pausable for emergency stops
 *
 * Defensive subsidies are escrowed co-stakes, never wallet payouts: the counterparty opts in through
 * ILRM.depositStakeWithSubsidy, ILRM calls fundStakeSubsidy (ILRM-only), and ILRM pulls the granted
 * amount straight into dispute escrow. On resolution ILRM repays this treasury its pro-rata share of the
 * counterparty payout with a plain ERC20 transfer (in full on mutual acceptance, net of its share of the
 * burn on timeout). Repayments are not counted in totalInflows (index ILRM.SubsidyReturned), and the
 * per-participant rolling allowance is charged gross and is not restored on repayment.
 *
 * DID-based subsidies, tiered subsidies, dynamic caps and harassment-score decay are not implemented
 * (removed in Phase 1).
 */
contract NatLangChainTreasury is ISubsidyTreasury, ReentrancyGuard, Pausable, Ownable2Step {
    using SafeERC20 for IERC20;

    // ============ State Variables ============

    /// @notice Protocol token for stakes/subsidies
    IERC20 public immutable token;

    /// @notice Authorized ILRM contract
    address public ilrm;

    /// @notice Maximum subsidy per dispute
    uint256 public maxPerDispute;

    /// @notice Maximum subsidy per participant in rolling window
    uint256 public maxPerParticipant;

    /// @notice Rolling window duration for participant caps
    uint256 public windowDuration;

    /// @notice Harassment score threshold (0-100, higher = worse)
    uint256 public constant HARASSMENT_THRESHOLD = 50;

    /// @notice Minimum treasury balance to maintain (safety buffer)
    uint256 public minReserve;

    /// @notice Subsidized participant per (ILRM, dispute); non-zero means subsidized (prevents double-subsidy)
    /// @dev Keyed by the ILRM that requested the subsidy because dispute IDs restart at 0 for every ILRM
    ///      deployment: after setILRM to a redeployed ILRM its disputes do not collide with the old ones.
    mapping(address ilrm => mapping(uint256 disputeId => address participant)) public subsidyRecipientOf;

    /// @notice Rolling window subsidy usage per participant
    mapping(address => uint256) public participantSubsidyUsed;

    /// @notice Timestamp of first subsidy in current window per participant
    mapping(address => uint256) public participantWindowStart;

    /// @notice Harassment score per participant (0-100)
    mapping(address => uint256) public harassmentScore;

    /// @notice Total subsidies distributed
    uint256 public totalSubsidiesDistributed;

    /// @notice Total inflows received
    uint256 public totalInflows;

    // ============ Events ============

    /// @notice Emitted when subsidy is granted
    event SubsidyFunded(address indexed participant, uint256 indexed disputeId, uint256 amount);

    /// @notice Emitted when treasury receives funds
    event TreasuryReceived(address indexed from, uint256 amount, string reason);

    /// @notice Emitted when harassment score is updated
    event HarassmentScoreUpdated(address indexed participant, uint256 oldScore, uint256 newScore);

    /// @notice Emitted when ILRM address is updated
    event ILRMUpdated(address indexed oldILRM, address indexed newILRM);

    /// @notice Emitted when caps are updated
    event CapsUpdated(uint256 maxPerDispute, uint256 maxPerParticipant, uint256 windowDuration);

    // ============ Errors ============

    error DisputeAlreadySubsidized(uint256 disputeId);
    error ZeroAmount();
    error NoSubsidyAvailable();
    error ParticipantFlaggedForAbuse(address participant, uint256 score);
    error InsufficientTreasuryBalance(uint256 available, uint256 requested);
    error NotILRM(address caller);
    error NotCounterparty(address caller, address expected);
    error InvalidAddress();
    error DisputeAlreadyResolved(uint256 disputeId);
    error SubsidyNotEscrowed(uint256 disputeId);
    error ScoreDeltaOutOfBounds(int256 delta);
    error ETHTransferFailed();

    // ============ Constructor ============

    /**
     * @param _token Protocol ERC20 token
     * @param _maxPerDispute Maximum subsidy per dispute
     * @param _maxPerParticipant Maximum subsidy per participant in window
     * @param _windowDuration Rolling window duration in seconds
     */
    constructor(IERC20 _token, uint256 _maxPerDispute, uint256 _maxPerParticipant, uint256 _windowDuration)
        Ownable(msg.sender)
    {
        if (address(_token) == address(0)) revert InvalidAddress();

        token = _token;
        maxPerDispute = _maxPerDispute;
        maxPerParticipant = _maxPerParticipant;
        windowDuration = _windowDuration;
        minReserve = 0;
    }

    // ============ Modifiers ============

    modifier onlyILRM() {
        if (msg.sender != ilrm) revert NotILRM(msg.sender);
        _;
    }

    // ============ Treasury Inflows ============

    /**
     * @notice Deposit tokens to treasury (from burns, fees, etc.)
     * @param amount Amount of tokens to deposit
     * @param reason Description of inflow source
     */
    function deposit(uint256 amount, string calldata reason) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        token.safeTransferFrom(msg.sender, address(this), amount);
        totalInflows += amount;

        emit TreasuryReceived(msg.sender, amount, reason);
    }

    /**
     * @notice ILRM deposits burn proceeds directly
     * @dev ILRM-only; the current ILRM never calls it (it burns to 0xdEaD). Kept for integrations.
     * @param amount Amount of tokens from burn
     */
    function depositBurn(uint256 amount) external onlyILRM nonReentrant {
        if (amount == 0) revert ZeroAmount();

        token.safeTransferFrom(msg.sender, address(this), amount);
        totalInflows += amount;

        emit TreasuryReceived(msg.sender, amount, "burn");
    }

    /**
     * @notice Accept native ETH (from counter-fees)
     */
    receive() external payable {
        emit TreasuryReceived(msg.sender, msg.value, "eth");
    }

    // ============ Subsidy Functions ============

    /**
     * @notice Fund part (or all) of a counterparty's defensive stake in an ILRM dispute
     * @dev Only callable by ILRM, from inside ILRM.depositStakeWithSubsidy: ILRM has already checked
     *      that the caller is the counterparty, that the stake window is open and the dispute unresolved,
     *      and has committed the matching stake. The subsidy is an escrowed co-stake, never a wallet
     *      payout: this function only approves ILRM for exactly the granted amount, which ILRM pulls into
     *      escrow in the same transaction (any revert there rolls this bookkeeping back too).
     *      ILRM repays this treasury its pro-rata share of the counterparty payout on resolution with a
     *      plain ERC20 transfer; the rolling allowance is charged gross and not restored on repayment.
     * @param disputeId The dispute ID in ILRM
     * @param participant The counterparty (defender) being subsidized
     * @param maxAmount Maximum subsidy requested (ILRM caps it at the dispute's stake)
     * @return subsidyAmount Amount granted, after all caps; ILRM is approved for exactly this amount
     */
    function fundStakeSubsidy(uint256 disputeId, address participant, uint256 maxAmount)
        external
        override
        onlyILRM
        nonReentrant
        whenNotPaused
        returns (uint256 subsidyAmount)
    {
        // Validate request (onlyILRM: msg.sender == ilrm, so (msg.sender, disputeId) is globally unique)
        if (subsidyRecipientOf[msg.sender][disputeId] != address(0)) {
            revert DisputeAlreadySubsidized(disputeId);
        }
        if (maxAmount == 0) revert ZeroAmount();

        // Verify participant is the counterparty (defender, not initiator); msg.sender == ilrm
        IILRM.Dispute memory d = IILRM(msg.sender).disputes(disputeId);

        // Dispute must be active (not resolved)
        if (d.resolved) revert DisputeAlreadyResolved(disputeId);

        // Initiators cannot receive subsidies (they're the attackers)
        if (participant != d.counterparty || participant == d.initiator) {
            revert NotCounterparty(participant, d.counterparty);
        }

        // Defence in depth: a zero participant would read as "not subsidized" in subsidyRecipientOf
        if (participant == address(0)) revert InvalidAddress();

        // Defence in depth: ILRM must have committed the matching (symmetric) stake before calling
        if (d.counterpartyStake == 0 || d.counterpartyStake != d.initiatorStake) {
            revert SubsidyNotEscrowed(disputeId);
        }

        // Check harassment score (threshold-based, no tiers)
        if (harassmentScore[participant] >= HARASSMENT_THRESHOLD) {
            revert ParticipantFlaggedForAbuse(participant, harassmentScore[participant]);
        }

        // Reset rolling window if expired
        if (block.timestamp > participantWindowStart[participant] + windowDuration) {
            participantSubsidyUsed[participant] = 0;
            participantWindowStart[participant] = block.timestamp;
        }

        // Calculate available subsidy
        subsidyAmount = maxAmount;

        // Never more than the stake actually owed in the dispute
        if (subsidyAmount > d.initiatorStake) {
            subsidyAmount = d.initiatorStake;
        }

        // Cap by per-dispute limit
        if (subsidyAmount > maxPerDispute) {
            subsidyAmount = maxPerDispute;
        }

        // Cap by per-participant rolling window
        uint256 participantAvailable = maxPerParticipant > participantSubsidyUsed[participant]
            ? maxPerParticipant - participantSubsidyUsed[participant]
            : 0;
        if (subsidyAmount > participantAvailable) {
            subsidyAmount = participantAvailable;
        }

        // Cap by treasury balance (minus reserve)
        uint256 treasuryBalance = token.balanceOf(address(this));
        uint256 availableBalance = treasuryBalance > minReserve ? treasuryBalance - minReserve : 0;
        if (subsidyAmount > availableBalance) {
            subsidyAmount = availableBalance;
        }

        // Computed amount after caps, not a balance check
        // slither-disable-next-line incorrect-equality
        if (subsidyAmount == 0) revert NoSubsidyAvailable();

        // Update state
        subsidyRecipientOf[msg.sender][disputeId] = participant;
        participantSubsidyUsed[participant] += subsidyAmount;
        totalSubsidiesDistributed += subsidyAmount;

        // ILRM pulls exactly this amount into dispute escrow; never pay a wallet
        token.forceApprove(msg.sender, subsidyAmount);

        emit SubsidyFunded(participant, disputeId, subsidyAmount);
    }

    /**
     * @notice Calculate potential subsidy without executing
     * @dev Preview only: it does not cap by the dispute's stake, so callers should pass the dispute's
     *      initiatorStake (or less) as stakeNeeded to match what fundStakeSubsidy would grant. Refers to
     *      disputes of the currently wired ilrm. The grant can still shrink before the stake is included
     *      (bound it with ILRM.depositStakeWithSubsidy's maxTopUp).
     * @param disputeId The dispute ID
     * @param stakeNeeded Amount of stake required (pass ILRM.disputes(disputeId).initiatorStake)
     * @param participant The participant to check
     * @return subsidyAmount Potential subsidy amount
     * @return eligible Whether participant is eligible
     */
    function calculateSubsidy(uint256 disputeId, uint256 stakeNeeded, address participant)
        external
        view
        returns (uint256 subsidyAmount, bool eligible)
    {
        // Check basic eligibility
        if (subsidyRecipientOf[ilrm][disputeId] != address(0)) return (0, false);
        if (stakeNeeded == 0) return (0, false);
        if (harassmentScore[participant] >= HARASSMENT_THRESHOLD) return (0, false);

        subsidyAmount = stakeNeeded;

        // Apply caps
        if (subsidyAmount > maxPerDispute) {
            subsidyAmount = maxPerDispute;
        }

        // Check rolling window
        uint256 usedInWindow = participantSubsidyUsed[participant];
        if (block.timestamp > participantWindowStart[participant] + windowDuration) {
            usedInWindow = 0; // Window expired, would reset
        }
        uint256 participantAvailable = maxPerParticipant > usedInWindow ? maxPerParticipant - usedInWindow : 0;
        if (subsidyAmount > participantAvailable) {
            subsidyAmount = participantAvailable;
        }

        // Check treasury balance
        uint256 treasuryBalance = token.balanceOf(address(this));
        uint256 availableBalance = treasuryBalance > minReserve ? treasuryBalance - minReserve : 0;
        if (subsidyAmount > availableBalance) {
            subsidyAmount = availableBalance;
        }

        eligible = subsidyAmount > 0;
    }

    // ============ Harassment Score Management ============

    /**
     * @notice Update harassment score for a participant
     * @dev ILRM-only; the current ILRM never calls it. Scores are set by the owner via setHarassmentScore.
     * @param participant The participant to update
     * @param scoreDelta Change in score (positive = worse behavior)
     */
    function updateHarassmentScore(address participant, int256 scoreDelta) external onlyILRM {
        // Reasonable bound: delta should be between -100 and +100
        if (scoreDelta < -100 || scoreDelta > 100) revert ScoreDeltaOutOfBounds(scoreDelta);

        uint256 oldScore = harassmentScore[participant];
        uint256 newScore;

        if (scoreDelta >= 0) {
            newScore = oldScore + uint256(scoreDelta);
            if (newScore > 100) newScore = 100; // Cap at 100
        } else {
            uint256 decrease = uint256(-scoreDelta);
            newScore = oldScore > decrease ? oldScore - decrease : 0;
        }

        harassmentScore[participant] = newScore;

        emit HarassmentScoreUpdated(participant, oldScore, newScore);
    }

    /**
     * @notice Admin setter for harassment score (for initial setup/testing)
     * @dev Owner-only. This is how scores are set: the current ILRM never calls updateHarassmentScore.
     * @param participant The participant to update
     * @param score The new score (0-100)
     */
    function setHarassmentScore(address participant, uint256 score) external onlyOwner {
        uint256 oldScore = harassmentScore[participant];
        uint256 newScore = score > 100 ? 100 : score;
        harassmentScore[participant] = newScore;
        emit HarassmentScoreUpdated(participant, oldScore, newScore);
    }

    // ============ Admin Functions ============

    /**
     * @notice Set the authorized ILRM contract
     * @dev Subsidy records are kept per ILRM (subsidyRecipientOf), so a redeployed ILRM whose dispute IDs
     *      restart at 0 does not collide with the old one. Disputes still open in the old ILRM still
     *      resolve and repay this treasury with plain transfers, but the old ILRM can no longer draw new
     *      subsidies (NotILRM). Pointing back to an earlier ILRM restores its records.
     * @param _ilrm New ILRM address
     */
    function setILRM(address _ilrm) external onlyOwner {
        if (_ilrm == address(0)) revert InvalidAddress();
        emit ILRMUpdated(ilrm, _ilrm);
        ilrm = _ilrm;
    }

    /**
     * @notice Update subsidy caps
     * @param _maxPerDispute New per-dispute cap
     * @param _maxPerParticipant New per-participant cap
     * @param _windowDuration New window duration
     */
    function updateCaps(uint256 _maxPerDispute, uint256 _maxPerParticipant, uint256 _windowDuration)
        external
        onlyOwner
    {
        maxPerDispute = _maxPerDispute;
        maxPerParticipant = _maxPerParticipant;
        windowDuration = _windowDuration;

        emit CapsUpdated(_maxPerDispute, _maxPerParticipant, _windowDuration);
    }

    /**
     * @notice Set minimum reserve balance
     * @param _minReserve New minimum reserve
     */
    function setMinReserve(uint256 _minReserve) external onlyOwner {
        minReserve = _minReserve;
    }

    /**
     * @notice Emergency withdraw tokens (DAO-controlled in production)
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert InvalidAddress();
        token.safeTransfer(to, amount);
    }

    /**
     * @notice Emergency withdraw ETH
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function emergencyWithdrawETH(address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert InvalidAddress();
        (bool success,) = to.call{value: amount}("");
        if (!success) revert ETHTransferFailed();
    }

    // ============ View Functions ============

    /**
     * @notice Get treasury token balance
     */
    function balance() external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    /**
     * @notice Get available balance for subsidies
     */
    function availableForSubsidies() external view returns (uint256) {
        uint256 bal = token.balanceOf(address(this));
        return bal > minReserve ? bal - minReserve : 0;
    }

    /**
     * @notice Get participant's remaining subsidy allowance in current window
     */
    function getRemainingAllowance(address participant) external view returns (uint256) {
        if (block.timestamp > participantWindowStart[participant] + windowDuration) {
            return maxPerParticipant; // Window expired
        }
        return maxPerParticipant > participantSubsidyUsed[participant]
            ? maxPerParticipant - participantSubsidyUsed[participant]
            : 0;
    }

    /**
     * @notice Whether a dispute of the currently wired ilrm has been subsidized
     * @dev For the currently wired ilrm; see subsidyRecipientOf for history across ILRM deployments
     * @param disputeId The dispute ID in the current ilrm
     */
    function disputeSubsidized(uint256 disputeId) external view returns (bool) {
        return subsidyRecipientOf[ilrm][disputeId] != address(0);
    }

    /**
     * @notice Subsidized participant of a dispute of the currently wired ilrm (address(0) if none)
     * @dev For the currently wired ilrm; see subsidyRecipientOf for history across ILRM deployments
     * @param disputeId The dispute ID in the current ilrm
     */
    function disputeSubsidyRecipient(uint256 disputeId) external view returns (address) {
        return subsidyRecipientOf[ilrm][disputeId];
    }

    /**
     * @notice Check if participant is eligible for subsidy
     */
    function isEligible(address participant) external view returns (bool) {
        return harassmentScore[participant] < HARASSMENT_THRESHOLD;
    }

    /**
     * @notice Pause contract in case of emergency
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause contract
     */
    function unpause() external onlyOwner {
        _unpause();
    }
}
