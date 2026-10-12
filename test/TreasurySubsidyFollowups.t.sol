// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/ILRM.sol";
import "../contracts/Treasury.sol";
import "../contracts/mocks/MockAssetRegistry.sol";
import "../contracts/mocks/MockOracle.sol";
import "../contracts/mocks/MockToken.sol";

/// @notice Fails loudly if ILRM ever calls it
contract RevertIfCalledTreasury is ISubsidyTreasury {
    error TreasuryCalled();

    function fundStakeSubsidy(uint256, address, uint256) external pure returns (uint256) {
        revert TreasuryCalled();
    }
}

/**
 * @title TreasurySubsidyFollowupsTest
 * @notice The maxTopUp slippage bound of ILRM.depositStakeWithSubsidy, Treasury subsidy records keyed per
 *         (ILRM, disputeId), and subsidized disputes that go through counter-proposal rounds or time out with
 *         token reserves funded.
 */
contract TreasurySubsidyFollowupsTest is Test {
    ILRM internal ilrm;
    NatLangChainTreasury internal treasury;
    MockToken internal token;
    MockAssetRegistry internal registry;
    MockOracle internal oracle;

    address internal initiator = makeAddr("initiator");
    address internal defender = makeAddr("defender");

    address internal constant BURN = 0x000000000000000000000000000000000000dEaD;

    uint256 internal constant MAX_PER_DISPUTE = 100 ether;
    uint256 internal constant MAX_PER_PARTICIPANT = 1000 ether;
    uint256 internal constant WINDOW = 30 days;
    uint256 internal constant TREASURY_FUNDS = 10_000 ether;
    uint256 internal constant STAKE = 10 ether;

    IILRM.FallbackLicense internal fallbackLicense = IILRM.FallbackLicense({
        termsHash: keccak256("fallback"), termDuration: 365 days, royaltyCapBps: 500, nonExclusive: true
    });

    event InitiatorIncentivePaid(
        uint256 indexed disputeId, address indexed initiator, uint256 amount, uint256 uncappedAmount
    );

    function setUp() public {
        token = new MockToken(); // mints 1_000_000 ether to this contract (funds tokenReserves)
        registry = new MockAssetRegistry();
        oracle = new MockOracle();
        ilrm = new ILRM(IERC20(address(token)), address(oracle), registry);
        treasury = new NatLangChainTreasury(IERC20(address(token)), MAX_PER_DISPUTE, MAX_PER_PARTICIPANT, WINDOW);
        treasury.setILRM(address(ilrm));
        ilrm.setSubsidyTreasury(address(treasury));

        token.mint(address(treasury), TREASURY_FUNDS);
        token.approve(address(ilrm), type(uint256).max);
        token.mint(initiator, 1_000_000 ether);
        vm.prank(initiator);
        token.approve(address(ilrm), type(uint256).max);
        vm.prank(defender);
        token.approve(address(ilrm), type(uint256).max); // unlimited allowance: only maxTopUp bounds the charge
    }

    // =========================================================================
    // maxTopUp slippage bound
    // =========================================================================

    function test_MaxTopUp_ExactBoundSucceeds() public {
        uint256 stake = MAX_PER_DISPUTE + 50 ether; // grant 100, top-up 50
        token.mint(defender, 50 ether);
        uint256 id = _open(defender, stake);

        vm.prank(defender);
        ilrm.depositStakeWithSubsidy(id, type(uint256).max, 50 ether);

        assertEq(token.balanceOf(defender), 0, "paid exactly the bound");
        (, uint256 granted) = ilrm.stakeSubsidy(id);
        assertEq(granted, MAX_PER_DISPUTE);
        assertEq(ilrm.disputes(id).counterpartyStake, stake);
        assertEq(token.balanceOf(address(ilrm)), 2 * stake);
    }

    function test_MaxTopUp_BoundMinusOne_RevertsAtomically_ThenRetrySucceeds() public {
        uint256 stake = MAX_PER_DISPUTE + 50 ether;
        token.mint(defender, 50 ether);
        uint256 id = _open(defender, stake);
        uint256 escrowBefore = token.balanceOf(address(ilrm));

        // Passes the pre-call check (a full grant would need no top-up), fails after the grant is known
        vm.prank(defender);
        vm.expectRevert("Top-up exceeds max");
        ilrm.depositStakeWithSubsidy(id, type(uint256).max, 50 ether - 1);

        _assertNothingReserved(id, escrowBefore);
        assertEq(token.balanceOf(defender), 50 ether, "defender charged");

        // A retry with a looser bound succeeds
        vm.prank(defender);
        ilrm.depositStakeWithSubsidy(id, type(uint256).max, 60 ether);
        assertEq(token.balanceOf(defender), 0);
        assertEq(treasury.subsidyRecipientOf(address(ilrm), id), defender);
        assertEq(treasury.participantSubsidyUsed(defender), MAX_PER_DISPUTE);
    }

    function test_MaxTopUp_Zero_AcceptsOnlyFullSubsidy() public {
        token.mint(defender, 1000 ether);

        // Full subsidy available: no top-up
        uint256 full = _open(defender, STAKE);
        vm.prank(defender);
        ilrm.depositStakeWithSubsidy(full, STAKE, 0);
        assertEq(token.balanceOf(defender), 1000 ether);
        (, uint256 granted) = ilrm.stakeSubsidy(full);
        assertEq(granted, STAKE);

        // Only a partial subsidy available (per-dispute cap): reverts instead of charging
        uint256 partialId = _open(defender, MAX_PER_DISPUTE + 1);
        vm.prank(defender);
        vm.expectRevert("Top-up exceeds max");
        ilrm.depositStakeWithSubsidy(partialId, type(uint256).max, 0);
        assertEq(token.balanceOf(defender), 1000 ether);
        assertFalse(treasury.disputeSubsidized(partialId));
    }

    function test_MaxTopUp_UnsatisfiableBound_RevertsBeforeTreasuryCall() public {
        RevertIfCalledTreasury tripwire = new RevertIfCalledTreasury();
        ilrm.setSubsidyTreasury(address(tripwire));
        uint256 id = _open(defender, STAKE);

        // maxSubsidy 4 of a 10 stake needs a top-up of at least 6: a bound of 5 can never be met
        vm.prank(defender);
        vm.expectRevert("Top-up exceeds max");
        ilrm.depositStakeWithSubsidy(id, 4 ether, 6 ether - 1);

        // At exactly the minimum possible top-up the treasury is called
        vm.prank(defender);
        vm.expectRevert(RevertIfCalledTreasury.TreasuryCalled.selector);
        ilrm.depositStakeWithSubsidy(id, 4 ether, 6 ether);
    }

    /// @notice With a random front-run drain the caller is never charged above its bound, and a revert moves nothing
    function testFuzz_TopUpNeverAboveBound(uint256 stake, uint256 maxSubsidy, uint256 maxTopUp, uint256 drain) public {
        stake = bound(stake, 1, 300 ether);
        maxSubsidy = bound(maxSubsidy, 1, type(uint256).max);
        maxTopUp = bound(maxTopUp, 0, stake);
        drain = bound(drain, 0, MAX_PER_DISPUTE);
        token.mint(defender, stake);
        uint256 id = _open(defender, stake);

        // Front-run: a sybil pair's subsidized stake takes `drain` of the treasury's available balance first
        treasury.setMinReserve(TREASURY_FUNDS - MAX_PER_DISPUTE); // only 100 available to subsidies
        if (drain > 0) {
            address sybil = makeAddr("sybil");
            vm.prank(sybil);
            token.approve(address(ilrm), type(uint256).max);
            uint256 sybilId = _open(sybil, drain);
            vm.prank(sybil);
            ilrm.depositStakeWithSubsidy(sybilId, type(uint256).max, 0);
        }

        uint256 requested = maxSubsidy < stake ? maxSubsidy : stake;
        (uint256 grant,) = treasury.calculateSubsidy(id, requested, defender);
        bool expectOk = grant > 0 && stake - grant <= maxTopUp;

        uint256 walletBefore = token.balanceOf(defender);
        uint256 treasuryBefore = token.balanceOf(address(treasury));
        uint256 escrowBefore = token.balanceOf(address(ilrm));
        vm.prank(defender);
        (bool ok,) = address(ilrm).call(abi.encodeCall(ILRM.depositStakeWithSubsidy, (id, maxSubsidy, maxTopUp)));
        assertEq(ok, expectOk, "outcome differs from the preview");

        uint256 charged = walletBefore - token.balanceOf(defender);
        if (ok) {
            (, uint256 granted) = ilrm.stakeSubsidy(id);
            assertEq(granted, grant, "grant differs from the preview");
            assertLe(charged, maxTopUp, "charged above the bound");
            assertEq(charged + granted, stake, "stake not covered exactly");
            assertEq(treasuryBefore - token.balanceOf(address(treasury)), granted);
        } else {
            assertEq(charged, 0, "a revert moved the caller's funds");
            assertEq(token.balanceOf(address(treasury)), treasuryBefore, "a revert moved treasury funds");
            assertEq(token.balanceOf(address(ilrm)), escrowBefore);
            assertFalse(treasury.disputeSubsidized(id));
            assertEq(token.allowance(address(treasury), address(ilrm)), 0, "approval left behind");
        }
    }

    // =========================================================================
    // Treasury records keyed per (ILRM, disputeId)
    // =========================================================================

    function test_PerIlrmRecords_BothSubsidized_ViewsFollowWiredIlrm() public {
        _subsidize(ilrm, defender, STAKE); // A#0
        (ILRM ilrmB, address defenderB) = _repointToNewIlrm();
        uint256 idB = _subsidize(ilrmB, defenderB, STAKE); // B#0
        assertEq(idB, 0);

        assertEq(treasury.subsidyRecipientOf(address(ilrm), 0), defender);
        assertEq(treasury.subsidyRecipientOf(address(ilrmB), 0), defenderB);
        assertTrue(treasury.disputeSubsidized(0));
        assertEq(treasury.disputeSubsidyRecipient(0), defenderB, "1-arg view follows the wired ILRM (B)");
        assertEq(treasury.subsidyRecipientOf(address(ilrm), 1), address(0));
        assertFalse(treasury.disputeSubsidized(1));

        treasury.setILRM(address(ilrm));
        assertEq(treasury.disputeSubsidyRecipient(0), defender, "1-arg view follows the wired ILRM (A)");
    }

    function test_OldIlrm_NotILRM_LiveDisputeStillRepaysInFull() public {
        uint256 idA = _subsidize(ilrm, defender, STAKE);
        _repointToNewIlrm();

        // A can no longer draw subsidies
        address late = makeAddr("late-defender");
        vm.prank(late);
        token.approve(address(ilrm), type(uint256).max);
        uint256 lateId = _open(late, STAKE);
        vm.prank(late);
        vm.expectRevert(abi.encodeWithSelector(NatLangChainTreasury.NotILRM.selector, address(ilrm)));
        ilrm.depositStakeWithSubsidy(lateId, STAKE, type(uint256).max);

        // ...but A's live subsidized dispute still resolves and repays the treasury in full
        _propose(ilrm, idA);
        vm.prank(initiator);
        ilrm.acceptProposal(idA);
        vm.prank(defender);
        ilrm.acceptProposal(idA);
        assertEq(token.balanceOf(address(treasury)), TREASURY_FUNDS, "treasury not repaid in full");
        assertEq(token.balanceOf(defender), 0);
    }

    function test_PointBackToOldIlrm_KeepsHistory_BlocksDoubleSubsidy() public {
        _subsidize(ilrm, defender, STAKE); // A#0
        _repointToNewIlrm();
        assertFalse(treasury.disputeSubsidized(0), "B#0 is not subsidized");

        treasury.setILRM(address(ilrm));
        assertEq(treasury.subsidyRecipientOf(address(ilrm), 0), defender, "A history kept");
        assertTrue(treasury.disputeSubsidized(0));

        vm.prank(address(ilrm));
        vm.expectRevert(abi.encodeWithSelector(NatLangChainTreasury.DisputeAlreadySubsidized.selector, 0));
        treasury.fundStakeSubsidy(0, defender, STAKE);
    }

    function test_CalculateSubsidy_UsesCurrentIlrm() public {
        _subsidize(ilrm, defender, STAKE); // A#0
        (uint256 amount, bool eligible) = treasury.calculateSubsidy(0, STAKE, defender);
        assertEq(amount, 0);
        assertFalse(eligible);

        (ILRM ilrmB, address defenderB) = _repointToNewIlrm();
        (amount, eligible) = treasury.calculateSubsidy(0, STAKE, defenderB);
        assertEq(amount, STAKE);
        assertTrue(eligible, "B#0 eligible");

        _subsidize(ilrmB, defenderB, STAKE);
        (, eligible) = treasury.calculateSubsidy(0, STAKE, defenderB);
        assertFalse(eligible, "B#0 subsidized");

        treasury.setILRM(address(ilrm));
        (, eligible) = treasury.calculateSubsidy(0, STAKE, defender);
        assertFalse(eligible, "A#0 still subsidized");
        (, eligible) = treasury.calculateSubsidy(1, STAKE, defender);
        assertTrue(eligible, "A#1 eligible");
    }

    // =========================================================================
    // Subsidized disputes through counter-proposal rounds / timeout with reserves
    // =========================================================================

    function test_Subsidized_CounterRounds_AcceptAfterOriginalDeadline() public {
        ilrm.depositTokenReserves(50 ether);
        uint256 stake = MAX_PER_DISPUTE + 50 ether; // grant 100, top-up 50
        token.mint(defender, 50 ether);
        uint256 id = _open(defender, stake);
        uint256 start = ilrm.disputes(id).startTime;
        uint256 initiatorAfterStake = token.balanceOf(initiator);

        vm.prank(defender);
        ilrm.depositStakeWithSubsidy(id, type(uint256).max, 50 ether);
        assertEq(token.balanceOf(address(treasury)), TREASURY_FUNDS - MAX_PER_DISPUTE);

        // Two counter rounds, each with an ETH excess over the fee
        vm.deal(defender, 1 ether);
        vm.deal(initiator, 1 ether);
        _propose(ilrm, id);
        vm.prank(defender);
        ilrm.counterPropose{value: 0.01 ether + 0.003 ether}(id, keccak256("defender-1"));
        _propose(ilrm, id);
        vm.prank(initiator);
        ilrm.counterPropose{value: 0.02 ether + 0.004 ether}(id, keccak256("initiator-1"));
        assertEq(ilrm.disputes(id).startTime, start + 2 days, "two 1-day extensions");

        // Mutual acceptance after the original 7-day deadline, inside the extension
        vm.warp(start + ilrm.RESOLUTION_TIMEOUT() + 1 days);
        _propose(ilrm, id);
        vm.prank(initiator);
        ilrm.acceptProposal(id);
        vm.prank(defender);
        ilrm.acceptProposal(id);

        assertEq(uint256(ilrm.disputes(id).outcome), uint256(IILRM.DisputeOutcome.AcceptedProposal));
        assertEq(token.balanceOf(address(treasury)), TREASURY_FUNDS, "funder repaid in full");
        assertEq(token.balanceOf(defender), 50 ether, "defender gets back only its top-up");
        assertEq(token.balanceOf(initiator) - initiatorAfterStake, stake);
        assertEq(ilrm.tokenReserves(), 50 ether, "reserves untouched");
        assertEq(token.balanceOf(address(ilrm)), ilrm.tokenReserves());
        assertEq(ilrm.treasury(), 0.007 ether, "ILRM.treasury == ETH excess");
    }

    function test_Subsidized_ThreeCounters_Timeout_ExactProRata() public {
        ilrm.depositTokenReserves(50 ether);
        uint256 stake = 8e18;
        uint256 subsidy = 5e18;
        token.mint(defender, stake - subsidy);
        uint256 id = _open(defender, stake);
        uint256 start = ilrm.disputes(id).startTime;
        uint256 initiatorAfterStake = token.balanceOf(initiator);
        uint256 windowStartBefore = ilrm.incentiveWindowStart();

        vm.prank(defender);
        ilrm.depositStakeWithSubsidy(id, subsidy, stake - subsidy);

        vm.deal(defender, 1 ether);
        vm.deal(initiator, 1 ether);
        vm.prank(defender);
        ilrm.counterPropose{value: 0.01 ether}(id, keccak256("c1"));
        vm.prank(initiator);
        ilrm.counterPropose{value: 0.02 ether}(id, keccak256("c2"));
        vm.prank(defender);
        ilrm.counterPropose{value: 0.04 ether}(id, keccak256("c3"));
        vm.prank(initiator);
        vm.expectRevert("Max counters reached");
        ilrm.counterPropose{value: 0.08 ether}(id, keccak256("c4"));

        uint256 extendedDeadline = start + ilrm.MAX_TIME_EXTENSION() + ilrm.RESOLUTION_TIMEOUT();
        assertEq(ilrm.disputes(id).startTime + ilrm.RESOLUTION_TIMEOUT(), extendedDeadline, "capped at 3 days");

        vm.warp(extendedDeadline); // one second before the first timestamp that times out
        vm.expectRevert("Not timed out");
        ilrm.enforceTimeout(id);

        vm.warp(extendedDeadline + 1);
        vm.recordLogs();
        ilrm.enforceTimeout(id);

        assertEq(token.balanceOf(BURN), 8e18, "burned");
        assertEq(token.balanceOf(initiator) - initiatorAfterStake, 4e18, "initiator");
        assertEq(token.balanceOf(address(treasury)), TREASURY_FUNDS - subsidy + 2.5e18, "funder");
        assertEq(token.balanceOf(defender), 1.5e18, "defender");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != InitiatorIncentivePaid.selector, "unexpected InitiatorIncentivePaid");
        }
        assertEq(ilrm.tokenReserves(), 50 ether, "reserves untouched");
        assertEq(ilrm.incentivePaidInWindow(), 0);
        assertEq(ilrm.incentiveWindowStart(), windowStartBefore);
        assertEq(token.balanceOf(address(ilrm)), ilrm.tokenReserves());
    }

    function test_FullySubsidizedTimeout_WithReservesFunded() public {
        ilrm.depositTokenReserves(100 ether);
        uint256 id = _open(defender, STAKE);
        uint256 initiatorAfterStake = token.balanceOf(initiator);

        vm.prank(defender);
        ilrm.depositStakeWithSubsidy(id, STAKE, 0);

        vm.warp(block.timestamp + ilrm.RESOLUTION_TIMEOUT() + 1);
        ilrm.enforceTimeout(id);

        assertEq(token.balanceOf(initiator) - initiatorAfterStake, STAKE / 2, "no incentive on timeout");
        assertEq(token.balanceOf(defender), 0);
        assertEq(token.balanceOf(address(treasury)), TREASURY_FUNDS - STAKE / 2);
        assertEq(ilrm.tokenReserves(), 100 ether, "reserves untouched");
        assertEq(ilrm.incentivePaidInWindow(), 0);
        assertEq(token.balanceOf(address(ilrm)), ilrm.tokenReserves(), "ILRM balance != tokenReserves");
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _open(address counterparty, uint256 stake) internal returns (uint256 id) {
        id = _openOn(ilrm, counterparty, stake);
    }

    function _openOn(ILRM target, address counterparty, uint256 stake) internal returns (uint256 id) {
        vm.prank(initiator);
        id = target.initiateBreachDispute(
            counterparty, stake, keccak256(abi.encode(counterparty, stake)), fallbackLicense
        );
    }

    /// @dev Open a dispute on `target` and stake it fully subsidized
    function _subsidize(ILRM target, address cp, uint256 stake) internal returns (uint256 id) {
        vm.prank(cp);
        token.approve(address(target), type(uint256).max);
        id = _openOn(target, cp, stake);
        vm.prank(cp);
        target.depositStakeWithSubsidy(id, stake, 0);
    }

    /// @dev Deploy a new ILRM (dispute IDs restart at 0) and re-point the treasury to it
    function _repointToNewIlrm() internal returns (ILRM ilrmB, address defenderB) {
        ilrmB = new ILRM(IERC20(address(token)), address(oracle), registry);
        treasury.setILRM(address(ilrmB));
        ilrmB.setSubsidyTreasury(address(treasury));
        vm.prank(initiator);
        token.approve(address(ilrmB), type(uint256).max);
        defenderB = makeAddr("defenderB");
    }

    function _propose(ILRM target, uint256 id) internal {
        vm.prank(address(oracle));
        target.submitLLMProposal(id, "split the royalties", "");
    }

    function _assertNothingReserved(uint256 id, uint256 escrowBefore) internal view {
        assertFalse(treasury.disputeSubsidized(id), "subsidy flag left behind");
        assertEq(treasury.subsidyRecipientOf(address(ilrm), id), address(0));
        assertEq(token.balanceOf(address(treasury)), TREASURY_FUNDS, "treasury balance changed");
        assertEq(treasury.participantSubsidyUsed(defender), 0, "rolling allowance charged");
        assertEq(treasury.totalSubsidiesDistributed(), 0);
        assertEq(token.allowance(address(treasury), address(ilrm)), 0, "approval left behind");
        assertEq(ilrm.disputes(id).counterpartyStake, 0, "stake recorded");
        assertEq(token.balanceOf(address(ilrm)), escrowBefore, "escrow changed");
        (address funder, uint256 amount) = ilrm.stakeSubsidy(id);
        assertEq(funder, address(0));
        assertEq(amount, 0);
    }
}
