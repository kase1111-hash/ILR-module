// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/**
 * @title BLS12381
 * @notice Minimal BLS12-381 signature verification over the EIP-2537 precompiles (Prague)
 * @dev Signature scheme (the "minimal-pubkey-size" variant, as produced by sdk/threshold-bls.ts):
 *      - public keys are G1 points and signatures are G2 points;
 *      - H(m) = hash_to_curve(m) per RFC 9380, suite BLS12381G2_XMD:SHA-256_SSWU_RO_, with a caller-supplied DST;
 *      - a signature is valid iff e(pk, H(m)) * e(-G1, sig) == 1, and the public key is not the point at infinity.
 *
 *      Encodings (EIP-2537):
 *      - Fp: 64 bytes big-endian, i.e. 16 zero bytes followed by the 48-byte value;
 *      - Fp2: c0 || c1 (128 bytes);
 *      - G1 point: x || y (128 bytes);
 *      - G2 point: x || y (256 bytes), in the order x.c0, x.c1, y.c0, y.c1;
 *      - the all-zero encoding is the point at infinity.
 *
 *      Precompiles used: MODEXP 0x05, G1ADD 0x0b, G1MSM 0x0c, G2ADD 0x0d, PAIRING_CHECK 0x0f, MAP_FP2_TO_G2 0x11.
 *
 *      Failure model: apart from expandMessageXmd (which reverts on an invalid DST) no function reverts.
 *      Every precompile call must succeed AND return exactly the expected number of bytes, otherwise the
 *      function returns false. The length check matters: on a chain without EIP-2537 the call reaches an
 *      empty account and "succeeds" with no output. A failing EIP-2537 precompile consumes all gas forwarded
 *      to it; forwarded gas is deliberately not capped because precompiles may be repriced.
 */
