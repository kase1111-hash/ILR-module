/**
 * Threshold BLS Cryptography SDK
 *
 * Implements BLS12-381 threshold signatures for ComplianceCouncil.
 * Supports:
 * - Distributed key generation (FROST-style)
 * - Partial signature generation
 * - Signature aggregation
 * - Key reconstruction from shares
 *
 * Dependencies:
 * - @noble/bls12-381 for BLS operations
 * - @noble/hashes for message hashing
 */

import { bls12_381 as bls } from "@noble/curves/bls12-381";
import { sha256 } from "@noble/hashes/sha2";
import { bytesToHex, hexToBytes, concatBytes } from "@noble/hashes/utils";

// ============ Types ============

export interface BLSPublicKey {
  x: Uint8Array; // 32 bytes
  y: Uint8Array; // 32 bytes
}

export interface BLSSignature {
  x: [Uint8Array, Uint8Array]; // Fp2 x coordinate
  y: [Uint8Array, Uint8Array]; // Fp2 y coordinate
}

export interface KeyShare {
  index: number; // 1-based participant index
  secretShare: Uint8Array; // Scalar share
  publicKey: Uint8Array; // Corresponding public key
}

export interface DKGOutput {
  threshold: number;
  totalParticipants: number;
  shares: KeyShare[];
  aggregatedPublicKey: Uint8Array;
  commitments: Uint8Array[]; // Feldman VSS commitments
}

export interface PartialSignature {
  signerIndex: number;
  signature: Uint8Array;
}

export interface ThresholdSignature {
  aggregatedSignature: Uint8Array;
  signerIndices: number[];
}

export interface WarrantSigningMessage {
  warrantId: bigint;
  targetDisputeId: bigint;
  documentHash: Uint8Array;
  executionTime: bigint;
}

// ============ Constants ============

const DOMAIN_SEPARATOR = "COMPLIANCE_REVEAL";
const BLS_SCALAR_SIZE = 32;
const BLS_G1_SIZE = 48;
const BLS_G2_SIZE = 96;

// ============ Distributed Key Generation ============

/**
 * Generate Feldman VSS coefficients for threshold scheme
 * @param threshold Minimum shares needed (t)
 * @param secret The secret to share (or random if null)
 * @returns Polynomial coefficients
 */
function generatePolynomialCoefficients(
  threshold: number,
  secret?: Uint8Array
): bigint[] {
  const coefficients: bigint[] = [];

  // First coefficient is the secret
  if (secret) {
    coefficients.push(bytesToBigInt(secret));
  } else {
    coefficients.push(bytesToBigInt(bls.utils.randomPrivateKey()));
  }

  // Random coefficients for degree 1 to t-1
  for (let i = 1; i < threshold; i++) {
    coefficients.push(bytesToBigInt(bls.utils.randomPrivateKey()));
  }

  return coefficients;
}

// Get the scalar field order for BLS12-381
function getScalarOrder(): bigint {
  return bls.G1.CURVE.n;
}

/**
 * Evaluate polynomial at a point (for share generation)
 */
function evaluatePolynomial(coefficients: bigint[], x: bigint): bigint {
  const order = getScalarOrder();
  let result = 0n;
  let power = 1n;

  for (const coef of coefficients) {
    result = (result + coef * power) % order;
    power = (power * x) % order;
  }

  return result;
}

/**
 * Generate key shares using Feldman VSS
 * @param threshold Minimum shares required (t)
 * @param totalParticipants Total number of participants (n)
 * @param masterSecret Optional master secret to share
 * @returns DKG output with shares and commitments
 */
export function generateKeyShares(
  threshold: number,
  totalParticipants: number,
  masterSecret?: Uint8Array
): DKGOutput {
  if (threshold < 1 || threshold > totalParticipants) {
    throw new Error("Invalid threshold parameters");
  }

  // Generate polynomial coefficients
  const coefficients = generatePolynomialCoefficients(threshold, masterSecret);

  // Generate Feldman VSS commitments: C_i = g^a_i
  const commitments = coefficients.map((coef) =>
    bls.G1.ProjectivePoint.BASE.multiply(coef).toRawBytes(true)
  );

  // Generate shares for each participant
  const shares: KeyShare[] = [];
  for (let i = 1; i <= totalParticipants; i++) {
    const shareValue = evaluatePolynomial(coefficients, BigInt(i));
    const shareBytes = bigIntToBytes(shareValue, BLS_SCALAR_SIZE);

    // Public key for this share
    const publicKey = bls.G1.ProjectivePoint.BASE.multiply(shareValue).toRawBytes(true);

    shares.push({
      index: i,
      secretShare: shareBytes,
      publicKey,
    });
  }

  // Aggregated public key = g^a_0 (commitment to secret)
  const aggregatedPublicKey = commitments[0];

  return {
    threshold,
    totalParticipants,
    shares,
    aggregatedPublicKey,
    commitments,
  };
}

