// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/**
 * @title IDummyTransactionGenerator
 * @notice Interface for privacy-preserving dummy transaction generation
 * @dev Generates "noop" transactions at random intervals to obscure real patterns
 *
 * Privacy Model:
 * - Injects dummy transactions that look identical to real transactions
 * - Random intervals prevent timing correlation
 * - Treasury-funded to avoid user cost
 * - Dedicated dummy addresses prevent inflation of real metrics
 *
 * Chainlink Integration:
 * - Uses Chainlink VRF for verifiable randomness
 * - Chainlink Automation for scheduled execution
 * - Configurable probability thresholds
 *
 * Safety:
 * - Dummy addresses are marked to exclude from analytics
 * - Doesn't inflate harassment scores or entropy metrics
 * - Bounded treasury spending per period
 */
interface IDummyTransactionGenerator {
    // ============ Enums ============

    /// @notice Types of dummy transactions that can be generated
    enum DummyTxType {
        VoluntaryRequest,     // Empty voluntary reconciliation request
        BatchQueueEntry,      // Dummy entry in batch queue
        ViewingKeyCommit,     // Dummy viewing key commitment
        ZKProofSubmit,        // Dummy ZK proof submission
        StakeDeposit          // Dummy stake (immediately refunded)
    }

    // ============ Structs ============

    /// @notice Configuration for dummy generation
    struct GeneratorConfig {
        uint256 minInterval;          // Minimum time between generations (seconds)
        uint256 maxInterval;          // Maximum time between generations (seconds)
        uint256 probabilityBps;       // Probability per check in basis points (e.g., 5000 = 50%)
        uint256 maxPerPeriod;         // Maximum dummy txs per period
        uint256 periodDuration;       // Period duration in seconds
        uint256 maxTreasurySpend;     // Maximum treasury spend per period
        bool enabled;                 // Whether generation is enabled
    }

    /// @notice Statistics for dummy generation
    struct GeneratorStats {
        uint256 totalGenerated;       // Total dummy txs ever generated
        uint256 periodGenerated;      // Dummy txs in current period
        uint256 periodSpent;          // Treasury spent in current period
        uint256 lastGenerationTime;   // Last generation timestamp
        uint256 periodStartTime;      // Current period start
        uint256 consecutiveSkips;     // Consecutive probability misses
    }

    /// @notice A registered dummy address
    struct DummyAddress {
        address addr;
        bool isActive;
        uint256 registeredAt;
        uint256 txCount;
    }

    // ============ Events ============

    /// @notice Emitted when a dummy transaction is generated
    event DummyTransactionGenerated(
        uint256 indexed txIndex,
        DummyTxType txType,
        address indexed dummyAddress,
        bytes32 dataHash
    );

    /// @notice Emitted when generation is triggered but skipped (probability)
    event GenerationSkipped(
        uint256 randomValue,
        uint256 threshold
    );

    /// @notice Emitted when a dummy address is registered
    event DummyAddressRegistered(
        address indexed dummyAddress,
        uint256 index
    );

    /// @notice Emitted when a dummy address is deactivated
    event DummyAddressDeactivated(
        address indexed dummyAddress
    );

    /// @notice Emitted when configuration is updated
    event ConfigUpdated(
        uint256 minInterval,
        uint256 maxInterval,
        uint256 probabilityBps
    );

    /// @notice Emitted when treasury funds are deposited
    event TreasuryFunded(
        address indexed funder,
        uint256 amount
    );

    /// @notice Emitted when a new period starts
    event PeriodReset(
        uint256 periodStart,
        uint256 previousGenerated,
        uint256 previousSpent
    );

    // ============ Generation Functions ============

    /**
     * @notice Attempt to generate a dummy transaction
     * @dev Uses randomness to determine if generation should occur
     * @return generated True if a dummy tx was generated
     * @return txType The type of dummy tx generated (if any)
     */
    function tryGenerate() external returns (bool generated, DummyTxType txType);

    /**
     * @notice Force generate a specific dummy tx type
     * @dev Only callable by owner/automation
     * @param txType The type of dummy tx to generate
     * @return success True if generation succeeded
     */
    function forceGenerate(DummyTxType txType) external returns (bool success);

    /**
     * @notice Generate multiple dummy transactions
     * @dev Useful for batch generation during low-activity periods
     * @param count Number of dummy txs to generate
     * @return generated Actual number generated
     */
    function generateBatch(uint256 count) external returns (uint256 generated);

    // ============ Chainlink Functions ============

    /**
     * @notice Chainlink Automation check function
     * @return upkeepNeeded True if generation should be attempted
     * @return performData Encoded generation parameters
     */
    function checkUpkeep(bytes calldata) external view returns (
        bool upkeepNeeded,
        bytes memory performData
    );

    /**
     * @notice Chainlink Automation perform function
     * @param performData Data from checkUpkeep
     */
    function performUpkeep(bytes calldata performData) external;

    /**
     * @notice Request randomness from Chainlink VRF
     * @return requestId The VRF request ID
     */
    function requestRandomness() external returns (uint256 requestId);

    // ============ Address Management ============

    /**
     * @notice Register a new dummy address
     * @param dummyAddr The address to register
     */
    function registerDummyAddress(address dummyAddr) external;

    /**
     * @notice Deactivate a dummy address
     * @param dummyAddr The address to deactivate
     */
    function deactivateDummyAddress(address dummyAddr) external;

    /**
     * @notice Check if an address is a registered dummy
     * @param addr The address to check
     * @return isDummy True if address is a dummy
     */
    function isDummyAddress(address addr) external view returns (bool isDummy);

    /**
     * @notice Get all active dummy addresses
     * @return addresses Array of active dummy addresses
     */
    function getActiveDummyAddresses() external view returns (address[] memory addresses);

    // ============ Treasury Functions ============

    /**
     * @notice Fund the dummy transaction treasury
     */
    function fundTreasury() external payable;

    /**
     * @notice Get current treasury balance
     * @return balance Treasury ETH balance
     */
    function getTreasuryBalance() external view returns (uint256 balance);

    /**
     * @notice Withdraw excess treasury funds
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function withdrawTreasury(address to, uint256 amount) external;

    // ============ View Functions ============

    /**
     * @notice Get current configuration
     * @return config The generator configuration
     */
    function getConfig() external view returns (GeneratorConfig memory config);

    /**
     * @notice Get current statistics
     * @return stats The generator statistics
     */
    function getStats() external view returns (GeneratorStats memory stats);

    /**
     * @notice Get time until next possible generation
     * @return timeRemaining Seconds until next generation allowed
     */
    function getTimeToNextGeneration() external view returns (uint256 timeRemaining);

    /**
     * @notice Check if generation is currently possible
     * @return canGenerate True if generation can occur
     * @return reason Reason if cannot generate
     */
    function canGenerate() external view returns (bool canGenerate, string memory reason);

    /**
     * @notice Get dummy address info
     * @param addr The address to query
     * @return info The dummy address info
     */
    function getDummyAddressInfo(address addr) external view returns (DummyAddress memory info);

    // ============ Admin Functions ============

    /**
     * @notice Update generator configuration
     * @param config New configuration
     */
    function updateConfig(GeneratorConfig calldata config) external;

    /**
     * @notice Enable or disable the generator
     * @param enabled Whether to enable
     */
    function setEnabled(bool enabled) external;

    /**
     * @notice Set the target contracts (ILRM, BatchQueue, etc.)
     * @param ilrm ILRM contract address
     * @param batchQueue BatchQueue contract address
     */
    function setTargetContracts(address ilrm, address batchQueue) external;
}
