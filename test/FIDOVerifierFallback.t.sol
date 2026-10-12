// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/modules/FIDOVerifier.sol";

/// @dev Exposes the internal modular inverse
contract FIDOVerifierHarness is FIDOVerifier {
    constructor() FIDOVerifier("natlangchain.io") {}

    function modInverse(uint256 a, uint256 m) external pure returns (uint256) {
        return _modInverse(a, m);
    }
}

/**
 * @title FIDOVerifierFallbackTest
 * @notice The pure-Solidity P-256 fallback must work: _modInverse used signed Bezout coefficients, which overflow
 *         int256 for both P-256 moduli (> 2^255), so inversion reverted for almost every input and fallback
 *         verification reverted in practice. Also pins the unambiguous generateChallenge encoding.
 * @dev Uses only the pre-existing API, so this file compiles against the unfixed contract, where the regression
 *      tests fail.
 */
contract FIDOVerifierFallbackTest is Test {
    uint256 internal constant N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551;
    uint256 internal constant P = 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF;

    FIDOVerifierHarness internal verifier;

    struct Vector {
        bytes32 hash;
        bytes32 r;
        bytes32 s;
        bytes32 x;
        bytes32 y;
    }

    function setUp() public {
        verifier = new FIDOVerifierHarness();
        // Force the pure-Solidity path even where a P256VERIFY precompile exists
        verifier.setPrecompileAvailable(false);
    }

    /// @dev The constructor's precompile-probe vector (generated and verified with @noble/curves)
    function _probeVector() internal pure returns (Vector memory) {
        return Vector({
            hash: 0x6db63153beccdf2eea6fc735bfcc6b786c70f71d4702fd9a1e1edbcd4b1bd720,
            r: 0xcb625de23fe666a5a6958d57a21b2f39ede272cb99314e4cb9df19459574aa64,
            s: 0x467165dead78a280aa20a20071a36a3feaf6ac1539703dc29635464033ef1ef3,
            x: 0x0280bdc8e5eef0f3b10436ea18b10553c17872bf98f4f3e1ade5ee0f3c67099a,
            y: 0xf63eeeed2fbae9096a680f4da72a8f1554a852477f30bc4086216c1ac965ce9a
        });
    }

    /// @dev Second independent vector from @noble/curves p256.sign (key and message: sha256 of fixed strings)
    function _nobleVector() internal pure returns (Vector memory) {
        return Vector({
            hash: 0x9d1e32a08b5ce480cac3c9acecb5552236811bf927fdab828251bc1296c19771,
            r: 0x775181f2694bef1664784c3fee4ccfea76bf522068004e340fc7f012daeb4d92,
            s: 0x3f05194c55aa288116480449d2911ba1aba96b44641f7a6b8594768f91497221,
            x: 0x4a69c9ca7f0d0196557ef1dfd5ff09763d72a85db71eda7a927878608d8ee61d,
            y: 0x1bf2530ed6e1de65793608594bfdeecf8db23168fb35404b97608c8898bc4517
        });
    }

    function _verify(Vector memory v) internal view returns (bool) {
        return verifier.verifyP256Signature(v.hash, v.r, v.s, v.x, v.y);
    }

    // ============ _modInverse ============

    function test_ModInverseEdgeCases() public view {
        uint256[2] memory moduli = [N, P];
        for (uint256 i = 0; i < 2; i++) {
            uint256 m = moduli[i];
            assertEq(verifier.modInverse(0, m), 0); // documented: no inverse, returns 0
            assertEq(verifier.modInverse(1, m), 1);
            assertEq(verifier.modInverse(m - 1, m), m - 1); // (-1)^-1 == -1
            assertEq(verifier.modInverse(2, m), (m + 1) / 2); // unfixed: reverts (int256 overflow)
            assertEq(mulmod(verifier.modInverse(m - 2, m), m - 2, m), 1);
        }
    }

    function testFuzz_ModInverseModN(uint256 a) public view {
        a = bound(a, 1, N - 1);
        uint256 inv = verifier.modInverse(a, N);
        assertLt(inv, N);
        assertEq(mulmod(inv, a, N), 1);
    }

    function testFuzz_ModInverseModP(uint256 a) public view {
        a = bound(a, 1, P - 1);
        uint256 inv = verifier.modInverse(a, P);
        assertLt(inv, P);
        assertEq(mulmod(inv, a, P), 1);
    }

    // ============ Pure-Solidity verification ============

    function test_PureFallbackVerifiesValidSignatures() public view {
        assertFalse(verifier.precompileAvailable());
        assertTrue(_verify(_probeVector())); // unfixed: reverts
        assertTrue(_verify(_nobleVector())); // unfixed: reverts
    }

    function test_PureFallbackAcceptsHighSFormOfValidSignature() public view {
        // (r, n - s) is the malleated twin; verifyP256Signature normalizes it to low-s first
        Vector memory v = _nobleVector();
        v.s = bytes32(N - uint256(v.s));
        assertTrue(_verify(v));
    }

    function test_PureFallbackRejectsInvalidSignatures() public view {
        Vector memory v = _nobleVector();
        v.hash = bytes32(uint256(v.hash) ^ 1);
        assertFalse(_verify(v)); // wrong message

        v = _nobleVector();
        v.r = bytes32(uint256(v.r) + 1);
        assertFalse(_verify(v)); // wrong r

        // A valid signature checked against another valid key
        v = _nobleVector();
        Vector memory other = _probeVector();
        v.x = other.x;
        v.y = other.y;
        assertFalse(_verify(v));
    }

    // ============ generateChallenge encoding ============

    function test_ChallengeSeparatesActionFromData() public {
        uint256 snap = vm.snapshotState();
        (bytes32 split1,) = verifier.generateChallenge("accept-proposal", hex"01");
        vm.revertToState(snap);
        // Same sender, nonce, timestamp and chain; the boundary between action and data moved by one byte
        (bytes32 split2,) = verifier.generateChallenge("accept-proposa", abi.encodePacked("l", hex"01"));

        assertTrue(split1 != split2); // unfixed: equal (abi.encodePacked collision)
        assertEq(
            split1,
            keccak256(abi.encode(address(this), "accept-proposal", hex"01", uint256(0), block.timestamp, block.chainid))
        );
    }

    function test_ChallengeNonceAdvances() public {
        (bytes32 first, uint256 deadline) = verifier.generateChallenge("accept-proposal", hex"01");
        (bytes32 second,) = verifier.generateChallenge("accept-proposal", hex"01");
        assertTrue(first != second);
        assertEq(deadline, block.timestamp + verifier.challengeDeadline());
    }
}
