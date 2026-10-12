// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "./OracleRounds.t.sol";

/**
 * @title AcceptProposalHashTest
 * @notice acceptProposalWithHash binds an acceptance to the proposal text the party reviewed: an acceptance sent
 *         while P1 was live can never land on a replacement or on a later round's proposal.
 */
contract AcceptProposalHashTest is OracleRoundsBase {
    event AcceptanceSignaled(uint256 indexed disputeId, address indexed party);

    string constant P1 = '{"terms":"P1"}';
    string constant P2 = '{"terms":"P2"}';

    function setUp() public {
        _deploy();
    }

    function _acceptBound(address party, uint256 id, bytes32 h) internal {
        vm.prank(party);
        ilrm.acceptProposalWithHash(id, h);
    }

    function _expectBoundRevert(address party, uint256 id, bytes32 h, bytes memory reason) internal {
        vm.prank(party);
        vm.expectRevert(reason);
        ilrm.acceptProposalWithHash(id, h);
    }

    // ============ Stale acceptances ============

    function test_StaleHashRejectedAfterResetAndReplacement() public {
        uint256 id = _openDispute(counterparty, EVIDENCE_0);
        _submit(id, P1);
        _acceptBound(initiator, id, _hash(P1));

        oracle.resetProposal(id, "replace P1");
        _submit(id, P2);

        // The counterparty's transaction, signed while P1 was live, lands on P2
        _expectBoundRevert(counterparty, id, _hash(P1), "Proposal changed");
        IILRM.Dispute memory d = ilrm.disputes(id);
        assertFalse(d.counterpartyAccepted);
        assertFalse(d.initiatorAccepted);
        assertFalse(d.resolved);
    }

    function test_StaleHashRejectedOnNextRoundProposal() public {
        uint256 id = _openDispute(counterparty, EVIDENCE_0);
        _submit(id, P1);
        _counter(initiator, id, keccak256("evidence-1"));
        _submit(id, P2);

        _expectBoundRevert(counterparty, id, _hash(P1), "Proposal changed");
        assertFalse(ilrm.disputes(id).counterpartyAccepted);
    }

    function test_StaleHashAfterVoidHitsNoProposal() public {
        uint256 id = _openDispute(counterparty, EVIDENCE_0);
        _submit(id, P1);
        oracle.resetProposal(id, "void");

        _expectBoundRevert(counterparty, id, _hash(P1), "No proposal yet");
    }

    // ============ Resolution ============

    function test_BoundPlusBoundResolves() public {
        uint256 id = _openDispute(counterparty, EVIDENCE_0);
        _submit(id, P1);

        vm.expectEmit(true, true, false, false, address(ilrm));
        emit AcceptanceSignaled(id, initiator);
        _acceptBound(initiator, id, _hash(P1));
        _acceptBound(counterparty, id, _hash(P1));

        IILRM.Dispute memory d = ilrm.disputes(id);
        assertTrue(d.resolved);
        assertEq(uint256(d.outcome), uint256(IILRM.DisputeOutcome.AcceptedProposal));
        assertEq(token.balanceOf(address(ilrm)), 0);
    }

    function test_BoundPlusLegacyResolves() public {
        uint256 id = _openDispute(counterparty, EVIDENCE_0);
        _submit(id, P1);

        _accept(initiator, id);
        _acceptBound(counterparty, id, _hash(P1));
        assertTrue(ilrm.disputes(id).resolved);

        uint256 id2 = _openDispute(counterparty2, EVIDENCE_0);
        _submit(id2, P2);
        _acceptBound(initiator, id2, _hash(P2));
        _accept(counterparty2, id2);
        assertTrue(ilrm.disputes(id2).resolved);
    }

    /// @notice Identical text in a later round carries the same terms, so the hash still matches
    function test_IdenticalTextInLaterRoundAccepted() public {
        uint256 id = _openDispute(counterparty, EVIDENCE_0);
        _submit(id, P1);
        _counter(counterparty, id, keccak256("evidence-1"));
        _submit(id, P1);

        _acceptBound(initiator, id, _hash(P1));
        _acceptBound(counterparty, id, _hash(P1));
        IILRM.Dispute memory d = ilrm.disputes(id);
        assertTrue(d.resolved);
        assertEq(d.counterCount, 1);
    }

    function test_AlreadyAcceptedStillEnforced() public {
        uint256 id = _openDispute(counterparty, EVIDENCE_0);
        _submit(id, P1);
        _acceptBound(initiator, id, _hash(P1));
        _expectBoundRevert(initiator, id, _hash(P1), "Already accepted");
        vm.prank(initiator);
        vm.expectRevert("Already accepted");
        ilrm.acceptProposal(id);
    }

    // ============ Check order: resolved, no proposal, timeout, hash, party ============

    function test_CheckOrder() public {
        address outsider = makeAddr("outsider");
        bytes32 wrong = _hash(P2);

        uint256 id = _openDispute(counterparty, EVIDENCE_0);

        // No proposal beats timeout, hash and party
        _expectBoundRevert(outsider, id, wrong, "No proposal yet");

        _submit(id, P1);
        // Hash beats party; with the right hash the party check applies
        _expectBoundRevert(outsider, id, wrong, "Proposal changed");
        _expectBoundRevert(outsider, id, _hash(P1), "Not a party");

        // Timeout beats hash and party
        vm.warp(ilrm.disputes(id).startTime + ilrm.RESOLUTION_TIMEOUT() + 1);
        _expectBoundRevert(outsider, id, wrong, "Timeout passed");

        // Resolved beats everything
        ilrm.enforceTimeout(id);
        _expectBoundRevert(outsider, id, wrong, "Dispute resolved");

        // Resolved beats "No proposal yet" too
        uint256 empty = _openDispute(counterparty2, EVIDENCE_0);
        vm.warp(ilrm.disputes(empty).startTime + ilrm.RESOLUTION_TIMEOUT() + 1);
        _expectBoundRevert(outsider, empty, wrong, "No proposal yet");
        ilrm.enforceTimeout(empty);
        _expectBoundRevert(outsider, empty, wrong, "Dispute resolved");
    }

    // ============ Fuzz ============

    /// @notice No hash other than the live proposal's ever records an acceptance
    function testFuzz_OnlyLiveHashRecordsAcceptance(bytes32 h, bool useLive, bool byInitiator, uint8 roundSeed) public {
        uint256 id = _openDispute(counterparty, EVIDENCE_0);
        uint256 rounds = roundSeed % 4;
        for (uint256 r = 0; r < rounds; r++) {
            _counter(r % 2 == 0 ? initiator : counterparty, id, keccak256(abi.encode("evidence", r)));
        }
        string memory live = string(abi.encodePacked('{"round":', vm.toString(rounds), "}"));
        _submit(id, live);
        bytes32 liveHash = _hash(live);
        if (useLive) h = liveHash;
        address party = byInitiator ? initiator : counterparty;

        vm.prank(party);
        if (h != liveHash) {
            vm.expectRevert("Proposal changed");
            ilrm.acceptProposalWithHash(id, h);
        } else {
            ilrm.acceptProposalWithHash(id, h);
        }

        IILRM.Dispute memory d = ilrm.disputes(id);
        bool accepted = byInitiator ? d.initiatorAccepted : d.counterpartyAccepted;
        assertEq(accepted, h == liveHash, "acceptance recorded for a hash other than the live one");
        assertFalse(byInitiator ? d.counterpartyAccepted : d.initiatorAccepted);
    }
}
