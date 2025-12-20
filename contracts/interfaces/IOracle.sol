// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/**
 * @title IOracle - Oracle Node Interface
 * @notice Interface for the trusted off-chain executor that bridges LLM proposals
 * @dev Oracle is responsible for:
 *      - Fetching canonicalized evidence from IPFS/storage
 *      - Invoking LLM Engine with constrained prompts
 *      - Signing and submitting proposals on-chain
 *      - Verifying evidence hash integrity
 */
interface IOracle {
    // ============ Events ============

    /// @notice Emitted when oracle processes a dispute
    event DisputeProcessed(
        uint256 indexed disputeId,
        bytes32 evidenceHash,
        bytes32 proposalHash
    );

    /// @notice Emitted when oracle is registered/updated
    event OracleRegistered(
        address indexed oracle,
        bytes32 publicKeyHash
    );

    // ============ Core Functions ============

    /**
     * @notice Request proposal generation for a dispute
     * @dev Called by ILRM contract when dispute enters Active state
     * @param disputeId The dispute requiring a proposal
     * @param evidenceHash Hash of canonicalized evidence bundle
     */
    function requestProposal(
        uint256 disputeId,
        bytes32 evidenceHash
    ) external;

    /**
     * @notice Callback from LLM processing (off-chain initiated)
     * @dev Oracle signs the proposal and submits to ILRM
     * @param disputeId The dispute receiving the proposal
     * @param proposal JSON-encoded reconciliation proposal
     * @param signature EIP-712 signature over (disputeId, proposalHash)
     */
    function submitProposal(
        uint256 disputeId,
        string calldata proposal,
        bytes calldata signature
    ) external;

    /**
     * @notice Verify oracle signature on a proposal
     * @param disputeId The dispute ID
     * @param proposalHash Hash of the proposal content
     * @param signature Signature to verify
     * @return valid True if signature is valid from registered oracle
     */
    function verifySignature(
        uint256 disputeId,
        bytes32 proposalHash,
        bytes calldata signature
    ) external view returns (bool valid);

    // ============ View Functions ============

    /**
     * @notice Get the ILRM contract this oracle serves
     * @return The ILRM contract address
     */
    function ilrmContract() external view returns (address);

    /**
     * @notice Check if an address is a registered oracle
     * @param account Address to check
     * @return True if registered oracle
     */
    function isOracle(address account) external view returns (bool);

    /**
     * @notice Get oracle's public key hash for signature verification
     * @param oracle Oracle address
     * @return Public key hash
     */
    function oraclePublicKeyHash(address oracle) external view returns (bytes32);
}
