// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./interfaces/IComplianceEscrow.sol";
import "./interfaces/IILRM.sol";

/**
 * @title ComplianceEscrow
 * @notice Manages viewing key shares for selective de-anonymization
 * @dev Implements threshold decryption via Shamir's Secret Sharing
 *
 * Design Principles:
 * 1. No Honeypot: No single party holds the complete viewing key
 * 2. Transparency: All reveal requests and votes are logged on-chain
 * 3. Governance: Threshold of parties must approve before reconstruction
 * 4. Auditability: Complete audit trail of all compliance actions
 *
 * Flow:
 * 1. User creates escrow with viewing key commitment + share holders
 * 2. Each holder submits their share commitment (proof of possession)
 * 3. Legal request triggers reveal request with voting
 * 4. If approved, holders submit encrypted shares
 * 5. Off-chain coordinator reconstructs key and decrypts data
 * 6. Reconstruction is recorded on-chain for audit
 */
contract ComplianceEscrow is IComplianceEscrow, ReentrancyGuard, Pausable, Ownable2Step {
    // ============ Constants ============

    /// @notice Maximum share holders per escrow
    uint8 public constant MAX_HOLDERS = 10;

    /// @notice Minimum threshold (must have at least 2 parties)
    uint8 public constant MIN_THRESHOLD = 2;

    /// @notice Maximum voting period (30 days)
    uint256 public constant MAX_VOTING_PERIOD = 30 days;

    /// @notice Minimum voting period (1 day)
    uint256 public constant MIN_VOTING_PERIOD = 1 days;

    // ============ State Variables ============

    /// @notice Counter for escrow IDs
    uint256 private _escrowCounter;

    /// @notice Counter for reveal request IDs
    uint256 private _requestCounter;

    /// @notice Escrow configurations: escrowId => config
    mapping(uint256 => EscrowConfig) private _escrows;

    /// @notice Share holders: escrowId => array of holders
    mapping(uint256 => ShareHolder[]) private _shareHolders;

    /// @notice Holder index lookup: escrowId => holder => index
    mapping(uint256 => mapping(address => uint256)) private _holderIndex;

    /// @notice Is holder registered: escrowId => holder => bool
    mapping(uint256 => mapping(address => bool)) private _isHolder;

    /// @notice Reveal requests: requestId => request
    mapping(uint256 => RevealRequest) private _revealRequests;

    /// @notice Has voted on request: requestId => voter => bool
    mapping(uint256 => mapping(address => bool)) private _hasVoted;

    /// @notice Submitted shares for request: requestId => array of encrypted shares
    mapping(uint256 => bytes[]) private _submittedShares;

    /// @notice Share submission tracking: requestId => holder => submitted
    mapping(uint256 => mapping(address => bool)) private _hasSubmittedShare;

    /// @notice Dispute to escrow mapping: disputeId => escrowId
    mapping(uint256 => uint256) public disputeEscrow;

    /// @notice Authorized ILRM contract
    address public ilrm;

    // ============ Constructor ============

    constructor() Ownable(msg.sender) {}

    // ============ Modifiers ============

    modifier escrowExists(uint256 escrowId) {
        if (_escrows[escrowId].createdAt == 0) revert EscrowNotFound(escrowId);
        _;
    }

    modifier requestExists(uint256 requestId) {
        if (_revealRequests[requestId].requestedAt == 0) revert RequestNotFound(requestId);
        _;
    }

    modifier onlyShareHolder(uint256 escrowId) {
        if (!_isHolder[escrowId][msg.sender]) revert NotShareHolder(msg.sender);
        _;
    }

    // ============ Escrow Management ============

    /**
     * @inheritdoc IComplianceEscrow
     */
    function createEscrow(
        uint256 disputeId,
        bytes32 viewingKeyCommitment,
        bytes32 encryptedDataHash,
        uint8 threshold,
        uint8 totalShares,
        address[] calldata holders,
        HolderType[] calldata holderTypes
    ) external override nonReentrant whenNotPaused returns (uint256 escrowId) {
        // Validate inputs
        if (threshold < MIN_THRESHOLD) revert InvalidThreshold(threshold, totalShares);
        if (threshold > totalShares) revert InvalidThreshold(threshold, totalShares);
        if (totalShares > MAX_HOLDERS) revert InvalidThreshold(threshold, totalShares);
        if (holders.length != totalShares) revert InvalidThreshold(threshold, totalShares);
        if (holders.length != holderTypes.length) revert InvalidThreshold(threshold, totalShares);
        if (viewingKeyCommitment == bytes32(0)) revert InvalidCommitment();

        // Validate dispute exists in ILRM
        if (ilrm == address(0)) revert ILRMNotSet();
        uint256 disputeCount = IILRM(ilrm).disputeCounter();
        if (disputeId >= disputeCount) revert DisputeNotFound(disputeId);

        escrowId = _escrowCounter++;

        // Store escrow config
        _escrows[escrowId] = EscrowConfig({
            disputeId: disputeId,
            viewingKeyCommitment: viewingKeyCommitment,
            encryptedDataHash: encryptedDataHash,
            threshold: threshold,
            totalShares: totalShares,
            createdAt: block.timestamp,
            revealed: false
        });

        // Register share holders
        for (uint256 i = 0; i < holders.length; i++) {
            _shareHolders[escrowId].push(ShareHolder({
                holder: holders[i],
                holderType: holderTypes[i],
                shareCommitment: bytes32(0),
                hasSubmitted: false
            }));

            _holderIndex[escrowId][holders[i]] = i;
            _isHolder[escrowId][holders[i]] = true;

            emit ShareHolderRegistered(escrowId, holders[i], holderTypes[i], i);
        }

        // Link dispute to escrow
        disputeEscrow[disputeId] = escrowId;

        emit EscrowCreated(
            escrowId,
            disputeId,
            viewingKeyCommitment,
            threshold,
            totalShares
        );
    }

    /**
     * @inheritdoc IComplianceEscrow
     */
    function submitShareCommitment(
        uint256 escrowId,
        bytes32 shareCommitment
    ) external override escrowExists(escrowId) onlyShareHolder(escrowId) nonReentrant {
        if (shareCommitment == bytes32(0)) revert InvalidCommitment();

        uint256 index = _holderIndex[escrowId][msg.sender];
        ShareHolder storage holder = _shareHolders[escrowId][index];

        if (holder.shareCommitment != bytes32(0)) revert ShareAlreadySubmitted(msg.sender);

        holder.shareCommitment = shareCommitment;

        emit ShareCommitmentSubmitted(escrowId, msg.sender, shareCommitment);
    }

    // ============ Reveal Request Management ============

    /**
     * @inheritdoc IComplianceEscrow
     */
    function requestReveal(
        uint256 escrowId,
        string calldata reason,
        bytes32 legalDocHash,
        uint256 votingPeriod
    ) external override escrowExists(escrowId) nonReentrant whenNotPaused returns (uint256 requestId) {
        EscrowConfig storage escrow = _escrows[escrowId];

        if (escrow.revealed) revert AlreadyRevealed(escrowId);
        if (votingPeriod < MIN_VOTING_PERIOD || votingPeriod > MAX_VOTING_PERIOD) {
            revert InvalidThreshold(0, 0);
        }

        requestId = _requestCounter++;

        _revealRequests[requestId] = RevealRequest({
            escrowId: escrowId,
            requester: msg.sender,
            reason: reason,
            legalDocHash: legalDocHash,
            requestedAt: block.timestamp,
            expiresAt: block.timestamp + votingPeriod,
            status: RevealStatus.Pending,
            approvalsReceived: 0,
            rejectionsReceived: 0
        });

        emit RevealRequested(requestId, escrowId, msg.sender, reason);
    }

    /**
     * @inheritdoc IComplianceEscrow
     */
    function voteOnReveal(
        uint256 requestId,
        bool approve
    ) external override requestExists(requestId) nonReentrant {
        RevealRequest storage request = _revealRequests[requestId];
        uint256 escrowId = request.escrowId;

        // Validate
        if (!_isHolder[escrowId][msg.sender]) revert NotShareHolder(msg.sender);
        if (_hasVoted[requestId][msg.sender]) revert AlreadyVoted(msg.sender);
        if (block.timestamp > request.expiresAt) revert RequestExpired(requestId);
        if (request.status != RevealStatus.Pending) revert RequestNotApproved(requestId);

        // Record vote
        _hasVoted[requestId][msg.sender] = true;

        if (approve) {
            request.approvalsReceived++;
        } else {
            request.rejectionsReceived++;
        }

        emit RevealVoteCast(requestId, msg.sender, approve);

        // Check if threshold met
        EscrowConfig storage escrow = _escrows[escrowId];

        if (request.approvalsReceived >= escrow.threshold) {
            RevealStatus oldStatus = request.status;
            request.status = RevealStatus.Approved;
            emit RevealStatusChanged(requestId, oldStatus, RevealStatus.Approved);
        } else if (request.rejectionsReceived > escrow.totalShares - escrow.threshold) {
            // Majority rejected - cannot reach threshold
            RevealStatus oldStatus = request.status;
            request.status = RevealStatus.Rejected;
            emit RevealStatusChanged(requestId, oldStatus, RevealStatus.Rejected);
        }
    }

    /**
     * @inheritdoc IComplianceEscrow
     */
    function submitShareForReveal(
        uint256 requestId,
        uint256 shareIndex,
        bytes calldata encryptedShare
    ) external override requestExists(requestId) nonReentrant {
        RevealRequest storage request = _revealRequests[requestId];
        uint256 escrowId = request.escrowId;
        EscrowConfig storage escrow = _escrows[escrowId];

        // Validate
        if (request.status != RevealStatus.Approved) revert RequestNotApproved(requestId);
        if (!_isHolder[escrowId][msg.sender]) revert NotShareHolder(msg.sender);
        if (_hasSubmittedShare[requestId][msg.sender]) revert ShareAlreadySubmitted(msg.sender);
        if (shareIndex >= escrow.totalShares) revert InvalidShareIndex(shareIndex);

        // Verify caller is the holder for this index
        if (_holderIndex[escrowId][msg.sender] != shareIndex) revert InvalidShareIndex(shareIndex);

        // Store encrypted share
        _submittedShares[requestId].push(encryptedShare);
        _hasSubmittedShare[requestId][msg.sender] = true;

        // Update holder status
        _shareHolders[escrowId][shareIndex].hasSubmitted = true;

        emit ShareSubmittedForReveal(requestId, msg.sender, shareIndex);
    }

    /**
     * @inheritdoc IComplianceEscrow
     */
    function finalizeReveal(
        uint256 requestId,
        bytes32 reconstructedKeyHash
    ) external override requestExists(requestId) nonReentrant {
        RevealRequest storage request = _revealRequests[requestId];
        uint256 escrowId = request.escrowId;
        EscrowConfig storage escrow = _escrows[escrowId];

        // Validate
        if (request.status != RevealStatus.Approved) revert RequestNotApproved(requestId);
        if (_submittedShares[requestId].length < escrow.threshold) {
            revert ThresholdNotMet(escrow.threshold, _submittedShares[requestId].length);
        }
        if (escrow.revealed) revert AlreadyRevealed(escrowId);

        // Only share holders or owner can finalize
        if (!_isHolder[escrowId][msg.sender] && msg.sender != owner()) {
            revert Unauthorized();
        }

        // Mark as revealed
        escrow.revealed = true;
        request.status = RevealStatus.Executed;

        emit RevealStatusChanged(requestId, RevealStatus.Approved, RevealStatus.Executed);
        emit KeyReconstructed(requestId, escrowId, reconstructedKeyHash);
    }

    /**
     * @notice Expire a pending request after voting period
     * @param requestId The request to expire
     */
    function expireRequest(uint256 requestId) external requestExists(requestId) {
        RevealRequest storage request = _revealRequests[requestId];

        if (request.status != RevealStatus.Pending) revert RequestNotApproved(requestId);
        if (block.timestamp <= request.expiresAt) revert RequestNotApproved(requestId);

        RevealStatus oldStatus = request.status;
        request.status = RevealStatus.Expired;

        emit RevealStatusChanged(requestId, oldStatus, RevealStatus.Expired);
    }

    // ============ View Functions ============

    /**
     * @inheritdoc IComplianceEscrow
     */
    function getEscrow(uint256 escrowId) external view override returns (EscrowConfig memory config) {
        return _escrows[escrowId];
    }

    /**
     * @inheritdoc IComplianceEscrow
     */
    function getShareHolders(uint256 escrowId) external view override returns (ShareHolder[] memory holders) {
        return _shareHolders[escrowId];
    }

    /**
     * @inheritdoc IComplianceEscrow
     */
    function getRevealRequest(uint256 requestId) external view override returns (RevealRequest memory request) {
        return _revealRequests[requestId];
    }

    /**
     * @inheritdoc IComplianceEscrow
     */
    function isShareHolder(uint256 escrowId, address holder) external view override returns (bool) {
        return _isHolder[escrowId][holder];
    }

    /**
     * @inheritdoc IComplianceEscrow
     */
    function getSubmittedShareCount(uint256 requestId) external view override returns (uint256 count) {
        return _submittedShares[requestId].length;
    }

    /**
     * @inheritdoc IComplianceEscrow
     */
    function isThresholdMet(uint256 requestId) external view override returns (bool) {
        RevealRequest storage request = _revealRequests[requestId];
        EscrowConfig storage escrow = _escrows[request.escrowId];
        return _submittedShares[requestId].length >= escrow.threshold;
    }

    /**
     * @notice Get submitted encrypted shares for a request
     * @param requestId The request ID
     * @return shares Array of encrypted shares
     */
    function getSubmittedShares(uint256 requestId) external view returns (bytes[] memory shares) {
        return _submittedShares[requestId];
    }

    /**
     * @notice Get total escrow count
     */
    function escrowCount() external view returns (uint256) {
        return _escrowCounter;
    }

    /**
     * @notice Get total request count
     */
    function requestCount() external view returns (uint256) {
        return _requestCounter;
    }

    /**
     * @notice Check if address has voted on a request
     */
    function hasVoted(uint256 requestId, address voter) external view returns (bool) {
        return _hasVoted[requestId][voter];
    }

    // ============ Admin Functions ============

    /**
     * @notice Set the authorized ILRM contract
     * @param _ilrm The ILRM contract address
     */
    function setILRM(address _ilrm) external onlyOwner {
        ilrm = _ilrm;
    }

    /**
     * @notice Pause the contract
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause the contract
     */
    function unpause() external onlyOwner {
        _unpause();
    }
}
