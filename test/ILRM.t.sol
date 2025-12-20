// test/ILRM.t.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/ILRM.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Mock ERC20 token
contract MockToken is ERC20 {
    constructor() ERC20("StakeToken", "STK") {
        _mint(msg.sender, 1_000_000 ether);
    }
}

// Mock Asset Registry
contract MockAssetRegistry is IAssetRegistry {
    mapping(uint256 => bool) public frozen;
    mapping(uint256 => bytes32) public appliedFallback;
    bytes public lastExecutionData;

    function freezeAssets(uint256 disputeId, address) external override {
        frozen[disputeId] = true;
    }

    function unfreezeAssets(uint256 disputeId, bytes calldata executionData) external override {
        frozen[disputeId] = false;
        lastExecutionData = executionData;
    }

    function applyFallbackLicense(uint256 disputeId, bytes32 termsHash) external override {
        appliedFallback[disputeId] = termsHash;
    }
}

// Mock Oracle (simplified)
contract MockOracle {
    ILRM public ilrm;

    constructor(ILRM _ilrm) {
        ilrm = _ilrm;
    }

    function submitProposal(uint256 disputeId, string memory proposal) external {
        ilrm.submitLLMProposal(disputeId, proposal);
    }
}

contract ILRMTest is Test {
    ILRM ilrm;
    MockToken token;
    MockAssetRegistry registry;
    MockOracle oracle;

    address initiator = address(0x1);
    address counterparty = address(0x2);
    uint256 constant STAKE = 10 ether;

    ILRM.FallbackLicense fallback = ILRM.FallbackLicense({
        nonExclusive: true,
        termDuration: 365 days,
        royaltyCapBps: 500,
        termsHash: bytes32(uint256(0xabc))
    });

    function setUp() public {
        token = new MockToken();
        registry = new MockAssetRegistry();
        oracle = new MockOracle(ILRM(address(0))); // Temp
        ilrm = new ILRM(IERC20(token), address(oracle), registry);
        oracle = new MockOracle(ilrm); // Fix reference

        vm.startPrank(initiator);
        token.approve(address(ilrm), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(counterparty);
        token.approve(address(ilrm), type(uint256).max);
        vm.stopPrank();

        token.transfer(initiator, 1000 ether);
        token.transfer(counterparty, 1000 ether);
    }

    function testInitiateBreachDispute() public {
        vm.prank(initiator);
        uint256 disputeId = ilrm.initiateBreachDispute(
            counterparty,
            STAKE,
            bytes32(uint256(0x123)),
            fallback
        );

        assertEq(uint256(ilrm.disputeCounter()), 1);
        ILRM.Dispute memory d = ilrm.disputes(disputeId);
        assertEq(d.initiator, initiator);
        assertEq(d.counterparty, counterparty);
        assertEq(d.initiatorStake, STAKE);
        assertTrue(registry.frozen(disputeId));
    }

    function testFullResolutionAccepted() public {
        uint256 disputeId = _initiateDispute();

        // Counterparty stakes
        vm.prank(counterparty);
        ilrm.depositStake(disputeId);

        // Oracle submits proposal
        vm.prank(address(oracle));
        ilrm.submitLLMProposal(disputeId, "Royalty split 50/50");

        // Both accept
        vm.prank(initiator);
        ilrm.acceptProposal(disputeId);
        vm.prank(counterparty);
        ilrm.acceptProposal(disputeId);

        ILRM.Dispute memory d = ilrm.disputes(disputeId);
        assertTrue(d.resolved);
        assertEq(uint256(d.outcome), uint256(ILRM.DisputeOutcome.AcceptedProposal));
        assertEq(token.balanceOf(initiator), 1000 ether); // Stakes returned
        assertEq(token.balanceOf(counterparty), 1000 ether);
        assertFalse(registry.frozen(disputeId));
    }

    function testTimeoutWithBurn() public {
        uint256 disputeId = _initiateDispute();

        vm.prank(counterparty);
        ilrm.depositStake(disputeId);

        vm.warp(block.timestamp + 8 days); // Past timeout
        ilrm.enforceTimeout(disputeId);

        ILRM.Dispute memory d = ilrm.disputes(disputeId);
        assertTrue(d.resolved);
        assertEq(uint256(d.outcome), uint256(ILRM.DisputeOutcome.TimeoutWithBurn));
        assertEq(token.balanceOf(initiator), 995 ether); // 5 ether each returned (50% burned)
        assertEq(token.balanceOf(counterparty), 995 ether);
        assertEq(registry.appliedFallback(disputeId), fallback.termsHash);
    }

    function testDefaultLicenseAppliedNoStake() public {
        uint256 disputeId = _initiateDispute();

        vm.warp(block.timestamp + 4 days); // Past stake window
        ilrm.enforceTimeout(disputeId);

        ILRM.Dispute memory d = ilrm.disputes(disputeId);
        assertTrue(d.resolved);
        assertEq(uint256(d.outcome), uint256(ILRM.DisputeOutcome.DefaultLicenseApplied));
        assertEq(token.balanceOf(initiator), 1001 ether); // Stake + 10% incentive
        assertEq(registry.appliedFallback(disputeId), fallback.termsHash);
    }

    function testCounterProposals() public {
        uint256 disputeId = _initiateDispute();
        vm.prank(counterparty);
        ilrm.depositStake(disputeId);

        // First counter
        vm.prank(initiator);
        ilrm.counterPropose{value: 0.01 ether}(disputeId, bytes32(uint256(0x456)));

        // Second
        vm.prank(counterparty);
        ilrm.counterPropose{value: 0.02 ether}(disputeId, bytes32(uint256(0x789)));

        // Third
        vm.prank(initiator);
        ilrm.counterPropose{value: 0.04 ether}(disputeId, bytes32(uint256(0xabc)));

        // Fourth should revert
        vm.expectRevert("Max counters");
        vm.prank(counterparty);
        ilrm.counterPropose{value: 0.08 ether}(disputeId, bytes32(uint256(0xdef)));
    }

    function testVoluntaryRequest() public {
        uint256 balanceBefore = initiator.balance;

        vm.prank(initiator);
        ilrm.initiateVoluntaryRequest{value: 0.01 ether}(counterparty, bytes32(uint256(0x999)));

        assertEq(initiator.balance, balanceBefore - 0.01 ether); // Burned
    }

    function testEscalationAndCooldown() public {
        _initiateDispute();

        // Second dispute within cooldown
        vm.prank(initiator);
        vm.expectRevert(); // Stake too low (needs 1.5x)
        ilrm.initiateBreachDispute(counterparty, STAKE, bytes32(uint256(0x222)), fallback);

        // With escalated stake
        vm.prank(initiator);
        ilrm.initiateBreachDispute(counterparty, STAKE * 150 / 100, bytes32(uint256(0x222)), fallback);
    }

    // Helper
    function _initiateDispute() internal returns (uint256) {
        vm.prank(initiator);
        return ilrm.initiateBreachDispute(
            counterparty,
            STAKE,
            bytes32(uint256(0x123)),
            fallback
        );
    }
}
