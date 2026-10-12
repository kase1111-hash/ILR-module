// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/ILRM.sol";
import "../contracts/Oracle.sol";
import "../contracts/Treasury.sol";
import "../contracts/mocks/MockToken.sol";
import "../contracts/mocks/MockAssetRegistry.sol";

/// @dev Minimal IOracle whose requestProposal is configurable; signatures always verify
abstract contract RequestOracleBase is IOracle {
    function submitProposal(uint256, string calldata, bytes calldata) external virtual {}

    function verifySignature(uint256, bytes32, bytes calldata) external pure returns (bool) {
        return true;
    }

    function ilrmContract() external pure returns (address) {
        return address(0);
    }

    function isOracle(address) external pure returns (bool) {
        return true;
    }

    function oraclePublicKeyHash(address) external pure returns (bytes32) {
        return bytes32(0);
    }
}

contract RevertingRequestOracle is RequestOracleBase {
    function requestProposal(uint256, bytes32) external pure {
        revert("oracle down");
    }
}

contract GasBurningRequestOracle is RequestOracleBase {
    uint256 public spins;

    function requestProposal(uint256, bytes32) external {
        while (true) {
            spins++;
        }
    }
}

/// @dev Records the gas it was given, so a test can prove the full ORACLE_REQUEST_GAS was forwarded
contract GasProbeOracle is RequestOracleBase {
    mapping(uint256 => uint256) public entryGas;

    function requestProposal(uint256 disputeId, bytes32) external {
        uint256 g = gasleft();
        entryGas[disputeId] = g;
    }
}

/**
 * @title OracleRequestWiringTest
 * @notice ILRM requests an oracle proposal when a dispute becomes fully staked and on every counter-proposal.
 *         The request is advisory: no oracle failure (no code, revert, gas exhaustion, wrong consumer) can block
 *         staking or countering, and a successful stake always gave the oracle its full gas allowance.
 */
