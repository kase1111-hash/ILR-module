// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../contracts/ILRM.sol";
import "../contracts/Treasury.sol";
import "../contracts/modules/DIDRegistry.sol";
import "../contracts/scaling/L3Bridge.sol";
import "../contracts/scaling/L3StateVerifier.sol";
import "../contracts/scaling/L3DisputeBatcher.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title E2ESimulation
 * @notice End-to-end simulation running 100 varied scenarios
 * @dev Tests all parameter variations and human error handling
 *
 * Simulation Categories:
 * 1-20:   Happy path variations (different stakes, timing)
 * 21-40:  Counter-proposal scenarios
 * 41-60:  Timeout and default license scenarios
 * 61-80:  DID integration scenarios
 * 81-90:  L3 Bridge scenarios
 * 91-100: Human error simulations
 */

// ============ Mock Contracts ============

contract SimulationToken is ERC20 {
    constructor() ERC20("SimToken", "SIM") {
        _mint(msg.sender, 1_000_000_000 ether);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract SimulationAssetRegistry is IAssetRegistry {
    mapping(uint256 => bool) public frozen;
    mapping(uint256 => bytes32) public appliedFallback;
    uint256 public freezeCount;
    uint256 public unfreezeCount;

    function registerAsset(bytes32, address, bytes32) external pure override {}

    function freezeAssets(uint256 disputeId, address) external override {
        frozen[disputeId] = true;
        freezeCount++;
    }

    function unfreezeAssets(uint256 disputeId, bytes calldata) external override {
        frozen[disputeId] = false;
        unfreezeCount++;
    }

    function applyFallbackLicense(uint256 disputeId, bytes32 termsHash) external override {
        appliedFallback[disputeId] = termsHash;
    }

    function grantLicense(bytes32, address, bytes32, uint256, uint256, bool) external pure override {}
    function revokeLicense(bytes32, address) external pure override {}

    function getAsset(bytes32) external pure override returns (Asset memory) {
        return Asset(bytes32(0), address(0), bytes32(0), FreezeStatus.Active, 0, 0);
    }

    function getLicense(bytes32, address) external pure override returns (LicenseGrant memory) {
        return LicenseGrant(bytes32(0), address(0), bytes32(0), 0, 0, 0, true, false);
    }

    function isFrozen(bytes32) external pure override returns (bool) {
        return false;
    }

    function getAssetsByOwner(address) external pure override returns (bytes32[] memory) {
        return new bytes32[](0);
    }

    function isAuthorizedILRM(address) external pure override returns (bool) {
        return true;
    }
}

contract SimulationOracle is IOracle {
    bool public shouldVerify = true;
    address public ilrmAddress;

    function setVerify(bool _verify) external {
        shouldVerify = _verify;
    }

    function setILRM(address _ilrm) external {
        ilrmAddress = _ilrm;
    }

    function requestProposal(uint256, bytes32) external pure override {}

    function submitProposal(uint256, string calldata, bytes calldata) external pure override {}

    function verifySignature(uint256, bytes32, bytes calldata) external view override returns (bool) {
        return shouldVerify;
    }

    function ilrmContract() external view override returns (address) {
        return ilrmAddress;
    }

    function isOracle(address account) external view override returns (bool) {
        return account == address(this);
    }

    function oraclePublicKeyHash(address) external pure override returns (bytes32) {
        return bytes32(0);
    }
}

// ============ Simulation Results ============

struct SimulationResult {
    uint256 scenarioId;
    string scenarioType;
    bool success;
    string outcome;
    uint256 gasUsed;
    string errorMessage;
}

// ============ Main Simulation Contract ============

contract E2ESimulationTest is Test {
    // Contracts
    ILRM public ilrm;
    NatLangChainTreasury public treasury;
    DIDRegistry public didRegistry;
    L3Bridge public l3Bridge;
    L3StateVerifier public stateVerifier;
    L3DisputeBatcher public batcher;

    // Mocks
    SimulationToken public token;
    SimulationAssetRegistry public assetRegistry;
    SimulationOracle public oracle;

    // Test addresses - simulate different users
    address[] public users;
    address public owner;
    address public sequencer;
    uint256 internal sequencerKey;

    // Simulation tracking
    SimulationResult[] public results;
    uint256 public successCount;
    uint256 public failureCount;
    uint256 public gracefulErrorCount;

    // Constants
    uint256 constant MIN_STAKE = 0.1 ether;
    uint256 constant MAX_STAKE = 1000 ether;

    // Fallback license template
    IILRM.FallbackLicense defaultFallback;

    function setUp() public {
        owner = address(this);
        // Sequencer needs a known private key so it can sign state commitments
        (sequencer, sequencerKey) = makeAddrAndKey("sequencer");

        // Deploy mocks
        token = new SimulationToken();
        assetRegistry = new SimulationAssetRegistry();
        oracle = new SimulationOracle();

        // Deploy core contracts
        ilrm = new ILRM(IERC20(token), address(oracle), IAssetRegistry(assetRegistry));
        oracle.setILRM(address(ilrm));
        treasury = new NatLangChainTreasury(IERC20(token), 100 ether, 1000 ether, 30 days);
        didRegistry = new DIDRegistry();
        l3Bridge = new L3Bridge(address(ilrm));
        stateVerifier = new L3StateVerifier(address(l3Bridge));
        batcher = new L3DisputeBatcher(address(l3Bridge), address(ilrm));

        // Configure contracts
        treasury.setILRM(address(ilrm));

        // Configure L3 Bridge
        IL3Bridge.SequencerConfig memory config = IL3Bridge.SequencerConfig({
            sequencerAddress: sequencer,
            commitmentInterval: 100,
            challengePeriod: 7 days,
            minBatchSize: 1,
            maxBatchSize: 100
        });
        l3Bridge.updateSequencerConfig(config);

        // Create test users (20 users for variety)
        for (uint256 i = 1; i <= 20; i++) {
            address user = makeAddr(string.concat("user", vm.toString(i)));
            users.push(user);
            token.mint(user, 100000 ether);
            vm.deal(user, 1000 ether);

            vm.prank(user);
            token.approve(address(ilrm), type(uint256).max);
        }

        // Fund treasury
        token.mint(address(treasury), 100000 ether);
        vm.deal(address(l3Bridge), 100 ether);

        // Default fallback license
        defaultFallback = IILRM.FallbackLicense({
            nonExclusive: true,
            termDuration: 365 days,
            royaltyCapBps: 500,
            termsHash: keccak256("default_terms")
        });

        // Add trusted DID issuer (allowed to issue every attestation type)
        IDIDRegistry.AttestationType[] memory types = new IDIDRegistry.AttestationType[](6);
        types[0] = IDIDRegistry.AttestationType.Identity;
        types[1] = IDIDRegistry.AttestationType.KYC;
        types[2] = IDIDRegistry.AttestationType.Reputation;
        types[3] = IDIDRegistry.AttestationType.Governance;
        types[4] = IDIDRegistry.AttestationType.Professional;
        types[5] = IDIDRegistry.AttestationType.Custom;
        didRegistry.addTrustedIssuer(owner, "TestIssuer", types, 100);
    }

    // ============ Main Simulation Runner ============

    /**
     * @notice Run all 100 simulation scenarios
     */
    function testRunAllSimulations() public {
        console.log("========================================");
        console.log("  NatLangChain ILRM E2E Simulation");
        console.log("  Running 100 Varied Scenarios");
        console.log("========================================");
        console.log("");

        // Scenarios 1-20: Happy Path Variations
        for (uint256 i = 1; i <= 20; i++) {
            _runHappyPathScenario(i);
        }

        // Scenarios 21-40: Counter-Proposal Scenarios
        for (uint256 i = 21; i <= 40; i++) {
            _runCounterProposalScenario(i);
        }

        // Scenarios 41-60: Timeout Scenarios
        for (uint256 i = 41; i <= 60; i++) {
            _runTimeoutScenario(i);
        }

        // Scenarios 61-80: DID Integration Scenarios
        for (uint256 i = 61; i <= 80; i++) {
            _runDIDScenario(i);
        }

        // Scenarios 81-90: L3 Bridge Scenarios
        for (uint256 i = 81; i <= 90; i++) {
            _runL3BridgeScenario(i);
        }

        // Scenarios 91-100: Human Error Simulations
        for (uint256 i = 91; i <= 100; i++) {
            _runHumanErrorScenario(i);
        }

        // Print summary
        _printSummary();

        // Every scenario must be accounted for. Scenarios 1-90 must complete outright;
        // scenarios 91-100 (human errors) must all be rejected by the contracts.
        assertEq(results.length, 100, "Not all scenarios ran");
        assertEq(failureCount, 0, "Some scenarios failed");
        assertEq(successCount, 90, "Non-error scenarios did not all succeed");
        assertEq(gracefulErrorCount, 10, "Human-error scenarios were not all rejected");
    }

    // ============ Scenario Categories ============

    /**
     * @notice Happy path scenarios with varying parameters
     */
    function _runHappyPathScenario(uint256 scenarioId) internal {
        string memory scenarioType = "HappyPath";
        uint256 startGas = gasleft();

        // Vary parameters based on scenario
        uint256 stakeAmount = _varyStake(scenarioId);
        address initiator = users[scenarioId % users.length];
        address counterparty = users[(scenarioId + 1) % users.length];

        try this.executeHappyPath(initiator, counterparty, stakeAmount) returns (string memory outcome) {
            _recordSuccess(scenarioId, scenarioType, outcome, startGas - gasleft());
        } catch Error(string memory reason) {
            _recordGracefulError(scenarioId, scenarioType, reason, startGas - gasleft());
        } catch {
            _recordFailure(scenarioId, scenarioType, "Unknown error", startGas - gasleft());
        }
    }

    function executeHappyPath(
        address initiator,
        address counterparty,
        uint256 stakeAmount
    ) external returns (string memory) {
        // Initiate dispute
        vm.prank(initiator);
        uint256 disputeId = ilrm.initiateBreachDispute(
            counterparty,
            stakeAmount,
            keccak256(abi.encodePacked("evidence", block.timestamp)),
            defaultFallback
        );

        // Counterparty stakes
        vm.prank(counterparty);
        ilrm.depositStake(disputeId);

        // Oracle submits proposal
        vm.prank(address(oracle));
        ilrm.submitLLMProposal(disputeId, "Settlement: 50/50 split", "");

        // Both accept
        vm.prank(initiator);
        ilrm.acceptProposal(disputeId);
        vm.prank(counterparty);
        ilrm.acceptProposal(disputeId);

        IILRM.Dispute memory d = ilrm.disputes(disputeId);
        require(d.resolved, "Dispute not resolved");
        require(d.outcome == IILRM.DisputeOutcome.AcceptedProposal, "Unexpected outcome");

        return "MutualAcceptance";
    }

    /**
     * @notice Counter-proposal scenarios
     */
    function _runCounterProposalScenario(uint256 scenarioId) internal {
        string memory scenarioType = "CounterProposal";
        uint256 startGas = gasleft();

        uint256 counterCount = (scenarioId % 3) + 1; // 1-3 counters
        uint256 stakeAmount = _varyStake(scenarioId);
        address initiator = users[scenarioId % users.length];
        address counterparty = users[(scenarioId + 3) % users.length];

        try this.executeCounterProposalScenario(initiator, counterparty, stakeAmount, counterCount)
            returns (string memory outcome) {
            _recordSuccess(scenarioId, scenarioType, outcome, startGas - gasleft());
        } catch Error(string memory reason) {
            _recordGracefulError(scenarioId, scenarioType, reason, startGas - gasleft());
        } catch {
            _recordFailure(scenarioId, scenarioType, "Unknown error", startGas - gasleft());
        }
    }

    function executeCounterProposalScenario(
        address initiator,
        address counterparty,
        uint256 stakeAmount,
        uint256 counterCount
    ) external returns (string memory) {
        vm.prank(initiator);
        uint256 disputeId = ilrm.initiateBreachDispute(
            counterparty,
            stakeAmount,
            keccak256("initial_evidence"),
            defaultFallback
        );

        vm.prank(counterparty);
        ilrm.depositStake(disputeId);

        // Submit counter-proposals
        for (uint256 i = 0; i < counterCount; i++) {
            uint256 fee = 0.01 ether * (1 << i);
            address proposer = i % 2 == 0 ? initiator : counterparty;

            vm.prank(proposer);
            ilrm.counterPropose{value: fee}(disputeId, keccak256(abi.encodePacked("counter", i)));
        }

        // Final proposal and acceptance
        vm.prank(address(oracle));
        ilrm.submitLLMProposal(disputeId, "Final settlement after counters", "");

        vm.prank(initiator);
        ilrm.acceptProposal(disputeId);
        vm.prank(counterparty);
        ilrm.acceptProposal(disputeId);

        IILRM.Dispute memory d = ilrm.disputes(disputeId);
        require(d.resolved, "Dispute not resolved");
        require(d.outcome == IILRM.DisputeOutcome.AcceptedProposal, "Unexpected outcome");
        require(d.counterCount == counterCount, "Counter count mismatch");

        return string(abi.encodePacked("Resolved after ", _uint2str(counterCount), " counters"));
    }

    /**
     * @notice Timeout scenarios
     */
    function _runTimeoutScenario(uint256 scenarioId) internal {
        string memory scenarioType = "Timeout";
        uint256 startGas = gasleft();

        bool counterpartyStakes = scenarioId % 2 == 0;
        uint256 stakeAmount = _varyStake(scenarioId);
        address initiator = users[scenarioId % users.length];
        address counterparty = users[(scenarioId + 5) % users.length];

        try this.executeTimeoutScenario(initiator, counterparty, stakeAmount, counterpartyStakes)
            returns (string memory outcome) {
            _recordSuccess(scenarioId, scenarioType, outcome, startGas - gasleft());
        } catch Error(string memory reason) {
            _recordGracefulError(scenarioId, scenarioType, reason, startGas - gasleft());
        } catch {
            _recordFailure(scenarioId, scenarioType, "Unknown error", startGas - gasleft());
        }
    }

    function executeTimeoutScenario(
        address initiator,
        address counterparty,
        uint256 stakeAmount,
        bool counterpartyStakes
    ) external returns (string memory) {
        vm.prank(initiator);
        uint256 disputeId = ilrm.initiateBreachDispute(
            counterparty,
            stakeAmount,
            keccak256("timeout_evidence"),
            defaultFallback
        );

        if (counterpartyStakes) {
            vm.prank(counterparty);
            ilrm.depositStake(disputeId);

            // Warp past resolution timeout
            vm.warp(block.timestamp + 8 days);
            ilrm.enforceTimeout(disputeId);

            require(ilrm.disputes(disputeId).outcome == IILRM.DisputeOutcome.TimeoutWithBurn, "Unexpected outcome");
            return "TimeoutWithBurn";
        } else {
            // Warp past stake window
            vm.warp(block.timestamp + 4 days);
            ilrm.enforceTimeout(disputeId);

            require(ilrm.disputes(disputeId).outcome == IILRM.DisputeOutcome.DefaultLicenseApplied, "Unexpected outcome");
            require(assetRegistry.appliedFallback(disputeId) == defaultFallback.termsHash, "Fallback not applied");
            return "DefaultLicenseApplied";
        }
    }

    /**
     * @notice DID integration scenarios
     */
    function _runDIDScenario(uint256 scenarioId) internal {
        string memory scenarioType = "DIDIntegration";
        uint256 startGas = gasleft();

        address user = users[scenarioId % users.length];
        bool hasValidDID = scenarioId % 3 != 0; // 2/3 have valid DID

        try this.executeDIDScenario(user, hasValidDID, scenarioId) returns (string memory outcome) {
            _recordSuccess(scenarioId, scenarioType, outcome, startGas - gasleft());
        } catch Error(string memory reason) {
            _recordGracefulError(scenarioId, scenarioType, reason, startGas - gasleft());
        } catch {
            _recordFailure(scenarioId, scenarioType, "Unknown error", startGas - gasleft());
        }
    }

    function executeDIDScenario(
        address user,
        bool hasValidDID,
        uint256 scenarioId
    ) external returns (string memory) {
        // Register DID if supposed to have one
        if (hasValidDID) {
            // Check if already registered
            if (!didRegistry.hasDID(user)) {
                vm.prank(user);
                bytes32 newDid = didRegistry.registerDID(keccak256(abi.encodePacked("did_doc", user)));

                // Issue credentials based on scenario variation
                uint256 credCount = (scenarioId % 5) + 1;
                for (uint256 i = 0; i < credCount; i++) {
                    didRegistry.issueCredential(
                        newDid,
                        IDIDRegistry.AttestationType(i % 6),
                        keccak256(abi.encodePacked("claim", i)),
                        0, // No expiry
                        50 + (i * 10) // Varying weights
                    );
                }
            }

            bytes32 did = didRegistry.addressToDID(user);
            uint256 sybilScore = didRegistry.getSybilScore(did);

            return string(abi.encodePacked("DID registered, sybilScore=", _uint2str(sybilScore)));
        } else {
            // Try to use functions requiring DID without one
            bool hasDID = didRegistry.hasDID(user);
            require(!hasDID, "UnexpectedDID");
            return "NoDID_AsExpected";
        }
    }

    /**
     * @notice L3 Bridge scenarios
     */
    function _runL3BridgeScenario(uint256 scenarioId) internal {
        string memory scenarioType = "L3Bridge";
        uint256 startGas = gasleft();

        try this.executeL3BridgeScenario(scenarioId) returns (string memory outcome) {
            _recordSuccess(scenarioId, scenarioType, outcome, startGas - gasleft());
        } catch Error(string memory reason) {
            _recordGracefulError(scenarioId, scenarioType, reason, startGas - gasleft());
        } catch {
            _recordFailure(scenarioId, scenarioType, "Unknown error", startGas - gasleft());
        }
    }

    function executeL3BridgeScenario(uint256 scenarioId) external returns (string memory) {
        // Test various bridge operations
        if (scenarioId % 3 == 0) {
            // Test state commitment
            bytes32 stateRoot = keccak256(abi.encodePacked("state", scenarioId));
            // Commitments must chain from the latest committed root (or finalized root if none pending)
            bytes32 previousRoot = l3Bridge.latestCommittedRoot();
            if (previousRoot == bytes32(0)) {
                previousRoot = l3Bridge.latestFinalizedRoot();
            }

            bytes32 messageHash = keccak256(abi.encodePacked(
                stateRoot,
                uint256(scenarioId),
                uint256(0),
                previousRoot
            ));

            // Sign with sequencer key (EIP-191 personal_sign, as verified by L3Bridge)
            bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(sequencerKey, ethSignedHash);
            bytes memory sig = abi.encodePacked(r, s, v);

            IL3Bridge.StateCommitment memory commitment = IL3Bridge.StateCommitment({
                stateRoot: stateRoot,
                blockNumber: scenarioId,
                timestamp: block.timestamp,
                disputeCount: 0,
                previousRoot: previousRoot,
                sequencerSignature: sig
            });

            vm.prank(sequencer);
            l3Bridge.submitStateCommitment(commitment);

            require(l3Bridge.getStateCommitment(stateRoot).stateRoot == stateRoot, "Commitment not stored");
            require(l3Bridge.latestCommittedRoot() == stateRoot, "Latest committed root not updated");
            require(!l3Bridge.isStateFinalized(stateRoot), "Finalized before challenge period");

            return "StateCommitmentSubmitted";
        } else if (scenarioId % 3 == 1) {
            // Test bridge status
            IL3Bridge.BridgeStatus status = l3Bridge.getBridgeStatus();
            return status == IL3Bridge.BridgeStatus.Active ? "BridgeActive" : "BridgeInactive";
        } else {
            // Test view functions
            uint256 totalBridged = l3Bridge.getTotalBridgedDisputes();
            uint256 totalSettled = l3Bridge.getTotalSettlements();
            return string(abi.encodePacked("Bridged:", _uint2str(totalBridged), ",Settled:", _uint2str(totalSettled)));
        }
    }

    /**
     * @notice Human error simulation scenarios
     */
    function _runHumanErrorScenario(uint256 scenarioId) internal {
        string memory scenarioType = "HumanError";
        uint256 startGas = gasleft();

        try this.executeHumanErrorScenario(scenarioId) returns (string memory outcome) {
            // Reaching here means the contracts accepted invalid input ("ShouldHaveFailed_*")
            _recordFailure(scenarioId, scenarioType, outcome, startGas - gasleft());
        } catch Error(string memory reason) {
            // This is expected for error scenarios!
            _recordGracefulError(scenarioId, scenarioType, reason, startGas - gasleft());
        } catch (bytes memory) {
            // Custom errors
            _recordGracefulError(scenarioId, scenarioType, "CustomError:GracefullyHandled", startGas - gasleft());
        }
    }

    function executeHumanErrorScenario(uint256 scenarioId) external returns (string memory) {
        address user = users[0];

        // Different error types based on scenario
        uint256 errorType = scenarioId % 10;

        if (errorType == 0) {
            // Error: Zero address counterparty
            vm.prank(user);
            ilrm.initiateBreachDispute(address(0), 1 ether, bytes32(0), defaultFallback);
            return "ShouldHaveFailed_ZeroAddress";
        }
        else if (errorType == 1) {
            // Error: Dispute with self
            vm.prank(user);
            ilrm.initiateBreachDispute(user, 1 ether, bytes32(0), defaultFallback);
            return "ShouldHaveFailed_SelfDispute";
        }
        else if (errorType == 2) {
            // Error: Zero stake amount
            vm.prank(user);
            ilrm.initiateBreachDispute(users[1], 0, bytes32(0), defaultFallback);
            return "ShouldHaveFailed_ZeroStake";
        }
        else if (errorType == 3) {
            // Error: Exclusive fallback license
            IILRM.FallbackLicense memory badFallback = IILRM.FallbackLicense({
                nonExclusive: false, // Invalid!
                termDuration: 365 days,
                royaltyCapBps: 500,
                termsHash: bytes32(0)
            });
            vm.prank(user);
            ilrm.initiateBreachDispute(users[1], 1 ether, bytes32(0), badFallback);
            return "ShouldHaveFailed_ExclusiveFallback";
        }
        else if (errorType == 4) {
            // Error: Accept non-existent dispute
            vm.prank(user);
            ilrm.acceptProposal(999999);
            return "ShouldHaveFailed_NonExistentDispute";
        }
        else if (errorType == 5) {
            // Error: Deposit stake for non-existent dispute
            vm.prank(user);
            ilrm.depositStake(999999);
            return "ShouldHaveFailed_NonExistentDispute";
        }
        else if (errorType == 6) {
            // Error: Counter-propose with insufficient fee
            vm.prank(user);
            uint256 disputeId = ilrm.initiateBreachDispute(users[1], 1 ether, bytes32(0), defaultFallback);
            vm.prank(users[1]);
            ilrm.depositStake(disputeId);

            vm.prank(user);
            ilrm.counterPropose{value: 0.001 ether}(disputeId, bytes32(0)); // Too little!
            return "ShouldHaveFailed_InsufficientFee";
        }
        else if (errorType == 7) {
            // Error: Revoke non-existent DID
            vm.prank(user);
            didRegistry.revokeDID(bytes32(uint256(0xdead)), "test");
            return "ShouldHaveFailed_NonExistentDID";
        }
        else if (errorType == 8) {
            // Error: Issue credential without being trusted issuer
            vm.prank(users[5]); // Not a trusted issuer
            didRegistry.issueCredential(
                bytes32(uint256(0x123)),
                IDIDRegistry.AttestationType.Identity,
                bytes32(0),
                0,
                50
            );
            return "ShouldHaveFailed_NotTrustedIssuer";
        }
        else {
            // Error: Voluntary request with insufficient burn fee
            vm.prank(user);
            ilrm.initiateVoluntaryRequest{value: 0.001 ether}(users[1], bytes32(0));
            return "ShouldHaveFailed_InsufficientBurnFee";
        }
    }

    // ============ Additional Fuzz-like Scenarios ============

    /**
     * @notice Run fuzz-like tests with random parameters
     */
    function testFuzzLikeSimulations() public {
        console.log("");
        console.log("========================================");
        console.log("  Fuzz-Like Parameter Variations");
        console.log("========================================");

        // Vary stake amounts
        uint256[] memory stakeAmounts = new uint256[](10);
        stakeAmounts[0] = 0.1 ether;
        stakeAmounts[1] = 0.5 ether;
        stakeAmounts[2] = 1 ether;
        stakeAmounts[3] = 5 ether;
        stakeAmounts[4] = 10 ether;
        stakeAmounts[5] = 50 ether;
        stakeAmounts[6] = 100 ether;
        stakeAmounts[7] = 500 ether;
        stakeAmounts[8] = 1000 ether;
        stakeAmounts[9] = 10000 ether;

        for (uint256 i = 0; i < stakeAmounts.length; i++) {
            _testStakeAmount(stakeAmounts[i]);
        }

        // Vary timing
        uint256[] memory timings = new uint256[](5);
        timings[0] = 1 hours;
        timings[1] = 1 days;
        timings[2] = 3 days;
        timings[3] = 7 days;
        timings[4] = 30 days;

        for (uint256 i = 0; i < timings.length; i++) {
            _testTiming(timings[i]);
        }
    }

    function _testStakeAmount(uint256 amount) internal {
        address initiator = users[0];
        address counterparty = users[1];

        try this.executeHappyPath(initiator, counterparty, amount) returns (string memory) {
            console.log("  Stake %s: SUCCESS", amount / 1e18);
        } catch Error(string memory reason) {
            console.log("  Stake %s: GRACEFUL ERROR - %s", amount / 1e18, reason);
        } catch {
            console.log("  Stake %s: FAILED", amount / 1e18);
        }
    }

    function _testTiming(uint256 waitTime) internal {
        address initiator = users[2];
        address counterparty = users[3];

        uint256 snapshot = vm.snapshotState();

        try this.executeTimingScenario(initiator, counterparty, waitTime) returns (string memory result) {
            console.log("  Wait %s hours: %s", waitTime / 1 hours, result);
        } catch Error(string memory reason) {
            console.log("  Wait %s hours: ERROR - %s", waitTime / 1 hours, reason);
        } catch {
            console.log("  Wait %s hours: FAILED", waitTime / 1 hours);
        }

        vm.revertToState(snapshot);
    }

    // Named execute* (not test*) so forge does not pick it up as a standalone fuzz test
    function executeTimingScenario(address initiator, address counterparty, uint256 waitTime) external returns (string memory) {
        vm.prank(initiator);
        uint256 disputeId = ilrm.initiateBreachDispute(counterparty, 1 ether, bytes32(0), defaultFallback);

        vm.warp(block.timestamp + waitTime);

        // Try to stake after waiting (stake window is inclusive of its end)
        if (waitTime <= ilrm.STAKE_WINDOW()) {
            vm.prank(counterparty);
            ilrm.depositStake(disputeId);
            return "Staked";
        } else {
            ilrm.enforceTimeout(disputeId);
            return "Timeout";
        }
    }

    // ============ Input Validation Edge Cases ============

    /**
     * @notice Test edge cases in input validation
     */
    function testInputValidationEdgeCases() public {
        console.log("");
        console.log("========================================");
        console.log("  Input Validation Edge Cases");
        console.log("========================================");

        // Test various invalid inputs
        _testInvalidEvidence();
        _testBoundaryStakes();
        _testStringInputs();
    }

    function _testInvalidEvidence() internal {
        address user = users[0];

        // Empty evidence hash (should work - it's just bytes32(0))
        vm.prank(user);
        try ilrm.initiateBreachDispute(users[1], 1 ether, bytes32(0), defaultFallback) {
            console.log("  Empty evidence hash: ACCEPTED");
        } catch {
            console.log("  Empty evidence hash: REJECTED");
        }

        // Max bytes32 value
        vm.prank(user);
        try ilrm.initiateBreachDispute(users[1], 1 ether, bytes32(type(uint256).max), defaultFallback) {
            console.log("  Max evidence hash: ACCEPTED");
        } catch {
            console.log("  Max evidence hash: REJECTED");
        }
    }

    function _testBoundaryStakes() internal {
        address user = users[0];

        // Minimum possible stake (1 wei)
        vm.prank(user);
        try ilrm.initiateBreachDispute(users[1], 1, bytes32(0), defaultFallback) {
            console.log("  1 wei stake: ACCEPTED");
        } catch {
            console.log("  1 wei stake: REJECTED");
        }

        // Very large stake
        token.mint(user, type(uint128).max);
        vm.prank(user);
        token.approve(address(ilrm), type(uint256).max);

        vm.prank(user);
        try ilrm.initiateBreachDispute(users[1], type(uint128).max, bytes32(0), defaultFallback) {
            console.log("  Max uint128 stake: ACCEPTED");
        } catch {
            console.log("  Max uint128 stake: REJECTED");
        }
    }

    function _testStringInputs() internal {
        // Test DID document hashes with various patterns
        bytes32[] memory testHashes = new bytes32[](5);
        testHashes[0] = bytes32(0); // Empty
        testHashes[1] = keccak256("short");
        testHashes[2] = keccak256("A much longer string with various characters !@#$%^&*()");
        testHashes[3] = keccak256(unicode"Unicode: 你好世界 🌍");
        testHashes[4] = bytes32(type(uint256).max);

        for (uint256 i = 0; i < testHashes.length; i++) {
            address user = users[10 + i];
            vm.prank(user);
            try didRegistry.registerDID(testHashes[i]) returns (bytes32) {
                console.log("  Hash pattern %s: DID REGISTERED", i);
            } catch {
                console.log("  Hash pattern %s: REJECTED", i);
            }
        }
    }

    // ============ Concurrent Operations ============

    /**
     * @notice Test concurrent dispute operations
     */
    function testConcurrentOperations() public {
        console.log("");
        console.log("========================================");
        console.log("  Concurrent Operations Test");
        console.log("========================================");

        // Create multiple disputes simultaneously
        uint256[] memory disputeIds = new uint256[](10);

        for (uint256 i = 0; i < 10; i++) {
            address initiator = users[i];
            address counterparty = users[(i + 10) % users.length];

            vm.prank(initiator);
            disputeIds[i] = ilrm.initiateBreachDispute(
                counterparty,
                (i + 1) * 1 ether,
                keccak256(abi.encodePacked("concurrent", i)),
                defaultFallback
            );

            console.log("  Dispute %s created by user %s", disputeIds[i], i);
        }

        // Stake on all disputes
        for (uint256 i = 0; i < 10; i++) {
            address counterparty = users[(i + 10) % users.length];
            vm.prank(counterparty);
            ilrm.depositStake(disputeIds[i]);
        }

        console.log("  All 10 disputes staked successfully");

        // Verify dispute count
        assertEq(ilrm.disputeCounter(), 10);
        console.log("  Total disputes verified: 10");
    }

    // ============ Helper Functions ============

    function _varyStake(uint256 seed) internal pure returns (uint256) {
        // Generate varying stake amounts based on seed
        uint256 base = (seed % 10) + 1;
        uint256 multiplier = 10 ** ((seed % 3) + 17); // 0.1 ether to 100 ether range
        return base * multiplier;
    }

    function _recordSuccess(uint256 id, string memory sType, string memory outcome, uint256 gas) internal {
        results.push(SimulationResult({
            scenarioId: id,
            scenarioType: sType,
            success: true,
            outcome: outcome,
            gasUsed: gas,
            errorMessage: ""
        }));
        successCount++;
    }

    function _recordGracefulError(uint256 id, string memory sType, string memory error, uint256 gas) internal {
        results.push(SimulationResult({
            scenarioId: id,
            scenarioType: sType,
            success: true, // Graceful = success in error handling
            outcome: "GracefulError",
            gasUsed: gas,
            errorMessage: error
        }));
        gracefulErrorCount++;
    }

    function _recordFailure(uint256 id, string memory sType, string memory error, uint256 gas) internal {
        results.push(SimulationResult({
            scenarioId: id,
            scenarioType: sType,
            success: false,
            outcome: "FAILURE",
            gasUsed: gas,
            errorMessage: error
        }));
        failureCount++;
    }

    function _printSummary() internal view {
        console.log("");
        console.log("========================================");
        console.log("  SIMULATION SUMMARY");
        console.log("========================================");
        console.log("  Total Scenarios:     ", results.length);
        console.log("  Successful:          ", successCount);
        console.log("  Graceful Errors:     ", gracefulErrorCount);
        console.log("  Failures:            ", failureCount);
        console.log("");

        // Calculate success rate
        uint256 successRate = ((successCount + gracefulErrorCount) * 100) / results.length;
        console.log("  Success Rate:        ", successRate, "%");
        console.log("");

        if (failureCount == 0) {
            console.log("  STATUS: ALL SCENARIOS HANDLED GRACEFULLY");
        } else {
            console.log("  STATUS: SOME SCENARIOS FAILED");
            console.log("  Review failure details above");
        }

        console.log("========================================");
    }

    function _uint2str(uint256 _i) internal pure returns (string memory) {
        if (_i == 0) return "0";
        uint256 j = _i;
        uint256 length;
        while (j != 0) {
            length++;
            j /= 10;
        }
        bytes memory bstr = new bytes(length);
        uint256 k = length;
        while (_i != 0) {
            k = k - 1;
            uint8 temp = (48 + uint8(_i - (_i / 10) * 10));
            bytes1 b1 = bytes1(temp);
            bstr[k] = b1;
            _i /= 10;
        }
        return string(bstr);
    }
}
