// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/ILRM.sol";
import "../contracts/interfaces/IILRM.sol";
import "../contracts/interfaces/IAssetRegistry.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockToken - Test ERC20 token
 */
contract MockToken is ERC20 {
    constructor() ERC20("NatLangChain", "NLC") {
        _mint(msg.sender, 1_000_000 ether);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title MockAssetRegistry - Minimal asset registry for testing
 */
contract MockAssetRegistry is IAssetRegistry {
    mapping(uint256 => bool) public frozen;
    mapping(uint256 => bytes32) public appliedFallbacks;

    function registerAsset(bytes32, address, bytes32) external pure override {}

    function freezeAssets(uint256 disputeId, address) external override {
        frozen[disputeId] = true;
        emit AssetsFrozen(disputeId, msg.sender, new bytes32[](0));
    }

    function unfreezeAssets(uint256 disputeId, bytes calldata outcome) external override {
        frozen[disputeId] = false;
        emit AssetsUnfrozen(disputeId, outcome);
    }

    function applyFallbackLicense(uint256 disputeId, bytes32 termsHash) external override {
        appliedFallbacks[disputeId] = termsHash;
        emit FallbackLicenseApplied(disputeId, termsHash, new bytes32[](0));
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

/**
 * @title ILRMTest - Unit tests for ILRM contract
 * @dev Tests all invariants from Protocol-Safety-Invariants.md
 */
contract ILRMTest is Test {
    ILRM public ilrm;
    MockToken public token;
    MockAssetRegistry public registry;

    address public oracle = address(0x1);
    address public initiator = address(0x2);
    address public counterparty = address(0x3);

    uint256 public constant STAKE_AMOUNT = 1 ether;
    bytes32 public constant EVIDENCE_HASH = keccak256("test evidence");

    event DisputeInitiated(uint256 indexed disputeId, address indexed initiator, address indexed counterparty, bytes32 evidenceHash);
    event StakeDeposited(uint256 indexed disputeId, address indexed depositor, uint256 amount);
    event DisputeResolved(uint256 indexed disputeId, IILRM.DisputeOutcome outcome);

    function setUp() public {
        token = new MockToken();
        registry = new MockAssetRegistry();
        ilrm = new ILRM(token, oracle, registry);

        // Fund test accounts
        token.mint(initiator, 100 ether);
        token.mint(counterparty, 100 ether);

        // Approve ILRM to spend tokens
        vm.prank(initiator);
        token.approve(address(ilrm), type(uint256).max);

        vm.prank(counterparty);
        token.approve(address(ilrm), type(uint256).max);
    }

    // ============ Invariant 1: No Unilateral Cost Imposition ============

    function test_InitiatorMustStakeFirst() public {
        IILRM.FallbackLicense memory fallback = IILRM.FallbackLicense({
            termsHash: keccak256("fallback"),
            duration: 30 days,
            royaltyCap: 500,
            nonExclusive: true
        });

        uint256 initiatorBalanceBefore = token.balanceOf(initiator);

        vm.prank(initiator);
        uint256 disputeId = ilrm.initiateBreachDispute(counterparty, STAKE_AMOUNT, EVIDENCE_HASH, fallback);

        // Initiator's stake is taken immediately
        assertEq(token.balanceOf(initiator), initiatorBalanceBefore - STAKE_AMOUNT);

        // Counterparty has no exposure yet
        (,, uint256 initiatorStake, uint256 counterpartyStake,,,,,,,,,) = ilrm.disputes(disputeId);
        assertEq(initiatorStake, STAKE_AMOUNT);
        assertEq(counterpartyStake, 0);
    }

    // ============ Invariant 2: Silence Is Always Free ============

    function test_CounterpartyCanIgnoreDispute() public {
        IILRM.FallbackLicense memory fallback = IILRM.FallbackLicense({
            termsHash: keccak256("fallback"),
            duration: 30 days,
            royaltyCap: 500,
            nonExclusive: true
        });

        vm.prank(initiator);
        uint256 disputeId = ilrm.initiateBreachDispute(counterparty, STAKE_AMOUNT, EVIDENCE_HASH, fallback);

        uint256 counterpartyBalanceBefore = token.balanceOf(counterparty);

        // Warp past stake window
        vm.warp(block.timestamp + 4 days);

        // Counterparty never staked - resolve via timeout
        ilrm.enforceTimeout(disputeId);

        // Counterparty lost nothing
        assertEq(token.balanceOf(counterparty), counterpartyBalanceBefore);
    }

    // ============ Invariant 4: Bounded Griefing ============

    function test_MaxThreeCounters() public {
        IILRM.FallbackLicense memory fallback = IILRM.FallbackLicense({
            termsHash: keccak256("fallback"),
            duration: 30 days,
            royaltyCap: 500,
            nonExclusive: true
        });

        vm.prank(initiator);
        uint256 disputeId = ilrm.initiateBreachDispute(counterparty, STAKE_AMOUNT, EVIDENCE_HASH, fallback);

        vm.prank(counterparty);
        ilrm.depositStake(disputeId);

        // Submit 3 counters (max allowed)
        for (uint256 i = 0; i < 3; i++) {
            uint256 fee = 0.01 ether * (1 << i); // Exponential fee
            vm.deal(initiator, fee);
            vm.prank(initiator);
            ilrm.counterPropose{value: fee}(disputeId, keccak256(abi.encode("evidence", i)));
        }

        // 4th counter should fail
        vm.deal(initiator, 1 ether);
        vm.prank(initiator);
        vm.expectRevert("Max counters reached");
        ilrm.counterPropose{value: 0.08 ether}(disputeId, keccak256("fourth"));
    }

    // ============ Invariant 6: Mutuality or Exit ============

    function test_TimeoutResolvesDispute() public {
        IILRM.FallbackLicense memory fallback = IILRM.FallbackLicense({
            termsHash: keccak256("fallback"),
            duration: 30 days,
            royaltyCap: 500,
            nonExclusive: true
        });

        vm.prank(initiator);
        uint256 disputeId = ilrm.initiateBreachDispute(counterparty, STAKE_AMOUNT, EVIDENCE_HASH, fallback);

        vm.prank(counterparty);
        ilrm.depositStake(disputeId);

        // Warp past resolution timeout
        vm.warp(block.timestamp + 8 days);

        ilrm.enforceTimeout(disputeId);

        (,,,,,,,,,bool resolved, IILRM.DisputeOutcome outcome,,) = ilrm.disputes(disputeId);
        assertTrue(resolved);
        assertEq(uint256(outcome), uint256(IILRM.DisputeOutcome.TimeoutWithBurn));
    }

    // ============ Invariant 8: Economic Symmetry by Default ============

    function test_SymmetricStakes() public {
        IILRM.FallbackLicense memory fallback = IILRM.FallbackLicense({
            termsHash: keccak256("fallback"),
            duration: 30 days,
            royaltyCap: 500,
            nonExclusive: true
        });

        vm.prank(initiator);
        uint256 disputeId = ilrm.initiateBreachDispute(counterparty, STAKE_AMOUNT, EVIDENCE_HASH, fallback);

        vm.prank(counterparty);
        ilrm.depositStake(disputeId);

        (,, uint256 initiatorStake, uint256 counterpartyStake,,,,,,,,,) = ilrm.disputes(disputeId);
        assertEq(initiatorStake, counterpartyStake, "Stakes must be symmetric");
    }

    // ============ Mutual Acceptance Resolution ============

    function test_MutualAcceptanceReturnsStakes() public {
        IILRM.FallbackLicense memory fallback = IILRM.FallbackLicense({
            termsHash: keccak256("fallback"),
            duration: 30 days,
            royaltyCap: 500,
            nonExclusive: true
        });

        vm.prank(initiator);
        uint256 disputeId = ilrm.initiateBreachDispute(counterparty, STAKE_AMOUNT, EVIDENCE_HASH, fallback);

        vm.prank(counterparty);
        ilrm.depositStake(disputeId);

        // Oracle submits proposal
        vm.prank(oracle);
        ilrm.submitLLMProposal(disputeId, '{"proposal": "split 50/50"}', "");

        uint256 initiatorBalanceBefore = token.balanceOf(initiator);
        uint256 counterpartyBalanceBefore = token.balanceOf(counterparty);

        // Both accept
        vm.prank(initiator);
        ilrm.acceptProposal(disputeId);

        vm.prank(counterparty);
        ilrm.acceptProposal(disputeId);

        // Both get stakes back
        assertEq(token.balanceOf(initiator), initiatorBalanceBefore + STAKE_AMOUNT);
        assertEq(token.balanceOf(counterparty), counterpartyBalanceBefore + STAKE_AMOUNT);

        (,,,,,,,,,bool resolved, IILRM.DisputeOutcome outcome,,) = ilrm.disputes(disputeId);
        assertTrue(resolved);
        assertEq(uint256(outcome), uint256(IILRM.DisputeOutcome.AcceptedProposal));
    }

    // ============ Fallback License Validation ============

    function test_FallbackMustBeNonExclusive() public {
        IILRM.FallbackLicense memory exclusiveFallback = IILRM.FallbackLicense({
            termsHash: keccak256("exclusive"),
            duration: 30 days,
            royaltyCap: 500,
            nonExclusive: false // Invalid per spec
        });

        vm.prank(initiator);
        vm.expectRevert("Fallback must be non-exclusive");
        ilrm.initiateBreachDispute(counterparty, STAKE_AMOUNT, EVIDENCE_HASH, exclusiveFallback);
    }
}
