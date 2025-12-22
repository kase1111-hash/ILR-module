// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/**
 * @title IDIDRegistry
 * @notice Interface for Decentralized Identity (DID) Registry
 * @dev Implements sybil-resistant identity verification for NatLangChain
 *
 * Purpose:
 * - Sybil-resistant participation in ILRM disputes
 * - Verifiable Credentials (VC) support for attestations
 * - ERC-725 compatible identity management
 * - Integration with treasury subsidies and reputation
 *
 * DID Format: did:nlc:<chain-id>:<address>
 * Example: did:nlc:10:0x1234...abcd
 */
interface IDIDRegistry {
    // ============ Enums ============

    /// @notice Types of attestations that can be issued
    enum AttestationType {
        Identity,           // Basic identity verification
        KYC,               // Know Your Customer verification
        Reputation,        // Reputation from other protocols
        Governance,        // DAO/governance participation
        Professional,      // Professional credentials
        Custom             // Custom attestation type
    }

    /// @notice DID document status
    enum DIDStatus {
        Inactive,          // Not yet activated
        Active,            // Currently active
        Suspended,         // Temporarily suspended
        Revoked            // Permanently revoked
    }

    // ============ Structs ============

    /// @notice Core DID document on-chain representation
    struct DIDDocument {
        bytes32 did;                    // DID identifier hash
        address controller;             // Address controlling this DID
        address[] delegates;            // Authorized delegates
        uint256 created;                // Creation timestamp
        uint256 updated;                // Last update timestamp
        DIDStatus status;               // Current status
        bytes32 documentHash;           // IPFS hash of full DID document
        uint256 sybilScore;             // Sybil resistance score (0-100, higher = more trusted)
    }

    /// @notice Verifiable Credential representation
    struct Credential {
        bytes32 credentialId;           // Unique credential identifier
        bytes32 did;                    // DID this credential is issued to
        address issuer;                 // Credential issuer address
        AttestationType attestationType; // Type of attestation
        bytes32 claimHash;              // Hash of the claim data
        uint256 issuedAt;               // Issuance timestamp
        uint256 expiresAt;              // Expiration timestamp (0 = never)
        bool revoked;                   // Whether credential is revoked
        uint256 weight;                 // Weight for sybil score calculation (0-100)
    }

    /// @notice Trusted issuer configuration
    struct TrustedIssuer {
        address issuerAddress;          // Issuer's address
        string name;                    // Issuer name/identifier
        AttestationType[] allowedTypes; // Types this issuer can issue
        uint256 trustLevel;             // Trust level (0-100)
        bool active;                    // Whether issuer is active
    }

    // ============ Events ============

    /// @notice Emitted when a DID is registered
    event DIDRegistered(
        bytes32 indexed did,
        address indexed controller,
        bytes32 documentHash
    );

    /// @notice Emitted when a DID is updated
    event DIDUpdated(
        bytes32 indexed did,
        bytes32 oldDocumentHash,
        bytes32 newDocumentHash
    );

    /// @notice Emitted when DID status changes
    event DIDStatusChanged(
        bytes32 indexed did,
        DIDStatus oldStatus,
        DIDStatus newStatus
    );

    /// @notice Emitted when a delegate is added
    event DelegateAdded(
        bytes32 indexed did,
        address indexed delegate,
        uint256 expiresAt
    );

    /// @notice Emitted when a delegate is removed
    event DelegateRemoved(
        bytes32 indexed did,
        address indexed delegate
    );

    /// @notice Emitted when a credential is issued
    event CredentialIssued(
        bytes32 indexed credentialId,
        bytes32 indexed did,
        address indexed issuer,
        AttestationType attestationType
    );

    /// @notice Emitted when a credential is revoked
    event CredentialRevoked(
        bytes32 indexed credentialId,
        address indexed revoker,
        string reason
    );

