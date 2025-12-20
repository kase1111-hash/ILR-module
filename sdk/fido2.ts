/**
 * FIDO2/WebAuthn SDK for NatLangChain
 *
 * This module provides browser-side WebAuthn integration for
 * hardware-backed authentication (YubiKey, TouchID, etc.).
 *
 * Features:
 * - Key registration (credential creation)
 * - Assertion generation (signature creation)
 * - Challenge management with blockchain integration
 * - Support for cross-platform and platform authenticators
 *
 * Usage:
 * ```typescript
 * import { FIDO2SDK } from './fido2';
 *
 * const fido = new FIDO2SDK({
 *   rpId: 'natlangchain.io',
 *   rpName: 'NatLangChain Protocol',
 * });
 *
 * // Register a hardware key
 * const credential = await fido.registerKey(userAddress);
 *
 * // Sign an action (e.g., accept proposal)
 * const assertion = await fido.signAction('accept-proposal', { disputeId: 123 });
 * ```
 */

// ============ Types ============

export interface FIDO2Config {
  rpId: string; // Relying party ID (domain)
  rpName: string; // Human-readable RP name
  timeout?: number; // Timeout in ms (default: 60000)
  userVerification?: UserVerificationRequirement;
  attestation?: AttestationConveyancePreference;
}

export interface RegisteredCredential {
  credentialId: Uint8Array;
  credentialIdHex: string;
  publicKeyX: string; // Hex-encoded X coordinate
  publicKeyY: string; // Hex-encoded Y coordinate
  publicKeyHex: string; // Full uncompressed public key
  attestation?: ArrayBuffer;
}

export interface SignedAssertion {
  authenticatorData: Uint8Array;
  authenticatorDataHex: string;
  clientDataJSON: Uint8Array;
  clientDataJSONHex: string;
  signature: Uint8Array;
  signatureHex: string;
  challenge: string; // Hex-encoded challenge that was signed
}

export interface ActionData {
  disputeId?: number;
  proposalHash?: string;
  [key: string]: unknown;
}

// ============ SDK Class ============

export class FIDO2SDK {
  private config: Required<FIDO2Config>;

  constructor(config: FIDO2Config) {
    this.config = {
      rpId: config.rpId,
      rpName: config.rpName,
      timeout: config.timeout ?? 60000,
      userVerification: config.userVerification ?? 'preferred',
      attestation: config.attestation ?? 'none',
    };
  }

  /**
   * Check if WebAuthn is supported in current environment
   */
  isSupported(): boolean {
    return (
      typeof window !== 'undefined' &&
      window.PublicKeyCredential !== undefined &&
      typeof window.PublicKeyCredential === 'function'
    );
  }

  /**
   * Check if platform authenticator is available (TouchID, FaceID, Windows Hello)
   */
  async isPlatformAuthenticatorAvailable(): Promise<boolean> {
    if (!this.isSupported()) return false;

    try {
      return await PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable();
    } catch {
      return false;
    }
  }

  /**
   * Register a new FIDO2 credential (hardware key)
   *
   * @param userAddress Ethereum address of the user
   * @param userName Display name for the user
   * @param preferPlatform Prefer platform authenticator (TouchID) over roaming (YubiKey)
   * @returns Registered credential with public key components
   */
  async registerKey(
    userAddress: string,
    userName?: string,
    preferPlatform = false
  ): Promise<RegisteredCredential> {
    if (!this.isSupported()) {
      throw new Error('WebAuthn not supported in this environment');
    }

    // Generate a random challenge
    const challenge = this.generateChallenge();

    // User ID from Ethereum address
    const userId = this.hexToBytes(userAddress);

    const publicKeyCredentialCreationOptions: PublicKeyCredentialCreationOptions = {
      challenge,
      rp: {
        name: this.config.rpName,
        id: this.config.rpId,
      },
      user: {
        id: userId,
        name: userName ?? userAddress,
        displayName: userName ?? `User ${userAddress.slice(0, 8)}...`,
      },
      pubKeyCredParams: [
        { alg: -7, type: 'public-key' }, // ES256 (P-256)
      ],
      authenticatorSelection: {
        authenticatorAttachment: preferPlatform ? 'platform' : 'cross-platform',
        userVerification: this.config.userVerification,
        residentKey: 'preferred',
      },
      timeout: this.config.timeout,
      attestation: this.config.attestation,
    };

    const credential = (await navigator.credentials.create({
      publicKey: publicKeyCredentialCreationOptions,
    })) as PublicKeyCredential | null;

    if (!credential) {
      throw new Error('Credential creation failed or was cancelled');
    }

    const response = credential.response as AuthenticatorAttestationResponse;

    // Parse the public key from attestation object
    const { publicKeyX, publicKeyY, publicKeyHex } = this.parsePublicKey(
      response.getPublicKey()!
    );

    return {
      credentialId: new Uint8Array(credential.rawId),
      credentialIdHex: this.bytesToHex(new Uint8Array(credential.rawId)),
      publicKeyX,
      publicKeyY,
      publicKeyHex,
      attestation: response.attestationObject,
    };
  }

