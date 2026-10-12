// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/ILRM.sol";
import "../contracts/scaling/BatchQueue.sol";
import "../contracts/scaling/DummyTransactionGenerator.sol";
import "../contracts/mocks/MockAssetRegistry.sol";
import "../contracts/mocks/MockOracle.sol";
import "../contracts/mocks/MockToken.sol";

/// @dev ILRM stand-in for queued acceptances: disputes() can be made to revert or to burn more gas than
///      BatchQueue forwards to it; acceptProposalFor counts relays. The Dispute fields are written one by
///      one so fields added to the struct do not break compilation.
contract SP3AcceptanceTarget {
    IILRM.Dispute internal _d;
    bool public revertDisputes;
    uint256 public burnInDisputes;
    uint256 public relayCount;

    function setDispute(address initiator, address counterparty, string calldata proposal) external {
        _d.initiator = initiator;
        _d.counterparty = counterparty;
        _d.llmProposal = proposal;
    }

    function setRevertDisputes(bool r) external {
        revertDisputes = r;
    }

    function setBurnInDisputes(uint256 g) external {
        burnInDisputes = g;
    }

    function disputes(uint256) external view returns (IILRM.Dispute memory) {
        require(!revertDisputes, "disputes reverted");
        uint256 g0 = gasleft();
        while (g0 - gasleft() < burnInDisputes) {}
        return _d;
    }

    function acceptProposalFor(uint256, address) external {
        relayCount++;
    }
}

/// @dev Generator target (ILRM and/or BatchQueue) whose dummy-facing calls always fail
contract SP3FailingTarget {
    enum Mode {
        Revert, // plain revert
        BurnGas, // burn every unit of gas it is given
        BurnThenRevertBig // burn all but REVERT_RESERVE gas, then revert with 208 KB of returndata
    }

    /// @dev Left unburned by BurnThenRevertBig: pays for its own large revert and returns enough to the
    ///      generator's generation frame for that frame to copy and bubble the returndata
    uint256 internal constant REVERT_RESERVE = 270_000;

    Mode public mode;

    function setMode(Mode m) external {
        mode = m;
    }

    function initiateVoluntaryRequest(address, bytes32) external payable {
        _fail();
    }

    function queueTransaction(IBatchQueue.TxType, bytes calldata) external view returns (uint256) {
        _fail();
    }

    function _fail() internal view {
        if (mode == Mode.BurnGas) {
            while (true) {}
        }
        if (mode == Mode.BurnThenRevertBig) {
            while (gasleft() > REVERT_RESERVE) {}
            assembly {
                revert(0, 208000)
            }
        }
        revert("target failed");
    }
}

/// @dev Generator ILRM target that succeeds only if it starts with at least `required` gas
contract SP3GasProbeTarget {
    uint256 public required;
    uint256 public lastEntryGas;

    function setRequired(uint256 r) external {
        required = r;
    }

    function initiateVoluntaryRequest(address, bytes32) external payable {
        uint256 g = gasleft();
        require(g >= required, "short of gas");
        lastEntryGas = g;
    }
}

/**
 * @title ScalingPrivacyFollowUpsTest
 * @notice Follow-ups to the BatchQueue / DummyTransactionGenerator hardening: tests for code paths that
 *         mutation testing showed were unpinned, and the regression test for the dummy generator's free
 *         retry (a failing generation reverted the attempt, so the probability gate could be re-rolled).
 */
