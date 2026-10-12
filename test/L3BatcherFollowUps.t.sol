// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "./L3TestBase.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title L3BatcherFollowUpsTest
 * @notice Batcher follow-ups:
 *         - the failed-auto-batch backoff is reset by setL3Bridge, setAutoBatchEnabled and the owner-only
 *           resetAutoBatchBackoff (for fixes on the bridge the batcher cannot observe)
 *         - processSettlementBatch keeps settlements that only wait for their stateProof root to finalize,
 *           and drops the permanently invalid ones
 *         - the bridge reports the first failing check of a settlement that fails several (batch path)
 */
contract L3BatcherFollowUpsTest is L3TestBase {
    L3DisputeBatcher public batcher;

    address internal ilrm = makeAddr("ilrm");
    address internal outsider = makeAddr("outsider");
    address internal challenger = makeAddr("challenger");

    uint256 internal constant BOND = 0.1 ether;
    uint256 internal constant MAX_RETRY_DELAY = 1 days;

    // Re-declared L3DisputeBatcher events (solc 0.8.20 has no qualified emit)
    event AutoBatchBackoffReset(uint256 consecutiveFailures);
    event SettlementDeferred(uint256 indexed l2DisputeId, uint256 indexed l3DisputeId, bytes32 indexed stateProof);

    function setUp() public {
        _deployBridge(ilrm);
        batcher = new L3DisputeBatcher(address(l3Bridge), ilrm);
        // Settlement relaying works; dispute bridging is NOT granted, so every auto-batch fails
        l3Bridge.setSettlementRelayer(address(batcher), true);
        vm.deal(challenger, 10 ether);
    }

    // ============ Helpers: dispute batching ============

    function _queueRange(uint256 firstId, uint256 count) internal {
        for (uint256 i = 0; i < count; i++) {
            batcher.queueDisputeInitiation(_initiation(firstId + i));
        }
    }

    function _backoff() internal view returns (uint256 retryAfter, uint256 delay, uint256 failures) {
        (uint64 r, uint64 d, uint64 f) = batcher.autoBatchBackoff();
        return (r, d, f);
    }

    function _assertNoBackoff() internal view {
        (uint256 r, uint256 d, uint256 f) = _backoff();
        assertEq(r, 0, "retryAfter not reset");
        assertEq(d, 0, "delay not reset");
        assertEq(f, 0, "failures not reset");
    }

    /// @notice Fail the time-triggered auto-batch until the backoff reaches its 1-day cap
    /// @return nextId The next unused L2 dispute ID
    /// @return failures Consecutive failures recorded
    function _backOffToCap() internal returns (uint256 nextId, uint256 failures) {
        _queueRange(1, 5);
        vm.warp(block.timestamp + batcher.MAX_BATCH_WAIT());
        nextId = 6;
        uint256 delay;
        while (delay < MAX_RETRY_DELAY) {
            batcher.queueDisputeInitiation(_initiation(nextId++));
            uint256 retryAfter;
            (retryAfter, delay, failures) = _backoff();
            if (delay < MAX_RETRY_DELAY) vm.warp(retryAfter);
        }
        assertEq(batcher.getPendingInitiationsCount(), nextId - 1, "auto-batch should have failed");
        assertEq(batcher.getTimeUntilAutoTrigger(), MAX_RETRY_DELAY, "time trigger off for a day");
    }

    /// @notice Queue one more dispute and assert that the (overdue) time trigger flushed the whole queue
    function _assertNextQueueCallFlushes(L3Bridge bridge, uint256 nextId) internal {
        assertEq(batcher.getTimeUntilAutoTrigger(), 0, "time trigger still backed off");
        batcher.queueDisputeInitiation(_initiation(nextId));
        assertEq(batcher.getPendingInitiationsCount(), 0, "queue not flushed by the time trigger");
        assertEq(bridge.getTotalBridgedDisputes(), nextId);
        _assertNoBackoff();
    }

    // ============ Helpers: settlements ============

    function _bridge(uint256 l2DisputeId) internal returns (uint256 l3DisputeId) {
        IL3Bridge.DisputeInitiationMessage memory message = _initiation(l2DisputeId);
        vm.prank(ilrm);
        l3DisputeId = l3Bridge.bridgeDisputeToL3(message);
    }

    /// @notice Settlement for a bridged dispute with its real L3 ID (makes a call: never use after vm.prank)
    function _valid(uint256 l2DisputeId, bytes32 stateProof)
        internal
        view
        returns (IL3Bridge.DisputeSettlementMessage memory)
    {
        return _settlementMsg(l2DisputeId, l3Bridge.getL3DisputeId(l2DisputeId), stateProof);
    }

    function _queueSettlement(IL3Bridge.DisputeSettlementMessage memory message) internal {
        vm.prank(sequencer);
        batcher.queueSettlement(message);
    }

    function _finalize(bytes32 root) internal {
        vm.warp(l3Bridge.getChallengeDeadline(root));
        l3Bridge.finalizeStateCommitment(root);
        assertTrue(l3Bridge.isStateFinalized(root));
    }

    /// @notice Reject a canonical root with a (valid) commit-reveal fraud proof
    function _reject(bytes32 root, IL3Bridge.FraudProof memory proof) internal {
        bytes32 salt = keccak256(abi.encode("salt", root));
        bytes32 commitHash = _commitHash(challenger, proof, salt);
        vm.prank(challenger);
        l3Bridge.commitFraudProof{value: BOND}(commitHash, root);
        vm.warp(block.timestamp + l3Bridge.MIN_REVEAL_DELAY());
        vm.prank(challenger);
        l3Bridge.revealFraudProof(proof, salt);
        assertEq(l3Bridge.getActiveChallenger(root), challenger);
        assertFalse(l3Bridge.isStateCanonical(root));
    }

    function _expectSkipped(IL3Bridge.DisputeSettlementMessage memory m, IL3Bridge.SettlementSkipReason reason)
        internal
    {
        vm.expectEmit(address(l3Bridge));
        emit SettlementSkipped(m.l2DisputeId, m.l3DisputeId, reason);
    }

    function _expectDeferred(IL3Bridge.DisputeSettlementMessage memory m) internal {
        vm.expectEmit(address(batcher));
        emit SettlementDeferred(m.l2DisputeId, m.l3DisputeId, m.stateProof);
    }

    function _assertQueued(uint256 index, IL3Bridge.DisputeSettlementMessage memory m) internal view {
        assertEq(keccak256(abi.encode(batcher.getPendingSettlement(index))), keccak256(abi.encode(m)));
    }

    // ============ (1) Backoff reset ============

    /// @notice Regression: setL3Bridge kept the backoff, so the time trigger stayed off for up to a day
    function test_SetL3BridgeResetsBackoff() public {
        (uint256 nextId, uint256 failures) = _backOffToCap();

        // The owner moves the batcher to a bridge it is authorized on
        L3Bridge newBridge = new L3Bridge(ilrm);
        newBridge.setDisputeBridger(address(batcher), true);
        vm.expectEmit(address(batcher));
        emit AutoBatchBackoffReset(failures);
        batcher.setL3Bridge(address(newBridge));
        _assertNoBackoff();

        // The very next queue call fires the overdue time trigger
        _assertNextQueueCallFlushes(newBridge, nextId);
        assertEq(l3Bridge.getTotalBridgedDisputes(), 0);
    }

    function test_SetAutoBatchEnabledResetsBackoff() public {
        (uint256 nextId, uint256 failures) = _backOffToCap();
        l3Bridge.setDisputeBridger(address(batcher), true);

        // Disabling and re-enabling auto-batching after the fix starts it afresh
        vm.expectEmit(address(batcher));
        emit AutoBatchBackoffReset(failures);
        batcher.setAutoBatchEnabled(false);
        _assertNoBackoff();
        batcher.setAutoBatchEnabled(true);

        _assertNextQueueCallFlushes(l3Bridge, nextId);
    }

    function test_SetAutoBatchEnabledAloneResetsBackoff() public {
        (uint256 nextId,) = _backOffToCap();
        l3Bridge.setDisputeBridger(address(batcher), true);

        // Re-asserting the current setting is enough
        batcher.setAutoBatchEnabled(true);
        _assertNextQueueCallFlushes(l3Bridge, nextId);
    }

    /// @notice A fix on the bridge (setDisputeBridger) is invisible to the batcher; the owner resets the backoff
    function test_OwnerResetAfterBridgeSideFix() public {
        (uint256 nextId, uint256 failures) = _backOffToCap();

        // The bridge owner grants the role, but the batcher keeps backing off
        l3Bridge.setDisputeBridger(address(batcher), true);
        batcher.queueDisputeInitiation(_initiation(nextId++));
        assertEq(batcher.getPendingInitiationsCount(), nextId - 1, "retried during the backoff");
        (,, uint256 stillFailing) = _backoff();
        assertEq(stillFailing, failures);

        vm.expectEmit(address(batcher));
        emit AutoBatchBackoffReset(failures);
        batcher.resetAutoBatchBackoff();
        _assertNoBackoff();

        _assertNextQueueCallFlushes(l3Bridge, nextId);
    }

    function test_ResetAutoBatchBackoffOnlyOwner() public {
        _backOffToCap();
        (uint256 retryAfter, uint256 delay, uint256 failures) = _backoff();

        // Not even an authorized submitter can lift the backoff
        batcher.setAuthorizedSubmitter(outsider, true);
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        batcher.resetAutoBatchBackoff();

        (uint256 r, uint256 d, uint256 f) = _backoff();
        assertEq(r, retryAfter);
        assertEq(d, delay);
        assertEq(f, failures);
    }

    function test_ResetWithoutBackoffIsNoOp() public {
        vm.recordLogs();
        batcher.resetAutoBatchBackoff();
        batcher.setAutoBatchEnabled(true);
        batcher.setL3Bridge(address(l3Bridge));
        assertEq(vm.getRecordedLogs().length, 0, "reset event without a backoff");
        _assertNoBackoff();
    }

    function test_ManualSuccessEmitsBackoffReset() public {
        _queueRange(1, 5);
        vm.warp(block.timestamp + batcher.MAX_BATCH_WAIT());
        batcher.queueDisputeInitiation(_initiation(6)); // fails once
        l3Bridge.setDisputeBridger(address(batcher), true);

        vm.expectEmit(address(batcher));
        emit AutoBatchBackoffReset(1);
        batcher.submitInitiationBatch();
        _assertNoBackoff();
    }

    // ============ (2) Settlements awaiting finalization stay queued ============

    /// @notice Regression: an early relay (by any authorized submitter) dropped settlements whose root was not
    ///         finalized yet, so they were lost
    function test_EarlyRelayKeepsSettlementsAwaitingFinalization() public {
        for (uint256 id = 1; id <= 3; id++) {
            _bridge(id);
        }
        bytes32 root = keccak256("root_1");
        _submitOnHead(root);

        IL3Bridge.DisputeSettlementMessage memory s1 = _valid(1, root);
        IL3Bridge.DisputeSettlementMessage memory s2 = _valid(2, bytes32(0));
        IL3Bridge.DisputeSettlementMessage memory s3 = _valid(3, root);
        _queueSettlement(s1);
        _queueSettlement(s2);
        _queueSettlement(s3);

        // Any authorized submitter may relay before the root finalizes
        address relayerBot = makeAddr("relayerBot");
        batcher.setAuthorizedSubmitter(relayerBot, true);
        IL3Bridge.DisputeSettlementMessage[] memory relayed = new IL3Bridge.DisputeSettlementMessage[](1);
        relayed[0] = s2;
        _expectDeferred(s1);
        _expectDeferred(s3);
        vm.expectEmit(address(batcher));
        emit SettlementBatchProcessed(uint256(keccak256(abi.encode(relayed))), 1);
        vm.prank(relayerBot);
        assertEq(batcher.processSettlementBatch(), 1);

        assertTrue(l3Bridge.isDisputeSettled(2));
        assertFalse(l3Bridge.isDisputeSettled(1));
        assertFalse(l3Bridge.isDisputeSettled(3));
        assertEq(batcher.getPendingSettlementsCount(), 2, "settlements awaiting finalization were dropped");
        _assertQueued(0, s1);
        _assertQueued(1, s3);
        assertEq(batcher.settlementBatchSequencer(), sequencer);

        // Nothing is relayable until the root finalizes
        vm.prank(relayerBot);
        vm.expectRevert(L3DisputeBatcher.BatchNotReady.selector);
        batcher.processSettlementBatch();

        // New settlements queue behind the kept ones
        _bridge(4);
        IL3Bridge.DisputeSettlementMessage memory s4 = _valid(4, bytes32(0));
        vm.prank(sequencer);
        assertEq(batcher.queueSettlement(s4), 2);

        // Once the root finalizes, the kept settlements go through
        _finalize(root);
        vm.prank(relayerBot);
        assertEq(batcher.processSettlementBatch(), 3);
        for (uint256 id = 1; id <= 4; id++) {
            assertTrue(l3Bridge.isDisputeSettled(id));
        }
        assertEq(batcher.getPendingSettlementsCount(), 0);
        assertEq(batcher.settlementBatchSequencer(), address(0));
        assertEq(l3Bridge.getPendingSettlementsCount(), 0);
    }

    /// @notice Settlements that can never apply leave the queue, whatever their root
    function test_RelayDropsPermanentlyInvalidSettlements() public {
        for (uint256 id = 1; id <= 6; id++) {
            _bridge(id);
        }
        vm.prank(sequencer);
        l3Bridge.processSettlementFromL3(_settlementMsg(4, 4, bytes32(0)));

        // A rejected root and its orphaned child, then a pending root on the rolled-back head
        (bytes32 rejected, IL3Bridge.FraudProof memory proof) = _commitFraudulentState("fraudulent state");
        bytes32 orphaned = keccak256("orphaned_child");
        _submitOnHead(orphaned);
        _reject(rejected, proof);
        assertFalse(l3Bridge.isStateCanonical(orphaned));
        bytes32 pending = keccak256("pending_root");
        _submitOnHead(pending);
        assertTrue(l3Bridge.isStateCanonical(pending));
        assertFalse(l3Bridge.isStateFinalized(pending));

        IL3Bridge.DisputeSettlementMessage[] memory q = new IL3Bridge.DisputeSettlementMessage[](8);
        q[0] = _valid(1, keccak256("never_committed")); // root never committed
        q[1] = _valid(2, rejected); // root rejected by a fraud proof
        q[2] = _valid(3, orphaned); // root orphaned by the rejection
        q[3] = _valid(4, pending); // pending root, but already settled
        q[4] = _settlementMsg(5, 99, pending); // pending root, but wrong L3 ID
        q[5] = _settlementMsg(7, 7, pending); // pending root, but never bridged
        q[6] = _settlementMsg(8, 0, pending); // pending root, never bridged, L3 ID 0 (= "no L3 ID")
        q[7] = _valid(6, pending); // waiting for the pending root only
        for (uint256 i = 0; i < q.length; i++) {
            _queueSettlement(q[i]);
        }

        _expectDeferred(q[7]);
        _expectSkipped(q[0], IL3Bridge.SettlementSkipReason.StateRootNotFinalized);
        _expectSkipped(q[1], IL3Bridge.SettlementSkipReason.StateRootNotFinalized);
        _expectSkipped(q[2], IL3Bridge.SettlementSkipReason.StateRootNotFinalized);
        _expectSkipped(q[3], IL3Bridge.SettlementSkipReason.AlreadySettled);
        _expectSkipped(q[4], IL3Bridge.SettlementSkipReason.L3DisputeIdMismatch);
        _expectSkipped(q[5], IL3Bridge.SettlementSkipReason.NotBridged);
        _expectSkipped(q[6], IL3Bridge.SettlementSkipReason.NotBridged);
        assertEq(batcher.processSettlementBatch(), 0);

        assertEq(batcher.getPendingSettlementsCount(), 1);
        _assertQueued(0, q[7]);

        _finalize(pending);
        assertEq(batcher.processSettlementBatch(), 1);
        assertTrue(l3Bridge.isDisputeSettled(6));
        assertEq(batcher.getPendingSettlementsCount(), 0);
    }

    /// @notice A kept settlement is dropped once its root is rejected (it can then never finalize)
    function test_KeptSettlementDroppedWhenRootRejected() public {
        _bridge(1);
        _bridge(2);
        (bytes32 root, IL3Bridge.FraudProof memory proof) = _commitFraudulentState("bad state");
        IL3Bridge.DisputeSettlementMessage memory s1 = _valid(1, root);
        _queueSettlement(s1);
        _queueSettlement(_valid(2, bytes32(0)));

        assertEq(batcher.processSettlementBatch(), 1);
        assertEq(batcher.getPendingSettlementsCount(), 1);

        _reject(root, proof);
        _expectSkipped(s1, IL3Bridge.SettlementSkipReason.StateRootNotFinalized);
        assertEq(batcher.processSettlementBatch(), 0);
        assertEq(batcher.getPendingSettlementsCount(), 0);
        assertEq(batcher.settlementBatchSequencer(), address(0));
        assertFalse(l3Bridge.isDisputeSettled(1));
    }

    /// @notice A kept settlement whose dispute gets settled another way is dropped without waiting for its root
    function test_KeptSettlementDroppedOnceSettledDirectly() public {
        _bridge(1);
        _bridge(2);
        bytes32 root = keccak256("root_1");
        _submitOnHead(root);
        IL3Bridge.DisputeSettlementMessage memory s1 = _valid(1, root);
        _queueSettlement(s1);
        _queueSettlement(_valid(2, bytes32(0)));
        assertEq(batcher.processSettlementBatch(), 1);
        assertEq(batcher.getPendingSettlementsCount(), 1);

        vm.prank(sequencer);
        l3Bridge.processSettlementFromL3(_settlementMsg(1, 1, bytes32(0)));

        _expectSkipped(s1, IL3Bridge.SettlementSkipReason.AlreadySettled);
        assertEq(batcher.processSettlementBatch(), 0);
        assertEq(batcher.getPendingSettlementsCount(), 0);
        assertFalse(l3Bridge.isStateFinalized(root));
    }

    /// @notice Kept settlements belong to the sequencer that queued them: a rotation discards them
    function test_KeptSettlementsDiscardedAfterSequencerRotation() public {
        _bridge(1);
        _bridge(2);
        bytes32 root = keccak256("root_1");
        _submitOnHead(root);
        _queueSettlement(_valid(1, root));
        _queueSettlement(_valid(2, bytes32(0)));
        assertEq(batcher.processSettlementBatch(), 1);

        address oldSequencer = sequencer;
        address newSequencer = makeAddr("newSequencer");
        IL3Bridge.SequencerConfig memory config = l3Bridge.getSequencerConfig();
        config.sequencerAddress = newSequencer;
        l3Bridge.updateSequencerConfig(config);

        vm.expectRevert(abi.encodeWithSelector(L3DisputeBatcher.SequencerChanged.selector, oldSequencer, newSequencer));
        batcher.processSettlementBatch();

        _bridge(3);
        IL3Bridge.DisputeSettlementMessage memory s3 = _valid(3, bytes32(0));
        vm.expectEmit(address(batcher));
        emit StaleSettlementsDiscarded(oldSequencer, 1);
        vm.prank(newSequencer);
        assertEq(batcher.queueSettlement(s3), 0);
    }

    /// @notice A full queue of waiting settlements costs a bounded amount to check and cannot be lost
    function test_FullQueueOfWaitingSettlementsIsBounded() public {
        uint256 maxSize = batcher.MAX_BATCH_SIZE();
        bytes32 root = keccak256("root_1");
        _submitOnHead(root);
        for (uint256 id = 1; id <= maxSize; id++) {
            _bridge(id);
            _queueSettlement(_valid(id, root));
        }
        IL3Bridge.DisputeSettlementMessage memory extra = _valid(1, bytes32(0));
        vm.prank(sequencer);
        vm.expectRevert(L3DisputeBatcher.BatchFull.selector);
        batcher.queueSettlement(extra);

        uint256 gasBefore = gasleft();
        vm.expectRevert(L3DisputeBatcher.BatchNotReady.selector);
        batcher.processSettlementBatch();
        assertLt(gasBefore - gasleft(), 3_000_000, "checking a full queue is not bounded");
        assertEq(batcher.getPendingSettlementsCount(), maxSize);

        _finalize(root);
        assertEq(batcher.processSettlementBatch(), maxSize);
        assertEq(batcher.getPendingSettlementsCount(), 0);
        assertEq(l3Bridge.getTotalSettlements(), maxSize);
    }

    /// @notice The kept settlements are exactly those that only wait for a root that can still finalize (checked
    ///         against the state before the relay); the relayed ones behave as processSettlementFromL3 calls
    function testFuzz_RelayKeepsExactlyTheSettlementsAwaitingFinalization(uint256 seed) public {
        bytes32 finalized = keccak256("finalized_root");
        _submitOnHead(finalized);
        _finalize(finalized);
        (bytes32 rejected, IL3Bridge.FraudProof memory proof) = _commitFraudulentState("fraudulent state");
        _reject(rejected, proof);
        bytes32 pending = keccak256("pending_root");
        _submitOnHead(pending);
        for (uint256 id = 1; id <= 4; id++) {
            assertEq(_bridge(id), id);
        }
        // Dispute 4 is settled before the queue is relayed
        vm.prank(sequencer);
        l3Bridge.processSettlementFromL3(_settlementMsg(4, 4, bytes32(0)));

        // Up to 12 settlements over disputes 1..6 (5 and 6 never bridged), sometimes with a wrong L3 ID, and with
        // a zero, finalized, pending, rejected or never-committed state proof
        uint256 n = bound(seed, 1, 12);
        IL3Bridge.DisputeSettlementMessage[] memory q = new IL3Bridge.DisputeSettlementMessage[](n);
        bool[] memory expectKept = new bool[](n);
        uint256 keptCount;
        for (uint256 i = 0; i < n; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 l2Id = 1 + (r % 6);
            uint256 l3Id = (r >> 8) % 4 == 0 ? l2Id + 1 : l2Id;
            uint256 p = (r >> 16) % 5;
            bytes32 stateProof =
                p == 0 ? bytes32(0) : p == 1 ? finalized : p == 2 ? pending : p == 3 ? rejected : bytes32(r);
            q[i] = _settlementMsg(l2Id, l3Id, stateProof);
            _queueSettlement(q[i]);
            // Model: bridged (1..4) with the right L3 ID (== L2 ID here), not settled before the relay (not 4),
            // and the pending root (the only canonical, unfinalized one)
            expectKept[i] = l2Id <= 3 && l3Id == l2Id && stateProof == pending;
            if (expectKept[i]) keptCount++;
        }

        if (keptCount == n) {
            vm.expectRevert(L3DisputeBatcher.BatchNotReady.selector);
            batcher.processSettlementBatch();
            assertEq(batcher.getPendingSettlementsCount(), n);
            return;
        }

        // Reference: one processSettlementFromL3 call per relayed settlement, in queue order
        uint256 snapshot = vm.snapshotState();
        uint256 expectedApplied;
        for (uint256 i = 0; i < n; i++) {
            if (expectKept[i]) continue;
            vm.prank(sequencer);
            try l3Bridge.processSettlementFromL3(q[i]) {
                expectedApplied++;
            } catch {}
        }
        bool[7] memory settledRef;
        for (uint256 id = 1; id <= 6; id++) {
            settledRef[id] = l3Bridge.isDisputeSettled(id);
        }
        vm.revertToState(snapshot);

        assertEq(batcher.processSettlementBatch(), expectedApplied, "applied count");
        for (uint256 id = 1; id <= 6; id++) {
            assertEq(l3Bridge.isDisputeSettled(id), settledRef[id], "settled state differs from the reference");
        }

        // The queue now holds exactly the kept settlements, in their original order
        assertEq(batcher.getPendingSettlementsCount(), keptCount, "kept count");
        uint256 k;
        for (uint256 i = 0; i < n; i++) {
            if (expectKept[i]) _assertQueued(k++, q[i]);
        }
        assertEq(batcher.settlementBatchSequencer(), keptCount == 0 ? address(0) : sequencer);
    }

    // ============ (3) Skip-reason precedence on the batch path ============

    /// @notice Each settlement fails every check from its reason on, so a reordering of the bridge's checks
    ///         changes the reported reason. (The single path cannot tell L3DisputeIdMismatch from
    ///         AlreadySettled: both revert InvalidSettlement.)
    function _precedenceBatch(bytes32 pending) internal returns (IL3Bridge.DisputeSettlementMessage[] memory b) {
        _bridge(1);
        _bridge(2);
        vm.prank(sequencer);
        l3Bridge.processSettlementFromL3(_settlementMsg(1, 1, bytes32(0)));
        _submitOnHead(pending);

        b = new IL3Bridge.DisputeSettlementMessage[](4);
        b[0] = _settlementMsg(9, 2, pending); // never bridged; L3 ID 2 is not its own; root pending
        b[1] = _settlementMsg(1, 2, pending); // wrong L3 ID; already settled; root pending
        b[2] = _settlementMsg(1, 1, pending); // already settled; root pending
        b[3] = _settlementMsg(2, 2, pending); // root pending only
    }

    function test_BatchReportsFirstFailingCheck() public {
        IL3Bridge.DisputeSettlementMessage[] memory b = _precedenceBatch(keccak256("pending_root"));

        _expectSkipped(b[0], IL3Bridge.SettlementSkipReason.NotBridged);
        _expectSkipped(b[1], IL3Bridge.SettlementSkipReason.L3DisputeIdMismatch);
        _expectSkipped(b[2], IL3Bridge.SettlementSkipReason.AlreadySettled);
        _expectSkipped(b[3], IL3Bridge.SettlementSkipReason.StateRootNotFinalized);
        vm.prank(sequencer);
        assertEq(l3Bridge.batchProcessSettlements(b), 0);

        // The single path collapses the middle two into one error
        for (uint256 i = 1; i <= 2; i++) {
            vm.prank(sequencer);
            vm.expectRevert(abi.encodeWithSelector(IL3Bridge.InvalidSettlement.selector, 1));
            l3Bridge.processSettlementFromL3(b[i]);
        }
    }

    function test_BatcherRelayReportsFirstFailingCheck() public {
        bytes32 pending = keccak256("pending_root");
        IL3Bridge.DisputeSettlementMessage[] memory b = _precedenceBatch(pending);
        for (uint256 i = 0; i < b.length; i++) {
            _queueSettlement(b[i]);
        }

        // The first three fail a permanent check before the root check and are dropped; the last one waits
        _expectDeferred(b[3]);
        _expectSkipped(b[0], IL3Bridge.SettlementSkipReason.NotBridged);
        _expectSkipped(b[1], IL3Bridge.SettlementSkipReason.L3DisputeIdMismatch);
        _expectSkipped(b[2], IL3Bridge.SettlementSkipReason.AlreadySettled);
        assertEq(batcher.processSettlementBatch(), 0);
        assertEq(batcher.getPendingSettlementsCount(), 1);
        _assertQueued(0, b[3]);

        _finalize(pending);
        assertEq(batcher.processSettlementBatch(), 1);
        assertTrue(l3Bridge.isDisputeSettled(2));
    }
}