  /**
   * Sign an action using the registered FIDO2 credential
   *
   * @param action Action identifier (e.g., 'accept-proposal')
   * @param data Additional data for the challenge
   * @param credentialId Optional specific credential to use
   * @returns Signed assertion for on-chain verification
   */
  async signAction(
    action: string,
    data: ActionData,
    credentialId?: Uint8Array
  ): Promise<SignedAssertion> {
    if (!this.isSupported()) {
      throw new Error('WebAuthn not supported in this environment');
    }

    // Generate challenge incorporating action and data
    const challenge = this.generateActionChallenge(action, data);

    const publicKeyCredentialRequestOptions: PublicKeyCredentialRequestOptions = {
      challenge,
      rpId: this.config.rpId,
      timeout: this.config.timeout,
      userVerification: this.config.userVerification,
      allowCredentials: credentialId
        ? [{ id: credentialId, type: 'public-key' }]
        : undefined,
    };

    const assertion = (await navigator.credentials.get({
      publicKey: publicKeyCredentialRequestOptions,
    })) as PublicKeyCredential | null;

    if (!assertion) {
      throw new Error('Assertion request failed or was cancelled');
    }

    const response = assertion.response as AuthenticatorAssertionResponse;

    return {
      authenticatorData: new Uint8Array(response.authenticatorData),
      authenticatorDataHex: this.bytesToHex(new Uint8Array(response.authenticatorData)),
      clientDataJSON: new Uint8Array(response.clientDataJSON),
      clientDataJSONHex: this.bytesToHex(new Uint8Array(response.clientDataJSON)),
      signature: new Uint8Array(response.signature),
      signatureHex: this.bytesToHex(new Uint8Array(response.signature)),
      challenge: this.bytesToHex(challenge),
    };
  }

  /**
   * Sign a proposal acceptance for ILRM
   *
   * @param disputeId The dispute ID to accept
   * @param credentialId Optional specific credential
   * @returns Signed assertion
   */
  async signAcceptProposal(
    disputeId: number,
    credentialId?: Uint8Array
  ): Promise<SignedAssertion> {
    return this.signAction('accept-proposal', { disputeId }, credentialId);
  }

  /**
   * Sign a counter-proposal for ILRM
   *
   * @param disputeId The dispute ID
   * @param evidenceHash Hash of new evidence
   * @param credentialId Optional specific credential
   * @returns Signed assertion
   */
  async signCounterProposal(
    disputeId: number,
    evidenceHash: string,
    credentialId?: Uint8Array
  ): Promise<SignedAssertion> {
    return this.signAction(
      'counter-propose',
      { disputeId, evidenceHash },
      credentialId
    );
  }

  /**
   * Format assertion for contract call
   *
   * @param assertion The signed assertion
   * @returns Formatted for FIDOVerifier.verifyAssertion()
   */
  formatForContract(assertion: SignedAssertion): {
    authenticatorData: string;
    clientDataJSON: string;
    signature: string;
  } {
    return {
      authenticatorData: assertion.authenticatorDataHex,
      clientDataJSON: assertion.clientDataJSONHex,
      signature: assertion.signatureHex,
    };
  }

  // ============ Private Methods ============

  /**
   * Generate a random challenge
   */
  private generateChallenge(): Uint8Array {
    const challenge = new Uint8Array(32);
    crypto.getRandomValues(challenge);
    return challenge;
  }