/**
 * Verify a share against VSS commitments
 * @param share The share to verify
 * @param commitments Feldman VSS commitments
 * @returns True if share is valid
 */
export function verifyShare(
  share: KeyShare,
  commitments: Uint8Array[]
): boolean {
  try {
    // Compute expected public key: product of C_j^(i^j) for j = 0..t-1
    let expectedPK = bls.G1.ProjectivePoint.ZERO;
    const i = BigInt(share.index);
    const order = getScalarOrder();

    for (let j = 0; j < commitments.length; j++) {
      const C_j = bls.G1.ProjectivePoint.fromHex(bytesToHex(commitments[j]));
      const power = modPow(i, BigInt(j), order);
      expectedPK = expectedPK.add(C_j.multiply(power));
    }

    // Compare with share's public key
    const actualPK = bls.G1.ProjectivePoint.fromHex(bytesToHex(share.publicKey));
    return expectedPK.equals(actualPK);
  } catch {
    return false;
  }
}

// ============ Signing ============

/**
 * Create the message to sign for a warrant
 */
export function createWarrantMessage(warrant: WarrantSigningMessage): Uint8Array {
  const encoder = new TextEncoder();
  const domainBytes = encoder.encode(DOMAIN_SEPARATOR);

  return sha256(
    concatBytes(
      domainBytes,
      bigIntToBytes(warrant.warrantId, 32),
      bigIntToBytes(warrant.targetDisputeId, 32),
      warrant.documentHash,
      bigIntToBytes(warrant.executionTime, 32)
    )
  );
}

/**
 * Generate a partial signature using a key share
 * @param share The signer's key share
 * @param message Message hash to sign
 * @returns Partial signature
 */
export async function signPartial(
  share: KeyShare,
  message: Uint8Array
): Promise<PartialSignature> {
  // Sign with the share's secret
  const signature = await bls.sign(message, share.secretShare);

  return {
    signerIndex: share.index,
    signature,
  };
}

/**
 * Verify a partial signature
 * @param partialSig Partial signature to verify
 * @param message Original message
 * @param signerPublicKey Signer's public key
 * @returns True if valid
 */
export async function verifyPartialSignature(
  partialSig: PartialSignature,
  message: Uint8Array,
  signerPublicKey: Uint8Array
): Promise<boolean> {
  return bls.verify(partialSig.signature, message, signerPublicKey);
}

// ============ Aggregation ============

/**
 * Compute Lagrange coefficient for aggregation
 * @param signerIndex The signer's index
 * @param allSignerIndices All participating signer indices
 * @returns Lagrange coefficient (lambda_i)
 */
function computeLagrangeCoefficient(
  signerIndex: number,
  allSignerIndices: number[]
): bigint {
  const order = getScalarOrder();
  const i = BigInt(signerIndex);

  let numerator = 1n;
  let denominator = 1n;

  for (const j of allSignerIndices) {
    if (j !== signerIndex) {
      const jBig = BigInt(j);
      numerator = (numerator * jBig) % order;
      denominator = (denominator * ((jBig - i + order) % order)) % order;
    }
  }

  // Return numerator * denominator^(-1) mod order
  const denominatorInverse = modInverse(denominator, order);
  return (numerator * denominatorInverse) % order;
}

/**
 * Aggregate partial signatures into threshold signature
 * @param partialSignatures Array of partial signatures
 * @returns Aggregated threshold signature
 */
export function aggregateSignatures(
  partialSignatures: PartialSignature[]
): ThresholdSignature {
  if (partialSignatures.length === 0) {
    throw new Error("No signatures to aggregate");
  }

  const signerIndices = partialSignatures.map((ps) => ps.signerIndex);

  // Compute weighted sum: sigma = sum(lambda_i * sigma_i)
  let aggregated = bls.G2.ProjectivePoint.ZERO;

  for (const partialSig of partialSignatures) {
    const lambda = computeLagrangeCoefficient(partialSig.signerIndex, signerIndices);
    const sigPoint = bls.Signature.fromHex(bytesToHex(partialSig.signature));
    aggregated = aggregated.add(sigPoint.multiply(lambda));
  }

  return {
    aggregatedSignature: aggregated.toRawBytes(),
    signerIndices,
  };
}

