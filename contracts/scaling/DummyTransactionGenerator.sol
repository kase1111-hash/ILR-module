// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "../interfaces/IDummyTransactionGenerator.sol";
import "../interfaces/IBatchQueue.sol";
import "../interfaces/IILRM.sol";

/**
 * @title DummyTransactionGenerator
 * @notice Generates dummy transactions to add noise to transaction counts and timing
 * @dev Treasury-funded automated "noop" calls. See IDummyTransactionGenerator for what this does and
 *      does not hide.
 *
 * Threat model for the randomness: the seed mixes the previous seed, block.prevrandao, block.number
 * and generation counters (no caller-controlled input such as gasleft or timestamp). The keeper, the
 * owner and the block proposer can predict it and choose which block within a slot to attempt in, so
 * they can force at most one generation per minInterval. That is the whole extent of the bias, and it
 * is harmless because:
 * - attempts are keeper/owner-only and limited to one per minInterval; a skipped attempt consumes the
 *   slot, so the probability gate cannot be retried (better randomness could not fix a free retry);
 * - every generation path enforces maxPerPeriod and maxTreasurySpend (including this dummy's cost), so
 *   the worst case is the spend the owner configured as the per-period cap;
 * - dummies are attributable to this contract anyway, so predictability reveals nothing extra.
 * No VRF or commit-reveal: either would add trust and liveness assumptions without a safety or privacy
 * gain. The simulated requestRandomness() was removed.
 *
 * Slither triage:
 * - arbitrary-send-eth (voluntary request): the recipient is the owner-set, code-checked ILRM and the
 *   amount is the constant fee, so "arbitrary" is a false positive; the real bug was that anyone could
 *   trigger it. Fixed by keeper/owner gating and the per-period caps (no suppression).
 * - weak-prng (tryGenerate gate): the real bug was the free retry. Fixed by gating plus one attempt per
 *   slot; the remaining modulo is suppressed. weak-prng (type and address choice): false positive,
 *   decorrelated from the gate draw and suppressed.
 * - reentrancy-eth (tryGenerate, _generateDummyTx, generateBatch, forceGenerate): not exploitable
 *   (nonReentrant, owner-set callees), fixed anyway with checks-effects-interactions.
 * - incorrect-equality (getTimeToNextGeneration): sentinel check rewritten. unused-return
 *   (performUpkeep): internal call.
 * Also fixed (not reported by Slither): the spend cap was checked before adding the dummy's cost, and
 * forceGenerate / generateBatch ignored the caps; batch-queue dummies were queued as StakeDeposit with
 * data that bricked BatchQueue execution (now EvidenceSubmission, record-only); requestRandomness only
 * simulated a VRF and let the owner set the seed (removed). Dummies remain labeled on-chain (see
 * IDummyTransactionGenerator): that is documented, not fixable here.
 *
 * Safety Measures:
 * - Dummy addresses are labeled (isDummyAddress) so off-chain analytics and scoring can exclude them;
 *   ILRM itself has no notion of dummies (a dummy voluntary request is an ordinary fee-burning request
 *   initiated by this contract)
 * - Maximum spend and count per period, enforced on every generation path
 * - Owner can pause/disable at any time; pausing stops every generation path
 */
