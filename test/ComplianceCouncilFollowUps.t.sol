// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ComplianceCouncil} from "../contracts/modules/ComplianceCouncil.sol";
import {IComplianceCouncil} from "../contracts/interfaces/IComplianceCouncil.sol";
import {BLS12381ThresholdHarness} from "../contracts/mocks/BLS12381ThresholdHarness.sol";

/**
 * @title ComplianceCouncil follow-up fixes (EVM without EIP-2537)
 * @notice Membership and key bookkeeping, configuration, hybrid execution and the Lagrange coefficients, on
 *         Foundry's pre-Prague EVM (keys are only checked structurally there). The Prague path with real
 *         signatures is covered by test/ComplianceCouncil.bls.test.js.
 */
contract ComplianceCouncilFollowUpsTest is Test {
    ComplianceCouncil internal council;
    BLS12381ThresholdHarness internal harness;

    address internal admin = address(0xA11CE);
    address internal requester = address(0xC0C);
    address internal operator = address(0x0E7);
    address internal m1 = address(0xB01);
    address internal m2 = address(0xB02);
    address internal m3 = address(0xB03);
    address internal m4 = address(0xB04);

    /// @dev BLS12-381 group order r
    uint256 internal constant R = 0x73eda753299d7d483339d80809a1d80553bda402fffe5bfeffffffff00000001;

    /// @dev BLS12-381 base field modulus p as [hi, lo] words of its 64-byte encoding
    bytes32 internal constant P_HI = 0x000000000000000000000000000000001a0111ea397fe69a4b1ba7b6434bacd7;
    bytes32 internal constant P_LO = 0x64774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab;

    bytes32 internal constant SIGMA_HASH = keccak256("threshold signature verified off chain");

    // Events of IComplianceCouncil (qualified event access needs solc >= 0.8.21)
    event MemberKeyRotated(address indexed memberAddress, uint256 keyId);
    event SignatureSubmitted(
        uint256 indexed warrantId, address indexed signer, uint256 memberIndex, uint256 totalSignatures
    );
    event ConfigUpdated(uint256 threshold, uint256 totalMembers, uint256 votingPeriod);
    event KeyReconstructed(uint256 indexed warrantId, bytes32 keyHash, address indexed recipient);

    function setUp() public {
        // threshold 2, voting period 1h, execution delay 1d, appeal window 1d
        council = new ComplianceCouncil(2, 1 hours, 1 days, 1 days, admin);
        assertFalse(council.areBLSPrecompilesAvailable(), "suite targets EVMs without EIP-2537");
        harness = new BLS12381ThresholdHarness();
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

    function _enc(IComplianceCouncil.BLSPublicKey memory pk) internal pure returns (bytes memory) {
        return abi.encode(pk);
    }

    function _add(address member, uint256 seed, uint256 keyIndex) internal {
        vm.prank(admin);
        council.addMember(member, IComplianceCouncil.MemberRole.LegalCounsel, _pk(seed), keyIndex);
    }

    function _addThree() internal {
        _add(m1, 11, 1);
        _add(m2, 22, 2);
        _add(m3, 33, 3);
    }

    function _newWarrant(uint256 disputeId) internal returns (uint256 id) {
        vm.prank(requester);
        id = council.submitWarrantRequest(
            IComplianceCouncil.RequestType.CourtOrder, disputeId, keccak256(abi.encode(disputeId)), "US"
        );
    }

    /// @dev Hybrid mode, members 1..3, and an approved warrant whose execution time has been reached
    function _hybridApprovedWarrant() internal returns (uint256 id) {
        vm.startPrank(admin);
        council.setExecutionMode(ComplianceCouncil.ExecutionMode.HYBRID_ATTESTED, "no EIP-2537");
        council.grantRole(council.OPERATOR_ROLE(), operator);
        council.setAuthorizedRequester(requester, true);
        vm.stopPrank();
        _addThree();

        id = _newWarrant(1);
        vm.prank(m1);
        council.castVote(id, true, "");
        vm.prank(m2);
        council.castVote(id, true, "");
        vm.prank(m3);
        council.castVote(id, true, "");
        vm.warp(council.getWarrant(id).executionTime);
    }

    function _sign(address member, uint256 id, uint256 seed) internal {
        vm.prank(member);
        council.submitSignature(id, _sig(seed));
    }

    function _attest(uint256 id) internal {
        vm.prank(operator);
        council.attestHybridVerification(id, SIGMA_HASH, "noble-curves");
    }

    // ============ (1) Only current partial signatures count ============

    function test_RemovedMemberPartialDoesNotCount() public {
        uint256 id = _hybridApprovedWarrant();
        _sign(m1, id, 101);
        _sign(m2, id, 202);
        _attest(id);

        vm.prank(admin);
        council.removeMember(m2);
        assertFalse(council.hasSubmittedSignature(id, m2));
        assertEq(council.getMember(m2).keyId, 0);

        // m2's partial is still listed but no longer counts
        IComplianceCouncil.SignatureSubmission[] memory subs = council.getSignatures(id);
        assertEq(subs.length, 2);
        assertEq(subs[1].signer, m2);

        vm.expectRevert(bytes("Insufficient signatures"));
        council.executeReconstruction(id);

        _sign(m3, id, 303);
        council.executeReconstruction(id);
        assertEq(uint256(council.getWarrant(id).status), uint256(IComplianceCouncil.WarrantStatus.Executed));
    }

    function test_ReAddedMemberMustSignAgain() public {
        uint256 id = _hybridApprovedWarrant();
        _add(m4, 44, 4);
        _sign(m1, id, 101);
        _sign(m2, id, 202);
        _attest(id);

        vm.startPrank(admin);
        council.removeMember(m2);
        council.addMember(m2, IComplianceCouncil.MemberRole.LegalCounsel, _pk(22), 2);
        vm.stopPrank();

        // Same key and index, but a new registration: the old partial stays void
        assertFalse(council.hasSubmittedSignature(id, m2));
        vm.expectRevert(bytes("Insufficient signatures"));
        council.executeReconstruction(id);

        _sign(m2, id, 202);
        assertTrue(council.hasSubmittedSignature(id, m2));
        vm.prank(m2);
        vm.expectRevert(bytes("Already submitted"));
        council.submitSignature(id, _sig(202));

        council.executeReconstruction(id);
    }

    function test_RotatedKeyVoidsPartialAndAllowsResigning() public {
        uint256 id = _hybridApprovedWarrant();
        _sign(m1, id, 101);
        _sign(m2, id, 202);
        _attest(id);

        // Registration ids 1..3 went to m1..m3; the rotation hands out 4
        assertEq(council.getMember(m2).keyId, 2);
        vm.expectEmit(true, false, false, true, address(council));
        emit MemberKeyRotated(m2, 4);
        vm.prank(admin);
        council.rotateMemberKey(m2, _pk(222));
        assertEq(council.getMember(m2).keyId, 4);
        assertFalse(council.hasSubmittedSignature(id, m2));

        vm.expectRevert(bytes("Insufficient signatures"));
        council.executeReconstruction(id);

        // Signing again under the new key; the stale entry stays listed but no longer counts
        _sign(m2, id, 2222);
        IComplianceCouncil.SignatureSubmission[] memory subs = council.getSignatures(id);
        assertEq(subs.length, 3);
        assertEq(subs[1].signer, m2);
        assertEq(subs[1].keyId, 2);
        assertEq(subs[2].signer, m2);
        assertEq(subs[2].keyId, 4);

        bytes32 keyHash = council.executeReconstruction(id);
        assertEq(keyHash, SIGMA_HASH);
    }

    function test_SignatureCountEventCountsCurrentPartialsOnly() public {
        uint256 id = _hybridApprovedWarrant();
        _sign(m1, id, 101);
        vm.prank(admin);
        council.removeMember(m1);

        vm.expectEmit(true, true, false, true, address(council));
        emit SignatureSubmitted(id, m2, 2, 1);
        _sign(m2, id, 202);
    }

    // ============ (1) Only active members sign and vote, whatever their roles ============

    /// @dev Removed after signing, then MEMBER_ROLE granted back directly (not through addMember): the member is
    ///      inactive with keyId 0, so a new partial recorded under keyId 0 would match it and count
    function test_RemovedMemberWithRegrantedRoleCannotSign() public {
        uint256 id = _hybridApprovedWarrant();
        _sign(m1, id, 101);
        _sign(m2, id, 202);
        _attest(id);

        vm.startPrank(admin);
        council.removeMember(m2);
        council.grantRole(council.MEMBER_ROLE(), m2);
        vm.stopPrank();
        assertTrue(council.hasRole(council.MEMBER_ROLE(), m2));
        assertFalse(council.isMember(m2));
        assertEq(council.getMember(m2).keyId, 0);

        vm.prank(m2);
        vm.expectRevert(bytes("Not a member"));
        council.submitSignature(id, _sig(202));

        assertEq(council.getSignatures(id).length, 2);
        assertFalse(council.hasSubmittedSignature(id, m2));
        vm.expectRevert(bytes("Insufficient signatures"));
        council.executeReconstruction(id);

        // An active member completes the threshold
        _sign(m3, id, 303);
        council.executeReconstruction(id);
    }

    function test_RoleHolderNeverAddedCannotSignOrVote() public {
        uint256 id = _hybridApprovedWarrant();
        vm.startPrank(admin);
        council.grantRole(council.MEMBER_ROLE(), m4);
        vm.stopPrank();
        uint256 pending = _newWarrant(2);

        vm.prank(m4);
        vm.expectRevert(bytes("Not a member"));
        council.submitSignature(id, _sig(404));

        vm.prank(m4);
        vm.expectRevert(bytes("Not a member"));
        council.castVote(pending, true, "");
        assertFalse(council.hasVoted(pending, m4));
    }

    /// @dev A removed member's vote would otherwise count toward the approvals and the all-voted auto-conclusion
    function test_RemovedMemberWithRegrantedRoleCannotVote() public {
        _addThree();
        vm.startPrank(admin);
        council.setAuthorizedRequester(requester, true);
        council.removeMember(m3);
        council.grantRole(council.MEMBER_ROLE(), m3);
        vm.stopPrank();
        uint256 id = _newWarrant(5);

        vm.prank(m3);
        vm.expectRevert(bytes("Not a member"));
        council.castVote(id, true, "");

        vm.prank(m1);
        council.castVote(id, true, "");
        assertEq(uint256(council.getWarrant(id).status), uint256(IComplianceCouncil.WarrantStatus.Pending));
        vm.prank(m2);
        council.castVote(id, true, "");
        assertEq(uint256(council.getWarrant(id).status), uint256(IComplianceCouncil.WarrantStatus.Approved));
        assertEq(council.getWarrant(id).approvalsCount, 2);
    }

    // ============ (2) updateConfig keeps the member count ============

    function test_UpdateConfigIgnoresTotalMembers() public {
        _addThree();
        IComplianceCouncil.CouncilConfig memory cfg = council.getConfig();
        cfg.totalMembers = 1;
        cfg.votingPeriod = 2 hours;

        vm.expectEmit(false, false, false, true, address(council));
        emit ConfigUpdated(2, 3, 2 hours);
        vm.prank(admin);
        council.updateConfig(cfg);

        assertEq(council.getConfig().totalMembers, 3);
        assertEq(council.getConfig().votingPeriod, 2 hours);
        assertEq(council.getActiveMembers().length, 3);

        // With totalMembers overwritten to 1 the first vote would have concluded the warrant
        vm.prank(admin);
        council.setAuthorizedRequester(requester, true);
        uint256 id = _newWarrant(7);
        vm.prank(m1);
        council.castVote(id, true, "");
        assertEq(uint256(council.getWarrant(id).status), uint256(IComplianceCouncil.WarrantStatus.Pending));

        // Removing still respects the real count
        vm.startPrank(admin);
        council.removeMember(m3);
        vm.expectRevert(bytes("Cannot go below threshold"));
        council.removeMember(m2);
        vm.stopPrank();
    }

    function test_UpdateConfigBoundsThresholdByActualMembers() public {
        _addThree();
        IComplianceCouncil.CouncilConfig memory cfg = council.getConfig();
        cfg.threshold = 4;
        cfg.totalMembers = 10;

        vm.prank(admin);
        vm.expectRevert(bytes("Threshold > members"));
        council.updateConfig(cfg);

        cfg.threshold = 3;
        vm.prank(admin);
        council.updateConfig(cfg);
        assertEq(council.getConfig().threshold, 3);
        assertEq(council.getConfig().totalMembers, 3);
    }

    function test_UpdateConfigAnyThresholdWithoutMembers() public {
        IComplianceCouncil.CouncilConfig memory cfg = council.getConfig();
        cfg.threshold = 5;
        cfg.totalMembers = 9;
        vm.prank(admin);
        council.updateConfig(cfg);
        assertEq(council.getConfig().threshold, 5);
        assertEq(council.getConfig().totalMembers, 0);
    }

    // ============ (3) Key index bound ============

    function test_ThreeOfSevenCouncilCanBeConfigured() public {
        vm.prank(admin);
        council = new ComplianceCouncil(3, 1 hours, 1 days, 1 days, admin);
        for (uint256 i = 1; i <= 7; i++) {
            _add(address(uint160(0xD00 + i)), 1000 + 10 * i, i);
        }
        assertEq(council.getConfig().totalMembers, 7);
        assertEq(council.getMember(address(0xD07)).keyIndex, 7);
    }

    function test_KeyIndexMustBeANonzeroScalar() public {
        vm.startPrank(admin);
        vm.expectRevert(bytes("Invalid key index"));
        council.addMember(m1, IComplianceCouncil.MemberRole.LegalCounsel, _pk(11), 0);
        vm.expectRevert(bytes("Invalid key index"));
        council.addMember(m1, IComplianceCouncil.MemberRole.LegalCounsel, _pk(11), R);
        vm.expectRevert(bytes("Invalid key index"));
        council.addMember(m1, IComplianceCouncil.MemberRole.LegalCounsel, _pk(11), type(uint256).max);

        council.addMember(m1, IComplianceCouncil.MemberRole.LegalCounsel, _pk(11), R - 1);
        council.addMember(m2, IComplianceCouncil.MemberRole.LegalCounsel, _pk(22), 1000);
        vm.stopPrank();
        assertEq(council.getMember(m1).keyIndex, R - 1);
    }

    // ============ (6) Duplicate keys ============

    function test_DuplicateMemberKeysRejected() public {
        _addThree();
        vm.startPrank(admin);
        vm.expectRevert(bytes("BLS key in use"));
        council.addMember(m4, IComplianceCouncil.MemberRole.LegalCounsel, _pk(22), 4);

        vm.expectRevert(bytes("BLS key in use"));
        council.rotateMemberKey(m1, _pk(22));

        // Rotating to the key already held is rejected as well
        vm.expectRevert(bytes("BLS key in use"));
        council.rotateMemberKey(m1, _pk(11));

        // A removed member's key is free again, and so is a rotated-away key
        council.removeMember(m3);
        council.addMember(m4, IComplianceCouncil.MemberRole.LegalCounsel, _pk(33), 4);
        council.rotateMemberKey(m1, _pk(111));
        council.rotateMemberKey(m2, _pk(11));
        vm.stopPrank();

        assertEq(_enc(council.getMember(m2).publicKey), _enc(_pk(11)));
        assertEq(_enc(council.getMember(m4).publicKey), _enc(_pk(33)));
    }

    function test_GroupKeyAndMemberKeysAreDistinct() public {
        _addThree();
        vm.startPrank(admin);
        vm.expectRevert(bytes("BLS key in use"));
        council.setAggregatedPublicKey(_pk(11));

        council.setAggregatedPublicKey(_pk(77));
        // Setting the same group key again is allowed
        council.setAggregatedPublicKey(_pk(77));

        vm.expectRevert(bytes("BLS key in use"));
        council.addMember(m4, IComplianceCouncil.MemberRole.LegalCounsel, _pk(77), 4);
        vm.expectRevert(bytes("BLS key in use"));
        council.rotateMemberKey(m1, _pk(77));

        // A removed member's key may become the group key
        council.removeMember(m3);
        council.setAggregatedPublicKey(_pk(33));
        vm.stopPrank();
    }

    // ============ (7) rotateMemberKey key validation ============

    function test_RotateMemberKeyRejectsInvalidKeys() public {
        _addThree();

        IComplianceCouncil.BLSPublicKey memory infinity;
        IComplianceCouncil.BLSPublicKey memory xEqualsP = _pk(11);
        xEqualsP.x[0] = P_HI;
        xEqualsP.x[1] = P_LO;
        IComplianceCouncil.BLSPublicKey memory dirtyPad = _pk(11);
        dirtyPad.y[0] = bytes32(uint256(1) << 128);

        vm.startPrank(admin);
        vm.expectRevert(bytes("Invalid BLS public key"));
        council.rotateMemberKey(m1, infinity);
        vm.expectRevert(bytes("Invalid BLS public key"));
        council.rotateMemberKey(m1, xEqualsP);
        vm.expectRevert(bytes("Invalid BLS public key"));
        council.rotateMemberKey(m1, dirtyPad);
        vm.expectRevert(bytes("Member not found"));
        council.rotateMemberKey(m4, _pk(44));
        vm.stopPrank();

        assertEq(_enc(council.getMember(m1).publicKey), _enc(_pk(11)));
        assertEq(council.getMember(m1).keyId, 1);
    }

    // ============ (9) decryptedKeyHash in HYBRID_ATTESTED ============

    function test_HybridDecryptedKeyHashIsTheAttestation() public {
        uint256 id = _hybridApprovedWarrant();
        _sign(m1, id, 101);
        _sign(m2, id, 202);

        vm.startPrank(operator);
        vm.expectRevert(bytes("Invalid attestation"));
        council.attestHybridVerification(id, bytes32(0), "noble-curves");
        vm.expectRevert(bytes("Warrant not found"));
        council.attestHybridVerification(99, SIGMA_HASH, "noble-curves");
        council.attestHybridVerification(id, SIGMA_HASH, "noble-curves");
        vm.expectRevert(bytes("Already attested"));
        council.attestHybridVerification(id, SIGMA_HASH, "noble-curves");
        vm.stopPrank();

        (bool attested, bytes32 attestation) = council.getHybridAttestation(id);
        assertTrue(attested);
        assertEq(attestation, SIGMA_HASH);

        vm.expectEmit(true, true, false, true, address(council));
        emit KeyReconstructed(id, SIGMA_HASH, requester);
        assertEq(council.executeReconstruction(id), SIGMA_HASH);
        assertEq(council.getWarrant(id).decryptedKeyHash, SIGMA_HASH);
    }

    // ============ Warrant listing (ids derived from the warrant counter) ============

    function test_WarrantsByStatus() public {
        _addThree();
        vm.prank(admin);
        council.setAuthorizedRequester(requester, true);
        uint256 a = _newWarrant(1);
        uint256 b = _newWarrant(2);
        uint256 c = _newWarrant(3);

        // b approved by all three, c rejected by all three
        address[3] memory ms = [m1, m2, m3];
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(ms[i]);
            council.castVote(b, true, "");
            vm.prank(ms[i]);
            council.castVote(c, false, "");
        }

        uint256[] memory pending = council.getWarrantsByStatus(IComplianceCouncil.WarrantStatus.Pending);
        assertEq(pending.length, 1);
        assertEq(pending[0], a);
        assertEq(council.getPendingWarrantCount(), 1);
        uint256[] memory approved = council.getWarrantsByStatus(IComplianceCouncil.WarrantStatus.Approved);
        assertEq(approved.length, 1);
        assertEq(approved[0], b);
        uint256[] memory rejected = council.getWarrantsByStatus(IComplianceCouncil.WarrantStatus.Rejected);
        assertEq(rejected.length, 1);
        assertEq(rejected[0], c);
        assertEq(council.getWarrantsByStatus(IComplianceCouncil.WarrantStatus.Executed).length, 0);
    }

    // ============ Library: Lagrange coefficients and input checks ============

    function _pairs(uint256 n) internal pure returns (bytes memory) {
        return new bytes(n * 288);
    }

    function test_LagrangeCoefficientsAtZero() public view {
        uint256[] memory xs = new uint256[](3);
        xs[0] = 1;
        xs[1] = 2;
        xs[2] = 3;
        // l_1 = 2*3/((2-1)(3-1)) = 3, l_2 = 1*3/((1-2)(3-2)) = -3, l_3 = 1*2/((1-3)(2-3)) = 1
        (bool ok, uint256[] memory l) = harness.lagrangeScalars(_pairs(3), xs);
        assertFalse(ok, "no G2MSM on this EVM");
        assertEq(l[0], 3);
        assertEq(l[1], R - 3);
        assertEq(l[2], 1);

        // The coefficients interpolate any polynomial of degree < 3 at zero: f(x) = 5 + 7x + 11x^2
        xs[0] = 4;
        xs[1] = 9;
        xs[2] = R - 1;
        (, l) = harness.lagrangeScalars(_pairs(3), xs);
        uint256 acc = 0;
        for (uint256 i = 0; i < 3; i++) {
            uint256 x = xs[i];
            uint256 fx = addmod(addmod(5, mulmod(7, x, R), R), mulmod(11, mulmod(x, x, R), R), R);
            acc = addmod(acc, mulmod(l[i], fx, R), R);
        }
        assertEq(acc, 5);
    }

    function test_InterpolationRejectsBadInputs() public view {
        uint256[] memory xs = new uint256[](2);
        bool ok;

        (ok,) = harness.interpolateG2AtZero(_pairs(0), new uint256[](0));
        assertFalse(ok, "empty");

        xs[0] = 1;
        xs[1] = 2;
        (ok,) = harness.interpolateG2AtZero(_pairs(3), xs);
        assertFalse(ok, "length mismatch");

        uint256[3] memory bad = [uint256(0), R, R + 1];
        for (uint256 i = 0; i < bad.length; i++) {
            xs[1] = bad[i];
            uint256[] memory l;
            (ok, l) = harness.lagrangeScalars(_pairs(2), xs);
            assertFalse(ok, "point outside [1, r)");
        }

        // Repeated point: no inverse exists, rejected before any precompile call
        xs[1] = 1;
        (ok,) = harness.interpolateG2AtZero(_pairs(2), xs);
        assertFalse(ok, "repeated point");
    }

    function test_IsCanonicalG2() public view {
        bytes memory pt = new bytes(256);
        assertFalse(harness.isCanonicalG2(pt), "infinity");
        pt[63] = 0x01;
        assertTrue(harness.isCanonicalG2(pt));
        assertFalse(harness.isCanonicalG2(new bytes(128)), "length");

        // limb y.c1 = p
        bytes memory bad = bytes.concat(new bytes(192), P_HI, P_LO);
        bad[63] = 0x01;
        assertFalse(harness.isCanonicalG2(bad), "limb >= p");

        // nonzero pad byte in limb x.c1
        bytes memory dirty = new bytes(256);
        dirty[63] = 0x01;
        dirty[64] = 0x01;
        assertFalse(harness.isCanonicalG2(dirty), "dirty pad");
    }
}
