// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "./L3TestBase.sol";

/**
 * @notice Bridge stand-in that fails (or misreports) in configurable ways
 */
contract MisbehavingBatchBridge {
    enum Mode {
        Succeed,
        EmptyRevert, // revert with no data
        BurnAllGas, // run out of gas (no revert data)
        ShortIds, // return one L3 ID too few
        LongIds, // return one L3 ID too many
        OverCountSettlements // report more processed settlements than were sent
    }

    Mode public mode;
    address public sequencer;
    mapping(uint256 => uint256) private _sink;

    constructor(address _sequencer) {
        sequencer = _sequencer;
    }

    function setMode(Mode m) external {
        mode = m;
    }

    function getSequencerConfig() external view returns (IL3Bridge.SequencerConfig memory) {
        return IL3Bridge.SequencerConfig({
            sequencerAddress: sequencer,
            commitmentInterval: 100,
            challengePeriod: 7 days,
            minBatchSize: 1,
            maxBatchSize: 100
        });
    }

    function bridgeDisputeBatchToL3(IL3Bridge.DisputeInitiationMessage[] calldata messages)
        external
        returns (uint256[] memory l3DisputeIds)
    {
        if (mode == Mode.EmptyRevert) {
            assembly {
                revert(0, 0)
            }
        }
        if (mode == Mode.BurnAllGas) {
            uint256 i;
            while (gasleft() > 0) {
                _sink[i] = i + 1;
                i++;
            }
        }

        uint256 len = messages.length;
        if (mode == Mode.ShortIds) len -= 1;
        if (mode == Mode.LongIds) len += 1;
        l3DisputeIds = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            l3DisputeIds[i] = i + 1;
        }
    }

    function batchProcessSettlements(IL3Bridge.DisputeSettlementMessage[] calldata messages)
        external
        view
        returns (uint256 processed)
    {
        processed = mode == Mode.OverCountSettlements ? messages.length + 1 : messages.length;
    }
}

/**
 * @title L3BatcherResilienceTest
 * @notice Auto-batch failure backoff, empty-revert / out-of-gas auto-batch failures and the batcher's
 *         sanity checks on what the bridge returns
 */
