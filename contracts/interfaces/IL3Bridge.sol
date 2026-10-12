// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/**
 * @title IL3Bridge
 * @notice Interface for the L3 Bridge connecting L2 ILRM to App-Specific Rollup
 * @dev Enables high-throughput dispute handling via dedicated L3 rollup
 *
 * WARNING: the L3Bridge implementation is NOT production-ready and must not be deployed (unsound fraud
 * proofs, no sequencer bond, settlements not tied to finalized roots, bridged disputes not validated
 * against the ILRM). See the security warning on L3Bridge.
 *
 * Architecture:
 * - L2 (Arbitrum/Optimism): Main ILRM contract, asset registry, treasury
 * - L3 (App-Specific): High-throughput dispute processing, batched settlements
 * - Bridge: State commitments, proof verification, cross-chain messaging
 *
 * Flow:
 * 1. User initiates dispute on L2 (stakes locked)
 * 2. Dispute bridged to L3 for processing (by the ILRM or an authorized dispute bridger)
 * 3. L3 handles proposals, counters, acceptances at high throughput
 * 4. Settlement bridged back to L2 for stake distribution
 */
interface IL3Bridge {
    // ============ Enums ============

    /// @notice Message types for cross-chain communication
    enum MessageType {
        DisputeInitiation, // L2 → L3: New dispute
        DisputeSettlement, // L3 → L2: Resolved dispute
        StateCommitment, // L3 → L2: Batch state root
        FraudProof, // L2: Challenge invalid state
        WithdrawalRequest, // L3 → L2: Stake withdrawal
        ConfigUpdate // L2 → L3: Parameter changes
    }

    /// @notice Bridge status
    enum BridgeStatus {
        Active, // Normal operation
        Paused, // Temporarily halted
        Deprecated // Migrated to new bridge
    }

    /// @notice Lifecycle of a bonded fraud-proof commitment
    enum CommitmentStatus {
        None, // No commitment under this (challenger, commitHash)
        Pending, // Bond escrowed, awaiting reveal
        Won, // Valid proof rejected the root: bond + reward paid
        Refunded, // Valid proof, but the root was already rejected or orphaned: bond returned
        Forfeited // Invalid or mismatched proof, or never revealed: bond kept by the bridge
    }

    /// @notice Why batchProcessSettlements skipped a settlement (None = valid, applied)
    /// @dev Each reason is the check processSettlementFromL3 reverts on, in the same order
    enum SettlementSkipReason {
        None, // Valid: the settlement was applied
        NotBridged, // The L2 dispute was never bridged (single path: DisputeNotBridged)
        L3DisputeIdMismatch, // l3DisputeId is not the bridged dispute's L3 ID (single path: InvalidSettlement)
        AlreadySettled, // Already settled, including earlier in the same batch (single path: InvalidSettlement)
        StateRootNotFinalized // Nonzero stateProof that is not a finalized root (single path: InvalidStateRoot)
    }

    /// @notice L3 dispute state (compressed)
    enum L3DisputeState {
        Pending, // Awaiting counterparty
        Active, // Both staked, processing
        ProposalSubmitted, // LLM proposal ready
        Accepted, // Both parties accepted
        TimedOut, // Resolution timeout
        Settled // Bridged back to L2
    }

    // ============ Structs ============

    /// @notice State commitment from L3 sequencer
    struct StateCommitment {
        bytes32 stateRoot; // Merkle root of L3 state
        uint256 blockNumber; // L3 block number
        uint256 timestamp; // Commitment timestamp
        uint256 disputeCount; // Total disputes in batch
        bytes32 previousRoot; // Previous state root (for chain)
        bytes sequencerSignature; // Sequencer attestation
    }

    /// @notice Dispute initiation message (L2 → L3)
    struct DisputeInitiationMessage {
        uint256 l2DisputeId; // Original L2 dispute ID
        address initiator; // Initiator address
        address counterparty; // Counterparty address
        uint256 stakeAmount; // Locked stake on L2
        bytes32 evidenceHash; // Evidence bundle hash
        bytes32 fallbackTermsHash; // Fallback license hash
        uint256 l2BlockNumber; // L2 block for ordering
    }

