// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {GovernanceTimelockFixture, GovTimelockTarget} from "./GovernanceTimelock.t.sol";
import {GovernanceTimelock} from "../contracts/modules/GovernanceTimelock.sol";
import {IGovernanceTimelock} from "../contracts/interfaces/IGovernanceTimelock.sol";

/**
 * @notice Regression tests for two GovernanceTimelock liveness follow-ups:
 *         (1) the timelock's own EXECUTOR_ROLE does not count as a live executor, so the last-executor
 *             guard cannot be satisfied by an account that can never initiate an execution;
 *         (2) unpause operations made stale by a later emergencyPauseAll are reported Stale (not
 *             Ready) by the governance metadata and leave the pending list, while OZ's own state views
 *             stay untouched.
 */
contract GovernanceTimelockLivenessTest is GovernanceTimelockFixture {
    bytes internal constant UNPAUSE_ALL = abi.encodeWithSelector(IGovernanceTimelock.emergencyUnpauseAll.selector);

    function setUp() public override {
        super.setUp();
        vm.prank(admin);
        timelock.registerProtocolContract("ilrm", address(target));
    }

    // =====================================================================
    // Helpers
    // =====================================================================

    function _status(bytes32 id) internal view returns (IGovernanceTimelock.OperationStatus) {
        return timelock.getOperation(id).status;
    }

    function _lastExecutor(address account) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IGovernanceTimelock.LastExecutor.selector, account);
    }

    function _stale(bytes32 id, uint256 scheduledEpoch, uint256 currentEpoch) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IGovernanceTimelock.StaleUnpause.selector, id, scheduledEpoch, currentEpoch);
    }

    function _unpauseData() internal pure returns (bytes memory) {
        return abi.encodeCall(GovTimelockTarget.unpause, ());
    }

    function _guardianUnpause() internal returns (bytes32 id, bytes32 salt) {
        vm.prank(guardian);
        id = timelock.emergencyUnpauseAll();
        salt = timelock.getOperation(id).salt;
    }

    function _contains(bytes32[] memory ids, bytes32 id) internal pure returns (bool) {
        for (uint256 i = 0; i < ids.length; ++i) {
            if (ids[i] == id) return true;
        }
        return false;
    }

    function _assertStatus(bytes32 id, IGovernanceTimelock.OperationStatus expected) internal view {
        assertEq(uint256(_status(id)), uint256(expected));
    }

    // =====================================================================
    // (1) The timelock itself is not a live executor
    // =====================================================================

    /// REGRESSION: with EXECUTOR_ROLE granted to the timelock, closing open execution left the timelock
    /// as the only holder, and nobody could initiate an execution again
    function test_TimelockExecutorRole_DoesNotKeepOpenExecutionClosable() public {
        vm.prank(admin);
        timelock.grantRole(EXECUTOR_ROLE, address(timelock));
        assertTrue(timelock.hasRole(EXECUTOR_ROLE, address(timelock)));
        assertEq(timelock.getExecutorCount(), 1); // address(0) only

        vm.prank(admin);
        vm.expectRevert(_lastExecutor(address(0)));
        timelock.setOpenExecutor(false);
        vm.prank(admin);
        vm.expectRevert(_lastExecutor(address(0)));
        timelock.revokeRole(EXECUTOR_ROLE, address(0));
        assertTrue(timelock.getTimelockConfig().openExecutor);

        // Anyone can still execute
        bytes memory data = _setFeeData(5);
        vm.prank(proposer);
        timelock.schedule(address(target), 0, data, bytes32(0), bytes32(0), MIN);
        vm.warp(T0 + MIN);
        vm.prank(stranger);
        timelock.execute(address(target), 0, data, bytes32(0), bytes32(0));
        assertEq(target.fee(), 5);
    }

    /// REGRESSION: with closed execution, the last explicit executor could be revoked or renounced as
    /// long as the timelock also held EXECUTOR_ROLE
    function test_TimelockExecutorRole_DoesNotStandInForLastExplicitExecutor() public {
        address executor = makeAddr("executor");
        vm.startPrank(admin);
        timelock.grantRole(EXECUTOR_ROLE, executor);
        timelock.grantRole(EXECUTOR_ROLE, address(timelock));
        timelock.setOpenExecutor(false);
        vm.stopPrank();
        assertEq(timelock.getExecutorCount(), 1);

        vm.prank(admin);
        vm.expectRevert(_lastExecutor(executor));
        timelock.revokeRole(EXECUTOR_ROLE, executor);
        vm.prank(executor);
        vm.expectRevert(_lastExecutor(executor));
        timelock.renounceRole(EXECUTOR_ROLE, executor);

        // The same revocation as a matured self-operation (after the bootstrap admin renounced)
        vm.prank(admin);
        timelock.renounceRole(DEFAULT_ADMIN_ROLE, admin);
        bytes memory revokeData = abi.encodeCall(timelock.revokeRole, (EXECUTOR_ROLE, executor));
        vm.prank(proposer);
        timelock.schedule(address(timelock), 0, revokeData, bytes32(0), bytes32(0), LONG);
        vm.warp(T0 + LONG);
        vm.prank(executor);
        vm.expectRevert(_lastExecutor(executor));
        timelock.execute(address(timelock), 0, revokeData, bytes32(0), bytes32(0));
        assertTrue(timelock.hasRole(EXECUTOR_ROLE, executor));

        // The explicit executor can still execute; a stranger cannot
        bytes memory data = _setFeeData(6);
        vm.prank(proposer);
        timelock.schedule(address(target), 0, data, bytes32(0), bytes32("fee"), MIN);
        vm.warp(T0 + LONG + MIN);
        vm.prank(stranger);
        vm.expectRevert(_unauthorized(stranger, EXECUTOR_ROLE));
        timelock.execute(address(target), 0, data, bytes32(0), bytes32("fee"));
        vm.prank(executor);
        timelock.execute(address(target), 0, data, bytes32(0), bytes32("fee"));
        assertEq(target.fee(), 6);
    }

    /// The timelock's own EXECUTOR_ROLE is not counted, so removing it is always allowed
    function test_TimelockExecutorRole_AlwaysRemovable() public {
        vm.startPrank(admin);
        timelock.grantRole(EXECUTOR_ROLE, address(timelock));
        timelock.grantRole(EXECUTOR_ROLE, address(timelock)); // duplicate grant: no-op
        assertEq(timelock.getExecutorCount(), 1);
        timelock.revokeRole(EXECUTOR_ROLE, address(timelock));
        timelock.revokeRole(EXECUTOR_ROLE, address(timelock)); // non-holder: no-op
        vm.stopPrank();
        assertFalse(timelock.hasRole(EXECUTOR_ROLE, address(timelock)));
        assertEq(timelock.getExecutorCount(), 1);

        // The timelock renouncing its own role through a self-operation is fine too
        vm.prank(admin);
        timelock.grantRole(EXECUTOR_ROLE, address(timelock));
        bytes memory data = abi.encodeCall(timelock.renounceRole, (EXECUTOR_ROLE, address(timelock)));
        vm.prank(proposer);
        timelock.schedule(address(timelock), 0, data, bytes32(0), bytes32(0), LONG);
        vm.warp(T0 + LONG);
        timelock.execute(address(timelock), 0, data, bytes32(0), bytes32(0));
        assertFalse(timelock.hasRole(EXECUTOR_ROLE, address(timelock)));
        assertEq(timelock.getExecutorCount(), 1);
    }

    /// A constructor executor list naming only the timelock itself would deploy a bricked timelock
    function test_Constructor_TimelockAsOnlyExecutorRejected() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(_lastExecutor(predicted));
        new GovernanceTimelock(MIN, _one(proposer), _one(predicted), admin);

        // Next to a live executor it is accepted, but not counted
        address e1 = makeAddr("e1");
        predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        address[] memory executors = new address[](2);
        executors[0] = predicted;
        executors[1] = e1;
        GovernanceTimelock t = new GovernanceTimelock(MIN, _one(proposer), executors, admin);
        assertEq(address(t), predicted);
        assertTrue(t.hasRole(EXECUTOR_ROLE, address(t)));
        assertEq(t.getExecutorCount(), 1);
        assertFalse(t.getTimelockConfig().openExecutor);

        vm.prank(admin);
        vm.expectRevert(_lastExecutor(e1));
        t.revokeRole(EXECUTOR_ROLE, e1);
    }

    // =====================================================================
    // (2) Stale unpauses are reported stale, not ready, and leave the pending list
    // =====================================================================

    /// REGRESSION: an unpause made unexecutable by a later emergencyPauseAll was still reported Ready by
    /// getOperation and stayed in getPendingOperations
    function test_StaleUnpause_MetadataReportsStale() public {
        vm.prank(guardian);
        timelock.emergencyPauseAll("incident 1");

        // Epoch 1: a guardian unpause, a proposer unpause (metadata and raw), a batch containing an
        // unpause, and an operation that does not unpause
        (bytes32 idGuardian, bytes32 saltGuardian) = _guardianUnpause();
        vm.startPrank(proposer);
        bytes32 idOp = timelock.scheduleOperation(
            address(target),
            0,
            _unpauseData(),
            bytes32(0),
            bytes32("op"),
            IGovernanceTimelock.OperationType.ProtocolPause,
            ""
        );
        timelock.schedule(address(target), 0, _unpauseData(), bytes32(0), bytes32("raw"), MIN);
        bytes32 idRaw = timelock.hashOperation(address(target), 0, _unpauseData(), bytes32(0), bytes32("raw"));
        address[] memory targets = new address[](2);
        targets[0] = address(target);
        targets[1] = address(target);
        bytes[] memory payloads = new bytes[](2);
        payloads[0] = _setFeeData(9);
        payloads[1] = _unpauseData();
        bytes32 idBatch = timelock.scheduleBatch(
            targets,
            new uint256[](2),
            payloads,
            bytes32(0),
            bytes32("batch"),
            IGovernanceTimelock.OperationType.ProtocolPause,
            ""
        );
        bytes32 idFee = timelock.scheduleOperation(
            address(target),
            0,
            _setFeeData(7),
            bytes32(0),
            bytes32("fee"),
            IGovernanceTimelock.OperationType.ParameterChange,
            ""
        );
        vm.stopPrank();

        // Same epoch: nothing is stale
        _assertStatus(idGuardian, IGovernanceTimelock.OperationStatus.Pending);
        assertFalse(timelock.isOperationStale(idGuardian));
        assertFalse(timelock.isOperationStale(idRaw));
        assertEq(timelock.getPendingOperationsCount(), 4);
        assertEq(timelock.getStaleOperations().length, 0);

        vm.prank(guardian);
        timelock.emergencyPauseAll("incident 2");

        // Stale while still waiting
        _assertStatus(idGuardian, IGovernanceTimelock.OperationStatus.Stale);
        assertTrue(timelock.isOperationStale(idGuardian));
        assertTrue(timelock.isOperationPending(idGuardian));
        assertFalse(timelock.isOperationReady(idGuardian));

        vm.warp(T0 + MIN);

        // OZ's state views are untouched: the delay passed, so OZ reports them ready ...
        assertTrue(timelock.isOperationReady(idGuardian));
        assertTrue(timelock.isOperationReady(idOp));
        assertTrue(timelock.isOperationReady(idRaw));
        assertTrue(timelock.isOperationReady(idBatch));
        // ... but none of them can execute
        vm.expectRevert(_stale(idGuardian, 1, 2));
        timelock.execute(address(timelock), 0, UNPAUSE_ALL, bytes32(0), saltGuardian);
        vm.expectRevert(_stale(idOp, 1, 2));
        timelock.execute(address(target), 0, _unpauseData(), bytes32(0), bytes32("op"));

        // The governance metadata says so
        _assertStatus(idGuardian, IGovernanceTimelock.OperationStatus.Stale);
        _assertStatus(idOp, IGovernanceTimelock.OperationStatus.Stale);
        _assertStatus(idBatch, IGovernanceTimelock.OperationStatus.Stale);
        _assertStatus(idRaw, IGovernanceTimelock.OperationStatus.None); // raw schedule: no metadata
        _assertStatus(idFee, IGovernanceTimelock.OperationStatus.Ready);
        assertTrue(timelock.isOperationStale(idGuardian));
        assertTrue(timelock.isOperationStale(idOp));
        assertTrue(timelock.isOperationStale(idRaw)); // covers raw schedules
        assertTrue(timelock.isOperationStale(idBatch));
        assertFalse(timelock.isOperationStale(idFee));
        assertFalse(timelock.isOperationStale(keccak256("unknown")));

        // Only what can still execute is pending; the stale ones are listed separately
        bytes32[] memory pending = timelock.getPendingOperations();
        assertEq(pending.length, 1);
        assertEq(pending[0], idFee);
        assertEq(timelock.getPendingOperationsCount(), 1);
        bytes32[] memory stale = timelock.getStaleOperations();
        assertEq(stale.length, 3);
        assertTrue(_contains(stale, idGuardian));
        assertTrue(_contains(stale, idOp));
        assertTrue(_contains(stale, idBatch));

        // A fresh unpause queued in the current epoch is live
        (bytes32 idFresh, bytes32 saltFresh) = _guardianUnpause();
        assertFalse(timelock.isOperationStale(idFresh));
        _assertStatus(idFresh, IGovernanceTimelock.OperationStatus.Pending);
        assertTrue(_contains(timelock.getPendingOperations(), idFresh));
        assertEq(timelock.getPendingOperationsCount(), 2);

        // Cancelling clears a stale operation everywhere
        vm.startPrank(proposer);
        timelock.cancel(idGuardian);
        timelock.cancel(idRaw);
        vm.stopPrank();
        _assertStatus(idGuardian, IGovernanceTimelock.OperationStatus.Cancelled);
        assertFalse(timelock.isOperationStale(idGuardian));
        assertFalse(timelock.isOperationStale(idRaw));
        stale = timelock.getStaleOperations();
        assertEq(stale.length, 2);
        assertFalse(_contains(stale, idGuardian));

        // An executed unpause is Executed, never Stale, even after a later pause
        vm.warp(T0 + 2 * MIN);
        timelock.execute(address(timelock), 0, UNPAUSE_ALL, bytes32(0), saltFresh);
        assertFalse(target.paused());
        vm.prank(guardian);
        timelock.emergencyPauseAll("incident 3");
        _assertStatus(idFresh, IGovernanceTimelock.OperationStatus.Executed);
        assertFalse(timelock.isOperationStale(idFresh));
        _assertStatus(idOp, IGovernanceTimelock.OperationStatus.Stale);

        // The operation that does not unpause executes normally and leaves the list
        timelock.execute(address(target), 0, _setFeeData(7), bytes32(0), bytes32("fee"));
        _assertStatus(idFee, IGovernanceTimelock.OperationStatus.Executed);
        assertEq(timelock.getPendingOperationsCount(), 0);
        assertEq(timelock.getPendingOperations().length, 0);
        assertEq(timelock.getStaleOperations().length, 2);
    }

    /// Re-scheduling a cancelled stale proposer unpause binds it to the current epoch again
    function test_StaleUnpause_RescheduledInCurrentEpochIsLive() public {
        vm.prank(guardian);
        timelock.emergencyPauseAll("incident 1");
        vm.prank(proposer);
        bytes32 id = timelock.scheduleOperation(
            address(target),
            0,
            _unpauseData(),
            bytes32(0),
            bytes32("op"),
            IGovernanceTimelock.OperationType.ProtocolPause,
            ""
        );
        vm.prank(guardian);
        timelock.emergencyPauseAll("incident 2");
        assertTrue(timelock.isOperationStale(id));

        vm.startPrank(proposer);
        timelock.cancel(id);
        bytes32 again = timelock.scheduleOperation(
            address(target),
            0,
            _unpauseData(),
            bytes32(0),
            bytes32("op"),
            IGovernanceTimelock.OperationType.ProtocolPause,
            ""
        );
        vm.stopPrank();
        assertEq(again, id);
        assertFalse(timelock.isOperationStale(id));
        _assertStatus(id, IGovernanceTimelock.OperationStatus.Pending);
        assertEq(timelock.getStaleOperations().length, 0);

        vm.warp(T0 + MIN);
        _assertStatus(id, IGovernanceTimelock.OperationStatus.Ready);
        assertEq(timelock.getPendingOperations()[0], id);
        timelock.execute(address(target), 0, _unpauseData(), bytes32(0), bytes32("op"));
        assertFalse(target.paused());
    }
}