/**
 * Verify threshold signature against aggregated public key
 * @param thresholdSig Threshold signature
 * @param message Original message
 * @param aggregatedPublicKey Aggregated public key from DKG
 * @returns True if valid
 */
export async function verifyThresholdSignature(
  thresholdSig: ThresholdSignature,
  message: Uint8Array,
  aggregatedPublicKey: Uint8Array
): Promise<boolean> {
  return bls.verify(thresholdSig.aggregatedSignature, message, aggregatedPublicKey);
}

// ============ Key Reconstruction ============

/**
 * Reconstruct the master secret from shares
 * @param shares Key shares (must be >= threshold)
 * @param threshold Required threshold
 * @returns Reconstructed master secret
 */
export function reconstructSecret(
  shares: KeyShare[],
  threshold: number
): Uint8Array {
  if (shares.length < threshold) {
    throw new Error(`Need ${threshold} shares, got ${shares.length}`);
  }

  const order = getScalarOrder();
  const shareIndices = shares.slice(0, threshold).map((s) => s.index);

  let secret = 0n;

  for (const share of shares.slice(0, threshold)) {
    const lambda = computeLagrangeCoefficient(share.index, shareIndices);
    const shareValue = bytesToBigInt(share.secretShare);
    secret = (secret + lambda * shareValue) % order;
  }

  return bigIntToBytes(secret, BLS_SCALAR_SIZE);
}

/**
 * Encrypt viewing key using a secret (for threshold encryption)
 * Uses AES-256-GCM for authenticated encryption
 * @param viewingKey The viewing key to encrypt
 * @param secret The encryption secret (32 bytes)
 * @returns Encrypted viewing key with IV and auth tag prepended
 */
export async function encryptViewingKey(
  viewingKey: Uint8Array,
  secret: Uint8Array
): Promise<Uint8Array> {
  // Derive encryption key from secret using SHA-256
  const encryptionKey = sha256(secret);

  // Generate random 12-byte IV for GCM
  const iv = new Uint8Array(12);
  if (typeof crypto !== 'undefined' && crypto.getRandomValues) {
    crypto.getRandomValues(iv);
  } else {
    const nodeCrypto = require('crypto');
    const randomBytes = nodeCrypto.randomBytes(12);
    iv.set(new Uint8Array(randomBytes));
  }

  // Encrypt using AES-256-GCM
  if (typeof crypto !== 'undefined' && crypto.subtle) {
    // Create proper ArrayBuffer copies to satisfy TypeScript's strict typing
    const encryptionKeyBuffer = new Uint8Array(encryptionKey).buffer;
    const ivBuffer = new Uint8Array(iv).buffer;
    const viewingKeyBuffer = new Uint8Array(viewingKey).buffer;

    const cryptoKey = await crypto.subtle.importKey(
      'raw',
      encryptionKeyBuffer,
      'AES-GCM',
      false,
      ['encrypt']
    );

    const result = await crypto.subtle.encrypt(
      { name: 'AES-GCM', iv: ivBuffer, tagLength: 128 },
      cryptoKey,
      viewingKeyBuffer
    );

    const resultBytes = new Uint8Array(result);
    // Format: IV (12 bytes) || ciphertext || authTag (16 bytes)
    const output = new Uint8Array(12 + resultBytes.length);
    output.set(iv, 0);
    output.set(resultBytes, 12);
    return output;
  }

  // Node.js fallback
  const nodeCrypto = require('crypto');
  const cipher = nodeCrypto.createCipheriv('aes-256-gcm', encryptionKey, iv);
  const ciphertext = Buffer.concat([cipher.update(viewingKey), cipher.final()]);
  const authTag = cipher.getAuthTag();

  // Format: IV (12 bytes) || ciphertext || authTag (16 bytes)
  const output = new Uint8Array(12 + ciphertext.length + 16);
  output.set(iv, 0);
  output.set(new Uint8Array(ciphertext), 12);
  output.set(new Uint8Array(authTag), 12 + ciphertext.length);
  return output;
}

/**
 * Decrypt viewing key using reconstructed secret
 * Uses AES-256-GCM for authenticated decryption
 * @param encryptedKey Encrypted viewing key (IV || ciphertext || authTag)
 * @param shares Key shares for reconstruction
 * @param threshold Threshold value
 * @returns Decrypted viewing key
 */
