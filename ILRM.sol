// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IILRM {
    enum DisputeOutcome { Pending, AcceptedProposal, TimeoutWithBurn, DefaultLicenseApplied }

    struct FallbackLicense {
        bool nonExclusive;
        uint64 termDuration;    // seconds
        uint16 royaltyCapBps;   // basis points (e.g., 500 = 5%)
        bytes32 termsHash;      // IPFS/Arweave hash
    }

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
        uint8 counterCount;
    }

    event DisputeInitiated(uint256 indexed disputeId, address indexed initiator, address indexed counterparty, bytes32 evidenceHash);
    event StakeDeposited(uint256 indexed disputeId, address indexed staker, uint256 amount);
    event ProposalSubmitted(uint256 indexed disputeId, string proposal);
    event CounterProposed(uint256 indexed disputeId, address proposer, uint8 counterNumber);
    event AcceptanceSignaled(uint256 indexed disputeId, address indexed party);
    event DisputeResolved(uint256 indexed disputeId, DisputeOutcome outcome);
    event StakesBurned(uint256 indexed disputeId, uint256 amountBurned);
    event DefaultLicenseApplied(uint256 indexed disputeId);
}

interface IAssetRegistry {
    function freezeAssets(uint256 disputeId, address owner) external;
    function unfreezeAssets(uint256 disputeId, bytes calldata executionData) external;
    function applyFallbackLicense(uint256 disputeId, bytes32 termsHash) external;
}

