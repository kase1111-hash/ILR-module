// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IAssetRegistry.sol";

/**
 * @title NatLangChainAssetRegistry
 * @notice Registry for IP assets and licenses in the NatLangChain ecosystem
 * @dev Manages asset ownership, licensing state, and dispute-related freezes
 *
 * Key Features:
 * - Register and track IP assets
 * - Grant and revoke licenses
 * - Freeze assets during disputes
 * - Apply fallback licenses on dispute resolution
 */
/**
 * FIX L-NEW-02: Added Ownable2Step for two-step ownership transfer
 * Consistent with I-02 fix applied to other contracts
 */
contract NatLangChainAssetRegistry is IAssetRegistry, ReentrancyGuard, Ownable2Step {
    // ============ Constants ============

    /// @notice FIX H-04: Maximum assets per owner to prevent DoS in freeze/unfreeze loops
    uint256 public constant MAX_ASSETS_PER_OWNER = 100;

    // ============ State Variables ============

    /// @notice Authorized ILRM contracts
    mapping(address => bool) private _authorizedILRM;

    /// @notice Assets by ID
    mapping(bytes32 => Asset) private _assets;

    /// @notice License grants: assetId => licensee => grant
    mapping(bytes32 => mapping(address => LicenseGrant)) private _licenses;

    /// @notice Assets owned by address
    mapping(address => bytes32[]) private _ownerAssets;

    /// @notice Asset index in owner's array (for efficient removal)
    mapping(bytes32 => uint256) private _assetOwnerIndex;

    /// @notice Dispute to frozen assets mapping
    mapping(uint256 => bytes32[]) private _disputeFrozenAssets;

    /// @notice Total registered assets
    uint256 public totalAssets;

    /// @notice Total active licenses
    uint256 public totalLicenses;

    // ============ Errors ============

    error AssetAlreadyExists(bytes32 assetId);
    error AssetNotFound(bytes32 assetId);
    error AssetFrozen(bytes32 assetId);
    error NotAssetOwner(address caller, address owner);
    error NotAuthorizedILRM(address caller);
    error LicenseNotFound(bytes32 assetId, address licensee);
    error LicenseExpired(bytes32 assetId, address licensee);
    error InvalidAddress();
    error InvalidDuration();
    error MaxAssetsExceeded(address owner, uint256 limit);

    // ============ Constructor ============

    constructor() Ownable(msg.sender) {}

    // ============ Modifiers ============

    modifier onlyAuthorizedILRM() {
        if (!_authorizedILRM[msg.sender]) revert NotAuthorizedILRM(msg.sender);
        _;
    }

    modifier assetExists(bytes32 assetId) {
        if (_assets[assetId].owner == address(0)) revert AssetNotFound(assetId);
        _;
    }

    modifier assetNotFrozen(bytes32 assetId) {
        if (_assets[assetId].status == FreezeStatus.Frozen) revert AssetFrozen(assetId);
        _;
    }

    // ============ Asset Management ============

    /**
     * @inheritdoc IAssetRegistry
     * @dev FIX H-05: Only the owner can register assets for themselves
     *      This prevents attackers from registering fake assets under victim's address
     */
    function registerAsset(
        bytes32 assetId,
        address owner,
        bytes32 licenseTermsHash
    ) external override nonReentrant {
        if (owner == address(0)) revert InvalidAddress();
        // FIX H-05: Only owner can register their own assets
        // Prevents attack where attacker registers fake assets under victim's address
        if (msg.sender != owner) revert NotAssetOwner(msg.sender, owner);
        if (_assets[assetId].owner != address(0)) revert AssetAlreadyExists(assetId);
        // FIX H-04: Prevent DoS by limiting assets per owner
        if (_ownerAssets[owner].length >= MAX_ASSETS_PER_OWNER) {
            revert MaxAssetsExceeded(owner, MAX_ASSETS_PER_OWNER);
        }

        _assets[assetId] = Asset({
            assetId: assetId,
            owner: owner,
            licenseTermsHash: licenseTermsHash,
            status: FreezeStatus.Active,
            disputeId: 0,
            lastModified: block.timestamp
        });

        _assetOwnerIndex[assetId] = _ownerAssets[owner].length;
        _ownerAssets[owner].push(assetId);
        totalAssets++;

        emit AssetRegistered(assetId, owner, licenseTermsHash);
    }

    /**
     * @notice Transfer asset ownership
     * @param assetId The asset to transfer
     * @param newOwner New owner address
     */
    function transferAsset(
        bytes32 assetId,
        address newOwner
    ) external assetExists(assetId) assetNotFrozen(assetId) nonReentrant {
        Asset storage asset = _assets[assetId];
        if (msg.sender != asset.owner) revert NotAssetOwner(msg.sender, asset.owner);
        if (newOwner == address(0)) revert InvalidAddress();
        // FIX HIGH: Prevent MAX_ASSETS_PER_OWNER bypass via transfers
        if (_ownerAssets[newOwner].length >= MAX_ASSETS_PER_OWNER) {
            revert MaxAssetsExceeded(newOwner, MAX_ASSETS_PER_OWNER);
        }

        address oldOwner = asset.owner;

        // Remove from old owner's list
        uint256 index = _assetOwnerIndex[assetId];
        uint256 lastIndex = _ownerAssets[oldOwner].length - 1;
        if (index != lastIndex) {
            bytes32 lastAssetId = _ownerAssets[oldOwner][lastIndex];
            _ownerAssets[oldOwner][index] = lastAssetId;
            _assetOwnerIndex[lastAssetId] = index;
        }
        _ownerAssets[oldOwner].pop();

        // Add to new owner's list
        _assetOwnerIndex[assetId] = _ownerAssets[newOwner].length;
        _ownerAssets[newOwner].push(assetId);

        asset.owner = newOwner;
        asset.lastModified = block.timestamp;
    }

    // ============ License Management ============

    /**
     * @inheritdoc IAssetRegistry
     */
    function grantLicense(
        bytes32 assetId,
        address licensee,
        bytes32 termsHash,
        uint256 duration,
        uint256 royaltyBps,
        bool nonExclusive
    ) external override assetExists(assetId) assetNotFrozen(assetId) nonReentrant {
        Asset storage asset = _assets[assetId];
        if (msg.sender != asset.owner) revert NotAssetOwner(msg.sender, asset.owner);
        if (licensee == address(0)) revert InvalidAddress();
        if (duration == 0) revert InvalidDuration();

        LicenseGrant storage grant = _licenses[assetId][licensee];

        // If updating existing license, don't increment total
        bool isNew = !grant.active;

        grant.assetId = assetId;
        grant.licensee = licensee;
        grant.termsHash = termsHash;
        grant.grantedAt = block.timestamp;
        grant.expiresAt = block.timestamp + duration;
        grant.royaltyBps = royaltyBps;
        grant.nonExclusive = nonExclusive;
        grant.active = true;

        if (isNew) {
            totalLicenses++;
        }

        emit LicenseModified(assetId, licensee, bytes32(0), termsHash);
    }

    /**
     * @inheritdoc IAssetRegistry
     */
    function revokeLicense(
        bytes32 assetId,
        address licensee
    ) external override assetExists(assetId) nonReentrant {
        Asset storage asset = _assets[assetId];
        if (msg.sender != asset.owner && !_authorizedILRM[msg.sender]) {
            revert NotAssetOwner(msg.sender, asset.owner);
        }

        LicenseGrant storage grant = _licenses[assetId][licensee];
        if (!grant.active) revert LicenseNotFound(assetId, licensee);

        bytes32 oldTermsHash = grant.termsHash;
        grant.active = false;
        grant.expiresAt = block.timestamp;
        totalLicenses--;

        emit LicenseModified(assetId, licensee, oldTermsHash, bytes32(0));
    }

    // ============ ILRM Integration ============

    /**
     * @inheritdoc IAssetRegistry
     */
    function freezeAssets(
        uint256 disputeId,
        address party
    ) external override onlyAuthorizedILRM nonReentrant {
        bytes32[] storage partyAssets = _ownerAssets[party];
        bytes32[] storage frozen = _disputeFrozenAssets[disputeId];

        for (uint256 i = 0; i < partyAssets.length; i++) {
            bytes32 assetId = partyAssets[i];
            Asset storage asset = _assets[assetId];

            if (asset.status == FreezeStatus.Active) {
                asset.status = FreezeStatus.Frozen;
                asset.disputeId = disputeId;
                asset.lastModified = block.timestamp;
                frozen.push(assetId);
            }
        }

        emit AssetsFrozen(disputeId, party, frozen);
    }

    /**
     * @inheritdoc IAssetRegistry
     */
    function unfreezeAssets(
        uint256 disputeId,
        bytes calldata outcome
    ) external override onlyAuthorizedILRM nonReentrant {
        bytes32[] storage frozen = _disputeFrozenAssets[disputeId];

        for (uint256 i = 0; i < frozen.length; i++) {
            bytes32 assetId = frozen[i];
            Asset storage asset = _assets[assetId];

            if (asset.disputeId == disputeId) {
                asset.status = FreezeStatus.Active;
                asset.disputeId = 0;
                asset.lastModified = block.timestamp;
            }
        }

        emit AssetsUnfrozen(disputeId, outcome);

        // Clear frozen assets for this dispute
        delete _disputeFrozenAssets[disputeId];
    }

    /**
     * @inheritdoc IAssetRegistry
     */
    function applyFallbackLicense(
        uint256 disputeId,
        bytes32 fallbackTermsHash
    ) external override onlyAuthorizedILRM nonReentrant {
        bytes32[] storage frozen = _disputeFrozenAssets[disputeId];

        for (uint256 i = 0; i < frozen.length; i++) {
            bytes32 assetId = frozen[i];
            Asset storage asset = _assets[assetId];

            // Update the asset's license terms to fallback
            asset.licenseTermsHash = fallbackTermsHash;
            asset.lastModified = block.timestamp;
        }

        emit FallbackLicenseApplied(disputeId, fallbackTermsHash, frozen);
    }

    // ============ View Functions ============

    /**
     * @inheritdoc IAssetRegistry
     */
    function getAsset(bytes32 assetId) external view override returns (Asset memory) {
        return _assets[assetId];
    }

    /**
     * @inheritdoc IAssetRegistry
     */
    function getLicense(
        bytes32 assetId,
        address licensee
    ) external view override returns (LicenseGrant memory) {
        return _licenses[assetId][licensee];
    }

    /**
     * @inheritdoc IAssetRegistry
     */
    function isFrozen(bytes32 assetId) external view override returns (bool) {
        return _assets[assetId].status == FreezeStatus.Frozen;
    }

    /**
     * @inheritdoc IAssetRegistry
     */
    function getAssetsByOwner(address owner) external view override returns (bytes32[] memory) {
        return _ownerAssets[owner];
    }

    /**
     * @inheritdoc IAssetRegistry
     */
    function isAuthorizedILRM(address ilrm) external view override returns (bool) {
        return _authorizedILRM[ilrm];
    }

    /**
     * @notice Get frozen assets for a dispute
     * @param disputeId The dispute ID
     * @return Array of frozen asset IDs
     */
    function getFrozenAssets(uint256 disputeId) external view returns (bytes32[] memory) {
        return _disputeFrozenAssets[disputeId];
    }

    /**
     * @notice Check if a license is valid (active and not expired)
     * @param assetId The asset ID
     * @param licensee The licensee address
     * @return True if license is valid
     */
    function isLicenseValid(
        bytes32 assetId,
        address licensee
    ) external view returns (bool) {
        LicenseGrant storage grant = _licenses[assetId][licensee];
        return grant.active && block.timestamp < grant.expiresAt;
    }

    // ============ Admin Functions ============

    /// @notice FIX L-02: Event for ILRM authorization changes
    event ILRMAuthorizationChanged(address indexed ilrm, bool authorized);

    /**
     * @notice Authorize an ILRM contract
     * @param ilrm ILRM contract address
     */
    function authorizeILRM(address ilrm) external onlyOwner {
        if (ilrm == address(0)) revert InvalidAddress();
        _authorizedILRM[ilrm] = true;
        emit ILRMAuthorizationChanged(ilrm, true);
    }

    /**
     * @notice Revoke ILRM authorization
     * @param ilrm ILRM contract address
     */
    function revokeILRM(address ilrm) external onlyOwner {
        _authorizedILRM[ilrm] = false;
        emit ILRMAuthorizationChanged(ilrm, false);
    }
}
