// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/ILRM.sol";
import "../contracts/scaling/BatchQueue.sol";
import "../contracts/scaling/DummyTransactionGenerator.sol";
import "../contracts/mocks/MockAssetRegistry.sol";
import "../contracts/mocks/MockOracle.sol";
import "../contracts/mocks/MockToken.sol";

/// @dev Misconfigured / malicious ILRM target: re-enters the generator from initiateVoluntaryRequest
contract SPReentrantTarget {
    DummyTransactionGenerator public gen;
    uint8 public mode; // 0 = tryGenerate, 1 = generateBatch, 2 = fundTreasury, 3 = revert
    bool public reentered;

    function set(DummyTransactionGenerator g, uint8 m) external {
        gen = g;
        mode = m;
    }

    function initiateVoluntaryRequest(address, bytes32) external payable {
        if (mode == 3) revert("target reverted");
        if (mode == 2) {
            gen.fundTreasury{value: msg.value}(); // hand the fee straight back
            return;
        }
        reentered = true;
        if (mode == 0) gen.tryGenerate();
        else gen.generateBatch(1);
    }

    receive() external payable {}
}

/**
 * @title DummyTransactionGeneratorSecurityTest
 * @notice Behaviour of the hardened generator: keeper-only attempts, one attempt per slot, caps on every
 *         path, CEI accounting, reentrancy, labeled dummies against the real ILRM, and queue integration.
 */
