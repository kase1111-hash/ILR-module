/**
 * Threshold BLS Cryptography SDK
 *
 * Implements BLS12-381 threshold signatures for ComplianceCouncil.
 * Supports:
 * - Distributed key generation (Feldman VSS, trusted dealer)
 * - Partial signature generation
 * - Signature aggregation (Lagrange interpolation in the exponent)
 * - Key reconstruction from shares
 * - Encoding of keys and signatures for the ComplianceCouncil contract
 *
 * Scheme (must match contracts/modules/libraries/BLS12381.sol):
 * - Public keys are G1 points (48 bytes compressed), signatures are G2 points (96 bytes compressed)
 * - Messages are hashed to G2 with RFC 9380 hash_to_curve (BLS12381G2_XMD:SHA-256_SSWU_RO_)
 *   under WARRANT_SIGNATURE_DST
 * - The signed message is the 32-byte warrant hash from createWarrantMessage, which equals
 *   ComplianceCouncil.getSigningMessage(warrantId)
 * - Contract structs use the EIP-2537 encoding: every Fp element is 64 bytes big-endian
 *   (16 zero bytes followed by the 48-byte value), split into two 32-byte words; the decoders accept
 *   only canonical encodings, as the contract does
 * - A warrant's decryptedKeyHash is keccak256 of the 256-byte encoding of its threshold signature
 *   (computeDecryptedKeyHash); any valid t-subset of partial signatures aggregates to the same value
 *
 * Dependencies:
 * - @noble/curves for BLS12-381
 * - @noble/hashes (v2, ESM-only: requires Node 20.19+ when loaded from CommonJS) for hashing
 */

import { bls12_381 as bls } from "@noble/curves/bls12-381";
import { sha256 } from "@noble/hashes/sha2.js";
import { keccak_256 } from "@noble/hashes/sha3.js";
import { bytesToHex, concatBytes, hexToBytes } from "@noble/hashes/utils.js";

// ============ Types ============

/**
 * G1 public key as the ComplianceCouncil BLSPublicKey struct: each coordinate is [hi, lo],
 * two 32-byte words of the 64-byte EIP-2537 Fp encoding.
 */
export interface BLSPublicKey {
  x: [Uint8Array, Uint8Array];
  y: [Uint8Array, Uint8Array];
}

/**
 * G2 signature as the ComplianceCouncil BLSSignature struct: each Fp2 coordinate is
 * [c0.hi, c0.lo, c1.hi, c1.lo] (32-byte words).
 */