contract L3BatcherResilienceTest is L3TestBase {
    L3DisputeBatcher public batcher;
    MisbehavingBatchBridge public badBridge;

    address internal ilrm = makeAddr("ilrm");

    uint256 internal constant RETRY_DELAY = 10 minutes;
    uint256 internal constant MAX_RETRY_DELAY = 1 days;

    function setUp() public {
        _deployBridge(ilrm);
        batcher = new L3DisputeBatcher(address(l3Bridge), ilrm);
        badBridge = new MisbehavingBatchBridge(sequencer);
        // The batcher is NOT a dispute bridger yet, so every auto-batch against the real bridge fails
    }

    // ============ Helpers ============

    function _queueRange(uint256 firstId, uint256 count) internal {
        for (uint256 i = 0; i < count; i++) {
            batcher.queueDisputeInitiation(_initiation(firstId + i));
        }
    }

    function _backoff() internal view returns (uint256 retryAfter, uint256 delay, uint256 failures) {
        (uint64 r, uint64 d, uint64 f) = batcher.autoBatchBackoff();
        return (r, d, f);
    }

    function _notAuthorized() internal view returns (bytes memory) {
        return abi.encodeWithSelector(IL3Bridge.NotAuthorizedBridger.selector, address(batcher));
    }

    /// @notice Queue one dispute and return how many auto-batch failures that queue call reported
    function _queueCountingFailures(uint256 l2DisputeId) internal returns (uint256 failed) {
        vm.recordLogs();
        batcher.queueDisputeInitiation(_initiation(l2DisputeId));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(batcher) && logs[i].topics[0] == AutoBatchFailed.selector) failed++;
        }
    }

    // ============ Backoff ============

    function test_TimeTriggerBacksOffAfterFailure() public {
        assertEq(batcher.AUTO_BATCH_RETRY_DELAY(), RETRY_DELAY);
        assertEq(batcher.MAX_AUTO_BATCH_RETRY_DELAY(), MAX_RETRY_DELAY);

        _queueRange(1, 5);
        vm.warp(block.timestamp + batcher.MAX_BATCH_WAIT());

        // First failure: retry in RETRY_DELAY
        vm.expectEmit(address(batcher));
        emit AutoBatchFailed(6, _notAuthorized());
        vm.expectEmit(address(batcher));
        emit AutoBatchDeferred(1, block.timestamp + RETRY_DELAY);
        batcher.queueDisputeInitiation(_initiation(6));

        (uint256 retryAfter, uint256 delay, uint256 failures) = _backoff();
        assertEq(retryAfter, block.timestamp + RETRY_DELAY);
        assertEq(delay, RETRY_DELAY);
        assertEq(failures, 1);
        assertEq(batcher.getTimeUntilAutoTrigger(), RETRY_DELAY);

        // No retry before retryAfter: the queue calls stay cheap
        assertEq(_queueCountingFailures(7), 0, "retried during the backoff");
        vm.warp(retryAfter - 1);
        assertEq(batcher.getTimeUntilAutoTrigger(), 1);
        uint256 gasBefore = gasleft();
        assertEq(_queueCountingFailures(8), 0, "retried during the backoff");
        assertLt(gasBefore - gasleft(), 300_000, "queue call during backoff paid for a retry");

        // Each consecutive failure doubles the delay, up to the cap
        uint256 expectedDelay = RETRY_DELAY;
        uint256 nextId = 9;
        for (uint256 i = 2; i <= 11; i++) {
            vm.warp(retryAfter);
            expectedDelay = expectedDelay * 2 > MAX_RETRY_DELAY ? MAX_RETRY_DELAY : expectedDelay * 2;
            vm.expectEmit(address(batcher));
            emit AutoBatchDeferred(i, block.timestamp + expectedDelay);
            assertEq(_queueCountingFailures(nextId++), 1, "no retry once the backoff expired");

            (retryAfter, delay, failures) = _backoff();
            assertEq(delay, expectedDelay);
            assertEq(failures, i);
            assertEq(retryAfter, block.timestamp + expectedDelay);
            assertLe(delay, MAX_RETRY_DELAY);
        }
        assertEq(delay, MAX_RETRY_DELAY, "cap reached");

        // Fixing the cause does not retry early (a retry would now succeed and flush the queue)...
        l3Bridge.setDisputeBridger(address(batcher), true);
        vm.warp(retryAfter - 1);
        batcher.queueDisputeInitiation(_initiation(nextId++));
        uint256 queued = batcher.getPendingInitiationsCount();
        assertEq(queued, nextId - 1);
        assertEq(l3Bridge.getTotalBridgedDisputes(), 0);

        // ...but manual submission is never backed off, and a success resets the backoff
        (, uint256 count) = batcher.submitInitiationBatch();
        assertEq(count, queued);
        (retryAfter, delay, failures) = _backoff();
        assertEq(retryAfter, 0);
        assertEq(delay, 0);
        assertEq(failures, 0);

        // A fresh overdue batch triggers immediately again
        _queueRange(100, 5);
        vm.warp(block.timestamp + batcher.MAX_BATCH_WAIT());
        batcher.queueDisputeInitiation(_initiation(105));
        assertEq(batcher.getPendingInitiationsCount(), 0);
        assertEq(l3Bridge.getTotalBridgedDisputes(), queued + 6);
    }

    function test_SuccessfulAutoRetryResetsBackoff() public {
        _queueRange(1, 5);
        vm.warp(block.timestamp + batcher.MAX_BATCH_WAIT());
        batcher.queueDisputeInitiation(_initiation(6));
        (uint256 retryAfter,,) = _backoff();

        l3Bridge.setDisputeBridger(address(batcher), true);
        vm.warp(retryAfter);
        batcher.queueDisputeInitiation(_initiation(7));

        assertEq(batcher.getPendingInitiationsCount(), 0);
        assertEq(l3Bridge.getTotalBridgedDisputes(), 7);
        (uint256 r, uint256 d, uint256 f) = _backoff();
        assertEq(r + d + f, 0, "backoff not reset by a successful auto-batch");
    }

    function test_SizeTriggerIgnoresBackoff() public {
        uint256 maxSize = batcher.MAX_BATCH_SIZE();
        _queueRange(1, 5);
        vm.warp(block.timestamp + batcher.MAX_BATCH_WAIT());
        batcher.queueDisputeInitiation(_initiation(6)); // fails, starts the backoff

        // Fill the queue inside the backoff window, after the cause was fixed
        l3Bridge.setDisputeBridger(address(batcher), true);
        _queueRange(7, maxSize - 7);
        assertEq(batcher.getPendingInitiationsCount(), maxSize - 1);

        // The call that fills the batch always tries once (and now succeeds)
        (uint256 retryAfter,,) = _backoff();
        assertGt(retryAfter, block.timestamp, "still backing off");
        batcher.queueDisputeInitiation(_initiation(maxSize));
        assertEq(batcher.getPendingInitiationsCount(), 0);
        assertEq(l3Bridge.getTotalBridgedDisputes(), maxSize);
        (,, uint256 failures) = _backoff();
        assertEq(failures, 0);
    }

    function test_EmergencyClearAndForceSubmitResetBackoff() public {
        _queueRange(1, 5);
        vm.warp(block.timestamp + batcher.MAX_BATCH_WAIT());
        batcher.queueDisputeInitiation(_initiation(6));
        (,, uint256 failures) = _backoff();
        assertEq(failures, 1);

        batcher.emergencyClearBatches();
        (uint256 r, uint256 d, uint256 f) = _backoff();
        assertEq(r + d + f, 0, "emergencyClearBatches kept the backoff");

        _queueRange(10, 5);
        vm.warp(block.timestamp + batcher.MAX_BATCH_WAIT());
        batcher.queueDisputeInitiation(_initiation(15));
        (,, failures) = _backoff();
        assertEq(failures, 1);

        l3Bridge.setDisputeBridger(address(batcher), true);
        batcher.forceSubmitBatch();
        (r, d, f) = _backoff();
        assertEq(r + d + f, 0, "forceSubmitBatch kept the backoff");
        assertEq(l3Bridge.getTotalBridgedDisputes(), 6);
    }

    function test_FailedManualSubmissionKeepsBackoff() public {
        _queueRange(1, 5);
        vm.warp(block.timestamp + batcher.MAX_BATCH_WAIT());
        batcher.queueDisputeInitiation(_initiation(6));
        (uint256 retryAfter, uint256 delay, uint256 failures) = _backoff();

        // A manual submission that reverts rolls its backoff reset back too
        vm.expectRevert(_notAuthorized());
        batcher.submitInitiationBatch();
        (uint256 r, uint256 d, uint256 f) = _backoff();
        assertEq(r, retryAfter);
        assertEq(d, delay);
        assertEq(f, failures);
    }

    // ============ Failure kinds ============

    function test_AutoBatchEmptyRevertReason() public {
        batcher.setL3Bridge(address(badBridge));
        badBridge.setMode(MisbehavingBatchBridge.Mode.EmptyRevert);

        _queueRange(1, 5);
        vm.warp(block.timestamp + batcher.MAX_BATCH_WAIT());
        vm.expectEmit(address(batcher));
        emit AutoBatchFailed(6, "");
        vm.expectEmit(address(batcher));
        emit AutoBatchDeferred(1, block.timestamp + RETRY_DELAY);
        assertEq(batcher.queueDisputeInitiation(_initiation(6)), 5);
        assertEq(batcher.getPendingInitiationsCount(), 6);
        assertEq(batcher.getPendingInitiation(5).l2DisputeId, 6);

        // Once the bridge recovers, the intact queue is submitted
        badBridge.setMode(MisbehavingBatchBridge.Mode.Succeed);
        (, uint256 count) = batcher.submitInitiationBatch();
        assertEq(count, 6);
    }

    function test_AutoBatchOutOfGasTimeTrigger() public {
        batcher.setL3Bridge(address(badBridge));
        badBridge.setMode(MisbehavingBatchBridge.Mode.BurnAllGas);

        _queueRange(1, 5);
        vm.warp(block.timestamp + batcher.MAX_BATCH_WAIT());

        // The self-call runs out of gas (empty revert data); the queue call keeps 1/64 and still succeeds
        vm.expectEmit(address(batcher));
        emit AutoBatchFailed(6, "");
        vm.expectEmit(address(batcher));
        emit AutoBatchDeferred(1, block.timestamp + RETRY_DELAY);
        uint256 position = batcher.queueDisputeInitiation{gas: 5_000_000}(_initiation(6));
        assertEq(position, 5);
        assertEq(batcher.getPendingInitiationsCount(), 6);

        // During the backoff the next caller does not burn its gas again
        uint256 gasBefore = gasleft();
        batcher.queueDisputeInitiation{gas: 5_000_000}(_initiation(7));
        assertLt(gasBefore - gasleft(), 300_000, "queue call during backoff burned gas on a retry");
        assertEq(batcher.getPendingInitiationsCount(), 7);
    }

    function test_AutoBatchOutOfGasSizeTrigger() public {
        batcher.setL3Bridge(address(badBridge));
        badBridge.setMode(MisbehavingBatchBridge.Mode.BurnAllGas);
        uint256 maxSize = batcher.MAX_BATCH_SIZE();
        _queueRange(1, maxSize - 1);

        vm.expectEmit(address(batcher));
        emit AutoBatchFailed(maxSize, "");
        assertEq(batcher.queueDisputeInitiation{gas: 5_000_000}(_initiation(maxSize)), maxSize - 1);
        assertEq(batcher.getPendingInitiationsCount(), maxSize);

        vm.expectRevert(L3DisputeBatcher.BatchFull.selector);
        batcher.queueDisputeInitiation(_initiation(maxSize + 1));
    }

    // ============ Bridge return-value checks ============

    function test_InvalidBatchDataOnWrongIdCount() public {
        batcher.setL3Bridge(address(badBridge));
        _queueRange(1, 3);

        badBridge.setMode(MisbehavingBatchBridge.Mode.ShortIds);
        vm.expectRevert(L3DisputeBatcher.InvalidBatchData.selector);
        batcher.submitInitiationBatch();
        assertEq(batcher.getPendingInitiationsCount(), 3);

        badBridge.setMode(MisbehavingBatchBridge.Mode.LongIds);
        vm.expectRevert(L3DisputeBatcher.InvalidBatchData.selector);
        batcher.submitInitiationBatch();
        assertEq(batcher.getPendingInitiationsCount(), 3);
        assertEq(batcher.getPendingInitiation(0).l2DisputeId, 1);
        assertEq(batcher.getPendingInitiation(2).l2DisputeId, 3);

        // The auto-batch path reports it as a failure
        _queueRange(4, 2);
        vm.warp(block.timestamp + batcher.MAX_BATCH_WAIT());
        vm.expectEmit(address(batcher));
        emit AutoBatchFailed(6, abi.encodeWithSelector(L3DisputeBatcher.InvalidBatchData.selector));
        batcher.queueDisputeInitiation(_initiation(6));
        assertEq(batcher.getPendingInitiationsCount(), 6);

        badBridge.setMode(MisbehavingBatchBridge.Mode.Succeed);
        (, uint256 count) = batcher.submitInitiationBatch();
        assertEq(count, 6);
    }

    function test_InvalidBatchDataOnSettlementOvercount() public {
        batcher.setL3Bridge(address(badBridge));
        vm.prank(sequencer);
        batcher.queueSettlement(_settlementMsg(1, 1, bytes32(0)));

        badBridge.setMode(MisbehavingBatchBridge.Mode.OverCountSettlements);
        vm.expectRevert(L3DisputeBatcher.InvalidBatchData.selector);
        batcher.processSettlementBatch();
        assertEq(batcher.getPendingSettlementsCount(), 1);
        assertEq(batcher.settlementBatchSequencer(), sequencer);

        badBridge.setMode(MisbehavingBatchBridge.Mode.Succeed);
        assertEq(batcher.processSettlementBatch(), 1);
        assertEq(batcher.getPendingSettlementsCount(), 0);
    }
}
