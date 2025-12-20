// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/**
 * @title IFIDOVerifier
 * @notice Interface for FIDO2/WebAuthn signature verification
 * @dev Implements P-256 (secp256r1) signature verification for hardware keys
 *
 * WebAuthn Flow:
 * 1. User registers their hardware key (YubiKey) via registerKey()
 * 2. For sensitive actions, frontend generates a challenge
 * 3. User signs with their hardware key
 * 4. Contract verifies the WebAuthn assertion
 *
 * Security Properties:
 * - Hardware-backed key storage (keys never leave device)
 * - Phishing resistance (origin binding)
 * - User presence verification (touch required)
 * - Optional user verification (PIN/biometric)
 */
interface IFIDOVerifier {
    // ============ Structs ============

    /**
     * @notice WebAuthn authenticator data structure
     * @dev Parsed from the raw authenticatorData bytes
     * @param rpIdHash SHA-256 hash of the relying party ID (32 bytes)
     * @param flags Authenticator flags (UP, UV, AT, ED, etc.)
     * @param signCount Signature counter (replay protection)
     */
    struct AuthenticatorData {
        bytes32 rpIdHash;
        uint8 flags;
        uint32 signCount;
    }

    /**
     * @notice WebAuthn assertion for verification
     * @dev Contains all data needed to verify a WebAuthn signature
     * @param authenticatorData Raw authenticator data from the key
     * @param clientDataJSON Client data JSON (contains challenge, origin, type)
     * @param signature DER-encoded P-256 signature (r, s)
     */
    struct WebAuthnAssertion {
        bytes authenticatorData;
        bytes clientDataJSON;
        bytes signature;
    }

    /**
     * @notice Parsed P-256 signature components
     * @param r R component (32 bytes)
     * @param s S component (32 bytes)
     */
    struct P256Signature {
        bytes32 r;
        bytes32 s;
    }

    /**
     * @notice Registered FIDO key information
     * @param publicKeyX X coordinate of P-256 public key
     * @param publicKeyY Y coordinate of P-256 public key
     * @param credentialId WebAuthn credential ID
     * @param signCount Last known signature count
     * @param registeredAt Timestamp of registration
     * @param active Whether the key is currently active
     */
    struct FIDOKey {
        bytes32 publicKeyX;
        bytes32 publicKeyY;
        bytes credentialId;
        uint32 signCount;
        uint64 registeredAt;
        bool active;
    }

    // ============ Events ============

    /// @notice Emitted when a new FIDO key is registered
    event FIDOKeyRegistered(
        address indexed user,
        bytes32 indexed credentialIdHash,
        bytes32 publicKeyX,
        bytes32 publicKeyY
    );

    /// @notice Emitted when a FIDO key is revoked
    event FIDOKeyRevoked(
        address indexed user,
        bytes32 indexed credentialIdHash
    );

    /// @notice Emitted when a signature is successfully verified
    event FIDOSignatureVerified(
        address indexed user,
        bytes32 indexed credentialIdHash,
        bytes32 challenge
    );

    // ============ Registration Functions ============

    /**
     * @notice Register a new FIDO/WebAuthn key
     * @dev Called after successful WebAuthn registration ceremony
     * @param credentialId The credential ID from the authenticator
     * @param publicKeyX X coordinate of the P-256 public key
     * @param publicKeyY Y coordinate of the P-256 public key
     * @param attestation Optional attestation data for verification
     */
    function registerKey(
        bytes calldata credentialId,
        bytes32 publicKeyX,
        bytes32 publicKeyY,
        bytes calldata attestation
    ) external;

    /**
     * @notice Revoke a registered FIDO key
     * @dev User can revoke their own keys
     * @param credentialIdHash Hash of the credential ID to revoke
     */
    function revokeKey(bytes32 credentialIdHash) external;

    // ============ Verification Functions ============

    /**
     * @notice Verify a WebAuthn assertion
     * @dev Full WebAuthn verification with all checks
     * @param user The user whose key should be verified
     * @param assertion The WebAuthn assertion to verify
     * @param expectedChallenge The challenge that was signed
     * @return valid True if the assertion is valid
     */
    function verifyAssertion(
        address user,
        WebAuthnAssertion calldata assertion,
        bytes32 expectedChallenge
    ) external returns (bool valid);

    /**
     * @notice Verify a P-256 signature directly
     * @dev Lower-level verification for custom implementations
     * @param messageHash The hash of the message that was signed
     * @param r Signature R component
     * @param s Signature S component
     * @param publicKeyX Public key X coordinate
     * @param publicKeyY Public key Y coordinate
     * @return valid True if the signature is valid
     */
    function verifyP256Signature(
        bytes32 messageHash,
        bytes32 r,
        bytes32 s,
        bytes32 publicKeyX,
        bytes32 publicKeyY
    ) external view returns (bool valid);

    /**
     * @notice Generate a challenge for signing
     * @dev Combines nonce, action, and timestamp for replay protection
     * @param action The action being authorized (e.g., "accept-proposal")
     * @param data Additional data to include in challenge (e.g., disputeId)
     * @return challenge The challenge to be signed
     * @return deadline Expiration timestamp for this challenge
     */
    function generateChallenge(
        string calldata action,
        bytes calldata data
    ) external view returns (bytes32 challenge, uint256 deadline);

    // ============ View Functions ============

    /**
     * @notice Get a user's registered FIDO key
     * @param user The user address
     * @param credentialIdHash Hash of the credential ID
     * @return key The FIDO key information
     */
    function getKey(
        address user,
        bytes32 credentialIdHash
    ) external view returns (FIDOKey memory key);

    /**
     * @notice Check if a user has any registered FIDO keys
     * @param user The user address
     * @return hasKey True if user has at least one active key
     */
    function hasRegisteredKey(address user) external view returns (bool hasKey);

    /**
     * @notice Get all credential ID hashes for a user
     * @param user The user address
     * @return credentialIdHashes Array of credential ID hashes
     */
    function getUserKeyIds(address user) external view returns (bytes32[] memory credentialIdHashes);

    /**
     * @notice Get the expected relying party ID hash
     * @return rpIdHash SHA-256 hash of the RP ID
     */
    function getRpIdHash() external view returns (bytes32 rpIdHash);

    /**
     * @notice Challenge deadline duration
     * @return duration Seconds until challenges expire
     */
    function challengeDeadline() external view returns (uint256 duration);
}
