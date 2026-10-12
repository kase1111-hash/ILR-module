import { afterEach, assert, clearStore, createMockedFunction, describe, test } from "matchstick-as/assembly/index";
import { Address, Bytes, ethereum } from "@graphprotocol/graph-ts";
import {
  AssetRegistered,
  AssetsFrozen,
  AssetsUnfrozen,
  FallbackLicenseApplied,
  ILRMAuthorizationChanged,
  LicenseModified
} from "../generated/AssetRegistry/AssetRegistry";
import {
  handleAssetRegistered,
  handleAssetsFrozen,
  handleAssetsUnfrozen,
  handleFallbackLicenseApplied,
  handleILRMAuthorizationChanged,
  handleLicenseModified
} from "../src/assetregistry";
import { eventId } from "../src/common";
import {
  ALICE,
  BOB,
  CAROL,
  ILRM_ADDRESS,
  REGISTRY_ADDRESS,
  beginTx,
  bi,
  mockEvent,
  pAddr,
  pB32,
  pB32Array,
  pBool,
  pBytes,
  pInt,
  word
} from "./helpers";

const A1 = word(0xa1);
const A2 = word(0xa2);
const A3 = word(0xa3);
const T1 = word(0x71);
const T2 = word(0x72);
const ZERO32 = word(0);

function register(assetId: Bytes, owner: Address): void {
  handleAssetRegistered(
    changetype<AssetRegistered>(
      mockEvent(REGISTRY_ADDRESS, [pB32("assetId", assetId), pAddr("owner", owner), pB32("licenseTermsHash", T1)])
    )
  );
}

function frozen(disputeId: i32, party: Address, assets: Array<Bytes>): void {
  handleAssetsFrozen(
    changetype<AssetsFrozen>(
      mockEvent(REGISTRY_ADDRESS, [pInt("disputeId", disputeId), pAddr("party", party), pB32Array("assetIds", assets)])
    )
  );
}

function unfrozen(disputeId: i32): void {
  handleAssetsUnfrozen(
    changetype<AssetsUnfrozen>(
      mockEvent(REGISTRY_ADDRESS, [pInt("disputeId", disputeId), pBytes("outcome", Bytes.fromUTF8("accepted"))])
    )
  );
}

function mockLicense(assetId: Bytes, licensee: Address, terms: Bytes, active: boolean): void {
  const grant = new ethereum.Tuple();
  grant.push(ethereum.Value.fromFixedBytes(assetId));
  grant.push(ethereum.Value.fromAddress(licensee));
  grant.push(ethereum.Value.fromFixedBytes(terms));
  grant.push(ethereum.Value.fromUnsignedBigInt(bi(1000)));
  grant.push(ethereum.Value.fromUnsignedBigInt(bi(31537000)));
  grant.push(ethereum.Value.fromUnsignedBigInt(bi(250)));
  grant.push(ethereum.Value.fromBoolean(true));
  grant.push(ethereum.Value.fromBoolean(active));
  createMockedFunction(
    REGISTRY_ADDRESS,
    "getLicense",
    "getLicense(bytes32,address):((bytes32,address,bytes32,uint256,uint256,uint256,bool,bool))"
  )
    .withArgs([ethereum.Value.fromFixedBytes(assetId), ethereum.Value.fromAddress(licensee)])
    .returns([ethereum.Value.fromTuple(grant)]);
}

function licenseModified(assetId: Bytes, licensee: Address, oldTerms: Bytes, newTerms: Bytes): void {
  handleLicenseModified(
    changetype<LicenseModified>(
      mockEvent(REGISTRY_ADDRESS, [
        pB32("assetId", assetId),
        pAddr("licensee", licensee),
        pB32("oldTermsHash", oldTerms),
        pB32("newTermsHash", newTerms)
      ])
    )
  );
}

