// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/ILRM.sol";
import "../contracts/Treasury.sol";
import "../contracts/Oracle.sol";
import "../contracts/L3Bridge.sol";
import "../contracts/AssetRegistry.sol";
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

// Minimal mock for AssetRegistry
contract MockAssetRegistryBench is IAssetRegistry {
    function freezeAssets(uint256, address) external override {}
    function unfreezeAssets(uint256, bytes calldata) external override {}
    function applyFallbackLicense(uint256, bytes32) external override {}
}

contract GasBenchmarks is Test {
    // Contracts
    ILRM public ilrm;
    Treasury public treasury;
    Oracle public oracle;
    BenchmarkToken public token;
    MockAssetRegistryBench public assetRegistry;

    // Test accounts
    address public initiator = address(0x1);
    address public counterparty = address(0x2);
    address public oracleSubmitter = address(0x3);

    // Constants
    uint256 constant STAKE_AMOUNT = 1 ether;
    bytes32 constant EVIDENCE_HASH = keccak256("evidence");
    bytes32 constant FALLBACK_TERMS = keccak256("fallback");

    function setUp() public {
        // Deploy mock token
        token = new BenchmarkToken();

        // Deploy mock asset registry
        assetRegistry = new MockAssetRegistryBench();

        // Deploy Treasury
        treasury = new Treasury(address(token));

        // Deploy ILRM
        ilrm = new ILRM(
            address(token),
            address(treasury),
            address(assetRegistry)
        );

        // Deploy Oracle
        oracle = new Oracle(address(ilrm));

        // Configure ILRM
        ilrm.setOracle(address(oracle));

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
            ILRM.FallbackLicense({
                termDuration: 365 days,
                royaltyCapBps: 500,
                termsHash: FALLBACK_TERMS
            })
        );
    }

    /// @notice Benchmark: Match stake (counterparty joins)
    function testGas_ILRM_matchStake() public {
        // Setup: Create dispute
        vm.prank(initiator);
        uint256 disputeId = ilrm.initiateBreachDispute(
            counterparty,
            STAKE_AMOUNT,
            EVIDENCE_HASH,
            ILRM.FallbackLicense({
                termDuration: 365 days,
                royaltyCapBps: 500,
                termsHash: FALLBACK_TERMS
            })
        );

        // Benchmark: Match stake
        vm.prank(counterparty);
        ilrm.matchStake(disputeId);
    }

    /// @notice Benchmark: Submit counter-proposal
    function testGas_ILRM_counterPropose() public {
        // Setup: Create and activate dispute
        vm.prank(initiator);
        uint256 disputeId = ilrm.initiateBreachDispute(
            counterparty,
            STAKE_AMOUNT,
            EVIDENCE_HASH,
            ILRM.FallbackLicense({
                termDuration: 365 days,
                royaltyCapBps: 500,
                termsHash: FALLBACK_TERMS
            })
        );

        vm.prank(counterparty);
        ilrm.matchStake(disputeId);

        // Submit initial proposal
        vm.prank(oracleSubmitter);
        oracle.submitProposal(disputeId, "Initial proposal");

        // Fund counter fee
        token.mint(counterparty, 1 ether);

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
            ILRM.FallbackLicense({
                termDuration: 365 days,
                royaltyCapBps: 500,
                termsHash: FALLBACK_TERMS
            })
        );

        vm.prank(counterparty);
        ilrm.matchStake(disputeId);

        vm.prank(oracleSubmitter);
        oracle.submitProposal(disputeId, "Proposal to accept");

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
            ILRM.FallbackLicense({
                termDuration: 365 days,
                royaltyCapBps: 500,
                termsHash: FALLBACK_TERMS
            })
        );

        vm.prank(counterparty);
        ilrm.matchStake(disputeId);

        // Advance time past resolution timeout
        vm.warp(block.timestamp + 8 days);

        // Benchmark: Enforce timeout
        ilrm.enforceTimeout(disputeId);
    }

    // =========================================================================
    // Treasury Gas Benchmarks
    // =========================================================================

    /// @notice Benchmark: Distribute subsidy
    function testGas_Treasury_distributeSubsidy() public {
        // Fund treasury
        token.mint(address(treasury), 100 ether);

        // Setup recipient
        address recipient = address(0x4);

        // Benchmark: Distribute subsidy
        treasury.distributeSubsidy(recipient, 1 ether, "dispute_refund");
    }

    /// @notice Benchmark: Record burn
    function testGas_Treasury_recordBurn() public {
        // Benchmark: Record burn
        treasury.recordBurn(1 ether, "timeout_burn");
    }

    // =========================================================================
    // Oracle Gas Benchmarks
    // =========================================================================

    /// @notice Benchmark: Submit LLM proposal
    function testGas_Oracle_submitProposal() public {
        // Setup: Create and activate dispute
        vm.prank(initiator);
        uint256 disputeId = ilrm.initiateBreachDispute(
            counterparty,
            STAKE_AMOUNT,
            EVIDENCE_HASH,
            ILRM.FallbackLicense({
                termDuration: 365 days,
                royaltyCapBps: 500,
                termsHash: FALLBACK_TERMS
            })
        );

        vm.prank(counterparty);
        ilrm.matchStake(disputeId);

        // Benchmark: Submit proposal
        vm.prank(oracleSubmitter);
        oracle.submitProposal(disputeId, "This is a proposal for resolving the intellectual property dispute between the parties. The proposed terms include a royalty rate of 5% and a term of 2 years.");
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
                ILRM.FallbackLicense({
                    termDuration: 365 days,
                    royaltyCapBps: 500,
                    termsHash: FALLBACK_TERMS
                })
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
            ILRM.FallbackLicense({
                termDuration: 365 days,
                royaltyCapBps: 500,
                termsHash: FALLBACK_TERMS
            })
        );

        // Benchmark view call
        ilrm.getDispute(disputeId);
    }
}
