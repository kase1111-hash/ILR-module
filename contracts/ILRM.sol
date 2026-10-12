// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./interfaces/IILRM.sol";
import "./interfaces/IOracle.sol";
import "./interfaces/IAssetRegistry.sol";

/**
 * @title ILRM - IP & Licensing Reconciliation Module
 * @notice Core implementation of the NatLangChain ILRM Protocol v1.1
 * @dev Implements non-adjudicative dispute resolution with economic incentives
 *
 * Key Features:
 * - Dual initiation: Breach disputes (stakes first) vs voluntary requests (burn-only)
 * - Anti-harassment: Exponential counters, cooldowns, escalating stakes
 * - Spec-compliant: Follows Protocol-Safety-Invariants.md
 * - Analytics-ready: Events for every state transition
 * - Pausable for emergency stops
 * - Two-step ownership transfer via Ownable2Step
 * - Optional Treasury-backed defensive stake subsidies (depositStakeWithSubsidy): the subsidy is
 *   escrowed here as part of the counterparty stake, never paid to a wallet, and the funder is repaid
 *   its pro-rata share of the counterparty payout on resolution; the caller bounds its own top-up
 *   (maxTopUp), so a shrunken grant can force a revert but never an overcharge
 * - Initiator incentive on counterparty non-participation: 10% of the stake from tokenReserves, capped
 *   per dispute and across all disputes per window (setInitiatorIncentiveCaps); the initiator always
 *   gets its full stake back, with a partial or zero incentive once a cap or the reserves run out
 *
 * Identity/privacy modules (ZK, FIDO, DID, viewing keys) are available as
 * separate composable contracts in contracts/modules/.
 */
