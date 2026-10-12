/**
 * FIDOVerifier P-256 key validation against a real P256VERIFY precompile (EIP-7951, Hardhat network >= Osaka)
 *
 * verifyP256Signature must give the same answer on the precompile path and the pure-Solidity fallback. The
 * precompile rejects public keys that are not on the curve; the fallback encodes the point at infinity as (0,0),
 * so without its own key check it accepted forged signatures for the key (0,0) and for off-curve keys.
 */

const { expect } = require("chai");
const { ethers } = require("hardhat");
const { p256 } = require("@noble/curves/p256");
const { sha256 } = require("@noble/hashes/sha2.js");

const P256_PRECOMPILE = "0x0000000000000000000000000000000000000100";
const N = p256.CURVE.n;
const G = p256.ProjectivePoint.BASE.toAffine();

const hex32 = (v) => ethers.toBeHex(v, 32);
const mod = (a, m) => ((a % m) + m) % m;
const invert = (a, m) => {
  // Fermat: m is prime
  let result = 1n;
  let base = mod(a, m);
  let e = m - 2n;
  while (e > 0n) {
    if (e & 1n) result = (result * base) % m;
    base = (base * base) % m;
    e >>= 1n;
  }
  return result;
};

/** Forges (h, r, s) that "verifies" under a key Q for which u2*Q is the point at infinity: x(u1*G) == r */
function forge(message, k) {
  const h = BigInt(ethers.hexlify(sha256(ethers.toUtf8Bytes(message))));
  const r = mod(p256.ProjectivePoint.BASE.multiply(k).toAffine().x, N);
  const s = mod(h * invert(k, N), N);
  return { h, r, s };
}

describe("FIDOVerifier P-256 key validation (real precompile)", function () {
  let verifier;

  async function precompile(h, r, s, x, y) {
    const data = ethers.concat([hex32(h), hex32(r), hex32(s), hex32(x), hex32(y)]);
    return ethers.provider.call({ to: P256_PRECOMPILE, data });
  }

  async function verifyBothPaths(h, r, s, x, y) {
    await verifier.setPrecompileAvailable(true);
    const withPrecompile = await verifier.verifyP256Signature(hex32(h), hex32(r), hex32(s), hex32(x), hex32(y));
    await verifier.setPrecompileAvailable(false);
    const fallback = await verifier.verifyP256Signature(hex32(h), hex32(r), hex32(s), hex32(x), hex32(y));
    return { withPrecompile, fallback };
  }

  before(async function () {
    const FIDOVerifier = await ethers.getContractFactory("FIDOVerifier");
    verifier = await FIDOVerifier.deploy("natlangchain.io");
    await verifier.waitForDeployment();
    if (!(await verifier.precompileAvailable())) {
      // The comparison needs a real P256VERIFY; Foundry covers the fallback on its own
      this.skip();
    }
  });

  it("detects the precompile and verifies a genuine signature on it", async function () {
    const priv = sha256(ethers.toUtf8Bytes("fido key validation"));
    const h = sha256(ethers.toUtf8Bytes("genuine message"));
    const sig = p256.sign(h, priv, { prehash: false, lowS: true });
    const pub = p256.ProjectivePoint.fromPrivateKey(priv).toAffine();

    await verifier.setPrecompileAvailable(true);
    expect(
      await verifier.verifyP256Signature(ethers.hexlify(h), hex32(sig.r), hex32(sig.s), hex32(pub.x), hex32(pub.y))
    ).to.equal(true);
  });

  it("rejects a forgery for the key (0,0) on both paths, matching the precompile", async function () {
    for (const k of [1n, 123456789n]) {
      const { h, r, s } = forge("attacker-chosen message", k);
      expect(await precompile(h, r, s, 0n, 0n)).to.equal("0x"); // precompile: invalid input
      const { withPrecompile, fallback } = await verifyBothPaths(h, r, s, 0n, 0n);
      expect(withPrecompile).to.equal(false);
      expect(fallback).to.equal(false); // before the fix: true
    }
  });

  it("rejects a forgery for the off-curve order-2 key (1,0) on both paths, matching the precompile", async function () {
    // Pick a nonce whose (low-s) u2 = r/s is even, so u2*(1,0) is the point at infinity in affine arithmetic
    let vector;
    for (let k = 1n; !vector; k++) {
      const { h, r, s } = forge("invalid-curve key", k);
      if (s > N / 2n) continue;
      if (mod(r * invert(s, N), N) % 2n === 0n) vector = { h, r, s };
    }
    const { h, r, s } = vector;
    expect(await precompile(h, r, s, 1n, 0n)).to.equal("0x");
    const { withPrecompile, fallback } = await verifyBothPaths(h, r, s, 1n, 0n);
    expect(withPrecompile).to.equal(false);
    expect(fallback).to.equal(false); // before the fix: true
  });

  it("rejects an off-curve neighbour of a valid key on both paths", async function () {
    const { h, r, s } = forge("neighbour key", 7n);
    const { withPrecompile, fallback } = await verifyBothPaths(h, r, s, G.x, G.y + 1n);
    expect(await precompile(h, r, s, G.x, G.y + 1n)).to.equal("0x");
    expect(withPrecompile).to.equal(false);
    expect(fallback).to.equal(false);
  });
});
