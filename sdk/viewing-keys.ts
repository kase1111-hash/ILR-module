/**
 * NatLangChain Viewing Keys SDK
 *
 * This SDK provides a complete solution for privacy-preserving dispute
 * metadata management with selective de-anonymization capabilities.
 *
 * Architecture:
 * 1. Dispute metadata is encrypted with a viewing key using ECIES
 * 2. The viewing key is split into m-of-n shares using Shamir's Secret Sharing
 * 3. Shares are distributed to trusted parties (user, DAO, auditors)
 * 4. On-chain escrow contract manages reveal requests and voting
 * 5. Threshold of parties must approve before key can be reconstructed
 *
 * This creates a "no honeypot" design with full audit trail.
 *
 * Usage:
 * ```typescript
 * import { ViewingKeysSDK } from './viewing-keys';
 *
 * const sdk = new ViewingKeysSDK(provider, escrowContractAddress);
 *
 * // Create escrow with encrypted metadata
 * const result = await sdk.createEscrow({
 *   disputeId: 123,
 *   metadata: { ... },
 *   holders: [...],
 *   threshold: 3,
 * });
 *
 * // Later: request reveal for compliance
 * const requestId = await sdk.requestReveal(escrowId, 'Legal subpoena');
 *
 * // Holders vote and submit shares
 * await sdk.voteOnReveal(requestId, true);
 * await sdk.submitShare(requestId, myShare);
 *
 * // Reconstruct and decrypt
 * const decrypted = await sdk.reconstructAndDecrypt(requestId, shares);
 * ```
 */

import { ECIES, ECIESCiphertext, ECIESKeyPair } from './ecies';
import { ShamirSecretSharing, Share, EncodedShare } from './shamir';

// Types
export interface HolderInfo {
  address: string;
  publicKey: string;  // For encrypting their share
  type: HolderType;
}

export enum HolderType {
  User = 0,
  DAO = 1,
  Auditor = 2,
  LegalCounsel = 3,
  Regulator = 4,
}

export interface CreateEscrowParams {
  disputeId: number;
  metadata: object;           // Dispute metadata to encrypt
  holders: HolderInfo[];      // Share holders with their public keys
  threshold: number;          // Required shares for reconstruction (m)
  ipfsClient?: any;           // Optional IPFS client for storage
}

export interface EscrowResult {
  escrowId: number;
  viewingKeyCommitment: string;
  encryptedDataHash: string;
  encryptedShares: { address: string; encryptedShare: ECIESCiphertext }[];
  viewingKey: string;         // Only returned to creator, should be discarded after share distribution
}

export interface RevealData {
  metadata: object;
  reconstructedKeyHash: string;
}

/**
 * Main SDK class for viewing key management
 */
export class ViewingKeysSDK {
  private ecies: ECIES;
  private shamir: ShamirSecretSharing;
  private provider: any;
  private escrowAddress: string;
  private escrowContract: any;

  /**
   * Create a new ViewingKeysSDK instance
   * @param provider Ethereum provider (ethers.js provider)
   * @param escrowAddress ComplianceEscrow contract address
   */
  constructor(provider: any, escrowAddress: string) {
    this.ecies = new ECIES();
    this.shamir = new ShamirSecretSharing();
    this.provider = provider;
    this.escrowAddress = escrowAddress;
  }

