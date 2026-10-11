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
 * Emergency path:
 * - Only EMERGENCY_ROLE, through executeEmergency, can use emergencyDelay. It works only for single,
 *   zero-value calls whose (target, selector) governance classified Emergency (default-deny).
 * - The call is queued in the normal OZ queue with a salt from a reserved namespace plus a nonce, so
 *   cancellers can still veto it during the emergency delay.
 *
 * Invariants:
 * - OZ's operation-state views (getTimestamp, isOperation*, getOperationState, hashOperation*) are not
 *   overridden; executed operations are marked done and cannot be replayed.
 * - _config is the single source of delay configuration; getMinDelay() reads it.
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

    /// @dev Salt namespace reserved for executeEmergency
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

    // ============ State Variables ============

    /// @notice Timelock configuration (single source of delay configuration)
    TimelockConfig private _config;

    /// @notice Protocol contract registry
    ProtocolContracts private _protocolContracts;

    /// @notice Contract name to address mapping
    mapping(string => address) private _contractRegistry;

    /// @notice Operation metadata
    mapping(bytes32 => GovernanceOperation) private _operations;

    /// @notice List of pending operation IDs
    bytes32[] private _pendingOperations;

    /// @notice Index of operation in pending array
    mapping(bytes32 => uint256) private _pendingIndex;

    /// @notice Registered delay class per (target, selector)
    mapping(address => mapping(bytes4 => CallClass)) private _callClass;

    /// @notice Number of emergency operations queued so far (low bits of the emergency salt)
    uint256 public emergencyNonce;

    /// @dev True only inside executeEmergency while it calls TimelockController.schedule
    bool private _emergencyScheduling;

    // ============ Constructor ============

    /**
     * @param minDelay Minimum delay for standard operations (e.g., 2 days)
     * @param proposers Addresses with proposer role (multi-sig)
     * @param executors Addresses with executor role (or empty for open execution)
     * @param admin Admin address for initial setup (should renounce later). It is NOT granted
     *        EMERGENCY_ROLE; grant that role explicitly.
     */
    constructor(uint256 minDelay, address[] memory proposers, address[] memory executors, address admin)
        TimelockController(minDelay, proposers, executors, admin)
    {
        require(minDelay >= MIN_ALLOWED_DELAY, "Delay too short");
        require(minDelay <= MAX_ALLOWED_DELAY, "Delay too long");

        // Defaults always satisfy the delay bounds: 15m <= min/4 <= min <= 2*min <= 60d
        _config = TimelockConfig({
            minDelay: minDelay,
            emergencyDelay: minDelay / 4, // 25% of normal delay
            longDelay: minDelay * 2, // 200% of normal delay
            openExecutor: executors.length == 0
        });

        // An empty executor list means anyone may execute after the delay
        if (executors.length == 0) {
            _grantRole(EXECUTOR_ROLE, address(0));
        }
    }

    // ============ OZ Scheduling Entry Points (policy checkpoint) ============

    /**
     * @notice Schedule a single call (OZ entry point)
     * @dev Enforces the content-derived delay floor and rejects the reserved emergency salt namespace.
     *      Records no governance metadata.
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
    }

    /**
     * @notice Schedule a batch of calls (OZ entry point)
     * @dev Enforces the strictest call's content-derived delay floor and rejects the reserved emergency
     *      salt namespace. Records no governance metadata.
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
        id = hashOperation(target, value, data, predecessor, salt);

        // The label can only lengthen the content-derived delay
        uint256 delay = _withLabelFloor(_requiredDelay(target, data), opType);

        // Schedule via the policy checkpoint
        schedule(target, value, data, predecessor, salt, delay);

        // Store metadata
        _storeOperationMetadata(id, opType, target, value, data, predecessor, salt, delay, description);

        emit OperationScheduled(id, opType, target, value, data, block.timestamp + delay, description);
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
        id = hashOperationBatch(targets, values, datas, predecessor, salt);

        uint256 delay = _withLabelFloor(_requiredDelayBatch(targets, values, datas), opType);

        // Schedule batch via the policy checkpoint
        scheduleBatch(targets, values, datas, predecessor, salt, delay);

        // Store metadata (use first call for simplicity). Built in memory to stay within stack limits.
        GovernanceOperation memory op;
        op.id = id;
        op.opType = opType;
        if (targets.length > 0) op.target = targets[0];
        if (values.length > 0) op.value = values[0];
        if (datas.length > 0) op.data = datas[0];
        op.predecessor = predecessor;
        op.salt = salt;
        op.scheduledAt = block.timestamp;
        op.readyAt = block.timestamp + delay;
        op.status = OperationStatus.Pending;
        op.description = description;
        _storeOperation(op);

        emit OperationScheduled(id, op.opType, op.target, op.value, op.data, op.readyAt, op.description);
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

        id = hashOperation(target, value, data, predecessor, salt);

        // longDelay satisfies every content requirement
        uint256 delay = _config.longDelay;

        schedule(target, value, data, predecessor, salt, delay);

        _storeOperationMetadata(id, opType, target, value, data, predecessor, salt, delay, description);

        emit OperationScheduled(id, opType, target, value, data, block.timestamp + delay, description);
    }

    // ============ Execution Functions ============

    /**
     * @notice Execute a ready single-call operation (OZ entry point)
     * @dev Keeps governance metadata in sync with OZ state
     */
    function execute(address target, uint256 value, bytes calldata payload, bytes32 predecessor, bytes32 salt)
        public
        payable
        override
    {
        super.execute(target, value, payload, predecessor, salt);
        _markExecuted(hashOperation(target, value, payload, predecessor, salt), target);
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
        // Execute batch via parent (enforces EXECUTOR_ROLE and readiness)
        super.executeBatch(targets, values, datas, predecessor, salt);

        _markExecuted(
            hashOperationBatch(targets, values, datas, predecessor, salt), targets.length > 0 ? targets[0] : address(0)
        );
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
        bytes32 salt;
        uint256 readyAt;
        (id, salt, readyAt) = _scheduleEmergency(target, data);

        GovernanceOperation memory op;
        op.id = id;
        op.opType = OperationType.EmergencyAction;
        op.target = target;
        op.data = data;
        op.salt = salt;
        op.scheduledAt = block.timestamp;
        op.readyAt = readyAt;
        op.status = OperationStatus.Pending;
        op.description = reason;
        _storeOperation(op);

        emit OperationScheduled(id, OperationType.EmergencyAction, target, 0, data, readyAt, reason);
        // Legacy event, kept for compatibility. The operation is queued, not executed.
        emit EmergencyActionExecuted(id, msg.sender, reason);
    }

    /// @inheritdoc IGovernanceTimelock
    function emergencyPauseAll(string calldata reason) external override onlyRole(EMERGENCY_ROLE) {
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
    function emergencyUnpauseAll() external override onlyRole(EMERGENCY_ROLE) {
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
            keccak256(abi.encodePacked("UNPAUSE_ALL", block.timestamp)), msg.sender, "Emergency unpause all"
        );
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
        // Overlay OZ readiness: metadata stores Pending, OZ knows when the delay has passed
        if (op.status == OperationStatus.Pending && isOperationReady(id)) {
            op.status = OperationStatus.Ready;
        }
    }

    /// @inheritdoc IGovernanceTimelock
    function getTimelockConfig() external view override returns (TimelockConfig memory config) {
        config = _config;
        config.openExecutor = hasRole(EXECUTOR_ROLE, address(0));
    }

    /// @inheritdoc IGovernanceTimelock
    function getPendingOperationsCount() external view override returns (uint256) {
        return _pendingOperations.length;
    }

    /**
     * @notice Minimum delay for operations
     * @dev Reads _config (the single source of delay configuration). Inside the executeEmergency frame
     *      it returns emergencyDelay so TimelockController accepts the emergency delay.
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
        _config.openExecutor = open;

        if (open) {
            // Grant executor role to zero address (anyone)
            _grantRole(EXECUTOR_ROLE, address(0));
        } else {
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

        _callClass[target][selector] = callClass;

        emit CallClassUpdated(target, selector, callClass);
    }

    // ============ Internal Functions ============

    /**
     * @dev Inside the executeEmergency frame, TimelockController.schedule's PROPOSER_ROLE check is
     *      satisfied by EMERGENCY_ROLE instead. Outside that frame PROPOSER_ROLE is never substituted.
     */
    function _checkRole(bytes32 role) internal view override {
        if (_emergencyScheduling && role == PROPOSER_ROLE) {
            role = EMERGENCY_ROLE;
        }
        super._checkRole(role);
    }

    /**
     * @dev Queue an Emergency-classified call at emergencyDelay through TimelockController.schedule
     * @return id Operation ID
     * @return salt Salt from the reserved emergency namespace
     * @return readyAt Timestamp at which the operation becomes executable
     */
    function _scheduleEmergency(address target, bytes calldata data)
        private
        returns (bytes32 id, bytes32 salt, uint256 readyAt)
    {
        bytes4 sel = _selectorOf(data);
        if (data.length < 4 || _effectiveClass(target, sel) != CallClass.Emergency) {
            revert NotEmergencyCall(target, sel);
        }

        salt = _EMERGENCY_SALT_PREFIX | bytes32(++emergencyNonce);
        uint256 delay = _config.emergencyDelay;
        id = hashOperation(target, 0, data, bytes32(0), salt);

        // No external call happens while the flag is set
        _emergencyScheduling = true;
        super.schedule(target, 0, data, bytes32(0), salt, delay);
        _emergencyScheduling = false;

        readyAt = block.timestamp + delay;
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
     * @dev Proposer-path delay floor for a batch: the strictest call wins
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
     * @dev Proposer paths may not use salts in the namespace reserved for executeEmergency
     */
    function _rejectReservedSalt(bytes32 salt) internal pure {
        if ((salt & _SALT_PREFIX_MASK) == _EMERGENCY_SALT_PREFIX) revert ReservedEmergencySalt(salt);
    }

    /**
     * @dev Mark an operation executed (no-op for raw-scheduled operations without metadata)
     */
    function _markExecuted(bytes32 id, address target) private {
        GovernanceOperation storage op = _operations[id];
        if (op.scheduledAt == 0) return;

        op.status = OperationStatus.Executed;
        _removePendingOperation(id);

        emit OperationExecuted(id, op.opType, target, true);
    }

    /**
     * @dev Mark an operation cancelled (no-op for raw-scheduled operations without metadata)
     */
    function _markCancelled(bytes32 id) private {
        GovernanceOperation storage op = _operations[id];
        if (op.scheduledAt == 0) return;

        op.status = OperationStatus.Cancelled;
        _removePendingOperation(id);

        emit OperationCancelled(id, msg.sender);
    }

    /**
     * @notice Store operation metadata
     */
    function _storeOperationMetadata(
        bytes32 id,
        OperationType opType,
        address target,
        uint256 value,
        bytes memory data,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay,
        string memory description
    ) internal {
        _storeOperation(
            GovernanceOperation({
                id: id,
                opType: opType,
                target: target,
                value: value,
                data: data,
                predecessor: predecessor,
                salt: salt,
                scheduledAt: block.timestamp,
                readyAt: block.timestamp + delay,
                status: OperationStatus.Pending,
                description: description
            })
        );
    }

    /**
     * @notice Store operation metadata and track it as pending
     */
    function _storeOperation(GovernanceOperation memory op) internal {
        _operations[op.id] = op;

        // Re-scheduling a cancelled id must not create a duplicate pending entry
        if (_pendingIndex[op.id] == 0) {
            _pendingOperations.push(op.id);
            _pendingIndex[op.id] = _pendingOperations.length; // 1-indexed
        }
    }

    /**
     * @notice Remove operation from pending list
     */
    function _removePendingOperation(bytes32 id) internal {
        uint256 index = _pendingIndex[id];
        if (index == 0) return; // Not in list

        uint256 lastIndex = _pendingOperations.length;
        if (index < lastIndex) {
            // Move last element to this position
            bytes32 lastId = _pendingOperations[lastIndex - 1];
            _pendingOperations[index - 1] = lastId;
            _pendingIndex[lastId] = index;
        }

        _pendingOperations.pop();
        delete _pendingIndex[id];
    }

    /// @notice Emitted when a contract pause operation completes
    event ContractPauseResult(address indexed target, bool success, bool isPause);

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
     * @notice Get pending operation IDs
     * @return ids Array of pending operation IDs
     */
    function getPendingOperations() external view returns (bytes32[] memory) {
        return _pendingOperations;
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
