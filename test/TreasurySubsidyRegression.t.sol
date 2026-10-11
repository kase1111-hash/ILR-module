// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/ILRM.sol";
import "../contracts/Treasury.sol";
import "../contracts/mocks/MockAssetRegistry.sol";
import "../contracts/mocks/MockOracle.sol";
import "../contracts/mocks/MockToken.sol";

/**
 * @title TreasurySubsidyRegression
 * @notice Regression tests for the defensive-subsidy drain: Treasury.requestSubsidy used to pay the
 *         subsidy straight into the counterparty's wallet, for a caller-chosen amount, even after the
 *         stake window, so an initiator with sybil counterparties could drain the Treasury.
 * @dev The subsidy entry points are reached ONLY through low-level calls (results ignored) so this file
 *      compiles both before the fix (requestSubsidy, no ILRM wiring) and after it
 *      (ILRM.depositStakeWithSubsidy + ILRM.setSubsidyTreasury). Every test fails before the fix.
 */
contract TreasurySubsidyRegressionTest is Test {
    ILRM internal ilrm;
    NatLangChainTreasury internal treasury;
    MockToken internal token;
    MockAssetRegistry internal registry;
    MockOracle internal oracle;

    address internal initiator = makeAddr("initiator");

    uint256 internal constant MAX_PER_DISPUTE = 100 ether;
    uint256 internal constant MAX_PER_PARTICIPANT = 1000 ether;
    uint256 internal constant TREASURY_FUNDS = 10_000 ether;
    uint256 internal constant INITIATOR_FUNDS = 1000 ether;

    IILRM.FallbackLicense internal fallbackLicense = IILRM.FallbackLicense({
        termsHash: keccak256("fallback"), termDuration: 365 days, royaltyCapBps: 500, nonExclusive: true
    });

    function setUp() public {
        token = new MockToken();
        registry = new MockAssetRegistry();
        oracle = new MockOracle();
        ilrm = new ILRM(IERC20(address(token)), address(oracle), registry);
        treasury = new NatLangChainTreasury(IERC20(address(token)), MAX_PER_DISPUTE, MAX_PER_PARTICIPANT, 30 days);
        treasury.setILRM(address(ilrm));

        // Wire the subsidy treasury into ILRM (no-op on versions without the function)
        _tryCall(address(ilrm), abi.encodeWithSignature("setSubsidyTreasury(address)", address(treasury)));

        token.mint(address(treasury), TREASURY_FUNDS);
        token.mint(initiator, INITIATOR_FUNDS);
        vm.prank(initiator);
        token.approve(address(ilrm), type(uint256).max);
    }

    // ============ Regression tests ============

    /// @notice A subsidy must never be paid into the counterparty's wallet
    function test_Regression_SubsidyNeverReachesCounterpartyWallet() public {
        address defender = _newParty("defender", 50 ether);
        uint256 id = _openDispute(defender, 10 ether);
        uint256 walletBefore = token.balanceOf(defender);

        _tryRequestSubsidy(defender, id, MAX_PER_DISPUTE);
        assertEq(token.balanceOf(defender), walletBefore, "subsidy paid into the counterparty wallet");

        // The supported path escrows the (full) subsidy in ILRM instead
        _tryDepositStakeWithSubsidy(defender, id, MAX_PER_DISPUTE);
        assertEq(token.balanceOf(defender), walletBefore, "subsidized stake touched the wallet");
    }

    /// @notice Fresh sybil counterparties on 1-wei disputes cannot farm maxPerDispute each
    function test_Regression_DustStakeSybilLoopCannotDrain() public {
        uint256 numDisputes = 15;
        address[] memory sybils = new address[](numDisputes);
        uint256[] memory ids = new uint256[](numDisputes);

        uint256 treasuryStart = token.balanceOf(address(treasury));
        uint256 colludersStart = token.balanceOf(initiator);

        for (uint256 i = 0; i < numDisputes; i++) {
            sybils[i] = _newParty(string.concat("sybil", vm.toString(i)), 0);
            ids[i] = _openDispute(sybils[i], 1);

            // Try every entry point for the maximum subsidy
            _tryRequestSubsidy(sybils[i], ids[i], MAX_PER_DISPUTE);
            _tryDepositStakeWithSubsidy(sybils[i], ids[i], MAX_PER_DISPUTE);
        }

        // Every dispute defaults (non-participation or timeout-with-burn, whichever applies)
        vm.warp(block.timestamp + ilrm.RESOLUTION_TIMEOUT() + 1);
        for (uint256 i = 0; i < numDisputes; i++) {
            ilrm.enforceTimeout(ids[i]);
        }

        uint256 colludersEnd = token.balanceOf(initiator);
        for (uint256 i = 0; i < numDisputes; i++) {
            colludersEnd += token.balanceOf(sybils[i]);
        }
        uint256 treasuryEnd = token.balanceOf(address(treasury));

        assertLe(colludersEnd, colludersStart, "colluders profited from the sybil loop");
        assertLe(treasuryStart - treasuryEnd, numDisputes, "treasury lost more than 1 wei per dispute");
    }

    /// @notice A subsidized stake returned on mutual acceptance must go back to the Treasury
    function test_Regression_MutualAcceptanceDoesNotKeepSubsidy() public {
        uint256 stake = 50 ether;
        address defender = _newParty("sybil-defender", 0);

        uint256 treasuryStart = token.balanceOf(address(treasury));
        uint256 colludersStart = token.balanceOf(initiator) + token.balanceOf(defender);

        uint256 id = _openDispute(defender, stake);
        _tryRequestSubsidy(defender, id, stake);
        _tryDepositStakeWithSubsidy(defender, id, stake);

        // If the subsidy only reached the wallet, stake it the plain way
        if (ilrm.disputes(id).counterpartyStake == 0) {
            vm.prank(defender);
            ilrm.depositStake(id);
        }
        assertEq(ilrm.disputes(id).counterpartyStake, stake);

        vm.prank(address(oracle));
        ilrm.submitLLMProposal(id, "split the royalties", "");
        vm.prank(initiator);
        ilrm.acceptProposal(id);
        vm.prank(defender);
        ilrm.acceptProposal(id);
        assertTrue(ilrm.disputes(id).resolved);

        uint256 colludersEnd = token.balanceOf(initiator) + token.balanceOf(defender);
        assertEq(token.balanceOf(address(treasury)), treasuryStart, "treasury not made whole on acceptance");
        assertLe(colludersEnd, colludersStart, "colluders kept the subsidy");
    }

    /// @notice No subsidy can be obtained once the stake window has closed
    function test_Regression_NoSubsidyAfterStakeWindow() public {
        address defender = _newParty("late-defender", 0);
        uint256 id = _openDispute(defender, 10 ether);

        vm.warp(block.timestamp + ilrm.STAKE_WINDOW() + 1);

        uint256 treasuryStart = token.balanceOf(address(treasury));
        _tryRequestSubsidy(defender, id, MAX_PER_DISPUTE);
        _tryDepositStakeWithSubsidy(defender, id, MAX_PER_DISPUTE);

        assertEq(token.balanceOf(address(treasury)), treasuryStart, "treasury paid out after the stake window");
        assertEq(token.balanceOf(defender), 0, "defender received funds after the stake window");
        assertFalse(treasury.disputeSubsidized(id));
    }

    // ============ Helpers ============

    function _newParty(string memory label, uint256 funds) internal returns (address party) {
        party = makeAddr(label);
        if (funds > 0) token.mint(party, funds);
        vm.prank(party);
        token.approve(address(ilrm), type(uint256).max);
    }

    function _openDispute(address counterparty, uint256 stake) internal returns (uint256 id) {
        vm.prank(initiator);
        id = ilrm.initiateBreachDispute(counterparty, stake, keccak256(abi.encode(counterparty)), fallbackLicense);
    }

    /// @dev Legacy entry point (removed by the fix)
    function _tryRequestSubsidy(address caller, uint256 id, uint256 amount) internal {
        vm.prank(caller);
        _tryCall(
            address(treasury), abi.encodeWithSignature("requestSubsidy(uint256,uint256,address)", id, amount, caller)
        );
    }

    /// @dev New entry point (added by the fix)
    function _tryDepositStakeWithSubsidy(address caller, uint256 id, uint256 maxSubsidy) internal {
        vm.prank(caller);
        _tryCall(address(ilrm), abi.encodeWithSignature("depositStakeWithSubsidy(uint256,uint256)", id, maxSubsidy));
    }

    /// @dev Low-level call whose result is deliberately ignored
    function _tryCall(address target, bytes memory data) internal returns (bool ok) {
        (ok,) = target.call(data);
    }
}
