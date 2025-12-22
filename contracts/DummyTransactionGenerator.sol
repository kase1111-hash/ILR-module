// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./interfaces/IDummyTransactionGenerator.sol";

/**
 * @title DummyTransactionGenerator
 * @notice Generates dummy transactions to obscure real transaction patterns
 * @dev Treasury-funded automated "noop" calls at random intervals
 *
 * Privacy Features:
 * - Injects transactions indistinguishable from real ones
 * - Random intervals based on configurable probability
 * - Uses dedicated dummy addresses to avoid metric pollution
 * - Bounded spending prevents treasury drain
 *
 * Chainlink Integration:
 * - Automation-compatible for scheduled checks
 * - VRF-compatible for verifiable randomness (optional)
 * - Fallback to block-based pseudo-randomness
 *
 * Safety Measures:
 * - Dummy addresses excluded from harassment scores
 * - Entropy oracle ignores dummy address patterns
 * - Maximum spend limits per period
 * - Owner can pause/disable at any time
 */
contract DummyTransactionGenerator is IDummyTransactionGenerator, Ownable2Step, ReentrancyGuard, Pausable {
    // ============ Constants ============

    /// @notice Minimum generation interval (1 minute)
    uint256 public constant MIN_INTERVAL_FLOOR = 1 minutes;

    /// @notice Maximum generation interval (1 day)
    uint256 public constant MAX_INTERVAL_CEILING = 1 days;

    /// @notice Basis points denominator
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @notice Default voluntary request fee
    uint256 public constant DEFAULT_VOLUNTARY_FEE = 0.01 ether;

    /// @notice Maximum dummy addresses
    uint256 public constant MAX_DUMMY_ADDRESSES = 50;

    // ============ State Variables ============

    /// @notice Target ILRM contract
    address public ilrm;

    /// @notice Target BatchQueue contract
    address public batchQueue;

    /// @notice Generator configuration
    GeneratorConfig private _config;

    /// @notice Generator statistics
    GeneratorStats private _stats;

    /// @notice Dummy transaction treasury
    uint256 public dummyTreasury;

    /// @notice Registered dummy addresses
    mapping(address => DummyAddress) private _dummyAddresses;

    /// @notice List of dummy address keys
    address[] private _dummyAddressList;

    /// @notice Current random seed (updated each generation)
    uint256 private _randomSeed;

    /// @notice VRF request tracking
    mapping(uint256 => bool) private _pendingVrfRequests;

    /// @notice Last VRF result
    uint256 private _lastVrfResult;

    /// @notice Dummy tx counter
    uint256 private _dummyTxCounter;

    // ============ Constructor ============

    /**
     * @param _ilrm Target ILRM contract
     * @param initialConfig Initial generator configuration
     */
    constructor(
        address _ilrm,
        GeneratorConfig memory initialConfig
    ) Ownable(msg.sender) {
        require(_ilrm != address(0), "Invalid ILRM");

        ilrm = _ilrm;
        _validateAndSetConfig(initialConfig);

        _stats.periodStartTime = block.timestamp;
        _randomSeed = uint256(keccak256(abi.encodePacked(
            block.timestamp,
            block.prevrandao,
            msg.sender
        )));
    }

    // ============ Generation Functions ============

    /**
     * @inheritdoc IDummyTransactionGenerator
     */
    function tryGenerate() external override nonReentrant whenNotPaused returns (
        bool generated,
        DummyTxType txType
    ) {
        (bool canGen, ) = canGenerate();
        if (!canGen) {
            return (false, DummyTxType.VoluntaryRequest);
        }

        // Update random seed
        _updateRandomSeed();

        // Check probability
        uint256 random = _randomSeed % BPS_DENOMINATOR;
        if (random >= _config.probabilityBps) {
            _stats.consecutiveSkips++;
            emit GenerationSkipped(random, _config.probabilityBps);
            return (false, DummyTxType.VoluntaryRequest);
        }

        // Reset skip counter
        _stats.consecutiveSkips = 0;

        // Select random tx type
        txType = _selectRandomTxType();

        // Generate the dummy transaction
        generated = _generateDummyTx(txType);

        if (generated) {
            _stats.totalGenerated++;
            _stats.periodGenerated++;
            _stats.lastGenerationTime = block.timestamp;
        }

        return (generated, txType);
    }

    /**
     * @inheritdoc IDummyTransactionGenerator
     */
    function forceGenerate(DummyTxType txType) external override onlyOwner nonReentrant returns (bool success) {
        require(_config.enabled, "Generator disabled");

        success = _generateDummyTx(txType);

        if (success) {
            _stats.totalGenerated++;
            _stats.periodGenerated++;
            _stats.lastGenerationTime = block.timestamp;
        }
    }

    /**
     * @inheritdoc IDummyTransactionGenerator
     */
    function generateBatch(uint256 count) external override onlyOwner nonReentrant returns (uint256 generated) {
        require(_config.enabled, "Generator disabled");
        require(count > 0 && count <= 10, "Invalid count");

        for (uint256 i = 0; i < count; i++) {
            // Check period limits
            if (_stats.periodGenerated >= _config.maxPerPeriod) {
                break;
            }

            _updateRandomSeed();
            DummyTxType txType = _selectRandomTxType();

            if (_generateDummyTx(txType)) {
                generated++;
                _stats.totalGenerated++;
                _stats.periodGenerated++;
            }
        }

        if (generated > 0) {
            _stats.lastGenerationTime = block.timestamp;
        }
    }

    // ============ Chainlink Functions ============

    /**
     * @inheritdoc IDummyTransactionGenerator
     */
    function checkUpkeep(bytes calldata) external view override returns (
        bool upkeepNeeded,
        bytes memory performData
    ) {
        (upkeepNeeded, ) = canGenerate();
        performData = "";
    }

    /**
     * @inheritdoc IDummyTransactionGenerator
     */
    function performUpkeep(bytes calldata) external override {
        this.tryGenerate();
    }

    /**
     * @inheritdoc IDummyTransactionGenerator
     */
    function requestRandomness() external override onlyOwner returns (uint256 requestId) {
        // In production, this would call Chainlink VRF
        // For now, use pseudo-random as placeholder
        requestId = uint256(keccak256(abi.encodePacked(
            block.timestamp,
            block.prevrandao,
            _stats.totalGenerated
        )));

        _pendingVrfRequests[requestId] = true;

        // Simulate VRF callback (in production, VRF coordinator calls back)
        _lastVrfResult = uint256(keccak256(abi.encodePacked(requestId, block.number)));
        _randomSeed = _lastVrfResult;
    }

    // ============ Address Management ============

    /**
     * @inheritdoc IDummyTransactionGenerator
     */
    function registerDummyAddress(address dummyAddr) external override onlyOwner {
        require(dummyAddr != address(0), "Invalid address");
        require(!_dummyAddresses[dummyAddr].isActive, "Already registered");
        require(_dummyAddressList.length < MAX_DUMMY_ADDRESSES, "Max addresses reached");

        _dummyAddresses[dummyAddr] = DummyAddress({
            addr: dummyAddr,
            isActive: true,
            registeredAt: block.timestamp,
            txCount: 0
        });

        _dummyAddressList.push(dummyAddr);

        emit DummyAddressRegistered(dummyAddr, _dummyAddressList.length - 1);
    }

    /**
     * @inheritdoc IDummyTransactionGenerator
     */
    function deactivateDummyAddress(address dummyAddr) external override onlyOwner {
        require(_dummyAddresses[dummyAddr].isActive, "Not active");

        _dummyAddresses[dummyAddr].isActive = false;

        emit DummyAddressDeactivated(dummyAddr);
    }

    /**
     * @inheritdoc IDummyTransactionGenerator
     */
    function isDummyAddress(address addr) external view override returns (bool) {
        return _dummyAddresses[addr].isActive;
    }

    /**
     * @inheritdoc IDummyTransactionGenerator
     */
    function getActiveDummyAddresses() external view override returns (address[] memory addresses) {
        uint256 activeCount = 0;
        for (uint256 i = 0; i < _dummyAddressList.length; i++) {
            if (_dummyAddresses[_dummyAddressList[i]].isActive) {
                activeCount++;
            }
        }

        addresses = new address[](activeCount);
        uint256 index = 0;
        for (uint256 i = 0; i < _dummyAddressList.length; i++) {
            if (_dummyAddresses[_dummyAddressList[i]].isActive) {
                addresses[index] = _dummyAddressList[i];
                index++;
            }
        }
    }

    // ============ Treasury Functions ============

    /**
     * @inheritdoc IDummyTransactionGenerator
     */
    function fundTreasury() external payable override {
        require(msg.value > 0, "Zero amount");
        dummyTreasury += msg.value;
        emit TreasuryFunded(msg.sender, msg.value);
    }

    /**
     * @inheritdoc IDummyTransactionGenerator
     */
    function getTreasuryBalance() external view override returns (uint256) {
        return dummyTreasury;
    }

    /**
     * @inheritdoc IDummyTransactionGenerator
     */
    function withdrawTreasury(address to, uint256 amount) external override onlyOwner {
        require(to != address(0), "Invalid recipient");
        require(amount <= dummyTreasury, "Insufficient balance");

        dummyTreasury -= amount;
        (bool success, ) = to.call{value: amount}("");
        require(success, "Transfer failed");
    }

    // ============ View Functions ============

    /**
     * @inheritdoc IDummyTransactionGenerator
     */
    function getConfig() external view override returns (GeneratorConfig memory) {
        return _config;
    }

    /**
     * @inheritdoc IDummyTransactionGenerator
     */
    function getStats() external view override returns (GeneratorStats memory) {
        return _stats;
    }

    /**
     * @inheritdoc IDummyTransactionGenerator
     */
    function getTimeToNextGeneration() external view override returns (uint256) {
        if (_stats.lastGenerationTime == 0) {
            return 0;
        }

        uint256 nextAllowed = _stats.lastGenerationTime + _config.minInterval;
        if (block.timestamp >= nextAllowed) {
            return 0;
        }

        return nextAllowed - block.timestamp;
    }

    /**
     * @inheritdoc IDummyTransactionGenerator
     */
    function canGenerate() public view override returns (bool, string memory) {
        if (!_config.enabled) {
            return (false, "Generator disabled");
        }

        if (paused()) {
            return (false, "Contract paused");
        }

        // Check period reset
        if (block.timestamp >= _stats.periodStartTime + _config.periodDuration) {
            // Period would reset, so limits don't apply
        } else {
            if (_stats.periodGenerated >= _config.maxPerPeriod) {
                return (false, "Period limit reached");
            }

            if (_stats.periodSpent >= _config.maxTreasurySpend) {
                return (false, "Treasury spend limit reached");
            }
        }

        // Check interval
        if (_stats.lastGenerationTime > 0) {
            if (block.timestamp < _stats.lastGenerationTime + _config.minInterval) {
                return (false, "Min interval not passed");
            }
        }

        // Check treasury
        if (dummyTreasury < DEFAULT_VOLUNTARY_FEE) {
            return (false, "Insufficient treasury");
        }

        // Check dummy addresses
        if (_getActiveDummyCount() == 0) {
            return (false, "No active dummy addresses");
        }

        return (true, "");
    }

    /**
     * @inheritdoc IDummyTransactionGenerator
     */
    function getDummyAddressInfo(address addr) external view override returns (DummyAddress memory) {
        return _dummyAddresses[addr];
    }

    // ============ Admin Functions ============

    /**
     * @inheritdoc IDummyTransactionGenerator
     */
    function updateConfig(GeneratorConfig calldata config) external override onlyOwner {
        _validateAndSetConfig(config);

        emit ConfigUpdated(
            config.minInterval,
            config.maxInterval,
            config.probabilityBps
        );
    }

    /**
     * @inheritdoc IDummyTransactionGenerator
     */
    function setEnabled(bool enabled) external override onlyOwner {
        _config.enabled = enabled;
    }

    /**
     * @inheritdoc IDummyTransactionGenerator
     */
    function setTargetContracts(address _ilrm, address _batchQueue) external override onlyOwner {
        require(_ilrm != address(0), "Invalid ILRM");
        ilrm = _ilrm;
        batchQueue = _batchQueue;
    }

    /**
     * @notice Pause the generator
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause the generator
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // ============ Internal Functions ============

    /**
     * @dev Generate a dummy transaction of the specified type
     */
    function _generateDummyTx(DummyTxType txType) internal returns (bool success) {
        // Check and reset period if needed
        _checkAndResetPeriod();

        // Get a random dummy address
        address dummyAddr = _getRandomDummyAddress();
        if (dummyAddr == address(0)) {
            return false;
        }

        // Generate random data hash
        bytes32 dataHash = keccak256(abi.encodePacked(
            _randomSeed,
            _dummyTxCounter++,
            block.timestamp
        ));

        uint256 cost = 0;

        if (txType == DummyTxType.VoluntaryRequest) {
            cost = DEFAULT_VOLUNTARY_FEE;
            success = _generateVoluntaryRequest(dummyAddr, dataHash, cost);
        } else if (txType == DummyTxType.BatchQueueEntry) {
            success = _generateBatchQueueEntry(dummyAddr, dataHash);
        } else if (txType == DummyTxType.ViewingKeyCommit) {
            success = _generateViewingKeyCommit(dummyAddr, dataHash);
        } else {
            // Default to voluntary request
            cost = DEFAULT_VOLUNTARY_FEE;
            success = _generateVoluntaryRequest(dummyAddr, dataHash, cost);
        }

        if (success) {
            _dummyAddresses[dummyAddr].txCount++;
            _stats.periodSpent += cost;
            dummyTreasury -= cost;

            emit DummyTransactionGenerated(
                _stats.totalGenerated,
                txType,
                dummyAddr,
                dataHash
            );
        }

        return success;
    }

    /**
     * @dev Generate a voluntary request dummy tx
     */
    function _generateVoluntaryRequest(
        address dummyAddr,
        bytes32 dataHash,
        uint256 fee
    ) internal returns (bool) {
        if (dummyTreasury < fee) {
            return false;
        }

        // Call ILRM's voluntary request function
        // Using a dummy counterparty (another dummy address or self)
        address counterparty = _getRandomDummyAddress();
        if (counterparty == dummyAddr) {
            // Get a different one
            counterparty = address(uint160(uint256(keccak256(abi.encodePacked(dummyAddr)))));
        }

        (bool success, ) = ilrm.call{value: fee}(
            abi.encodeWithSignature(
                "initiateVoluntaryRequest(address,bytes32)",
                counterparty,
                dataHash
            )
        );

        return success;
    }

    /**
     * @dev Generate a batch queue entry dummy tx
     */
    function _generateBatchQueueEntry(
        address dummyAddr,
        bytes32 dataHash
    ) internal returns (bool) {
        if (batchQueue == address(0)) {
            return false;
        }

        // Queue a dummy transaction
        (bool success, ) = batchQueue.call(
            abi.encodeWithSignature(
                "queueTransaction(uint8,bytes)",
                uint8(DummyTxType.BatchQueueEntry),
                abi.encode(dummyAddr, dataHash)
            )
        );

        return success;
    }

    /**
     * @dev Generate a viewing key commitment dummy tx
     */
    function _generateViewingKeyCommit(
        address,
        bytes32 dataHash
    ) internal returns (bool) {
        // This would commit a dummy viewing key
        // For now, just emit the event
        // In production, would interact with ComplianceEscrow
        return dataHash != bytes32(0);
    }

    /**
     * @dev Update the random seed
     */
    function _updateRandomSeed() internal {
        _randomSeed = uint256(keccak256(abi.encodePacked(
            _randomSeed,
            block.timestamp,
            block.prevrandao,
            _stats.totalGenerated,
            gasleft()
        )));
    }

    /**
     * @dev Select a random transaction type
     */
    function _selectRandomTxType() internal view returns (DummyTxType) {
        // Weight towards voluntary requests (most common)
        uint256 rand = _randomSeed % 100;

        if (rand < 70) {
            return DummyTxType.VoluntaryRequest;
        } else if (rand < 90 && batchQueue != address(0)) {
            return DummyTxType.BatchQueueEntry;
        } else {
            return DummyTxType.ViewingKeyCommit;
        }
    }

    /**
     * @dev Get a random active dummy address
     */
    function _getRandomDummyAddress() internal view returns (address) {
        uint256 activeCount = _getActiveDummyCount();
        if (activeCount == 0) {
            return address(0);
        }

        uint256 targetIndex = _randomSeed % activeCount;
        uint256 currentIndex = 0;

        for (uint256 i = 0; i < _dummyAddressList.length; i++) {
            address addr = _dummyAddressList[i];
            if (_dummyAddresses[addr].isActive) {
                if (currentIndex == targetIndex) {
                    return addr;
                }
                currentIndex++;
            }
        }

        return address(0);
    }

    /**
     * @dev Get count of active dummy addresses
     */
    function _getActiveDummyCount() internal view returns (uint256 count) {
        for (uint256 i = 0; i < _dummyAddressList.length; i++) {
            if (_dummyAddresses[_dummyAddressList[i]].isActive) {
                count++;
            }
        }
    }

    /**
     * @dev Check and reset period if needed
     */
    function _checkAndResetPeriod() internal {
        if (block.timestamp >= _stats.periodStartTime + _config.periodDuration) {
            emit PeriodReset(
                block.timestamp,
                _stats.periodGenerated,
                _stats.periodSpent
            );

            _stats.periodStartTime = block.timestamp;
            _stats.periodGenerated = 0;
            _stats.periodSpent = 0;
        }
    }

    /**
     * @dev Validate and set configuration
     */
    function _validateAndSetConfig(GeneratorConfig memory config) internal {
        require(config.minInterval >= MIN_INTERVAL_FLOOR, "Min interval too low");
        require(config.maxInterval <= MAX_INTERVAL_CEILING, "Max interval too high");
        require(config.maxInterval >= config.minInterval, "Max must be >= min");
        require(config.probabilityBps <= BPS_DENOMINATOR, "Probability too high");
        require(config.maxPerPeriod > 0, "Max per period must be > 0");
        require(config.periodDuration > 0, "Period duration must be > 0");

        _config = config;
    }

    /// @notice Accept ETH for treasury
    receive() external payable {
        dummyTreasury += msg.value;
        emit TreasuryFunded(msg.sender, msg.value);
    }
}
