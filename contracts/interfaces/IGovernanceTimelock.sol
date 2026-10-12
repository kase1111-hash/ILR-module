// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/**
 * @title IGovernanceTimelock
 * @notice Interface for NatLangChain protocol governance with timelock
 * @dev Extends OpenZeppelin TimelockController with protocol-specific features
 *
 * Architecture:
 * - Multi-sig (Gnosis Safe) as proposer
 * - Timelock enforces delay before execution
 * - Short, cancellable emergency path for pre-approved defensive calls
 * - Transparent on-chain governance
 *
 * Roles:
 * - PROPOSER_ROLE: Can schedule operations (multi-sig)
 * - EXECUTOR_ROLE: Can execute after delay (open when granted to address(0)). The role can never lose
 *   its last live holder (any account but the timelock itself, which cannot initiate an execution),
 *   so execution cannot be bricked.
 * - CANCELLER_ROLE: Can cancel pending operations, including the ones EMERGENCY_ROLE queues
 * - EMERGENCY_ROLE: Not a proposer. May pause all registered contracts instantly (emergencyPauseAll),
 *   queue an unpause of all of them at minDelay (emergencyUnpauseAll), and queue Emergency-classified
 *   calls at emergencyDelay (executeEmergency). Nothing it queues runs before its delay, and cancellers
 *   can veto all of it.
 *
 * Pause model (pause instant, unpause delayed):
 * - emergencyPauseAll pauses at once and starts a new pause epoch.
 * - Every unpause goes through the queue: emergencyUnpauseAll (EMERGENCY_ROLE, minDelay), or a proposer
 *   operation calling unpause() on a contract (minDelay or more) or emergencyUnpauseAll on the timelock
 *   (longDelay). unpause() can never be classified Emergency.
 * - An operation that calls unpause() or emergencyUnpauseAll is bound to the pause epoch in which it
 *   was scheduled: once emergencyPauseAll starts a new epoch it can no longer execute (StaleUnpause),
 *   so no unpause queued before the latest emergency pause can undo it.
 * - OZ's state views keep reporting such a stale unpause pending (and ready once its delay passed)
 *   until a canceller cancels it. The governance views report it: isOperationStale, status Stale in
 *   getOperation, left out of getPendingOperations/getPendingOperationsCount (getStaleOperations).
 *
 * Delay policy (the required delay comes from what a call does, not from its label):
 * - LongDelay: any call whose target is the timelock itself, any call whose selector is one of the
 *   locked ownership/role/upgrade/multicall selectors, and any (target, selector) pair governance
 *   classified LongDelay via setCallClass.
 * - Standard: everything else needs minDelay.
 * - Emergency: (target, selector) pairs governance classified Emergency (default-deny). Only
 *   EMERGENCY_ROLE may use emergencyDelay, and only through executeEmergency. On proposer paths an
 *   Emergency-classified call is treated as Standard.
 * - The OperationType label can only lengthen the delay (ContractUpgrade and OwnershipTransfer
 *   floor at longDelay); EmergencyAction is reserved for executeEmergency.
 * - The inherited OZ schedule/scheduleBatch enforce the same content-derived floor.
 */
interface IGovernanceTimelock {
    // ============ Enums ============

    /// @notice Types of governance operations
    enum OperationType {
        ParameterChange, // Update protocol parameters
        ContractUpgrade, // Upgrade proxy implementations
        OwnershipTransfer, // Transfer contract ownership
        EmergencyAction, // Security-related actions
        TreasuryOperation, // Treasury fund movements
        OracleManagement, // Oracle registration/removal
        ProtocolPause // Pause/unpause protocol
    }

    /// @notice Status of a governance operation
    enum OperationStatus {
        None, // Not scheduled
        Pending, // Scheduled, waiting for delay
        Ready, // Delay passed, ready to execute
        Executed, // Successfully executed
        Cancelled, // Cancelled before execution
        Stale // Unpause scheduled before the latest emergencyPauseAll: never executable, cancel it
    }

    /// @notice Delay class of a (target, selector) pair
    enum CallClass {
        Standard, // Needs minDelay (default for unregistered pairs)
        LongDelay, // Needs longDelay on every scheduling path
        Emergency // May be queued by EMERGENCY_ROLE via executeEmergency at emergencyDelay
    }

    // ============ Structs ============

    /// @notice Governance operation details
    struct GovernanceOperation {
        bytes32 id;
        OperationType opType;
        address target;
        uint256 value;
        bytes data;
        bytes32 predecessor;
        bytes32 salt;
        uint256 scheduledAt;
        uint256 readyAt;
        OperationStatus status;
        string description;
    }

