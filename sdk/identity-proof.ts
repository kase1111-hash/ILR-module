/**
 * NatLangChain Identity Proof SDK
 *
 * This SDK provides utilities for generating and verifying ZK proofs of identity
 * for privacy-preserving dispute participation in the ILRM protocol.
 *
 * Key Features:
 * - Generate identity secrets from private keys
 * - Compute Poseidon hashes (compatible with on-chain verification)
 * - Generate Groth16 proofs using snarkjs
 * - Format proofs for on-chain submission
 *
 * Usage:
 * ```typescript
 * import { IdentityProofSDK } from './identity-proof';
 *
 * const sdk = new IdentityProofSDK('./circuits/prove_identity.wasm', './circuits/prove_identity.zkey');
 *
 * // Generate identity
 * const identity = await sdk.generateIdentity(privateKey, salt);
 *
 * // Generate proof
 * const proof = await sdk.generateProof(identity.secret, identity.hash);
 *
 * // Submit to contract
 * await ilrm.acceptProposalWithZKProof(disputeId, proof.solidityProof, identity.hash);
 * ```
 */

// NOTE: These imports require installing the following packages:
// npm install snarkjs circomlibjs ethers

// Types for the SDK
export interface IdentityData {
  secret: bigint;
  hash: bigint;
  hashBytes32: string;
}

export interface ProofData {
  proof: {
    pi_a: [bigint, bigint];
    pi_b: [[bigint, bigint], [bigint, bigint]];
    pi_c: [bigint, bigint];
  };
  publicSignals: bigint[];
}

export interface SolidityProof {
  a: [string, string];
  b: [[string, string], [string, string]];
  c: [string, string];
}

export interface ProofForContract {
  solidityProof: SolidityProof;
  publicSignals: {
    identityManager: string;
  };
}

/**
 * Main SDK class for ZK identity proof operations
 */
export class IdentityProofSDK {
  private wasmPath: string;
  private zkeyPath: string;
  private poseidon: any;
  private snarkjs: any;
  private initialized: boolean = false;

  /**
   * Create a new IdentityProofSDK instance
   * @param wasmPath Path to the compiled circuit WASM file
   * @param zkeyPath Path to the proving key (from trusted setup)
   */
  constructor(wasmPath: string, zkeyPath: string) {
    this.wasmPath = wasmPath;
    this.zkeyPath = zkeyPath;
  }

  /**
   * Initialize the SDK (loads Poseidon and snarkjs)
   * Must be called before using other methods
   */
  async initialize(): Promise<void> {
    if (this.initialized) return;

    // Dynamic imports for Node.js/browser compatibility
    const circomlibjs = await import('circomlibjs');
    this.snarkjs = await import('snarkjs');

    // Build Poseidon hash function
    this.poseidon = await circomlibjs.buildPoseidon();

    this.initialized = true;
  }

  /**
   * Ensure SDK is initialized
   */
  private ensureInitialized(): void {
    if (!this.initialized) {
      throw new Error('SDK not initialized. Call initialize() first.');
    }
  }

  /**
   * Generate an identity from a private key and salt
   * @param privateKey User's private key (or derived secret)
   * @param salt Random salt for additional entropy
   * @returns Identity data including secret and hash
   */
  async generateIdentity(privateKey: string, salt: string): Promise<IdentityData> {
    this.ensureInitialized();

    // Combine private key and salt to create the identity secret
    // In production, use a proper KDF (Key Derivation Function)
    const ethers = await import('ethers');
    const combined = ethers.keccak256(
      ethers.concat([
        ethers.toUtf8Bytes(privateKey),
        ethers.toUtf8Bytes(salt),
      ])
    );

    // Convert to field element (must be < SNARK_SCALAR_FIELD)
    const secret = BigInt(combined) % BigInt(
      '21888242871839275222246405745257275088548364400416034343698204186575808495617'
    );

    // Compute Poseidon hash
    const hash = this.poseidonHash([secret]);

    return {
      secret,
      hash,
      hashBytes32: '0x' + hash.toString(16).padStart(64, '0'),
    };
  }

  /**
   * Compute Poseidon hash of inputs
   * @param inputs Array of bigint inputs
   * @returns Hash as bigint
   */
  poseidonHash(inputs: bigint[]): bigint {
    this.ensureInitialized();

    const hash = this.poseidon(inputs.map((x) => this.poseidon.F.e(x)));
    return this.poseidon.F.toObject(hash);
  }

  /**
   * Generate a ZK proof of identity
   * @param identitySecret The private identity secret
   * @param identityManager The public identity hash (on-chain)
   * @returns Proof data for verification
   */
  async generateProof(
    identitySecret: bigint,
    identityManager: bigint
  ): Promise<ProofForContract> {
    this.ensureInitialized();

    // Prepare circuit inputs
    const input = {
      identitySecret: identitySecret.toString(),
      identityManager: identityManager.toString(),
    };

    // Generate the proof
    const { proof, publicSignals } = await this.snarkjs.groth16.fullProve(
      input,
      this.wasmPath,
      this.zkeyPath
    );

    // Format for Solidity
    const solidityProof = this.formatProofForSolidity(proof);

    return {
      solidityProof,
      publicSignals: {
        identityManager: '0x' + BigInt(publicSignals[0]).toString(16).padStart(64, '0'),
      },
    };
  }