    /// @notice Dispute settlement message (L3 → L2)
    struct DisputeSettlementMessage {
        uint256 l2DisputeId; // Original L2 dispute ID
        uint256 l3DisputeId; // L3 dispute ID
        L3DisputeState outcome; // Final state
        uint256 initiatorReturn; // Stake return to initiator
        uint256 counterpartyReturn; // Stake return to counterparty
        uint256 burnAmount; // Amount burned (timeout)
        bytes32 proposalHash; // Accepted proposal (if any)
        bytes32 stateProof; // Merkle proof of settlement
    }

    /// @notice L3 dispute summary for state verification
    struct L3DisputeSummary {
        uint256 l3DisputeId;
        uint256 l2DisputeId;
        L3DisputeState state;
        uint256 counterCount;
        bool initiatorAccepted;
        bool counterpartyAccepted;
        bytes32 currentProposalHash;
        uint256 lastUpdateBlock;
    }

    /// @notice Fraud proof for challenging invalid state
    struct FraudProof {
        bytes32 claimedRoot; // State root being challenged
        bytes32 correctRoot; // Correct state root
        bytes32[] merkleProof; // Proof of incorrect state
        uint256 disputeId; // Affected dispute
        bytes invalidStateData; // Data showing invalidity
    }

    /// @notice Sequencer configuration
    struct SequencerConfig {
        address sequencerAddress; // Authorized sequencer
        uint256 commitmentInterval; // Blocks between commitments
        uint256 challengePeriod; // Time to challenge state
        uint256 minBatchSize; // Minimum disputes per batch
        uint256 maxBatchSize; // Maximum disputes per batch
    }

    // ============ Events ============

    /// @notice Emitted when dispute is bridged to L3
    event DisputeBridgedToL3(
        uint256 indexed l2DisputeId, uint256 indexed l3DisputeId, address indexed initiator, uint256 stakeAmount
    );

    /// @notice Emitted when dispute settlement is bridged from L3
    event DisputeSettledFromL3(
        uint256 indexed l2DisputeId,
        uint256 indexed l3DisputeId,
        L3DisputeState outcome,
        uint256 initiatorReturn,
        uint256 counterpartyReturn
    );

    /// @notice Emitted when state commitment is submitted
    event StateCommitmentSubmitted(
        bytes32 indexed stateRoot, uint256 indexed blockNumber, uint256 disputeCount, address sequencer
    );

    /// @notice Emitted when state commitment is finalized
    event StateCommitmentFinalized(bytes32 indexed stateRoot, uint256 indexed blockNumber);

    /// @notice Emitted when fraud proof is submitted
    event FraudProofSubmitted(bytes32 indexed claimedRoot, uint256 indexed disputeId, address challenger);

    /// @notice Emitted when fraud proof is validated
    event FraudProofValidated(bytes32 indexed claimedRoot, address indexed challenger, uint256 reward);

    /// @notice Emitted when sequencer is updated
    event SequencerUpdated(address indexed oldSequencer, address indexed newSequencer);

    /// @notice Emitted when bridge status changes
    event BridgeStatusChanged(BridgeStatus oldStatus, BridgeStatus newStatus);

    /// @notice Fraud proof commitment for MEV protection
    /// @dev Keyed by (challenger, commitHash); any number may be open against the same state root
    struct FraudProofCommitment {
        bytes32 commitHash; // computeFraudProofCommitHash(challenger, proof, salt)
        bytes32 stateRoot; // Root the bond was posted against
        address challenger; // Committer address
        CommitmentStatus status; // Lifecycle status (packs with challenger)
        uint256 bond; // Bond amount
        uint256 commitTime; // Block timestamp of commit
    }

    // ============ Events (Commit-Reveal) ============

    /// @notice Emitted when fraud proof commitment is submitted
    event FraudProofCommitted(
        bytes32 indexed commitHash, bytes32 indexed stateRoot, address indexed challenger, uint256 bond
    );

    /// @notice Emitted when fraud proof is revealed
    /// @dev The second argument is the state root the commitment was bonded against
    event FraudProofRevealed(bytes32 indexed commitHash, bytes32 indexed stateRoot, address indexed challenger);

