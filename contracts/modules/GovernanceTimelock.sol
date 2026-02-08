// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/governance/TimelockController.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
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
 * 1. Multi-sig proposes operation (scheduleOperation)
 * 2. Timelock delay passes (minDelay, longDelay, or emergencyDelay)
 * 3. Executor executes operation (executeOperation)
 * 4. Protocol state is updated
 *
 * Security Features:
 * - Multi-sig required for proposals (PROPOSER_ROLE)
 * - Configurable delays for different operation types
 * - Emergency bypass with reduced delay for security issues
 * - All operations are transparent and auditable on-chain
 * - Cancellation possible before execution
 *
 * Decentralization:
 * - No single point of failure
 * - Time for community review before execution
 * - Emergency procedures for security incidents
 */
contract GovernanceTimelock is TimelockController, IGovernanceTimelock {
    // ============ Constants ============

    /// @notice Role for emergency actions
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    /// @notice Minimum allowed delay (1 hour)
    uint256 public constant MIN_ALLOWED_DELAY = 1 hours;

    /// @notice Maximum allowed delay (30 days)
    uint256 public constant MAX_ALLOWED_DELAY = 30 days;

    // ============ State Variables ============

    /// @notice Timelock configuration
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

    // ============ Constructor ============

    /**
     * @param minDelay Minimum delay for standard operations (e.g., 2 days)
     * @param proposers Addresses with proposer role (multi-sig)
     * @param executors Addresses with executor role (or empty for open)
     * @param admin Admin address for initial setup (should renounce later)
     */
    constructor(
        uint256 minDelay,
        address[] memory proposers,
        address[] memory executors,
        address admin
    ) TimelockController(minDelay, proposers, executors, admin) {
        require(minDelay >= MIN_ALLOWED_DELAY, "Delay too short");
        require(minDelay <= MAX_ALLOWED_DELAY, "Delay too long");

        _config = TimelockConfig({
            minDelay: minDelay,
            emergencyDelay: minDelay / 4,  // 25% of normal delay
            longDelay: minDelay * 2,       // 200% of normal delay
            openExecutor: executors.length == 0
        });

        // Grant emergency role to admin initially
        _grantRole(EMERGENCY_ROLE, admin);
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

        // Use appropriate delay based on operation type
        uint256 delay = _getDelayForType(opType);

        // Schedule via parent
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

        uint256 delay = _getDelayForType(opType);

        // Schedule batch via parent
        scheduleBatch(targets, values, datas, predecessor, salt, delay);

        // Store metadata (use first target for simplicity)
        _storeOperationMetadata(
            id,
            opType,
            targets.length > 0 ? targets[0] : address(0),
            values.length > 0 ? values[0] : 0,
            datas.length > 0 ? datas[0] : "",
            predecessor,
            salt,
            delay,
            description
        );

        emit OperationScheduled(
            id,
            opType,
            targets.length > 0 ? targets[0] : address(0),
            values.length > 0 ? values[0] : 0,
            datas.length > 0 ? datas[0] : "",
            block.timestamp + delay,
            description
        );
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
        id = hashOperation(target, value, data, predecessor, salt);

        // Use long delay
        uint256 delay = _config.longDelay;

        schedule(target, value, data, predecessor, salt, delay);

        _storeOperationMetadata(id, opType, target, value, data, predecessor, salt, delay, description);

        emit OperationScheduled(id, opType, target, value, data, block.timestamp + delay, description);
    }

    // ============ Execution Functions ============

    /// @inheritdoc IGovernanceTimelock
    function executeOperation(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt
    ) external payable override {
        bytes32 id = hashOperation(target, value, data, predecessor, salt);

        // Execute via parent
        execute(target, value, data, predecessor, salt);

        // Update metadata
        _operations[id].status = OperationStatus.Executed;
        _removePendingOperation(id);

        emit OperationExecuted(id, _operations[id].opType, target, true);
    }

    /// @inheritdoc IGovernanceTimelock
    function executeBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata datas,
        bytes32 predecessor,
        bytes32 salt
    ) external payable override {
        bytes32 id = hashOperationBatch(targets, values, datas, predecessor, salt);

        // Execute batch via parent
        executeBatch(targets, values, datas, predecessor, salt);

        // Update metadata
        _operations[id].status = OperationStatus.Executed;
        _removePendingOperation(id);

        emit OperationExecuted(
            id,
            _operations[id].opType,
            targets.length > 0 ? targets[0] : address(0),
            true
        );
    }

    /// @inheritdoc IGovernanceTimelock
    function cancelOperation(bytes32 id) external override onlyRole(CANCELLER_ROLE) {
        cancel(id);

        _operations[id].status = OperationStatus.Cancelled;
        _removePendingOperation(id);

        emit OperationCancelled(id, msg.sender);
    }

    // ============ Emergency Functions ============

    /// @inheritdoc IGovernanceTimelock
    function executeEmergency(
        address target,
        bytes calldata data,
        string calldata reason
    ) external override onlyRole(EMERGENCY_ROLE) returns (bytes32 id) {
        bytes32 salt = keccak256(abi.encodePacked(block.timestamp, reason));
        id = hashOperation(target, 0, data, bytes32(0), salt);

        // Schedule with emergency delay
        schedule(target, 0, data, bytes32(0), salt, _config.emergencyDelay);

        _storeOperationMetadata(
            id,
            OperationType.EmergencyAction,
            target,
            0,
            data,
            bytes32(0),
            salt,
            _config.emergencyDelay,
            reason
        );

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

        emit EmergencyActionExecuted(
            keccak256(abi.encodePacked("PAUSE_ALL", block.timestamp)),
            msg.sender,
            reason
        );
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
            keccak256(abi.encodePacked("UNPAUSE_ALL", block.timestamp)),
            msg.sender,
            "Emergency unpause all"
        );
    }

    // ============ Protocol Management ============

    /// @inheritdoc IGovernanceTimelock
    function registerProtocolContract(
        string calldata name,
        address contractAddress
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) {
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
        (bool success,) = contractAddress.call(
            abi.encodeWithSignature("acceptOwnership()")
        );
        require(success, "Accept ownership failed");

        emit OwnershipAccepted(contractAddress, "");
    }

    /// @inheritdoc IGovernanceTimelock
    function getProtocolContracts() external view override returns (ProtocolContracts memory) {
        return _protocolContracts;
    }

    // ============ View Functions ============

    /// @inheritdoc IGovernanceTimelock
    function getOperation(bytes32 id) external view override returns (GovernanceOperation memory) {
        return _operations[id];
    }

    /// @inheritdoc IGovernanceTimelock
    function isOperationPending(bytes32 id) external view override returns (bool) {
        return _operations[id].status == OperationStatus.Pending;
    }

    /// @inheritdoc IGovernanceTimelock
    function isOperationReady(bytes32 id) public view override(TimelockController, IGovernanceTimelock) returns (bool) {
        return TimelockController.isOperationReady(id);
    }

    /// @inheritdoc IGovernanceTimelock
    function isOperationDone(bytes32 id) external view override returns (bool) {
        return _operations[id].status == OperationStatus.Executed;
    }

    /// @inheritdoc IGovernanceTimelock
    function getTimestamp(bytes32 id) external view override returns (uint256) {
        return _operations[id].readyAt;
    }

    /// @inheritdoc IGovernanceTimelock
    function getTimelockConfig() external view override returns (TimelockConfig memory) {
        return _config;
    }

    /// @inheritdoc IGovernanceTimelock
    function getPendingOperationsCount() external view override returns (uint256) {
        return _pendingOperations.length;
    }

    /// @inheritdoc IGovernanceTimelock
    function hashOperation(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt
    ) public pure override returns (bytes32) {
        return keccak256(abi.encode(target, value, data, predecessor, salt));
    }

    // ============ Configuration Functions ============

    /// @inheritdoc IGovernanceTimelock
    function updateDelays(
        uint256 minDelay,
        uint256 emergencyDelay,
        uint256 longDelay
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(minDelay >= MIN_ALLOWED_DELAY, "Min delay too short");
        require(minDelay <= MAX_ALLOWED_DELAY, "Min delay too long");
        require(emergencyDelay <= minDelay, "Emergency delay > min delay");
        require(longDelay >= minDelay, "Long delay < min delay");

        _config.minDelay = minDelay;
        _config.emergencyDelay = emergencyDelay;
        _config.longDelay = longDelay;

        // Update parent's min delay
        updateDelay(minDelay);

        emit TimelockConfigUpdated(minDelay, emergencyDelay, longDelay);
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

    // ============ Internal Functions ============

    /**
     * @notice Get appropriate delay for operation type
     */
    function _getDelayForType(OperationType opType) internal view returns (uint256) {
        if (opType == OperationType.EmergencyAction) {
            return _config.emergencyDelay;
        }
        if (opType == OperationType.ContractUpgrade || opType == OperationType.OwnershipTransfer) {
            return _config.longDelay;
        }
        return _config.minDelay;
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
        _operations[id] = GovernanceOperation({
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
        });

        _pendingOperations.push(id);
        _pendingIndex[id] = _pendingOperations.length; // 1-indexed
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
    function getPauseStatus() external view returns (
        bool ilrmPaused,
        bool treasuryPaused,
        bool multiPartyPaused,
        bool councilPaused
    ) {
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
