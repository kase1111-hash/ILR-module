// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/governance/TimelockController.sol";
import "../interfaces/IGovernanceTimelock.sol";

/// @notice Simple interface for checking pausable contracts
interface IPausable {
    function paused() external view returns (bool);
}

/**
 * @title GovernanceTimelock
 * @notice NatLangChain protocol governance with multi-sig and timelock
 * @dev Extends OpenZeppelin TimelockController with protocol-specific features
 *
 * Governance Flow:
 * 1. Multi-sig proposes operation (scheduleOperation, or the inherited schedule/scheduleBatch)
 * 2. Timelock delay passes (minDelay or longDelay, derived from what the call does)
 * 3. Executor executes operation (executeOperation, or the inherited execute/executeBatch)
 * 4. Protocol state is updated
 *
 * Delay policy:
 * - The required delay comes from the call content. Calls to the timelock itself and calls with a
 *   locked selector (ownership, roles, upgrades, multicall) always need longDelay. Governance can mark
 *   further (target, selector) pairs LongDelay via setCallClass. Everything else needs minDelay.
 * - The OperationType label can only lengthen the delay; EmergencyAction is reserved.
 * - Every OZ scheduling entry point is overridden, so the inherited schedule/scheduleBatch enforce the
 *   same floor (reverting with OZ's TimelockInsufficientDelay).
 *
 * Emergency path (EMERGENCY_ROLE, never a proposer):
 * - executeEmergency queues single, zero-value calls whose (target, selector) governance classified
 *   Emergency (default-deny) at emergencyDelay.
 * - emergencyPauseAll pauses every registered contract at once; emergencyUnpauseAll only queues the
 *   unpause, at minDelay.
 * - Guardian operations use the normal OZ queue with a salt from a reserved namespace plus a nonce,
 *   so cancellers can veto them during their delay.
 *
 * Pause epochs:
 * - emergencyPauseAll increments pauseEpoch. Every operation that calls unpause() (any target) or the
 *   timelock's emergencyUnpauseAll is bound to the epoch it was scheduled in and reverts with
 *   StaleUnpause in any later epoch, so no unpause queued before an emergency pause can undo it.
 * - Such a stale unpause stays pending (and becomes ready) in OZ's state views until a canceller
 *   cancels it. isOperationStale reports it, getOperation reports it Stale, and
 *   getPendingOperations(Count) leave it out (getStaleOperations lists it).
 *
 * Invariants:
 * - OZ's operation-state views (getTimestamp, isOperation*, getOperationState, hashOperation*) are not
 *   overridden; executed operations are marked done and cannot be replayed.
 * - _config is the single source of delay configuration; getMinDelay() reads it. Whether execution is
 *   open is not stored: it is EXECUTOR_ROLE of address(0).
 * - EXECUTOR_ROLE always has at least one live holder: an account other than the timelock itself
 *   (address(0), open execution, counts). The timelock can only call execute from inside an execution
 *   someone else started, so as the only holder it could never initiate one.
 * - Metadata: an id is in the pending list iff its record is Pending iff it was scheduled through a
 *   metadata path and OZ still reports it pending. A non-empty record always describes the id's
 *   latest scheduling; a raw OZ schedule clears the record of an earlier, cancelled scheduling. The
 *   views derive Ready (from OZ) and Stale (from the pause epoch) from a Pending record.
 */
