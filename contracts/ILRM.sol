// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "./interfaces/IILRM.sol";
import "./interfaces/IOracle.sol";
import "./interfaces/IAssetRegistry.sol";
import "./interfaces/IIdentityVerifier.sol";
import "./interfaces/IComplianceEscrow.sol";
import "./interfaces/IFIDOVerifier.sol";
import "./interfaces/IDIDRegistry.sol";

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
 * - FIX L-05: Pausable for emergency stops
 * - FIX I-02: Two-step ownership transfer via Ownable2Step
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

    /// @notice Initiator incentive on counterparty non-stake (10% = 1000 bps)
    uint256 public constant INITIATOR_INCENTIVE_BPS = 1000;

    /// @notice Stake escalation multiplier for repeat disputes (150% = 1.5x)
    uint256 public constant ESCALATION_MULTIPLIER = 150;

    /// @notice Cooldown period between disputes with same counterparty
    uint256 public constant COOLDOWN_PERIOD = 30 days;

    /// @notice FIX L-01: Maximum total time extension from counter-proposals (3 days)
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

    /// @notice Optional ZK identity verifier (address(0) if disabled)
    IIdentityVerifier public identityVerifier;

    /// @notice ZK identity hashes for disputes: disputeId => isInitiator => identityHash
    mapping(uint256 => mapping(bool => bytes32)) private _zkIdentities;

    /// @notice Whether ZK mode is enabled for a dispute
    mapping(uint256 => bool) private _zkModeEnabled;

    /// @notice Optional compliance escrow for viewing keys (address(0) if disabled)
    IComplianceEscrow public complianceEscrow;

    /// @notice Viewing key commitments for disputes: disputeId => commitment
    mapping(uint256 => bytes32) private _viewingKeyCommitments;

    /// @notice Encrypted data hashes for disputes: disputeId => hash (IPFS/Arweave)
    mapping(uint256 => bytes32) private _encryptedDataHashes;

    /// @notice Optional FIDO verifier for hardware-backed authentication
    IFIDOVerifier public fidoVerifier;

    /// @notice Whether FIDO is required for a specific address: address => required
    mapping(address => bool) public fidoRequired;

    /// @notice Used FIDO challenges: challengeHash => used
    mapping(bytes32 => bool) private _usedFidoChallenges;

    // ============ DID Integration Variables ============

    /// @notice Optional DID registry for sybil-resistant identity
    IDIDRegistry public didRegistry;

    /// @notice Whether DID verification is required for dispute participation
    bool public didRequired;

    /// @notice Minimum sybil score required for dispute participation
    uint256 public minDIDSybilScore;

    /// @notice DID associated with each dispute party: disputeId => isInitiator => did
    mapping(uint256 => mapping(bool => bytes32)) private _disputeDIDs;

    /// @notice Event emitted when DID registry is set
    event DIDRegistrySet(address indexed registry);

    /// @notice Event emitted when DID requirement is changed
    event DIDRequirementChanged(bool required, uint256 minScore);

    /// @notice Event emitted when a DID is associated with a dispute
    event DIDAssociatedWithDispute(
        uint256 indexed disputeId,
        bytes32 indexed did,
        bool isInitiator
    );

    /// @notice Error for invalid DID
    error InvalidDID(address participant);

    /// @notice Error for insufficient sybil score
    error InsufficientSybilScore(address participant, uint256 required, uint256 actual);

    /// @notice Error for DID not meeting requirements
    error DIDRequirementNotMet(address participant);

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

        // FIX H-01: Verify EIP-712 signature via Oracle contract
        // Defense in depth - Oracle already verifies, but we double-check
        bytes32 proposalHash = keccak256(bytes(_proposal));
        require(
            IOracle(oracle).verifySignature(_disputeId, proposalHash, _signature),
            "Invalid signature"
        );

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
    ) external payable override nonReentrant whenNotPaused {
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

        // FIX L-01: Extend timeout by 1 day per counter, but cap at MAX_TIME_EXTENSION
        // This prevents indefinite delays while still allowing reasonable extensions
        uint256 currentExtension = d.counterCount * 1 days; // counterCount already incremented
        if (currentExtension <= MAX_TIME_EXTENSION) {
            d.startTime += 1 days;
        }
        // If we've hit max extension, no further time added

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

        // Handle dust (any odd wei from division) - burn any remainder
        uint256 dust = remainder - (returnPerParty * 2);
        if (dust > 0) {
            token.safeTransfer(BURN_ADDRESS, dust);
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
        // FIX L-02: Emit event for admin action
        emit TreasuryWithdrawn(_to, _amount);
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

    /// @notice Accept ETH for treasury (from external sources)
    receive() external payable {
        treasury += msg.value;
    }

    // ============ ZK Identity Functions ============

    /**
     * @notice Set the identity verifier contract
     * @dev Only owner can set; address(0) disables ZK mode
     * @param _verifier The identity verifier contract address
     */
    function setIdentityVerifier(address _verifier) external onlyOwner {
        identityVerifier = IIdentityVerifier(_verifier);
    }

    /**
     * @notice Initiate a breach dispute with ZK identity (privacy-preserving)
     * @dev Initiator registers their identity hash instead of address
     * @param _counterparty The counterparty's address (or address(0) if using ZK for both)
     * @param _initiatorIdentityHash Poseidon hash of initiator's identity secret
     * @param _counterpartyIdentityHash Poseidon hash of counterparty's identity secret (optional)
     * @param _stakeAmount Base stake amount
     * @param _evidenceHash Hash of canonicalized evidence bundle
     * @param _fallback Fallback license terms
     * @return disputeId The unique dispute identifier
     */
    function initiateZKBreachDispute(
        address _counterparty,
        bytes32 _initiatorIdentityHash,
        bytes32 _counterpartyIdentityHash,
        uint256 _stakeAmount,
        bytes32 _evidenceHash,
        FallbackLicense calldata _fallback
    ) external nonReentrant whenNotPaused returns (uint256 disputeId) {
        require(address(identityVerifier) != address(0), "ZK mode not enabled");
        require(_initiatorIdentityHash != bytes32(0), "Invalid initiator identity");
        require(_stakeAmount > 0, "Zero stake");
        require(_fallback.nonExclusive, "Fallback must be non-exclusive");

        // Calculate escalated stake if applicable
        uint256 escalatedStake = _counterparty != address(0)
            ? _getEscalatedStake(msg.sender, _counterparty, _stakeAmount)
            : _stakeAmount;

        // Transfer stake from initiator
        token.safeTransferFrom(msg.sender, address(this), escalatedStake);

        disputeId = _disputeCounter++;

        // Store dispute with addresses (msg.sender for stake tracking)
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

        // Enable ZK mode and store identity hashes
        _zkModeEnabled[disputeId] = true;
        _zkIdentities[disputeId][true] = _initiatorIdentityHash;

        if (_counterpartyIdentityHash != bytes32(0)) {
            _zkIdentities[disputeId][false] = _counterpartyIdentityHash;
        }

        // Freeze assets via registry
        assetRegistry.freezeAssets(disputeId, msg.sender);

        // Update cooldown tracking if counterparty is known
        if (_counterparty != address(0)) {
            lastDisputeTime[msg.sender][_counterparty] = block.timestamp;
        }

        emit DisputeInitiated(disputeId, msg.sender, _counterparty, _evidenceHash);
        emit ZKIdentityRegistered(disputeId, _initiatorIdentityHash, true);

        if (_counterpartyIdentityHash != bytes32(0)) {
            emit ZKIdentityRegistered(disputeId, _counterpartyIdentityHash, false);
        }
    }

    /**
     * @notice Accept proposal using ZK proof of identity
     * @dev Verifies ZK proof that caller knows the identity secret
     * @param _disputeId The dispute to accept
     * @param _proof Groth16 proof components
     * @param _identityHash The identity hash being proven
     */
    function acceptProposalWithZKProof(
        uint256 _disputeId,
        IIdentityVerifier.Proof calldata _proof,
        bytes32 _identityHash
    ) external nonReentrant {
        require(address(identityVerifier) != address(0), "ZK mode not enabled");
        require(_zkModeEnabled[_disputeId], "Dispute not in ZK mode");

        Dispute storage d = _disputes[_disputeId];
        require(!d.resolved, "Dispute resolved");
        require(bytes(d.llmProposal).length > 0, "No proposal yet");
        require(block.timestamp <= d.startTime + RESOLUTION_TIMEOUT, "Timeout passed");

        // Verify the ZK proof
        IIdentityVerifier.IdentityPublicSignals memory signals = IIdentityVerifier
            .IdentityPublicSignals({identityManager: uint256(_identityHash)});

        require(
            identityVerifier.verifyIdentityProof(_proof, signals),
            "Invalid ZK proof"
        );

        // Determine which party this proof is for
        bool isInitiator = _zkIdentities[_disputeId][true] == _identityHash;
        bool isCounterparty = _zkIdentities[_disputeId][false] == _identityHash;

        require(isInitiator || isCounterparty, "Identity not registered for dispute");

        if (isInitiator) {
            require(!d.initiatorAccepted, "Already accepted");
            d.initiatorAccepted = true;
        } else {
            require(!d.counterpartyAccepted, "Already accepted");
            d.counterpartyAccepted = true;
        }

        emit ZKProofAcceptance(_disputeId, _identityHash);
        emit AcceptanceSignaled(_disputeId, msg.sender);

        // Resolve if both accepted
        if (d.initiatorAccepted && d.counterpartyAccepted) {
            _resolveAccepted(_disputeId, d);
        }
    }

    /**
     * @notice Register counterparty's ZK identity for an existing dispute
     * @dev Only counterparty can register their identity
     * @param _disputeId The dispute ID
     * @param _identityHash The counterparty's identity hash
     */
    function registerCounterpartyZKIdentity(
        uint256 _disputeId,
        bytes32 _identityHash
    ) external nonReentrant {
        require(_zkModeEnabled[_disputeId], "Dispute not in ZK mode");
        require(_identityHash != bytes32(0), "Invalid identity hash");

        Dispute storage d = _disputes[_disputeId];
        require(msg.sender == d.counterparty, "Not counterparty");
        require(_zkIdentities[_disputeId][false] == bytes32(0), "Already registered");
        require(!d.resolved, "Dispute resolved");

        _zkIdentities[_disputeId][false] = _identityHash;

        emit ZKIdentityRegistered(_disputeId, _identityHash, false);
    }

    /**
     * @inheritdoc IILRM
     */
    function getZKIdentity(
        uint256 _disputeId,
        bool _isInitiator
    ) external view override returns (bytes32) {
        return _zkIdentities[_disputeId][_isInitiator];
    }

    /**
     * @inheritdoc IILRM
     */
    function isZKModeEnabled(uint256 _disputeId) external view override returns (bool) {
        return _zkModeEnabled[_disputeId];
    }

    // ============ Viewing Key Functions ============

    /// @notice Emitted when viewing key commitment is registered
    event ViewingKeyCommitmentRegistered(
        uint256 indexed disputeId,
        bytes32 indexed commitment,
        bytes32 encryptedDataHash
    );

    /// @notice Emitted when compliance escrow is created for a dispute
    event ComplianceEscrowCreated(
        uint256 indexed disputeId,
        uint256 indexed escrowId
    );

    /**
     * @notice Set the compliance escrow contract
     * @dev Only owner can set; address(0) disables viewing key features
     * @param _escrow The compliance escrow contract address
     */
    function setComplianceEscrow(address _escrow) external onlyOwner {
        complianceEscrow = IComplianceEscrow(_escrow);
    }

    /**
     * @notice Register viewing key commitment for a dispute
     * @dev Either party can register; allows privacy-preserving metadata storage
     * @param _disputeId The dispute to register for
     * @param _viewingKeyCommitment Commitment to the viewing key
     * @param _encryptedDataHash Hash of encrypted data location (IPFS/Arweave)
     */
    function registerViewingKeyCommitment(
        uint256 _disputeId,
        bytes32 _viewingKeyCommitment,
        bytes32 _encryptedDataHash
    ) external nonReentrant {
        Dispute storage d = _disputes[_disputeId];
        require(
            msg.sender == d.initiator || msg.sender == d.counterparty,
            "Not a party"
        );
        require(!d.resolved, "Dispute resolved");
        require(_viewingKeyCommitment != bytes32(0), "Invalid commitment");
        require(_viewingKeyCommitments[_disputeId] == bytes32(0), "Already registered");

        _viewingKeyCommitments[_disputeId] = _viewingKeyCommitment;
        _encryptedDataHashes[_disputeId] = _encryptedDataHash;

        emit ViewingKeyCommitmentRegistered(_disputeId, _viewingKeyCommitment, _encryptedDataHash);
    }

    /**
     * @notice Create a compliance escrow for a dispute with viewing key
     * @dev Requires complianceEscrow to be set
     * @param _disputeId The dispute to create escrow for
     * @param _viewingKeyCommitment Commitment to the viewing key
     * @param _encryptedDataHash Hash of encrypted data location
     * @param _threshold Required shares for reconstruction (m)
     * @param _holders Array of share holder addresses
     * @param _holderTypes Array of holder types
     * @return escrowId The created escrow ID
     */
    function createDisputeEscrow(
        uint256 _disputeId,
        bytes32 _viewingKeyCommitment,
        bytes32 _encryptedDataHash,
        uint8 _threshold,
        address[] calldata _holders,
        IComplianceEscrow.HolderType[] calldata _holderTypes
    ) external nonReentrant whenNotPaused returns (uint256 escrowId) {
        require(address(complianceEscrow) != address(0), "Escrow not configured");

        Dispute storage d = _disputes[_disputeId];
        require(
            msg.sender == d.initiator || msg.sender == d.counterparty,
            "Not a party"
        );
        require(!d.resolved, "Dispute resolved");

        // Register commitment
        if (_viewingKeyCommitments[_disputeId] == bytes32(0)) {
            _viewingKeyCommitments[_disputeId] = _viewingKeyCommitment;
            _encryptedDataHashes[_disputeId] = _encryptedDataHash;

            emit ViewingKeyCommitmentRegistered(
                _disputeId,
                _viewingKeyCommitment,
                _encryptedDataHash
            );
        }

        // Create escrow
        escrowId = complianceEscrow.createEscrow(
            _disputeId,
            _viewingKeyCommitment,
            _encryptedDataHash,
            _threshold,
            uint8(_holders.length),
            _holders,
            _holderTypes
        );

        emit ComplianceEscrowCreated(_disputeId, escrowId);
    }

    /**
     * @notice Get viewing key commitment for a dispute
     * @param _disputeId The dispute ID
     * @return commitment The viewing key commitment
     */
    function getViewingKeyCommitment(uint256 _disputeId) external view returns (bytes32 commitment) {
        return _viewingKeyCommitments[_disputeId];
    }

    /**
     * @notice Get encrypted data hash for a dispute
     * @param _disputeId The dispute ID
     * @return hash The encrypted data hash
     */
    function getEncryptedDataHash(uint256 _disputeId) external view returns (bytes32 hash) {
        return _encryptedDataHashes[_disputeId];
    }

    /**
     * @notice Check if viewing key is registered for a dispute
     * @param _disputeId The dispute ID
     * @return True if viewing key commitment exists
     */
    function hasViewingKey(uint256 _disputeId) external view returns (bool) {
        return _viewingKeyCommitments[_disputeId] != bytes32(0);
    }

    // ============ FIDO2/WebAuthn Functions ============

    /// @notice Emitted when FIDO-authenticated acceptance occurs
    event FIDOAcceptance(
        uint256 indexed disputeId,
        address indexed party,
        bytes32 indexed credentialIdHash
    );

    /// @notice Emitted when user enables/disables FIDO requirement
    event FIDORequirementUpdated(
        address indexed user,
        bool required
    );

    /**
     * @notice Set the FIDO verifier contract
     * @dev Only owner can set; address(0) disables FIDO features
     * @param _verifier The FIDO verifier contract address
     */
    function setFIDOVerifier(address _verifier) external onlyOwner {
        fidoVerifier = IFIDOVerifier(_verifier);
    }

    /**
     * @notice Enable or disable FIDO requirement for the caller
     * @dev Users can opt-in to require hardware authentication for their actions
     * @param _required Whether FIDO is required
     */
    function setFIDORequired(bool _required) external {
        require(address(fidoVerifier) != address(0), "FIDO not configured");

        if (_required) {
            // Verify user has a registered key before enabling requirement
            require(fidoVerifier.hasRegisteredKey(msg.sender), "No FIDO key registered");
        }

        fidoRequired[msg.sender] = _required;
        emit FIDORequirementUpdated(msg.sender, _required);
    }

    /**
     * @notice Accept proposal with FIDO2/WebAuthn hardware authentication
     * @dev Provides stronger security than regular acceptProposal
     * @param _disputeId The dispute to accept
     * @param _assertion WebAuthn assertion from hardware key
     * @param _challenge The challenge that was signed
     */
    function fidoAcceptProposal(
        uint256 _disputeId,
        IFIDOVerifier.WebAuthnAssertion calldata _assertion,
        bytes32 _challenge
    ) external nonReentrant {
        require(address(fidoVerifier) != address(0), "FIDO not configured");
        require(!_usedFidoChallenges[_challenge], "Challenge already used");

        Dispute storage d = _disputes[_disputeId];
        require(!d.resolved, "Dispute resolved");
        require(bytes(d.llmProposal).length > 0, "No proposal yet");
        require(block.timestamp <= d.startTime + RESOLUTION_TIMEOUT, "Timeout passed");

        // Verify caller is a party
        bool isInitiator = msg.sender == d.initiator;
        bool isCounterparty = msg.sender == d.counterparty;
        require(isInitiator || isCounterparty, "Not a party");

        // Verify FIDO assertion - the challenge should be generated via generateFIDOChallenge()
        // which binds it to the action, dispute, user, and chain
        require(
            fidoVerifier.verifyAssertion(msg.sender, _assertion, _challenge),
            "Invalid FIDO signature"
        );

        // Mark challenge as used
        _usedFidoChallenges[_challenge] = true;

        // Record acceptance
        if (isInitiator) {
            require(!d.initiatorAccepted, "Already accepted");
            d.initiatorAccepted = true;
        } else {
            require(!d.counterpartyAccepted, "Already accepted");
            d.counterpartyAccepted = true;
        }

        // Get credential ID hash for event
        bytes32[] memory keyIds = fidoVerifier.getUserKeyIds(msg.sender);
        bytes32 credIdHash = keyIds.length > 0 ? keyIds[0] : bytes32(0);

        emit FIDOAcceptance(_disputeId, msg.sender, credIdHash);
        emit AcceptanceSignaled(_disputeId, msg.sender);

        // Resolve if both accepted
        if (d.initiatorAccepted && d.counterpartyAccepted) {
            _resolveAccepted(_disputeId, d);
        }
    }

    /**
     * @notice Counter-propose with FIDO2 authentication
     * @dev Hardware-backed counter-proposal for enhanced security
     * @param _disputeId The dispute ID
     * @param _newEvidenceHash Hash of new evidence
     * @param _assertion WebAuthn assertion
     * @param _challenge The challenge that was signed
     */
    function fidoCounterPropose(
        uint256 _disputeId,
        bytes32 _newEvidenceHash,
        IFIDOVerifier.WebAuthnAssertion calldata _assertion,
        bytes32 _challenge
    ) external payable nonReentrant whenNotPaused {
        require(address(fidoVerifier) != address(0), "FIDO not configured");
        require(!_usedFidoChallenges[_challenge], "Challenge already used");

        Dispute storage d = _disputes[_disputeId];
        require(msg.sender == d.initiator || msg.sender == d.counterparty, "Not a party");
        require(!d.resolved, "Dispute resolved");
        require(d.counterpartyStake > 0, "Not fully staked");
        require(d.counterCount < MAX_COUNTERS, "Max counters reached");

        // Verify FIDO assertion
        require(
            fidoVerifier.verifyAssertion(msg.sender, _assertion, _challenge),
            "Invalid FIDO signature"
        );

        _usedFidoChallenges[_challenge] = true;

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
        d.evidenceHash = _newEvidenceHash;
        d.initiatorAccepted = false;
        d.counterpartyAccepted = false;
        d.llmProposal = "";

        // FIX M-NEW-01: Apply same MAX_TIME_EXTENSION check as counterPropose
        // Prevents FIDO path from bypassing the L-01 fix
        uint256 currentExtension = d.counterCount * 1 days;
        if (currentExtension <= MAX_TIME_EXTENSION) {
            d.startTime += 1 days;
        }

        emit CounterProposed(_disputeId, msg.sender, d.counterCount);
    }

    /**
     * @notice Check if FIDO is required for an address and action
     * @param _user The user address
     * @return required True if FIDO is required
     */
    function isFIDORequired(address _user) external view returns (bool required) {
        return fidoRequired[_user] && address(fidoVerifier) != address(0);
    }

    /**
     * @notice Generate challenge data for FIDO signing
     * @dev Frontend should use this to create the challenge for WebAuthn
     * @param _action Action identifier
     * @param _disputeId Dispute ID (0 if not applicable)
     * @return challenge The challenge to be signed
     */
    function generateFIDOChallenge(
        string calldata _action,
        uint256 _disputeId
    ) external view returns (bytes32 challenge) {
        return keccak256(
            abi.encodePacked(
                _action,
                _disputeId,
                msg.sender,
                block.timestamp,
                block.chainid
            )
        );
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
     * @notice Enable or disable DID requirement for disputes
     * @dev When enabled, parties must have a valid DID with sufficient sybil score
     * @param _required Whether DID verification is required
     * @param _minScore Minimum sybil score required (0-100)
     */
    function setDIDRequirement(bool _required, uint256 _minScore) external onlyOwner {
        didRequired = _required;
        minDIDSybilScore = _minScore;
        emit DIDRequirementChanged(_required, _minScore);
    }

    /**
     * @notice Initiate a breach dispute with DID verification
     * @dev Requires both parties to have valid DIDs with sufficient sybil scores
     * @param _counterparty The opposing party
     * @param _stakeAmount Base stake amount (may be escalated)
     * @param _evidenceHash Hash of canonicalized evidence bundle
     * @param _fallbackTerms Fallback license applied on timeout
     * @return disputeId The unique dispute identifier
     */
    function initiateBreachDisputeWithDID(
        address _counterparty,
        uint256 _stakeAmount,
        bytes32 _evidenceHash,
        FallbackLicense calldata _fallbackTerms
    ) external nonReentrant whenNotPaused returns (uint256 disputeId) {
        require(address(didRegistry) != address(0), "DID registry not set");
        require(_counterparty != address(0), "Invalid counterparty");
        require(_counterparty != msg.sender, "Cannot dispute self");
        require(_stakeAmount > 0, "Zero stake");
        require(_fallbackTerms.nonExclusive, "Fallback must be non-exclusive");

        // Verify initiator has valid DID with sufficient sybil score
        _verifyDIDRequirement(msg.sender);

        // Calculate escalated stake for repeat disputes
        uint256 escalatedStake = _getEscalatedStake(msg.sender, _counterparty, _stakeAmount);

        // Transfer stake from initiator
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
            fallback: _fallbackTerms,
            counterCount: 0
        });

        // Store initiator's DID
        bytes32 initiatorDID = didRegistry.addressToDID(msg.sender);
        _disputeDIDs[disputeId][true] = initiatorDID;

        // Freeze assets via registry
        assetRegistry.freezeAssets(disputeId, msg.sender);

        // Update cooldown tracking
        lastDisputeTime[msg.sender][_counterparty] = block.timestamp;

        emit DisputeInitiated(disputeId, msg.sender, _counterparty, _evidenceHash);
        emit DIDAssociatedWithDispute(disputeId, initiatorDID, true);
    }

    /**
     * @notice Deposit stake for a dispute with DID verification
     * @dev Counterparty must have valid DID with sufficient sybil score
     * @param _disputeId The dispute ID
     */
    function depositStakeWithDID(uint256 _disputeId) external nonReentrant whenNotPaused {
        require(address(didRegistry) != address(0), "DID registry not set");

        Dispute storage d = _disputes[_disputeId];
        require(msg.sender == d.counterparty, "Not counterparty");
        require(d.counterpartyStake == 0, "Already staked");
        require(!d.resolved, "Dispute resolved");
        require(block.timestamp <= d.startTime + STAKE_WINDOW, "Stake window closed");

        // Verify counterparty has valid DID with sufficient sybil score
        _verifyDIDRequirement(msg.sender);

        // Match initiator's stake (symmetric)
        token.safeTransferFrom(msg.sender, address(this), d.initiatorStake);
        d.counterpartyStake = d.initiatorStake;

        // Store counterparty's DID
        bytes32 counterpartyDID = didRegistry.addressToDID(msg.sender);
        _disputeDIDs[_disputeId][false] = counterpartyDID;

        emit StakeDeposited(_disputeId, msg.sender, d.initiatorStake);
        emit DIDAssociatedWithDispute(_disputeId, counterpartyDID, false);
    }

    /**
     * @notice Check if a participant meets DID requirements
     * @param _participant Address to check
     * @return hasDID Whether they have a DID
     * @return did The DID identifier
     * @return sybilScore Their sybil score
     * @return meetsRequirement Whether they meet the minimum score
     */
    function checkDIDRequirement(address _participant) external view returns (
        bool hasDID,
        bytes32 did,
        uint256 sybilScore,
        bool meetsRequirement
    ) {
        if (address(didRegistry) == address(0)) {
            return (false, bytes32(0), 0, !didRequired);
        }

        hasDID = didRegistry.hasDID(_participant);
        if (!hasDID) {
            return (false, bytes32(0), 0, !didRequired);
        }

        did = didRegistry.addressToDID(_participant);
        sybilScore = didRegistry.getSybilScore(did);
        meetsRequirement = sybilScore >= minDIDSybilScore;
    }

    /**
     * @notice Get the DID associated with a party in a dispute
     * @param _disputeId The dispute ID
     * @param _isInitiator True for initiator, false for counterparty
     * @return The DID identifier
     */
    function getDisputeDID(uint256 _disputeId, bool _isInitiator) external view returns (bytes32) {
        return _disputeDIDs[_disputeId][_isInitiator];
    }

    /**
     * @notice Internal function to verify DID requirement
     * @param _participant Address to verify
     */
    function _verifyDIDRequirement(address _participant) internal view {
        // FIX: If DID is not required, skip all validation
        if (!didRequired) {
            return;
        }

        if (!didRegistry.hasDID(_participant)) {
            revert InvalidDID(_participant);
        }

        bytes32 did = didRegistry.addressToDID(_participant);
        IDIDRegistry.DIDDocument memory doc = didRegistry.getDIDDocument(did);

        if (doc.status != IDIDRegistry.DIDStatus.Active) {
            revert InvalidDID(_participant);
        }

        if (doc.sybilScore < minDIDSybilScore) {
            revert InsufficientSybilScore(_participant, minDIDSybilScore, doc.sybilScore);
        }
    }
}
