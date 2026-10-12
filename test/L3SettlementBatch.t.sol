// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "./L3TestBase.sol";

/**
 * @title L3SettlementBatchTest
 * @notice Settlement-queue liveness: batchProcessSettlements skips invalid items (SettlementSkipped) instead of
 *         reverting the batch, while every item gets exactly the checks of processSettlementFromL3
 */
contract L3SettlementBatchTest is L3TestBase {
    L3DisputeBatcher public batcher;

    address internal ilrm = makeAddr("ilrm");

    function setUp() public {
        _deployBridge(ilrm);
        batcher = new L3DisputeBatcher(address(l3Bridge), ilrm);
        l3Bridge.setSettlementRelayer(address(batcher), true);
    }

    // ============ Helpers ============

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

    function _single(IL3Bridge.DisputeSettlementMessage memory message) internal {
        vm.prank(sequencer);
        l3Bridge.processSettlementFromL3(message);
    }

    function _batch(IL3Bridge.DisputeSettlementMessage[] memory messages) internal returns (uint256 processed) {
        vm.prank(sequencer);
        processed = l3Bridge.batchProcessSettlements(messages);
    }

    /// @notice Commit a root on the head and finalize it
    function _finalizedRoot(bytes32 root) internal returns (bytes32) {
        _submitOnHead(root);
        vm.warp(l3Bridge.getChallengeDeadline(root));
        l3Bridge.finalizeStateCommitment(root);
        assertTrue(l3Bridge.isStateFinalized(root));
        return root;
    }

    function _expectSettled(IL3Bridge.DisputeSettlementMessage memory m) internal {
        vm.expectEmit(address(l3Bridge));
        emit DisputeSettledFromL3(m.l2DisputeId, m.l3DisputeId, m.outcome, m.initiatorReturn, m.counterpartyReturn);
    }

    function _expectSkipped(IL3Bridge.DisputeSettlementMessage memory m, IL3Bridge.SettlementSkipReason reason)
        internal
    {
        vm.expectEmit(address(l3Bridge));
        emit SettlementSkipped(m.l2DisputeId, m.l3DisputeId, reason);
    }

    // ============ Single path (unchanged behavior) ============

    function test_SinglePathRevertsOnEachInvalidSettlement() public {
        bytes32 finalized = _finalizedRoot(keccak256("root_1"));
        bytes32 pending = keccak256("root_2");
        _submitOnHead(pending);
        assertEq(_bridge(1), 1);
        _bridge(2);

        // Never bridged
        vm.prank(sequencer);
        vm.expectRevert(abi.encodeWithSelector(IL3Bridge.DisputeNotBridged.selector, 5));
        l3Bridge.processSettlementFromL3(_settlementMsg(5, 1, bytes32(0)));

        // L3 ID mismatch
        vm.prank(sequencer);
        vm.expectRevert(abi.encodeWithSelector(IL3Bridge.InvalidSettlement.selector, 1));
        l3Bridge.processSettlementFromL3(_settlementMsg(1, 2, bytes32(0)));

        // Nonzero stateProof that is committed but not finalized, or never committed
        IL3Bridge.DisputeSettlementMessage memory unfinalized = _valid(1, pending);
        vm.prank(sequencer);
        vm.expectRevert(abi.encodeWithSelector(IL3Bridge.InvalidStateRoot.selector, pending));
        l3Bridge.processSettlementFromL3(unfinalized);
        bytes32 unknown = keccak256("unknown_root");
        IL3Bridge.DisputeSettlementMessage memory uncommitted = _valid(1, unknown);
        vm.prank(sequencer);
        vm.expectRevert(abi.encodeWithSelector(IL3Bridge.InvalidStateRoot.selector, unknown));
        l3Bridge.processSettlementFromL3(uncommitted);

        // Valid against a finalized root, and on the sequencer's word (stateProof == 0)
        IL3Bridge.DisputeSettlementMessage memory s1 = _valid(1, finalized);
        _expectSettled(s1);
        _single(s1);
        _single(_valid(2, bytes32(0)));

        // Already settled
        vm.prank(sequencer);
        vm.expectRevert(abi.encodeWithSelector(IL3Bridge.InvalidSettlement.selector, 1));
        l3Bridge.processSettlementFromL3(s1);

        assertEq(l3Bridge.getTotalSettlements(), 2);
        assertEq(l3Bridge.getPendingSettlementsCount(), 0);
    }

    // ============ Batch path ============

    function test_BatchSkipsInvalidItemsAndSettlesTheRest() public {
        bytes32 finalized = _finalizedRoot(keccak256("root_1"));
        bytes32 pending = keccak256("root_2");
        _submitOnHead(pending);
        for (uint256 id = 1; id <= 4; id++) {
            assertEq(_bridge(id), id);
        }

        // Dispute 2 is settled directly before the batch
        _single(_valid(2, bytes32(0)));

        IL3Bridge.DisputeSettlementMessage[] memory batch = new IL3Bridge.DisputeSettlementMessage[](8);
        batch[0] = _valid(1, bytes32(0)); // applied
        batch[1] = _settlementMsg(9, 7, bytes32(0)); // never bridged
        batch[2] = _valid(2, bytes32(0)); // already settled via processSettlementFromL3
        batch[3] = _settlementMsg(3, 99, bytes32(0)); // L3 ID mismatch
        batch[4] = _valid(3, pending); // stateProof not finalized
        batch[5] = _valid(1, bytes32(0)); // duplicate of batch[0]
        batch[6] = _valid(3, finalized); // applied (dispute 3 was untouched by the skipped items)
        batch[7] = _valid(4, bytes32(0)); // applied

        _expectSettled(batch[0]);
        _expectSkipped(batch[1], IL3Bridge.SettlementSkipReason.NotBridged);
        _expectSkipped(batch[2], IL3Bridge.SettlementSkipReason.AlreadySettled);
        _expectSkipped(batch[3], IL3Bridge.SettlementSkipReason.L3DisputeIdMismatch);
        _expectSkipped(batch[4], IL3Bridge.SettlementSkipReason.StateRootNotFinalized);
        _expectSkipped(batch[5], IL3Bridge.SettlementSkipReason.AlreadySettled);
        _expectSettled(batch[6]);
        _expectSettled(batch[7]);
        assertEq(_batch(batch), 3);

        for (uint256 id = 1; id <= 4; id++) {
            assertTrue(l3Bridge.isDisputeSettled(id));
        }
        assertFalse(l3Bridge.isDisputeSettled(9));
        assertEq(l3Bridge.getTotalSettlements(), 4);
        assertEq(l3Bridge.getPendingSettlementsCount(), 0);
        assertEq(l3Bridge.getTotalBridgedDisputes(), 4);
    }

    function test_SkippedSettlementCanBeResubmitted() public {
        _bridge(1);
        bytes32 root = keccak256("root_1");
        _submitOnHead(root);

        IL3Bridge.DisputeSettlementMessage[] memory batch = new IL3Bridge.DisputeSettlementMessage[](2);
        batch[0] = _valid(1, root); // root not finalized yet
        batch[1] = _settlementMsg(2, 2, bytes32(0)); // dispute 2 not bridged yet
        assertEq(_batch(batch), 0);
        assertFalse(l3Bridge.isDisputeSettled(1));
        assertEq(l3Bridge.getTotalSettlements(), 0);
        assertEq(l3Bridge.getPendingSettlementsCount(), 1);

        // Nothing was recorded for the skipped items: once valid they go through
        vm.warp(l3Bridge.getChallengeDeadline(root));
        l3Bridge.finalizeStateCommitment(root);
        assertEq(_bridge(2), 2);
        assertEq(_batch(batch), 2);
        assertTrue(l3Bridge.isDisputeSettled(1));
        assertTrue(l3Bridge.isDisputeSettled(2));
        assertEq(l3Bridge.getPendingSettlementsCount(), 0);
    }

    function test_BatchLevelChecksStillRevert() public {
        _bridge(1);
        IL3Bridge.DisputeSettlementMessage[] memory batch = new IL3Bridge.DisputeSettlementMessage[](1);
        batch[0] = _valid(1, bytes32(0));

        // Caller: neither the sequencer nor a relayer
        address outsider = makeAddr("outsider");
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(IL3Bridge.NotSequencer.selector, outsider));
        l3Bridge.batchProcessSettlements(batch);

        // Bridge status
        l3Bridge.setBridgeStatus(IL3Bridge.BridgeStatus.Paused);
        vm.prank(sequencer);
        vm.expectRevert(IL3Bridge.BridgeNotActive.selector);
        l3Bridge.batchProcessSettlements(batch);
        l3Bridge.setBridgeStatus(IL3Bridge.BridgeStatus.Active);

        // Size (the cap applies to invalid items too)
        IL3Bridge.DisputeSettlementMessage[] memory tooMany = new IL3Bridge.DisputeSettlementMessage[](101);
        vm.prank(sequencer);
        vm.expectRevert(abi.encodeWithSelector(IL3Bridge.BatchSizeExceeded.selector, 101, 100));
        l3Bridge.batchProcessSettlements(tooMany);

        assertFalse(l3Bridge.isDisputeSettled(1));
        assertEq(_batch(batch), 1);
    }

    /// @notice The batch is exactly "processSettlementFromL3 per item, skipping the ones that revert"
    function testFuzz_BatchEqualsSequentialSingles(uint256 seed) public {
        bytes32 finalized = _finalizedRoot(keccak256("root_1"));
        bytes32 pending = keccak256("root_2");
        _submitOnHead(pending);
        for (uint256 id = 1; id <= 4; id++) {
            _bridge(id);
        }

        // Up to 12 messages over disputes 1..6 (5 and 6 never bridged), with occasional wrong L3 IDs and
        // zero, finalized, pending or unknown state proofs
        uint256 n = bound(seed, 1, 12);
        IL3Bridge.DisputeSettlementMessage[] memory batch = new IL3Bridge.DisputeSettlementMessage[](n);
        for (uint256 i = 0; i < n; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 l2Id = 1 + (r % 6);
            uint256 l3Id = (r >> 8) % 4 == 0 ? l2Id + 1 : l2Id;
            uint256 p = (r >> 16) % 4;
            bytes32 proof = p == 0 ? bytes32(0) : p == 1 ? finalized : p == 2 ? pending : bytes32(r);
            batch[i] = _settlementMsg(l2Id, l3Id, proof);
        }

        // Reference: one processSettlementFromL3 call per item
        uint256 snapshot = vm.snapshotState();
        bool[] memory ok = new bool[](n);
        bytes[] memory errs = new bytes[](n);
        uint256 expectedProcessed;
        for (uint256 i = 0; i < n; i++) {
            vm.prank(sequencer);
            try l3Bridge.processSettlementFromL3(batch[i]) {
                ok[i] = true;
                expectedProcessed++;
            } catch (bytes memory err) {
                errs[i] = err;
            }
        }
        bool[7] memory settledRef;
        for (uint256 id = 1; id <= 6; id++) {
            settledRef[id] = l3Bridge.isDisputeSettled(id);
        }
        uint256 totalRef = l3Bridge.getTotalSettlements();
        uint256 pendingRef = l3Bridge.getPendingSettlementsCount();
        vm.revertToState(snapshot);

        // Batch
        vm.recordLogs();
        assertEq(_batch(batch), expectedProcessed, "processed count");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, n, "one event per item");

        for (uint256 i = 0; i < n; i++) {
            assertEq(logs[i].emitter, address(l3Bridge));
            assertEq(uint256(logs[i].topics[1]), batch[i].l2DisputeId);
            if (ok[i]) {
                assertEq(logs[i].topics[0], DisputeSettledFromL3.selector, "valid item not applied");
            } else {
                assertEq(logs[i].topics[0], SettlementSkipped.selector, "invalid item not skipped");
                IL3Bridge.SettlementSkipReason reason = abi.decode(logs[i].data, (IL3Bridge.SettlementSkipReason));
                assertEq(errs[i], _singlePathError(batch[i], reason), "skip reason != single-path revert");
            }
        }

        for (uint256 id = 1; id <= 6; id++) {
            assertEq(l3Bridge.isDisputeSettled(id), settledRef[id]);
        }
        assertEq(l3Bridge.getTotalSettlements(), totalRef);
        assertEq(l3Bridge.getPendingSettlementsCount(), pendingRef);
        assertEq(l3Bridge.getPendingSettlementsCount() + l3Bridge.getTotalSettlements(), 4);
    }

    function _singlePathError(IL3Bridge.DisputeSettlementMessage memory m, IL3Bridge.SettlementSkipReason reason)
        internal
        pure
        returns (bytes memory)
    {
        if (reason == IL3Bridge.SettlementSkipReason.NotBridged) {
            return abi.encodeWithSelector(IL3Bridge.DisputeNotBridged.selector, m.l2DisputeId);
        }
        if (reason == IL3Bridge.SettlementSkipReason.StateRootNotFinalized) {
            return abi.encodeWithSelector(IL3Bridge.InvalidStateRoot.selector, m.stateProof);
        }
        assertTrue(
            reason == IL3Bridge.SettlementSkipReason.L3DisputeIdMismatch
                || reason == IL3Bridge.SettlementSkipReason.AlreadySettled,
            "unexpected skip reason"
        );
        return abi.encodeWithSelector(IL3Bridge.InvalidSettlement.selector, m.l2DisputeId);
    }

    // ============ Batcher relaying ============

    /// @notice Regression: one bad message used to revert the relayed batch, so the queue could never be relayed
    function test_BatcherRelayNotStuckOnBadMessage() public {
        _bridge(1);
        _bridge(2);
        _single(_valid(2, bytes32(0)));

        IL3Bridge.DisputeSettlementMessage[] memory batch = new IL3Bridge.DisputeSettlementMessage[](4);
        batch[0] = _settlementMsg(7, 3, bytes32(0)); // never bridged
        batch[1] = _valid(1, bytes32(0)); // valid
        batch[2] = _valid(2, bytes32(0)); // already settled via processSettlementFromL3
        batch[3] = _valid(1, bytes32(0)); // duplicate within the batch
        for (uint256 i = 0; i < batch.length; i++) {
            vm.prank(sequencer);
            batcher.queueSettlement(batch[i]);
        }

        _expectSkipped(batch[0], IL3Bridge.SettlementSkipReason.NotBridged);
        _expectSettled(batch[1]);
        _expectSkipped(batch[2], IL3Bridge.SettlementSkipReason.AlreadySettled);
        _expectSkipped(batch[3], IL3Bridge.SettlementSkipReason.AlreadySettled);
        vm.expectEmit(address(batcher));
        emit SettlementBatchProcessed(uint256(keccak256(abi.encode(batch))), 1);
        assertEq(batcher.processSettlementBatch(), 1);

        assertTrue(l3Bridge.isDisputeSettled(1));
        assertFalse(l3Bridge.isDisputeSettled(7));
        assertEq(l3Bridge.getTotalSettlements(), 2);
        assertEq(batcher.getPendingSettlementsCount(), 0);
        assertEq(batcher.settlementBatchSequencer(), address(0));

        // The queue is free for the next batch
        _bridge(3);
        IL3Bridge.DisputeSettlementMessage memory next = _valid(3, bytes32(0));
        vm.prank(sequencer);
        batcher.queueSettlement(next);
        assertEq(batcher.processSettlementBatch(), 1);
        assertTrue(l3Bridge.isDisputeSettled(3));
    }

    function test_BatcherAllInvalidBatchIsConsumed() public {
        vm.prank(sequencer);
        batcher.queueSettlement(_settlementMsg(1, 1, bytes32(0)));

        assertEq(batcher.processSettlementBatch(), 0);
        assertEq(batcher.getPendingSettlementsCount(), 0);
        assertEq(l3Bridge.getTotalSettlements(), 0);
    }

    function test_BatcherKeepsQueueOnBatchLevelRevert() public {
        _bridge(1);
        IL3Bridge.DisputeSettlementMessage memory settlement = _valid(1, bytes32(0));
        vm.prank(sequencer);
        batcher.queueSettlement(settlement);

        l3Bridge.setBridgeStatus(IL3Bridge.BridgeStatus.Paused);
        vm.expectRevert(IL3Bridge.BridgeNotActive.selector);
        batcher.processSettlementBatch();
        assertEq(batcher.getPendingSettlementsCount(), 1);
        assertEq(batcher.settlementBatchSequencer(), sequencer);

        l3Bridge.setBridgeStatus(IL3Bridge.BridgeStatus.Active);
        assertEq(batcher.processSettlementBatch(), 1);
        assertTrue(l3Bridge.isDisputeSettled(1));
    }
}
