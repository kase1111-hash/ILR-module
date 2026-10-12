// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "./L3TestBase.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @notice Bridge stand-in that records the batcher's queue lengths while it is being called,
 *         and tries to re-enter the batcher from inside the call
 */
contract QueueObservingBridge {
    L3DisputeBatcher public batcher;
    address public sequencer;

    uint256 public observedInitiations = type(uint256).max;
    uint256 public observedSettlements = type(uint256).max;
    bytes public queueReentryError;
    bytes public submitReentryError;

    uint256 private _nextId;

    constructor(address _sequencer) {
        sequencer = _sequencer;
    }

    function setBatcher(address _batcher) external {
        batcher = L3DisputeBatcher(_batcher);
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
        observedInitiations = batcher.getPendingInitiationsCount();

        try batcher.queueDisputeInitiation(messages[0]) {}
        catch (bytes memory reason) {
            queueReentryError = reason;
        }
        try batcher.submitInitiationBatch() {}
        catch (bytes memory reason) {
            submitReentryError = reason;
        }

        l3DisputeIds = new uint256[](messages.length);
        for (uint256 i = 0; i < messages.length; i++) {
            l3DisputeIds[i] = ++_nextId;
        }
    }

    function batchProcessSettlements(IL3Bridge.DisputeSettlementMessage[] calldata messages)
        external
        returns (uint256 processed)
    {
        observedSettlements = batcher.getPendingSettlementsCount();
        processed = messages.length;
    }
}

/**
 * @title L3DisputeBatcherTest
 * @notice Batcher <-> bridge authorization, auto-batch failure isolation and settlement relaying
 */