  /**
   * Generate challenge for a specific action
   */
  private generateActionChallenge(action: string, data: ActionData): Uint8Array {
    const encoder = new TextEncoder();
    const actionBytes = encoder.encode(action);
    const dataBytes = encoder.encode(JSON.stringify(data));
    const timestamp = encoder.encode(Date.now().toString());
    const random = new Uint8Array(16);
    crypto.getRandomValues(random);

    // Combine all components
    const combined = new Uint8Array(
      actionBytes.length + dataBytes.length + timestamp.length + random.length
    );
    let offset = 0;
    combined.set(actionBytes, offset);
    offset += actionBytes.length;
    combined.set(dataBytes, offset);
    offset += dataBytes.length;
    combined.set(timestamp, offset);
    offset += timestamp.length;
    combined.set(random, offset);

    // Hash to get 32-byte challenge
    return this.sha256(combined);
  }

  /**
   * Parse public key from COSE format
   */
  private parsePublicKey(
    spkiKey: ArrayBuffer
  ): { publicKeyX: string; publicKeyY: string; publicKeyHex: string } {
    const keyBytes = new Uint8Array(spkiKey);

    // SPKI format for P-256: skip header to get raw point
    // The raw point is 65 bytes: 0x04 || x (32 bytes) || y (32 bytes)
    let rawPoint: Uint8Array;

    if (keyBytes.length === 65 && keyBytes[0] === 0x04) {
      rawPoint = keyBytes;
    } else if (keyBytes.length === 91) {
      // SPKI wrapped
      rawPoint = keyBytes.slice(26);
    } else {
      // Try to find 0x04 prefix
      for (let i = 0; i < keyBytes.length - 64; i++) {
        if (keyBytes[i] === 0x04) {
          rawPoint = keyBytes.slice(i, i + 65);
          break;
        }
      }
      if (!rawPoint!) {
        throw new Error('Could not parse public key');
      }
    }

    const x = rawPoint.slice(1, 33);
    const y = rawPoint.slice(33, 65);

    return {
      publicKeyX: this.bytesToHex(x),
      publicKeyY: this.bytesToHex(y),
      publicKeyHex: this.bytesToHex(rawPoint),
    };
  }

  /**
   * SHA-256 hash (browser implementation)
   */
  private sha256(data: Uint8Array): Uint8Array {
    // Synchronous fallback for challenge generation
    // In production, use SubtleCrypto.digest() async
    const hash = new Uint8Array(32);
    let h0 = 0x6a09e667,
      h1 = 0xbb67ae85,
      h2 = 0x3c6ef372,
      h3 = 0xa54ff53a;
    let h4 = 0x510e527f,
      h5 = 0x9b05688c,
      h6 = 0x1f83d9ab,
      h7 = 0x5be0cd19;

    const k = [
      0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
      0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
      0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
      0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
      0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
      0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
      0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
      0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
      0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
      0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
      0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ];

    // Pad message
    const bitLen = data.length * 8;
    const padLen = ((data.length + 8) % 64 < 56 ? 56 : 120) - ((data.length + 8) % 64);
    const padded = new Uint8Array(data.length + 1 + padLen + 8);
    padded.set(data);
    padded[data.length] = 0x80;
    const view = new DataView(padded.buffer);
    view.setUint32(padded.length - 4, bitLen, false);

    // Process blocks
    for (let i = 0; i < padded.length; i += 64) {
      const w = new Uint32Array(64);
      for (let j = 0; j < 16; j++) {
        w[j] = view.getUint32(i + j * 4, false);
      }
      for (let j = 16; j < 64; j++) {
        const s0 =
          ((w[j - 15] >>> 7) | (w[j - 15] << 25)) ^
          ((w[j - 15] >>> 18) | (w[j - 15] << 14)) ^
          (w[j - 15] >>> 3);
        const s1 =
          ((w[j - 2] >>> 17) | (w[j - 2] << 15)) ^
          ((w[j - 2] >>> 19) | (w[j - 2] << 13)) ^
          (w[j - 2] >>> 10);
        w[j] = (w[j - 16] + s0 + w[j - 7] + s1) >>> 0;
      }

      let a = h0,
        b = h1,
        c = h2,
        d = h3,
        e = h4,
        f = h5,
        g = h6,
        hh = h7;

      for (let j = 0; j < 64; j++) {
        const S1 = ((e >>> 6) | (e << 26)) ^ ((e >>> 11) | (e << 21)) ^ ((e >>> 25) | (e << 7));
        const ch = (e & f) ^ (~e & g);
        const temp1 = (hh + S1 + ch + k[j] + w[j]) >>> 0;
        const S0 = ((a >>> 2) | (a << 30)) ^ ((a >>> 13) | (a << 19)) ^ ((a >>> 22) | (a << 10));
        const maj = (a & b) ^ (a & c) ^ (b & c);
        const temp2 = (S0 + maj) >>> 0;

        hh = g;
        g = f;
        f = e;
        e = (d + temp1) >>> 0;
        d = c;
        c = b;
        b = a;
        a = (temp1 + temp2) >>> 0;
      }

      h0 = (h0 + a) >>> 0;
      h1 = (h1 + b) >>> 0;
      h2 = (h2 + c) >>> 0;
      h3 = (h3 + d) >>> 0;
      h4 = (h4 + e) >>> 0;
      h5 = (h5 + f) >>> 0;
      h6 = (h6 + g) >>> 0;
      h7 = (h7 + hh) >>> 0;
    }

    const result = new DataView(hash.buffer);
    result.setUint32(0, h0, false);
    result.setUint32(4, h1, false);
    result.setUint32(8, h2, false);
    result.setUint32(12, h3, false);
    result.setUint32(16, h4, false);
    result.setUint32(20, h5, false);
    result.setUint32(24, h6, false);
    result.setUint32(28, h7, false);

    return hash;
  }