contract DummyTransactionGenerator is IDummyTransactionGenerator, Ownable2Step, ReentrancyGuard, Pausable {
    // ============ Constants ============

    /// @notice Minimum generation interval (1 minute)
    uint256 public constant MIN_INTERVAL_FLOOR = 1 minutes;

    /// @notice Maximum generation interval (1 day)
    uint256 public constant MAX_INTERVAL_CEILING = 1 days;

    /// @notice Basis points denominator
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Default voluntary request fee
    uint256 public constant DEFAULT_VOLUNTARY_FEE = 0.01 ether;

    /// @notice Maximum dummy addresses
    uint256 public constant MAX_DUMMY_ADDRESSES = 50;

    // ============ State Variables ============

    /// @notice Target ILRM contract
    address public ilrm;

    /// @notice Target BatchQueue contract (address(0) disables BatchQueueEntry dummies)
    address public batchQueue;

    /// @notice Account allowed to trigger generation besides the owner (Chainlink forwarder)
    address public keeper;

    /// @notice Time of the last tryGenerate attempt (generated or skipped)
    uint256 public lastAttemptTime;

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

    /// @notice Current random seed (updated each attempt; public, not unpredictable)
    uint256 private _randomSeed;

    /// @notice Dummy tx counter
    uint256 private _dummyTxCounter;

    // ============ Modifiers ============

    modifier onlyKeeperOrOwner() {
        require(msg.sender == keeper || msg.sender == owner(), "Not keeper");
        _;
    }

    // ============ Constructor ============

    /**
     * @param _ilrm Target ILRM contract
     * @param initialConfig Initial generator configuration
     */
    constructor(address _ilrm, GeneratorConfig memory initialConfig) Ownable(msg.sender) {
        require(_ilrm.code.length > 0, "Invalid ILRM");

        ilrm = _ilrm;
        _validateAndSetConfig(initialConfig);

        _stats.periodStartTime = block.timestamp;
        _randomSeed = uint256(keccak256(abi.encodePacked(block.timestamp, block.prevrandao, msg.sender)));
    }

    // ============ Generation Functions ============

    /// @inheritdoc IDummyTransactionGenerator
    function tryGenerate()
        external
        override
        onlyKeeperOrOwner
        nonReentrant
        whenNotPaused
        returns (bool generated, DummyTxType txType)
    {
        return _tryGenerate();
    }

    /// @inheritdoc IDummyTransactionGenerator
    function forceGenerate(DummyTxType txType)
        external
        override
        onlyOwner
        nonReentrant
        whenNotPaused
        returns (bool success)
    {
        require(_config.enabled, "Generator disabled");
        success = _generateDummyTx(txType);
    }

    /// @inheritdoc IDummyTransactionGenerator
    function generateBatch(uint256 count)
        external
        override
        onlyOwner
        nonReentrant
        whenNotPaused
        returns (uint256 generated)
    {
        require(_config.enabled, "Generator disabled");
        require(count > 0 && count <= 10, "Invalid count");

        for (uint256 i = 0; i < count; i++) {
            if (!_generateDummyTx(_selectRandomTxType())) {
                break; // a per-period cap or the treasury ran out
            }
            generated++;
        }
    }

    // ============ Chainlink Functions ============

    /// @inheritdoc IDummyTransactionGenerator
    function checkUpkeep(bytes calldata) external view override returns (bool upkeepNeeded, bytes memory performData) {
        (upkeepNeeded,) = canGenerate();
        performData = "";
    }

    /// @inheritdoc IDummyTransactionGenerator
    function performUpkeep(bytes calldata) external override onlyKeeperOrOwner nonReentrant whenNotPaused {
        // Internal call: the outcome is reported by DummyTransactionGenerated / GenerationSkipped
        _tryGenerate();
    }

    // ============ Address Management ============

    /// @inheritdoc IDummyTransactionGenerator
    function registerDummyAddress(address dummyAddr) external override onlyOwner {
        require(dummyAddr != address(0), "Invalid address");
        require(!_dummyAddresses[dummyAddr].isActive, "Already registered");
        require(_dummyAddressList.length < MAX_DUMMY_ADDRESSES, "Max addresses reached");

        _dummyAddresses[dummyAddr] =
            DummyAddress({addr: dummyAddr, isActive: true, registeredAt: block.timestamp, txCount: 0});

        _dummyAddressList.push(dummyAddr);

        emit DummyAddressRegistered(dummyAddr, _dummyAddressList.length - 1);
    }

    /// @inheritdoc IDummyTransactionGenerator
    function deactivateDummyAddress(address dummyAddr) external override onlyOwner {
        require(_dummyAddresses[dummyAddr].isActive, "Not active");

        _dummyAddresses[dummyAddr].isActive = false;

        emit DummyAddressDeactivated(dummyAddr);
    }

    /// @inheritdoc IDummyTransactionGenerator
    function isDummyAddress(address addr) external view override returns (bool) {
        return _dummyAddresses[addr].isActive;
    }

    /// @inheritdoc IDummyTransactionGenerator
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

    /// @inheritdoc IDummyTransactionGenerator
    function fundTreasury() external payable override {
        require(msg.value > 0, "Zero amount");
        dummyTreasury += msg.value;
        emit TreasuryFunded(msg.sender, msg.value);
    }

    /// @inheritdoc IDummyTransactionGenerator
    function getTreasuryBalance() external view override returns (uint256) {
        return dummyTreasury;
    }

    /// @inheritdoc IDummyTransactionGenerator
    function withdrawTreasury(address to, uint256 amount) external override onlyOwner nonReentrant {
        require(to != address(0), "Invalid recipient");
        require(amount <= dummyTreasury, "Insufficient balance");

        dummyTreasury -= amount;
        emit TreasuryWithdrawn(to, amount);
        (bool success,) = to.call{value: amount}("");
        require(success, "Transfer failed");
    }

    // ============ View Functions ============

    /// @inheritdoc IDummyTransactionGenerator
    function getConfig() external view override returns (GeneratorConfig memory) {
        return _config;
    }

    /// @inheritdoc IDummyTransactionGenerator
    function getStats() external view override returns (GeneratorStats memory) {
        return _stats;
    }

    /// @inheritdoc IDummyTransactionGenerator
    function getTimeToNextGeneration() external view override returns (uint256) {
        uint256 last = _lastActivity();
        uint256 nextAllowed = last + _config.minInterval;
        if (last > 0 && block.timestamp < nextAllowed) {
            return nextAllowed - block.timestamp;
        }
        return 0;
    }

    /// @inheritdoc IDummyTransactionGenerator
    function canGenerate() public view override returns (bool, string memory) {
        if (!_config.enabled) {
            return (false, "Generator disabled");
        }

        if (paused()) {
            return (false, "Contract paused");
        }

        // Limits apply unless the period is about to reset
        if (block.timestamp < _stats.periodStartTime + _config.periodDuration) {
            if (_stats.periodGenerated >= _config.maxPerPeriod) {
                return (false, "Period limit reached");
            }

            if (_stats.periodSpent >= _config.maxTreasurySpend) {
                return (false, "Treasury spend limit reached");
            }
        }

        // One attempt (generated or skipped) per minInterval
        uint256 last = _lastActivity();
        if (last > 0 && block.timestamp < last + _config.minInterval) {
            return (false, "Min interval not passed");
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

    /// @inheritdoc IDummyTransactionGenerator
    function getDummyAddressInfo(address addr) external view override returns (DummyAddress memory) {
        return _dummyAddresses[addr];
    }

    // ============ Admin Functions ============

    /// @inheritdoc IDummyTransactionGenerator
    function updateConfig(GeneratorConfig calldata config) external override onlyOwner {
        _validateAndSetConfig(config);

        emit ConfigUpdated(config.minInterval, config.maxInterval, config.probabilityBps);
    }

    /// @inheritdoc IDummyTransactionGenerator
    function setEnabled(bool enabled) external override onlyOwner {
        _config.enabled = enabled;
    }

    /// @inheritdoc IDummyTransactionGenerator
    function setKeeper(address newKeeper) external override onlyOwner {
        emit KeeperUpdated(keeper, newKeeper);
        // address(0) is valid: generation becomes owner-only
        // slither-disable-next-line missing-zero-check
        keeper = newKeeper;
    }

    /// @inheritdoc IDummyTransactionGenerator
    function setTargetContracts(address _ilrm, address _batchQueue) external override onlyOwner {
        require(_ilrm.code.length > 0, "Invalid ILRM");
        // address(0) is valid for the queue: it disables BatchQueueEntry dummies
        require(_batchQueue == address(0) || _batchQueue.code.length > 0, "Invalid BatchQueue");
        ilrm = _ilrm;
        batchQueue = _batchQueue;
        emit TargetContractsUpdated(_ilrm, _batchQueue);
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
     * @dev One generation attempt. The attempt is recorded before any randomness is drawn, so a skipped
     *      attempt cannot be retried until minInterval has passed.
     */
    function _tryGenerate() internal returns (bool generated, DummyTxType txType) {
        (bool canGen,) = canGenerate();
        if (!canGen) {
            return (false, DummyTxType.VoluntaryRequest);
        }

        lastAttemptTime = block.timestamp;
        _updateRandomSeed();

        // Block-derived gate: one keeper/owner attempt per slot and hard caps bound any bias (threat model)
        // slither-disable-next-line weak-prng
        uint256 random = _randomSeed % BPS_DENOMINATOR;
        if (random >= _config.probabilityBps) {
            _stats.consecutiveSkips++;
            emit GenerationSkipped(random, _config.probabilityBps);
            return (false, DummyTxType.VoluntaryRequest);
        }

        _stats.consecutiveSkips = 0;
        txType = _selectRandomTxType();
        generated = _generateDummyTx(txType);
    }

    /**
     * @dev Generate a dummy transaction of the specified type. Single choke point for every generation
     *      path: returns false (no effects) when a per-period cap, the treasury or the target does not
     *      allow it. Checks-effects-interactions: all accounting is written before the external call,
     *      and a failed call reverts the whole generation, so accounting always matches the ETH spent.
     */
    function _generateDummyTx(DummyTxType txType) internal returns (bool) {
        _checkAndResetPeriod();
        _updateRandomSeed();

        bool toQueue = txType == DummyTxType.BatchQueueEntry;
        // VoluntaryRequest pays the fee; ZKProofSubmit and StakeDeposit fall back to a voluntary request
        // (as before the fix); BatchQueueEntry and ViewingKeyCommit cost nothing
        uint256 cost = (toQueue || txType == DummyTxType.ViewingKeyCommit) ? 0 : DEFAULT_VOLUNTARY_FEE;

        if (
            _stats.periodGenerated >= _config.maxPerPeriod || _stats.periodSpent + cost > _config.maxTreasurySpend
                || dummyTreasury < cost || (toQueue && batchQueue == address(0))
        ) {
            return false;
        }

        address dummyAddr = _getRandomDummyAddress();
        if (dummyAddr == address(0)) {
            return false;
        }

        // Effects
        bytes32 dataHash = keccak256(abi.encodePacked(_randomSeed, _dummyTxCounter++, block.timestamp));
        _dummyAddresses[dummyAddr].txCount++;
        _stats.periodSpent += cost;
        dummyTreasury -= cost;
        uint256 id = _stats.totalGenerated; // 0-based txIndex, as before the fix
        _stats.totalGenerated = id + 1;
        _stats.periodGenerated++;
        _stats.lastGenerationTime = block.timestamp;
        emit DummyTransactionGenerated(id, txType, dummyAddr, dataHash);

        // Interactions (typed calls revert on a target without code)
        if (toQueue) {
            // A record-only type: the queue rejects relayed types from anyone but their typed functions.
            // The queue's txId is not needed; a failed queue call reverts the whole generation.
            // slither-disable-next-line unused-return
            IBatchQueue(batchQueue).queueTransaction(IBatchQueue.TxType.EvidenceSubmission, abi.encode(dataHash));
        } else if (cost > 0) {
            // Recipient is the owner-configured ILRM (code-checked), amount is the constant fee, and the
            // caller is the keeper or owner within the per-period spend cap.
            IILRM(ilrm).initiateVoluntaryRequest{value: cost}(_counterpartyFor(dummyAddr), dataHash);
        }
        // ViewingKeyCommit: nothing to call yet (would commit a dummy viewing key in ComplianceEscrow)

        return true;
    }

    /**
     * @dev Counterparty for a dummy voluntary request: the next active dummy after dummyAddr (always a
     *      different one when two or more are active), else a pseudo-address derived from dummyAddr.
     *      (The original code re-drew with the same seed, so it always fell back to the pseudo-address.)
     */
    function _counterpartyFor(address dummyAddr) internal view returns (address) {
        address other = _getDummyAddressAt((_randomSeed >> 1) + 1);
        if (other != dummyAddr && other != address(0)) {
            return other;
        }
        return address(uint160(uint256(keccak256(abi.encodePacked(dummyAddr)))));
    }

    /**
     * @dev Update the random seed (no caller-controlled inputs)
     */
    function _updateRandomSeed() internal {
        _randomSeed = uint256(
            keccak256(abi.encode(_randomSeed, block.prevrandao, block.number, _stats.totalGenerated, _dummyTxCounter))
        );
    }

    /**
     * @dev Select a random transaction type, weighted towards voluntary requests. Uses a value derived
     *      separately from the probability draw so the type mix does not depend on probabilityBps.
     */
    function _selectRandomTxType() internal view returns (DummyTxType) {
        // Type mix only, decorrelated from the gate draw; predictability is harmless (threat model)
        // slither-disable-next-line weak-prng
        uint256 rand = uint256(keccak256(abi.encode(_randomSeed, "type"))) % 100;

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
        return _getDummyAddressAt(_randomSeed >> 1);
    }

    /**
     * @dev Active dummy address number (r mod activeCount), or address(0) if none is active
     */
    function _getDummyAddressAt(uint256 r) internal view returns (address) {
        uint256 activeCount = _getActiveDummyCount();
        if (activeCount == 0) {
            return address(0);
        }

        // Dummy address choice only; dummies are attributable anyway, so predictability is harmless
        // slither-disable-next-line weak-prng
        uint256 targetIndex = r % activeCount;
        uint256 currentIndex = 0;

        for (uint256 i = 0; i < _dummyAddressList.length; i++) {
            address addr = _dummyAddressList[i];
            if (_dummyAddresses[addr].isActive) {
                // currentIndex counts up from 0, so >= first holds at targetIndex
                if (currentIndex >= targetIndex) {
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
     * @dev Latest of the last attempt and the last generation (0 if neither happened)
     */
    function _lastActivity() internal view returns (uint256) {
        uint256 lastGen = _stats.lastGenerationTime;
        return lastAttemptTime > lastGen ? lastAttemptTime : lastGen;
    }

    /**
     * @dev Check and reset period if needed
     */
    function _checkAndResetPeriod() internal {
        if (block.timestamp >= _stats.periodStartTime + _config.periodDuration) {
            emit PeriodReset(block.timestamp, _stats.periodGenerated, _stats.periodSpent);

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
