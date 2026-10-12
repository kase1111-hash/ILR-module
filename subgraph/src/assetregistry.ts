// =============================================================================
// AssetRegistry Event Handlers - TheGraph Subgraph
// =============================================================================
// Handles every event of contracts/AssetRegistry.sol (NatLangChainAssetRegistry).
// Asset ids are bytes32. Inside an ILRM transaction the registry events come
// first: AssetsFrozen precedes ILRM.DisputeInitiated, and FallbackLicenseApplied /
// AssetsUnfrozen precede ILRM.DisputeResolved.
// transferAsset emits no event, so Asset.owner is the registering owner.
// =============================================================================

import { Bytes } from "@graphprotocol/graph-ts";
import {
  AssetRegistry,
  AssetRegistered,
  AssetsFrozen,
  AssetsUnfrozen,
  FallbackLicenseApplied,
  ILRMAuthorizationChanged,
  LicenseModified,
  OwnershipTransferStarted,
  OwnershipTransferred
} from "../generated/AssetRegistry/AssetRegistry";
import { Asset, AssetFreeze, DisputeAssetSet, FallbackLicenseApplication, License } from "../generated/schema";
import {
  KIND_ASSET_REGISTRY,
  eventId,
  isZeroBytes,
  newAdminEvent,
  recordOwnershipTransferStarted,
  recordOwnershipTransferred,
  setRole,
  touchParty
} from "./common";

function idsOf(assetIds: Bytes[]): string[] {
  const ids: string[] = [];
  for (let i = 0; i < assetIds.length; i++) ids.push(assetIds[i].toHexString());
  return ids;
}

// =============================================================================
// Assets
// =============================================================================

export function handleAssetRegistered(event: AssetRegistered): void {
  const owner = touchParty(event.params.owner, event.block.timestamp);

  const asset = new Asset(event.params.assetId.toHexString());
  asset.owner = owner.id;
  asset.licenseTermsHash = event.params.licenseTermsHash;
  asset.registeredAt = event.block.timestamp;
  asset.frozen = false;
  asset.fallbackLicenseCount = 0;
  asset.save();
}

// =============================================================================
// Dispute freezes
// =============================================================================

export function handleAssetsFrozen(event: AssetsFrozen): void {
  const disputeId = event.params.disputeId;
  const key = disputeId.toString();
  // The event lists every asset frozen for this dispute so far (the registry's storage array)
  const ids = idsOf(event.params.assetIds);

  let set = DisputeAssetSet.load(key);
  if (set == null) set = new DisputeAssetSet(key);
  set.assets = ids;
  set.unfrozenAt = null;
  set.unfreezeOutcome = null;
  set.save();

  for (let i = 0; i < ids.length; i++) {
    const asset = Asset.load(ids[i]);
    if (asset == null) continue;
    const freezeId = ids[i] + "-" + key;
    if (AssetFreeze.load(freezeId) != null) continue; // frozen by an earlier call for this dispute

    asset.frozen = true;
    asset.frozenByDispute = disputeId;
    asset.save();

    const freeze = new AssetFreeze(freezeId);
    freeze.asset = asset.id;
    freeze.disputeId = disputeId;
    freeze.dispute = key;
    freeze.party = event.params.party;
    freeze.frozenAt = event.block.timestamp;
    freeze.txHash = event.transaction.hash;
    freeze.save();
  }
}

export function handleAssetsUnfrozen(event: AssetsUnfrozen): void {
  const disputeId = event.params.disputeId;
  const key = disputeId.toString();
  // Emitted on every resolution, also when nothing was frozen
  const set = DisputeAssetSet.load(key);
  if (set == null) return;

  const ids = set.assets;
  for (let i = 0; i < ids.length; i++) {
    const asset = Asset.load(ids[i]);
    if (asset == null) continue;
    // Mirrors the registry: only assets still frozen by this dispute are released
    const frozenBy = asset.frozenByDispute;
    if (frozenBy === null || !frozenBy.equals(disputeId)) continue;
    asset.frozen = false;
    asset.frozenByDispute = null;
    asset.save();

    const freeze = AssetFreeze.load(ids[i] + "-" + key);
    if (freeze != null) {
      freeze.unfrozenAt = event.block.timestamp;
      freeze.save();
    }
  }

  set.unfreezeOutcome = event.params.outcome;
  set.unfrozenAt = event.block.timestamp;
  set.save();
}

