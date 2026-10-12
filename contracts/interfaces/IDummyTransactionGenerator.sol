// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/**
 * @title IDummyTransactionGenerator
 * @notice Interface for dummy transaction generation (noise in transaction counts and timing)
 * @dev Generates treasury-funded "noop" transactions at pseudo-random times.
 *
 * Privacy Model (limits):
 * - Dummies are attributable, NOT indistinguishable on-chain: this contract is msg.sender of every
 *   dummy call (ILRM logs it as the voluntary-request initiator, BatchQueue as the submitter), it emits
 *   DummyTransactionGenerated for each one, and isDummyAddress is public. Dummies add noise only for
 *   observers that see aggregate counts or timing and do not trace call frames or logs.
 * - Randomness is block-derived and NOT unpredictable (no VRF). It only paces generation and picks the
 *   dummy type and address; no safety property depends on it (see Safety).
 *
 * Automation:
 * - Chainlink Automation compatible (checkUpkeep / performUpkeep); generation is keeper- or owner-only
 *
 * Safety:
 * - Only the keeper or owner can trigger generation, at most one attempt (generated, skipped or failed)
 *   per minInterval: a failing target call or the caller's gas limit cannot undo a drawn attempt
 * - Hard per-period caps (count and treasury spend, including the cost of the dummy being generated)
 *   bound the spend on every generation path, whatever the randomness
 * - Generation only ever sends ETH to the owner-set, code-checked ILRM (the constant voluntary-request
 *   fee); the only other outflow is the owner's withdrawTreasury
 * - Dummy addresses are labeled so off-chain analytics can exclude them
 */
interface IDummyTransactionGenerator {
    // ============ Enums ============

    /// @notice Types of dummy transactions that can be generated
    enum DummyTxType {
        VoluntaryRequest, // Empty voluntary reconciliation request
        BatchQueueEntry, // Dummy entry in batch queue
        ViewingKeyCommit, // Dummy viewing key commitment
        ZKProofSubmit, // Dummy ZK proof submission
        StakeDeposit // Dummy stake (immediately refunded)
    }

    // ============ Structs ============

    /// @notice Configuration for dummy generation
    struct GeneratorConfig {
        uint256 minInterval; // Minimum time between generations (seconds)
        uint256 maxInterval; // Maximum time between generations (seconds)
        uint256 probabilityBps; // Probability per check in basis points (e.g., 5000 = 50%)
        uint256 maxPerPeriod; // Maximum dummy txs per period
        uint256 periodDuration; // Period duration in seconds
        uint256 maxTreasurySpend; // Maximum treasury spend per period
        bool enabled; // Whether generation is enabled
    }

    /// @notice Statistics for dummy generation
    struct GeneratorStats {
        uint256 totalGenerated; // Total dummy txs ever generated
        uint256 periodGenerated; // Dummy txs in current period
        uint256 periodSpent; // Treasury spent in current period
        uint256 lastGenerationTime; // Last generation timestamp
        uint256 periodStartTime; // Current period start
        uint256 consecutiveSkips; // Consecutive probability misses
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
        uint256 indexed txIndex, DummyTxType txType, address indexed dummyAddress, bytes32 dataHash
    );

    /// @notice Emitted when generation is triggered but skipped (probability)
    event GenerationSkipped(uint256 randomValue, uint256 threshold);

    /// @notice Emitted when an attempt passed the probability gate but its generation failed (the target
    ///         call reverted or ran out of gas). The generation is rolled back; the attempt stays consumed.
    event GenerationFailed(DummyTxType txType);

    /// @notice Emitted when a dummy address is registered
    event DummyAddressRegistered(address indexed dummyAddress, uint256 index);

    /// @notice Emitted when a dummy address is deactivated
    event DummyAddressDeactivated(address indexed dummyAddress);

    /// @notice Emitted when configuration is updated
    event ConfigUpdated(uint256 minInterval, uint256 maxInterval, uint256 probabilityBps);

    /// @notice Emitted when treasury funds are deposited
    event TreasuryFunded(address indexed funder, uint256 amount);

    /// @notice Emitted when a new period starts
    event PeriodReset(uint256 periodStart, uint256 previousGenerated, uint256 previousSpent);

    /// @notice Emitted when the keeper allowed to trigger generation changes
    event KeeperUpdated(address indexed previousKeeper, address indexed newKeeper);

    /// @notice Emitted when the target contracts change
    event TargetContractsUpdated(address indexed ilrm, address indexed batchQueue);

    /// @notice Emitted when treasury funds are withdrawn
    event TreasuryWithdrawn(address indexed to, uint256 amount);

    // ============ Generation Functions ============

    /**
     * @notice Attempt to generate a dummy transaction
     * @dev Keeper or owner only; pausable. Returns (false, VoluntaryRequest) without effects when
     *      canGenerate() is false. Otherwise needs MIN_ATTEMPT_GAS gas left (reverts "Insufficient gas"
     *      before drawing), then records the attempt and draws, so at most one attempt (generated, skipped
     *      or failed) happens per minInterval and no outcome can be retried. Uses block-derived randomness
     *      to decide whether to generate (see Privacy Model). Does not revert if the target call fails: the
     *      generation is rolled back, GenerationFailed is emitted and (false, the drawn type) is returned.
     * @return generated True if a dummy tx was generated
     * @return txType The type of dummy tx generated, or whose generation failed (VoluntaryRequest if none)
     */
    function tryGenerate() external returns (bool generated, DummyTxType txType);

    /**
     * @notice Force generate a specific dummy tx type
     * @dev Owner only; pausable; requires the generator to be enabled. Subject to the same per-period
     *      caps as tryGenerate (count, and spend including this dummy's cost): returns false without
     *      effects when a cap, the treasury or the target configuration does not allow it. Reverts if the
     *      target call fails.
     * @param txType The type of dummy tx to generate
     * @return success True if generation succeeded
     */
    function forceGenerate(DummyTxType txType) external returns (bool success);

    /**
     * @notice Generate multiple dummy transactions
     * @dev Owner only; pausable; requires the generator to be enabled; 1 to 10 per call. Stops at the
     *      first dummy that a per-period cap or the treasury does not allow.
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
    function checkUpkeep(bytes calldata) external view returns (bool upkeepNeeded, bytes memory performData);

    /**
     * @notice Chainlink Automation perform function
     * @dev Keeper or owner only; pausable. Same as tryGenerate (internal call), including the
     *      MIN_ATTEMPT_GAS requirement: register the upkeep with a gas limit of at least 1,000,000 (a cold
     *      attempt with 50 dummy addresses needs about 935k). The outcome is reported by
     *      DummyTransactionGenerated, GenerationSkipped or GenerationFailed.
     * @param performData Data from checkUpkeep (unused)
     */
    function performUpkeep(bytes calldata performData) external;

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
     * @return allowed True if generation can occur
     * @return reason Reason if cannot generate
     */
    function canGenerate() external view returns (bool allowed, string memory reason);

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
     * @notice Set the keeper (e.g. the Chainlink Automation forwarder) allowed to trigger generation
     * @param keeper Keeper address, or address(0) for owner-only
     */
    function setKeeper(address keeper) external;

    /**
     * @notice Set the target contracts (ILRM, BatchQueue, etc.)
     * @param ilrm ILRM contract address
     * @param batchQueue BatchQueue contract address
     */
    function setTargetContracts(address ilrm, address batchQueue) external;
}