contract ILRM is IILRM, ReentrancyGuard, Ownable {
    IERC20 public immutable token;                     // Stake token
    address public immutable oracle;                   // Trusted oracle address
    IAssetRegistry public immutable assetRegistry;     // External asset registry

    // Constants (tunable via constructor in future upgrades)
    uint256 public constant MAX_COUNTERS = 3;
    uint256 public constant BURN_PERCENTAGE = 50;               // 50% burn on timeout
    uint256 public constant STAKE_WINDOW = 3 days;
    uint256 public constant RESOLUTION_TIMEOUT = 7 days;
    uint256 public constant COUNTER_FEE_BASE = 0.01 ether;
    uint256 public constant INITIATOR_INCENTIVE_BPS = 1000;      // 10%
    uint256 public constant ESCALATION_MULTIPLIER = 150;        // 1.5x for repeat initiators
    uint256 public constant COOLDOWN_PERIOD = 30 days;

    mapping(uint256 => Dispute) public override disputes;
    uint256 public disputeCounter;

    mapping(address => mapping(address => uint256)) public lastDisputeTime; // Cooldown
    uint256 public treasury; // Accumulated from excess fees/burns for subsidies

    constructor(
        IERC20 _token,
        address _oracle,
        IAssetRegistry _assetRegistry
    ) Ownable(msg.sender) {
        token = _token;
        oracle = _oracle;
        assetRegistry = _assetRegistry;
    }

    // --- Breach/Drift Dispute (initiator stakes first) ---
    function initiateBreachDispute(
        address _counterparty,
        uint256 _stakeAmount,
        bytes32 _evidenceHash,
        FallbackLicense calldata _fallback
    ) external nonReentrant returns (uint256 disputeId) {
        require(_stakeAmount > 0, "Zero stake");
        require(_counterparty != msg.sender, "Self-dispute");

        // Escalate stake for repeat initiators
        uint256 escalatedStake = _getEscalatedStake(msg.sender, _counterparty, _stakeAmount);
        token.transferFrom(msg.sender, address(this), escalatedStake);

        disputeId = disputeCounter++;
        disputes[disputeId] = Dispute({
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

        assetRegistry.freezeAssets(disputeId, msg.sender);
        lastDisputeTime[msg.sender][_counterparty] = block.timestamp;

        emit DisputeInitiated(disputeId, msg.sender, _counterparty, _evidenceHash);
    }

    // --- Voluntary Request (ignorable, burn-fee only) ---
    function initiateVoluntaryRequest(
        address _counterparty,
        bytes32 _evidenceHash
    ) external payable {
        require(msg.value >= COUNTER_FEE_BASE, "Insufficient burn fee");
        payable(address(0)).transfer(msg.value); // Immediate burn
        // Special ID to distinguish requests (off-chain monitoring)
        emit DisputeInitiated(type(uint256).max, msg.sender, _counterparty, _evidenceHash);
    }

    // --- Counterparty deposits matching stake ---
    function depositStake(uint256 _disputeId) external nonReentrant {
        Dispute storage d = disputes[_disputeId];
        require(msg.sender == d.counterparty, "Not counterparty");
        require(d.counterpartyStake == 0, "Already staked");
        require(block.timestamp <= d.startTime + STAKE_WINDOW, "Stake window closed");

        token.transferFrom(msg.sender, address(this), d.initiatorStake);
        d.counterpartyStake = d.initiatorStake;

        emit StakeDeposited(_disputeId, msg.sender, d.initiatorStake);
    }

    // --- Oracle submits LLM proposal ---
    function submitLLMProposal(
        uint256 _disputeId,
        string calldata _proposal
    ) external nonReentrant {
        require(msg.sender == oracle, "Only oracle");
        Dispute storage d = disputes[_disputeId];
        require(d.counterpartyStake > 0, "Not fully staked");
        require(!d.resolved, "Already resolved");

        d.llmProposal = _proposal;
        emit ProposalSubmitted(_disputeId, _proposal);
    }

    // --- Party accepts proposal ---
    function acceptProposal(uint256 _disputeId) external nonReentrant {
        Dispute storage d = disputes[_disputeId];
        require(!d.resolved, "Resolved");
        require(block.timestamp <= d.startTime + RESOLUTION_TIMEOUT, "Timeout");
        require(msg.sender == d.initiator || msg.sender == d.counterparty, "Not party");

        if (msg.sender == d.initiator) d.initiatorAccepted = true;
        else d.counterpartyAccepted = true;

        emit AcceptanceSignaled(_disputeId, msg.sender);

        if (d.initiatorAccepted && d.counterpartyAccepted) {
            _resolveAccepted(_disputeId, d);
        }
    }

    // --- Counter-proposal with exponential fee ---
    function counterPropose(uint256 _disputeId, bytes32 _newEvidenceHash) external payable nonReentrant {
        Dispute storage d = disputes[_disputeId];
        require(msg.sender == d.initiator || msg.sender == d.counterparty, "Not party");
        require(!d.resolved, "Resolved");
        require(d.counterCount < MAX_COUNTERS, "Max counters");

        uint256 fee = COUNTER_FEE_BASE * (1 << d.counterCount); // 2^n
        require(msg.value >= fee, "Insufficient fee");
        payable(address(0)).transfer(fee);
        if (msg.value > fee) treasury += msg.value - fee;

        d.counterCount++;
        d.evidenceHash = _newEvidenceHash;
        d.startTime += 1 days; // Extend timeout

        emit CounterProposed(_disputeId, msg.sender, d.counterCount);
    }

    // --- Anyone can enforce timeout ---
    function enforceTimeout(uint256 _disputeId) external nonReentrant {
        Dispute storage d = disputes[_disputeId];
        require(block.timestamp > d.startTime + RESOLUTION_TIMEOUT, "Not timed out");
        require(!d.resolved, "Resolved");
        d.resolved = true;

        if (d.counterpartyStake == 0) {
            // Non-participation default
            uint256 incentive = (d.initiatorStake * INITIATOR_INCENTIVE_BPS) / 10000;
            token.transfer(d.initiator, d.initiatorStake + incentive);
            d.outcome = DisputeOutcome.DefaultLicenseApplied;
            emit DefaultLicenseApplied(_disputeId);
        } else {
            uint256 total = d.initiatorStake + d.counterpartyStake;
            uint256 burnAmt = (total * BURN_PERCENTAGE) / 100;
            token.transfer(address(0), burnAmt);
            treasury += burnAmt / 10; // Optional treasury portion
            uint256 remainder = total - burnAmt;
            token.transfer(d.initiator, remainder / 2);
            token.transfer(d.counterparty, remainder / 2);
            d.outcome = DisputeOutcome.TimeoutWithBurn;
            emit StakesBurned(_disputeId, burnAmt);
        }

        assetRegistry.applyFallbackLicense(_disputeId, d.fallback.termsHash);
        assetRegistry.unfreezeAssets(_disputeId, abi.encode(d.outcome));
        emit DisputeResolved(_disputeId, d.outcome);
    }

    // --- Internal helpers ---
    function _getEscalatedStake(address _initiator, address _counterparty, uint256 _base) internal view returns (uint256) {
        if (block.timestamp < lastDisputeTime[_initiator][_counterparty] + COOLDOWN_PERIOD) {
            return _base * ESCALATION_MULTIPLIER / 100;
        }
        return _base;
    }

    function _resolveAccepted(uint256 _disputeId, Dispute storage d) internal {
        token.transfer(d.initiator, d.initiatorStake);
        token.transfer(d.counterparty, d.counterpartyStake);
        assetRegistry.unfreezeAssets(_disputeId, abi.encode(d.llmProposal));
        d.outcome = DisputeOutcome.AcceptedProposal;
        emit DisputeResolved(_disputeId, d.outcome);
    }

    function disputes(uint256 _id) external view override returns (Dispute memory) {
        return disputes[_id];
    }
}