    /// @notice Emitted when a valid reveal is refunded because its root was already rejected or orphaned
    event FraudProofRefunded(
        bytes32 indexed commitHash, bytes32 indexed stateRoot, address indexed challenger, uint256 bond
    );

    /// @notice Emitted when a bond is forfeited (invalid or mismatched reveal, or never revealed)
    event FraudProofForfeited(
        bytes32 indexed commitHash, bytes32 indexed stateRoot, address indexed challenger, uint256 bond
    );

    /// @notice Emitted when a successful challenge rolls the committed chain head back to the rejected root's parent
    event CommittedChainRolledBack(bytes32 indexed rejectedRoot, bytes32 indexed newHead, uint256 newHeight);

    // ============ Events (Roles & Admin) ============

    /// @notice Emitted when an account is granted or revoked the dispute-bridger role
    event DisputeBridgerUpdated(address indexed account, bool authorized);

    /// @notice Emitted when an account is granted or revoked the settlement-relayer role
    event SettlementRelayerUpdated(address indexed account, bool authorized);

    /// @notice Emitted when a batched dispute is skipped because it is already bridged
    event DisputeBridgeSkipped(uint256 indexed l2DisputeId, uint256 existingL3DisputeId);

    /// @notice Emitted when batchProcessSettlements skips an invalid settlement instead of reverting the batch
    /// @dev Nothing is recorded for a skipped settlement; once valid it can be submitted again
    event SettlementSkipped(uint256 indexed l2DisputeId, uint256 indexed l3DisputeId, SettlementSkipReason reason);

    /// @notice Emitted when the owner withdraws free (non-escrowed) balance
    event FeesWithdrawn(address indexed to, uint256 amount);

    // ============ Errors ============

    error BridgeNotActive();
    error NotSequencer(address caller);
    error InvalidStateRoot(bytes32 root);
    error StateRootAlreadyCommitted(bytes32 root);
    error ChallengePeriodNotPassed(uint256 remaining);
    error ChallengePeriodExpired();
    error InvalidMerkleProof();
    error DisputeNotBridged(uint256 disputeId);
    error DisputeAlreadyBridged(uint256 disputeId);
    error InvalidSettlement(uint256 disputeId);
    error InvalidFraudProof();
    error InsufficientChallengerBond();
    error BatchSizeExceeded(uint256 size, uint256 max);
    error InvalidSequencerSignature();
    error CommitmentNotFound();
    error RevealTooEarly(uint256 remaining);
    error RevealTooLate();
    error AlreadyRevealed();
    error InvalidCommitment();
    error StateRootNotCanonical(bytes32 root);
    error ParentNotFinalized(bytes32 parentRoot);
    error CommitmentNotExpired(uint256 remaining);
    error NotAuthorizedBridger(address caller);
    error InsufficientFreeBalance(uint256 requested, uint256 available);

    // ============ Bridge Operations ============

    /**
     * @notice Bridge a dispute from L2 to L3 for high-throughput processing
     * @dev Callable by the ILRM or an owner-authorized dispute bridger (e.g. L3DisputeBatcher).
     *      Reverts DisputeAlreadyBridged if the L2 dispute was bridged before.
     * @param message Dispute initiation data
     * @return l3DisputeId The assigned L3 dispute ID
     */
    function bridgeDisputeToL3(DisputeInitiationMessage calldata message) external returns (uint256 l3DisputeId);

    /**
     * @notice Bridge a batch of disputes from L2 to L3 in one call
     * @dev Callable by the ILRM or an owner-authorized dispute bridger. Reverts BatchSizeExceeded above
     *      MAX_BATCH_SIZE but never reverts for a single item: a dispute that is already bridged
     *      (including a duplicate earlier in the same batch) is skipped and DisputeBridgeSkipped is emitted.
     * @param messages Dispute initiation data
     * @return l3DisputeIds The assigned L3 dispute IDs, index-aligned with messages (0 = skipped)
     */
    function bridgeDisputeBatchToL3(DisputeInitiationMessage[] calldata messages)
        external
        returns (uint256[] memory l3DisputeIds);