export async function decryptViewingKey(
  encryptedKey: Uint8Array,
  shares: KeyShare[],
  threshold: number
): Promise<Uint8Array> {
  // Reconstruct the decryption key
  const secret = reconstructSecret(shares, threshold);

  // Derive encryption key from secret using SHA-256
  const encryptionKey = sha256(secret);

  // Parse encrypted data: IV (12 bytes) || ciphertext || authTag (16 bytes)
  if (encryptedKey.length < 28) {
    throw new Error('Encrypted data too short');
  }

  const iv = encryptedKey.slice(0, 12);
  const ciphertextWithTag = encryptedKey.slice(12);

  // Decrypt using AES-256-GCM
  if (typeof crypto !== 'undefined' && crypto.subtle) {
    // Create proper ArrayBuffer copies to satisfy TypeScript's strict typing
    const encryptionKeyBuffer = new Uint8Array(encryptionKey).buffer;
    const ivBuffer = new Uint8Array(iv).buffer;
    const ciphertextWithTagBuffer = new Uint8Array(ciphertextWithTag).buffer;

    const cryptoKey = await crypto.subtle.importKey(
      'raw',
      encryptionKeyBuffer,
      'AES-GCM',
      false,
      ['decrypt']
    );

    try {
      const result = await crypto.subtle.decrypt(
        { name: 'AES-GCM', iv: ivBuffer, tagLength: 128 },
        cryptoKey,
        ciphertextWithTagBuffer
      );
      return new Uint8Array(result);
    } catch (error) {
      throw new Error('Decryption failed: authentication tag mismatch');
    }
  }

  // Node.js fallback
  const nodeCrypto = require('crypto');
  const ciphertext = ciphertextWithTag.slice(0, -16);
  const authTag = ciphertextWithTag.slice(-16);

  const decipher = nodeCrypto.createDecipheriv('aes-256-gcm', encryptionKey, iv);
  decipher.setAuthTag(authTag);

  try {
    const plaintext = Buffer.concat([decipher.update(ciphertext), decipher.final()]);
    return new Uint8Array(plaintext);
  } catch (error) {
    throw new Error('Decryption failed: authentication tag mismatch');
  }
}

// ============ Solidity Encoding ============

/**
 * Encode BLS public key for Solidity
 */
export function encodeBLSPublicKeyForSolidity(pk: Uint8Array): BLSPublicKey {
  if (pk.length !== BLS_G1_SIZE) {
    throw new Error("Invalid public key length");
  }

  // BLS12-381 G1 points are 48 bytes compressed
  // For Solidity, we need to expand to x, y coordinates (32 bytes each)
  const point = bls.G1.ProjectivePoint.fromHex(bytesToHex(pk));
  const affine = point.toAffine();

  return {
    x: bigIntToBytes(affine.x, 32),
    y: bigIntToBytes(affine.y, 32),
  };
}

/**
 * Encode BLS signature for Solidity
 */
export function encodeBLSSignatureForSolidity(sig: Uint8Array): BLSSignature {
  if (sig.length !== BLS_G2_SIZE) {
    throw new Error("Invalid signature length");
  }

  // G2 point (Fp2 coordinates)
  const point = bls.Signature.fromHex(bytesToHex(sig));
  const affine = point.toAffine();

  // In @noble/curves, Fp2 coordinates are represented as { c0: bigint, c1: bigint }
  return {
    x: [
      bigIntToBytes(affine.x.c0, 32),
      bigIntToBytes(affine.x.c1, 32),
    ],
    y: [
      bigIntToBytes(affine.y.c0, 32),
      bigIntToBytes(affine.y.c1, 32),
    ],
  };
}

/**
 * Create Solidity-compatible warrant message hash
 */
export function createSolidityWarrantMessage(
  warrantId: bigint,
  targetDisputeId: bigint,
  documentHash: Uint8Array,
  executionTime: bigint
): Uint8Array {
  // Match Solidity keccak256(abi.encodePacked(...))
  const encoder = new TextEncoder();
  const domainBytes = encoder.encode(DOMAIN_SEPARATOR);

  // Use keccak256 for Ethereum compatibility
  // Note: In production, use keccak256 from @noble/hashes
  return sha256(
    concatBytes(
      domainBytes,
      bigIntToBytes(warrantId, 32),
      bigIntToBytes(targetDisputeId, 32),
      documentHash,
      bigIntToBytes(executionTime, 32)
    )
  );
}

// ============ Utility Functions ============