describe("AssetRegistry", () => {
  afterEach(() => {
    clearStore();
  });

  test("freeze, fallback license and unfreeze follow the dispute", () => {
    beginTx(1, 1000);
    register(A1, ALICE);
    register(A2, ALICE);
    register(A3, BOB);
    assert.fieldEquals("Asset", A1.toHexString(), "owner", ALICE.toHexString());
    assert.fieldEquals("Asset", A1.toHexString(), "frozen", "false");

    // initiateBreachDispute: AssetsFrozen comes before ILRM.DisputeInitiated
    beginTx(2, 2000);
    frozen(0, ALICE, [A1, A2]);
    assert.fieldEquals("Asset", A1.toHexString(), "frozen", "true");
    assert.fieldEquals("Asset", A1.toHexString(), "frozenByDispute", "0");
    assert.fieldEquals("AssetFreeze", A2.toHexString() + "-0", "dispute", "0");
    assert.fieldEquals("DisputeAssetSet", "0", "assets", "[" + A1.toHexString() + ", " + A2.toHexString() + "]");

    // A3 frozen by dispute 1; dispute 2 finds it already frozen and freezes nothing
    beginTx(3, 3000);
    frozen(1, BOB, [A3]);
    frozen(2, BOB, []);

    // enforceTimeout: FallbackLicenseApplied, AssetsUnfrozen
    beginTx(4, 4000);
    const fallback = changetype<FallbackLicenseApplied>(
      mockEvent(REGISTRY_ADDRESS, [pInt("disputeId", 0), pB32("termsHash", T2), pB32Array("affectedAssets", [A1, A2])])
    );
    handleFallbackLicenseApplied(fallback);
    unfrozen(0);
    unfrozen(2);
    unfrozen(9); // nothing frozen: no-op
    assert.fieldEquals("FallbackLicenseApplication", eventId(fallback), "termsHash", T2.toHexString());
    assert.fieldEquals("Asset", A1.toHexString(), "licenseTermsHash", T2.toHexString());
    assert.fieldEquals("Asset", A1.toHexString(), "fallbackLicenseCount", "1");
    assert.fieldEquals("Asset", A1.toHexString(), "frozen", "false");
    assert.fieldEquals("Asset", A2.toHexString(), "frozenByDispute", "null");
    assert.fieldEquals("AssetFreeze", A1.toHexString() + "-0", "unfrozenAt", "4000");
    assert.fieldEquals("DisputeAssetSet", "0", "unfrozenAt", "4000");
    // Released only by the dispute that froze it
    assert.fieldEquals("Asset", A3.toHexString(), "frozen", "true");
    assert.fieldEquals("Asset", A3.toHexString(), "frozenByDispute", "1");
  });

  test("license grants, re-grants and revocations", () => {
    beginTx(10, 1000);
    register(A1, ALICE);
    register(A2, ALICE);
    const id = A1.toHexString() + "-" + CAROL.toHexString();

    mockLicense(A1, CAROL, T1, true);
    licenseModified(A1, CAROL, ZERO32, T1);
    assert.fieldEquals("License", id, "active", "true");
    assert.fieldEquals("License", id, "grantCount", "1");
    assert.fieldEquals("License", id, "expiresAt", "31537000");
    assert.fieldEquals("License", id, "royaltyBps", "250");
    assert.fieldEquals("License", id, "licensee", CAROL.toHexString());

    // grantLicense on an existing grant still emits (0, terms)
    beginTx(11, 2000);
    mockLicense(A1, CAROL, T2, true);
    licenseModified(A1, CAROL, ZERO32, T2);
    assert.fieldEquals("License", id, "termsHash", T2.toHexString());
    assert.fieldEquals("License", id, "grantCount", "2");

    beginTx(12, 3000);
    licenseModified(A1, CAROL, T2, ZERO32);
    assert.fieldEquals("License", id, "active", "false");
    assert.fieldEquals("License", id, "revokedAt", "3000");
    assert.fieldEquals("License", id, "expiresAt", "3000");

    // Zero terms: grant and revoke both emit (0, 0); the current state disambiguates
    const zeroId = A2.toHexString() + "-" + BOB.toHexString();
    beginTx(13, 4000);
    mockLicense(A2, BOB, ZERO32, true);
    licenseModified(A2, BOB, ZERO32, ZERO32);
    assert.fieldEquals("License", zeroId, "active", "true");
    beginTx(14, 5000);
    licenseModified(A2, BOB, ZERO32, ZERO32);
    assert.fieldEquals("License", zeroId, "active", "false");
  });

  test("ILRM authorization", () => {
    beginTx(20, 1000);
    handleILRMAuthorizationChanged(
      changetype<ILRMAuthorizationChanged>(
        mockEvent(REGISTRY_ADDRESS, [pAddr("ilrm", ILRM_ADDRESS), pBool("authorized", true)])
      )
    );
    const roleId = REGISTRY_ADDRESS.toHexString() + "-AUTHORIZED_ILRM-" + ILRM_ADDRESS.toHexString();
    assert.fieldEquals("RoleMember", roleId, "active", "true");
    assert.fieldEquals("ProtocolContract", REGISTRY_ADDRESS.toHexString(), "kind", "ASSET_REGISTRY");
    assert.entityCount("AdminEvent", 1);
  });
});
