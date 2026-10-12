// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/ILRM.sol";
import "../contracts/mocks/MockAssetRegistry.sol";
import "../contracts/mocks/MockOracle.sol";
import "../contracts/mocks/MockToken.sol";

/**
 * @title InitiatorIncentiveCapsTest
 * @notice The non-participation initiator incentive (10% of the stake from tokenReserves) is capped per dispute
 *         and across all disputes per window; the initiator always gets its full stake back and the payout
 *         never reverts.
 */
contract InitiatorIncentiveCapsTest is Test {
    ILRM internal ilrm;
    MockToken internal token;
    MockAssetRegistry internal registry;
    MockOracle internal oracle;

    address internal stranger = makeAddr("stranger");

    uint256 internal constant PER_DISPUTE = 1e18;
    uint256 internal constant PER_WINDOW = 10e18;
    uint256 internal constant WINDOW = 30 days;
    uint256 internal constant DEPLOY_TIME = 1_000_000;

    uint256 internal partyNonce;

    IILRM.FallbackLicense internal fallbackLicense = IILRM.FallbackLicense({
        termsHash: keccak256("fallback"), termDuration: 365 days, royaltyCapBps: 500, nonExclusive: true
    });

    // Mirrors of the contract events, for vm.expectEmit
    event InitiatorIncentiveCapsUpdated(uint256 maxPerDispute, uint256 maxPerWindow, uint256 window);
    event InitiatorIncentivePaid(
        uint256 indexed disputeId, address indexed initiator, uint256 amount, uint256 uncappedAmount
    );

    function setUp() public {
        vm.warp(DEPLOY_TIME);
        token = new MockToken(); // mints 1_000_000 ether to this contract (funds tokenReserves)
        registry = new MockAssetRegistry();
        oracle = new MockOracle();
        ilrm = new ILRM(IERC20(address(token)), address(oracle), registry);
        token.approve(address(ilrm), type(uint256).max);
    }

    // =========================================================================
    // Defaults and setter
    // =========================================================================

    function test_Defaults() public view {
        assertEq(ilrm.MIN_INCENTIVE_WINDOW(), 1 days);
        assertEq(ilrm.MAX_INCENTIVE_WINDOW(), 365 days);
        assertEq(ilrm.DEFAULT_MAX_INCENTIVE_PER_DISPUTE(), PER_DISPUTE);
        assertEq(ilrm.DEFAULT_MAX_INCENTIVE_PER_WINDOW(), PER_WINDOW);
        assertEq(ilrm.DEFAULT_INCENTIVE_WINDOW(), WINDOW);
        assertEq(ilrm.maxIncentivePerDispute(), PER_DISPUTE);
        assertEq(ilrm.maxIncentivePerWindow(), PER_WINDOW);
        assertEq(ilrm.incentiveWindow(), WINDOW);
        assertEq(ilrm.incentiveWindowStart(), DEPLOY_TIME, "window starts at deployment");
        assertEq(ilrm.incentivePaidInWindow(), 0);
        assertEq(ilrm.tokenReserves(), 0);
    }

    function test_Constructor_EmitsCapsUpdated() public {
        vm.warp(DEPLOY_TIME + 5 days);
        address expected = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectEmit(true, true, true, true, expected);
        emit InitiatorIncentiveCapsUpdated(PER_DISPUTE, PER_WINDOW, WINDOW);
        ILRM fresh = new ILRM(IERC20(address(token)), address(oracle), registry);
        assertEq(address(fresh), expected);
        assertEq(fresh.incentiveWindowStart(), DEPLOY_TIME + 5 days);
    }

    function test_SetCaps_OnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        ilrm.setInitiatorIncentiveCaps(1, 2, 2 days);
    }

    function test_SetCaps_WindowBoundsInclusive() public {
        vm.expectRevert("Invalid incentive window");
        ilrm.setInitiatorIncentiveCaps(PER_DISPUTE, PER_WINDOW, 1 days - 1);
        vm.expectRevert("Invalid incentive window");
        ilrm.setInitiatorIncentiveCaps(PER_DISPUTE, PER_WINDOW, 365 days + 1);
        vm.expectRevert("Invalid incentive window");
        ilrm.setInitiatorIncentiveCaps(PER_DISPUTE, PER_WINDOW, 0);

        ilrm.setInitiatorIncentiveCaps(PER_DISPUTE, PER_WINDOW, 1 days);
        assertEq(ilrm.incentiveWindow(), 1 days);
        ilrm.setInitiatorIncentiveCaps(PER_DISPUTE, PER_WINDOW, 365 days);
        assertEq(ilrm.incentiveWindow(), 365 days);
    }

    function test_SetCaps_PerDisputeAboveWindowReverts() public {
        vm.expectRevert("Per-dispute cap above window cap");
        ilrm.setInitiatorIncentiveCaps(5e18 + 1, 5e18, WINDOW);

        // Equal caps are fine
        ilrm.setInitiatorIncentiveCaps(5e18, 5e18, WINDOW);
        assertEq(ilrm.maxIncentivePerDispute(), 5e18);
    }

    function test_SetCaps_EmitsAndStores_ZeroAllowed() public {
        vm.expectEmit(true, true, true, true, address(ilrm));
        emit InitiatorIncentiveCapsUpdated(2e18, 7e18, 7 days);
        ilrm.setInitiatorIncentiveCaps(2e18, 7e18, 7 days);
        assertEq(ilrm.maxIncentivePerDispute(), 2e18);
        assertEq(ilrm.maxIncentivePerWindow(), 7e18);
        assertEq(ilrm.incentiveWindow(), 7 days);

        vm.expectEmit(true, true, true, true, address(ilrm));
        emit InitiatorIncentiveCapsUpdated(0, 0, 7 days);
        ilrm.setInitiatorIncentiveCaps(0, 0, 7 days);
        assertEq(ilrm.maxIncentivePerDispute(), 0);
        assertEq(ilrm.maxIncentivePerWindow(), 0);

        // The window state is never touched by the setter
        assertEq(ilrm.incentiveWindowStart(), DEPLOY_TIME);
        assertEq(ilrm.incentivePaidInWindow(), 0);
    }

    function test_SetCaps_WorksWhilePaused() public {
        ilrm.pause();
        ilrm.setInitiatorIncentiveCaps(0, 0, WINDOW);
        assertEq(ilrm.maxIncentivePerWindow(), 0);
    }

    // =========================================================================
    // Payouts
    // =========================================================================

    function test_FullIncentiveWithinCaps_MatchesPreview() public {
        ilrm.depositTokenReserves(100e18);
        uint256 stake = 5e18; // 10% = 0.5e18 < per-dispute cap
        (address init, uint256 id) = _openAbsent(stake);
        _warpPastStakeWindow();

        uint256 preview = ilrm.previewInitiatorIncentive(stake);
        assertEq(preview, 0.5e18);
        vm.expectEmit(true, true, true, true, address(ilrm));
        emit InitiatorIncentivePaid(id, init, 0.5e18, 0.5e18);
        ilrm.enforceTimeout(id);

        assertEq(token.balanceOf(init), stake + preview, "stake + full 10%");
        assertEq(ilrm.tokenReserves(), 100e18 - preview);
        assertEq(ilrm.incentivePaidInWindow(), preview);
        _assertBalanceMatchesReserves();
    }

    function test_PerDisputeCapBinds() public {
        ilrm.depositTokenReserves(500e18);
        uint256 stake = 1000e18;
        (address init, uint256 id) = _openAbsent(stake);
        _warpPastStakeWindow();

        assertEq(ilrm.previewInitiatorIncentive(stake), PER_DISPUTE);
        vm.expectEmit(true, true, true, true, address(ilrm));
        emit InitiatorIncentivePaid(id, init, PER_DISPUTE, 100e18);
        ilrm.enforceTimeout(id);

        assertEq(token.balanceOf(init), stake + PER_DISPUTE);
        assertEq(ilrm.tokenReserves(), 500e18 - PER_DISPUTE);
        _assertBalanceMatchesReserves();
    }

    function test_WindowExhausted_StakeStillReturned() public {
        ilrm.depositTokenReserves(100e18);
        uint256 stake = 10e18; // 1e18 each
        (address[] memory inits, uint256[] memory ids) = _openAbsentMany(11, stake);
        _warpPastStakeWindow();

        for (uint256 i = 0; i < 10; i++) {
            ilrm.enforceTimeout(ids[i]);
            assertEq(token.balanceOf(inits[i]), stake + 1e18);
        }
        assertEq(ilrm.incentivePaidInWindow(), PER_WINDOW);
        assertEq(ilrm.tokenReserves(), 90e18);
        assertEq(ilrm.previewInitiatorIncentive(stake), 0);

        uint256 startBefore = ilrm.incentiveWindowStart();
        vm.expectEmit(true, true, true, true, address(ilrm));
        emit InitiatorIncentivePaid(ids[10], inits[10], 0, 1e18);
        ilrm.enforceTimeout(ids[10]); // no revert

        assertEq(token.balanceOf(inits[10]), stake, "full stake back, no incentive");
        assertEq(ilrm.tokenReserves(), 90e18, "reserves untouched");
        assertEq(ilrm.incentivePaidInWindow(), PER_WINDOW, "window usage untouched");
        assertEq(ilrm.incentiveWindowStart(), startBefore);
        assertTrue(ilrm.disputes(ids[10]).resolved);
        _assertBalanceMatchesReserves();
    }

    function test_WindowRemainderPaidPartially() public {
        ilrm.setInitiatorIncentiveCaps(4e18, 10e18, WINDOW);
        ilrm.depositTokenReserves(100e18);
        uint256 stake = 50e18; // uncapped 5e18
        (address[] memory inits, uint256[] memory ids) = _openAbsentMany(4, stake);
        _warpPastStakeWindow();

        uint256[4] memory expected = [uint256(4e18), 4e18, 2e18, 0];
        for (uint256 i = 0; i < 4; i++) {
            assertEq(ilrm.previewInitiatorIncentive(stake), expected[i]);
            vm.expectEmit(true, true, true, true, address(ilrm));
            emit InitiatorIncentivePaid(ids[i], inits[i], expected[i], 5e18);
            ilrm.enforceTimeout(ids[i]);
            assertEq(token.balanceOf(inits[i]), stake + expected[i]);
        }
        assertEq(ilrm.incentivePaidInWindow(), 10e18);
        assertEq(ilrm.tokenReserves(), 90e18);
        _assertBalanceMatchesReserves();
    }

    function test_WindowRollsExactlyAtExpiry() public {
        ilrm.depositTokenReserves(100e18);
        uint256 stake = 10e18;
        (, uint256[] memory ids) = _openAbsentMany(10, stake);
        _warpPastStakeWindow();
        for (uint256 i = 0; i < 10; i++) {
            ilrm.enforceTimeout(ids[i]);
        }
        assertEq(ilrm.incentivePaidInWindow(), PER_WINDOW);

        uint256 expiry = DEPLOY_TIME + WINDOW;
        vm.warp(expiry - 5 days);
        (address lateA, uint256 idA) = _openAbsent(stake);
        (address lateB, uint256 idB) = _openAbsent(stake);

        // One second before expiry the window is still exhausted
        vm.warp(expiry - 1);
        assertEq(ilrm.previewInitiatorIncentive(stake), 0);
        ilrm.enforceTimeout(idA);
        assertEq(token.balanceOf(lateA), stake);
        assertEq(ilrm.incentiveWindowStart(), DEPLOY_TIME);

        // Exactly at start + window it rolls: the budget is restored and the new window starts now
        vm.warp(expiry);
        assertEq(ilrm.previewInitiatorIncentive(stake), 1e18);
        ilrm.enforceTimeout(idB);
        assertEq(token.balanceOf(lateB), stake + 1e18);
        assertEq(ilrm.incentiveWindowStart(), expiry);
        assertEq(ilrm.incentivePaidInWindow(), 1e18);
        _assertBalanceMatchesReserves();
    }

    function test_BoundaryBurst_ExactlyTwoWindowCaps() public {
        ilrm.depositTokenReserves(1000e18);
        uint256 stake = 10e18;
        uint256 expiry = DEPLOY_TIME + WINDOW;
        vm.warp(expiry - 5 days);
        (address[] memory inits, uint256[] memory ids) = _openAbsentMany(22, stake);

        uint256 reservesBefore = ilrm.tokenReserves();
        vm.warp(expiry - 1);
        for (uint256 i = 0; i < 11; i++) {
            ilrm.enforceTimeout(ids[i]);
        }
        vm.warp(expiry);
        for (uint256 i = 11; i < 22; i++) {
            ilrm.enforceTimeout(ids[i]);
        }

        uint256 paid;
        for (uint256 i = 0; i < 22; i++) {
            assertGe(token.balanceOf(inits[i]), stake);
            paid += token.balanceOf(inits[i]) - stake;
        }
        assertEq(paid, 2 * PER_WINDOW, "exactly 2W across the boundary");
        assertEq(token.balanceOf(inits[10]), stake, "11th payout before the boundary is 0");
        assertEq(token.balanceOf(inits[21]), stake, "11th payout after the boundary is 0");
        assertEq(reservesBefore - ilrm.tokenReserves(), paid);
        _assertBalanceMatchesReserves();
    }

    function test_LowReserves_PayRemainderThenZero() public {
        ilrm.depositTokenReserves(1.5e18);
        uint256 stake = 10e18;
        (address[] memory inits, uint256[] memory ids) = _openAbsentMany(3, stake);
        _warpPastStakeWindow();

        uint256[3] memory expected = [uint256(1e18), 0.5e18, 0];
        for (uint256 i = 0; i < 3; i++) {
            assertEq(ilrm.previewInitiatorIncentive(stake), expected[i]);
            vm.expectEmit(true, true, true, true, address(ilrm));
            emit InitiatorIncentivePaid(ids[i], inits[i], expected[i], 1e18);
            ilrm.enforceTimeout(ids[i]);
            assertEq(token.balanceOf(inits[i]), stake + expected[i]);
        }
        assertEq(ilrm.tokenReserves(), 0);
        assertEq(ilrm.incentivePaidInWindow(), 1.5e18);
        _assertBalanceMatchesReserves();
    }

    function test_ZeroReserves_NoStateWrites() public {
        ilrm.depositTokenReserves(1e18);
        uint256 stake = 10e18;
        (, uint256 first) = _openAbsent(stake);
        _warpPastStakeWindow();
        ilrm.enforceTimeout(first);
        assertEq(ilrm.tokenReserves(), 0);
        assertEq(ilrm.incentivePaidInWindow(), 1e18);

        // Past expiry a payout would roll the window, but with no reserves nothing is written
        vm.warp(DEPLOY_TIME + WINDOW + 1 days);
        (address init, uint256 id) = _openAbsent(stake);
        _warpPastStakeWindow();
        vm.record();
        ilrm.enforceTimeout(id);
        (, bytes32[] memory writes) = vm.accesses(address(ilrm));

        assertEq(token.balanceOf(init), stake);
        assertEq(ilrm.incentiveWindowStart(), DEPLOY_TIME, "window rolled without a payout");
        assertEq(ilrm.incentivePaidInWindow(), 1e18);
        assertEq(ilrm.tokenReserves(), 0);
        bytes32 startSlot = _slotOf(abi.encodeWithSelector(ilrm.incentiveWindowStart.selector));
        bytes32 paidSlot = _slotOf(abi.encodeWithSelector(ilrm.incentivePaidInWindow.selector));
        bytes32 reservesSlot = _slotOf(abi.encodeWithSelector(ilrm.tokenReserves.selector));
        for (uint256 i = 0; i < writes.length; i++) {
            assertTrue(writes[i] != startSlot && writes[i] != paidSlot && writes[i] != reservesSlot, "state written");
        }
    }

    function test_ZeroCaps_KillSwitch() public {
        ilrm.depositTokenReserves(100e18);
        (address init, uint256 id) = _openAbsent(10e18);
        ilrm.pause(); // enforceTimeout is unpausable; so is the kill switch
        ilrm.setInitiatorIncentiveCaps(0, 0, WINDOW);
        _warpPastStakeWindow();

        assertEq(ilrm.previewInitiatorIncentive(10e18), 0);
        vm.expectEmit(true, true, true, true, address(ilrm));
        emit InitiatorIncentivePaid(id, init, 0, 1e18);
        ilrm.enforceTimeout(id);

        assertEq(token.balanceOf(init), 10e18);
        assertEq(ilrm.tokenReserves(), 100e18);
        assertEq(ilrm.incentivePaidInWindow(), 0);
        _assertBalanceMatchesReserves();
    }

    function test_LoweringCapBelowPaid_PaysZeroUntilRoll() public {
        ilrm.depositTokenReserves(100e18);
        uint256 stake = 10e18;
        (address[] memory inits, uint256[] memory ids) = _openAbsentMany(7, stake);
        _warpPastStakeWindow();
        for (uint256 i = 0; i < 5; i++) {
            ilrm.enforceTimeout(ids[i]);
        }
        assertEq(ilrm.incentivePaidInWindow(), 5e18);

        ilrm.setInitiatorIncentiveCaps(1e18, 3e18, WINDOW);
        assertEq(ilrm.incentivePaidInWindow(), 5e18, "usage not reset by the setter");
        ilrm.enforceTimeout(ids[5]);
        assertEq(token.balanceOf(inits[5]), stake, "cap below paid: 0 until the roll");

        vm.warp(DEPLOY_TIME + WINDOW);
        ilrm.enforceTimeout(ids[6]);
        assertEq(token.balanceOf(inits[6]), stake + 1e18, "budget restored after the roll");
        assertEq(ilrm.incentivePaidInWindow(), 1e18);
        _assertBalanceMatchesReserves();
    }

    function test_ShorterWindowAppliesToCurrentWindow() public {
        ilrm.depositTokenReserves(100e18);
        uint256 stake = 10e18;
        (address[] memory inits, uint256[] memory ids) = _openAbsentMany(12, stake);
        _warpPastStakeWindow();
        for (uint256 i = 0; i < 10; i++) {
            ilrm.enforceTimeout(ids[i]);
        }

        ilrm.setInitiatorIncentiveCaps(PER_DISPUTE, PER_WINDOW, 5 days);
        assertEq(ilrm.incentiveWindowStart(), DEPLOY_TIME, "start kept");

        vm.warp(DEPLOY_TIME + 5 days - 1);
        ilrm.enforceTimeout(ids[10]);
        assertEq(token.balanceOf(inits[10]), stake, "current window still exhausted");

        vm.warp(DEPLOY_TIME + 5 days); // would still be inside the old 30-day window
        ilrm.enforceTimeout(ids[11]);
        assertEq(token.balanceOf(inits[11]), stake + 1e18, "new length applied to the current window");
        assertEq(ilrm.incentiveWindowStart(), DEPLOY_TIME + 5 days);
        _assertBalanceMatchesReserves();
    }

    function test_AcceptAndTimeoutPaths_IncentiveStateUntouched() public {
        ilrm.depositTokenReserves(50e18);
        uint256 stake = 10e18;
        address cpA = _newParty(stake);
        address cpT = _newParty(stake);
        address init = _newParty(2 * stake);

        vm.startPrank(init);
        uint256 acceptId = ilrm.initiateBreachDispute(cpA, stake, bytes32("a"), fallbackLicense);
        uint256 timeoutId = ilrm.initiateBreachDispute(cpT, stake, bytes32("t"), fallbackLicense);
        vm.stopPrank();
        vm.prank(cpA);
        ilrm.depositStake(acceptId);
        vm.prank(cpT);
        ilrm.depositStake(timeoutId);

        vm.recordLogs();
        vm.prank(address(oracle));
        ilrm.submitLLMProposal(acceptId, "split the royalties", "");
        vm.prank(init);
        ilrm.acceptProposal(acceptId);
        vm.prank(cpA);
        ilrm.acceptProposal(acceptId);

        vm.warp(block.timestamp + ilrm.RESOLUTION_TIMEOUT() + 1);
        ilrm.enforceTimeout(timeoutId);

        assertEq(ilrm.tokenReserves(), 50e18);
        assertEq(ilrm.incentivePaidInWindow(), 0);
        assertEq(ilrm.incentiveWindowStart(), DEPLOY_TIME);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != InitiatorIncentivePaid.selector, "unexpected InitiatorIncentivePaid");
        }
        assertEq(token.balanceOf(init), stake + stake / 2, "accept: full stake, timeout: half");
        _assertBalanceMatchesReserves();
    }

    // =========================================================================
    // Fuzz
    // =========================================================================

    /// @notice Every payout equals the preview, respects every cap, and conserves the accounting
    function testFuzz_PayoutMatchesPreviewAndCaps(
        uint256 perDispute,
        uint256 perWindow,
        uint256 window,
        uint256 reserves,
        uint256 seed,
        uint8 count
    ) public {
        perWindow = bound(perWindow, 0, 1e24);
        perDispute = bound(perDispute, 0, perWindow);
        window = bound(window, 1 days, 365 days);
        reserves = bound(reserves, 0, 1e24);
        count = uint8(bound(count, 1, 6));
        ilrm.setInitiatorIncentiveCaps(perDispute, perWindow, window);
        if (reserves > 0) ilrm.depositTokenReserves(reserves);

        uint256 totalPaid;
        for (uint256 i = 0; i < count; i++) {
            totalPaid += _payOneAndCheck(uint256(keccak256(abi.encode(seed, i))));
        }
        assertEq(ilrm.tokenReserves(), reserves - totalPaid);
        _assertBalanceMatchesReserves();
    }

    /// @notice Sybil farming with fresh initiators/counterparties is bounded by W * (ceil(elapsed / T) + 1)
    /// @dev Up to 30 full dispute cycles per run: capped in the ci profile to keep it under ~10s
    /// forge-config: ci.fuzz.runs = 2000
    function testFuzz_FarmingBoundedByCaps(uint256 perDispute, uint256 perWindow, uint256 window, uint8 n, uint256 seed)
        public
    {
        perWindow = bound(perWindow, 0, 1e21);
        perDispute = bound(perDispute, 0, perWindow);
        window = bound(window, 1 days, 365 days);
        n = uint8(bound(n, 1, 30));
        ilrm.setInitiatorIncentiveCaps(perDispute, perWindow, window);
        uint256 reserves = 1e24;
        ilrm.depositTokenReserves(reserves);

        uint256 total;
        uint256 firstPayout;
        for (uint256 i = 0; i < n; i++) {
            total += _farmOnce(uint256(keccak256(abi.encode(seed, i))));
            if (i == 0) firstPayout = block.timestamp;
        }

        uint256 elapsed = block.timestamp - firstPayout; // the last payout happened now
        uint256 windows = (elapsed + window - 1) / window + 1;
        assertLe(total, perWindow * windows, "farming above W * (ceil(t / T) + 1)");
        assertEq(ilrm.tokenReserves(), reserves - total);
        _assertBalanceMatchesReserves();
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    /// @dev One non-participation payout with a random stake and delay; checks it against the preview and caps
    function _payOneAndCheck(uint256 r) internal returns (uint256 paid) {
        uint256 stake = bound(r, 1, 1e25);
        (address init, uint256 id) = _openAbsent(stake);
        vm.warp(block.timestamp + ilrm.STAKE_WINDOW() + 1 + ((r >> 128) % 40 days));

        uint256 preview = ilrm.previewInitiatorIncentive(stake);
        uint256 reservesBefore = ilrm.tokenReserves();
        ilrm.enforceTimeout(id);
        assertGe(token.balanceOf(init), stake, "stake not returned");
        paid = token.balanceOf(init) - stake;

        assertEq(paid, preview, "paid != preview");
        assertLe(paid, stake / 10, "above 10% of the stake");
        assertLe(paid, ilrm.maxIncentivePerDispute(), "above the per-dispute cap");
        assertLe(paid, ilrm.maxIncentivePerWindow(), "above the window cap");
        assertLe(paid, reservesBefore, "above the reserves");
        assertLe(ilrm.incentivePaidInWindow(), ilrm.maxIncentivePerWindow(), "window usage above the cap");
        assertEq(ilrm.tokenReserves(), reservesBefore - paid);
    }

    /// @dev One farming cycle: random gap, fresh initiator and never-staking counterparty, random stake
    function _farmOnce(uint256 r) internal returns (uint256 farmed) {
        uint256 stake = bound(r, 1, 1e22);
        vm.warp(block.timestamp + ((r >> 128) % 20 days));
        (address init, uint256 id) = _openAbsent(stake);
        vm.warp(block.timestamp + ilrm.STAKE_WINDOW() + 1);
        ilrm.enforceTimeout(id);
        assertGe(token.balanceOf(init), stake, "stake not returned");
        farmed = token.balanceOf(init) - stake;
    }

    function _newParty(uint256 funds) internal returns (address party) {
        party = makeAddr(string.concat("party", vm.toString(partyNonce++)));
        token.mint(party, funds);
        vm.prank(party);
        token.approve(address(ilrm), type(uint256).max);
    }

    /// @dev Fresh initiator vs a fresh counterparty that never stakes
    function _openAbsent(uint256 stake) internal returns (address init, uint256 id) {
        init = _newParty(stake);
        address absent = makeAddr(string.concat("absent", vm.toString(partyNonce++)));
        vm.prank(init);
        id = ilrm.initiateBreachDispute(absent, stake, keccak256(abi.encode(init)), fallbackLicense);
    }

    function _openAbsentMany(uint256 count, uint256 stake)
        internal
        returns (address[] memory inits, uint256[] memory ids)
    {
        inits = new address[](count);
        ids = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            (inits[i], ids[i]) = _openAbsent(stake);
        }
    }

    function _warpPastStakeWindow() internal {
        vm.warp(block.timestamp + ilrm.STAKE_WINDOW() + 1);
    }

    function _assertBalanceMatchesReserves() internal view {
        assertEq(token.balanceOf(address(ilrm)), ilrm.tokenReserves(), "ILRM balance != tokenReserves");
    }

    /// @dev The single storage slot a public getter reads
    function _slotOf(bytes memory getterCall) internal returns (bytes32) {
        vm.record();
        (bool ok,) = address(ilrm).staticcall(getterCall);
        require(ok, "getter failed");
        (bytes32[] memory reads,) = vm.accesses(address(ilrm));
        require(reads.length == 1, "getter read more than one slot");
        return reads[0];
    }
}