contract ScalingPrivacyFollowUpsTest is Test {
    event BatchExecuted(uint256 indexed batchId, uint256 successCount, uint256 failCount, bool complete);

    bytes32 internal constant SKIPPED_SIG = keccak256("GenerationSkipped(uint256,uint256)");
    bytes32 internal constant FAILED_SIG = keccak256("GenerationFailed(uint8)");

    MockToken internal token;
    ILRM internal ilrm;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal keeper = makeAddr("keeper");

    function setUp() public {
        token = new MockToken();
        ilrm = new ILRM(IERC20(address(token)), address(new MockOracle()), new MockAssetRegistry());
    }

    // ============ BatchQueue: released txIds are trimmed ============

    /// @notice A stale entry counted as pending but expired during release leaves the batch short of its
    ///         allocated size: the stored txIds must not carry trailing zeros (0 is a real txId)
    function test_ReleasedIdsTrimmedAfterStaleEntries() public {
        BatchQueue q = _queue(address(ilrm), false);
        vm.startPrank(alice);
        uint256 stale = q.queueZKProof(0, hex"01");
        vm.warp(block.timestamp + 2 days);
        uint256 a = q.queueZKProof(1, hex"02");
        uint256 b = q.queueZKProof(2, hex"03");
        vm.stopPrank();
        assertEq(stale, 0);
        assertEq(q.getPendingCount(), 3, "the stale entry still counts as pending before release");

        vm.warp(block.timestamp + 6 minutes);
        (uint256 batchId, uint256 n) = q.releaseBatch();
        assertEq(n, 2);
        uint256[] memory ids = q.getBatch(batchId).txIds;
        assertEq(ids.length, 2, "batch carries trailing txIds");
        assertEq(ids[0], a);
        assertEq(ids[1], b);
        assertEq(uint8(q.getTransaction(stale).status), uint8(IBatchQueue.QueueStatus.Expired));
    }

    /// @notice Same with the shuffle on: only the collected ids are shuffled and stored
    function test_ReleasedIdsTrimmedAfterStaleEntriesShuffled() public {
        BatchQueue q = _queue(address(ilrm), true);
        vm.startPrank(alice);
        q.queueZKProof(0, hex"01");
        vm.warp(block.timestamp + 2 days);
        uint256 a = q.queueZKProof(1, hex"02");
        uint256 b = q.queueZKProof(2, hex"03");
        uint256 c = q.queueZKProof(3, hex"04");
        vm.stopPrank();

        vm.warp(block.timestamp + 6 minutes);
        (uint256 batchId, uint256 n) = q.releaseBatch();
        assertEq(n, 3);
        uint256[] memory ids = q.getBatch(batchId).txIds;
        assertEq(ids.length, 3, "batch carries trailing txIds");
        assertEq(ids[0] + ids[1] + ids[2], a + b + c);
        assertTrue(ids[0] != 0 && ids[1] != 0 && ids[2] != 0, "the expired txId 0 is listed in the batch");
    }

    /// @notice The MAX_LOOP_ITERATIONS scan bound also stops a release short of the pending count
    function test_ReleasedIdsTrimmedWhenScanBoundHit() public {
        BatchQueue q = _queue(address(ilrm), false);
        vm.startPrank(alice);
        for (uint256 i = 0; i < q.MAX_LOOP_ITERATIONS() - 1; i++) {
            q.cancelTransaction(q.queueZKProof(i, hex""));
        }
        uint256 inWindow = q.queueZKProof(0, hex"01"); // the last entry the first scan reaches
        for (uint256 i = 0; i < 5; i++) {
            q.queueZKProof(i, hex"02");
        }
        vm.stopPrank();
        assertEq(q.getPendingCount(), 6);

        vm.warp(block.timestamp + 6 minutes);
        (uint256 batchId, uint256 n) = q.releaseBatch();
        assertEq(n, 1);
        uint256[] memory ids = q.getBatch(batchId).txIds;
        assertEq(ids.length, 1, "batch carries trailing txIds");
        assertEq(ids[0], inWindow);
    }

    // ============ BatchQueue: acceptance binding check fails closed ============

    /// @notice If ILRM's disputes() reverts at execution, the acceptance fails without being relayed and
    ///         the batch still completes
    function test_AcceptanceNotRelayedWhenDisputesReverts() public {
        SP3AcceptanceTarget target = new SP3AcceptanceTarget();
        uint256 id = _queueAcceptance(target);

        target.setRevertDisputes(true);
        _assertAcceptanceFailsUnrelayed(target, id);
    }

    /// @notice If disputes() needs more than RELAY_GAS_LIMIT at execution, the capped call runs out of gas:
    ///         the acceptance fails without being relayed and the batch still completes
    function test_AcceptanceNotRelayedWhenDisputesExceedsGasCap() public {
        SP3AcceptanceTarget target = new SP3AcceptanceTarget();
        uint256 id = _queueAcceptance(target);

        BatchQueue q = _lastQueue;
        target.setBurnInDisputes(q.RELAY_GAS_LIMIT() + 100_000);
        _assertAcceptanceFailsUnrelayed(target, id);
    }

    // ============ DummyTransactionGenerator: generateBatch stops at the first refusal ============

    /// @notice generateBatch stops at the first dummy a cap refuses, even when a later one would fit. With
    ///         no spend allowance, paid VoluntaryRequests are refused and free types are not; calling
    ///         generateBatch(1) ten times in the same block replays the exact sequence generateBatch(10)
    ///         draws, without stopping.
    function test_GenerateBatchStopsAtFirstRefusedDummy() public {
        DummyTransactionGenerator g = _gen(address(ilrm), 10_000, 0);
        for (uint256 k = 0; k < 20; k++) {
            uint256 snap = vm.snapshotState();
            uint256 leading;
            uint256 total;
            bool refused;
            for (uint256 i = 0; i < 10; i++) {
                uint256 r = g.generateBatch(1);
                total += r;
                if (r == 0) refused = true;
                else if (!refused) leading++;
            }
            vm.revertToState(snap);

            if (refused && leading < total) {
                uint256 before = g.getStats().totalGenerated;
                assertEq(g.generateBatch(10), leading, "generateBatch went on after a refused dummy");
                assertEq(g.getStats().totalGenerated - before, leading);
                return;
            }
            // No refusal followed by an allowed dummy in this sequence: move the seed chain on
            vm.roll(block.number + 1);
            assertTrue(g.forceGenerate(IDummyTransactionGenerator.DummyTxType.ViewingKeyCommit));
        }
        fail("no sequence with a refused dummy followed by an allowed one");
    }

    // ============ DummyTransactionGenerator: a failed generation consumes the attempt ============

    /// @notice A drawn attempt whose generation fails (ILRM reverts, BatchQueue paused) does not revert:
    ///         the generation is rolled back, GenerationFailed is emitted, and the attempt stays consumed,
    ///         so the keeper cannot re-roll the gate in a later block of the same slot.
    function test_FailedGenerationConsumesAttempt() public {
        SP3FailingTarget failing = new SP3FailingTarget();
        DummyTransactionGenerator g = _gen(address(failing), 10_000, 1 ether);
        BatchQueue q = _queue(address(ilrm), true);
        q.pause();
        g.setTargetContracts(address(failing), address(q));

        for (uint256 k = 0; k < 10; k++) {
            vm.warp(block.timestamp + 1 minutes);
            IDummyTransactionGenerator.GeneratorStats memory before = g.getStats();

            vm.recordLogs();
            vm.prank(keeper);
            (bool ok, bytes memory ret) = address(g).call{gas: 5_000_000}(abi.encodeCall(g.tryGenerate, ()));
            assertTrue(ok, "a failed generation reverted the attempt");
            (bool generated, IDummyTransactionGenerator.DummyTxType t) =
                abi.decode(ret, (bool, IDummyTransactionGenerator.DummyTxType));
            assertEq(g.lastAttemptTime(), block.timestamp, "attempt not recorded");
            if (generated) {
                continue; // a ViewingKeyCommit calls nothing, so it cannot fail; try the next slot
            }

            // The drawn type failed: logged, rolled back (no generation counted), nothing spent
            assertTrue(
                t == IDummyTransactionGenerator.DummyTxType.VoluntaryRequest
                    || t == IDummyTransactionGenerator.DummyTxType.BatchQueueEntry
            );
            _assertOnlyFailureLogged(address(g), vm.getRecordedLogs(), t);
            IDummyTransactionGenerator.GeneratorStats memory s = g.getStats();
            assertEq(s.totalGenerated, before.totalGenerated, "failed generation counted");
            assertEq(s.periodGenerated, before.periodGenerated);
            assertEq(s.periodSpent, 0);
            assertEq(s.lastGenerationTime, before.lastGenerationTime);
            assertEq(g.dummyTreasury(), 10 ether, "failed generation spent the treasury");
            assertEq(address(g).balance, 10 ether);
            assertEq(q.getTotalTxCount(), 0);

            (bool can, string memory why) = g.canGenerate();
            assertFalse(can);
            assertEq(why, "Min interval not passed");

            // Retrying in later blocks of the same slot (fresh prevrandao and block number), through
            // both keeper entry points, draws nothing
            uint256 slot = block.timestamp;
            for (uint256 j = 1; j <= 4; j++) {
                vm.roll(block.number + 1);
                vm.prevrandao(uint256(keccak256(abi.encode("retry", j))));
                vm.warp(block.timestamp + 12);
                vm.recordLogs();
                vm.prank(keeper);
                if (j % 2 == 0) {
                    g.performUpkeep("");
                } else {
                    (bool again,) = g.tryGenerate();
                    assertFalse(again);
                }
                assertEq(vm.getRecordedLogs().length, 0, "the gate was drawn again inside the slot");
            }
            assertEq(g.lastAttemptTime(), slot);
            assertEq(g.getStats().totalGenerated, before.totalGenerated);

            // The next slot draws again
            vm.warp(slot + 1 minutes);
            vm.recordLogs();
            vm.prank(keeper);
            g.tryGenerate();
            assertEq(g.lastAttemptTime(), block.timestamp);
            assertGt(vm.getRecordedLogs().length, 0, "next slot did not draw");
            return;
        }
        fail("no failing draw found");
    }

    /// @notice The generation entry point of an attempt is callable only by the generator itself: nobody,
    ///         not even the keeper or owner, can use it to generate without an attempt (gate, interval)
    function test_GenerateForAttemptOnlySelf() public {
        DummyTransactionGenerator g = _gen(address(ilrm), 10_000, 1 ether);
        address[3] memory callers = [makeAddr("outsider"), keeper, address(this)];
        for (uint256 i = 0; i < callers.length; i++) {
            vm.prank(callers[i]);
            (bool ok, bytes memory ret) = address(g)
                .call(
                    abi.encodeWithSignature(
                        "generateForAttempt(uint8)", uint8(IDummyTransactionGenerator.DummyTxType.VoluntaryRequest)
                    )
                );
            assertFalse(ok, "generated outside an attempt");
            assertEq(ret, abi.encodeWithSignature("Error(string)", "Only self"));
        }
        assertEq(g.getStats().totalGenerated, 0);
        assertEq(g.dummyTreasury(), 10 ether);
    }

    /// @notice No gas limit can undo a drawn attempt whose target burns all the gas it gets: the caller
    ///         either is refused before the draw ("Insufficient gas") or the attempt lands consumed
    function test_GasLimitCannotUndoDrawnAttempt() public {
        _scanGasLimits(SP3FailingTarget.Mode.BurnGas);
    }

    /// @notice Same for a target that leaves the attempt little gas and reverts with a large returndata:
    ///         the attempt does not copy the returndata, so it cannot be starved of its reserve
    function test_LargeRevertDataCannotUndoDrawnAttempt() public {
        _scanGasLimits(SP3FailingTarget.Mode.BurnThenRevertBig);
    }

    /// @notice Once an attempt passes the gas check its generation gets exactly GENERATION_GAS_LIMIT, so the
    ///         caller's gas limit cannot change the generation's outcome: a target that needs the gas it
    ///         starts with under a 5M gas limit succeeds under every gas limit that is not refused
    function test_GenerationOutcomeIndependentOfGasLimit() public {
        SP3GasProbeTarget probe = new SP3GasProbeTarget();
        DummyTransactionGenerator g = _gen(address(probe), 10_000, 1 ether);

        // Find a slot drawing a VoluntaryRequest and record the gas the target starts with
        uint256 entryGas;
        for (uint256 k = 0; k < 10 && entryGas == 0; k++) {
            vm.warp(block.timestamp + 1 minutes);
            uint256 snap = vm.snapshotState();
            (, IDummyTransactionGenerator.DummyTxType t) = g.tryGenerate{gas: 5_000_000}();
            if (t == IDummyTransactionGenerator.DummyTxType.VoluntaryRequest) {
                entryGas = probe.lastEntryGas();
                vm.revertToState(snap);
            }
        }
        assertGt(entryGas, 0, "no VoluntaryRequest draw found");
        probe.setRequired(entryGas);

        uint256 minGas = _minAttemptGas(g);
        uint256 landed;
        uint256 refused;
        for (uint256 gasLimit = minGas; gasLimit < minGas + 150_000; gasLimit += 1500) {
            uint256 snap = vm.snapshotState();
            (bool ok, bytes memory ret) = address(g).call{gas: gasLimit}(abi.encodeCall(g.tryGenerate, ()));
            if (ok) {
                landed++;
                (bool generated,) = abi.decode(ret, (bool, IDummyTransactionGenerator.DummyTxType));
                assertTrue(generated, "the caller's gas limit changed the generation's outcome");
            } else {
                refused++;
                assertEq(keccak256(ret), keccak256(abi.encodeWithSignature("Error(string)", "Insufficient gas")));
            }
            vm.revertToState(snap);
        }
        assertGt(landed, 0, "no gas limit let the attempt land");
        assertGt(refused, 0, "scan did not cover the gas threshold");
    }

    // ============ Helpers ============

    BatchQueue internal _lastQueue;

    function _queue(address target, bool shuffle) internal returns (BatchQueue q) {
        q = new BatchQueue(
            target,
            IERC20(address(token)),
            IBatchQueue.BatchConfig({
                minBatchSize: 1,
                maxBatchSize: 100,
                releaseInterval: 5 minutes,
                maxQueueTime: 1 days,
                randomizeOrder: shuffle,
                allowCancellation: true
            })
        );
        _lastQueue = q;
    }

    function _queueAcceptance(SP3AcceptanceTarget target) internal returns (uint256 id) {
        BatchQueue q = _queue(address(target), false);
        q.setRelayEnabled(true);
        target.setDispute(alice, bob, "terms v1");
        vm.prank(bob);
        id = q.queueAcceptance(1, keccak256("terms v1"));
    }

    function _assertAcceptanceFailsUnrelayed(SP3AcceptanceTarget target, uint256 id) internal {
        BatchQueue q = _lastQueue;
        vm.warp(block.timestamp + 6 minutes);
        (uint256 batchId,) = q.releaseBatch();
        vm.expectEmit(address(q));
        emit BatchExecuted(batchId, 0, 1, true);
        (bool ok,) = address(q).call{gas: 5_000_000}(abi.encodeCall(q.executeBatch, (batchId)));
        assertTrue(ok, "executeBatch reverted");
        assertEq(target.relayCount(), 0, "acceptance relayed without a live-proposal check");
        assertEq(uint8(q.getTransaction(id).status), uint8(IBatchQueue.QueueStatus.Failed));
        assertTrue(q.getBatch(batchId).executed);
    }

    function _gen(address target, uint256 probBps, uint256 maxSpend) internal returns (DummyTransactionGenerator g) {
        g = new DummyTransactionGenerator(
            target,
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
        g.setKeeper(keeper);
        vm.deal(address(this), 100 ether);
        g.fundTreasury{value: 10 ether}();
    }

    /// @dev Logs of one attempt: exactly one GenerationFailed(t) and no skip. (vm.recordLogs also returns
    ///      logs of reverted frames, so the rolled-back DummyTransactionGenerated is checked through state.)
    function _assertOnlyFailureLogged(address g, Vm.Log[] memory logs, IDummyTransactionGenerator.DummyTxType t)
        internal
        pure
    {
        uint256 failures;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != g) continue;
            bytes32 t0 = logs[i].topics[0];
            assertTrue(t0 != SKIPPED_SIG, "failed generation logged as a skip");
            if (t0 == FAILED_SIG) {
                assertEq(abi.decode(logs[i].data, (uint8)), uint8(t));
                failures++;
            }
        }
        assertEq(failures, 1, "failure not recorded");
    }

    /// @dev MIN_ATTEMPT_GAS, read through a low-level call so this file also compiles against the generator
    ///      before the fix (which has no such constant)
    function _minAttemptGas(DummyTransactionGenerator g) internal view returns (uint256) {
        (bool ok, bytes memory ret) = address(g).staticcall(abi.encodeWithSignature("MIN_ATTEMPT_GAS()"));
        return ok ? abi.decode(ret, (uint256)) : 700_000;
    }

    /// @dev Find a slot whose draw fails against `mode`, then try every gas limit around the threshold:
    ///      each call must be refused before the draw or land with the attempt consumed
    function _scanGasLimits(SP3FailingTarget.Mode mode) internal {
        SP3FailingTarget failing = new SP3FailingTarget();
        failing.setMode(mode);
        DummyTransactionGenerator g = _gen(address(failing), 10_000, 1 ether);

        bool found;
        for (uint256 k = 0; k < 10 && !found; k++) {
            vm.warp(block.timestamp + 1 minutes);
            uint256 probe = vm.snapshotState();
            (bool ok, bytes memory ret) = address(g).call{gas: 5_000_000}(abi.encodeCall(g.tryGenerate, ()));
            if (!ok || !abi.decode(ret, (bool))) {
                found = true; // a failing draw: rewind and scan this slot
                vm.revertToState(probe);
            }
        }
        assertTrue(found, "no failing draw found");

        uint256 totalBefore = g.getStats().totalGenerated;
        uint256 minGas = _minAttemptGas(g);
        uint256 landed;
        uint256 refused;
        for (uint256 gasLimit = minGas; gasLimit < minGas + 150_000; gasLimit += 1500) {
            uint256 snap = vm.snapshotState();
            (bool ok, bytes memory ret) = address(g).call{gas: gasLimit}(abi.encodeCall(g.tryGenerate, ()));
            if (ok) {
                landed++;
                (bool generated,) = abi.decode(ret, (bool, IDummyTransactionGenerator.DummyTxType));
                assertFalse(generated);
                assertEq(g.lastAttemptTime(), block.timestamp, "attempt not recorded");
                assertEq(g.getStats().totalGenerated, totalBefore);
                assertEq(g.dummyTreasury(), 10 ether);
            } else {
                refused++;
                // Hashes, so a 200 KB returndata is not printed on failure
                assertEq(
                    keccak256(ret),
                    keccak256(abi.encodeWithSignature("Error(string)", "Insufficient gas")),
                    "a drawn attempt was undone"
                );
            }
            vm.revertToState(snap);
        }
        assertGt(landed, 0, "no gas limit let the attempt land");
        assertGt(refused, 0, "scan did not cover the gas threshold");
    }
}
