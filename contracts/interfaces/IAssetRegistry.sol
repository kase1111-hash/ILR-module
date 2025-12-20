// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/**
 * @title IAssetRegistry - IP & License Asset Registry Interface
 * @notice Interface for external contract holding IP assets and licenses
 * @dev The Asset Registry is responsible for:
 *      - Tracking IP asset ownership and licensing state
 *      - Freezing assets during active disputes
 *      - Applying license modifications from resolved disputes
 *      - Emitting provenance and usage metadata
 */
interface IAssetRegistry {
    // ============ Enums ============

    /// @notice Asset freeze status
    enum FreezeStatus {
        Active,      // Normal operation
        Frozen,      // Locked during dispute
        Restricted   // Partial restrictions applied
    }

    // ============ Structs ============

    /// @notice IP Asset metadata
    struct Asset {
        bytes32 assetId;
        address owner;
        bytes32 licenseTermsHash;
        FreezeStatus status;
        uint256 disputeId;       // Active dispute, 0 if none
        uint256 lastModified;
    }

    /// @notice License grant record
    struct LicenseGrant {
        bytes32 assetId;
        address licensee;
        bytes32 termsHash;
        uint256 grantedAt;
        uint256 expiresAt;
        uint256 royaltyBps;      // Basis points (e.g., 500 = 5%)
        bool nonExclusive;
        bool active;
    }

    // ============ Events ============

    /// @notice Emitted when asset is registered
    event AssetRegistered(
        bytes32 indexed assetId,
        address indexed owner,
        bytes32 licenseTermsHash
    );

    /// @notice Emitted when assets are frozen for dispute
    event AssetsFrozen(
        uint256 indexed disputeId,
        address indexed party,
        bytes32[] assetIds
    );

    /// @notice Emitted when assets are unfrozen after resolution
    event AssetsUnfrozen(
        uint256 indexed disputeId,
        bytes outcome
    );

    /// @notice Emitted when fallback license is applied
    event FallbackLicenseApplied(
        uint256 indexed disputeId,
        bytes32 termsHash,
        bytes32[] affectedAssets
    );

    /// @notice Emitted when license terms are modified
    event LicenseModified(
        bytes32 indexed assetId,
        address indexed licensee,
        bytes32 oldTermsHash,
        bytes32 newTermsHash
    );

    // ============ Core Functions ============

    /**
     * @notice Register a new IP asset
     * @param assetId Unique identifier for the asset
     * @param owner Asset owner address
     * @param licenseTermsHash IPFS hash of license terms
     */
    function registerAsset(
        bytes32 assetId,
        address owner,
        bytes32 licenseTermsHash
    ) external;

    /**
     * @notice Freeze assets involved in a dispute
     * @dev Only callable by authorized ILRM contract
     * @param disputeId The dispute triggering the freeze
     * @param party The party whose assets to freeze
     */
    function freezeAssets(
        uint256 disputeId,
        address party
    ) external;

    /**
     * @notice Unfreeze assets after dispute resolution
     * @dev Only callable by authorized ILRM contract
     * @param disputeId The resolved dispute
     * @param outcome Encoded resolution outcome
     */
    function unfreezeAssets(
        uint256 disputeId,
        bytes calldata outcome
    ) external;

    /**
     * @notice Apply fallback license terms after timeout
     * @dev Only callable by authorized ILRM contract
     * @param disputeId The timed-out dispute
     * @param fallbackTermsHash Hash of fallback license terms
     */
    function applyFallbackLicense(
        uint256 disputeId,
        bytes32 fallbackTermsHash
    ) external;

    /**
     * @notice Grant a license to a licensee
     * @param assetId The asset being licensed
     * @param licensee The license recipient
     * @param termsHash Hash of license terms
     * @param duration License duration in seconds
     * @param royaltyBps Royalty rate in basis points
     * @param nonExclusive Whether license is non-exclusive
     */
    function grantLicense(
        bytes32 assetId,
        address licensee,
        bytes32 termsHash,
        uint256 duration,
        uint256 royaltyBps,
        bool nonExclusive
    ) external;

    /**
     * @notice Revoke an active license
     * @param assetId The licensed asset
     * @param licensee The licensee to revoke
     */
    function revokeLicense(
        bytes32 assetId,
        address licensee
    ) external;

    // ============ View Functions ============

    /**
     * @notice Get asset details
     * @param assetId The asset to query
     * @return The asset struct
     */
    function getAsset(bytes32 assetId) external view returns (Asset memory);

    /**
     * @notice Get license grant details
     * @param assetId The licensed asset
     * @param licensee The licensee address
     * @return The license grant struct
     */
    function getLicense(
        bytes32 assetId,
        address licensee
    ) external view returns (LicenseGrant memory);

    /**
     * @notice Check if asset is frozen
     * @param assetId The asset to check
     * @return True if frozen
     */
    function isFrozen(bytes32 assetId) external view returns (bool);

    /**
     * @notice Get all assets owned by an address
     * @param owner The owner address
     * @return Array of asset IDs
     */
    function getAssetsByOwner(address owner) external view returns (bytes32[] memory);

    /**
     * @notice Check if address is authorized ILRM contract
     * @param ilrm Address to check
     * @return True if authorized
     */
    function isAuthorizedILRM(address ilrm) external view returns (bool);
}
