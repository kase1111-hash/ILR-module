// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/ILRM.sol";
import "../contracts/scaling/BatchQueue.sol";
import "../contracts/scaling/DummyTransactionGenerator.sol";
import "../contracts/mocks/MockAssetRegistry.sol";
import "../contracts/mocks/MockOracle.sol";
import "../contracts/mocks/MockToken.sol";

/// @dev Relay-capable ILRM stand-in: implements the *For entry points (both the old bytes-fallback
///      selector and the typed one) and a configurable disputes() view, and trusts its caller to name
///      the party, which is what a relayed ILRM would do. The Dispute fields are written one by one so
///      added struct fields do not break compilation.
contract SPRegressionRelayILRM {
    IERC20 public immutable token;
    address public lastParty;
    uint256 public relayCount;
    mapping(address => uint256) public pulledFor;
    IILRM.Dispute internal _d;

    constructor(IERC20 t) {
        token = t;
    }

    function setDispute(address initiator, address counterparty, string calldata proposal, uint256 round) external {
        _d.initiator = initiator;
        _d.counterparty = counterparty;
        _d.counterpartyStake = 1;
        _d.llmProposal = proposal;
        _d.counterCount = round;
    }

    function disputes(uint256) external view returns (IILRM.Dispute memory) {
        return _d;
    }

    function initiateBreachDisputeFor(address initiator, address, uint256 stake, bytes32, bytes calldata) external {
        _pull(initiator, stake);
    }

    function initiateBreachDisputeFor(
        address initiator,
        address,
        uint256 stake,
        bytes32,
        IILRM.FallbackLicense calldata
    ) external returns (uint256) {
        _pull(initiator, stake);
        return 0;
    }

    function depositStakeFor(uint256, address depositor) external {
        lastParty = depositor;
        relayCount++;
    }

    function acceptProposalFor(uint256, address acceptor) external {
        lastParty = acceptor;
        relayCount++;
    }

    function _pull(address initiator, uint256 stake) internal {
        require(token.transferFrom(msg.sender, address(this), stake), "pull failed");
        pulledFor[initiator] += stake;
        lastParty = initiator;
        relayCount++;
    }
}

/// @dev Submitter without receive/fallback: any ETH refund pushed to it fails
contract SPEthRejecter {
    /// @dev Queues a record-only entry, with ETH attached if the queue still accepts it
    function queueRecordOnly(address q) external payable returns (bool withValue) {
        bytes memory call_ = abi.encodeWithSignature(
            "queueTransaction(uint8,bytes)", uint8(IBatchQueue.TxType.EvidenceSubmission), hex"01"
        );
        (withValue,) = q.call{value: msg.value}(call_);
        if (!withValue) {
            (bool ok,) = q.call(call_);
            require(ok, "queue failed");
        }
    }
}

/// @dev Calls tryGenerate until it reports a generation (or the tries run out), all in one transaction
contract SPGrinder {
    function grind(address g, uint256 tries) external {
        for (uint256 i = 0; i < tries; i++) {
            (bool ok, bytes memory ret) = g.call(abi.encodeWithSignature("tryGenerate()"));
            if (ok && abi.decode(ret, (bool))) return;
        }
    }
}

/**
 * @title ScalingPrivacyRegression
 * @notice Regression tests for BatchQueue / DummyTransactionGenerator. Every test fails on the code
 *         before the fix (7743360) and passes after it.
 * @dev Entry points added or changed by the fix (setRelayEnabled, reclaim, setKeeper, the two-argument
 *      queueAcceptance, the now non-payable queueTransaction) are reached ONLY through low-level calls
 *      whose result is ignored where the entry point may not exist, so this file compiles against both
 *      versions. No oracle-owned ILRM function (submitLLMProposal, counterPropose, acceptProposal) is
 *      called.
 */