    /**
     * @notice Process settlement from L3 back to L2
     * @dev Sequencer only. Reverts DisputeNotBridged, InvalidSettlement (L3 ID mismatch or already settled)
     *      or InvalidStateRoot (nonzero stateProof that is not finalized). A zero stateProof is accepted on
     *      the sequencer's word alone (see the L3Bridge security warning).
     * @param message Settlement data with proof
     */
    function processSettlementFromL3(DisputeSettlementMessage calldata message) external;

    /**
     * @notice Batch process multiple settlements
     * @dev Callable by the sequencer or an owner-authorized settlement relayer (e.g. L3DisputeBatcher
     *      relaying a batch the sequencer queued). Reverts only for the whole batch (caller, bridge status,
     *      BatchSizeExceeded above MAX_BATCH_SIZE). Each settlement gets exactly the checks of
     *      processSettlementFromL3, against the state left by the settlements before it; one that fails them
     *      (never bridged, L3 ID mismatch, already settled - including a duplicate earlier in the same batch -
     *      or an unfinalized stateProof) is skipped with SettlementSkipped instead of reverting the batch.
     * @param messages Array of settlement messages
     * @return processed Number of settlements applied (messages.length minus the skipped ones)
     */
    function batchProcessSettlements(DisputeSettlementMessage[] calldata messages) external returns (uint256 processed);

    // ============ State Commitments ============

    /**
     * @notice Submit state commitment from L3 sequencer
     * @dev Starts challenge period before finalization
     * @param commitment State root and metadata
     */
    function submitStateCommitment(StateCommitment calldata commitment) external;

    /**
     * @notice Finalize state commitment after challenge period
     * @param stateRoot The state root to finalize
     */
    function finalizeStateCommitment(bytes32 stateRoot) external;

    /**
     * @notice Get the latest finalized state root
     * @return stateRoot The finalized root
     * @return blockNumber The L3 block number
     */
    function getLatestFinalizedState() external view returns (bytes32 stateRoot, uint256 blockNumber);

    /**
     * @notice Check if a state root is finalized
     * @param stateRoot The root to check
     * @return True if finalized
     */
    function isStateFinalized(bytes32 stateRoot) external view returns (bool);

    /**
     * @notice Whether a state root is on the current canonical chain (finalized roots included)
     * @dev A canonical root that is not finalized yet can still finalize; a non-canonical root never can
     * @param stateRoot The state root to query
     * @return False if never committed, or orphaned by a rejected ancestor (or rejected itself)
     */
    function isStateCanonical(bytes32 stateRoot) external view returns (bool);

    // ============ Fraud Proofs (Commit-Reveal for MEV Protection) ============

    /**
     * @notice Commit to a fraud proof (Phase 1 of commit-reveal)
     * @dev Prevents MEV front-running by hiding the proof until reveal. The commit hash is
     *      keccak256(abi.encode(FRAUD_PROOF_COMMIT_TYPEHASH, block.chainid, bridge, challenger,
     *      keccak256(abi.encode(proof)), salt)), see computeFraudProofCommitHash. Because it binds the
     *      challenger, a copied hash is useless to anyone else. Any number of commitments may be open
     *      against the same root; they are keyed by (challenger, commitHash). Commits close once a reveal
     *      window opened now could still be open at the root's challenge deadline.
     * @param commitHash computeFraudProofCommitHash(msg.sender, proof, salt)
     * @param stateRoot The state root being challenged (the reveal is bound to it)
     */
    function commitFraudProof(bytes32 commitHash, bytes32 stateRoot) external payable;

    /**
     * @notice Reveal a committed fraud proof (Phase 2 of commit-reveal)
     * @dev Must be called by the original committer between MIN_REVEAL_DELAY and
     *      MIN_REVEAL_DELAY + MAX_REVEAL_WINDOW after the commit. The reveal only acts on the root the
     *      bond was posted against. The bond ends in exactly one outcome, none of which reverts:
     *      - Forfeited: proof.claimedRoot differs from the committed root, or the proof is invalid
     *      - Refunded: valid proof, but the root was already rejected or is no longer canonical
     *      - Won: valid proof; the root is rejected, the chain head rolls back to its parent and the
     *        challenger receives bond + reward (the reward is paid only from free, non-escrowed balance)
     * @param proof The fraud proof data
     * @param salt Random salt used in commitment
     */
    function revealFraudProof(FraudProof calldata proof, bytes32 salt) external;

