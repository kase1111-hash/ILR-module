// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/ILRM.sol";
import "../contracts/Treasury.sol";
import "../contracts/mocks/MockAssetRegistry.sol";
import "../contracts/mocks/MockOracle.sol";
import "../contracts/mocks/MockToken.sol";

/**
 * @title TreasuryFollowupsRegression
 * @notice Regression tests for the Treasury / initiator-incentive follow-ups:
 *         - a front-run that shrinks the Treasury grant overcharged the defender's allowance (no slippage bound)
 *         - the non-participation initiator incentive could be farmed without limit (one dispute, or sybils)
 *         - Treasury subsidy records were keyed by disputeId only and collided after re-pointing to a new ILRM
 *         - unsubsidized resolutions loaded the unused subsidy funder slot
 * @dev New or changed entry points (the 3-argument depositStakeWithSubsidy) are reached only through low-level
 *      calls, so this file compiles against both the old and the new ABI. Every test fails before the fix.
 */
contract TreasuryFollowupsRegressionTest is Test {
    ILRM internal ilrm;
    NatLangChainTreasury internal treasury;
    MockToken internal token;
    MockAssetRegistry internal registry;
    MockOracle internal oracle;

    address internal initiator = makeAddr("initiator");

    // Default initiator-incentive caps of the fix (local: the old ABI has no getters for them)
    uint256 internal constant DEFAULT_MAX_INCENTIVE_PER_DISPUTE = 1e18;
    uint256 internal constant DEFAULT_MAX_INCENTIVE_PER_WINDOW = 10e18;
    uint256 internal constant DEFAULT_INCENTIVE_WINDOW = 30 days;

    uint256 internal constant MAX_PER_DISPUTE = 100 ether;
    uint256 internal constant MAX_PER_PARTICIPANT = 1000 ether;

    uint256 internal constant FARM_STAKE = 10e18; // uncapped incentive 1e18 per farming dispute

    IILRM.FallbackLicense internal fallbackLicense = IILRM.FallbackLicense({
        termsHash: keccak256("fallback"), termDuration: 365 days, royaltyCapBps: 500, nonExclusive: true
    });

    // Farming-loop state (kept in storage to stay below the stack limit)
    address[] internal farmers;
    uint256[] internal farmIds;
    uint256[] internal farmOpenedAt;
    uint256 internal farmResolved;
    uint256 internal farmed;
    uint256 internal firstPayout;
    uint256 internal lastPayout;

    function setUp() public {
        token = new MockToken(); // mints 1_000_000 ether to this contract (funds tokenReserves)
        registry = new MockAssetRegistry();
        oracle = new MockOracle();
        ilrm = new ILRM(IERC20(address(token)), address(oracle), registry);
        treasury = new NatLangChainTreasury(IERC20(address(token)), MAX_PER_DISPUTE, MAX_PER_PARTICIPANT, 30 days);
        treasury.setILRM(address(ilrm));
        ilrm.setSubsidyTreasury(address(treasury));

        token.approve(address(ilrm), type(uint256).max);
        token.mint(initiator, 1_000_000 ether);
        vm.prank(initiator);
        token.approve(address(ilrm), type(uint256).max);
    }

    // =========================================================================
    // (1) Slippage bound on the subsidized stake
    // =========================================================================

    /// @notice A sybil front-run that shrinks the grant must not charge the defender more than it bounded
    function test_Regression_FrontRunGrantShrink_NoOvercharge() public {
        uint256 stake = 10 ether;
        token.mint(address(treasury), stake); // the Treasury holds exactly one full grant

        // Defender: funded, MaxUint256 allowance to ILRM, previews a full subsidy => expects to pay 0
        address defender = _newParty("defender", stake, ilrm);
        uint256 id = _open(ilrm, initiator, defender, stake);
        (uint256 preview, bool eligible) = treasury.calculateSubsidy(id, stake, defender);
        assertTrue(eligible);
        assertEq(preview, stake, "preview is a full subsidy");
        uint256 maxTopUp = stake - preview; // 0

        // Front-run: a sybil pair's subsidized stake uses up most of the Treasury's available balance
        address sybilInitiator = _newParty("sybil-initiator", stake, ilrm);
        address sybil = _newParty("sybil", 0, ilrm);
        uint256 sybilId = _open(ilrm, sybilInitiator, sybil, stake - 1 ether);
        (bool sybilOk,) = _depositWithSubsidy(ilrm, sybil, sybilId, type(uint256).max, type(uint256).max);
        assertTrue(sybilOk, "sybil stake");
        assertEq(treasury.availableForSubsidies(), 1 ether, "treasury drained by the front-run");

        uint256 walletBefore = token.balanceOf(defender);
        (bool ok, bytes memory ret) = _depositWithSubsidy(ilrm, defender, id, type(uint256).max, maxTopUp);

        assertEq(walletBefore - token.balanceOf(defender), 0, "defender charged above its top-up bound");
        assertFalse(ok, "shrunken grant must revert");
        assertEq(ret, abi.encodeWithSignature("Error(string)", "Top-up exceeds max"));
        assertFalse(treasury.disputeSubsidized(id), "subsidy reserved");
        assertEq(ilrm.disputes(id).counterpartyStake, 0, "stake recorded");
    }

    // =========================================================================
    // (2) Initiator-incentive farming
    // =========================================================================

    /// @notice One dispute staked at 10x the reserves used to take all of them as its 10% incentive
    function test_Regression_SingleDisputeCannotDrainReserves() public {
        ilrm.depositTokenReserves(1000e18);
        uint256 stake = 10_000e18;
        address absent = makeAddr("absent-counterparty");

        uint256 before = token.balanceOf(initiator);
        uint256 id = _open(ilrm, initiator, absent, stake);
        vm.warp(block.timestamp + ilrm.STAKE_WINDOW() + 1);
        ilrm.enforceTimeout(id);

        assertGe(token.balanceOf(initiator), before, "stake not returned");
        uint256 incentive = token.balanceOf(initiator) - before;
        assertLe(incentive, DEFAULT_MAX_INCENTIVE_PER_DISPUTE, "single dispute drained the reserves");
        assertEq(ilrm.tokenReserves(), 1000e18 - incentive);
        assertEq(token.balanceOf(address(ilrm)), ilrm.tokenReserves(), "ILRM balance != tokenReserves");
    }

    /// @notice Fresh sybil counterparties that never stake farm at most the window cap per window
    function test_Regression_SybilFarmingBoundedPerWindow() public {
        ilrm.depositTokenReserves(1000e18);

        uint256 n = 60;
        uint256 span = 36 days;
        uint256 t0 = block.timestamp;

        // One dispute every span / n against a fresh never-staking counterparty (and a fresh initiator),
        // each resolved as soon as its stake window has passed
        for (uint256 i = 0; i < n; i++) {
            uint256 openAt = t0 + i * (span / n);
            _resolveFarmsDueBy(openAt);
            vm.warp(openAt);
            _openFarm(i);
        }
        _resolveFarmsDueBy(type(uint256).max);
        assertEq(farmResolved, n);

        assertLe(lastPayout - firstPayout, span, "payouts spread over the span");
        uint256 windows = (span + DEFAULT_INCENTIVE_WINDOW - 1) / DEFAULT_INCENTIVE_WINDOW + 1;
        assertLe(farmed, DEFAULT_MAX_INCENTIVE_PER_WINDOW * windows, "farming exceeded the window cap");
        assertLe(farmed, 30e18);
        assertEq(ilrm.tokenReserves(), 1000e18 - farmed);
        assertEq(token.balanceOf(address(ilrm)), ilrm.tokenReserves(), "ILRM balance != tokenReserves");
    }

    // =========================================================================
    // (3) Treasury records keyed per (ILRM, disputeId)
    // =========================================================================

    /// @notice After setILRM to a redeployed ILRM, its dispute 0 must not collide with the old ILRM's dispute 0
    function test_Regression_RedeployedILRM_DisputeIdsDoNotCollide() public {
        token.mint(address(treasury), 1000 ether);
        uint256 stake = 10 ether;

        // Old ILRM (A): dispute 0 is subsidized
        address defenderA = _newParty("defenderA", 0, ilrm);
        uint256 idA = _open(ilrm, initiator, defenderA, stake);
        assertEq(idA, 0);
        (bool okA,) = _depositWithSubsidy(ilrm, defenderA, idA, type(uint256).max, type(uint256).max);
        assertTrue(okA, "A#0 subsidy");
        assertTrue(treasury.disputeSubsidized(0));

        // Redeploy ILRM (B) and re-point the Treasury
        ILRM ilrmB = new ILRM(IERC20(address(token)), address(oracle), registry);
        treasury.setILRM(address(ilrmB));
        ilrmB.setSubsidyTreasury(address(treasury));
        vm.prank(initiator);
        token.approve(address(ilrmB), type(uint256).max);
        address defenderB = _newParty("defenderB", 0, ilrmB);
        uint256 idB = _open(ilrmB, initiator, defenderB, stake);
        assertEq(idB, 0, "IDs restart per ILRM deployment");

        (uint256 preview, bool eligible) = treasury.calculateSubsidy(0, stake, defenderB);
        (bool okB, bytes memory ret) = _depositWithSubsidy(ilrmB, defenderB, idB, type(uint256).max, type(uint256).max);

        assertTrue(okB, string.concat("B#0 subsidized stake reverted: ", vm.toString(ret)));
        assertTrue(eligible, "B#0 previewed as already subsidized");
        assertEq(preview, stake);
        (address funder, uint256 granted) = ilrmB.stakeSubsidy(0);
        assertEq(funder, address(treasury));
        assertEq(granted, stake);
        assertTrue(treasury.disputeSubsidized(0));
        assertEq(treasury.disputeSubsidyRecipient(0), defenderB, "1-arg view must reflect the wired ILRM");
    }

    // =========================================================================
    // (4) Gas: unsubsidized payouts read only the subsidy amount slot
    // =========================================================================

    /// @notice Timeout path: an unsubsidized resolution must not load the subsidy funder slot
    function test_Regression_UnsubsidizedPayout_ReadsOnlyAmountSlot() public {
        address cp = _newParty("plain-cp", 10 ether, ilrm);
        uint256 id = _open(ilrm, initiator, cp, 10 ether);
        vm.prank(cp);
        ilrm.depositStake(id);
        bytes32 funderSlot = _funderSlot(id);

        vm.warp(block.timestamp + ilrm.RESOLUTION_TIMEOUT() + 1);
        vm.record();
        ilrm.enforceTimeout(id);
        _assertNotRead(funderSlot);
        assertEq(token.balanceOf(cp), 5 ether, "timeout payout changed");
    }

    /// @notice Accept path: an unsubsidized resolution must not load the subsidy funder slot
    function test_Regression_UnsubsidizedPayout_ReadsOnlyAmountSlot_AcceptPath() public {
        address cp = _newParty("plain-cp", 10 ether, ilrm);
        uint256 id = _open(ilrm, initiator, cp, 10 ether);
        vm.prank(cp);
        ilrm.depositStake(id);
        bytes32 funderSlot = _funderSlot(id);

        vm.prank(address(oracle));
        ilrm.submitLLMProposal(id, "split the royalties", "");
        vm.prank(initiator);
        ilrm.acceptProposal(id);

        vm.record();
        vm.prank(cp);
        ilrm.acceptProposal(id); // resolves
        _assertNotRead(funderSlot);
        assertEq(token.balanceOf(cp), 10 ether, "accept payout changed");
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _openFarm(uint256 i) internal {
        address farmer = _newParty(string.concat("farmer", vm.toString(i)), FARM_STAKE, ilrm);
        farmers.push(farmer);
        farmIds.push(_open(ilrm, farmer, makeAddr(string.concat("absent", vm.toString(i))), FARM_STAKE));
        farmOpenedAt.push(block.timestamp);
    }

    /// @dev Resolve (in order) every farming dispute whose stake window has passed by time `t`
    function _resolveFarmsDueBy(uint256 t) internal {
        while (farmResolved < farmIds.length) {
            uint256 due = farmOpenedAt[farmResolved] + ilrm.STAKE_WINDOW() + 1;
            if (due > t) return;
            vm.warp(due);
            ilrm.enforceTimeout(farmIds[farmResolved]);
            uint256 bal = token.balanceOf(farmers[farmResolved]);
            assertGe(bal, FARM_STAKE, "stake not returned");
            farmed += bal - FARM_STAKE;
            if (farmResolved == 0) firstPayout = block.timestamp;
            lastPayout = block.timestamp;
            farmResolved++;
        }
    }

    function _newParty(string memory label, uint256 funds, ILRM target) internal returns (address party) {
        party = makeAddr(label);
        if (funds > 0) token.mint(party, funds);
        vm.prank(party);
        token.approve(address(target), type(uint256).max);
    }

    function _open(ILRM target, address from, address counterparty, uint256 stake) internal returns (uint256 id) {
        vm.prank(from);
        id = target.initiateBreachDispute(
            counterparty, stake, keccak256(abi.encode(from, counterparty, stake)), fallbackLicense
        );
    }

    /// @dev 3-argument depositStakeWithSubsidy; retried with the 2-argument form only when the 3-argument
    ///      selector does not exist (empty revert data)
    function _depositWithSubsidy(ILRM target, address caller, uint256 id, uint256 maxSubsidy, uint256 maxTopUp)
        internal
        returns (bool ok, bytes memory revertData)
    {
        vm.prank(caller);
        (ok, revertData) = address(target)
            .call(abi.encodeWithSignature("depositStakeWithSubsidy(uint256,uint256,uint256)", id, maxSubsidy, maxTopUp));
        if (!ok && revertData.length == 0) {
            vm.prank(caller);
            (ok, revertData) = address(target)
                .call(abi.encodeWithSignature("depositStakeWithSubsidy(uint256,uint256)", id, maxSubsidy));
        }
    }

    /// @dev Finds the storage slot holding StakeSubsidy.funder for `id` without assuming the layout: record
    ///      the slots stakeSubsidy(id) reads, then find the one that changes the returned funder
    function _funderSlot(uint256 id) internal returns (bytes32) {
        vm.record();
        ilrm.stakeSubsidy(id);
        (bytes32[] memory reads,) = vm.accesses(address(ilrm));
        address marker = address(0xBEEF);
        for (uint256 i = 0; i < reads.length; i++) {
            bytes32 old = vm.load(address(ilrm), reads[i]);
            vm.store(address(ilrm), reads[i], bytes32(uint256(uint160(marker))));
            (address funder,) = ilrm.stakeSubsidy(id);
            vm.store(address(ilrm), reads[i], old);
            if (funder == marker) return reads[i];
        }
        revert("funder slot not found");
    }

    function _assertNotRead(bytes32 slot) internal view {
        (bytes32[] memory reads,) = vm.accesses(address(ilrm));
        assertGt(reads.length, 0, "no reads recorded");
        for (uint256 i = 0; i < reads.length; i++) {
            assertTrue(reads[i] != slot, "unsubsidized payout read the subsidy funder slot");
        }
    }
}
