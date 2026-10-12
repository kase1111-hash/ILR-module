// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {GovernanceTimelockFixture, GovTimelockTarget} from "./GovernanceTimelock.t.sol";
import {GovernanceTimelock} from "../contracts/modules/GovernanceTimelock.sol";
import {IGovernanceTimelock} from "../contracts/interfaces/IGovernanceTimelock.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Vm} from "forge-std/Vm.sol";

/**
 * @notice Regression tests for the GovernanceTimelock follow-ups: stale metadata after raw
 *         re-schedules, accurate emergency events, delayed and epoch-bound unpausing, the executor
 *         guard, batch length-check ordering and the 7-argument scheduleBatch label floor.
 */
contract GovernanceTimelockFollowUpsTest is GovernanceTimelockFixture {
    event EmergencyActionScheduled(
        bytes32 indexed id,
        address indexed guardian,
        address indexed target,
        bytes32 salt,
        uint256 readyAt,
        string reason
    );
    event EmergencyActionExecuted(bytes32 indexed id, address indexed executor, string reason);
    event OperationExecuted(
        bytes32 indexed id, IGovernanceTimelock.OperationType indexed opType, address indexed target, bool success
    );

    bytes internal constant UNPAUSE_ALL = abi.encodeWithSelector(IGovernanceTimelock.emergencyUnpauseAll.selector);

    function setUp() public override {
        super.setUp();
        vm.prank(admin);
        timelock.registerProtocolContract("ilrm", address(target));
    }

    // =====================================================================
    // Helpers
    // =====================================================================

    function _status(bytes32 id) internal view returns (uint256) {
        return uint256(timelock.getOperation(id).status);
    }

    function _countLogs(Vm.Log[] memory logs, bytes32 topic0) internal pure returns (uint256 n) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == topic0) n++;
        }
    }

    function _guardianUnpause() internal returns (bytes32 id, bytes32 salt) {
        vm.prank(guardian);
        id = timelock.emergencyUnpauseAll();
        salt = timelock.getOperation(id).salt;
    }

    function _executeUnpauseAll(bytes32 salt) internal {
        timelock.execute(address(timelock), 0, UNPAUSE_ALL, bytes32(0), salt);
    }

    function _stale(bytes32 id, uint256 scheduledEpoch, uint256 currentEpoch) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IGovernanceTimelock.StaleUnpause.selector, id, scheduledEpoch, currentEpoch);
    }

    // =====================================================================
    // (1) Stale metadata after a raw re-schedule of a tracked id
    // =====================================================================

    /// REGRESSION: scheduleOperation -> cancel -> raw schedule left a Cancelled record (old label) behind
    function test_RawRescheduleAfterCancel_ClearsStaleMetadata() public {
        bytes memory data = _setFeeData(5);
        vm.prank(proposer);
        bytes32 id = timelock.scheduleOperation(
            address(target),
            0,
            data,
            bytes32(0),
            bytes32("x"),
            IGovernanceTimelock.OperationType.TreasuryOperation,
            "old"
        );
        vm.prank(proposer);
        timelock.cancel(id);
        assertEq(_status(id), uint256(IGovernanceTimelock.OperationStatus.Cancelled));

        vm.warp(T0 + 1 days);
        vm.prank(proposer);
        timelock.schedule(address(target), 0, data, bytes32(0), bytes32("x"), MIN);
        assertEq(uint256(timelock.getOperationState(id)), uint256(TimelockController.OperationState.Waiting));

        // Raw schedules carry no metadata, even for a previously tracked id
        IGovernanceTimelock.GovernanceOperation memory op = timelock.getOperation(id);
        assertEq(uint256(op.status), uint256(IGovernanceTimelock.OperationStatus.None));
        assertEq(uint256(op.opType), 0);
        assertEq(op.scheduledAt, 0);
        assertEq(op.readyAt, 0);
        assertEq(op.description, "");
        assertEq(timelock.getPendingOperationsCount(), 0);

        // Executing the raw operation emits no governance event for the stale record
        vm.warp(T0 + 1 days + MIN);
        vm.recordLogs();
        timelock.execute(address(target), 0, data, bytes32(0), bytes32("x"));
        assertEq(_countLogs(vm.getRecordedLogs(), OperationExecuted.selector), 0);
        assertEq(_status(id), uint256(IGovernanceTimelock.OperationStatus.None));
        assertEq(target.fee(), 5);
    }

    /// REGRESSION: the same for the 7-argument scheduleBatch followed by the raw 6-argument one
    function test_RawBatchRescheduleAfterCancel_ClearsStaleMetadata() public {
        address[] memory targets = _one(address(target));
        uint256[] memory values = _oneValue(0);
        bytes[] memory payloads = _oneData(_setFeeData(6));

        vm.prank(proposer);
        bytes32 id = timelock.scheduleBatch(
            targets,
            values,
            payloads,
            bytes32(0),
            bytes32("b"),
            IGovernanceTimelock.OperationType.ContractUpgrade,
            "old"
        );
        vm.prank(proposer);
        timelock.cancelOperation(id);

        vm.prank(proposer);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), bytes32("b"), MIN);
        assertTrue(timelock.isOperationPending(id));
        assertEq(_status(id), uint256(IGovernanceTimelock.OperationStatus.None));
        assertEq(timelock.getOperation(id).scheduledAt, 0);

        // Cancelling the raw re-schedule does not resurrect the old record either
        vm.prank(proposer);
        timelock.cancel(id);
        assertEq(_status(id), uint256(IGovernanceTimelock.OperationStatus.None));
    }

    /// A metadata path after a raw cancel records a fresh record with the new label
    function test_MetadataRescheduleRecordsFreshLabel() public {
        bytes memory data = _setFeeData(7);
        vm.startPrank(proposer);
        bytes32 id = timelock.scheduleOperation(
            address(target), 0, data, bytes32(0), bytes32("m"), IGovernanceTimelock.OperationType.TreasuryOperation, "a"
        );
        timelock.cancel(id);
        timelock.schedule(address(target), 0, data, bytes32(0), bytes32("m"), MIN);
        timelock.cancel(id);
        vm.warp(T0 + 1 hours);
        timelock.scheduleOperation(
            address(target), 0, data, bytes32(0), bytes32("m"), IGovernanceTimelock.OperationType.OracleManagement, "b"
        );
        vm.stopPrank();

        IGovernanceTimelock.GovernanceOperation memory op = timelock.getOperation(id);
        assertEq(uint256(op.status), uint256(IGovernanceTimelock.OperationStatus.Pending));
        assertEq(uint256(op.opType), uint256(IGovernanceTimelock.OperationType.OracleManagement));
        assertEq(op.description, "b");
        assertEq(op.scheduledAt, T0 + 1 hours);
        assertEq(op.readyAt, timelock.getTimestamp(id));
        assertEq(timelock.getPendingOperationsCount(), 1);
    }

    /// Repeated cancel/re-schedule cycles interleaved with other operations never duplicate pending entries
    function test_RescheduleCycles_PendingListStaysUnique() public {
        bytes memory dataA = _setFeeData(1);
        bytes memory dataB = _setFeeData(2);
        vm.startPrank(proposer);
        bytes32 idB = timelock.scheduleOperation(
            address(target), 0, dataB, bytes32(0), bytes32(0), IGovernanceTimelock.OperationType.ParameterChange, ""
        );
        bytes32 idA;
        for (uint256 i = 0; i < 3; ++i) {
            idA = timelock.scheduleOperation(
                address(target), 0, dataA, bytes32(0), bytes32(0), IGovernanceTimelock.OperationType.ParameterChange, ""
            );
            timelock.cancel(idA);
        }
        idA = timelock.scheduleOperation(
            address(target), 0, dataA, bytes32(0), bytes32(0), IGovernanceTimelock.OperationType.ParameterChange, ""
        );
        vm.stopPrank();

        bytes32[] memory pending = timelock.getPendingOperations();
        assertEq(pending.length, 2);
        assertTrue(pending[0] != pending[1]);
        assertTrue((pending[0] == idA && pending[1] == idB) || (pending[0] == idB && pending[1] == idA));

        vm.warp(T0 + MIN);
        timelock.executeOperation(address(target), 0, dataA, bytes32(0), bytes32(0));
        timelock.executeOperation(address(target), 0, dataB, bytes32(0), bytes32(0));
        assertEq(timelock.getPendingOperationsCount(), 0);
    }

    // =====================================================================
    // (2) executeEmergency emits an accurate event
    // =====================================================================

    /// REGRESSION: executeEmergency only queues, so it must not emit EmergencyActionExecuted
    function test_ExecuteEmergency_EmitsScheduledNotExecuted() public {
        bytes memory data = _pauseData();
        bytes32 salt = _emergencySalt(1);
        bytes32 id = timelock.hashOperation(address(target), 0, data, bytes32(0), salt);

        vm.recordLogs();
        vm.expectEmit(true, true, true, true, address(timelock));
        emit EmergencyActionScheduled(id, guardian, address(target), salt, T0 + EMERGENCY, "incident");
        vm.prank(guardian);
        assertEq(timelock.executeEmergency(address(target), data, "incident"), id);
        assertEq(_countLogs(vm.getRecordedLogs(), EmergencyActionExecuted.selector), 0);
        assertFalse(target.paused());

        // Executing it emits OperationExecuted, still no EmergencyActionExecuted
        vm.warp(T0 + EMERGENCY);
        vm.recordLogs();
        timelock.execute(address(target), 0, data, bytes32(0), salt);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countLogs(logs, EmergencyActionExecuted.selector), 0);
        assertEq(_countLogs(logs, OperationExecuted.selector), 1);
        assertTrue(target.paused());
    }

    function test_EmergencyPauseAll_StillEmitsExecuted() public {
        vm.recordLogs();
        vm.prank(guardian);
        timelock.emergencyPauseAll("incident");
        assertEq(_countLogs(vm.getRecordedLogs(), EmergencyActionExecuted.selector), 1);
        assertTrue(target.paused());
        assertEq(timelock.pauseEpoch(), 1);
    }

    // =====================================================================
    // (3) Pause instant, unpause queued at minDelay and bound to the pause epoch
    // =====================================================================

    /// REGRESSION: a guardian can no longer unpause instantly
    function test_EmergencyUnpauseAll_QueuesAtMinDelay() public {
        vm.prank(guardian);
        timelock.emergencyPauseAll("incident");

        bytes32 salt = _emergencySalt(1);
        bytes32 id = timelock.hashOperation(address(timelock), 0, UNPAUSE_ALL, bytes32(0), salt);

        vm.recordLogs();
        vm.expectEmit(true, true, true, true, address(timelock));
        emit EmergencyActionScheduled(id, guardian, address(timelock), salt, T0 + MIN, "Emergency unpause all");
        vm.prank(guardian);
        assertEq(timelock.emergencyUnpauseAll(), id);
        assertEq(_countLogs(vm.getRecordedLogs(), EmergencyActionExecuted.selector), 0);

        assertTrue(target.paused());
        assertEq(timelock.getTimestamp(id), T0 + MIN);
        assertEq(timelock.emergencyNonce(), 1);
        IGovernanceTimelock.GovernanceOperation memory op = timelock.getOperation(id);
        assertEq(uint256(op.opType), uint256(IGovernanceTimelock.OperationType.ProtocolPause));
        assertEq(op.target, address(timelock));
        assertEq(op.data, UNPAUSE_ALL);
        assertEq(op.salt, salt);
        assertEq(op.readyAt, T0 + MIN);
        assertEq(timelock.getPendingOperationsCount(), 1);

        vm.warp(T0 + MIN - 1);
        vm.expectRevert(
            abi.encodeWithSelector(TimelockController.TimelockUnexpectedOperationState.selector, id, _readyBitmap())
        );
        _executeUnpauseAll(salt);
        assertTrue(target.paused());

        vm.warp(T0 + MIN);
        vm.recordLogs();
        vm.prank(stranger);
        _executeUnpauseAll(salt);
        assertEq(_countLogs(vm.getRecordedLogs(), EmergencyActionExecuted.selector), 1);
        assertFalse(target.paused());
        assertEq(_status(id), uint256(IGovernanceTimelock.OperationStatus.Executed));
        assertEq(timelock.getPendingOperationsCount(), 0);

        // Not replayable: done in the same epoch, stale (checked first) after a new pause
        vm.expectRevert(
            abi.encodeWithSelector(TimelockController.TimelockUnexpectedOperationState.selector, id, _readyBitmap())
        );
        _executeUnpauseAll(salt);
        vm.prank(guardian);
        timelock.emergencyPauseAll("again");
        vm.expectRevert(_stale(id, 1, 2));
        _executeUnpauseAll(salt);
        assertTrue(target.paused());
    }

    function test_EmergencyUnpauseAll_UsesMinDelayEvenAfterDelayChange() public {
        vm.prank(admin);
        timelock.updateDelays(3 days, 1 hours, 6 days);
        (bytes32 id,) = _guardianUnpause();
        assertEq(timelock.getTimestamp(id), T0 + 3 days);
    }

    function test_EmergencyUnpauseAll_RequiresEmergencyRole() public {
        address[3] memory callers = [proposer, admin, stranger];
        for (uint256 i = 0; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(_unauthorized(callers[i], EMERGENCY_ROLE));
            timelock.emergencyUnpauseAll();
        }
        assertEq(timelock.emergencyNonce(), 0);
    }

    /// The guardian is not a canceller; CANCELLER_ROLE vetoes a queued unpause
    function test_EmergencyUnpauseAll_CancellerVetoes() public {
        vm.prank(guardian);
        timelock.emergencyPauseAll("incident");
        (bytes32 id, bytes32 salt) = _guardianUnpause();

        vm.prank(guardian);
        vm.expectRevert(_unauthorized(guardian, CANCELLER_ROLE));
        timelock.cancel(id);

        vm.prank(proposer);
        timelock.cancelOperation(id);
        assertEq(_status(id), uint256(IGovernanceTimelock.OperationStatus.Cancelled));

        vm.warp(T0 + MIN);
        vm.expectRevert(
            abi.encodeWithSelector(TimelockController.TimelockUnexpectedOperationState.selector, id, _readyBitmap())
        );
        _executeUnpauseAll(salt);
        assertTrue(target.paused());
    }

    /// REGRESSION: an unpause queued before a later emergency pause cannot undo it
    function test_EmergencyUnpauseAll_StaleAfterRepause() public {
        vm.prank(guardian);
        timelock.emergencyPauseAll("incident 1");
        (bytes32 id, bytes32 salt) = _guardianUnpause();

        vm.warp(T0 + 1 hours);
        vm.prank(guardian);
        timelock.emergencyPauseAll("incident 2");
        assertEq(timelock.pauseEpoch(), 2);

        vm.warp(T0 + MIN);
        vm.expectRevert(_stale(id, 1, 2));
        _executeUnpauseAll(salt);
        assertTrue(target.paused());
        assertTrue(timelock.isOperationReady(id));

        // A fresh unpause queued in the current epoch works
        (bytes32 id2, bytes32 salt2) = _guardianUnpause();
        vm.warp(T0 + 2 * MIN);
        _executeUnpauseAll(salt2);
        assertFalse(target.paused());
        assertTrue(timelock.isOperationDone(id2));

        // The stale one stays unexecutable and can be cleaned up by a canceller
        vm.expectRevert(_stale(id, 1, 2));
        _executeUnpauseAll(salt);
        vm.prank(proposer);
        timelock.cancel(id);
    }

    /// REGRESSION: a rogue guardian cannot pre-load a matured unpause to fire during a later incident
    function test_RogueGuardian_PreQueuedUnpauseCannotUndoLaterPause() public {
        address rogue = makeAddr("rogue");
        vm.prank(admin);
        timelock.grantRole(EMERGENCY_ROLE, rogue);

        // Queued in calm times (epoch 0) and left to mature
        vm.prank(rogue);
        bytes32 id = timelock.emergencyUnpauseAll();
        bytes32 salt = timelock.getOperation(id).salt;
        vm.warp(T0 + 10 days);
        assertTrue(timelock.isOperationReady(id));

        // Incident: the honest guardian pauses
        vm.prank(guardian);
        timelock.emergencyPauseAll("incident");

        vm.prank(rogue);
        vm.expectRevert(_stale(id, 0, 1));
        _executeUnpauseAll(salt);
        assertTrue(target.paused());
    }

    /// Proposer unpause operations (unpause() on any target, or emergencyUnpauseAll on the timelock)
    /// are bound to the pause epoch in which they were scheduled
    function test_ProposerUnpauseOperations_BoundToEpoch() public {
        vm.prank(guardian);
        timelock.emergencyPauseAll("incident 1");

        bytes memory unpauseData = abi.encodeCall(GovTimelockTarget.unpause, ());
        vm.startPrank(proposer);
        // Single call through the metadata path, the raw path, a batch, and the timelock self-call
        bytes32 idOp = timelock.scheduleOperation(
            address(target),
            0,
            unpauseData,
            bytes32(0),
            bytes32("op"),
            IGovernanceTimelock.OperationType.ProtocolPause,
            ""
        );
        timelock.schedule(address(target), 0, unpauseData, bytes32(0), bytes32("raw"), MIN);
        bytes32 idRaw = timelock.hashOperation(address(target), 0, unpauseData, bytes32(0), bytes32("raw"));
        address[] memory targets = new address[](2);
        targets[0] = address(target);
        targets[1] = address(target);
        bytes[] memory payloads = new bytes[](2);
        payloads[0] = _setFeeData(9);
        payloads[1] = unpauseData;
        uint256[] memory values = new uint256[](2);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), bytes32("batch"), MIN);
        bytes32 idBatch = timelock.hashOperationBatch(targets, values, payloads, bytes32(0), bytes32("batch"));
        timelock.schedule(address(timelock), 0, UNPAUSE_ALL, bytes32(0), bytes32("self"), LONG);
        bytes32 idSelf = timelock.hashOperation(address(timelock), 0, UNPAUSE_ALL, bytes32(0), bytes32("self"));
        vm.stopPrank();

        vm.prank(guardian);
        timelock.emergencyPauseAll("incident 2");
        vm.warp(T0 + LONG);

        vm.expectRevert(_stale(idOp, 1, 2));
        timelock.executeOperation(address(target), 0, unpauseData, bytes32(0), bytes32("op"));
        vm.expectRevert(_stale(idRaw, 1, 2));
        timelock.execute(address(target), 0, unpauseData, bytes32(0), bytes32("raw"));
        vm.expectRevert(_stale(idBatch, 1, 2));
        timelock.executeBatch(targets, values, payloads, bytes32(0), bytes32("batch"));
        vm.expectRevert(_stale(idSelf, 1, 2));
        timelock.execute(address(timelock), 0, UNPAUSE_ALL, bytes32(0), bytes32("self"));
        assertTrue(target.paused());

        // Re-scheduled in the current epoch, the governance self-call unpauses
        vm.startPrank(proposer);
        timelock.cancel(idSelf);
        timelock.schedule(address(timelock), 0, UNPAUSE_ALL, bytes32(0), bytes32("self"), LONG);
        vm.stopPrank();
        vm.warp(T0 + 2 * LONG);
        timelock.execute(address(timelock), 0, UNPAUSE_ALL, bytes32(0), bytes32("self"));
        assertFalse(target.paused());
    }

    /// Operations that do not unpause are not affected by the pause epoch
    function test_NonUnpauseOperations_IgnoreEpoch() public {
        bytes memory data = _setFeeData(4);
        vm.prank(proposer);
        timelock.schedule(address(target), 0, data, bytes32(0), bytes32(0), MIN);
        vm.prank(guardian);
        bytes32 eid =
            timelock.executeEmergency(address(target), abi.encodeCall(GovTimelockTarget.revokeThing, (stranger)), "x");

        vm.prank(guardian);
        timelock.emergencyPauseAll("incident");
        vm.warp(T0 + MIN);

        timelock.execute(address(target), 0, data, bytes32(0), bytes32(0));
        timelock.execute(
            address(target), 0, abi.encodeCall(GovTimelockTarget.revokeThing, (stranger)), bytes32(0), _emergencySalt(1)
        );
        assertEq(target.fee(), 4);
        assertTrue(target.revoked(stranger));
        assertTrue(timelock.isOperationDone(eid));
    }

    function test_SelfCallUnpause_OnlyFromTheTimelock() public {
        vm.prank(guardian);
        timelock.emergencyPauseAll("incident");

        // The unpausing branch runs only when the timelock calls itself (a matured operation)
        vm.prank(address(timelock));
        assertEq(timelock.emergencyUnpauseAll(), bytes32(0));
        assertFalse(target.paused());
        assertEq(timelock.emergencyNonce(), 0);
    }

    /// REGRESSION: unpause() can never be classified Emergency (no unpause path at emergencyDelay)
    function test_SetCallClass_UnpauseCannotBeEmergency() public {
        bytes4 sel = GovTimelockTarget.unpause.selector;
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernanceTimelock.InvalidCallClass.selector,
                address(target),
                sel,
                IGovernanceTimelock.CallClass.Emergency
            )
        );
        timelock.setCallClass(address(target), sel, IGovernanceTimelock.CallClass.Emergency);

        vm.startPrank(admin);
        timelock.setCallClass(address(target), sel, IGovernanceTimelock.CallClass.LongDelay);
        timelock.setCallClass(address(target), sel, IGovernanceTimelock.CallClass.Standard);
        vm.stopPrank();

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IGovernanceTimelock.NotEmergencyCall.selector, address(target), sel));
        timelock.executeEmergency(address(target), abi.encodeCall(GovTimelockTarget.unpause, ()), "x");
    }

    // =====================================================================
    // (4) Execution can never be bricked
    // =====================================================================

    /// REGRESSION: closing open execution without an explicit executor bricked every operation
    function test_SetOpenExecutor_CannotCloseWithoutExplicitExecutor() public {
        assertEq(timelock.getExecutorCount(), 1);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IGovernanceTimelock.LastExecutor.selector, address(0)));
        timelock.setOpenExecutor(false);

        // Nor through the raw AccessControl path
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IGovernanceTimelock.LastExecutor.selector, address(0)));
        timelock.revokeRole(EXECUTOR_ROLE, address(0));

        assertTrue(timelock.getTimelockConfig().openExecutor);
        bytes memory data = _setFeeData(3);
        vm.prank(proposer);
        timelock.schedule(address(target), 0, data, bytes32(0), bytes32(0), MIN);
        vm.warp(T0 + MIN);
        vm.prank(stranger);
        timelock.execute(address(target), 0, data, bytes32(0), bytes32(0));
        assertEq(target.fee(), 3);
    }

    function test_SetOpenExecutor_ClosesWithExplicitExecutor() public {
        address executor = makeAddr("executor");
        vm.startPrank(admin);
        timelock.grantRole(EXECUTOR_ROLE, executor);
        timelock.setOpenExecutor(false);
        vm.stopPrank();
        assertFalse(timelock.getTimelockConfig().openExecutor);
        assertEq(timelock.getExecutorCount(), 1);

        // The last explicit executor can be neither revoked nor renounced
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IGovernanceTimelock.LastExecutor.selector, executor));
        timelock.revokeRole(EXECUTOR_ROLE, executor);
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(IGovernanceTimelock.LastExecutor.selector, executor));
        timelock.renounceRole(EXECUTOR_ROLE, executor);

        // Re-opening, then removing the explicit executor, is fine
        vm.startPrank(admin);
        timelock.setOpenExecutor(true);
        timelock.revokeRole(EXECUTOR_ROLE, executor);
        vm.stopPrank();
        assertEq(timelock.getExecutorCount(), 1);
        assertTrue(timelock.getTimelockConfig().openExecutor);

        // Closing a timelock that is already closed for address(0) is a no-op
        vm.startPrank(admin);
        timelock.grantRole(EXECUTOR_ROLE, executor);
        timelock.setOpenExecutor(false);
        timelock.setOpenExecutor(false);
        vm.stopPrank();
        assertEq(timelock.getExecutorCount(), 1);
    }

    function test_ExecutorCount_ConstructorAndDuplicates() public {
        address e1 = makeAddr("e1");
        address[] memory executors = new address[](3);
        executors[0] = e1;
        executors[1] = e1; // duplicate
        executors[2] = makeAddr("e2");
        GovernanceTimelock closed = new GovernanceTimelock(MIN, _one(proposer), executors, admin);
        assertEq(closed.getExecutorCount(), 2);
        assertFalse(closed.getTimelockConfig().openExecutor);

        vm.prank(admin);
        closed.revokeRole(EXECUTOR_ROLE, e1);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IGovernanceTimelock.LastExecutor.selector, executors[2]));
        closed.revokeRole(EXECUTOR_ROLE, executors[2]);

        // Revoking a non-holder changes nothing
        vm.prank(admin);
        closed.revokeRole(EXECUTOR_ROLE, stranger);
        assertEq(closed.getExecutorCount(), 1);
    }

    /// After the bootstrap admin renounces, a self-operation cannot brick execution either
    function test_SelfOperationCannotRemoveLastExecutor() public {
        vm.prank(admin);
        timelock.renounceRole(DEFAULT_ADMIN_ROLE, admin);

        bytes memory data = abi.encodeCall(IGovernanceTimelock.setOpenExecutor, (false));
        vm.prank(proposer);
        timelock.schedule(address(timelock), 0, data, bytes32(0), bytes32(0), LONG);
        vm.warp(T0 + LONG);
        vm.expectRevert(abi.encodeWithSelector(IGovernanceTimelock.LastExecutor.selector, address(0)));
        timelock.execute(address(timelock), 0, data, bytes32(0), bytes32(0));
        assertTrue(timelock.getTimelockConfig().openExecutor);
    }

    // =====================================================================
    // (6) Batch length-check ordering and the 7-argument label floor
    // =====================================================================

    /// The length check runs before any element is read: more targets than payloads must give OZ's
    /// length error, not an out-of-bounds panic
    function test_BatchLengthCheck_BeforeElementAccess() public {
        address[] memory targets = new address[](2);
        targets[0] = address(target);
        targets[1] = address(target);
        uint256[] memory values = new uint256[](2);
        bytes[] memory payloads = _oneData(_setFeeData(1));
        bytes memory lengthError =
            abi.encodeWithSelector(TimelockController.TimelockInvalidOperationLength.selector, 2, 1, 2);

        vm.startPrank(proposer);
        vm.expectRevert(lengthError);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), bytes32(0), MIN);
        vm.expectRevert(lengthError);
        timelock.scheduleBatch(
            targets, values, payloads, bytes32(0), bytes32(0), IGovernanceTimelock.OperationType.ParameterChange, ""
        );
        vm.stopPrank();
    }

    /// The length check also wins over the delay check, even when the first call needs longDelay
    function test_BatchLengthCheck_BeforeDelayCheck() public {
        address[] memory targets = new address[](2);
        targets[0] = address(target);
        targets[1] = address(target);
        uint256[] memory values = new uint256[](2);
        bytes[] memory payloads = _oneData(abi.encodeCall(Ownable.transferOwnership, (stranger)));
        bytes memory lengthError =
            abi.encodeWithSelector(TimelockController.TimelockInvalidOperationLength.selector, 2, 1, 2);

        vm.startPrank(proposer);
        vm.expectRevert(lengthError);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), bytes32(0), 0);
        vm.expectRevert(lengthError);
        timelock.scheduleBatch(
            targets, values, payloads, bytes32(0), bytes32(0), IGovernanceTimelock.OperationType.ParameterChange, ""
        );
        // ...and over the reserved-label check of the 7-argument form
        vm.expectRevert(lengthError);
        timelock.scheduleBatch(
            targets, values, payloads, bytes32(0), bytes32(0), IGovernanceTimelock.OperationType.EmergencyAction, ""
        );
        vm.stopPrank();
    }

    /// The 7-argument scheduleBatch label floor on its own: an all-standard batch labelled
    /// ContractUpgrade or OwnershipTransfer needs longDelay
    function test_ScheduleBatch7_LabelFloorAlone() public {
        address[] memory targets = new address[](2);
        targets[0] = address(target);
        targets[1] = address(target);
        uint256[] memory values = new uint256[](2);
        bytes[] memory payloads = new bytes[](2);
        payloads[0] = _setFeeData(1);
        payloads[1] = _setFeeData(2);

        // Content alone needs only minDelay
        vm.prank(proposer);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), bytes32("raw"), MIN);

        IGovernanceTimelock.OperationType[3] memory labels = [
            IGovernanceTimelock.OperationType.ContractUpgrade,
            IGovernanceTimelock.OperationType.OwnershipTransfer,
            IGovernanceTimelock.OperationType.TreasuryOperation
        ];
        uint256[3] memory expected = [LONG, LONG, MIN];
        for (uint256 i = 0; i < labels.length; ++i) {
            vm.prank(proposer);
            bytes32 id = timelock.scheduleBatch(targets, values, payloads, bytes32(0), bytes32(i + 1), labels[i], "");
            assertEq(timelock.getTimestamp(id), T0 + expected[i]);
            assertEq(timelock.getOperation(id).readyAt, T0 + expected[i]);
            assertEq(uint256(timelock.getOperation(id).opType), uint256(labels[i]));
        }

        // A labelled long batch is not executable at minDelay
        bytes32 upgradeId = timelock.hashOperationBatch(targets, values, payloads, bytes32(0), bytes32(uint256(1)));
        vm.warp(T0 + MIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockController.TimelockUnexpectedOperationState.selector, upgradeId, _readyBitmap()
            )
        );
        timelock.executeBatch(targets, values, payloads, bytes32(0), bytes32(uint256(1)));
    }

    // =====================================================================
    // (8) Stored config no longer carries openExecutor
    // =====================================================================

    function test_TimelockConfig_OpenExecutorDerivedFromRole() public {
        address executor = makeAddr("executor");
        vm.startPrank(admin);
        timelock.grantRole(EXECUTOR_ROLE, executor);
        timelock.revokeRole(EXECUTOR_ROLE, address(0));
        vm.stopPrank();
        IGovernanceTimelock.TimelockConfig memory cfg = timelock.getTimelockConfig();
        assertFalse(cfg.openExecutor);
        assertEq(cfg.minDelay, MIN);
        assertEq(cfg.emergencyDelay, EMERGENCY);
        assertEq(cfg.longDelay, LONG);

        vm.prank(admin);
        timelock.grantRole(EXECUTOR_ROLE, address(0));
        assertTrue(timelock.getTimelockConfig().openExecutor);
    }
}