library BLS12381 {
    address internal constant MODEXP = address(0x05);
    address internal constant G1_ADD = address(0x0b);
    address internal constant G1_MSM = address(0x0c);
    address internal constant G2_ADD = address(0x0d);
    address internal constant PAIRING_CHECK = address(0x0f);
    address internal constant MAP_FP2_TO_G2 = address(0x11);

    /// @dev Base field modulus p, split into the two 32-byte words of its 64-byte EIP-2537 encoding
    bytes32 private constant P_HI = 0x000000000000000000000000000000001a0111ea397fe69a4b1ba7b6434bacd7;
    bytes32 private constant P_LO = 0x64774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab;

    /// @dev P_HI || P_LO: p left-padded to 64 bytes, so MODEXP returns an EIP-2537 Fp encoding
    bytes private constant P = hex"000000000000000000000000000000001a0111ea397fe69a4b1ba7b6434bacd7"
        hex"64774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab";

    /// @dev Negated G1 generator (g1.x, p - g1.y) in EIP-2537 encoding
    bytes private constant NEG_G1 = hex"0000000000000000000000000000000017f1d3a73197d7942695638c4fa9ac0f"
        hex"c3688c4f9774b905a14e3a3f171bac586c55e83ff97a1aeffb3af00adb22c6bb"
        hex"00000000000000000000000000000000114d1d6855d545a8aa7d76c8cf2e21f2"
        hex"67816aef1db507c96655b9d5caac42364e6f38ba0ecb751bad54dcd6b939c2ca";

    /**
     * @notice True if the EIP-2537 precompiles are present
     * @dev Known-answer test: G1ADD(-G1, infinity) must return exactly -G1. The input is valid, so no gas is
     *      burned on Prague chains; an empty account (or any other contract at 0x0b) yields false.
     */
    function precompilesAvailable() internal view returns (bool) {
        (bool ok, bytes memory out) = G1_ADD.staticcall(abi.encodePacked(NEG_G1, new bytes(128)));
        return ok && out.length == 128 && keccak256(out) == keccak256(NEG_G1);
    }

    /**
     * @notice Structural check of a G1 point encoding: 128 bytes, not infinity, both coordinates canonical
     * @dev A coordinate is canonical if its top 16 bytes are zero and its value is below p. This does NOT check
     *      that the point is on the curve or in the subgroup; use isValidG1 for that.
     */
    function isCanonicalG1(bytes memory pt) internal pure returns (bool) {
        if (pt.length != 128 || isZero(pt)) return false;
        (bytes32 xHi, bytes32 xLo, bytes32 yHi, bytes32 yLo) = abi.decode(pt, (bytes32, bytes32, bytes32, bytes32));
        return _isCanonicalFp(xHi, xLo) && _isCanonicalFp(yHi, yLo);
    }

    /**
     * @notice True if `pt` is a canonical G1 point on the curve, in the prime-order subgroup and not infinity
     * @dev G1MSM(pt, 1) enforces the encoding, curve and subgroup checks on its input
     */
    function isValidG1(bytes memory pt) internal view returns (bool) {
        if (!isCanonicalG1(pt)) return false;
        (bool ok, bytes memory out) = G1_MSM.staticcall(abi.encodePacked(pt, uint256(1)));
        return ok && out.length == 128;
    }

    /**
     * @notice Verify the G2 signature `sig` over `msg_` under the G1 public key `pk`, with domain tag `dst`
     * @dev Checks e(pk, H(m)) * e(-G1, sig) == 1. The infinity public key is rejected because e(O, .) == 1 would
     *      accept the infinity signature for every message. PAIRING_CHECK rejects non-canonical, off-curve and
     *      out-of-subgroup inputs.
     */
    function verify(bytes memory pk, bytes memory sig, bytes memory msg_, bytes memory dst)
        internal
        view
        returns (bool)
    {
        if (pk.length != 128 || sig.length != 256 || isZero(pk)) return false;
        (bool ok, bytes memory hm) = hashToG2(msg_, dst);
        if (!ok) return false;
        bytes memory out;
        (ok, out) = PAIRING_CHECK.staticcall(abi.encodePacked(pk, hm, NEG_G1, sig));
        return ok && out.length == 32 && abi.decode(out, (uint256)) == 1;
    }

    /**
     * @notice RFC 9380 hash_to_curve for the suite BLS12381G2_XMD:SHA-256_SSWU_RO_ with domain tag `dst`
     * @dev u0, u1 = hash_to_field(msg, 2); Q0 = map_to_curve(u0); Q1 = map_to_curve(u1); return Q0 + Q1.
     *      MAP_FP2_TO_G2 applies SSWU, the isogeny and cofactor clearing; clearing is linear, so
     *      clear(Q0') + clear(Q1') == clear(Q0' + Q1') as the RFC specifies.
     * @return ok False if any precompile call failed
     * @return point The 256-byte G2 point H(msg)
     */
    function hashToG2(bytes memory msg_, bytes memory dst) internal view returns (bool ok, bytes memory point) {
        bytes32[8] memory b = expandMessageXmd(msg_, dst);
        bytes memory q0;
        bytes memory q1;
        (ok, q0) = _mapToG2(b[0], b[1], b[2], b[3]);
        if (!ok) return (false, point);
        (ok, q1) = _mapToG2(b[4], b[5], b[6], b[7]);
        if (!ok) return (false, point);
        return g2Add(q0, q1);
    }

    /**
     * @notice expand_message_xmd (RFC 9380 section 5.3.1) with SHA-256 and len_in_bytes = 256
     * @dev Reverts if the DST is empty or longer than 255 bytes
     */
    function expandMessageXmd(bytes memory msg_, bytes memory dst) internal pure returns (bytes32[8] memory b) {
        require(dst.length > 0 && dst.length < 256, "Invalid DST");
        bytes memory dstPrime = abi.encodePacked(dst, uint8(dst.length));
        // msg_prime = Z_pad (64 zero bytes) || msg || I2OSP(256, 2) || I2OSP(0, 1) || DST_prime
        bytes32 b0 = sha256(abi.encodePacked(bytes32(0), bytes32(0), msg_, uint16(256), uint8(0), dstPrime));
        b[0] = sha256(abi.encodePacked(b0, uint8(1), dstPrime));
        for (uint8 i = 1; i < 8; i++) {
            b[i] = sha256(abi.encodePacked(b0 ^ b[i - 1], i + 1, dstPrime));
        }
    }

    /// @notice G2 point addition; ok only if the precompile returned a 256-byte point
    function g2Add(bytes memory a, bytes memory b) internal view returns (bool ok, bytes memory sum) {
        (ok, sum) = G2_ADD.staticcall(abi.encodePacked(a, b));
        ok = ok && sum.length == 256;
    }

    /// @notice True if every byte of `data` is zero (the EIP-2537 encoding of the point at infinity)
    function isZero(bytes memory data) internal pure returns (bool) {
        return keccak256(data) == keccak256(new bytes(data.length));
    }

    /// @dev (hi, lo) is a canonical Fp encoding: top 16 bytes zero and value < p
    function _isCanonicalFp(bytes32 hi, bytes32 lo) private pure returns (bool) {
        if (uint256(hi) >> 128 != 0) return false;
        return hi < P_HI || (hi == P_HI && lo < P_LO);
    }

    /// @dev map_to_curve(u) for u = (OS2IP(a0 || a1) mod p, OS2IP(b0 || b1) mod p)
    function _mapToG2(bytes32 a0, bytes32 a1, bytes32 b0, bytes32 b1) private view returns (bool, bytes memory) {
        (bool ok0, bytes memory c0) = _modP(a0, a1);
        (bool ok1, bytes memory c1) = _modP(b0, b1);
        if (!(ok0 && ok1)) return (false, c0);
        (bool ok, bytes memory point) = MAP_FP2_TO_G2.staticcall(abi.encodePacked(c0, c1));
        return (ok && point.length == 256, point);
    }

    /// @dev hash_to_field reduction of a 64-byte string: MODEXP(hi || lo, 1, p), a 64-byte Fp encoding
    function _modP(bytes32 hi, bytes32 lo) private view returns (bool ok, bytes memory fp) {
        (ok, fp) = MODEXP.staticcall(abi.encodePacked(uint256(64), uint256(1), uint256(64), hi, lo, uint8(1), P));
        ok = ok && fp.length == 64;
    }
}
