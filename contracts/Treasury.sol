// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "./interfaces/IILRM.sol";
import "./interfaces/IDIDRegistry.sol";

/**
 * @title NatLangChainTreasury
 * @notice Treasury contract for ILRM protocol - holds burns, fees, and provides defensive subsidies
 * @dev Implements the Treasury Blueprint from Treasury.md
 *
 * Key Features:
 * - Holds protocol funds from burns and counter-fees
 * - Subsidizes defensive stakes for low-resource counterparties
 * - Anti-Sybil protections (single subsidy per dispute, rolling caps, reputation)
 * - Fully algorithmic - no discretionary human control
 * - FIX L-05: Pausable for emergency stops
 * - FIX I-02: Two-step ownership transfer via Ownable2Step
 */
contract NatLangChainTreasury is ReentrancyGuard, Pausable, Ownable2Step {
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

    /// @notice Tracks if dispute has been subsidized (prevents double-subsidy)
    mapping(uint256 => bool) public disputeSubsidized;

    /// @notice Subsidy recipient for each dispute
    mapping(uint256 => address) public disputeSubsidyRecipient;

    /// @notice Rolling window subsidy usage per participant
    mapping(address => uint256) public participantSubsidyUsed;

    /// @notice Timestamp of first subsidy in current window per participant
    mapping(address => uint256) public participantWindowStart;

    /// @notice Harassment score per participant (0-100)
    mapping(address => uint256) public harassmentScore;

    /// @notice Last harassment score update timestamp per participant
    mapping(address => uint256) public harassmentScoreLastUpdated;

    /// @notice Harassment score decay rate (points per period)
    uint256 public harassmentDecayRate;

    /// @notice Harassment score decay period (default: 30 days)
    uint256 public harassmentDecayPeriod;

    /// @notice Total subsidies distributed
    uint256 public totalSubsidiesDistributed;

    /// @notice Total inflows received
    uint256 public totalInflows;

    // ============ Dynamic Cap Variables ============

    /// @notice Whether dynamic caps are enabled
    bool public dynamicCapEnabled;

    /// @notice Dynamic cap percentage of treasury balance (in basis points, e.g., 1000 = 10%)
    uint256 public dynamicCapPercentageBps;

    /// @notice Minimum dynamic cap (floor)
    uint256 public dynamicCapFloor;

    /// @notice Basis points denominator
    uint256 public constant BPS_DENOMINATOR = 10000;

    // ============ Tiered Subsidy Variables ============

    /// @notice Whether tiered subsidies are enabled
    bool public tieredSubsidiesEnabled;

    /// @notice Tier thresholds (harassment score boundaries)
    /// @dev Tier 0: score < tier1Threshold → 100% subsidy
    /// @dev Tier 1: tier1Threshold <= score < tier2Threshold → tier1Multiplier
    /// @dev Tier 2: tier2Threshold <= score < tier3Threshold → tier2Multiplier
    /// @dev Tier 3: tier3Threshold <= score < HARASSMENT_THRESHOLD → tier3Multiplier
    /// @dev score >= HARASSMENT_THRESHOLD → 0% (blocked)
    uint256 public tier1Threshold;
    uint256 public tier2Threshold;
    uint256 public tier3Threshold;

    /// @notice Tier multipliers in basis points (10000 = 100%)
    uint256 public tier1MultiplierBps;
    uint256 public tier2MultiplierBps;
    uint256 public tier3MultiplierBps;

    // ============ DID Integration Variables ============

    /// @notice Optional DID registry for sybil-resistant subsidies
    IDIDRegistry public didRegistry;

    /// @notice Whether DID verification is required for subsidies
    bool public didRequiredForSubsidy;

    /// @notice Minimum sybil score for subsidy eligibility
    uint256 public minDIDSybilScoreForSubsidy;

    /// @notice Subsidy bonus multiplier for high sybil scores (in basis points)
    /// @dev e.g., 1500 = 15% bonus for participants with high sybil scores
    uint256 public didBonusMultiplierBps;

    /// @notice Sybil score threshold for bonus eligibility
    uint256 public didBonusThreshold;

    // ============ Events ============

    /// @notice Emitted when subsidy is granted
    event SubsidyFunded(
        address indexed participant,
        uint256 indexed disputeId,
        uint256 amount
    );

    /// @notice Emitted when treasury receives funds
    event TreasuryReceived(
        address indexed from,
        uint256 amount,
        string reason
    );

    /// @notice Emitted when harassment score is updated
    event HarassmentScoreUpdated(
        address indexed participant,
        uint256 oldScore,
        uint256 newScore
    );

    /// @notice Emitted when ILRM address is updated
    event ILRMUpdated(address indexed oldILRM, address indexed newILRM);

    /// @notice Emitted when caps are updated
    event CapsUpdated(
        uint256 maxPerDispute,
        uint256 maxPerParticipant,
        uint256 windowDuration
    );

    /// @notice Emitted when dynamic cap configuration is updated
    event DynamicCapConfigUpdated(
        bool enabled,
        uint256 percentageBps,
        uint256 floor
    );

    /// @notice Emitted when tiered subsidy configuration is updated
    event TieredSubsidyConfigUpdated(
        bool enabled,
        uint256 tier1Threshold,
        uint256 tier2Threshold,
        uint256 tier3Threshold,
        uint256 tier1MultiplierBps,
        uint256 tier2MultiplierBps,
        uint256 tier3MultiplierBps
    );

    // ============ Errors ============

    error DisputeAlreadySubsidized(uint256 disputeId);
    error ZeroAmount();
    error NoSubsidyAvailable();
    error ParticipantFlaggedForAbuse(address participant, uint256 score);
    error InsufficientTreasuryBalance(uint256 available, uint256 requested);
    error NotILRM(address caller);
    error NotCounterparty(address caller, address expected);
    error InvalidAddress();
    error DIDRequirementNotMet(address participant);
    error InsufficientDIDSybilScore(address participant, uint256 required, uint256 actual);
    error DisputeAlreadyResolved(uint256 disputeId);
    error CounterpartyAlreadyStaked(uint256 disputeId);
    error ScoreDeltaOutOfBounds(int256 delta);
    error LengthMismatch(uint256 participants, uint256 scores);
    error EmptyArray();
    error BatchTooLarge(uint256 size);
    error ETHTransferFailed();

    /// @notice Emitted when DID registry is set
    event DIDRegistrySet(address indexed registry);

    /// @notice Emitted when DID subsidy configuration is updated
    event DIDSubsidyConfigUpdated(
        bool required,
        uint256 minScore,
        uint256 bonusMultiplierBps,
        uint256 bonusThreshold
    );

    // ============ Constructor ============

    /**
     * @param _token Protocol ERC20 token
     * @param _maxPerDispute Maximum subsidy per dispute
     * @param _maxPerParticipant Maximum subsidy per participant in window
     * @param _windowDuration Rolling window duration in seconds
     */
    constructor(
        IERC20 _token,
        uint256 _maxPerDispute,
        uint256 _maxPerParticipant,
        uint256 _windowDuration
    ) Ownable(msg.sender) {
        if (address(_token) == address(0)) revert InvalidAddress();

        token = _token;
        maxPerDispute = _maxPerDispute;
        maxPerParticipant = _maxPerParticipant;
        windowDuration = _windowDuration;
        minReserve = 0; // Can be set later

        // Initialize harassment score decay (1 point per 30 days by default)
        harassmentDecayRate = 1;
        harassmentDecayPeriod = 30 days;
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
     * @notice Request defensive subsidy for a dispute
     * @dev Only counterparty (defender) can request subsidy
     * @param disputeId The dispute ID in ILRM
     * @param stakeNeeded Amount of stake required
     * @param participant The participant requesting subsidy (must be counterparty)
     */
    function requestSubsidy(
        uint256 disputeId,
        uint256 stakeNeeded,
        address participant
    ) external nonReentrant whenNotPaused returns (uint256 subsidyAmount) {
        // FIX M-04: Only the participant themselves can request their subsidy
        // Prevents front-running and ensures intended recipient gets subsidy
        if (msg.sender != participant) {
            revert NotCounterparty(msg.sender, participant);
        }

        // Validate request
        if (disputeSubsidized[disputeId]) {
            revert DisputeAlreadySubsidized(disputeId);
        }
        if (stakeNeeded == 0) revert ZeroAmount();

        // FIX H-02: ILRM MUST be set before subsidies can be requested
        // Without ILRM validation, anyone could drain treasury with fake disputes
        if (ilrm == address(0)) {
            revert InvalidAddress();
        }

        // Verify participant is the counterparty (defender, not initiator)
        // FIX: Also check dispute is not resolved and counterparty hasn't staked yet
        (
            address initiator,
            address counterparty,
            ,
            uint256 counterpartyStake,
            ,,,,,
            bool resolved,
            ,,
        ) = IILRM(ilrm).disputes(disputeId);

        // Dispute must be active (not resolved)
        if (resolved) revert DisputeAlreadyResolved(disputeId);

        // Counterparty must not have staked yet (subsidy is to HELP them stake)
        if (counterpartyStake != 0) revert CounterpartyAlreadyStaked(disputeId);

        if (participant != counterparty) {
            revert NotCounterparty(participant, counterparty);
        }
        // Initiators cannot receive subsidies (they're the attackers)
        if (participant == initiator) {
            revert NotCounterparty(participant, counterparty);
        }

        // Check harassment score (with time-based decay applied)
        uint256 effectiveScore = getEffectiveHarassmentScore(participant);
        if (effectiveScore >= HARASSMENT_THRESHOLD) {
            revert ParticipantFlaggedForAbuse(participant, effectiveScore);
        }

        // Reset rolling window if expired
        if (block.timestamp > participantWindowStart[participant] + windowDuration) {
            participantSubsidyUsed[participant] = 0;
            participantWindowStart[participant] = block.timestamp;
        }

        // Calculate available subsidy
        subsidyAmount = stakeNeeded;

        // Cap by per-dispute limit
        if (subsidyAmount > maxPerDispute) {
            subsidyAmount = maxPerDispute;
        }

        // Cap by per-participant rolling window (use dynamic cap if enabled)
        uint256 effectiveMaxPerParticipant = getEffectiveMaxPerParticipant();
        uint256 participantAvailable = effectiveMaxPerParticipant > participantSubsidyUsed[participant]
            ? effectiveMaxPerParticipant - participantSubsidyUsed[participant]
            : 0;
        if (subsidyAmount > participantAvailable) {
            subsidyAmount = participantAvailable;
        }

        // Cap by treasury balance (minus reserve)
        uint256 treasuryBalance = token.balanceOf(address(this));
        uint256 availableBalance = treasuryBalance > minReserve
            ? treasuryBalance - minReserve
            : 0;
        if (subsidyAmount > availableBalance) {
            subsidyAmount = availableBalance;
        }

        // Apply tiered subsidy multiplier based on harassment score
        if (tieredSubsidiesEnabled) {
            (uint256 multiplierBps,) = getSubsidyMultiplier(participant);
            subsidyAmount = (subsidyAmount * multiplierBps) / BPS_DENOMINATOR;
        }

        if (subsidyAmount == 0) revert NoSubsidyAvailable();

        // Update state
        disputeSubsidized[disputeId] = true;
        disputeSubsidyRecipient[disputeId] = participant;
        participantSubsidyUsed[participant] += subsidyAmount;
        totalSubsidiesDistributed += subsidyAmount;

        // Transfer subsidy
        token.safeTransfer(participant, subsidyAmount);

        emit SubsidyFunded(participant, disputeId, subsidyAmount);
    }

    /**
     * @notice Calculate potential subsidy without executing
     * @param disputeId The dispute ID
     * @param stakeNeeded Amount of stake required
     * @param participant The participant to check
     * @return subsidyAmount Potential subsidy amount
     * @return eligible Whether participant is eligible
     */
    function calculateSubsidy(
        uint256 disputeId,
        uint256 stakeNeeded,
        address participant
    ) external view returns (uint256 subsidyAmount, bool eligible) {
        // Check basic eligibility
        if (disputeSubsidized[disputeId]) return (0, false);
        if (stakeNeeded == 0) return (0, false);
        if (harassmentScore[participant] >= HARASSMENT_THRESHOLD) return (0, false);

        subsidyAmount = stakeNeeded;

        // Apply caps
        if (subsidyAmount > maxPerDispute) {
            subsidyAmount = maxPerDispute;
        }

        // Check rolling window (use dynamic cap if enabled)
        uint256 usedInWindow = participantSubsidyUsed[participant];
        if (block.timestamp > participantWindowStart[participant] + windowDuration) {
            usedInWindow = 0; // Window expired, would reset
        }
        uint256 effectiveMaxPerParticipant = getEffectiveMaxPerParticipant();
        uint256 participantAvailable = effectiveMaxPerParticipant > usedInWindow
            ? effectiveMaxPerParticipant - usedInWindow
            : 0;
        if (subsidyAmount > participantAvailable) {
            subsidyAmount = participantAvailable;
        }

        // Check treasury balance
        uint256 treasuryBalance = token.balanceOf(address(this));
        uint256 availableBalance = treasuryBalance > minReserve
            ? treasuryBalance - minReserve
            : 0;
        if (subsidyAmount > availableBalance) {
            subsidyAmount = availableBalance;
        }

        // Apply tiered subsidy multiplier based on harassment score
        if (tieredSubsidiesEnabled) {
            (uint256 multiplierBps,) = getSubsidyMultiplier(participant);
            subsidyAmount = (subsidyAmount * multiplierBps) / BPS_DENOMINATOR;
        }

        eligible = subsidyAmount > 0;
    }

    // ============ Harassment Score Management ============

    /**
     * @notice Update harassment score for a participant
     * @dev Called by ILRM after dispute resolution
     * @param participant The participant to update
     * @param scoreDelta Change in score (positive = worse behavior)
     */
    function updateHarassmentScore(
        address participant,
        int256 scoreDelta
    ) external onlyILRM {
        // FIX M-08: Prevent overflow when negating type(int256).min
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
        harassmentScoreLastUpdated[participant] = block.timestamp;

        emit HarassmentScoreUpdated(participant, oldScore, newScore);
    }

    /**
     * @notice Batch update harassment scores
     * @param participants Array of participants
     * @param scores Array of new scores
     */
    function batchSetHarassmentScores(
        address[] calldata participants,
        uint256[] calldata scores
    ) external onlyOwner {
        if (participants.length != scores.length) revert LengthMismatch(participants.length, scores.length);
        if (participants.length == 0) revert EmptyArray();
        if (participants.length > 100) revert BatchTooLarge(participants.length);

        for (uint256 i = 0; i < participants.length; ++i) {
            if (participants[i] == address(0)) revert InvalidAddress();
            uint256 oldScore = harassmentScore[participants[i]];
            uint256 newScore = scores[i] > 100 ? 100 : scores[i];
            harassmentScore[participants[i]] = newScore;
            harassmentScoreLastUpdated[participants[i]] = block.timestamp;
            emit HarassmentScoreUpdated(participants[i], oldScore, newScore);
        }
    }

    /**
     * @notice Get effective harassment score with time-based decay applied
     * @dev FIX: Scores decay over time so participants can rehabilitate
     * @param participant Address to check
     * @return effectiveScore The harassment score after decay is applied
     */
    function getEffectiveHarassmentScore(address participant) public view returns (uint256 effectiveScore) {
        uint256 rawScore = harassmentScore[participant];
        if (rawScore == 0) return 0;

        uint256 lastUpdate = harassmentScoreLastUpdated[participant];
        if (lastUpdate == 0 || harassmentDecayPeriod == 0) {
            return rawScore;
        }

        // Calculate decay based on time elapsed
        uint256 elapsed = block.timestamp - lastUpdate;
        uint256 periodsElapsed = elapsed / harassmentDecayPeriod;
        uint256 decayAmount = periodsElapsed * harassmentDecayRate;

        // Apply decay (cannot go below 0)
        if (decayAmount >= rawScore) {
            return 0;
        }
        return rawScore - decayAmount;
    }

    /**
     * @notice Configure harassment score decay parameters
     * @dev FIX: Allows tuning how fast scores decay over time
     * @param _decayRate Points to decay per period
     * @param _decayPeriod Duration of each decay period in seconds
     */
    function setHarassmentDecayConfig(
        uint256 _decayRate,
        uint256 _decayPeriod
    ) external onlyOwner {
        require(_decayPeriod >= 1 days, "Decay period too short");
        require(_decayRate <= 10, "Decay rate too high");

        harassmentDecayRate = _decayRate;
        harassmentDecayPeriod = _decayPeriod;

        emit HarassmentDecayConfigUpdated(_decayRate, _decayPeriod);
    }

    /// @notice Emitted when harassment decay config is updated
    event HarassmentDecayConfigUpdated(uint256 decayRate, uint256 decayPeriod);

    // ============ Admin Functions ============

    /**
     * @notice Set the authorized ILRM contract
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
    function updateCaps(
        uint256 _maxPerDispute,
        uint256 _maxPerParticipant,
        uint256 _windowDuration
    ) external onlyOwner {
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
     * @notice Configure dynamic caps
     * @dev When enabled, maxPerParticipant scales with treasury balance
     * @param _enabled Whether dynamic caps are enabled
     * @param _percentageBps Percentage of treasury balance (in basis points, e.g., 1000 = 10%)
     * @param _floor Minimum cap even when treasury is low
     */
    function setDynamicCapConfig(
        bool _enabled,
        uint256 _percentageBps,
        uint256 _floor
    ) external onlyOwner {
        require(_percentageBps <= BPS_DENOMINATOR, "Percentage too high");

        dynamicCapEnabled = _enabled;
        dynamicCapPercentageBps = _percentageBps;
        dynamicCapFloor = _floor;

        emit DynamicCapConfigUpdated(_enabled, _percentageBps, _floor);
    }

    /**
     * @notice Configure tiered subsidies
     * @dev When enabled, subsidy amount is multiplied by tier-based percentage
     * @param _enabled Whether tiered subsidies are enabled
     * @param _tier1Threshold Harassment score threshold for tier 1 (e.g., 10)
     * @param _tier2Threshold Harassment score threshold for tier 2 (e.g., 25)
     * @param _tier3Threshold Harassment score threshold for tier 3 (e.g., 40)
     * @param _tier1MultiplierBps Tier 1 multiplier in basis points (e.g., 7500 = 75%)
     * @param _tier2MultiplierBps Tier 2 multiplier in basis points (e.g., 5000 = 50%)
     * @param _tier3MultiplierBps Tier 3 multiplier in basis points (e.g., 2500 = 25%)
     */
    function setTieredSubsidyConfig(
        bool _enabled,
        uint256 _tier1Threshold,
        uint256 _tier2Threshold,
        uint256 _tier3Threshold,
        uint256 _tier1MultiplierBps,
        uint256 _tier2MultiplierBps,
        uint256 _tier3MultiplierBps
    ) external onlyOwner {
        // FIX: Require tier1Threshold > 0 when enabling to ensure score 0 users get 100%
        // Without this, score < 0 is always false for uint256, breaking tier 0
        if (_enabled) {
            require(_tier1Threshold > 0, "Tier 1 threshold must be > 0");
        }
        require(_tier1Threshold < _tier2Threshold, "Tier 1 must be < Tier 2");
        require(_tier2Threshold < _tier3Threshold, "Tier 2 must be < Tier 3");
        require(_tier3Threshold < HARASSMENT_THRESHOLD, "Tier 3 must be < threshold");
        require(_tier1MultiplierBps <= BPS_DENOMINATOR, "Tier 1 multiplier too high");
        require(_tier2MultiplierBps <= _tier1MultiplierBps, "Tier 2 must be <= Tier 1");
        require(_tier3MultiplierBps <= _tier2MultiplierBps, "Tier 3 must be <= Tier 2");

        tieredSubsidiesEnabled = _enabled;
        tier1Threshold = _tier1Threshold;
        tier2Threshold = _tier2Threshold;
        tier3Threshold = _tier3Threshold;
        tier1MultiplierBps = _tier1MultiplierBps;
        tier2MultiplierBps = _tier2MultiplierBps;
        tier3MultiplierBps = _tier3MultiplierBps;

        emit TieredSubsidyConfigUpdated(
            _enabled,
            _tier1Threshold,
            _tier2Threshold,
            _tier3Threshold,
            _tier1MultiplierBps,
            _tier2MultiplierBps,
            _tier3MultiplierBps
        );
    }

    /**
     * @notice Emergency withdraw (DAO-controlled in production)
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert InvalidAddress();
        token.safeTransfer(to, amount);
    }

    /**
     * @notice Emergency withdraw ETH
     * @dev FIX: Added nonReentrant to prevent reentrancy attacks
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function emergencyWithdrawETH(address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert InvalidAddress();
        (bool success, ) = to.call{value: amount}("");
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
     * @notice Calculate dynamic cap based on current treasury balance
     * @dev Returns percentage of treasury balance, with floor
     * @return dynamicCap The calculated dynamic cap
     */
    function calculateDynamicCap() public view returns (uint256 dynamicCap) {
        uint256 treasuryBalance = token.balanceOf(address(this));
        uint256 availableBalance = treasuryBalance > minReserve
            ? treasuryBalance - minReserve
            : 0;

        // Calculate percentage of available balance
        dynamicCap = (availableBalance * dynamicCapPercentageBps) / BPS_DENOMINATOR;

        // Apply floor
        if (dynamicCap < dynamicCapFloor) {
            dynamicCap = dynamicCapFloor;
        }
    }

    /**
     * @notice Get effective max per participant (considers dynamic caps)
     * @dev Returns the lower of configured cap and dynamic cap when enabled
     * @return effectiveCap The effective maximum per participant
     */
    function getEffectiveMaxPerParticipant() public view returns (uint256 effectiveCap) {
        if (!dynamicCapEnabled) {
            return maxPerParticipant;
        }

        uint256 dynamicCap = calculateDynamicCap();

        // Return the lower of configured and dynamic cap
        effectiveCap = dynamicCap < maxPerParticipant ? dynamicCap : maxPerParticipant;
    }

    /**
     * @notice Get subsidy multiplier for a participant based on harassment score
     * @dev Returns multiplier in basis points (10000 = 100%)
     * @param participant The participant to check
     * @return multiplierBps The subsidy multiplier in basis points
     * @return tier The tier the participant falls into (0-3)
     */
    function getSubsidyMultiplier(address participant) public view returns (uint256 multiplierBps, uint256 tier) {
        if (!tieredSubsidiesEnabled) {
            return (BPS_DENOMINATOR, 0); // 100% if tiered subsidies disabled
        }

        // Use effective score with decay applied
        uint256 score = getEffectiveHarassmentScore(participant);

        // Tier 0: score < tier1Threshold → 100% subsidy
        if (score < tier1Threshold) {
            return (BPS_DENOMINATOR, 0);
        }

        // Tier 1: tier1Threshold <= score < tier2Threshold
        if (score < tier2Threshold) {
            return (tier1MultiplierBps, 1);
        }

        // Tier 2: tier2Threshold <= score < tier3Threshold
        if (score < tier3Threshold) {
            return (tier2MultiplierBps, 2);
        }

        // Tier 3: tier3Threshold <= score < HARASSMENT_THRESHOLD
        if (score < HARASSMENT_THRESHOLD) {
            return (tier3MultiplierBps, 3);
        }

        // score >= HARASSMENT_THRESHOLD → blocked (0%)
        return (0, 4);
    }

    /**
     * @notice Get participant's remaining subsidy allowance in current window
     * @dev Uses effective cap (considers dynamic caps when enabled)
     */
    function getRemainingAllowance(address participant) external view returns (uint256) {
        uint256 effectiveCap = getEffectiveMaxPerParticipant();

        if (block.timestamp > participantWindowStart[participant] + windowDuration) {
            return effectiveCap; // Window expired
        }
        return effectiveCap > participantSubsidyUsed[participant]
            ? effectiveCap - participantSubsidyUsed[participant]
            : 0;
    }

    /**
     * @notice Check if participant is eligible for subsidy
     */
    function isEligible(address participant) external view returns (bool) {
        return harassmentScore[participant] < HARASSMENT_THRESHOLD;
    }

    /**
     * @notice FIX L-05: Pause contract in case of emergency
     * @dev Only owner can pause
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice FIX L-05: Unpause contract
     * @dev Only owner can unpause
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // ============ DID Integration Functions ============

    /**
     * @notice Set the DID registry contract
     * @dev Only owner can set; address(0) disables DID verification
     * @param _registry The DID registry contract address
     */
    function setDIDRegistry(address _registry) external onlyOwner {
        didRegistry = IDIDRegistry(_registry);
        emit DIDRegistrySet(_registry);
    }

    /**
     * @notice Configure DID-based subsidy requirements
     * @dev DID verification adds sybil resistance to subsidies
     * @param _required Whether DID is required for subsidies
     * @param _minScore Minimum sybil score required (0-100)
     * @param _bonusMultiplierBps Bonus multiplier for high sybil scores (e.g., 1500 = 15%)
     * @param _bonusThreshold Sybil score threshold for bonus eligibility
     */
    function setDIDSubsidyConfig(
        bool _required,
        uint256 _minScore,
        uint256 _bonusMultiplierBps,
        uint256 _bonusThreshold
    ) external onlyOwner {
        didRequiredForSubsidy = _required;
        minDIDSybilScoreForSubsidy = _minScore;
        didBonusMultiplierBps = _bonusMultiplierBps;
        didBonusThreshold = _bonusThreshold;

        emit DIDSubsidyConfigUpdated(_required, _minScore, _bonusMultiplierBps, _bonusThreshold);
    }

    /**
     * @notice Check if participant meets DID requirements for subsidy
     * @param participant The participant to check
     * @return meetsRequirement Whether they meet DID requirements
     * @return sybilScore Their sybil score (0 if no DID)
     * @return eligibleForBonus Whether they qualify for bonus multiplier
     */
    function checkDIDSubsidyEligibility(address participant) public view returns (
        bool meetsRequirement,
        uint256 sybilScore,
        bool eligibleForBonus
    ) {
        if (address(didRegistry) == address(0)) {
            // No DID registry set
            return (!didRequiredForSubsidy, 0, false);
        }

        if (!didRegistry.hasDID(participant)) {
            // No DID registered
            return (!didRequiredForSubsidy, 0, false);
        }

        bytes32 did = didRegistry.addressToDID(participant);
        IDIDRegistry.DIDDocument memory doc = didRegistry.getDIDDocument(did);

        // Must have active DID
        if (doc.status != IDIDRegistry.DIDStatus.Active) {
            return (false, 0, false);
        }

        sybilScore = doc.sybilScore;
        meetsRequirement = sybilScore >= minDIDSybilScoreForSubsidy;
        eligibleForBonus = sybilScore >= didBonusThreshold && didBonusMultiplierBps > 0;
    }

    /**
     * @notice Calculate DID-adjusted subsidy amount
     * @dev Applies DID bonus multiplier if eligible
     * @param baseAmount The base subsidy amount
     * @param participant The participant requesting subsidy
     * @return adjustedAmount The adjusted amount with DID bonus
     */
    function calculateDIDAdjustedSubsidy(
        uint256 baseAmount,
        address participant
    ) public view returns (uint256 adjustedAmount) {
        (, uint256 sybilScore, bool eligibleForBonus) = checkDIDSubsidyEligibility(participant);

        if (eligibleForBonus && sybilScore >= didBonusThreshold) {
            // Apply bonus: baseAmount * (1 + bonusMultiplier/10000)
            adjustedAmount = baseAmount + (baseAmount * didBonusMultiplierBps) / BPS_DENOMINATOR;
        } else {
            adjustedAmount = baseAmount;
        }
    }

    /**
     * @notice Request subsidy with DID verification
     * @dev Enhanced subsidy request with sybil resistance
     * @param disputeId The dispute ID
     * @param stakeNeeded Amount of stake required
     * @param participant The participant requesting
     * @return subsidyAmount The final subsidy amount (may include DID bonus)
     */
    function requestSubsidyWithDID(
        uint256 disputeId,
        uint256 stakeNeeded,
        address participant
    ) external nonReentrant whenNotPaused returns (uint256 subsidyAmount) {
        // Verify caller is the participant
        if (msg.sender != participant) {
            revert NotCounterparty(msg.sender, participant);
        }

        // Check DID requirements
        if (address(didRegistry) != address(0) && didRequiredForSubsidy) {
            (bool meetsRequirement, uint256 sybilScore, ) = checkDIDSubsidyEligibility(participant);

            if (!meetsRequirement) {
                if (!didRegistry.hasDID(participant)) {
                    revert DIDRequirementNotMet(participant);
                }
                revert InsufficientDIDSybilScore(participant, minDIDSybilScoreForSubsidy, sybilScore);
            }
        }

        // Validate request
        if (disputeSubsidized[disputeId]) {
            revert DisputeAlreadySubsidized(disputeId);
        }
        if (stakeNeeded == 0) revert ZeroAmount();

        // ILRM must be set
        if (ilrm == address(0)) {
            revert InvalidAddress();
        }

        // Verify participant is the counterparty
        (
            address initiator,
            address counterparty,
            ,
            uint256 counterpartyStake,
            ,,,,,
            bool resolved,
            ,,
        ) = IILRM(ilrm).disputes(disputeId);

        if (resolved) revert DisputeAlreadyResolved(disputeId);
        if (counterpartyStake != 0) revert CounterpartyAlreadyStaked(disputeId);

        if (participant != counterparty) {
            revert NotCounterparty(participant, counterparty);
        }
        if (participant == initiator) {
            revert NotCounterparty(participant, counterparty);
        }

        // Check harassment score
        uint256 effectiveScore = getEffectiveHarassmentScore(participant);
        if (effectiveScore >= HARASSMENT_THRESHOLD) {
            revert ParticipantFlaggedForAbuse(participant, effectiveScore);
        }

        // Calculate base subsidy
        uint256 baseSubsidy = _calculateBaseSubsidy(stakeNeeded, participant);

        // Apply DID bonus if eligible
        subsidyAmount = calculateDIDAdjustedSubsidy(baseSubsidy, participant);

        // Cap at max per dispute
        uint256 effectiveCap = getEffectiveMaxPerParticipant();
        if (subsidyAmount > effectiveCap) {
            subsidyAmount = effectiveCap;
        }

        // Check treasury balance
        uint256 balance = token.balanceOf(address(this));
        if (balance < subsidyAmount + minReserve) {
            // FIX: Prevent underflow in error message when balance < minReserve
            uint256 available = balance > minReserve ? balance - minReserve : 0;
            revert InsufficientTreasuryBalance(available, subsidyAmount);
        }

        // Update state
        disputeSubsidized[disputeId] = true;
        disputeSubsidyRecipient[disputeId] = participant;
        _updateParticipantWindow(participant, subsidyAmount);
        totalSubsidiesDistributed += subsidyAmount;

        // Transfer subsidy
        token.safeTransfer(participant, subsidyAmount);

        emit SubsidyFunded(participant, disputeId, subsidyAmount);
    }

    /**
     * @notice Internal function to calculate base subsidy amount
     * @dev Caches storage reads for gas optimization
     */
    function _calculateBaseSubsidy(uint256 stakeNeeded, address participant) internal view returns (uint256) {
        uint256 effectiveCap = getEffectiveMaxPerParticipant();
        uint256 subsidyAmount = stakeNeeded;

        // Cache storage reads for gas optimization
        uint256 windowStart = participantWindowStart[participant];
        uint256 usedInWindow = participantSubsidyUsed[participant];

        // Apply per-dispute cap
        if (subsidyAmount > maxPerDispute) {
            subsidyAmount = maxPerDispute;
        }

        // Check participant window
        if (block.timestamp > windowStart + windowDuration) {
            // Window expired, reset
            if (subsidyAmount > effectiveCap) {
                subsidyAmount = effectiveCap;
            }
        } else {
            uint256 available = effectiveCap > usedInWindow
                ? effectiveCap - usedInWindow
                : 0;
            if (subsidyAmount > available) {
                subsidyAmount = available;
            }
        }

        // Apply tiered subsidy multiplier
        (uint256 multiplier, ) = getSubsidyMultiplier(participant);
        subsidyAmount = (subsidyAmount * multiplier) / BPS_DENOMINATOR;

        return subsidyAmount;
    }

    /**
     * @notice Update participant's subsidy usage window
     */
    function _updateParticipantWindow(address participant, uint256 amount) internal {
        if (block.timestamp > participantWindowStart[participant] + windowDuration) {
            participantWindowStart[participant] = block.timestamp;
            participantSubsidyUsed[participant] = amount;
        } else {
            participantSubsidyUsed[participant] += amount;
        }
    }
}
