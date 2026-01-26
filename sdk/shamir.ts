/**
 * Shamir's Secret Sharing Implementation
 *
 * This module implements Shamir's Secret Sharing scheme for splitting
 * viewing keys into m-of-n shares. The scheme provides:
 *
 * - Information-theoretic security: fewer than m shares reveal nothing
 * - Threshold reconstruction: exactly m shares reconstruct the secret
 * - Perfect secrecy: any m-1 shares are computationally indistinguishable
 *
 * Implementation uses GF(2^8) (Galois Field with 256 elements) for
 * byte-level operations, compatible with standard cryptographic libraries.
 *
 * Usage:
 * ```typescript
 * import { ShamirSecretSharing } from './shamir';
 *
 * const sss = new ShamirSecretSharing();
 *
 * // Split a secret into 5 shares, requiring 3 to reconstruct
 * const secret = Buffer.from('my-viewing-key');
 * const shares = sss.split(secret, 5, 3);
 *
 * // Reconstruct from any 3 shares
 * const reconstructed = sss.combine([shares[0], shares[2], shares[4]]);
 * ```
 */

// GF(2^8) operations using AES polynomial x^8 + x^4 + x^3 + x + 1
const GF256_PRIMITIVE = 0x11b;

/**
 * Represents a single share in the secret sharing scheme
 */
export interface Share {
  index: number;      // Share index (1 to n, never 0)
  data: Uint8Array;   // Share data (same length as secret)
}

/**
 * Encoded share for storage/transmission
 */
export interface EncodedShare {
  index: number;
  data: string;  // Base64 encoded
}

/**
 * Shamir's Secret Sharing implementation
 */
export class ShamirSecretSharing {
  // Precomputed log and exp tables for GF(2^8)
  private readonly logTable: Uint8Array;
  private readonly expTable: Uint8Array;

  constructor() {
    // Initialize GF(2^8) lookup tables
    // IMPORTANT: Use 3 as the generator (primitive element), not 2
    // With polynomial 0x11b, element 2 has order 51 (not 255)
    // Element 3 has order 255 and generates the full multiplicative group
    this.logTable = new Uint8Array(256);
    this.expTable = new Uint8Array(256);

    let x = 1;
    for (let i = 0; i < 255; i++) {
      this.expTable[i] = x;
      this.logTable[x] = i;
      x = this.gfMultiplyNoTable(x, 3);  // Use 3 as primitive element
    }
    this.expTable[255] = this.expTable[0];
  }

  /**
   * Multiply in GF(2^8) without lookup tables (for table generation)
   */
  private gfMultiplyNoTable(a: number, b: number): number {
    let result = 0;
    while (b > 0) {
      if (b & 1) {
        result ^= a;
      }
      a <<= 1;
      if (a & 0x100) {
        a ^= GF256_PRIMITIVE;
      }
      b >>= 1;
    }
    return result & 0xff;
  }

  /**
   * Add in GF(2^8) - same as XOR
   */
  private gfAdd(a: number, b: number): number {
    return a ^ b;
  }

  /**
   * Multiply in GF(2^8) using lookup tables
   */
  private gfMultiply(a: number, b: number): number {
    if (a === 0 || b === 0) return 0;
    const logSum = this.logTable[a] + this.logTable[b];
    return this.expTable[logSum % 255];
  }

  /**
   * Divide in GF(2^8)
   */
  private gfDivide(a: number, b: number): number {
    if (b === 0) throw new Error('Division by zero in GF(2^8)');
    if (a === 0) return 0;
    const logDiff = this.logTable[a] - this.logTable[b] + 255;
    return this.expTable[logDiff % 255];
  }

  /**
   * Evaluate polynomial at point x in GF(2^8)
   * Polynomial is represented as array of coefficients [a0, a1, ..., ak]
   * where polynomial = a0 + a1*x + a2*x^2 + ... + ak*x^k
   */
  private evaluatePolynomial(coefficients: Uint8Array, x: number): number {
    if (x === 0) return coefficients[0];

    let result = 0;
    for (let i = coefficients.length - 1; i >= 0; i--) {
      result = this.gfAdd(this.gfMultiply(result, x), coefficients[i]);
    }
    return result;
  }

  /**
   * Generate cryptographically secure random bytes
   */
  private randomBytes(length: number): Uint8Array {
    if (typeof window !== 'undefined' && window.crypto) {
      const array = new Uint8Array(length);
      window.crypto.getRandomValues(array);
      return array;
    } else {
      const crypto = require('crypto');
      return new Uint8Array(crypto.randomBytes(length));
    }
  }

  /**
   * Split a secret into n shares, requiring threshold shares to reconstruct
   *
   * @param secret The secret to split (as Buffer or Uint8Array)
   * @param numShares Total number of shares to generate (n)
   * @param threshold Minimum shares required to reconstruct (m)
   * @returns Array of shares
   */
  split(secret: Uint8Array | Buffer, numShares: number, threshold: number): Share[] {
    // Validate inputs
    if (threshold < 2) {
      throw new Error('Threshold must be at least 2');
    }
    if (threshold > numShares) {
      throw new Error('Threshold cannot exceed number of shares');
    }
    if (numShares > 255) {
      throw new Error('Maximum 255 shares supported');
    }
    if (secret.length === 0) {
      throw new Error('Secret cannot be empty');
    }

    const secretBytes = secret instanceof Buffer ? new Uint8Array(secret) : secret;
    const shares: Share[] = [];

    // For each byte position in the secret
    for (let shareIndex = 1; shareIndex <= numShares; shareIndex++) {
      shares.push({
        index: shareIndex,
        data: new Uint8Array(secretBytes.length),
      });
    }

    // Process each byte of the secret
    for (let byteIndex = 0; byteIndex < secretBytes.length; byteIndex++) {
      // Create random polynomial with secret as constant term
      // P(x) = secret + a1*x + a2*x^2 + ... + a(t-1)*x^(t-1)
      const coefficients = new Uint8Array(threshold);
      coefficients[0] = secretBytes[byteIndex];

      // Generate random coefficients for higher terms
      const randomCoeffs = this.randomBytes(threshold - 1);
      for (let i = 1; i < threshold; i++) {
        coefficients[i] = randomCoeffs[i - 1];
      }

      // Evaluate polynomial at each share index (1 to n)
      for (let shareIndex = 1; shareIndex <= numShares; shareIndex++) {
        shares[shareIndex - 1].data[byteIndex] = this.evaluatePolynomial(
          coefficients,
          shareIndex
        );
      }
    }

    return shares;
  }

