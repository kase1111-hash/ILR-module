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
    event DisputeProcessed(uint256 indexed disputeId, bytes32 evidenceHash, bytes32 proposalHash);

    /// @notice Emitted when oracle is registered/updated
    event OracleRegistered(address indexed oracle, bytes32 publicKeyHash);

    // ============ Core Functions ============

    /**
     * @notice Request proposal generation for a dispute
     * @dev Called by ILRM (best effort, gas-capped, never blocks the caller) when a dispute becomes fully staked
     *      and whenever counterPropose opens a new round. Advisory: submitProposal does not require a pending
     *      request. MultiPartyILRM does not call it.
     * @param disputeId The dispute requiring a proposal
     * @param evidenceHash Hash of canonicalized evidence bundle
     */
    function requestProposal(uint256 disputeId, bytes32 evidenceHash) external;

    /**
     * @notice Callback from LLM processing (off-chain initiated)
     * @dev Oracle signs the proposal and submits to ILRM
     * @param disputeId The dispute receiving the proposal
     * @param proposal JSON-encoded reconciliation proposal
     * @param signature EIP-712 signature over (disputeId, round, evidenceHash, proposalHash, nonce), where
     *        round/evidenceHash are the dispute's current ILRM counterCount/evidenceHash. At most one proposal
     *        per round; reverts while the current round already holds one unless the owner reset it.
     */
    function submitProposal(uint256 disputeId, string calldata proposal, bytes calldata signature) external;

    /**
     * @notice Verify oracle signature on a proposal
     * @dev Verifies against the current round, evidence and nonce.
     * @param disputeId The dispute ID
     * @param proposalHash Hash of the proposal content
     * @param signature Signature to verify
     * @return valid True if signature is valid from registered oracle
     */
    function verifySignature(uint256 disputeId, bytes32 proposalHash, bytes calldata signature)
        external
        view
        returns (bool valid);

    // ============ View Functions ============

    /**
     * @notice Get the dispute contract this oracle serves
     * @return The IOracleConsumer (ILRM or MultiPartyILRM) this oracle serves
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

/**
 * @title IOracleConsumer - Dispute contract served by NatLangChainOracle
 * @notice Implemented by ILRM and MultiPartyILRM. NatLangChainOracle reads and writes its consumer only through
 *         this interface, so one Oracle implementation serves both.
 */
interface IOracleConsumer {
    /// @notice Emitted when the oracle voids the live proposal; every acceptance (or vote) of it is cleared
    event ProposalVoided(uint256 indexed disputeId, uint256 indexed round, bytes32 proposalHash);

    /// @notice Emitted when the advisory Oracle.requestProposal call could not be made or reverted
    event OracleRequestFailed(uint256 indexed disputeId, uint256 indexed round);

    /**
     * @notice The signing and recovery context of a dispute
     * @dev MUST NOT be nonReentrant: the Oracle STATICCALLs it while the consumer is inside submitLLMProposal.
     * @param disputeId The dispute ID
     * @return round The dispute's counterCount (negotiation round)
     * @return evidenceHash The dispute's current evidence hash
     * @return resolved True once the dispute is resolved
     * @return deadline Last timestamp (inclusive) at which proposals, acceptances, counters and resets are allowed
     */
    function oracleContext(uint256 disputeId)
        external
        view
        returns (uint256 round, bytes32 evidenceHash, bool resolved, uint256 deadline);

    /**
     * @notice Oracle relays a signed LLM proposal
     * @dev Only callable by the oracle; the consumer re-verifies the signature via IOracle.verifySignature
     * @param disputeId The dispute receiving the proposal
     * @param proposal The proposal text
     * @param signature Oracle operator signature over the dispute's live context
     */
    function submitLLMProposal(uint256 disputeId, string calldata proposal, bytes calldata signature) external;

    /**
     * @notice Oracle recovery hook: void the live proposal
     * @dev Oracle-only, for unresolved disputes at or before the deadline. No-op if no proposal is live. Reverts if
     *      the live proposal's hash differs from proposalHash (compare-and-clear); otherwise clears it and every
     *      acceptance or vote, and emits ProposalVoided.
     * @param disputeId The dispute ID
     * @param proposalHash keccak256 of the proposal text being voided
     */
    function voidLLMProposal(uint256 disputeId, bytes32 proposalHash) external;
}