  /**
   * Convert hex string to Uint8Array
   */
  private hexToBytes(hex: string): Uint8Array {
    const cleanHex = hex.startsWith('0x') ? hex.slice(2) : hex;
    const bytes = new Uint8Array(cleanHex.length / 2);
    for (let i = 0; i < bytes.length; i++) {
      bytes[i] = parseInt(cleanHex.substr(i * 2, 2), 16);
    }
    return bytes;
  }

  /**
   * Convert Uint8Array to hex string
   */
  private bytesToHex(bytes: Uint8Array): string {
    return (
      '0x' +
      Array.from(bytes)
        .map((b) => b.toString(16).padStart(2, '0'))
        .join('')
    );
  }
}

// ============ Contract Integration Helpers ============

/**
 * Prepare key registration data for FIDOVerifier.registerKey()
 */
export function prepareKeyRegistration(credential: RegisteredCredential): {
  credentialId: string;
  publicKeyX: string;
  publicKeyY: string;
  attestation: string;
} {
  return {
    credentialId: credential.credentialIdHex,
    publicKeyX: credential.publicKeyX,
    publicKeyY: credential.publicKeyY,
    attestation: credential.attestation
      ? '0x' +
        Array.from(new Uint8Array(credential.attestation))
          .map((b) => b.toString(16).padStart(2, '0'))
          .join('')
      : '0x',
  };
}

/**
 * Prepare assertion data for FIDOVerifier.verifyAssertion()
 */
export function prepareAssertionVerification(assertion: SignedAssertion): {
  authenticatorData: string;
  clientDataJSON: string;
  signature: string;
} {
  return {
    authenticatorData: assertion.authenticatorDataHex,
    clientDataJSON: assertion.clientDataJSONHex,
    signature: assertion.signatureHex,
  };
}

// ============ Exports ============

export const fido2 = {
  create: (config: FIDO2Config) => new FIDO2SDK(config),
  prepareKeyRegistration,
  prepareAssertionVerification,
};

// Example usage
export async function exampleUsage() {
  console.log('=== FIDO2/WebAuthn Example ===\n');

  // Check support
  const sdk = new FIDO2SDK({
    rpId: 'localhost',
    rpName: 'NatLangChain Test',
  });

  if (!sdk.isSupported()) {
    console.log('WebAuthn not supported in this environment');
    console.log('Run this in a browser with HTTPS or localhost');
    return;
  }

  console.log('WebAuthn is supported!');

  const hasPlatform = await sdk.isPlatformAuthenticatorAvailable();
  console.log('Platform authenticator available:', hasPlatform);

  console.log('\nTo register a key:');
  console.log('  const credential = await sdk.registerKey("0x1234...");');

  console.log('\nTo sign an action:');
  console.log('  const assertion = await sdk.signAcceptProposal(123);');

  console.log('\nTo prepare for contract call:');
  console.log('  const data = prepareAssertionVerification(assertion);');
}

if (typeof require !== 'undefined' && require.main === module) {
  exampleUsage();
}
