// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/modules/GovernanceTimelock.sol";
import "../contracts/AssetRegistry.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/access/IAccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @notice Test-local protocol contract owned by the timelock
contract GovTimelockTarget is Ownable2Step, Pausable {
    uint256 public fee;
    mapping(address => bool) public revoked;
    address public implementation;
    uint256 public multicallCount;

    constructor() Ownable(msg.sender) {}

    function setFee(uint256 newFee) external onlyOwner {
        fee = newFee;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function revokeThing(address who) external onlyOwner {
        revoked[who] = true;
    }

    /// @dev Stub with the UUPS upgrade signature
    function upgradeToAndCall(address newImplementation, bytes calldata) external payable onlyOwner {
        implementation = newImplementation;
    }

    /// @dev Stub with the multicall signature
    function multicall(bytes[] calldata) external onlyOwner {
        multicallCount++;
    }
}

/// @notice Shared fixture and helpers
abstract contract GovernanceTimelockFixture is Test {
    GovernanceTimelock internal timelock;
    GovTimelockTarget internal target;

    address internal admin = makeAddr("admin");
    address internal proposer = makeAddr("proposer");
    address internal guardian = makeAddr("guardian");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant MIN = 2 days;
    uint256 internal constant EMERGENCY = 12 hours;
    uint256 internal constant LONG = 4 days;
    uint256 internal constant T0 = 1_700_000_000;

    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal PROPOSER_ROLE;
    bytes32 internal EXECUTOR_ROLE;
    bytes32 internal CANCELLER_ROLE;
    bytes32 internal EMERGENCY_ROLE;

    bytes32 internal constant SALT_MASK = ~bytes32(uint256(type(uint160).max));
    bytes32 internal constant EMERGENCY_PREFIX = keccak256("ILRM.GovernanceTimelock.emergency-salt") & SALT_MASK;

    function setUp() public virtual {
        vm.warp(T0);

        address[] memory proposers = new address[](1);
        proposers[0] = proposer;
        address[] memory executors = new address[](0);
        timelock = new GovernanceTimelock(MIN, proposers, executors, admin);

        PROPOSER_ROLE = timelock.PROPOSER_ROLE();
        EXECUTOR_ROLE = timelock.EXECUTOR_ROLE();
        CANCELLER_ROLE = timelock.CANCELLER_ROLE();
        EMERGENCY_ROLE = timelock.EMERGENCY_ROLE();

        vm.prank(admin);
        timelock.grantRole(EMERGENCY_ROLE, guardian);

        target = new GovTimelockTarget();
        target.transferOwnership(address(timelock));
        vm.prank(admin);
        timelock.acceptContractOwnership(address(target));

        vm.startPrank(admin);
        timelock.setCallClass(
            address(target), GovTimelockTarget.pause.selector, IGovernanceTimelock.CallClass.Emergency
        );
        timelock.setCallClass(
            address(target), GovTimelockTarget.revokeThing.selector, IGovernanceTimelock.CallClass.Emergency
        );
        vm.stopPrank();
    }

    function _emergencySalt(uint256 nonce) internal pure returns (bytes32) {
        return EMERGENCY_PREFIX | bytes32(nonce);
    }

    function _readyBitmap() internal pure returns (bytes32) {
        return bytes32(uint256(1) << uint8(TimelockController.OperationState.Ready));
    }

    function _setFeeData(uint256 newFee) internal pure returns (bytes memory) {
        return abi.encodeCall(GovTimelockTarget.setFee, (newFee));
    }

    function _pauseData() internal pure returns (bytes memory) {
        return abi.encodeCall(GovTimelockTarget.pause, ());
    }

    function _one(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _oneValue(uint256 v) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = v;
    }

    function _oneData(bytes memory d) internal pure returns (bytes[] memory arr) {
        arr = new bytes[](1);
        arr[0] = d;
    }

    function _unauthorized(address account, bytes32 role) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, account, role);
    }

    function _insufficientDelay(uint256 delay, uint256 required) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(TimelockController.TimelockInsufficientDelay.selector, delay, required);
    }

    function _lockedSignatures() internal pure returns (string[13] memory sigs) {
        sigs = [
            "transferOwnership(address)",
            "renounceOwnership()",
            "grantRole(bytes32,address)",
            "revokeRole(bytes32,address)",
            "renounceRole(bytes32,address)",
            "beginDefaultAdminTransfer(address)",
            "upgradeTo(address)",
            "upgradeToAndCall(address,bytes)",
            "upgradeAndCall(address,address,bytes)",
            "upgrade(address,address)",
            "changeAdmin(address)",
            "changeProxyAdmin(address,address)",
            "multicall(bytes[])"
        ];
    }

    function _isLocked(bytes4 sel) internal pure returns (bool) {
        string[13] memory sigs = _lockedSignatures();
        for (uint256 i = 0; i < sigs.length; ++i) {
            if (sel == bytes4(keccak256(bytes(sigs[i])))) return true;
        }
        return false;
    }
}

