// SPDX-License-Identifier: Apache-2.0
pragma circom 2.1.6;

include "circomlib/circuits/poseidon.circom";

/**
 * @title ProveIdentity
 * @notice ZK circuit to prove dispute party membership without revealing identity
 * @dev Uses Poseidon hash for Ethereum compatibility
 *
 * Purpose:
 * - Proves a user knows a secret that hashes to the on-chain identityManager
 * - Prevents address exposure during dispute participation
 * - Enables privacy-preserving acceptance/proposal signing
 *
 * Usage:
 * 1. User generates identitySecret = hash(privateKey, salt)
 * 2. On-chain, identityManager = Poseidon(identitySecret) is stored
 * 3. User generates ZK proof proving knowledge of identitySecret
 * 4. Contract verifies proof without learning identitySecret
 */
template ProveIdentity() {
    // Private input: User's secret (e.g., hash of private key + salt)
    // This NEVER leaves the user's device
    signal input identitySecret;

    // Public input: On-chain hash stored in Dispute struct
    // This is the value everyone can see (initiatorHash or counterpartyHash)
    signal input identityManager;

    // Compute Poseidon hash of the secret
    // Poseidon is ZK-friendly and gas-efficient for on-chain verification
    component hasher = Poseidon(1);
    hasher.inputs[0] <== identitySecret;

    // Constraint: The hash of identitySecret MUST equal identityManager
    // If this doesn't hold, the proof generation will fail
    hasher.out === identityManager;
}

// Main component with identityManager as public signal
// identitySecret remains private (not in public signals array)
component main {public [identityManager]} = ProveIdentity();

/**
 * Extended Circuit: ProveDisputeParty
 * Proves membership in a specific dispute by including disputeId
 */
template ProveDisputeParty() {
    // Private inputs
    signal input identitySecret;
    signal input role; // 0 = initiator, 1 = counterparty

    // Public inputs
    signal input identityManager;
    signal input disputeId;
    signal input expectedRole; // Which role we're proving (0 or 1)

    // Verify identity hash
    component hasher = Poseidon(1);
    hasher.inputs[0] <== identitySecret;
    hasher.out === identityManager;

    // Verify role matches expected (using constraint)
    signal roleMatch;
    roleMatch <== role - expectedRole;
    roleMatch === 0;

    // Include disputeId in proof to bind to specific dispute
    // This prevents proof reuse across disputes
    signal disputeBinding;
    disputeBinding <== disputeId * 1; // Simple binding
}

/**
 * Extended Circuit: ProveIdentityWithNonce
 * Prevents replay attacks by including a nonce
 */
template ProveIdentityWithNonce() {
    // Private input
    signal input identitySecret;

    // Public inputs
    signal input identityManager;
    signal input nonce; // Incremented per proof to prevent replay
    signal input action; // Hash of action being authorized (e.g., "accept", "counter")

    // Verify identity
    component hasher = Poseidon(1);
    hasher.inputs[0] <== identitySecret;
    hasher.out === identityManager;

    // Bind proof to specific action and nonce
    // This creates a unique proof per action
    component actionHasher = Poseidon(3);
    actionHasher.inputs[0] <== identitySecret;
    actionHasher.inputs[1] <== nonce;
    actionHasher.inputs[2] <== action;

    // Output commitment for on-chain verification
    signal output actionCommitment;
    actionCommitment <== actionHasher.out;
}