    /// @notice Protocol contract registry
    struct ProtocolContracts {
        address ilrm;
        address treasury;
        address oracle;
        address assetRegistry;
        address multiPartyILRM;
        address complianceCouncil;
        address batchQueue;
        address dummyGenerator;
    }

    /// @notice Timelock configuration
    struct TimelockConfig {
        uint256 minDelay; // Minimum delay for standard operations
        uint256 emergencyDelay; // Shorter delay, Emergency-classified calls only
        uint256 longDelay; // Longer delay for critical changes
        bool openExecutor; // Whether anyone can execute after delay (derived from EXECUTOR_ROLE of address(0))
    }

    // ============ Events ============

    /// @notice Emitted when an operation is scheduled
    event OperationScheduled(
        bytes32 indexed id,
        OperationType indexed opType,
        address indexed target,
        uint256 value,
        bytes data,
        uint256 readyAt,
        string description
    );

    /// @notice Emitted when an operation is executed
    event OperationExecuted(bytes32 indexed id, OperationType indexed opType, address indexed target, bool success);

    /// @notice Emitted when an operation is cancelled
    event OperationCancelled(bytes32 indexed id, address indexed canceller);

    /// @notice Emitted when an emergency action takes effect: emergencyPauseAll, or a queued
    ///         emergencyUnpauseAll when it executes. Never emitted for actions that are only queued.
    event EmergencyActionExecuted(bytes32 indexed id, address indexed executor, string reason);

    /**
     * @notice Emitted when EMERGENCY_ROLE queues an operation (executeEmergency or emergencyUnpauseAll)
     * @dev The operation is NOT executed: it becomes executable at readyAt through execute(target, 0,
     *      data, bytes32(0), salt), and CANCELLER_ROLE can cancel it until then.
     */
    event EmergencyActionScheduled(
        bytes32 indexed id,
        address indexed guardian,
        address indexed target,
        bytes32 salt,
        uint256 readyAt,
        string reason
    );

    /// @notice Emitted when protocol contract is registered
    event ProtocolContractRegistered(string indexed name, address indexed contractAddress);

    /// @notice Emitted when timelock configuration is updated
    event TimelockConfigUpdated(uint256 minDelay, uint256 emergencyDelay, uint256 longDelay);

    /// @notice Emitted when ownership is accepted
    event OwnershipAccepted(address indexed contractAddress, string contractName);

    /// @notice Emitted when governance changes the delay class of a (target, selector) pair
    event CallClassUpdated(address indexed target, bytes4 indexed selector, CallClass callClass);

    // ============ Errors ============

    /// @notice The EmergencyAction label is reserved for executeEmergency
    error EmergencyActionLabelReserved();

    /// @notice The salt lies in the namespace reserved for executeEmergency
    error ReservedEmergencySalt(bytes32 salt);

    /// @notice The call is not an Emergency-classified call
    error NotEmergencyCall(address target, bytes4 selector);

    /// @notice Call classes cannot be set for the zero address or the timelock itself
    error InvalidCallClassTarget(address target);

    /// @notice Locked selectors always require longDelay and cannot be reclassified
    error CallClassLocked(bytes4 selector);

    /// @notice The delay configuration violates the delay bounds
    error InvalidDelayConfig(uint256 minDelay, uint256 emergencyDelay, uint256 longDelay);

    /// @notice The (target, selector) pair cannot take this class (unpause() can never be Emergency)
    error InvalidCallClass(address target, bytes4 selector, CallClass callClass);

    /// @notice The unpause operation was scheduled before the latest emergencyPauseAll
    error StaleUnpause(bytes32 id, uint256 scheduledEpoch, uint256 currentEpoch);

    /// @notice Revoking the last live EXECUTOR_ROLE holder (any account but the timelock itself) would
    ///         make every operation unexecutable. Also raised, with the timelock's address, by a
    ///         constructor whose executor list names only the timelock itself.
    error LastExecutor(address account);

    // ============ Scheduling Functions ============

    /**
     * @notice Schedule a standard governance operation
     * @dev The delay is the max of the content requirement (getRequiredDelay) and the label floor
     *      (longDelay for ContractUpgrade/OwnershipTransfer, minDelay otherwise). The EmergencyAction
     *      label is rejected, as are salts in the reserved emergency namespace.
     * @param target Target contract address
     * @param value ETH value to send
     * @param data Calldata for the operation
     * @param predecessor Required predecessor operation (0 for none)
     * @param salt Unique salt for operation ID
     * @param opType Type of operation
     * @param description Human-readable description
     * @return id The scheduled operation ID
     */
    function scheduleOperation(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt,
        OperationType opType,
        string calldata description
    ) external returns (bytes32 id);