export interface BLSSignature {
  x: [Uint8Array, Uint8Array, Uint8Array, Uint8Array];
  y: [Uint8Array, Uint8Array, Uint8Array, Uint8Array];
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

/**
 * Fields of the warrant signing message. Read the warrant fields from
 * ComplianceCouncil.getWarrant(warrantId); `council` is the council contract address.
 */
export interface WarrantSigningMessage {
  chainId: bigint;
  council: string; // 20-byte hex address
  warrantId: bigint;
  targetDisputeId: bigint;
  documentHash: Uint8Array;
  executionTime: bigint;
}

/** A 32-byte word as bytes or 0x-prefixed hex (as returned by ethers). */
export type SolidityWord = Uint8Array | string;

// ============ Constants ============

/**
 * RFC 9380 domain separation tag used to hash warrant messages to G2.
 * Must equal ComplianceCouncil.BLS_SIGNATURE_DST byte for byte.
 */
export const WARRANT_SIGNATURE_DST = "ILRM-COMPLIANCE-COUNCIL-V01-CS01-with-BLS12381G2_XMD:SHA-256_SSWU_RO_";

/** hash-to-curve options passed to every noble sign / verify / hashToCurve call */
const HTF = { DST: WARRANT_SIGNATURE_DST };

/** Domain tag of the warrant message: keccak256("COMPLIANCE_REVEAL") */
const WARRANT_MESSAGE_TAG = "COMPLIANCE_REVEAL";

const BLS_SCALAR_SIZE = 32;
const BLS_G1_SIZE = 48;
const BLS_G2_SIZE = 96;
const UINT256_MAX = (1n << 256n) - 1n;
/** BLS12-381 base field modulus p */
const FP_ORDER = bls.fields.Fp.ORDER;

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
 * Create the 32-byte message council members sign for a warrant.
 *
 * Equals ComplianceCouncil.getSigningMessage(warrantId):
 *   keccak256(abi.encode(keccak256("COMPLIANCE_REVEAL"), chainId, council, warrantId,
 *                        targetDisputeId, documentHash, executionTime))
 * The message is bound to the chain and the council deployment, so a signature cannot be replayed
 * on another chain or another council.
 *
 * @throws if documentHash is not 32 bytes, council is not a 20-byte hex address, or a number is
 *         outside the uint256 range
 */
export function createWarrantMessage(warrant: WarrantSigningMessage): Uint8Array {
  if (!(warrant.documentHash instanceof Uint8Array) || warrant.documentHash.length !== 32) {
    throw new Error("documentHash must be 32 bytes");
  }
  const council = parseHex(warrant.council, "council");
  if (council.length !== 20) {
    throw new Error("council must be a 20-byte address");
  }

  return keccak_256(
    concatBytes(
      keccak_256(new TextEncoder().encode(WARRANT_MESSAGE_TAG)),
      uint256ToBytes(warrant.chainId),
      concatBytes(new Uint8Array(12), council),
      uint256ToBytes(warrant.warrantId),
      uint256ToBytes(warrant.targetDisputeId),
      warrant.documentHash,
      uint256ToBytes(warrant.executionTime)
    )
  );
}

/**
 * Hash a message to G2 exactly as the contract does (RFC 9380, WARRANT_SIGNATURE_DST)
 * @param message Message bytes (for warrants: the 32-byte createWarrantMessage output)
 * @returns The G2 point H(message)
 */
export function hashMessageToG2(message: Uint8Array) {
  return bls.G2.hashToCurve(message, HTF);
}

/**
 * Generate a partial signature using a key share
 * @param share The signer's key share
 * @param message Message hash to sign (createWarrantMessage output)
 * @returns Partial signature (96-byte compressed G2 point)
 */
export async function signPartial(
  share: KeyShare,
  message: Uint8Array
): Promise<PartialSignature> {
  const signature = bls.sign(message, share.secretShare, HTF);

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
 * @returns True if valid; false for an invalid or malformed input
 */
export async function verifyPartialSignature(
  partialSig: PartialSignature,
  message: Uint8Array,
  signerPublicKey: Uint8Array
): Promise<boolean> {
  try {
    return bls.verify(partialSig.signature, message, signerPublicKey, HTF);
  } catch {
    return false;
  }
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
 * @returns Aggregated threshold signature; signerIndices are sorted ascending (the aggregate itself
 *          does not depend on the order), as ComplianceCouncil.verifyThresholdSignature expects
 * @throws on an empty input, a non-positive or non-integer index, or a duplicate index
 */
export function aggregateSignatures(
  partialSignatures: PartialSignature[]
): ThresholdSignature {
  if (partialSignatures.length === 0) {
    throw new Error("No signatures to aggregate");
  }

  const signerIndices = partialSignatures.map((ps) => ps.signerIndex);
  for (const index of signerIndices) {
    if (!Number.isSafeInteger(index) || index <= 0) {
      throw new Error(`Invalid signer index ${index}`);
    }
  }
  if (new Set(signerIndices).size !== signerIndices.length) {
    throw new Error("Duplicate signer index");
  }

  // Compute weighted sum: sigma = sum(lambda_i * sigma_i)
  let aggregated = bls.G2.ProjectivePoint.ZERO;

  for (const partialSig of partialSignatures) {
    const lambda = computeLagrangeCoefficient(partialSig.signerIndex, signerIndices);
    const sigPoint = bls.G2.ProjectivePoint.fromHex(partialSig.signature);
    aggregated = aggregated.add(sigPoint.multiply(lambda));
  }

  return {
    aggregatedSignature: aggregated.toRawBytes(true),
    signerIndices: [...signerIndices].sort((a, b) => a - b),
  };
}

/**
 * Verify threshold signature against aggregated public key
 * @param thresholdSig Threshold signature
 * @param message Original message
 * @param aggregatedPublicKey Aggregated public key from DKG
 * @returns True if valid; false for an invalid or malformed input
 */
export async function verifyThresholdSignature(
  thresholdSig: ThresholdSignature,
  message: Uint8Array,
  aggregatedPublicKey: Uint8Array
): Promise<boolean> {
  try {
    return bls.verify(thresholdSig.aggregatedSignature, message, aggregatedPublicKey, HTF);
  } catch {
    return false;
  }
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
 * Encode an Fp element as its 64-byte EIP-2537 encoding, split into two 32-byte words [hi, lo]
 */
function encodeFp(v: bigint): [Uint8Array, Uint8Array] {
  const bytes = bigIntToBytes(v, 64);
  return [bytes.slice(0, 32), bytes.slice(32, 64)];
}

/**
 * Encode a BLS public key (G1) as the ComplianceCouncil BLSPublicKey struct
 * @param pk 48-byte compressed or 96-byte uncompressed G1 point
 * @throws if the point is malformed, not on the curve, not in the subgroup, or infinity
 */
export function encodeBLSPublicKeyForSolidity(pk: Uint8Array): BLSPublicKey {
  if (pk.length !== BLS_G1_SIZE && pk.length !== 2 * BLS_G1_SIZE) {
    throw new Error("Invalid public key length");
  }

  // fromHex validates the curve equation and subgroup membership
  const point = bls.G1.ProjectivePoint.fromHex(pk);
  if (point.equals(bls.G1.ProjectivePoint.ZERO)) {
    throw new Error("Public key is the point at infinity");
  }
  const affine = point.toAffine();

  return {
    x: encodeFp(affine.x),
    y: encodeFp(affine.y),
  };
}

/**
 * Encode a BLS signature (G2) as the ComplianceCouncil BLSSignature struct
 * @param sig 96-byte compressed or 192-byte uncompressed G2 point
 * @throws if the point is malformed, not on the curve, not in the subgroup, or infinity
 */
export function encodeBLSSignatureForSolidity(sig: Uint8Array): BLSSignature {
  if (sig.length !== BLS_G2_SIZE && sig.length !== 2 * BLS_G2_SIZE) {
    throw new Error("Invalid signature length");
  }

  // fromHex validates the curve equation and subgroup membership
  const point = bls.G2.ProjectivePoint.fromHex(sig);
  if (point.equals(bls.G2.ProjectivePoint.ZERO)) {
    throw new Error("Signature is the point at infinity");
  }
  const affine = point.toAffine();

  // Fp2 coordinates are { c0, c1 }; EIP-2537 orders them c0 || c1
  return {
    x: [...encodeFp(affine.x.c0), ...encodeFp(affine.x.c1)],
    y: [...encodeFp(affine.y.c0), ...encodeFp(affine.y.c1)],
  };
}

/**
 * Decode a ComplianceCouncil BLSPublicKey struct (e.g. from getMember or getAggregatedPublicKey)
 * @param pk Struct with 32-byte words as bytes or 0x-hex strings
 * @returns 48-byte compressed G1 point
 * @throws if a coordinate is not a canonical Fp encoding, or the point is not a valid, non-infinity
 *         G1 point
 */
export function decodeBLSPublicKeyFromSolidity(pk: {
  x: ArrayLike<SolidityWord>;
  y: ArrayLike<SolidityWord>;
}): Uint8Array {
  const [x, y] = decodeFpWords([pk.x, pk.y], 2);
  const point = bls.G1.ProjectivePoint.fromAffine({ x: x[0], y: y[0] });
  point.assertValidity();
  if (point.equals(bls.G1.ProjectivePoint.ZERO)) {
    throw new Error("Public key is the point at infinity");
  }
  return point.toRawBytes(true);
}

/**
 * Decode a ComplianceCouncil BLSSignature struct (e.g. from getSignatures or aggregateSignatures)
 * @param sig Struct with 32-byte words as bytes or 0x-hex strings
 * @returns 96-byte compressed G2 point
 * @throws if a coordinate limb is not a canonical Fp encoding, or the point is not a valid,
 *         non-infinity G2 point
 */
export function decodeBLSSignatureFromSolidity(sig: {
  x: ArrayLike<SolidityWord>;
  y: ArrayLike<SolidityWord>;
}): Uint8Array {
  // decodeFpWords rejects non-canonical limbs, so fromBigTuple's reduction mod p never changes a value
  const [x, y] = decodeFpWords([sig.x, sig.y], 4);
  const Fp2 = bls.fields.Fp2;
  const point = bls.G2.ProjectivePoint.fromAffine({
    x: Fp2.fromBigTuple([x[0], x[1]]),
    y: Fp2.fromBigTuple([y[0], y[1]]),
  });
  point.assertValidity();
  if (point.equals(bls.G2.ProjectivePoint.ZERO)) {
    throw new Error("Signature is the point at infinity");
  }
  return point.toRawBytes(true);
}

/**
 * The warrant's decryptedKeyHash for a threshold signature: keccak256 of its 256-byte EIP-2537
 * encoding (abi.encode of the BLSSignature struct).
 *
 * ComplianceCouncil.executeReconstruction computes this on chain in STRICT_ONCHAIN mode; in
 * HYBRID_ATTESTED mode the operator passes it to attestHybridVerification after verifying the
 * signature off chain. BLS signatures are unique, so every valid t-subset of partial signatures
 * aggregates to the same signature and hash.
 *
 * @param signature 96-byte compressed or 192-byte uncompressed G2 threshold signature
 *        (aggregateSignatures(...).aggregatedSignature)
 * @returns 32-byte hash
 * @throws if the signature is not a valid, non-infinity G2 point
 */
export function computeDecryptedKeyHash(signature: Uint8Array): Uint8Array {
  const enc = encodeBLSSignatureForSolidity(signature);
  return keccak_256(concatBytes(...enc.x, ...enc.y));
}

/**
 * Create Solidity-compatible warrant message hash.
 *
 * Alias of createWarrantMessage. BREAKING: this used to take positional arguments
 * (warrantId, targetDisputeId, documentHash, executionTime) and hashed them with SHA-256 without
 * chain or council binding, so it never matched the contract. It now takes a WarrantSigningMessage
 * (including chainId and council) and returns ComplianceCouncil.getSigningMessage(warrantId).
 */
export function createSolidityWarrantMessage(warrant: WarrantSigningMessage): Uint8Array {
  return createWarrantMessage(warrant);
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

function uint256ToBytes(value: bigint): Uint8Array {
  if (typeof value !== "bigint" || value < 0n || value > UINT256_MAX) {
    throw new Error("Value out of uint256 range");
  }
  return bigIntToBytes(value, 32);
}

/** Parse a hex string with optional 0x prefix */
function parseHex(value: string, name: string): Uint8Array {
  if (typeof value !== "string") {
    throw new Error(`${name} must be a hex string`);
  }
  const hex = value.startsWith("0x") || value.startsWith("0X") ? value.slice(2) : value;
  if (hex.length % 2 !== 0 || !/^[0-9a-fA-F]*$/.test(hex)) {
    throw new Error(`${name} is not valid hex`);
  }
  return hexToBytes(hex);
}

/** Convert a 32-byte word given as bytes or hex into bytes */
function wordToBytes(word: SolidityWord): Uint8Array {
  const bytes = typeof word === "string" ? parseHex(word, "word") : word;
  if (!(bytes instanceof Uint8Array) || bytes.length !== 32) {
    throw new Error("Expected a 32-byte word");
  }
  return bytes;
}

/**
 * Decode coordinates made of [hi, lo] word pairs into Fp values
 * @param coords Coordinate word arrays (x, y)
 * @param wordsPerCoord 2 for Fp (G1), 4 for Fp2 (G2)
 * @throws unless every 64-byte element is canonical (16 zero pad bytes and a value below p), the
 *         encoding the contract accepts; anything else would otherwise be silently reduced mod p
 */
function decodeFpWords(coords: ArrayLike<SolidityWord>[], wordsPerCoord: number): bigint[][] {
  return coords.map((coord) => {
    if (coord.length !== wordsPerCoord) {
      throw new Error(`Expected ${wordsPerCoord} words per coordinate`);
    }
    const values: bigint[] = [];
    for (let i = 0; i < wordsPerCoord; i += 2) {
      const value = bytesToBigInt(concatBytes(wordToBytes(coord[i]), wordToBytes(coord[i + 1])));
      // p < 2^384, so value < p also means the 16 pad bytes are zero
      if (value >= FP_ORDER) {
        throw new Error("Non-canonical field element encoding");
      }
      values.push(value);
    }
    return values;
  });
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

export async function thresholdBlsExampleUsage(): Promise<void> {
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

  // 3. Create warrant message (read these fields from ComplianceCouncil.getWarrant in practice)
  const warrant: WarrantSigningMessage = {
    chainId: 31337n,
    council: "0x5FbDB2315678afecb367f032d93F642f64180aa3",
    warrantId: 1n,
    targetDisputeId: 42n,
    documentHash: keccak_256(new TextEncoder().encode("Court Order #12345")),
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

  // Encode for Solidity (ComplianceCouncil.setAggregatedPublicKey / submitSignature)
  console.log("\n=== Solidity Encoding ===");
  const solidityPK = encodeBLSPublicKeyForSolidity(dkg.aggregatedPublicKey);
  console.log(`Public Key X: 0x${bytesToHex(concatBytes(...solidityPK.x))}`);
  console.log(`Public Key Y: 0x${bytesToHex(concatBytes(...solidityPK.y))}`);
  const soliditySig = encodeBLSSignatureForSolidity(thresholdSig.aggregatedSignature);
  console.log(`Signature X: 0x${bytesToHex(concatBytes(...soliditySig.x)).slice(0, 40)}...`);
}

// Run if executed directly
if (typeof require !== "undefined" && require.main === module) {
  thresholdBlsExampleUsage().catch(console.error);
}
