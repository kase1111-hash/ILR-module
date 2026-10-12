// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "./OracleRounds.t.sol";

/// @notice IOracleConsumer whose void hook always reverts; proves Oracle.resetProposal is atomic
contract RevertingVoidConsumer is IOracleConsumer {
    bytes32 public evidenceHash = keccak256("mock-evidence");
    uint256 public deadline = type(uint256).max;
    string public lastProposal;

    function oracleContext(uint256) external view returns (uint256, bytes32, bool, uint256) {
        return (0, evidenceHash, false, deadline);
    }

    function submitLLMProposal(uint256, string calldata proposal, bytes calldata) external {
        lastProposal = proposal;
    }

    function voidLLMProposal(uint256, bytes32) external pure {
        revert("void failed");
    }
}

/**
 * @title OracleRecoveryTest
 * @notice Owner recovery voids the proposal in ILRM atomically (compare-and-clear), the pinned reset, deadline
 *         checks on counterPropose and resetProposal, and the advisory pending-request lifecycle.
 */
contract OracleRecoveryTest is OracleRoundsBase {
    // Oracle events
    event ProposalRequested(uint256 indexed disputeId, bytes32 evidenceHash, uint256 timestamp);
    event ProposalRequestCancelled(uint256 indexed disputeId);
    event ProposalReset(uint256 indexed disputeId, bytes32 oldProposalHash, string reason);
    event ProposalRoundReopened(uint256 indexed disputeId, uint256 indexed round, bytes32 voidedProposalHash);
    event ProposalRoundFilled(uint256 indexed disputeId, uint256 indexed round, bytes32 proposalHash, uint256 nonce);
    // ILRM events
    event ProposalVoided(uint256 indexed disputeId, uint256 indexed round, bytes32 proposalHash);
    event ProposalSubmitted(uint256 indexed disputeId, string proposal);
    event CounterProposed(uint256 indexed disputeId, address indexed party, uint256 counterNumber);

    string constant P1 = '{"terms":"P1"}';
    string constant P2 = '{"terms":"P2"}';
    bytes32 constant EVIDENCE_1 = keccak256("evidence-1");

    function setUp() public {
        _deploy();
    }

    function _deadline(uint256 id) internal view returns (uint256) {
        return ilrm.disputes(id).startTime + ilrm.RESOLUTION_TIMEOUT();
    }

    function _countTopic(Vm.Log[] memory logs, address emitter, bytes32 topic0) internal pure returns (uint256 n) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == emitter && logs[i].topics.length > 0 && logs[i].topics[0] == topic0) n++;
        }
    }

    // ============ Atomic void ============

    /// @notice REGRESSION (reviewer PoC): a reset voids the proposal in ILRM, so the voided text can no longer
    ///         resolve the dispute
    function test_ResetVoidsProposalInILRM() public {
        uint256 id = _openDispute(counterparty, EVIDENCE_0);
        _submit(id, P1);
        _accept(initiator, id);

        vm.expectEmit(true, true, false, true, address(ilrm));
        emit ProposalVoided(id, 0, _hash(P1));
        oracle.resetProposal(id, "incorrect proposal");

        IILRM.Dispute memory d = ilrm.disputes(id);
        assertEq(d.llmProposal, "", "voided text still live in ILRM");
        assertFalse(d.initiatorAccepted, "initiator acceptance of the voided proposal survived");
        assertFalse(d.counterpartyAccepted);

        // Before the fix the counterparty's acceptance resolved the dispute on the voided proposal
        vm.prank(counterparty);
        vm.expectRevert("No proposal yet");
        ilrm.acceptProposal(id);
        assertFalse(ilrm.disputes(id).resolved);
    }

    /// @notice The void clears the counterparty's acceptance too, and recovery works while ILRM is paused
    function test_ResetWorksWhileILRMPaused() public {
        uint256 id = _openDispute(counterparty, EVIDENCE_0);
        _submit(id, P1);
        _accept(counterparty, id);
        ilrm.pause();

        vm.expectEmit(true, true, false, true, address(ilrm));
        emit ProposalVoided(id, 0, _hash(P1));
        oracle.resetProposal(id, "recover while paused");

        IILRM.Dispute memory d = ilrm.disputes(id);
        assertEq(d.llmProposal, "");
        assertFalse(d.counterpartyAccepted, "counterparty acceptance of the voided proposal survived");

        // The replacement lands and the parties can still accept while paused
        _submit(id, P2);
        vm.prank(initiator);
        ilrm.acceptProposalWithHash(id, _hash(P2));
        vm.prank(counterparty);
        ilrm.acceptProposalWithHash(id, _hash(P2));
        d = ilrm.disputes(id);
        assertTrue(d.resolved);
        assertEq(d.llmProposal, P2);
    }

    function test_ReplacementAfterResetEmitsNoSupersede() public {
        uint256 id = _openDispute(counterparty, EVIDENCE_0);
        _submit(id, P1);
        oracle.resetProposal(id, "recover");

        bytes memory sig = _signCurrent(operatorKey, id, P2);
        vm.recordLogs();
        vm.prank(operator);
        oracle.submitProposal(id, P2, sig);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 supersededTopic = keccak256("ProposalSuperseded(uint256,uint256,bytes32,bytes32)");
        assertEq(_countTopic(logs, address(ilrm), supersededTopic), 0, "replacement superseded a live proposal");
        assertEq(_countTopic(logs, address(ilrm), keccak256("ProposalSubmitted(uint256,string)")), 1);
        assertEq(ilrm.disputes(id).llmProposal, P2);
    }

    /// @notice A consumer whose void hook reverts rolls the whole reset back
    function test_ResetIsAtomicWhenVoidReverts() public {
        RevertingVoidConsumer consumer = new RevertingVoidConsumer();
        oracle.setILRM(address(consumer));

        bytes memory sig = _signFor(operatorKey, 0, 0, consumer.evidenceHash(), P1, 0);
        vm.prank(operator);
        oracle.submitProposal(0, P1, sig);
        assertEq(consumer.lastProposal(), P1);
        assertEq(oracle.roundProposals(0, 0), _hash(P1));
        assertEq(oracle.getNonce(0), 1);
        assertFalse(oracle.isPending(0));

        vm.expectRevert("void failed");
        oracle.resetProposal(0, "atomic");

        assertEq(oracle.roundProposals(0, 0), _hash(P1), "slot re-opened without a void");
        assertEq(oracle.getNonce(0), 1, "nonce bumped without a void");
        assertFalse(oracle.isPending(0), "pending set without a void");
    }

    // ============ The void hook itself ============

    function test_VoidOnlyOracle() public {
        uint256 id = _openDispute(counterparty, EVIDENCE_0);
        _submit(id, P1);

        address[3] memory callers = [initiator, operator, address(this)];
        for (uint256 i = 0; i < callers.length; i++) {
            vm.prank(callers[i]);
            vm.expectRevert("Only oracle");
            ilrm.voidLLMProposal(id, _hash(P1));
        }
        assertEq(ilrm.disputes(id).llmProposal, P1);
    }

    function test_VoidRevertsOnResolvedDispute() public {
        uint256 id = _openDispute(counterparty, EVIDENCE_0);
        _submit(id, P1);
        _accept(initiator, id);
        _accept(counterparty, id);

        vm.prank(address(oracle));
        vm.expectRevert("Dispute resolved");
        ilrm.voidLLMProposal(id, _hash(P1));
        assertEq(ilrm.disputes(id).llmProposal, P1);
    }

    function test_VoidRevertsAfterDeadline() public {
        uint256 id = _openDispute(counterparty, EVIDENCE_0);
        _submit(id, P1);
        _accept(initiator, id);
        vm.warp(_deadline(id) + 1);

        vm.prank(address(oracle));
        vm.expectRevert("Timeout passed");
        ilrm.voidLLMProposal(id, _hash(P1));

        IILRM.Dispute memory d = ilrm.disputes(id);
        assertEq(d.llmProposal, P1);
        assertTrue(d.initiatorAccepted);
    }

    function test_VoidIsNoOpWithoutLiveProposal() public {
        uint256 id = _openDispute(counterparty, EVIDENCE_0);

        vm.recordLogs();
        vm.prank(address(oracle));
        ilrm.voidLLMProposal(id, _hash(P1));
        assertEq(vm.getRecordedLogs().length, 0, "no-op void emitted logs");

        // Also after a counter cleared the previous round's proposal
        _submit(id, P1);
        _counter(initiator, id, EVIDENCE_1);
        vm.recordLogs();
        vm.prank(address(oracle));
        ilrm.voidLLMProposal(id, _hash(P1));
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(ilrm.disputes(id).counterCount, 1);
    }

    function test_VoidRevertsOnHashMismatch() public {
        uint256 id = _openDispute(counterparty, EVIDENCE_0);
        _submit(id, P1);
        _accept(initiator, id);

        vm.prank(address(oracle));
        vm.expectRevert("Proposal mismatch");
        ilrm.voidLLMProposal(id, _hash(P2));

        IILRM.Dispute memory d = ilrm.disputes(id);
        assertEq(d.llmProposal, P1);
        assertTrue(d.initiatorAccepted);
    }

    // ============ Deadlines ============

    /// @notice REGRESSION: a counter after the resolution deadline cannot revive a timed-out dispute
    function test_CounterAfterDeadlineRejected() public {
        uint256 id = _openDispute(counterparty, EVIDENCE_0);
        uint256 start = ilrm.disputes(id).startTime;
        vm.warp(_deadline(id) + 1);

        uint256 fee = ilrm.COUNTER_FEE_BASE();
        vm.deal(initiator, fee);
        vm.prank(initiator);
        vm.expectRevert("Timeout passed");
        ilrm.counterPropose{value: fee}(id, EVIDENCE_1);

        IILRM.Dispute memory d = ilrm.disputes(id);
        assertEq(d.startTime, start, "late counter moved startTime");
        assertEq(d.counterCount, 0);

        ilrm.enforceTimeout(id);
        d = ilrm.disputes(id);
        assertTrue(d.resolved);
        assertEq(uint256(d.outcome), uint256(IILRM.DisputeOutcome.TimeoutWithBurn));
    }

    function test_CounterAtDeadlineAllowed() public {
        uint256 id = _openDispute(counterparty, EVIDENCE_0);
        uint256 start = ilrm.disputes(id).startTime;
        vm.warp(_deadline(id));

        _counter(counterparty, id, EVIDENCE_1);

        IILRM.Dispute memory d = ilrm.disputes(id);
        assertEq(d.counterCount, 1);
        assertEq(d.startTime, start + 1 days, "counter at the deadline extends by one day");
    }

    /// @notice REGRESSION: a reset after the deadline could never be followed by a replacement
    function test_ResetAfterDeadlineRejected() public {
        uint256 id = _openDispute(counterparty, EVIDENCE_0);
        _submit(id, P1);
        uint256 deadline = _deadline(id);
        vm.warp(deadline + 1);

        vm.expectRevert(abi.encodeWithSelector(NatLangChainOracle.ResolutionDeadlinePassed.selector, id, deadline));
        oracle.resetProposal(id, "too late");

        vm.expectRevert(abi.encodeWithSelector(NatLangChainOracle.ResolutionDeadlinePassed.selector, id, deadline));
        oracle.resetProposalExact(id, 0, _hash(P1), "too late");

        assertEq(oracle.roundProposals(id, 0), _hash(P1));
        assertEq(oracle.getNonce(id), 1);
        assertFalse(oracle.isPending(id));
        assertEq(ilrm.disputes(id).llmProposal, P1);
    }

    function test_ResetAtDeadlineThenReplacement() public {
        uint256 id = _openDispute(counterparty, EVIDENCE_0);
        _submit(id, P1);
        vm.warp(_deadline(id));

        oracle.resetProposal(id, "at the deadline");
        assertEq(ilrm.disputes(id).llmProposal, "");

        _submit(id, P2);
        assertEq(ilrm.disputes(id).llmProposal, P2);
        assertEq(oracle.roundProposals(id, 0), _hash(P2));
        assertEq(oracle.getNonce(id), 3);
    }

    // ============ Reset followed by a counter ============

    function test_ResetThenCounterWithoutReplacement() public {
        uint256 id = _openDispute(counterparty, EVIDENCE_0);
        bytes memory sigP1 = _signCurrent(operatorKey, id, P1);
        vm.prank(operator);
        oracle.submitProposal(id, P1, sigP1);
        // Signed for the live round-0 context before the reset
        bytes memory preReset = _signCurrent(operatorKey, id, P2);

        oracle.resetProposal(id, "void, then negotiate");
        _counter(initiator, id, EVIDENCE_1);

        (uint256 round, bytes32 evidenceHash, uint256 nonce, bool open) = oracle.proposalContext(id);
        assertEq(round, 1);
        assertEq(evidenceHash, EVIDENCE_1);
        assertEq(nonce, 2);
        assertTrue(open);
        assertEq(oracle.roundProposals(id, 0), bytes32(0), "round-0 slot refilled");
        assertEq(ilrm.disputes(id).llmProposal, "");

        vm.prank(operator);
        vm.expectRevert(NatLangChainOracle.InvalidSignature.selector);
        oracle.submitProposal(id, P2, preReset);
        vm.prank(operator);
        vm.expectRevert(NatLangChainOracle.InvalidSignature.selector);
        oracle.submitProposal(id, P1, sigP1);

        _submit(id, P2);
        assertEq(oracle.roundProposals(id, 1), _hash(P2));

        vm.prank(initiator);
        ilrm.acceptProposalWithHash(id, _hash(P2));
        vm.prank(counterparty);
        ilrm.acceptProposalWithHash(id, _hash(P2));
        IILRM.Dispute memory d = ilrm.disputes(id);
        assertTrue(d.resolved);
        assertEq(d.llmProposal, P2);
        assertEq(uint256(d.outcome), uint256(IILRM.DisputeOutcome.AcceptedProposal));
    }

    // ============ Pinned reset ============

    function test_ResetProposalExactVoidsPinnedProposal() public {
        uint256 id = _openDispute(counterparty, EVIDENCE_0);
        _submit(id, P1);
        _accept(initiator, id);

        vm.expectEmit(true, false, false, true, address(oracle));
        emit ProposalReset(id, _hash(P1), "pinned");
        vm.expectEmit(true, true, false, true, address(oracle));
        emit ProposalRoundReopened(id, 0, _hash(P1));
        vm.expectEmit(true, true, false, true, address(ilrm));
        emit ProposalVoided(id, 0, _hash(P1));
        oracle.resetProposalExact(id, 0, _hash(P1), "pinned");

        IILRM.Dispute memory d = ilrm.disputes(id);
        assertEq(d.llmProposal, "");
        assertFalse(d.initiatorAccepted);
        assertEq(oracle.roundProposals(id, 0), bytes32(0));
        assertEq(oracle.getNonce(id), 2);
        assertTrue(oracle.isPending(id));
    }

    /// @notice A pinned reset queued behind a timelock never voids a proposal that landed after it was queued
    function test_ResetProposalExactRevertsAfterRoundChanged() public {
        uint256 id = _openDispute(counterparty, EVIDENCE_0);
        _submit(id, P1);
        // ... resetProposalExact(id, 0, h(P1)) is queued here; meanwhile the parties negotiate on
        _counter(counterparty, id, EVIDENCE_1);
        _submit(id, P2);
        _accept(initiator, id);

        vm.expectRevert(abi.encodeWithSelector(NatLangChainOracle.ProposalMismatch.selector, id, 1, _hash(P2)));
        oracle.resetProposalExact(id, 0, _hash(P1), "queued for P1");

        IILRM.Dispute memory d = ilrm.disputes(id);
        assertEq(d.llmProposal, P2, "P2 voided by a reset queued for P1");
        assertTrue(d.initiatorAccepted, "acceptance of P2 cleared");
        assertEq(oracle.roundProposals(id, 1), _hash(P2));
        assertEq(oracle.getNonce(id), 2);
    }

    function test_ResetProposalExactRevertsOnWrongHash() public {
        uint256 id = _openDispute(counterparty, EVIDENCE_0);
        _submit(id, P1);

        vm.expectRevert(abi.encodeWithSelector(NatLangChainOracle.ProposalMismatch.selector, id, 0, _hash(P1)));
        oracle.resetProposalExact(id, 0, _hash(P2), "wrong hash");

        // Same round, but a different proposal replaced the pinned one
        oracle.resetProposal(id, "replace P1");
        _submit(id, P2);
        vm.expectRevert(abi.encodeWithSelector(NatLangChainOracle.ProposalMismatch.selector, id, 0, _hash(P2)));
        oracle.resetProposalExact(id, 0, _hash(P1), "stale pin");

        assertEq(ilrm.disputes(id).llmProposal, P2);
        assertEq(oracle.getNonce(id), 3);
    }

    function test_ResetProposalExactOnlyOwner() public {
        uint256 id = _openDispute(counterparty, EVIDENCE_0);
        _submit(id, P1);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator));
        oracle.resetProposalExact(id, 0, _hash(P1), "not owner");
        assertEq(oracle.roundProposals(id, 0), _hash(P1));
    }

    function test_ResetProposalExactKeepsResetErrors() public {
        uint256 id = _openDispute(counterparty, EVIDENCE_0);
        vm.expectRevert(abi.encodeWithSelector(NatLangChainOracle.NoProposalToReset.selector, id));
        oracle.resetProposalExact(id, 0, bytes32(0), "nothing");

        _submit(id, P1);
        _accept(initiator, id);
        _accept(counterparty, id);
        vm.expectRevert(abi.encodeWithSelector(NatLangChainOracle.DisputeAlreadyResolved.selector, id));
        oracle.resetProposalExact(id, 0, _hash(P1), "resolved");

        NatLangChainOracle fresh = new NatLangChainOracle();
        vm.expectRevert(NatLangChainOracle.ILRMNotSet.selector);
        fresh.resetProposalExact(0, 0, bytes32(0), "no consumer");
    }

    // ============ Advisory pending-request lifecycle ============

    function test_PendingLifecycle() public {
        vm.prank(initiator);
        uint256 id = ilrm.initiateBreachDispute(counterparty, STAKE, EVIDENCE_0, _fallback());
        assertFalse(oracle.isPending(id), "pending before the dispute is staked");

        vm.expectEmit(true, false, false, true, address(oracle));
        emit ProposalRequested(id, EVIDENCE_0, block.timestamp);
        vm.prank(counterparty);
        ilrm.depositStake(id);
        assertTrue(oracle.isPending(id), "fully staked dispute not requested");

        _submit(id, P1);
        assertFalse(oracle.isPending(id), "relay did not clear the request");

        oracle.resetProposal(id, "recover");
        assertTrue(oracle.isPending(id), "reset did not re-request");

        _submit(id, P2);
        assertFalse(oracle.isPending(id), "replacement did not clear the request");

        vm.warp(block.timestamp + 1 hours);
        uint256 fee = ilrm.COUNTER_FEE_BASE();
        vm.deal(initiator, fee);
        vm.expectEmit(true, false, false, true, address(oracle));
        emit ProposalRequested(id, EVIDENCE_1, block.timestamp);
        vm.prank(initiator);
        ilrm.counterPropose{value: fee}(id, EVIDENCE_1);
        assertTrue(oracle.isPending(id), "new round not requested");

        vm.recordLogs();
        oracle.cancelPendingRequest(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(oracle));
        assertEq(logs[0].topics[0], keccak256("ProposalRequestCancelled(uint256)"));
        assertEq(logs[0].topics[1], bytes32(id));
        assertEq(_countTopic(logs, address(oracle), keccak256("ProposalRequested(uint256,bytes32,uint256)")), 0);
        assertFalse(oracle.isPending(id));

        vm.expectRevert(abi.encodeWithSelector(NatLangChainOracle.NoPendingRequest.selector, id));
        oracle.cancelPendingRequest(id);

        // Advisory only: a proposal still lands after the cancel
        _submit(id, P1);
        assertEq(ilrm.disputes(id).llmProposal, P1);
        assertFalse(oracle.isPending(id));
    }
}