    /**
     * @notice Schedule a batch of operations
     * @dev The delay is the max of the strictest call's content requirement and the label floor.
     *      The EmergencyAction label is rejected, as are salts in the reserved emergency namespace.
     * @param targets Target contract addresses
     * @param values ETH values to send
     * @param datas Calldatas for operations
     * @param predecessor Required predecessor operation
     * @param salt Unique salt for operation ID
     * @param opType Type of operation
     * @param description Human-readable description
     * @return id The scheduled batch operation ID
     */
    function scheduleBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata datas,
        bytes32 predecessor,
        bytes32 salt,
        OperationType opType,
        string calldata description
    ) external returns (bytes32 id);

    /**
     * @notice Schedule operation with extended delay (critical changes)
     * @dev Always uses longDelay, which satisfies every content requirement. The EmergencyAction
     *      label is rejected, as are salts in the reserved emergency namespace.
     * @param target Target contract address
     * @param value ETH value to send
     * @param data Calldata for the operation
     * @param predecessor Required predecessor operation
     * @param salt Unique salt for operation ID
     * @param opType Type of operation
     * @param description Human-readable description
     * @return id The scheduled operation ID
     */
    function scheduleLongDelay(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt,
        OperationType opType,
        string calldata description
    ) external returns (bytes32 id);

    // ============ Execution Functions ============

    /**
     * @notice Execute a ready operation
     * @param target Target contract address
     * @param value ETH value to send
     * @param data Calldata for the operation
     * @param predecessor Required predecessor operation
     * @param salt Salt used when scheduling
     */
    function executeOperation(address target, uint256 value, bytes calldata data, bytes32 predecessor, bytes32 salt)
        external
        payable;

    /**
     * @notice Execute a batch of ready operations
     * @param targets Target contract addresses
     * @param values ETH values to send
     * @param datas Calldatas for operations
     * @param predecessor Required predecessor operation
     * @param salt Salt used when scheduling
     */
    function executeBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata datas,
        bytes32 predecessor,
        bytes32 salt
    ) external payable;

    /**
     * @notice Cancel a pending operation
     * @param id Operation ID to cancel
     */
    function cancelOperation(bytes32 id) external;

    // ============ Emergency Functions ============

    /**
     * @notice Queue an emergency action with the reduced emergency delay
     * @dev SCHEDULES (does not execute) a single call at emergencyDelay and emits
     *      EmergencyActionScheduled (not EmergencyActionExecuted). Requires EMERGENCY_ROLE only
     *      (PROPOSER_ROLE is not needed). The call must target a (target, selector) pair governance
     *      classified Emergency; value and predecessor are always 0. The salt is taken from a reserved
     *      namespace plus emergencyNonce; read it back via getOperation(id).salt, the
     *      EmergencyActionScheduled event or OZ's CallSalt event to execute. The operation can be
     *      cancelled by CANCELLER_ROLE like any other. The name is kept for ABI compatibility.
     * @param target Target contract address
     * @param data Calldata for the operation (at least a 4-byte selector)
     * @param reason Reason for emergency action
     * @return id The emergency operation ID
     */
    function executeEmergency(address target, bytes calldata data, string calldata reason) external returns (bytes32 id);

    /**
     * @notice Emergency pause all protocol contracts
     * @dev Instant. Requires EMERGENCY_ROLE. Starts a new pause epoch, which invalidates every unpause
     *      operation scheduled before it (see StaleUnpause).
     * @param reason Reason for emergency pause
     */
    function emergencyPauseAll(string calldata reason) external;

    /**
     * @notice Queue an unpause of all registered protocol contracts
     * @dev Called by an EMERGENCY_ROLE holder, it does NOT unpause: it queues this same call (target =
     *      the timelock, data = its selector) at minDelay with a reserved-namespace salt, bound to the
     *      current pause epoch, and returns the operation id. CANCELLER_ROLE can cancel it; once ready,
     *      an executor runs it through execute(timelock, 0, data, bytes32(0), salt), and that call
     *      (made by the timelock itself) unpauses every registered contract. It reverts with
     *      StaleUnpause if emergencyPauseAll ran after it was queued.
     * @return id The queued operation id (bytes32(0) when the timelock itself performs the unpause)
     */
    function emergencyUnpauseAll() external returns (bytes32 id);

    /**
     * @notice Number of emergencyPauseAll calls so far (the current pause epoch)
     */
    function pauseEpoch() external view returns (uint256);

    // ============ Protocol Management ============

    /**
     * @notice Register a protocol contract for governance
     * @param name Contract name (e.g., "ilrm", "treasury")
     * @param contractAddress Contract address
     */
    function registerProtocolContract(string calldata name, address contractAddress) external;

    /**
     * @notice Accept ownership of a protocol contract
     * @dev For contracts using Ownable2Step
     * @param contractAddress Contract to accept ownership of
     */
    function acceptContractOwnership(address contractAddress) external;

    /**
     * @notice Get all registered protocol contracts
     * @return contracts Protocol contracts struct
     */
    function getProtocolContracts() external view returns (ProtocolContracts memory contracts);

    // ============ View Functions ============

    /**
     * @notice Get operation details
     * @dev Only operations scheduled through scheduleOperation, scheduleBatch (7 arguments),
     *      scheduleLongDelay, executeEmergency and emergencyUnpauseAll carry metadata. Operations
     *      scheduled through the raw OZ schedule/scheduleBatch return an empty record (status None),
     *      even when the same id was tracked by an earlier, cancelled scheduling; use OZ's
     *      getOperationState for them. A non-empty record always describes the id's latest
     *      scheduling: Pending/Ready while OZ reports it pending, Executed once done, Cancelled once
     *      cancelled. An unpause scheduled before the latest emergencyPauseAll reports Stale instead
     *      of Pending/Ready, although OZ still reports it pending (see isOperationStale).
     * @param id Operation ID
     * @return operation Operation details
     */
    function getOperation(bytes32 id) external view returns (GovernanceOperation memory operation);

    /**
     * @notice Whether an operation is a stale unpause
     * @dev True iff OZ reports the id pending (waiting or ready) and it calls unpause() or the timelock's
     *      emergencyUnpauseAll but was scheduled before the latest emergencyPauseAll, so execute reverts
     *      with StaleUnpause. Covers every scheduling path, raw OZ schedules included. Only cancelling
     *      clears it; OZ's isOperationReady is unchanged and reports it ready once its delay passed.
     * @param id Operation ID
     * @return stale Whether the operation is pending but can never execute
     */
    function isOperationStale(bytes32 id) external view returns (bool stale);

    // isOperationPending, isOperationReady, isOperationDone, getTimestamp and hashOperation
    // are inherited from OpenZeppelin's TimelockController, which is the source of truth for
    // operation state. They cannot be redeclared here because OZ v5 makes most of them non-virtual.

    /**
     * @notice Get timelock configuration
     * @return config Timelock configuration
     */
    function getTimelockConfig() external view returns (TimelockConfig memory config);

    /**
     * @notice Get pending operations count
     * @dev Operations with metadata that OZ reports pending and that can still execute: stale unpauses
     *      are not counted
     * @return count Number of pending operations
     */
    function getPendingOperationsCount() external view returns (uint256 count);

    // ============ Configuration Functions ============

    /**
     * @notice Update timelock delays
     * @dev Requires DEFAULT_ADMIN_ROLE (bootstrap admin until renounced; afterwards only the timelock
     *      itself via a long-delay self-operation). Bounds: 1h <= min <= 30d, 15m <= emergency <= min,
     *      min <= long <= 60d. Does not affect already-scheduled operations.
     * @param minDelay New minimum delay
     * @param emergencyDelay New emergency delay
     * @param longDelay New long delay
     */
    function updateDelays(uint256 minDelay, uint256 emergencyDelay, uint256 longDelay) external;

    /**
     * @notice Set whether executor role is open to anyone
     * @dev Grants or revokes EXECUTOR_ROLE for address(0). Closing reverts with LastExecutor unless at
     *      least one explicit executor other than the timelock itself holds EXECUTOR_ROLE (no role
     *      change may leave it without a live holder).
     * @param open True to allow anyone to execute
     */
    function setOpenExecutor(bool open) external;

    // ============ Call Classification ============

    /**
     * @notice Set the delay class of a (target, selector) pair
     * @dev Requires DEFAULT_ADMIN_ROLE. Rejects the zero address, the timelock itself and locked
     *      selectors, and classifying unpause() as Emergency. After the bootstrap admin renounces, only
     *      a (long-delay) self-operation can call it.
     * @param target Target contract address
     * @param selector Function selector
     * @param callClass New delay class
     */
    function setCallClass(address target, bytes4 selector, CallClass callClass) external;

    /**
     * @notice Get the effective delay class of a (target, selector) pair
     * @dev Calls to the timelock itself and locked selectors always report LongDelay
     * @param target Target contract address
     * @param selector Function selector
     * @return callClass Effective delay class
     */
    function getCallClass(address target, bytes4 selector) external view returns (CallClass callClass);

    /**
     * @notice Get the minimum delay a proposer must use to schedule one call
     * @param target Target contract address
     * @param data Calldata of the call
     * @return delay longDelay for LongDelay calls, minDelay otherwise
     */
    function getRequiredDelay(address target, bytes calldata data) external view returns (uint256 delay);
}
