/**
 * ComplianceCouncil follow-ups on the EIP-2537 precompiles (Hardhat network >= Prague)
 *
 * - getCurrentSignatures and the SDK operator flow (selectCurrentSubmissions, aggregateCurrentPartials,
 *   aggregateWarrantSignature over COMPLIANCE_COUNCIL_ABI): stale partials are never aggregated
 * - aggregateSignatures rejects a sum that is the point at infinity (contract and SDK)
 * - even-threshold reconstruction (a sign error in the Lagrange denominators only shows for even t),
 *   checked against a group signature computed directly from the master secret
 * - the verifyThresholdSignature unknown-warrant guard at warrantId == counter and counter + 1
 * - the SDK decoders at a limb value of exactly p
 */

const { expect } = require("chai");
const { ethers, artifacts } = require("hardhat");
const { loadFixture, time } = require("@nomicfoundation/hardhat-network-helpers");
const { bls12_381: bls } = require("@noble/curves/bls12-381");

// The SDK is TypeScript; load it with ts-node unless another test already registered it
if (!process[Symbol.for("ts-node.register.instance")]) {
  require("ts-node").register({ transpileOnly: true, compilerOptions: { module: "commonjs" } });
}
const sdk = require("../sdk/threshold-bls");

const P = bls.fields.Fp.ORDER;
const DST = sdk.WARRANT_SIGNATURE_DST;
const MODE = { DISABLED: 0, STRICT_ONCHAIN: 1, HYBRID_ATTESTED: 2 };
const STATUS = { Approved: 1, Executing: 3, Executed: 4 };

// ============ Encoding helpers (EIP-2537) ============

const fp = (v) => ethers.toBeHex(v, 64).slice(2);

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

const structHex = (s) => ethers.concat([...s.x, ...s.y]);

const sdkPk = (pk) => {
  const e = sdk.encodeBLSPublicKeyForSolidity(pk);
  return { x: e.x.map((w) => ethers.hexlify(w)), y: e.y.map((w) => ethers.hexlify(w)) };
};

const sdkSig = (sig) => {
  const e = sdk.encodeBLSSignatureForSolidity(sig);
  return { x: e.x.map((w) => ethers.hexlify(w)), y: e.y.map((w) => ethers.hexlify(w)) };
};

const g2 = (bytes) => bls.G2.ProjectivePoint.fromHex(bytes);

/** decryptedKeyHash of the group signature, computed from the master secret without any Lagrange code */
const directKeyHash = (message, masterSecret) => ethers.keccak256(g2Hex(g2(bls.sign(message, masterSecret, { DST }))));

/** A council with threshold t, voting period, execution delay and appeal window of 1h */
async function deployCouncil(t, admin) {
  return (await ethers.getContractFactory("ComplianceCouncil")).deploy(t, 3600, 3600, 3600, admin.address);
}

/**
 * A t-of-n council whose members hold the shares of a known master secret, with the group key set and
 * approved warrants 1 and 2 past their execution time
 */
async function councilFixture(t, n) {
  const [admin, requester, operator, outsider, ...rest] = await ethers.getSigners();
  const members = rest.slice(0, n + 1);
  const council = await deployCouncil(t, admin);
  const masterSecret = bls.utils.randomPrivateKey();
  const dkg = sdk.generateKeyShares(t, n, masterSecret);
  for (let i = 0; i < n; i++) {
    await council.addMember(members[i].address, i % 5, sdkPk(dkg.shares[i].publicKey), dkg.shares[i].index);
  }
  await council.setAggregatedPublicKey(sdkPk(dkg.aggregatedPublicKey));
  await council.setAuthorizedRequester(requester.address, true);
  await council.grantRole(await council.OPERATOR_ROLE(), operator.address);

  const docHash = ethers.keccak256(ethers.toUtf8Bytes("Court Order #77"));
  await council.connect(requester).submitWarrantRequest(0, 42, docHash, "US");
  await council.connect(requester).submitWarrantRequest(0, 43, docHash, "US");
  // Every member approves, which concludes voting
  for (const id of [1, 2]) {
    for (let i = 0; i < n; i++) await council.connect(members[i]).castVote(id, true, "");
    expect((await council.getWarrant(id)).status).to.equal(STATUS.Approved);
  }
  await time.increaseTo((await council.getWarrant(2)).executionTime);

  const messages = [null];
  for (const id of [1, 2]) messages.push(ethers.getBytes(await council.getSigningMessage(id)));
  return { council, admin, requester, operator, outsider, members, dkg, masterSecret, messages };
}

