// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/ILRM.sol";
import "../contracts/Treasury.sol";
import "../contracts/mocks/MockAssetRegistry.sol";
import "../contracts/mocks/MockOracle.sol";
import "../contracts/mocks/MockToken.sol";
import "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

// ============ Adversarial treasury mocks ============

/// @notice Reports the requested amount as granted but never approves ILRM to pull it
contract NonPayingTreasury is ISubsidyTreasury {
    function fundStakeSubsidy(uint256, address, uint256 maxAmount) external pure returns (uint256) {
        return maxAmount;
    }
}

/// @notice Approves and reports more than ILRM asked for
contract OverReportingTreasury is ISubsidyTreasury {
    IERC20 public immutable token;

    constructor(IERC20 _token) {
        token = _token;
    }

    function fundStakeSubsidy(uint256, address, uint256 maxAmount) external returns (uint256) {
        token.approve(msg.sender, maxAmount + 1);
        return maxAmount + 1;
    }
}

/// @notice Grants nothing but returns successfully
contract ZeroGrantTreasury is ISubsidyTreasury {
    function fundStakeSubsidy(uint256, address, uint256) external pure returns (uint256) {
        return 0;
    }
}

/// @notice Tries to re-enter ILRM from inside fundStakeSubsidy
contract ReentrantTreasury is ISubsidyTreasury {
    enum Mode {
        DepositStake,
        DepositStakeWithSubsidy,
        AcceptProposal,
        EnforceTimeout
    }

    ILRM public immutable ilrm;
    Mode public mode;

    constructor(ILRM _ilrm) {
        ilrm = _ilrm;
    }

    function setMode(Mode _mode) external {
        mode = _mode;
    }

    function fundStakeSubsidy(uint256 disputeId, address, uint256 maxAmount) external returns (uint256) {
        if (mode == Mode.DepositStake) {
            ilrm.depositStake(disputeId);
        } else if (mode == Mode.DepositStakeWithSubsidy) {
            ilrm.depositStakeWithSubsidy(disputeId, maxAmount);
        } else if (mode == Mode.AcceptProposal) {
            ilrm.acceptProposal(disputeId);
        } else {
            ilrm.enforceTimeout(disputeId);
        }
        return maxAmount;
    }
}

/**
 * @title TreasurySubsidyTest
 * @notice Treasury-backed defensive stake subsidies: ILRM.depositStakeWithSubsidy escrows the subsidy
 *         as part of the counterparty stake and repays the funder pro rata on every resolution path.
 */