  /**
   * Combine shares to reconstruct the secret using Lagrange interpolation
   *
   * @param shares Array of shares (must be at least threshold shares)
   * @returns Reconstructed secret
   */
  combine(shares: Share[]): Uint8Array {
    if (shares.length < 2) {
      throw new Error('Need at least 2 shares to reconstruct');
    }

    // Verify all shares have same length
    const dataLength = shares[0].data.length;
    for (const share of shares) {
      if (share.data.length !== dataLength) {
        throw new Error('All shares must have same data length');
      }
    }

    // Check for duplicate indices
    const indices = new Set(shares.map((s) => s.index));
    if (indices.size !== shares.length) {
      throw new Error('Duplicate share indices detected');
    }

    const result = new Uint8Array(dataLength);

    // Reconstruct each byte using Lagrange interpolation at x=0
    for (let byteIndex = 0; byteIndex < dataLength; byteIndex++) {
      let value = 0;

      for (let i = 0; i < shares.length; i++) {
        const xi = shares[i].index;
        const yi = shares[i].data[byteIndex];

        // Calculate Lagrange basis polynomial Li(0)
        let numerator = 1;
        let denominator = 1;

        for (let j = 0; j < shares.length; j++) {
          if (i === j) continue;

          const xj = shares[j].index;

          // Li(0) = product of (0 - xj) / (xi - xj) for all j != i
          // In GF(2^8), subtraction is same as addition (XOR)
          numerator = this.gfMultiply(numerator, xj);
          denominator = this.gfMultiply(denominator, this.gfAdd(xi, xj));
        }

        // Li(0) * yi
        const lagrangeTerm = this.gfMultiply(
          yi,
          this.gfDivide(numerator, denominator)
        );

        value = this.gfAdd(value, lagrangeTerm);
      }

      result[byteIndex] = value;
    }

    return result;
  }

  /**
   * Encode a share for storage/transmission
   */
  encodeShare(share: Share): EncodedShare {
    const base64 = typeof Buffer !== 'undefined'
      ? Buffer.from(share.data).toString('base64')
      : btoa(String.fromCharCode(...share.data));

    return {
      index: share.index,
      data: base64,
    };
  }

  /**
   * Decode a share from storage/transmission
   */
  decodeShare(encoded: EncodedShare): Share {
    let data: Uint8Array;

    if (typeof Buffer !== 'undefined') {
      data = new Uint8Array(Buffer.from(encoded.data, 'base64'));
    } else {
      const binaryString = atob(encoded.data);
      data = new Uint8Array(binaryString.length);
      for (let i = 0; i < binaryString.length; i++) {
        data[i] = binaryString.charCodeAt(i);
      }
    }

    return {
      index: encoded.index,
      data,
    };
  }

  /**
   * Generate a commitment to a share (for on-chain verification)
   * Uses keccak256 hash of index + data
   */
  async generateShareCommitment(share: Share): Promise<string> {
    const ethers = await import('ethers');

    const packed = ethers.solidityPacked(
      ['uint8', 'bytes'],
      [share.index, share.data]
    );

    return ethers.keccak256(packed);
  }

  /**
   * Verify a share matches its commitment
   */
  async verifyShareCommitment(share: Share, commitment: string): Promise<boolean> {
    const computed = await this.generateShareCommitment(share);
    return computed.toLowerCase() === commitment.toLowerCase();
  }
}

/**
 * Utility: Convert hex string to Uint8Array
 */
export function hexToBytes(hex: string): Uint8Array {
  const cleanHex = hex.startsWith('0x') ? hex.slice(2) : hex;
  const bytes = new Uint8Array(cleanHex.length / 2);
  for (let i = 0; i < bytes.length; i++) {
    bytes[i] = parseInt(cleanHex.substring(i * 2, i * 2 + 2), 16);
  }
  return bytes;
}

/**
 * Utility: Convert Uint8Array to hex string
 */
export function bytesToHex(bytes: Uint8Array): string {
  return '0x' + Array.from(bytes)
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}

// Export singleton instance
export const shamirSecretSharing = new ShamirSecretSharing();

// Self-test on import (development only)
if (process.env.NODE_ENV === 'development') {
  (async () => {
    const sss = new ShamirSecretSharing();
    const secret = new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
    const shares = sss.split(secret, 5, 3);

    // Test reconstruction with different share combinations
    const reconstructed1 = sss.combine([shares[0], shares[1], shares[2]]);
    const reconstructed2 = sss.combine([shares[0], shares[2], shares[4]]);
    const reconstructed3 = sss.combine([shares[1], shares[3], shares[4]]);

    const match1 = reconstructed1.every((v, i) => v === secret[i]);
    const match2 = reconstructed2.every((v, i) => v === secret[i]);
    const match3 = reconstructed3.every((v, i) => v === secret[i]);

    if (!match1 || !match2 || !match3) {
      console.error('Shamir self-test FAILED');
    } else {
      console.log('Shamir self-test passed');
    }
  })();
}
