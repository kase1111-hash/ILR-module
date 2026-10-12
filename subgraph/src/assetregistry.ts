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
  AssetRegistry__getLicenseResultValue0Struct,
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
  // grantLicense emits (0, terms) - also when re-granting an active license; revokeLicense emits (terms, 0).
  // A grant with zero terms and a revocation of it both emit (0, 0). Those are told apart by the
  // registry's own `active` flag, never by the subgraph's stored state: a zero-terms re-grant of an
  // active license is not a revoke, and the revoke that follows it is not a grant.
  const assetKey = event.params.assetId.toHexString();
  const id = assetKey + "-" + event.params.licensee.toHexString();
  const oldTerms = event.params.oldTermsHash;
  const newTerms = event.params.newTermsHash;
  const ambiguous = isZeroBytes(oldTerms) && isZeroBytes(newTerms);

  let license = License.load(id);
  let isRevoke = !ambiguous && isZeroBytes(newTerms);

  // The stored grant as of the end of this block: duration, royalty and exclusivity are not in the
  // event, and its `active` flag classifies (0, 0). Every (0, 0) event of a block sees the same
  // final state, so the License ends the block in the registry's state even when a zero-terms grant
  // and its revoke share a block.
  let grant: AssetRegistry__getLicenseResultValue0Struct | null = null;
  if (!isRevoke) {
    const call = AssetRegistry.bind(event.address).try_getLicense(event.params.assetId, event.params.licensee);
    if (!call.reverted) grant = call.value;
  }
  if (ambiguous) {
    // getLicense is a plain storage read; the fallback only covers a registry without it
    isRevoke = grant != null ? !grant.active : license != null && license.active;
  }

  if (license == null) {
    // A revoke needs an earlier grant. With (T, 0) the grant predates startBlock: nothing to update.
    // A (0, 0) revoke is a zero-terms grant revoked later in this same block: record it as revoked.
    if (isRevoke && !ambiguous) return;
    const licensee = touchParty(event.params.licensee, event.block.timestamp);
    license = new License(id);
    license.asset = assetKey;
    license.licensee = licensee.id;
    license.termsHash = newTerms;
    license.grantCount = isRevoke ? 1 : 0;
  }

  if (grant != null && grant.termsHash.equals(newTerms)) {
    license.grantedAt = grant.grantedAt;
    license.expiresAt = grant.expiresAt;
    license.royaltyBps = grant.royaltyBps;
    license.nonExclusive = grant.nonExclusive;
  }
  license.updatedTx = event.transaction.hash;

  if (isRevoke) {
    license.active = false;
    license.revokedAt = event.block.timestamp;
    license.expiresAt = event.block.timestamp; // revokeLicense sets expiresAt = block.timestamp
  } else {
    license.termsHash = newTerms;
    license.active = true;
    license.revokedAt = null;
    if (isZeroBytes(oldTerms)) license.grantCount = license.grantCount + 1;
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