contract TreasurySubsidyTest is Test {
    ILRM internal ilrm;
    NatLangChainTreasury internal treasury;
    MockToken internal token;
    MockAssetRegistry internal registry;
    MockOracle internal oracle;

    address internal owner = address(this);
    address internal initiator = makeAddr("initiator");
    address internal defender = makeAddr("defender");
    address internal attacker = makeAddr("attacker");

    address internal constant BURN = 0x000000000000000000000000000000000000dEaD;

    uint256 internal constant MAX_PER_DISPUTE = 100 ether;
    uint256 internal constant MAX_PER_PARTICIPANT = 1000 ether;
    uint256 internal constant WINDOW = 30 days;
    uint256 internal constant TREASURY_FUNDS = 10_000 ether;
    uint256 internal constant STAKE = 10 ether;

    IILRM.FallbackLicense internal fallbackLicense = IILRM.FallbackLicense({
        termsHash: keccak256("fallback"), termDuration: 365 days, royaltyCapBps: 500, nonExclusive: true
    });

    // Mirrors of the contract events, for vm.expectEmit (solc 0.8.20 has no qualified event access)
    event SubsidyFunded(address indexed participant, uint256 indexed disputeId, uint256 amount);
    event StakeSubsidized(
        uint256 indexed disputeId, address indexed counterparty, address indexed funder, uint256 amount
    );
    event StakeDeposited(uint256 indexed disputeId, address indexed depositor, uint256 amount);
    event SubsidyReturned(uint256 indexed disputeId, address indexed funder, uint256 amount);
    event SubsidyTreasuryUpdated(address indexed previousTreasury, address indexed newTreasury);

    function setUp() public {
        token = new MockToken();
        registry = new MockAssetRegistry();
        oracle = new MockOracle();
        ilrm = new ILRM(IERC20(address(token)), address(oracle), registry);
        treasury = new NatLangChainTreasury(IERC20(address(token)), MAX_PER_DISPUTE, MAX_PER_PARTICIPANT, WINDOW);
        treasury.setILRM(address(ilrm));
        ilrm.setSubsidyTreasury(address(treasury));

        token.mint(address(treasury), TREASURY_FUNDS);
        token.approve(address(ilrm), type(uint256).max); // owner funds tokenReserves in some tests

        // Initiator is well funded; the defender starts with nothing (low-resource)
        token.mint(initiator, 1_000_000 ether);
        vm.prank(initiator);
        token.approve(address(ilrm), type(uint256).max);
        vm.prank(defender);
        token.approve(address(ilrm), type(uint256).max);
        token.mint(attacker, 1000 ether);
        vm.prank(attacker);
        token.approve(address(ilrm), type(uint256).max);
    }

    // =========================================================================
    // Funding
    // =========================================================================

    function test_FullSubsidy_ZeroBalanceDefender() public {
        uint256 id = _open(defender, STAKE);
        uint256 treasuryBefore = token.balanceOf(address(treasury));

        vm.expectEmit(true, true, true, true, address(treasury));
        emit SubsidyFunded(defender, id, STAKE);
        vm.expectEmit(true, true, true, true, address(ilrm));
        emit StakeSubsidized(id, defender, address(treasury), STAKE);
        vm.expectEmit(true, true, true, true, address(ilrm));
        emit StakeDeposited(id, defender, STAKE);

        vm.prank(defender);
        ilrm.depositStakeWithSubsidy(id, type(uint256).max);

        assertEq(token.balanceOf(defender), 0, "wallet must stay empty");
        assertEq(ilrm.disputes(id).counterpartyStake, STAKE, "stake not symmetric");
        _assertSubsidy(id, address(treasury), STAKE);
        assertEq(token.balanceOf(address(ilrm)), 2 * STAKE, "escrow must hold both stakes");
        assertEq(token.allowance(address(treasury), address(ilrm)), 0, "leftover treasury allowance");
        assertEq(treasuryBefore - token.balanceOf(address(treasury)), STAKE);
        assertTrue(treasury.disputeSubsidized(id));
        assertEq(treasury.disputeSubsidyRecipient(id), defender);
        assertEq(treasury.participantSubsidyUsed(defender), STAKE);
        assertEq(treasury.totalSubsidiesDistributed(), STAKE);
    }

    function test_PartialSubsidy_TopUp() public {
        uint256 stake = MAX_PER_DISPUTE + 50 ether;
        uint256 topUp = stake - MAX_PER_DISPUTE;
        token.mint(defender, topUp);
        uint256 id = _open(defender, stake);

        vm.prank(defender);
        ilrm.depositStakeWithSubsidy(id, type(uint256).max);

        _assertSubsidy(id, address(treasury), MAX_PER_DISPUTE);
        assertEq(token.balanceOf(defender), 0, "defender must pay exactly stake - maxPerDispute");
        assertEq(ilrm.disputes(id).counterpartyStake, stake);
        assertEq(token.balanceOf(address(ilrm)), 2 * stake);
        assertEq(TREASURY_FUNDS - token.balanceOf(address(treasury)), MAX_PER_DISPUTE);
    }

    function test_MaxSubsidyBelowGrant_ConservesAllowance() public {
        uint256 maxSubsidy = 4 ether;
        token.mint(defender, STAKE);
        uint256 id = _open(defender, STAKE);

        vm.prank(defender);
        ilrm.depositStakeWithSubsidy(id, maxSubsidy);

        _assertSubsidy(id, address(treasury), maxSubsidy);
        assertEq(treasury.participantSubsidyUsed(defender), maxSubsidy);
        assertEq(treasury.getRemainingAllowance(defender), MAX_PER_PARTICIPANT - maxSubsidy);
        assertEq(token.balanceOf(defender), maxSubsidy, "defender pays stake - maxSubsidy");
    }

    function test_SubsidyCappedAtStake() public {
        uint256 id = _open(defender, 1);

        vm.prank(defender);
        ilrm.depositStakeWithSubsidy(id, type(uint256).max);

        _assertSubsidy(id, address(treasury), 1);
        assertEq(treasury.participantSubsidyUsed(defender), 1);
        assertEq(TREASURY_FUNDS - token.balanceOf(address(treasury)), 1);
        assertEq(token.balanceOf(address(ilrm)), 2);
    }

    /// @notice Even if ILRM asked for more, the treasury never grants more than the dispute's stake
    function test_TreasuryCapsGrantAtStake() public {
        token.mint(defender, STAKE);
        uint256 id = _open(defender, STAKE);
        vm.prank(defender);
        ilrm.depositStake(id); // matching stake committed, no subsidy recorded

        vm.prank(address(ilrm));
        uint256 granted = treasury.fundStakeSubsidy(id, defender, type(uint256).max);

        assertEq(granted, STAKE);
        assertEq(token.allowance(address(treasury), address(ilrm)), STAKE);
    }

    function test_EscalatedStakeCovered() public {
        _open(defender, STAKE);
        uint256 id = _open(defender, STAKE); // repeat dispute within cooldown => 1.5x
        uint256 escalated = (STAKE * ilrm.ESCALATION_MULTIPLIER()) / 100;
        assertEq(ilrm.disputes(id).initiatorStake, escalated);

        vm.prank(defender);
        ilrm.depositStakeWithSubsidy(id, type(uint256).max);

        IILRM.Dispute memory d = ilrm.disputes(id);
        assertEq(d.counterpartyStake, d.initiatorStake, "stakes must stay symmetric");
        _assertSubsidy(id, address(treasury), escalated);
        assertEq(token.balanceOf(defender), 0);
    }

    function test_MissingTopUpRevertsAtomically() public {
        uint256 stake = MAX_PER_DISPUTE + 50 ether;
        token.mint(defender, 50 ether);
        uint256 id = _open(defender, stake);
        vm.prank(defender);
        token.approve(address(ilrm), 0);

        uint256 escrowBefore = token.balanceOf(address(ilrm));

        vm.prank(defender);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(ilrm), 0, 50 ether)
        );
        ilrm.depositStakeWithSubsidy(id, type(uint256).max);

        _assertNothingReserved(id, escrowBefore);
        assertEq(token.balanceOf(defender), 50 ether);
    }

    function test_PartialTopUpRevertsAtomically() public {
        uint256 stake = MAX_PER_DISPUTE + 50 ether;
        token.mint(defender, 49 ether); // one token short of the top-up
        uint256 id = _open(defender, stake);
        uint256 escrowBefore = token.balanceOf(address(ilrm));

        vm.prank(defender);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, defender, 49 ether, 50 ether)
        );
        ilrm.depositStakeWithSubsidy(id, type(uint256).max);

        _assertNothingReserved(id, escrowBefore);
        assertEq(token.balanceOf(defender), 49 ether);
    }

    // =========================================================================
    // Access control and state checks
    // =========================================================================

    function test_Revert_NotCounterparty() public {
        uint256 id = _open(defender, STAKE);

        vm.prank(initiator);
        vm.expectRevert("Not counterparty");
        ilrm.depositStakeWithSubsidy(id, STAKE);

        vm.prank(attacker);
        vm.expectRevert("Not counterparty");
        ilrm.depositStakeWithSubsidy(id, STAKE);

        assertFalse(treasury.disputeSubsidized(id));
    }

    function test_Revert_AlreadyStaked_AfterPlainStake() public {
        token.mint(defender, STAKE);
        uint256 id = _open(defender, STAKE);
        vm.prank(defender);
        ilrm.depositStake(id);

        vm.prank(defender);
        vm.expectRevert("Already staked");
        ilrm.depositStakeWithSubsidy(id, STAKE);
    }

    function test_Revert_AlreadyStaked_AfterSubsidizedStake() public {
        token.mint(defender, STAKE);
        uint256 id = _open(defender, STAKE);
        vm.prank(defender);
        ilrm.depositStakeWithSubsidy(id, STAKE);

        vm.prank(defender);
        vm.expectRevert("Already staked");
        ilrm.depositStake(id);

        vm.prank(defender);
        vm.expectRevert("Already staked");
        ilrm.depositStakeWithSubsidy(id, STAKE);
    }

    function test_Revert_StakeWindowClosed() public {
        uint256 id = _open(defender, STAKE);
        vm.warp(block.timestamp + ilrm.STAKE_WINDOW() + 1);

        vm.prank(defender);
        vm.expectRevert("Stake window closed");
        ilrm.depositStakeWithSubsidy(id, STAKE);
    }

    function test_Revert_ResolvedDispute() public {
        uint256 id = _open(defender, STAKE);
        vm.warp(block.timestamp + ilrm.STAKE_WINDOW() + 1);
        ilrm.enforceTimeout(id);

        vm.prank(defender);
        vm.expectRevert("Dispute resolved");
        ilrm.depositStakeWithSubsidy(id, STAKE);
    }

    function test_Revert_SubsidiesDisabled_PlainStakeStillWorks() public {
        token.mint(defender, 2 * STAKE);

        // Never configured
        ILRM fresh = new ILRM(IERC20(address(token)), address(oracle), registry);
        assertEq(fresh.subsidyTreasury(), address(0));
        vm.prank(initiator);
        token.approve(address(fresh), type(uint256).max);
        vm.prank(defender);
        token.approve(address(fresh), type(uint256).max);
        vm.prank(initiator);
        uint256 freshId = fresh.initiateBreachDispute(defender, STAKE, bytes32(0), fallbackLicense);

        vm.prank(defender);
        vm.expectRevert("Subsidies disabled");
        fresh.depositStakeWithSubsidy(freshId, STAKE);
        vm.prank(defender);
        fresh.depositStake(freshId);
        assertEq(fresh.disputes(freshId).counterpartyStake, STAKE);

        // Explicitly zeroed
        ilrm.setSubsidyTreasury(address(0));
        uint256 id = _open(defender, STAKE);
        vm.prank(defender);
        vm.expectRevert("Subsidies disabled");
        ilrm.depositStakeWithSubsidy(id, STAKE);
        vm.prank(defender);
        ilrm.depositStake(id);
        assertEq(ilrm.disputes(id).counterpartyStake, STAKE);
        assertEq(token.balanceOf(address(treasury)), TREASURY_FUNDS);
    }

    function test_Revert_ZeroSubsidy() public {
        uint256 id = _open(defender, STAKE);
        vm.prank(defender);
        vm.expectRevert("Zero subsidy");
        ilrm.depositStakeWithSubsidy(id, 0);
    }

    function test_Revert_IlrmPaused() public {
        uint256 id = _open(defender, STAKE);
        ilrm.pause();

        vm.prank(defender);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        ilrm.depositStakeWithSubsidy(id, STAKE);
    }

    function test_Revert_TreasuryPaused_PlainStakeStillWorks() public {
        token.mint(defender, STAKE);
        uint256 id = _open(defender, STAKE);
        treasury.pause();

        vm.prank(defender);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        ilrm.depositStakeWithSubsidy(id, STAKE);

        vm.prank(defender);
        ilrm.depositStake(id);
        assertEq(ilrm.disputes(id).counterpartyStake, STAKE);
        assertEq(token.balanceOf(address(treasury)), TREASURY_FUNDS);
    }

    function test_Revert_HarassmentFlagged() public {
        treasury.setHarassmentScore(defender, 50);
        uint256 id = _open(defender, STAKE);

        vm.prank(defender);
        vm.expectRevert(abi.encodeWithSelector(NatLangChainTreasury.ParticipantFlaggedForAbuse.selector, defender, 50));
        ilrm.depositStakeWithSubsidy(id, STAKE);
    }

    function test_Revert_RollingCapExhausted() public {
        treasury.updateCaps(MAX_PER_DISPUTE, STAKE, WINDOW);
        uint256 first = _open(defender, STAKE);
        vm.prank(defender);
        ilrm.depositStakeWithSubsidy(first, STAKE);
        assertEq(treasury.getRemainingAllowance(defender), 0);

        address otherInitiator = makeAddr("otherInitiator");
        token.mint(otherInitiator, STAKE);
        vm.startPrank(otherInitiator);
        token.approve(address(ilrm), type(uint256).max);
        uint256 second = ilrm.initiateBreachDispute(defender, STAKE, bytes32(0), fallbackLicense);
        vm.stopPrank();

        vm.prank(defender);
        vm.expectRevert(NatLangChainTreasury.NoSubsidyAvailable.selector);
        ilrm.depositStakeWithSubsidy(second, STAKE);
    }

    function test_Revert_DirectFundStakeSubsidy_NotILRM() public {
        uint256 id = _open(defender, STAKE);

        address[3] memory callers = [defender, attacker, owner];
        for (uint256 i = 0; i < callers.length; i++) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(NatLangChainTreasury.NotILRM.selector, callers[i]));
            treasury.fundStakeSubsidy(id, defender, STAKE);
        }
        assertFalse(treasury.disputeSubsidized(id));
    }

    function test_Revert_FundStakeSubsidy_NotEscrowed() public {
        uint256 id = _open(defender, STAKE);

        vm.prank(address(ilrm));
        vm.expectRevert(abi.encodeWithSelector(NatLangChainTreasury.SubsidyNotEscrowed.selector, id));
        treasury.fundStakeSubsidy(id, defender, STAKE);
    }

    function test_Revert_FundStakeSubsidy_AlreadySubsidized() public {
        uint256 id = _open(defender, STAKE);
        vm.prank(defender);
        ilrm.depositStakeWithSubsidy(id, STAKE);

        vm.prank(address(ilrm));
        vm.expectRevert(abi.encodeWithSelector(NatLangChainTreasury.DisputeAlreadySubsidized.selector, id));
        treasury.fundStakeSubsidy(id, defender, STAKE);
    }

    function test_Revert_FundStakeSubsidy_ParticipantChecks() public {
        token.mint(defender, STAKE);
        uint256 id = _open(defender, STAKE);
        vm.prank(defender);
        ilrm.depositStake(id);

        vm.startPrank(address(ilrm));
        vm.expectRevert(abi.encodeWithSelector(NatLangChainTreasury.NotCounterparty.selector, attacker, defender));
        treasury.fundStakeSubsidy(id, attacker, STAKE);

        vm.expectRevert(abi.encodeWithSelector(NatLangChainTreasury.NotCounterparty.selector, initiator, defender));
        treasury.fundStakeSubsidy(id, initiator, STAKE);

        vm.expectRevert(NatLangChainTreasury.ZeroAmount.selector);
        treasury.fundStakeSubsidy(id, defender, 0);
        vm.stopPrank();

        vm.warp(block.timestamp + ilrm.RESOLUTION_TIMEOUT() + 1);
        ilrm.enforceTimeout(id);

        vm.prank(address(ilrm));
        vm.expectRevert(abi.encodeWithSelector(NatLangChainTreasury.DisputeAlreadyResolved.selector, id));
        treasury.fundStakeSubsidy(id, defender, STAKE);
    }

    function test_SetSubsidyTreasury_OnlyOwner() public {
        address newTreasury = makeAddr("newTreasury");

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        ilrm.setSubsidyTreasury(newTreasury);

        vm.expectEmit(true, true, false, false, address(ilrm));
        emit SubsidyTreasuryUpdated(address(treasury), newTreasury);
        ilrm.setSubsidyTreasury(newTreasury);
        assertEq(ilrm.subsidyTreasury(), newTreasury);

        vm.expectEmit(true, true, false, false, address(ilrm));
        emit SubsidyTreasuryUpdated(newTreasury, address(0));
        ilrm.setSubsidyTreasury(address(0));
        assertEq(ilrm.subsidyTreasury(), address(0));
    }

    // =========================================================================
    // Resolution paths
    // =========================================================================

    function test_Accept_RepaysSubsidyInFull() public {
        ilrm.depositTokenReserves(5 ether);
        uint256 stake = MAX_PER_DISPUTE + 50 ether;
        uint256 topUp = 50 ether;
        token.mint(defender, topUp);
        uint256 id = _open(defender, stake);
        uint256 initiatorAfterStake = token.balanceOf(initiator);

        vm.prank(defender);
        ilrm.depositStakeWithSubsidy(id, type(uint256).max);
        assertEq(token.balanceOf(address(treasury)), TREASURY_FUNDS - MAX_PER_DISPUTE);

        _propose(id);
        vm.prank(initiator);
        ilrm.acceptProposal(id);

        vm.expectEmit(true, true, false, true, address(ilrm));
        emit SubsidyReturned(id, address(treasury), MAX_PER_DISPUTE);
        vm.prank(defender);
        ilrm.acceptProposal(id);

        assertEq(token.balanceOf(address(treasury)), TREASURY_FUNDS, "treasury not made whole");
        assertEq(token.balanceOf(defender), topUp, "defender must get back only its top-up");
        assertEq(token.balanceOf(initiator) - initiatorAfterStake, stake, "initiator stake not returned");
        assertEq(token.balanceOf(address(ilrm)), ilrm.tokenReserves(), "funds stuck in ILRM");
        assertEq(uint256(ilrm.disputes(id).outcome), uint256(IILRM.DisputeOutcome.AcceptedProposal));
    }

    function test_Timeout_ProRataSplit() public {
        uint256 stake = 8e18;
        uint256 subsidy = 5e18;
        token.mint(defender, stake - subsidy);
        uint256 id = _open(defender, stake);
        uint256 initiatorAfterStake = token.balanceOf(initiator);

        vm.prank(defender);
        ilrm.depositStakeWithSubsidy(id, subsidy);
        assertEq(token.balanceOf(defender), 0);

        vm.warp(block.timestamp + ilrm.RESOLUTION_TIMEOUT() + 1);
        vm.expectEmit(true, true, false, true, address(ilrm));
        emit SubsidyReturned(id, address(treasury), 2.5e18);
        ilrm.enforceTimeout(id);

        assertEq(token.balanceOf(BURN), 8e18, "burn changed");
        assertEq(token.balanceOf(initiator) - initiatorAfterStake, 4e18, "initiator payout changed");
        assertEq(token.balanceOf(address(treasury)), TREASURY_FUNDS - subsidy + 2.5e18, "funder share");
        assertEq(token.balanceOf(defender), 1.5e18, "defender share");
        assertEq(token.balanceOf(address(ilrm)), 0);
    }

    function test_Timeout_FullSubsidy_DefenderGetsNothing_TreasuryHalf() public {
        uint256 id = _open(defender, STAKE);
        uint256 initiatorAfterStake = token.balanceOf(initiator);

        vm.prank(defender);
        ilrm.depositStakeWithSubsidy(id, STAKE);

        vm.warp(block.timestamp + ilrm.RESOLUTION_TIMEOUT() + 1);
        ilrm.enforceTimeout(id);

        assertEq(token.balanceOf(defender), 0, "fully subsidized defender must get nothing");
        assertEq(token.balanceOf(address(treasury)), TREASURY_FUNDS - STAKE / 2, "treasury gets half back");
        assertEq(token.balanceOf(initiator) - initiatorAfterStake, STAKE / 2);
        assertEq(token.balanceOf(BURN), STAKE);
        assertEq(token.balanceOf(address(ilrm)), 0);
    }

    function test_Timeout_OddWeiRounding() public {
        // stake S, subsidy s => counterparty side R = floor(S/2), defender floor(R(S-s)/S), funder the rest
        uint256[3] memory stakes = [uint256(1), 3, 7];
        uint256[3] memory subsidies = [uint256(1), 2, 3];
        uint256[3] memory expectedDefender = [uint256(0), 0, 1];
        uint256[3] memory expectedFunder = [uint256(0), 1, 2];

        for (uint256 i = 0; i < stakes.length; i++) {
            uint256 snap = vm.snapshotState();
            uint256 stake = stakes[i];
            uint256 subsidy = subsidies[i];
            token.mint(defender, stake - subsidy);
            uint256 id = _open(defender, stake);
            uint256 initiatorAfterStake = token.balanceOf(initiator);

            vm.prank(defender);
            ilrm.depositStakeWithSubsidy(id, subsidy);
            _assertSubsidy(id, address(treasury), subsidy);

            vm.warp(block.timestamp + ilrm.RESOLUTION_TIMEOUT() + 1);
            ilrm.enforceTimeout(id);

            uint256 returnPerParty = stake / 2;
            assertEq(token.balanceOf(BURN), stake + (stake % 2), "burn + dust changed");
            assertEq(token.balanceOf(initiator) - initiatorAfterStake, returnPerParty, "initiator payout");
            assertEq(token.balanceOf(defender), expectedDefender[i], "defender share must round down");
            assertEq(
                token.balanceOf(address(treasury)), TREASURY_FUNDS - subsidy + expectedFunder[i], "funder remainder"
            );
            assertEq(expectedDefender[i] + expectedFunder[i], returnPerParty);
            assertEq(token.balanceOf(address(ilrm)), 0);

            vm.revertToState(snap);
        }
    }

    function test_NonParticipation_TreasuryUntouched() public {
        ilrm.depositTokenReserves(100 ether);
        uint256 initiatorBefore = token.balanceOf(initiator);
        uint256 id = _open(defender, STAKE);

        vm.warp(block.timestamp + ilrm.STAKE_WINDOW() + 1);
        ilrm.enforceTimeout(id);

        uint256 incentive = (STAKE * ilrm.INITIATOR_INCENTIVE_BPS()) / 10_000;
        assertEq(token.balanceOf(initiator) - initiatorBefore, incentive, "initiator gets stake + 10%");
        assertEq(token.balanceOf(address(treasury)), TREASURY_FUNDS);
        assertFalse(treasury.disputeSubsidized(id));
        _assertSubsidy(id, address(0), 0);
        assertEq(registry.appliedFallbacks(id), fallbackLicense.termsHash);
        assertEq(uint256(ilrm.disputes(id).outcome), uint256(IILRM.DisputeOutcome.DefaultLicenseApplied));
    }

    function test_UnsubsidizedPayoutsUnchanged() public {
        address cp = makeAddr("funded-cp");
        token.mint(cp, 1000 ether);
        vm.prank(cp);
        token.approve(address(ilrm), type(uint256).max);

        vm.recordLogs();

        // Mutual acceptance: both get exactly their stake back
        uint256 acceptId = _open(cp, STAKE);
        vm.prank(cp);
        ilrm.depositStake(acceptId);
        uint256 initiatorBefore = token.balanceOf(initiator);
        uint256 cpBefore = token.balanceOf(cp);
        _propose(acceptId);
        vm.prank(initiator);
        ilrm.acceptProposal(acceptId);
        vm.prank(cp);
        ilrm.acceptProposal(acceptId);
        assertEq(token.balanceOf(initiator) - initiatorBefore, STAKE);
        assertEq(token.balanceOf(cp) - cpBefore, STAKE);

        // Timeout with an odd stake: S burned, floor(S/2) each, dust burned
        address cp2 = makeAddr("funded-cp2");
        token.mint(cp2, 1000 ether);
        vm.prank(cp2);
        token.approve(address(ilrm), type(uint256).max);
        uint256 oddStake = 7 ether + 1;
        uint256 timeoutId = _open(cp2, oddStake);
        vm.prank(cp2);
        ilrm.depositStake(timeoutId);
        initiatorBefore = token.balanceOf(initiator);
        uint256 cp2Before = token.balanceOf(cp2);
        vm.warp(block.timestamp + ilrm.RESOLUTION_TIMEOUT() + 1);
        ilrm.enforceTimeout(timeoutId);
        assertEq(token.balanceOf(initiator) - initiatorBefore, oddStake / 2);
        assertEq(token.balanceOf(cp2) - cp2Before, oddStake / 2);
        assertEq(token.balanceOf(BURN), oddStake + 1);
        assertEq(token.balanceOf(address(ilrm)), 0);
        assertEq(token.balanceOf(address(treasury)), TREASURY_FUNDS);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != SubsidyReturned.selector, "unexpected SubsidyReturned");
        }
    }

    function test_ResolutionWorksWithTreasuryPausedOrPointerZeroed() public {
        address defender2 = makeAddr("defender2");
        vm.prank(defender2);
        token.approve(address(ilrm), type(uint256).max);

        uint256 acceptId = _open(defender, STAKE);
        vm.prank(defender);
        ilrm.depositStakeWithSubsidy(acceptId, STAKE);
        uint256 timeoutId = _open(defender2, STAKE);
        vm.prank(defender2);
        ilrm.depositStakeWithSubsidy(timeoutId, STAKE);
        _propose(acceptId);

        // Everything that could block a treasury call is switched off
        treasury.pause();
        ilrm.setSubsidyTreasury(address(0));
        ilrm.pause();

        vm.prank(initiator);
        ilrm.acceptProposal(acceptId);
        vm.prank(defender);
        ilrm.acceptProposal(acceptId);
        assertEq(token.balanceOf(address(treasury)), TREASURY_FUNDS - STAKE, "accept repaid in full");

        vm.warp(block.timestamp + ilrm.RESOLUTION_TIMEOUT() + 1);
        ilrm.enforceTimeout(timeoutId);
        assertEq(token.balanceOf(address(treasury)), TREASURY_FUNDS - STAKE / 2, "timeout repaid pro rata");
        assertEq(token.balanceOf(address(ilrm)), 0);
    }

    function test_RepaymentGoesToRecordedFunderAfterRotation() public {
        uint256 id = _open(defender, STAKE);
        vm.prank(defender);
        ilrm.depositStakeWithSubsidy(id, STAKE);

        NatLangChainTreasury treasuryB =
            new NatLangChainTreasury(IERC20(address(token)), MAX_PER_DISPUTE, MAX_PER_PARTICIPANT, WINDOW);
        treasuryB.setILRM(address(ilrm));
        token.mint(address(treasuryB), TREASURY_FUNDS);
        ilrm.setSubsidyTreasury(address(treasuryB));

        _propose(id);
        vm.prank(initiator);
        ilrm.acceptProposal(id);
        vm.prank(defender);
        ilrm.acceptProposal(id);

        assertEq(token.balanceOf(address(treasury)), TREASURY_FUNDS, "original funder must be repaid");
        assertEq(token.balanceOf(address(treasuryB)), TREASURY_FUNDS, "new treasury must be untouched");

        // New subsidized stakes use (and repay) the new treasury
        address defender2 = makeAddr("defender2");
        vm.prank(defender2);
        token.approve(address(ilrm), type(uint256).max);
        uint256 id2 = _open(defender2, STAKE);
        vm.prank(defender2);
        ilrm.depositStakeWithSubsidy(id2, STAKE);
        _assertSubsidy(id2, address(treasuryB), STAKE);
        assertEq(token.balanceOf(address(treasuryB)), TREASURY_FUNDS - STAKE);
    }

    // =========================================================================
    // Adversarial treasuries
    // =========================================================================

    function test_NonPayingTreasury_Reverts() public {
        NonPayingTreasury bad = new NonPayingTreasury();
        token.mint(address(bad), TREASURY_FUNDS);
        ilrm.setSubsidyTreasury(address(bad));
        uint256 id = _open(defender, STAKE);
        uint256 escrowBefore = token.balanceOf(address(ilrm));

        vm.prank(defender);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(ilrm), 0, STAKE)
        );
        ilrm.depositStakeWithSubsidy(id, STAKE);

        assertEq(token.balanceOf(address(ilrm)), escrowBefore, "escrow touched");
        assertEq(ilrm.disputes(id).counterpartyStake, 0);
        _assertSubsidy(id, address(0), 0);
    }

    function test_OverReportingTreasury_InvalidSubsidy() public {
        OverReportingTreasury bad = new OverReportingTreasury(IERC20(address(token)));
        token.mint(address(bad), TREASURY_FUNDS);
        ilrm.setSubsidyTreasury(address(bad));
        uint256 id = _open(defender, STAKE);

        vm.prank(defender);
        vm.expectRevert("Invalid subsidy");
        ilrm.depositStakeWithSubsidy(id, STAKE);
    }

    function test_ZeroGrantTreasury_InvalidSubsidy() public {
        ilrm.setSubsidyTreasury(address(new ZeroGrantTreasury()));
        uint256 id = _open(defender, STAKE);

        vm.prank(defender);
        vm.expectRevert("Invalid subsidy");
        ilrm.depositStakeWithSubsidy(id, STAKE);
    }

    function test_ReentrantTreasury_Blocked() public {
        ReentrantTreasury bad = new ReentrantTreasury(ilrm);
        ilrm.setSubsidyTreasury(address(bad));
        uint256 id = _open(defender, STAKE);

        for (uint8 m = 0; m <= uint8(ReentrantTreasury.Mode.EnforceTimeout); m++) {
            bad.setMode(ReentrantTreasury.Mode(m));
            vm.prank(defender);
            vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
            ilrm.depositStakeWithSubsidy(id, STAKE);
        }
        assertEq(ilrm.disputes(id).counterpartyStake, 0);
    }

    // =========================================================================
    // Fuzz: collusion is never profitable
    // =========================================================================

    function testFuzz_CollusionNeverProfitable(
        uint256 stake,
        uint256 maxSubsidy,
        uint256 maxPerDispute,
        uint256 maxPerParticipant,
        uint8 path
    ) public {
        stake = bound(stake, 1, 1e30);
        maxSubsidy = bound(maxSubsidy, 1, type(uint256).max);
        maxPerDispute = bound(maxPerDispute, 1, 2e30);
        maxPerParticipant = bound(maxPerParticipant, 1, 2e30);
        path = uint8(bound(path, 0, 2)); // 0 = accept, 1 = timeout, 2 = non-participation

        // tokenReserves stay 0: the separate non-participation incentive is out of scope here
        assertEq(ilrm.tokenReserves(), 0);
        treasury.updateCaps(maxPerDispute, maxPerParticipant, WINDOW);
        token.mint(address(treasury), 2e30);

        address colluder = makeAddr("colluder");
        address sybil = makeAddr("sybil");
        token.mint(colluder, stake);
        token.mint(sybil, stake);
        vm.prank(colluder);
        token.approve(address(ilrm), type(uint256).max);
        vm.prank(sybil);
        token.approve(address(ilrm), type(uint256).max);

        uint256 colludersStart = token.balanceOf(colluder) + token.balanceOf(sybil);
        uint256 treasuryStart = token.balanceOf(address(treasury));
        uint256 burnStart = token.balanceOf(BURN);

        vm.prank(colluder);
        uint256 id = ilrm.initiateBreachDispute(sybil, stake, bytes32(0), fallbackLicense);

        if (path == 2) {
            // Never stakes in time: a late subsidized stake is impossible
            vm.warp(block.timestamp + ilrm.STAKE_WINDOW() + 1);
            vm.prank(sybil);
            vm.expectRevert("Stake window closed");
            ilrm.depositStakeWithSubsidy(id, maxSubsidy);
            ilrm.enforceTimeout(id);
        } else {
            vm.prank(sybil);
            ilrm.depositStakeWithSubsidy(id, maxSubsidy);
            (, uint256 granted) = ilrm.stakeSubsidy(id);
            assertGt(granted, 0);
            assertLe(granted, stake);

            if (path == 0) {
                _propose(id);
                vm.prank(colluder);
                ilrm.acceptProposal(id);
                vm.prank(sybil);
                ilrm.acceptProposal(id);
            } else {
                vm.warp(block.timestamp + ilrm.RESOLUTION_TIMEOUT() + 1);
                ilrm.enforceTimeout(id);
            }
        }

        uint256 colludersEnd = token.balanceOf(colluder) + token.balanceOf(sybil);
        uint256 treasuryEnd = token.balanceOf(address(treasury));
        uint256 burned = token.balanceOf(BURN) - burnStart;

        assertLe(colludersEnd, colludersStart, "colluders profited");
        assertLe(treasuryEnd, treasuryStart, "treasury gained");
        uint256 colluderLoss = colludersStart - colludersEnd;
        uint256 treasuryLoss = treasuryStart - treasuryEnd;
        assertLe(treasuryLoss, colluderLoss, "treasury lost more than the colluders");
        if (path != 1) {
            assertEq(treasuryEnd, treasuryStart, "treasury not whole");
        }
        assertEq(token.balanceOf(address(ilrm)), 0, "funds stuck in ILRM");
        assertEq(burned, colluderLoss + treasuryLoss, "tokens not conserved");
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _open(address counterparty, uint256 stake) internal returns (uint256 id) {
        vm.prank(initiator);
        id = ilrm.initiateBreachDispute(
            counterparty, stake, keccak256(abi.encode(counterparty, stake)), fallbackLicense
        );
    }

    function _propose(uint256 id) internal {
        vm.prank(address(oracle));
        ilrm.submitLLMProposal(id, "split the royalties", "");
    }

    function _assertSubsidy(uint256 id, address expectedFunder, uint256 expectedAmount) internal view {
        (address funder, uint256 amount) = ilrm.stakeSubsidy(id);
        assertEq(funder, expectedFunder, "subsidy funder");
        assertEq(amount, expectedAmount, "subsidy amount");
    }

    function _assertNothingReserved(uint256 id, uint256 escrowBefore) internal view {
        assertFalse(treasury.disputeSubsidized(id), "subsidy flag left behind");
        assertEq(token.balanceOf(address(treasury)), TREASURY_FUNDS, "treasury balance changed");
        assertEq(treasury.participantSubsidyUsed(defender), 0, "allowance charged");
        assertEq(treasury.totalSubsidiesDistributed(), 0);
        assertEq(token.allowance(address(treasury), address(ilrm)), 0, "approval left behind");
        assertEq(ilrm.disputes(id).counterpartyStake, 0, "stake recorded");
        assertEq(token.balanceOf(address(ilrm)), escrowBefore, "escrow changed");
        _assertSubsidy(id, address(0), 0);
    }
}