contract ILRM is IILRM, ReentrancyGuard, Pausable, Ownable2Step {
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

    /// @notice Initiator incentive rate on counterparty non-stake, before the incentive caps (10% = 1000 bps)
    uint256 public constant INITIATOR_INCENTIVE_BPS = 1000;

    /// @notice Shortest allowed initiator-incentive window
    uint256 public constant MIN_INCENTIVE_WINDOW = 1 days;

    /// @notice Longest allowed initiator-incentive window
    uint256 public constant MAX_INCENTIVE_WINDOW = 365 days;

    /// @notice Default cap on a single initiator incentive (1 token; assumes 18 decimals, like deploy.js)
    uint256 public constant DEFAULT_MAX_INCENTIVE_PER_DISPUTE = 1e18;

    /// @notice Default cap on all initiator incentives paid per window (10 tokens; assumes 18 decimals)
    uint256 public constant DEFAULT_MAX_INCENTIVE_PER_WINDOW = 10e18;

    /// @notice Default initiator-incentive window
    uint256 public constant DEFAULT_INCENTIVE_WINDOW = 30 days;

    /// @notice Stake escalation multiplier for repeat disputes (150% = 1.5x)
    uint256 public constant ESCALATION_MULTIPLIER = 150;

    /// @notice Cooldown period between disputes with same counterparty
    uint256 public constant COOLDOWN_PERIOD = 30 days;

    /// @notice Maximum total time extension from counter-proposals (3 days)
    /// @dev Prevents indefinite delays - one day per counter, capped at MAX_COUNTERS
    uint256 public constant MAX_TIME_EXTENSION = 3 days;

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

    // ---- Initiator-incentive caps ----
    // On non-participation the initiator gets its stake back plus 10% of it from tokenReserves. The
    // counterparty can be a sybil of the initiator that simply never stakes, and a fresh counterparty faces
    // no stake escalation, so uncapped this let anyone farm the reserves at 10% of their stake per 3-day
    // cycle (one dispute staked at 10x the reserves drained them at once). Every payout is therefore
    // min(10% of stake, maxIncentivePerDispute, maxIncentivePerWindow - incentivePaidInWindow, tokenReserves).
    // The window cap is global, not keyed by address, so it holds against sybils.
    // Residual risk (accepted): farming up to maxIncentivePerWindow per window remains possible. Under a
    // fixed config (window T, window cap W) at most W * (ceil(t / T) + 1) is paid over any interval of
    // length t (2W across a window boundary), and never more than the deposited reserves.

    /// @notice Cap on a single initiator incentive
    uint256 public maxIncentivePerDispute;

    /// @notice Cap on all initiator incentives paid in one incentive window
    uint256 public maxIncentivePerWindow;

    /// @notice Initiator-incentive window length in seconds
    uint256 public incentiveWindow;

    /// @notice Start of the current incentive window (rolled lazily by the first payout after it expires)
    uint256 public incentiveWindowStart;

    /// @notice Initiator incentives paid in the current incentive window
    uint256 public incentivePaidInWindow;

    /// @notice Treasury allowed to fund defensive stake subsidies (address(0) = subsidies disabled)
    address public subsidyTreasury;

    /// @dev disputeId => who funded part of the counterparty stake and how much
    mapping(uint256 => StakeSubsidy) private _stakeSubsidies;

    // ============ Constructor ============

    /**
     * @param _token NatLangChain ERC20 token for staking
     * @param _oracle Trusted oracle address for LLM proposals
     * @param _assetRegistry Asset registry contract
     */
    constructor(IERC20 _token, address _oracle, IAssetRegistry _assetRegistry) Ownable(msg.sender) {
        require(address(_token) != address(0), "Invalid token");
        require(_oracle != address(0), "Invalid oracle");
        require(address(_assetRegistry) != address(0), "Invalid registry");

        token = _token;
        oracle = _oracle;
        assetRegistry = _assetRegistry;

        _setInitiatorIncentiveCaps(
            DEFAULT_MAX_INCENTIVE_PER_DISPUTE, DEFAULT_MAX_INCENTIVE_PER_WINDOW, DEFAULT_INCENTIVE_WINDOW
        );
        incentiveWindowStart = block.timestamp;
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
    ) external override nonReentrant whenNotPaused returns (uint256 disputeId) {
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
            fallbackLicense: _fallback,
            counterCount: 0
        });

        // Update cooldown tracking
        lastDisputeTime[msg.sender][_counterparty] = block.timestamp;

        // Freeze assets via registry
        assetRegistry.freezeAssets(disputeId, msg.sender);

        emit DisputeInitiated(disputeId, msg.sender, _counterparty, _evidenceHash);
    }

    /**
     * @inheritdoc IILRM
     * @dev Implements Invariant 2 (Silence Is Always Free) - counterparty can ignore
     */
    function initiateVoluntaryRequest(address _counterparty, bytes32 _evidenceHash)
        external
        payable
        override
        nonReentrant
    {
        require(_counterparty != address(0), "Invalid counterparty");
        require(msg.value >= COUNTER_FEE_BASE, "Insufficient burn fee");

        // Burn fee immediately (harassment self-tax)
        (bool success,) = BURN_ADDRESS.call{value: msg.value}("");
        require(success, "Burn failed");

        // Log as request (special ID indicates voluntary request, not full dispute)
        // Off-chain monitoring via event; counterparty ignores for free
        emit DisputeInitiated(type(uint256).max, msg.sender, _counterparty, _evidenceHash);
    }

    /**
     * @inheritdoc IILRM
     * @dev Implements Invariant 8 (Economic Symmetry by Default) - matched stakes.
     *      A low-resource counterparty can instead opt in to depositStakeWithSubsidy, which stakes the
     *      same amount with part of it funded by the subsidy treasury.
     */
    function depositStake(uint256 _disputeId) external override nonReentrant whenNotPaused {
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
     * @dev FIX H-01: Signature verification is now enforced via Oracle contract
     * @dev The Oracle admits one proposal per round (counterCount); a live proposal is replaced only via the
     *      Oracle owner's recovery path. Storing any proposal voids both acceptances, so an acceptance always
     *      refers to the live proposal.
     */
    function submitLLMProposal(uint256 _disputeId, string calldata _proposal, bytes calldata _signature)
        external
        override
        nonReentrant
    {
        require(msg.sender == oracle, "Only oracle");

        Dispute storage d = _disputes[_disputeId];
        require(d.counterpartyStake > 0, "Not fully staked");
        require(!d.resolved, "Dispute resolved");
        require(block.timestamp <= d.startTime + RESOLUTION_TIMEOUT, "Timeout passed");
        require(bytes(_proposal).length > 0, "Empty proposal");

        // FIX H-01: Verify EIP-712 signature via Oracle contract
        // Defense in depth - Oracle already verifies, but we double-check
        bytes32 proposalHash = keccak256(bytes(_proposal));
        require(IOracle(oracle).verifySignature(_disputeId, proposalHash, _signature), "Invalid signature");

        // Replacing a live proposal in the same round (Oracle owner recovery)
        if (bytes(d.llmProposal).length != 0) {
            emit ProposalSuperseded(_disputeId, d.counterCount, keccak256(bytes(d.llmProposal)), proposalHash);
        }

        // An acceptance always refers to the live proposal: storing any proposal voids both acceptances
        d.initiatorAccepted = false;
        d.counterpartyAccepted = false;
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
    function counterPropose(uint256 _disputeId, bytes32 _newEvidenceHash)
        external
        payable
        override
        nonReentrant
        whenNotPaused
    {
        Dispute storage d = _disputes[_disputeId];
        require(msg.sender == d.initiator || msg.sender == d.counterparty, "Not a party");
        require(!d.resolved, "Dispute resolved");
        require(d.counterpartyStake > 0, "Not fully staked");
        require(d.counterCount < MAX_COUNTERS, "Max counters reached");

        // Exponential fee: base * 2^count (Invariant 4: Bounded Griefing)
        // Safe: counterCount is guaranteed < MAX_COUNTERS (3) by require above
        // Defense in depth: ensure shift doesn't overflow (max safe is 255)
        require(d.counterCount < 64, "Counter overflow protection");
        uint256 fee = COUNTER_FEE_BASE * (1 << d.counterCount);
        require(msg.value >= fee, "Insufficient counter fee");

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

        // Extend timeout by 1 day per counter, but cap at MAX_TIME_EXTENSION
        // This prevents indefinite delays while still allowing reasonable extensions
        uint256 currentExtension = d.counterCount * 1 days; // counterCount already incremented
        if (currentExtension <= MAX_TIME_EXTENSION) {
            d.startTime += 1 days;
        }
        // If we've hit max extension, no further time added

        // Burn the fee (after state updates: checks-effects-interactions)
        (bool success,) = BURN_ADDRESS.call{value: fee}("");
        require(success, "Burn failed");

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

    /**
     * @inheritdoc IILRM
     * @dev Invariant 8 (Economic Symmetry by Default): a Treasury-backed defensive subsidy is an opt-in
     *      exception for the counterparty only, and stakes stay symmetric (counterpartyStake ==
     *      initiatorStake). The subsidy is escrowed here as part of that stake - it never reaches the
     *      counterparty's wallet - and _payCounterpartySide repays the recorded funder its pro-rata share
     *      of whatever the counterparty side receives on resolution.
     *      Slippage bound: the grant is only known once the treasury has run, so the caller's top-up
     *      (stake - grant) is checked against _maxTopUp twice - before the treasury call against the best
     *      case (requested bounds any grant from above), and after it against the actual grant, before any
     *      record or transfer. The caller's outflow is therefore <= _maxTopUp whatever ran before it, and
     *      any failure reverts atomically: a front-runner can force a revert but never an overcharge. The
     *      bound only restricts the caller, so it cannot be used to draw more from the treasury.
     */
    function depositStakeWithSubsidy(uint256 _disputeId, uint256 _maxSubsidy, uint256 _maxTopUp)
        external
        override
        nonReentrant
        whenNotPaused
    {
        Dispute storage d = _disputes[_disputeId];
        require(msg.sender == d.counterparty, "Not counterparty");
        require(d.counterpartyStake == 0, "Already staked");
        require(!d.resolved, "Dispute resolved");
        require(block.timestamp <= d.startTime + STAKE_WINDOW, "Stake window closed");

        address funder = subsidyTreasury;
        require(funder != address(0), "Subsidies disabled");
        require(_maxSubsidy > 0, "Zero subsidy");

        uint256 stake = d.initiatorStake;
        uint256 requested = _maxSubsidy < stake ? _maxSubsidy : stake;
        // Pre-call check: requested is an upper bound on any grant, so this only rejects a bound that can
        // never be met, before the treasury is called (requested <= stake, so no underflow)
        require(stake - requested <= _maxTopUp, "Top-up exceeds max");

        // Effect before any external call: the treasury verifies the matching stake is committed
        d.counterpartyStake = stake;

        uint256 subsidy = ISubsidyTreasury(funder).fundStakeSubsidy(_disputeId, msg.sender, requested);
        require(subsidy > 0 && subsidy <= requested, "Invalid subsidy");
        // The grant may have shrunk since the caller's preview; never charge the caller more than it
        // bounded (checked before the record below and before both transfers)
        require(stake - subsidy <= _maxTopUp, "Top-up exceeds max");

        // Recorded after the treasury call because the granted amount is only known now. Safe against
        // reentrancy: this function is nonReentrant, and every reader of the record (acceptProposal and
        // enforceTimeout, via _payCounterpartySide) is nonReentrant too.
        _stakeSubsidies[_disputeId] = StakeSubsidy({funder: funder, amount: subsidy});

        // Pull exactly the granted subsidy; the funder approved exactly this amount in fundStakeSubsidy.
        // A treasury that did not pay makes this revert, so escrow can never be under-collateralised.
        // slither-disable-next-line arbitrary-send-erc20
        token.safeTransferFrom(funder, address(this), subsidy);

        // The counterparty pays the rest: at most _maxTopUp (checked above)
        if (stake > subsidy) {
            token.safeTransferFrom(msg.sender, address(this), stake - subsidy);
        }

        emit StakeSubsidized(_disputeId, msg.sender, funder, subsidy);
        emit StakeDeposited(_disputeId, msg.sender, stake);
    }

    // ============ View Functions ============

    /// @inheritdoc IILRM
    function disputes(uint256 _disputeId) external view override returns (Dispute memory) {
        return _disputes[_disputeId];
    }

    /// @inheritdoc IILRM
    function disputeCounter() external view override returns (uint256) {
        return _disputeCounter;
    }

    /// @inheritdoc IILRM
    function getDisputeCount() external view override returns (uint256) {
        return _disputeCounter;
    }

    /**
     * @inheritdoc IILRM
     * @dev Records are kept after resolution as history; double repayment is impossible because every
     *      resolve function sets `resolved` before paying out.
     */
    function stakeSubsidy(uint256 _disputeId) external view override returns (address funder, uint256 amount) {
        StakeSubsidy memory s = _stakeSubsidies[_disputeId];
        return (s.funder, s.amount);
    }

    // ============ Internal Functions ============

    /**
     * @dev Calculate escalated stake for repeat disputes
     * @param _initiator Dispute initiator
     * @param _counterparty Dispute counterparty
     * @param _baseStake Base stake amount
     * @return Escalated stake (1.5x if within cooldown period)
     */
    function _getEscalatedStake(address _initiator, address _counterparty, uint256 _baseStake)
        internal
        view
        returns (uint256)
    {
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
        _payCounterpartySide(_disputeId, d, d.counterpartyStake);

        // Unfreeze assets with proposal outcome
        assetRegistry.unfreezeAssets(_disputeId, bytes(d.llmProposal));

        emit DisputeResolved(_disputeId, DisputeOutcome.AcceptedProposal);
    }

    /**
     * @dev Resolve dispute when counterparty doesn't stake. The initiator always gets its full stake back,
     *      plus the initiator incentive (10% of the stake) within the incentive caps: partial or 0 once
     *      maxIncentivePerDispute, the window budget or tokenReserves bind (see _takeInitiatorIncentive).
     *      The incentive never makes this revert: it adds no external call and no require, and all state
     *      is written before the single transfer (enforceTimeout is nonReentrant).
     * @param _disputeId Dispute ID
     * @param d Dispute storage reference
     */
    function _resolveNonParticipation(uint256 _disputeId, Dispute storage d) internal {
        d.resolved = true;
        d.outcome = DisputeOutcome.DefaultLicenseApplied;

        // Uncapped initiator incentive: 10% of the stake the counterparty would have matched
        uint256 uncapped = (d.initiatorStake * INITIATOR_INCENTIVE_BPS) / 10_000;
        uint256 incentive = _takeInitiatorIncentive(uncapped);

        // Return initiator stake + capped incentive (already taken from tokenReserves; may be 0)
        token.safeTransfer(d.initiator, d.initiatorStake + incentive);
        emit InitiatorIncentivePaid(_disputeId, d.initiator, incentive, uncapped);

        // Apply fallback license
        assetRegistry.applyFallbackLicense(_disputeId, d.fallbackLicense.termsHash);
        assetRegistry.unfreezeAssets(_disputeId, abi.encode(d.outcome));

        emit DefaultLicenseApplied(_disputeId);
        emit DisputeResolved(_disputeId, DisputeOutcome.DefaultLicenseApplied);
    }

    /**
     * @dev Quote the capped initiator incentive at the current block without writing state:
     *      min(_uncapped, maxIncentivePerDispute, window budget left, tokenReserves). The window is fixed
     *      and rolled lazily: once block.timestamp >= incentiveWindowStart + incentiveWindow, the quote
     *      treats a new window as starting now with nothing paid in it.
     * @param _uncapped The uncapped incentive (10% of the initiator stake)
     * @return incentive The incentive payable now
     * @return windowStart The window start that applies to this payout (rolled if expired)
     * @return paidInWindow Incentives already paid in that window (0 if rolled)
     */
    function _quoteInitiatorIncentive(uint256 _uncapped)
        internal
        view
        returns (uint256 incentive, uint256 windowStart, uint256 paidInWindow)
    {
        windowStart = incentiveWindowStart;
        paidInWindow = incentivePaidInWindow;
        if (block.timestamp >= windowStart + incentiveWindow) {
            windowStart = block.timestamp;
            paidInWindow = 0;
        }

        uint256 maxPerWindow = maxIncentivePerWindow;
        uint256 windowLeft = maxPerWindow > paidInWindow ? maxPerWindow - paidInWindow : 0;

        incentive = Math.min(Math.min(_uncapped, maxIncentivePerDispute), Math.min(windowLeft, tokenReserves));
    }

    /**
     * @dev Take the capped initiator incentive out of tokenReserves and charge it to the current window.
     *      Never reverts. With a 0 incentive (a cap or the reserves exhausted, or zero caps) it writes no
     *      state at all, so the window is not rolled and tokenReserves stays untouched.
     *      Residual risk (accepted): the caps bound farming but do not stop it. Under a fixed config each
     *      payout is <= min(10% of the stake, maxIncentivePerDispute), incentivePaidInWindow stays <=
     *      maxIncentivePerWindow (W), and over any interval of length t at most W * (ceil(t / T) + 1) is
     *      paid (T = incentiveWindow; 2W across a window boundary), never more than the deposited reserves.
     *      The window budget is first come, first served across all initiators.
     * @param _uncapped The uncapped incentive (10% of the initiator stake)
     * @return incentive The incentive to pay on top of the returned stake
     */
    function _takeInitiatorIncentive(uint256 _uncapped) internal returns (uint256 incentive) {
        uint256 windowStart;
        uint256 paidInWindow;
        (incentive, windowStart, paidInWindow) = _quoteInitiatorIncentive(_uncapped);
        if (incentive > 0) {
            if (windowStart != incentiveWindowStart) incentiveWindowStart = windowStart;
            incentivePaidInWindow = paidInWindow + incentive;
            tokenReserves -= incentive;
        }
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

        // Return remaining stake symmetrically
        uint256 returnPerParty = remainder / 2;
        token.safeTransfer(d.initiator, returnPerParty);
        _payCounterpartySide(_disputeId, d, returnPerParty);

        // Handle dust (any odd wei from division) - burn any remainder
        uint256 dust = remainder % 2;
        if (dust > 0) {
            token.safeTransfer(BURN_ADDRESS, dust);
        }

        // Apply fallback license
        assetRegistry.applyFallbackLicense(_disputeId, d.fallbackLicense.termsHash);
        assetRegistry.unfreezeAssets(_disputeId, abi.encode(d.outcome));

        emit StakesBurned(_disputeId, burnAmount);
        emit DisputeResolved(_disputeId, DisputeOutcome.TimeoutWithBurn);
    }

    /**
     * @dev Pay the counterparty side of a resolution. Without a subsidy this is the plain transfer to the
     *      counterparty. With one, the payout is split pro rata between the counterparty (own share of
     *      the stake, rounded down) and the recorded funder (the remainder): on mutual acceptance the
     *      funder gets its full subsidy back, on timeout it bears its share of the burn.
     *      Repayment is a plain ERC20 transfer, so resolution never runs treasury code.
     *      Invariants: s.amount <= counterpartyStake (enforced in depositStakeWithSubsidy), and
     *      counterpartyStake > 0 whenever s.amount > 0, so there is no division by zero.
     * @param _disputeId Dispute ID
     * @param d Dispute storage reference
     * @param _amount Total amount owed to the counterparty side
     */
    function _payCounterpartySide(uint256 _disputeId, Dispute storage d, uint256 _amount) internal {
        // Storage pointer: the unsubsidized path reads only the amount slot, never the funder slot
        StakeSubsidy storage s = _stakeSubsidies[_disputeId];
        uint256 subsidy = s.amount;
        if (subsidy == 0) {
            token.safeTransfer(d.counterparty, _amount);
            return;
        }

        uint256 cpStake = d.counterpartyStake;
        uint256 own = Math.mulDiv(_amount, cpStake - subsidy, cpStake);
        uint256 toFunder = _amount - own;

        if (own > 0) {
            token.safeTransfer(d.counterparty, own);
        }
        if (toFunder > 0) {
            address funder = s.funder;
            token.safeTransfer(funder, toFunder);
            emit SubsidyReturned(_disputeId, funder, toFunder);
        }
    }

    // ============ Admin Functions ============

    /**
     * @notice Set the treasury allowed to fund defensive stake subsidies
     * @dev Only owner. address(0) disables depositStakeWithSubsidy. Rotation only affects future
     *      subsidized stakes: existing disputes repay the funder recorded when they were staked.
     * @param _treasury Treasury implementing ISubsidyTreasury, or address(0) to disable subsidies
     */
    function setSubsidyTreasury(address _treasury) external onlyOwner {
        emit SubsidyTreasuryUpdated(subsidyTreasury, _treasury);
        // address(0) is a valid value: it disables depositStakeWithSubsidy
        // slither-disable-next-line missing-zero-check
        subsidyTreasury = _treasury;
    }

    // ============ Initiator Incentive ============

    /**
     * @notice Set the initiator-incentive caps
     * @dev Only owner (intended owner: GovernanceTimelock). Deliberately not whenNotPaused: enforceTimeout
     *      cannot be paused, so the kill switch (zero caps, which are allowed) must work while paused.
     *      There is no absolute ceiling: the owner can raise the caps up to the deposited reserves (owner
     *      trust). The current window is not reset: a cap lowered below incentivePaidInWindow pays 0 until
     *      the window rolls, and a new window length applies to the current window (its start is kept).
     *      There is deliberately no per-initiator cap: initiator addresses are free, so sybils would defeat
     *      it and it would only cost gas. The global window cap is what bounds farming.
     * @param _maxPerDispute Cap on a single incentive (must be <= _maxPerWindow)
     * @param _maxPerWindow Cap on all incentives paid in one window
     * @param _window Window length in seconds, MIN_INCENTIVE_WINDOW to MAX_INCENTIVE_WINDOW inclusive
     */
    function setInitiatorIncentiveCaps(uint256 _maxPerDispute, uint256 _maxPerWindow, uint256 _window)
        external
        onlyOwner
    {
        _setInitiatorIncentiveCaps(_maxPerDispute, _maxPerWindow, _window);
    }

    /**
     * @notice Preview the initiator incentive a non-participation resolution would pay now
     * @dev Same caps as the payout. The actual payout can be lower if other payouts land first (the window
     *      budget is first come, first served across all initiators).
     * @param _initiatorStake The dispute's initiatorStake
     * @return The incentive that would be paid on top of the returned stake
     */
    function previewInitiatorIncentive(uint256 _initiatorStake) external view returns (uint256) {
        (uint256 incentive,,) = _quoteInitiatorIncentive((_initiatorStake * INITIATOR_INCENTIVE_BPS) / 10_000);
        return incentive;
    }

    /**
     * @dev Validate and store the initiator-incentive caps and emit InitiatorIncentiveCapsUpdated. Does not
     *      touch incentiveWindowStart or incentivePaidInWindow.
     */
    function _setInitiatorIncentiveCaps(uint256 _maxPerDispute, uint256 _maxPerWindow, uint256 _window) private {
        require(_window >= MIN_INCENTIVE_WINDOW && _window <= MAX_INCENTIVE_WINDOW, "Invalid incentive window");
        require(_maxPerDispute <= _maxPerWindow, "Per-dispute cap above window cap");

        maxIncentivePerDispute = _maxPerDispute;
        maxIncentivePerWindow = _maxPerWindow;
        incentiveWindow = _window;

        emit InitiatorIncentiveCapsUpdated(_maxPerDispute, _maxPerWindow, _window);
    }

    /**
     * @notice Deposit tokens into reserves for initiator incentives
     * @dev Anyone can contribute to the incentive pool. Deposits are irrevocable: there is no withdrawal
     *      path, and reserves leave ILRM only as capped initiator incentives on non-participation
     *      resolutions (see setInitiatorIncentiveCaps). With zero caps they stay locked.
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
        (bool success,) = _to.call{value: _amount}("");
        require(success, "Transfer failed");
        emit TreasuryWithdrawn(_to, _amount);
    }

    /**
     * @notice Pause contract in case of emergency
     * @dev Only owner can pause
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause contract
     * @dev Only owner can unpause
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Accept ETH for treasury (from external sources)
    receive() external payable {
        treasury += msg.value;
    }
}