contract DummyTransactionGeneratorSecurityTest is Test {
    event KeeperUpdated(address indexed previousKeeper, address indexed newKeeper);
    event TreasuryWithdrawn(address indexed to, uint256 amount);
    event TargetContractsUpdated(address indexed ilrm, address indexed batchQueue);
    event DisputeInitiated(
        uint256 indexed disputeId, address indexed initiator, address indexed counterparty, bytes32 evidenceHash
    );
    event DummyTransactionGenerated(
        uint256 indexed txIndex,
        IDummyTransactionGenerator.DummyTxType txType,
        address indexed dummyAddress,
        bytes32 dataHash
    );

    MockToken internal token;
    ILRM internal ilrm;
    DummyTransactionGenerator internal g;
    address internal keeper = makeAddr("keeper");
    address internal dummy1 = makeAddr("dummy1");
    address internal dummy2 = makeAddr("dummy2");

    function setUp() public {
        token = new MockToken();
        ilrm = _deployIlrm();
        g = _gen(address(ilrm), 10_000, 1000, 1 ether);
        g.setKeeper(keeper);
    }

    // ============ Access control and attempt rate ============

    function test_OnlyKeeperOrOwnerCanAttempt() public {
        address outsider = makeAddr("outsider");
        vm.startPrank(outsider);
        vm.expectRevert(bytes("Not keeper"));
        g.tryGenerate();
        vm.expectRevert(bytes("Not keeper"));
        g.performUpkeep("");
        vm.stopPrank();

        vm.prank(keeper);
        (bool generated,) = g.tryGenerate();
        assertTrue(generated);
        vm.warp(block.timestamp + 1 minutes);
        g.tryGenerate(); // owner
        assertEq(g.getStats().totalGenerated, 2);
    }

    function test_SetKeeperOnlyOwnerAndEmits() public {
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        g.setKeeper(keeper);
        vm.expectEmit(address(g));
        emit KeeperUpdated(keeper, address(0));
        g.setKeeper(address(0));
        vm.prank(keeper);
        vm.expectRevert(bytes("Not keeper"));
        g.tryGenerate();
    }

    function test_OneAttemptPerSlotEvenAfterSkip() public {
        g.updateConfig(_config(0, 1000, 1 ether)); // never generates
        vm.startPrank(keeper);
        g.tryGenerate();
        assertEq(g.getStats().consecutiveSkips, 1);
        (bool can, string memory why) = g.canGenerate();
        assertFalse(can);
        assertEq(why, "Min interval not passed");
        for (uint256 i = 0; i < 20; i++) {
            g.tryGenerate(); // no-ops inside the slot
        }
        assertEq(g.getStats().consecutiveSkips, 1, "retried inside the slot");
        assertEq(g.lastAttemptTime(), block.timestamp);
        assertEq(g.getTimeToNextGeneration(), 1 minutes);

        vm.warp(block.timestamp + 1 minutes);
        g.tryGenerate();
        assertEq(g.getStats().consecutiveSkips, 2);
        vm.stopPrank();
    }

    function test_PerformUpkeepIsInternalCall() public {
        (bool needed,) = g.checkUpkeep("");
        assertTrue(needed);
        vm.prank(keeper);
        g.performUpkeep("");
        assertEq(g.getStats().totalGenerated, 1);
        (needed,) = g.checkUpkeep("");
        assertFalse(needed);
    }

    function test_TimeToNextGenerationZeroBeforeAnyActivity() public view {
        assertEq(g.getTimeToNextGeneration(), 0);
    }

    // ============ Caps on every path ============

    function test_SpendCapIncludesCostOnEveryPath() public {
        g.updateConfig(_config(10_000, 1000, 0.025 ether));
        address burn = ilrm.BURN_ADDRESS();

        // keeper paths, one attempt per slot, until the cap stops paying dummies
        for (uint256 i = 0; i < 20; i++) {
            vm.warp(block.timestamp + 1 minutes);
            vm.prank(keeper);
            if (i % 2 == 0) g.tryGenerate();
            else g.performUpkeep("");
            assertLe(g.getStats().periodSpent, 0.025 ether, "keeper path spent above the cap");
        }
        assertEq(g.getStats().periodSpent, 0.02 ether, "keeper paths stop below the cap");

        // owner paths
        assertFalse(g.forceGenerate(IDummyTransactionGenerator.DummyTxType.VoluntaryRequest), "cap exceeded");
        assertTrue(g.forceGenerate(IDummyTransactionGenerator.DummyTxType.ViewingKeyCommit), "free type blocked");
        g.generateBatch(10);
        assertEq(g.getStats().periodSpent, 0.02 ether, "owner path spent above the cap");

        // outflow == accounted spend, and never above the cap
        assertEq(g.dummyTreasury(), 10 ether - g.getStats().periodSpent);
        assertEq(address(g).balance, g.dummyTreasury());
        assertEq(burn.balance, g.getStats().periodSpent);
    }

    function test_SpendCapIncludesCostOnOwnerPaths() public {
        g.updateConfig(_config(10_000, 1000, 0.025 ether));
        assertTrue(g.forceGenerate(IDummyTransactionGenerator.DummyTxType.VoluntaryRequest));
        assertTrue(g.forceGenerate(IDummyTransactionGenerator.DummyTxType.VoluntaryRequest));
        assertFalse(g.forceGenerate(IDummyTransactionGenerator.DummyTxType.VoluntaryRequest), "cap exceeded");
        // non-paying types still fit
        assertTrue(g.forceGenerate(IDummyTransactionGenerator.DummyTxType.ViewingKeyCommit));
        g.generateBatch(10);
        assertLe(g.getStats().periodSpent, 0.025 ether);
        assertEq(g.dummyTreasury(), 10 ether - g.getStats().periodSpent);
    }

    function test_MaxPerPeriodOnEveryPath() public {
        g.updateConfig(_config(10_000, 3, 1 ether));
        assertEq(g.generateBatch(10), 3);
        assertFalse(g.forceGenerate(IDummyTransactionGenerator.DummyTxType.ViewingKeyCommit));
        vm.warp(block.timestamp + 1 minutes);
        vm.prank(keeper);
        (bool generated,) = g.tryGenerate();
        assertFalse(generated);
        vm.prank(keeper);
        g.performUpkeep("");
        assertEq(g.getStats().periodGenerated, 3);
        assertLe(10 ether - address(g).balance, 3 * g.DEFAULT_VOLUNTARY_FEE(), "outflow above maxPerPeriod * fee");

        vm.warp(block.timestamp + 1 days); // period resets
        assertTrue(g.forceGenerate(IDummyTransactionGenerator.DummyTxType.ViewingKeyCommit));
        assertEq(g.getStats().periodGenerated, 1);
    }

    function test_TreasuryAccountingMatchesBalance() public {
        for (uint256 i = 0; i < 30; i++) {
            vm.warp(block.timestamp + 1 minutes);
            vm.prank(keeper);
            g.tryGenerate();
        }
        assertEq(address(g).balance, g.dummyTreasury(), "accounting != ETH held");
        assertEq(ilrm.BURN_ADDRESS().balance, 10 ether - g.dummyTreasury(), "spent != burned");
    }

    function test_PauseStopsEveryGenerationPath() public {
        g.pause();
        vm.prank(keeper);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        g.tryGenerate();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        g.forceGenerate(IDummyTransactionGenerator.DummyTxType.VoluntaryRequest);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        g.generateBatch(1);
        vm.prank(keeper);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        g.performUpkeep("");
    }

    // ============ CEI and reentrancy ============

    function test_FailedTargetCallRevertsWholeGeneration() public {
        SPReentrantTarget t = new SPReentrantTarget();
        DummyTransactionGenerator tg = _gen(address(t), 10_000, 1000, 1 ether);
        t.set(tg, 3);
        IDummyTransactionGenerator.GeneratorStats memory before = tg.getStats();
        vm.expectRevert(bytes("target reverted"));
        tg.forceGenerate(IDummyTransactionGenerator.DummyTxType.VoluntaryRequest);
        assertEq(tg.getStats().totalGenerated, before.totalGenerated);
        assertEq(tg.dummyTreasury(), 10 ether);
    }

    function test_ReentryFromTargetReverts() public {
        SPReentrantTarget t = new SPReentrantTarget();
        DummyTransactionGenerator tg = _gen(address(t), 10_000, 1000, 1 ether);
        tg.transferOwnership(address(t)); // worst case: the target is even the owner
        vm.prank(address(t));
        tg.acceptOwnership();

        for (uint8 m = 0; m < 2; m++) {
            t.set(tg, m);
            vm.prank(address(t));
            vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
            tg.forceGenerate(IDummyTransactionGenerator.DummyTxType.VoluntaryRequest);
        }
    }

    function test_FundsReturnedDuringCallKeepAccountingExact() public {
        SPReentrantTarget t = new SPReentrantTarget();
        DummyTransactionGenerator tg = _gen(address(t), 10_000, 1000, 1 ether);
        t.set(tg, 2);
        assertTrue(tg.forceGenerate(IDummyTransactionGenerator.DummyTxType.VoluntaryRequest));
        assertEq(tg.dummyTreasury(), 10 ether);
        assertEq(address(tg).balance, 10 ether);
    }

    // ============ Targets ============

    function test_SetTargetContractsChecksCodeAndEmits() public {
        vm.expectRevert(bytes("Invalid ILRM"));
        g.setTargetContracts(makeAddr("eoa"), address(0));
        vm.expectRevert(bytes("Invalid BatchQueue"));
        g.setTargetContracts(address(ilrm), makeAddr("eoa"));
        vm.expectEmit(address(g));
        emit TargetContractsUpdated(address(ilrm), address(0));
        g.setTargetContracts(address(ilrm), address(0));
    }

    function test_WithdrawTreasuryEmits() public {
        vm.expectEmit(address(g));
        emit TreasuryWithdrawn(dummy1, 1 ether);
        g.withdrawTreasury(dummy1, 1 ether);
        assertEq(dummy1.balance, 1 ether);
    }

    function test_FakeVrfRemoved() public {
        (bool ok,) = address(g).call(abi.encodeWithSignature("requestRandomness()"));
        assertFalse(ok);
    }

    /// @notice DummyTransactionGenerated keeps the original 0-based txIndex numbering
    function test_EventIdIsZeroBased() public {
        vm.expectEmit(true, false, false, false, address(g));
        emit DummyTransactionGenerated(0, IDummyTransactionGenerator.DummyTxType.ViewingKeyCommit, address(0), 0);
        assertTrue(g.forceGenerate(IDummyTransactionGenerator.DummyTxType.ViewingKeyCommit));
        assertEq(g.getStats().totalGenerated, 1);

        vm.expectEmit(true, false, false, false, address(g));
        emit DummyTransactionGenerated(1, IDummyTransactionGenerator.DummyTxType.ViewingKeyCommit, address(0), 0);
        assertTrue(g.forceGenerate(IDummyTransactionGenerator.DummyTxType.ViewingKeyCommit));
        assertEq(g.getStats().totalGenerated, 2);
    }

    // ============ Against the real ILRM / BatchQueue ============

    /// @notice Against the real ILRM: DisputeInitiated(max, generator, another dummy), a 0.01 ETH burn,
    ///         and accounting equal to the ETH held. Also documents the privacy limit: ILRM records the
    ///         generator as the initiator.
    function test_RealIlrm_DummyIsAttributableToGenerator() public {
        vm.recordLogs();
        assertTrue(g.forceGenerate(IDummyTransactionGenerator.DummyTxType.VoluntaryRequest));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        address chosen;
        address cp;
        uint256 seen;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(g) && logs[i].topics[0] == DummyTransactionGenerated.selector) {
                assertEq(uint256(logs[i].topics[1]), 0, "0-based txIndex");
                chosen = address(uint160(uint256(logs[i].topics[2])));
            } else if (logs[i].emitter == address(ilrm) && logs[i].topics[0] == DisputeInitiated.selector) {
                seen++;
                assertEq(logs[i].topics[1], bytes32(type(uint256).max), "voluntary-request id");
                assertEq(address(uint160(uint256(logs[i].topics[2]))), address(g), "initiator");
                cp = address(uint160(uint256(logs[i].topics[3])));
            }
        }
        assertEq(seen, 1);
        assertTrue(chosen == dummy1 || chosen == dummy2, "dummy is a registered dummy");
        assertTrue(cp == dummy1 || cp == dummy2, "counterparty is a registered dummy");
        assertTrue(cp != chosen, "counterparty is another dummy");

        assertEq(ilrm.BURN_ADDRESS().balance, 0.01 ether, "fee burned");
        assertEq(g.dummyTreasury(), 10 ether - 0.01 ether);
        assertEq(address(g).balance, g.dummyTreasury(), "accounting != ETH held");
    }

    function test_RealBatchQueue_EntryIsRecordOnlyAndExecutes() public {
        IBatchQueue.BatchConfig memory c = IBatchQueue.BatchConfig({
            minBatchSize: 1,
            maxBatchSize: 10,
            releaseInterval: 5 minutes,
            maxQueueTime: 1 days,
            randomizeOrder: true,
            allowCancellation: true
        });
        BatchQueue q = new BatchQueue(address(ilrm), IERC20(address(token)), c);
        g.setTargetContracts(address(ilrm), address(q));
        assertTrue(g.forceGenerate(IDummyTransactionGenerator.DummyTxType.BatchQueueEntry));
        IBatchQueue.QueuedTx memory e = q.getTransaction(0);
        assertEq(uint8(e.txType), uint8(IBatchQueue.TxType.EvidenceSubmission));
        assertEq(e.submitter, address(g));

        vm.warp(block.timestamp + 6 minutes);
        (uint256 b,) = q.releaseBatch();
        q.executeBatch(b);
        assertTrue(q.getBatch(b).executed);

        // A paused queue makes the dummy fail atomically (no accounting change)
        q.pause();
        uint256 total = g.getStats().totalGenerated;
        vm.expectRevert(Pausable.EnforcedPause.selector);
        g.forceGenerate(IDummyTransactionGenerator.DummyTxType.BatchQueueEntry);
        assertEq(g.getStats().totalGenerated, total);
    }

    // ============ Helpers ============

    function _deployIlrm() internal returns (ILRM) {
        return new ILRM(IERC20(address(token)), address(new MockOracle()), new MockAssetRegistry());
    }

    function _config(uint256 probBps, uint256 maxPerPeriod, uint256 maxSpend)
        internal
        pure
        returns (IDummyTransactionGenerator.GeneratorConfig memory)
    {
        return IDummyTransactionGenerator.GeneratorConfig({
            minInterval: 1 minutes,
            maxInterval: 1 hours,
            probabilityBps: probBps,
            maxPerPeriod: maxPerPeriod,
            periodDuration: 1 days,
            maxTreasurySpend: maxSpend,
            enabled: true
        });
    }

    function _gen(address target, uint256 probBps, uint256 maxPerPeriod, uint256 maxSpend)
        internal
        returns (DummyTransactionGenerator gen)
    {
        gen = new DummyTransactionGenerator(target, _config(probBps, maxPerPeriod, maxSpend));
        gen.registerDummyAddress(dummy1);
        gen.registerDummyAddress(dummy2);
        vm.deal(address(this), 100 ether);
        gen.fundTreasury{value: 10 ether}();
    }
}