function bytesToBigInt(bytes: Uint8Array): bigint {
  let result = 0n;
  for (const byte of bytes) {
    result = (result << 8n) + BigInt(byte);
  }
  return result;
}

function bigIntToBytes(value: bigint, length: number): Uint8Array {
  const bytes = new Uint8Array(length);
  let remaining = value;

  for (let i = length - 1; i >= 0; i--) {
    bytes[i] = Number(remaining & 0xffn);
    remaining >>= 8n;
  }

  return bytes;
}

function modPow(base: bigint, exp: bigint, mod: bigint): bigint {
  let result = 1n;
  base = base % mod;

  while (exp > 0n) {
    if (exp % 2n === 1n) {
      result = (result * base) % mod;
    }
    exp = exp >> 1n;
    base = (base * base) % mod;
  }

  return result;
}

function modInverse(a: bigint, m: bigint): bigint {
  return modPow(a, m - 2n, m);
}

// ============ Example Usage ============

export async function exampleUsage(): Promise<void> {
  console.log("=== Threshold BLS Example ===\n");

  // 1. Generate key shares (3-of-5 threshold)
  const threshold = 3;
  const totalParticipants = 5;
  console.log(`Generating ${threshold}-of-${totalParticipants} key shares...`);

  const dkg = generateKeyShares(threshold, totalParticipants);
  console.log(`Generated ${dkg.shares.length} shares`);
  console.log(`Aggregated PK: ${bytesToHex(dkg.aggregatedPublicKey)}\n`);

  // 2. Verify shares
  console.log("Verifying shares against commitments...");
  for (const share of dkg.shares) {
    const valid = verifyShare(share, dkg.commitments);
    console.log(`  Share ${share.index}: ${valid ? "✓" : "✗"}`);
  }

  // 3. Create warrant message
  const warrant: WarrantSigningMessage = {
    warrantId: 1n,
    targetDisputeId: 42n,
    documentHash: sha256(new TextEncoder().encode("Court Order #12345")),
    executionTime: BigInt(Math.floor(Date.now() / 1000) + 86400),
  };
  const message = createWarrantMessage(warrant);
  console.log(`\nWarrant message hash: ${bytesToHex(message)}`);

  // 4. Collect partial signatures (from participants 1, 2, 4)
  const signingParticipants = [0, 1, 3]; // 0-indexed
  const partialSigs: PartialSignature[] = [];

  console.log("\nCollecting partial signatures...");
  for (const i of signingParticipants) {
    const partialSig = await signPartial(dkg.shares[i], message);
    partialSigs.push(partialSig);
    console.log(`  Participant ${dkg.shares[i].index} signed`);
  }

  // 5. Verify partial signatures
  console.log("\nVerifying partial signatures...");
  for (let i = 0; i < partialSigs.length; i++) {
    const idx = signingParticipants[i];
    const valid = await verifyPartialSignature(
      partialSigs[i],
      message,
      dkg.shares[idx].publicKey
    );
    console.log(`  Signature ${i + 1}: ${valid ? "✓" : "✗"}`);
  }

  // 6. Aggregate signatures
  console.log("\nAggregating threshold signature...");
  const thresholdSig = aggregateSignatures(partialSigs);
  console.log(`  Signers: [${thresholdSig.signerIndices.join(", ")}]`);
  console.log(`  Signature: ${bytesToHex(thresholdSig.aggregatedSignature).slice(0, 40)}...`);

  // 7. Verify threshold signature
  const valid = await verifyThresholdSignature(
    thresholdSig,
    message,
    dkg.aggregatedPublicKey
  );
  console.log(`\nThreshold signature valid: ${valid ? "✓" : "✗"}`);

  // 8. Demonstrate key reconstruction
  console.log("\n=== Key Reconstruction ===");
  const reconstructedSecret = reconstructSecret(
    dkg.shares.slice(0, threshold),
    threshold
  );
  console.log(`Reconstructed secret from shares 1-3: ${bytesToHex(reconstructedSecret).slice(0, 40)}...`);

  // Encode for Solidity
  console.log("\n=== Solidity Encoding ===");
  const solidityPK = encodeBLSPublicKeyForSolidity(dkg.aggregatedPublicKey);
  console.log(`Public Key X: 0x${bytesToHex(solidityPK.x)}`);
  console.log(`Public Key Y: 0x${bytesToHex(solidityPK.y)}`);
}

// Run if executed directly
if (typeof require !== "undefined" && require.main === module) {
  exampleUsage().catch(console.error);
}