  /**
   * Initialize the contract connection
   */
  async initialize(): Promise<void> {
    const { Contract } = await import('ethers');

    const abi = [
      'function createEscrow(uint256 disputeId, bytes32 viewingKeyCommitment, bytes32 encryptedDataHash, uint8 threshold, uint8 totalShares, address[] holders, uint8[] holderTypes) returns (uint256)',
      'function submitShareCommitment(uint256 escrowId, bytes32 shareCommitment)',
      'function requestReveal(uint256 escrowId, string reason, bytes32 legalDocHash, uint256 votingPeriod) returns (uint256)',
      'function voteOnReveal(uint256 requestId, bool approve)',
      'function submitShareForReveal(uint256 requestId, uint256 shareIndex, bytes encryptedShare)',
      'function finalizeReveal(uint256 requestId, bytes32 reconstructedKeyHash)',
      'function getEscrow(uint256 escrowId) view returns (tuple(uint256 disputeId, bytes32 viewingKeyCommitment, bytes32 encryptedDataHash, uint8 threshold, uint8 totalShares, uint256 createdAt, bool revealed))',
      'function getShareHolders(uint256 escrowId) view returns (tuple(address holder, uint8 holderType, bytes32 shareCommitment, bool hasSubmitted)[])',
      'function getRevealRequest(uint256 requestId) view returns (tuple(uint256 escrowId, address requester, string reason, bytes32 legalDocHash, uint256 requestedAt, uint256 expiresAt, uint8 status, uint256 approvalsReceived, uint256 rejectionsReceived))',
      'function isShareHolder(uint256 escrowId, address holder) view returns (bool)',
      'function getSubmittedShareCount(uint256 requestId) view returns (uint256)',
      'function isThresholdMet(uint256 requestId) view returns (bool)',
      'event EscrowCreated(uint256 indexed escrowId, uint256 indexed disputeId, bytes32 viewingKeyCommitment, uint8 threshold, uint8 totalShares)',
      'event RevealRequested(uint256 indexed requestId, uint256 indexed escrowId, address indexed requester, string reason)',
      'event KeyReconstructed(uint256 indexed requestId, uint256 indexed escrowId, bytes32 reconstructedKeyHash)',
    ];

    this.escrowContract = new Contract(this.escrowAddress, abi, this.provider);
  }

  /**
   * Create a new viewing key escrow for dispute metadata
   *
   * @param params Escrow creation parameters
   * @returns Escrow result including encrypted shares for distribution
   */
  async createEscrow(params: CreateEscrowParams): Promise<EscrowResult> {
    const { disputeId, metadata, holders, threshold, ipfsClient } = params;

    // 1. Generate viewing key
    const viewingKeyBytes = this.generateRandomBytes(32);
    const viewingKey = this.bytesToHex(viewingKeyBytes);

    // 2. Encrypt metadata with viewing key
    const metadataJson = JSON.stringify(metadata);
    const encryptedMetadata = await this.encryptWithViewingKey(
      viewingKeyBytes,
      new TextEncoder().encode(metadataJson)
    );

    // 3. Store encrypted data (IPFS or return hash)
    let encryptedDataHash: string;
    if (ipfsClient) {
      const cid = await ipfsClient.add(JSON.stringify(encryptedMetadata));
      encryptedDataHash = this.cidToBytes32(cid.path);
    } else {
      // Use keccak256 of the encrypted data as hash
      const ethers = await import('ethers');
      encryptedDataHash = ethers.keccak256(
        ethers.toUtf8Bytes(JSON.stringify(encryptedMetadata))
      );
    }

    // 4. Split viewing key into shares
    const shares = this.shamir.split(viewingKeyBytes, holders.length, threshold);

    // 5. Encrypt each share to its holder's public key
    const encryptedShares: { address: string; encryptedShare: ECIESCiphertext }[] = [];

    for (let i = 0; i < holders.length; i++) {
      const holder = holders[i];
      const share = shares[i];

      // Encode share for encryption
      const shareData = new Uint8Array(1 + share.data.length);
      shareData[0] = share.index;
      shareData.set(share.data, 1);

      // Encrypt to holder's public key
      const encryptedShare = await this.ecies.encrypt(holder.publicKey, shareData);

      encryptedShares.push({
        address: holder.address,
        encryptedShare,
      });
    }

    // 6. Compute viewing key commitment (Pedersen-like)
    const viewingKeyCommitment = await this.computeCommitment(viewingKeyBytes);

    // 7. Create escrow on-chain (if signer available)
    let escrowId = 0;
    if (this.escrowContract.runner?.sendTransaction) {
      const signer = this.escrowContract.runner;
      const contract = this.escrowContract.connect(signer);

      const holderAddresses = holders.map((h) => h.address);
      const holderTypes = holders.map((h) => h.type);

      const tx = await contract.createEscrow(
        disputeId,
        viewingKeyCommitment,
        encryptedDataHash,
        threshold,
        holders.length,
        holderAddresses,
        holderTypes
      );

      const receipt = await tx.wait();

      // Parse escrowId from event
      const event = receipt.logs.find(
        (log: any) => log.topics[0] === this.escrowContract.interface.getEvent('EscrowCreated').topicHash
      );
      if (event) {
        const decoded = this.escrowContract.interface.parseLog(event);
        escrowId = Number(decoded.args.escrowId);
      }
    }

    return {
      escrowId,
      viewingKeyCommitment,
      encryptedDataHash,
      encryptedShares,
      viewingKey, // Caller should securely distribute and then discard
    };
  }

