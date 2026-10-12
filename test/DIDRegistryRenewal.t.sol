// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "../contracts/modules/DIDRegistry.sol";

/**
 * @title DIDRegistryRenewalTest
 * @notice An honest issuer must be able to renew its credentials early without hitting its own
 *         MAX_CREDENTIALS_PER_ISSUER limit. Renewing with issueCredential needs a second slot while the old
 *         credential is still live, so an issuer holding one credential per attestation type (or any issuer at its
 *         limit) could not renew before expiry. renewCredential supersedes the issuer's own credential with a new
 *         one of the same attestation type for the same DID, in the same array slot.
 */
contract DIDRegistryRenewalTest is Test {
    // Redeclared locally: a qualified `emit IDIDRegistry.X` needs solc >= 0.8.21.
    event CredentialIssued(
        bytes32 indexed credentialId,
        bytes32 indexed did,
        address indexed issuer,
        IDIDRegistry.AttestationType attestationType
    );
    event CredentialRevoked(bytes32 indexed credentialId, address indexed revoker, string reason);
    event CredentialSuperseded(bytes32 indexed oldCredentialId, bytes32 indexed newCredentialId, bytes32 indexed did);
    event SybilScoreUpdated(bytes32 indexed did, uint256 oldScore, uint256 newScore);

    uint256 internal constant TYPE_COUNT = 6; // members of IDIDRegistry.AttestationType

    DIDRegistry internal registry;

    address internal controller = makeAddr("controller");
    address internal hiIssuer = makeAddr("hiIssuer"); // trust 100, Identity only
    address internal loIssuer = makeAddr("loIssuer"); // trust 20, Identity only
    address internal allTypes = makeAddr("allTypes"); // trust 100, every attestation type

    bytes32 internal did;
    uint256 internal perIssuer;
    uint256 internal cap;
    uint256 internal claimNonce;

    function setUp() public {
        vm.warp(1_700_000_000);
        registry = new DIDRegistry();
        registry.addTrustedIssuer(hiIssuer, "hi", _identityTypes(), 100);
        registry.addTrustedIssuer(loIssuer, "lo", _identityTypes(), 20);
        registry.addTrustedIssuer(allTypes, "all", _allTypes(), 100);

        vm.prank(controller);
        did = registry.registerDID(bytes32(uint256(0xd1d)));
        perIssuer = registry.MAX_CREDENTIALS_PER_ISSUER();
        cap = registry.MAX_CREDENTIALS_FOR_SCORE();
    }

    // ============ Helpers ============

    function _identityTypes() internal pure returns (IDIDRegistry.AttestationType[] memory types) {
        types = new IDIDRegistry.AttestationType[](1);
        types[0] = IDIDRegistry.AttestationType.Identity;
    }

    function _allTypes() internal pure returns (IDIDRegistry.AttestationType[] memory types) {
        types = new IDIDRegistry.AttestationType[](TYPE_COUNT);
        for (uint256 t = 0; t < TYPE_COUNT; t++) {
            types[t] = IDIDRegistry.AttestationType(t);
        }
    }

    function _issueType(address issuer, IDIDRegistry.AttestationType attestationType, uint256 expiresAt, uint256 weight)
        internal
        returns (bytes32)
    {
        vm.prank(issuer);
        return registry.issueCredential(did, attestationType, bytes32(++claimNonce), expiresAt, weight);
    }

    function _issue(address issuer, uint256 expiresAt, uint256 weight) internal returns (bytes32) {
        return _issueType(issuer, IDIDRegistry.AttestationType.Identity, expiresAt, weight);
    }

    function _renew(address issuer, bytes32 credentialId, uint256 expiresAt, uint256 weight)
        internal
        returns (bytes32)
    {
        vm.prank(issuer);
        return registry.renewCredential(credentialId, bytes32(++claimNonce), expiresAt, weight);
    }

    function _expectRenewRevert(address issuer, bytes32 credentialId, uint256 expiresAt, bytes memory reason) internal {
        vm.prank(issuer);
        vm.expectRevert(reason);
        registry.renewCredential(credentialId, bytes32(++claimNonce), expiresAt, 50);
    }

    function _indexOf(bytes32 credentialId) internal view returns (uint256) {
        bytes32[] memory ids = registry.getCredentials(did);
        for (uint256 i = 0; i < ids.length; i++) {
            if (ids[i] == credentialId) return i;
        }
        return type(uint256).max;
    }

    function _countIn(address issuer) internal view returns (uint256 count) {
        bytes32[] memory ids = registry.getCredentials(did);
        for (uint256 i = 0; i < ids.length; i++) {
            if (registry.getCredential(ids[i]).issuer == issuer) count++;
        }
    }

    function _assertCount(address issuer) internal view {
        assertEq(registry.getIssuerCredentialCount(did, issuer), _countIn(issuer));
    }

    // ============ The defect: early renewal needs a slot the issuer does not have ============

    function test_IssuerWithOneCredentialPerTypeRenewsEachEarly() public {
        uint256 expiry = block.timestamp + 30 days;
        bytes32[] memory current = new bytes32[](TYPE_COUNT);
        for (uint256 t = 0; t < TYPE_COUNT; t++) {
            current[t] = _issueType(allTypes, IDIDRegistry.AttestationType(t), expiry, 50);
        }
        assertEq(registry.getIssuerCredentialCount(did, allTypes), TYPE_COUNT);

        // A week before expiry the issuer renews each one and lets the old ones lapse. With issueCredential the
        // old (still live) credentials keep counting until they expire and are pruned, so TYPE_COUNT + 4 = 10 is
        // the most it can hold: the fifth renewal needs an 11th slot and is rejected, although the issuer only
        // ever means to hold one current credential per type.
        vm.warp(expiry - 7 days);
        uint256 snapshot = vm.snapshotState();
        for (uint256 t = 0; t < perIssuer - TYPE_COUNT; t++) {
            _issueType(allTypes, IDIDRegistry.AttestationType(t), expiry + 30 days, 50);
        }
        vm.prank(allTypes);
        vm.expectRevert(abi.encodeWithSelector(IDIDRegistry.IssuerCredentialLimit.selector, did, allTypes));
        registry.issueCredential(did, IDIDRegistry.AttestationType(4), bytes32(++claimNonce), expiry + 30 days, 50);
        vm.revertToState(snapshot);

        // renewCredential supersedes each one in place: no extra slot, ever
        for (uint256 t = 0; t < TYPE_COUNT; t++) {
            uint256 slot = _indexOf(current[t]);
            bytes32 renewed = _renew(allTypes, current[t], expiry + 30 days, 50);

            assertEq(_indexOf(renewed), slot, "replacement must take the old slot");
            assertEq(registry.getCredentials(did).length, TYPE_COUNT);
            assertEq(registry.getIssuerCredentialCount(did, allTypes), TYPE_COUNT);

            IDIDRegistry.Credential memory cred = registry.getCredential(renewed);
            assertEq(uint8(cred.attestationType), t, "same attestation type");
            assertEq(cred.did, did, "same DID");
            assertTrue(registry.getCredential(current[t]).revoked);
            assertFalse(registry.verifyCredential(current[t]));
            assertTrue(registry.verifyCredential(renewed));
            current[t] = renewed;
        }
        assertEq(registry.getActiveCredentialCount(did), TYPE_COUNT);
        assertEq(registry.getSybilScore(did), 100);

        // The old expiry passes: the renewed set is untouched
        vm.warp(expiry + 1);
        assertEq(registry.getActiveCredentialCount(did), TYPE_COUNT);
        assertEq(registry.getSybilScore(did), 100);
    }

    function test_IssuerAtItsLimitRenewsEveryCredentialEarly() public {
        uint256 expiry = block.timestamp + 1 days;
        bytes32[] memory ids = new bytes32[](perIssuer);
        for (uint256 i = 0; i < perIssuer; i++) {
            ids[i] = _issue(hiIssuer, expiry, 50);
        }
        bytes32 loCred = _issue(loIssuer, 0, 50);

        // All live: a fresh issuance cannot get a slot
        vm.prank(hiIssuer);
        vm.expectRevert(abi.encodeWithSelector(IDIDRegistry.IssuerCredentialLimit.selector, did, hiIssuer));
        registry.issueCredential(did, IDIDRegistry.AttestationType.Identity, bytes32(++claimNonce), 0, 50);

        // ...but each credential can be renewed before it expires, repeatedly
        for (uint256 round = 0; round < 3; round++) {
            for (uint256 i = 0; i < perIssuer; i++) {
                ids[i] = _renew(hiIssuer, ids[i], block.timestamp + 2 days, 50);
            }
            assertEq(registry.getIssuerCredentialCount(did, hiIssuer), perIssuer);
            assertEq(registry.getCredentials(did).length, perIssuer + 1);
            assertEq(registry.getActiveCredentialCount(did), perIssuer + 1);
            _assertCount(hiIssuer);
            _assertCount(loIssuer);
            vm.warp(block.timestamp + 1 days);
        }
        assertTrue(registry.verifyCredential(loCred));
        // (10 * 50 + 50 * 20 / 100) * 100 / 550 = 92
        assertEq(registry.getSybilScore(did), 92);
    }

    function test_RenewsInAFullDIDWithoutPruning() public {
        address[] memory issuers = new address[](cap / perIssuer);
        for (uint256 k = 0; k < issuers.length; k++) {
            issuers[k] = makeAddr(string(abi.encodePacked("issuer", vm.toString(k))));
            registry.addTrustedIssuer(issuers[k], "issuer", _identityTypes(), 100);
        }
        bytes32 target;
        for (uint256 i = 0; i < cap; i++) {
            bytes32 id = _issue(issuers[i / perIssuer], 0, 50);
            if (i == 17) target = id;
        }
        assertEq(registry.getCredentials(did).length, cap);

        vm.prank(hiIssuer);
        vm.expectRevert(abi.encodeWithSelector(IDIDRegistry.TooManyCredentials.selector, did));
        registry.issueCredential(did, IDIDRegistry.AttestationType.Identity, bytes32(++claimNonce), 0, 50);

        uint256 slot = _indexOf(target);
        bytes32 renewed = _renew(issuers[1], target, 0, 80);
        assertEq(_indexOf(renewed), slot);
        assertEq(registry.getCredentials(did).length, cap);
        assertEq(registry.getIssuerCredentialCount(did, issuers[1]), perIssuer);
        assertEq(registry.getCredential(renewed).weight, 80);
    }

    // ============ Expired credentials ============

    function test_RenewAfterExpiryReusesTheUnprunedSlot() public {
        uint256 expiry = block.timestamp + 1 days;
        bytes32 old = _issue(hiIssuer, expiry, 50);
        _issue(loIssuer, 0, 50);
        vm.warp(expiry + 1);
        assertEq(registry.getSybilScore(did), 20);

        uint256 slot = _indexOf(old);
        bytes32 renewed = _renew(hiIssuer, old, block.timestamp + 1 days, 50);
        assertEq(_indexOf(renewed), slot);
        assertEq(registry.getCredentials(did).length, 2);
        assertEq(registry.getIssuerCredentialCount(did, hiIssuer), 1);
        assertTrue(registry.getCredential(old).revoked);
        assertEq(registry.getSybilScore(did), 60);
    }

    function test_RenewAfterTheExpiredEntryWasPrunedTakesAFreshSlot() public {
        uint256 expiry = block.timestamp + 1 days;
        bytes32 old = _issue(hiIssuer, expiry, 50);
        _issue(loIssuer, 0, 50);
        vm.warp(expiry + 1);
        assertEq(registry.cleanupCredentials(did), 1); // anyone may prune it first
        assertEq(registry.getIssuerCredentialCount(did, hiIssuer), 0);

        bytes32 renewed = _renew(hiIssuer, old, 0, 50);
        assertEq(registry.getCredentials(did).length, 2);
        assertEq(registry.getIssuerCredentialCount(did, hiIssuer), 1);
        assertTrue(registry.getCredential(old).revoked);
        assertTrue(registry.verifyCredential(renewed));
        _assertCount(hiIssuer);
        assertEq(registry.getSybilScore(did), 60);
    }

    function test_PrunedRenewalStillObeysTheIssuerLimit() public {
        uint256 expiry = block.timestamp + 1 days;
        bytes32 old = _issue(hiIssuer, expiry, 50);
        vm.warp(expiry + 1);
        registry.cleanupCredentials(did);
        for (uint256 i = 0; i < perIssuer; i++) {
            _issue(hiIssuer, 0, 50);
        }

        // The old entry is gone, so the replacement needs a slot, and the issuer has none left
        _expectRenewRevert(
            hiIssuer, old, 0, abi.encodeWithSelector(IDIDRegistry.IssuerCredentialLimit.selector, did, hiIssuer)
        );
        assertFalse(registry.getCredential(old).revoked); // the revert undid the supersession
    }

    // ============ Events and recorded state ============

    function test_EmitsRevokeIssueAndSupersede() public {
        bytes32 old = _issue(hiIssuer, 0, 50);
        _issue(loIssuer, 0, 50);
        // (50 + 10) * 100 / 100 = 60
        assertEq(registry.getSybilScore(did), 60);
        uint256 totalBefore = registry.totalCredentials();

        vm.recordLogs();
        vm.prank(hiIssuer);
        bytes32 renewed = registry.renewCredential(old, bytes32(uint256(0xc1a1)), block.timestamp + 365 days, 150);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // CredentialRevoked(old, issuer, "superseded"), SybilScoreUpdated(60 -> 67), CredentialIssued, CredentialSuperseded
        assertEq(logs.length, 4);
        assertEq(logs[0].topics[0], CredentialRevoked.selector);
        assertEq(logs[0].topics[1], old);
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(hiIssuer))));
        assertEq(abi.decode(logs[0].data, (string)), "superseded");

        assertEq(logs[1].topics[0], SybilScoreUpdated.selector);
        (uint256 oldScore, uint256 newScore) = abi.decode(logs[1].data, (uint256, uint256));
        assertEq(oldScore, 60);
        // weight capped at 100: (100 + 10) * 100 / 150 = 73
        assertEq(newScore, 73);

        assertEq(logs[2].topics[0], CredentialIssued.selector);
        assertEq(logs[2].topics[1], renewed);
        assertEq(logs[2].topics[2], did);
        assertEq(logs[2].topics[3], bytes32(uint256(uint160(hiIssuer))));
        assertEq(abi.decode(logs[2].data, (uint8)), uint8(IDIDRegistry.AttestationType.Identity));

        assertEq(logs[3].topics[0], CredentialSuperseded.selector);
        assertEq(logs[3].topics[1], old);
        assertEq(logs[3].topics[2], renewed);
        assertEq(logs[3].topics[3], did);

        IDIDRegistry.Credential memory cred = registry.getCredential(renewed);
        assertEq(cred.credentialId, renewed);
        assertEq(cred.issuer, hiIssuer);
        assertEq(cred.claimHash, bytes32(uint256(0xc1a1)));
        assertEq(cred.issuedAt, block.timestamp);
        assertEq(cred.expiresAt, block.timestamp + 365 days);
        assertEq(cred.weight, 100);
        assertFalse(cred.revoked);
        assertTrue(renewed != old);
        assertEq(registry.totalCredentials(), totalBefore + 1);
        assertEq(registry.getDIDDocument(did).sybilScore, 73);
    }

    // ============ Who may renew, and when ============

    function test_OnlyTheIssuerRenewsALiveCredentialOfAnActiveDID() public {
        bytes32 cred = _issue(hiIssuer, 0, 50);
        bytes32 unknown = bytes32(uint256(0xdead));

        _expectRenewRevert(
            hiIssuer, unknown, 0, abi.encodeWithSelector(IDIDRegistry.CredentialNotFound.selector, unknown)
        );
        // Neither another trusted issuer nor the DID controller can supersede it
        _expectRenewRevert(
            loIssuer, cred, 0, abi.encodeWithSelector(IDIDRegistry.NotCredentialIssuer.selector, cred, loIssuer)
        );
        _expectRenewRevert(
            controller, cred, 0, abi.encodeWithSelector(IDIDRegistry.NotCredentialIssuer.selector, cred, controller)
        );
        // Expiry must be 0 or in the future
        _expectRenewRevert(
            hiIssuer,
            cred,
            block.timestamp,
            abi.encodeWithSelector(IDIDRegistry.ExpiryNotInFuture.selector, block.timestamp)
        );

        // A superseded credential cannot be renewed again (no second live replacement)
        bytes32 renewed = _renew(hiIssuer, cred, 0, 50);
        _expectRenewRevert(
            hiIssuer, cred, 0, abi.encodeWithSelector(IDIDRegistry.CredentialAlreadyRevoked.selector, cred)
        );

        // Nor can one the controller revoked
        vm.prank(controller);
        registry.revokeCredential(renewed, "unwanted");
        _expectRenewRevert(
            hiIssuer, renewed, 0, abi.encodeWithSelector(IDIDRegistry.CredentialAlreadyRevoked.selector, renewed)
        );
        assertEq(registry.getActiveCredentialCount(did), 0);
    }

    function test_RenewalNeedsAnActiveDID() public {
        bytes32 cred = _issue(hiIssuer, 0, 50);

        vm.prank(controller);
        registry.suspendDID(did, "pause");
        _expectRenewRevert(hiIssuer, cred, 0, abi.encodeWithSelector(IDIDRegistry.DIDNotActive.selector, did));

        vm.prank(controller);
        registry.reactivateDID(did);
        bytes32 renewed = _renew(hiIssuer, cred, 0, 50);

        vm.prank(controller);
        registry.revokeDID(did, "done");
        _expectRenewRevert(hiIssuer, renewed, 0, abi.encodeWithSelector(IDIDRegistry.DIDNotActive.selector, did));
        assertFalse(registry.getCredential(renewed).revoked);
    }

    function test_RenewalNeedsATrustedIssuerStillAllowedTheType() public {
        bytes32 identityCred = _issueType(allTypes, IDIDRegistry.AttestationType.Identity, 0, 50);
        bytes32 kycCred = _issueType(allTypes, IDIDRegistry.AttestationType.KYC, 0, 50);

        // KYC no longer allowed: that credential cannot be renewed, the Identity one still can
        registry.updateTrustedIssuer(allTypes, _identityTypes(), 100);
        _expectRenewRevert(
            allTypes,
            kycCred,
            0,
            abi.encodeWithSelector(
                IDIDRegistry.InvalidAttestationType.selector, allTypes, IDIDRegistry.AttestationType.KYC
            )
        );
        bytes32 renewed = _renew(allTypes, identityCred, 0, 50);

        // A removed issuer cannot renew at all
        registry.removeTrustedIssuer(allTypes);
        _expectRenewRevert(
            allTypes, renewed, 0, abi.encodeWithSelector(IDIDRegistry.NotTrustedIssuer.selector, allTypes)
        );
        assertFalse(registry.getCredential(renewed).revoked);
        assertFalse(registry.getCredential(kycCred).revoked);
    }

    function test_RenewalIsPausable() public {
        bytes32 cred = _issue(hiIssuer, 0, 50);
        registry.pause();
        _expectRenewRevert(hiIssuer, cred, 0, abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        registry.unpause();
        _renew(hiIssuer, cred, 0, 50);
    }

    // ============ Invariant over random renewal schedules ============

    /// @dev Random renew / warp / cleanup steps for one issuer at its limit: renewal never fails for want of a
    ///      slot, the count tracks the array, and the issuer never holds more than MAX_CREDENTIALS_PER_ISSUER.
    function testFuzz_RenewalNeverNeedsAnExtraSlot(uint256 seed) public {
        bytes32[] memory ids = new bytes32[](perIssuer);
        for (uint256 i = 0; i < perIssuer; i++) {
            ids[i] = _issue(hiIssuer, block.timestamp + 1 days + (i * 1 hours), 50);
        }
        for (uint256 step = 0; step < 40; step++) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            uint256 i = r % perIssuer;
            uint256 action = (r >> 8) % 4;
            if (action == 0) {
                vm.warp(block.timestamp + ((r >> 16) % 2 days));
            } else if (action == 1) {
                registry.cleanupCredentials(did);
            } else {
                ids[i] = _renew(hiIssuer, ids[i], block.timestamp + 1 + ((r >> 16) % 3 days), 50);
            }
            assertLe(registry.getIssuerCredentialCount(did, hiIssuer), perIssuer);
            _assertCount(hiIssuer);
            assertTrue(registry.getCredentials(did).length <= perIssuer);
        }
    }
}
