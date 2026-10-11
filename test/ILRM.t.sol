// test/ILRM.t.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/ILRM.sol";
import "../contracts/mocks/MockAssetRegistry.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Mock ERC20 token
contract MockToken is ERC20 {
    constructor() ERC20("StakeToken", "STK") {
        _mint(msg.sender, 1_000_000 ether);
    }
}

// Mock Oracle (simplified): accepts any signature and relays proposals to ILRM
contract MockOracle {
    ILRM public ilrm;

    function setILRM(ILRM _ilrm) external {
        ilrm = _ilrm;
    }

    function verifySignature(uint256, bytes32, bytes calldata) external pure returns (bool) {
        return true;
    }

    function submitProposal(uint256 disputeId, string memory proposal) external {
        ilrm.submitLLMProposal(disputeId, proposal, "");
    }
}

contract ILRMTest is Test {
    ILRM ilrm;
    MockToken token;
    MockAssetRegistry registry;
    MockOracle oracle;

    address initiator = makeAddr("initiator");
    address counterparty = makeAddr("counterparty");
    uint256 constant STAKE = 10 ether;

    IILRM.FallbackLicense fallbackLicense = IILRM.FallbackLicense({
        nonExclusive: true,
        termDuration: 365 days,
        royaltyCapBps: 500,
        termsHash: bytes32(uint256(0xabc))
    });

    function setUp() public {
        token = new MockToken();
        registry = new MockAssetRegistry();
        oracle = new MockOracle();
        ilrm = new ILRM(IERC20(token), address(oracle), registry);
        oracle.setILRM(ilrm);

        vm.startPrank(initiator);
        token.approve(address(ilrm), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(counterparty);
        token.approve(address(ilrm), type(uint256).max);
        vm.stopPrank();

        token.transfer(initiator, 1000 ether);
        token.transfer(counterparty, 1000 ether);

        vm.deal(initiator, 1 ether);
        vm.deal(counterparty, 1 ether);
    }

    function testInitiateBreachDispute() public {
        vm.prank(initiator);
        uint256 disputeId = ilrm.initiateBreachDispute(
            counterparty,
            STAKE,
            bytes32(uint256(0x123)),
            fallbackLicense
        );

        assertEq(uint256(ilrm.disputeCounter()), 1);
        IILRM.Dispute memory d = ilrm.disputes(disputeId);
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
        oracle.submitProposal(disputeId, "Royalty split 50/50");

        // Both accept
        vm.prank(initiator);
        ilrm.acceptProposal(disputeId);
        vm.prank(counterparty);
        ilrm.acceptProposal(disputeId);

        IILRM.Dispute memory d = ilrm.disputes(disputeId);
        assertTrue(d.resolved);
        assertEq(uint256(d.outcome), uint256(IILRM.DisputeOutcome.AcceptedProposal));
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

        IILRM.Dispute memory d = ilrm.disputes(disputeId);
        assertTrue(d.resolved);
        assertEq(uint256(d.outcome), uint256(IILRM.DisputeOutcome.TimeoutWithBurn));
        assertEq(token.balanceOf(initiator), 995 ether); // 5 ether each returned (50% burned)
        assertEq(token.balanceOf(counterparty), 995 ether);
        assertEq(registry.appliedFallbacks(disputeId), fallbackLicense.termsHash);
    }

    function testDefaultLicenseAppliedNoStake() public {
        // Fund the initiator incentive pool
        token.approve(address(ilrm), 100 ether);
        ilrm.depositTokenReserves(100 ether);

        uint256 disputeId = _initiateDispute();

        vm.warp(block.timestamp + 4 days); // Past stake window
        ilrm.enforceTimeout(disputeId);

        IILRM.Dispute memory d = ilrm.disputes(disputeId);
        assertTrue(d.resolved);
        assertEq(uint256(d.outcome), uint256(IILRM.DisputeOutcome.DefaultLicenseApplied));
        assertEq(token.balanceOf(initiator), 1001 ether); // Stake + 10% incentive
        assertEq(registry.appliedFallbacks(disputeId), fallbackLicense.termsHash);
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
        vm.expectRevert("Max counters reached");
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

        // Second dispute within cooldown is charged 1.5x the requested stake
        uint256 balanceBefore = token.balanceOf(initiator);
        vm.prank(initiator);
        uint256 secondId =
            ilrm.initiateBreachDispute(counterparty, STAKE, bytes32(uint256(0x222)), fallbackLicense);

        assertEq(ilrm.disputes(secondId).initiatorStake, STAKE * 150 / 100);
        assertEq(token.balanceOf(initiator), balanceBefore - STAKE * 150 / 100);

        // After the cooldown, stakes are no longer escalated
        vm.warp(block.timestamp + ilrm.COOLDOWN_PERIOD() + 1);
        vm.prank(initiator);
        uint256 thirdId =
            ilrm.initiateBreachDispute(counterparty, STAKE, bytes32(uint256(0x333)), fallbackLicense);
        assertEq(ilrm.disputes(thirdId).initiatorStake, STAKE);
    }

    // Helper
    function _initiateDispute() internal returns (uint256) {
        vm.prank(initiator);
        return ilrm.initiateBreachDispute(
            counterparty,
            STAKE,
            bytes32(uint256(0x123)),
            fallbackLicense
        );
    }
}