contract L3DisputeBatcherTest is L3TestBase {
    L3DisputeBatcher public batcher;

    address internal ilrm = makeAddr("ilrm");
    address internal outsider = makeAddr("outsider");

    function setUp() public {
        // As in the E2E setup: bridge and batcher both point at the ILRM, which is not the batcher
        _deployBridge(ilrm);
        batcher = new L3DisputeBatcher(address(l3Bridge), ilrm);
    }

    // ============ Helpers ============

    function _message(uint256 l2DisputeId) internal view returns (IL3Bridge.DisputeInitiationMessage memory) {
        return IL3Bridge.DisputeInitiationMessage({
            l2DisputeId: l2DisputeId,
            initiator: address(uint160(0x1000 + l2DisputeId)),
            counterparty: address(uint160(0x2000 + l2DisputeId)),
            stakeAmount: 1 ether,
            evidenceHash: keccak256(abi.encode("evidence", l2DisputeId)),
            fallbackTermsHash: bytes32(0),
            l2BlockNumber: block.number
        });
    }

    function _messages(uint256 firstId, uint256 count)
        internal
        view
        returns (IL3Bridge.DisputeInitiationMessage[] memory messages)
    {
        messages = new IL3Bridge.DisputeInitiationMessage[](count);
        for (uint256 i = 0; i < count; i++) {
            messages[i] = _message(firstId + i);
        }
    }

    function _queue(IL3Bridge.DisputeInitiationMessage[] memory messages) internal {
        for (uint256 i = 0; i < messages.length; i++) {
            batcher.queueDisputeInitiation(messages[i]);
        }
    }

    function _settlement(uint256 l2DisputeId) internal view returns (IL3Bridge.DisputeSettlementMessage memory) {
        return IL3Bridge.DisputeSettlementMessage({
            l2DisputeId: l2DisputeId,
            l3DisputeId: l3Bridge.getL3DisputeId(l2DisputeId),
            outcome: IL3Bridge.L3DisputeState.Accepted,
            initiatorReturn: 1 ether,
            counterpartyReturn: 1 ether,
            burnAmount: 0,
            proposalHash: keccak256("proposal"),
            stateProof: bytes32(0)
        });
    }

    function _bridgeViaIlrm(uint256 l2DisputeId) internal returns (uint256 l3DisputeId) {
        IL3Bridge.DisputeInitiationMessage memory message = _message(l2DisputeId);
        vm.prank(ilrm);
        l3DisputeId = l3Bridge.bridgeDisputeToL3(message);
    }

    function _notAuthorized(address caller) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IL3Bridge.NotAuthorizedBridger.selector, caller);
    }

    // ============ Dispute bridging ============

    function test_AuthorizedBatcherBridgesBatch() public {
        l3Bridge.setDisputeBridger(address(batcher), true);

        IL3Bridge.DisputeInitiationMessage[] memory messages = _messages(101, 5);
        _queue(messages);
        assertEq(batcher.getPendingInitiationsCount(), 5);

        bytes32 batchHash = keccak256(abi.encode(messages));
        vm.expectEmit(address(batcher));
        emit BatchSubmitted(uint256(batchHash), 5, batchHash);
        (uint256 batchId, uint256 count) = batcher.submitInitiationBatch();

        assertEq(batchId, uint256(batchHash));
        assertEq(count, 5);
        for (uint256 i = 0; i < 5; i++) {
            assertEq(l3Bridge.getL3DisputeId(101 + i), i + 1);
        }
        assertEq(l3Bridge.getTotalBridgedDisputes(), 5);
        assertEq(batcher.getPendingInitiationsCount(), 0);
        assertEq(batcher.batchStartTime(), 0);
    }

    function test_BridgerRoleAccessControl() public {
        IL3Bridge.DisputeInitiationMessage memory message = _message(1);
        IL3Bridge.DisputeInitiationMessage[] memory batch = _messages(2, 2);

        // Unauthorized callers
        vm.prank(outsider);
        vm.expectRevert(_notAuthorized(outsider));
        l3Bridge.bridgeDisputeToL3(message);
        vm.prank(outsider);
        vm.expectRevert(_notAuthorized(outsider));
        l3Bridge.bridgeDisputeBatchToL3(batch);

        // Only the owner manages the roles, and never for the zero address
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        l3Bridge.setDisputeBridger(outsider, true);
        vm.expectRevert(bytes("Invalid bridger"));
        l3Bridge.setDisputeBridger(address(0), true);
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        l3Bridge.setSettlementRelayer(outsider, true);
        vm.expectRevert(bytes("Invalid relayer"));
        l3Bridge.setSettlementRelayer(address(0), true);

        // The ILRM can still bridge directly
        vm.prank(ilrm);
        assertEq(l3Bridge.bridgeDisputeToL3(message), 1);

        // Grant, bridge, revoke
        vm.expectEmit(address(l3Bridge));
        emit DisputeBridgerUpdated(outsider, true);
        l3Bridge.setDisputeBridger(outsider, true);
        assertTrue(l3Bridge.disputeBridgers(outsider));
        vm.prank(outsider);
        uint256[] memory ids = l3Bridge.bridgeDisputeBatchToL3(batch);
        assertEq(ids.length, 2);
        assertEq(ids[0], 2);
        assertEq(ids[1], 3);

        vm.expectEmit(address(l3Bridge));
        emit DisputeBridgerUpdated(outsider, false);
        l3Bridge.setDisputeBridger(outsider, false);
        vm.prank(outsider);
        vm.expectRevert(_notAuthorized(outsider));
        l3Bridge.bridgeDisputeToL3(_message(4));
        vm.prank(outsider);
        vm.expectRevert(_notAuthorized(outsider));
        l3Bridge.bridgeDisputeBatchToL3(_messages(4, 1));
    }

    function test_AutoBatchAtMaxSizeBridges() public {
        l3Bridge.setDisputeBridger(address(batcher), true);
        uint256 maxSize = batcher.MAX_BATCH_SIZE();

        IL3Bridge.DisputeInitiationMessage[] memory messages = _messages(1, maxSize);
        for (uint256 i = 0; i < maxSize - 1; i++) {
            batcher.queueDisputeInitiation(messages[i]);
        }
        assertEq(batcher.getPendingInitiationsCount(), maxSize - 1);

        bytes32 batchHash = keccak256(abi.encode(messages));
        vm.expectEmit(address(batcher));
        emit BatchSubmitted(uint256(batchHash), maxSize, batchHash);
        uint256 gasBefore = gasleft();
        uint256 position = batcher.queueDisputeInitiation(messages[maxSize - 1]);
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("gas used by the auto-batching queue call", gasUsed);
        assertEq(position, maxSize - 1);
        assertLt(gasUsed, 15_000_000, "auto-batch of a full queue too expensive");
        assertEq(batcher.getPendingInitiationsCount(), 0);
        assertEq(l3Bridge.getTotalBridgedDisputes(), maxSize);
        for (uint256 i = 0; i < maxSize; i++) {
            assertEq(l3Bridge.getL3DisputeId(1 + i), i + 1);
        }
    }

    function test_AutoBatchFailureAt50DoesNotBrick() public {
        uint256 maxSize = batcher.MAX_BATCH_SIZE();
        IL3Bridge.DisputeInitiationMessage[] memory messages = _messages(1, maxSize);
        for (uint256 i = 0; i < maxSize - 1; i++) {
            batcher.queueDisputeInitiation(messages[i]);
        }

        // The batcher is not yet an authorized bridger: the auto-batch fails, the queue call does not
        vm.expectEmit(address(batcher));
        emit AutoBatchFailed(maxSize, _notAuthorized(address(batcher)));
        uint256 position = batcher.queueDisputeInitiation(messages[maxSize - 1]);
        assertEq(position, maxSize - 1);
        assertEq(batcher.getPendingInitiationsCount(), maxSize);
        assertEq(l3Bridge.getTotalBridgedDisputes(), 0);

        vm.expectRevert(L3DisputeBatcher.BatchFull.selector);
        batcher.queueDisputeInitiation(_message(maxSize + 1));

        // Once authorized, the intact queue is bridged manually
        l3Bridge.setDisputeBridger(address(batcher), true);
        (, uint256 count) = batcher.submitInitiationBatch();
        assertEq(count, maxSize);
        assertEq(batcher.getPendingInitiationsCount(), 0);
        assertEq(l3Bridge.getTotalBridgedDisputes(), maxSize);
    }

    function test_TimeTriggeredAutoBatchFailureDoesNotBrick() public {
        _queue(_messages(1, 5));
        vm.warp(block.timestamp + batcher.MAX_BATCH_WAIT());

        // The overdue batch fails in isolation and the queue call still succeeds
        vm.expectEmit(address(batcher));
        emit AutoBatchFailed(6, _notAuthorized(address(batcher)));
        batcher.queueDisputeInitiation(_message(6));

        // Later queue calls succeed too; during the backoff they do not retry (see L3BatcherResilience.t.sol)
        _queue(_messages(7, 2));
        assertEq(batcher.getPendingInitiationsCount(), 8);

        // After the grant and the backoff, the next queue call flushes everything
        l3Bridge.setDisputeBridger(address(batcher), true);
        vm.warp(block.timestamp + batcher.AUTO_BATCH_RETRY_DELAY());
        batcher.queueDisputeInitiation(_message(9));
        assertEq(batcher.getPendingInitiationsCount(), 0);
        assertEq(l3Bridge.getTotalBridgedDisputes(), 9);
        assertEq(batcher.batchStartTime(), 0);
    }

    function test_BridgeInactiveKeepsQueue() public {
        l3Bridge.setDisputeBridger(address(batcher), true);
        l3Bridge.setBridgeStatus(IL3Bridge.BridgeStatus.Paused);

        _queue(_messages(1, 5));
        vm.warp(block.timestamp + batcher.MAX_BATCH_WAIT());
        vm.expectEmit(address(batcher));
        emit AutoBatchFailed(6, abi.encodeWithSelector(IL3Bridge.BridgeNotActive.selector));
        batcher.queueDisputeInitiation(_message(6));
        assertEq(batcher.getPendingInitiationsCount(), 6);

        // A manual submission reverts as a whole and keeps the queue
        vm.expectRevert(IL3Bridge.BridgeNotActive.selector);
        batcher.submitInitiationBatch();
        assertEq(batcher.getPendingInitiationsCount(), 6);

        l3Bridge.setBridgeStatus(IL3Bridge.BridgeStatus.Active);
        (, uint256 count) = batcher.submitInitiationBatch();
        assertEq(count, 6);
        assertEq(batcher.getPendingInitiationsCount(), 0);
        assertEq(l3Bridge.getTotalBridgedDisputes(), 6);
    }

    function test_AlreadyBridgedAndDuplicateSkipped() public {
        l3Bridge.setDisputeBridger(address(batcher), true);
        assertEq(_bridgeViaIlrm(10), 1);

        IL3Bridge.DisputeInitiationMessage[] memory messages = new IL3Bridge.DisputeInitiationMessage[](4);
        messages[0] = _message(10); // already bridged by the ILRM
        messages[1] = _message(11);
        messages[2] = _message(12);
        messages[3] = _message(11); // duplicate within the batch
        _queue(messages);

        bytes32 batchHash = keccak256(abi.encode(messages));
        vm.expectEmit(address(l3Bridge));
        emit DisputeBridgeSkipped(10, 1);
        vm.expectEmit(address(l3Bridge));
        emit DisputeBridgeSkipped(11, 2);
        vm.expectEmit(address(batcher));
        emit BatchSubmitted(uint256(batchHash), 2, batchHash);
        (, uint256 count) = batcher.submitInitiationBatch();

        assertEq(count, 2);
        assertEq(l3Bridge.getL3DisputeId(11), 2);
        assertEq(l3Bridge.getL3DisputeId(12), 3);
        assertEq(l3Bridge.getTotalBridgedDisputes(), 3);
        assertEq(batcher.getPendingInitiationsCount(), 0);
    }

    function test_BridgeDisputeBatchToL3SizeCap() public {
        uint256 bridgeMax = l3Bridge.MAX_BATCH_SIZE();
        IL3Bridge.DisputeInitiationMessage[] memory tooMany = new IL3Bridge.DisputeInitiationMessage[](bridgeMax + 1);

        vm.prank(ilrm);
        vm.expectRevert(abi.encodeWithSelector(IL3Bridge.BatchSizeExceeded.selector, bridgeMax + 1, bridgeMax));
        l3Bridge.bridgeDisputeBatchToL3(tooMany);

        vm.prank(ilrm);
        uint256[] memory ids = l3Bridge.bridgeDisputeBatchToL3(new IL3Bridge.DisputeInitiationMessage[](0));
        assertEq(ids.length, 0);
        assertEq(l3Bridge.getTotalBridgedDisputes(), 0);
    }

    function test_ExecuteAutoBatchSelfOnly() public {
        _queue(_messages(1, 3));

        vm.expectRevert(abi.encodeWithSelector(L3DisputeBatcher.NotAuthorizedSubmitter.selector, address(this)));
        batcher.executeAutoBatch();

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(L3DisputeBatcher.NotAuthorizedSubmitter.selector, outsider));
        batcher.executeAutoBatch();

        assertEq(batcher.getPendingInitiationsCount(), 3);
    }

    function test_QueuesClearedBeforeExternalCalls() public {
        QueueObservingBridge observer = new QueueObservingBridge(sequencer);
        observer.setBatcher(address(batcher));
        batcher.setL3Bridge(address(observer));
        batcher.setAuthorizedSubmitter(address(observer), true);

        _queue(_messages(1, 2));
        (, uint256 count) = batcher.submitInitiationBatch();
        assertEq(count, 2);
        assertEq(observer.observedInitiations(), 0, "initiation queue not cleared before bridge call");

        bytes memory reentrant = abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(observer.queueReentryError(), reentrant);
        assertEq(observer.submitReentryError(), reentrant);
        assertEq(batcher.getPendingInitiationsCount(), 0);

        IL3Bridge.DisputeSettlementMessage memory settlement = _settlement(1);
        vm.prank(sequencer);
        batcher.queueSettlement(settlement);
        assertEq(batcher.processSettlementBatch(), 1);
        assertEq(observer.observedSettlements(), 0, "settlement queue not cleared before bridge call");
        assertEq(batcher.settlementBatchSequencer(), address(0));
    }

    // ============ Settlement relaying ============

    function test_SettlementRelay() public {
        _bridgeViaIlrm(7);
        IL3Bridge.DisputeSettlementMessage memory settlement = _settlement(7);

        // Submitters cannot queue settlements; only the bridge's sequencer can
        vm.expectRevert(abi.encodeWithSelector(L3DisputeBatcher.NotBridgeSequencer.selector, address(this)));
        batcher.queueSettlement(settlement);

        vm.prank(sequencer);
        assertEq(batcher.queueSettlement(settlement), 0);
        assertEq(batcher.settlementBatchSequencer(), sequencer);

        // Without the relayer grant the bridge rejects the batcher, and the queue is kept
        vm.expectRevert(abi.encodeWithSelector(IL3Bridge.NotSequencer.selector, address(batcher)));
        batcher.processSettlementBatch();
        assertEq(batcher.getPendingSettlementsCount(), 1);

        vm.expectEmit(address(l3Bridge));
        emit SettlementRelayerUpdated(address(batcher), true);
        l3Bridge.setSettlementRelayer(address(batcher), true);

        IL3Bridge.DisputeSettlementMessage[] memory batch = new IL3Bridge.DisputeSettlementMessage[](1);
        batch[0] = settlement;
        vm.expectEmit(address(batcher));
        emit SettlementBatchProcessed(uint256(keccak256(abi.encode(batch))), 1);
        assertEq(batcher.processSettlementBatch(), 1);

        assertTrue(l3Bridge.isDisputeSettled(7));
        assertEq(l3Bridge.getTotalSettlements(), 1);
        assertEq(batcher.getPendingSettlementsCount(), 0);
        assertEq(batcher.settlementBatchSequencer(), address(0));
    }

    function test_SettlementBatchFromReplacedSequencerNotRelayed() public {
        l3Bridge.setSettlementRelayer(address(batcher), true);
        _bridgeViaIlrm(1);
        _bridgeViaIlrm(2);

        IL3Bridge.DisputeSettlementMessage memory settlement1 = _settlement(1);
        IL3Bridge.DisputeSettlementMessage memory settlement2 = _settlement(2);

        address oldSequencer = sequencer;
        vm.prank(oldSequencer);
        batcher.queueSettlement(settlement1);

        // Owner rotates the sequencer
        address newSequencer = makeAddr("newSequencer");
        IL3Bridge.SequencerConfig memory config = l3Bridge.getSequencerConfig();
        config.sequencerAddress = newSequencer;
        l3Bridge.updateSequencerConfig(config);

        vm.expectRevert(abi.encodeWithSelector(L3DisputeBatcher.SequencerChanged.selector, oldSequencer, newSequencer));
        batcher.processSettlementBatch();

        vm.prank(oldSequencer);
        vm.expectRevert(abi.encodeWithSelector(L3DisputeBatcher.NotBridgeSequencer.selector, oldSequencer));
        batcher.queueSettlement(settlement2);

        // The new sequencer's first queue call discards the stale batch
        vm.expectEmit(address(batcher));
        emit StaleSettlementsDiscarded(oldSequencer, 1);
        vm.prank(newSequencer);
        assertEq(batcher.queueSettlement(settlement2), 0);
        assertEq(batcher.getPendingSettlementsCount(), 1);
        assertEq(batcher.settlementBatchSequencer(), newSequencer);

        assertEq(batcher.processSettlementBatch(), 1);
        assertTrue(l3Bridge.isDisputeSettled(2));
        assertFalse(l3Bridge.isDisputeSettled(1));

        // emergencyClearBatches resets the queue owner
        vm.prank(newSequencer);
        batcher.queueSettlement(settlement1);
        assertEq(batcher.settlementBatchSequencer(), newSequencer);
        batcher.emergencyClearBatches();
        assertEq(batcher.settlementBatchSequencer(), address(0));
        assertEq(batcher.getPendingSettlementsCount(), 0);
    }
}
