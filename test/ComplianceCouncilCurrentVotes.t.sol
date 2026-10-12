// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ComplianceCouncil} from "../contracts/modules/ComplianceCouncil.sol";
import {IComplianceCouncil} from "../contracts/interfaces/IComplianceCouncil.sol";
import {BLS12381Harness} from "../contracts/mocks/BLS12381Harness.sol";
import {BLS12381ThresholdHarness} from "../contracts/mocks/BLS12381ThresholdHarness.sol";

/**
 * @title ComplianceCouncil follow-ups: current votes, current signatures, canonical limbs, even-size Lagrange
 * @notice On Foundry's EVM without EIP-2537 (keys are only checked structurally there). The Prague path with real
 *         signatures is covered by test/ComplianceCouncil.currency.test.js.
 */
contract ComplianceCouncilCurrentVotesTest is Test {
    ComplianceCouncil internal council;
    BLS12381Harness internal g1Harness;
    BLS12381ThresholdHarness internal harness;

    address internal admin = address(0xA11CE);
    address internal requester = address(0xC0C);
    address internal operator = address(0x0E7);
    address[5] internal m = [address(0xB01), address(0xB02), address(0xB03), address(0xB04), address(0xB05)];

    /// @dev BLS12-381 group order r
    uint256 internal constant R = 0x73eda753299d7d483339d80809a1d80553bda402fffe5bfeffffffff00000001;

    /// @dev BLS12-381 base field modulus p as [hi, lo] words of its 64-byte encoding
    bytes32 internal constant P_HI = 0x000000000000000000000000000000001a0111ea397fe69a4b1ba7b6434bacd7;
    bytes32 internal constant P_LO = 0x64774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab;

    // Events of IComplianceCouncil (qualified event access needs solc >= 0.8.21)
    event VoteCast(
        uint256 indexed warrantId, address indexed voter, bool approved, uint256 approvalsCount, uint256 rejectionsCount
    );
    event VotingConcluded(
        uint256 indexed warrantId,
        IComplianceCouncil.WarrantStatus status,
        uint256 approvalsCount,
        uint256 rejectionsCount
    );

    function setUp() public {
        // 3-of-5: threshold 3, voting period 1h, execution delay 1d, appeal window 1d
        council = new ComplianceCouncil(3, 1 hours, 1 days, 1 days, admin);
        assertFalse(council.areBLSPrecompilesAvailable(), "suite targets EVMs without EIP-2537");
        g1Harness = new BLS12381Harness();
        harness = new BLS12381ThresholdHarness();

        vm.startPrank(admin);
        council.setAuthorizedRequester(requester, true);
        council.grantRole(council.OPERATOR_ROLE(), operator);
        vm.stopPrank();
        for (uint256 i = 0; i < 5; i++) {
            _add(m[i], 10 * (i + 1), i + 1);
        }
    }

    // ============ Helpers ============

    /// @dev Structurally canonical G1 encoding (not on the curve; enough without precompiles)
    function _pk(uint256 seed) internal pure returns (IComplianceCouncil.BLSPublicKey memory pk) {
        pk.x[1] = bytes32(seed);
        pk.y[1] = bytes32(seed + 1);
    }

    function _sig(uint256 seed) internal pure returns (IComplianceCouncil.BLSSignature memory sig) {
        sig.x[1] = bytes32(seed);
        sig.y[1] = bytes32(seed + 1);
    }

    function _add(address member, uint256 seed, uint256 keyIndex) internal {
        vm.prank(admin);
        council.addMember(member, IComplianceCouncil.MemberRole.LegalCounsel, _pk(seed), keyIndex);
    }

    function _remove(address member) internal {
        vm.prank(admin);
        council.removeMember(member);
    }

    function _newWarrant() internal returns (uint256 id) {
        vm.prank(requester);
        id = council.submitWarrantRequest(IComplianceCouncil.RequestType.CourtOrder, 7, keccak256("order"), "US");
    }

    function _vote(address member, uint256 id, bool approve) internal {
        vm.prank(member);
        council.castVote(id, approve, "");
    }

    function _status(uint256 id) internal view returns (IComplianceCouncil.WarrantStatus) {
        return council.getWarrant(id).status;
    }

    function _counts(uint256 id) internal view returns (uint256 approvals, uint256 rejections) {
        IComplianceCouncil.WarrantRequest memory w = council.getWarrant(id);
        return (w.approvalsCount, w.rejectionsCount);
    }

    // ============ Votes count only while the voter is still a member ============

    /// @dev The reported case: 3-of-5, members 1-3 approve, member 3 is removed. The warrant used to be Approved
    ///      with only two active approvers.
    function test_RemovedMembersApprovalDoesNotCount() public {
        uint256 id = _newWarrant();
        _vote(m[0], id, true);
        _vote(m[1], id, true);
        _vote(m[2], id, true);
        (uint256 approvals,) = _counts(id);
        assertEq(approvals, 3);

        _remove(m[2]);
        assertFalse(council.hasVoted(id, m[2]));
        (approvals,) = _counts(id);
        assertEq(approvals, 2, "live tally drops the removed member's vote");
        // The vote stays on record
        assertEq(council.getWarrantVotes(id).length, 3);

        vm.warp(block.timestamp + 1 hours + 1);
        vm.expectEmit(true, false, false, true, address(council));
        emit VotingConcluded(id, IComplianceCouncil.WarrantStatus.Rejected, 2, 0);
        council.concludeVoting(id);

        assertEq(uint256(_status(id)), uint256(IComplianceCouncil.WarrantStatus.Rejected));
        (uint256 a, uint256 r) = _counts(id);
        assertEq(a, 2);
        assertEq(r, 0);
    }

    /// @dev Stale votes also used to trigger the all-members-voted auto-conclusion early: with m4 and m5 removed
    ///      after rejecting, m2's vote made 4 recorded votes >= 3 members and concluded the warrant as Rejected before
    ///      m3 could vote.
    function test_StaleVotesDoNotAutoConclude() public {
        uint256 id = _newWarrant();
        _vote(m[0], id, true);
        _vote(m[3], id, false);
        _vote(m[4], id, false);
        _remove(m[3]);
        _remove(m[4]);
        assertEq(council.getConfig().totalMembers, 3);

        vm.expectEmit(true, true, false, true, address(council));
        emit VoteCast(id, m[1], true, 2, 0);
        _vote(m[1], id, true);
        assertEq(uint256(_status(id)), uint256(IComplianceCouncil.WarrantStatus.Pending));

        // The last active member's vote concludes it on the votes that count
        vm.expectEmit(true, false, false, true, address(council));
        emit VotingConcluded(id, IComplianceCouncil.WarrantStatus.Approved, 3, 0);
        _vote(m[2], id, true);
        assertEq(uint256(_status(id)), uint256(IComplianceCouncil.WarrantStatus.Approved));
        (uint256 a, uint256 r) = _counts(id);
        assertEq(a, 3);
        assertEq(r, 0);
    }

    function test_RemovedMembersRejectionDoesNotCount() public {
        uint256 id = _newWarrant();
        _vote(m[0], id, true);
        _vote(m[1], id, true);
        _vote(m[4], id, false);
        _remove(m[4]);
        (uint256 a, uint256 r) = _counts(id);
        assertEq(a, 2);
        assertEq(r, 0);

        _vote(m[2], id, true);
        _vote(m[3], id, false);
        // Four active members, four current votes
        assertEq(uint256(_status(id)), uint256(IComplianceCouncil.WarrantStatus.Approved));
        (a, r) = _counts(id);
        assertEq(a, 3);
        assertEq(r, 1);
    }

    /// @dev A re-added member starts a new membership: its earlier vote stays void and it may vote once more
    function test_ReAddedMemberVotesAgainOnce() public {
        uint256 id = _newWarrant();
        _vote(m[0], id, true);
        uint256 firstMembership = council.getMember(m[0]).membershipId;
        assertTrue(council.hasVoted(id, m[0]));

        _remove(m[0]);
        assertEq(council.getMember(m[0]).membershipId, 0);
        _add(m[0], 10, 1);
        uint256 secondMembership = council.getMember(m[0]).membershipId;
        assertTrue(secondMembership != 0 && secondMembership != firstMembership, "fresh membership id");
        assertFalse(council.hasVoted(id, m[0]));
        (uint256 a,) = _counts(id);
        assertEq(a, 0, "the earlier membership's vote is void");

        _vote(m[0], id, false);
        assertTrue(council.hasVoted(id, m[0]));
        vm.prank(m[0]);
        vm.expectRevert(bytes("Already voted"));
        council.castVote(id, true, "");

        // Both votes are on record, only the second counts
        IComplianceCouncil.Vote[] memory votes = council.getWarrantVotes(id);
        assertEq(votes.length, 2);
        assertEq(votes[0].membershipId, firstMembership);
        assertTrue(votes[0].approved);
        assertEq(votes[1].membershipId, secondMembership);
        assertFalse(votes[1].approved);
        (uint256 approvals, uint256 rejections) = _counts(id);
        assertEq(approvals, 0);
        assertEq(rejections, 1);
    }

    /// @dev Votes are authenticated by the member's address, not its BLS key: a rotation keeps them
    function test_KeyRotationKeepsVote() public {
        uint256 id = _newWarrant();
        _vote(m[0], id, true);
        uint256 membershipId = council.getMember(m[0]).membershipId;
        uint256 keyId = council.getMember(m[0]).keyId;
        assertEq(membershipId, keyId, "membership id is the keyId handed out by addMember");

        vm.prank(admin);
        council.rotateMemberKey(m[0], _pk(1000));
        assertTrue(council.getMember(m[0]).keyId != keyId);
        assertEq(council.getMember(m[0]).membershipId, membershipId);
        assertTrue(council.hasVoted(id, m[0]));
        vm.prank(m[0]);
        vm.expectRevert(bytes("Already voted"));
        council.castVote(id, true, "");

        _vote(m[1], id, true);
        _vote(m[2], id, true);
        vm.warp(block.timestamp + 1 hours + 1);
        council.concludeVoting(id);
        assertEq(uint256(_status(id)), uint256(IComplianceCouncil.WarrantStatus.Approved));
        assertEq(council.getWarrant(id).approvalsCount, 3);
    }

    /// @dev The stored tally is fixed when voting closes, also by cancellation; later removals do not change it
    function test_TallyStoredWhenVotingCloses() public {
        uint256 cancelled = _newWarrant();
        uint256 concluded = _newWarrant();
        for (uint256 i = 0; i < 3; i++) {
            _vote(m[i], cancelled, i != 1);
            _vote(m[i], concluded, true);
        }
        _remove(m[0]);

        vm.prank(admin);
        council.cancelWarrant(cancelled, "withdrawn");
        (uint256 a, uint256 r) = _counts(cancelled);
        assertEq(a, 1, "m1's approval no longer counted at cancellation");
        assertEq(r, 1);

        vm.warp(block.timestamp + 1 hours + 1);
        council.concludeVoting(concluded);
        assertEq(uint256(_status(concluded)), uint256(IComplianceCouncil.WarrantStatus.Rejected));
        (a,) = _counts(concluded);
        assertEq(a, 2);

        // Removing another voter after closing leaves both tallies as recorded
        _remove(m[2]);
        (a, r) = _counts(cancelled);
        assertEq(a, 1);
        assertEq(r, 1);
        (a,) = _counts(concluded);
        assertEq(a, 2);
    }

    // ============ getCurrentSignatures ============

    function _hybridApproved() internal returns (uint256 id) {
        vm.prank(admin);
        council.setExecutionMode(ComplianceCouncil.ExecutionMode.HYBRID_ATTESTED, "no EIP-2537");
        id = _newWarrant();
        for (uint256 i = 0; i < 5; i++) {
            _vote(m[i], id, true);
        }
        vm.warp(council.getWarrant(id).executionTime);
    }

    function _sign(address member, uint256 id, uint256 seed) internal {
        vm.prank(member);
        council.submitSignature(id, _sig(seed));
    }

    function test_GetCurrentSignaturesOmitsStaleSubmissions() public {
        uint256 id = _hybridApproved();
        assertEq(council.getCurrentSignatures(id).length, 0);
        _sign(m[0], id, 101);
        _sign(m[1], id, 202);
        _sign(m[2], id, 303);

        _remove(m[1]);
        vm.prank(admin);
        council.rotateMemberKey(m[2], _pk(3000));
        _sign(m[2], id, 3030);
        _sign(m[3], id, 404);

        IComplianceCouncil.SignatureSubmission[] memory all = council.getSignatures(id);
        assertEq(all.length, 5);

        // m2 removed, m3's first partial made under its old key
        IComplianceCouncil.SignatureSubmission[] memory current = council.getCurrentSignatures(id);
        assertEq(current.length, 3);
        assertEq(current[0].signer, m[0]);
        assertEq(current[1].signer, m[2]);
        assertEq(current[1].keyId, council.getMember(m[2]).keyId);
        assertEq(current[1].signature.x[1], bytes32(uint256(3030)));
        assertEq(current[2].signer, m[3]);
        assertEq(current[2].memberIndex, 4);
        assertEq(abi.encode(current[0]), abi.encode(all[0]), "copied verbatim");
        assertEq(abi.encode(current[2]), abi.encode(all[4]));
        for (uint256 i = 0; i < current.length; i++) {
            assertTrue(council.hasSubmittedSignature(id, current[i].signer));
        }

        // Exactly the submissions executeReconstruction counts
        vm.prank(operator);
        council.attestHybridVerification(id, keccak256("sigma"), "test");
        _remove(m[3]);
        assertEq(council.getCurrentSignatures(id).length, 2);
        vm.expectRevert(bytes("Insufficient signatures"));
        council.executeReconstruction(id);
        _sign(m[4], id, 505);
        assertEq(council.getCurrentSignatures(id).length, 3);
        council.executeReconstruction(id);
    }

    function test_GetCurrentSignaturesUnknownWarrant() public view {
        assertEq(council.getCurrentSignatures(0).length, 0);
        assertEq(council.getCurrentSignatures(99).length, 0);
    }

    // ============ Canonical Fp limbs: hi word in (P_HI, 2^128) with clean padding ============

    /// @dev 256-byte G2 encoding with limb `limb` set to (hi, lo) and a nonzero limb elsewhere (not infinity)
    function _g2WithLimb(uint256 limb, bytes32 hi, bytes32 lo) internal pure returns (bytes memory pt) {
        bytes32[8] memory w;
        w[((limb + 1) % 4) * 2 + 1] = bytes32(uint256(1));
        w[limb * 2] = hi;
        w[limb * 2 + 1] = lo;
        pt = abi.encodePacked(w);
    }

    function _g1WithLimb(uint256 limb, bytes32 hi, bytes32 lo) internal pure returns (bytes memory pt) {
        bytes32[4] memory w;
        w[((limb + 1) % 2) * 2 + 1] = bytes32(uint256(1));
        w[limb * 2] = hi;
        w[limb * 2 + 1] = lo;
        pt = abi.encodePacked(w);
    }

    function test_CanonicalLimbHiWordAboveP() public view {
        bytes32 justAbove = bytes32(uint256(P_HI) + 1);
        bytes32 padLimit = bytes32((uint256(1) << 128) - 1);
        bytes32 belowHi = bytes32(uint256(P_HI) - 1);
        bytes32 maxLo = bytes32(type(uint256).max);
        bytes32 belowLo = bytes32(uint256(P_LO) - 1);

        for (uint256 limb = 0; limb < 4; limb++) {
            // Value >= p although the 16 pad bytes are zero
            assertFalse(harness.isCanonicalG2(_g2WithLimb(limb, justAbove, 0)), "G2 hi = P_HI + 1");
            assertFalse(harness.isCanonicalG2(_g2WithLimb(limb, padLimit, maxLo)), "G2 hi = 2^128 - 1");
            assertFalse(harness.isCanonicalG2(_g2WithLimb(limb, P_HI, P_LO)), "G2 limb = p");
            // Just below p
            assertTrue(harness.isCanonicalG2(_g2WithLimb(limb, P_HI, belowLo)), "G2 limb = p - 1");
            assertTrue(harness.isCanonicalG2(_g2WithLimb(limb, belowHi, maxLo)), "G2 hi = P_HI - 1");
        }
        for (uint256 limb = 0; limb < 2; limb++) {
            assertFalse(g1Harness.isCanonicalG1(_g1WithLimb(limb, justAbove, 0)), "G1 hi = P_HI + 1");
            assertFalse(g1Harness.isCanonicalG1(_g1WithLimb(limb, padLimit, maxLo)), "G1 hi = 2^128 - 1");
            assertFalse(g1Harness.isCanonicalG1(_g1WithLimb(limb, P_HI, P_LO)), "G1 limb = p");
            assertTrue(g1Harness.isCanonicalG1(_g1WithLimb(limb, P_HI, belowLo)), "G1 limb = p - 1");
            assertTrue(g1Harness.isCanonicalG1(_g1WithLimb(limb, belowHi, maxLo)), "G1 hi = P_HI - 1");
        }
    }

    /// @dev Without EIP-2537 the structural check is all addMember / rotateMemberKey have
    function test_MemberKeyWithHiWordAbovePRejected() public {
        IComplianceCouncil.BLSPublicKey memory bad = _pk(77);
        bad.x[0] = bytes32(uint256(P_HI) + 1);
        IComplianceCouncil.BLSPublicKey memory badY = _pk(78);
        badY.y[0] = bytes32((uint256(1) << 128) - 1);

        vm.startPrank(admin);
        vm.expectRevert(bytes("Invalid BLS public key"));
        council.rotateMemberKey(m[0], bad);
        vm.expectRevert(bytes("Invalid BLS public key"));
        council.rotateMemberKey(m[0], badY);
        vm.expectRevert(bytes("Invalid BLS public key"));
        council.setAggregatedPublicKey(bad);

        // Clean padding and value below p is accepted
        IComplianceCouncil.BLSPublicKey memory ok = _pk(79);
        ok.x[0] = bytes32(uint256(P_HI) - 1);
        council.rotateMemberKey(m[0], ok);
        vm.stopPrank();
    }

    // ============ Lagrange coefficients for an even number of points ============

    function _pairs(uint256 n) internal pure returns (bytes memory) {
        return new bytes(n * 288);
    }

    /// @dev A sign error in the denominators (x_i - x_j for x_j - x_i) multiplies every coefficient by (-1)^(n-1):
    ///      invisible for odd n, so these use n = 2 and n = 4
    function test_LagrangeCoefficientsEvenCount() public view {
        uint256[] memory two = new uint256[](2);
        two[0] = 1;
        two[1] = 2;
        // l_1 = 2/(2-1) = 2, l_2 = 1/(1-2) = -1
        (, uint256[] memory l) = harness.lagrangeScalars(_pairs(2), two);
        assertEq(l[0], 2);
        assertEq(l[1], R - 1);

        // f(x) = 5 + 7x + 11x^2 + 13x^3 at four points, one of them r - 1
        uint256[] memory four = new uint256[](4);
        four[0] = 2;
        four[1] = 5;
        four[2] = 9;
        four[3] = R - 1;
        (, l) = harness.lagrangeScalars(_pairs(4), four);
        uint256 acc = 0;
        for (uint256 i = 0; i < 4; i++) {
            uint256 x = four[i];
            uint256 x2 = mulmod(x, x, R);
            uint256 fx =
                addmod(addmod(5, mulmod(7, x, R), R), addmod(mulmod(11, x2, R), mulmod(13, mulmod(x2, x, R), R), R), R);
            acc = addmod(acc, mulmod(l[i], fx, R), R);
        }
        assertEq(acc, 5);
    }
}
