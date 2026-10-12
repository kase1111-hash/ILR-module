// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "./IILRM.sol";

/**
 * @title IBatchQueue
 * @notice Interface for the batch transaction queue (delays when actions land on ILRM)
 * @dev Buffers transactions and releases them in batches at interval-based times.
 *
 * Threat model (what batching does and does not hide):
 * - Batching only delays WHEN an action is submitted to ILRM. It hides nothing else.
 * - Every queued transaction is public from the moment it is queued: submitter, type, data and txId
 *   are in storage (getTransaction) and in TransactionQueued, and TransactionExecuted links each txId
 *   to its execution. Neither batching nor the shuffle hides who did what.
 * - The optional in-batch shuffle is cosmetic and predictable: its seed is public and the releaser
 *   influences batch composition. No safety or privacy property depends on it.
 * - Relayed types (DisputeInitiation, StakeDeposit, ProposalAcceptance) always act for the account
 *   that queued them: only their typed queue functions create them, binding the party to msg.sender,
 *   and execution names tx.submitter, never a party read from calldata. queueTransaction accepts only
 *   record-only types, which are never sent to ILRM.
 * - Relaying is off (relayEnabled == false) until ILRM ships the relay entry points in IILRMRelay;
 *   the current ILRM has none, so a relayed transaction cannot succeed against it.
 *
 * Escrow model:
 * - Each transaction's token escrow is tracked per txId. Release and execution never transfer tokens
 *   to users, so no queued transaction can block another one; the queue never holds ETH.
 * - Every escrow has an exit that needs neither the keeper nor ILRM and works while paused:
 *   cancelTransaction while pending, or reclaim() maxQueueTime after queueing or release.
 *
 * Use Cases:
 * - Dispute initiation batching
 * - Stake deposits batching
 * - Evidence submission batching
 * - ZK proof submission batching
 */
interface IBatchQueue {
    // ============ Enums ============

    /// @notice Types of transactions that can be batched (order is part of the ABI)
    /// @dev RELAYED types are created only by their typed queue functions and are relayed to ILRM for
    ///      the submitter. RECORD-ONLY types are never decoded and never executed: they only occupy a
    ///      batch slot and end with status Failed when their batch executes.
    enum TxType {
        DisputeInitiation, // RELAYED: initiateBreachDisputeFor (queueDisputeInitiation only)
        StakeDeposit, // RELAYED: depositStakeFor (queueStakeDeposit only)
        EvidenceSubmission, // RECORD-ONLY
        ProposalAcceptance, // RELAYED: acceptProposalFor (queueAcceptance only)
        ZKProofSubmission, // RECORD-ONLY
        ViewingKeyCommitment // RECORD-ONLY
    }

    /// @notice Status of a queued transaction
    enum QueueStatus {
        Pending, // Waiting in queue
        Released, // Released in a batch
        Executed, // Successfully relayed to ILRM
        Failed, // Relay failed, relaying was off, or record-only type (nothing to execute)
        Expired, // Not released within maxQueueTime, or Released but not executed within maxQueueTime
        Cancelled // Cancelled by submitter
    }

    // ============ Structs ============

    /// @notice Configuration for batch release
    struct BatchConfig {
        uint256 minBatchSize; // Minimum transactions before release
        uint256 maxBatchSize; // Maximum transactions per batch
        uint256 releaseInterval; // Minimum time between releases (seconds)
        uint256 maxQueueTime; // Maximum time a tx can stay queued (and stay released but unexecuted)
        bool randomizeOrder; // Shuffle transactions within batch (cosmetic and predictable, see threat model)
        bool allowCancellation; // Allow users to cancel queued txs
    }

    /// @notice A queued transaction
    struct QueuedTx {
        uint256 id;
        address submitter;
        TxType txType;
        bytes data; // Canonical encoding, written by the queue functions
        uint256 value; // Always 0: the queue does not accept ETH
        uint256 submittedAt;
        uint256 releasedAt;
        uint256 batchId;
        QueueStatus status;
        bytes32 commitmentHash; // Hash for verification
    }

    /// @notice A batch of transactions
    struct Batch {
        uint256 id;
        uint256 createdAt;
        uint256 releasedAt;
        uint256 txCount;
        uint256[] txIds;
        bool executed; // True once every transaction in the batch has been processed
    }

    // ============ Events ============

