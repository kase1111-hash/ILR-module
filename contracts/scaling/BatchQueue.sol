// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IBatchQueue.sol";
import "../interfaces/IILRM.sol";

/**
 * @title BatchQueue
 * @notice Batch transaction queue for NatLangChain (delays when actions land on ILRM)
 * @dev See IBatchQueue for the threat model. Summary of the guarantees:
 *      - No queued transaction can make another one revert, fail or get stuck: relayed types are only
 *        created by typed queue functions (well-formed data, party == submitter), release makes no
 *        external call, execution never reverts on queued input and never transfers to users, and the
 *        queue never holds ETH.
 *      - Release cost is independent of queue length (head pointer, at most MAX_LOOP_ITERATIONS entries
 *        scanned); the caller's gas limit cannot decide relay outcomes (execution is resumable).
 *      - A relayed initiation can pull at most its own escrow (exact allowance, reset to 0 after the call).
 *      - A queued acceptance is relayed only while the proposal hash and round it accepted are live.
 *      - Every escrow can be returned via cancelTransaction or reclaim without the keeper or ILRM, even
 *        while paused; emergencyWithdraw can never touch escrow.
 *
 *      Token assumption: `token` is the plain protocol ERC20 (no fee-on-transfer, rebasing or transfer
 *      hooks). A transfer that delivers less than the stake reverts at queue time ("Escrow short").
 *
 *      Slither triage:
 *      - weak-prng (_shuffleArray): not a security boundary (cosmetic order only); suppressed, see there.
 *      - reentrancy-eth (releaseBatch, executeBatch): not exploitable (nonReentrant), but the root cause,
 *        push ETH refunds inside the loops, let one reverting recipient brick release and execution for
 *        everyone. Fixed: the queue holds no ETH and neither loop transfers to users. The remaining
 *        status write after a relay is suppressed (reentrancy-no-eth) with its justification.
 *      - unused-return (performUpkeep): fixed with internal calls; results are in BatchReleased and
 *        BatchExecuted. unused-return (approve): fixed with forceApprove(exact) then forceApprove(0),
 *        and success measured by the balance delta.
 *      Also fixed (not reported by Slither): queueTransaction could queue relayed types naming another
 *      party and funded from pooled escrow; a malformed queued tx made executeBatch revert; release
 *      scanned the whole queue (spam could push it past the block gas limit); acceptances were not bound
 *      to the proposal and round; a low-gas executor could fail relays; emergencyWithdraw could take
 *      escrow; executeBatch was not pausable; escrow was not zeroed after a successful relay; batches
 *      carried trailing zero txIds; the ILRM address was not code-checked.
 *
 * Chainlink Automation Compatible:
 * - Implements checkUpkeep() and performUpkeep() for automated releases. checkUpkeep does not signal a
 *   partially executed batch; anyone can call executeBatch to finish it.
 */
