// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ComplianceCouncil} from "../contracts/modules/ComplianceCouncil.sol";
import {IComplianceCouncil} from "../contracts/interfaces/IComplianceCouncil.sol";
import {BLS12381Harness} from "../contracts/mocks/BLS12381Harness.sol";

/**
 * @title ComplianceCouncil on an EVM without EIP-2537
 * @notice Foundry runs this solc 0.8.20 code on a pre-Prague EVM, where 0x0b..0x11 are empty accounts: calls to
 *         them succeed with no output. The council must detect that, refuse STRICT_ONCHAIN, fail every BLS
 *         verification closed and still support the HYBRID_ATTESTED flow. The Prague path (real precompiles) is
 *         covered by the Hardhat suite test/ComplianceCouncil.bls.test.js.
 */
contract ComplianceCouncilNoPrecompilesTest is Test {
    ComplianceCouncil internal council;
    BLS12381Harness internal harness;

    address internal admin = address(0xA11CE);
    address internal requester = address(0xC0C);
    address internal operator = address(0x0E7);
    address internal m1 = address(0xB01);
    address internal m2 = address(0xB02);
    address internal m3 = address(0xB03);
    address internal m4 = address(0xB04);

    bytes internal constant DST = "ILRM-COMPLIANCE-COUNCIL-V01-CS01-with-BLS12381G2_XMD:SHA-256_SSWU_RO_";

    /// @dev BLS12-381 base field modulus p as [hi, lo] words of its 64-byte encoding
    bytes32 internal constant P_HI = 0x000000000000000000000000000000001a0111ea397fe69a4b1ba7b6434bacd7;
    bytes32 internal constant P_LO = 0x64774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab;

    function setUp() public {
        harness = new BLS12381Harness();
        // This suite targets chains WITHOUT EIP-2537. If a future Foundry / solc bump enables the precompiles,
        // fail loudly here instead of silently exercising the wrong path.
        assertFalse(harness.precompilesAvailable(), "EVM has EIP-2537: this suite targets pre-Prague chains");

        // threshold 2 (key indices 1..4), voting period 1h, execution delay 1d, appeal window 1d
        council = new ComplianceCouncil(2, 1 hours, 1 days, 1 days, admin);
    }

    // ============ Helpers ============

    /// @dev Structurally canonical (not necessarily on-curve) G1 encoding: hi words zero, small lo words
    function _pk(uint256 seed) internal pure returns (IComplianceCouncil.BLSPublicKey memory pk) {
        pk.x[1] = bytes32(seed);
        pk.y[1] = bytes32(seed + 1);
    }

    function _sig(uint256 seed) internal pure returns (IComplianceCouncil.BLSSignature memory sig) {
        sig.x[1] = bytes32(seed);
        sig.y[1] = bytes32(seed + 1);
    }

    function _enc(IComplianceCouncil.BLSPublicKey memory pk) internal pure returns (bytes memory) {
        return abi.encodePacked(pk.x, pk.y);
    }

    function _addThreeMembers() internal {
        vm.startPrank(admin);
        council.addMember(m1, IComplianceCouncil.MemberRole.LegalCounsel, _pk(11), 1);
        council.addMember(m2, IComplianceCouncil.MemberRole.IndependentAuditor, _pk(22), 2);
        council.addMember(m3, IComplianceCouncil.MemberRole.UserRepresentative, _pk(33), 3);
        vm.stopPrank();
    }

    /// @dev Members 1..3 plus an approved warrant whose execution time has been reached
    function _approvedWarrant() internal returns (uint256 id) {
        _addThreeMembers();
        vm.prank(admin);
        council.setAuthorizedRequester(requester, true);

        vm.prank(requester);
        id = council.submitWarrantRequest(IComplianceCouncil.RequestType.CourtOrder, 1, keccak256("doc"), "US");

        vm.prank(m1);
        council.castVote(id, true, "ok");
        vm.prank(m2);
        council.castVote(id, true, "ok");
        vm.prank(m3);
        council.castVote(id, false, "no");

        IComplianceCouncil.WarrantRequest memory w = council.getWarrant(id);
        assertEq(uint256(w.status), uint256(IComplianceCouncil.WarrantStatus.Approved));
        vm.warp(w.executionTime);
    }

    // ============ Detection ============

    function test_DetectionReportsPrecompilesUnavailable() public view {
        assertFalse(harness.precompilesAvailable());
        assertFalse(council.areBLSPrecompilesAvailable());
        assertEq(uint256(council.executionMode()), uint256(ComplianceCouncil.ExecutionMode.DISABLED));
    }

    function test_StrictModeCannotBeSelected() public {
        vm.prank(admin);
        vm.expectRevert(bytes("BLS precompiles required for STRICT_ONCHAIN"));
        council.setExecutionMode(ComplianceCouncil.ExecutionMode.STRICT_ONCHAIN, "no precompiles");
    }

    // ============ Fail closed ============

    function test_VerificationFailsClosed() public {
        uint256 id = _approvedWarrant();

        assertFalse(council.verifySignature(council.getSigningMessage(id), _sig(5), _pk(11)));

        uint256[] memory indices = new uint256[](2);
        indices[0] = 1;
        indices[1] = 2;
        IComplianceCouncil.ThresholdSignature memory ts =
            IComplianceCouncil.ThresholdSignature({aggregatedSig: _sig(5), signerIndices: indices, signatureCount: 2});
        assertFalse(council.verifyThresholdSignature(id, ts));

        IComplianceCouncil.BLSSignature[] memory sigs = new IComplianceCouncil.BLSSignature[](2);
        sigs[0] = _sig(5);
        sigs[1] = _sig(6);
        vm.expectRevert(bytes("BLS precompiles required"));
        council.aggregateSignatures(sigs);
    }

    function test_LibraryFailsClosed() public view {
        bytes memory pk = _enc(_pk(11));
        bytes memory sig = abi.encodePacked(_sig(5).x, _sig(5).y);

        assertFalse(harness.verify(pk, sig, "message", DST));
        (bool ok,) = harness.hashToG2("message", DST);
        assertFalse(ok);
        (ok,) = harness.g2Add(sig, sig);
        assertFalse(ok);
        assertFalse(harness.isValidG1(pk));
        // The structural check needs no precompile
        assertTrue(harness.isCanonicalG1(pk));
    }

    // ============ Key checks without precompiles ============

    function test_StructuralKeyCheckThroughAddMember() public {
        IComplianceCouncil.BLSPublicKey memory infinity;

        IComplianceCouncil.BLSPublicKey memory xEqualsP = _pk(11);
        xEqualsP.x[0] = P_HI;
        xEqualsP.x[1] = P_LO;

        IComplianceCouncil.BLSPublicKey memory dirtyPad = _pk(11);
        dirtyPad.y[0] = bytes32(uint256(1) << 128);

        vm.startPrank(admin);
        vm.expectRevert(bytes("Invalid BLS public key"));
        council.addMember(m1, IComplianceCouncil.MemberRole.LegalCounsel, infinity, 1);
        vm.expectRevert(bytes("Invalid BLS public key"));
        council.addMember(m1, IComplianceCouncil.MemberRole.LegalCounsel, xEqualsP, 1);
        vm.expectRevert(bytes("Invalid BLS public key"));
        council.addMember(m1, IComplianceCouncil.MemberRole.LegalCounsel, dirtyPad, 1);

        // x = p - 1 is the largest canonical coordinate
        IComplianceCouncil.BLSPublicKey memory maxCanonical = _pk(11);
        maxCanonical.x[0] = P_HI;
        maxCanonical.x[1] = bytes32(uint256(P_LO) - 1);
        council.addMember(m1, IComplianceCouncil.MemberRole.LegalCounsel, maxCanonical, 1);
        vm.stopPrank();

        assertTrue(council.isMember(m1));
        assertEq(_enc(council.getMember(m1).publicKey), _enc(maxCanonical));
    }

    function test_KeyIndexUniquenessAndNoDuplicateOnReAdd() public {
        _addThreeMembers();

        vm.startPrank(admin);
        vm.expectRevert(bytes("Key index in use"));
        council.addMember(m4, IComplianceCouncil.MemberRole.LegalCounsel, _pk(44), 2);

        // Removing m2 frees index 2; m2 is re-added and m4 takes the remaining index
        council.removeMember(m2);
        council.addMember(m2, IComplianceCouncil.MemberRole.IndependentAuditor, _pk(22), 2);
        council.addMember(m4, IComplianceCouncil.MemberRole.LegalCounsel, _pk(44), 4);
        vm.stopPrank();

        IComplianceCouncil.CouncilMember[] memory active = council.getActiveMembers();
        assertEq(active.length, 4);
        for (uint256 i = 0; i < active.length; i++) {
            for (uint256 j = i + 1; j < active.length; j++) {
                assertTrue(active[i].memberAddress != active[j].memberAddress, "duplicate active member");
            }
        }
        assertEq(active[3].memberAddress, m4);
    }

    function test_SetAggregatedPublicKeyChecksEncoding() public {
        IComplianceCouncil.BLSPublicKey memory infinity;
        vm.startPrank(admin);
        vm.expectRevert(bytes("Invalid BLS public key"));
        council.setAggregatedPublicKey(infinity);

        council.setAggregatedPublicKey(_pk(77));
        vm.stopPrank();
        assertEq(_enc(council.getAggregatedPublicKey()), _enc(_pk(77)));
    }

    // ============ Hybrid flow ============

    function test_HybridFlowRequiresAttestation() public {
        vm.startPrank(admin);
        council.setExecutionMode(ComplianceCouncil.ExecutionMode.HYBRID_ATTESTED, "L2 without EIP-2537");
        council.grantRole(council.OPERATOR_ROLE(), operator);
        vm.stopPrank();

        uint256 id = _approvedWarrant();

        // Unverifiable on chain: recorded as unverified instead of reverting
        vm.prank(m1);
        council.submitSignature(id, _sig(101));
        vm.prank(m2);
        council.submitSignature(id, _sig(202));

        IComplianceCouncil.SignatureSubmission[] memory subs = council.getSignatures(id);
        assertEq(subs.length, 2);
        assertFalse(subs[0].verified);
        assertFalse(subs[1].verified);

        vm.expectRevert(bytes("Hybrid attestation required"));
        council.executeReconstruction(id);

        vm.prank(operator);
        council.attestHybridVerification(id, keccak256("off-chain BLS verification"), "noble-curves");

        council.executeReconstruction(id);
        assertEq(uint256(council.getWarrant(id).status), uint256(IComplianceCouncil.WarrantStatus.Executed));
    }
}