contract OracleRequestWiringTest is Test {
    event ProposalRequested(uint256 indexed disputeId, bytes32 evidenceHash, uint256 timestamp);
    event OracleRequestFailed(uint256 indexed disputeId, uint256 indexed round);
    event StakeDeposited(uint256 indexed disputeId, address indexed depositor, uint256 amount);
    event CounterProposed(uint256 indexed disputeId, address indexed party, uint256 counterNumber);

    uint256 internal constant STAKE = 10 ether;
    bytes32 internal constant EVIDENCE_0 = keccak256("evidence-0");
    bytes32 internal constant EVIDENCE_1 = keccak256("evidence-1");

    MockToken internal token;
    MockAssetRegistry internal registry;

    address internal initiator = makeAddr("initiator");
    address internal counterparty = makeAddr("counterparty");

    function setUp() public {
        token = new MockToken();
        registry = new MockAssetRegistry();
    }

    // ============ Helpers ============

    function _ilrmWith(address oracleAddr) internal returns (ILRM ilrm) {
        ilrm = new ILRM(IERC20(address(token)), oracleAddr, registry);
        address[2] memory parties = [initiator, counterparty];
        for (uint256 i = 0; i < 2; i++) {
            token.mint(parties[i], 1000 ether);
            vm.prank(parties[i]);
            token.approve(address(ilrm), type(uint256).max);
        }
    }

    function _realSystem() internal returns (ILRM ilrm, NatLangChainOracle oracle) {
        oracle = new NatLangChainOracle();
        ilrm = _ilrmWith(address(oracle));
        oracle.setILRM(address(ilrm));
    }

    function _fallback() internal pure returns (IILRM.FallbackLicense memory) {
        return IILRM.FallbackLicense({
            termsHash: keccak256("fallback"), termDuration: 365 days, royaltyCapBps: 500, nonExclusive: true
        });
    }

    function _initiate(ILRM ilrm) internal returns (uint256 id) {
        vm.prank(initiator);
        id = ilrm.initiateBreachDispute(counterparty, STAKE, EVIDENCE_0, _fallback());
    }

    function _counter(ILRM ilrm, uint256 id) internal {
        uint256 fee = ilrm.COUNTER_FEE_BASE() << ilrm.disputes(id).counterCount;
        vm.deal(initiator, fee);
        vm.prank(initiator);
        ilrm.counterPropose{value: fee}(id, EVIDENCE_1);
    }

    function _stakeWithGas(ILRM ilrm, uint256 id, uint256 gasLimit) internal returns (bool ok, bytes memory ret) {
        vm.prank(counterparty);
        (ok, ret) = address(ilrm).call{gas: gasLimit}(abi.encodeCall(ILRM.depositStake, (id)));
    }

    // ============ Requests on the real Oracle ============

    function test_DepositStakeRequestsProposal() public {
        (ILRM ilrm, NatLangChainOracle oracle) = _realSystem();
        uint256 id = _initiate(ilrm);

        vm.expectEmit(true, true, false, true, address(ilrm));
        emit StakeDeposited(id, counterparty, STAKE);
        vm.expectEmit(true, false, false, true, address(oracle));
        emit ProposalRequested(id, EVIDENCE_0, block.timestamp);
        vm.prank(counterparty);
        ilrm.depositStake(id);

        assertTrue(oracle.isPending(id));
    }

    function test_CounterRequestsProposalForNewRound() public {
        (ILRM ilrm, NatLangChainOracle oracle) = _realSystem();
        uint256 id = _initiate(ilrm);
        vm.prank(counterparty);
        ilrm.depositStake(id);
        oracle.cancelPendingRequest(id);
        assertFalse(oracle.isPending(id));

        uint256 fee = ilrm.COUNTER_FEE_BASE();
        vm.deal(initiator, fee);
        vm.expectEmit(true, true, false, true, address(ilrm));
        emit CounterProposed(id, initiator, 1);
        vm.expectEmit(true, false, false, true, address(oracle));
        emit ProposalRequested(id, EVIDENCE_1, block.timestamp);
        vm.prank(initiator);
        ilrm.counterPropose{value: fee}(id, EVIDENCE_1);

        assertTrue(oracle.isPending(id));
    }

    /// @notice The subsidized stake path requests a proposal too (real Treasury)
    function test_DepositStakeWithSubsidyRequestsProposal() public {
        (ILRM ilrm, NatLangChainOracle oracle) = _realSystem();
        NatLangChainTreasury treasury = new NatLangChainTreasury(IERC20(address(token)), 100 ether, 1000 ether, 30 days);
        treasury.setILRM(address(ilrm));
        ilrm.setSubsidyTreasury(address(treasury));
        token.mint(address(treasury), 1000 ether);

        uint256 id = _initiate(ilrm);
        vm.expectEmit(true, false, false, true, address(oracle));
        emit ProposalRequested(id, EVIDENCE_0, block.timestamp);
        vm.prank(counterparty);
        ilrm.depositStakeWithSubsidy(id, type(uint256).max);

        assertTrue(oracle.isPending(id));
        (, uint256 amount) = ilrm.stakeSubsidy(id);
        assertEq(amount, STAKE);
    }

    // ============ Oracle failures never block ============

    /// @notice An Oracle that serves another consumer rejects the request (NotILRM); ILRM carries on
    function test_MisdirectedOracleDoesNotBlock() public {
        NatLangChainOracle oracle = new NatLangChainOracle();
        ILRM ilrm = _ilrmWith(address(oracle));
        oracle.setILRM(makeAddr("other-consumer"));

        uint256 id = _initiate(ilrm);
        vm.expectEmit(true, true, false, true, address(ilrm));
        emit OracleRequestFailed(id, 0);
        vm.prank(counterparty);
        ilrm.depositStake(id);
        assertEq(ilrm.disputes(id).counterpartyStake, STAKE);

        vm.expectEmit(true, true, false, true, address(ilrm));
        emit OracleRequestFailed(id, 1);
        _counter(ilrm, id);
        assertEq(ilrm.disputes(id).counterCount, 1);
        assertFalse(oracle.isPending(id));
    }

    /// @notice An oracle address without code (EOA): try/catch alone would revert on Solidity's extcodesize check
    function test_EOAOracleDoesNotBlockStaking() public {
        address eoaOracle = makeAddr("eoa-oracle");
        assertEq(eoaOracle.code.length, 0);
        ILRM ilrm = _ilrmWith(eoaOracle);

        uint256 id = _initiate(ilrm);
        vm.expectEmit(true, true, false, true, address(ilrm));
        emit OracleRequestFailed(id, 0);
        vm.prank(counterparty);
        ilrm.depositStake(id);
        assertEq(ilrm.disputes(id).counterpartyStake, STAKE);

        vm.expectEmit(true, true, false, true, address(ilrm));
        emit OracleRequestFailed(id, 1);
        _counter(ilrm, id);
    }

    function test_RevertingOracleDoesNotBlock() public {
        ILRM ilrm = _ilrmWith(address(new RevertingRequestOracle()));
        uint256 id = _initiate(ilrm);

        vm.expectEmit(true, true, false, true, address(ilrm));
        emit OracleRequestFailed(id, 0);
        vm.prank(counterparty);
        ilrm.depositStake(id);

        uint256 burnBefore = ilrm.BURN_ADDRESS().balance;
        vm.expectEmit(true, true, false, true, address(ilrm));
        emit OracleRequestFailed(id, 1);
        _counter(ilrm, id);
        assertEq(ilrm.BURN_ADDRESS().balance - burnBefore, ilrm.COUNTER_FEE_BASE(), "counter fee not burned");
        assertEq(ilrm.disputes(id).counterCount, 1);
    }

    /// @notice A gas-burning oracle costs at most ORACLE_REQUEST_GAS and cannot block staking or countering
    function test_GasBurningOracleDoesNotBlock() public {
        ILRM ilrm = _ilrmWith(address(new GasBurningRequestOracle()));
        uint256 id = _initiate(ilrm);

        vm.expectEmit(true, true, false, true, address(ilrm));
        emit OracleRequestFailed(id, 0);
        uint256 before = gasleft();
        vm.prank(counterparty);
        ilrm.depositStake(id);
        uint256 used = before - gasleft();
        assertLt(used, 250_000, "oracle burned more than its cap");
        assertEq(ilrm.disputes(id).counterpartyStake, STAKE);

        vm.expectEmit(true, true, false, true, address(ilrm));
        emit OracleRequestFailed(id, 1);
        _counter(ilrm, id);
        assertEq(ilrm.disputes(id).counterCount, 1);
    }

    // ============ Gas floor ============

    /// @notice Calibrated: one gas unit below the cheapest successful depositStake reverts exactly
    ///         Error("Insufficient gas") (never a silently dropped request); at the threshold it succeeds
    function test_InsufficientGasRevertsExactly() public {
        (ILRM ilrm, NatLangChainOracle oracle) = _realSystem();
        uint256 id = _initiate(ilrm);

        uint256 lo = 50_000; // fails
        uint256 hi = 400_000; // succeeds
        {
            uint256 snap = vm.snapshotState();
            (bool okHi,) = _stakeWithGas(ilrm, id, hi);
            assertTrue(okHi, "400k gas must be enough");
            vm.revertToState(snap);
        }
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            (bool ok,) = _stakeWithGas(ilrm, id, mid);
            vm.revertToState(snap);
            if (ok) hi = mid;
            else lo = mid;
        }

        uint256 snapshot = vm.snapshotState();
        (bool okBelow, bytes memory ret) = _stakeWithGas(ilrm, id, hi - 1);
        assertFalse(okBelow);
        assertEq(ret, abi.encodeWithSignature("Error(string)", "Insufficient gas"), "not the gas-floor revert");
        assertEq(ilrm.disputes(id).counterpartyStake, 0);
        vm.revertToState(snapshot);

        (bool okAt,) = _stakeWithGas(ilrm, id, hi);
        assertTrue(okAt);
        assertTrue(oracle.isPending(id), "request dropped at the threshold");
    }

    /// @notice Whatever gas the caller supplies, a successful stake has requested a proposal
    function testFuzz_GasLimitSuccessImpliesPending(uint256 gasLimit) public {
        gasLimit = bound(gasLimit, 50_000, 400_000);
        (ILRM ilrm, NatLangChainOracle oracle) = _realSystem();
        uint256 id = _initiate(ilrm);

        (bool ok,) = _stakeWithGas(ilrm, id, gasLimit);
        if (ok) {
            assertTrue(oracle.isPending(id), "stake succeeded but the request was dropped");
        } else {
            assertEq(ilrm.disputes(id).counterpartyStake, 0);
        }
    }

    /// @notice Whatever gas the caller supplies, a successful stake gave the oracle its full allowance
    function testFuzz_GasLimitSuccessImpliesFullAllowance(uint256 gasLimit) public {
        gasLimit = bound(gasLimit, 50_000, 400_000);
        GasProbeOracle probe = new GasProbeOracle();
        ILRM ilrm = _ilrmWith(address(probe));
        uint256 id = _initiate(ilrm);

        (bool ok,) = _stakeWithGas(ilrm, id, gasLimit);
        if (ok) {
            assertGe(probe.entryGas(id), ilrm.ORACLE_REQUEST_GAS() - 1000, "oracle got less than its allowance");
        }
    }
}