contract BatchQueue is IBatchQueue, Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    /// @notice Minimum release interval (5 minutes)
    uint256 public constant MIN_RELEASE_INTERVAL = 5 minutes;

    /// @notice Maximum queue time (7 days)
    uint256 public constant MAX_QUEUE_TIME = 7 days;

    /// @notice Maximum batch size
    uint256 public constant ABSOLUTE_MAX_BATCH_SIZE = 100;

    /// @notice Maximum queue entries scanned per release (gas bound)
    uint256 public constant MAX_LOOP_ITERATIONS = 500;

    /// @notice Gas forwarded to each ILRM relay call
    uint256 public constant RELAY_GAS_LIMIT = 500_000;

    /// @notice Gas kept back for per-transaction bookkeeping after a relay
    uint256 public constant RELAY_GAS_RESERVE = 60_000;

    /// @notice Gas executeBatch needs left before processing a transaction: two capped ILRM calls (an
    ///         acceptance's binding check and its relay) under the 63/64 rule, plus bookkeeping
    uint256 public constant MIN_GAS_PER_TX = (2 * RELAY_GAS_LIMIT * 64) / 63 + RELAY_GAS_RESERVE;

    // ============ State Variables ============

    /// @notice Target ILRM contract
    address public immutable ilrm;

    /// @notice Staking token
    IERC20 public immutable token;

    /// @notice Whether relayed types may be queued and relayed to ILRM
    bool public relayEnabled;

    /// @notice Sum of all per-transaction escrow (never withdrawable by the owner)
    uint256 public totalEscrowed;

    /// @notice Batch configuration
    BatchConfig private _config;

    /// @notice Transaction counter (txIds are assigned in queue order)
    uint256 private _txCounter;

    /// @notice Batch counter
    uint256 private _batchCounter;

    /// @notice Last batch release time
    uint256 public lastReleaseTime;

    /// @notice All queued transactions: txId => QueuedTx
    mapping(uint256 => QueuedTx) private _transactions;

    /// @notice All batches: batchId => Batch
    mapping(uint256 => Batch) private _batches;

    /// @notice Next index of a batch's txIds to execute
    mapping(uint256 => uint256) private _batchCursor;

    /// @notice Lowest txId that may still be pending (every txId below it is not)
    uint256 private _queueHead;

    /// @notice Number of transactions with status Pending
    uint256 private _pendingCount;

    /// @notice Every txId a user has queued
    mapping(address => uint256[]) private _userPendingTxs;

    /// @notice Escrowed tokens per transaction: txId => amount
    mapping(uint256 => uint256) private _escrowedTokens;

    /// @notice Seed for the cosmetic in-batch shuffle
    uint256 private _randomSeed;

    // ============ Constructor ============

    /**
     * @param _ilrm Target ILRM contract
     * @param _token Staking token
     * @param initialConfig Initial batch configuration
     */
    constructor(address _ilrm, IERC20 _token, BatchConfig memory initialConfig) Ownable(msg.sender) {
        require(_ilrm.code.length > 0, "Invalid ILRM");
        require(address(_token) != address(0), "Invalid token");

        ilrm = _ilrm;
        token = _token;

        _validateAndSetConfig(initialConfig);
        lastReleaseTime = block.timestamp;
        _randomSeed = uint256(keccak256(abi.encodePacked(block.timestamp, block.prevrandao)));
    }

    // ============ Queue Functions ============

    /// @inheritdoc IBatchQueue
    function queueDisputeInitiation(
        address counterparty,
        uint256 stakeAmount,
        bytes32 evidenceHash,
        bytes calldata fallbackData
    ) external override nonReentrant whenNotPaused returns (uint256 txId) {
        require(relayEnabled, "Relay disabled");
        require(counterparty != address(0), "Invalid counterparty");
        require(counterparty != msg.sender, "Cannot dispute self");
        require(stakeAmount > 0, "Zero stake");
        IILRM.FallbackLicense memory fallbackLicense = abi.decode(fallbackData, (IILRM.FallbackLicense));
        require(fallbackLicense.nonExclusive, "Fallback must be non-exclusive");

        txId = _queueTx(TxType.DisputeInitiation, abi.encode(counterparty, stakeAmount, evidenceHash, fallbackLicense));
        _escrowedTokens[txId] = stakeAmount;
        totalEscrowed += stakeAmount;

        // Escrow the full stakeAmount (a fee-on-transfer token would leave the escrow short)
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), stakeAmount);
        require(token.balanceOf(address(this)) - balanceBefore >= stakeAmount, "Escrow short");
    }

    /// @inheritdoc IBatchQueue
    function queueStakeDeposit(uint256 disputeId) external override nonReentrant whenNotPaused returns (uint256 txId) {
        require(relayEnabled, "Relay disabled");
        // The depositor's ILRM allowance is spent at execution; the depositor is always msg.sender
        txId = _queueTx(TxType.StakeDeposit, abi.encode(disputeId, msg.sender));
    }

    /// @inheritdoc IBatchQueue
    function queueAcceptance(uint256 disputeId, bytes32 proposalHash)
        external
        override
        nonReentrant
        whenNotPaused
        returns (uint256 txId)
    {
        require(relayEnabled, "Relay disabled");
        IILRM.Dispute memory d = IILRM(ilrm).disputes(disputeId);
        require(msg.sender == d.initiator || msg.sender == d.counterparty, "Not a party");
        require(!d.resolved, "Dispute resolved");
        require(bytes(d.llmProposal).length > 0, "No proposal yet");
        require(keccak256(bytes(d.llmProposal)) == proposalHash, "Not the live proposal");

        txId = _queueTx(TxType.ProposalAcceptance, abi.encode(disputeId, msg.sender, proposalHash, d.counterCount));
    }

    /// @inheritdoc IBatchQueue
    function queueZKProof(uint256 disputeId, bytes calldata proofData)
        external
        override
        nonReentrant
        whenNotPaused
        returns (uint256 txId)
    {
        txId = _queueTx(TxType.ZKProofSubmission, abi.encode(disputeId, msg.sender, proofData));
    }

    /// @inheritdoc IBatchQueue
    function queueTransaction(TxType txType, bytes calldata data)
        external
        override
        nonReentrant
        whenNotPaused
        returns (uint256 txId)
    {
        // Relayed types act for a party and may move escrow: only their typed functions can create them
        require(!_isRelayed(txType), "Use typed queue function");
        txId = _queueTx(txType, data);
    }

    /// @inheritdoc IBatchQueue
    function cancelTransaction(uint256 txId) external override nonReentrant {
        require(_config.allowCancellation, "Cancellation disabled");

        QueuedTx storage tx_ = _transactions[txId];
        require(tx_.submitter == msg.sender, "Not submitter");
        require(tx_.status == QueueStatus.Pending, "Not pending");

        tx_.status = QueueStatus.Cancelled;
        _pendingCount--;
        emit TransactionCancelled(txId, msg.sender);

        _returnEscrow(txId, tx_.submitter);
    }

    /// @inheritdoc IBatchQueue
    function reclaim(uint256 txId) external override nonReentrant returns (uint256 amount) {
        QueuedTx storage tx_ = _transactions[txId];
        QueueStatus status = tx_.status;

        if (status == QueueStatus.Pending && tx_.submitter != address(0)) {
            require(block.timestamp > tx_.submittedAt + _config.maxQueueTime, "Not expired");
            _expire(txId, tx_);
            _pendingCount--;
        } else if (status == QueueStatus.Released) {
            // Released but its batch never executed it within the execution window
            require(block.timestamp > tx_.releasedAt + _config.maxQueueTime, "Execution window open");
            _expire(txId, tx_);
        }

        amount = _returnEscrow(txId, tx_.submitter);
        require(amount > 0, "Nothing to reclaim");
    }

    // ============ Batch Functions ============

    /// @inheritdoc IBatchQueue
    function canReleaseBatch() public view override returns (bool canRelease, uint256 pendingCount) {
        pendingCount = _pendingCount;

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

    /// @inheritdoc IBatchQueue
    function releaseBatch() external override nonReentrant whenNotPaused returns (uint256 batchId, uint256 txCount) {
        return _releaseBatch();
    }

    /// @inheritdoc IBatchQueue
    function executeBatch(uint256 batchId)
        external
        override
        nonReentrant
        whenNotPaused
        returns (uint256 successCount, uint256 failCount)
    {
        return _executeBatch(batchId);
    }

    /// @inheritdoc IBatchQueue
    function checkUpkeep(bytes calldata) external view override returns (bool upkeepNeeded, bytes memory performData) {
        (upkeepNeeded,) = canReleaseBatch();
        performData = "";
    }

    /// @inheritdoc IBatchQueue
    function performUpkeep(bytes calldata) external override nonReentrant whenNotPaused {
        // Internal calls: results are reported by the BatchReleased / BatchExecuted events
        (uint256 batchId, uint256 txCount) = _releaseBatch();
        if (txCount > 0) {
            _executeBatch(batchId);
        }
    }

    // ============ View Functions ============

    /// @inheritdoc IBatchQueue
    function getConfig() external view override returns (BatchConfig memory) {
        return _config;
    }

    /// @inheritdoc IBatchQueue
    function getTransaction(uint256 txId) external view override returns (QueuedTx memory) {
        return _transactions[txId];
    }

    /// @inheritdoc IBatchQueue
    function getBatch(uint256 batchId) external view override returns (Batch memory) {
        return _batches[batchId];
    }

    /// @inheritdoc IBatchQueue
    function getPendingCount() external view override returns (uint256) {
        return _pendingCount;
    }

    /// @inheritdoc IBatchQueue
    function getUserPendingTxs(address user) external view override returns (uint256[] memory) {
        return _userPendingTxs[user];
    }

    /// @inheritdoc IBatchQueue
    function escrowOf(uint256 txId) external view override returns (uint256) {
        return _escrowedTokens[txId];
    }

    /// @inheritdoc IBatchQueue
    function getTimeToNextRelease() external view override returns (uint256) {
        uint256 nextRelease = lastReleaseTime + _config.releaseInterval;
        if (block.timestamp >= nextRelease) {
            return 0;
        }
        return nextRelease - block.timestamp;
    }

    /// @inheritdoc IBatchQueue
    function getTotalTxCount() external view override returns (uint256) {
        return _txCounter;
    }

    /// @inheritdoc IBatchQueue
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
            newConfig.releaseInterval,
            newConfig.maxQueueTime,
            newConfig.allowCancellation,
            newConfig.randomizeOrder
        );
    }

    /**
     * @notice Turn relaying of DisputeInitiation / StakeDeposit / ProposalAcceptance to ILRM on or off
     * @dev Off by default: the current ILRM has no relayed entry points. Turning it off fails (and makes
     *      reclaimable) relayed transactions that have not executed yet; it can never move escrow.
     * @param enabled Whether relaying is enabled
     */
    function setRelayEnabled(bool enabled) external onlyOwner {
        relayEnabled = enabled;
        emit RelayEnabledUpdated(enabled);
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
     * @notice Withdraw funds that do not belong to any queued transaction
     * @dev Token withdrawals are limited to the surplus above totalEscrowed. The queue never accepts
     *      ETH, so any ETH balance (e.g. force-sent) is surplus.
     * @param to Recipient
     * @param amount Amount to withdraw
     * @param isToken True for token, false for ETH
     */
    function emergencyWithdraw(address to, uint256 amount, bool isToken) external onlyOwner {
        require(to != address(0), "Invalid recipient");

        if (isToken) {
            require(amount <= token.balanceOf(address(this)) - totalEscrowed, "Exceeds surplus");
            token.safeTransfer(to, amount);
        } else {
            (bool success,) = to.call{value: amount}("");
            require(success, "ETH transfer failed");
        }
    }

    // ============ Internal Functions ============

    /**
     * @dev Queue a transaction
     */
    function _queueTx(TxType txType, bytes memory data) internal returns (uint256 txId) {
        txId = _txCounter++;

        bytes32 commitmentHash = keccak256(abi.encodePacked(txId, msg.sender, txType, data, block.timestamp));

        _transactions[txId] = QueuedTx({
            id: txId,
            submitter: msg.sender,
            txType: txType,
            data: data,
            value: 0,
            submittedAt: block.timestamp,
            releasedAt: 0,
            batchId: 0,
            status: QueueStatus.Pending,
            commitmentHash: commitmentHash
        });

        _pendingCount++;
        _userPendingTxs[msg.sender].push(txId);

        emit TransactionQueued(txId, msg.sender, txType, commitmentHash);
    }

    /**
     * @dev Release the oldest live pending transactions (FIFO) into a new batch. Scans at most
     *      MAX_LOOP_ITERATIONS entries from the queue head; never makes an external call.
     */
    function _releaseBatch() internal returns (uint256 batchId, uint256 txCount) {
        (bool canRelease, uint256 pendingCount) = canReleaseBatch();
        require(canRelease, "Cannot release yet");

        uint256 limit = pendingCount > _config.maxBatchSize ? _config.maxBatchSize : pendingCount;
        uint256[] memory txIds = new uint256[](limit);
        batchId = _batchCounter;

        uint256 i = _queueHead;
        uint256 end = _txCounter;
        uint256 scanned = 0;
        for (; i < end && scanned < MAX_LOOP_ITERATIONS && txCount < limit; ++i) {
            ++scanned;
            QueuedTx storage tx_ = _transactions[i];
            if (tx_.status != QueueStatus.Pending) {
                continue;
            }
            _pendingCount--;

            // Stale: expire it (escrow stays attached to the tx and is returned by reclaim)
            if (block.timestamp > tx_.submittedAt + _config.maxQueueTime) {
                _expire(i, tx_);
                continue;
            }

            tx_.status = QueueStatus.Released;
            tx_.releasedAt = block.timestamp;
            tx_.batchId = batchId;
            txIds[txCount++] = i;
        }
        // Every txId below i has now left Pending
        _queueHead = i;

        if (txCount == 0) {
            // Only stale or finished entries in the window: no batch, release interval not consumed
            return (batchId, 0);
        }

        // Trim to the number actually collected (shrinking a memory array's length is memory-safe)
        assembly ("memory-safe") {
            mstore(txIds, txCount)
        }

        if (_config.randomizeOrder && txCount > 1) {
            _shuffleArray(txIds, txCount);
        }

        _batchCounter = batchId + 1;
        lastReleaseTime = block.timestamp;
        _batches[batchId] = Batch({
            id: batchId,
            createdAt: block.timestamp,
            releasedAt: block.timestamp,
            txCount: txCount,
            txIds: txIds,
            executed: false
        });
        _randomSeed = uint256(keccak256(abi.encodePacked(_randomSeed, block.timestamp, batchId)));

        emit BatchCreated(batchId, txCount);
        emit BatchReleased(batchId, txCount, block.timestamp);
    }

    /**
     * @dev Execute a batch from its cursor while each relay can still get RELAY_GAS_LIMIT gas.
     *      Stopping early (instead of failing a relay) means the caller's gas limit can never decide
     *      whether a user's transaction succeeds. The guard applies only to transactions that will call
     *      ILRM: record-only transactions (e.g. generator dummies) make no external call, so a record-only
     *      batch still runs under a small Automation gas limit (running out of gas just reverts the call).
     */
    function _executeBatch(uint256 batchId) internal returns (uint256 successCount, uint256 failCount) {
        Batch storage batch = _batches[batchId];
        uint256 count = batch.txCount;
        require(count > 0, "Invalid batch");
        require(!batch.executed, "Already executed");

        uint256 i = _batchCursor[batchId];
        for (; i < count; ++i) {
            uint256 txId = batch.txIds[i];
            QueuedTx storage tx_ = _transactions[txId];
            if (tx_.status != QueueStatus.Released) {
                continue; // reclaimed after the execution window
            }

            bool relays = relayEnabled && _isRelayed(tx_.txType);
            if (relays && gasleft() < MIN_GAS_PER_TX) {
                break; // resume from here in the next call
            }

            bool success = _executeTx(txId, tx_);
            // reentrancy: status is written after the relay by design (it records the relay's outcome).
            // Every function that reads or writes a transaction's status is nonReentrant, and the only
            // callee is the immutable ILRM.
            // slither-disable-next-line reentrancy-no-eth
            tx_.status = success ? QueueStatus.Executed : QueueStatus.Failed;
            if (success) {
                successCount++;
            } else {
                failCount++;
            }

            emit TransactionExecuted(txId, batchId, success);
        }

        _batchCursor[batchId] = i;
        bool complete = i == count;
        if (complete) {
            batch.executed = true;
        }
        emit BatchExecuted(batchId, successCount, failCount, complete);
    }

    /**
     * @dev Relay one released transaction. Never reverts for any queued input: relayed txs were encoded
     *      by the typed queue functions, and every ILRM call is a gas-capped low-level call.
     */
    function _executeTx(uint256 txId, QueuedTx storage tx_) internal returns (bool) {
        TxType txType = tx_.txType;
        if (!_isRelayed(txType) || !relayEnabled) {
            return false; // record-only, or relaying switched off: nothing is sent to ILRM
        }
        if (txType == TxType.DisputeInitiation) {
            return _executeDisputeInitiation(txId, tx_);
        } else if (txType == TxType.StakeDeposit) {
            return _executeStakeDeposit(tx_);
        }
        return _executeAcceptance(tx_);
    }

    /**
     * @dev Relay a dispute initiation. ILRM gets an allowance of exactly this tx's escrow, reset to zero
     *      afterwards, so it can never pull another transaction's escrow. Succeeds only if ILRM pulled
     *      exactly the stake; anything not pulled stays escrowed for reclaim.
     */
    function _executeDisputeInitiation(uint256 txId, QueuedTx storage tx_) internal returns (bool success) {
        (address counterparty, uint256 stakeAmount, bytes32 evidenceHash, IILRM.FallbackLicense memory fb) =
            abi.decode(tx_.data, (address, uint256, bytes32, IILRM.FallbackLicense));

        uint256 balanceBefore = token.balanceOf(address(this));
        token.forceApprove(ilrm, stakeAmount);
        (bool ok,) = ilrm.call{gas: RELAY_GAS_LIMIT}(
            abi.encodeCall(
                IILRMRelay.initiateBreachDisputeFor, (tx_.submitter, counterparty, stakeAmount, evidenceHash, fb)
            )
        );
        token.forceApprove(ilrm, 0);

        // The allowance caps the pull at stakeAmount; tokens sent in during the call do not count as pulled
        uint256 balanceAfter = token.balanceOf(address(this));
        uint256 pulled = balanceBefore > balanceAfter ? balanceBefore - balanceAfter : 0;
        _escrowedTokens[txId] -= pulled;
        totalEscrowed -= pulled;

        // pulled <= stakeAmount (allowance), so >= means exactly the stake was pulled
        return ok && pulled >= stakeAmount;
    }

    /**
     * @dev Relay a stake deposit for the submitter (never a party named in calldata)
     */
    function _executeStakeDeposit(QueuedTx storage tx_) internal returns (bool success) {
        (uint256 disputeId,) = abi.decode(tx_.data, (uint256, address));
        (success,) =
            ilrm.call{gas: RELAY_GAS_LIMIT}(abi.encodeCall(IILRMRelay.depositStakeFor, (disputeId, tx_.submitter)));
    }

    /**
     * @dev Relay an acceptance only if the proposal and round the submitter accepted are still live.
     *      ILRM voids acceptances whenever the proposal changes (new round or Oracle-owner replacement);
     *      a delayed acceptance must not land on a proposal the submitter never saw.
     */
    function _executeAcceptance(QueuedTx storage tx_) internal returns (bool success) {
        (uint256 disputeId,, bytes32 proposalHash, uint256 round) =
            abi.decode(tx_.data, (uint256, address, bytes32, uint256));

        try IILRM(ilrm).disputes{gas: RELAY_GAS_LIMIT}(disputeId) returns (IILRM.Dispute memory d) {
            if (d.resolved || d.counterCount != round || keccak256(bytes(d.llmProposal)) != proposalHash) {
                return false;
            }
        } catch {
            return false;
        }

        (success,) =
            ilrm.call{gas: RELAY_GAS_LIMIT}(abi.encodeCall(IILRMRelay.acceptProposalFor, (disputeId, tx_.submitter)));
    }

    /**
     * @dev Mark a transaction expired (escrow stays attached until reclaim)
     */
    function _expire(uint256 txId, QueuedTx storage tx_) internal {
        tx_.status = QueueStatus.Expired;
        emit TransactionExpired(txId, tx_.submitter);
    }

    /**
     * @dev Return whatever escrow a finished (cancelled / expired / failed) transaction still holds.
     *      Called only from cancelTransaction and reclaim, never from release or execution.
     */
    function _returnEscrow(uint256 txId, address submitter) internal returns (uint256 amount) {
        QueueStatus status = _transactions[txId].status;
        if (status != QueueStatus.Cancelled && status != QueueStatus.Expired && status != QueueStatus.Failed) {
            return 0;
        }
        amount = _escrowedTokens[txId];
        if (amount > 0) {
            _escrowedTokens[txId] = 0;
            totalEscrowed -= amount;
            emit EscrowReturned(txId, submitter, amount);
            token.safeTransfer(submitter, amount);
        }
    }

    /**
     * @dev Types relayed to ILRM on behalf of the submitter
     */
    function _isRelayed(TxType txType) internal pure returns (bool) {
        return
            txType == TxType.DisputeInitiation || txType == TxType.StakeDeposit || txType == TxType.ProposalAcceptance;
    }

    /**
     * @dev Fisher-Yates shuffle. COSMETIC ONLY, not a security or privacy boundary.
     *      Threat model: the seed is public (derived from block data and the previous seed) and whoever
     *      calls releaseBatch chooses the block and influences batch composition, so anyone can predict
     *      or steer the order. Nothing depends on it: queued data, submitters and the txId -> execution
     *      link are all public anyway (so the order hides nothing), and every relayed tx acts only for
     *      its own submitter on ILRM, which enforces its own state checks (so the order grants nothing).
     *      A VRF or commit-reveal seed would add trust and liveness assumptions for no gain.
     */
    function _shuffleArray(uint256[] memory arr, uint256 length) internal view {
        uint256 seed = _randomSeed;
        for (uint256 i = length - 1; i > 0; --i) {
            seed = uint256(keccak256(abi.encodePacked(seed, i)));
            // Predictable by design: in-batch order is cosmetic and protects nothing (threat model above)
            // slither-disable-next-line weak-prng
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
}
