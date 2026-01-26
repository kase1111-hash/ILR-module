/**
 * ECIES (Elliptic Curve Integrated Encryption Scheme) Implementation
 *
 * This module implements ECIES on secp256k1 for encrypting viewing keys
 * in the NatLangChain protocol. ECIES provides:
 *
 * - Asymmetric encryption using ECDH key exchange
 * - Authenticated encryption using AES-256-GCM
 * - Forward secrecy via ephemeral key pairs
 *
 * The scheme is compatible with Ethereum keys, allowing users to use
 * their existing wallets for encryption/decryption.
 *
 * Flow:
 * 1. Generate ephemeral key pair
 * 2. Perform ECDH with recipient's public key
 * 3. Derive symmetric key using HKDF
 * 4. Encrypt data using AES-256-GCM
 * 5. Return (ephemeral public key, ciphertext, auth tag)
 *
 * Usage:
 * ```typescript
 * import { ECIES } from './ecies';
 *
 * const ecies = new ECIES();
 *
 * // Encrypt to a recipient's public key
 * const encrypted = await ecies.encrypt(recipientPublicKey, plaintext);
 *
 * // Decrypt with private key
 * const decrypted = await ecies.decrypt(privateKey, encrypted);
 * ```
 */

// Current ECIES format version - increment when making breaking changes
export const ECIES_VERSION = 1;

// Types for ECIES operations
export interface ECIESCiphertext {
  version: number;              // Format version for backward compatibility
  ephemeralPublicKey: string;  // Hex-encoded ephemeral public key (65 bytes uncompressed)
  iv: string;                   // Hex-encoded initialization vector (12 bytes for GCM)
  ciphertext: string;          // Hex-encoded encrypted data
  authTag: string;             // Hex-encoded authentication tag (16 bytes)
}

export interface ECIESKeyPair {
  privateKey: string;          // Hex-encoded private key (32 bytes)
  publicKey: string;           // Hex-encoded public key (65 bytes uncompressed)
}

/**
 * ECIES encryption/decryption class
 */
export class ECIES {
  /**
   * Generate a new secp256k1 key pair
   */
  async generateKeyPair(): Promise<ECIESKeyPair> {
    const secp256k1 = await import('@noble/secp256k1');

    // Generate random private key
    const privateKeyBytes = this.randomBytes(32);
    const privateKey = this.bytesToHex(privateKeyBytes);

    // Derive public key (uncompressed format)
    const publicKeyBytes = secp256k1.getPublicKey(privateKeyBytes, false);
    const publicKey = this.bytesToHex(publicKeyBytes);

    return { privateKey, publicKey };
  }

  /**
   * Derive public key from private key
   */
  async publicKeyFromPrivate(privateKey: string): Promise<string> {
    const secp256k1 = await import('@noble/secp256k1');
    const privateKeyBytes = this.hexToBytes(privateKey);
    const publicKeyBytes = secp256k1.getPublicKey(privateKeyBytes, false);
    return this.bytesToHex(publicKeyBytes);
  }

  /**
   * Encrypt data to a recipient's public key
   *
   * @param recipientPublicKey Recipient's public key (hex, 65 bytes uncompressed or 33 bytes compressed)
   * @param plaintext Data to encrypt
   * @returns ECIES ciphertext object
   */
  async encrypt(
    recipientPublicKey: string,
    plaintext: Uint8Array | Buffer | string
  ): Promise<ECIESCiphertext> {
    const secp256k1 = await import('@noble/secp256k1');

    // Convert plaintext to bytes
    const plaintextBytes = typeof plaintext === 'string'
      ? new TextEncoder().encode(plaintext)
      : new Uint8Array(plaintext);

    // Generate ephemeral key pair
    const ephemeralPrivate = this.randomBytes(32);
    const ephemeralPublic = secp256k1.getPublicKey(ephemeralPrivate, false);

    // Parse recipient public key
    const recipientPubBytes = this.hexToBytes(recipientPublicKey);

    // Perform ECDH
    const sharedPoint = secp256k1.getSharedSecret(ephemeralPrivate, recipientPubBytes);

    // Derive encryption key using HKDF
    const encryptionKey = await this.deriveKey(sharedPoint, 'ecies-encryption');

    // Generate random IV (12 bytes for AES-GCM)
    const iv = this.randomBytes(12);

    // Encrypt using AES-256-GCM
    const { ciphertext, authTag } = await this.aesGcmEncrypt(
      encryptionKey,
      iv,
      plaintextBytes
    );

    return {
      version: ECIES_VERSION,
      ephemeralPublicKey: this.bytesToHex(ephemeralPublic),
      iv: this.bytesToHex(iv),
      ciphertext: this.bytesToHex(ciphertext),
      authTag: this.bytesToHex(authTag),
    };
  }

