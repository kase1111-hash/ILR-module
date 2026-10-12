// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../contracts/ILRM.sol";
import "../contracts/scaling/BatchQueue.sol";
import "../contracts/mocks/MockAssetRegistry.sol";
import "../contracts/mocks/MockOracle.sol";
import "../contracts/mocks/MockToken.sol";

/// @dev Relay-capable ILRM stand-in with configurable behaviour. Its disputes() view returns a struct
///      whose IILRM.Dispute fields are filled one by one in storage (never a struct literal), so fields
///      added to the struct by other workstreams do not break compilation.
contract SPRelayTarget {
    enum Mode {
        Normal, // pull the full stake and succeed
        Revert, // revert every relay
        PullHalf, // pull half the stake and succeed
        PullMore, // try to pull 2x the stake
        PayIn // send tokens to the caller instead of pulling
    }

    IERC20 public immutable token;
    Mode public mode;
    IILRM.Dispute internal _d;
    uint256 public relayCount;
    uint256 public minGasSeen = type(uint256).max;
    uint256 public burnGas;
    address public lastParty;

    constructor(IERC20 t) {
        token = t;
    }

    function setMode(Mode m) external {
        mode = m;
    }

    function setBurnGas(uint256 g) external {
        burnGas = g;
    }

    function setDispute(address initiator, address counterparty, string calldata proposal, uint256 round, bool resolved)
        external
    {
        _d.initiator = initiator;
        _d.counterparty = counterparty;
        _d.llmProposal = proposal;
        _d.counterCount = round;
        _d.resolved = resolved;
    }

    function disputes(uint256) external view returns (IILRM.Dispute memory) {
        return _d;
    }

    function initiateBreachDisputeFor(
        address initiator,
        address,
        uint256 stake,
        bytes32,
        IILRM.FallbackLicense calldata
    ) external returns (uint256) {
        _enter(initiator);
        if (mode == Mode.Revert) revert("relay reverted");
        if (mode == Mode.PayIn) {
            require(token.transfer(msg.sender, 1), "pay-in failed");
            return relayCount;
        }
        uint256 amount = mode == Mode.PullHalf ? stake / 2 : mode == Mode.PullMore ? stake * 2 : stake;
        require(token.transferFrom(msg.sender, address(this), amount), "pull failed");
        return relayCount;
    }

    function depositStakeFor(uint256, address depositor) external {
        _enter(depositor);
        if (mode == Mode.Revert) revert("relay reverted");
    }

    function acceptProposalFor(uint256, address acceptor) external {
        _enter(acceptor);
        if (mode == Mode.Revert) revert("relay reverted");
    }

    function _enter(address party) internal {
        uint256 g = gasleft();
        if (g < minGasSeen) minGasSeen = g;
        lastParty = party;
        relayCount++;
        while (g - gasleft() < burnGas) {}
    }
}