  /**
   * Submit share commitment to prove possession
   *
   * @param escrowId The escrow ID
   * @param share The holder's decrypted share
   */
  async submitShareCommitment(escrowId: number, share: Share): Promise<string> {
    const commitment = await this.shamir.generateShareCommitment(share);

    if (this.escrowContract.runner?.sendTransaction) {
      const signer = this.escrowContract.runner;
      const contract = this.escrowContract.connect(signer);

      const tx = await contract.submitShareCommitment(escrowId, commitment);
      await tx.wait();
    }

    return commitment;
  }

  /**
   * Request to reveal a viewing key
   *
   * @param escrowId The escrow to reveal
   * @param reason Legal/compliance reason
   * @param legalDocHash Hash of supporting documentation
   * @param votingPeriodDays Voting period in days
   * @returns Request ID
   */
  async requestReveal(
    escrowId: number,
    reason: string,
    legalDocHash: string,
    votingPeriodDays: number = 7
  ): Promise<number> {
    const votingPeriodSeconds = votingPeriodDays * 24 * 60 * 60;

    if (this.escrowContract.runner?.sendTransaction) {
      const signer = this.escrowContract.runner;
      const contract = this.escrowContract.connect(signer);

      const tx = await contract.requestReveal(
        escrowId,
        reason,
        legalDocHash,
        votingPeriodSeconds
      );

      const receipt = await tx.wait();

      // Parse requestId from event
      const event = receipt.logs.find(
        (log: any) => log.topics[0] === this.escrowContract.interface.getEvent('RevealRequested').topicHash
      );
      if (event) {
        const decoded = this.escrowContract.interface.parseLog(event);
        return Number(decoded.args.requestId);
      }
    }

    return 0;
  }

  /**
   * Vote on a reveal request
   *
   * @param requestId The request to vote on
   * @param approve True to approve, false to reject
   */
  async voteOnReveal(requestId: number, approve: boolean): Promise<void> {
    if (this.escrowContract.runner?.sendTransaction) {
      const signer = this.escrowContract.runner;
      const contract = this.escrowContract.connect(signer);

      const tx = await contract.voteOnReveal(requestId, approve);
      await tx.wait();
    }
  }

  /**
   * Submit decrypted share for reveal (after approval)
   *
   * @param requestId The approved request
   * @param share The holder's share
   * @param coordinatorPublicKey Public key of the coordinator collecting shares
   */
  async submitShare(
    requestId: number,
    share: Share,
    coordinatorPublicKey: string
  ): Promise<void> {
    // Encrypt share to coordinator
    const shareData = new Uint8Array(1 + share.data.length);
    shareData[0] = share.index;
    shareData.set(share.data, 1);

    const encryptedShare = await this.ecies.encrypt(coordinatorPublicKey, shareData);

    if (this.escrowContract.runner?.sendTransaction) {
      const signer = this.escrowContract.runner;
      const contract = this.escrowContract.connect(signer);

      const tx = await contract.submitShareForReveal(
        requestId,
        share.index - 1, // Contract uses 0-indexed
        JSON.stringify(encryptedShare)
      );
      await tx.wait();
    }
  }

  /**
   * Reconstruct viewing key from shares and decrypt metadata
   * (Called by coordinator after collecting threshold shares)
   *
   * @param shares Collected shares
   * @param encryptedMetadata The encrypted metadata
   * @returns Decrypted metadata
   */
  async reconstructAndDecrypt(
    shares: Share[],
    encryptedMetadata: { iv: string; ciphertext: string; authTag: string }
  ): Promise<RevealData> {
    // Reconstruct viewing key
    const viewingKeyBytes = this.shamir.combine(shares);
    const viewingKey = this.bytesToHex(viewingKeyBytes);

    // Decrypt metadata
    const decrypted = await this.decryptWithViewingKey(viewingKeyBytes, encryptedMetadata);
    const metadataJson = new TextDecoder().decode(decrypted);
    const metadata = JSON.parse(metadataJson);

    // Compute hash for on-chain verification
    const ethers = await import('ethers');
    const reconstructedKeyHash = ethers.keccak256(viewingKeyBytes);

    return {
      metadata,
      reconstructedKeyHash,
    };
  }

