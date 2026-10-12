// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "../interfaces/IL3Bridge.sol";
import "../interfaces/IILRM.sol";

/**
 * @title L3DisputeBatcher
 * @notice Batches dispute operations for efficient L3 processing
 *
 * @custom:security-warning NOT PRODUCTION-READY - MUST NOT BE DEPLOYED.
 * This batcher only queues and relays for L3Bridge, which is known to be unsound (see the L3Bridge warning):
 * its fraud proofs let anyone reject honest state roots, the sequencer posts no bond, settlements with
 * stateProof == bytes32(0) are not tied to any finalized root, and bridged disputes are never validated
 * against the ILRM. The batcher adds no such checks: queued initiations are bridged as submitted and queued
 * settlements are relayed on the sequencer's word alone. No deploy script deploys this contract.
 *
 * @dev Aggregates multiple disputes for single state commitment
 *
 * Features:
 * - Queue disputes for batched bridging
 * - Aggregate settlements for batch processing
 * - Gas-efficient batch operations
 * - Automatic batch triggers based on size/time
 * - FIX I-02: Two-step ownership transfer via Ownable2Step
 *
 * Required bridge grants (the bridge owner must run these once the batcher is deployed):
 * - l3Bridge.setDisputeBridger(batcher, true)    - lets batches call bridgeDisputeBatchToL3
 * - l3Bridge.setSettlementRelayer(batcher, true) - lets processSettlementBatch call batchProcessSettlements
 *
 * Dispute batches:
 * - A batch is submitted with one bridgeDisputeBatchToL3 call. Disputes that are already bridged
 *   (or duplicated within the batch) are skipped by the bridge, and BatchSubmitted.disputeCount
 *   counts only the disputes actually bridged.
 * - The queue is cleared before the bridge is called. A manual submission (submitInitiationBatch,
 *   forceSubmitBatch) reverts as a whole if the bridge reverts, restoring the queue.
 * - Auto-batching (on the queue call that fills the batch, or once MIN_BATCH_SIZE items have waited
 *   MAX_BATCH_WAIT) runs as an isolated self-call. If it fails for any reason (bridge revert, missing
 *   role, bridge inactive, out of gas) the self-call is rolled back, the queue stays intact,
 *   AutoBatchFailed is emitted and the queue call itself still succeeds.
 * - A failed auto-batch backs the time trigger off (AutoBatchDeferred): no time-triggered attempt is made
 *   for AUTO_BATCH_RETRY_DELAY (10 min), doubling per consecutive failure up to MAX_AUTO_BATCH_RETRY_DELAY
 *   (1 day), so queue calls do not each pay for a doomed retry. Any successful batch submission (auto,
 *   submitInitiationBatch or forceSubmitBatch) and emergencyClearBatches reset the backoff. The size
 *   trigger is not backed off: only the queue call that fills the batch reaches it.
 *
 * Settlement batches:
 * - Only the bridge's current sequencer can queue settlements; any authorized submitter can relay them.
 * - A batch queued by a sequencer that has since been replaced is never relayed: processSettlementBatch
 *   reverts SequencerChanged, and the new sequencer's first queueSettlement discards the stale batch.
 * - The bridge skips invalid settlements (SettlementSkipped) instead of reverting, so one bad message
 *   cannot get the queue stuck. SettlementBatchProcessed.settlementCount counts only the applied ones.
 */