/// @dev Token that takes a 1% fee on transfer
contract SPFeeToken is ERC20 {
    constructor() ERC20("Fee", "FEE") {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, address(0xFEE), fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}

/**
 * @title BatchQueueSecurityTest
 * @notice Behaviour of the hardened BatchQueue: relay gating, party binding, escrow isolation and exits,
 *         bounded release, gas-safe execution, proposal binding, and compatibility with the real ILRM.
 */
contract BatchQueueSecurityTest is Test {
    // Redeclared for expectEmit (0.8.20 cannot reference interface events by qualified name)
    event RelayEnabledUpdated(bool enabled);
    event BatchExecuted(uint256 indexed batchId, uint256 successCount, uint256 failCount, bool complete);

    MockToken internal token;
    ILRM internal ilrm;
    SPRelayTarget internal relay;
    BatchQueue internal q;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    bytes internal fb;

    function setUp() public {
        token = new MockToken();
        ilrm = _deployIlrm();
        relay = new SPRelayTarget(IERC20(address(token)));
        fb = abi.encode(IILRM.FallbackLicense(keccak256("terms"), 365 days, 500, true));
        q = _deploy(address(relay));
        q.setRelayEnabled(true);
        for (uint256 i = 0; i < 3; i++) {
            address u = [alice, bob, carol][i];
            token.mint(u, 1000 ether);
            vm.prank(u);
            token.approve(address(q), type(uint256).max);
        }
    }

    // ============ Relay gating and party binding ============

    function test_RelayDisabledByDefault() public {
        BatchQueue fresh = _deploy(address(ilrm));
        assertFalse(fresh.relayEnabled());
        vm.startPrank(alice);
        vm.expectRevert(bytes("Relay disabled"));
        fresh.queueDisputeInitiation(bob, 1 ether, bytes32("e"), fb);
        vm.expectRevert(bytes("Relay disabled"));
        fresh.queueStakeDeposit(0);
        vm.expectRevert(bytes("Relay disabled"));
        fresh.queueAcceptance(0, keccak256("p"));
        // record-only types still work
        fresh.queueZKProof(0, hex"01");
        fresh.queueTransaction(IBatchQueue.TxType.EvidenceSubmission, hex"02");
        vm.stopPrank();
        assertEq(fresh.getPendingCount(), 2);
    }

    function test_SetRelayEnabledOnlyOwnerAndEmits() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        q.setRelayEnabled(false);
        vm.expectEmit(address(q));
        emit RelayEnabledUpdated(false);
        q.setRelayEnabled(false);
    }

    function test_ConstructorRejectsIlrmWithoutCode() public {
        vm.expectRevert(bytes("Invalid ILRM"));
        new BatchQueue(makeAddr("eoa"), IERC20(address(token)), _cfg());
    }

    function test_QueueTransactionRejectsRelayedTypes() public {
        vm.startPrank(alice);
        vm.expectRevert(bytes("Use typed queue function"));
        q.queueTransaction(IBatchQueue.TxType.DisputeInitiation, abi.encode(bob, 1 ether, bytes32(0), fb));
        vm.expectRevert(bytes("Use typed queue function"));
        q.queueTransaction(IBatchQueue.TxType.StakeDeposit, abi.encode(uint256(0), bob));
        vm.expectRevert(bytes("Use typed queue function"));
        q.queueTransaction(IBatchQueue.TxType.ProposalAcceptance, abi.encode(uint256(0), bob));
        vm.stopPrank();
    }

    function test_QueueTransactionRejectsEth() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(q).call{value: 1}(
            abi.encodeCall(q.queueTransaction, (IBatchQueue.TxType.EvidenceSubmission, hex"01"))
        );
        assertFalse(ok, "queue accepted ETH");
        (ok,) = address(q).call{value: 1}("");
        assertFalse(ok, "queue accepts plain ETH transfers");
    }

    function test_StakeDepositRelayedForSubmitterOnly() public {
        vm.prank(alice);
        q.queueStakeDeposit(42);
        _releaseExecute();
        assertEq(relay.lastParty(), alice);
    }

    // ============ Dispute initiation escrow ============

    function test_InitiationValidatesInputs() public {
        vm.startPrank(alice);
        vm.expectRevert(bytes("Cannot dispute self"));
        q.queueDisputeInitiation(alice, 1 ether, bytes32("e"), fb);
        vm.expectRevert(bytes("Fallback must be non-exclusive"));
        q.queueDisputeInitiation(bob, 1 ether, bytes32("e"), abi.encode(IILRM.FallbackLicense(0, 1, 1, false)));
        vm.expectRevert();
        q.queueDisputeInitiation(bob, 1 ether, bytes32("e"), hex"1234");
        vm.stopPrank();
    }

    function test_InitiationEscrowsExactlyStake() public {
        vm.prank(alice);
        uint256 id = q.queueDisputeInitiation(bob, 10 ether, bytes32("e"), fb);
        assertEq(q.escrowOf(id), 10 ether);
        assertEq(q.totalEscrowed(), 10 ether);
        assertEq(token.balanceOf(address(q)), 10 ether);
    }

    function test_FeeOnTransferTokenRejected() public {
        SPFeeToken ft = new SPFeeToken();
        BatchQueue fq = new BatchQueue(address(relay), IERC20(address(ft)), _cfg());
        fq.setRelayEnabled(true);
        ft.mint(alice, 100 ether);
        vm.startPrank(alice);
        ft.approve(address(fq), type(uint256).max);
        vm.expectRevert(bytes("Escrow short"));
        fq.queueDisputeInitiation(bob, 10 ether, bytes32("e"), fb);
        vm.stopPrank();
    }

    function test_InitiationRelayUsesExactAllowanceAndResetsIt() public {
        vm.prank(alice);
        uint256 id = q.queueDisputeInitiation(bob, 10 ether, bytes32("e"), fb);
        _releaseExecute();
        assertEq(uint8(q.getTransaction(id).status), uint8(IBatchQueue.QueueStatus.Executed));
        assertEq(relay.lastParty(), alice);
        assertEq(q.escrowOf(id), 0);
        assertEq(q.totalEscrowed(), 0);
        assertEq(token.allowance(address(q), address(relay)), 0, "allowance left behind");
    }

    function test_RelayCannotPullBeyondOwnEscrow() public {
        vm.prank(bob);
        uint256 other = q.queueDisputeInitiation(carol, 50 ether, bytes32("o"), fb);
        IBatchQueue.BatchConfig memory c = _cfg();
        c.maxBatchSize = 1;
        q.updateConfig(c);
        _releaseExecute(); // bob's executes normally first

        vm.prank(alice);
        uint256 id = q.queueDisputeInitiation(bob, 10 ether, bytes32("e"), fb);
        vm.prank(carol);
        q.queueDisputeInitiation(alice, 40 ether, bytes32("c"), fb);
        relay.setMode(SPRelayTarget.Mode.PullMore);
        _releaseExecute(); // alice's: relay tries to pull 20 ether with a 10 ether allowance

        assertEq(uint8(q.getTransaction(other).status), uint8(IBatchQueue.QueueStatus.Executed));
        assertEq(uint8(q.getTransaction(id).status), uint8(IBatchQueue.QueueStatus.Failed));
        assertEq(q.escrowOf(id), 10 ether, "failed relay consumed escrow");
        assertEq(token.balanceOf(address(q)), 50 ether, "escrow of queued txs touched");
        assertEq(q.totalEscrowed(), 50 ether);
    }

    function test_PartialPullFailsAndLeftoverIsReclaimable() public {
        relay.setMode(SPRelayTarget.Mode.PullHalf);
        vm.prank(alice);
        uint256 id = q.queueDisputeInitiation(bob, 10 ether, bytes32("e"), fb);
        _releaseExecute();
        assertEq(uint8(q.getTransaction(id).status), uint8(IBatchQueue.QueueStatus.Failed));
        assertEq(q.escrowOf(id), 5 ether);
        uint256 before = token.balanceOf(alice);
        q.reclaim(id);
        assertEq(token.balanceOf(alice) - before, 5 ether);
        assertEq(q.totalEscrowed(), 0);
    }

    function test_RelayPayingTokensInCannotBrickBatch() public {
        token.mint(address(relay), 1 ether);
        relay.setMode(SPRelayTarget.Mode.PayIn);
        vm.prank(alice);
        uint256 id = q.queueDisputeInitiation(bob, 10 ether, bytes32("e"), fb);
        _releaseExecute();
        assertEq(uint8(q.getTransaction(id).status), uint8(IBatchQueue.QueueStatus.Failed));
        assertEq(q.reclaim(id), 10 ether);
        assertEq(token.balanceOf(address(q)), 1, "inbound tokens become surplus");
    }

    function test_RevertingRelayFailsAndEscrowIsReclaimable() public {
        relay.setMode(SPRelayTarget.Mode.Revert);
        vm.prank(alice);
        uint256 id = q.queueDisputeInitiation(bob, 10 ether, bytes32("e"), fb);
        _releaseExecute();
        assertEq(uint8(q.getTransaction(id).status), uint8(IBatchQueue.QueueStatus.Failed));
        vm.prank(carol); // anyone can trigger; always pays the submitter
        assertEq(q.reclaim(id), 10 ether);
        assertEq(token.balanceOf(alice), 1000 ether);
        vm.expectRevert(bytes("Nothing to reclaim"));
        q.reclaim(id);
    }

    function test_RelayDisabledMidFlightFailsWithoutCallingIlrm() public {
        vm.prank(alice);
        uint256 id = q.queueDisputeInitiation(bob, 10 ether, bytes32("e"), fb);
        q.setRelayEnabled(false);
        _releaseExecute();
        assertEq(relay.relayCount(), 0);
        assertEq(uint8(q.getTransaction(id).status), uint8(IBatchQueue.QueueStatus.Failed));
        assertEq(q.reclaim(id), 10 ether);
    }

    // ============ Exits: cancel and reclaim ============

    function test_CancelReturnsEscrowEvenWhilePaused() public {
        vm.prank(alice);
        uint256 id = q.queueDisputeInitiation(bob, 10 ether, bytes32("e"), fb);
        q.pause();
        vm.prank(alice);
        q.cancelTransaction(id);
        assertEq(token.balanceOf(alice), 1000 ether);
        assertEq(q.getPendingCount(), 0);
        assertEq(q.totalEscrowed(), 0);
    }

    function test_ReclaimStalePendingWithoutKeeperEvenWhilePaused() public {
        vm.prank(alice);
        uint256 id = q.queueDisputeInitiation(bob, 10 ether, bytes32("e"), fb);
        vm.expectRevert(bytes("Not expired"));
        q.reclaim(id);
        q.pause();
        vm.warp(block.timestamp + 1 days + 1);
        q.reclaim(id);
        assertEq(uint8(q.getTransaction(id).status), uint8(IBatchQueue.QueueStatus.Expired));
        assertEq(token.balanceOf(alice), 1000 ether);
        assertEq(q.getPendingCount(), 0);
    }

    function test_ReclaimReleasedButNeverExecuted() public {
        vm.prank(alice);
        uint256 id = q.queueDisputeInitiation(bob, 10 ether, bytes32("e"), fb);
        vm.warp(block.timestamp + 6 minutes);
        (uint256 b,) = q.releaseBatch();
        q.pause(); // execution blocked
        vm.expectRevert(bytes("Execution window open"));
        q.reclaim(id);
        vm.warp(block.timestamp + 1 days + 1);
        q.reclaim(id);
        assertEq(token.balanceOf(alice), 1000 ether);

        // Executing later skips it
        q.unpause();
        (uint256 s, uint256 f) = q.executeBatch(b);
        assertEq(s + f, 0);
        assertEq(relay.relayCount(), 0);
        assertTrue(q.getBatch(b).executed);
    }

    function test_ReclaimNothingForExecutedOrRecordOnly() public {
        vm.prank(alice);
        uint256 a = q.queueDisputeInitiation(bob, 10 ether, bytes32("e"), fb);
        vm.prank(alice);
        uint256 z = q.queueZKProof(1, hex"01");
        _releaseExecute();
        vm.expectRevert(bytes("Nothing to reclaim"));
        q.reclaim(a);
        vm.expectRevert(bytes("Nothing to reclaim"));
        q.reclaim(z);
        vm.expectRevert(bytes("Nothing to reclaim"));
        q.reclaim(999); // never queued
    }

    function test_EmergencyWithdrawCannotTouchEscrow() public {
        vm.prank(alice);
        q.queueDisputeInitiation(bob, 10 ether, bytes32("e"), fb);
        token.mint(address(q), 3 ether); // donation = surplus
        vm.expectRevert(bytes("Exceeds surplus"));
        q.emergencyWithdraw(address(this), 3 ether + 1, true);
        q.emergencyWithdraw(address(this), 3 ether, true);
        assertEq(token.balanceOf(address(q)), 10 ether);

        vm.deal(address(q), 1 ether); // force-sent ETH is surplus
        q.emergencyWithdraw(carol, 1 ether, false);
        assertEq(carol.balance, 1 ether);
    }

    // ============ Bounded release ============

    function test_ReleaseIsFifoAndSkipsDeadEntries() public {
        IBatchQueue.BatchConfig memory c = _cfg();
        c.randomizeOrder = false;
        q.updateConfig(c);
        vm.startPrank(alice);
        uint256 a0 = q.queueZKProof(0, hex"");
        uint256 a1 = q.queueZKProof(1, hex"");
        uint256 a2 = q.queueZKProof(2, hex"");
        q.cancelTransaction(a1);
        vm.stopPrank();
        vm.warp(block.timestamp + 6 minutes);
        (uint256 b, uint256 n) = q.releaseBatch();
        assertEq(n, 2);
        uint256[] memory ids = q.getBatch(b).txIds;
        assertEq(ids.length, 2, "batch has trailing ids");
        assertEq(ids[0], a0);
        assertEq(ids[1], a2);
    }

    function test_ReleaseWithOnlyStaleEntriesCreatesNoBatch() public {
        vm.prank(alice);
        uint256 id = q.queueDisputeInitiation(bob, 10 ether, bytes32("e"), fb);
        vm.warp(block.timestamp + 2 days);
        uint256 lastRelease = q.lastReleaseTime();
        (, uint256 n) = q.releaseBatch();
        assertEq(n, 0);
        assertEq(q.getTotalBatchCount(), 0);
        assertEq(q.lastReleaseTime(), lastRelease, "release interval consumed by an empty scan");
        assertEq(uint8(q.getTransaction(id).status), uint8(IBatchQueue.QueueStatus.Expired));
        assertEq(q.escrowOf(id), 10 ether, "expiry moved escrow");
        q.reclaim(id);
        assertEq(token.balanceOf(alice), 1000 ether);
    }

    function test_ReleaseScanBoundedByMaxLoopIterations() public {
        // 600 dead entries ahead of a live one: first release scans 500, second reaches the live one
        vm.startPrank(alice);
        for (uint256 i = 0; i < 600; i++) {
            q.cancelTransaction(q.queueZKProof(i, hex""));
        }
        uint256 live = q.queueZKProof(600, hex"");
        vm.stopPrank();
        vm.warp(block.timestamp + 6 minutes);
        (, uint256 n) = q.releaseBatch();
        assertEq(n, 0);
        (uint256 b, uint256 n2) = q.releaseBatch();
        assertEq(n2, 1);
        assertEq(q.getBatch(b).txIds[0], live);
    }

    // ============ Gas-safe execution ============

    function test_LowGasCallerCannotFailRelays() public {
        IBatchQueue.BatchConfig memory c = _cfg();
        c.maxBatchSize = 10;
        q.updateConfig(c);
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(alice);
            q.queueStakeDeposit(i);
        }
        vm.warp(block.timestamp + 6 minutes);
        (uint256 b,) = q.releaseBatch();
        relay.setBurnGas(400_000); // each relay really needs ~400k gas

        // Enough gas for a few transactions only: execution stops instead of failing the rest
        (bool ok,) = address(q).call{gas: 3_000_000}(abi.encodeCall(q.executeBatch, (b)));
        assertTrue(ok);
        assertFalse(q.getBatch(b).executed);
        assertGt(relay.relayCount(), 0);
        assertLt(relay.relayCount(), 10);
        assertGe(relay.minGasSeen(), q.RELAY_GAS_LIMIT() - 5000, "relay ran short of gas");
        for (uint256 i = 0; i < 10; i++) {
            assertTrue(q.getTransaction(i).status != IBatchQueue.QueueStatus.Failed, "relay failed for lack of gas");
        }

        q.executeBatch(b);
        assertTrue(q.getBatch(b).executed);
        assertEq(relay.relayCount(), 10);
        for (uint256 i = 0; i < 10; i++) {
            assertEq(uint8(q.getTransaction(i).status), uint8(IBatchQueue.QueueStatus.Executed));
        }
        vm.expectRevert(bytes("Already executed"));
        q.executeBatch(b);
    }

    /// @notice The MIN_GAS_PER_TX guard applies only to transactions that call ILRM: a record-only batch
    ///         (e.g. generator dummies) completes under a small Automation gas limit, relaying enabled
    function test_RecordOnlyBatchExecutesUnderLowGas() public {
        IBatchQueue.BatchConfig memory c = _cfg();
        c.maxBatchSize = 20;
        q.updateConfig(c);
        for (uint256 i = 0; i < 20; i++) {
            vm.prank(alice);
            if (i % 2 == 0) q.queueZKProof(i, hex"01");
            else q.queueTransaction(IBatchQueue.TxType.EvidenceSubmission, abi.encode(i));
        }
        vm.warp(block.timestamp + 6 minutes);
        (uint256 b, uint256 n) = q.releaseBatch();
        assertEq(n, 20);
        assertTrue(q.relayEnabled());

        uint256 gasLimit = 600_000;
        assertLt(gasLimit, q.MIN_GAS_PER_TX());
        vm.expectEmit(address(q));
        emit BatchExecuted(b, 0, 20, true);
        (bool ok,) = address(q).call{gas: gasLimit}(abi.encodeCall(q.executeBatch, (b)));
        assertTrue(ok, "record-only batch needs more than a small gas limit");
        assertTrue(q.getBatch(b).executed, "record-only batch stalled on the relay gas guard");
        for (uint256 i = 0; i < 20; i++) {
            assertEq(uint8(q.getTransaction(i).status), uint8(IBatchQueue.QueueStatus.Failed));
        }
        assertEq(relay.relayCount(), 0);
    }

    /// @notice Release never calls out (no ILRM call, no token transfer), so no queued transaction or
    ///         target can make it revert
    function test_ReleaseMakesNoExternalCalls() public {
        relay.setMode(SPRelayTarget.Mode.Revert);
        vm.startPrank(alice);
        q.queueDisputeInitiation(bob, 10 ether, bytes32("e"), fb);
        q.queueStakeDeposit(1);
        q.queueZKProof(2, hex"01");
        vm.stopPrank();
        vm.prank(bob);
        uint256 stale = q.queueDisputeInitiation(carol, 5 ether, bytes32("s"), fb);
        vm.warp(block.timestamp + 1 days + 1); // everything stale: release only expires
        vm.prank(carol);
        q.queueZKProof(3, hex"02");
        vm.warp(block.timestamp + 6 minutes);

        vm.expectCall(address(relay), bytes(""), 0);
        vm.expectCall(address(token), bytes(""), 0);
        (, uint256 n) = q.releaseBatch();
        assertEq(n, 1);
        assertEq(uint8(q.getTransaction(stale).status), uint8(IBatchQueue.QueueStatus.Expired));
        assertEq(q.escrowOf(stale), 5 ether, "expiry moved escrow");
        assertEq(address(q).balance, 0, "queue holds ETH");
    }

    function test_ExecuteBatchPausable() public {
        vm.prank(alice);
        q.queueZKProof(0, hex"");
        vm.warp(block.timestamp + 6 minutes);
        (uint256 b,) = q.releaseBatch();
        q.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        q.executeBatch(b);
    }

    function test_PerformUpkeepReleasesAndExecutes() public {
        vm.prank(alice);
        q.queueStakeDeposit(1);
        vm.warp(block.timestamp + 6 minutes);
        (bool needed,) = q.checkUpkeep("");
        assertTrue(needed);
        vm.expectEmit(address(q));
        emit BatchExecuted(0, 1, 0, true);
        vm.prank(carol); // permissionless
        q.performUpkeep("");
        assertEq(relay.relayCount(), 1);
    }

    // ============ Acceptance bound to proposal and round ============

    function test_AcceptanceQueueRequiresPartyAndLiveProposal() public {
        relay.setDispute(alice, bob, "terms v1", 0, false);
        vm.prank(carol);
        vm.expectRevert(bytes("Not a party"));
        q.queueAcceptance(1, keccak256("terms v1"));
        vm.prank(alice);
        vm.expectRevert(bytes("Not the live proposal"));
        q.queueAcceptance(1, keccak256("terms v0"));
        relay.setDispute(alice, bob, "", 0, false);
        vm.prank(alice);
        vm.expectRevert(bytes("No proposal yet"));
        q.queueAcceptance(1, bytes32(0));
    }

    function test_AcceptanceRelayedWhenProposalUnchanged() public {
        relay.setDispute(alice, bob, "terms v1", 2, false);
        vm.prank(bob);
        q.queueAcceptance(1, keccak256("terms v1"));
        _releaseExecute();
        assertEq(relay.relayCount(), 1);
        assertEq(relay.lastParty(), bob);
    }

    function test_AcceptanceNotRelayedAfterProposalReplacedInSameRound() public {
        relay.setDispute(alice, bob, "terms v1", 0, false);
        vm.prank(bob);
        uint256 id = q.queueAcceptance(1, keccak256("terms v1"));
        relay.setDispute(alice, bob, "terms v1 (superseded)", 0, false); // Oracle-owner replacement
        _releaseExecute();
        assertEq(relay.relayCount(), 0);
        assertEq(uint8(q.getTransaction(id).status), uint8(IBatchQueue.QueueStatus.Failed));
    }

    function test_AcceptanceNotRelayedAfterNewRoundWithSameText() public {
        relay.setDispute(alice, bob, "terms v1", 0, false);
        vm.prank(bob);
        q.queueAcceptance(1, keccak256("terms v1"));
        relay.setDispute(alice, bob, "terms v1", 1, false); // counter-proposal round, same text
        _releaseExecute();
        assertEq(relay.relayCount(), 0);
    }

    function test_AcceptanceNotRelayedAfterResolution() public {
        relay.setDispute(alice, bob, "terms v1", 0, false);
        vm.prank(bob);
        q.queueAcceptance(1, keccak256("terms v1"));
        relay.setDispute(alice, bob, "terms v1", 0, true);
        _releaseExecute();
        assertEq(relay.relayCount(), 0);
    }

    // ============ Against the real ILRM (current API) ============

    /// @notice queueAcceptance reads the real ILRM's disputes() struct (party, resolved, llmProposal).
    ///         Uses only initiateBreachDispute / enforceTimeout: no oracle-owned function is called.
    function test_RealIlrm_AcceptanceQueueReadsDisputesStruct() public {
        BatchQueue rq = _deploy(address(ilrm));
        rq.setRelayEnabled(true);
        uint256 id = _realOpenDispute();

        vm.prank(carol);
        vm.expectRevert(bytes("Not a party"));
        rq.queueAcceptance(id, keccak256(""));
        vm.prank(alice);
        vm.expectRevert(bytes("No proposal yet"));
        rq.queueAcceptance(id, keccak256(""));
        vm.prank(bob);
        vm.expectRevert(bytes("No proposal yet"));
        rq.queueAcceptance(id, bytes32(0));

        // Unknown id: the zeroed struct names no party
        vm.prank(alice);
        vm.expectRevert(bytes("Not a party"));
        rq.queueAcceptance(id + 1, keccak256(""));

        // Resolved (non-participation timeout)
        vm.warp(block.timestamp + ilrm.STAKE_WINDOW() + 1);
        ilrm.enforceTimeout(id);
        assertTrue(ilrm.disputes(id).resolved);
        vm.prank(alice);
        vm.expectRevert(bytes("Dispute resolved"));
        rq.queueAcceptance(id, keccak256(""));
        assertEq(rq.getTotalTxCount(), 0);
    }

    function test_RealIlrm_RelaysFailCleanlyAndEscrowReturns() public {
        BatchQueue rq = _deploy(address(ilrm));
        rq.setRelayEnabled(true);
        uint256 id = _realOpenDispute();
        vm.startPrank(bob);
        token.approve(address(rq), type(uint256).max);
        uint256 s = rq.queueStakeDeposit(id);
        uint256 d = rq.queueDisputeInitiation(carol, 5 ether, bytes32("e"), fb);
        vm.stopPrank();

        uint256 disputeCount = ilrm.disputeCounter();

        vm.warp(block.timestamp + 6 minutes);
        (uint256 b,) = rq.releaseBatch();
        (uint256 ok, uint256 failed) = rq.executeBatch(b);
        assertEq(ok, 0, "the current ILRM has no relayed entry points");
        assertEq(failed, 2);

        // ILRM state untouched: the disputes() struct, including fallbackLicense, and the dispute counter
        IILRM.Dispute memory dsp = ilrm.disputes(id);
        assertEq(dsp.counterpartyStake, 0, "dispute state changed");
        assertEq(dsp.fallbackLicense.termsHash, keccak256("terms"));
        assertEq(dsp.fallbackLicense.termDuration, 365 days);
        assertEq(dsp.fallbackLicense.royaltyCapBps, 500);
        assertTrue(dsp.fallbackLicense.nonExclusive);
        assertEq(ilrm.disputeCounter(), disputeCount, "a relay created a dispute");
        assertEq(token.allowance(address(rq), address(ilrm)), 0, "allowance left behind");

        assertEq(uint8(rq.getTransaction(s).status), uint8(IBatchQueue.QueueStatus.Failed));
        assertEq(uint8(rq.getTransaction(d).status), uint8(IBatchQueue.QueueStatus.Failed));
        uint256 bobBefore = token.balanceOf(bob);
        assertEq(rq.reclaim(d), 5 ether);
        assertEq(token.balanceOf(bob) - bobBefore, 5 ether);
        assertEq(token.balanceOf(address(rq)), 0, "queue kept tokens");
        assertEq(rq.totalEscrowed(), 0);
    }

    // ============ Invariant-style fuzz ============

    function testFuzz_EscrowAccountingHolds(uint8[16] calldata ops, uint96 seed) public {
        uint256[] memory ids = new uint256[](16);
        uint256 n;
        for (uint256 i = 0; i < ops.length; i++) {
            uint8 op = ops[i] % 7;
            address u = [alice, bob, carol][(uint256(seed) + i) % 3];
            if (op == 0) {
                vm.prank(u);
                ids[n++] = q.queueDisputeInitiation(u == bob ? carol : bob, 1 ether + i, bytes32(i), fb);
            } else if (op == 1 && n > 0) {
                vm.prank(_submitter(ids[i % n]));
                try q.cancelTransaction(ids[i % n]) {} catch {}
            } else if (op == 2) {
                vm.warp(block.timestamp + 6 minutes);
                try q.releaseBatch() returns (uint256 b, uint256 c) {
                    if (c > 0) q.executeBatch(b);
                } catch {}
            } else if (op == 3) {
                relay.setMode(SPRelayTarget.Mode(uint8(seed >> i) % 5));
            } else if (op == 4) {
                vm.warp(block.timestamp + 1 days + 1);
            } else if (op == 5 && n > 0) {
                try q.reclaim(ids[i % n]) {} catch {}
            } else if (op == 6) {
                vm.prank(u);
                q.queueStakeDeposit(i);
            }
            uint256 sum;
            for (uint256 k = 0; k < n; k++) {
                sum += q.escrowOf(ids[k]);
            }
            assertEq(sum, q.totalEscrowed(), "sum of escrow != totalEscrowed");
            assertGe(token.balanceOf(address(q)), q.totalEscrowed(), "escrow under-collateralised");
            assertEq(token.allowance(address(q), address(relay)), 0, "dangling allowance");
            uint256 pending;
            for (uint256 t = 0; t < q.getTotalTxCount(); t++) {
                if (q.getTransaction(t).status == IBatchQueue.QueueStatus.Pending) pending++;
            }
            assertEq(pending, q.getPendingCount(), "pending counter drifted");
        }
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
            randomizeOrder: true,
            allowCancellation: true
        });
    }

    function _deploy(address target) internal returns (BatchQueue) {
        return new BatchQueue(target, IERC20(address(token)), _cfg());
    }

    function _releaseExecute() internal {
        vm.warp(block.timestamp + 6 minutes);
        (uint256 b, uint256 n) = q.releaseBatch();
        if (n > 0) q.executeBatch(b);
    }

    function _submitter(uint256 txId) internal view returns (address) {
        return q.getTransaction(txId).submitter;
    }

    function _realOpenDispute() internal returns (uint256 id) {
        vm.startPrank(alice);
        token.approve(address(ilrm), type(uint256).max);
        id = ilrm.initiateBreachDispute(
            bob, 10 ether, keccak256("evidence"), IILRM.FallbackLicense(keccak256("terms"), 365 days, 500, true)
        );
        vm.stopPrank();
    }
}
