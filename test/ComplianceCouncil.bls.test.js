/**
 * ComplianceCouncil BLS12-381 tests (EIP-2537 precompiles, Hardhat network >= Prague)
 *
 * End-to-end agreement between sdk/threshold-bls.ts (noble-curves) and the on-chain verifier
 * (contracts/modules/libraries/BLS12381.sol, ComplianceCouncil):
 * - precompile detection, RFC 9380 expand_message_xmd and hash-to-G2 (known answers and noble)
 * - valid signatures verify; wrong message / key / DST, infinity and malformed points fail
 * - member and group key validation, key index uniqueness, no duplicate members on re-add
 * - signing message agreement (chain id and council address binding)
 * - SDK DKG -> partial signatures -> Lagrange aggregate -> on-chain verification
 * - follow-ups: only current partials count (removal / rotation), on-chain reconstruction and
 *   decryptedKeyHash, key index bound, duplicate keys, aggregateSignatures validation, updateConfig,
 *   the unknown-warrant guard, canonical SDK decoding
 */

const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture, time } = require("@nomicfoundation/hardhat-network-helpers");
const { bls12_381: bls } = require("@noble/curves/bls12-381");
const { expand_message_xmd } = require("@noble/curves/abstract/hash-to-curve");
const { sha256 } = require("@noble/hashes/sha2.js");

// Loading the SDK at all is a regression check: it used @noble/hashes subpaths that v2 does not export
require("ts-node").register({ transpileOnly: true, compilerOptions: { module: "commonjs" } });
const sdk = require("../sdk/threshold-bls");

const Fp = bls.fields.Fp;
const Fp2 = bls.fields.Fp2;
const P = Fp.ORDER;
const DST = sdk.WARRANT_SIGNATURE_DST;
const DST_BYTES = ethers.toUtf8Bytes(DST);
const STANDARD_DST = "BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_NUL_";
const RFC_DST = "QUUX-V01-CS02-with-BLS12381G2_XMD:SHA-256_SSWU_RO_";

// Failing EIP-2537 precompiles consume all forwarded gas: bound calls expected to hit one
const GAS = { gasLimit: 3_000_000 };

const MODE = { DISABLED: 0, STRICT_ONCHAIN: 1, HYBRID_ATTESTED: 2 };
const STATUS = { Pending: 0, Approved: 1, Rejected: 2, Executing: 3, Executed: 4 };

// ============ Encoding helpers (EIP-2537) ============

/** 64-byte big-endian Fp encoding, hex without 0x */
const fp = (v) => ethers.toBeHex(v, 64).slice(2);

const g1Hex = (pt) => {
  const a = pt.toAffine();
  return "0x" + fp(a.x) + fp(a.y);
};

const g2Hex = (pt) => {
  const a = pt.toAffine();
  return "0x" + fp(a.x.c0) + fp(a.x.c1) + fp(a.y.c0) + fp(a.y.c1);
};

const words = (hex) => {
  const b = ethers.getBytes(hex);
  const out = [];
  for (let i = 0; i < b.length; i += 32) out.push(ethers.hexlify(b.slice(i, i + 32)));
  return out;
};

const pkStruct = (hex) => {
  const w = words(hex);
  return { x: [w[0], w[1]], y: [w[2], w[3]] };
};

const sigStruct = (hex) => {
  const w = words(hex);
  return { x: w.slice(0, 4), y: w.slice(4, 8) };
};

/** Struct (or ethers Result) -> concatenated hex */
const structHex = (s) => ethers.concat([...s.x, ...s.y]);

const sdkPk = (pk) => {
  const e = sdk.encodeBLSPublicKeyForSolidity(pk);
  return { x: e.x.map((w) => ethers.hexlify(w)), y: e.y.map((w) => ethers.hexlify(w)) };
};

const sdkSig = (sig) => {
  const e = sdk.encodeBLSSignatureForSolidity(sig);
  return { x: e.x.map((w) => ethers.hexlify(w)), y: e.y.map((w) => ethers.hexlify(w)) };
};

/** On-curve G1 point outside the prime-order subgroup */
function g1OffSubgroup() {
  for (let x = 1n; ; x++) {
    let y;
    try {
      y = Fp.sqrt(Fp.add(Fp.pow(x, 3n), 4n));
    } catch {
      continue;
    }
    if (!bls.G1.ProjectivePoint.fromAffine({ x, y }).isTorsionFree()) return "0x" + fp(x) + fp(y);
  }
}

/** Point on the G2 twist curve y^2 = x^3 + 4(1 + u) outside the prime-order subgroup */
function g2OffSubgroup() {
  const b = Fp2.fromBigTuple([4n, 4n]);
  for (let i = 1n; ; i++) {
    const x = Fp2.fromBigTuple([i, 1n]);
    const rhs = Fp2.add(Fp2.mul(Fp2.sqr(x), x), b);
    let y;
    try {
      y = Fp2.sqrt(rhs);
    } catch {
      continue;
    }
    if (!y || !Fp2.eql(Fp2.sqr(y), rhs)) continue;
    if (!bls.G2.ProjectivePoint.fromAffine({ x, y }).isTorsionFree()) {
      return "0x" + fp(x.c0) + fp(x.c1) + fp(y.c0) + fp(y.c1);
    }
  }
}

const ZERO_PK = "0x" + "00".repeat(128);
const ZERO_SIG = "0x" + "00".repeat(256);

/** Locate a storage address[] whose first elements are `expected`; returns its slot */
async function findAddressArraySlot(contract, expected) {
  const addr = await contract.getAddress();
  for (let slot = 0; slot < 64; slot++) {
    const len = BigInt(await ethers.provider.getStorage(addr, slot));
    if (len !== BigInt(expected.length)) continue;
    const base = BigInt(ethers.keccak256(ethers.toBeHex(slot, 32)));
    let match = true;
    for (let i = 0; i < expected.length && match; i++) {
      const word = await ethers.provider.getStorage(addr, base + BigInt(i));
      match = ethers.getAddress(ethers.dataSlice(word, 12)) === expected[i];
    }
    if (match) return slot;
  }
  throw new Error("address array not found");
}