  /**
   * Decrypt ECIES ciphertext with private key
   *
   * @param privateKey Recipient's private key (hex, 32 bytes)
   * @param ciphertext ECIES ciphertext object
   * @returns Decrypted plaintext
   * @throws Error if ciphertext version is unsupported
   */
  async decrypt(
    privateKey: string,
    ciphertext: ECIESCiphertext
  ): Promise<Uint8Array> {
    // Version check for forward compatibility
    // Accept version 0 (legacy, no version field) and version 1 (current)
    const version = ciphertext.version ?? 0;
    if (version > ECIES_VERSION) {
      throw new Error(
        `Unsupported ECIES ciphertext version ${version}. ` +
        `This SDK supports up to version ${ECIES_VERSION}. Please upgrade.`
      );
    }

    const secp256k1 = await import('@noble/secp256k1');

    // Parse inputs
    const privateKeyBytes = this.hexToBytes(privateKey);
    const ephemeralPublic = this.hexToBytes(ciphertext.ephemeralPublicKey);
    const iv = this.hexToBytes(ciphertext.iv);
    const encrypted = this.hexToBytes(ciphertext.ciphertext);
    const authTag = this.hexToBytes(ciphertext.authTag);

    // Perform ECDH
    const sharedPoint = secp256k1.getSharedSecret(privateKeyBytes, ephemeralPublic);

    // Derive encryption key
    const encryptionKey = await this.deriveKey(sharedPoint, 'ecies-encryption');

    // Decrypt using AES-256-GCM
    const plaintext = await this.aesGcmDecrypt(
      encryptionKey,
      iv,
      encrypted,
      authTag
    );

    return plaintext;
  }

  /**
   * Encrypt data for multiple recipients
   * Each recipient can decrypt with their own private key
   */
  async encryptMulti(
    recipientPublicKeys: string[],
    plaintext: Uint8Array | Buffer | string
  ): Promise<{ sharedCiphertext: ECIESCiphertext; keyShares: ECIESCiphertext[] }> {
    // Generate a random data encryption key (DEK)
    const dek = this.randomBytes(32);

    // Encrypt the plaintext with the DEK
    const plaintextBytes = typeof plaintext === 'string'
      ? new TextEncoder().encode(plaintext)
      : new Uint8Array(plaintext);

    const iv = this.randomBytes(12);
    const { ciphertext, authTag } = await this.aesGcmEncrypt(dek, iv, plaintextBytes);

    // Create a "fake" ECIES ciphertext for the shared data
    const sharedCiphertext: ECIESCiphertext = {
      version: ECIES_VERSION,
      ephemeralPublicKey: '0x' + '00'.repeat(65), // Placeholder (not used for shared data)
      iv: this.bytesToHex(iv),
      ciphertext: this.bytesToHex(ciphertext),
      authTag: this.bytesToHex(authTag),
    };

    // Encrypt the DEK to each recipient
    const keyShares: ECIESCiphertext[] = [];
    for (const pubKey of recipientPublicKeys) {
      const encryptedDEK = await this.encrypt(pubKey, dek);
      keyShares.push(encryptedDEK);
    }

    return { sharedCiphertext, keyShares };
  }

  /**
   * Decrypt multi-recipient ciphertext
   */
  async decryptMulti(
    privateKey: string,
    sharedCiphertext: ECIESCiphertext,
    myKeyShare: ECIESCiphertext
  ): Promise<Uint8Array> {
    // Decrypt the DEK
    const dek = await this.decrypt(privateKey, myKeyShare);

    // Decrypt the shared ciphertext with the DEK
    const iv = this.hexToBytes(sharedCiphertext.iv);
    const encrypted = this.hexToBytes(sharedCiphertext.ciphertext);
    const authTag = this.hexToBytes(sharedCiphertext.authTag);

    return await this.aesGcmDecrypt(dek, iv, encrypted, authTag);
  }

