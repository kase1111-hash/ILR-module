// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "./OracleRounds.t.sol";

/**
 * @title OraclePinnedResetRoundTest
 * @notice resetProposalExact pins the round as well as the proposal hash, and the stale-slot behaviour that
 *         Oracle.setILRM documents for a re-pointed consumer.
 */
contract OraclePinnedResetRoundTest is OracleRoundsBase {
    string constant P1 = '{"terms":"P1"}';
    bytes32 constant EVIDENCE_1 = keccak256("evidence-1");

    function setUp() public {
        _deploy();
    }

    // ============ Round pin ============

    /// @notice REGRESSION (surviving mutant): with only the hash pinned, a reset queued for round 0 voided the
    ///         same text re-proposed (same hash) in round 1, together with the acceptances made in round 1
    function test_ResetProposalExactRevertsOnSameHashInLaterRound() public {
        uint256 id = _openDispute(counterparty, EVIDENCE_0);
        _submit(id, P1);
        // ... resetProposalExact(id, 0, h(P1)) is queued here; meanwhile a counter opens round 1 and the
        // oracle proposes the same text again
        _counter(counterparty, id, EVIDENCE_1);
        _submit(id, P1);
        _accept(initiator, id);
        assertEq(oracle.roundProposals(id, 1), _hash(P1), "setup: round 1 holds the same hash");

        vm.expectRevert(abi.encodeWithSelector(NatLangChainOracle.ProposalMismatch.selector, id, 1, _hash(P1)));
        oracle.resetProposalExact(id, 0, _hash(P1), "queued for round 0");

        IILRM.Dispute memory d = ilrm.disputes(id);
        assertEq(d.llmProposal, P1);
        assertTrue(d.initiatorAccepted, "round-1 acceptance voided by a round-0 pin");
        assertEq(oracle.roundProposals(id, 1), _hash(P1));
        assertEq(oracle.getNonce(id), 2);
        assertFalse(oracle.isPending(id));

        // Pinning the live round still voids it
        oracle.resetProposalExact(id, 1, _hash(P1), "round 1");
        assertEq(oracle.roundProposals(id, 1), bytes32(0));
        assertEq(ilrm.disputes(id).llmProposal, "");
        assertFalse(ilrm.disputes(id).initiatorAccepted);
        assertEq(oracle.getNonce(id), 3);
    }

    // ============ Stale slot after setILRM (as documented on setILRM) ============

    /// @notice A slot filled for the old consumer blocks the new consumer's dispute with the same ID; resetProposal
    ///         reads the new consumer, so it reverts for an ID the new consumer never created and clears the slot
    ///         once that dispute exists, is unresolved and is within its deadline
    function test_StaleSlotAfterRepointIsClearedThroughTheNewConsumer() public {
        vm.warp(30 days); // a realistic clock: an unknown dispute's deadline (startTime 0 + 7 days) is long past
        uint256 id = _openDispute(counterparty, EVIDENCE_0);
        _submit(id, P1);
        assertEq(oracle.roundProposals(id, 0), _hash(P1));

        ILRM ilrm2 = new ILRM(IERC20(address(token)), address(oracle), registry);
        oracle.setILRM(address(ilrm2));
        ilrm = ilrm2; // the base helpers now act on the new consumer
        _fund(initiator);
        _fund(counterparty);

        // Unknown to the new consumer: past its deadline, so the stale slot cannot be reset yet
        vm.expectRevert(
            abi.encodeWithSelector(NatLangChainOracle.ResolutionDeadlinePassed.selector, id, ilrm.RESOLUTION_TIMEOUT())
        );
        oracle.resetProposal(id, "unknown to the new consumer");

        // The new consumer's dispute with the same ID is blocked by the stale slot ...
        uint256 id2 = _openDispute(counterparty, EVIDENCE_0);
        assertEq(id2, id, "setup: overlapping dispute IDs");
        bytes memory sig = _signCurrent(operatorKey, id2, P1);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(NatLangChainOracle.ProposalAlreadyProcessed.selector, id2, 0));
        oracle.submitProposal(id2, P1, sig);

        // ... until a reset clears it (the new consumer holds no live proposal, so its void hook is a no-op)
        oracle.resetProposal(id2, "stale slot from the old consumer");
        assertEq(oracle.roundProposals(id2, 0), bytes32(0));
        _submit(id2, P1);
        assertEq(ilrm2.disputes(id2).llmProposal, P1);
    }
}