contract GovernanceTimelockTest is GovernanceTimelockFixture {
    event MinDelayChange(uint256 oldDuration, uint256 newDuration);
    event TimelockConfigUpdated(uint256 minDelay, uint256 emergencyDelay, uint256 longDelay);
    event CallClassUpdated(address indexed target, bytes4 indexed selector, IGovernanceTimelock.CallClass callClass);

    // =====================================================================
    // Constructor / config
    // =====================================================================

    function test_Constructor_DefaultDelays() public view {
        IGovernanceTimelock.TimelockConfig memory cfg = timelock.getTimelockConfig();
        assertEq(cfg.minDelay, MIN);
        assertEq(cfg.emergencyDelay, EMERGENCY);
        assertEq(cfg.longDelay, LONG);
        assertTrue(cfg.openExecutor);
        assertEq(timelock.getMinDelay(), MIN);
        assertEq(timelock.emergencyNonce(), 0);
    }

    function test_Constructor_RejectsOutOfRangeMinDelay() public {
        address[] memory none = new address[](0);

        vm.expectRevert(bytes("Delay too short"));
        new GovernanceTimelock(1 hours - 1, none, none, admin);

        vm.expectRevert(bytes("Delay too long"));
        new GovernanceTimelock(30 days + 1, none, none, admin);

        // Boundaries are accepted and the derived defaults satisfy the delay bounds without clamping
        GovernanceTimelock lo = new GovernanceTimelock(1 hours, none, none, admin);
        IGovernanceTimelock.TimelockConfig memory cfg = lo.getTimelockConfig();
        assertEq(cfg.emergencyDelay, 15 minutes);
        assertEq(cfg.longDelay, 2 hours);

        GovernanceTimelock hi = new GovernanceTimelock(30 days, none, none, admin);
        cfg = hi.getTimelockConfig();
        assertEq(cfg.emergencyDelay, 7.5 days);
        assertEq(cfg.longDelay, 60 days);
    }

    /// REGRESSION: an empty executor list must really open execution
    function test_Constructor_EmptyExecutorsOpensExecution() public {
        assertTrue(timelock.hasRole(EXECUTOR_ROLE, address(0)));

        bytes memory data = _setFeeData(7);
        vm.prank(proposer);
        timelock.schedule(address(target), 0, data, bytes32(0), bytes32("open"), MIN);

        vm.warp(T0 + MIN);
        vm.prank(stranger);
        timelock.execute(address(target), 0, data, bytes32(0), bytes32("open"));
        assertEq(target.fee(), 7);
    }

    function test_Constructor_ExplicitExecutorsStayClosed() public {
        address executor = makeAddr("executor");
        GovernanceTimelock closed = new GovernanceTimelock(MIN, _one(proposer), _one(executor), admin);
        assertFalse(closed.hasRole(EXECUTOR_ROLE, address(0)));
        assertFalse(closed.getTimelockConfig().openExecutor);

        GovTimelockTarget t2 = new GovTimelockTarget();
        t2.transferOwnership(address(closed));
        vm.prank(admin);
        closed.acceptContractOwnership(address(t2));

        bytes memory data = _setFeeData(9);
        vm.prank(proposer);
        closed.schedule(address(t2), 0, data, bytes32(0), bytes32(0), MIN);
        vm.warp(T0 + MIN);

        vm.prank(stranger);
        vm.expectRevert(_unauthorized(stranger, EXECUTOR_ROLE));
        closed.execute(address(t2), 0, data, bytes32(0), bytes32(0));

        vm.prank(executor);
        closed.execute(address(t2), 0, data, bytes32(0), bytes32(0));
        assertEq(t2.fee(), 9);
    }

    /// REGRESSION: the bootstrap admin is not auto-granted EMERGENCY_ROLE
    function test_Constructor_AdminNotGrantedEmergencyRole() public {
        assertFalse(timelock.hasRole(EMERGENCY_ROLE, admin));

        address[] memory none = new address[](0);
        GovernanceTimelock noAdmin = new GovernanceTimelock(MIN, _one(proposer), none, address(0));
        assertFalse(noAdmin.hasRole(EMERGENCY_ROLE, address(0)));
        assertFalse(noAdmin.hasRole(DEFAULT_ADMIN_ROLE, address(0)));
        assertEq(noAdmin.getRoleAdmin(EMERGENCY_ROLE), DEFAULT_ADMIN_ROLE);
    }

    function test_Config_OpenExecutorTracksRole() public {
        // Closing execution needs an explicit executor (closing the last one reverts, see the follow-up suite)
        vm.prank(admin);
        timelock.grantRole(EXECUTOR_ROLE, makeAddr("executor"));

        vm.prank(admin);
        timelock.setOpenExecutor(false);
        assertFalse(timelock.getTimelockConfig().openExecutor);
        assertFalse(timelock.hasRole(EXECUTOR_ROLE, address(0)));

        // The reported value is derived from the role, not from the stored flag
        vm.prank(admin);
        timelock.grantRole(EXECUTOR_ROLE, address(0));
        assertTrue(timelock.getTimelockConfig().openExecutor);

        vm.prank(admin);
        timelock.revokeRole(EXECUTOR_ROLE, address(0));
        assertFalse(timelock.getTimelockConfig().openExecutor);

        vm.prank(admin);
        timelock.setOpenExecutor(true);
        assertTrue(timelock.getTimelockConfig().openExecutor);
    }

    // =====================================================================
    // Emergency path
    // =====================================================================

    /// REGRESSION: EMERGENCY_ROLE alone can queue an Emergency-classified call at emergencyDelay
    function test_Emergency_GuardianWithoutProposerSchedulesAtEmergencyDelay() public {
        assertFalse(timelock.hasRole(PROPOSER_ROLE, guardian));
        bytes memory data = _pauseData();

        vm.prank(guardian);
        bytes32 id = timelock.executeEmergency(address(target), data, "incident");

        assertEq(timelock.getTimestamp(id), T0 + EMERGENCY);
        assertEq(timelock.emergencyNonce(), 1);

        IGovernanceTimelock.GovernanceOperation memory op = timelock.getOperation(id);
        assertEq(uint256(op.opType), uint256(IGovernanceTimelock.OperationType.EmergencyAction));
        assertEq(op.salt, _emergencySalt(1));
        assertEq(op.salt & SALT_MASK, EMERGENCY_PREFIX);
        assertEq(op.target, address(target));
        assertEq(op.value, 0);
        assertEq(op.data, data);
        assertEq(op.predecessor, bytes32(0));
        assertEq(op.readyAt, T0 + EMERGENCY);
        assertEq(op.description, "incident");
        assertEq(uint256(op.status), uint256(IGovernanceTimelock.OperationStatus.Pending));
        assertEq(id, timelock.hashOperation(address(target), 0, data, bytes32(0), op.salt));
        assertEq(timelock.getPendingOperationsCount(), 1);

        vm.warp(T0 + EMERGENCY - 1);
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(TimelockController.TimelockUnexpectedOperationState.selector, id, _readyBitmap())
        );
        timelock.execute(address(target), 0, data, bytes32(0), op.salt);

        vm.warp(T0 + EMERGENCY);
        vm.prank(stranger);
        timelock.execute(address(target), 0, data, bytes32(0), op.salt);

        assertTrue(target.paused());
        assertEq(uint256(timelock.getOperation(id).status), uint256(IGovernanceTimelock.OperationStatus.Executed));
        assertEq(timelock.getPendingOperationsCount(), 0);
    }

    function test_Emergency_ProposerWithEmergencyRoleAlsoWorks() public {
        vm.prank(admin);
        timelock.grantRole(EMERGENCY_ROLE, proposer);

        vm.prank(proposer);
        bytes32 id = timelock.executeEmergency(address(target), _pauseData(), "proposer emergency");
        assertEq(timelock.getTimestamp(id), T0 + EMERGENCY);
    }

    function test_Emergency_FlagDoesNotLeak() public {
        vm.prank(guardian);
        timelock.executeEmergency(address(target), _pauseData(), "incident");

        assertEq(timelock.getMinDelay(), MIN);

        bytes memory data = _setFeeData(1);
        vm.prank(guardian);
        vm.expectRevert(_unauthorized(guardian, PROPOSER_ROLE));
        timelock.schedule(address(target), 0, data, bytes32(0), bytes32(0), MIN);

        vm.prank(proposer);
        vm.expectRevert(_insufficientDelay(EMERGENCY, MIN));
        timelock.schedule(address(target), 0, data, bytes32(0), bytes32(0), EMERGENCY);
    }

    function test_Emergency_RequiresEmergencyRole() public {
        bytes memory data = _pauseData();

        vm.prank(proposer);
        vm.expectRevert(_unauthorized(proposer, EMERGENCY_ROLE));
        timelock.executeEmergency(address(target), data, "x");

        vm.prank(stranger);
        vm.expectRevert(_unauthorized(stranger, EMERGENCY_ROLE));
        timelock.executeEmergency(address(target), data, "x");

        vm.prank(admin);
        vm.expectRevert(_unauthorized(admin, EMERGENCY_ROLE));
        timelock.executeEmergency(address(target), data, "x");
    }

    function test_Emergency_RejectsNonEmergencyCalls() public {
        // Standard call
        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernanceTimelock.NotEmergencyCall.selector, address(target), GovTimelockTarget.setFee.selector
            )
        );
        timelock.executeEmergency(address(target), _setFeeData(1), "x");

        // Locked selector
        bytes memory transfer = abi.encodeCall(Ownable.transferOwnership, (guardian));
        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernanceTimelock.NotEmergencyCall.selector, address(target), Ownable.transferOwnership.selector
            )
        );
        timelock.executeEmergency(address(target), transfer, "x");

        // Any call to the timelock itself
        bytes memory grant = abi.encodeCall(IAccessControl.grantRole, (PROPOSER_ROLE, guardian));
        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernanceTimelock.NotEmergencyCall.selector, address(timelock), IAccessControl.grantRole.selector
            )
        );
        timelock.executeEmergency(address(timelock), grant, "x");

        bytes memory pauseAll = abi.encodeCall(IGovernanceTimelock.emergencyPauseAll, ("x"));
        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernanceTimelock.NotEmergencyCall.selector,
                address(timelock),
                IGovernanceTimelock.emergencyPauseAll.selector
            )
        );
        timelock.executeEmergency(address(timelock), pauseAll, "x");

        // Calldata shorter than a selector, even if the zero selector were classified Emergency
        vm.prank(admin);
        timelock.setCallClass(address(target), bytes4(0), IGovernanceTimelock.CallClass.Emergency);

        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(IGovernanceTimelock.NotEmergencyCall.selector, address(target), bytes4(0))
        );
        timelock.executeEmergency(address(target), hex"8456cb", "x");

        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(IGovernanceTimelock.NotEmergencyCall.selector, address(target), bytes4(0))
        );
        timelock.executeEmergency(address(target), "", "x");

        assertEq(timelock.emergencyNonce(), 0);
    }

    function testFuzz_Emergency_RejectsUnclassifiedSelectors(bytes4 sel) public {
        vm.assume(sel != GovTimelockTarget.pause.selector && sel != GovTimelockTarget.revokeThing.selector);

        bytes memory data = abi.encodePacked(sel, uint256(uint160(stranger)));
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(IGovernanceTimelock.NotEmergencyCall.selector, address(target), sel));
        timelock.executeEmergency(address(target), data, "x");
    }

    /// REGRESSION: identical emergency actions in the same block get distinct ids
    function test_Emergency_SameBlockIdenticalActionsGetDistinctIds() public {
        bytes memory data = abi.encodeCall(GovTimelockTarget.revokeThing, (stranger));

        vm.startPrank(guardian);
        bytes32 id1 = timelock.executeEmergency(address(target), data, "same");
        bytes32 id2 = timelock.executeEmergency(address(target), data, "same");
        vm.stopPrank();

        assertTrue(id1 != id2);
        assertEq(timelock.getOperation(id1).salt, _emergencySalt(1));
        assertEq(timelock.getOperation(id2).salt, _emergencySalt(2));
        assertEq(timelock.emergencyNonce(), 2);
        assertEq(timelock.getPendingOperationsCount(), 2);
    }

    /// REGRESSION: a proposer cannot pre-schedule the id the guardian's next emergency action will get
    function test_Emergency_ProposerCannotSquatEmergencyId() public {
        bytes memory data = _pauseData();
        bytes32 predicted = _emergencySalt(1);
        bytes memory reserved = abi.encodeWithSelector(IGovernanceTimelock.ReservedEmergencySalt.selector, predicted);

        vm.startPrank(proposer);

        vm.expectRevert(reserved);
        timelock.schedule(address(target), 0, data, bytes32(0), predicted, LONG);

        vm.expectRevert(reserved);
        timelock.scheduleBatch(_one(address(target)), _oneValue(0), _oneData(data), bytes32(0), predicted, LONG);

        vm.expectRevert(reserved);
        timelock.scheduleOperation(
            address(target), 0, data, bytes32(0), predicted, IGovernanceTimelock.OperationType.ProtocolPause, ""
        );

        vm.expectRevert(reserved);
        timelock.scheduleBatch(
            _one(address(target)),
            _oneValue(0),
            _oneData(data),
            bytes32(0),
            predicted,
            IGovernanceTimelock.OperationType.ProtocolPause,
            ""
        );

        vm.expectRevert(reserved);
        timelock.scheduleLongDelay(
            address(target), 0, data, bytes32(0), predicted, IGovernanceTimelock.OperationType.ProtocolPause, ""
        );

        vm.stopPrank();

        vm.prank(guardian);
        bytes32 id = timelock.executeEmergency(address(target), data, "incident");
        assertEq(id, timelock.hashOperation(address(target), 0, data, bytes32(0), predicted));
        assertEq(timelock.getTimestamp(id), T0 + EMERGENCY);
    }

    function testFuzz_ReservedSaltNamespaceRejected(uint160 low) public {
        bytes32 salt = EMERGENCY_PREFIX | bytes32(uint256(low));
        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(IGovernanceTimelock.ReservedEmergencySalt.selector, salt));
        timelock.schedule(address(target), 0, _setFeeData(1), bytes32(0), salt, MIN);
    }

    function testFuzz_NonReservedSaltAccepted(bytes32 salt) public {
        vm.assume((salt & SALT_MASK) != EMERGENCY_PREFIX);
        bytes memory data = _setFeeData(1);
        vm.prank(proposer);
        timelock.schedule(address(target), 0, data, bytes32(0), salt, MIN);
        assertEq(timelock.getTimestamp(timelock.hashOperation(address(target), 0, data, bytes32(0), salt)), T0 + MIN);
    }

    function test_Emergency_CancellableByCanceller() public {
        vm.prank(guardian);
        bytes32 id = timelock.executeEmergency(address(target), _pauseData(), "incident");

        // The guardian is not a canceller
        vm.prank(guardian);
        vm.expectRevert(_unauthorized(guardian, CANCELLER_ROLE));
        timelock.cancel(id);

        vm.prank(proposer);
        timelock.cancelOperation(id);

        assertFalse(timelock.isOperation(id));
        assertEq(uint256(timelock.getOperation(id).status), uint256(IGovernanceTimelock.OperationStatus.Cancelled));
        assertEq(timelock.getPendingOperationsCount(), 0);

        vm.warp(T0 + EMERGENCY);
        bytes32 salt = _emergencySalt(1);
        vm.expectRevert(
            abi.encodeWithSelector(TimelockController.TimelockUnexpectedOperationState.selector, id, _readyBitmap())
        );
        timelock.execute(address(target), 0, _pauseData(), bytes32(0), salt);
        assertFalse(target.paused());
    }

    function test_Emergency_ExecutedOperationNotReplayable() public {
        bytes memory data = abi.encodeCall(GovTimelockTarget.revokeThing, (stranger));
        vm.prank(guardian);
        bytes32 id = timelock.executeEmergency(address(target), data, "incident");
        bytes32 salt = timelock.getOperation(id).salt;

        vm.warp(T0 + EMERGENCY);
        timelock.execute(address(target), 0, data, bytes32(0), salt);
        assertTrue(target.revoked(stranger));
        assertEq(timelock.getTimestamp(id), 1);
        assertTrue(timelock.isOperationDone(id));

        vm.expectRevert(
            abi.encodeWithSelector(TimelockController.TimelockUnexpectedOperationState.selector, id, _readyBitmap())
        );
        timelock.execute(address(target), 0, data, bytes32(0), salt);

        vm.expectRevert(
            abi.encodeWithSelector(TimelockController.TimelockUnexpectedOperationState.selector, id, _readyBitmap())
        );
        timelock.executeOperation(address(target), 0, data, bytes32(0), salt);
    }

    // =====================================================================
    // Labels and call-class policy
    // =====================================================================

    function test_Label_EmergencyActionRejectedOnProposerPaths() public {
        // Even a proposer that also holds EMERGENCY_ROLE cannot use the label
        vm.prank(admin);
        timelock.grantRole(EMERGENCY_ROLE, proposer);

        bytes memory data = _pauseData();
        IGovernanceTimelock.OperationType label = IGovernanceTimelock.OperationType.EmergencyAction;
        bytes memory reserved = abi.encodeWithSelector(IGovernanceTimelock.EmergencyActionLabelReserved.selector);

        vm.startPrank(proposer);

        vm.expectRevert(reserved);
        timelock.scheduleOperation(address(target), 0, data, bytes32(0), bytes32(0), label, "");

        vm.expectRevert(reserved);
        timelock.scheduleBatch(_one(address(target)), _oneValue(0), _oneData(data), bytes32(0), bytes32(0), label, "");

        vm.expectRevert(reserved);
        timelock.scheduleLongDelay(address(target), 0, data, bytes32(0), bytes32(0), label, "");

        vm.stopPrank();
    }

    /// REGRESSION: an ownership transfer labelled as a parameter change still needs longDelay
    function test_Policy_MislabelledOwnershipTransferGetsLongDelay() public {
        address newOwner = makeAddr("newOwner");
        bytes memory data = abi.encodeCall(Ownable.transferOwnership, (newOwner));

        vm.prank(proposer);
        bytes32 id = timelock.scheduleOperation(
            address(target), 0, data, bytes32(0), bytes32(0), IGovernanceTimelock.OperationType.ParameterChange, ""
        );
        assertEq(timelock.getTimestamp(id), T0 + LONG);
        assertEq(timelock.getOperation(id).readyAt, T0 + LONG);

        vm.warp(T0 + MIN);
        vm.expectRevert(
            abi.encodeWithSelector(TimelockController.TimelockUnexpectedOperationState.selector, id, _readyBitmap())
        );
        timelock.executeOperation(address(target), 0, data, bytes32(0), bytes32(0));

        vm.warp(T0 + LONG);
        timelock.executeOperation(address(target), 0, data, bytes32(0), bytes32(0));
        assertEq(target.pendingOwner(), newOwner);
    }

    /// REGRESSION: an upgrade labelled as a parameter change still needs longDelay
    function test_Policy_MislabelledUpgradeGetsLongDelay() public {
        address impl = makeAddr("impl");
        bytes memory data = abi.encodeCall(GovTimelockTarget.upgradeToAndCall, (impl, ""));

        vm.prank(proposer);
        bytes32 id = timelock.scheduleOperation(
            address(target), 0, data, bytes32(0), bytes32(0), IGovernanceTimelock.OperationType.ParameterChange, ""
        );
        assertEq(timelock.getTimestamp(id), T0 + LONG);

        vm.warp(T0 + LONG - 1);
        assertFalse(timelock.isOperationReady(id));
        vm.warp(T0 + LONG);
        timelock.executeOperation(address(target), 0, data, bytes32(0), bytes32(0));
        assertEq(target.implementation(), impl);
    }

    /// REGRESSION: every call to the timelock itself needs longDelay (closes the two-hop bypass)
    function test_Policy_SelfTargetAlwaysLong() public {
        bytes[] memory calls = new bytes[](4);
        calls[0] = abi.encodeCall(IGovernanceTimelock.updateDelays, (MIN, 15 minutes, LONG));
        calls[1] = abi.encodeCall(IAccessControl.grantRole, (EMERGENCY_ROLE, stranger));
        calls[2] = abi.encodeCall(
            IGovernanceTimelock.setCallClass,
            (address(target), GovTimelockTarget.setFee.selector, IGovernanceTimelock.CallClass.Emergency)
        );
        calls[3] = abi.encodeCall(IGovernanceTimelock.setOpenExecutor, (false));

        for (uint256 i = 0; i < calls.length; ++i) {
            assertEq(timelock.getRequiredDelay(address(timelock), calls[i]), LONG);

            vm.prank(proposer);
            bytes32 id = timelock.scheduleOperation(
                address(timelock),
                0,
                calls[i],
                bytes32(0),
                bytes32(i),
                IGovernanceTimelock.OperationType.ParameterChange,
                ""
            );
            assertEq(timelock.getTimestamp(id), T0 + LONG);

            vm.prank(proposer);
            vm.expectRevert(_insufficientDelay(MIN, LONG));
            timelock.schedule(address(timelock), 0, calls[i], bytes32(0), bytes32(i + 100), MIN);
        }
    }

    function test_Policy_StandardCallUsesMinDelay() public {
        bytes memory data = _setFeeData(42);
        assertEq(timelock.getRequiredDelay(address(target), data), MIN);

        vm.prank(proposer);
        bytes32 id = timelock.scheduleOperation(
            address(target), 0, data, bytes32(0), bytes32(0), IGovernanceTimelock.OperationType.ParameterChange, ""
        );
        assertEq(timelock.getTimestamp(id), T0 + MIN);

        vm.warp(T0 + MIN);
        timelock.executeOperation(address(target), 0, data, bytes32(0), bytes32(0));
        assertEq(target.fee(), 42);
    }

    function test_Policy_EmergencyClassOnProposerPathUsesMinDelay() public {
        bytes memory data = _pauseData();
        assertEq(timelock.getRequiredDelay(address(target), data), MIN);

        vm.prank(proposer);
        bytes32 id = timelock.scheduleOperation(
            address(target), 0, data, bytes32(0), bytes32(0), IGovernanceTimelock.OperationType.ProtocolPause, ""
        );
        assertEq(timelock.getTimestamp(id), T0 + MIN);

        vm.prank(proposer);
        vm.expectRevert(_insufficientDelay(EMERGENCY, MIN));
        timelock.schedule(address(target), 0, data, bytes32(0), bytes32("x"), EMERGENCY);
    }

    function test_ScheduleLongDelay_AlwaysUsesLongDelay() public {
        bytes memory data = _setFeeData(21);

        vm.prank(proposer);
        bytes32 id = timelock.scheduleLongDelay(
            address(target),
            0,
            data,
            bytes32(0),
            bytes32(0),
            IGovernanceTimelock.OperationType.TreasuryOperation,
            "long"
        );
        assertEq(timelock.getTimestamp(id), T0 + LONG);

        IGovernanceTimelock.GovernanceOperation memory op = timelock.getOperation(id);
        assertEq(uint256(op.opType), uint256(IGovernanceTimelock.OperationType.TreasuryOperation));
        assertEq(op.readyAt, T0 + LONG);
        assertEq(op.description, "long");
        assertEq(timelock.getPendingOperationsCount(), 1);

        vm.warp(T0 + LONG - 1);
        assertFalse(timelock.isOperationReady(id));
        vm.warp(T0 + LONG);
        timelock.executeOperation(address(target), 0, data, bytes32(0), bytes32(0));
        assertEq(target.fee(), 21);
        assertEq(uint256(timelock.getOperation(id).status), uint256(IGovernanceTimelock.OperationStatus.Executed));
        assertEq(timelock.getPendingOperationsCount(), 0);

        // Non-proposers cannot use it
        vm.prank(guardian);
        vm.expectRevert(_unauthorized(guardian, PROPOSER_ROLE));
        timelock.scheduleLongDelay(
            address(target), 0, data, bytes32(0), bytes32("g"), IGovernanceTimelock.OperationType.ParameterChange, ""
        );
    }

    function test_Policy_LabelOnlyLengthens() public {
        bytes memory data = _setFeeData(1);

        vm.startPrank(proposer);
        bytes32 id1 = timelock.scheduleOperation(
            address(target),
            0,
            data,
            bytes32(0),
            bytes32(uint256(1)),
            IGovernanceTimelock.OperationType.ContractUpgrade,
            ""
        );
        bytes32 id2 = timelock.scheduleOperation(
            address(target),
            0,
            data,
            bytes32(0),
            bytes32(uint256(2)),
            IGovernanceTimelock.OperationType.OwnershipTransfer,
            ""
        );
        bytes32 id3 = timelock.scheduleOperation(
            address(target),
            0,
            data,
            bytes32(0),
            bytes32(uint256(3)),
            IGovernanceTimelock.OperationType.TreasuryOperation,
            ""
        );
        vm.stopPrank();

        assertEq(timelock.getTimestamp(id1), T0 + LONG);
        assertEq(timelock.getTimestamp(id2), T0 + LONG);
        assertEq(timelock.getTimestamp(id3), T0 + MIN);
    }

    function test_Policy_RegisteredLongDelayPair() public {
        vm.prank(admin);
        vm.expectEmit(true, true, false, true, address(timelock));
        emit CallClassUpdated(
            address(target), GovTimelockTarget.setFee.selector, IGovernanceTimelock.CallClass.LongDelay
        );
        timelock.setCallClass(
            address(target), GovTimelockTarget.setFee.selector, IGovernanceTimelock.CallClass.LongDelay
        );

        bytes memory data = _setFeeData(5);
        assertEq(
            uint256(timelock.getCallClass(address(target), GovTimelockTarget.setFee.selector)),
            uint256(IGovernanceTimelock.CallClass.LongDelay)
        );
        assertEq(timelock.getRequiredDelay(address(target), data), LONG);

        vm.prank(proposer);
        vm.expectRevert(_insufficientDelay(MIN, LONG));
        timelock.schedule(address(target), 0, data, bytes32(0), bytes32(0), MIN);

        vm.prank(proposer);
        bytes32 id = timelock.scheduleOperation(
            address(target), 0, data, bytes32(0), bytes32(0), IGovernanceTimelock.OperationType.ParameterChange, ""
        );
        assertEq(timelock.getTimestamp(id), T0 + LONG);

        // The same selector on another target is unaffected
        assertEq(timelock.getRequiredDelay(stranger, data), MIN);
    }

    function test_Policy_BatchUsesStrictestCall() public {
        address[] memory targets = new address[](2);
        targets[0] = address(target);
        targets[1] = address(target);
        uint256[] memory values = new uint256[](2);
        bytes[] memory payloads = new bytes[](2);
        payloads[0] = _setFeeData(3);
        payloads[1] = abi.encodeCall(Ownable.transferOwnership, (stranger));

        // 7-arg form, mislabelled
        vm.prank(proposer);
        bytes32 id = timelock.scheduleBatch(
            targets, values, payloads, bytes32(0), bytes32(0), IGovernanceTimelock.OperationType.ParameterChange, ""
        );
        assertEq(timelock.getTimestamp(id), T0 + LONG);
        assertEq(timelock.getOperation(id).readyAt, T0 + LONG);

        // 6-arg form
        vm.prank(proposer);
        vm.expectRevert(_insufficientDelay(MIN, LONG));
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), bytes32("six"), MIN);

        vm.prank(proposer);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), bytes32("six"), LONG);
        bytes32 id6 = timelock.hashOperationBatch(targets, values, payloads, bytes32(0), bytes32("six"));
        assertEq(timelock.getTimestamp(id6), T0 + LONG);

        // An all-standard batch only needs minDelay
        payloads[1] = _setFeeData(4);
        vm.prank(proposer);
        bytes32 idStd = timelock.scheduleBatch(
            targets, values, payloads, bytes32(0), bytes32(0), IGovernanceTimelock.OperationType.ParameterChange, ""
        );
        assertEq(timelock.getTimestamp(idStd), T0 + MIN);

        vm.warp(T0 + MIN);
        timelock.executeBatch(targets, values, payloads, bytes32(0), bytes32(0));
        assertEq(target.fee(), 4);
        assertEq(uint256(timelock.getOperation(idStd).status), uint256(IGovernanceTimelock.OperationStatus.Executed));
    }

    function test_LockedSelectorsMatchSignatures() public {
        // Cross-check a few against compiler-derived selectors
        assertTrue(_isLocked(Ownable.transferOwnership.selector));
        assertTrue(_isLocked(Ownable.renounceOwnership.selector));
        assertTrue(_isLocked(IAccessControl.grantRole.selector));
        assertTrue(_isLocked(IAccessControl.revokeRole.selector));
        assertTrue(_isLocked(IAccessControl.renounceRole.selector));
        assertTrue(_isLocked(GovTimelockTarget.upgradeToAndCall.selector));
        assertTrue(_isLocked(GovTimelockTarget.multicall.selector));

        string[13] memory sigs = _lockedSignatures();
        for (uint256 i = 0; i < sigs.length; ++i) {
            bytes4 sel = bytes4(keccak256(bytes(sigs[i])));
            assertEq(
                uint256(timelock.getCallClass(address(target), sel)),
                uint256(IGovernanceTimelock.CallClass.LongDelay),
                sigs[i]
            );
            assertEq(timelock.getRequiredDelay(stranger, abi.encodePacked(sel)), LONG, sigs[i]);

            vm.prank(admin);
            vm.expectRevert(abi.encodeWithSelector(IGovernanceTimelock.CallClassLocked.selector, sel));
            timelock.setCallClass(address(target), sel, IGovernanceTimelock.CallClass.Standard);

            vm.prank(admin);
            vm.expectRevert(abi.encodeWithSelector(IGovernanceTimelock.CallClassLocked.selector, sel));
            timelock.setCallClass(address(target), sel, IGovernanceTimelock.CallClass.Emergency);
        }
    }

    function test_SetCallClass_RejectsZeroAndSelf() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(IGovernanceTimelock.InvalidCallClassTarget.selector, address(0)));
        timelock.setCallClass(address(0), GovTimelockTarget.pause.selector, IGovernanceTimelock.CallClass.Emergency);

        vm.expectRevert(abi.encodeWithSelector(IGovernanceTimelock.InvalidCallClassTarget.selector, address(timelock)));
        timelock.setCallClass(
            address(timelock), IGovernanceTimelock.emergencyPauseAll.selector, IGovernanceTimelock.CallClass.Emergency
        );

        vm.expectRevert(abi.encodeWithSelector(IGovernanceTimelock.InvalidCallClassTarget.selector, address(timelock)));
        timelock.setCallClass(
            address(timelock), IGovernanceTimelock.setOpenExecutor.selector, IGovernanceTimelock.CallClass.Standard
        );
        vm.stopPrank();

        // Self-calls stay LongDelay regardless
        assertEq(
            uint256(timelock.getCallClass(address(timelock), IGovernanceTimelock.emergencyPauseAll.selector)),
            uint256(IGovernanceTimelock.CallClass.LongDelay)
        );
    }

    function test_SetCallClass_OnlyAdmin() public {
        bytes4 sel = GovTimelockTarget.setFee.selector;

        vm.prank(proposer);
        vm.expectRevert(_unauthorized(proposer, DEFAULT_ADMIN_ROLE));
        timelock.setCallClass(address(target), sel, IGovernanceTimelock.CallClass.Emergency);

        vm.prank(guardian);
        vm.expectRevert(_unauthorized(guardian, DEFAULT_ADMIN_ROLE));
        timelock.setCallClass(address(target), sel, IGovernanceTimelock.CallClass.Emergency);

        vm.prank(stranger);
        vm.expectRevert(_unauthorized(stranger, DEFAULT_ADMIN_ROLE));
        timelock.setCallClass(address(target), sel, IGovernanceTimelock.CallClass.Emergency);

        assertEq(uint256(timelock.getCallClass(address(target), sel)), uint256(IGovernanceTimelock.CallClass.Standard));
    }

    function testFuzz_GetRequiredDelay(address tgt, bytes memory data) public {
        vm.prank(admin);
        timelock.setCallClass(
            address(target), GovTimelockTarget.setFee.selector, IGovernanceTimelock.CallClass.LongDelay
        );

        // Steer part of the input space towards the interesting targets and selectors
        if (data.length > 0) {
            uint8 steer = uint8(data[0]);
            if (steer < 48) tgt = address(timelock);
            else if (steer < 128) tgt = address(target);
        }
        if (data.length >= 4 && uint8(data[1]) < 64) {
            bytes4 sel = uint8(data[2]) < 128
                ? bytes4(keccak256(bytes(_lockedSignatures()[uint8(data[3]) % 13])))
                : GovTimelockTarget.setFee.selector;
            for (uint256 i = 0; i < 4; ++i) {
                data[i] = sel[i];
            }
        }

        bytes4 s = data.length >= 4 ? bytes4(bytes.concat(data[0], data[1], data[2], data[3])) : bytes4(0);
        bool isLong = tgt == address(timelock) || _isLocked(s)
            || (tgt == address(target) && s == GovTimelockTarget.setFee.selector);

        uint256 required = timelock.getRequiredDelay(tgt, data);
        assertTrue(required == MIN || required == LONG);
        assertEq(required, isLong ? LONG : MIN);
        if (data.length >= 4) {
            assertEq(
                timelock.getCallClass(tgt, s) == IGovernanceTimelock.CallClass.LongDelay, isLong, "class/delay mismatch"
            );
        }
    }

    // =====================================================================
    // Inherited OZ entry points
    // =====================================================================

    /// REGRESSION: the inherited schedule() enforces the content-derived floor
    function test_DirectSchedule_CriticalCallNeedsLongDelay() public {
        bytes memory data = abi.encodeCall(Ownable.transferOwnership, (stranger));

        vm.prank(proposer);
        vm.expectRevert(_insufficientDelay(MIN, LONG));
        timelock.schedule(address(target), 0, data, bytes32(0), bytes32(0), MIN);

        vm.prank(proposer);
        timelock.schedule(address(target), 0, data, bytes32(0), bytes32(0), LONG);
        bytes32 id = timelock.hashOperation(address(target), 0, data, bytes32(0), bytes32(0));
        assertEq(timelock.getTimestamp(id), T0 + LONG);
    }

    /// REGRESSION: the inherited scheduleBatch() enforces the content-derived floor
    function test_DirectScheduleBatch_CriticalCallNeedsLongDelay() public {
        bytes memory data = abi.encodeCall(Ownable.transferOwnership, (stranger));

        vm.prank(proposer);
        vm.expectRevert(_insufficientDelay(MIN, LONG));
        timelock.scheduleBatch(_one(address(target)), _oneValue(0), _oneData(data), bytes32(0), bytes32(0), MIN);

        vm.prank(proposer);
        timelock.scheduleBatch(_one(address(target)), _oneValue(0), _oneData(data), bytes32(0), bytes32(0), LONG);
        bytes32 id =
            timelock.hashOperationBatch(_one(address(target)), _oneValue(0), _oneData(data), bytes32(0), bytes32(0));
        assertEq(timelock.getTimestamp(id), T0 + LONG);
    }

    function test_DirectSchedule_NonCriticalAtMinDelayWorks() public {
        bytes memory data = _setFeeData(11);

        // Plain OZ / Safe usage keeps working for standard calls
        vm.prank(proposer);
        timelock.schedule(address(target), 0, data, bytes32(0), bytes32("safe"), MIN);
        bytes32 id = timelock.hashOperation(address(target), 0, data, bytes32(0), bytes32("safe"));
        assertEq(timelock.getTimestamp(id), T0 + MIN);

        vm.prank(proposer);
        timelock.scheduleBatch(_one(address(target)), _oneValue(0), _oneData(data), bytes32(0), bytes32("safe"), MIN);

        vm.warp(T0 + MIN);
        timelock.execute(address(target), 0, data, bytes32(0), bytes32("safe"));
        assertEq(target.fee(), 11);
    }

    function test_DirectSchedule_RequiresProposer() public {
        bytes memory data = _setFeeData(1);

        vm.prank(stranger);
        vm.expectRevert(_unauthorized(stranger, PROPOSER_ROLE));
        timelock.schedule(address(target), 0, data, bytes32(0), bytes32(0), MIN);

        vm.prank(guardian);
        vm.expectRevert(_unauthorized(guardian, PROPOSER_ROLE));
        timelock.scheduleBatch(_one(address(target)), _oneValue(0), _oneData(data), bytes32(0), bytes32(0), MIN);

        vm.prank(admin);
        vm.expectRevert(_unauthorized(admin, PROPOSER_ROLE));
        timelock.schedule(address(target), 0, data, bytes32(0), bytes32(0), MIN);
    }

    function test_DirectScheduleBatch_LengthMismatchKeepsOzError() public {
        address[] memory targets = new address[](2);
        uint256[] memory values = new uint256[](1);
        bytes[] memory payloads = new bytes[](2);

        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockInvalidOperationLength.selector, 2, 2, 1));
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), bytes32(0), LONG);

        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockInvalidOperationLength.selector, 2, 2, 1));
        timelock.scheduleBatch(
            targets, values, payloads, bytes32(0), bytes32(0), IGovernanceTimelock.OperationType.ParameterChange, ""
        );
    }

    function testFuzz_DirectSchedule_ContentDerivedFloor(uint8 selIdx, uint256 delay, bool selfTarget) public {
        delay = _bound(delay, 0, 60 days);

        bytes[8] memory candidates = [
            _setFeeData(1),
            _pauseData(),
            abi.encodeCall(GovTimelockTarget.revokeThing, (stranger)),
            abi.encodeCall(Ownable.transferOwnership, (stranger)),
            abi.encodeCall(GovTimelockTarget.upgradeToAndCall, (stranger, "")),
            abi.encodeCall(IAccessControl.grantRole, (PROPOSER_ROLE, stranger)),
            abi.encodeCall(IGovernanceTimelock.updateDelays, (MIN, EMERGENCY, LONG)),
            bytes("")
        ];
        bytes memory data = candidates[selIdx % candidates.length];
        address tgt = selfTarget ? address(timelock) : address(target);

        bool critical = selfTarget || (selIdx % candidates.length >= 3 && selIdx % candidates.length <= 5);
        uint256 required = critical ? LONG : MIN;
        assertEq(timelock.getRequiredDelay(tgt, data), required);

        vm.prank(proposer);
        if (delay < required) {
            vm.expectRevert(_insufficientDelay(delay, required));
            timelock.schedule(tgt, 0, data, bytes32(0), bytes32(0), delay);
        } else {
            timelock.schedule(tgt, 0, data, bytes32(0), bytes32(0), delay);
            assertEq(timelock.getTimestamp(timelock.hashOperation(tgt, 0, data, bytes32(0), bytes32(0))), T0 + delay);
        }
    }

    // =====================================================================
    // Delays
    // =====================================================================

    function test_UpdateDelays_BootstrapAdmin() public {
        vm.expectEmit(false, false, false, true, address(timelock));
        emit MinDelayChange(MIN, 3 days);
        vm.expectEmit(false, false, false, true, address(timelock));
        emit TimelockConfigUpdated(3 days, 1 days, 6 days);

        vm.prank(admin);
        timelock.updateDelays(3 days, 1 days, 6 days);

        assertEq(timelock.getMinDelay(), 3 days);
        IGovernanceTimelock.TimelockConfig memory cfg = timelock.getTimelockConfig();
        assertEq(cfg.minDelay, 3 days);
        assertEq(cfg.emergencyDelay, 1 days);
        assertEq(cfg.longDelay, 6 days);

        // New delays apply to new operations
        vm.prank(guardian);
        bytes32 id = timelock.executeEmergency(address(target), _pauseData(), "x");
        assertEq(timelock.getTimestamp(id), T0 + 1 days);
    }

    function _expectInvalidDelays(uint256 minD, uint256 emD, uint256 longD) internal {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IGovernanceTimelock.InvalidDelayConfig.selector, minD, emD, longD));
        timelock.updateDelays(minD, emD, longD);
    }

    /// REGRESSION: delay configuration is bounded
    function test_UpdateDelays_Bounds() public {
        _expectInvalidDelays(MIN, 0, LONG); // emergency 0
        _expectInvalidDelays(MIN, 15 minutes - 1, LONG); // emergency below floor
        _expectInvalidDelays(MIN, MIN + 1, LONG); // emergency above min
        _expectInvalidDelays(MIN, EMERGENCY, MIN - 1); // long below min
        _expectInvalidDelays(MIN, EMERGENCY, 60 days + 1); // long above cap
        _expectInvalidDelays(MIN, EMERGENCY, type(uint256).max); // long overflow bait
        _expectInvalidDelays(1 hours - 1, 15 minutes, LONG); // min below floor
        _expectInvalidDelays(30 days + 1, EMERGENCY, 60 days); // min above cap

        // Boundary values are accepted
        vm.startPrank(admin);
        timelock.updateDelays(1 hours, 15 minutes, 1 hours);
        assertEq(timelock.getMinDelay(), 1 hours);
        timelock.updateDelays(30 days, 30 days, 60 days);
        assertEq(timelock.getMinDelay(), 30 days);
        timelock.updateDelays(MIN, 15 minutes, 60 days);
        timelock.updateDelays(MIN, MIN, MIN);
        vm.stopPrank();

        IGovernanceTimelock.TimelockConfig memory cfg = timelock.getTimelockConfig();
        assertEq(cfg.minDelay, MIN);
        assertEq(cfg.emergencyDelay, MIN);
        assertEq(cfg.longDelay, MIN);
    }

    function test_UpdateDelays_OnlyAdmin() public {
        address[3] memory callers = [proposer, guardian, stranger];
        for (uint256 i = 0; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(_unauthorized(callers[i], DEFAULT_ADMIN_ROLE));
            timelock.updateDelays(3 days, 1 days, 6 days);
        }
    }

    function test_UpdateDelays_AfterRenounceRequiresLongSelfOp() public {
        vm.prank(admin);
        timelock.renounceRole(DEFAULT_ADMIN_ROLE, admin);

        vm.prank(admin);
        vm.expectRevert(_unauthorized(admin, DEFAULT_ADMIN_ROLE));
        timelock.updateDelays(3 days, 1 days, 6 days);

        bytes memory data = abi.encodeCall(IGovernanceTimelock.updateDelays, (3 days, 1 days, 6 days));
        vm.prank(proposer);
        bytes32 id = timelock.scheduleOperation(
            address(timelock), 0, data, bytes32(0), bytes32(0), IGovernanceTimelock.OperationType.ParameterChange, ""
        );
        assertEq(timelock.getTimestamp(id), T0 + LONG);

        vm.warp(T0 + MIN);
        assertFalse(timelock.isOperationReady(id));

        vm.warp(T0 + LONG);
        vm.prank(stranger);
        timelock.executeOperation(address(timelock), 0, data, bytes32(0), bytes32(0));

        IGovernanceTimelock.TimelockConfig memory cfg = timelock.getTimelockConfig();
        assertEq(cfg.minDelay, 3 days);
        assertEq(cfg.emergencyDelay, 1 days);
        assertEq(cfg.longDelay, 6 days);
        assertEq(timelock.getMinDelay(), 3 days);
    }

    /// REGRESSION: OZ updateDelay is validated and keeps _config in sync
    function test_UpdateDelay_OzEntryPointValidatedAndSynced() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockUnauthorizedCaller.selector, stranger));
        timelock.updateDelay(3 days);

        bytes memory data = abi.encodeCall(TimelockController.updateDelay, (3 days));
        vm.prank(proposer);
        timelock.schedule(address(timelock), 0, data, bytes32(0), bytes32(0), LONG);
        vm.warp(T0 + LONG);
        timelock.execute(address(timelock), 0, data, bytes32(0), bytes32(0));

        assertEq(timelock.getMinDelay(), 3 days);
        IGovernanceTimelock.TimelockConfig memory cfg = timelock.getTimelockConfig();
        assertEq(cfg.minDelay, 3 days);
        assertEq(cfg.emergencyDelay, EMERGENCY);
        assertEq(cfg.longDelay, LONG);

        bytes memory zero = abi.encodeCall(TimelockController.updateDelay, (0));
        vm.prank(proposer);
        timelock.schedule(address(timelock), 0, zero, bytes32(0), bytes32(0), LONG);
        bytes32 id = timelock.hashOperation(address(timelock), 0, zero, bytes32(0), bytes32(0));
        vm.warp(T0 + 2 * LONG);

        vm.expectRevert(abi.encodeWithSelector(IGovernanceTimelock.InvalidDelayConfig.selector, 0, EMERGENCY, LONG));
        timelock.execute(address(timelock), 0, zero, bytes32(0), bytes32(0));
        assertTrue(timelock.isOperationReady(id));
        assertEq(timelock.getMinDelay(), 3 days);
    }

    function test_UpdateDelays_PendingOpsKeepTimestamp() public {
        bytes memory data = _setFeeData(8);
        vm.prank(proposer);
        bytes32 id = timelock.scheduleOperation(
            address(target), 0, data, bytes32(0), bytes32(0), IGovernanceTimelock.OperationType.ParameterChange, ""
        );
        vm.prank(guardian);
        bytes32 eid = timelock.executeEmergency(address(target), _pauseData(), "x");

        vm.prank(admin);
        timelock.updateDelays(5 days, 1 days, 10 days);

        assertEq(timelock.getTimestamp(id), T0 + MIN);
        assertEq(timelock.getTimestamp(eid), T0 + EMERGENCY);

        vm.warp(T0 + MIN);
        timelock.executeOperation(address(target), 0, data, bytes32(0), bytes32(0));
        assertEq(target.fee(), 8);
    }

    // =====================================================================
    // Metadata / state
    // =====================================================================

    /// REGRESSION: the inherited execute() keeps governance metadata in sync
    function test_InheritedExecute_UpdatesMetadata() public {
        bytes memory data = _setFeeData(3);
        vm.prank(proposer);
        bytes32 id = timelock.scheduleOperation(
            address(target), 0, data, bytes32(0), bytes32(0), IGovernanceTimelock.OperationType.ParameterChange, ""
        );
        assertEq(timelock.getPendingOperationsCount(), 1);

        vm.warp(T0 + MIN);
        vm.prank(stranger);
        timelock.execute(address(target), 0, data, bytes32(0), bytes32(0));

        assertEq(uint256(timelock.getOperation(id).status), uint256(IGovernanceTimelock.OperationStatus.Executed));
        assertEq(timelock.getPendingOperationsCount(), 0);
    }

    /// REGRESSION: the inherited cancel() keeps governance metadata in sync
    function test_InheritedCancel_UpdatesMetadata() public {
        bytes memory data = _setFeeData(3);
        vm.prank(proposer);
        bytes32 id = timelock.scheduleOperation(
            address(target), 0, data, bytes32(0), bytes32(0), IGovernanceTimelock.OperationType.ParameterChange, ""
        );

        vm.prank(proposer);
        timelock.cancel(id);

        assertFalse(timelock.isOperation(id));
        assertEq(uint256(timelock.getOperation(id).status), uint256(IGovernanceTimelock.OperationStatus.Cancelled));
        assertEq(timelock.getPendingOperationsCount(), 0);
    }

    function test_GetOperation_ReportsReady() public {
        bytes memory data = _setFeeData(3);
        vm.prank(proposer);
        bytes32 id = timelock.scheduleOperation(
            address(target), 0, data, bytes32(0), bytes32(0), IGovernanceTimelock.OperationType.ParameterChange, ""
        );
        assertEq(uint256(timelock.getOperation(id).status), uint256(IGovernanceTimelock.OperationStatus.Pending));

        vm.warp(T0 + MIN - 1);
        assertEq(uint256(timelock.getOperation(id).status), uint256(IGovernanceTimelock.OperationStatus.Pending));

        vm.warp(T0 + MIN);
        assertEq(uint256(timelock.getOperation(id).status), uint256(IGovernanceTimelock.OperationStatus.Ready));
        assertEq(
            uint256(timelock.getOperation(bytes32("none")).status), uint256(IGovernanceTimelock.OperationStatus.None)
        );
    }

    function test_RescheduleAfterCancel_NoDuplicatePending() public {
        bytes memory data = _setFeeData(3);
        vm.startPrank(proposer);
        bytes32 id = timelock.scheduleOperation(
            address(target), 0, data, bytes32(0), bytes32(0), IGovernanceTimelock.OperationType.ParameterChange, ""
        );
        timelock.cancelOperation(id);
        bytes32 id2 = timelock.scheduleOperation(
            address(target), 0, data, bytes32(0), bytes32(0), IGovernanceTimelock.OperationType.ParameterChange, ""
        );
        vm.stopPrank();

        assertEq(id, id2);
        assertEq(timelock.getPendingOperationsCount(), 1);
        assertEq(timelock.getPendingOperations()[0], id);
        assertEq(uint256(timelock.getOperation(id).status), uint256(IGovernanceTimelock.OperationStatus.Pending));

        vm.warp(T0 + MIN);
        timelock.executeOperation(address(target), 0, data, bytes32(0), bytes32(0));
        assertEq(timelock.getPendingOperationsCount(), 0);
    }

    function test_RawScheduledOp_NoMetadataExecutesFine() public {
        bytes memory data = _setFeeData(12);
        vm.prank(proposer);
        timelock.schedule(address(target), 0, data, bytes32(0), bytes32(0), MIN);
        bytes32 id = timelock.hashOperation(address(target), 0, data, bytes32(0), bytes32(0));

        assertEq(timelock.getPendingOperationsCount(), 0);
        assertEq(timelock.getOperation(id).scheduledAt, 0);

        vm.warp(T0 + MIN);
        timelock.execute(address(target), 0, data, bytes32(0), bytes32(0));

        assertEq(target.fee(), 12);
        assertTrue(timelock.isOperationDone(id));
        assertEq(uint256(timelock.getOperation(id).status), uint256(IGovernanceTimelock.OperationStatus.None));
        assertEq(timelock.getPendingOperationsCount(), 0);

        // Raw cancel of a raw op is also fine
        vm.prank(proposer);
        timelock.schedule(address(target), 0, data, bytes32(0), bytes32("c"), MIN);
        bytes32 cid = timelock.hashOperation(address(target), 0, data, bytes32(0), bytes32("c"));
        vm.prank(proposer);
        timelock.cancel(cid);
        assertFalse(timelock.isOperation(cid));
    }

    function test_ViewsNotOverridden_StateMachine() public {
        bytes memory dataA = _setFeeData(1);
        bytes memory dataB = _setFeeData(2);
        bytes32 idA = timelock.hashOperation(address(target), 0, dataA, bytes32(0), bytes32(0));
        bytes32 idB = timelock.hashOperation(address(target), 0, dataB, idA, bytes32(0));

        assertEq(uint256(timelock.getOperationState(idA)), uint256(TimelockController.OperationState.Unset));
        assertFalse(timelock.isOperation(idA));

        vm.startPrank(proposer);
        timelock.scheduleOperation(
            address(target), 0, dataA, bytes32(0), bytes32(0), IGovernanceTimelock.OperationType.ParameterChange, ""
        );
        timelock.scheduleOperation(
            address(target), 0, dataB, idA, bytes32(0), IGovernanceTimelock.OperationType.ParameterChange, ""
        );
        vm.stopPrank();

        assertEq(uint256(timelock.getOperationState(idA)), uint256(TimelockController.OperationState.Waiting));
        assertTrue(timelock.isOperation(idA));
        assertTrue(timelock.isOperationPending(idA));
        assertFalse(timelock.isOperationReady(idA));

        vm.warp(T0 + MIN);
        assertEq(uint256(timelock.getOperationState(idA)), uint256(TimelockController.OperationState.Ready));
        assertTrue(timelock.isOperationReady(idA));

        // Predecessor enforced
        vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockUnexecutedPredecessor.selector, idA));
        timelock.executeOperation(address(target), 0, dataB, idA, bytes32(0));

        timelock.executeOperation(address(target), 0, dataA, bytes32(0), bytes32(0));
        assertEq(uint256(timelock.getOperationState(idA)), uint256(TimelockController.OperationState.Done));
        assertTrue(timelock.isOperationDone(idA));
        assertFalse(timelock.isOperationPending(idA));
        assertEq(timelock.getTimestamp(idA), 1);

        timelock.executeOperation(address(target), 0, dataB, idA, bytes32(0));
        assertEq(target.fee(), 2);
        assertTrue(timelock.isOperationDone(idB));
    }

    function test_EmergencyPauseAllInstant_UnpauseQueued() public {
        vm.prank(admin);
        timelock.registerProtocolContract("ilrm", address(target));

        vm.prank(stranger);
        vm.expectRevert(_unauthorized(stranger, EMERGENCY_ROLE));
        timelock.emergencyPauseAll("x");

        vm.prank(guardian);
        timelock.emergencyPauseAll("incident");
        assertTrue(target.paused());
        (bool ilrmPaused,,,) = timelock.getPauseStatus();
        assertTrue(ilrmPaused);

        // Unpausing is queued at minDelay, not instant
        vm.prank(guardian);
        bytes32 id = timelock.emergencyUnpauseAll();
        assertTrue(target.paused());

        vm.warp(T0 + MIN);
        timelock.execute(
            address(timelock),
            0,
            abi.encodeCall(IGovernanceTimelock.emergencyUnpauseAll, ()),
            bytes32(0),
            timelock.getOperation(id).salt
        );
        assertFalse(target.paused());

        assertEq(timelock.getProtocolContracts().ilrm, address(target));
        assertEq(timelock.getContractAddress("ilrm"), address(target));
    }

    function test_AssetRegistry_EndToEnd() public {
        address dummyIlrm = makeAddr("dummyIlrm");
        address newIlrm = makeAddr("newIlrm");

        NatLangChainAssetRegistry registry = new NatLangChainAssetRegistry();
        registry.authorizeILRM(dummyIlrm);
        registry.transferOwnership(address(timelock));

        vm.startPrank(admin);
        timelock.acceptContractOwnership(address(registry));
        timelock.setCallClass(
            address(registry), NatLangChainAssetRegistry.authorizeILRM.selector, IGovernanceTimelock.CallClass.LongDelay
        );
        timelock.setCallClass(
            address(registry), NatLangChainAssetRegistry.revokeILRM.selector, IGovernanceTimelock.CallClass.Emergency
        );
        vm.stopPrank();
        assertEq(registry.owner(), address(timelock));

        // Authorizing a new ILRM needs longDelay
        bytes memory authData = abi.encodeCall(NatLangChainAssetRegistry.authorizeILRM, (newIlrm));
        vm.prank(proposer);
        vm.expectRevert(_insufficientDelay(MIN, LONG));
        timelock.schedule(address(registry), 0, authData, bytes32(0), bytes32(0), MIN);

        vm.prank(proposer);
        bytes32 authId = timelock.scheduleOperation(
            address(registry),
            0,
            authData,
            bytes32(0),
            bytes32(0),
            IGovernanceTimelock.OperationType.ParameterChange,
            ""
        );
        assertEq(timelock.getTimestamp(authId), T0 + LONG);

        // The guardian cannot use the emergency path to authorize
        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGovernanceTimelock.NotEmergencyCall.selector,
                address(registry),
                NatLangChainAssetRegistry.authorizeILRM.selector
            )
        );
        timelock.executeEmergency(address(registry), authData, "nope");

        // ...but can queue a revocation that is executable after the emergency delay
        bytes memory revokeData = abi.encodeCall(NatLangChainAssetRegistry.revokeILRM, (dummyIlrm));
        vm.prank(guardian);
        bytes32 id = timelock.executeEmergency(address(registry), revokeData, "compromised ILRM");
        bytes32 salt = timelock.getOperation(id).salt;

        vm.warp(T0 + EMERGENCY);
        vm.prank(stranger);
        timelock.execute(address(registry), 0, revokeData, bytes32(0), salt);
        assertFalse(registry.isAuthorizedILRM(dummyIlrm));

        vm.warp(T0 + LONG);
        timelock.executeOperation(address(registry), 0, authData, bytes32(0), bytes32(0));
        assertTrue(registry.isAuthorizedILRM(newIlrm));
    }
}