  // ============ Private Helper Methods ============

  // Domain-specific salt for HKDF - provides defense-in-depth
  // Using a fixed, non-zero salt is recommended over zero salt per RFC 5869
  private static readonly HKDF_SALT = new TextEncoder().encode('natlangchain-ecies-v1-salt');

  /**
   * Derive a symmetric key using HKDF (HMAC-based Key Derivation Function)
   * Uses a domain-specific salt for additional security
   */
  private async deriveKey(sharedSecret: Uint8Array, info: string): Promise<Uint8Array> {
    // Use Web Crypto API if available
    if (typeof crypto !== 'undefined' && crypto.subtle) {
      // Create proper ArrayBuffer copies to satisfy TypeScript's strict typing
      const keyMaterial = sharedSecret.slice(1); // Skip the 0x04 prefix
      const keyMaterialBuffer = new Uint8Array(keyMaterial).buffer;
      const saltBuffer = new Uint8Array(ECIES.HKDF_SALT).buffer;

      const baseKey = await crypto.subtle.importKey(
        'raw',
        keyMaterialBuffer,
        'HKDF',
        false,
        ['deriveKey']
      );

      const derivedKey = await crypto.subtle.deriveKey(
        {
          name: 'HKDF',
          hash: 'SHA-256',
          salt: saltBuffer, // Domain-specific salt
          info: new TextEncoder().encode(info),
        },
        baseKey,
        { name: 'AES-GCM', length: 256 },
        true,
        ['encrypt', 'decrypt']
      );

      const keyBytes = await crypto.subtle.exportKey('raw', derivedKey);
      return new Uint8Array(keyBytes);
    }

    // Fallback for Node.js without Web Crypto
    const nodeCrypto = await import('crypto');
    return new Uint8Array(
      nodeCrypto.hkdfSync(
        'sha256',
        sharedSecret.slice(1),
        Buffer.from(ECIES.HKDF_SALT), // Domain-specific salt
        info,
        32
      )
    );
  }

  /**
   * AES-256-GCM encryption
   */
  private async aesGcmEncrypt(
    key: Uint8Array,
    iv: Uint8Array,
    plaintext: Uint8Array
  ): Promise<{ ciphertext: Uint8Array; authTag: Uint8Array }> {
    if (typeof crypto !== 'undefined' && crypto.subtle) {
      // Create proper ArrayBuffer copies to satisfy TypeScript's strict typing
      const keyBuffer = new Uint8Array(key).buffer;
      const ivBuffer = new Uint8Array(iv).buffer;
      const plaintextBuffer = new Uint8Array(plaintext).buffer;

      const cryptoKey = await crypto.subtle.importKey(
        'raw',
        keyBuffer,
        'AES-GCM',
        false,
        ['encrypt']
      );

      const result = await crypto.subtle.encrypt(
        { name: 'AES-GCM', iv: ivBuffer, tagLength: 128 },
        cryptoKey,
        plaintextBuffer
      );

      const resultBytes = new Uint8Array(result);
      // GCM appends the auth tag to the ciphertext
      const ciphertext = resultBytes.slice(0, -16);
      const authTag = resultBytes.slice(-16);

      return { ciphertext, authTag };
    }

    // Fallback for Node.js
    const nodeCrypto = await import('crypto');
    const cipher = nodeCrypto.createCipheriv('aes-256-gcm', key, iv);
    const ciphertext = Buffer.concat([cipher.update(plaintext), cipher.final()]);
    const authTag = cipher.getAuthTag();

    return {
      ciphertext: new Uint8Array(ciphertext),
      authTag: new Uint8Array(authTag),
    };
  }

