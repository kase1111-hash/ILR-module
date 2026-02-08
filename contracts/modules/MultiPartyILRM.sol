// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "../interfaces/IMultiPartyILRM.sol";
import "../interfaces/IOracle.sol";
import "../interfaces/IAssetRegistry.sol";

/**
 * @title MultiPartyILRM - Multi-Party IP & Licensing Reconciliation Module
 * @notice Extends ILRM for disputes involving 3+ parties
 * @dev Implements quorum-based acceptance with configurable thresholds
 *
 * Key Features:
 * - Support for 2-255 parties per dispute
 * - Configurable quorum (unanimous, 2/3, majority, custom)
 * - Symmetric stakes across all parties
 * - Proportional stake burns on timeout
 * - Per-party evidence submission
 * - Late-join support (optional)
 *
 * Invariants Maintained:
 * - All parties must stake before dispute proceeds
 * - Initiator always stakes first
 * - Quorum required for acceptance
 * - Proportional burns on timeout
 */
contract MultiPartyILRM is IMultiPartyILRM, ReentrancyGuard, Pausable, Ownable2Step {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    /// @notice Dead address for token burns
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice Maximum parties per dispute
    uint256 public constant MAX_PARTIES = 255;

    /// @notice Minimum parties for multi-party dispute
    uint256 public constant MIN_PARTIES = 2;

    /// @notice Maximum counter-proposals
    uint256 public constant MAX_COUNTERS = 3;

    /// @notice Burn percentage on timeout (50%)
    uint256 public constant BURN_PERCENTAGE = 50;

    /// @notice Default stake window (3 days)
    uint256 public constant DEFAULT_STAKE_WINDOW = 3 days;

    /// @notice Default resolution timeout (7 days)
    uint256 public constant DEFAULT_RESOLUTION_TIMEOUT = 7 days;

    /// @notice Counter fee base (0.01 ETH)
    uint256 public constant COUNTER_FEE_BASE = 0.01 ether;

    /// @notice Basis points denominator
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @notice FIX M-FINAL-01: Maximum time extension to prevent indefinite delays
    uint256 public constant MAX_TIME_EXTENSION = 3 days;

    // ============ State Variables ============

    /// @notice Staking token
    IERC20 public immutable token;

    /// @notice Oracle for LLM proposals
    address public immutable oracle;

    /// @notice Asset registry
    IAssetRegistry public immutable assetRegistry;

    /// @notice Dispute counter
    uint256 private _disputeCounter;

    /// @notice Dispute storage: disputeId => MultiPartyDispute
    mapping(uint256 => MultiPartyDispute) private _disputes;

    /// @notice Party info storage: disputeId => partyAddress => PartyInfo
    mapping(uint256 => mapping(address => PartyInfo)) private _partyInfo;

    /// @notice Party list: disputeId => address[]
    mapping(uint256 => address[]) private _partyList;

    /// @notice Party index: disputeId => address => index (1-indexed, 0 = not party)
    mapping(uint256 => mapping(address => uint256)) private _partyIndex;

    /// @notice Treasury for counter fees
    uint256 public treasury;

    // ============ Constructor ============

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
     * @inheritdoc IMultiPartyILRM
     */
    function createMultiPartyDispute(
        address[] calldata parties,
        uint256 baseStake,
        bytes32 evidenceHash,
        FallbackLicense calldata fallbackTerms,
        DisputeConfig calldata config
    ) external override nonReentrant whenNotPaused returns (uint256 disputeId) {
        // Validate inputs
        require(parties.length >= MIN_PARTIES, "Need at least 2 parties");
        require(parties.length <= MAX_PARTIES, "Too many parties");
        require(baseStake > 0, "Zero stake");
        require(fallbackTerms.nonExclusive, "Fallback must be non-exclusive");

        // Validate config
        uint256 stakeWindow = config.stakeWindow > 0 ? config.stakeWindow : DEFAULT_STAKE_WINDOW;
        uint256 resolutionTimeout = config.resolutionTimeout > 0
            ? config.resolutionTimeout
            : DEFAULT_RESOLUTION_TIMEOUT;

        require(config.minParties >= MIN_PARTIES, "Min parties too low");
        require(config.maxParties <= MAX_PARTIES, "Max parties too high");
        require(config.minParties <= parties.length, "Not enough initial parties");

        if (config.quorumType == QuorumType.Custom) {
            require(config.customQuorumBps > 0 && config.customQuorumBps <= BPS_DENOMINATOR,
                "Invalid custom quorum");
        }

        // Verify initiator is in parties list
        bool initiatorFound = false;
        for (uint256 i = 0; i < parties.length; i++) {
            if (parties[i] == msg.sender) {
                initiatorFound = true;
                break;
            }
        }
        require(initiatorFound, "Initiator must be in parties");

        // Initiator stakes first (Invariant 3)
        token.safeTransferFrom(msg.sender, address(this), baseStake);

        disputeId = _disputeCounter++;

        // Store dispute
        _disputes[disputeId] = MultiPartyDispute({
            id: disputeId,
            initiator: msg.sender,
            baseStake: baseStake,
            totalStaked: baseStake,
            startTime: block.timestamp,
            evidenceHash: evidenceHash,
            llmProposal: "",
            acceptanceCount: 0,
            rejectionCount: 0,
            resolved: false,
            outcome: MultiPartyOutcome.Pending,
            fallback: fallbackTerms,
            counterCount: 0,
            config: DisputeConfig({
                quorumType: config.quorumType,
                customQuorumBps: config.customQuorumBps,
                minParties: config.minParties,
                maxParties: config.maxParties,
                stakeWindow: stakeWindow,
                resolutionTimeout: resolutionTimeout,
                allowLateJoin: config.allowLateJoin
            })
        });

        // Add all parties
        for (uint256 i = 0; i < parties.length; i++) {
            address party = parties[i];
            require(party != address(0), "Invalid party address");
            require(_partyIndex[disputeId][party] == 0, "Duplicate party");

            _partyList[disputeId].push(party);
            _partyIndex[disputeId][party] = i + 1; // 1-indexed

            bool isInitiator = party == msg.sender;
            _partyInfo[disputeId][party] = PartyInfo({
                partyAddress: party,
                stake: isInitiator ? baseStake : 0,
                hasStaked: isInitiator,
                hasAccepted: false,
                hasRejected: false,
                evidenceHash: isInitiator ? evidenceHash : bytes32(0),
                joinedAt: block.timestamp
            });

            emit PartyJoined(disputeId, party, i);
        }

        // Freeze initiator's assets
        assetRegistry.freezeAssets(disputeId, msg.sender);

        emit MultiPartyDisputeCreated(
            disputeId,
            msg.sender,
            parties.length,
            config.quorumType
        );

        emit PartyStaked(disputeId, msg.sender, baseStake);
    }

    /**
     * @inheritdoc IMultiPartyILRM
     */
    function joinDispute(uint256 disputeId) external override nonReentrant whenNotPaused {
        MultiPartyDispute storage d = _disputes[disputeId];
        require(!d.resolved, "Dispute resolved");
        require(d.config.allowLateJoin, "Late join not allowed");
        require(_partyIndex[disputeId][msg.sender] == 0, "Already a party");
        require(_partyList[disputeId].length < d.config.maxParties, "Max parties reached");
        require(block.timestamp <= d.startTime + d.config.stakeWindow, "Stake window closed");

        uint256 partyIndex = _partyList[disputeId].length;
        _partyList[disputeId].push(msg.sender);
        _partyIndex[disputeId][msg.sender] = partyIndex + 1;

        _partyInfo[disputeId][msg.sender] = PartyInfo({
            partyAddress: msg.sender,
            stake: 0,
            hasStaked: false,
            hasAccepted: false,
            hasRejected: false,
            evidenceHash: bytes32(0),
            joinedAt: block.timestamp
        });

        emit PartyJoined(disputeId, msg.sender, partyIndex);
    }

    /**
     * @inheritdoc IMultiPartyILRM
     */
    function depositStake(uint256 disputeId) external override nonReentrant whenNotPaused {
        MultiPartyDispute storage d = _disputes[disputeId];
        require(!d.resolved, "Dispute resolved");
        require(_partyIndex[disputeId][msg.sender] > 0, "Not a party");
        require(!_partyInfo[disputeId][msg.sender].hasStaked, "Already staked");
        require(block.timestamp <= d.startTime + d.config.stakeWindow, "Stake window closed");

        // Transfer stake
        token.safeTransferFrom(msg.sender, address(this), d.baseStake);

        _partyInfo[disputeId][msg.sender].stake = d.baseStake;
        _partyInfo[disputeId][msg.sender].hasStaked = true;
        d.totalStaked += d.baseStake;

        // Freeze party's assets
        assetRegistry.freezeAssets(disputeId, msg.sender);

        emit PartyStaked(disputeId, msg.sender, d.baseStake);
    }

    /**
     * @inheritdoc IMultiPartyILRM
     */
    function submitEvidence(
        uint256 disputeId,
        bytes32 evidenceHash
    ) external override nonReentrant {
        MultiPartyDispute storage d = _disputes[disputeId];
        require(!d.resolved, "Dispute resolved");
        require(_partyIndex[disputeId][msg.sender] > 0, "Not a party");
        require(_partyInfo[disputeId][msg.sender].hasStaked, "Must stake first");

        _partyInfo[disputeId][msg.sender].evidenceHash = evidenceHash;

        // Aggregate evidence hash
        bytes32 newAggregateHash = keccak256(abi.encodePacked(d.evidenceHash, evidenceHash));
        d.evidenceHash = newAggregateHash;

        emit EvidenceAggregated(disputeId, msg.sender, newAggregateHash);
    }

    /**
     * @notice Oracle submits LLM proposal
     * @param disputeId The dispute ID
     * @param proposal The proposal text
     * @param signature Oracle signature
     */
    function submitLLMProposal(
        uint256 disputeId,
        string calldata proposal,
        bytes calldata signature
    ) external nonReentrant {
        require(msg.sender == oracle, "Only oracle");

        MultiPartyDispute storage d = _disputes[disputeId];
        require(!d.resolved, "Dispute resolved");
        require(_allPartiesStaked(disputeId), "Not all parties staked");
        require(bytes(proposal).length > 0, "Empty proposal");

        // Verify signature
        bytes32 proposalHash = keccak256(bytes(proposal));
        require(
            IOracle(oracle).verifySignature(disputeId, proposalHash, signature),
            "Invalid signature"
        );

        d.llmProposal = proposal;

        // Reset acceptance counts for new proposal
        d.acceptanceCount = 0;
        d.rejectionCount = 0;

        // Reset all party acceptance states
        address[] storage parties = _partyList[disputeId];
        for (uint256 i = 0; i < parties.length; i++) {
            _partyInfo[disputeId][parties[i]].hasAccepted = false;
            _partyInfo[disputeId][parties[i]].hasRejected = false;
        }
    }

    /**
     * @inheritdoc IMultiPartyILRM
     */
    function acceptProposal(uint256 disputeId) external override nonReentrant {
        MultiPartyDispute storage d = _disputes[disputeId];
        require(!d.resolved, "Dispute resolved");
        require(_partyIndex[disputeId][msg.sender] > 0, "Not a party");
        require(_partyInfo[disputeId][msg.sender].hasStaked, "Must stake first");
        require(bytes(d.llmProposal).length > 0, "No proposal yet");
        require(!_partyInfo[disputeId][msg.sender].hasAccepted, "Already accepted");
        require(!_partyInfo[disputeId][msg.sender].hasRejected, "Already rejected");
        require(
            block.timestamp <= d.startTime + d.config.stakeWindow + d.config.resolutionTimeout,
            "Timeout passed"
        );

        _partyInfo[disputeId][msg.sender].hasAccepted = true;
        d.acceptanceCount++;

        uint256 required = _getQuorumRequirement(disputeId);
        emit PartyAccepted(disputeId, msg.sender, d.acceptanceCount, required);

        // Check if quorum reached
        if (d.acceptanceCount >= required) {
            emit QuorumReached(disputeId, d.acceptanceCount, _partyList[disputeId].length);
            _resolveWithQuorum(disputeId);
        }
    }

    /**
     * @inheritdoc IMultiPartyILRM
     */
    function rejectProposal(uint256 disputeId) external override nonReentrant {
        MultiPartyDispute storage d = _disputes[disputeId];
        require(!d.resolved, "Dispute resolved");
        require(_partyIndex[disputeId][msg.sender] > 0, "Not a party");
        require(_partyInfo[disputeId][msg.sender].hasStaked, "Must stake first");
        require(bytes(d.llmProposal).length > 0, "No proposal yet");
        require(!_partyInfo[disputeId][msg.sender].hasAccepted, "Already accepted");
        require(!_partyInfo[disputeId][msg.sender].hasRejected, "Already rejected");

        _partyInfo[disputeId][msg.sender].hasRejected = true;
        d.rejectionCount++;

        emit PartyRejected(disputeId, msg.sender, d.rejectionCount);

        // Check if quorum is now impossible
        uint256 required = _getQuorumRequirement(disputeId);
        uint256 remaining = _partyList[disputeId].length - d.acceptanceCount - d.rejectionCount;

        if (d.acceptanceCount + remaining < required) {
            // Quorum impossible - trigger counter-proposal round or timeout
            // For now, just emit event; parties can counter-propose
        }
    }

    /**
     * @inheritdoc IMultiPartyILRM
     */
    function counterPropose(
        uint256 disputeId,
        bytes32 newEvidenceHash
    ) external payable override nonReentrant whenNotPaused {
        MultiPartyDispute storage d = _disputes[disputeId];
        require(!d.resolved, "Dispute resolved");
        require(_partyIndex[disputeId][msg.sender] > 0, "Not a party");
        require(_partyInfo[disputeId][msg.sender].hasStaked, "Must stake first");
        require(d.counterCount < MAX_COUNTERS, "Max counters reached");

        // Exponential fee
        uint256 fee = COUNTER_FEE_BASE * (1 << d.counterCount);
        require(msg.value >= fee, "Insufficient counter fee");

        // Burn the fee
        (bool success, ) = BURN_ADDRESS.call{value: fee}("");
        require(success, "Burn failed");

        if (msg.value > fee) {
            treasury += msg.value - fee;
        }

        d.counterCount++;
        d.evidenceHash = newEvidenceHash;
        d.llmProposal = "";
        d.acceptanceCount = 0;
        d.rejectionCount = 0;

        // Reset all party states
        address[] storage parties = _partyList[disputeId];
        for (uint256 i = 0; i < parties.length; i++) {
            _partyInfo[disputeId][parties[i]].hasAccepted = false;
            _partyInfo[disputeId][parties[i]].hasRejected = false;
        }

        // FIX M-FINAL-01: Extend timeout only if within MAX_TIME_EXTENSION
        uint256 currentExtension = d.counterCount * 1 days;
        if (currentExtension <= MAX_TIME_EXTENSION) {
            d.startTime += 1 days;
        }
    }

    /**
     * @inheritdoc IMultiPartyILRM
     */
    function enforceTimeout(uint256 disputeId) external override nonReentrant {
        MultiPartyDispute storage d = _disputes[disputeId];
        require(!d.resolved, "Already resolved");

        uint256 stakeDeadline = d.startTime + d.config.stakeWindow;
        uint256 resolutionDeadline = stakeDeadline + d.config.resolutionTimeout;

        if (!_allPartiesStaked(disputeId)) {
            // Not all parties staked - check stake window
            require(block.timestamp > stakeDeadline, "Stake window open");
            _resolveNonParticipation(disputeId);
        } else {
            // All staked - check resolution timeout
            require(block.timestamp > resolutionDeadline, "Resolution window open");
            _resolveTimeout(disputeId);
        }
    }

    // ============ View Functions ============

    /**
     * @inheritdoc IMultiPartyILRM
     */
    function getDispute(
        uint256 disputeId
    ) external view override returns (MultiPartyDispute memory) {
        return _disputes[disputeId];
    }

    /**
     * @inheritdoc IMultiPartyILRM
     */
    function getParties(
        uint256 disputeId
    ) external view override returns (PartyInfo[] memory parties) {
        address[] storage partyAddresses = _partyList[disputeId];
        parties = new PartyInfo[](partyAddresses.length);

        for (uint256 i = 0; i < partyAddresses.length; i++) {
            parties[i] = _partyInfo[disputeId][partyAddresses[i]];
        }
    }

    /**
     * @inheritdoc IMultiPartyILRM
     */
    function getPartyInfo(
        uint256 disputeId,
        address party
    ) external view override returns (PartyInfo memory) {
        return _partyInfo[disputeId][party];
    }

    /**
     * @inheritdoc IMultiPartyILRM
     */
    function checkQuorum(
        uint256 disputeId
    ) external view override returns (bool reached, uint256 current, uint256 required) {
        MultiPartyDispute storage d = _disputes[disputeId];
        required = _getQuorumRequirement(disputeId);
        current = d.acceptanceCount;
        reached = current >= required;
    }

    /**
     * @inheritdoc IMultiPartyILRM
     */
    function getQuorumRequirement(
        uint256 disputeId
    ) external view override returns (uint256) {
        return _getQuorumRequirement(disputeId);
    }

    /**
     * @inheritdoc IMultiPartyILRM
     */
    function isParty(
        uint256 disputeId,
        address account
    ) external view override returns (bool) {
        return _partyIndex[disputeId][account] > 0;
    }

    /**
     * @inheritdoc IMultiPartyILRM
     */
    function disputeCount() external view override returns (uint256) {
        return _disputeCounter;
    }

    // ============ Internal Functions ============

    /**
     * @dev Calculate quorum requirement based on config
     */
    function _getQuorumRequirement(uint256 disputeId) internal view returns (uint256) {
        MultiPartyDispute storage d = _disputes[disputeId];
        uint256 totalParties = _partyList[disputeId].length;

        if (d.config.quorumType == QuorumType.Unanimous) {
            return totalParties;
        } else if (d.config.quorumType == QuorumType.SuperMajority) {
            // 2/3 (67%)
            return (totalParties * 6667) / BPS_DENOMINATOR + 1;
        } else if (d.config.quorumType == QuorumType.SimpleMajority) {
            // More than half (51%)
            return (totalParties / 2) + 1;
        } else {
            // Custom
            return (totalParties * d.config.customQuorumBps) / BPS_DENOMINATOR;
        }
    }

    /**
     * @dev Check if all parties have staked
     */
    function _allPartiesStaked(uint256 disputeId) internal view returns (bool) {
        address[] storage parties = _partyList[disputeId];
        for (uint256 i = 0; i < parties.length; i++) {
            if (!_partyInfo[disputeId][parties[i]].hasStaked) {
                return false;
            }
        }
        return true;
    }

    /**
     * @dev Resolve dispute when quorum is reached
     */
    function _resolveWithQuorum(uint256 disputeId) internal {
        MultiPartyDispute storage d = _disputes[disputeId];
        d.resolved = true;
        d.outcome = MultiPartyOutcome.QuorumAccepted;

        // Return all stakes
        address[] storage parties = _partyList[disputeId];
        for (uint256 i = 0; i < parties.length; i++) {
            address party = parties[i];
            uint256 stake = _partyInfo[disputeId][party].stake;
            if (stake > 0) {
                token.safeTransfer(party, stake);
            }
        }

        // FIX: Call unfreezeAssets once (not in loop) to avoid redundant calls
        assetRegistry.unfreezeAssets(disputeId, bytes(d.llmProposal));

        emit MultiPartyResolved(disputeId, MultiPartyOutcome.QuorumAccepted, 0);
    }

    /**
     * @dev Resolve when not all parties staked
     */
    function _resolveNonParticipation(uint256 disputeId) internal {
        MultiPartyDispute storage d = _disputes[disputeId];
        d.resolved = true;
        d.outcome = MultiPartyOutcome.PartialResolution;

        address[] storage parties = _partyList[disputeId];

        // Return stakes to parties who staked
        // Non-stakers forfeit their participation
        for (uint256 i = 0; i < parties.length; i++) {
            address party = parties[i];
            PartyInfo storage info = _partyInfo[disputeId][party];

            if (info.hasStaked && info.stake > 0) {
                // Return stake plus proportional share from non-participation
                token.safeTransfer(party, info.stake);
            }
        }

        // FIX: Unfreeze assets for ALL parties (including non-stakers)
        // This prevents soft lock where non-staking parties have frozen assets
        assetRegistry.unfreezeAssets(disputeId, abi.encode(d.outcome));

        // Apply fallback license
        assetRegistry.applyFallbackLicense(disputeId, d.fallback.termsHash);

        emit MultiPartyResolved(disputeId, MultiPartyOutcome.PartialResolution, 0);
    }

    /**
     * @dev Resolve on timeout with proportional burns
     */
    function _resolveTimeout(uint256 disputeId) internal {
        MultiPartyDispute storage d = _disputes[disputeId];
        d.resolved = true;
        d.outcome = MultiPartyOutcome.TimeoutWithBurn;

        uint256 totalBurn = (d.totalStaked * BURN_PERCENTAGE) / 100;
        uint256 remainder = d.totalStaked - totalBurn;

        // Burn tokens
        token.safeTransfer(BURN_ADDRESS, totalBurn);

        // Distribute remainder proportionally
        address[] storage parties = _partyList[disputeId];
        uint256 partyCount = parties.length;
        uint256 returnPerParty = remainder / partyCount;

        for (uint256 i = 0; i < partyCount; i++) {
            address party = parties[i];
            if (_partyInfo[disputeId][party].hasStaked) {
                token.safeTransfer(party, returnPerParty);
            }
        }

        // FIX: Call unfreezeAssets once (not in loop) for all parties
        assetRegistry.unfreezeAssets(disputeId, abi.encode(d.outcome));

        // Handle dust
        uint256 dust = remainder - (returnPerParty * partyCount);
        if (dust > 0) {
            token.safeTransfer(BURN_ADDRESS, dust);
        }

        // Apply fallback license to all
        assetRegistry.applyFallbackLicense(disputeId, d.fallback.termsHash);

        emit MultiPartyResolved(disputeId, MultiPartyOutcome.TimeoutWithBurn, totalBurn);
    }

    // ============ Admin Functions ============

    /**
     * @notice Withdraw treasury funds
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function withdrawTreasury(address to, uint256 amount) external onlyOwner {
        require(amount <= treasury, "Insufficient treasury");
        require(to != address(0), "Invalid recipient");

        treasury -= amount;
        (bool success, ) = to.call{value: amount}("");
        require(success, "Transfer failed");
    }

    /**
     * @notice Pause contract
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

    /// @notice Accept ETH for treasury
    receive() external payable {
        treasury += msg.value;
    }
}
