// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/modules/DIDRegistry.sol";

/**
 * @title DIDRegistryHardeningTest
 * @notice Follow-ups to the M-04 credential cap:
 *         - one trusted issuer must not be able to fill a DID it does not control (per-issuer limit);
 *         - the sybil score views must be live: credential expiry and issuer removal / trust changes count at
 *           once, with no recompute transaction;
 *         - a credential that is already expired cannot be issued;
 *         - revert precedence when the credential array is full.
 * @dev Uses only the pre-existing API (new errors are matched by selectors derived from their signatures), so
 *      this file compiles against the unfixed contract, where the regression tests fail.
 */
contract DIDRegistryHardeningTest is Test {
    bytes4 internal constant TOO_MANY_CREDENTIALS = bytes4(keccak256("TooManyCredentials(bytes32)"));
    bytes4 internal constant ISSUER_CREDENTIAL_LIMIT = bytes4(keccak256("IssuerCredentialLimit(bytes32,address)"));
    bytes4 internal constant EXPIRY_NOT_IN_FUTURE = bytes4(keccak256("ExpiryNotInFuture(uint256)"));

    /// @dev MAX_CREDENTIALS_PER_ISSUER (literal: the unfixed contract has no such constant)
    uint256 internal constant PER_ISSUER = 10;

    /// @dev Generous bound for one cold live-score view over a full array (also holds unoptimized)
    uint256 internal constant VIEW_GAS_BOUND = 1_500_000;

    // Redeclared locally: a qualified `emit IDIDRegistry.SybilScoreUpdated` needs solc >= 0.8.21.
    event SybilScoreUpdated(bytes32 indexed did, uint256 oldScore, uint256 newScore);

    DIDRegistry internal registry;

    address internal controller = makeAddr("controller");
    address internal griefer = makeAddr("griefer"); // trusted, trust 1
    address internal hiIssuer = makeAddr("hiIssuer"); // trust 100
    address internal loIssuer = makeAddr("loIssuer"); // trust 20
    address[] internal honest; // four more trust-100 issuers

    bytes32 internal did;
    uint256 internal cap;
    uint256 internal claimNonce;

    function setUp() public {
        vm.warp(1_700_000_000);
        registry = new DIDRegistry();
        registry.addTrustedIssuer(griefer, "griefer", _identityTypes(), 1);
        registry.addTrustedIssuer(hiIssuer, "hi", _identityTypes(), 100);
        registry.addTrustedIssuer(loIssuer, "lo", _identityTypes(), 20);
        for (uint256 i = 0; i < 4; i++) {
            honest.push(makeAddr(string(abi.encodePacked("honest", vm.toString(i)))));
            registry.addTrustedIssuer(honest[i], "honest", _identityTypes(), 100);
        }

        vm.prank(controller);
        did = registry.registerDID(bytes32(uint256(0xd1d)));
        cap = registry.MAX_CREDENTIALS_FOR_SCORE();
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

    function _expectIssueRevert(address issuer, bytes32 target, uint256 expiresAt, bytes memory reason) internal {
        vm.prank(issuer);
        vm.expectRevert(reason);
        registry.issueCredential(target, IDIDRegistry.AttestationType.Identity, bytes32(++claimNonce), expiresAt, 50);
    }

    /// @dev Fill the DID with live credentials: PER_ISSUER each from the four honest issuers and hiIssuer
    function _fill() internal {
        for (uint256 i = 0; i < cap; i++) {
            _issue(i < 40 ? honest[i / PER_ISSUER] : hiIssuer, 0, 50);
        }
        assertEq(registry.getCredentials(did).length, cap);
    }

    // ============ (1) One issuer cannot fill a DID it does not control ============

    function test_OneIssuerCannotLockOutHonestIssuers() public {
        // A trust-1 issuer tries to fill the victim's DID with perpetual zero-weight credentials
        uint256 issued;
        for (uint256 i = 0; i < cap; i++) {
            vm.prank(griefer);
            try registry.issueCredential(did, IDIDRegistry.AttestationType.Identity, bytes32(++claimNonce), 0, 0) {
                issued++;
            } catch (bytes memory reason) {
                assertEq(reason, abi.encodeWithSelector(ISSUER_CREDENTIAL_LIMIT, did, griefer));
                break;
            }
        }
        assertEq(issued, PER_ISSUER); // unfixed: 50, the whole array
        assertEq(registry.getCredentials(did).length, PER_ISSUER);

        // An honest issuer can still issue, and the zero-weight spam does not dilute its credential
        _issue(hiIssuer, 0, 50); // unfixed: reverts TooManyCredentials
        assertEq(registry.getSybilScore(did), 100);
        assertTrue(registry.meetsSybilRequirement(did, registry.minSybilScore()));
    }

    function test_FillingADIDTakesFiveIssuers() public {
        // Low weight instead of zero weight: still capped per issuer
        for (uint256 i = 0; i < PER_ISSUER; i++) {
            _issue(griefer, 0, 1);
        }
        _expectIssueRevert(griefer, did, 0, abi.encodeWithSelector(ISSUER_CREDENTIAL_LIMIT, did, griefer));

        // Four more issuers at their limit fill the rest
        for (uint256 i = 0; i < 40; i++) {
            _issue(honest[i / PER_ISSUER], 0, 100);
        }
        assertEq(registry.getCredentials(did).length, cap);
        // A sixth issuer now meets the DID limit, not its own
        _expectIssueRevert(hiIssuer, did, 0, abi.encodeWithSelector(TOO_MANY_CREDENTIALS, did));

        // Removing the griefer stops further issuance and its credentials stop counting, but keep their slots
        uint256 diluted = registry.getSybilScore(did);
        registry.removeTrustedIssuer(griefer);
        assertGt(registry.getSybilScore(did), diluted);
        assertEq(registry.getSybilScore(did), 100);
        _expectIssueRevert(griefer, did, 0, abi.encodeWithSelector(IDIDRegistry.NotTrustedIssuer.selector, griefer));
        assertEq(registry.getCredentials(did).length, cap);
    }

    function test_IssuerLimitIsPerDID() public {
        for (uint256 i = 0; i < PER_ISSUER; i++) {
            _issue(griefer, 0, 0);
        }
        // The same issuer can still issue to another DID
        address other = makeAddr("otherController");
        vm.prank(other);
        bytes32 otherDid = registry.registerDID(bytes32(uint256(0xbeef)));
        vm.prank(griefer);
        registry.issueCredential(otherDid, IDIDRegistry.AttestationType.Identity, bytes32(++claimNonce), 0, 0);
        assertEq(registry.getCredentials(otherDid).length, 1);
    }

    // ============ (2) Live sybil score ============

    function test_ScoreDropsWhenCredentialExpiresWithoutAnyTransaction() public {
        uint256 expiry = block.timestamp + 1 days;
        _issue(hiIssuer, expiry, 50);
        _issue(loIssuer, 0, 50);
        // (50 * 100 / 100 + 50 * 20 / 100) * 100 / 100 = 60
        assertEq(registry.getSybilScore(did), 60);
        assertTrue(registry.meetsSybilRequirement(did, 50));

        vm.warp(expiry); // still valid at expiresAt
        assertEq(registry.getSybilScore(did), 60);

        vm.warp(expiry + 1);
        assertEq(registry.getSybilScore(did), 20); // unfixed: 60
        assertFalse(registry.meetsSybilRequirement(did, 50)); // unfixed: true
        assertTrue(registry.meetsSybilRequirement(did, 20));
        assertEq(registry.getDIDDocument(did).sybilScore, 20); // unfixed: 60
        assertEq(registry.getDIDByController(controller).sybilScore, 20); // unfixed: 60
    }

    function test_ScoreDropsWhenIssuerRemoved() public {
        _issue(hiIssuer, 0, 100);
        assertEq(registry.getSybilScore(did), 100);

        registry.removeTrustedIssuer(hiIssuer);

        assertEq(registry.getSybilScore(did), 0); // unfixed: 100
        assertFalse(registry.meetsSybilRequirement(did, registry.minSybilScore())); // unfixed: true
        assertEq(registry.getDIDDocument(did).sybilScore, 0); // unfixed: 100

        // Re-adding the issuer with another trust level counts at once, at the new level
        registry.addTrustedIssuer(hiIssuer, "hi", _identityTypes(), 70);
        assertEq(registry.getSybilScore(did), 70); // unfixed: 100
    }

    function test_ScoreFollowsIssuerTrustUpdates() public {
        _issue(hiIssuer, 0, 100);
        _issue(loIssuer, 0, 100);
        assertEq(registry.getSybilScore(did), 60); // (100 + 20) / 2

        // Lowered trust must not leave an inflated score behind
        registry.updateTrustedIssuer(hiIssuer, _identityTypes(), 10);
        assertEq(registry.getSybilScore(did), 15); // unfixed: 60
        assertFalse(registry.meetsSybilRequirement(did, registry.minSybilScore())); // unfixed: true

        // Raised trust counts at once too
        registry.updateTrustedIssuer(loIssuer, _identityTypes(), 90);
        assertEq(registry.getSybilScore(did), 50); // unfixed: 60
        assertEq(registry.getDIDByController(controller).sybilScore, 50);
    }

    function test_MeetsSybilRequirementStillGatesOnStatus() public {
        _issue(hiIssuer, 0, 100);
        assertTrue(registry.meetsSybilRequirement(did, 100));
        assertFalse(registry.meetsSybilRequirement(did, 101));
        assertFalse(registry.meetsSybilRequirement(bytes32(uint256(0xdead)), 0));

        vm.prank(controller);
        registry.suspendDID(did, "test");
        assertFalse(registry.meetsSybilRequirement(did, 0));
        assertEq(registry.getSybilScore(did), 100); // the score itself does not depend on status
    }

    function test_CalculateSybilScoreRecordsTheLiveScore() public {
        uint256 expiry = block.timestamp + 1 days;
        _issue(hiIssuer, expiry, 50);
        _issue(loIssuer, 0, 50);
        vm.warp(expiry + 1);

        // The views are already live; calculateSybilScore records the value and emits the change
        vm.expectEmit(true, false, false, true, address(registry));
        emit SybilScoreUpdated(did, 60, 20);
        assertEq(registry.calculateSybilScore(did), 20);
        assertEq(registry.getSybilScore(did), 20);

        // No change, no event
        vm.recordLogs();
        registry.calculateSybilScore(did);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_LiveScoreViewsAreBounded() public {
        // Worst case: a full array of credentials from 50 distinct issuers, all cold
        address[] memory issuers = new address[](cap);
        for (uint256 i = 0; i < cap; i++) {
            issuers[i] = makeAddr(string(abi.encodePacked("viewIssuer", vm.toString(i))));
            registry.addTrustedIssuer(issuers[i], "i", _identityTypes(), 10 + i);
            _issue(issuers[i], block.timestamp + 1 days + i, 50);
        }
        vm.warp(block.timestamp + 1 days + 25); // about half have expired

        vm.cool(address(registry));
        uint256 gasBefore = gasleft();
        uint256 score = registry.getSybilScore(did);
        uint256 scoreGas = gasBefore - gasleft();

        vm.cool(address(registry));
        gasBefore = gasleft();
        registry.meetsSybilRequirement(did, 20);
        uint256 meetsGas = gasBefore - gasleft();

        vm.cool(address(registry));
        gasBefore = gasleft();
        IDIDRegistry.DIDDocument memory doc = registry.getDIDDocument(did);
        uint256 docGas = gasBefore - gasleft();

        emit log_named_uint("getSybilScore gas (cold, 50 issuers)", scoreGas);
        emit log_named_uint("meetsSybilRequirement gas", meetsGas);
        emit log_named_uint("getDIDDocument gas", docGas);
        assertEq(doc.sybilScore, score);
        assertGt(score, 0);
        assertLt(scoreGas, VIEW_GAS_BOUND);
        assertLt(meetsGas, VIEW_GAS_BOUND);
        assertLt(docGas, VIEW_GAS_BOUND);
    }

    // ============ (3) Already-expired credentials are rejected ============

    function test_RejectsCredentialThatIsAlreadyExpired() public {
        uint256 total = registry.totalCredentials();

        _expectIssueRevert(
            hiIssuer, did, block.timestamp - 1, abi.encodeWithSelector(EXPIRY_NOT_IN_FUTURE, block.timestamp - 1)
        ); // unfixed: issued
        _expectIssueRevert(hiIssuer, did, 1, abi.encodeWithSelector(EXPIRY_NOT_IN_FUTURE, 1));
        // Expiring this very second would be dead on arrival from the next block on
        _expectIssueRevert(
            hiIssuer, did, block.timestamp, abi.encodeWithSelector(EXPIRY_NOT_IN_FUTURE, block.timestamp)
        );
        assertEq(registry.getCredentials(did).length, 0);
        assertEq(registry.totalCredentials(), total);

        // Future expiry and "never" are fine
        bytes32 soon = _issue(hiIssuer, block.timestamp + 1, 50);
        bytes32 never = _issue(hiIssuer, 0, 50);
        assertTrue(registry.verifyCredential(soon));
        assertTrue(registry.verifyCredential(never));
        assertEq(registry.getCredentials(did).length, 2);
    }

    // ============ (4) Revert precedence when the array is full ============

    function test_RevertPrecedenceWhenArrayIsFull() public {
        _fill();
        bytes32 snapshot = keccak256(abi.encode(registry.getCredentials(did)));
        uint256 total = registry.totalCredentials();
        address stranger = makeAddr("stranger");
        uint256 past = block.timestamp - 1;

        // An issuer without the KYC type, and a DID made inactive: every later check fails too
        vm.prank(controller);
        registry.suspendDID(did, "precedence");

        // 0. Paused beats everything
        registry.pause();
        _expectIssueRevert(stranger, did, past, abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        registry.unpause();

        // 1. Untrusted issuer (type, DID status, expiry, issuer limit and DID limit would all fail too)
        _expectIssueRevert(
            stranger, did, past, abi.encodeWithSelector(IDIDRegistry.NotTrustedIssuer.selector, stranger)
        );

        // 2. Trusted issuer, attestation type it may not issue
        vm.prank(hiIssuer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDIDRegistry.InvalidAttestationType.selector, hiIssuer, IDIDRegistry.AttestationType.KYC
            )
        );
        registry.issueCredential(did, IDIDRegistry.AttestationType.KYC, bytes32(++claimNonce), past, 50);

        // 3. Allowed type, inactive DID (hiIssuer is also at its limit and the array is full)
        _expectIssueRevert(hiIssuer, did, past, abi.encodeWithSelector(IDIDRegistry.DIDNotActive.selector, did));
        // ... or an unknown DID
        bytes32 unknown = bytes32(uint256(0xdead));
        _expectIssueRevert(hiIssuer, unknown, past, abi.encodeWithSelector(IDIDRegistry.DIDNotFound.selector, unknown));

        vm.prank(controller);
        registry.reactivateDID(did);

        // 4. Active DID, expiry already passed
        _expectIssueRevert(hiIssuer, did, past, abi.encodeWithSelector(EXPIRY_NOT_IN_FUTURE, past));

        // 5. Valid credential, issuer at its own limit: reported before the DID limit
        _expectIssueRevert(hiIssuer, did, 0, abi.encodeWithSelector(ISSUER_CREDENTIAL_LIMIT, did, hiIssuer));

        // 6. Valid credential from an issuer with room: the DID limit
        _expectIssueRevert(loIssuer, did, 0, abi.encodeWithSelector(TOO_MANY_CREDENTIALS, did));

        // No rejected call changed anything
        assertEq(keccak256(abi.encode(registry.getCredentials(did))), snapshot);
        assertEq(registry.totalCredentials(), total);
        assertEq(registry.getSybilScore(did), 100);
    }

    // ============ suspendDID state allowlist (slither incorrect-equality rewrite) ============

    function test_SuspendAllowsActiveAndSuspendedOnly() public {
        vm.startPrank(controller);
        registry.suspendDID(did, "once");
        assertEq(uint256(registry.getDIDDocument(did).status), uint256(IDIDRegistry.DIDStatus.Suspended));
        // Re-suspending is allowed, as before
        registry.suspendDID(did, "twice");
        assertEq(uint256(registry.getDIDDocument(did).status), uint256(IDIDRegistry.DIDStatus.Suspended));

        registry.revokeDID(did, "gone");
        vm.expectRevert(abi.encodeWithSelector(IDIDRegistry.DIDNotActive.selector, did));
        registry.suspendDID(did, "after revoke");
        vm.stopPrank();
        assertEq(uint256(registry.getDIDDocument(did).status), uint256(IDIDRegistry.DIDStatus.Revoked));
    }
}