  /**
   * Finalize reveal on-chain
   *
   * @param requestId The request being finalized
   * @param reconstructedKeyHash Hash of reconstructed key for verification
   */
  async finalizeReveal(requestId: number, reconstructedKeyHash: string): Promise<void> {
    if (this.escrowContract.runner?.sendTransaction) {
      const signer = this.escrowContract.runner;
      const contract = this.escrowContract.connect(signer);

      const tx = await contract.finalizeReveal(requestId, reconstructedKeyHash);
      await tx.wait();
    }
  }

  /**
   * Decrypt a holder's encrypted share
   *
   * @param privateKey Holder's private key
   * @param encryptedShare The encrypted share received during escrow creation
   * @returns The decrypted share
   */
  async decryptShare(privateKey: string, encryptedShare: ECIESCiphertext): Promise<Share> {
    const decrypted = await this.ecies.decrypt(privateKey, encryptedShare);

    return {
      index: decrypted[0],
      data: decrypted.slice(1),
    };
  }

  // ============ View Functions ============

  /**
   * Get escrow details
   */
  async getEscrow(escrowId: number): Promise<any> {
    return await this.escrowContract.getEscrow(escrowId);
  }

  /**
   * Get share holders for an escrow
   */
  async getShareHolders(escrowId: number): Promise<any[]> {
    return await this.escrowContract.getShareHolders(escrowId);
  }

  /**
   * Get reveal request details
   */
  async getRevealRequest(requestId: number): Promise<any> {
    return await this.escrowContract.getRevealRequest(requestId);
  }

  /**
   * Check if threshold is met for a request
   */
  async isThresholdMet(requestId: number): Promise<boolean> {
    return await this.escrowContract.isThresholdMet(requestId);
  }

  // ============ Private Helper Methods ============

  /**
   * Encrypt data with viewing key using AES-256-GCM
   */
  private async encryptWithViewingKey(
    key: Uint8Array,
    data: Uint8Array
  ): Promise<{ iv: string; ciphertext: string; authTag: string }> {
    const iv = this.generateRandomBytes(12);

    if (typeof crypto !== 'undefined' && crypto.subtle) {
      // Create proper ArrayBuffer copies to satisfy TypeScript's strict typing
      const keyBuffer = new Uint8Array(key).buffer;
      const ivBuffer = new Uint8Array(iv).buffer;
      const dataBuffer = new Uint8Array(data).buffer;

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
        dataBuffer
      );

      const resultBytes = new Uint8Array(result);
      const ciphertext = resultBytes.slice(0, -16);
      const authTag = resultBytes.slice(-16);

      return {
        iv: this.bytesToHex(iv),
        ciphertext: this.bytesToHex(ciphertext),
        authTag: this.bytesToHex(authTag),
      };
    }

    // Node.js fallback
    const nodeCrypto = await import('crypto');
    const cipher = nodeCrypto.createCipheriv('aes-256-gcm', key, iv);
    const ciphertext = Buffer.concat([cipher.update(data), cipher.final()]);
    const authTag = cipher.getAuthTag();