  /**
   * Format snarkjs proof for Solidity contract
   * @param proof Raw proof from snarkjs
   * @returns Solidity-compatible proof format
   */
  private formatProofForSolidity(proof: any): SolidityProof {
    return {
      a: [proof.pi_a[0], proof.pi_a[1]],
      b: [
        [proof.pi_b[0][1], proof.pi_b[0][0]], // Note: reversed order for Solidity
        [proof.pi_b[1][1], proof.pi_b[1][0]],
      ],
      c: [proof.pi_c[0], proof.pi_c[1]],
    };
  }

  /**
   * Verify a proof locally (for testing)
   * @param proof The proof to verify
   * @param publicSignals The public signals
   * @param vkeyPath Path to verification key JSON
   * @returns True if proof is valid
   */
  async verifyProofLocally(
    proof: any,
    publicSignals: string[],
    vkeyPath: string
  ): Promise<boolean> {
    this.ensureInitialized();

    const fs = await import('fs');
    const vkey = JSON.parse(fs.readFileSync(vkeyPath, 'utf8'));

    return await this.snarkjs.groth16.verify(vkey, publicSignals, proof);
  }

  /**
   * Export verification key for contract deployment
   * @param vkeyPath Path to verification key JSON
   * @returns Constructor arguments for IdentityVerifier contract
   */
  async exportVerificationKeyForContract(vkeyPath: string): Promise<{
    alpha: [string, string];
    beta: [[string, string], [string, string]];
    gamma: [[string, string], [string, string]];
    delta: [[string, string], [string, string]];
    ic: [string, string][];
  }> {
    const fs = await import('fs');
    const vkey = JSON.parse(fs.readFileSync(vkeyPath, 'utf8'));

    return {
      alpha: [vkey.vk_alpha_1[0], vkey.vk_alpha_1[1]],
      beta: [
        [vkey.vk_beta_2[0][1], vkey.vk_beta_2[0][0]],
        [vkey.vk_beta_2[1][1], vkey.vk_beta_2[1][0]],
      ],
      gamma: [
        [vkey.vk_gamma_2[0][1], vkey.vk_gamma_2[0][0]],
        [vkey.vk_gamma_2[1][1], vkey.vk_gamma_2[1][0]],
      ],
      delta: [
        [vkey.vk_delta_2[0][1], vkey.vk_delta_2[0][0]],
        [vkey.vk_delta_2[1][1], vkey.vk_delta_2[1][0]],
      ],
      ic: vkey.IC.map((ic: string[]) => [ic[0], ic[1]]),
    };
  }
}

/**
 * Helper function to generate a random salt
 * @returns Random 32-byte hex string
 */
export function generateRandomSalt(): string {
  if (typeof window !== 'undefined' && window.crypto) {
    // Browser
    const array = new Uint8Array(32);
    window.crypto.getRandomValues(array);
    return Array.from(array, (b) => b.toString(16).padStart(2, '0')).join('');
  } else {
    // Node.js
    const crypto = require('crypto');
    return crypto.randomBytes(32).toString('hex');
  }
}

/**
 * Helper to compute identity hash without full SDK (for contract interaction)
 * Uses keccak256 as a fallback when Poseidon is not available
 */
export async function computeIdentityHashFallback(
  privateKey: string,
  salt: string
): Promise<string> {
  const ethers = await import('ethers');

  // This is a simplified version - in production, use Poseidon
  const combined = ethers.keccak256(
    ethers.concat([
      ethers.toUtf8Bytes(privateKey),
      ethers.toUtf8Bytes(salt),
    ])
  );

  return combined;
}

// Export types for TypeScript users
export type { IdentityData, ProofData, SolidityProof, ProofForContract };

/**
 * Example usage and testing
 */
export async function exampleUsage() {
  console.log('=== NatLangChain Identity Proof SDK Example ===\n');

  // Initialize SDK
  const sdk = new IdentityProofSDK(
    './circuits/prove_identity_js/prove_identity.wasm',
    './circuits/prove_identity.zkey'
  );

  try {
    await sdk.initialize();
    console.log('SDK initialized successfully\n');

    // Generate identity
    const privateKey = 'my-secret-private-key';
    const salt = generateRandomSalt();

    console.log('Generating identity...');
    const identity = await sdk.generateIdentity(privateKey, salt);
    console.log('Identity secret:', identity.secret.toString().slice(0, 20) + '...');
    console.log('Identity hash:', identity.hashBytes32);
    console.log();

    // Generate proof
    console.log('Generating ZK proof...');
    const proofData = await sdk.generateProof(identity.secret, identity.hash);
    console.log('Proof generated successfully!');
    console.log('Public signal (identityManager):', proofData.publicSignals.identityManager);
    console.log();

    // Format for contract call
    console.log('Solidity proof format:');
    console.log(JSON.stringify(proofData.solidityProof, null, 2));

  } catch (error) {
    console.error('Error:', error);
    console.log('\nNote: This example requires compiled circuit files.');
    console.log('Run the following to compile:');
    console.log('  cd circuits');
    console.log('  circom prove_identity.circom --r1cs --wasm --sym');
    console.log('  snarkjs groth16 setup prove_identity.r1cs pot12_final.ptau prove_identity.zkey');
  }
}

// Run example if executed directly
if (require.main === module) {
  exampleUsage();
}