async function fixture2of3() {
  return councilFixture(2, 3);
}

async function fixture3of5() {
  return councilFixture(3, 5);
}

async function fixture4of5() {
  return councilFixture(4, 5);
}

/** Member `index` (1-based share index) signs warrant `id` with its DKG share */
async function signAs(f, id, index) {
  const partial = await sdk.signPartial(f.dkg.shares[index - 1], f.messages[id]);
  await f.council.connect(f.members[index - 1]).submitSignature(id, sdkSig(partial.signature));
}

describe("ComplianceCouncil follow-ups (EIP-2537)", function () {
  // ============ (3) Current partial signatures ============

  describe("getCurrentSignatures and the SDK operator flow", function () {
    /**
     * Warrant 1 submissions, in order:
     *   member 3 under a non-share key K (verified against K, then K is rotated away)
     *   member 2 (then removed)
     *   member 1
     *   member 3 under its DKG share again
     *   member 4
     * Current: members 1, 3 (share), 4.
     */
    async function staleFixture() {
      const f = await fixture3of5();
      const { council, members, dkg, messages } = f;
      const k = bls.utils.randomPrivateKey();
      await council.rotateMemberKey(members[2].address, sdkPk(bls.getPublicKey(k)));
      await council.connect(members[2]).submitSignature(1, sdkSig(bls.sign(messages[1], k, { DST })));
      await signAs(f, 1, 2);
      await signAs(f, 1, 1);
      await council.rotateMemberKey(members[2].address, sdkPk(dkg.shares[2].publicKey));
      await signAs(f, 1, 3);
      await signAs(f, 1, 4);
      await council.removeMember(members[1].address);
      const sdkCouncil = new ethers.Contract(await council.getAddress(), sdk.COMPLIANCE_COUNCIL_ABI, ethers.provider);
      return { ...f, sdkCouncil };
    }

    it("getSignatures keeps stale partials that poison a naive aggregate", async function () {
      const { council, dkg, messages } = await loadFixture(staleFixture);
      const all = await council.getSignatures(1);
      expect(all.map((s) => s.memberIndex)).to.deep.equal([3n, 2n, 1n, 3n, 4n]);
      expect(all.every((s) => s.verified)).to.equal(true);

      const partials = all.map((s) => ({
        signerIndex: Number(s.memberIndex),
        signature: sdk.decodeBLSSignatureFromSolidity(s.signature),
      }));
      // The first threshold entries include the partial under the rotated-away non-share key
      const naive = sdk.aggregateSignatures(partials.slice(0, 3));
      expect(await sdk.verifyThresholdSignature(naive, messages[1], dkg.aggregatedPublicKey)).to.equal(false);
      // All of them repeat key index 3
      expect(() => sdk.aggregateSignatures(partials)).to.throw(/Duplicate signer index/);
    });

    it("getCurrentSignatures returns exactly the current submissions (= selectCurrentSubmissions)", async function () {
      const { council, members } = await loadFixture(staleFixture);
      const all = await council.getSignatures(1);
      const current = await council.getCurrentSignatures(1);
      expect(current.map((s) => s.signer)).to.deep.equal([members[0], members[2], members[3]].map((m) => m.address));
      expect(current.map((s) => s.memberIndex)).to.deep.equal([1n, 3n, 4n]);
      for (const s of current) {
        expect(s.keyId).to.equal((await council.getMember(s.signer)).keyId);
        expect(await council.hasSubmittedSignature(1, s.signer)).to.equal(true);
      }

      const active = await council.getActiveMembers();
      const selected = sdk.selectCurrentSubmissions(all, active);
      expect(selected.map((s) => structHex(s.signature))).to.deep.equal(current.map((s) => structHex(s.signature)));
      expect(sdk.selectCurrentSubmissions(current, active).length).to.equal(3);
      // Unknown and untouched warrants have none
      expect((await council.getCurrentSignatures(2)).length).to.equal(0);
      expect((await council.getCurrentSignatures(99)).length).to.equal(0);
    });

    it("aggregateWarrantSignature yields the group signature, which the operator attests", async function () {
      const { council, operator, sdkCouncil, messages, masterSecret, dkg } = await loadFixture(staleFixture);
      const expected = directKeyHash(messages[1], masterSecret);

      const result = await sdk.aggregateWarrantSignature(sdkCouncil, 1n);
      expect(ethers.hexlify(result.decryptedKeyHash)).to.equal(expected);
      expect(result.thresholdSignature.signerIndices).to.deep.equal([1, 3, 4]);
      expect(await sdk.verifyThresholdSignature(result.thresholdSignature, messages[1], dkg.aggregatedPublicKey)).to
        .equal(true);

      await council.setExecutionMode(MODE.HYBRID_ATTESTED, "operator flow");
      await sdkCouncil
        .connect(operator)
        .attestHybridVerification(1, ethers.hexlify(result.decryptedKeyHash), "sdk aggregateWarrantSignature");
      const [attested, hash] = await sdkCouncil.getHybridAttestation(1);
      expect(attested).to.equal(true);
      expect(hash).to.equal(expected);
      await council.executeReconstruction(1);
      expect((await council.getWarrant(1)).decryptedKeyHash).to.equal(expected);
    });

    it("predicts the STRICT_ONCHAIN decryptedKeyHash", async function () {
      const f = await loadFixture(staleFixture);
      const { council, sdkCouncil, messages, masterSecret } = f;
      // Member 2 was removed
      for (const i of [5, 1, 3]) await signAs(f, 2, i);
      const predicted = ethers.hexlify((await sdk.aggregateWarrantSignature(sdkCouncil, 2)).decryptedKeyHash);
      expect(predicted).to.equal(directKeyHash(messages[2], masterSecret));
      expect(await council.executeReconstruction.staticCall(2)).to.equal(predicted);
    });

    it("aggregateCurrentPartials skips partials that do not verify and fails below threshold", async function () {
      const { council, dkg, messages, members, masterSecret } = await loadFixture(staleFixture);
      const current = (await council.getCurrentSignatures(1)).map((s) => s.toObject(true));
      const active = await council.getActiveMembers();
      const input = { members: active, message: messages[1], groupPublicKey: dkg.aggregatedPublicKey, threshold: 3 };

      // Member 1's partial replaced by its signature on another message (as in HYBRID_ATTESTED, unverified)
      const wrong = await sdk.signPartial(dkg.shares[0], messages[2]);
      const tampered = [{ ...current[0], signature: sdkSig(wrong.signature) }, ...current.slice(1)];
      expect(() => sdk.aggregateCurrentPartials({ ...input, submissions: tampered })).to.throw(
        /Need 3 valid current partial signatures, found 2/
      );

      // A further current partial (member 5) makes up for it
      await signAs({ council, members, dkg, messages }, 1, 5);
      const more = (await council.getCurrentSignatures(1)).map((s) => s.toObject(true));
      const res = sdk.aggregateCurrentPartials({
        ...input,
        submissions: [{ ...more[0], signature: sdkSig(wrong.signature) }, ...more.slice(1)],
      });
      expect(res.thresholdSignature.signerIndices).to.deep.equal([3, 4, 5]);
      expect(ethers.hexlify(res.decryptedKeyHash)).to.equal(directKeyHash(messages[1], masterSecret));

      // Stale entries from getSignatures are dropped, never aggregated
      const fromAll = sdk.aggregateCurrentPartials({ ...input, submissions: await council.getSignatures(1) });
      expect(fromAll.thresholdSignature.signerIndices).to.deep.equal([1, 3, 4]);
    });

    it("a removed and re-added member's earlier partial is not aggregated a second time", async function () {
      const f = await loadFixture(fixture3of5);
      const { council, members, dkg, messages, masterSecret } = f;
      // Member 1 signs, is removed and re-added with the same share and index, and signs again
      await signAs(f, 1, 1);
      await council.removeMember(members[0].address);
      await council.addMember(members[0].address, 0, sdkPk(dkg.shares[0].publicKey), 1);
      await signAs(f, 1, 1);
      await signAs(f, 1, 2);
      await signAs(f, 1, 3);

      const all = await council.getSignatures(1);
      expect(all.map((s) => s.memberIndex)).to.deep.equal([1n, 1n, 2n, 3n]);
      // Both member-1 partials verify under its key: without the currency filter they collide on index 1
      const naive = all.slice(0, 3).map((s) => ({
        signerIndex: Number(s.memberIndex),
        signature: sdk.decodeBLSSignatureFromSolidity(s.signature),
      }));
      expect(() => sdk.aggregateSignatures(naive)).to.throw(/Duplicate signer index/);

      const res = sdk.aggregateCurrentPartials({
        submissions: all,
        members: await council.getActiveMembers(),
        message: messages[1],
        groupPublicKey: dkg.aggregatedPublicKey,
        threshold: 3,
      });
      expect(res.thresholdSignature.signerIndices).to.deep.equal([1, 2, 3]);
      expect(ethers.hexlify(res.decryptedKeyHash)).to.equal(directKeyHash(messages[1], masterSecret));
      expect((await council.getCurrentSignatures(1)).length).to.equal(3);
    });

    it("aggregateCurrentPartials rejects an aggregate that does not verify against the group key", async function () {
      const { council, dkg, messages } = await loadFixture(staleFixture);
      const otherGroup = bls.getPublicKey(bls.utils.randomPrivateKey());
      expect(() =>
        sdk.aggregateCurrentPartials({
          submissions: [],
          members: [],
          message: messages[1],
          groupPublicKey: dkg.aggregatedPublicKey,
          threshold: 0,
        })
      ).to.throw(/Invalid threshold/);
      const submissions = await council.getCurrentSignatures(1);
      const members = await council.getActiveMembers();
      expect(() =>
        sdk.aggregateCurrentPartials({
          submissions,
          members,
          message: messages[1],
          groupPublicKey: otherGroup,
          threshold: 3,
        })
      ).to.throw(/does not verify against the group key/);
    });

    it("aggregateWarrantSignature requires the group key", async function () {
      const [admin] = await ethers.getSigners();
      const council = await deployCouncil(1, admin);
      const reader = new ethers.Contract(await council.getAddress(), sdk.COMPLIANCE_COUNCIL_ABI, ethers.provider);
      await expect(sdk.aggregateWarrantSignature(reader, 1)).to.be.rejectedWith(/Group public key is unset/);
    });

    it("COMPLIANCE_COUNCIL_ABI matches the compiled contract", async function () {
      const real = new ethers.Interface((await artifacts.readArtifact("ComplianceCouncil")).abi);
      const ours = new ethers.Interface(sdk.COMPLIANCE_COUNCIL_ABI);
      // Field names matter: the SDK reads struct fields by name
      const typeOf = (p) => (p.name ? p.format("full").slice(0, -(p.name.length + 1)) : p.format("full"));
      let n = 0;
      ours.forEachFunction((f) => {
        const r = real.getFunction(f.selector);
        expect(r, f.format()).to.not.equal(null);
        expect(r.stateMutability, f.name).to.equal(f.stateMutability);
        expect(r.outputs.map(typeOf), f.name).to.deep.equal(f.outputs.map(typeOf));
        n++;
      });
      expect(n).to.equal(sdk.COMPLIANCE_COUNCIL_ABI.length);
    });
  });

  // ============ (2) Infinity aggregate ============

  describe("aggregateSignatures rejects an infinity sum", function () {
    async function sigsFixture() {
      const [admin] = await ethers.getSigners();
      const council = await deployCouncil(1, admin);
      const msg = ethers.getBytes(ethers.keccak256(ethers.toUtf8Bytes("aggregate")));
      const a = g2(bls.sign(msg, bls.utils.randomPrivateKey(), { DST }));
      const b = g2(bls.sign(msg, bls.utils.randomPrivateKey(), { DST }));
      return { council, a, b };
    }

    it("reverts for [P, -P] and any other cancelling set", async function () {
      const { council, a, b } = await loadFixture(sigsFixture);
      const s = (pt) => sigStruct(g2Hex(pt));
      for (const set of [
        [a, a.negate()],
        [a.negate(), a],
        [a, b, a.add(b).negate()],
        [a, a, a.double().negate()],
      ]) {
        await expect(council.aggregateSignatures(set.map(s))).to.be.revertedWith("Infinity aggregate");
      }
      // Cancelling elements next to others are fine
      expect(structHex(await council.aggregateSignatures([a, a.negate(), b].map(s)))).to.equal(g2Hex(b));
      expect(structHex(await council.aggregateSignatures([a, b].map(s)))).to.equal(g2Hex(a.add(b)));
    });

    it("the SDK aggregate throws on partials that cancel out", async function () {
      const { a } = await loadFixture(sigsFixture);
      // Indices 1 and 2: l_1 = 2, l_2 = -1, so sigma_2 = 2 * sigma_1 cancels
      const partials = [
        { signerIndex: 1, signature: a.toRawBytes(true) },
        { signerIndex: 2, signature: a.double().toRawBytes(true) },
      ];
      expect(() => sdk.aggregateSignatures(partials)).to.throw(/point at infinity/);
      expect(() => sdk.aggregateSignatures([partials[0]])).to.not.throw();
    });
  });

  // ============ (5) Even-threshold reconstruction ============

  describe("even-threshold reconstruction on the precompiles", function () {
    const cases = [
      { name: "2-of-3", fixture: fixture2of3, signers: [3, 1] },
      { name: "4-of-5", fixture: fixture4of5, signers: [5, 2, 1, 4] },
    ];
    for (const c of cases) {
      it(`${c.name}: executeReconstruction records the master-secret group signature`, async function () {
        const f = await loadFixture(c.fixture);
        for (const i of c.signers) await signAs(f, 1, i);
        await f.council.executeReconstruction(1);
        const w = await f.council.getWarrant(1);
        expect(w.status).to.equal(STATUS.Executed);
        expect(w.decryptedKeyHash).to.equal(directKeyHash(f.messages[1], f.masterSecret));
      });
    }

    const libraryCases = [
      { name: "two points (2-of-3)", fixture: fixture2of3, subsets: [[2, 3], [3, 1]] },
      { name: "four points (4-of-5)", fixture: fixture4of5, subsets: [[4, 2, 5, 1], [1, 2, 3, 4]] },
    ];
    for (const c of libraryCases) {
      it(`interpolateG2AtZero and the SDK aggregate match the master-secret signature: ${c.name}`, async function () {
        const f = await loadFixture(c.fixture);
        // Deployed after loadFixture, which reverts to the fixture snapshot
        const th = await (await ethers.getContractFactory("BLS12381ThresholdHarness")).deploy();
        const group = g2Hex(g2(bls.sign(f.messages[1], f.masterSecret, { DST })));
        for (const indices of c.subsets) {
          const partials = await Promise.all(indices.map((i) => sdk.signPartial(f.dkg.shares[i - 1], f.messages[1])));
          const pairs = ethers.concat(
            partials.map((p) => ethers.concat([structHex(sdkSig(p.signature)), ethers.ZeroHash]))
          );
          const [ok, sum] = await th.interpolateG2AtZero(pairs, indices);
          expect(ok, indices.join(",")).to.equal(true);
          expect(sum, indices.join(",")).to.equal(group);
          expect(g2Hex(g2(sdk.aggregateSignatures(partials).aggregatedSignature))).to.equal(group);
        }
      });
    }
  });

  // ============ (5) verifyThresholdSignature guard boundary ============

  describe("verifyThresholdSignature unknown-warrant guard", function () {
    async function aggregate(f, message) {
      const partials = await Promise.all([1, 2, 3].map((i) => sdk.signPartial(f.dkg.shares[i - 1], message)));
      const agg = sdk.aggregateSignatures(partials);
      return {
        aggregatedSig: sdkSig(agg.aggregatedSignature),
        signerIndices: agg.signerIndices,
        signatureCount: agg.signerIndices.length,
      };
    }

    it("accepts the last warrant (id == counter) and rejects id == counter + 1", async function () {
      const f = await loadFixture(fixture3of5);
      const groupKey = sdkPk(f.dkg.aggregatedPublicKey);

      expect(await f.council.verifyThresholdSignature(2, await aggregate(f, f.messages[2]))).to.equal(true);

      const next = ethers.getBytes(await f.council.getSigningMessage(3));
      const ts = await aggregate(f, next);
      // Valid for the next id's message under the group key: only the guard rejects it
      expect(await f.council.verifySignature(next, ts.aggregatedSig, groupKey)).to.equal(true);
      expect(await f.council.verifyThresholdSignature(3, ts)).to.equal(false);
    });
  });

  // ============ (5) SDK canonical check at value == p ============

  describe("SDK decoders reject a limb equal to p", function () {
    it("decodeBLSSignatureFromSolidity and decodeBLSPublicKeyFromSolidity", async function () {
      const sk = bls.utils.randomPrivateKey();
      const sig = g2(bls.sign(ethers.toUtf8Bytes("m"), sk, { DST }));
      const a = sig.toAffine();
      const limbs = [a.x.c0, a.x.c1, a.y.c0, a.y.c1];
      for (let i = 0; i < 4; i++) {
        const bad = limbs.map((v, j) => (j === i ? P : v));
        expect(() => sdk.decodeBLSSignatureFromSolidity(sigStruct("0x" + bad.map(fp).join(""))), `limb ${i}`).to.throw(
          /Non-canonical/
        );
      }
      expect(sdk.decodeBLSSignatureFromSolidity(sigStruct(g2Hex(sig)))).to.deep.equal(sig.toRawBytes(true));

      const pk = bls.G1.ProjectivePoint.fromHex(bls.getPublicKey(sk)).toAffine();
      for (const hex of ["0x" + fp(P) + fp(pk.y), "0x" + fp(pk.x) + fp(P)]) {
        expect(() => sdk.decodeBLSPublicKeyFromSolidity(pkStruct(hex))).to.throw(/Non-canonical/);
      }
    });
  });
});
