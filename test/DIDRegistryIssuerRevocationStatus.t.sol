// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/modules/DIDRegistry.sol";

/**
 * @title DIDRegistryIssuerRevocationStatusTest
 * @notice revokeIssuerCredentials coverage the original suite lacked: it must work on a suspended and on a revoked
 *         DID (status does not gate recovery, as with revokeCredential), and an issuer that is no longer trusted
 *         must still be able to clear its own credentials (but not anyone else's).
 */
contract DIDRegistryIssuerRevocationStatusTest is Test {
    // Redeclared locally: a qualified `emit IDIDRegistry.X` needs solc >= 0.8.21.
    event SybilScoreUpdated(bytes32 indexed did, uint256 oldScore, uint256 newScore);

    DIDRegistry internal registry;

    address internal controller = makeAddr("controller");
    address internal griefer = makeAddr("griefer"); // trust 1
    address internal hiIssuer = makeAddr("hiIssuer"); // trust 100

    bytes32 internal did;
    uint256 internal perIssuer;
    uint256 internal claimNonce;

    function setUp() public {
        vm.warp(1_700_000_000);
        registry = new DIDRegistry();
        registry.addTrustedIssuer(griefer, "griefer", _identityTypes(), 1);
        registry.addTrustedIssuer(hiIssuer, "hi", _identityTypes(), 100);

        vm.prank(controller);
        did = registry.registerDID(bytes32(uint256(0xd1d)));
        perIssuer = registry.MAX_CREDENTIALS_PER_ISSUER();
    }

    function _identityTypes() internal pure returns (IDIDRegistry.AttestationType[] memory types) {
        types = new IDIDRegistry.AttestationType[](1);
        types[0] = IDIDRegistry.AttestationType.Identity;
    }

    function _issue(address issuer, uint256 weight) internal returns (bytes32) {
        vm.prank(issuer);
        return registry.issueCredential(did, IDIDRegistry.AttestationType.Identity, bytes32(++claimNonce), 0, weight);
    }

    /// @dev perIssuer griefer credentials plus one from hiIssuer; returns the griefer's
    function _populate() internal returns (bytes32[] memory spam) {
        spam = new bytes32[](perIssuer);
        for (uint256 i = 0; i < perIssuer; i++) {
            spam[i] = _issue(griefer, 50);
        }
        _issue(hiIssuer, 50);
        // Each griefer credential contributes 50 * 1 / 100 = 0 but adds weight: 50 * 100 / 550 = 9
        assertEq(registry.getSybilScore(did), 9);
    }

    function _assertGrieferCleared(bytes32[] memory spam) internal view {
        for (uint256 i = 0; i < spam.length; i++) {
            assertTrue(registry.getCredential(spam[i]).revoked);
        }
        assertEq(registry.getCredentials(did).length, 1);
        assertEq(registry.getIssuerCredentialCount(did, griefer), 0);
        assertEq(registry.getIssuerCredentialCount(did, hiIssuer), 1);
        assertEq(registry.getSybilScore(did), 100);
    }

    // ============ Suspended DID ============

    function test_ControllerClearsAnIssuerOnASuspendedDID() public {
        bytes32[] memory spam = _populate();
        vm.prank(controller);
        registry.suspendDID(did, "investigating spam");

        vm.expectEmit(true, false, false, true, address(registry));
        emit SybilScoreUpdated(did, 9, 100); // recorded, not just live
        vm.prank(controller);
        assertEq(registry.revokeIssuerCredentials(did, griefer, "spam"), perIssuer);
        _assertGrieferCleared(spam);
        // Suspension still gates participation until the controller reactivates
        assertFalse(registry.meetsSybilRequirement(did, 1));

        vm.prank(controller);
        registry.reactivateDID(did);
        assertTrue(registry.meetsSybilRequirement(did, 100));
        // Freed slots are usable again once active
        _issue(griefer, 50);
        assertEq(registry.getIssuerCredentialCount(did, griefer), 1);
    }

    function test_IssuerClearsItsOwnCredentialsOnASuspendedDID() public {
        bytes32[] memory spam = _populate();
        vm.prank(controller);
        registry.suspendDID(did, "pause");

        vm.prank(griefer);
        assertEq(registry.revokeIssuerCredentials(did, griefer, "withdrawn"), perIssuer);
        _assertGrieferCleared(spam);
        assertEq(uint8(registry.getDIDDocument(did).status), uint8(IDIDRegistry.DIDStatus.Suspended));
    }

    // ============ Revoked DID ============

    function test_ControllerAndIssuerClearCredentialsOnARevokedDID() public {
        bytes32[] memory spam = _populate();
        vm.prank(controller);
        registry.revokeDID(did, "retired");
        // revokeDID frees the address mapping but keeps the document's controller
        assertFalse(registry.hasDID(controller));
        assertEq(registry.resolveDID(did), controller);

        // A revoked DID takes no new credentials...
        vm.prank(hiIssuer);
        vm.expectRevert(abi.encodeWithSelector(IDIDRegistry.DIDNotActive.selector, did));
        registry.issueCredential(did, IDIDRegistry.AttestationType.Identity, bytes32(++claimNonce), 0, 50);

        // ...but its former controller can still clear an issuer, and an issuer its own
        vm.prank(controller);
        assertEq(registry.revokeIssuerCredentials(did, griefer, "retired"), perIssuer);
        _assertGrieferCleared(spam);

        vm.prank(hiIssuer);
        assertEq(registry.revokeIssuerCredentials(did, hiIssuer, "retired"), 1);
        assertEq(registry.getCredentials(did).length, 0);
        assertEq(registry.getIssuerCredentialCount(did, hiIssuer), 0);
        assertEq(registry.getSybilScore(did), 0);
        assertEq(uint8(registry.getDIDDocument(did).status), uint8(IDIDRegistry.DIDStatus.Revoked));
    }

    function test_RevokedDIDStillRejectsStrangers() public {
        _populate();
        vm.prank(controller);
        registry.revokeDID(did, "retired");

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IDIDRegistry.NotDIDController.selector, did, stranger));
        registry.revokeIssuerCredentials(did, griefer, "x");
        // hiIssuer cannot clear the griefer's credentials either
        vm.prank(hiIssuer);
        vm.expectRevert(abi.encodeWithSelector(IDIDRegistry.NotDIDController.selector, did, hiIssuer));
        registry.revokeIssuerCredentials(did, griefer, "x");
        assertEq(registry.getIssuerCredentialCount(did, griefer), perIssuer);
    }

    // ============ Removed (untrusted) issuer ============

    function test_RemovedIssuerClearsItsOwnCredentials() public {
        bytes32[] memory spam = _populate();
        registry.removeTrustedIssuer(griefer);
        assertFalse(registry.isTrustedIssuer(griefer));
        // Removal alone keeps the slots (the credentials would count again if the issuer were re-added)
        assertEq(registry.getIssuerCredentialCount(did, griefer), perIssuer);

        vm.prank(griefer);
        assertEq(registry.revokeIssuerCredentials(did, griefer, "offboarded"), perIssuer);
        _assertGrieferCleared(spam);

        // Clearing again is a no-op, and the untrusted issuer still cannot issue
        vm.prank(griefer);
        assertEq(registry.revokeIssuerCredentials(did, griefer, "again"), 0);
        vm.prank(griefer);
        vm.expectRevert(abi.encodeWithSelector(IDIDRegistry.NotTrustedIssuer.selector, griefer));
        registry.issueCredential(did, IDIDRegistry.AttestationType.Identity, bytes32(++claimNonce), 0, 50);

        // Re-adding the issuer does not resurrect anything
        registry.addTrustedIssuer(griefer, "griefer", _identityTypes(), 1);
        assertEq(registry.getSybilScore(did), 100);
    }

    function test_RemovedIssuerCannotClearAnotherIssuer() public {
        _populate();
        registry.removeTrustedIssuer(griefer);

        vm.prank(griefer);
        vm.expectRevert(abi.encodeWithSelector(IDIDRegistry.NotDIDController.selector, did, griefer));
        registry.revokeIssuerCredentials(did, hiIssuer, "x");
        assertEq(registry.getIssuerCredentialCount(did, hiIssuer), 1);
    }

    function test_RemovedIssuerClearsItsOwnCredentialsOnASuspendedDIDWhilePaused() public {
        bytes32[] memory spam = _populate();
        registry.removeTrustedIssuer(griefer);
        vm.prank(controller);
        registry.suspendDID(did, "pause");
        registry.pause();

        vm.prank(griefer);
        assertEq(registry.revokeIssuerCredentials(did, griefer, "offboarded"), perIssuer);
        _assertGrieferCleared(spam);
    }
}
