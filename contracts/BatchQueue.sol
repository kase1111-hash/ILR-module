// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IBatchQueue.sol";

/**
 * @title BatchQueue
 * @notice Privacy-preserving batch transaction queue for NatLangChain
 * @dev Buffers transactions and releases them in batches to prevent timing inference
 *
 * Privacy Features:
 * - Transactions are held until batch release conditions are met
 * - Release timing is deterministic (interval-based) not per-transaction
 * - Optional order randomization within batches
 * - Commitment hashes allow verification without revealing content
 *
 * Chainlink Automation Compatible:
 * - Implements checkUpkeep() and performUpkeep() for automated releases
 * - Can run fully autonomously once configured
 *
 * Security:
 * - Users pre-approve tokens before queuing
 * - Transactions can be cancelled (if enabled)
 * - Expired transactions are automatically cleaned
 */
contract BatchQueue is IBatchQueue, Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    /// @notice Minimum release interval (5 minutes)
    uint256 public constant MIN_RELEASE_INTERVAL = 5 minutes;

    /// @notice Maximum queue time (7 days)
    uint256 public constant MAX_QUEUE_TIME = 7 days;

    /// @notice Maximum batch size
    uint256 public constant ABSOLUTE_MAX_BATCH_SIZE = 100;

    // ============ State Variables ============

    /// @notice Target ILRM contract
    address public immutable ilrm;

    /// @notice Staking token
    IERC20 public immutable token;

    /// @notice Batch configuration
    BatchConfig private _config;

    /// @notice Transaction counter
    uint256 private _txCounter;

    /// @notice Batch counter
    uint256 private _batchCounter;

    /// @notice Last batch release time
    uint256 public lastReleaseTime;

    /// @notice All queued transactions: txId => QueuedTx
    mapping(uint256 => QueuedTx) private _transactions;

    /// @notice All batches: batchId => Batch
    mapping(uint256 => Batch) private _batches;

    /// @notice Pending transaction IDs (FIFO queue)
    uint256[] private _pendingQueue;

    /// @notice User's pending transactions: user => txId[]
    mapping(address => uint256[]) private _userPendingTxs;

    /// @notice Escrowed tokens per transaction: txId => amount
    mapping(uint256 => uint256) private _escrowedTokens;

    /// @notice Escrowed ETH per transaction: txId => amount
    mapping(uint256 => uint256) private _escrowedEth;

    /// @notice Random seed for shuffling (updated each batch)
    uint256 private _randomSeed;

    // ============ Constructor ============

    /**
     * @param _ilrm Target ILRM contract
     * @param _token Staking token
     * @param initialConfig Initial batch configuration
     */
    constructor(
        address _ilrm,
        IERC20 _token,
        BatchConfig memory initialConfig
    ) Ownable(msg.sender) {
        require(_ilrm != address(0), "Invalid ILRM");
        require(address(_token) != address(0), "Invalid token");

        ilrm = _ilrm;
        token = _token;

        _validateAndSetConfig(initialConfig);
        lastReleaseTime = block.timestamp;
        _randomSeed = uint256(keccak256(abi.encodePacked(block.timestamp, block.prevrandao)));
    }

    // ============ Queue Functions ============

    /**
     * @inheritdoc IBatchQueue
     */
    function queueDisputeInitiation(
        address counterparty,
        uint256 stakeAmount,
        bytes32 evidenceHash,
        bytes calldata fallbackData
    ) external override nonReentrant whenNotPaused returns (uint256 txId) {
        require(counterparty != address(0), "Invalid counterparty");
        require(stakeAmount > 0, "Zero stake");

        // Escrow tokens from user
        token.safeTransferFrom(msg.sender, address(this), stakeAmount);

        // Encode transaction data
        bytes memory data = abi.encode(
            counterparty,
            stakeAmount,
            evidenceHash,
            fallbackData
        );

        txId = _queueTx(TxType.DisputeInitiation, data, 0);
        _escrowedTokens[txId] = stakeAmount;
    }

    /**
     * @inheritdoc IBatchQueue
     */
    function queueStakeDeposit(
        uint256 disputeId
    ) external override nonReentrant whenNotPaused returns (uint256 txId) {
        // Note: User must have approved tokens; actual transfer happens at execution
        bytes memory data = abi.encode(disputeId, msg.sender);
        txId = _queueTx(TxType.StakeDeposit, data, 0);
    }

    /**
     * @inheritdoc IBatchQueue
     */
    function queueAcceptance(
        uint256 disputeId
    ) external override nonReentrant whenNotPaused returns (uint256 txId) {
        bytes memory data = abi.encode(disputeId, msg.sender);
        txId = _queueTx(TxType.ProposalAcceptance, data, 0);
    }

    /**
     * @inheritdoc IBatchQueue
     */
    function queueZKProof(
        uint256 disputeId,
        bytes calldata proofData
    ) external override nonReentrant whenNotPaused returns (uint256 txId) {
        bytes memory data = abi.encode(disputeId, msg.sender, proofData);
        txId = _queueTx(TxType.ZKProofSubmission, data, 0);
    }

    /**
     * @inheritdoc IBatchQueue
     */
    function queueTransaction(
        TxType txType,
        bytes calldata data
    ) external payable override nonReentrant whenNotPaused returns (uint256 txId) {
        txId = _queueTx(txType, data, msg.value);
        if (msg.value > 0) {
            _escrowedEth[txId] = msg.value;
        }
    }

    /**
     * @inheritdoc IBatchQueue
     */
    function cancelTransaction(uint256 txId) external override nonReentrant {
        require(_config.allowCancellation, "Cancellation disabled");

        QueuedTx storage tx_ = _transactions[txId];
        require(tx_.submitter == msg.sender, "Not submitter");
        require(tx_.status == QueueStatus.Pending, "Not pending");

        tx_.status = QueueStatus.Cancelled;

        // Refund escrowed assets
        _refundEscrow(txId);

        // Remove from pending queue (leave gap, clean up in batch)
        emit TransactionCancelled(txId, msg.sender);
    }

    // ============ Batch Functions ============

    /**
     * @inheritdoc IBatchQueue
     */
    function canReleaseBatch() public view override returns (bool canRelease, uint256 pendingCount) {
        pendingCount = _getActivePendingCount();

        // Check minimum batch size
        if (pendingCount < _config.minBatchSize) {
            return (false, pendingCount);
        }

        // Check release interval
        if (block.timestamp < lastReleaseTime + _config.releaseInterval) {
            return (false, pendingCount);
        }

        return (true, pendingCount);
    }

    /**
     * @inheritdoc IBatchQueue
     */
    function releaseBatch() external override nonReentrant whenNotPaused returns (
        uint256 batchId,
        uint256 txCount
    ) {
        (bool canRelease, uint256 pendingCount) = canReleaseBatch();
        require(canRelease, "Cannot release yet");

        batchId = _batchCounter++;
        lastReleaseTime = block.timestamp;

        // Determine batch size
        txCount = pendingCount > _config.maxBatchSize ? _config.maxBatchSize : pendingCount;

        // Collect transaction IDs
        uint256[] memory txIds = new uint256[](txCount);
        uint256 collected = 0;

        for (uint256 i = 0; i < _pendingQueue.length && collected < txCount; i++) {
            uint256 txId = _pendingQueue[i];
            QueuedTx storage tx_ = _transactions[txId];

            if (tx_.status != QueueStatus.Pending) {
                continue;
            }

            // Check expiration
            if (block.timestamp > tx_.submittedAt + _config.maxQueueTime) {
                tx_.status = QueueStatus.Expired;
                _refundEscrow(txId);
                continue;
            }

            tx_.status = QueueStatus.Released;
            tx_.releasedAt = block.timestamp;
            tx_.batchId = batchId;

            txIds[collected] = txId;
            collected++;
        }

        // Optionally randomize order
        if (_config.randomizeOrder && collected > 1) {
            _shuffleArray(txIds, collected);
        }

        // Store batch
        _batches[batchId] = Batch({
            id: batchId,
            createdAt: block.timestamp,
            releasedAt: block.timestamp,
            txCount: collected,
            txIds: txIds,
            executed: false
        });

        // Update random seed
        _randomSeed = uint256(keccak256(abi.encodePacked(_randomSeed, block.timestamp, batchId)));

        // Clean up pending queue
        _cleanPendingQueue();

        emit BatchCreated(batchId, collected);
        emit BatchReleased(batchId, collected, block.timestamp);

        return (batchId, collected);
    }

    /**
     * @inheritdoc IBatchQueue
     */
    function executeBatch(uint256 batchId) external override nonReentrant returns (
        uint256 successCount,
        uint256 failCount
    ) {
        Batch storage batch = _batches[batchId];
        require(batch.txCount > 0, "Invalid batch");
        require(!batch.executed, "Already executed");

        batch.executed = true;

        for (uint256 i = 0; i < batch.txCount; i++) {
            uint256 txId = batch.txIds[i];
            QueuedTx storage tx_ = _transactions[txId];

            if (tx_.status != QueueStatus.Released) {
                continue;
            }

            bool success = _executeTx(tx_);

            if (success) {
                tx_.status = QueueStatus.Executed;
                successCount++;
            } else {
                tx_.status = QueueStatus.Failed;
                _refundEscrow(txId);
                failCount++;
            }

            emit TransactionExecuted(txId, batchId, success);
        }
    }

    /**
     * @inheritdoc IBatchQueue
     */
    function checkUpkeep(bytes calldata) external view override returns (
        bool upkeepNeeded,
        bytes memory performData
    ) {
        (upkeepNeeded, ) = canReleaseBatch();
        performData = "";
    }

    /**
     * @inheritdoc IBatchQueue
     */
    function performUpkeep(bytes calldata) external override {
        (uint256 batchId, uint256 txCount) = this.releaseBatch();

        if (txCount > 0) {
            this.executeBatch(batchId);
        }
    }

    // ============ View Functions ============

    /**
     * @inheritdoc IBatchQueue
     */
    function getConfig() external view override returns (BatchConfig memory) {
        return _config;
    }

    /**
     * @inheritdoc IBatchQueue
     */
    function getTransaction(uint256 txId) external view override returns (QueuedTx memory) {
        return _transactions[txId];
    }

    /**
     * @inheritdoc IBatchQueue
     */
    function getBatch(uint256 batchId) external view override returns (Batch memory) {
        return _batches[batchId];
    }

    /**
     * @inheritdoc IBatchQueue
     */
    function getPendingCount() external view override returns (uint256) {
        return _getActivePendingCount();
    }

    /**
     * @inheritdoc IBatchQueue
     */
    function getUserPendingTxs(address user) external view override returns (uint256[] memory) {
        return _userPendingTxs[user];
    }

    /**
     * @inheritdoc IBatchQueue
     */
    function getTimeToNextRelease() external view override returns (uint256) {
        uint256 nextRelease = lastReleaseTime + _config.releaseInterval;
        if (block.timestamp >= nextRelease) {
            return 0;
        }
        return nextRelease - block.timestamp;
    }

    /**
     * @inheritdoc IBatchQueue
     */
    function getTotalTxCount() external view override returns (uint256) {
        return _txCounter;
    }

    /**
     * @inheritdoc IBatchQueue
     */
    function getTotalBatchCount() external view override returns (uint256) {
        return _batchCounter;
    }

    // ============ Admin Functions ============

    /**
     * @notice Update batch configuration
     * @param newConfig New configuration
     */
    function updateConfig(BatchConfig calldata newConfig) external onlyOwner {
        _validateAndSetConfig(newConfig);

        emit ConfigUpdated(
            newConfig.minBatchSize,
            newConfig.maxBatchSize,
            newConfig.releaseInterval
        );
    }

    /**
     * @notice Pause the queue
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause the queue
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Emergency withdraw stuck funds
     * @param to Recipient
     * @param amount Amount to withdraw
     * @param isToken True for token, false for ETH
     */
    function emergencyWithdraw(
        address to,
        uint256 amount,
        bool isToken
    ) external onlyOwner {
        require(to != address(0), "Invalid recipient");

        if (isToken) {
            token.safeTransfer(to, amount);
        } else {
            (bool success, ) = to.call{value: amount}("");
            require(success, "ETH transfer failed");
        }
    }

    // ============ Internal Functions ============

    /**
     * @dev Queue a transaction
     */
    function _queueTx(
        TxType txType,
        bytes memory data,
        uint256 value
    ) internal returns (uint256 txId) {
        txId = _txCounter++;

        bytes32 commitmentHash = keccak256(abi.encodePacked(
            txId,
            msg.sender,
            txType,
            data,
            block.timestamp
        ));

        _transactions[txId] = QueuedTx({
            id: txId,
            submitter: msg.sender,
            txType: txType,
            data: data,
            value: value,
            submittedAt: block.timestamp,
            releasedAt: 0,
            batchId: 0,
            status: QueueStatus.Pending,
            commitmentHash: commitmentHash
        });

        _pendingQueue.push(txId);
        _userPendingTxs[msg.sender].push(txId);

        emit TransactionQueued(txId, msg.sender, txType, commitmentHash);
    }

    /**
     * @dev Execute a transaction on target contract
     */
    function _executeTx(QueuedTx storage tx_) internal returns (bool) {
        if (tx_.txType == TxType.DisputeInitiation) {
            return _executeDisputeInitiation(tx_);
        } else if (tx_.txType == TxType.StakeDeposit) {
            return _executeStakeDeposit(tx_);
        } else if (tx_.txType == TxType.ProposalAcceptance) {
            return _executeAcceptance(tx_);
        }
        // Add more execution paths as needed

        return false;
    }

    /**
     * @dev Execute dispute initiation
     */
    function _executeDisputeInitiation(QueuedTx storage tx_) internal returns (bool) {
        (
            address counterparty,
            uint256 stakeAmount,
            bytes32 evidenceHash,
            bytes memory fallbackData
        ) = abi.decode(tx_.data, (address, uint256, bytes32, bytes));

        // Approve tokens to ILRM
        token.approve(ilrm, stakeAmount);

        // Call ILRM (simplified - actual implementation would use interface)
        (bool success, ) = ilrm.call(
            abi.encodeWithSignature(
                "initiateBreachDisputeFor(address,address,uint256,bytes32,bytes)",
                tx_.submitter,
                counterparty,
                stakeAmount,
                evidenceHash,
                fallbackData
            )
        );

        return success;
    }

    /**
     * @dev Execute stake deposit
     */
    function _executeStakeDeposit(QueuedTx storage tx_) internal returns (bool) {
        (uint256 disputeId, address depositor) = abi.decode(tx_.data, (uint256, address));

        (bool success, ) = ilrm.call(
            abi.encodeWithSignature(
                "depositStakeFor(uint256,address)",
                disputeId,
                depositor
            )
        );

        return success;
    }

    /**
     * @dev Execute proposal acceptance
     */
    function _executeAcceptance(QueuedTx storage tx_) internal returns (bool) {
        (uint256 disputeId, address acceptor) = abi.decode(tx_.data, (uint256, address));

        (bool success, ) = ilrm.call(
            abi.encodeWithSignature(
                "acceptProposalFor(uint256,address)",
                disputeId,
                acceptor
            )
        );

        return success;
    }

    /**
     * @dev Refund escrowed assets for a transaction
     */
    function _refundEscrow(uint256 txId) internal {
        QueuedTx storage tx_ = _transactions[txId];

        uint256 tokenAmount = _escrowedTokens[txId];
        if (tokenAmount > 0) {
            _escrowedTokens[txId] = 0;
            token.safeTransfer(tx_.submitter, tokenAmount);
        }

        uint256 ethAmount = _escrowedEth[txId];
        if (ethAmount > 0) {
            _escrowedEth[txId] = 0;
            (bool success, ) = tx_.submitter.call{value: ethAmount}("");
            require(success, "ETH refund failed");
        }
    }

    /**
     * @dev Get count of active pending transactions
     */
    function _getActivePendingCount() internal view returns (uint256 count) {
        for (uint256 i = 0; i < _pendingQueue.length; i++) {
            QueuedTx storage tx_ = _transactions[_pendingQueue[i]];
            if (tx_.status == QueueStatus.Pending) {
                count++;
            }
        }
    }

    /**
     * @dev Clean up the pending queue (remove processed items)
     */
    function _cleanPendingQueue() internal {
        uint256 writeIndex = 0;
        for (uint256 readIndex = 0; readIndex < _pendingQueue.length; readIndex++) {
            QueuedTx storage tx_ = _transactions[_pendingQueue[readIndex]];
            if (tx_.status == QueueStatus.Pending) {
                if (writeIndex != readIndex) {
                    _pendingQueue[writeIndex] = _pendingQueue[readIndex];
                }
                writeIndex++;
            }
        }

        // Trim array
        while (_pendingQueue.length > writeIndex) {
            _pendingQueue.pop();
        }
    }

    /**
     * @dev Shuffle array using Fisher-Yates
     */
    function _shuffleArray(uint256[] memory arr, uint256 length) internal view {
        uint256 seed = _randomSeed;
        for (uint256 i = length - 1; i > 0; i--) {
            seed = uint256(keccak256(abi.encodePacked(seed, i)));
            uint256 j = seed % (i + 1);
            (arr[i], arr[j]) = (arr[j], arr[i]);
        }
    }

    /**
     * @dev Validate and set configuration
     */
    function _validateAndSetConfig(BatchConfig memory config) internal {
        require(config.minBatchSize > 0, "Min batch size must be > 0");
        require(config.maxBatchSize >= config.minBatchSize, "Max must be >= min");
        require(config.maxBatchSize <= ABSOLUTE_MAX_BATCH_SIZE, "Max batch size exceeded");
        require(config.releaseInterval >= MIN_RELEASE_INTERVAL, "Interval too short");
        require(config.maxQueueTime <= MAX_QUEUE_TIME, "Queue time too long");
        require(config.maxQueueTime > config.releaseInterval, "Queue time must exceed interval");

        _config = config;
    }

    /// @notice Accept ETH
    receive() external payable {}
}
