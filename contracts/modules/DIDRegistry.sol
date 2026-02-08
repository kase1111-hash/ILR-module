// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "../interfaces/IDIDRegistry.sol";

/**
 * @title DIDRegistry
 * @notice Decentralized Identity Registry for NatLangChain Protocol
 * @dev Implements sybil-resistant identity verification
 *
 * Features:
 * - ERC-725 compatible DID management
 * - Verifiable Credentials (VC) support
 * - Sybil resistance through weighted attestations
 * - Trusted issuer framework
 * - Delegate support for key rotation
 * - FIX I-02: Two-step ownership transfer via Ownable2Step
 *
 * DID Format: did:nlc:<chain-id>:<address>
 * On-chain representation: keccak256(abi.encodePacked("did:nlc:", chainId, ":", address))
 */
contract DIDRegistry is IDIDRegistry, ReentrancyGuard, Pausable, Ownable2Step {
    // ============ Constants ============

    /// @notice Maximum delegates per DID
    uint256 public constant MAX_DELEGATES = 10;

    /// @notice Maximum credentials per DID for score calculation
    uint256 public constant MAX_CREDENTIALS_FOR_SCORE = 50;

    /// @notice Maximum sybil score
    uint256 public constant MAX_SYBIL_SCORE = 100;

    /// @notice Default minimum sybil score for protocol participation
    uint256 public constant DEFAULT_MIN_SYBIL_SCORE = 20;

    /// @notice FIX L-02: Maximum attestation types per issuer
    /// @dev Prevents unbounded loops in _canIssueType. 6 types defined in enum.
    uint256 public constant MAX_ATTESTATION_TYPES = 10;

    // ============ State Variables ============

    /// @notice DID document storage
    mapping(bytes32 => DIDDocument) private _didDocuments;

    /// @notice Address to DID mapping (one DID per address)
    mapping(address => bytes32) private _addressToDID;

    /// @notice Delegate mappings: did => delegate => expiresAt
    mapping(bytes32 => mapping(address => uint256)) private _delegates;

    /// @notice Delegate list for enumeration
    mapping(bytes32 => address[]) private _delegateList;

    /// @notice Credential storage
    mapping(bytes32 => Credential) private _credentials;

    /// @notice DID to credentials mapping
    mapping(bytes32 => bytes32[]) private _didCredentials;

    /// @notice Credential counter for unique IDs
    uint256 private _credentialCounter;

    /// @notice Trusted issuers
    mapping(address => TrustedIssuer) private _trustedIssuers;

    /// @notice Trusted issuer list for enumeration
    address[] private _trustedIssuerList;

    /// @notice Minimum sybil score required for protocol participation
    uint256 public minSybilScore;

    /// @notice Total DIDs registered
    uint256 public totalDIDs;

    /// @notice Total credentials issued
    uint256 public totalCredentials;

    // ============ Constructor ============

    constructor() Ownable(msg.sender) {
        minSybilScore = DEFAULT_MIN_SYBIL_SCORE;
    }

    // ============ DID Management Functions ============

    /**
     * @inheritdoc IDIDRegistry
     */
    function registerDID(bytes32 documentHash) external override nonReentrant whenNotPaused returns (bytes32 did) {
        // One DID per address
        if (_addressToDID[msg.sender] != bytes32(0)) {
            revert AddressAlreadyHasDID(msg.sender);
        }

        // Generate DID
        did = generateDID(msg.sender);

        // Check DID doesn't already exist (shouldn't happen with unique addresses)
        if (_didDocuments[did].controller != address(0)) {
            revert DIDAlreadyExists(did);
        }

        // Create DID document
        _didDocuments[did] = DIDDocument({
            did: did,
            controller: msg.sender,
            delegates: new address[](0),
            created: block.timestamp,
            updated: block.timestamp,
            status: DIDStatus.Active,
            documentHash: documentHash,
            sybilScore: 0  // Starts at 0, increases with credentials
        });

        // Map address to DID
        _addressToDID[msg.sender] = did;
        totalDIDs++;

        emit DIDRegistered(did, msg.sender, documentHash);
    }

    /**
     * @inheritdoc IDIDRegistry
     */
    function updateDIDDocument(bytes32 did, bytes32 newDocumentHash) external override nonReentrant whenNotPaused {
        _requireControllerOrDelegate(did);
        _requireActiveDID(did);

        bytes32 oldHash = _didDocuments[did].documentHash;
        _didDocuments[did].documentHash = newDocumentHash;
        _didDocuments[did].updated = block.timestamp;

        emit DIDUpdated(did, oldHash, newDocumentHash);
    }

    /**
     * @inheritdoc IDIDRegistry
     */
    function changeController(bytes32 did, address newController) external override nonReentrant whenNotPaused {
        _requireController(did);
        _requireActiveDID(did);

        if (newController == address(0)) revert InvalidDelegate(newController);
        if (_addressToDID[newController] != bytes32(0)) {
            revert AddressAlreadyHasDID(newController);
        }

        address oldController = _didDocuments[did].controller;

        // Update mappings
        delete _addressToDID[oldController];
        _addressToDID[newController] = did;
        _didDocuments[did].controller = newController;
        _didDocuments[did].updated = block.timestamp;

        emit DIDStatusChanged(did, DIDStatus.Active, DIDStatus.Active);
    }

    /**
     * @inheritdoc IDIDRegistry
     */
    function suspendDID(bytes32 did, string calldata) external override nonReentrant whenNotPaused {
        // FIX: Check DID exists before _requireController (which only checks msg.sender)
        if (_didDocuments[did].controller == address(0)) {
            revert DIDNotFound(did);
        }
        _requireController(did);

        DIDStatus oldStatus = _didDocuments[did].status;
        if (oldStatus == DIDStatus.Revoked) revert DIDNotActive(did);

        _didDocuments[did].status = DIDStatus.Suspended;
        _didDocuments[did].updated = block.timestamp;

        emit DIDStatusChanged(did, oldStatus, DIDStatus.Suspended);
    }

    /**
     * @inheritdoc IDIDRegistry
     */
    function reactivateDID(bytes32 did) external override nonReentrant whenNotPaused {
        // FIX: Check DID exists
        if (_didDocuments[did].controller == address(0)) {
            revert DIDNotFound(did);
        }
        _requireController(did);

        DIDStatus oldStatus = _didDocuments[did].status;
        if (oldStatus != DIDStatus.Suspended) revert DIDNotActive(did);

        _didDocuments[did].status = DIDStatus.Active;
        _didDocuments[did].updated = block.timestamp;

        emit DIDStatusChanged(did, oldStatus, DIDStatus.Active);
    }

    /**
     * @inheritdoc IDIDRegistry
     */
    function revokeDID(bytes32 did, string calldata) external override nonReentrant whenNotPaused {
        // FIX: Check DID exists
        if (_didDocuments[did].controller == address(0)) {
            revert DIDNotFound(did);
        }
        _requireController(did);

        DIDStatus oldStatus = _didDocuments[did].status;
        _didDocuments[did].status = DIDStatus.Revoked;
        _didDocuments[did].updated = block.timestamp;

        // Clear address mapping
        delete _addressToDID[_didDocuments[did].controller];

        emit DIDStatusChanged(did, oldStatus, DIDStatus.Revoked);
    }

    // ============ Delegate Management ============

    /**
     * @inheritdoc IDIDRegistry
     */
    function addDelegate(bytes32 did, address delegate, uint256 expiresAt) external override nonReentrant whenNotPaused {
        _requireController(did);
        _requireActiveDID(did);

        if (delegate == address(0)) revert InvalidDelegate(delegate);
        if (_delegates[did][delegate] != 0) revert DelegateAlreadyExists(delegate);
        if (_delegateList[did].length >= MAX_DELEGATES) revert InvalidDelegate(delegate);

        // Set expiration (0 means max uint for never expires)
        uint256 expiry = expiresAt == 0 ? type(uint256).max : expiresAt;
        _delegates[did][delegate] = expiry;
        _delegateList[did].push(delegate);

        // Update document delegates array
        _didDocuments[did].delegates.push(delegate);
        _didDocuments[did].updated = block.timestamp;

        emit DelegateAdded(did, delegate, expiresAt);
    }

    /**
     * @inheritdoc IDIDRegistry
     */
    function removeDelegate(bytes32 did, address delegate) external override nonReentrant {
        _requireController(did);

        if (_delegates[did][delegate] == 0) revert DelegateNotFound(delegate);

        delete _delegates[did][delegate];

        // Remove from delegate list
        address[] storage delegateList = _delegateList[did];
        for (uint256 i = 0; i < delegateList.length; ++i) {
            if (delegateList[i] == delegate) {
                delegateList[i] = delegateList[delegateList.length - 1];
                delegateList.pop();
                break;
            }
        }

        // Update document delegates array
        _didDocuments[did].delegates = delegateList;
        _didDocuments[did].updated = block.timestamp;

        emit DelegateRemoved(did, delegate);
    }

    /**
     * @inheritdoc IDIDRegistry
     */
    function isValidDelegate(bytes32 did, address delegate) external view override returns (bool) {
        uint256 expiry = _delegates[did][delegate];
        return expiry != 0 && block.timestamp < expiry;
    }

    // ============ Credential Management ============

    /**
     * @inheritdoc IDIDRegistry
     */
    function issueCredential(
        bytes32 did,
        AttestationType attestationType,
        bytes32 claimHash,
        uint256 expiresAt,
        uint256 weight
    ) external override nonReentrant whenNotPaused returns (bytes32 credentialId) {
        // Verify issuer is trusted
        if (!_isTrustedIssuerInternal(msg.sender)) {
            revert NotTrustedIssuer(msg.sender);
        }

        // Verify issuer can issue this type
        if (!_canIssueType(msg.sender, attestationType)) {
            revert InvalidAttestationType(msg.sender, attestationType);
        }

        // Verify DID exists and is active
        _requireActiveDID(did);

        // Cap weight at 100
        if (weight > 100) weight = 100;

        // Generate credential ID
        _credentialCounter++;
        credentialId = keccak256(abi.encodePacked(
            did,
            msg.sender,
            attestationType,
            claimHash,
            block.timestamp,
            _credentialCounter
        ));

        // Store credential
        _credentials[credentialId] = Credential({
            credentialId: credentialId,
            did: did,
            issuer: msg.sender,
            attestationType: attestationType,
            claimHash: claimHash,
            issuedAt: block.timestamp,
            expiresAt: expiresAt,
            revoked: false,
            weight: weight
        });

        // Add to DID's credentials
        _didCredentials[did].push(credentialId);
        totalCredentials++;

        // Recalculate sybil score
        _updateSybilScore(did);

        emit CredentialIssued(credentialId, did, msg.sender, attestationType);
    }

    /**
     * @inheritdoc IDIDRegistry
     */
    function revokeCredential(bytes32 credentialId, string calldata reason) external override nonReentrant {
        Credential storage cred = _credentials[credentialId];

        if (cred.issuer == address(0)) revert CredentialNotFound(credentialId);
        if (cred.revoked) revert CredentialAlreadyRevoked(credentialId);

        // Only issuer or DID controller can revoke
        if (msg.sender != cred.issuer && msg.sender != _didDocuments[cred.did].controller) {
            revert NotDIDController(cred.did, msg.sender);
        }

        cred.revoked = true;

        // Recalculate sybil score
        _updateSybilScore(cred.did);

        emit CredentialRevoked(credentialId, msg.sender, reason);
    }

    /**
     * @notice FIX M-04: Clean up revoked and expired credentials from DID's credential array
     * @dev Removes credentials that are revoked or expired to prevent unbounded array growth
     * @param did The DID to clean up credentials for
     * @return removedCount Number of credentials removed
     */
    function cleanupCredentials(bytes32 did) external nonReentrant returns (uint256 removedCount) {
        bytes32[] storage credIds = _didCredentials[did];
        uint256 i = 0;

        while (i < credIds.length) {
            Credential storage cred = _credentials[credIds[i]];

            // Check if credential should be removed (revoked or expired)
            bool shouldRemove = cred.revoked ||
                (cred.expiresAt != 0 && block.timestamp > cred.expiresAt);

            if (shouldRemove) {
                // Swap with last element and pop
                credIds[i] = credIds[credIds.length - 1];
                credIds.pop();
                removedCount++;
                // Don't increment i - check the swapped element
            } else {
                i++;
            }
        }

        // Recalculate sybil score after cleanup
        if (removedCount > 0) {
            _updateSybilScore(did);
        }
    }

    /**
     * @notice Get count of active (non-revoked, non-expired) credentials for a DID
     * @dev Iterates through all credentials checking revocation status and expiration
     * @param did The DID to check credentials for
     * @return count Number of active (valid) credentials associated with the DID
     */
    function getActiveCredentialCount(bytes32 did) external view returns (uint256 count) {
        bytes32[] storage credIds = _didCredentials[did];
        for (uint256 i = 0; i < credIds.length; ++i) {
            Credential storage cred = _credentials[credIds[i]];
            if (!cred.revoked && (cred.expiresAt == 0 || block.timestamp <= cred.expiresAt)) {
                ++count;
            }
        }
    }

    /**
     * @inheritdoc IDIDRegistry
     */
    function verifyCredential(bytes32 credentialId) external view override returns (bool valid) {
        Credential storage cred = _credentials[credentialId];

        if (cred.issuer == address(0)) return false;
        if (cred.revoked) return false;
        if (cred.expiresAt != 0 && block.timestamp > cred.expiresAt) return false;
        if (!_isTrustedIssuerInternal(cred.issuer)) return false;

        return true;
    }

    /**
     * @inheritdoc IDIDRegistry
     */
    function getCredentials(bytes32 did) external view override returns (bytes32[] memory) {
        return _didCredentials[did];
    }

    // ============ Sybil Resistance ============

    /**
     * @inheritdoc IDIDRegistry
     */
    function calculateSybilScore(bytes32 did) external override returns (uint256 score) {
        return _updateSybilScore(did);
    }

    /**
     * @inheritdoc IDIDRegistry
     */
    function meetsSybilRequirement(bytes32 did, uint256 requiredScore) external view override returns (bool) {
        if (_didDocuments[did].controller == address(0)) return false;
        if (_didDocuments[did].status != DIDStatus.Active) return false;
        return _didDocuments[did].sybilScore >= requiredScore;
    }

    /**
     * @inheritdoc IDIDRegistry
     */
    function getSybilScore(bytes32 did) external view override returns (uint256) {
        return _didDocuments[did].sybilScore;
    }

    /**
     * @notice Internal function to update sybil score
     */
    function _updateSybilScore(bytes32 did) internal returns (uint256 score) {
        bytes32[] storage credIds = _didCredentials[did];
        uint256 totalWeight = 0;
        uint256 weightedScore = 0;
        uint256 count = credIds.length > MAX_CREDENTIALS_FOR_SCORE ? MAX_CREDENTIALS_FOR_SCORE : credIds.length;

        for (uint256 i = 0; i < count; ++i) {
            Credential storage cred = _credentials[credIds[i]];

            // Skip revoked or expired credentials
            if (cred.revoked) continue;
            if (cred.expiresAt != 0 && block.timestamp > cred.expiresAt) continue;

            // Get issuer trust level
            TrustedIssuer storage issuer = _trustedIssuers[cred.issuer];
            if (!issuer.active) continue;

            // Calculate weighted contribution: (credential weight * issuer trust) / 100
            uint256 contribution = (cred.weight * issuer.trustLevel) / 100;
            weightedScore += contribution;
            totalWeight += cred.weight;
        }

        // FIX: Properly normalize score to 0-100 range using weighted average
        if (totalWeight > 0) {
            // Compute weighted average: (sum of contributions * 100) / totalWeight
            // This normalizes to a 0-100 scale based on average trust level
            score = (weightedScore * 100) / totalWeight;

            // Cap at maximum score
            if (score > MAX_SYBIL_SCORE) {
                score = MAX_SYBIL_SCORE;
            }
        }

        uint256 oldScore = _didDocuments[did].sybilScore;
        _didDocuments[did].sybilScore = score;

        if (oldScore != score) {
            emit SybilScoreUpdated(did, oldScore, score);
        }

        return score;
    }

    // ============ Issuer Management (Admin) ============

    /**
     * @inheritdoc IDIDRegistry
     */
    function addTrustedIssuer(
        address issuer,
        string calldata name,
        AttestationType[] calldata allowedTypes,
        uint256 trustLevel
    ) external override onlyOwner {
        if (issuer == address(0)) revert InvalidDelegate(issuer);
        if (trustLevel > 100) trustLevel = 100;
        // FIX L-02: Limit attestation types to prevent unbounded loops
        require(allowedTypes.length <= MAX_ATTESTATION_TYPES, "Too many attestation types");

        _trustedIssuers[issuer] = TrustedIssuer({
            issuerAddress: issuer,
            name: name,
            allowedTypes: allowedTypes,
            trustLevel: trustLevel,
            active: true
        });

        // Add to list if not already present
        bool found = false;
        for (uint256 i = 0; i < _trustedIssuerList.length; ++i) {
            if (_trustedIssuerList[i] == issuer) {
                found = true;
                break;
            }
        }
        if (!found) {
            _trustedIssuerList.push(issuer);
        }

        emit TrustedIssuerAdded(issuer, name);
    }

    /**
     * @inheritdoc IDIDRegistry
     */
    function removeTrustedIssuer(address issuer) external override onlyOwner {
        if (!_trustedIssuers[issuer].active) revert NotTrustedIssuer(issuer);

        _trustedIssuers[issuer].active = false;

        emit TrustedIssuerRemoved(issuer);
    }

    /**
     * @inheritdoc IDIDRegistry
     */
    function updateTrustedIssuer(
        address issuer,
        AttestationType[] calldata allowedTypes,
        uint256 trustLevel
    ) external override onlyOwner {
        if (!_trustedIssuers[issuer].active) revert NotTrustedIssuer(issuer);
        if (trustLevel > 100) trustLevel = 100;
        // FIX L-02: Limit attestation types to prevent unbounded loops
        require(allowedTypes.length <= MAX_ATTESTATION_TYPES, "Too many attestation types");

        _trustedIssuers[issuer].allowedTypes = allowedTypes;
        _trustedIssuers[issuer].trustLevel = trustLevel;
    }

    /**
     * @inheritdoc IDIDRegistry
     */
    function isTrustedIssuer(address issuer) external view override returns (bool) {
        return _isTrustedIssuerInternal(issuer);
    }

    /**
     * @notice Internal trusted issuer check
     */
    function _isTrustedIssuerInternal(address issuer) internal view returns (bool) {
        return _trustedIssuers[issuer].active;
    }

    /**
     * @notice Check if issuer can issue a specific type
     */
    function _canIssueType(address issuer, AttestationType attestationType) internal view returns (bool) {
        TrustedIssuer storage ti = _trustedIssuers[issuer];
        for (uint256 i = 0; i < ti.allowedTypes.length; ++i) {
            if (ti.allowedTypes[i] == attestationType) {
                return true;
            }
        }
        return false;
    }

    // ============ View Functions ============

    /**
     * @inheritdoc IDIDRegistry
     */
    function getDIDByController(address controller) external view override returns (DIDDocument memory) {
        bytes32 did = _addressToDID[controller];
        return _didDocuments[did];
    }

    /**
     * @inheritdoc IDIDRegistry
     */
    function getDIDDocument(bytes32 did) external view override returns (DIDDocument memory) {
        return _didDocuments[did];
    }

    /**
     * @inheritdoc IDIDRegistry
     */
    function hasDID(address controller) external view override returns (bool) {
        return _addressToDID[controller] != bytes32(0);
    }

    /**
     * @inheritdoc IDIDRegistry
     */
    function addressToDID(address controller) external view override returns (bytes32) {
        return _addressToDID[controller];
    }

    /**
     * @inheritdoc IDIDRegistry
     */
    function resolveDID(bytes32 did) external view override returns (address) {
        return _didDocuments[did].controller;
    }

    /**
     * @inheritdoc IDIDRegistry
     */
    function getCredential(bytes32 credentialId) external view override returns (Credential memory) {
        return _credentials[credentialId];
    }

    /**
     * @inheritdoc IDIDRegistry
     */
    function getTrustedIssuer(address issuer) external view override returns (TrustedIssuer memory) {
        return _trustedIssuers[issuer];
    }

    /**
     * @inheritdoc IDIDRegistry
     */
    function generateDID(address controller) public view override returns (bytes32) {
        return keccak256(abi.encodePacked("did:nlc:", block.chainid, ":", controller));
    }

    // ============ Admin Functions ============

    /**
     * @notice Set minimum sybil score for protocol participation
     * @param score New minimum score (0-100)
     */
    function setMinSybilScore(uint256 score) external onlyOwner {
        if (score > MAX_SYBIL_SCORE) score = MAX_SYBIL_SCORE;
        minSybilScore = score;
    }

    /**
     * @notice Pause the registry
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause the registry
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // ============ Internal Helpers ============

    /**
     * @notice Require caller is DID controller
     */
    function _requireController(bytes32 did) internal view {
        if (_didDocuments[did].controller != msg.sender) {
            revert NotDIDController(did, msg.sender);
        }
    }

    /**
     * @notice Require caller is controller or delegate
     */
    function _requireControllerOrDelegate(bytes32 did) internal view {
        if (_didDocuments[did].controller == msg.sender) return;

        uint256 expiry = _delegates[did][msg.sender];
        if (expiry == 0 || block.timestamp >= expiry) {
            revert NotDIDControllerOrDelegate(did, msg.sender);
        }
    }

    /**
     * @notice Require DID is active
     */
    function _requireActiveDID(bytes32 did) internal view {
        if (_didDocuments[did].controller == address(0)) {
            revert DIDNotFound(did);
        }
        if (_didDocuments[did].status != DIDStatus.Active) {
            revert DIDNotActive(did);
        }
    }
}