    /**
     * @notice Forfeit the bond of a commitment that was not revealed within its reveal window
     * @dev Permissionless. Reverts CommitmentNotExpired while the reveal window is still open.
     * @param challenger The committer
     * @param commitHash The commitment hash
     */
    function forfeitExpiredCommitment(address challenger, bytes32 commitHash) external;

    /**
     * @notice Compute the commit hash a challenger must commit for a given proof and salt
     * @param challenger The address that will commit and reveal
     * @param proof The fraud proof data
     * @param salt Random salt
     * @return The commit hash
     */
    function computeFraudProofCommitHash(address challenger, FraudProof calldata proof, bytes32 salt)
        external
        view
        returns (bytes32);

    /**
     * @notice Submit fraud proof to challenge invalid state (DEPRECATED)
     * @dev Use commitFraudProof + revealFraudProof instead for MEV protection
     * @param proof The fraud proof data
     */
    function submitFraudProof(FraudProof calldata proof) external payable;

    /**
     * @notice Verify a dispute state against committed root
     * @param stateRoot The state root to verify against
     * @param summary The dispute summary to verify
     * @param merkleProof The inclusion proof
     * @return valid True if state is valid
     */
    function verifyDisputeState(bytes32 stateRoot, L3DisputeSummary calldata summary, bytes32[] calldata merkleProof)
        external
        view
        returns (bool valid);

    // ============ Configuration ============

    /**
     * @notice Update sequencer configuration
     * @param config New sequencer settings
     */
    function updateSequencerConfig(SequencerConfig calldata config) external;

    /**
     * @notice Get current sequencer configuration
     * @return Current config
     */
    function getSequencerConfig() external view returns (SequencerConfig memory);

    /**
     * @notice Set bridge status
     * @param status New bridge status
     */
    function setBridgeStatus(BridgeStatus status) external;

    /**
     * @notice Get current bridge status
     * @return Current status
     */
    function getBridgeStatus() external view returns (BridgeStatus);

    // ============ View Functions ============

    /**
     * @notice Get L3 dispute ID for an L2 dispute
     * @param l2DisputeId The L2 dispute ID
     * @return l3DisputeId The corresponding L3 ID (0 if not bridged)
     */
    function getL3DisputeId(uint256 l2DisputeId) external view returns (uint256);

    /**
     * @notice Get L2 dispute ID for an L3 dispute
     * @param l3DisputeId The L3 dispute ID
     * @return l2DisputeId The corresponding L2 ID
     */
    function getL2DisputeId(uint256 l3DisputeId) external view returns (uint256);

    /**
     * @notice Check if dispute is bridged to L3
     * @param l2DisputeId The L2 dispute ID
     * @return True if bridged
     */
    function isDisputeBridged(uint256 l2DisputeId) external view returns (bool);

    /**
     * @notice Check if dispute is settled
     * @param l2DisputeId The L2 dispute ID to check
     * @return True if the dispute has been settled
     */
    function isDisputeSettled(uint256 l2DisputeId) external view returns (bool);

    /**
     * @notice Get pending settlements count
     * @return Number of settlements awaiting finalization
     */
    function getPendingSettlementsCount() external view returns (uint256);

    /**
     * @notice Get state commitment details
     * @param stateRoot The state root
     * @return commitment The commitment data
     */
    function getStateCommitment(bytes32 stateRoot) external view returns (StateCommitment memory);

    /**
     * @notice Get total disputes bridged to L3
     * @return Total count
     */
    function getTotalBridgedDisputes() external view returns (uint256);

    /**
     * @notice Get total settlements processed
     * @return Total count
     */
    function getTotalSettlements() external view returns (uint256);

    /**
     * @notice Get fraud proof commitment details
     * @param challenger The committer
     * @param commitHash The commitment hash
     * @return commitment The commitment data (status None if absent)
     */
    function getFraudProofCommitment(address challenger, bytes32 commitHash)
        external
        view
        returns (FraudProofCommitment memory);

    /**
     * @notice Check if commit-reveal mode is enabled
     * @return True if enabled
     */
    function isCommitRevealEnabled() external view returns (bool);
}
