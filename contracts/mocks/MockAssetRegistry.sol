// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "../interfaces/IAssetRegistry.sol";

/**
 * @title MockAssetRegistry - Minimal asset registry for ILRM testing
 */
contract MockAssetRegistry is IAssetRegistry {
    mapping(uint256 => bool) public frozen;
    mapping(uint256 => bytes32) public appliedFallbacks;

    function registerAsset(bytes32, address, bytes32) external pure override {}

    function freezeAssets(uint256 disputeId, address party) external override {
        frozen[disputeId] = true;
        emit AssetsFrozen(disputeId, party, new bytes32[](0));
    }

    function unfreezeAssets(uint256 disputeId, bytes calldata outcome) external override {
        frozen[disputeId] = false;
        emit AssetsUnfrozen(disputeId, outcome);
    }

    function applyFallbackLicense(uint256 disputeId, bytes32 termsHash) external override {
        appliedFallbacks[disputeId] = termsHash;
        emit FallbackLicenseApplied(disputeId, termsHash, new bytes32[](0));
    }

    function grantLicense(bytes32, address, bytes32, uint256, uint256, bool) external pure override {}
    function revokeLicense(bytes32, address) external pure override {}

    function getAsset(bytes32) external pure override returns (Asset memory) {
        return Asset(bytes32(0), address(0), bytes32(0), FreezeStatus.Active, 0, 0);
    }

    function getLicense(bytes32, address) external pure override returns (LicenseGrant memory) {
        return LicenseGrant(bytes32(0), address(0), bytes32(0), 0, 0, 0, true, false);
    }

    function isFrozen(bytes32) external pure override returns (bool) {
        return false;
    }

    function getAssetsByOwner(address) external pure override returns (bytes32[] memory) {
        return new bytes32[](0);
    }

    function isAuthorizedILRM(address) external pure override returns (bool) {
        return true;
    }
}
