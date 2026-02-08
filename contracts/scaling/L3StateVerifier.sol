// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "../interfaces/IL3Bridge.sol";

/**
 * @title L3StateVerifier
 * @notice Merkle proof verification for L3 dispute states
 * @dev Provides efficient verification of dispute states against committed roots
 *
 * Features:
 * - Merkle tree construction for dispute batches
 * - Inclusion proof verification
 * - Exclusion proof verification (for fraud proofs)
 * - Batch verification for gas efficiency
 * - Sparse Merkle tree support for efficient updates
 * - FIX I-02: Two-step ownership transfer via Ownable2Step
 */
contract L3StateVerifier is Ownable2Step {
    // ============ Constants ============

    /// @notice Maximum tree depth (supports 2^32 disputes)
    uint256 public constant MAX_TREE_DEPTH = 32;

    /// @notice Empty leaf value
    bytes32 public constant EMPTY_LEAF = bytes32(0);

    /// @notice FIX L-03: Maximum batch size for verification
    /// @dev Prevents gas limit issues with large batches
    uint256 public constant MAX_BATCH_VERIFY_SIZE = 50;

    // ============ State Variables ============

    /// @notice L3 Bridge contract
    IL3Bridge public l3Bridge;

    /// @notice Cached zero hashes for sparse Merkle tree
    bytes32[MAX_TREE_DEPTH] public zeroHashes;

    /// @notice Verified proofs cache (proofHash => verified)
    mapping(bytes32 => bool) public verifiedProofs;

    // ============ Events ============

    event ProofVerified(
        bytes32 indexed stateRoot,
        uint256 indexed disputeId,
        bytes32 leafHash
    );

    event BatchVerified(
        bytes32 indexed stateRoot,
        uint256 count
    );

    // ============ Errors ============

    error InvalidProofLength(uint256 length, uint256 expected);
    error InvalidLeafIndex(uint256 index, uint256 max);
    error ProofVerificationFailed();
    error StateRootNotFinalized(bytes32 root);

    // ============ Constructor ============

    constructor(address _l3Bridge) Ownable(msg.sender) {
        require(_l3Bridge != address(0), "Invalid bridge");
        l3Bridge = IL3Bridge(_l3Bridge);

        // Precompute zero hashes for sparse Merkle tree
        _initializeZeroHashes();
    }

    /**
     * @notice Initialize zero hashes for empty tree levels
     */
    function _initializeZeroHashes() internal {
        zeroHashes[0] = EMPTY_LEAF;
        for (uint256 i = 1; i < MAX_TREE_DEPTH; i++) {
            zeroHashes[i] = keccak256(abi.encodePacked(zeroHashes[i - 1], zeroHashes[i - 1]));
        }
    }

    // ============ Verification Functions ============

    /**
     * @notice Verify a dispute state inclusion proof
     * @param stateRoot The committed state root
     * @param disputeId The L3 dispute ID
     * @param state The dispute state to verify
     * @param leafIndex Index of the leaf in the tree
     * @param proof Merkle proof siblings
     * @return valid True if proof is valid
     */
    function verifyDisputeInclusion(
        bytes32 stateRoot,
        uint256 disputeId,
        IL3Bridge.L3DisputeSummary calldata state,
        uint256 leafIndex,
        bytes32[] calldata proof
    ) external view returns (bool valid) {
        // Verify state root is finalized
        if (!l3Bridge.isStateFinalized(stateRoot)) {
            revert StateRootNotFinalized(stateRoot);
        }

        // Compute leaf hash
        bytes32 leaf = computeDisputeLeaf(state);

        // Verify Merkle proof
        return _verifyProof(stateRoot, leaf, leafIndex, proof);
    }

    /**
     * @notice Verify a settlement state proof
     * @param stateRoot The committed state root
     * @param settlement The settlement message
     * @param leafIndex Index of the leaf
     * @param proof Merkle proof
     * @return valid True if valid
     */
    function verifySettlementProof(
        bytes32 stateRoot,
        IL3Bridge.DisputeSettlementMessage calldata settlement,
        uint256 leafIndex,
        bytes32[] calldata proof
    ) external view returns (bool valid) {
        // Verify state root is finalized
        if (!l3Bridge.isStateFinalized(stateRoot)) {
            revert StateRootNotFinalized(stateRoot);
        }

        // Compute leaf hash from settlement
        bytes32 leaf = computeSettlementLeaf(settlement);

        // Verify Merkle proof
        return _verifyProof(stateRoot, leaf, leafIndex, proof);
    }

    /**
     * @notice Batch verify multiple dispute states
     * @param stateRoot The committed state root
     * @param states Array of dispute states
     * @param leafIndices Array of leaf indices
     * @param proofs Array of proofs (flattened, each proof is 32 bytes * depth)
     * @param proofDepth Depth of each proof
     * @return valid True if all proofs are valid
     */
    function batchVerifyDisputes(
        bytes32 stateRoot,
        IL3Bridge.L3DisputeSummary[] calldata states,
        uint256[] calldata leafIndices,
        bytes32[] calldata proofs,
        uint256 proofDepth
    ) external returns (bool valid) {
        // FIX L-03: Limit batch size to prevent gas limit issues
        require(states.length <= MAX_BATCH_VERIFY_SIZE, "Batch size exceeds maximum");
        require(states.length == leafIndices.length, "Length mismatch");
        require(proofs.length == states.length * proofDepth, "Invalid proofs length");

        // Verify state root is finalized
        if (!l3Bridge.isStateFinalized(stateRoot)) {
            revert StateRootNotFinalized(stateRoot);
        }

        for (uint256 i = 0; i < states.length; i++) {
            bytes32 leaf = computeDisputeLeaf(states[i]);

            // Extract proof for this state
            bytes32[] memory proof = new bytes32[](proofDepth);
            for (uint256 j = 0; j < proofDepth; j++) {
                proof[j] = proofs[i * proofDepth + j];
            }

            if (!_verifyProof(stateRoot, leaf, leafIndices[i], proof)) {
                return false;
            }
        }

        emit BatchVerified(stateRoot, states.length);
        return true;
    }

    /**
     * @notice Verify exclusion (non-membership) proof
     * @dev Used for fraud proofs - proves a state does NOT exist
     * @param stateRoot The committed state root
     * @param disputeId The dispute ID that should NOT be in state
     * @param leafIndex Expected leaf index
     * @param emptyProof Proof that position is empty
     * @return valid True if exclusion is proven
     */
    function verifyExclusion(
        bytes32 stateRoot,
        uint256 disputeId,
        uint256 leafIndex,
        bytes32[] calldata emptyProof
    ) external view returns (bool valid) {
        // Verify that the leaf at this position is empty
        return _verifyProof(stateRoot, EMPTY_LEAF, leafIndex, emptyProof);
    }

    // ============ Leaf Computation ============

    /**
     * @notice Compute leaf hash for a dispute summary
     * @param state The dispute state
     * @return Leaf hash
     */
    function computeDisputeLeaf(
        IL3Bridge.L3DisputeSummary calldata state
    ) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(
            state.l3DisputeId,
            state.l2DisputeId,
            uint8(state.state),
            state.counterCount,
            state.initiatorAccepted,
            state.counterpartyAccepted,
            state.currentProposalHash,
            state.lastUpdateBlock
        ));
    }

    /**
     * @notice Compute leaf hash for a settlement message
     * @param settlement The settlement
     * @return Leaf hash
     */
    function computeSettlementLeaf(
        IL3Bridge.DisputeSettlementMessage calldata settlement
    ) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(
            settlement.l2DisputeId,
            settlement.l3DisputeId,
            uint8(settlement.outcome),
            settlement.initiatorReturn,
            settlement.counterpartyReturn,
            settlement.burnAmount,
            settlement.proposalHash
        ));
    }

    /**
     * @notice Compute leaf hash for dispute initiation
     * @param initiation The initiation message
     * @return Leaf hash
     */
    function computeInitiationLeaf(
        IL3Bridge.DisputeInitiationMessage calldata initiation
    ) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(
            initiation.l2DisputeId,
            initiation.initiator,
            initiation.counterparty,
            initiation.stakeAmount,
            initiation.evidenceHash,
            initiation.fallbackTermsHash,
            initiation.l2BlockNumber
        ));
    }

    // ============ Internal Functions ============

    /**
     * @notice Internal Merkle proof verification
     * @param root Expected root
     * @param leaf Leaf to verify
     * @param index Leaf index
     * @param proof Sibling hashes
     * @return True if proof is valid
     */
    function _verifyProof(
        bytes32 root,
        bytes32 leaf,
        uint256 index,
        bytes32[] memory proof
    ) internal pure returns (bool) {
        bytes32 computed = leaf;

        for (uint256 i = 0; i < proof.length; i++) {
            bytes32 sibling = proof[i];

            // Determine if current node is left or right child
            if (index % 2 == 0) {
                // Current is left, sibling is right
                computed = keccak256(abi.encodePacked(computed, sibling));
            } else {
                // Current is right, sibling is left
                computed = keccak256(abi.encodePacked(sibling, computed));
            }

            index = index / 2;
        }

        return computed == root;
    }

    // ============ Tree Construction Helpers ============

    /**
     * @notice Compute Merkle root from leaves
     * @dev Helper for off-chain tree construction
     * @param leaves Array of leaf hashes
     * @return root The computed root
     */
    function computeRoot(bytes32[] calldata leaves) external pure returns (bytes32 root) {
        require(leaves.length > 0, "Empty leaves");

        // Pad to power of 2
        uint256 n = leaves.length;
        uint256 size = 1;
        while (size < n) {
            size *= 2;
        }

        bytes32[] memory tree = new bytes32[](size);

        // Copy leaves
        for (uint256 i = 0; i < n; i++) {
            tree[i] = leaves[i];
        }

        // Pad with empty leaves
        for (uint256 i = n; i < size; i++) {
            tree[i] = EMPTY_LEAF;
        }

        // Build tree bottom-up
        while (size > 1) {
            for (uint256 i = 0; i < size / 2; i++) {
                tree[i] = keccak256(abi.encodePacked(tree[i * 2], tree[i * 2 + 1]));
            }
            size /= 2;
        }

        return tree[0];
    }

    /**
     * @notice Get zero hash at a given depth
     * @param depth Tree depth (0 = leaf level)
     * @return The zero hash
     */
    function getZeroHash(uint256 depth) external view returns (bytes32) {
        require(depth < MAX_TREE_DEPTH, "Depth too large");
        return zeroHashes[depth];
    }

    // ============ Admin Functions ============

    /**
     * @notice Update L3 Bridge address
     */
    function setL3Bridge(address _l3Bridge) external onlyOwner {
        require(_l3Bridge != address(0), "Invalid bridge");
        l3Bridge = IL3Bridge(_l3Bridge);
    }

    /**
     * @notice Cache a verified proof for gas savings on repeat queries
     * @dev Only owner can cache proofs - prevents malicious proof caching
     * @param proofHash Hash of the proof data
     */
    function cacheVerifiedProof(bytes32 proofHash) external onlyOwner {
        verifiedProofs[proofHash] = true;
    }

    /**
     * @notice Check if a proof is cached as verified
     * @param proofHash Hash of the proof data
     * @return True if cached
     */
    function isProofCached(bytes32 proofHash) external view returns (bool) {
        return verifiedProofs[proofHash];
    }
}
