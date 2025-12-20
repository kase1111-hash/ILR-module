// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IILRM.sol";

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
 */
contract NatLangChainTreasury is ReentrancyGuard, Ownable {
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

    /// @notice Total subsidies distributed
    uint256 public totalSubsidiesDistributed;

    /// @notice Total inflows received
    uint256 public totalInflows;

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

    // ============ Errors ============

    error DisputeAlreadySubsidized(uint256 disputeId);
    error ZeroAmount();
    error NoSubsidyAvailable();
    error ParticipantFlaggedForAbuse(address participant, uint256 score);
    error InsufficientTreasuryBalance(uint256 available, uint256 requested);
    error NotILRM(address caller);
    error NotCounterparty(address caller, address expected);
    error InvalidAddress();

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
    ) external nonReentrant returns (uint256 subsidyAmount) {
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
        (
            address initiator,
            address counterparty,
            ,,,,,,,,,,
        ) = IILRM(ilrm).disputes(disputeId);

        if (participant != counterparty) {
            revert NotCounterparty(participant, counterparty);
        }
        // Initiators cannot receive subsidies (they're the attackers)
        if (participant == initiator) {
            revert NotCounterparty(participant, counterparty);
        }

        // Check harassment score
        if (harassmentScore[participant] >= HARASSMENT_THRESHOLD) {
            revert ParticipantFlaggedForAbuse(participant, harassmentScore[participant]);
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

        // Cap by per-participant rolling window
        uint256 participantAvailable = maxPerParticipant - participantSubsidyUsed[participant];
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

        // Check rolling window
        uint256 usedInWindow = participantSubsidyUsed[participant];
        if (block.timestamp > participantWindowStart[participant] + windowDuration) {
            usedInWindow = 0; // Window expired, would reset
        }
        uint256 participantAvailable = maxPerParticipant > usedInWindow
            ? maxPerParticipant - usedInWindow
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
     * @notice Batch update harassment scores
     * @param participants Array of participants
     * @param scores Array of new scores
     */
    function batchSetHarassmentScores(
        address[] calldata participants,
        uint256[] calldata scores
    ) external onlyOwner {
        require(participants.length == scores.length, "Length mismatch");

        for (uint256 i = 0; i < participants.length; i++) {
            uint256 oldScore = harassmentScore[participants[i]];
            uint256 newScore = scores[i] > 100 ? 100 : scores[i];
            harassmentScore[participants[i]] = newScore;
            emit HarassmentScoreUpdated(participants[i], oldScore, newScore);
        }
    }

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
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function emergencyWithdrawETH(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert InvalidAddress();
        (bool success, ) = to.call{value: amount}("");
        require(success, "ETH transfer failed");
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
     * @notice Check if participant is eligible for subsidy
     */
    function isEligible(address participant) external view returns (bool) {
        return harassmentScore[participant] < HARASSMENT_THRESHOLD;
    }
}
