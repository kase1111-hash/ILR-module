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

    // User ID from Ethereum address - create fresh Uint8Array for proper typing
    const userIdRaw = this.hexToBytes(userAddress);
    const userId = new Uint8Array(userIdRaw.length);
    userId.set(userIdRaw);

    const publicKeyCredentialCreationOptions: PublicKeyCredentialCreationOptions = {
      challenge: new Uint8Array(challenge),
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
    const challengeRaw = await this.generateActionChallenge(action, data);
    const challenge = new Uint8Array(challengeRaw);

    // Create properly typed credential ID if provided
    let allowCredentials: PublicKeyCredentialDescriptor[] | undefined;
    if (credentialId) {
      const credId = new Uint8Array(credentialId.length);
      credId.set(credentialId);
      allowCredentials = [{ id: credId, type: 'public-key' }];
    }

    const publicKeyCredentialRequestOptions: PublicKeyCredentialRequestOptions = {
      challenge,
      rpId: this.config.rpId,
      timeout: this.config.timeout,
      userVerification: this.config.userVerification,
      allowCredentials,
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
   * Uses platform Web Crypto API for secure SHA-256 hashing
   */
  private async generateActionChallenge(action: string, data: ActionData): Promise<Uint8Array> {
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

    // Hash using platform Web Crypto API (preferred over custom implementation)
    return this.sha256Async(combined);
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
   * SHA-256 hash using Web Crypto API (preferred)
   * Uses the platform's native implementation for security and performance
   */
  private async sha256Async(data: Uint8Array): Promise<Uint8Array> {
    // Use Web Crypto API - available in all modern browsers
    if (typeof crypto !== 'undefined' && crypto.subtle) {
      // Create proper ArrayBuffer copy to satisfy TypeScript's strict typing
      const dataBuffer = new Uint8Array(data).buffer;
      const hashBuffer = await crypto.subtle.digest('SHA-256', dataBuffer);
      return new Uint8Array(hashBuffer);
    }

    // Node.js fallback using native crypto module
    const nodeCrypto = require('crypto');
    const hash = nodeCrypto.createHash('sha256');
    hash.update(data);
    return new Uint8Array(hash.digest());
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