    /// @notice Emitted when sybil score is updated
    event SybilScoreUpdated(
        bytes32 indexed did,
        uint256 oldScore,
        uint256 newScore
    );

    /// @notice Emitted when a trusted issuer is added
    event TrustedIssuerAdded(
        address indexed issuer,
        string name
    );

    /// @notice Emitted when a trusted issuer is removed
    event TrustedIssuerRemoved(
        address indexed issuer
    );

    // ============ Errors ============

    error DIDAlreadyExists(bytes32 did);
    error DIDNotFound(bytes32 did);
    error DIDNotActive(bytes32 did);
    error NotDIDController(bytes32 did, address caller);
    error NotDIDControllerOrDelegate(bytes32 did, address caller);
    error InvalidDelegate(address delegate);
    error DelegateAlreadyExists(address delegate);
    error DelegateNotFound(address delegate);
    error NotTrustedIssuer(address issuer);
    error InvalidAttestationType(address issuer, AttestationType attestationType);
    error CredentialNotFound(bytes32 credentialId);
    error CredentialAlreadyRevoked(bytes32 credentialId);
    error CredentialExpired(bytes32 credentialId);
    error InsufficientSybilScore(bytes32 did, uint256 required, uint256 actual);
    error AddressAlreadyHasDID(address controller);

    // ============ DID Management Functions ============

    /**
     * @notice Register a new DID for the caller
     * @param documentHash IPFS hash of the full DID document
     * @return did The registered DID identifier
     */
    function registerDID(bytes32 documentHash) external returns (bytes32 did);

    /**
     * @notice Update DID document
     * @param did The DID to update
     * @param newDocumentHash New IPFS hash of the DID document
     */
    function updateDIDDocument(bytes32 did, bytes32 newDocumentHash) external;

    /**
     * @notice Change DID controller (ownership transfer)
     * @param did The DID to transfer
     * @param newController New controller address
     */
    function changeController(bytes32 did, address newController) external;

    /**
     * @notice Suspend a DID (temporary)
     * @param did The DID to suspend
     * @param reason Reason for suspension
     */
    function suspendDID(bytes32 did, string calldata reason) external;

    /**
     * @notice Reactivate a suspended DID
     * @param did The DID to reactivate
     */
    function reactivateDID(bytes32 did) external;

    /**
     * @notice Revoke a DID permanently
     * @param did The DID to revoke
     * @param reason Reason for revocation
     */
    function revokeDID(bytes32 did, string calldata reason) external;

    // ============ Delegate Management ============

    /**
     * @notice Add a delegate to a DID
     * @param did The DID to add delegate to
     * @param delegate Address of the delegate
     * @param expiresAt Expiration timestamp (0 = never)
     */
    function addDelegate(bytes32 did, address delegate, uint256 expiresAt) external;

    /**
     * @notice Remove a delegate from a DID
     * @param did The DID to remove delegate from
     * @param delegate Address of the delegate to remove
     */
    function removeDelegate(bytes32 did, address delegate) external;

    /**
     * @notice Check if an address is a valid delegate for a DID
     * @param did The DID to check
     * @param delegate The address to check
     * @return True if delegate is valid and not expired
     */
    function isValidDelegate(bytes32 did, address delegate) external view returns (bool);

    // ============ Credential Management ============

    /**
     * @notice Issue a verifiable credential to a DID
     * @param did The DID to issue credential to
     * @param attestationType Type of attestation
     * @param claimHash Hash of the claim data
     * @param expiresAt Expiration timestamp (0 = never)
     * @param weight Weight for sybil score (0-100)
     * @return credentialId The issued credential ID
     */
    function issueCredential(
        bytes32 did,
        AttestationType attestationType,
        bytes32 claimHash,
        uint256 expiresAt,
        uint256 weight
    ) external returns (bytes32 credentialId);

    /**
     * @notice Revoke a credential
     * @param credentialId The credential to revoke
     * @param reason Reason for revocation
     */
    function revokeCredential(bytes32 credentialId, string calldata reason) external;

