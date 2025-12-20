// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/**
 * @title IIdentityVerifier
 * @notice Interface for ZK identity proof verification
 * @dev Verifies Groth16 proofs generated from prove_identity.circom
 *
 * The verifier enables privacy-preserving dispute participation:
 * - Users prove they are a party to a dispute without revealing their address
 * - Proofs are bound to specific disputes and actions to prevent replay
 * - On-chain verification is gas-efficient (~200k gas)
 */
interface IIdentityVerifier {
    // ============ Structs ============

    /**
     * @notice Groth16 proof components
     * @dev Standard format for snarkjs-generated proofs
     */
    struct Proof {
        uint256[2] a;      // G1 point
        uint256[2][2] b;   // G2 point
        uint256[2] c;      // G1 point
    }

    /**
     * @notice Public signals for identity proof
     * @dev Must match the public signals in the Circom circuit
     */
    struct IdentityPublicSignals {
        uint256 identityManager;  // Hash stored on-chain (public)
    }

    /**
     * @notice Extended public signals including dispute binding
     */
    struct DisputeIdentitySignals {
        uint256 identityManager;  // Hash stored on-chain
        uint256 disputeId;        // Dispute this proof is for
        uint256 expectedRole;     // 0 = initiator, 1 = counterparty
    }

    /**
     * @notice Public signals with nonce for replay protection
     */
    struct NonceIdentitySignals {
        uint256 identityManager;    // Hash stored on-chain
        uint256 nonce;              // Proof nonce (incremented per use)
        uint256 action;             // Action being authorized
        uint256 actionCommitment;   // Output from circuit
    }

    // ============ Events ============

    /**
     * @notice Emitted when an identity proof is verified
     */
    event IdentityProofVerified(
        uint256 indexed disputeId,
        bytes32 indexed identityHash,
        address indexed verifier
    );

    /**
     * @notice Emitted when verification keys are updated
     */
    event VerificationKeyUpdated(bytes32 indexed keyHash);

    // ============ Errors ============

    error InvalidProof();
    error InvalidPublicSignals();
    error ProofAlreadyUsed(bytes32 proofHash);
    error NonceTooLow(uint256 expected, uint256 provided);

    // ============ Core Functions ============

    /**
     * @notice Verify a basic identity proof
     * @param proof The Groth16 proof
     * @param signals Public signals (identityManager)
     * @return valid True if proof is valid
     */
    function verifyIdentityProof(
        Proof calldata proof,
        IdentityPublicSignals calldata signals
    ) external view returns (bool valid);

    /**
     * @notice Verify identity proof bound to a dispute
     * @param proof The Groth16 proof
     * @param signals Public signals including dispute binding
     * @return valid True if proof is valid
     */
    function verifyDisputeIdentityProof(
        Proof calldata proof,
        DisputeIdentitySignals calldata signals
    ) external view returns (bool valid);

    /**
     * @notice Verify identity proof with nonce (replay protection)
     * @dev Consumes the nonce - proof cannot be reused
     * @param proof The Groth16 proof
     * @param signals Public signals including nonce
     * @return valid True if proof is valid
     */
    function verifyNoncedIdentityProof(
        Proof calldata proof,
        NonceIdentitySignals calldata signals
    ) external returns (bool valid);

    /**
     * @notice Get the current nonce for an identity hash
     * @param identityHash The identity manager hash
     * @return Current nonce value
     */
    function getNonce(bytes32 identityHash) external view returns (uint256);

    /**
     * @notice Check if a proof has been used (for replay detection)
     * @param proofHash Hash of the proof
     * @return True if proof has been used
     */
    function isProofUsed(bytes32 proofHash) external view returns (bool);
}
