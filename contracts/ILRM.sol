// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IILRM.sol";
import "./interfaces/IOracle.sol";
import "./interfaces/IAssetRegistry.sol";

/**
 * @title ILRM - IP & Licensing Reconciliation Module
 * @notice Production-grade implementation of the NatLangChain ILRM Protocol v1.1
 * @dev Implements non-adjudicative dispute resolution with economic incentives
 *
 * Key Features:
 * - Dual initiation: Breach disputes (stakes first) vs voluntary requests (burn-only)
 * - Anti-harassment: Exponential counters, cooldowns, escalating stakes
 * - Spec-compliant: Follows Protocol-Safety-Invariants.md
 * - Analytics-ready: Events for every state transition
 */
contract ILRM is IILRM, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // ============ Constants (from Appendix A) ============

    /// @notice Dead address for token burns (ERC20 tokens can't burn to address(0))
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice Maximum counter-proposals per dispute (Invariant 4: Bounded Griefing)
    uint256 public constant MAX_COUNTERS = 3;

    /// @notice Percentage of total stake burned on timeout (50%)
    uint256 public constant BURN_PERCENTAGE = 50;

    /// @notice Stake symmetry window - T_stake (72 hours / 3 days)
    uint256 public constant STAKE_WINDOW = 3 days;

    /// @notice Resolution timeout window - T_resolution (7 days)
    uint256 public constant RESOLUTION_TIMEOUT = 7 days;

    /// @notice Base counter-proposal fee (0.01 ETH equivalent)
    uint256 public constant COUNTER_FEE_BASE = 0.01 ether;

    /// @notice Initiator incentive on counterparty non-stake (10% = 1000 bps)
    uint256 public constant INITIATOR_INCENTIVE_BPS = 1000;

    /// @notice Stake escalation multiplier for repeat disputes (150% = 1.5x)
    uint256 public constant ESCALATION_MULTIPLIER = 150;

    /// @notice Cooldown period between disputes with same counterparty
    uint256 public constant COOLDOWN_PERIOD = 30 days;

    // ============ State Variables ============

    /// @notice NatLangChain stake token
    IERC20 public immutable token;

    /// @notice Trusted oracle for LLM proposal submission
    address public immutable oracle;

    /// @notice Asset registry for IP/license management
    IAssetRegistry public immutable assetRegistry;

    /// @notice All disputes indexed by ID
    mapping(uint256 => Dispute) private _disputes;

    /// @notice Total disputes created
    uint256 private _disputeCounter;

    /// @notice Cooldown tracking: initiator => counterparty => lastDisputeTime
    mapping(address => mapping(address => uint256)) public lastDisputeTime;

    /// @notice Harassment score for repeat frivolous initiators
    mapping(address => uint256) public harassmentScore;

    /// @notice ETH Treasury balance from counter-fees
    uint256 public treasury;

    /// @notice Token reserves for initiator incentives
    uint256 public tokenReserves;

    // ============ Constructor ============

    /**
     * @param _token NatLangChain ERC20 token for staking
     * @param _oracle Trusted oracle address for LLM proposals
     * @param _assetRegistry Asset registry contract
     */
    constructor(
        IERC20 _token,
        address _oracle,
        IAssetRegistry _assetRegistry
    ) Ownable(msg.sender) {
        require(address(_token) != address(0), "Invalid token");
        require(_oracle != address(0), "Invalid oracle");
        require(address(_assetRegistry) != address(0), "Invalid registry");

        token = _token;
        oracle = _oracle;
        assetRegistry = _assetRegistry;
    }

    // ============ Core Functions ============

    /**
     * @inheritdoc IILRM
     * @dev Implements Invariant 1 (No Unilateral Cost Imposition) and
     *      Invariant 3 (Initiator Risk Precedence) - initiator stakes FIRST
     */
    function initiateBreachDispute(
        address _counterparty,
        uint256 _stakeAmount,
        bytes32 _evidenceHash,
        FallbackLicense calldata _fallback
    ) external override nonReentrant returns (uint256 disputeId) {
        require(_counterparty != address(0), "Invalid counterparty");
        require(_counterparty != msg.sender, "Cannot dispute self");
        require(_stakeAmount > 0, "Zero stake");
        require(_fallback.nonExclusive, "Fallback must be non-exclusive");

        // Calculate escalated stake for repeat disputes (Invariant 5: Harassment Is Net-Negative)
        uint256 escalatedStake = _getEscalatedStake(msg.sender, _counterparty, _stakeAmount);

        // Transfer stake from initiator (checks-effects-interactions)
        token.safeTransferFrom(msg.sender, address(this), escalatedStake);

        disputeId = _disputeCounter++;
        _disputes[disputeId] = Dispute({
            initiator: msg.sender,
            counterparty: _counterparty,
            initiatorStake: escalatedStake,
            counterpartyStake: 0,
            startTime: block.timestamp,
            evidenceHash: _evidenceHash,
            llmProposal: "",
            initiatorAccepted: false,
            counterpartyAccepted: false,
            resolved: false,
            outcome: DisputeOutcome.Pending,
            fallback: _fallback,
            counterCount: 0
        });

        // Freeze assets via registry
        assetRegistry.freezeAssets(disputeId, msg.sender);

        // Update cooldown tracking
        lastDisputeTime[msg.sender][_counterparty] = block.timestamp;

        emit DisputeInitiated(disputeId, msg.sender, _counterparty, _evidenceHash);
    }

    /**
     * @inheritdoc IILRM
     * @dev Implements Invariant 2 (Silence Is Always Free) - counterparty can ignore
     */
    function initiateVoluntaryRequest(
        address _counterparty,
        bytes32 _evidenceHash
    ) external payable override nonReentrant {
        require(_counterparty != address(0), "Invalid counterparty");
        require(msg.value >= COUNTER_FEE_BASE, "Insufficient burn fee");

        // Burn fee immediately (harassment self-tax)
        // Using call instead of transfer for compatibility
        (bool success, ) = BURN_ADDRESS.call{value: msg.value}("");
        require(success, "Burn failed");

        // Log as request (special ID indicates voluntary request, not full dispute)
        // Off-chain monitoring via event; counterparty ignores for free
        emit DisputeInitiated(type(uint256).max, msg.sender, _counterparty, _evidenceHash);
    }

    /**
     * @inheritdoc IILRM
     * @dev Implements Invariant 8 (Economic Symmetry by Default) - matched stakes
     */
    function depositStake(uint256 _disputeId) external override nonReentrant {
        Dispute storage d = _disputes[_disputeId];
        require(msg.sender == d.counterparty, "Not counterparty");
        require(d.counterpartyStake == 0, "Already staked");
        require(!d.resolved, "Dispute resolved");
        require(block.timestamp <= d.startTime + STAKE_WINDOW, "Stake window closed");

        // Match initiator's stake exactly (symmetric)
        token.safeTransferFrom(msg.sender, address(this), d.initiatorStake);
        d.counterpartyStake = d.initiatorStake;

        emit StakeDeposited(_disputeId, msg.sender, d.initiatorStake);
    }

    /**
     * @inheritdoc IILRM
     * @dev Only trusted oracle can submit proposals
     */
    function submitLLMProposal(
        uint256 _disputeId,
        string calldata _proposal,
        bytes calldata _signature
    ) external override nonReentrant {
        require(msg.sender == oracle, "Only oracle");

        Dispute storage d = _disputes[_disputeId];
        require(d.counterpartyStake > 0, "Not fully staked");
        require(!d.resolved, "Dispute resolved");
        require(bytes(_proposal).length > 0, "Empty proposal");

        // TODO: Verify EIP-712 signature on evidenceHash + proposal
        // require(_verifySignature(_disputeId, keccak256(bytes(_proposal)), _signature), "Invalid signature");
        (_signature); // Silence unused parameter warning for now

        d.llmProposal = _proposal;

        emit ProposalSubmitted(_disputeId, _proposal);
    }

    /// @inheritdoc IILRM
    function acceptProposal(uint256 _disputeId) external override nonReentrant {
        Dispute storage d = _disputes[_disputeId];
        require(!d.resolved, "Dispute resolved");
        require(bytes(d.llmProposal).length > 0, "No proposal yet");
        require(block.timestamp <= d.startTime + RESOLUTION_TIMEOUT, "Timeout passed");

        if (msg.sender == d.initiator) {
            require(!d.initiatorAccepted, "Already accepted");
            d.initiatorAccepted = true;
        } else if (msg.sender == d.counterparty) {
            require(!d.counterpartyAccepted, "Already accepted");
            d.counterpartyAccepted = true;
        } else {
            revert("Not a party");
        }

        emit AcceptanceSignaled(_disputeId, msg.sender);

        // Invariant 6: Mutuality or Exit - resolve when both accept
        if (d.initiatorAccepted && d.counterpartyAccepted) {
            _resolveAccepted(_disputeId, d);
        }
    }

    /**
     * @inheritdoc IILRM
     * @dev Implements Invariant 4 (Bounded Griefing) - capped counters, exponential fees
     */
    function counterPropose(
        uint256 _disputeId,
        bytes32 _newEvidenceHash
    ) external payable override nonReentrant {
        Dispute storage d = _disputes[_disputeId];
        require(msg.sender == d.initiator || msg.sender == d.counterparty, "Not a party");
        require(!d.resolved, "Dispute resolved");
        require(d.counterpartyStake > 0, "Not fully staked");
        require(d.counterCount < MAX_COUNTERS, "Max counters reached");

        // Exponential fee: base * 2^count (Invariant 4: Bounded Griefing)
        uint256 fee = COUNTER_FEE_BASE * (1 << d.counterCount);
        require(msg.value >= fee, "Insufficient counter fee");

        // Burn the fee
        (bool success, ) = BURN_ADDRESS.call{value: fee}("");
        require(success, "Burn failed");

        // Excess goes to treasury for subsidies
        if (msg.value > fee) {
            treasury += msg.value - fee;
        }

        d.counterCount++;
        d.evidenceHash = _newEvidenceHash;

        // Reset acceptance flags for new proposal round
        d.initiatorAccepted = false;
        d.counterpartyAccepted = false;
        d.llmProposal = "";

        // Extend timeout by 1 day per counter
        d.startTime += 1 days;

        emit CounterProposed(_disputeId, msg.sender, d.counterCount);
    }

    /**
     * @inheritdoc IILRM
     * @dev Implements Invariant 6 (Mutuality or Exit) - automatic resolution
     */
    function enforceTimeout(uint256 _disputeId) external override nonReentrant {
        Dispute storage d = _disputes[_disputeId];
        require(!d.resolved, "Already resolved");

        if (d.counterpartyStake == 0) {
            // Non-participation path: stake window must have passed
            require(block.timestamp > d.startTime + STAKE_WINDOW, "Stake window open");
            _resolveNonParticipation(_disputeId, d);
        } else {
            // Active dispute path: resolution timeout must have passed
            require(block.timestamp > d.startTime + RESOLUTION_TIMEOUT, "Not timed out");
            _resolveTimeout(_disputeId, d);
        }
    }

    // ============ View Functions ============

    /// @inheritdoc IILRM
    function disputes(uint256 _disputeId) external view override returns (
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
    ) {
        Dispute storage d = _disputes[_disputeId];
        return (
            d.initiator,
            d.counterparty,
            d.initiatorStake,
            d.counterpartyStake,
            d.startTime,
            d.evidenceHash,
            d.llmProposal,
            d.initiatorAccepted,
            d.counterpartyAccepted,
            d.resolved,
            d.outcome,
            d.fallback,
            d.counterCount
        );
    }

    /// @inheritdoc IILRM
    function disputeCounter() external view override returns (uint256) {
        return _disputeCounter;
    }

    /// @inheritdoc IILRM
    function getDisputeCount() external view override returns (uint256) {
        return _disputeCounter;
    }

    // ============ Internal Functions ============

    /**
     * @dev Calculate escalated stake for repeat disputes
     * @param _initiator Dispute initiator
     * @param _counterparty Dispute counterparty
     * @param _baseStake Base stake amount
     * @return Escalated stake (1.5x if within cooldown period)
     */
    function _getEscalatedStake(
        address _initiator,
        address _counterparty,
        uint256 _baseStake
    ) internal view returns (uint256) {
        uint256 lastDispute = lastDisputeTime[_initiator][_counterparty];
        if (lastDispute > 0 && block.timestamp < lastDispute + COOLDOWN_PERIOD) {
            // Escalate stake by 50% for repeat disputes within cooldown
            return (_baseStake * ESCALATION_MULTIPLIER) / 100;
        }
        return _baseStake;
    }

    /**
     * @dev Resolve dispute via mutual acceptance
     * @param _disputeId Dispute ID
     * @param d Dispute storage reference
     */
    function _resolveAccepted(uint256 _disputeId, Dispute storage d) internal {
        d.resolved = true;
        d.outcome = DisputeOutcome.AcceptedProposal;

        // Return full stakes to both parties
        token.safeTransfer(d.initiator, d.initiatorStake);
        token.safeTransfer(d.counterparty, d.counterpartyStake);

        // Unfreeze assets with proposal outcome
        assetRegistry.unfreezeAssets(_disputeId, bytes(d.llmProposal));

        emit DisputeResolved(_disputeId, DisputeOutcome.AcceptedProposal);
    }

    /**
     * @dev Resolve dispute when counterparty doesn't stake
     * @param _disputeId Dispute ID
     * @param d Dispute storage reference
     */
    function _resolveNonParticipation(uint256 _disputeId, Dispute storage d) internal {
        d.resolved = true;
        d.outcome = DisputeOutcome.DefaultLicenseApplied;

        // Calculate initiator incentive (10% of expected counterparty stake)
        uint256 incentive = (d.initiatorStake * INITIATOR_INCENTIVE_BPS) / 10000;

        // Return initiator stake + incentive (from token reserves)
        // FIX C-01: Actually transfer the incentive when reserves are sufficient
        if (tokenReserves >= incentive) {
            tokenReserves -= incentive;
            token.safeTransfer(d.initiator, d.initiatorStake + incentive);
        } else {
            // If reserves insufficient, just return stake
            token.safeTransfer(d.initiator, d.initiatorStake);
        }

        // Apply fallback license
        assetRegistry.applyFallbackLicense(_disputeId, d.fallback.termsHash);
        assetRegistry.unfreezeAssets(_disputeId, abi.encode(d.outcome));

        emit DefaultLicenseApplied(_disputeId);
        emit DisputeResolved(_disputeId, DisputeOutcome.DefaultLicenseApplied);
    }

    /**
     * @dev Resolve dispute on timeout with burn
     * @param _disputeId Dispute ID
     * @param d Dispute storage reference
     */
    function _resolveTimeout(uint256 _disputeId, Dispute storage d) internal {
        d.resolved = true;
        d.outcome = DisputeOutcome.TimeoutWithBurn;

        uint256 totalStake = d.initiatorStake + d.counterpartyStake;
        uint256 burnAmount = (totalStake * BURN_PERCENTAGE) / 100;
        uint256 remainder = totalStake - burnAmount;

        // Burn tokens to dead address
        token.safeTransfer(BURN_ADDRESS, burnAmount);

        // Add half of burn to treasury for future subsidies
        // (conceptually - actual treasury management would be more complex)

        // Return remaining stake symmetrically
        uint256 returnPerParty = remainder / 2;
        token.safeTransfer(d.initiator, returnPerParty);
        token.safeTransfer(d.counterparty, returnPerParty);

        // Handle dust (any odd wei from division)
        uint256 dust = remainder - (returnPerParty * 2);
        if (dust > 0) {
            treasury += dust;
        }

        // Apply fallback license
        assetRegistry.applyFallbackLicense(_disputeId, d.fallback.termsHash);
        assetRegistry.unfreezeAssets(_disputeId, abi.encode(d.outcome));

        emit StakesBurned(_disputeId, burnAmount);
        emit DisputeResolved(_disputeId, DisputeOutcome.TimeoutWithBurn);
    }

    // ============ Admin Functions ============

    /**
     * @notice Deposit tokens into reserves for initiator incentives
     * @dev Anyone can contribute to the incentive pool
     * @param _amount Amount of tokens to deposit
     */
    function depositTokenReserves(uint256 _amount) external nonReentrant {
        require(_amount > 0, "Zero amount");
        token.safeTransferFrom(msg.sender, address(this), _amount);
        tokenReserves += _amount;
        emit TokenReservesDeposited(msg.sender, _amount);
    }

    /**
     * @notice Update harassment score for a participant
     * @dev Only owner can update; used for off-chain analysis integration
     * @param _participant Address to update
     * @param _score New harassment score
     */
    function updateHarassmentScore(address _participant, uint256 _score) external onlyOwner {
        uint256 oldScore = harassmentScore[_participant];
        harassmentScore[_participant] = _score;
        emit HarassmentScoreUpdated(_participant, oldScore, _score);
    }

    /**
     * @notice Withdraw treasury funds (for subsidies, audits, etc.)
     * @dev Only owner; in production, this would be DAO-controlled
     * @param _to Recipient address
     * @param _amount Amount to withdraw
     */
    function withdrawTreasury(address _to, uint256 _amount) external onlyOwner {
        require(_amount <= treasury, "Insufficient treasury");
        require(_to != address(0), "Invalid recipient");
        treasury -= _amount;
        // Note: Treasury tracks ETH from counter fees, not tokens
        (bool success, ) = _to.call{value: _amount}("");
        require(success, "Transfer failed");
    }

    /// @notice Accept ETH for treasury (from external sources)
    receive() external payable {
        treasury += msg.value;
    }
}