    /// @notice Emitted when a transaction is queued
    event TransactionQueued(uint256 indexed txId, address indexed submitter, TxType txType, bytes32 commitmentHash);

    /// @notice Emitted when a transaction is cancelled
    event TransactionCancelled(uint256 indexed txId, address indexed submitter);

    /// @notice Emitted when a transaction expires (not released, or not executed, within maxQueueTime)
    event TransactionExpired(uint256 indexed txId, address indexed submitter);

    /// @notice Emitted when a transaction's remaining escrow is returned to its submitter
    event EscrowReturned(uint256 indexed txId, address indexed submitter, uint256 amount);

    /// @notice Emitted when a batch is created
    event BatchCreated(uint256 indexed batchId, uint256 txCount);

    /// @notice Emitted when a batch is released
    event BatchReleased(uint256 indexed batchId, uint256 txCount, uint256 timestamp);

    /// @notice Emitted when a transaction is executed
    event TransactionExecuted(uint256 indexed txId, uint256 indexed batchId, bool success);

    /// @notice Emitted after each executeBatch call; complete is true once the whole batch is processed
    event BatchExecuted(uint256 indexed batchId, uint256 successCount, uint256 failCount, bool complete);

    /// @notice Emitted when the owner turns relaying to ILRM on or off
    event RelayEnabledUpdated(bool enabled);

    /// @notice Emitted when configuration is updated
    event ConfigUpdated(
        uint256 minBatchSize,
        uint256 maxBatchSize,
        uint256 releaseInterval,
        uint256 maxQueueTime,
        bool allowCancellation,
        bool randomizeOrder
    );

    // ============ Queue Functions ============

    /**
     * @notice Queue a dispute initiation transaction (relayed; requires relaying enabled)
     * @dev Escrows exactly stakeAmount from the caller. The caller is the initiator.
     * @param counterparty The dispute counterparty
     * @param stakeAmount Stake amount
     * @param evidenceHash Evidence hash
     * @param fallbackData abi.encode(IILRM.FallbackLicense); must be non-exclusive
     * @return txId The queued transaction ID
     */
    function queueDisputeInitiation(
        address counterparty,
        uint256 stakeAmount,
        bytes32 evidenceHash,
        bytes calldata fallbackData
    ) external returns (uint256 txId);

    /**
     * @notice Queue a stake deposit transaction (relayed; requires relaying enabled)
     * @dev The caller is the depositor
     * @param disputeId The dispute to stake into
     * @return txId The queued transaction ID
     */
    function queueStakeDeposit(uint256 disputeId) external returns (uint256 txId);

    /**
     * @notice Queue acceptance of a specific proposal (relayed; requires relaying enabled)
     * @dev The caller must be a party. The acceptance is bound to proposalHash and to the dispute's
     *      current counter-proposal round: if either has changed by execution time it is not relayed.
     * @param disputeId The dispute to accept
     * @param proposalHash keccak256 of the proposal text being accepted (must be the live proposal)
     * @return txId The queued transaction ID
     */
    function queueAcceptance(uint256 disputeId, bytes32 proposalHash) external returns (uint256 txId);

    /**
     * @notice Queue a ZK proof submission (record-only)
     * @param disputeId The dispute ID
     * @param proofData Encoded proof data
     * @return txId The queued transaction ID
     */
    function queueZKProof(uint256 disputeId, bytes calldata proofData) external returns (uint256 txId);

    /**
     * @notice Queue a record-only transaction (EvidenceSubmission, ZKProofSubmission, ViewingKeyCommitment)
     * @dev Non-payable. Reverts for relayed types, which must use their typed queue functions. The data
     *      is stored as given and is never decoded or sent to ILRM.
     * @param txType Type of transaction
     * @param data Encoded transaction data
     * @return txId The queued transaction ID
     */
    function queueTransaction(TxType txType, bytes calldata data) external returns (uint256 txId);

    /**
     * @notice Cancel a pending transaction (if allowed) and return its escrow
     * @param txId Transaction ID to cancel
     */
    function cancelTransaction(uint256 txId) external;

    /**
     * @notice Return a transaction's escrow to its submitter once the transaction can no longer execute
     * @dev Callable by anyone, never paused; always pays the submitter. Expires a transaction first if
     *      it is still pending, or released but unexecuted, more than maxQueueTime after it was queued
     *      or released. Reverts if there is nothing to return.
     * @param txId Transaction ID
     * @return amount Escrow returned
     */
    function reclaim(uint256 txId) external returns (uint256 amount);