contract L3DisputeBatcher is ReentrancyGuard, Ownable2Step {
    // ============ Constants ============

    /// @notice Maximum disputes per batch
    uint256 public constant MAX_BATCH_SIZE = 50;

    /// @notice Minimum batch size to trigger
    uint256 public constant MIN_BATCH_SIZE = 5;

    /// @notice Maximum batch wait time (1 hour)
    uint256 public constant MAX_BATCH_WAIT = 1 hours;

    /// @notice Delay before the time trigger retries after a failed auto-batch; doubles per consecutive failure
    uint256 public constant AUTO_BATCH_RETRY_DELAY = 10 minutes;

    /// @notice Upper bound on the auto-batch retry delay
    uint256 public constant MAX_AUTO_BATCH_RETRY_DELAY = 1 days;

    // ============ Types ============

    /// @notice Failed auto-batch backoff state (a single storage slot, so the failure path stays cheap)
    struct AutoBatchBackoff {
        uint64 retryAfter; // The time trigger does not fire before this timestamp (0 = no backoff)
        uint64 delay; // Delay applied after the latest failure (0 = no failure since the last successful batch)
        uint64 consecutiveFailures; // Failed auto-batch attempts since the last successful batch
    }

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

    /// @notice Bridge sequencer that queued the current settlement batch (zero when the queue is empty)
    address public settlementBatchSequencer;

    /// @notice Backoff after failed auto-batches; reset by any successful batch submission or an emergency clear
    AutoBatchBackoff public autoBatchBackoff;

    // ============ Events ============

    event DisputeQueued(uint256 indexed l2DisputeId, address indexed initiator, uint256 batchPosition);

    event SettlementQueued(uint256 indexed l2DisputeId, uint256 indexed l3DisputeId, uint256 batchPosition);

    event BatchSubmitted(uint256 indexed batchId, uint256 disputeCount, bytes32 batchHash);

    event SettlementBatchProcessed(uint256 indexed batchId, uint256 settlementCount);

    event SubmitterAuthorized(address indexed submitter, bool authorized);

    event AutoBatchFailed(uint256 pendingCount, bytes reason);

    event AutoBatchDeferred(uint256 consecutiveFailures, uint256 retryAfter);

    event StaleSettlementsDiscarded(address indexed queuedBy, uint256 count);

    // ============ Errors ============

    error BatchFull();
    error BatchEmpty();
    error NotAuthorizedSubmitter(address caller);
    error BatchNotReady();
    error InvalidBatchData();
    error NotBridgeSequencer(address caller);
    error SequencerChanged(address queuedBy, address current);

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
    function queueDisputeInitiation(IL3Bridge.DisputeInitiationMessage calldata message)
        external
        onlyAuthorizedSubmitter
        nonReentrant
        returns (uint256 position)
    {
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

        // Check if auto-batch should trigger. The batch runs as an isolated self-call so that a failure
        // (of any kind, including out-of-gas with empty revert data) rolls back atomically, keeps the
        // queue intact and never makes this queue call revert. A failure backs the time trigger off, so
        // later queue calls do not each pay for a retry.
        if (autoBatchEnabled && _shouldTriggerBatch()) {
            // Self-call under the lock (no re-entry possible); the backoff can only be written after the failure
            // slither-disable-next-line reentrancy-no-eth
            try this.executeAutoBatch() {}
            catch (bytes memory reason) {
                emit AutoBatchFailed(_pendingInitiations.length, reason);
                _deferAutoBatch();
            }
        }
    }

    /**
     * @notice Back the time trigger off after a failed auto-batch
     * @dev The delay starts at AUTO_BATCH_RETRY_DELAY and doubles per consecutive failure, capped at
     *      MAX_AUTO_BATCH_RETRY_DELAY, so the time trigger makes at most one attempt per delay and is never
     *      disabled for good. Manual submission is unaffected.
     */
    function _deferAutoBatch() internal {
        AutoBatchBackoff memory backoff = autoBatchBackoff;

        // Double the previous delay (0 after a success); clamp to [AUTO_BATCH_RETRY_DELAY, MAX_AUTO_BATCH_RETRY_DELAY]
        uint256 delay = uint256(backoff.delay) * 2;
        if (delay < AUTO_BATCH_RETRY_DELAY) delay = AUTO_BATCH_RETRY_DELAY;
        if (delay > MAX_AUTO_BATCH_RETRY_DELAY) delay = MAX_AUTO_BATCH_RETRY_DELAY;
        uint256 retryAfter = block.timestamp + delay;
        uint256 failures = uint256(backoff.consecutiveFailures) + 1;

        // Cannot truncate: timestamps, delays (<= 1 day) and failure counts are far below 2^64
        autoBatchBackoff = AutoBatchBackoff({
            // forge-lint: disable-next-line(unsafe-typecast)
            retryAfter: uint64(retryAfter),
            // forge-lint: disable-next-line(unsafe-typecast)
            delay: uint64(delay),
            // forge-lint: disable-next-line(unsafe-typecast)
            consecutiveFailures: uint64(failures)
        });

        emit AutoBatchDeferred(failures, retryAfter);
    }

    /**
     * @notice Execute an auto-triggered batch submission
     * @dev Only callable by this contract (from queueDisputeInitiation, which holds the reentrancy lock)
     */
    function executeAutoBatch() external {
        if (msg.sender != address(this)) revert NotAuthorizedSubmitter(msg.sender);
        _submitInitiationBatch();
    }

    /**
     * @notice Queue a settlement for batched processing
     * @dev Only the bridge's current sequencer can queue settlements. If the queue holds a batch queued
     *      by a previous sequencer, that stale batch is discarded first.
     * @param message The settlement data
     * @return position Position in current batch
     */
    function queueSettlement(IL3Bridge.DisputeSettlementMessage calldata message)
        external
        nonReentrant
        returns (uint256 position)
    {
        address seq = l3Bridge.getSequencerConfig().sequencerAddress;
        if (msg.sender != seq) revert NotBridgeSequencer(msg.sender);

        uint256 len = _pendingSettlements.length;
        if (len != 0 && settlementBatchSequencer != msg.sender) {
            emit StaleSettlementsDiscarded(settlementBatchSequencer, len);
            delete _pendingSettlements;
            len = 0;
        }
        if (len == 0) {
            settlementBatchSequencer = msg.sender;
        }

        // Check batch capacity
        if (len >= MAX_BATCH_SIZE) {
            revert BatchFull();
        }

        // Add to batch
        _pendingSettlements.push(message);
        position = len;

        emit SettlementQueued(message.l2DisputeId, message.l3DisputeId, position);
    }

    // ============ Batch Submission ============

    /**
     * @notice Submit current initiation batch to L3 bridge
     * @return batchId The batch identifier
     * @return count Number of disputes bridged
     */
    function submitInitiationBatch()
        external
        onlyAuthorizedSubmitter
        nonReentrant
        returns (uint256 batchId, uint256 count)
    {
        return _submitInitiationBatch();
    }

    /**
     * @notice Internal batch submission
     * @dev Checks-effects-interactions: the queue is copied and cleared before the bridge is called.
     *      If the bridge reverts, the whole call (including the clear) is rolled back.
     * @return batchId The batch identifier (hash of the submitted batch)
     * @return count Number of disputes actually bridged (already-bridged disputes are skipped)
     */
    function _submitInitiationBatch() internal returns (uint256 batchId, uint256 count) {
        uint256 len = _pendingInitiations.length;
        if (len == 0) revert BatchEmpty();

        IL3Bridge.DisputeInitiationMessage[] memory batch = _pendingInitiations;

        // Compute batch hash for tracking
        bytes32 batchHash = keccak256(abi.encode(batch));
        batchId = uint256(batchHash);

        // Clear batch (and any failure backoff) before the external call; a bridge revert rolls both back
        delete _pendingInitiations;
        batchStartTime = 0;
        if (autoBatchBackoff.consecutiveFailures != 0) delete autoBatchBackoff;

        // Bridge the whole batch in one call
        uint256[] memory l3Ids = l3Bridge.bridgeDisputeBatchToL3(batch);
        if (l3Ids.length != len) revert InvalidBatchData();

        for (uint256 i = 0; i < len; i++) {
            if (l3Ids[i] != 0) count++;
        }

        emit BatchSubmitted(batchId, count, batchHash);
    }

    /**
     * @notice Process settlement batch through L3 bridge
     * @dev Requires the batcher to be an authorized settlement relayer on the bridge, and the bridge's
     *      sequencer to be the one that queued the batch. The bridge skips (and reports with
     *      SettlementSkipped) any settlement that fails its checks, so one bad message never blocks the
     *      queue; the whole queue is consumed either way. Only a batch-level revert (missing relayer role,
     *      bridge inactive) keeps the queue.
     * @return count Number of settlements the bridge applied (skipped settlements are not counted)
     */
    function processSettlementBatch() external onlyAuthorizedSubmitter nonReentrant returns (uint256 count) {
        uint256 len = _pendingSettlements.length;
        if (len == 0) revert BatchEmpty();

        // Never relay a batch queued by a sequencer that has since been replaced
        address current = l3Bridge.getSequencerConfig().sequencerAddress;
        if (settlementBatchSequencer != current) {
            revert SequencerChanged(settlementBatchSequencer, current);
        }

        IL3Bridge.DisputeSettlementMessage[] memory batch = _pendingSettlements;
        uint256 batchId = uint256(keccak256(abi.encode(batch)));

        // Clear batch before the external call
        delete _pendingSettlements;
        settlementBatchSequencer = address(0);

        // Process through bridge
        count = l3Bridge.batchProcessSettlements(batch);
        if (count > len) revert InvalidBatchData();

        emit SettlementBatchProcessed(batchId, count);
    }

    // ============ Batch Status ============

    /**
     * @notice Check if batch should auto-trigger
     * @return True if batch conditions are met
     */
    function _shouldTriggerBatch() internal view returns (bool) {
        uint256 count = _pendingInitiations.length;

        // Trigger if max size reached. Only the queue call that fills the batch gets here (the next one
        // reverts BatchFull), so this makes at most one attempt per fill and needs no backoff.
        if (count >= MAX_BATCH_SIZE) return true;

        // Trigger if min size and max wait exceeded, unless backing off after a failed auto-batch
        if (
            count >= MIN_BATCH_SIZE && block.timestamp >= batchStartTime + MAX_BATCH_WAIT
                && block.timestamp >= autoBatchBackoff.retryAfter
        ) {
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
     * @dev Includes any backoff after a failed auto-batch
     * @return remaining Seconds until trigger (0 if ready or empty)
     */
    function getTimeUntilAutoTrigger() external view returns (uint256 remaining) {
        if (_pendingInitiations.length == 0) return 0;
        if (_pendingInitiations.length >= MAX_BATCH_SIZE) return 0;

        uint256 triggerTime = batchStartTime + MAX_BATCH_WAIT;
        uint256 retryAfter = autoBatchBackoff.retryAfter;
        if (retryAfter > triggerTime) triggerTime = retryAfter;
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
    function getPendingInitiation(uint256 index) external view returns (IL3Bridge.DisputeInitiationMessage memory) {
        require(index < _pendingInitiations.length, "Index out of bounds");
        return _pendingInitiations[index];
    }

    /**
     * @notice Get pending settlement at index
     * @param index The index
     * @return The settlement message
     */
    function getPendingSettlement(uint256 index) external view returns (IL3Bridge.DisputeSettlementMessage memory) {
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
        settlementBatchSequencer = address(0);
        delete autoBatchBackoff;
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
