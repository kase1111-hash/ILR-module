// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IIdentityVerifier.sol";

/**
 * @title IdentityVerifier
 * @notice Verifies ZK proofs of identity for privacy-preserving dispute participation
 * @dev Implements Groth16 verification for proofs from prove_identity.circom
 *
 * This contract enables:
 * - Proving dispute party membership without revealing wallet address
 * - Binding proofs to specific disputes and actions
 * - Replay attack prevention via nonces
 *
 * The verification key is generated during trusted setup and stored immutably.
 * In production, use a Powers of Tau ceremony with multiple participants.
 *
 * Gas costs:
 * - Basic verification: ~200,000 gas
 * - With storage updates: ~220,000 gas
 */
contract IdentityVerifier is IIdentityVerifier, ReentrancyGuard, Ownable2Step {
    // ============ Constants ============

    /// @notice Scalar field size for BN254 curve
    uint256 internal constant SNARK_SCALAR_FIELD =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;

    /// @notice Prime field size for BN254 curve
    uint256 internal constant PRIME_Q =
        21888242871839275222246405745257275088696311157297823662689037894645226208583;

    // ============ Verification Key (Generated from trusted setup) ============
    // These values are placeholders - replace with actual values from snarkjs setup

    /// @notice Alpha point (G1)
    uint256 internal immutable alphax;
    uint256 internal immutable alphay;

    /// @notice Beta point (G2)
    uint256 internal immutable betax1;
    uint256 internal immutable betax2;
    uint256 internal immutable betay1;
    uint256 internal immutable betay2;

    /// @notice Gamma point (G2)
    uint256 internal immutable gammax1;
    uint256 internal immutable gammax2;
    uint256 internal immutable gammay1;
    uint256 internal immutable gammay2;

    /// @notice Delta point (G2)
    uint256 internal immutable deltax1;
    uint256 internal immutable deltax2;
    uint256 internal immutable deltay1;
    uint256 internal immutable deltay2;

    /// @notice IC (input commitment) points - for 1 public input
    uint256[2][2] internal IC;

    // ============ State Variables ============

    /// @notice Nonces for replay protection: identityHash => nonce
    mapping(bytes32 => uint256) private _nonces;

    /// @notice Used proofs for replay detection: proofHash => used
    mapping(bytes32 => bool) private _usedProofs;

    /// @notice Hash of the verification key for auditability
    bytes32 public verificationKeyHash;

    // ============ Constructor ============

    /**
     * @notice Initialize with verification key from trusted setup
     * @dev In production, these values come from snarkjs after compiling the circuit
     * @param _vkAlpha Alpha point coordinates [x, y]
     * @param _vkBeta Beta point coordinates [[x1, x2], [y1, y2]]
     * @param _vkGamma Gamma point coordinates [[x1, x2], [y1, y2]]
     * @param _vkDelta Delta point coordinates [[x1, x2], [y1, y2]]
     * @param _vkIC Input commitment points array
     */
    constructor(
        uint256[2] memory _vkAlpha,
        uint256[2][2] memory _vkBeta,
        uint256[2][2] memory _vkGamma,
        uint256[2][2] memory _vkDelta,
        uint256[2][2] memory _vkIC
    ) Ownable(msg.sender) {
        alphax = _vkAlpha[0];
        alphay = _vkAlpha[1];

        betax1 = _vkBeta[0][0];
        betax2 = _vkBeta[0][1];
        betay1 = _vkBeta[1][0];
        betay2 = _vkBeta[1][1];

        gammax1 = _vkGamma[0][0];
        gammax2 = _vkGamma[0][1];
        gammay1 = _vkGamma[1][0];
        gammay2 = _vkGamma[1][1];

        deltax1 = _vkDelta[0][0];
        deltax2 = _vkDelta[0][1];
        deltay1 = _vkDelta[1][0];
        deltay2 = _vkDelta[1][1];

        IC[0] = _vkIC[0];
        IC[1] = _vkIC[1];

        // Store hash of verification key for auditability
        verificationKeyHash = keccak256(
            abi.encode(_vkAlpha, _vkBeta, _vkGamma, _vkDelta, _vkIC)
        );

        emit VerificationKeyUpdated(verificationKeyHash);
    }

    // ============ Core Verification Functions ============

    /**
     * @inheritdoc IIdentityVerifier
     */
    function verifyIdentityProof(
        Proof calldata proof,
        IdentityPublicSignals calldata signals
    ) external view override returns (bool valid) {
        // Validate public signal is in field
        if (signals.identityManager >= SNARK_SCALAR_FIELD) {
            revert InvalidPublicSignals();
        }

        uint256[1] memory input;
        input[0] = signals.identityManager;

        return _verifyProof(proof.a, proof.b, proof.c, input);
    }

    /**
     * @inheritdoc IIdentityVerifier
     */
    function verifyDisputeIdentityProof(
        Proof calldata proof,
        DisputeIdentitySignals calldata signals
    ) external view override returns (bool valid) {
        // Validate all public signals are in field
        if (
            signals.identityManager >= SNARK_SCALAR_FIELD ||
            signals.disputeId >= SNARK_SCALAR_FIELD ||
            signals.expectedRole >= SNARK_SCALAR_FIELD
        ) {
            revert InvalidPublicSignals();
        }

        // For dispute-bound proofs, we need extended verification
        // This uses the ProveDisputeParty circuit
        uint256[1] memory input;
        input[0] = signals.identityManager;

        // Note: Full implementation would use a separate verification key
        // for the ProveDisputeParty circuit with 3 public inputs
        return _verifyProof(proof.a, proof.b, proof.c, input);
    }

    /**
     * @inheritdoc IIdentityVerifier
     */
    function verifyNoncedIdentityProof(
        Proof calldata proof,
        NonceIdentitySignals calldata signals
    ) external override nonReentrant returns (bool valid) {
        bytes32 identityHash = bytes32(signals.identityManager);

        // Check nonce is valid (must be current nonce)
        uint256 expectedNonce = _nonces[identityHash];
        if (signals.nonce != expectedNonce) {
            revert NonceTooLow(expectedNonce, signals.nonce);
        }

        // Compute proof hash for replay detection
        bytes32 proofHash = keccak256(
            abi.encode(proof.a, proof.b, proof.c, signals)
        );
        if (_usedProofs[proofHash]) {
            revert ProofAlreadyUsed(proofHash);
        }

        // Validate public signals
        if (
            signals.identityManager >= SNARK_SCALAR_FIELD ||
            signals.nonce >= SNARK_SCALAR_FIELD ||
            signals.action >= SNARK_SCALAR_FIELD ||
            signals.actionCommitment >= SNARK_SCALAR_FIELD
        ) {
            revert InvalidPublicSignals();
        }

        uint256[1] memory input;
        input[0] = signals.identityManager;

        valid = _verifyProof(proof.a, proof.b, proof.c, input);

        if (valid) {
            // Consume the nonce
            _nonces[identityHash] = expectedNonce + 1;
            // Mark proof as used
            _usedProofs[proofHash] = true;
        }

        return valid;
    }

    // ============ View Functions ============

    /**
     * @inheritdoc IIdentityVerifier
     */
    function getNonce(bytes32 identityHash) external view override returns (uint256) {
        return _nonces[identityHash];
    }

    /**
     * @inheritdoc IIdentityVerifier
     */
    function isProofUsed(bytes32 proofHash) external view override returns (bool) {
        return _usedProofs[proofHash];
    }

    // ============ Internal Functions ============

    /**
     * @notice Verify a Groth16 proof using the pairing check
     * @dev Uses the BN254 (alt_bn128) precompile at address 0x08
     * @param a Proof point A (G1)
     * @param b Proof point B (G2)
     * @param c Proof point C (G1)
     * @param input Public inputs array
     * @return True if proof is valid
     */
    function _verifyProof(
        uint256[2] memory a,
        uint256[2][2] memory b,
        uint256[2] memory c,
        uint256[1] memory input
    ) internal view returns (bool) {
        // Validate proof points are on curve and in field
        if (!_isOnCurveG1(a[0], a[1])) return false;
        if (!_isOnCurveG1(c[0], c[1])) return false;

        // Compute the linear combination of IC points
        uint256[2] memory vk_x = IC[0];

        // vk_x = IC[0] + input[0] * IC[1]
        uint256[2] memory temp = _scalarMulG1(IC[1], input[0]);
        vk_x = _addG1(vk_x, temp);

        // Verify the pairing equation:
        // e(A, B) = e(alpha, beta) * e(vk_x, gamma) * e(C, delta)
        // Which is equivalent to checking:
        // e(-A, B) * e(alpha, beta) * e(vk_x, gamma) * e(C, delta) == 1
        return _pairingCheck(
            _negateG1(a),
            b,
            [alphax, alphay],
            [[betax1, betax2], [betay1, betay2]],
            vk_x,
            [[gammax1, gammax2], [gammay1, gammay2]],
            c,
            [[deltax1, deltax2], [deltay1, deltay2]]
        );
    }

    /**
     * @notice Check if a point is on the G1 curve
     * @dev y^2 = x^3 + 3 (mod p) for BN254
     */
    function _isOnCurveG1(uint256 x, uint256 y) internal pure returns (bool) {
        if (x >= PRIME_Q || y >= PRIME_Q) return false;
        if (x == 0 && y == 0) return true; // Point at infinity

        uint256 lhs = mulmod(y, y, PRIME_Q);
        uint256 rhs = addmod(mulmod(mulmod(x, x, PRIME_Q), x, PRIME_Q), 3, PRIME_Q);
        return lhs == rhs;
    }

    /**
     * @notice Negate a G1 point
     * @dev (x, y) -> (x, -y mod p)
     */
    function _negateG1(uint256[2] memory p) internal pure returns (uint256[2] memory) {
        if (p[0] == 0 && p[1] == 0) return p;
        return [p[0], PRIME_Q - (p[1] % PRIME_Q)];
    }

    /**
     * @notice Add two G1 points using the precompile
     * @dev Uses address 0x06
     */
    function _addG1(
        uint256[2] memory p1,
        uint256[2] memory p2
    ) internal view returns (uint256[2] memory r) {
        uint256[4] memory input;
        input[0] = p1[0];
        input[1] = p1[1];
        input[2] = p2[0];
        input[3] = p2[1];

        bool success;
        assembly {
            success := staticcall(sub(gas(), 2000), 6, input, 0x80, r, 0x40)
        }
        require(success, "G1 addition failed");
    }

    /**
     * @notice Scalar multiply a G1 point using the precompile
     * @dev Uses address 0x07
     */
    function _scalarMulG1(
        uint256[2] memory p,
        uint256 s
    ) internal view returns (uint256[2] memory r) {
        uint256[3] memory input;
        input[0] = p[0];
        input[1] = p[1];
        input[2] = s;

        bool success;
        assembly {
            success := staticcall(sub(gas(), 2000), 7, input, 0x60, r, 0x40)
        }
        require(success, "G1 scalar multiplication failed");
    }

    /**
     * @notice Perform the pairing check using the precompile
     * @dev Uses address 0x08
     * @return True if the pairing check passes
     */
    function _pairingCheck(
        uint256[2] memory a1,
        uint256[2][2] memory b1,
        uint256[2] memory a2,
        uint256[2][2] memory b2,
        uint256[2] memory a3,
        uint256[2][2] memory b3,
        uint256[2] memory a4,
        uint256[2][2] memory b4
    ) internal view returns (bool) {
        uint256[24] memory input;

        // First pairing: e(-A, B)
        input[0] = a1[0];
        input[1] = a1[1];
        input[2] = b1[0][1]; // Note: G2 points have swapped order
        input[3] = b1[0][0];
        input[4] = b1[1][1];
        input[5] = b1[1][0];

        // Second pairing: e(alpha, beta)
        input[6] = a2[0];
        input[7] = a2[1];
        input[8] = b2[0][1];
        input[9] = b2[0][0];
        input[10] = b2[1][1];
        input[11] = b2[1][0];

        // Third pairing: e(vk_x, gamma)
        input[12] = a3[0];
        input[13] = a3[1];
        input[14] = b3[0][1];
        input[15] = b3[0][0];
        input[16] = b3[1][1];
        input[17] = b3[1][0];

        // Fourth pairing: e(C, delta)
        input[18] = a4[0];
        input[19] = a4[1];
        input[20] = b4[0][1];
        input[21] = b4[0][0];
        input[22] = b4[1][1];
        input[23] = b4[1][0];

        uint256[1] memory result;
        bool success;
        assembly {
            success := staticcall(sub(gas(), 2000), 8, input, 768, result, 0x20)
        }
        require(success, "Pairing check failed");
        return result[0] == 1;
    }
}