    /**
     * @notice Verify a credential is valid
     * @param credentialId The credential to verify
     * @return valid True if credential is valid, not expired, and not revoked
     */
    function verifyCredential(bytes32 credentialId) external view returns (bool valid);

    /**
     * @notice Get all credentials for a DID
     * @param did The DID to get credentials for
     * @return Array of credential IDs
     */
    function getCredentials(bytes32 did) external view returns (bytes32[] memory);

    // ============ Sybil Resistance ============

    /**
     * @notice Calculate and update sybil score for a DID
     * @dev Based on credentials, their weights, and issuer trust levels
     * @param did The DID to calculate score for
     * @return score The calculated sybil score (0-100)
     */
    function calculateSybilScore(bytes32 did) external returns (uint256 score);

    /**
     * @notice Check if DID meets minimum sybil score requirement
     * @param did The DID to check
     * @param requiredScore Minimum required score
     * @return True if DID meets requirement
     */
    function meetsSybilRequirement(bytes32 did, uint256 requiredScore) external view returns (bool);

    /**
     * @notice Get current sybil score for a DID
     * @param did The DID to query
     * @return Current sybil score
     */
    function getSybilScore(bytes32 did) external view returns (uint256);

    // ============ Issuer Management (Admin) ============

    /**
     * @notice Add a trusted credential issuer
     * @param issuer Issuer address
     * @param name Issuer name
     * @param allowedTypes Types this issuer can issue
     * @param trustLevel Trust level (0-100)
     */
    function addTrustedIssuer(
        address issuer,
        string calldata name,
        AttestationType[] calldata allowedTypes,
        uint256 trustLevel
    ) external;

    /**
     * @notice Remove a trusted issuer
     * @param issuer Issuer address to remove
     */
    function removeTrustedIssuer(address issuer) external;

    /**
     * @notice Update trusted issuer configuration
     * @param issuer Issuer address
     * @param allowedTypes New allowed types
     * @param trustLevel New trust level
     */
    function updateTrustedIssuer(
        address issuer,
        AttestationType[] calldata allowedTypes,
        uint256 trustLevel
    ) external;

    /**
     * @notice Check if an address is a trusted issuer
     * @param issuer Address to check
     * @return True if trusted issuer
     */
    function isTrustedIssuer(address issuer) external view returns (bool);

    // ============ View Functions ============

    /**
     * @notice Get DID document for an address
     * @param controller Controller address
     * @return The DID document
     */
    function getDIDByController(address controller) external view returns (DIDDocument memory);

    /**
     * @notice Get DID document by DID identifier
     * @param did The DID identifier
     * @return The DID document
     */
    function getDIDDocument(bytes32 did) external view returns (DIDDocument memory);

    /**
     * @notice Check if an address has a registered DID
     * @param controller Address to check
     * @return True if address has a DID
     */
    function hasDID(address controller) external view returns (bool);

    /**
     * @notice Get the DID for an address
     * @param controller Controller address
     * @return The DID identifier (bytes32(0) if none)
     */
    function addressToDID(address controller) external view returns (bytes32);

    /**
     * @notice Resolve DID to controller address
     * @param did The DID to resolve
     * @return Controller address
     */
    function resolveDID(bytes32 did) external view returns (address);

    /**
     * @notice Get credential details
     * @param credentialId The credential ID
     * @return The credential struct
     */
    function getCredential(bytes32 credentialId) external view returns (Credential memory);

    /**
     * @notice Get trusted issuer details
     * @param issuer Issuer address
     * @return The trusted issuer struct
     */
    function getTrustedIssuer(address issuer) external view returns (TrustedIssuer memory);

    /**
     * @notice Generate DID identifier from address
     * @param controller Controller address
     * @return The DID identifier hash
     */
    function generateDID(address controller) external view returns (bytes32);
}
