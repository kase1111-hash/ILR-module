// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/**
 * @title IBatchQueue
 * @notice Interface for privacy-preserving batch transaction queue
 * @dev Buffers transactions and releases them in batches to prevent timing inference
 *
 * Privacy Model:
 * - Users submit transactions to the queue instead of directly to ILRM
 * - Transactions are held until batch release conditions are met
 * - Batch release obscures the original submission timing
 * - Compatible with Chainlink Automation for timed releases
 *
 * Use Cases:
 * - Dispute initiation batching
 * - Stake deposits batching
 * - Evidence submission batching
 * - ZK proof submission batching
 */
interface IBatchQueue {
    // ============ Enums ============

    /// @notice Types of transactions that can be batched
    enum TxType {
        DisputeInitiation,
        StakeDeposit,
        EvidenceSubmission,
        ProposalAcceptance,
        ZKProofSubmission,
        ViewingKeyCommitment
    }

    /// @notice Status of a queued transaction
    enum QueueStatus {
        Pending,      // Waiting in queue
        Released,     // Released in a batch
        Executed,     // Successfully executed on target
        Failed,       // Execution failed
        Expired,      // Expired before release
        Cancelled     // Cancelled by submitter
    }

    // ============ Structs ============

    /// @notice Configuration for batch release
    struct BatchConfig {
        uint256 minBatchSize;      // Minimum transactions before release
        uint256 maxBatchSize;      // Maximum transactions per batch
        uint256 releaseInterval;   // Minimum time between releases (seconds)
        uint256 maxQueueTime;      // Maximum time a tx can stay queued
        bool randomizeOrder;       // Shuffle transactions within batch
        bool allowCancellation;    // Allow users to cancel queued txs
    }

    /// @notice A queued transaction
    struct QueuedTx {
        uint256 id;
        address submitter;
        TxType txType;
        bytes data;              // Encoded transaction data
        uint256 value;           // ETH value (for payable calls)
        uint256 submittedAt;
        uint256 releasedAt;
        uint256 batchId;
        QueueStatus status;
        bytes32 commitmentHash;  // Hash for verification
    }

    /// @notice A batch of transactions
    struct Batch {
        uint256 id;
        uint256 createdAt;
        uint256 releasedAt;
        uint256 txCount;
        uint256[] txIds;
        bool executed;
    }

    // ============ Events ============

    /// @notice Emitted when a transaction is queued
    event TransactionQueued(
        uint256 indexed txId,
        address indexed submitter,
        TxType txType,
        bytes32 commitmentHash
    );

    /// @notice Emitted when a transaction is cancelled
    event TransactionCancelled(
        uint256 indexed txId,
        address indexed submitter
    );

    /// @notice Emitted when a batch is created
    event BatchCreated(
        uint256 indexed batchId,
        uint256 txCount
    );

    /// @notice Emitted when a batch is released
    event BatchReleased(
        uint256 indexed batchId,
        uint256 txCount,
        uint256 timestamp
    );

    /// @notice Emitted when a transaction is executed
    event TransactionExecuted(
        uint256 indexed txId,
        uint256 indexed batchId,
        bool success
    );

    /// @notice Emitted when configuration is updated
    event ConfigUpdated(
        uint256 minBatchSize,
        uint256 maxBatchSize,
        uint256 releaseInterval
    );

    // ============ Queue Functions ============

    /**
     * @notice Queue a dispute initiation transaction
     * @param counterparty The dispute counterparty
     * @param stakeAmount Stake amount
     * @param evidenceHash Evidence hash
     * @param fallbackData Encoded fallback license
     * @return txId The queued transaction ID
     */
    function queueDisputeInitiation(
        address counterparty,
        uint256 stakeAmount,
        bytes32 evidenceHash,
        bytes calldata fallbackData
    ) external returns (uint256 txId);

    /**
     * @notice Queue a stake deposit transaction
     * @param disputeId The dispute to stake into
     * @return txId The queued transaction ID
     */
    function queueStakeDeposit(uint256 disputeId) external returns (uint256 txId);

    /**
     * @notice Queue a proposal acceptance transaction
     * @param disputeId The dispute to accept
     * @return txId The queued transaction ID
     */
    function queueAcceptance(uint256 disputeId) external returns (uint256 txId);

    /**
     * @notice Queue a ZK proof submission
     * @param disputeId The dispute ID
     * @param proofData Encoded proof data
     * @return txId The queued transaction ID
     */
    function queueZKProof(
        uint256 disputeId,
        bytes calldata proofData
    ) external returns (uint256 txId);

    /**
     * @notice Queue a generic transaction
     * @param txType Type of transaction
     * @param data Encoded transaction data
     * @return txId The queued transaction ID
     */
    function queueTransaction(
        TxType txType,
        bytes calldata data
    ) external payable returns (uint256 txId);

    /**
     * @notice Cancel a queued transaction (if allowed)
     * @param txId Transaction ID to cancel
     */
    function cancelTransaction(uint256 txId) external;

    // ============ Batch Functions ============

    /**
     * @notice Check if a batch can be released
     * @return canRelease True if release conditions are met
     * @return pendingCount Number of pending transactions
     */
    function canReleaseBatch() external view returns (bool canRelease, uint256 pendingCount);

    /**
     * @notice Release the current batch
     * @dev Can be called by anyone when conditions are met
     * @return batchId The released batch ID
     * @return txCount Number of transactions in batch
     */
    function releaseBatch() external returns (uint256 batchId, uint256 txCount);

    /**
     * @notice Execute a released batch on the target contract
     * @param batchId The batch to execute
     * @return successCount Number of successful executions
     * @return failCount Number of failed executions
     */
    function executeBatch(uint256 batchId) external returns (
        uint256 successCount,
        uint256 failCount
    );

    /**
     * @notice Chainlink Automation compatible check
     * @return upkeepNeeded True if batch should be released
     * @return performData Encoded batch data
     */
    function checkUpkeep(bytes calldata) external view returns (
        bool upkeepNeeded,
        bytes memory performData
    );

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
     * @notice Get user's pending transactions
     * @param user User address
     * @return txIds Array of transaction IDs
     */
    function getUserPendingTxs(address user) external view returns (uint256[] memory txIds);

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
