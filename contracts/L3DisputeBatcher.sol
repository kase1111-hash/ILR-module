// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "./interfaces/IL3Bridge.sol";
import "./interfaces/IILRM.sol";

/**
 * @title L3DisputeBatcher
 * @notice Batches dispute operations for efficient L3 processing
 * @dev Aggregates multiple disputes for single state commitment
 *
 * Features:
 * - Queue disputes for batched bridging
 * - Aggregate settlements for batch processing
 * - Gas-efficient batch operations
 * - Automatic batch triggers based on size/time
 * - FIX I-02: Two-step ownership transfer via Ownable2Step
 */
contract L3DisputeBatcher is ReentrancyGuard, Ownable2Step {
    // ============ Constants ============

    /// @notice Maximum disputes per batch
    uint256 public constant MAX_BATCH_SIZE = 50;

    /// @notice Minimum batch size to trigger
    uint256 public constant MIN_BATCH_SIZE = 5;

    /// @notice Maximum batch wait time (1 hour)
    uint256 public constant MAX_BATCH_WAIT = 1 hours;

    // ============ State Variables ============

    /// @notice L3 Bridge contract
    IL3Bridge public l3Bridge;

    /// @notice ILRM contract
    IILRM public ilrm;

    /// @notice Current batch of pending initiations
    IL3Bridge.DisputeInitiationMessage[] private _pendingInitiations;

    /// @notice Current batch of pending settlements
    IL3Bridge.DisputeSettlementMessage[] private _pendingSettlements;

    /// @notice Timestamp of first item in current batch
    uint256 public batchStartTime;

    /// @notice Whether auto-batching is enabled
    bool public autoBatchEnabled;

    /// @notice Authorized batch submitters
    mapping(address => bool) public authorizedSubmitters;

    // ============ Events ============

    event DisputeQueued(
        uint256 indexed l2DisputeId,
        address indexed initiator,
        uint256 batchPosition
    );

    event SettlementQueued(
        uint256 indexed l2DisputeId,
        uint256 indexed l3DisputeId,
        uint256 batchPosition
    );

    event BatchSubmitted(
        uint256 indexed batchId,
        uint256 disputeCount,
        bytes32 batchHash
    );

    event SettlementBatchProcessed(
        uint256 indexed batchId,
        uint256 settlementCount
    );

    event SubmitterAuthorized(address indexed submitter, bool authorized);

    // ============ Errors ============

    error BatchFull();
    error BatchEmpty();
    error NotAuthorizedSubmitter(address caller);
    error BatchNotReady();
    error InvalidBatchData();

    // ============ Constructor ============

    constructor(address _l3Bridge, address _ilrm) Ownable(msg.sender) {
        require(_l3Bridge != address(0), "Invalid bridge");
        require(_ilrm != address(0), "Invalid ILRM");

        l3Bridge = IL3Bridge(_l3Bridge);
        ilrm = IILRM(_ilrm);
        autoBatchEnabled = true;

        // Owner is initial authorized submitter
        authorizedSubmitters[msg.sender] = true;
    }

    // ============ Modifiers ============

    modifier onlyAuthorizedSubmitter() {
        if (!authorizedSubmitters[msg.sender]) {
            revert NotAuthorizedSubmitter(msg.sender);
        }
        _;
    }

    // ============ Queue Functions ============

    /**
     * @notice Queue a dispute initiation for batched bridging
     * @dev Only authorized submitters can queue to prevent spam DoS attacks
     * @param message The dispute initiation data
     * @return position Position in current batch
     */
    function queueDisputeInitiation(
        IL3Bridge.DisputeInitiationMessage calldata message
    ) external onlyAuthorizedSubmitter nonReentrant returns (uint256 position) {
        // Check batch capacity
        if (_pendingInitiations.length >= MAX_BATCH_SIZE) {
            revert BatchFull();
        }

        // Start batch timer if first item
        if (_pendingInitiations.length == 0) {
            batchStartTime = block.timestamp;
        }

        // Add to batch
        _pendingInitiations.push(message);
        position = _pendingInitiations.length - 1;

        emit DisputeQueued(message.l2DisputeId, message.initiator, position);

        // Check if auto-batch should trigger
        if (autoBatchEnabled && _shouldTriggerBatch()) {
            _submitInitiationBatch();
        }
    }

    /**
     * @notice Queue a settlement for batched processing
     * @param message The settlement data
     * @return position Position in current batch
     */
    function queueSettlement(
        IL3Bridge.DisputeSettlementMessage calldata message
    ) external onlyAuthorizedSubmitter nonReentrant returns (uint256 position) {
        // Check batch capacity
        if (_pendingSettlements.length >= MAX_BATCH_SIZE) {
            revert BatchFull();
        }

        // Add to batch
        _pendingSettlements.push(message);
        position = _pendingSettlements.length - 1;

        emit SettlementQueued(message.l2DisputeId, message.l3DisputeId, position);
    }

    // ============ Batch Submission ============

    /**
     * @notice Submit current initiation batch to L3 bridge
     * @return batchId The batch identifier
     * @return count Number of disputes bridged
     */
    function submitInitiationBatch() external onlyAuthorizedSubmitter nonReentrant returns (
        uint256 batchId,
        uint256 count
    ) {
        return _submitInitiationBatch();
    }

    /**
     * @notice Internal batch submission
     */
    function _submitInitiationBatch() internal returns (uint256 batchId, uint256 count) {
        count = _pendingInitiations.length;
        if (count == 0) revert BatchEmpty();

        // Compute batch hash for tracking
        bytes32 batchHash = keccak256(abi.encode(_pendingInitiations));
        batchId = uint256(batchHash);

        // Bridge each dispute
        for (uint256 i = 0; i < count; i++) {
            l3Bridge.bridgeDisputeToL3(_pendingInitiations[i]);
        }

        emit BatchSubmitted(batchId, count, batchHash);

        // Clear batch
        delete _pendingInitiations;
        batchStartTime = 0;
    }

    /**
     * @notice Process settlement batch through L3 bridge
     * @return count Number of settlements processed
     */
    function processSettlementBatch() external onlyAuthorizedSubmitter nonReentrant returns (uint256 count) {
        count = _pendingSettlements.length;
        if (count == 0) revert BatchEmpty();

        // Process through bridge
        l3Bridge.batchProcessSettlements(_pendingSettlements);

        uint256 batchId = uint256(keccak256(abi.encode(_pendingSettlements)));
        emit SettlementBatchProcessed(batchId, count);

        // Clear batch
        delete _pendingSettlements;
    }

    // ============ Batch Status ============

    /**
     * @notice Check if batch should auto-trigger
     * @return True if batch conditions are met
     */
    function _shouldTriggerBatch() internal view returns (bool) {
        uint256 count = _pendingInitiations.length;

        // Trigger if max size reached
        if (count >= MAX_BATCH_SIZE) return true;

        // Trigger if min size and max wait exceeded
        if (count >= MIN_BATCH_SIZE && block.timestamp >= batchStartTime + MAX_BATCH_WAIT) {
            return true;
        }

        return false;
    }

    /**
     * @notice Get pending initiation batch size
     * @return Current batch size
     */
    function getPendingInitiationsCount() external view returns (uint256) {
        return _pendingInitiations.length;
    }

    /**
     * @notice Get pending settlement batch size
     * @return Current batch size
     */
    function getPendingSettlementsCount() external view returns (uint256) {
        return _pendingSettlements.length;
    }

    /**
     * @notice Get time until batch auto-triggers
     * @return remaining Seconds until trigger (0 if ready or empty)
     */
    function getTimeUntilAutoTrigger() external view returns (uint256 remaining) {
        if (_pendingInitiations.length == 0) return 0;
        if (_pendingInitiations.length >= MAX_BATCH_SIZE) return 0;

        uint256 triggerTime = batchStartTime + MAX_BATCH_WAIT;
        if (block.timestamp >= triggerTime) return 0;

        return triggerTime - block.timestamp;
    }

    /**
     * @notice Check if batch is ready for manual submission
     * @return ready True if batch can be submitted
     * @return reason Reason if not ready
     */
    function isBatchReady() external view returns (bool ready, string memory reason) {
        if (_pendingInitiations.length == 0) {
            return (false, "Batch empty");
        }
        if (_pendingInitiations.length < MIN_BATCH_SIZE) {
            return (false, "Below min size");
        }
        return (true, "");
    }

    /**
     * @notice Get pending initiation at index
     * @param index The index
     * @return The initiation message
     */
    function getPendingInitiation(uint256 index) external view returns (
        IL3Bridge.DisputeInitiationMessage memory
    ) {
        require(index < _pendingInitiations.length, "Index out of bounds");
        return _pendingInitiations[index];
    }

    /**
     * @notice Get pending settlement at index
     * @param index The index
     * @return The settlement message
     */
    function getPendingSettlement(uint256 index) external view returns (
        IL3Bridge.DisputeSettlementMessage memory
    ) {
        require(index < _pendingSettlements.length, "Index out of bounds");
        return _pendingSettlements[index];
    }

    // ============ Admin Functions ============

    /**
     * @notice Set auto-batch enabled
     */
    function setAutoBatchEnabled(bool enabled) external onlyOwner {
        autoBatchEnabled = enabled;
    }

    /**
     * @notice Authorize or revoke batch submitter
     * @param submitter Address to authorize
     * @param authorized Whether to authorize or revoke
     */
    function setAuthorizedSubmitter(address submitter, bool authorized) external onlyOwner {
        authorizedSubmitters[submitter] = authorized;
        emit SubmitterAuthorized(submitter, authorized);
    }

    /**
     * @notice Update L3 Bridge address
     */
    function setL3Bridge(address _l3Bridge) external onlyOwner {
        require(_l3Bridge != address(0), "Invalid bridge");
        l3Bridge = IL3Bridge(_l3Bridge);
    }

    /**
     * @notice Update ILRM address
     */
    function setILRM(address _ilrm) external onlyOwner {
        require(_ilrm != address(0), "Invalid ILRM");
        ilrm = IILRM(_ilrm);
    }

    /**
     * @notice Emergency clear pending batches
     * @dev Only use if batch is stuck
     */
    function emergencyClearBatches() external onlyOwner {
        delete _pendingInitiations;
        delete _pendingSettlements;
        batchStartTime = 0;
    }

    /**
     * @notice Force trigger batch submission
     * @dev Bypasses size/time checks
     */
    function forceSubmitBatch() external onlyOwner nonReentrant {
        if (_pendingInitiations.length > 0) {
            _submitInitiationBatch();
        }
    }
}