export function handleFallbackLicenseApplied(event: FallbackLicenseApplied): void {
  const ids = idsOf(event.params.affectedAssets);
  const key = event.params.disputeId.toString();

  const application = new FallbackLicenseApplication(eventId(event));
  application.disputeId = event.params.disputeId;
  application.dispute = key;
  application.termsHash = event.params.termsHash;
  application.assets = ids;
  application.timestamp = event.block.timestamp;
  application.txHash = event.transaction.hash;
  application.save();

  for (let i = 0; i < ids.length; i++) {
    const asset = Asset.load(ids[i]);
    if (asset == null) continue;
    asset.licenseTermsHash = event.params.termsHash;
    asset.fallbackLicenseCount = asset.fallbackLicenseCount + 1;
    asset.save();
  }
}

// =============================================================================
// Licenses
// =============================================================================

export function handleLicenseModified(event: LicenseModified): void {
  // grantLicense emits (0, terms) - also when updating an existing grant; revokeLicense emits (terms, 0).
  // A grant with zero terms and its revocation both emit (0, 0): the current state disambiguates.
  const assetKey = event.params.assetId.toHexString();
  const id = assetKey + "-" + event.params.licensee.toHexString();
  const oldTerms = event.params.oldTermsHash;
  const newTerms = event.params.newTermsHash;

  let license = License.load(id);
  const wasActive = license != null && license.active;
  const isRevoke = isZeroBytes(newTerms) && (!isZeroBytes(oldTerms) || wasActive);

  if (isRevoke) {
    if (license == null) return;
    license.active = false;
    license.revokedAt = event.block.timestamp;
    license.expiresAt = event.block.timestamp; // revokeLicense sets expiresAt = block.timestamp
    license.updatedTx = event.transaction.hash;
    license.save();
    return;
  }

  if (license == null) {
    const licensee = touchParty(event.params.licensee, event.block.timestamp);
    license = new License(id);
    license.asset = assetKey;
    license.licensee = licensee.id;
    license.grantCount = 0;
  }
  license.termsHash = newTerms;
  license.active = true;
  license.revokedAt = null;
  license.updatedTx = event.transaction.hash;
  if (isZeroBytes(oldTerms)) license.grantCount = license.grantCount + 1;

  // Duration, royalty and exclusivity are not in the event; read the stored grant
  const call = AssetRegistry.bind(event.address).try_getLicense(event.params.assetId, event.params.licensee);
  if (!call.reverted && call.value.termsHash.equals(newTerms)) {
    license.grantedAt = call.value.grantedAt;
    license.expiresAt = call.value.expiresAt;
    license.royaltyBps = call.value.royaltyBps;
    license.nonExclusive = call.value.nonExclusive;
  }
  license.save();
}

// =============================================================================
// Roles and ownership
// =============================================================================

export function handleILRMAuthorizationChanged(event: ILRMAuthorizationChanged): void {
  setRole(event, KIND_ASSET_REGISTRY, "AUTHORIZED_ILRM", event.params.ilrm, event.params.authorized);

  const entry = newAdminEvent(event, KIND_ASSET_REGISTRY, "ILRMAuthorizationChanged");
  entry.account = event.params.ilrm;
  entry.flag = event.params.authorized;
  entry.save();
}

export function handleOwnershipTransferStarted(event: OwnershipTransferStarted): void {
  recordOwnershipTransferStarted(event, KIND_ASSET_REGISTRY, event.params.previousOwner, event.params.newOwner);
}

export function handleOwnershipTransferred(event: OwnershipTransferred): void {
  recordOwnershipTransferred(event, KIND_ASSET_REGISTRY, event.params.previousOwner, event.params.newOwner);
}
