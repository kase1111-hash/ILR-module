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
 * - Emergency bypass for critical security issues
 * - Transparent on-chain governance
 *
 * Roles:
 * - PROPOSER_ROLE: Can schedule operations (multi-sig)
 * - EXECUTOR_ROLE: Can execute after delay (open or restricted)
 * - CANCELLER_ROLE: Can cancel pending operations
 * - EMERGENCY_ROLE: Can bypass timelock for security emergencies
 */
interface IGovernanceTimelock {
    // ============ Enums ============

    /// @notice Types of governance operations
    enum OperationType {
        ParameterChange,        // Update protocol parameters
        ContractUpgrade,        // Upgrade proxy implementations
        OwnershipTransfer,      // Transfer contract ownership
        EmergencyAction,        // Security-related actions
        TreasuryOperation,      // Treasury fund movements
        OracleManagement,       // Oracle registration/removal
        ProtocolPause           // Pause/unpause protocol
    }

    /// @notice Status of a governance operation
    enum OperationStatus {
        None,           // Not scheduled
        Pending,        // Scheduled, waiting for delay
        Ready,          // Delay passed, ready to execute
        Executed,       // Successfully executed
        Cancelled       // Cancelled before execution
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
        uint256 minDelay;           // Minimum delay for standard operations
        uint256 emergencyDelay;     // Shorter delay for emergencies
        uint256 longDelay;          // Longer delay for critical changes
        bool openExecutor;          // Whether anyone can execute after delay
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
    event OperationExecuted(
        bytes32 indexed id,
        OperationType indexed opType,
        address indexed target,
        bool success
    );

    /// @notice Emitted when an operation is cancelled
    event OperationCancelled(
        bytes32 indexed id,
        address indexed canceller
    );

    /// @notice Emitted when emergency action is taken
    event EmergencyActionExecuted(
        bytes32 indexed id,
        address indexed executor,
        string reason
    );

    /// @notice Emitted when protocol contract is registered
    event ProtocolContractRegistered(
        string indexed name,
        address indexed contractAddress
    );

    /// @notice Emitted when timelock configuration is updated
    event TimelockConfigUpdated(
        uint256 minDelay,
        uint256 emergencyDelay,
        uint256 longDelay
    );

    /// @notice Emitted when ownership is accepted
    event OwnershipAccepted(
        address indexed contractAddress,
        string contractName
    );

    // ============ Scheduling Functions ============

    /**
     * @notice Schedule a standard governance operation
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
    function executeOperation(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt
    ) external payable;

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
     * @notice Execute emergency action with reduced delay
     * @dev Requires EMERGENCY_ROLE
     * @param target Target contract address
     * @param data Calldata for the operation
     * @param reason Reason for emergency action
     * @return id The emergency operation ID
     */
    function executeEmergency(
        address target,
        bytes calldata data,
        string calldata reason
    ) external returns (bytes32 id);

    /**
     * @notice Emergency pause all protocol contracts
     * @param reason Reason for emergency pause
     */
    function emergencyPauseAll(string calldata reason) external;

    /**
     * @notice Emergency unpause all protocol contracts
     */
    function emergencyUnpauseAll() external;

    // ============ Protocol Management ============

    /**
     * @notice Register a protocol contract for governance
     * @param name Contract name (e.g., "ilrm", "treasury")
     * @param contractAddress Contract address
     */
    function registerProtocolContract(
        string calldata name,
        address contractAddress
    ) external;

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
     * @param id Operation ID
     * @return operation Operation details
     */
    function getOperation(bytes32 id) external view returns (GovernanceOperation memory operation);

    /**
     * @notice Check if operation is pending
     * @param id Operation ID
     * @return isPending True if pending
     */
    function isOperationPending(bytes32 id) external view returns (bool isPending);

    /**
     * @notice Check if operation is ready for execution
     * @param id Operation ID
     * @return isReady True if ready
     */
    function isOperationReady(bytes32 id) external view returns (bool isReady);

    /**
     * @notice Check if operation was executed
     * @param id Operation ID
     * @return isExecuted True if executed
     */
    function isOperationDone(bytes32 id) external view returns (bool isExecuted);

    /**
     * @notice Get timestamp when operation becomes ready
     * @param id Operation ID
     * @return timestamp Ready timestamp (0 if not scheduled)
     */
    function getTimestamp(bytes32 id) external view returns (uint256 timestamp);

    /**
     * @notice Get timelock configuration
     * @return config Timelock configuration
     */
    function getTimelockConfig() external view returns (TimelockConfig memory config);

    /**
     * @notice Get pending operations count
     * @return count Number of pending operations
     */
    function getPendingOperationsCount() external view returns (uint256 count);

    /**
     * @notice Compute operation ID
     * @param target Target address
     * @param value ETH value
     * @param data Calldata
     * @param predecessor Predecessor ID
     * @param salt Salt
     * @return id Computed operation ID
     */
    function hashOperation(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt
    ) external pure returns (bytes32 id);

    // ============ Configuration Functions ============

    /**
     * @notice Update timelock delays
     * @dev Requires going through timelock itself
     * @param minDelay New minimum delay
     * @param emergencyDelay New emergency delay
     * @param longDelay New long delay
     */
    function updateDelays(
        uint256 minDelay,
        uint256 emergencyDelay,
        uint256 longDelay
    ) external;

    /**
     * @notice Set whether executor role is open to anyone
     * @param open True to allow anyone to execute
     */
    function setOpenExecutor(bool open) external;
}