// =========================================================================
// Invariant suite
// =========================================================================

/// @notice Drives every scheduling, execution, cancellation, pause/unpause and executor path.
/// @dev The suite runs with fail_on_revert = true: each action guards its preconditions and wraps the
///      reverts it expects (StaleUnpause, LastExecutor) in vm.expectRevert, so any other revert, or a
///      failed assertion inside an action, fails the run instead of being silently discarded.
contract GovTimelockHandler is Test {
    GovernanceTimelock public timelock;
    GovTimelockTarget public target;
    address public admin;
    address public proposer;
    address public guardian;
    address public executor = makeAddr("handlerExecutor");

    struct Call {
        address target;
        bytes data;
        bytes32 salt;
        bool batch; // scheduled as a one-call batch (hashOperationBatch / executeBatch)
        bool raw; // latest scheduling went through a raw OZ entry point (no metadata)
        bool guardian; // queued by EMERGENCY_ROLE (reserved salt namespace)
        bool unpause; // bound to the pause epoch it was scheduled in
        uint256 epoch; // pause epoch at its latest scheduling
    }

    Call[] internal _calls;
    bytes32[] internal _executedIds;
    uint256 public saltCounter;
    uint256 public guardianOps;
    uint256 public pauseCount;
    uint256 public staleRejections;

    constructor(GovernanceTimelock tl, GovTimelockTarget t, address a, address p, address g) {
        timelock = tl;
        target = t;
        admin = a;
        proposer = p;
        guardian = g;
    }

    // ---- Views for the invariants ----

    function callCount() external view returns (uint256) {
        return _calls.length;
    }

    function callAt(uint256 i) external view returns (Call memory) {
        return _calls[i];
    }

    function idOf(uint256 i) public view returns (bytes32) {
        Call storage c = _calls[i];
        return c.batch
            ? timelock.hashOperationBatch(_targets(c.target), _values(), _payloads(c.data), bytes32(0), c.salt)
            : timelock.hashOperation(c.target, 0, c.data, bytes32(0), c.salt);
    }

    function executedCount() external view returns (uint256) {
        return _executedIds.length;
    }

    function executedId(uint256 i) external view returns (bytes32) {
        return _executedIds[i];
    }

    // ---- Scheduling ----

    function scheduleStandard(uint256 newFee, uint8 label) external {
        bytes memory data = abi.encodeCall(GovTimelockTarget.setFee, (newFee));
        bytes32 salt = bytes32(++saltCounter);
        vm.prank(proposer);
        timelock.scheduleOperation(address(target), 0, data, bytes32(0), salt, _label(label), "");
        _push(address(target), data, salt, false, false, false);
    }

    function scheduleCritical(address newOwner) external {
        bytes memory data = abi.encodeCall(Ownable.transferOwnership, (newOwner));
        bytes32 salt = bytes32(++saltCounter);
        vm.prank(proposer);
        timelock.scheduleOperation(
            address(target), 0, data, bytes32(0), salt, IGovernanceTimelock.OperationType.ParameterChange, ""
        );
        _push(address(target), data, salt, false, false, false);
    }

    function scheduleRaw(uint256 newFee, uint256 extra) external {
        bytes memory data = abi.encodeCall(GovTimelockTarget.setFee, (newFee));
        bytes32 salt = bytes32(++saltCounter);
        uint256 delay = timelock.getRequiredDelay(address(target), data) + _bound(extra, 0, 1 days);
        vm.prank(proposer);
        timelock.schedule(address(target), 0, data, bytes32(0), salt, delay);
        _push(address(target), data, salt, false, true, false);
    }

    /// @dev 7-argument scheduleBatch of a standard call: the label floor alone sets the delay
    function scheduleBatchLabelled(uint256 newFee, uint8 label) external {
        IGovernanceTimelock.OperationType opType = _label(label);
        bytes memory data = abi.encodeCall(GovTimelockTarget.setFee, (newFee));
        bytes32 salt = bytes32(++saltCounter);
        IGovernanceTimelock.TimelockConfig memory cfg = timelock.getTimelockConfig();
        bool longLabel = opType == IGovernanceTimelock.OperationType.ContractUpgrade
            || opType == IGovernanceTimelock.OperationType.OwnershipTransfer;

        vm.prank(proposer);
        bytes32 id =
            timelock.scheduleBatch(_targets(address(target)), _values(), _payloads(data), bytes32(0), salt, opType, "");
        assertEq(timelock.getTimestamp(id), block.timestamp + (longLabel ? cfg.longDelay : cfg.minDelay));
        _push(address(target), data, salt, true, false, false);
    }

    function scheduleEmergency(address who) external {
        bytes memory data = abi.encodeCall(GovTimelockTarget.revokeThing, (who));
        vm.prank(guardian);
        bytes32 id = timelock.executeEmergency(address(target), data, "drill");
        guardianOps++;
        _push(address(target), data, timelock.getOperation(id).salt, false, false, true);
    }

    /// @dev Guardian emergencyUnpauseAll, or a proposer's raw unpause() of the target
    function queueUnpause(bool viaGuardian) external {
        if (viaGuardian) {
            vm.prank(guardian);
            bytes32 id = timelock.emergencyUnpauseAll();
            guardianOps++;
            _push(
                address(timelock),
                abi.encodeCall(IGovernanceTimelock.emergencyUnpauseAll, ()),
                timelock.getOperation(id).salt,
                false,
                false,
                true
            );
        } else {
            bytes memory data = abi.encodeCall(GovTimelockTarget.unpause, ());
            bytes32 salt = bytes32(++saltCounter);
            uint256 delay = timelock.getRequiredDelay(address(target), data);
            vm.prank(proposer);
            timelock.schedule(address(target), 0, data, bytes32(0), salt, delay);
            _push(address(target), data, salt, false, true, false);
        }
    }

    /// @dev Cancel (if pending) and re-schedule a proposer operation through the raw OZ entry point
    function rescheduleRaw(uint256 idx) external {
        if (_calls.length == 0) return;
        uint256 i = idx % _calls.length;
        Call storage c = _calls[i];
        if (c.guardian) return; // reserved salt namespace
        bytes32 id = idOf(i);
        if (timelock.isOperationDone(id)) return;
        if (timelock.isOperationPending(id)) {
            vm.prank(proposer);
            timelock.cancel(id);
        }

        uint256 delay = timelock.getRequiredDelay(c.target, c.data);
        vm.prank(proposer);
        if (c.batch) {
            timelock.scheduleBatch(_targets(c.target), _values(), _payloads(c.data), bytes32(0), c.salt, delay);
        } else {
            timelock.schedule(c.target, 0, c.data, bytes32(0), c.salt, delay);
        }
        c.raw = true;
        c.epoch = timelock.pauseEpoch();
    }

    // ---- Execution / cancellation ----

    function execute(uint256 idx) external {
        if (_calls.length == 0) return;
        uint256 i = idx % _calls.length;
        Call memory c = _calls[i];
        bytes32 id = idOf(i);
        if (!timelock.isOperationReady(id)) return;
        // A direct unpause() of a running target reverts in the target itself; nothing to check there
        if (c.target == address(target) && bytes4(c.data) == GovTimelockTarget.unpause.selector && !target.paused()) {
            return;
        }

        uint256 epoch = timelock.pauseEpoch();
        bool stale = c.unpause && c.epoch != epoch;
        address caller = timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)) ? address(this) : executor;

        if (stale) {
            vm.expectRevert(abi.encodeWithSelector(IGovernanceTimelock.StaleUnpause.selector, id, c.epoch, epoch));
        }
        vm.prank(caller);
        if (c.batch) {
            timelock.executeBatch(_targets(c.target), _values(), _payloads(c.data), bytes32(0), c.salt);
        } else {
            timelock.execute(c.target, 0, c.data, bytes32(0), c.salt);
        }

        if (stale) {
            staleRejections++;
            assertTrue(timelock.isOperationReady(id));
        } else {
            _executedIds.push(id);
            if (c.unpause) assertFalse(target.paused());
        }
    }

    function cancel(uint256 idx) external {
        if (_calls.length == 0) return;
        bytes32 id = idOf(idx % _calls.length);
        if (!timelock.isOperationPending(id)) return;
        vm.prank(proposer);
        timelock.cancel(id);
    }

    // ---- Pause ----

    function pauseAll() external {
        vm.prank(guardian);
        timelock.emergencyPauseAll("drill");
        pauseCount++;
        assertTrue(target.paused());
    }

    // ---- Configuration ----

    function updateDelays(uint256 minD, uint256 emD, uint256 longD) external {
        minD = _bound(minD, 1 hours, 30 days);
        emD = _bound(emD, 15 minutes, minD);
        longD = _bound(longD, minD, 60 days);
        vm.prank(admin);
        timelock.updateDelays(minD, emD, longD);
    }

    function setOpenExecution(bool open) external {
        bytes32 role = timelock.EXECUTOR_ROLE();
        if (!open && timelock.hasRole(role, address(0)) && !timelock.hasRole(role, executor)) {
            vm.expectRevert(abi.encodeWithSelector(IGovernanceTimelock.LastExecutor.selector, address(0)));
        }
        vm.prank(admin);
        timelock.setOpenExecutor(open);
    }

    function setExplicitExecutor(bool grant) external {
        bytes32 role = timelock.EXECUTOR_ROLE();
        if (!grant && timelock.hasRole(role, executor) && !timelock.hasRole(role, address(0))) {
            vm.expectRevert(abi.encodeWithSelector(IGovernanceTimelock.LastExecutor.selector, executor));
        }
        vm.prank(admin);
        if (grant) timelock.grantRole(role, executor);
        else timelock.revokeRole(role, executor);
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + _bound(dt, 0, 5 days));
    }

    // ---- Helpers ----

    function _push(address tgt, bytes memory data, bytes32 salt, bool batch, bool raw, bool byGuardian) internal {
        bytes4 sel = bytes4(data);
        bool unpause = sel == GovTimelockTarget.unpause.selector
            || (tgt == address(timelock) && sel == IGovernanceTimelock.emergencyUnpauseAll.selector);
        _calls.push(Call(tgt, data, salt, batch, raw, byGuardian, unpause, timelock.pauseEpoch()));
    }

    function _label(uint8 label) internal pure returns (IGovernanceTimelock.OperationType opType) {
        opType = IGovernanceTimelock.OperationType(label % 7);
        if (opType == IGovernanceTimelock.OperationType.EmergencyAction) {
            opType = IGovernanceTimelock.OperationType.ParameterChange;
        }
    }

    function _targets(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _values() internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
    }

    function _payloads(bytes memory d) internal pure returns (bytes[] memory arr) {
        arr = new bytes[](1);
        arr[0] = d;
    }
}