describe("ComplianceCouncil BLS12-381 (EIP-2537)", function () {
  async function deployFixture() {
    const [admin, requester, operator, outsider, ...rest] = await ethers.getSigners();
    const members = rest.slice(0, 6);
    const harness = await (await ethers.getContractFactory("BLS12381Harness")).deploy();
    const Council = await ethers.getContractFactory("ComplianceCouncil");
    // threshold 3, voting period 1h, execution delay 1h, appeal window 1h
    const council = await Council.deploy(3, 3600, 3600, 3600, admin.address);

    const dkg = sdk.generateKeyShares(3, 5);
    const msg = ethers.getBytes(ethers.keccak256(ethers.toUtf8Bytes("warrant message")));
    const share = dkg.shares[0];
    const partial = await sdk.signPartial(share, msg);

    return { harness, council, Council, admin, requester, operator, outsider, members, dkg, msg, share, partial };
  }

  /** Five members holding the DKG shares (keyIndex = share index) */
  async function membersFixture() {
    const base = await deployFixture();
    const { council, members, dkg } = base;
    for (let i = 0; i < 5; i++) {
      await council.addMember(members[i].address, i % 5, sdkPk(dkg.shares[i].publicKey), dkg.shares[i].index);
    }
    return base;
  }

  /** Approved warrants 1 and 2, past executionTime, group key NOT set */
  async function warrantNoGroupKeyFixture() {
    const base = await membersFixture();
    const { council, admin, requester, members } = base;
    await council.connect(admin).setAuthorizedRequester(requester.address, true);

    const docHash = ethers.keccak256(ethers.toUtf8Bytes("Court Order #12345"));
    await council.connect(requester).submitWarrantRequest(0, 42, docHash, "US");
    await council.connect(requester).submitWarrantRequest(0, 43, docHash, "US");
    for (const id of [1, 2]) {
      for (let i = 0; i < 4; i++) await council.connect(members[i]).castVote(id, i < 3, "");
    }
    await time.increase(3601);
    for (const id of [1, 2]) await council.concludeVoting(id);

    const warrant = await council.getWarrant(1);
    expect(warrant.status).to.equal(STATUS.Approved);
    await time.increaseTo((await council.getWarrant(2)).executionTime);

    const message = ethers.getBytes(await council.getSigningMessage(1));
    return { ...base, docHash, warrant, message };
  }

  /** Same, with the DKG group key set */
  async function warrantFixture() {
    const base = await warrantNoGroupKeyFixture();
    await base.council.setAggregatedPublicKey(sdkPk(base.dkg.aggregatedPublicKey));
    return base;
  }

  async function thresholdSig(dkg, message, indices) {
    const partials = await Promise.all(indices.map((i) => sdk.signPartial(dkg.shares[i - 1], message)));
    const agg = sdk.aggregateSignatures(partials);
    return {
      aggregatedSig: sdkSig(agg.aggregatedSignature),
      signerIndices: agg.signerIndices,
      signatureCount: agg.signerIndices.length,
    };
  }

  // ============ Deployment and constants ============

  describe("Deployment and detection", function () {
    it("detects EIP-2537 and starts in STRICT_ONCHAIN", async function () {
      const { harness, council } = await loadFixture(deployFixture);
      expect(await harness.precompilesAvailable()).to.equal(true);
      expect(await council.areBLSPrecompilesAvailable()).to.equal(true);
      expect(await council.executionMode()).to.equal(MODE.STRICT_ONCHAIN);
    });

    it("uses the SDK domain separation tag", async function () {
      const { council } = await loadFixture(deployFixture);
      expect(await council.BLS_SIGNATURE_DST()).to.equal(ethers.hexlify(DST_BYTES));
    });
  });

  // ============ Hash to curve ============

  describe("RFC 9380 hash-to-G2", function () {
    it("expand_message_xmd matches noble", async function () {
      const { harness } = await loadFixture(deployFixture);
      for (const len of [0, 3, 200]) {
        const msg = ethers.randomBytes(len);
        const expected = expand_message_xmd(msg, DST_BYTES, 256, sha256);
        const got = await harness.expandMessageXmd(msg, DST_BYTES);
        expect(ethers.concat([...got])).to.equal(ethers.hexlify(expected));
      }
    });

    it("expand_message_xmd rejects an empty DST", async function () {
      const { harness } = await loadFixture(deployFixture);
      await expect(harness.expandMessageXmd("0x616263", "0x")).to.be.revertedWith("Invalid DST");
    });

    it("matches the RFC 9380 J.10.1 known answer and noble", async function () {
      const { harness } = await loadFixture(deployFixture);
      const rfcDst = ethers.toUtf8Bytes(RFC_DST);

      const [ok, point] = await harness.hashToG2("0x", rfcDst);
      expect(ok).to.equal(true);
      expect(point).to.equal(
        "0x" +
          fp(0x0141ebfbdca40eb85b87142e130ab689c673cf60f1a3e98d69335266f30d9b8d4ac44c1038e9dcdd5393faf5c41fb78an) +
          fp(0x05cb8437535e20ecffaef7752baddf98034139c38452458baeefab379ba13dff5bf5dd71b72418717047f5b0f37da03dn) +
          fp(0x0503921d7f6a12805e72940b963c0cf3471c7b2a524950ca195d11062ee75ec076daf2d4bc358c4b190c0c98064fdd92n) +
          fp(0x12424ac32561493f3fe3c260708a12b7c620e7be00099a974e259ddc7d1f6395c3c811cdd19f1e8dbf3e9ecfdcbab8d6n)
      );

      const abc = ethers.toUtf8Bytes("abc");
      const [ok2, point2] = await harness.hashToG2(abc, rfcDst);
      expect(ok2).to.equal(true);
      expect(point2).to.equal(g2Hex(bls.G2.hashToCurve(abc, { DST: RFC_DST })));
    });

    it("matches sdk.hashMessageToG2 under the council DST", async function () {
      const { harness } = await loadFixture(deployFixture);
      const msgs = [
        new Uint8Array(0),
        ethers.getBytes(ethers.keccak256(ethers.toUtf8Bytes("digest"))),
        ethers.randomBytes(300),
      ];
      for (const m of msgs) {
        const [ok, point] = await harness.hashToG2(m, DST_BYTES);
        expect(ok).to.equal(true);
        expect(point).to.equal(g2Hex(sdk.hashMessageToG2(m)));
      }
    });
  });

  // ============ Signature verification ============

  describe("verifySignature", function () {
    it("accepts a valid SDK key and signature", async function () {
      const { council, share, msg, partial } = await loadFixture(deployFixture);
      expect(await council.verifySignature(msg, sdkSig(partial.signature), sdkPk(share.publicKey))).to.equal(true);
    });

    it("rejects a wrong message", async function () {
      const { council, share, msg, partial } = await loadFixture(deployFixture);
      const other = ethers.keccak256(msg);
      expect(await council.verifySignature(other, sdkSig(partial.signature), sdkPk(share.publicKey))).to.equal(
        false
      );
    });

    it("rejects a wrong key", async function () {
      const { council, dkg, msg, partial } = await loadFixture(deployFixture);
      const otherPk = dkg.shares[1].publicKey;
      expect(await council.verifySignature(msg, sdkSig(partial.signature), sdkPk(otherPk))).to.equal(false);
    });

    it("rejects a signature made with the standard IETF DST", async function () {
      const { council, share, msg } = await loadFixture(deployFixture);
      const sig = bls.sign(msg, share.secretShare, { DST: STANDARD_DST });
      expect(await council.verifySignature(msg, sdkSig(sig), sdkPk(share.publicKey))).to.equal(false);
    });

    it("rejects the infinity key with the infinity signature (trivial forgery)", async function () {
      const { council, msg } = await loadFixture(deployFixture);
      expect(await council.verifySignature(msg, sigStruct(ZERO_SIG), pkStruct(ZERO_PK))).to.equal(false);
    });

    it("rejects the infinity signature under a valid key", async function () {
      const { council, share, msg } = await loadFixture(deployFixture);
      expect(await council.verifySignature(msg, sigStruct(ZERO_SIG), sdkPk(share.publicKey))).to.equal(false);
    });

    it("rejects malformed signatures", async function () {
      const { council, share, msg, partial } = await loadFixture(deployFixture);
      const a = bls.G2.ProjectivePoint.fromHex(partial.signature).toAffine();
      const good = structHex(sdkSig(partial.signature));
      const cases = {
        offCurve: "0x" + fp(a.x.c0) + fp(a.x.c1) + fp(Fp.add(a.y.c0, 1n)) + fp(a.y.c1),
        nonCanonical: "0x" + fp(a.x.c0 + P) + fp(a.x.c1) + fp(a.y.c0) + fp(a.y.c1),
        dirtyPadding: "0x01" + good.slice(4),
        offSubgroup: g2OffSubgroup(),
      };
      expect(await council.verifySignature(msg, sigStruct(good), sdkPk(share.publicKey), GAS)).to.equal(true);
      for (const [name, bad] of Object.entries(cases)) {
        expect(await council.verifySignature(msg, sigStruct(bad), sdkPk(share.publicKey), GAS), name).to.equal(
          false
        );
      }
    });

    it("rejects malformed public keys", async function () {
      const { council, share, msg, partial } = await loadFixture(deployFixture);
      const a = bls.G1.ProjectivePoint.fromHex(share.publicKey).toAffine();
      const cases = {
        offCurve: "0x" + fp(a.x) + fp(Fp.add(a.y, 1n)),
        nonCanonical: "0x" + fp(a.x + P) + fp(a.y),
        offSubgroup: g1OffSubgroup(),
      };
      for (const [name, bad] of Object.entries(cases)) {
        expect(await council.verifySignature(msg, sdkSig(partial.signature), pkStruct(bad), GAS), name).to.equal(
          false
        );
      }
    });
  });

  describe("G1 key checks (library)", function () {
    it("isCanonicalG1 checks the encoding only; isValidG1 adds curve and subgroup checks", async function () {
      const { harness, share } = await loadFixture(deployFixture);
      const valid = g1Hex(bls.G1.ProjectivePoint.fromHex(share.publicKey));
      const a = bls.G1.ProjectivePoint.fromHex(share.publicKey).toAffine();
      const xEqualsP = "0x" + fp(P) + fp(a.y);
      const dirtyPad = "0x01" + valid.slice(4);
      const offSubgroup = g1OffSubgroup();

      expect(await harness.isCanonicalG1(valid)).to.equal(true);
      expect(await harness.isCanonicalG1(ZERO_PK)).to.equal(false);
      expect(await harness.isCanonicalG1(xEqualsP)).to.equal(false);
      expect(await harness.isCanonicalG1(dirtyPad)).to.equal(false);
      expect(await harness.isCanonicalG1(offSubgroup)).to.equal(true);

      expect(await harness.isValidG1(valid)).to.equal(true);
      expect(await harness.isValidG1(offSubgroup, GAS)).to.equal(false);
      expect(await harness.isValidG1(ZERO_PK)).to.equal(false);
    });
  });

  // ============ aggregateSignatures ============

  describe("aggregateSignatures", function () {
    it("is a plain G2 sum equal to noble's aggregate", async function () {
      const { council, msg } = await loadFixture(deployFixture);
      const sks = [1, 2, 3].map(() => bls.utils.randomPrivateKey());
      const sigs = sks.map((k) => bls.sign(msg, k, { DST }));
      const res = await council.aggregateSignatures(sigs.map(sdkSig));
      const expected = sdkSig(bls.aggregateSignatures(sigs));
      expect(structHex(res)).to.equal(structHex(expected));

      const aggPk = bls.aggregatePublicKeys(sks.map((k) => bls.getPublicKey(k)));
      const agg = { x: [...res.x], y: [...res.y] };
      expect(await council.verifySignature(msg, agg, sdkPk(aggPk))).to.equal(true);
    });

    it("reverts on empty input and on a malformed element", async function () {
      const { council, msg, partial } = await loadFixture(deployFixture);
      await expect(council.aggregateSignatures([])).to.be.revertedWith("No signatures");
      const a = bls.G2.ProjectivePoint.fromHex(partial.signature).toAffine();
      const offCurve = "0x" + fp(a.x.c0) + fp(a.x.c1) + fp(Fp.add(a.y.c0, 1n)) + fp(a.y.c1);
      const other = bls.sign(msg, bls.utils.randomPrivateKey(), { DST });
      await expect(
        council.aggregateSignatures([sdkSig(partial.signature), sdkSig(other), sigStruct(offCurve)], GAS)
      ).to.be.revertedWith("Invalid signature");
    });
  });

  // ============ Member keys ============

  describe("Member key registration", function () {
    it("rejects invalid member keys and stores a valid key byte-exact", async function () {
      const { council, members, share } = await loadFixture(deployFixture);
      const a = bls.G1.ProjectivePoint.fromHex(share.publicKey).toAffine();
      const bad = {
        zero: ZERO_PK,
        offCurve: "0x" + fp(a.x) + fp(Fp.add(a.y, 1n)),
        nonCanonical: "0x" + fp(a.x + P) + fp(a.y),
        offSubgroup: g1OffSubgroup(),
      };
      for (const [name, k] of Object.entries(bad)) {
        await expect(council.addMember(members[0].address, 0, pkStruct(k), 1, GAS), name).to.be.revertedWith(
          "Invalid BLS public key"
        );
      }

      await council.addMember(members[0].address, 0, sdkPk(share.publicKey), 1);
      const stored = (await council.getMember(members[0].address)).publicKey;
      expect(structHex(stored)).to.equal(g1Hex(bls.G1.ProjectivePoint.fromHex(share.publicKey)));
      expect(sdk.decodeBLSPublicKeyFromSolidity(stored)).to.deep.equal(share.publicKey);
    });

    it("rotateMemberKey rejects an off-subgroup key", async function () {
      const { council, members, share } = await loadFixture(deployFixture);
      await council.addMember(members[0].address, 0, sdkPk(share.publicKey), 1);
      await expect(
        council.rotateMemberKey(members[0].address, pkStruct(g1OffSubgroup()), GAS)
      ).to.be.revertedWith("Invalid BLS public key");
    });

    it("enforces unique key indices among active members", async function () {
      const { council, members, dkg } = await loadFixture(membersFixture);
      const freshKey = sdkPk(bls.getPublicKey(bls.utils.randomPrivateKey()));
      await expect(council.addMember(members[5].address, 0, freshKey, 3)).to.be.revertedWith("Key index in use");

      await council.removeMember(members[2].address);
      await council.addMember(members[5].address, 0, sdkPk(dkg.shares[2].publicKey), 3);
      expect((await council.getMember(members[5].address)).keyIndex).to.equal(3);
    });

    it("does not duplicate a re-added member", async function () {
      const { council, members, dkg } = await loadFixture(deployFixture);
      const addrs = members.map((m) => m.address);
      for (let i = 0; i < 4; i++) {
        await council.addMember(addrs[i], 0, sdkPk(dkg.shares[i].publicKey), i + 1);
      }
      const slot = await findAddressArraySlot(council, addrs.slice(0, 4));

      await council.removeMember(addrs[0]);
      await council.addMember(addrs[0], 0, sdkPk(dkg.shares[0].publicKey), 1);
      await council.addMember(addrs[4], 0, sdkPk(dkg.shares[4].publicKey), 5);

      const active = (await council.getActiveMembers()).map((m) => m.memberAddress);
      expect(active).to.have.members(addrs.slice(0, 5));
      expect(new Set(active).size).to.equal(active.length);

      const len = BigInt(await ethers.provider.getStorage(await council.getAddress(), slot));
      expect(len).to.equal(5n);
    });
  });

  // ============ Group key ============

  describe("setAggregatedPublicKey", function () {
    it("is admin-only and validates the key", async function () {
      const { council, outsider, dkg } = await loadFixture(deployFixture);
      await expect(
        council.connect(outsider).setAggregatedPublicKey(sdkPk(dkg.aggregatedPublicKey))
      ).to.be.revertedWithCustomError(council, "AccessControlUnauthorizedAccount");
      await expect(council.setAggregatedPublicKey(pkStruct(ZERO_PK))).to.be.revertedWith("Invalid BLS public key");
      await expect(council.setAggregatedPublicKey(pkStruct(g1OffSubgroup()), GAS)).to.be.revertedWith(
        "Invalid BLS public key"
      );
    });

    it("stores the group key and emits AggregatedPublicKeyUpdated", async function () {
      const { council, admin, dkg } = await loadFixture(deployFixture);
      expect(structHex(await council.getAggregatedPublicKey())).to.equal(ZERO_PK);

      const groupKey = sdkPk(dkg.aggregatedPublicKey);
      const tx = await council.setAggregatedPublicKey(groupKey);
      const receipt = await tx.wait();
      const events = receipt.logs
        .map((l) => council.interface.parseLog(l))
        .filter((e) => e && e.name === "AggregatedPublicKeyUpdated");
      expect(events.length).to.equal(1);
      expect(structHex(events[0].args.groupKey)).to.equal(structHex(groupKey));
      expect(events[0].args.updatedBy).to.equal(admin.address);

      const stored = await council.getAggregatedPublicKey();
      expect(structHex(stored)).to.equal(structHex(groupKey));
      expect(sdk.decodeBLSPublicKeyFromSolidity(stored)).to.deep.equal(dkg.aggregatedPublicKey);
    });
  });

  // ============ Threshold flow ============

  describe("Threshold flow (SDK DKG -> partials -> aggregate -> contract)", function () {
    it("signing message matches the SDK", async function () {
      const { council, warrant } = await loadFixture(warrantFixture);
      const expected = sdk.createSolidityWarrantMessage({
        chainId: 31337n,
        council: await council.getAddress(),
        warrantId: warrant.id,
        targetDisputeId: warrant.targetDisputeId,
        documentHash: ethers.getBytes(warrant.documentHash),
        executionTime: warrant.executionTime,
      });
      expect(await council.getSigningMessage(1)).to.equal(ethers.hexlify(expected));
      expect(await council.getSigningMessage(2)).to.not.equal(ethers.hexlify(expected));
    });

    it("verifies partial signatures on submission and executes in STRICT_ONCHAIN", async function () {
      const { council, members, dkg, message } = await loadFixture(warrantFixture);
      expect(await council.executionMode()).to.equal(MODE.STRICT_ONCHAIN);

      for (const i of [1, 2, 4]) {
        const partial = await sdk.signPartial(dkg.shares[i - 1], message);
        await council.connect(members[i - 1]).submitSignature(1, sdkSig(partial.signature));
      }
      const subs = await council.getSignatures(1);
      expect(subs.map((s) => s.verified)).to.deep.equal([true, true, true]);
      expect(subs.map((s) => s.memberIndex)).to.deep.equal([1n, 2n, 4n]);

      await expect(council.executeReconstruction(1)).to.emit(council, "KeyReconstructed");
      expect((await council.getWarrant(1)).status).to.equal(STATUS.Executed);
    });

    it("rejects a copied, wrong-message or cross-deployment partial signature", async function () {
      const { council, Council, admin, members, dkg, warrant, message } = await loadFixture(warrantFixture);

      // Another member's valid partial, copied
      const other = await sdk.signPartial(dkg.shares[1], message);
      await expect(council.connect(members[0]).submitSignature(1, sdkSig(other.signature))).to.be.revertedWith(
        "Invalid signature"
      );

      // Own share over the wrong message (warrant 2)
      const wrong = await sdk.signPartial(dkg.shares[0], ethers.getBytes(await council.getSigningMessage(2)));
      await expect(council.connect(members[0]).submitSignature(1, sdkSig(wrong.signature))).to.be.revertedWith(
        "Invalid signature"
      );

      // Same keys and warrant fields, signed for a second council deployment
      const council2 = await Council.deploy(3, 3600, 3600, 3600, admin.address);
      const fields = {
        chainId: 31337n,
        warrantId: 1n,
        targetDisputeId: warrant.targetDisputeId,
        documentHash: ethers.getBytes(warrant.documentHash),
        executionTime: warrant.executionTime,
      };
      expect(ethers.hexlify(sdk.createWarrantMessage({ ...fields, council: await council.getAddress() }))).to.equal(
        ethers.hexlify(message)
      );
      const replayMsg = sdk.createWarrantMessage({ ...fields, council: await council2.getAddress() });
      const replay = await sdk.signPartial(dkg.shares[0], replayMsg);
      await expect(council.connect(members[0]).submitSignature(1, sdkSig(replay.signature))).to.be.revertedWith(
        "Invalid signature"
      );

      // The genuine partial is still accepted
      const own = await sdk.signPartial(dkg.shares[0], message);
      await council.connect(members[0]).submitSignature(1, sdkSig(own.signature));
      expect((await council.getSignatures(1))[0].verified).to.equal(true);
    });

    it("verifyThresholdSignature accepts any valid t-subset aggregate", async function () {
      const { council, dkg, message } = await loadFixture(warrantFixture);
      const a = await thresholdSig(dkg, message, [1, 2, 4]);
      const b = await thresholdSig(dkg, message, [2, 3, 5]);
      expect(structHex(a.aggregatedSig)).to.equal(structHex(b.aggregatedSig));
      expect(await council.verifyThresholdSignature(1, a)).to.equal(true);
      expect(await council.verifyThresholdSignature(1, b)).to.equal(true);

      // Signer order given to the SDK does not matter
      const c = await thresholdSig(dkg, message, [4, 1, 2]);
      expect(c.signerIndices).to.deep.equal([1, 2, 4]);
      expect(await council.verifyThresholdSignature(1, c)).to.equal(true);
    });

    it("verifyThresholdSignature returns false for invalid aggregates", async function () {
      const { council, dkg, message } = await loadFixture(warrantFixture);

      // Only two shares signed, presented as three signers
      const two = await thresholdSig(dkg, message, [1, 2]);
      expect(await council.verifyThresholdSignature(1, { ...two, signerIndices: [1, 2, 3], signatureCount: 3 })).to
        .equal(false);

      // A valid aggregate for warrant 1 presented for warrant 2
      const valid = await thresholdSig(dkg, message, [1, 2, 3]);
      expect(await council.verifyThresholdSignature(1, valid)).to.equal(true);
      expect(await council.verifyThresholdSignature(2, valid)).to.equal(false);

      // Unknown warrant
      expect(await council.verifyThresholdSignature(99, valid)).to.equal(false);
    });

    it("verifyThresholdSignature returns false while the group key is unset", async function () {
      const { council, dkg, message } = await loadFixture(warrantNoGroupKeyFixture);
      const valid = await thresholdSig(dkg, message, [1, 2, 3]);
      expect(await council.verifyThresholdSignature(1, valid)).to.equal(false);
    });

    it("verifyThresholdSignature validates the signer indices", async function () {
      const { council, members, dkg, message } = await loadFixture(warrantFixture);
      const valid = await thresholdSig(dkg, message, [1, 2, 4]);
      const sig = valid.aggregatedSig;

      await expect(
        council.verifyThresholdSignature(1, { aggregatedSig: sig, signerIndices: [1, 2], signatureCount: 2 })
      ).to.be.revertedWith("Below threshold");
      await expect(
        council.verifyThresholdSignature(1, { aggregatedSig: sig, signerIndices: [1, 2], signatureCount: 3 })
      ).to.be.revertedWith("Signer count mismatch");
      await expect(
        council.verifyThresholdSignature(1, { aggregatedSig: sig, signerIndices: [2, 1, 4], signatureCount: 3 })
      ).to.be.revertedWith("Unsorted signers");
      await expect(
        council.verifyThresholdSignature(1, { aggregatedSig: sig, signerIndices: [1, 1, 2], signatureCount: 3 })
      ).to.be.revertedWith("Unsorted signers");
      await expect(
        council.verifyThresholdSignature(1, { aggregatedSig: sig, signerIndices: [0, 1, 2], signatureCount: 3 })
      ).to.be.revertedWith("Unsorted signers");

      // Never-added index
      await expect(
        council.verifyThresholdSignature(1, { aggregatedSig: sig, signerIndices: [1, 2, 6], signatureCount: 3 })
      ).to.be.revertedWith("Unknown signer");

      // Removed member's index
      await council.removeMember(members[4].address);
      await expect(
        council.verifyThresholdSignature(1, { aggregatedSig: sig, signerIndices: [1, 2, 5], signatureCount: 3 })
      ).to.be.revertedWith("Unknown signer");
    });
  });

  // ============ Follow-up fixes ============

  const R = bls.fields.Fr.ORDER;

  /** Member `index` (1-based share index) submits its partial signature on `message` for `warrantId` */
  async function signAs(council, members, dkg, message, warrantId, index) {
    const partial = await sdk.signPartial(dkg.shares[index - 1], message);
    await council.connect(members[index - 1]).submitSignature(warrantId, sdkSig(partial.signature));
  }

  /** SDK decryptedKeyHash for the threshold signature of `indices` on `message` */
  async function expectedKeyHash(dkg, message, indices) {
    const partials = await Promise.all(indices.map((i) => sdk.signPartial(dkg.shares[i - 1], message)));
    return ethers.hexlify(sdk.computeDecryptedKeyHash(sdk.aggregateSignatures(partials).aggregatedSignature));
  }

  /** A fresh BLS key pair outside the DKG */
  function freshKey() {
    const sk = bls.utils.randomPrivateKey();
    return { sk, pk: sdkPk(bls.getPublicKey(sk)) };
  }

  describe("Only current partial signatures count (STRICT_ONCHAIN)", function () {
    it("a removed member's partial no longer counts toward the threshold", async function () {
      const { council, members, dkg, message } = await loadFixture(warrantFixture);
      for (const i of [1, 2, 3]) await signAs(council, members, dkg, message, 1, i);
      expect(await council.hasSubmittedSignature(1, members[2].address)).to.equal(true);

      await council.removeMember(members[2].address);
      expect(await council.hasSubmittedSignature(1, members[2].address)).to.equal(false);
      const subs = await council.getSignatures(1);
      expect(subs.map((s) => s.signer)).to.deep.equal(members.slice(0, 3).map((m) => m.address));

      await expect(council.executeReconstruction(1)).to.be.revertedWith("Insufficient signatures");

      await signAs(council, members, dkg, message, 1, 4);
      await expect(council.executeReconstruction(1)).to.emit(council, "KeyReconstructed");
    });

    it("a removed member whose MEMBER_ROLE is granted back directly can neither sign nor vote", async function () {
      const { council, members, dkg, message, requester, docHash } = await loadFixture(warrantFixture);
      for (const i of [1, 2, 3]) await signAs(council, members, dkg, message, 1, i);
      await council.removeMember(members[2].address);
      await expect(council.executeReconstruction(1)).to.be.revertedWith("Insufficient signatures");

      // The role without addMember: still inactive, key registration id 0, stale share key still stored
      await council.grantRole(await council.MEMBER_ROLE(), members[2].address);
      const m = await council.getMember(members[2].address);
      expect(m.isActive).to.equal(false);
      expect(m.keyId).to.equal(0n);

      // Its share-3 partial verifies against that stale key; recorded under keyId 0 it would have matched the
      // zeroed registration and completed the threshold with two active signers
      const partial = await sdk.signPartial(dkg.shares[2], message);
      await expect(council.connect(members[2]).submitSignature(1, sdkSig(partial.signature))).to.be.revertedWith(
        "Not a member"
      );
      expect((await council.getSignatures(1)).length).to.equal(3);
      await expect(council.executeReconstruction(1)).to.be.revertedWith("Insufficient signatures");

      await council.connect(requester).submitWarrantRequest(0, 44, docHash, "US");
      await expect(council.connect(members[2]).castVote(3, true, "")).to.be.revertedWith("Not a member");

      // Its key index can go to a new member, whose partial at x = 3 completes the threshold
      await council.addMember(members[5].address, 0, sdkPk(dkg.shares[2].publicKey), 3);
      await council.connect(members[5]).submitSignature(1, sdkSig(partial.signature));
      await council.executeReconstruction(1);
      expect((await council.getWarrant(1)).decryptedKeyHash).to.equal(await expectedKeyHash(dkg, message, [1, 2, 3]));
    });

    it("a re-added member's old partial stays void until it signs again", async function () {
      const { council, members, dkg, message } = await loadFixture(warrantFixture);
      for (const i of [1, 2, 3]) await signAs(council, members, dkg, message, 1, i);
      await council.removeMember(members[2].address);
      await council.addMember(members[2].address, 0, sdkPk(dkg.shares[2].publicKey), 3);

      expect(await council.hasSubmittedSignature(1, members[2].address)).to.equal(false);
      await expect(council.executeReconstruction(1)).to.be.revertedWith("Insufficient signatures");

      await signAs(council, members, dkg, message, 1, 3);
      const again = await sdk.signPartial(dkg.shares[2], message);
      await expect(council.connect(members[2]).submitSignature(1, sdkSig(again.signature))).to.be.revertedWith(
        "Already submitted"
      );
      await expect(council.executeReconstruction(1)).to.emit(council, "KeyReconstructed");
    });

    it("a rotated key voids the partial; the member may sign again", async function () {
      const { council, members, dkg, message } = await loadFixture(warrantFixture);
      for (const i of [1, 2, 4]) await signAs(council, members, dkg, message, 1, i);

      // Rotate member 2 away from its DKG share: its partial stops counting
      const other = freshKey();
      await expect(council.rotateMemberKey(members[1].address, other.pk)).to.emit(council, "MemberKeyRotated");
      expect(await council.hasSubmittedSignature(1, members[1].address)).to.equal(false);
      await expect(council.executeReconstruction(1)).to.be.revertedWith("Insufficient signatures");

      // A partial under the new key verifies, but that key is not a share of the group key
      const wrong = bls.sign(message, other.sk, { DST });
      await council.connect(members[1]).submitSignature(1, sdkSig(wrong));
      await expect(council.executeReconstruction(1)).to.be.revertedWith("Invalid threshold signature");

      // Back on the DKG share (a new registration): sign once more and execute
      await council.rotateMemberKey(members[1].address, sdkPk(dkg.shares[1].publicKey));
      await expect(council.executeReconstruction(1)).to.be.revertedWith("Insufficient signatures");
      await signAs(council, members, dkg, message, 1, 2);

      const subs = await council.getSignatures(1);
      expect(subs.length).to.equal(5);
      await council.executeReconstruction(1);
      expect((await council.getWarrant(1)).decryptedKeyHash).to.equal(await expectedKeyHash(dkg, message, [3, 4, 5]));
    });

    it("a member key that is not a share blocks execution until the member is removed", async function () {
      const { council, members, dkg, message } = await loadFixture(warrantFixture);
      const outsider = freshKey();
      await council.addMember(members[5].address, 0, outsider.pk, 6);

      await council.connect(members[5]).submitSignature(1, sdkSig(bls.sign(message, outsider.sk, { DST })));
      for (const i of [1, 2]) await signAs(council, members, dkg, message, 1, i);
      await expect(council.executeReconstruction(1)).to.be.revertedWith("Invalid threshold signature");

      await council.removeMember(members[5].address);
      await expect(council.executeReconstruction(1)).to.be.revertedWith("Insufficient signatures");
      await signAs(council, members, dkg, message, 1, 3);
      await expect(council.executeReconstruction(1)).to.emit(council, "KeyReconstructed");
    });
  });

  describe("decryptedKeyHash", function () {
    it("is keccak256 of the group signature, whichever threshold subset signs", async function () {
      const { council, members, dkg, message, requester } = await loadFixture(warrantFixture);
      const message2 = ethers.getBytes(await council.getSigningMessage(2));
      for (const i of [1, 2, 4]) await signAs(council, members, dkg, message, 1, i);
      for (const i of [3, 4, 5]) await signAs(council, members, dkg, message2, 2, i);

      // Aggregated by the SDK from other subsets than the ones that signed on chain
      const h1 = await expectedKeyHash(dkg, message, [3, 5, 2]);
      const h2 = await expectedKeyHash(dkg, message2, [1, 2, 3]);
      expect(h1).to.not.equal(h2);

      // Equals keccak256 of the BLSSignature struct encoding of the threshold signature
      const partials = await Promise.all([1, 2, 3].map((i) => sdk.signPartial(dkg.shares[i - 1], message)));
      const agg = sdk.aggregateSignatures(partials);
      expect(ethers.keccak256(structHex(sdkSig(agg.aggregatedSignature)))).to.equal(h1);

      expect(await council.executeReconstruction.staticCall(1)).to.equal(h1);
      await expect(council.executeReconstruction(1))
        .to.emit(council, "KeyReconstructed")
        .withArgs(1, h1, requester.address);
      await council.executeReconstruction(2);
      expect((await council.getWarrant(1)).decryptedKeyHash).to.equal(h1);
      expect((await council.getWarrant(2)).decryptedKeyHash).to.equal(h2);
    });

    it("STRICT_ONCHAIN execution requires the group key", async function () {
      const { council, members, dkg, message } = await loadFixture(warrantNoGroupKeyFixture);
      for (const i of [1, 2, 3]) await signAs(council, members, dkg, message, 1, i);
      await expect(council.executeReconstruction(1)).to.be.revertedWith("Invalid threshold signature");

      await council.setAggregatedPublicKey(sdkPk(dkg.aggregatedPublicKey));
      await council.executeReconstruction(1);
      expect((await council.getWarrant(1)).decryptedKeyHash).to.equal(await expectedKeyHash(dkg, message, [1, 2, 3]));
    });

    it("HYBRID_ATTESTED records the operator-attested hash", async function () {
      const { council, members, dkg, message, operator } = await loadFixture(warrantFixture);
      await council.setExecutionMode(MODE.HYBRID_ATTESTED, "test");
      await council.grantRole(await council.OPERATOR_ROLE(), operator.address);
      for (const i of [1, 2, 3]) await signAs(council, members, dkg, message, 1, i);

      await expect(council.executeReconstruction(1)).to.be.revertedWith("Hybrid attestation required");
      await expect(council.connect(operator).attestHybridVerification(1, ethers.ZeroHash, "sdk")).to.be.revertedWith(
        "Invalid attestation"
      );
      const h = await expectedKeyHash(dkg, message, [1, 2, 3]);
      await council.connect(operator).attestHybridVerification(1, h, "sdk computeDecryptedKeyHash");
      await council.executeReconstruction(1);
      expect((await council.getWarrant(1)).decryptedKeyHash).to.equal(h);
    });
  });

  describe("Key index bound", function () {
    /** 3-of-7 council: indices 1..7 (the old bound keyIndex <= 2 * threshold allowed only 1..6) */
    async function sevenFixture() {
      const signers = await ethers.getSigners();
      const [admin, requester] = signers;
      const members = signers.slice(4, 11);
      const council = await (await ethers.getContractFactory("ComplianceCouncil")).deploy(3, 3600, 3600, 3600, admin.address);
      const dkg = sdk.generateKeyShares(3, 7);
      for (let i = 0; i < 7; i++) {
        await council.addMember(members[i].address, 0, sdkPk(dkg.shares[i].publicKey), i + 1);
      }
      await council.setAggregatedPublicKey(sdkPk(dkg.aggregatedPublicKey));
      await council.setAuthorizedRequester(requester.address, true);
      await council.connect(requester).submitWarrantRequest(0, 42, ethers.keccak256("0x01"), "US");
      for (let i = 0; i < 3; i++) await council.connect(members[i]).castVote(1, true, "");
      await time.increase(3601);
      await council.concludeVoting(1);
      await time.increaseTo((await council.getWarrant(1)).executionTime);
      const message = ethers.getBytes(await council.getSigningMessage(1));
      return { council, members, dkg, message };
    }

    it("a 3-of-7 council can be configured and executes with the top three indices", async function () {
      const { council, members, dkg, message } = await loadFixture(sevenFixture);
      expect((await council.getConfig()).totalMembers).to.equal(7n);
      for (const i of [7, 5, 6]) await signAs(council, members, dkg, message, 1, i);
      await council.executeReconstruction(1);
      expect((await council.getWarrant(1)).decryptedKeyHash).to.equal(await expectedKeyHash(dkg, message, [1, 2, 3]));
    });

    it("accepts any index in [1, r) and rejects 0 and r", async function () {
      const { council, members } = await loadFixture(deployFixture);
      await expect(council.addMember(members[0].address, 0, freshKey().pk, 0)).to.be.revertedWith("Invalid key index");
      await expect(council.addMember(members[0].address, 0, freshKey().pk, R)).to.be.revertedWith("Invalid key index");
      await council.addMember(members[0].address, 0, freshKey().pk, R - 1n);
      await council.addMember(members[1].address, 0, freshKey().pk, 1000n);
      expect((await council.getMember(members[0].address)).keyIndex).to.equal(R - 1n);
    });
  });

  describe("Duplicate keys", function () {
    it("rejects a key held by another active member, and the current key on rotation", async function () {
      const { council, members, dkg } = await loadFixture(membersFixture);
      await expect(council.addMember(members[5].address, 0, sdkPk(dkg.shares[0].publicKey), 6)).to.be.revertedWith(
        "BLS key in use"
      );
      await expect(council.rotateMemberKey(members[0].address, sdkPk(dkg.shares[1].publicKey))).to.be.revertedWith(
        "BLS key in use"
      );
      await expect(council.rotateMemberKey(members[0].address, sdkPk(dkg.shares[0].publicKey))).to.be.revertedWith(
        "BLS key in use"
      );
    });

    it("keeps member keys and the group key apart", async function () {
      const { council, members, dkg } = await loadFixture(membersFixture);
      const group = sdkPk(dkg.aggregatedPublicKey);
      await expect(council.setAggregatedPublicKey(sdkPk(dkg.shares[3].publicKey))).to.be.revertedWith(
        "BLS key in use"
      );
      await council.setAggregatedPublicKey(group);
      await council.setAggregatedPublicKey(group);
      await expect(council.addMember(members[5].address, 0, group, 6)).to.be.revertedWith("BLS key in use");
      await expect(council.rotateMemberKey(members[0].address, group)).to.be.revertedWith("BLS key in use");
    });
  });

  describe("aggregateSignatures validates every element", function () {
    it("validates a single element like several", async function () {
      const { council, partial } = await loadFixture(deployFixture);
      const good = structHex(sdkSig(partial.signature));
      const a = bls.G2.ProjectivePoint.fromHex(partial.signature).toAffine();
      const bad = {
        offSubgroup: g2OffSubgroup(),
        offCurve: "0x" + fp(a.x.c0) + fp(a.x.c1) + fp(Fp.add(a.y.c0, 1n)) + fp(a.y.c1),
        nonCanonical: "0x" + fp(a.x.c0 + P) + fp(a.x.c1) + fp(a.y.c0) + fp(a.y.c1),
        dirtyPadding: "0x01" + good.slice(4),
        infinity: ZERO_SIG,
      };

      expect(structHex(await council.aggregateSignatures([sigStruct(good)]))).to.equal(good);
      for (const [name, b] of Object.entries(bad)) {
        await expect(council.aggregateSignatures([sigStruct(b)], GAS), name).to.be.revertedWith("Invalid signature");
      }
      // G2ADD does not check the subgroup: a pair with an off-subgroup point used to be summed
      await expect(council.aggregateSignatures([sigStruct(good), sigStruct(bad.offSubgroup)], GAS)).to.be.revertedWith(
        "Invalid signature"
      );
    });
  });

  describe("Lagrange interpolation (library)", function () {
    it("interpolateG2AtZero matches the SDK aggregate and rejects repeated or out-of-range points", async function () {
      const { dkg, msg } = await loadFixture(deployFixture);
      const th = await (await ethers.getContractFactory("BLS12381ThresholdHarness")).deploy();
      const indices = [5, 1, 3];
      const partials = await Promise.all(indices.map((i) => sdk.signPartial(dkg.shares[i - 1], msg)));
      const pairs = ethers.concat(partials.map((p) => ethers.concat([structHex(sdkSig(p.signature)), ethers.ZeroHash])));

      const [ok, sum] = await th.interpolateG2AtZero(pairs, indices);
      expect(ok).to.equal(true);
      expect(sum).to.equal(structHex(sdkSig(sdk.aggregateSignatures(partials).aggregatedSignature)));

      for (const xs of [[5, 1, 5], [5, 0, 3], [5, 1, R], [5, 1]]) {
        const [bad] = await th.interpolateG2AtZero(pairs, xs);
        expect(bad, xs.join(",")).to.equal(false);
      }
    });
  });

  describe("updateConfig keeps the member count", function () {
    it("ignores config.totalMembers", async function () {
      const { council, members, requester } = await loadFixture(membersFixture);
      const cfg = await council.getConfig();
      const next = { ...cfg.toObject(), totalMembers: 1n };
      await expect(council.updateConfig(next)).to.emit(council, "ConfigUpdated").withArgs(3, 5, cfg.votingPeriod);
      expect((await council.getConfig()).totalMembers).to.equal(5n);
      expect((await council.getActiveMembers()).length).to.equal(5);

      // A corrupted count of 1 would conclude a warrant on its first vote
      await council.setAuthorizedRequester(requester.address, true);
      await council.connect(requester).submitWarrantRequest(0, 1, ethers.keccak256("0x02"), "US");
      await council.connect(members[0]).castVote(1, true, "");
      expect((await council.getWarrant(1)).status).to.equal(STATUS.Pending);

      await expect(council.updateConfig({ ...next, threshold: 6n, totalMembers: 100n })).to.be.revertedWith(
        "Threshold > members"
      );
    });
  });

  describe("verifyThresholdSignature on an unknown warrant", function () {
    it("returns false even for a valid group signature over the unknown warrant's message", async function () {
      const { council, dkg } = await loadFixture(warrantFixture);
      const groupKey = sdkPk(dkg.aggregatedPublicKey);
      for (const id of [0n, 99n]) {
        const message = ethers.getBytes(await council.getSigningMessage(id));
        expect(ethers.hexlify(message)).to.equal(
          ethers.hexlify(
            sdk.createWarrantMessage({
              chainId: 31337n,
              council: await council.getAddress(),
              warrantId: id,
              targetDisputeId: 0n,
              documentHash: new Uint8Array(32),
              executionTime: 0n,
            })
          )
        );
        const ts = await thresholdSig(dkg, message, [1, 2, 3]);
        // The signature is valid for that message under the group key: only the warrant guard rejects it
        expect(await council.verifySignature(message, ts.aggregatedSig, groupKey)).to.equal(true);
        expect(await council.verifyThresholdSignature(id, ts)).to.equal(false);
      }
    });
  });

  describe("SDK decoders reject non-canonical encodings", function () {
    it("decodeBLSSignatureFromSolidity", async function () {
      const { partial } = await loadFixture(deployFixture);
      const good = structHex(sdkSig(partial.signature));
      const a = bls.G2.ProjectivePoint.fromHex(partial.signature).toAffine();
      const yOffset = 2 + 128 * 2; // hex offset of y.c0
      expect(sdk.decodeBLSSignatureFromSolidity(sigStruct(good))).to.deep.equal(
        bls.G2.ProjectivePoint.fromHex(partial.signature).toRawBytes(true)
      );
      const bad = {
        xc0PlusP: "0x" + fp(a.x.c0 + P) + fp(a.x.c1) + fp(a.y.c0) + fp(a.y.c1),
        yc1PlusP: "0x" + fp(a.x.c0) + fp(a.x.c1) + fp(a.y.c0) + fp(a.y.c1 + P),
        dirtyPadding: "0x01" + good.slice(4),
        dirtyPaddingY: good.slice(0, yOffset) + "01" + good.slice(yOffset + 2),
      };
      for (const [name, b] of Object.entries(bad)) {
        expect(() => sdk.decodeBLSSignatureFromSolidity(sigStruct(b)), name).to.throw(/Non-canonical/);
      }
    });

    it("decodeBLSPublicKeyFromSolidity", async function () {
      const { share } = await loadFixture(deployFixture);
      const a = bls.G1.ProjectivePoint.fromHex(share.publicKey).toAffine();
      const good = "0x" + fp(a.x) + fp(a.y);
      expect(sdk.decodeBLSPublicKeyFromSolidity(pkStruct(good))).to.deep.equal(share.publicKey);
      for (const b of ["0x" + fp(a.x + P) + fp(a.y), "0x01" + good.slice(4)]) {
        expect(() => sdk.decodeBLSPublicKeyFromSolidity(pkStruct(b))).to.throw(/Non-canonical/);
      }
    });
  });
});