  /**
   * AES-256-GCM decryption
   */
  private async aesGcmDecrypt(
    key: Uint8Array,
    iv: Uint8Array,
    ciphertext: Uint8Array,
    authTag: Uint8Array
  ): Promise<Uint8Array> {
    if (typeof crypto !== 'undefined' && crypto.subtle) {
      // Create proper ArrayBuffer copies to satisfy TypeScript's strict typing
      const keyBuffer = new Uint8Array(key).buffer;
      const ivBuffer = new Uint8Array(iv).buffer;

      const cryptoKey = await crypto.subtle.importKey(
        'raw',
        keyBuffer,
        'AES-GCM',
        false,
        ['decrypt']
      );

      // GCM expects auth tag appended to ciphertext
      const combined = new Uint8Array(ciphertext.length + authTag.length);
      combined.set(ciphertext);
      combined.set(authTag, ciphertext.length);
      const combinedBuffer = new Uint8Array(combined).buffer;

      const result = await crypto.subtle.decrypt(
        { name: 'AES-GCM', iv: ivBuffer, tagLength: 128 },
        cryptoKey,
        combinedBuffer
      );

      return new Uint8Array(result);
    }

    // Fallback for Node.js
    const nodeCrypto = await import('crypto');
    const decipher = nodeCrypto.createDecipheriv('aes-256-gcm', key, iv);
    decipher.setAuthTag(authTag);
    const plaintext = Buffer.concat([decipher.update(ciphertext), decipher.final()]);

    return new Uint8Array(plaintext);
  }

  /**
   * Generate cryptographically secure random bytes
   */
  private randomBytes(length: number): Uint8Array {
    if (typeof crypto !== 'undefined' && crypto.getRandomValues) {
      const array = new Uint8Array(length);
      crypto.getRandomValues(array);
      return array;
    }
    const nodeCrypto = require('crypto');
    return new Uint8Array(nodeCrypto.randomBytes(length));
  }

  /**
   * Convert hex string to Uint8Array
   */
  private hexToBytes(hex: string): Uint8Array {
    const cleanHex = hex.startsWith('0x') ? hex.slice(2) : hex;
    const bytes = new Uint8Array(cleanHex.length / 2);
    for (let i = 0; i < bytes.length; i++) {
      bytes[i] = parseInt(cleanHex.substring(i * 2, i * 2 + 2), 16);
    }
    return bytes;
  }

  /**
   * Convert Uint8Array to hex string
   */
  private bytesToHex(bytes: Uint8Array): string {
    return '0x' + Array.from(bytes)
      .map((b) => b.toString(16).padStart(2, '0'))
      .join('');
  }
}

/**
 * Serialize ECIES ciphertext to JSON-compatible format
 */
export function serializeCiphertext(ciphertext: ECIESCiphertext): string {
  return JSON.stringify(ciphertext);
}

/**
 * Deserialize ECIES ciphertext from JSON
 */
export function deserializeCiphertext(json: string): ECIESCiphertext {
  return JSON.parse(json) as ECIESCiphertext;
}

// Export singleton instance
export const ecies = new ECIES();

// Example usage and self-test
export async function exampleUsage() {
  console.log('=== ECIES Encryption Example ===\n');

  const ecies = new ECIES();

  try {
    // Generate key pair
    console.log('Generating key pair...');
    const { privateKey, publicKey } = await ecies.generateKeyPair();
    console.log('Public key:', publicKey.slice(0, 40) + '...');
    console.log('Private key:', privateKey.slice(0, 20) + '...');
    console.log();

    // Encrypt a message
    const message = 'This is my secret viewing key data!';
    console.log('Original message:', message);
    console.log();

    console.log('Encrypting...');
    const encrypted = await ecies.encrypt(publicKey, message);
    console.log('Ciphertext:', encrypted.ciphertext.slice(0, 40) + '...');
    console.log('Auth tag:', encrypted.authTag);
    console.log();

    // Decrypt
    console.log('Decrypting...');
    const decrypted = await ecies.decrypt(privateKey, encrypted);
    const decryptedMessage = new TextDecoder().decode(decrypted);
    console.log('Decrypted message:', decryptedMessage);
    console.log();

    // Verify
    if (decryptedMessage === message) {
      console.log('SUCCESS: Message decrypted correctly!');
    } else {
      console.error('FAILED: Message mismatch');
    }
  } catch (error) {
    console.error('Error:', error);
    console.log('\nNote: This example requires @noble/secp256k1');
    console.log('Run: npm install @noble/secp256k1');
  }
}

if (require.main === module) {
  exampleUsage();
}
