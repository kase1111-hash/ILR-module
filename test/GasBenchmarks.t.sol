// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/ILRM.sol";
import "../contracts/Treasury.sol";
import "../contracts/Oracle.sol";
import "../contracts/AssetRegistry.sol";
import "../contracts/interfaces/IOracle.sol";
import "../contracts/interfaces/IAssetRegistry.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title Gas Benchmarks
 * @notice Measures gas costs for critical protocol operations
 * @dev Run with: forge test --match-contract GasBenchmarks --gas-report
 */

// Mock token for testing
contract BenchmarkToken is ERC20 {
    constructor() ERC20("Benchmark Token", "BENCH") {
        _mint(msg.sender, 1_000_000_000 ether);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// Mock oracle that auto-verifies signatures
contract MockOracleBench is IOracle {
    address public override ilrmContract;

    function setILRM(address _ilrm) external {
        ilrmContract = _ilrm;
    }

    function requestProposal(uint256, bytes32) external override {}

    function submitProposal(
        uint256 disputeId,
        string calldata proposal,
        bytes calldata signature
    ) external override {
        IILRM(ilrmContract).submitLLMProposal(disputeId, proposal, signature);
    }

    function verifySignature(uint256, bytes32, bytes calldata) external pure override returns (bool) {
        return true;
    }

    function isOracle(address) external pure override returns (bool) {
        return true;
    }

    function oraclePublicKeyHash(address) external pure override returns (bytes32) {
        return bytes32(0);
    }
}

// Minimal mock for AssetRegistry
contract MockAssetRegistryBench is IAssetRegistry {
    function registerAsset(bytes32, address, bytes32) external override {}
    function freezeAssets(uint256, address) external override {}
    function unfreezeAssets(uint256, bytes calldata) external override {}
    function applyFallbackLicense(uint256, bytes32) external override {}
    function grantLicense(bytes32, address, bytes32, uint256, uint256, bool) external override {}
    function revokeLicense(bytes32, address) external override {}

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

contract GasBenchmarks is Test {
    // Contracts
    ILRM public ilrm;
    NatLangChainTreasury public treasury;
    MockOracleBench public oracle;
    BenchmarkToken public token;
    MockAssetRegistryBench public assetRegistry;

    // Test accounts
    address public initiator = address(0x1);
    address public counterparty = address(0x2);

    // Constants
    uint256 constant STAKE_AMOUNT = 1 ether;
    bytes32 constant EVIDENCE_HASH = keccak256("evidence");
    bytes32 constant FALLBACK_TERMS = keccak256("fallback");

    IILRM.FallbackLicense fallbackLicense;

    function setUp() public {
        // Deploy mock token
        token = new BenchmarkToken();

        // Deploy mock oracle and asset registry
        oracle = new MockOracleBench();
        assetRegistry = new MockAssetRegistryBench();

        // Deploy ILRM with mock oracle address
        ilrm = new ILRM(
            IERC20(address(token)),
            address(oracle),
            IAssetRegistry(address(assetRegistry))
        );

        // Configure mock oracle
        oracle.setILRM(address(ilrm));

        // Deploy Treasury
        treasury = new NatLangChainTreasury(
            IERC20(address(token)),
            1 ether,        // maxPerDispute
            10 ether,       // maxPerParticipant
            30 days         // windowDuration
        );
        treasury.setILRM(address(ilrm));

        // Set up fallback license
        fallbackLicense = IILRM.FallbackLicense({
            termsHash: FALLBACK_TERMS,
            termDuration: 365 days,
            royaltyCapBps: 500,
            nonExclusive: true
        });

        // Fund test accounts
        token.mint(initiator, 100 ether);
        token.mint(counterparty, 100 ether);

        // Approve ILRM
        vm.prank(initiator);
        token.approve(address(ilrm), type(uint256).max);

        vm.prank(counterparty);
        token.approve(address(ilrm), type(uint256).max);
    }

    // =========================================================================
    // ILRM Gas Benchmarks
    // =========================================================================

    /// @notice Benchmark: Initiate breach dispute
    function testGas_ILRM_initiateBreachDispute() public {
        vm.prank(initiator);
        ilrm.initiateBreachDispute(
            counterparty,
            STAKE_AMOUNT,
            EVIDENCE_HASH,
            fallbackLicense
        );
    }

    /// @notice Benchmark: Deposit stake (counterparty joins)
    function testGas_ILRM_depositStake() public {
        // Setup: Create dispute
        vm.prank(initiator);
        uint256 disputeId = ilrm.initiateBreachDispute(
            counterparty,
            STAKE_AMOUNT,
            EVIDENCE_HASH,
            fallbackLicense
        );

        // Benchmark: Deposit stake
        vm.prank(counterparty);
        ilrm.depositStake(disputeId);
    }

    /// @notice Benchmark: Submit counter-proposal
    function testGas_ILRM_counterPropose() public {
        // Setup: Create and activate dispute
        vm.prank(initiator);
        uint256 disputeId = ilrm.initiateBreachDispute(
            counterparty,
            STAKE_AMOUNT,
            EVIDENCE_HASH,
            fallbackLicense
        );

        vm.prank(counterparty);
        ilrm.depositStake(disputeId);

        // Submit initial proposal via mock oracle
        vm.prank(address(oracle));
        ilrm.submitLLMProposal(disputeId, "Initial proposal", "");

        // Fund counter fee
        vm.deal(counterparty, 1 ether);

        // Benchmark: Counter-propose
        vm.prank(counterparty);
        ilrm.counterPropose{value: 0.01 ether}(disputeId, keccak256("counter evidence"));
    }

    /// @notice Benchmark: Accept proposal
    function testGas_ILRM_acceptProposal() public {
        // Setup: Create, activate, and get proposal
        vm.prank(initiator);
        uint256 disputeId = ilrm.initiateBreachDispute(
            counterparty,
            STAKE_AMOUNT,
            EVIDENCE_HASH,
            fallbackLicense
        );

        vm.prank(counterparty);
        ilrm.depositStake(disputeId);

        vm.prank(address(oracle));
        ilrm.submitLLMProposal(disputeId, "Proposal to accept", "");

        // Initiator accepts
        vm.prank(initiator);
        ilrm.acceptProposal(disputeId);

        // Benchmark: Counterparty accepts (triggers resolution)
        vm.prank(counterparty);
        ilrm.acceptProposal(disputeId);
    }

    /// @notice Benchmark: Enforce timeout
    function testGas_ILRM_enforceTimeout() public {
        // Setup: Create and activate dispute
        vm.prank(initiator);
        uint256 disputeId = ilrm.initiateBreachDispute(
            counterparty,
            STAKE_AMOUNT,
            EVIDENCE_HASH,
            fallbackLicense
        );

        vm.prank(counterparty);
        ilrm.depositStake(disputeId);

        // Advance time past resolution timeout
        vm.warp(block.timestamp + 8 days);

        // Benchmark: Enforce timeout
        ilrm.enforceTimeout(disputeId);
    }

    // =========================================================================
    // Treasury Gas Benchmarks
    // =========================================================================

    /// @notice Benchmark: Deposit to treasury
    function testGas_Treasury_deposit() public {
        token.mint(address(this), 100 ether);
        token.approve(address(treasury), type(uint256).max);

        treasury.deposit(1 ether, "benchmark_deposit");
    }

    /// @notice Benchmark: Request subsidy
    function testGas_Treasury_requestSubsidy() public {
        // Fund treasury
        token.mint(address(treasury), 100 ether);

        // Create a dispute so counterparty can request subsidy
        vm.prank(initiator);
        uint256 disputeId = ilrm.initiateBreachDispute(
            counterparty,
            STAKE_AMOUNT,
            EVIDENCE_HASH,
            fallbackLicense
        );

        // Benchmark: Counterparty requests subsidy
        vm.prank(counterparty);
        treasury.requestSubsidy(disputeId, STAKE_AMOUNT, counterparty);
    }

    // =========================================================================
    // Batch Operations Gas Benchmarks
    // =========================================================================

    /// @notice Benchmark: Multiple dispute initiations
    function testGas_Batch_multipleInitiations() public {
        for (uint256 i = 0; i < 10; i++) {
            address cp = address(uint160(100 + i));
            token.mint(initiator, STAKE_AMOUNT);

            vm.prank(initiator);
            ilrm.initiateBreachDispute(
                cp,
                STAKE_AMOUNT,
                keccak256(abi.encode("evidence", i)),
                fallbackLicense
            );
        }
    }

    // =========================================================================
    // View Function Gas Benchmarks (Informational)
    // =========================================================================

    /// @notice Benchmark: Get dispute details
    function testGas_ILRM_getDispute() public {
        vm.prank(initiator);
        uint256 disputeId = ilrm.initiateBreachDispute(
            counterparty,
            STAKE_AMOUNT,
            EVIDENCE_HASH,
            fallbackLicense
        );

        // Benchmark view call
        ilrm.disputes(disputeId);
    }
}