/**
 * @title OracleRecoveryInvariantTest
 * @notice (I5) for every unresolved dispute, the Oracle's current-round slot is empty iff ILRM holds no live
 *         proposal. Together with I4 (a filled slot == keccak256(live text)) the Oracle and ILRM never disagree
 *         about what is live.
 */
contract OracleRecoveryInvariantTest is OracleRoundsBase {
    OracleRoundsHandler internal handler;
    uint256[] internal ids;

    function setUp() public {
        _deploy();
        address counterparty3 = makeAddr("counterparty3");
        _fund(counterparty3);

        ids.push(_openDispute(counterparty, EVIDENCE_0));
        ids.push(_openDispute(counterparty2, EVIDENCE_0));
        ids.push(_openDispute(counterparty3, keccak256("evidence-x")));

        handler = new OracleRoundsHandler(ilrm, oracle, address(this), operator, operatorKey, ids);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    /// forge-config: ci.invariant.runs = 64
    /// forge-config: ci.invariant.depth = 40
    function invariant_EmptySlotIffNoLiveProposal() public view {
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];
            IILRM.Dispute memory d = ilrm.disputes(id);
            if (d.resolved) continue;
            bool slotEmpty = oracle.roundProposals(id, d.counterCount) == bytes32(0);
            bool noLiveProposal = bytes(d.llmProposal).length == 0;
            assertEq(slotEmpty, noLiveProposal, "Oracle slot and ILRM live proposal disagree");
        }
    }
}
