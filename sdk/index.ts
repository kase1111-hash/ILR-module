/**
 * NatLangChain ILRM - SDK
 *
 * Client-side SDK for interacting with the ILRM Protocol.
 * Provides cryptographic utilities, identity management, and security integrations.
 */

// ============================================================================
// Cryptographic Utilities
// ============================================================================

// ECIES encryption/decryption
export * from './ecies';

// Shamir Secret Sharing
export * from './shamir';

// Threshold BLS signatures
export * from './threshold-bls';

// Identity proofs
export * from './identity-proof';

// Viewing keys for encrypted data access
export * from './viewing-keys';

// FIDO2/WebAuthn integration
export * from './fido2';

// ============================================================================
// Security Module
// ============================================================================

// Full security module with SIEM and Daemon integration
export * as security from './security';

// Convenience re-exports of commonly used security items
export {
  initializeSecurity,
  shutdownSecurity,
  getSecurityManager,
  SecurityManager,
  handleError,
  ILRMError,
  Severity,
  PolicyDecision,
} from './security';

// ============================================================================
// Type Definitions
// ============================================================================

export * from './types';
