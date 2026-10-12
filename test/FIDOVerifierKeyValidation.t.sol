// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/modules/FIDOVerifier.sol";

/**
 * @title FIDOVerifierKeyValidationTest
 * @notice verifyP256Signature is public ("lower-level verification for custom implementations") and must reject
 *         public keys that are not points on P-256 on both verification paths. The pure-Solidity fallback encodes
 *         the point at infinity as (0,0) and its affine formulas never use the curve constant b, so without key
 *         validation:
 *         - key (0,0): u2*Q is the point at infinity, the check reduces to x(u1*G) mod n == r, and anyone can
 *           forge a signature on any message (pick k, r = x(kG) mod n, s = h/k mod n);
 *         - an off-curve key (invalid-curve attack), e.g. (1,0), which has order 2 on the curve
 *           y^2 = x^3 - 3x + 2: u2*Q vanishes for every even u2, so the same forgery works.
 *         The RIP-7212 / EIP-7951 P256VERIFY precompile rejects such keys; the paths must agree.
 * @dev Every forgery vector was generated with @noble/curves. Before the fix the fallback returned true for each.
 */
contract FIDOVerifierKeyValidationTest is Test {
    uint256 internal constant N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551;
    uint256 internal constant P = 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF;
    uint256 internal constant GX = 0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296;
    uint256 internal constant GY = 0x4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5;
    address internal constant P256_PRECOMPILE = address(0x100);

    FIDOVerifier internal verifier;

    struct Vector {
        bytes32 hash;
        bytes32 r;
        bytes32 s;
        bytes32 x;
        bytes32 y;
    }

    function setUp() public {
        verifier = new FIDOVerifier("natlangchain.io");
        // Force the pure-Solidity path even where a P256VERIFY precompile exists
        verifier.setPrecompileAvailable(false);
    }

    function _verify(Vector memory v) internal view returns (bool) {
        return verifier.verifyP256Signature(v.hash, v.r, v.s, v.x, v.y);
    }

    /// @dev A genuine signature (same as FIDOVerifierFallback's second vector)
    function _validVector() internal pure returns (Vector memory) {
        return Vector({
            hash: 0x9d1e32a08b5ce480cac3c9acecb5552236811bf927fdab828251bc1296c19771,
            r: 0x775181f2694bef1664784c3fee4ccfea76bf522068004e340fc7f012daeb4d92,
            s: 0x3f05194c55aa288116480449d2911ba1aba96b44641f7a6b8594768f91497221,
            x: 0x4a69c9ca7f0d0196557ef1dfd5ff09763d72a85db71eda7a927878608d8ee61d,
            y: 0x1bf2530ed6e1de65793608594bfdeecf8db23168fb35404b97608c8898bc4517
        });
    }

    /// @dev Key (0,0), k = 1: r = G.x, s = h mod n (already low-s), so u1 = 1 and x(u1*G) == r
    function _infinityKeyForgeryUnitNonce() internal pure returns (Vector memory) {
        bytes32 h = sha256("attacker-chosen message");
        uint256 s = uint256(h) % N;
        if (s > N / 2) s = N - s;
        return Vector({hash: h, r: bytes32(GX), s: bytes32(s), x: bytes32(0), y: bytes32(0)});
    }

    /// @dev Key (0,0), k = 123456789: r = x(kG) mod n, s = h/k mod n (high-s; normalization maps u1 to -k, and
    ///      x(-kG) == x(kG))
    function _infinityKeyForgeryArbitraryNonce() internal pure returns (Vector memory) {
        return Vector({
            hash: 0x1111111111111111111111111111111111111111111111111111111111111111,
            r: 0xfb50388f29498d0a93ad25ec4c34037b9d3cc3cca4787eb6fedabe2b3003eac8,
            s: 0xadf088ed54f2aca1c5fd87ed28ec211ed7c81bc34162878335bc9ad17b7ac178,
            x: bytes32(0),
            y: bytes32(0)
        });
    }

    /// @dev Off-curve key (1,0), k = 17: h = sha256("invalid-curve key"), r = x(17G) mod n, s = h/17 mod n (low-s),
    ///      so u1 = 17 and u2 = r/s mod n is even, which sends u2*(1,0) to the point at infinity
    function _offCurveKeyForgery() internal pure returns (Vector memory) {
        return Vector({
            hash: 0x9189244583a7a7ae10a666d0177d814accbc9280972611f548c0f74ae0241831,
            r: 0x47776904c0f1cc3a9c0984b66f75301a5fa68678f0d64af8ba1abce34738a73e,
            s: 0x71f90221cb825528c4be7e84b61671044ac48df4b71b0617ff39bc63c0672ee8,
            x: bytes32(uint256(1)),
            y: bytes32(0)
        });
    }

    // ============ Pure-Solidity path ============

    function test_FallbackRejectsInfinityKeyForgery() public view {
        assertFalse(verifier.precompileAvailable());
        assertEq(_infinityKeyForgeryUnitNonce().hash, sha256("attacker-chosen message"));
        assertFalse(_verify(_infinityKeyForgeryUnitNonce())); // unfixed: true
    }

    function test_FallbackRejectsInfinityKeyForgeryForAnyNonce() public view {
        assertFalse(_verify(_infinityKeyForgeryArbitraryNonce())); // unfixed: true
    }

    function test_FallbackRejectsInvalidCurveKeyForgery() public view {
        Vector memory v = _offCurveKeyForgery();
        assertEq(v.hash, sha256("invalid-curve key"));
        assertFalse(_verify(v)); // unfixed: true
    }

    function test_FallbackRejectsOffCurveAndNonCanonicalKeys() public view {
        // The genuine signature verifies against its own key
        Vector memory v = _validVector();
        assertTrue(_verify(v));

        // ...but not against an off-curve neighbour of that key
        v.y = bytes32(uint256(v.y) + 1);
        assertFalse(_verify(v));

        // Coordinates must be canonical field elements (below p)
        v = _validVector();
        v.x = bytes32(P);
        assertFalse(_verify(v));
        v = _validVector();
        v.y = bytes32(type(uint256).max);
        assertFalse(_verify(v));
    }

    function test_FallbackStillAcceptsGeneratorAsKey() public view {
        // Q = G is a valid key; with d = 1 and k = 1: r = G.x, s = (h + r) mod n. Pins that the new key check does
        // not reject legitimate on-curve keys.
        bytes32 h = sha256("generator key");
        uint256 s = addmod(uint256(h), GX, N);
        assertTrue(verifier.verifyP256Signature(h, bytes32(GX), bytes32(s), bytes32(GX), bytes32(GY)));
    }

    // ============ Precompile path ============

    /// @dev A stand-in precompile that accepts everything shows the key check runs before either path
    function test_PrecompilePathRejectsInvalidKeysBeforeCallingPrecompile() public {
        vm.mockCall(P256_PRECOMPILE, bytes(""), abi.encode(uint256(1)));
        verifier.setPrecompileAvailable(true);

        assertTrue(_verify(_validVector())); // a valid key reaches the (mocked) precompile
        assertFalse(_verify(_infinityKeyForgeryUnitNonce()));
        assertFalse(_verify(_infinityKeyForgeryArbitraryNonce()));
        assertFalse(_verify(_offCurveKeyForgery()));
    }

    function testFuzz_InvalidKeysRejectedOnBothPaths(bytes32 x, bytes32 y) public {
        // Keep the fuzz cheap: any (x, y) that is not on the curve must fail before verification work starts
        vm.assume(!_onCurve(uint256(x), uint256(y)));
        Vector memory v = _validVector();
        v.x = x;
        v.y = y;
        assertFalse(_verify(v));

        vm.mockCall(P256_PRECOMPILE, bytes(""), abi.encode(uint256(1)));
        verifier.setPrecompileAvailable(true);
        assertFalse(_verify(v));
    }

    function _onCurve(uint256 x, uint256 y) internal pure returns (bool) {
        if (x >= P || y >= P) return false;
        uint256 a = P - 3;
        uint256 b = 0x5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B;
        return mulmod(y, y, P) == addmod(addmod(mulmod(mulmod(x, x, P), x, P), mulmod(a, x, P), P), b, P);
    }
}