contract ScalingPrivacyRegressionTest is Test {
    MockToken internal token;
    ILRM internal ilrm;
    address internal victim = makeAddr("victim");
    address internal attacker = makeAddr("attacker");
    address internal counterparty = makeAddr("counterparty");

    function setUp() public {
        token = new MockToken();
        ilrm = _deployIlrm();
        token.mint(victim, 1000 ether);
    }

    // ============ BatchQueue ============

    /// @notice A malformed generic transaction must not brick a batch and lock co-batched escrow
    function test_Regression_MalformedQueuedTxCannotLockOtherEscrow() public {
        BatchQueue q = _queue(address(ilrm), false);
        uint256 vId = _victimInitiation(q, 100 ether);
        vm.prank(attacker);
        _call(address(q), abi.encodeWithSignature("queueTransaction(uint8,bytes)", uint8(0), hex""));

        vm.warp(block.timestamp + 6 minutes);
        (uint256 b,) = q.releaseBatch();
        assertTrue(_call(address(q), abi.encodeCall(q.executeBatch, (b))), "executeBatch bricked");

        // The victim's stake comes back (relays fail against the real ILRM)
        vm.prank(victim);
        _call(address(q), abi.encodeWithSignature("reclaim(uint256)", vId));
        assertEq(token.balanceOf(victim), 1000 ether, "victim escrow locked");
    }

    /// @notice A submitter that rejects ETH must not brick execution of its batch
    function test_Regression_EthRejectingSubmitterCannotBrickExecute() public {
        BatchQueue q = _queue(address(ilrm), false);
        SPEthRejecter r = new SPEthRejecter();
        vm.deal(address(this), 1 ether);
        r.queueRecordOnly{value: 1 wei}(address(q));
        uint256 vId = _victimInitiation(q, 100 ether);

        vm.warp(block.timestamp + 6 minutes);
        (uint256 b, uint256 n) = q.releaseBatch();
        assertEq(n, 2);
        assertTrue(_call(address(q), abi.encodeCall(q.executeBatch, (b))), "executeBatch bricked");

        vm.prank(victim);
        _call(address(q), abi.encodeWithSignature("reclaim(uint256)", vId));
        assertEq(token.balanceOf(victim), 1000 ether, "victim escrow locked");
    }

    /// @notice A submitter that rejects ETH must not brick release for the whole queue
    function test_Regression_EthRejectingSubmitterCannotBrickRelease() public {
        BatchQueue q = _queue(address(ilrm), false);
        SPEthRejecter r = new SPEthRejecter();
        vm.deal(address(this), 1 ether);
        r.queueRecordOnly{value: 1 wei}(address(q));

        vm.warp(block.timestamp + 2 days); // the rejecter's entry is stale
        _victimInitiation(q, 100 ether);
        vm.warp(block.timestamp + 6 minutes);
        assertTrue(_call(address(q), abi.encodeCall(q.releaseBatch, ())), "releaseBatch bricked");
    }

    /// @notice queueTransaction must not let anyone relay an action in another party's name
    function test_Regression_GenericQueueCannotActForAnotherParty() public {
        SPRegressionRelayILRM relay = new SPRegressionRelayILRM(IERC20(address(token)));
        BatchQueue q = _queue(address(relay), true);

        vm.prank(attacker);
        _call(
            address(q),
            abi.encodeWithSignature(
                "queueTransaction(uint8,bytes)", uint8(IBatchQueue.TxType.ProposalAcceptance), abi.encode(7, victim)
            )
        );
        _releaseAndExecute(q);
        assertTrue(relay.lastParty() != victim, "acceptance relayed in the victim's name");
    }

    /// @notice A relayed initiation must only ever be funded by its own escrow
    function test_Regression_GenericQueueCannotSpendOtherEscrow() public {
        SPRegressionRelayILRM relay = new SPRegressionRelayILRM(IERC20(address(token)));
        BatchQueue q = _queue(address(relay), true);
        IBatchQueue.BatchConfig memory c = _cfg();
        c.maxBatchSize = 1;
        q.updateConfig(c);

        bytes memory fb = abi.encode(IILRM.FallbackLicense(keccak256("t"), 365 days, 500, true));
        vm.prank(attacker);
        _call(
            address(q),
            abi.encodeWithSignature(
                "queueTransaction(uint8,bytes)",
                uint8(IBatchQueue.TxType.DisputeInitiation),
                abi.encode(counterparty, 100 ether, bytes32("x"), fb)
            )
        );
        _victimInitiation(q, 100 ether); // lands in the next batch

        _releaseAndExecute(q);
        _releaseAndExecute(q);
        assertEq(relay.pulledFor(attacker), 0, "attacker's dispute funded from the victim's escrow");
    }

    /// @notice A failed relayed initiation must not leave the queue's allowance to ILRM behind
    function test_Regression_NoAllowanceLeftAfterFailedInitiation() public {
        BatchQueue q = _queue(address(ilrm), false);
        _victimInitiation(q, 100 ether);
        _releaseAndExecute(q);
        assertEq(token.allowance(address(q), address(ilrm)), 0, "allowance left after failed initiation");
    }

    /// @notice A delayed acceptance must not land on a proposal the submitter never accepted
    function test_Regression_QueuedAcceptanceBoundToProposal() public {
        SPRegressionRelayILRM relay = new SPRegressionRelayILRM(IERC20(address(token)));
        relay.setDispute(victim, counterparty, "proposal A", 0);
        BatchQueue q = _queue(address(relay), true);

        vm.startPrank(victim);
        // new API binds the proposal; old API takes only the id
        if (!_call(address(q), abi.encodeWithSignature("queueAcceptance(uint256,bytes32)", 1, keccak256("proposal A"))))
        {
            _call(address(q), abi.encodeWithSignature("queueAcceptance(uint256)", 1));
        }
        vm.stopPrank();
        assertEq(q.getTotalTxCount(), 1, "acceptance not queued");

        // Before execution the dispute moves to a new round with a different proposal
        relay.setDispute(victim, counterparty, "proposal B", 1);
        _releaseAndExecute(q);
        assertEq(relay.relayCount(), 0, "acceptance relayed onto a different proposal");
    }

    /// @notice Release cost must not grow with the length of the pending queue
    function test_Regression_ReleaseGasBoundedByQueueLength() public {
        uint256 short = _releaseGasWithPending(100);
        uint256 long = _releaseGasWithPending(3000);
        emit log_named_uint("release gas, 100 pending", short);
        emit log_named_uint("release gas, 3000 pending", long);
        assertLt(long, (short * 12) / 10, "release gas grows with queue length");
    }

    function _releaseGasWithPending(uint256 n) internal returns (uint256 used) {
        BatchQueue q = _queue(address(ilrm), false);
        for (uint256 i = 0; i < n; i++) {
            vm.prank(address(uint160(0x10000 + i)));
            q.queueZKProof(i, hex"");
        }
        vm.warp(block.timestamp + 6 minutes);
        uint256 g0 = gasleft();
        q.releaseBatch();
        used = g0 - gasleft();
    }

    /// @notice The dummy generator's queue entries must not brick the queue
    function test_Regression_DummyQueueEntryDoesNotBrickBatch() public {
        BatchQueue q = _queue(address(ilrm), false);
        DummyTransactionGenerator g = _generator(10_000, 1 ether);
        g.setTargetContracts(address(ilrm), address(q));
        assertTrue(g.forceGenerate(IDummyTransactionGenerator.DummyTxType.BatchQueueEntry));
        vm.prank(victim);
        q.queueZKProof(1, hex"01");

        vm.warp(block.timestamp + 6 minutes);
        (uint256 b,) = q.releaseBatch();
        assertTrue(_call(address(q), abi.encodeCall(q.executeBatch, (b))), "executeBatch bricked by a dummy");
    }

    // ============ DummyTransactionGenerator ============

    /// @notice An outsider cannot force a 1% generation by retrying in one transaction, and the keeper
    ///         gets one attempt per slot
    function test_Regression_ProbabilityGateCannotBeRetried() public {
        DummyTransactionGenerator g = _generator(100, 1 ether);
        SPGrinder outsider = new SPGrinder();
        outsider.grind(address(g), 1000);
        assertEq(g.getStats().totalGenerated, 0, "outsider forced a generation");

        SPGrinder keeper = new SPGrinder();
        _call(address(g), abi.encodeWithSignature("setKeeper(address)", address(keeper)));
        vm.recordLogs();
        keeper.grind(address(g), 1000);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 attempts;
        for (uint256 i = 0; i < logs.length; i++) {
            bytes32 t0 = logs[i].topics[0];
            if (
                logs[i].emitter == address(g)
                    && (t0 == keccak256("GenerationSkipped(uint256,uint256)")
                        || t0 == keccak256("DummyTransactionGenerated(uint256,uint8,address,bytes32)"))
            ) attempts++;
        }
        assertLe(attempts, 1, "more than one attempt in a slot");
    }

    /// @notice maxTreasurySpend bounds the spend including the dummy being generated, on every path
    function test_Regression_SpendCapIncludesCost() public {
        DummyTransactionGenerator g = _generator(10_000, 0.015 ether);
        for (uint256 k = 0; k < 40; k++) {
            vm.warp(block.timestamp + 2 minutes);
            g.tryGenerate();
        }
        assertLe(g.getStats().periodSpent, 0.015 ether, "tryGenerate spent above the cap");
        _call(address(g), abi.encodeCall(g.generateBatch, (10)));
        assertLe(g.getStats().periodSpent, 0.015 ether, "generateBatch spent above the cap");
    }

    // ============ Helpers ============

    function _deployIlrm() internal returns (ILRM) {
        return new ILRM(IERC20(address(token)), address(new MockOracle()), new MockAssetRegistry());
    }

    function _cfg() internal pure returns (IBatchQueue.BatchConfig memory) {
        return IBatchQueue.BatchConfig({
            minBatchSize: 1,
            maxBatchSize: 100,
            releaseInterval: 5 minutes,
            maxQueueTime: 1 days,
            randomizeOrder: false,
            allowCancellation: true
        });
    }

    function _queue(address target, bool relay) internal returns (BatchQueue q) {
        q = new BatchQueue(target, IERC20(address(token)), _cfg());
        if (relay) _call(address(q), abi.encodeWithSignature("setRelayEnabled(bool)", true));
        vm.prank(victim);
        token.approve(address(q), type(uint256).max);
    }

    function _victimInitiation(BatchQueue q, uint256 stake) internal returns (uint256) {
        _call(address(q), abi.encodeWithSignature("setRelayEnabled(bool)", true));
        bytes memory fb = abi.encode(IILRM.FallbackLicense(keccak256("t"), 365 days, 500, true));
        vm.prank(victim);
        return q.queueDisputeInitiation(counterparty, stake, bytes32("e"), fb);
    }

    /// @dev Release (if anything is pending) and execute; tolerant of an empty queue
    function _releaseAndExecute(BatchQueue q) internal {
        vm.warp(block.timestamp + 6 minutes);
        (bool ok, bytes memory ret) = address(q).call(abi.encodeCall(q.releaseBatch, ()));
        if (!ok) return;
        (uint256 b, uint256 n) = abi.decode(ret, (uint256, uint256));
        if (n > 0) _call(address(q), abi.encodeCall(q.executeBatch, (b)));
    }

    function _generator(uint256 probBps, uint256 maxSpend) internal returns (DummyTransactionGenerator g) {
        g = new DummyTransactionGenerator(
            address(ilrm),
            IDummyTransactionGenerator.GeneratorConfig({
                minInterval: 1 minutes,
                maxInterval: 1 hours,
                probabilityBps: probBps,
                maxPerPeriod: 1000,
                periodDuration: 1 days,
                maxTreasurySpend: maxSpend,
                enabled: true
            })
        );
        g.registerDummyAddress(makeAddr("dummy1"));
        g.registerDummyAddress(makeAddr("dummy2"));
        vm.deal(address(this), 100 ether);
        g.fundTreasury{value: 10 ether}();
    }

    function _call(address target, bytes memory data) internal returns (bool ok) {
        (ok,) = target.call(data);
    }
}