    return {
      iv: this.bytesToHex(iv),
      ciphertext: this.bytesToHex(new Uint8Array(ciphertext)),
      authTag: this.bytesToHex(new Uint8Array(authTag)),
    };
  }

  /**
   * Decrypt data with viewing key
   */
  private async decryptWithViewingKey(
    key: Uint8Array,
    encrypted: { iv: string; ciphertext: string; authTag: string }
  ): Promise<Uint8Array> {
    const iv = this.hexToBytes(encrypted.iv);
    const ciphertext = this.hexToBytes(encrypted.ciphertext);
    const authTag = this.hexToBytes(encrypted.authTag);

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

    // Node.js fallback
    const nodeCrypto = await import('crypto');
    const decipher = nodeCrypto.createDecipheriv('aes-256-gcm', key, iv);
    decipher.setAuthTag(authTag);
    const plaintext = Buffer.concat([decipher.update(ciphertext), decipher.final()]);

    return new Uint8Array(plaintext);
  }

  /**
   * Compute Pedersen-like commitment to viewing key
   */
  private async computeCommitment(data: Uint8Array): Promise<string> {
    const ethers = await import('ethers');
    return ethers.keccak256(data);
  }

  /**
   * Convert IPFS CID to bytes32
   */
  private cidToBytes32(cid: string): string {
    const ethers = require('ethers');
    return ethers.keccak256(ethers.toUtf8Bytes(cid));
  }

  private generateRandomBytes(length: number): Uint8Array {
    if (typeof crypto !== 'undefined' && crypto.getRandomValues) {
      const array = new Uint8Array(length);
      crypto.getRandomValues(array);
      return array;
    }
    const nodeCrypto = require('crypto');
    return new Uint8Array(nodeCrypto.randomBytes(length));
  }

  private hexToBytes(hex: string): Uint8Array {
    const cleanHex = hex.startsWith('0x') ? hex.slice(2) : hex;
    const bytes = new Uint8Array(cleanHex.length / 2);
    for (let i = 0; i < bytes.length; i++) {
      bytes[i] = parseInt(cleanHex.substring(i * 2, i * 2 + 2), 16);
    }
    return bytes;
  }

  private bytesToHex(bytes: Uint8Array): string {
    return '0x' + Array.from(bytes)
      .map((b) => b.toString(16).padStart(2, '0'))
      .join('');
  }
}

// Re-export dependencies
export { ECIES, ECIESCiphertext, ECIESKeyPair } from './ecies';
export { ShamirSecretSharing, Share, EncodedShare } from './shamir';

// Example usage
export async function exampleUsage() {
  console.log('=== Viewing Keys SDK Example ===\n');

  // Note: This example shows the flow without actual blockchain connection
  const ecies = new ECIES();
  const shamir = new ShamirSecretSharing();

  try {
    // 1. Generate key pairs for 5 holders
    console.log('Generating holder key pairs...');
    const holders: { privateKey: string; publicKey: string }[] = [];
    for (let i = 0; i < 5; i++) {
      holders.push(await ecies.generateKeyPair());
    }
    console.log(`Generated ${holders.length} holder key pairs\n`);

    // 2. Create viewing key
    const viewingKey = new Uint8Array(32);
    crypto.getRandomValues(viewingKey);
    console.log('Viewing key generated\n');

    // 3. Split into 5 shares, threshold 3
    console.log('Splitting viewing key into 5 shares (threshold: 3)...');
    const shares = shamir.split(viewingKey, 5, 3);
    console.log(`Created ${shares.length} shares\n`);

    // 4. Encrypt each share to its holder
    console.log('Encrypting shares to holders...');
    const encryptedShares: ECIESCiphertext[] = [];
    for (let i = 0; i < holders.length; i++) {
      const shareData = new Uint8Array(1 + shares[i].data.length);
      shareData[0] = shares[i].index;
      shareData.set(shares[i].data, 1);

      const encrypted = await ecies.encrypt(holders[i].publicKey, shareData);
      encryptedShares.push(encrypted);
    }
    console.log('All shares encrypted\n');

    // 5. Simulate reveal: decrypt 3 shares and reconstruct
    console.log('Simulating reveal with 3 shares...');
    const revealedShares: Share[] = [];
    const indicesToReveal = [0, 2, 4]; // First, third, fifth holder

    for (const idx of indicesToReveal) {
      const decrypted = await ecies.decrypt(holders[idx].privateKey, encryptedShares[idx]);
      revealedShares.push({
        index: decrypted[0],
        data: decrypted.slice(1),
      });
    }

    // 6. Reconstruct viewing key
    console.log('Reconstructing viewing key...');
    const reconstructed = shamir.combine(revealedShares);

    // 7. Verify
    const matches = reconstructed.every((v, i) => v === viewingKey[i]);
    if (matches) {
      console.log('\nSUCCESS: Viewing key reconstructed correctly!');
    } else {
      console.error('\nFAILED: Viewing key mismatch');
    }
  } catch (error) {
    console.error('Error:', error);
  }
}

if (require.main === module) {
  exampleUsage();
}