    // ============ Batch Functions ============

    /**
     * @notice Check if a batch can be released
     * @return canRelease True if release conditions are met
     * @return pendingCount Number of pending transactions
     */
    function canReleaseBatch() external view returns (bool canRelease, uint256 pendingCount);

    /**
     * @notice Release the current batch
     * @dev Can be called by anyone when conditions are met. Scans at most MAX_LOOP_ITERATIONS queue
     *      entries from the queue head, expiring stale ones, and makes no external call or transfer.
     *      Returns txCount 0, and creates no batch, when the scanned window held only stale or finished
     *      entries (the release interval is then not consumed).
     * @return batchId The released batch ID
     * @return txCount Number of transactions in batch
     */
    function releaseBatch() external returns (uint256 batchId, uint256 txCount);

    /**
     * @notice Execute a released batch on the target contract
     * @dev Resumable. Processes transactions in order from the batch cursor and stops, rather than
     *      under-funding a relay, before any transaction that would call ILRM without MIN_GAS_PER_TX gas
     *      left; call again to continue. A relay never fails for lack of caller gas. Record-only
     *      transactions make no external call and need no gas reserve. Never transfers to users.
     * @param batchId The batch to execute
     * @return successCount Number of successful executions in this call
     * @return failCount Number of failed executions in this call
     */
    function executeBatch(uint256 batchId) external returns (uint256 successCount, uint256 failCount);

    /**
     * @notice Chainlink Automation compatible check
     * @return upkeepNeeded True if batch should be released
     * @return performData Encoded batch data
     */
    function checkUpkeep(bytes calldata) external view returns (bool upkeepNeeded, bytes memory performData);

    /**
     * @notice Chainlink Automation compatible perform
     * @param performData Data from checkUpkeep
     */
    function performUpkeep(bytes calldata performData) external;

    // ============ View Functions ============

    /**
     * @notice Get queue configuration
     * @return config The current configuration
     */
    function getConfig() external view returns (BatchConfig memory config);

    /**
     * @notice Get a queued transaction
     * @param txId Transaction ID
     * @return tx The transaction details
     */
    function getTransaction(uint256 txId) external view returns (QueuedTx memory);

    /**
     * @notice Get a batch
     * @param batchId Batch ID
     * @return batch The batch details
     */
    function getBatch(uint256 batchId) external view returns (Batch memory batch);

    /**
     * @notice Get pending transaction count
     * @return count Number of pending transactions
     */
    function getPendingCount() external view returns (uint256 count);

    /**
     * @notice Get every transaction a user has queued (any status)
     * @param user User address
     * @return txIds Array of transaction IDs
     */
    function getUserPendingTxs(address user) external view returns (uint256[] memory txIds);

    /**
     * @notice Token escrow still held for a transaction
     * @param txId Transaction ID
     * @return amount Escrowed amount
     */
    function escrowOf(uint256 txId) external view returns (uint256 amount);

    /**
     * @notice Get time until next possible release
     * @return timeRemaining Seconds until release is possible
     */
    function getTimeToNextRelease() external view returns (uint256 timeRemaining);

    /**
     * @notice Get total transaction count
     * @return count Total transactions ever queued
     */
    function getTotalTxCount() external view returns (uint256 count);

    /**
     * @notice Get total batch count
     * @return count Total batches ever created
     */
    function getTotalBatchCount() external view returns (uint256 count);
}

/**
 * @title IILRMRelay
 * @notice Relayed ILRM entry points BatchQueue calls, with the acting party named explicitly.
 * @dev The current ILRM implements none of these, so every relay fails against it and BatchQueue ships
 *      with relaying disabled. Any future implementation MUST accept these calls only from the
 *      BatchQueue (msg.sender == the configured BatchQueue): BatchQueue guarantees the named party is
 *      the account that queued the transaction and that a relayed initiation can pull only that
 *      transaction's escrow, but any other caller could name an arbitrary party.
 */
interface IILRMRelay {
    function initiateBreachDisputeFor(
        address initiator,
        address counterparty,
        uint256 stakeAmount,
        bytes32 evidenceHash,
        IILRM.FallbackLicense calldata fallbackLicense
    ) external returns (uint256 disputeId);

    function depositStakeFor(uint256 disputeId, address depositor) external;

    function acceptProposalFor(uint256 disputeId, address acceptor) external;
}
