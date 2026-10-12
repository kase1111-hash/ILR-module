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
 *   its pro-rata share of the counterparty payout on resolution
 *
 * Identity/privacy modules (ZK, FIDO, DID, viewing keys) are available as
 * separate composable contracts in contracts/modules/.
 */
contract ILRM is IILRM, IOracleConsumer, ReentrancyGuard, Pausable, Ownable2Step {
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
        _requestOracleProposal(_disputeId);
    }

    /**
     * @inheritdoc IILRM
     * @dev Only trusted oracle can submit proposals
     * @dev FIX H-01: Signature verification is now enforced via Oracle contract
     * @dev The Oracle admits one proposal per round (counterCount); a live proposal is replaced only via the
     *      Oracle owner's recovery path, which voids it first (voidLLMProposal). Storing any proposal voids both
     *      acceptances, so an acceptance always refers to the live proposal.
     */
    function submitLLMProposal(uint256 _disputeId, string calldata _proposal, bytes calldata _signature)
        external
        override(IILRM, IOracleConsumer)
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

        // Replacing a live proposal in the same round. Defence in depth: NatLangChainOracle voids the live
        // proposal (voidLLMProposal) before any replacement, so this branch does not trigger on that path.
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
        _acceptProposal(_disputeId, false, bytes32(0));
    }

    /// @inheritdoc IILRM
    function acceptProposalWithHash(uint256 _disputeId, bytes32 _proposalHash) external override nonReentrant {
        _acceptProposal(_disputeId, true, _proposalHash);
    }

    /**
     * @dev Shared body of acceptProposal and acceptProposalWithHash. With _bound, the acceptance only counts if the
     *      live proposal hashes to _proposalHash (computed from the stored text; no extra storage).
     */
    function _acceptProposal(uint256 _disputeId, bool _bound, bytes32 _proposalHash) private {
        Dispute storage d = _disputes[_disputeId];
        require(!d.resolved, "Dispute resolved");
        require(bytes(d.llmProposal).length > 0, "No proposal yet");
        require(block.timestamp <= d.startTime + RESOLUTION_TIMEOUT, "Timeout passed");
        require(!_bound || keccak256(bytes(d.llmProposal)) == _proposalHash, "Proposal changed");

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
     * @dev Implements Invariant 4 (Bounded Griefing) - capped counters, exponential fees.
     *      Rejected after startTime + RESOLUTION_TIMEOUT: a late counter must not push startTime forward and
     *      revive a timed-out dispute. Requests a proposal for the new round from the Oracle (advisory).
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
        // A timed-out dispute is only resolvable via enforceTimeout; a late counter must not revive it
        require(block.timestamp <= d.startTime + RESOLUTION_TIMEOUT, "Timeout passed");
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
        _requestOracleProposal(_disputeId);
    }

    // ============ Oracle consumer ============

    /// @notice Gas forwarded to the advisory Oracle.requestProposal call
    uint256 public constant ORACLE_REQUEST_GAS = 100_000;

    /**
     * @inheritdoc IOracleConsumer
     * @dev Plain view (not nonReentrant); reads the storage fields directly, without copying the Dispute struct.
     */
    function oracleContext(uint256 _disputeId)
        external
        view
        override
        returns (uint256 round, bytes32 evidenceHash, bool resolved, uint256 deadline)
    {
        Dispute storage d = _disputes[_disputeId];
        return (d.counterCount, d.evidenceHash, d.resolved, d.startTime + RESOLUTION_TIMEOUT);
    }

    /**
     * @inheritdoc IOracleConsumer
     * @dev Deliberately not whenNotPaused: recovery must work while ILRM is paused (acceptProposal is not
     *      pausable either). No external calls.
     */
    function voidLLMProposal(uint256 _disputeId, bytes32 _proposalHash) external override nonReentrant {
        require(msg.sender == oracle, "Only oracle");

        Dispute storage d = _disputes[_disputeId];
        require(!d.resolved, "Dispute resolved");
        require(block.timestamp <= d.startTime + RESOLUTION_TIMEOUT, "Timeout passed");

        // Nothing live (e.g. a stale Oracle slot after re-pointing setILRM): the acceptance flags are
        // necessarily false, since storing or clearing a proposal always clears them
        if (bytes(d.llmProposal).length == 0) return;

        // Compare-and-clear: never void a proposal the oracle did not name
        require(keccak256(bytes(d.llmProposal)) == _proposalHash, "Proposal mismatch");

        d.llmProposal = "";
        d.initiatorAccepted = false;
        d.counterpartyAccepted = false;

        emit ProposalVoided(_disputeId, d.counterCount, _proposalHash);
    }

    /**
     * @dev Ask the Oracle for a proposal of the dispute's current round. Advisory: never blocks staking or
     *      countering. The Oracle's requestProposal is onlyILRM and makes no calls; every caller is nonReentrant
     *      and calls this as its last statement.
     *      - No code at the oracle: emit and return (try/catch cannot catch Solidity's pre-call extcodesize revert
     *        for a function with no return values).
     *      - Gas floor: with this much gas left, EIP-150 always forwards the full ORACLE_REQUEST_GAS, so a
     *        transaction that succeeds never silently dropped the request for lack of gas.
     *      - Capped try/catch: a reverting or gas-burning Oracle only costs ORACLE_REQUEST_GAS and emits
     *        OracleRequestFailed. catch without parameters copies no returndata.
     * @param _disputeId Dispute ID
     */
    function _requestOracleProposal(uint256 _disputeId) internal {
        Dispute storage d = _disputes[_disputeId];
        if (oracle.code.length == 0) {
            emit OracleRequestFailed(_disputeId, d.counterCount);
            return;
        }
        require(gasleft() >= ORACLE_REQUEST_GAS + ORACLE_REQUEST_GAS / 63 + 10_000, "Insufficient gas");
        try IOracle(oracle).requestProposal{gas: ORACLE_REQUEST_GAS}(_disputeId, d.evidenceHash) {}
        catch {
            emit OracleRequestFailed(_disputeId, d.counterCount);
        }
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
     */
    function depositStakeWithSubsidy(uint256 _disputeId, uint256 _maxSubsidy)
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

        // Effect before any external call: the treasury verifies the matching stake is committed
        d.counterpartyStake = stake;

        uint256 subsidy = ISubsidyTreasury(funder).fundStakeSubsidy(_disputeId, msg.sender, requested);
        require(subsidy > 0 && subsidy <= requested, "Invalid subsidy");

        // Recorded after the treasury call because the granted amount is only known now. Safe against
        // reentrancy: this function is nonReentrant, and every reader of the record (acceptProposal and
        // enforceTimeout, via _payCounterpartySide) is nonReentrant too.
        _stakeSubsidies[_disputeId] = StakeSubsidy({funder: funder, amount: subsidy});

        // Pull exactly the granted subsidy; the funder approved exactly this amount in fundStakeSubsidy.
        // A treasury that did not pay makes this revert, so escrow can never be under-collateralised.
        // slither-disable-next-line arbitrary-send-erc20
        token.safeTransferFrom(funder, address(this), subsidy);

        // The counterparty pays the rest; its ERC20 allowance to ILRM bounds the top-up
        if (stake > subsidy) {
            token.safeTransferFrom(msg.sender, address(this), stake - subsidy);
        }

        emit StakeSubsidized(_disputeId, msg.sender, funder, subsidy);
        emit StakeDeposited(_disputeId, msg.sender, stake);
        _requestOracleProposal(_disputeId);
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
     * @dev Resolve dispute when counterparty doesn't stake
     * @param _disputeId Dispute ID
     * @param d Dispute storage reference
     */
    function _resolveNonParticipation(uint256 _disputeId, Dispute storage d) internal {
        d.resolved = true;
        d.outcome = DisputeOutcome.DefaultLicenseApplied;

        // Calculate initiator incentive (10% of expected counterparty stake)
        uint256 incentive = (d.initiatorStake * INITIATOR_INCENTIVE_BPS) / 10_000;

        // Return initiator stake + incentive (from token reserves)
        if (tokenReserves >= incentive) {
            tokenReserves -= incentive;
            token.safeTransfer(d.initiator, d.initiatorStake + incentive);
        } else {
            // If reserves insufficient, just return stake
            token.safeTransfer(d.initiator, d.initiatorStake);
        }

        // Apply fallback license
        assetRegistry.applyFallbackLicense(_disputeId, d.fallbackLicense.termsHash);
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
        StakeSubsidy memory s = _stakeSubsidies[_disputeId];
        if (s.amount == 0) {
            token.safeTransfer(d.counterparty, _amount);
            return;
        }

        uint256 own = Math.mulDiv(_amount, d.counterpartyStake - s.amount, d.counterpartyStake);
        uint256 toFunder = _amount - own;

        if (own > 0) {
            token.safeTransfer(d.counterparty, own);
        }
        if (toFunder > 0) {
            token.safeTransfer(s.funder, toFunder);
            emit SubsidyReturned(_disputeId, s.funder, toFunder);
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