contract GovernanceTimelockInvariantTest is GovernanceTimelockFixture {
    GovTimelockHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new GovTimelockHandler(timelock, target, admin, proposer, guardian);

        // emergencyPauseAll / emergencyUnpauseAll act on the target
        vm.prank(admin);
        timelock.registerProtocolContract("ilrm", address(target));

        // Fuzz the actions only (the handler's getters revert on out-of-range indexes)
        bytes4[] memory selectors = new bytes4[](16);
        selectors[0] = GovTimelockHandler.scheduleStandard.selector;
        selectors[1] = GovTimelockHandler.scheduleCritical.selector;
        selectors[2] = GovTimelockHandler.scheduleRaw.selector;
        selectors[3] = GovTimelockHandler.scheduleBatchLabelled.selector;
        selectors[4] = GovTimelockHandler.scheduleEmergency.selector;
        selectors[5] = GovTimelockHandler.queueUnpause.selector;
        selectors[6] = GovTimelockHandler.rescheduleRaw.selector;
        selectors[7] = GovTimelockHandler.execute.selector;
        selectors[8] = GovTimelockHandler.execute.selector; // weight execution
        selectors[9] = GovTimelockHandler.cancel.selector;
        selectors[10] = GovTimelockHandler.pauseAll.selector;
        selectors[11] = GovTimelockHandler.updateDelays.selector;
        selectors[12] = GovTimelockHandler.setOpenExecution.selector;
        selectors[13] = GovTimelockHandler.setExplicitExecutor.selector;
        selectors[14] = GovTimelockHandler.warp.selector;
        selectors[15] = GovTimelockHandler.warp.selector; // weight time
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: ci.invariant.runs = 64
    /// forge-config: ci.invariant.depth = 64
    /// forge-config: ci.invariant.fail-on-revert = true
    function invariant_MinDelayMatchesConfig() public view {
        assertEq(timelock.getMinDelay(), timelock.getTimelockConfig().minDelay);
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: ci.invariant.runs = 64
    /// forge-config: ci.invariant.depth = 64
    /// forge-config: ci.invariant.fail-on-revert = true
    function invariant_DelayBoundsHold() public view {
        IGovernanceTimelock.TimelockConfig memory cfg = timelock.getTimelockConfig();
        assertGe(cfg.minDelay, 1 hours);
        assertLe(cfg.minDelay, 30 days);
        assertGe(cfg.emergencyDelay, 15 minutes);
        assertLe(cfg.emergencyDelay, cfg.minDelay);
        assertLe(cfg.minDelay, cfg.longDelay);
        assertLe(cfg.longDelay, 60 days);
    }

    /// @dev Pending list: OZ-pending, metadata in sync, and no duplicate entries (the property the
    ///      removed _storeOperation dedupe guard was meant to protect)
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: ci.invariant.runs = 64
    /// forge-config: ci.invariant.depth = 64
    /// forge-config: ci.invariant.fail-on-revert = true
    function invariant_PendingListConsistent() public view {
        bytes32[] memory pending = timelock.getPendingOperations();
        assertEq(pending.length, timelock.getPendingOperationsCount());
        for (uint256 i = 0; i < pending.length; ++i) {
            assertTrue(timelock.isOperationPending(pending[i]));
            IGovernanceTimelock.GovernanceOperation memory op = timelock.getOperation(pending[i]);
            assertEq(op.id, pending[i]);
            assertEq(op.readyAt, timelock.getTimestamp(pending[i]));
            IGovernanceTimelock.OperationStatus expected = timelock.isOperationReady(pending[i])
                ? IGovernanceTimelock.OperationStatus.Ready
                : IGovernanceTimelock.OperationStatus.Pending;
            assertEq(uint256(op.status), uint256(expected));
            for (uint256 j = 0; j < i; ++j) {
                assertTrue(pending[j] != pending[i], "duplicate pending entry");
            }
        }
    }

    /// @dev getOperation never contradicts OZ: raw schedules (including raw re-schedules of a
    ///      previously tracked id) carry no metadata, tracked ones mirror the OZ state
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: ci.invariant.runs = 64
    /// forge-config: ci.invariant.depth = 64
    /// forge-config: ci.invariant.fail-on-revert = true
    function invariant_MetadataMatchesOz() public view {
        uint256 trackedPending;
        uint256 n = handler.callCount();
        for (uint256 i = 0; i < n; ++i) {
            GovTimelockHandler.Call memory c = handler.callAt(i);
            bytes32 id = handler.idOf(i);
            IGovernanceTimelock.GovernanceOperation memory op = timelock.getOperation(id);

            if (c.raw) {
                assertEq(uint256(op.status), uint256(IGovernanceTimelock.OperationStatus.None), "raw op has metadata");
                assertEq(op.scheduledAt, 0);
                continue;
            }

            assertEq(uint256(op.status), uint256(_expectedStatus(timelock.getOperationState(id))), "status vs OZ");
            assertEq(op.id, id);
            assertEq(op.salt, c.salt);
            if (timelock.isOperationPending(id)) {
                assertEq(op.readyAt, timelock.getTimestamp(id));
                trackedPending++;
            }
        }
        assertEq(timelock.getPendingOperationsCount(), trackedPending);
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: ci.invariant.runs = 64
    /// forge-config: ci.invariant.depth = 64
    /// forge-config: ci.invariant.fail-on-revert = true
    function invariant_ExecutedStayDoneAndCountersTrack() public view {
        uint256 n = handler.executedCount();
        for (uint256 i = 0; i < n; ++i) {
            assertEq(timelock.getTimestamp(handler.executedId(i)), 1);
        }
        assertEq(timelock.emergencyNonce(), handler.guardianOps());
        assertEq(timelock.pauseEpoch(), handler.pauseCount());
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    /// forge-config: ci.invariant.runs = 64
    /// forge-config: ci.invariant.depth = 64
    /// forge-config: ci.invariant.fail-on-revert = true
    function invariant_ExecutionNeverBricked() public view {
        bytes32 role = timelock.EXECUTOR_ROLE();
        uint256 holders =
            (timelock.hasRole(role, address(0)) ? 1 : 0) + (timelock.hasRole(role, handler.executor()) ? 1 : 0);
        assertGe(holders, 1);
        assertEq(timelock.getExecutorCount(), holders);
    }

    function _expectedStatus(TimelockController.OperationState s)
        internal
        pure
        returns (IGovernanceTimelock.OperationStatus)
    {
        if (s == TimelockController.OperationState.Unset) return IGovernanceTimelock.OperationStatus.Cancelled;
        if (s == TimelockController.OperationState.Waiting) return IGovernanceTimelock.OperationStatus.Pending;
        if (s == TimelockController.OperationState.Ready) return IGovernanceTimelock.OperationStatus.Ready;
        return IGovernanceTimelock.OperationStatus.Executed;
    }
}
