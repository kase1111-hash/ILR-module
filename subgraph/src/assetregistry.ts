// =============================================================================
// AssetRegistry Event Handlers - TheGraph Subgraph
// =============================================================================
// Handles all events from the AssetRegistry IP management contract
// =============================================================================

import { BigInt, Address } from "@graphprotocol/graph-ts";
import {
  AssetRegistered,
  AssetFrozen,
  AssetUnfrozen,
  FallbackLicenseApplied
} from "../generated/AssetRegistry/AssetRegistry";
import { Asset, License, AssetFreeze, Party } from "../generated/schema";

// =============================================================================
// Helper Functions
// =============================================================================

function getOrCreateParty(address: Address, timestamp: BigInt): Party {
  let id = address.toHexString();
  let party = Party.load(id);

  if (party == null) {
    party = new Party(id);
    party.totalDisputes = 0;
    party.disputesResolved = 0;
    party.disputesTimedOut = 0;
    party.totalStaked = BigInt.fromI32(0);
    party.totalBurned = BigInt.fromI32(0);
    party.harassmentScore = BigInt.fromI32(0);
    party.totalSubsidiesReceived = BigInt.fromI32(0);
    party.firstSeen = timestamp;
    party.lastActive = timestamp;
    party.save();
  }

  return party;
}

// =============================================================================
// Event Handlers
// =============================================================================

export function handleAssetRegistered(event: AssetRegistered): void {
  let assetId = event.params.assetId.toString();
  let timestamp = event.block.timestamp;

  // Get or create owner
  let owner = getOrCreateParty(event.params.owner, timestamp);
  owner.lastActive = timestamp;
  owner.save();

  // Create asset
  let asset = new Asset(assetId);
  asset.owner = owner.id;
  asset.contentHash = event.params.contentHash;
  asset.registeredAt = timestamp;
  asset.frozen = false;
  asset.save();
}

export function handleAssetFrozen(event: AssetFrozen): void {
  let assetId = event.params.assetId.toString();
  let timestamp = event.block.timestamp;

  let asset = Asset.load(assetId);
  if (asset == null) {
    return;
  }

  asset.frozen = true;
  asset.frozenByDispute = event.params.disputeId;
  asset.save();

  // Create freeze record
  // Count existing freezes for this asset
  let freezeIndex = 0;
  let freezeId = assetId + "-" + freezeIndex.toString();
  while (AssetFreeze.load(freezeId) != null) {
    freezeIndex++;
    freezeId = assetId + "-" + freezeIndex.toString();
  }

  let freeze = new AssetFreeze(freezeId);
  freeze.asset = assetId;
  freeze.disputeId = event.params.disputeId;
  freeze.frozenAt = timestamp;
  freeze.txHash = event.transaction.hash;
  freeze.save();
}

export function handleAssetUnfrozen(event: AssetUnfrozen): void {
  let assetId = event.params.assetId.toString();
  let timestamp = event.block.timestamp;

  let asset = Asset.load(assetId);
  if (asset == null) {
    return;
  }

  asset.frozen = false;
  asset.frozenByDispute = null;
  asset.save();

  // Find and update the most recent freeze record
  let freezeIndex = 0;
  let lastFreeze: AssetFreeze | null = null;
  let freezeId = assetId + "-" + freezeIndex.toString();

  while (true) {
    let freeze = AssetFreeze.load(freezeId);
    if (freeze == null) {
      break;
    }
    if (freeze.unfrozenAt == null) {
      lastFreeze = freeze;
    }
    freezeIndex++;
    freezeId = assetId + "-" + freezeIndex.toString();
  }

  if (lastFreeze != null) {
    lastFreeze.unfrozenAt = timestamp;
    lastFreeze.save();
  }
}

export function handleFallbackLicenseAppliedToAsset(event: FallbackLicenseApplied): void {
  let assetId = event.params.assetId.toString();
  let timestamp = event.block.timestamp;

  let asset = Asset.load(assetId);
  if (asset == null) {
    return;
  }

  // Create license record
  // Count existing licenses for this asset
  let licenseIndex = 0;
  let licenseId = assetId + "-" + licenseIndex.toString();
  while (License.load(licenseId) != null) {
    licenseIndex++;
    licenseId = assetId + "-" + licenseIndex.toString();
  }

  let license = new License(licenseId);
  license.asset = assetId;
  license.termsHash = event.params.termsHash;
  license.licenseType = "FALLBACK";
  license.grantedAt = timestamp;
  license.isFallback = true;
  // Would need additional event data for these:
  // license.fromDispute = disputeId;
  // license.expiresAt = expiry;
  // license.royaltyBps = royalty;
  license.save();
}
