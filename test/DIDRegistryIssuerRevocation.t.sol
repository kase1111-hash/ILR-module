// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/modules/DIDRegistry.sol";

/**
 * @title DIDRegistryIssuerRevocationTest
 * @notice The per-issuer credential limit and one-call recovery: revokeIssuerCredentials clears every credential
 *         of one issuer from a DID, and getIssuerCredentialCount stays in step with the credential array.
 */
contract DIDRegistryIssuerRevocationTest is Test {
    /// @dev Bound for one revokeIssuerCredentials over a full array (generous so unoptimized builds pass too)
    uint256 internal constant GAS_BOUND = 3_000_000;

    // Redeclared locally: a qualified `emit IDIDRegistry.X` needs solc >= 0.8.21.
    event CredentialRevoked(bytes32 indexed credentialId, address indexed revoker, string reason);
    event SybilScoreUpdated(bytes32 indexed did, uint256 oldScore, uint256 newScore);

    DIDRegistry internal registry;

    address internal controller = makeAddr("controller");
    address internal griefer = makeAddr("griefer"); // trust 1
    address internal hiIssuer = makeAddr("hiIssuer"); // trust 100
    address internal loIssuer = makeAddr("loIssuer"); // trust 20

    bytes32 internal did;
    uint256 internal perIssuer;
    uint256 internal claimNonce;

    function setUp() public {
        vm.warp(1_700_000_000);
        registry = new DIDRegistry();
        registry.addTrustedIssuer(griefer, "griefer", _identityTypes(), 1);
        registry.addTrustedIssuer(hiIssuer, "hi", _identityTypes(), 100);
        registry.addTrustedIssuer(loIssuer, "lo", _identityTypes(), 20);

        vm.prank(controller);
        did = registry.registerDID(bytes32(uint256(0xd1d)));
        perIssuer = registry.MAX_CREDENTIALS_PER_ISSUER();
    }

    function _identityTypes() internal pure returns (IDIDRegistry.AttestationType[] memory types) {
        types = new IDIDRegistry.AttestationType[](1);
        types[0] = IDIDRegistry.AttestationType.Identity;
    }

    function _issue(address issuer, uint256 expiresAt, uint256 weight) internal returns (bytes32) {
        vm.prank(issuer);
        return
            registry.issueCredential(
                did, IDIDRegistry.AttestationType.Identity, bytes32(++claimNonce), expiresAt, weight
            );
    }

    function _countIn(bytes32[] memory ids, address issuer) internal view returns (uint256 count) {
        for (uint256 i = 0; i < ids.length; i++) {
            if (registry.getCredential(ids[i]).issuer == issuer) count++;
        }
    }

    function _assertCount(address issuer) internal view {
        assertEq(registry.getIssuerCredentialCount(did, issuer), _countIn(registry.getCredentials(did), issuer));
    }

    function test_Limits() public view {
        assertEq(perIssuer, 10);
        // Filling a DID takes at least five issuers
        assertEq(registry.MAX_CREDENTIALS_FOR_SCORE() / perIssuer, 5);
    }

    function test_ControllerClearsAnIssuerInOneCall() public {
        bytes32[] memory spam = new bytes32[](perIssuer);
        for (uint256 i = 0; i < perIssuer; i++) {
            spam[i] = _issue(griefer, 0, 100);
        }
        bytes32 hiCred = _issue(hiIssuer, 0, 50);
        bytes32 loCred = _issue(loIssuer, 0, 50);
        // (10 * 100 * 1 / 100 + 50 + 10) * 100 / 1100 = 6
        assertEq(registry.getSybilScore(did), 6);
        assertEq(registry.getIssuerCredentialCount(did, griefer), perIssuer);

        vm.recordLogs();
        vm.prank(controller);
        uint256 gasBefore = gasleft();
        uint256 revoked = registry.revokeIssuerCredentials(did, griefer, "spam");
        uint256 used = gasBefore - gasleft();

        assertEq(revoked, perIssuer);
        assertLt(used, GAS_BOUND);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 revokedEvents;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == CredentialRevoked.selector) {
                revokedEvents++;
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(controller))));
            }
        }
        assertEq(revokedEvents, perIssuer);

        for (uint256 i = 0; i < perIssuer; i++) {
            assertTrue(registry.getCredential(spam[i]).revoked);
            assertFalse(registry.verifyCredential(spam[i]));
        }
        bytes32[] memory stored = registry.getCredentials(did);
        assertEq(stored.length, 2);
        assertTrue(stored[0] == hiCred || stored[1] == hiCred);
        assertTrue(stored[0] == loCred || stored[1] == loCred);
        assertEq(registry.getIssuerCredentialCount(did, griefer), 0);
        _assertCount(hiIssuer);
        _assertCount(loIssuer);
        assertEq(registry.getSybilScore(did), 60);

        // The issuer is still trusted, so it can issue again, but only up to its limit
        for (uint256 i = 0; i < perIssuer; i++) {
            _issue(griefer, 0, 0);
        }
        vm.prank(griefer);
        vm.expectRevert(abi.encodeWithSelector(IDIDRegistry.IssuerCredentialLimit.selector, did, griefer));
        registry.issueCredential(did, IDIDRegistry.AttestationType.Identity, bytes32(++claimNonce), 0, 0);
    }

    function test_ClearsCredentialsOfARemovedIssuer() public {
        for (uint256 i = 0; i < perIssuer; i++) {
            _issue(griefer, 0, 0);
        }
        registry.removeTrustedIssuer(griefer);
        // Removal alone keeps the slots (the credentials would count again if the issuer were re-added)
        assertEq(registry.getCredentials(did).length, perIssuer);

        vm.prank(controller);
        assertEq(registry.revokeIssuerCredentials(did, griefer, "removed issuer"), perIssuer);
        assertEq(registry.getCredentials(did).length, 0);
        assertEq(registry.getIssuerCredentialCount(did, griefer), 0);
    }

    function test_IssuerCanClearItsOwnCredentials() public {
        for (uint256 i = 0; i < 3; i++) {
            _issue(hiIssuer, 0, 50);
        }
        _issue(loIssuer, 0, 50);

        vm.prank(hiIssuer);
        assertEq(registry.revokeIssuerCredentials(did, hiIssuer, "rotate"), 3);
        assertEq(registry.getCredentials(did).length, 1);
        assertEq(registry.getSybilScore(did), 20);
    }

    function test_RevokeIssuerCredentialsAuthorization() public {
        _issue(hiIssuer, 0, 50);
        _issue(loIssuer, 0, 50);
        address stranger = makeAddr("stranger");

        // Neither the controller nor the named issuer
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IDIDRegistry.NotDIDController.selector, did, stranger));
        registry.revokeIssuerCredentials(did, hiIssuer, "x");

        // An issuer cannot clear another issuer's credentials
        vm.prank(loIssuer);
        vm.expectRevert(abi.encodeWithSelector(IDIDRegistry.NotDIDController.selector, did, loIssuer));
        registry.revokeIssuerCredentials(did, hiIssuer, "x");

        // Unknown DID
        bytes32 unknown = bytes32(uint256(0xdead));
        vm.prank(hiIssuer);
        vm.expectRevert(abi.encodeWithSelector(IDIDRegistry.DIDNotFound.selector, unknown));
        registry.revokeIssuerCredentials(unknown, hiIssuer, "x");

        assertEq(registry.getCredentials(did).length, 2);
    }

    function test_DoesNotRecountAlreadyRevokedAndPrunesEverythingStale() public {
        uint256 expiry = block.timestamp + 1 days;
        bytes32 first = _issue(griefer, 0, 10);
        for (uint256 i = 1; i < perIssuer; i++) {
            _issue(griefer, 0, 10);
        }
        bytes32 loRevoked = _issue(loIssuer, 0, 50);
        _issue(loIssuer, expiry, 50);
        _issue(hiIssuer, 0, 50);

        vm.startPrank(controller);
        registry.revokeCredential(first, "one");
        registry.revokeCredential(loRevoked, "two");
        vm.stopPrank();
        vm.warp(expiry + 1);

        registry.pause(); // recovery works while paused

        // 9 live griefer credentials dilute: (9 * (10 * 1 / 100) + 50) * 100 / (90 + 50) = 35
        assertEq(registry.getSybilScore(did), 35);
        vm.prank(controller);
        uint256 revoked = registry.revokeIssuerCredentials(did, griefer, "spam");

        assertEq(revoked, perIssuer - 1); // the one revoked earlier is not counted again
        assertEq(registry.getSybilScore(did), 100);
        // Everything stale went with it: only hiIssuer's credential remains
        assertEq(registry.getCredentials(did).length, 1);
        assertEq(registry.getIssuerCredentialCount(did, griefer), 0);
        assertEq(registry.getIssuerCredentialCount(did, loIssuer), 0);
        assertEq(registry.getIssuerCredentialCount(did, hiIssuer), 1);
        assertEq(registry.cleanupCredentials(did), 0);
    }

    function test_RecordsScoreAndEmits() public {
        _issue(hiIssuer, 0, 50);
        _issue(griefer, 0, 50);
        // (50 + 0) * 100 / 100 = 50
        assertEq(registry.getSybilScore(did), 50);

        vm.expectEmit(true, false, false, true, address(registry));
        emit SybilScoreUpdated(did, 50, 100);
        vm.prank(controller);
        registry.revokeIssuerCredentials(did, griefer, "spam");
    }

    function test_NoCredentialsIsANoOp() public {
        _issue(hiIssuer, 0, 50);
        vm.prank(controller);
        assertEq(registry.revokeIssuerCredentials(did, griefer, "none"), 0);
        assertEq(registry.getCredentials(did).length, 1);
    }

    function test_IssuerAtLimitReclaimsItsOwnRevokedAndExpiredSlots() public {
        uint256 expiry = block.timestamp + 1 days;
        bytes32[] memory ids = new bytes32[](perIssuer);
        for (uint256 i = 0; i < perIssuer; i++) {
            ids[i] = _issue(hiIssuer, i < 3 ? expiry : 0, 50);
        }
        _issue(loIssuer, 0, 50);
        assertEq(registry.getIssuerCredentialCount(did, hiIssuer), perIssuer);

        // At the limit with every entry live: rejected, nothing pruned
        vm.prank(hiIssuer);
        vm.expectRevert(abi.encodeWithSelector(IDIDRegistry.IssuerCredentialLimit.selector, did, hiIssuer));
        registry.issueCredential(did, IDIDRegistry.AttestationType.Identity, bytes32(++claimNonce), 0, 50);

        // Revoked entries keep counting until pruned...
        vm.prank(hiIssuer);
        registry.revokeCredential(ids[5], "renew");
        assertEq(registry.getIssuerCredentialCount(did, hiIssuer), perIssuer);
        // ...and issuance at the limit prunes them (and expired ones) first
        vm.warp(expiry + 1);
        _issue(hiIssuer, 0, 50);
        assertEq(registry.getIssuerCredentialCount(did, hiIssuer), perIssuer - 4 + 1);
        assertEq(registry.getCredentials(did).length, perIssuer - 4 + 1 + 1);
        _assertCount(hiIssuer);
        _assertCount(loIssuer);
    }

    function test_CountsFollowCleanup() public {
        uint256 expiry = block.timestamp + 1 days;
        for (uint256 i = 0; i < 4; i++) {
            _issue(hiIssuer, expiry, 50);
            _issue(loIssuer, 0, 50);
        }
        vm.warp(expiry + 1);
        assertEq(registry.getIssuerCredentialCount(did, hiIssuer), 4);

        assertEq(registry.cleanupCredentials(did), 4);
        assertEq(registry.getIssuerCredentialCount(did, hiIssuer), 0);
        assertEq(registry.getIssuerCredentialCount(did, loIssuer), 4);
        _assertCount(loIssuer);
    }
}
