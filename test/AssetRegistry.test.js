/**
 * AssetRegistry Tests
 *
 * Tests the IP Asset and License management:
 * - Asset registration and transfer
 * - License granting and revocation
 * - Freeze/unfreeze during disputes
 * - Fallback license application
 *
 * ⚠️  CRITICAL: Assets must be unfrozen after dispute resolution
 *     Stuck frozen assets = permanent lockup
 */

const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time, loadFixture } = require("@nomicfoundation/hardhat-network-helpers");

describe("AssetRegistry Tests", function () {
  async function deployFixture() {
    const [owner, ilrm, assetOwner, licensee, attacker] = await ethers.getSigners();

    const Registry = await ethers.getContractFactory("NatLangChainAssetRegistry");
    const registry = await Registry.deploy();

    await registry.authorizeILRM(ilrm.address);

    const ASSET_ID = ethers.keccak256(ethers.toUtf8Bytes("asset-1"));
    const TERMS_HASH = ethers.keccak256(ethers.toUtf8Bytes("license-terms"));

    return { registry, owner, ilrm, assetOwner, licensee, attacker, ASSET_ID, TERMS_HASH };
  }

  describe("Asset Registration", function () {
    it("should register new asset", async function () {
      const { registry, assetOwner, ASSET_ID, TERMS_HASH } = await loadFixture(deployFixture);

      await expect(registry.registerAsset(ASSET_ID, assetOwner.address, TERMS_HASH))
        .to.emit(registry, "AssetRegistered")
        .withArgs(ASSET_ID, assetOwner.address, TERMS_HASH);

      const asset = await registry.getAsset(ASSET_ID);
      expect(asset.owner).to.equal(assetOwner.address);
    });

    it("should reject duplicate asset registration", async function () {
      const { registry, assetOwner, ASSET_ID, TERMS_HASH } = await loadFixture(deployFixture);

      await registry.registerAsset(ASSET_ID, assetOwner.address, TERMS_HASH);

      await expect(registry.registerAsset(ASSET_ID, assetOwner.address, TERMS_HASH))
        .to.be.revertedWithCustomError(registry, "AssetAlreadyExists");
    });

    it("should reject zero address owner", async function () {
      const { registry, ASSET_ID, TERMS_HASH } = await loadFixture(deployFixture);

      await expect(registry.registerAsset(ASSET_ID, ethers.ZeroAddress, TERMS_HASH))
        .to.be.revertedWithCustomError(registry, "InvalidAddress");
    });
  });

  describe("Asset Transfer", function () {
    it("should allow owner to transfer", async function () {
      const { registry, assetOwner, licensee, ASSET_ID, TERMS_HASH } = await loadFixture(deployFixture);

      await registry.registerAsset(ASSET_ID, assetOwner.address, TERMS_HASH);

      await registry.connect(assetOwner).transferAsset(ASSET_ID, licensee.address);

      const asset = await registry.getAsset(ASSET_ID);
      expect(asset.owner).to.equal(licensee.address);
    });

    it("should reject transfer from non-owner", async function () {
      const { registry, assetOwner, attacker, ASSET_ID, TERMS_HASH } = await loadFixture(deployFixture);

      await registry.registerAsset(ASSET_ID, assetOwner.address, TERMS_HASH);

      await expect(registry.connect(attacker).transferAsset(ASSET_ID, attacker.address))
        .to.be.revertedWithCustomError(registry, "NotAssetOwner");
    });

    /**
     * ⚠️  CRITICAL: Frozen assets cannot be transferred
     *     This prevents dispute evasion
     */
    it("should reject transfer of frozen asset", async function () {
      const { registry, ilrm, assetOwner, licensee, ASSET_ID, TERMS_HASH } = await loadFixture(deployFixture);

      await registry.registerAsset(ASSET_ID, assetOwner.address, TERMS_HASH);
      await registry.connect(ilrm).freezeAssets(1, assetOwner.address);

      await expect(registry.connect(assetOwner).transferAsset(ASSET_ID, licensee.address))
        .to.be.revertedWithCustomError(registry, "AssetFrozen");
    });
  });

  describe("License Management", function () {
    it("should grant license", async function () {
      const { registry, assetOwner, licensee, ASSET_ID, TERMS_HASH } = await loadFixture(deployFixture);

      await registry.registerAsset(ASSET_ID, assetOwner.address, TERMS_HASH);

      const duration = 365 * 24 * 60 * 60; // 1 year
      await registry.connect(assetOwner).grantLicense(
        ASSET_ID,
        licensee.address,
        TERMS_HASH,
        duration,
        500, // 5% royalty
        true // non-exclusive
      );

      const license = await registry.getLicense(ASSET_ID, licensee.address);
      expect(license.active).to.be.true;
      expect(license.royaltyBps).to.equal(500);
    });

    it("should revoke license", async function () {
      const { registry, assetOwner, licensee, ASSET_ID, TERMS_HASH } = await loadFixture(deployFixture);

      await registry.registerAsset(ASSET_ID, assetOwner.address, TERMS_HASH);
      await registry.connect(assetOwner).grantLicense(
        ASSET_ID, licensee.address, TERMS_HASH, 86400, 500, true
      );

      await registry.connect(assetOwner).revokeLicense(ASSET_ID, licensee.address);

      const license = await registry.getLicense(ASSET_ID, licensee.address);
      expect(license.active).to.be.false;
    });

    it("should check license validity with expiry", async function () {
      const { registry, assetOwner, licensee, ASSET_ID, TERMS_HASH } = await loadFixture(deployFixture);

      await registry.registerAsset(ASSET_ID, assetOwner.address, TERMS_HASH);
      await registry.connect(assetOwner).grantLicense(
        ASSET_ID, licensee.address, TERMS_HASH, 86400, 500, true
      );

      expect(await registry.isLicenseValid(ASSET_ID, licensee.address)).to.be.true;

      // Warp past expiry
      await time.increase(86401);

      expect(await registry.isLicenseValid(ASSET_ID, licensee.address)).to.be.false;
    });
  });

  describe("ILRM Integration", function () {
    /**
     * ⚠️  CRITICAL: Only authorized ILRM can freeze assets
     */
    it("should only allow ILRM to freeze", async function () {
      const { registry, ilrm, assetOwner, attacker, ASSET_ID, TERMS_HASH } = await loadFixture(deployFixture);

      await registry.registerAsset(ASSET_ID, assetOwner.address, TERMS_HASH);

      await expect(registry.connect(attacker).freezeAssets(1, assetOwner.address))
        .to.be.revertedWithCustomError(registry, "NotAuthorizedILRM");

      await expect(registry.connect(ilrm).freezeAssets(1, assetOwner.address))
        .to.emit(registry, "AssetsFrozen");
    });

    /**
     * ⚠️  CRITICAL: Assets MUST be unfrozen after resolution
     *     This test verifies the critical unfreeze path
     */
    it("should unfreeze assets after resolution", async function () {
      const { registry, ilrm, assetOwner, ASSET_ID, TERMS_HASH } = await loadFixture(deployFixture);

      await registry.registerAsset(ASSET_ID, assetOwner.address, TERMS_HASH);
      await registry.connect(ilrm).freezeAssets(1, assetOwner.address);

      expect(await registry.isFrozen(ASSET_ID)).to.be.true;

      await registry.connect(ilrm).unfreezeAssets(1, ethers.toUtf8Bytes("resolved"));

      expect(await registry.isFrozen(ASSET_ID)).to.be.false;
    });

    it("should apply fallback license on timeout", async function () {
      const { registry, ilrm, assetOwner, ASSET_ID, TERMS_HASH } = await loadFixture(deployFixture);

      await registry.registerAsset(ASSET_ID, assetOwner.address, TERMS_HASH);
      await registry.connect(ilrm).freezeAssets(1, assetOwner.address);

      const fallbackTerms = ethers.keccak256(ethers.toUtf8Bytes("fallback"));
      await registry.connect(ilrm).applyFallbackLicense(1, fallbackTerms);

      const asset = await registry.getAsset(ASSET_ID);
      expect(asset.licenseTermsHash).to.equal(fallbackTerms);
    });
  });

  describe("View Functions", function () {
    it("should return assets by owner", async function () {
      const { registry, assetOwner, TERMS_HASH } = await loadFixture(deployFixture);

      const asset1 = ethers.keccak256(ethers.toUtf8Bytes("asset1"));
      const asset2 = ethers.keccak256(ethers.toUtf8Bytes("asset2"));

      await registry.registerAsset(asset1, assetOwner.address, TERMS_HASH);
      await registry.registerAsset(asset2, assetOwner.address, TERMS_HASH);

      const assets = await registry.getAssetsByOwner(assetOwner.address);
      expect(assets.length).to.equal(2);
    });

    it("should return frozen assets for dispute", async function () {
      const { registry, ilrm, assetOwner, ASSET_ID, TERMS_HASH } = await loadFixture(deployFixture);

      await registry.registerAsset(ASSET_ID, assetOwner.address, TERMS_HASH);
      await registry.connect(ilrm).freezeAssets(1, assetOwner.address);

      const frozen = await registry.getFrozenAssets(1);
      expect(frozen.length).to.equal(1);
      expect(frozen[0]).to.equal(ASSET_ID);
    });
  });
});