contract GovernanceTimelock is TimelockController, IGovernanceTimelock {
    // ============ Constants ============

    /// @notice Role for emergency actions
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    /// @notice Minimum allowed delay (1 hour)
    uint256 public constant MIN_ALLOWED_DELAY = 1 hours;

    /// @notice Maximum allowed delay (30 days)
    uint256 public constant MAX_ALLOWED_DELAY = 30 days;

    /// @notice Minimum allowed emergency delay (15 minutes)
    uint256 public constant MIN_EMERGENCY_DELAY = 15 minutes;

    /// @notice Maximum allowed long delay (60 days)
    uint256 public constant MAX_LONG_DELAY = 60 days;

    /// @dev Upper 96 bits of a salt; the lower 160 bits carry the emergency nonce
    bytes32 private constant _SALT_PREFIX_MASK = ~bytes32(uint256(type(uint160).max));

    /// @dev Salt namespace reserved for operations queued by EMERGENCY_ROLE
    bytes32 private constant _EMERGENCY_SALT_PREFIX =
        keccak256("ILRM.GovernanceTimelock.emergency-salt") & _SALT_PREFIX_MASK;

    // Locked selectors: always LongDelay, can never be reclassified
    bytes4 private constant _SEL_TRANSFER_OWNERSHIP = bytes4(keccak256("transferOwnership(address)"));
    bytes4 private constant _SEL_RENOUNCE_OWNERSHIP = bytes4(keccak256("renounceOwnership()"));
    bytes4 private constant _SEL_GRANT_ROLE = bytes4(keccak256("grantRole(bytes32,address)"));
    bytes4 private constant _SEL_REVOKE_ROLE = bytes4(keccak256("revokeRole(bytes32,address)"));
    bytes4 private constant _SEL_RENOUNCE_ROLE = bytes4(keccak256("renounceRole(bytes32,address)"));
    bytes4 private constant _SEL_BEGIN_DEFAULT_ADMIN_TRANSFER = bytes4(keccak256("beginDefaultAdminTransfer(address)"));
    bytes4 private constant _SEL_UPGRADE_TO = bytes4(keccak256("upgradeTo(address)"));
    bytes4 private constant _SEL_UPGRADE_TO_AND_CALL = bytes4(keccak256("upgradeToAndCall(address,bytes)"));
    bytes4 private constant _SEL_UPGRADE_AND_CALL = bytes4(keccak256("upgradeAndCall(address,address,bytes)"));
    bytes4 private constant _SEL_UPGRADE = bytes4(keccak256("upgrade(address,address)"));
    bytes4 private constant _SEL_CHANGE_ADMIN = bytes4(keccak256("changeAdmin(address)"));
    bytes4 private constant _SEL_CHANGE_PROXY_ADMIN = bytes4(keccak256("changeProxyAdmin(address,address)"));
    bytes4 private constant _SEL_MULTICALL = bytes4(keccak256("multicall(bytes[])"));

    // Unpause selectors bound to the pause epoch they were scheduled in
    bytes4 private constant _SEL_UNPAUSE = bytes4(keccak256("unpause()"));
    bytes4 private constant _SEL_EMERGENCY_UNPAUSE_ALL = IGovernanceTimelock.emergencyUnpauseAll.selector;

    /// @dev Description recorded for queued emergencyUnpauseAll operations
    string private constant _UNPAUSE_ALL_REASON = "Emergency unpause all";

    // ============ Types ============

    /// @dev Stored delay configuration (TimelockConfig without the derived openExecutor flag)
    struct DelayConfig {
        uint256 minDelay;
        uint256 emergencyDelay;
        uint256 longDelay;
    }

    // ============ State Variables ============

    /// @notice Delay configuration (single source of delay configuration)
    DelayConfig private _config;

    /// @notice Protocol contract registry
    ProtocolContracts private _protocolContracts;

    /// @notice Contract name to address mapping
    mapping(string => address) private _contractRegistry;

    /// @notice Operation metadata
    mapping(bytes32 => GovernanceOperation) private _operations;

    /// @notice List of pending operation IDs
    bytes32[] private _pendingOperations;

    /// @notice Index of operation in pending array (1-based; 0 = not pending)
    mapping(bytes32 => uint256) private _pendingIndex;

    /// @notice Registered delay class per (target, selector)
    mapping(address => mapping(bytes4 => CallClass)) private _callClass;

    /// @notice Number of operations EMERGENCY_ROLE queued so far (low bits of the emergency salt)
    uint256 public emergencyNonce;

    /// @inheritdoc IGovernanceTimelock
    uint256 public pauseEpoch;

    /// @dev pauseEpoch + 1 at scheduling time for operations that unpause (0 = not an unpause)
    mapping(bytes32 => uint256) private _unpauseEpochTag;

    /// @dev Number of live EXECUTOR_ROLE holders: address(0) included, the timelock itself excluded
    uint256 private _executorCount;

    /// @dev True only while _queueGuardianOperation calls TimelockController.schedule
    bool private _emergencyScheduling;

    // ============ Constructor ============

    /**
     * @param minDelay Minimum delay for standard operations (e.g., 2 days)
     * @param proposers Addresses with proposer role (multi-sig)
     * @param executors Addresses with executor role (or empty for open execution). A list naming only
     *        the timelock itself reverts with LastExecutor: the timelock cannot initiate an execution.
     * @param admin Admin address for initial setup (should renounce later). It is NOT granted
     *        EMERGENCY_ROLE; grant that role explicitly.
     */
    constructor(uint256 minDelay, address[] memory proposers, address[] memory executors, address admin)
        TimelockController(minDelay, proposers, executors, admin)
    {
        require(minDelay >= MIN_ALLOWED_DELAY, "Delay too short");
        require(minDelay <= MAX_ALLOWED_DELAY, "Delay too long");

        // Defaults always satisfy the delay bounds: 15m <= min/4 <= min <= 2*min <= 60d
        _config = DelayConfig({
            minDelay: minDelay,
            emergencyDelay: minDelay / 4, // 25% of normal delay
            longDelay: minDelay * 2 // 200% of normal delay
        });

        // An empty executor list means anyone may execute after the delay
        if (executors.length == 0) {
            _grantRole(EXECUTOR_ROLE, address(0));
        }
        // Only reachable with a list naming nothing but the timelock's own (precomputed) address
        if (_executorCount == 0) revert LastExecutor(address(this));
    }

    // ============ OZ Scheduling Entry Points (policy checkpoint) ============

    /**
     * @notice Schedule a single call (OZ entry point)
     * @dev Enforces the content-derived delay floor and rejects the reserved emergency salt namespace.
     *      Records no governance metadata, and clears the record a cancelled earlier scheduling of the
     *      same id left behind (the metadata paths re-record it).
     */
    function schedule(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) public override onlyRole(PROPOSER_ROLE) {
        _rejectReservedSalt(salt);
        uint256 required = _requiredDelay(target, data);
        if (delay < required) revert TimelockInsufficientDelay(delay, required);
        super.schedule(target, value, data, predecessor, salt, delay);
        _afterProposerSchedule(hashOperation(target, value, data, predecessor, salt), _isUnpauseCall(target, data));
    }

    /**
     * @notice Schedule a batch of calls (OZ entry point)
     * @dev Enforces the strictest call's content-derived delay floor and rejects the reserved emergency
     *      salt namespace. Records no governance metadata, and clears the record a cancelled earlier
     *      scheduling of the same id left behind (the metadata paths re-record it).
     */
    function scheduleBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata payloads,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) public override onlyRole(PROPOSER_ROLE) {
        _rejectReservedSalt(salt);
        uint256 required = _requiredDelayBatch(targets, values, payloads);
        if (delay < required) revert TimelockInsufficientDelay(delay, required);
        super.scheduleBatch(targets, values, payloads, predecessor, salt, delay);
        _afterProposerSchedule(
            hashOperationBatch(targets, values, payloads, predecessor, salt), _containsUnpause(targets, payloads)
        );
    }

    // ============ Scheduling Functions ============

    /// @inheritdoc IGovernanceTimelock
    function scheduleOperation(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt,
        OperationType opType,
        string calldata description
    ) external override onlyRole(PROPOSER_ROLE) returns (bytes32 id) {
        // The label can only lengthen the content-derived delay
        uint256 delay = _withLabelFloor(_requiredDelay(target, data), opType);
        id = _scheduleTracked(target, value, data, predecessor, salt, opType, delay, description);
    }

    /// @inheritdoc IGovernanceTimelock
    function scheduleBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata datas,
        bytes32 predecessor,
        bytes32 salt,
        OperationType opType,
        string calldata description
    ) external override onlyRole(PROPOSER_ROLE) returns (bytes32 id) {
        // Validates the array lengths before anything else, then applies the label floor
        uint256 delay = _withLabelFloor(_requiredDelayBatch(targets, values, datas), opType);

        // Schedule batch via the policy checkpoint
        scheduleBatch(targets, values, datas, predecessor, salt, delay);
        id = hashOperationBatch(targets, values, datas, predecessor, salt);

        // Metadata records the first call of the batch
        GovernanceOperation storage op = _track(id, opType, predecessor, salt, block.timestamp + delay, description);
        if (targets.length > 0) {
            op.target = targets[0];
            op.value = values[0];
            op.data = datas[0];
        }

        emit OperationScheduled(id, opType, op.target, op.value, op.data, op.readyAt, description);
    }

    /// @inheritdoc IGovernanceTimelock
    function scheduleLongDelay(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt,
        OperationType opType,
        string calldata description
    ) external override onlyRole(PROPOSER_ROLE) returns (bytes32 id) {
        if (opType == OperationType.EmergencyAction) revert EmergencyActionLabelReserved();

        // longDelay satisfies every content requirement
        id = _scheduleTracked(target, value, data, predecessor, salt, opType, _config.longDelay, description);
    }

    // ============ Execution Functions ============

    /**
     * @notice Execute a ready single-call operation (OZ entry point)
     * @dev Rejects unpause operations from an earlier pause epoch and keeps governance metadata in sync
     */
    function execute(address target, uint256 value, bytes calldata payload, bytes32 predecessor, bytes32 salt)
        public
        payable
        override
    {
        bytes32 id = hashOperation(target, value, payload, predecessor, salt);
        _requireCurrentPauseEpoch(id);
        super.execute(target, value, payload, predecessor, salt);
        _markExecuted(id, target);
    }

    /// @inheritdoc IGovernanceTimelock
    function executeOperation(address target, uint256 value, bytes calldata data, bytes32 predecessor, bytes32 salt)
        external
        payable
        override
    {
        execute(target, value, data, predecessor, salt);
    }

    /// @inheritdoc IGovernanceTimelock
    function executeBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata datas,
        bytes32 predecessor,
        bytes32 salt
    ) public payable override(TimelockController, IGovernanceTimelock) {
        bytes32 id = hashOperationBatch(targets, values, datas, predecessor, salt);
        _requireCurrentPauseEpoch(id);

        // Execute batch via parent (enforces EXECUTOR_ROLE, array lengths and readiness)
        super.executeBatch(targets, values, datas, predecessor, salt);

        _markExecuted(id, targets.length > 0 ? targets[0] : address(0));
    }

    /**
     * @notice Cancel a pending operation (OZ entry point)
     * @dev Keeps governance metadata in sync with OZ state
     */
    function cancel(bytes32 id) public override {
        super.cancel(id);
        _markCancelled(id);
    }

    /// @inheritdoc IGovernanceTimelock
    function cancelOperation(bytes32 id) external override onlyRole(CANCELLER_ROLE) {
        cancel(id);
    }

    // ============ Emergency Functions ============

    /// @inheritdoc IGovernanceTimelock
    function executeEmergency(address target, bytes calldata data, string calldata reason)
        external
        override
        onlyRole(EMERGENCY_ROLE)
        returns (bytes32 id)
    {
        bytes4 sel = _selectorOf(data);
        if (data.length < 4 || _effectiveClass(target, sel) != CallClass.Emergency) {
            revert NotEmergencyCall(target, sel);
        }

        // Queued, not executed: the event says so (EmergencyActionScheduled)
        id = _queueGuardianOperation(target, data, _config.emergencyDelay, OperationType.EmergencyAction, reason);
    }

    /// @inheritdoc IGovernanceTimelock
    function emergencyPauseAll(string calldata reason) external override onlyRole(EMERGENCY_ROLE) {
        // A new epoch: every unpause scheduled before this point can no longer execute
        ++pauseEpoch;

        // Pause all registered protocol contracts
        if (_protocolContracts.ilrm != address(0)) {
            _pauseContract(_protocolContracts.ilrm);
        }
        if (_protocolContracts.treasury != address(0)) {
            _pauseContract(_protocolContracts.treasury);
        }
        if (_protocolContracts.multiPartyILRM != address(0)) {
            _pauseContract(_protocolContracts.multiPartyILRM);
        }
        if (_protocolContracts.complianceCouncil != address(0)) {
            _pauseContract(_protocolContracts.complianceCouncil);
        }
        if (_protocolContracts.batchQueue != address(0)) {
            _pauseContract(_protocolContracts.batchQueue);
        }
        if (_protocolContracts.dummyGenerator != address(0)) {
            _pauseContract(_protocolContracts.dummyGenerator);
        }

        emit EmergencyActionExecuted(keccak256(abi.encodePacked("PAUSE_ALL", block.timestamp)), msg.sender, reason);
    }

    /// @inheritdoc IGovernanceTimelock
    function emergencyUnpauseAll() external override returns (bytes32 id) {
        if (msg.sender == address(this)) {
            // A queued unpause is executing (its pause epoch was checked by execute/executeBatch)
            _unpauseAll();
            return bytes32(0);
        }

        // A guardian queues this very call (target = the timelock, data = its selector) at minDelay
        _checkRole(EMERGENCY_ROLE);
        id = _queueGuardianOperation(
            address(this), msg.data[:4], _config.minDelay, OperationType.ProtocolPause, _UNPAUSE_ALL_REASON
        );
        _unpauseEpochTag[id] = pauseEpoch + 1;
    }

    // ============ Protocol Management ============

    /// @inheritdoc IGovernanceTimelock
    function registerProtocolContract(string calldata name, address contractAddress)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(contractAddress != address(0), "Invalid address");

        _contractRegistry[name] = contractAddress;

        // Update struct for known contracts
        bytes32 nameHash = keccak256(bytes(name));
        if (nameHash == keccak256("ilrm")) {
            _protocolContracts.ilrm = contractAddress;
        } else if (nameHash == keccak256("treasury")) {
            _protocolContracts.treasury = contractAddress;
        } else if (nameHash == keccak256("oracle")) {
            _protocolContracts.oracle = contractAddress;
        } else if (nameHash == keccak256("assetRegistry")) {
            _protocolContracts.assetRegistry = contractAddress;
        } else if (nameHash == keccak256("multiPartyILRM")) {
            _protocolContracts.multiPartyILRM = contractAddress;
        } else if (nameHash == keccak256("complianceCouncil")) {
            _protocolContracts.complianceCouncil = contractAddress;
        } else if (nameHash == keccak256("batchQueue")) {
            _protocolContracts.batchQueue = contractAddress;
        } else if (nameHash == keccak256("dummyGenerator")) {
            _protocolContracts.dummyGenerator = contractAddress;
        }

        emit ProtocolContractRegistered(name, contractAddress);
    }

    /// @inheritdoc IGovernanceTimelock
    function acceptContractOwnership(address contractAddress) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        // Call acceptOwnership on the target contract (for Ownable2Step)
        (bool success,) = contractAddress.call(abi.encodeWithSignature("acceptOwnership()"));
        require(success, "Accept ownership failed");

        emit OwnershipAccepted(contractAddress, "");
    }

    /// @inheritdoc IGovernanceTimelock
    function getProtocolContracts() external view override returns (ProtocolContracts memory) {
        return _protocolContracts;
    }

    // ============ View Functions ============

    /// @inheritdoc IGovernanceTimelock
    function getOperation(bytes32 id) external view override returns (GovernanceOperation memory op) {
        op = _operations[id];
        // A pending record stores Pending. Overlay what it cannot store: a stale unpause can never
        // execute (whatever OZ reports); otherwise OZ knows when the delay has passed.
        if (_pendingIndex[id] != 0) {
            if (_hasStaleEpoch(id)) {
                op.status = OperationStatus.Stale;
            } else if (isOperationReady(id)) {
                op.status = OperationStatus.Ready;
            }
        }
    }

    /// @inheritdoc IGovernanceTimelock
    function isOperationStale(bytes32 id) external view override returns (bool) {
        return _hasStaleEpoch(id) && isOperationPending(id);
    }

    /// @inheritdoc IGovernanceTimelock
    function getTimelockConfig() external view override returns (TimelockConfig memory) {
        return TimelockConfig({
            minDelay: _config.minDelay,
            emergencyDelay: _config.emergencyDelay,
            longDelay: _config.longDelay,
            openExecutor: hasRole(EXECUTOR_ROLE, address(0))
        });
    }

    /// @inheritdoc IGovernanceTimelock
    function getPendingOperationsCount() external view override returns (uint256) {
        return _countPending(false);
    }

    /**
     * @notice Minimum delay for operations
     * @dev Reads _config (the single source of delay configuration). Inside the frame in which
     *      EMERGENCY_ROLE queues an operation it returns emergencyDelay, so TimelockController accepts
     *      the emergency delay.
     */
    function getMinDelay() public view override returns (uint256) {
        return _emergencyScheduling ? _config.emergencyDelay : _config.minDelay;
    }

    /// @inheritdoc IGovernanceTimelock
    function getCallClass(address target, bytes4 selector) external view override returns (CallClass) {
        return _effectiveClass(target, selector);
    }

    /// @inheritdoc IGovernanceTimelock
    function getRequiredDelay(address target, bytes calldata data) external view override returns (uint256) {
        return _requiredDelay(target, data);
    }

    /**
     * @notice Number of live EXECUTOR_ROLE holders: address(0) (open execution) included, the timelock
     *         itself excluded (it cannot initiate an execution)
     * @dev Never drops to zero: revoking or renouncing the last live holder reverts with LastExecutor
     */
    function getExecutorCount() external view returns (uint256) {
        return _executorCount;
    }

    // ============ Configuration Functions ============

    /// @inheritdoc IGovernanceTimelock
    function updateDelays(uint256 minDelay, uint256 emergencyDelay, uint256 longDelay)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _setDelays(minDelay, emergencyDelay, longDelay);
    }

    /**
     * @notice Update the minimum delay (OZ entry point)
     * @dev Only callable by the timelock itself. Validated against the delay bounds and kept in sync
     *      with _config; the emergency and long delays are unchanged.
     */
    function updateDelay(uint256 newDelay) external override {
        if (msg.sender != address(this)) revert TimelockUnauthorizedCaller(msg.sender);
        _setDelays(newDelay, _config.emergencyDelay, _config.longDelay);
    }

    /// @inheritdoc IGovernanceTimelock
    function setOpenExecutor(bool open) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (open) {
            // Grant executor role to zero address (anyone)
            _grantRole(EXECUTOR_ROLE, address(0));
        } else {
            // Reverts with LastExecutor when no explicit executor other than the timelock would be left
            _revokeRole(EXECUTOR_ROLE, address(0));
        }
    }

    /// @inheritdoc IGovernanceTimelock
    function setCallClass(address target, bytes4 selector, CallClass callClass)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (target == address(0) || target == address(this)) revert InvalidCallClassTarget(target);
        if (_isLockedSelector(selector)) revert CallClassLocked(selector);
        // Unpausing is never a defensive call: no unpause path may use emergencyDelay
        if (callClass == CallClass.Emergency && selector == _SEL_UNPAUSE) {
            revert InvalidCallClass(target, selector, callClass);
        }

        _callClass[target][selector] = callClass;

        emit CallClassUpdated(target, selector, callClass);
    }

    // ============ Internal Functions ============

    /**
     * @dev Inside the frame in which EMERGENCY_ROLE queues an operation, TimelockController.schedule's
     *      PROPOSER_ROLE check is satisfied by EMERGENCY_ROLE instead. Outside that frame PROPOSER_ROLE
     *      is never substituted.
     */
    function _checkRole(bytes32 role) internal view override {
        if (_emergencyScheduling && role == PROPOSER_ROLE) {
            role = EMERGENCY_ROLE;
        }
        super._checkRole(role);
    }

    /**
     * @dev Counts live EXECUTOR_ROLE holders (address(0) included, the timelock itself excluded)
     */
    function _grantRole(bytes32 role, address account) internal override returns (bool granted) {
        granted = super._grantRole(role, account);
        if (granted && _isLiveExecutor(role, account)) {
            ++_executorCount;
        }
    }

    /**
     * @dev No path (setOpenExecutor, revokeRole, renounceRole) may remove the last live EXECUTOR_ROLE
     *      holder: without one no operation could execute, including the one that would grant a new
     *      executor. The timelock's own EXECUTOR_ROLE does not count and can always be removed.
     */
    function _revokeRole(bytes32 role, address account) internal override returns (bool revoked) {
        revoked = super._revokeRole(role, account);
        if (revoked && _isLiveExecutor(role, account)) {
            if (_executorCount < 2) revert LastExecutor(account);
            --_executorCount;
        }
    }

    /**
     * @dev Whether (role, account) is a live executor: EXECUTOR_ROLE held by anyone but the timelock,
     *      which can only call execute from inside an execution someone else initiated
     */
    function _isLiveExecutor(bytes32 role, address account) private view returns (bool) {
        return role == EXECUTOR_ROLE && account != address(this);
    }

    /**
     * @dev Queue an operation on behalf of EMERGENCY_ROLE through TimelockController.schedule, with a
     *      salt from the reserved namespace, and record its metadata
     * @param target Call target
     * @param data Calldata (value and predecessor are always 0)
     * @param delay emergencyDelay (executeEmergency) or minDelay (emergencyUnpauseAll)
     * @param opType Label recorded in the metadata
     * @param reason Description recorded in the metadata
     * @return id Operation ID
     */
    function _queueGuardianOperation(
        address target,
        bytes calldata data,
        uint256 delay,
        OperationType opType,
        string memory reason
    ) private returns (bytes32 id) {
        bytes32 salt = _EMERGENCY_SALT_PREFIX | bytes32(++emergencyNonce);
        id = hashOperation(target, 0, data, bytes32(0), salt);

        // TimelockController.schedule reads the flag (in _checkRole and getMinDelay) and makes no
        // external call, so the flag is never observable outside this frame.
        // slither-disable-next-line write-after-write
        _emergencyScheduling = true;
        super.schedule(target, 0, data, bytes32(0), salt, delay);
        _emergencyScheduling = false;

        uint256 readyAt = block.timestamp + delay;
        GovernanceOperation storage op = _track(id, opType, bytes32(0), salt, readyAt, reason);
        op.target = target;
        op.data = data;

        emit OperationScheduled(id, opType, target, 0, data, readyAt, reason);
        emit EmergencyActionScheduled(id, msg.sender, target, salt, readyAt, reason);
    }

    /**
     * @dev Schedule a single call through the policy checkpoint and record its metadata
     */
    function _scheduleTracked(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt,
        OperationType opType,
        uint256 delay,
        string calldata description
    ) private returns (bytes32 id) {
        schedule(target, value, data, predecessor, salt, delay);
        id = hashOperation(target, value, data, predecessor, salt);

        GovernanceOperation storage op = _track(id, opType, predecessor, salt, block.timestamp + delay, description);
        op.target = target;
        op.value = value;
        op.data = data;

        emit OperationScheduled(id, opType, target, value, data, op.readyAt, description);
    }

    /**
     * @dev After a proposer-path schedule: drop a stale record and bind unpause operations to the epoch
     * @param id Operation ID just scheduled
     * @param unpauses Whether the operation calls unpause() or the timelock's emergencyUnpauseAll
     */
    function _afterProposerSchedule(bytes32 id, bool unpauses) private {
        // OZ only re-schedules an id that is unset, so any record left here belongs to an earlier,
        // cancelled scheduling. Raw schedules record nothing; metadata paths re-record right after.
        // scheduledAt is only tested against the zero sentinel (record exists), never against time.
        // slither-disable-next-line timestamp
        if (_operations[id].scheduledAt != 0) {
            delete _operations[id];
        }
        if (unpauses) {
            _unpauseEpochTag[id] = pauseEpoch + 1;
        }
    }

    /**
     * @dev Revert if the operation unpauses and an emergencyPauseAll happened after it was scheduled
     */
    function _requireCurrentPauseEpoch(bytes32 id) private view {
        if (_hasStaleEpoch(id)) revert StaleUnpause(id, _unpauseEpochTag[id] - 1, pauseEpoch);
    }

    /**
     * @dev Whether the id's latest scheduling unpauses and an emergencyPauseAll happened after it. Says
     *      nothing about OZ state: an executed or cancelled unpause keeps its tag.
     */
    function _hasStaleEpoch(bytes32 id) private view returns (bool) {
        uint256 tag = _unpauseEpochTag[id];
        return tag != 0 && tag != pauseEpoch + 1;
    }

    /**
     * @dev Number of pending-list ids that are (stale = true) or are not (stale = false) stale unpauses.
     *      Every listed id is pending in OZ, so its pause epoch alone decides.
     */
    function _countPending(bool stale) private view returns (uint256 n) {
        uint256 len = _pendingOperations.length;
        for (uint256 i = 0; i < len; ++i) {
            if (_hasStaleEpoch(_pendingOperations[i]) == stale) ++n;
        }
    }

    /**
     * @dev The pending-list ids that are (stale = true) or are not (stale = false) stale unpauses, in
     *      list order
     */
    function _listPending(bool stale) private view returns (bytes32[] memory ids) {
        ids = new bytes32[](_countPending(stale));
        uint256 len = _pendingOperations.length;
        uint256 j = 0;
        for (uint256 i = 0; i < len; ++i) {
            bytes32 id = _pendingOperations[i];
            if (_hasStaleEpoch(id) == stale) ids[j++] = id;
        }
    }

    /**
     * @dev Whether a call unpauses: unpause() on any target, or the timelock's own emergencyUnpauseAll
     */
    function _isUnpauseCall(address target, bytes calldata data) private view returns (bool) {
        bytes4 sel = _selectorOf(data);
        return sel == _SEL_UNPAUSE || (target == address(this) && sel == _SEL_EMERGENCY_UNPAUSE_ALL);
    }

    /**
     * @dev Whether any call of a (length-checked) batch unpauses
     */
    function _containsUnpause(address[] calldata targets, bytes[] calldata payloads) private view returns (bool) {
        for (uint256 i = 0; i < targets.length; ++i) {
            if (_isUnpauseCall(targets[i], payloads[i])) return true;
        }
        return false;
    }

    /**
     * @dev Validate and store the delay configuration (single writer for every delay)
     */
    function _setDelays(uint256 minD, uint256 emD, uint256 longD) private {
        if (
            minD < MIN_ALLOWED_DELAY || minD > MAX_ALLOWED_DELAY || emD < MIN_EMERGENCY_DELAY || emD > minD
                || longD < minD || longD > MAX_LONG_DELAY
        ) {
            revert InvalidDelayConfig(minD, emD, longD);
        }

        emit MinDelayChange(_config.minDelay, minD);

        _config.minDelay = minD;
        _config.emergencyDelay = emD;
        _config.longDelay = longD;

        emit TimelockConfigUpdated(minD, emD, longD);
    }

    /**
     * @dev Function selector of a call (zero for calldata shorter than 4 bytes)
     */
    function _selectorOf(bytes calldata data) internal pure returns (bytes4) {
        return data.length >= 4 ? bytes4(data[:4]) : bytes4(0);
    }

    /**
     * @dev Selectors that always require longDelay and can never be reclassified
     */
    function _isLockedSelector(bytes4 s) internal pure returns (bool) {
        return s == _SEL_TRANSFER_OWNERSHIP || s == _SEL_RENOUNCE_OWNERSHIP || s == _SEL_GRANT_ROLE
            || s == _SEL_REVOKE_ROLE || s == _SEL_RENOUNCE_ROLE || s == _SEL_BEGIN_DEFAULT_ADMIN_TRANSFER
            || s == _SEL_UPGRADE_TO || s == _SEL_UPGRADE_TO_AND_CALL || s == _SEL_UPGRADE_AND_CALL || s == _SEL_UPGRADE
            || s == _SEL_CHANGE_ADMIN || s == _SEL_CHANGE_PROXY_ADMIN || s == _SEL_MULTICALL;
    }

    /**
     * @dev Effective delay class: self-calls and locked selectors are always LongDelay
     */
    function _effectiveClass(address target, bytes4 sel) internal view returns (CallClass) {
        if (target == address(this)) return CallClass.LongDelay;
        if (_isLockedSelector(sel)) return CallClass.LongDelay;
        return _callClass[target][sel];
    }

    /**
     * @dev Proposer-path delay floor for one call (value does not matter)
     */
    function _requiredDelay(address target, bytes calldata data) internal view returns (uint256) {
        return _effectiveClass(target, _selectorOf(data)) == CallClass.LongDelay ? _config.longDelay : _config.minDelay;
    }

    /**
     * @dev Proposer-path delay floor for a batch: the strictest call wins. Checks the array lengths
     *      first (OZ's error), before any element is read.
     */
    function _requiredDelayBatch(address[] calldata targets, uint256[] calldata values, bytes[] calldata payloads)
        internal
        view
        returns (uint256 required)
    {
        if (targets.length != values.length || targets.length != payloads.length) {
            revert TimelockInvalidOperationLength(targets.length, payloads.length, values.length);
        }

        required = _config.minDelay;
        for (uint256 i = 0; i < targets.length; ++i) {
            if (_effectiveClass(targets[i], _selectorOf(payloads[i])) == CallClass.LongDelay) {
                required = _config.longDelay;
                break;
            }
        }
    }

    /**
     * @dev Delay floor implied by an operation label; EmergencyAction is reserved for executeEmergency
     */
    function _labelFloor(OperationType opType) internal view returns (uint256) {
        if (opType == OperationType.EmergencyAction) revert EmergencyActionLabelReserved();
        if (opType == OperationType.ContractUpgrade || opType == OperationType.OwnershipTransfer) {
            return _config.longDelay;
        }
        return _config.minDelay;
    }

    /**
     * @dev max(content requirement, label floor)
     */
    function _withLabelFloor(uint256 required, OperationType opType) internal view returns (uint256) {
        uint256 floor = _labelFloor(opType);
        return required > floor ? required : floor;
    }

    /**
     * @dev Proposer paths may not use salts in the namespace reserved for EMERGENCY_ROLE operations
     */
    function _rejectReservedSalt(bytes32 salt) internal pure {
        if ((salt & _SALT_PREFIX_MASK) == _EMERGENCY_SALT_PREFIX) revert ReservedEmergencySalt(salt);
    }

    /**
     * @dev Record the metadata of a freshly scheduled operation and add it to the pending list. The
     *      record is empty here (never tracked, or cleared by _afterProposerSchedule) and the id is not
     *      in the pending list: OZ only schedules unset ids, and every pending id is removed from the
     *      list when it is executed or cancelled. Callers fill target, value and data.
     * @return op Storage pointer to the record
     */
    function _track(
        bytes32 id,
        OperationType opType,
        bytes32 predecessor,
        bytes32 salt,
        uint256 readyAt,
        string memory description
    ) private returns (GovernanceOperation storage op) {
        op = _operations[id];
        op.id = id;
        op.opType = opType;
        op.predecessor = predecessor;
        op.salt = salt;
        op.scheduledAt = block.timestamp;
        op.readyAt = readyAt;
        op.status = OperationStatus.Pending;
        op.description = description;

        _pendingOperations.push(id);
        _pendingIndex[id] = _pendingOperations.length; // 1-indexed
    }

    /**
     * @dev Mark an operation executed (no-op for operations scheduled through a raw OZ entry point)
     */
    function _markExecuted(bytes32 id, address target) private {
        if (!_removePendingOperation(id)) return;

        GovernanceOperation storage op = _operations[id];
        op.status = OperationStatus.Executed;

        emit OperationExecuted(id, op.opType, target, true);
    }

    /**
     * @dev Mark an operation cancelled (no-op for operations scheduled through a raw OZ entry point)
     */
    function _markCancelled(bytes32 id) private {
        if (!_removePendingOperation(id)) return;

        _operations[id].status = OperationStatus.Cancelled;

        emit OperationCancelled(id, msg.sender);
    }

    /**
     * @dev Remove an operation from the pending list
     * @return removed False if the id was not pending (untracked raw-scheduled operation)
     */
    function _removePendingOperation(bytes32 id) private returns (bool removed) {
        uint256 index = _pendingIndex[id];
        if (index == 0) return false; // Not in list

        uint256 lastIndex = _pendingOperations.length;
        if (index < lastIndex) {
            // Move last element to this position
            bytes32 lastId = _pendingOperations[lastIndex - 1];
            _pendingOperations[index - 1] = lastId;
            _pendingIndex[lastId] = index;
        }

        _pendingOperations.pop();
        delete _pendingIndex[id];
        return true;
    }

    /// @notice Emitted when a contract pause operation completes
    event ContractPauseResult(address indexed target, bool success, bool isPause);

    /**
     * @dev Unpause every registered protocol contract (only reached through a queued operation)
     */
    function _unpauseAll() private {
        if (_protocolContracts.ilrm != address(0)) {
            _unpauseContract(_protocolContracts.ilrm);
        }
        if (_protocolContracts.treasury != address(0)) {
            _unpauseContract(_protocolContracts.treasury);
        }
        if (_protocolContracts.multiPartyILRM != address(0)) {
            _unpauseContract(_protocolContracts.multiPartyILRM);
        }
        if (_protocolContracts.complianceCouncil != address(0)) {
            _unpauseContract(_protocolContracts.complianceCouncil);
        }
        if (_protocolContracts.batchQueue != address(0)) {
            _unpauseContract(_protocolContracts.batchQueue);
        }
        if (_protocolContracts.dummyGenerator != address(0)) {
            _unpauseContract(_protocolContracts.dummyGenerator);
        }

        emit EmergencyActionExecuted(
            keccak256(abi.encodePacked("UNPAUSE_ALL", block.timestamp)), msg.sender, _UNPAUSE_ALL_REASON
        );
    }

    /**
     * @notice Pause a contract
     * @dev FIX: Now emits event with success status for transparency
     */
    function _pauseContract(address target) internal {
        (bool success,) = target.call(abi.encodeWithSignature("pause()"));
        emit ContractPauseResult(target, success, true);
    }

    /**
     * @notice Unpause a contract
     * @dev FIX: Now emits event with success status for transparency
     */
    function _unpauseContract(address target) internal {
        (bool success,) = target.call(abi.encodeWithSignature("unpause()"));
        emit ContractPauseResult(target, success, false);
    }

    /**
     * @notice Get pause status of all registered contracts
     * @dev Allows admins to verify pause state
     * @return ilrmPaused ILRM contract paused state
     * @return treasuryPaused Treasury contract paused state
     * @return multiPartyPaused MultiPartyILRM contract paused state
     * @return councilPaused ComplianceCouncil contract paused state
     */
    function getPauseStatus()
        external
        view
        returns (bool ilrmPaused, bool treasuryPaused, bool multiPartyPaused, bool councilPaused)
    {
        if (_protocolContracts.ilrm != address(0)) {
            try IPausable(_protocolContracts.ilrm).paused() returns (bool p) {
                ilrmPaused = p;
            } catch {}
        }
        if (_protocolContracts.treasury != address(0)) {
            try IPausable(_protocolContracts.treasury).paused() returns (bool p) {
                treasuryPaused = p;
            } catch {}
        }
        if (_protocolContracts.multiPartyILRM != address(0)) {
            try IPausable(_protocolContracts.multiPartyILRM).paused() returns (bool p) {
                multiPartyPaused = p;
            } catch {}
        }
        if (_protocolContracts.complianceCouncil != address(0)) {
            try IPausable(_protocolContracts.complianceCouncil).paused() returns (bool p) {
                councilPaused = p;
            } catch {}
        }
    }

    /**
     * @notice Get pending operation IDs (operations with metadata that can still execute)
     * @dev Leaves out stale unpauses (see getStaleOperations): OZ still reports them pending, but they
     *      can never execute. Matches getPendingOperationsCount.
     * @return ids Array of pending operation IDs
     */
    function getPendingOperations() external view returns (bytes32[] memory) {
        return _listPending(false);
    }

    /**
     * @notice Get the IDs of stale unpause operations with metadata
     * @dev Unpauses queued before the latest emergencyPauseAll: OZ still reports them pending (waiting or
     *      ready), but every execution reverts with StaleUnpause. They stay listed until a canceller
     *      cancels them. Raw-scheduled stale unpauses carry no metadata; check them with isOperationStale.
     * @return ids Array of stale operation IDs
     */
    function getStaleOperations() external view returns (bytes32[] memory) {
        return _listPending(true);
    }

    /**
     * @notice Get contract address by name
     * @param name Contract name
     * @return addr Contract address
     */
    function getContractAddress(string calldata name) external view returns (address addr) {
        return _contractRegistry[name];
    }
}
