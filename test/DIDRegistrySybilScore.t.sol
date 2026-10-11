// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/modules/DIDRegistry.sol";

/**
 * @title DIDRegistrySybilScoreTest
 * @notice The sybil score must account for every valid credential regardless of its position in the
 *         DID's credential array, with bounded gas (the M-04 / L-02 caps must hold).
 * @dev The regression tests use only the pre-existing API (the new error's selector is derived from its
 *      signature), so this file compiles against the unfixed contract and the regression tests fail there.
 */
contract DIDRegistrySybilScoreTest is Test {
    bytes4 internal constant TOO_MANY_CREDENTIALS = bytes4(keccak256("TooManyCredentials(bytes32)"));

    /// @dev Generous bound so the unoptimized `forge coverage` build passes too; unbounded loops would blow it.
    uint256 internal constant GAS_BOUND = 3_000_000;

    // Redeclared locally: a qualified `emit IDIDRegistry.SybilScoreUpdated` needs solc >= 0.8.21.
    event SybilScoreUpdated(bytes32 indexed did, uint256 oldScore, uint256 newScore);

    DIDRegistry internal registry;

    address internal controller = makeAddr("controller");
    address internal hiIssuer = makeAddr("hiIssuer"); // trust 100
    address internal loIssuer = makeAddr("loIssuer"); // trust 20
    address internal midIssuer = makeAddr("midIssuer"); // trust 60

    bytes32 internal did;
    uint256 internal cap;
    uint256 internal claimNonce;

    function setUp() public {
        _deploy();
    }

    function _deploy() internal {
        registry = new DIDRegistry();
        registry.addTrustedIssuer(hiIssuer, "hi", _identityTypes(), 100);
        registry.addTrustedIssuer(loIssuer, "lo", _identityTypes(), 20);
        registry.addTrustedIssuer(midIssuer, "mid", _identityTypes(), 60);

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

    function _revoke(bytes32 credentialId) internal {
        vm.prank(controller);
        registry.revokeCredential(credentialId, "test");
    }

    /// @dev The contract's formula over the given credential ids, using live issuer state.
    function _scoreOf(bytes32[] memory ids) internal view returns (uint256) {
        uint256 weighted;
        uint256 total;
        for (uint256 i = 0; i < ids.length; i++) {
            IDIDRegistry.Credential memory c = registry.getCredential(ids[i]);
            if (c.revoked) continue;
            if (c.expiresAt != 0 && block.timestamp > c.expiresAt) continue;
            IDIDRegistry.TrustedIssuer memory ti = registry.getTrustedIssuer(c.issuer);
            if (!ti.active) continue;
            weighted += (c.weight * ti.trustLevel) / 100;
            total += c.weight;
        }
        if (total == 0) return 0;
        uint256 score = (weighted * 100) / total;
        return score > 100 ? 100 : score;
    }

    function _contains(bytes32[] memory ids, bytes32 id) internal pure returns (bool) {
        for (uint256 i = 0; i < ids.length; i++) {
            if (ids[i] == id) return true;
        }
        return false;
    }

    // ============ Regression: position must not matter (all fail on the unfixed contract) ============

    function test_RevokedCredentialsDoNotHideNewerValidOne() public {
        bytes32[] memory ids = new bytes32[](cap);
        for (uint256 i = 0; i < cap; i++) {
            ids[i] = _issue(hiIssuer, 0, 50);
        }
        for (uint256 i = 0; i < cap; i++) {
            _revoke(ids[i]);
        }
        assertEq(registry.getSybilScore(did), 0);

        vm.expectEmit(true, false, false, true, address(registry));
        emit SybilScoreUpdated(did, 0, 100);
        bytes32 valid = _issue(hiIssuer, 0, 50);

        assertEq(registry.getSybilScore(did), 100); // unfixed: 0
        bytes32[] memory stored = registry.getCredentials(did);
        assertEq(stored.length, 1);
        assertEq(stored[0], valid);
    }

    function test_ExpiredCredentialsDoNotHideNewerValidOne() public {
        uint256 expiry = block.timestamp + 1 days;
        for (uint256 i = 0; i < cap; i++) {
            _issue(hiIssuer, expiry, 50);
        }
        vm.warp(expiry + 1);

        _issue(hiIssuer, 0, 50);

        assertEq(registry.getSybilScore(did), 100); // unfixed: 0
        assertEq(registry.getCredentials(did).length, 1);
    }

    function test_ZeroWeightCredentialsDoNotHideNewerValidOne() public {
        bytes32[] memory ids = new bytes32[](cap);
        for (uint256 i = 0; i < cap; i++) {
            ids[i] = _issue(loIssuer, 0, 0);
        }
        // The controller makes room by revoking one zero-weight credential. On the unfixed contract
        // cleanupCredentials would only ever remove this one entry: zero-weight credentials are neither
        // revoked nor expired, so cleanup alone could never bring the new credential into the scored window.
        _revoke(ids[7]);

        _issue(hiIssuer, 0, 50);

        assertEq(registry.getSybilScore(did), 100); // unfixed: 0
        assertEq(registry.getCredentials(did).length, cap);
    }

    function test_ScoreIsWeightedAverageOverAllValidCredentials() public {
        bytes32[] memory ids = new bytes32[](cap);
        for (uint256 i = 0; i < cap; i++) {
            ids[i] = _issue(loIssuer, 0, 100);
        }
        for (uint256 i = 0; i < cap - 1; i++) {
            _revoke(ids[i]);
        }

        _issue(hiIssuer, 0, 100);

        // (100 * 20 / 100 + 100 * 100 / 100) * 100 / 200 = 60
        assertEq(registry.getSybilScore(did), 60); // unfixed: 20 (understated)
    }

    function test_LaterLowTrustCredentialIsNotIgnored() public {
        bytes32 first = _issue(hiIssuer, 0, 10);
        for (uint256 i = 1; i < cap; i++) {
            _issue(hiIssuer, 0, 10);
        }
        _revoke(first);

        _issue(loIssuer, 0, 100);

        // (49 * 10 * 100 / 100 + 100 * 20 / 100) * 100 / (490 + 100) = 51000 / 590 = 86
        assertEq(registry.getSybilScore(did), 86); // unfixed: 100 (overstated)
    }

    function test_HonestDailyRenewalKeepsScore() public {
        // An honest issuer renews a short-lived credential every day; the expired ones must never crowd it out.
        for (uint256 day = 0; day < 60; day++) {
            _issue(hiIssuer, block.timestamp + 1 days, 50);

            assertEq(registry.getSybilScore(did), 100); // unfixed: 0 from day 51
            assertLe(registry.getCredentials(did).length, cap);

            vm.warp(block.timestamp + 1 days + 1);
        }
    }

    // ============ Bounded credential array ============

    function test_IssueRevertsWhenFullOfLiveCredentials() public {
        for (uint256 i = 0; i < cap; i++) {
            _issue(loIssuer, 0, 0);
        }
        bytes32[] memory before = registry.getCredentials(did);
        uint256 scoreBefore = registry.getSybilScore(did);

        vm.prank(hiIssuer);
        vm.expectRevert(abi.encodeWithSelector(TOO_MANY_CREDENTIALS, did));
        registry.issueCredential(did, IDIDRegistry.AttestationType.Identity, bytes32(uint256(0xbeef)), 0, 50);

        bytes32[] memory afterIds = registry.getCredentials(did);
        assertEq(afterIds.length, cap);
        assertEq(keccak256(abi.encode(afterIds)), keccak256(abi.encode(before)));
        assertEq(registry.getSybilScore(did), scoreBefore);
    }

    function test_RemovedIssuerCredentialsCanBeRevokedToMakeRoom() public {
        bytes32[] memory ids = new bytes32[](cap);
        for (uint256 i = 0; i < cap; i++) {
            ids[i] = _issue(loIssuer, 0, 50);
        }
        assertEq(registry.getSybilScore(did), 20);

        registry.removeTrustedIssuer(loIssuer);
        assertEq(registry.calculateSybilScore(did), 0);

        vm.prank(hiIssuer);
        vm.expectRevert(abi.encodeWithSelector(TOO_MANY_CREDENTIALS, did));
        registry.issueCredential(did, IDIDRegistry.AttestationType.Identity, bytes32(uint256(0xbeef)), 0, 50);

        // The controller revokes one removed-issuer credential to make room
        _revoke(ids[0]);
        bytes32 hiCred = _issue(hiIssuer, 0, 50);
        assertEq(registry.getSybilScore(did), 100);
        assertEq(registry.getCredentials(did).length, cap);

        // Pruning never removed the inactive-issuer credentials: re-adding the issuer restores their contribution
        registry.addTrustedIssuer(loIssuer, "lo", _identityTypes(), 20);
        // (49 * (50 * 20 / 100) + 50 * 100 / 100) * 100 / (50 * 50) = 54000 / 2500 = 21
        assertEq(registry.calculateSybilScore(did), 21);
        bytes32[] memory stored = registry.getCredentials(did);
        assertEq(stored.length, cap);
        assertTrue(_contains(stored, hiCred));
        for (uint256 i = 1; i < cap; i++) {
            assertTrue(_contains(stored, ids[i]));
        }
    }

    function test_IssueAtCapPrunesOnlyRevokedAndExpired() public {
        uint256 expiry = block.timestamp + 1 days;
        bytes32[] memory ids = new bytes32[](cap);
        for (uint256 i = 0; i < cap; i++) {
            ids[i] = _issue(i % 5 == 0 ? loIssuer : hiIssuer, i % 5 == 1 ? expiry : 0, 50);
        }
        for (uint256 i = 0; i < cap; i += 5) {
            _revoke(ids[i]); // 10 revoked
        }
        vm.warp(expiry + 1); // 10 expired

        bytes32 newCred = _issue(midIssuer, 0, 50);

        bytes32[] memory stored = registry.getCredentials(did);
        assertEq(stored.length, cap - 20 + 1);
        for (uint256 i = 0; i < stored.length; i++) {
            assertTrue(registry.verifyCredential(stored[i]));
        }
        // Exactly the 30 live credentials and the new one survive
        for (uint256 i = 0; i < cap; i++) {
            assertEq(_contains(stored, ids[i]), i % 5 > 1);
        }
        assertTrue(_contains(stored, newCred));
        assertEq(registry.getActiveCredentialCount(did), 31);
        assertEq(registry.cleanupCredentials(did), 0);

        uint256 expected = _scoreOf(stored);
        // (30 * 50 + 50 * 60 / 100) * 100 / (31 * 50) = 153000 / 1550 = 98
        assertEq(expected, 98);
        assertEq(registry.getSybilScore(did), expected);
    }

    function test_CleanupStillWorksAndIsBounded() public {
        uint256 expiry = block.timestamp + 1 days;
        for (uint256 i = 0; i < 20; i++) {
            _issue(hiIssuer, expiry, 100);
        }
        bytes32[] memory lo = new bytes32[](20);
        for (uint256 i = 0; i < 20; i++) {
            lo[i] = _issue(loIssuer, 0, 100);
        }
        for (uint256 i = 0; i < 10; i++) {
            _issue(midIssuer, 0, 100);
        }
        for (uint256 i = 0; i < 20; i += 2) {
            _revoke(lo[i]); // 10 revoked
        }
        assertEq(registry.getCredentials(did).length, cap);
        // (20 * 100 + 10 * 20 + 10 * 60) * 100 / 4000 = 70
        assertEq(registry.getSybilScore(did), 70);

        vm.warp(expiry + 1); // 20 expired; the cached score is stale until recomputed
        assertEq(registry.getSybilScore(did), 70);

        registry.pause();

        // Permissionless, works while paused, and recomputes the score: (10 * 20 + 10 * 60) * 100 / 2000 = 40
        address anyone = makeAddr("anyone");
        vm.expectEmit(true, false, false, true, address(registry));
        emit SybilScoreUpdated(did, 70, 40);
        vm.prank(anyone);
        uint256 gasBefore = gasleft();
        uint256 removed = registry.cleanupCredentials(did);
        uint256 cleanupGas = gasBefore - gasleft();

        assertEq(removed, 30);
        assertLt(cleanupGas, GAS_BOUND);
        assertEq(registry.getCredentials(did).length, 20);
        assertEq(registry.getActiveCredentialCount(did), 20);
        assertEq(registry.getSybilScore(did), 40);

        vm.prank(anyone);
        assertEq(registry.cleanupCredentials(did), 0);
    }

    function test_PausedIssuanceDoesNotPrune() public {
        bytes32[] memory ids = new bytes32[](cap);
        for (uint256 i = 0; i < cap; i++) {
            ids[i] = _issue(hiIssuer, 0, 50);
        }
        for (uint256 i = 0; i < 5; i++) {
            _revoke(ids[i]);
        }

        registry.pause();

        vm.prank(hiIssuer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        registry.issueCredential(did, IDIDRegistry.AttestationType.Identity, bytes32(uint256(0xbeef)), 0, 50);
        assertEq(registry.getCredentials(did).length, cap);

        // Revocation and cleanup keep working while paused
        _revoke(ids[5]);
        assertTrue(!registry.verifyCredential(ids[5]));
        assertEq(registry.cleanupCredentials(did), 6);
        assertEq(registry.getCredentials(did).length, cap - 6);
    }

    function test_GasStaysBoundedWithDistinctIssuers() public {
        address[] memory issuers = new address[](cap + 1);
        for (uint256 i = 0; i <= cap; i++) {
            issuers[i] = address(uint160(0x10000 + i));
            registry.addTrustedIssuer(issuers[i], "i", _identityTypes(), 10 + i);
        }
        bytes32 first = _issue(issuers[0], 0, 50);
        for (uint256 i = 1; i < cap; i++) {
            _issue(issuers[i], 0, 50);
        }
        _revoke(first); // 49 live + 1 revoked: issuance at the cap must prune

        vm.cool(address(registry));
        uint256 gasBefore = gasleft();
        _issue(issuers[cap], 0, 50);
        uint256 issueGas = gasBefore - gasleft();

        vm.cool(address(registry));
        gasBefore = gasleft();
        registry.calculateSybilScore(did);
        uint256 scoreGas = gasBefore - gasleft();

        vm.cool(address(registry));
        gasBefore = gasleft();
        registry.cleanupCredentials(did);
        uint256 cleanupGas = gasBefore - gasleft();

        assertEq(registry.getCredentials(did).length, cap);
        assertLt(issueGas, GAS_BOUND);
        assertLt(scoreGas, GAS_BOUND);
        assertLt(cleanupGas, GAS_BOUND);
    }

    // ============ Reference model: score over every credential ever issued ============

    struct ModelCred {
        bytes32 id;
        address issuer;
        uint256 weight;
        uint256 expiresAt;
        bool revoked;
    }

    uint256 internal modelCapReverts;
    uint256 internal modelPrunedIssues;

    /// @dev Deterministic (not fuzzed) so CI's --fuzz-runs 10000 does not multiply its cost.
    function test_ScoreMatchesReferenceModel() public {
        uint256[4] memory seeds = [uint256(1), 7, 2024, 31_337];
        for (uint256 s = 0; s < seeds.length; s++) {
            _deploy();
            _runModel(seeds[s], 160);
        }
        // Both full-array paths were exercised
        assertGt(modelCapReverts, 0);
        assertGt(modelPrunedIssues, 0);
    }

    function _runModel(uint256 seed, uint256 steps) internal {
        ModelCred[] memory creds = new ModelCred[](steps);
        uint256 n;
        address[3] memory issuers = [hiIssuer, loIssuer, midIssuer];
        uint256[4] memory weights = [uint256(0), 1, 50, 100];

        for (uint256 step = 0; step < steps; step++) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            uint256 op = r % 10;

            if (op < 7) {
                address issuer = issuers[(r >> 8) % 3];
                if (!registry.isTrustedIssuer(issuer)) issuer = hiIssuer; // hi is never removed
                uint256 wsel = (r >> 16) % 5;
                uint256 weight = wsel < 4 ? weights[wsel] : (r >> 48) % 101;
                uint256 expiresAt = (r >> 24) % 3 == 0 ? block.timestamp + 100 + ((r >> 32) % 500) : 0;
                uint256 heldBefore = registry.getCredentials(did).length;

                vm.prank(issuer);
                try registry.issueCredential(
                    did, IDIDRegistry.AttestationType.Identity, bytes32(++claimNonce), expiresAt, weight
                ) returns (
                    bytes32 id
                ) {
                    creds[n++] = ModelCred(id, issuer, weight, expiresAt, false);
                    if (heldBefore == cap) modelPrunedIssues++;
                } catch (bytes memory reason) {
                    // Only rejected when the array is full and no held credential is revoked or expired
                    assertEq(bytes4(reason), TOO_MANY_CREDENTIALS);
                    assertEq(heldBefore, cap);
                    assertEq(registry.getCredentials(did).length, cap);
                    assertEq(registry.getActiveCredentialCount(did), cap);
                    modelCapReverts++;
                    _revokeRandom(creds, n, r >> 40);
                }
            } else if (op < 8) {
                _revokeRandom(creds, n, r >> 40);
            } else if (op < 9) {
                vm.warp(block.timestamp + 50 + ((r >> 8) % 300));
            } else {
                address issuer = issuers[1 + (r >> 8) % 2];
                if (registry.isTrustedIssuer(issuer)) {
                    registry.removeTrustedIssuer(issuer);
                } else {
                    registry.addTrustedIssuer(issuer, "re", _identityTypes(), issuer == loIssuer ? 20 : 60);
                }
            }

            assertEq(registry.calculateSybilScore(did), _referenceScore(creds, n));
            assertLe(registry.getCredentials(did).length, cap);
        }
    }

    function _revokeRandom(ModelCred[] memory creds, uint256 n, uint256 r) internal {
        uint256 live;
        for (uint256 i = 0; i < n; i++) {
            if (!creds[i].revoked) live++;
        }
        if (live == 0) return;
        uint256 pick = r % live;
        for (uint256 i = 0; i < n; i++) {
            if (creds[i].revoked) continue;
            if (pick == 0) {
                _revoke(creds[i].id);
                creds[i].revoked = true;
                return;
            }
            pick--;
        }
    }

    /// @dev Contract formula over every credential ever issued: per-credential floor of w * t / 100,
    ///      then * 100 / sum(w), capped at 100.
    function _referenceScore(ModelCred[] memory creds, uint256 n) internal view returns (uint256) {
        uint256 weighted;
        uint256 total;
        for (uint256 i = 0; i < n; i++) {
            ModelCred memory c = creds[i];
            if (c.revoked) continue;
            if (c.expiresAt != 0 && block.timestamp > c.expiresAt) continue;
            if (!registry.isTrustedIssuer(c.issuer)) continue;
            weighted += (c.weight * registry.getTrustedIssuer(c.issuer).trustLevel) / 100;
            total += c.weight;
        }
        if (total == 0) return 0;
        uint256 score = (weighted * 100) / total;
        return score > 100 ? 100 : score;
    }
}
