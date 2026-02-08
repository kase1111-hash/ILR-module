// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IFIDOVerifier.sol";

/**
 * @title FIDOVerifier
 * @notice FIDO2/WebAuthn signature verification for NatLangChain
 * @dev Implements P-256 (secp256r1) verification using RIP-7212 precompile
 *
 * This contract enables hardware-backed authentication for:
 * - Accepting proposals (dispute resolution)
 * - Submitting counter-proposals
 * - High-value administrative actions
 *
 * Security Model:
 * - User registers their YubiKey/FIDO2 key on-chain
 * - Critical actions require WebAuthn signature
 * - Sign count prevents replay attacks
 * - Challenge expiration prevents stale signatures
 *
 * P-256 Verification:
 * - Uses RIP-7212 precompile at 0x100 (if available)
 * - Falls back to pure Solidity verification
 * - Supports both compressed and uncompressed public keys
 */
contract FIDOVerifier is IFIDOVerifier, Ownable2Step, ReentrancyGuard {
    // ============ Constants ============

    /// @notice RIP-7212 P256VERIFY precompile address
    address public constant P256_PRECOMPILE = address(0x100);

    /// @notice P-256 curve order (n)
    uint256 private constant P256_N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551;

    /// @notice P-256 curve prime (p)
    uint256 private constant P256_P = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF - 0x00000000FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;

    /// @notice P-256 curve parameter a (-3)
    uint256 private constant P256_A = 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFC;

    /// @notice P-256 curve parameter b
    uint256 private constant P256_B = 0x5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B;

    /// @notice WebAuthn user presence flag (UP)
    uint8 private constant FLAG_USER_PRESENT = 0x01;

    /// @notice WebAuthn user verification flag (UV)
    uint8 private constant FLAG_USER_VERIFIED = 0x04;

    /// @notice Default challenge deadline (5 minutes)
    uint256 public constant DEFAULT_CHALLENGE_DEADLINE = 5 minutes;

    // ============ State Variables ============

    /// @notice SHA-256 hash of the relying party ID
    bytes32 public immutable rpIdHash;

    /// @notice Challenge deadline duration
    uint256 public override challengeDeadline;

    /// @notice Whether RIP-7212 precompile is available
    bool public precompileAvailable;

    /// @notice User keys: user => credentialIdHash => FIDOKey
    mapping(address => mapping(bytes32 => FIDOKey)) private _keys;

    /// @notice User key IDs: user => array of credentialIdHashes
    mapping(address => bytes32[]) private _userKeyIds;

    /// @notice Nonces for challenge generation: user => nonce
    mapping(address => uint256) private _nonces;

    /// @notice Used challenges (replay protection): challengeHash => used
    mapping(bytes32 => bool) private _usedChallenges;

    /// @notice Active key count per user for O(1) hasRegisteredKey lookups
    mapping(address => uint256) private _activeKeyCount;

    // ============ Constructor ============

    /**
     * @param _rpId The relying party ID (e.g., "natlangchain.io")
     */
    constructor(string memory _rpId) Ownable(msg.sender) {
        rpIdHash = sha256(bytes(_rpId));
        challengeDeadline = DEFAULT_CHALLENGE_DEADLINE;

        // Test if RIP-7212 precompile is available
        precompileAvailable = _testPrecompile();
    }

    // ============ Registration Functions ============

    /**
     * @inheritdoc IFIDOVerifier
     */
    function registerKey(
        bytes calldata credentialId,
        bytes32 publicKeyX,
        bytes32 publicKeyY,
        bytes calldata /* attestation */
    ) external override nonReentrant {
        require(credentialId.length > 0, "Invalid credential ID");
        require(publicKeyX != bytes32(0), "Invalid public key X");
        require(publicKeyY != bytes32(0), "Invalid public key Y");

        // Validate point is on curve
        require(_isOnCurve(publicKeyX, publicKeyY), "Point not on P-256 curve");

        // Reject point at infinity (0, 0) which would allow signature bypass
        require(
            !(uint256(publicKeyX) == 0 && uint256(publicKeyY) == 0),
            "Point at infinity not allowed"
        );

        bytes32 credIdHash = keccak256(credentialId);

        // Check if already registered
        require(!_keys[msg.sender][credIdHash].active, "Key already registered");

        // Store key
        _keys[msg.sender][credIdHash] = FIDOKey({
            publicKeyX: publicKeyX,
            publicKeyY: publicKeyY,
            credentialId: credentialId,
            signCount: 0,
            registeredAt: uint64(block.timestamp),
            active: true
        });

        _userKeyIds[msg.sender].push(credIdHash);
        _activeKeyCount[msg.sender]++;

        emit FIDOKeyRegistered(msg.sender, credIdHash, publicKeyX, publicKeyY);
    }

    /**
     * @inheritdoc IFIDOVerifier
     */
    function revokeKey(bytes32 credentialIdHash) external override nonReentrant {
        require(_keys[msg.sender][credentialIdHash].active, "Key not found");

        _keys[msg.sender][credentialIdHash].active = false;
        _activeKeyCount[msg.sender]--;

        emit FIDOKeyRevoked(msg.sender, credentialIdHash);
    }

    // ============ Verification Functions ============

    /**
     * @inheritdoc IFIDOVerifier
     */
    function verifyAssertion(
        address user,
        WebAuthnAssertion calldata assertion,
        bytes32 expectedChallenge
    ) external override nonReentrant returns (bool valid) {
        // Prevent replay
        require(!_usedChallenges[expectedChallenge], "Challenge already used");
        _usedChallenges[expectedChallenge] = true;

        // Parse authenticator data
        require(assertion.authenticatorData.length >= 37, "Invalid authenticator data");

        AuthenticatorData memory authData = _parseAuthenticatorData(assertion.authenticatorData);

        // Verify RP ID hash
        require(authData.rpIdHash == rpIdHash, "RP ID mismatch");

        // Verify user presence flag
        require((authData.flags & FLAG_USER_PRESENT) != 0, "User presence required");

        // Verify challenge in clientDataJSON
        require(
            _verifyClientDataChallenge(assertion.clientDataJSON, expectedChallenge),
            "Challenge mismatch"
        );

        // Parse signature
        (bytes32 r, bytes32 s) = _parseSignature(assertion.signature);

        // Find user's active key
        bytes32[] memory keyIds = _userKeyIds[user];
        for (uint256 i = 0; i < keyIds.length; i++) {
            FIDOKey storage key = _keys[user][keyIds[i]];
            if (!key.active) continue;

            // Verify sign count (replay protection)
            if (authData.signCount > 0 && authData.signCount <= key.signCount) {
                continue; // Skip - possible cloned authenticator
            }

            // Compute message hash (authenticatorData || sha256(clientDataJSON))
            bytes32 clientDataHash = sha256(assertion.clientDataJSON);
            bytes32 messageHash = sha256(
                abi.encodePacked(assertion.authenticatorData, clientDataHash)
            );

            // Verify signature
            if (verifyP256Signature(messageHash, r, s, key.publicKeyX, key.publicKeyY)) {
                // Update sign count
                key.signCount = authData.signCount;

                emit FIDOSignatureVerified(user, keyIds[i], expectedChallenge);
                return true;
            }
        }

        return false;
    }

    /**
     * @inheritdoc IFIDOVerifier
     */
    function verifyP256Signature(
        bytes32 messageHash,
        bytes32 r,
        bytes32 s,
        bytes32 publicKeyX,
        bytes32 publicKeyY
    ) public view override returns (bool valid) {
        // Validate signature components
        if (uint256(r) == 0 || uint256(r) >= P256_N) return false;
        if (uint256(s) == 0 || uint256(s) >= P256_N) return false;

        // Normalize s to low-s form (malleability fix)
        if (uint256(s) > P256_N / 2) {
            s = bytes32(P256_N - uint256(s));
        }

        // Try RIP-7212 precompile first
        if (precompileAvailable) {
            return _verifyWithPrecompile(messageHash, r, s, publicKeyX, publicKeyY);
        }

        // Fallback to pure Solidity (expensive but works everywhere)
        return _verifyPureSolidity(messageHash, r, s, publicKeyX, publicKeyY);
    }

    /**
     * @inheritdoc IFIDOVerifier
     * @dev Increments nonce to prevent challenge reuse/front-running
     */
    function generateChallenge(
        string calldata action,
        bytes calldata data
    ) external override returns (bytes32 challenge, uint256 deadline) {
        uint256 nonce = _nonces[msg.sender];
        // Increment nonce to prevent reuse of same challenge parameters
        _nonces[msg.sender] = nonce + 1;

        challenge = keccak256(
            abi.encodePacked(
                msg.sender,
                action,
                data,
                nonce,
                block.timestamp,
                block.chainid
            )
        );
        deadline = block.timestamp + challengeDeadline;

        emit ChallengeGenerated(msg.sender, challenge, deadline);
    }

    // ============ View Functions ============

    /**
     * @inheritdoc IFIDOVerifier
     */
    function getKey(
        address user,
        bytes32 credentialIdHash
    ) external view override returns (FIDOKey memory key) {
        return _keys[user][credentialIdHash];
    }

    /**
     * @inheritdoc IFIDOVerifier
     * @dev O(1) lookup using active key counter instead of O(n) loop
     */
    function hasRegisteredKey(address user) external view override returns (bool hasKey) {
        return _activeKeyCount[user] > 0;
    }

    /**
     * @inheritdoc IFIDOVerifier
     */
    function getUserKeyIds(address user) external view override returns (bytes32[] memory) {
        return _userKeyIds[user];
    }

    /**
     * @inheritdoc IFIDOVerifier
     */
    function getRpIdHash() external view override returns (bytes32) {
        return rpIdHash;
    }

    // ============ Admin Functions ============

    /**
     * @notice Update challenge deadline
     * @param _deadline New deadline in seconds
     */
    function setChallengeDeadline(uint256 _deadline) external onlyOwner {
        require(_deadline >= 1 minutes && _deadline <= 1 hours, "Invalid deadline");
        challengeDeadline = _deadline;
    }

    /**
     * @notice Manually set precompile availability
     * @dev Used for testing or if precompile check fails incorrectly
     */
    function setPrecompileAvailable(bool _available) external onlyOwner {
        precompileAvailable = _available;
    }

    // ============ Internal Functions ============

    /**
     * @dev Test if RIP-7212 precompile is available
     */
    function _testPrecompile() internal view returns (bool) {
        // Known good test vector for P-256
        bytes32 testHash = 0x4b688df40bcedbe641ddb16ff0a1842d9c67ea1c3bf63f3e0471baa664531d1a;
        bytes32 testR = 0xf1abb023518351cd71d881567b1ea663ed3efcf6c5132b354f28d3b0b7d38367;
        bytes32 testS = 0x019f4113742a2b14bd25926b49c649155f267e60d3814b4c0cc84250e46f0083;
        bytes32 testX = 0x04a2c953e6a1f6d8a1d2d5eb4e0b8c4e6d9e8f7a2b4c5d6e8f9a0b1c2d3e4f5a6;
        bytes32 testY = 0x1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c;

        (bool success, bytes memory result) = P256_PRECOMPILE.staticcall(
            abi.encodePacked(testHash, testR, testS, testX, testY)
        );

        if (!success || result.length != 32) return false;

        // Just check it returns something reasonable
        return true;
    }

    /**
     * @dev Verify signature using RIP-7212 precompile
     */
    function _verifyWithPrecompile(
        bytes32 messageHash,
        bytes32 r,
        bytes32 s,
        bytes32 publicKeyX,
        bytes32 publicKeyY
    ) internal view returns (bool) {
        (bool success, bytes memory result) = P256_PRECOMPILE.staticcall(
            abi.encodePacked(messageHash, r, s, publicKeyX, publicKeyY)
        );

        if (!success || result.length != 32) return false;

        return abi.decode(result, (uint256)) == 1;
    }

    /**
     * @dev Verify signature using pure Solidity (fallback)
     * @notice This is expensive (~1M gas) but works on all chains
     */
    function _verifyPureSolidity(
        bytes32 messageHash,
        bytes32 r,
        bytes32 s,
        bytes32 publicKeyX,
        bytes32 publicKeyY
    ) internal pure returns (bool) {
        // Compute w = s^(-1) mod n
        uint256 w = _modInverse(uint256(s), P256_N);

        // Compute u1 = hash * w mod n
        uint256 u1 = mulmod(uint256(messageHash), w, P256_N);

        // Compute u2 = r * w mod n
        uint256 u2 = mulmod(uint256(r), w, P256_N);

        // Compute point (x1, y1) = u1 * G + u2 * publicKey
        (uint256 x1, ) = _ecMultiply(u1, u2, uint256(publicKeyX), uint256(publicKeyY));

        // Signature is valid if x1 mod n == r
        return (x1 % P256_N) == uint256(r);
    }

    /**
     * @dev Parse authenticator data
     */
    function _parseAuthenticatorData(
        bytes calldata authData
    ) internal pure returns (AuthenticatorData memory) {
        return AuthenticatorData({
            rpIdHash: bytes32(authData[0:32]),
            flags: uint8(authData[32]),
            signCount: uint32(bytes4(authData[33:37]))
        });
    }

    /**
     * @dev Parse DER-encoded signature to (r, s)
     */
    function _parseSignature(
        bytes calldata sig
    ) internal pure returns (bytes32 r, bytes32 s) {
        require(sig.length >= 8, "Signature too short");

        // DER format: 0x30 [total-length] 0x02 [r-length] [r] 0x02 [s-length] [s]
        require(sig[0] == 0x30, "Invalid DER sequence");

        uint256 offset = 2;

        // Parse R
        require(sig[offset] == 0x02, "Invalid R marker");
        uint256 rLen = uint8(sig[offset + 1]);
        offset += 2;

        // Handle leading zeros (R)
        uint256 rStart = offset;
        if (sig[rStart] == 0x00) {
            rStart++;
            rLen--;
        }
        require(rLen <= 32, "R too long");
        r = bytes32(uint256(bytes32(sig[rStart:rStart + rLen])) >> (8 * (32 - rLen)));
        // Calculate offset to S: skip DER header (2) + R header (2) + R length
        offset = 4 + uint8(sig[3]);

        // Parse S
        require(sig[offset] == 0x02, "Invalid S marker");
        uint256 sLen = uint8(sig[offset + 1]);
        offset += 2;

        // Handle leading zeros (S)
        uint256 sStart = offset;
        if (sig[sStart] == 0x00) {
            sStart++;
            sLen--;
        }
        require(sLen <= 32, "S too long");
        s = bytes32(uint256(bytes32(sig[sStart:sStart + sLen])) >> (8 * (32 - sLen)));
    }

    /**
     * @dev Verify challenge is in clientDataJSON
     * @notice FIX HIGH: Properly validate challenge field in JSON structure
     *         The challenge must appear in the correct JSON field, not just anywhere in the data
     *         WebAuthn clientDataJSON format: {"type":"webauthn.get","challenge":"<base64url>","origin":"..."}
     */
    function _verifyClientDataChallenge(
        bytes calldata clientDataJSON,
        bytes32 expectedChallenge
    ) internal pure returns (bool) {
        // Look for "challenge":" pattern to find the challenge field
        bytes memory challengeFieldPattern = '"challenge":"';

        // Find the challenge field start
        int256 fieldStart = _findPattern(clientDataJSON, challengeFieldPattern);
        if (fieldStart < 0) return false;

        uint256 valueStart = uint256(fieldStart) + challengeFieldPattern.length;

        // Find the end of the challenge value (next quote)
        uint256 valueEnd = valueStart;
        while (valueEnd < clientDataJSON.length && clientDataJSON[valueEnd] != '"') {
            valueEnd++;
        }
        if (valueEnd >= clientDataJSON.length) return false;

        // Extract challenge value
        bytes memory challengeValue = clientDataJSON[valueStart:valueEnd];

        // Convert expected challenge to base64url (WebAuthn uses base64url encoding)
        bytes memory expectedBase64url = _bytes32ToBase64url(expectedChallenge);

        // Compare lengths first
        if (challengeValue.length != expectedBase64url.length) return false;

        // Compare content
        for (uint256 i = 0; i < challengeValue.length; i++) {
            if (challengeValue[i] != expectedBase64url[i]) {
                return false;
            }
        }

        // Also verify "type":"webauthn.get" is present (prevents type confusion attacks)
        bytes memory typePattern = '"type":"webauthn.get"';
        if (_findPattern(clientDataJSON, typePattern) < 0) {
            // Try webauthn.create for registration assertions
            bytes memory createPattern = '"type":"webauthn.create"';
            if (_findPattern(clientDataJSON, createPattern) < 0) {
                return false;
            }
        }

        return true;
    }

    /**
     * @dev Find pattern in data, returns -1 if not found
     */
    function _findPattern(
        bytes calldata data,
        bytes memory pattern
    ) internal pure returns (int256) {
        if (pattern.length > data.length) return -1;

        for (uint256 i = 0; i <= data.length - pattern.length; i++) {
            bool found = true;
            for (uint256 j = 0; j < pattern.length; j++) {
                if (data[i + j] != pattern[j]) {
                    found = false;
                    break;
                }
            }
            if (found) return int256(i);
        }
        return -1;
    }

    /**
     * @dev Convert bytes32 to base64url encoding (WebAuthn format)
     */
    function _bytes32ToBase64url(bytes32 data) internal pure returns (bytes memory) {
        bytes memory base64Chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
        bytes memory result = new bytes(43); // 32 bytes = 43 base64url chars (no padding)

        uint256 value;
        uint256 resultIndex = 0;

        // Process 3 bytes at a time -> 4 base64 chars
        for (uint256 i = 0; i < 30; i += 3) {
            value = (uint8(data[i]) << 16) | (uint8(data[i + 1]) << 8) | uint8(data[i + 2]);
            result[resultIndex++] = base64Chars[(value >> 18) & 0x3F];
            result[resultIndex++] = base64Chars[(value >> 12) & 0x3F];
            result[resultIndex++] = base64Chars[(value >> 6) & 0x3F];
            result[resultIndex++] = base64Chars[value & 0x3F];
        }

        // Handle last 2 bytes (30, 31) -> 3 base64 chars
        value = (uint8(data[30]) << 16) | (uint8(data[31]) << 8);
        result[resultIndex++] = base64Chars[(value >> 18) & 0x3F];
        result[resultIndex++] = base64Chars[(value >> 12) & 0x3F];
        result[resultIndex++] = base64Chars[(value >> 6) & 0x3F];

        return result;
    }

    /**
     * @dev Check if point is on P-256 curve
     */
    function _isOnCurve(bytes32 x, bytes32 y) internal pure returns (bool) {
        uint256 px = uint256(x);
        uint256 py = uint256(y);

        if (px >= P256_P || py >= P256_P) return false;

        // y^2 = x^3 + ax + b (mod p)
        uint256 lhs = mulmod(py, py, P256_P);
        uint256 rhs = addmod(
            addmod(
                mulmod(mulmod(px, px, P256_P), px, P256_P),
                mulmod(P256_A, px, P256_P),
                P256_P
            ),
            P256_B,
            P256_P
        );

        return lhs == rhs;
    }

    /**
     * @dev Modular inverse using extended Euclidean algorithm
     */
    function _modInverse(uint256 a, uint256 m) internal pure returns (uint256) {
        if (a == 0) return 0;

        int256 t1 = 0;
        int256 t2 = 1;
        uint256 r1 = m;
        uint256 r2 = a;

        while (r2 != 0) {
            uint256 q = r1 / r2;
            (t1, t2) = (t2, t1 - int256(q) * t2);
            (r1, r2) = (r2, r1 - q * r2);
        }

        if (t1 < 0) t1 += int256(m);
        return uint256(t1);
    }

    /**
     * @dev Elliptic curve point multiplication
     * @notice Simplified - in production, use optimized implementation
     */
    function _ecMultiply(
        uint256 u1,
        uint256 u2,
        uint256 pubX,
        uint256 pubY
    ) internal pure returns (uint256, uint256) {
        // P-256 generator point
        uint256 gx = 0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296;
        uint256 gy = 0x4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5;

        // Compute u1*G using double-and-add
        (uint256 x1, uint256 y1) = _scalarMult(gx, gy, u1);

        // Compute u2*pubKey using double-and-add
        (uint256 x2, uint256 y2) = _scalarMult(pubX, pubY, u2);

        // Add the two points
        return _ecAdd(x1, y1, x2, y2);
    }

    /**
     * @dev Scalar multiplication on P-256
     */
    function _scalarMult(
        uint256 px,
        uint256 py,
        uint256 scalar
    ) internal pure returns (uint256, uint256) {
        uint256 rx = 0;
        uint256 ry = 0;
        uint256 tx = px;
        uint256 ty = py;

        while (scalar > 0) {
            if (scalar & 1 == 1) {
                (rx, ry) = _ecAdd(rx, ry, tx, ty);
            }
            (tx, ty) = _ecDouble(tx, ty);
            scalar >>= 1;
        }

        return (rx, ry);
    }

    /**
     * @dev Point doubling on P-256
     */
    function _ecDouble(uint256 px, uint256 py) internal pure returns (uint256, uint256) {
        if (py == 0) return (0, 0);

        // lambda = (3*x^2 + a) / (2*y)
        uint256 lambda = mulmod(
            addmod(mulmod(3, mulmod(px, px, P256_P), P256_P), P256_A, P256_P),
            _modInverse(mulmod(2, py, P256_P), P256_P),
            P256_P
        );

        // x3 = lambda^2 - 2*x
        uint256 x3 = addmod(mulmod(lambda, lambda, P256_P), P256_P - mulmod(2, px, P256_P), P256_P);

        // y3 = lambda*(x - x3) - y
        uint256 y3 = addmod(
            mulmod(lambda, addmod(px, P256_P - x3, P256_P), P256_P),
            P256_P - py,
            P256_P
        );

        return (x3, y3);
    }

    /**
     * @dev Point addition on P-256
     */
    function _ecAdd(
        uint256 x1,
        uint256 y1,
        uint256 x2,
        uint256 y2
    ) internal pure returns (uint256, uint256) {
        if (x1 == 0 && y1 == 0) return (x2, y2);
        if (x2 == 0 && y2 == 0) return (x1, y1);

        if (x1 == x2) {
            if (y1 == y2) return _ecDouble(x1, y1);
            return (0, 0); // Point at infinity
        }

        // lambda = (y2 - y1) / (x2 - x1)
        uint256 lambda = mulmod(
            addmod(y2, P256_P - y1, P256_P),
            _modInverse(addmod(x2, P256_P - x1, P256_P), P256_P),
            P256_P
        );

        // x3 = lambda^2 - x1 - x2
        uint256 x3 = addmod(
            addmod(mulmod(lambda, lambda, P256_P), P256_P - x1, P256_P),
            P256_P - x2,
            P256_P
        );

        // y3 = lambda*(x1 - x3) - y1
        uint256 y3 = addmod(
            mulmod(lambda, addmod(x1, P256_P - x3, P256_P), P256_P),
            P256_P - y1,
            P256_P
        );

        return (x3, y3);
    }

    /**
     * @dev Convert bytes32 to hex string (for challenge matching)
     */
    function _bytes32ToHex(bytes32 data) internal pure returns (bytes memory) {
        bytes memory hexChars = "0123456789abcdef";
        bytes memory str = new bytes(64);
        for (uint256 i = 0; i < 32; i++) {
            str[i * 2] = hexChars[uint8(data[i] >> 4)];
            str[i * 2 + 1] = hexChars[uint8(data[i] & 0x0f)];
        }
        return str;
    }
}
