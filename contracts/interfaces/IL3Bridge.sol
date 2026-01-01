// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/**
 * @title IL3Bridge
 * @notice Interface for the L3 Bridge connecting L2 ILRM to App-Specific Rollup
 * @dev Enables high-throughput dispute handling via dedicated L3 rollup
 *
 * Architecture:
 * - L2 (Arbitrum/Optimism): Main ILRM contract, asset registry, treasury
 * - L3 (App-Specific): High-throughput dispute processing, batched settlements
 * - Bridge: State commitments, proof verification, cross-chain messaging
 *
 * Flow:
 * 1. User initiates dispute on L2 (stakes locked)
 * 2. Dispute bridged to L3 for processing
 * 3. L3 handles proposals, counters, acceptances at high throughput
 * 4. Settlement bridged back to L2 for stake distribution
 */
interface IL3Bridge {
    // ============ Enums ============

    /// @notice Message types for cross-chain communication
    enum MessageType {
        DisputeInitiation,      // L2 → L3: New dispute
        DisputeSettlement,      // L3 → L2: Resolved dispute
        StateCommitment,        // L3 → L2: Batch state root
        FraudProof,             // L2: Challenge invalid state
        WithdrawalRequest,      // L3 → L2: Stake withdrawal
        ConfigUpdate            // L2 → L3: Parameter changes
    }

    /// @notice Bridge status
    enum BridgeStatus {
        Active,                 // Normal operation
        Paused,                 // Temporarily halted
        Deprecated              // Migrated to new bridge
    }

    /// @notice L3 dispute state (compressed)
    enum L3DisputeState {
        Pending,                // Awaiting counterparty
        Active,                 // Both staked, processing
        ProposalSubmitted,      // LLM proposal ready
        Accepted,               // Both parties accepted
        TimedOut,               // Resolution timeout
        Settled                 // Bridged back to L2
    }

    // ============ Structs ============

    /// @notice State commitment from L3 sequencer
    struct StateCommitment {
        bytes32 stateRoot;          // Merkle root of L3 state
        uint256 blockNumber;        // L3 block number
        uint256 timestamp;          // Commitment timestamp
        uint256 disputeCount;       // Total disputes in batch
        bytes32 previousRoot;       // Previous state root (for chain)
        bytes sequencerSignature;   // Sequencer attestation
    }

    /// @notice Dispute initiation message (L2 → L3)
    struct DisputeInitiationMessage {
        uint256 l2DisputeId;        // Original L2 dispute ID
        address initiator;          // Initiator address
        address counterparty;       // Counterparty address
        uint256 stakeAmount;        // Locked stake on L2
        bytes32 evidenceHash;       // Evidence bundle hash
        bytes32 fallbackTermsHash;  // Fallback license hash
        uint256 l2BlockNumber;      // L2 block for ordering
    }

    /// @notice Dispute settlement message (L3 → L2)
    struct DisputeSettlementMessage {
        uint256 l2DisputeId;        // Original L2 dispute ID
        uint256 l3DisputeId;        // L3 dispute ID
        L3DisputeState outcome;     // Final state
        uint256 initiatorReturn;    // Stake return to initiator
        uint256 counterpartyReturn; // Stake return to counterparty
        uint256 burnAmount;         // Amount burned (timeout)
        bytes32 proposalHash;       // Accepted proposal (if any)
        bytes32 stateProof;         // Merkle proof of settlement
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
        bytes32 claimedRoot;        // State root being challenged
        bytes32 correctRoot;        // Correct state root
        bytes32[] merkleProof;      // Proof of incorrect state
        uint256 disputeId;          // Affected dispute
        bytes invalidStateData;     // Data showing invalidity
    }

    /// @notice Sequencer configuration
    struct SequencerConfig {
        address sequencerAddress;   // Authorized sequencer
        uint256 commitmentInterval; // Blocks between commitments
        uint256 challengePeriod;    // Time to challenge state
        uint256 minBatchSize;       // Minimum disputes per batch
        uint256 maxBatchSize;       // Maximum disputes per batch
    }

    // ============ Events ============

    /// @notice Emitted when dispute is bridged to L3
    event DisputeBridgedToL3(
        uint256 indexed l2DisputeId,
        uint256 indexed l3DisputeId,
        address indexed initiator,
        uint256 stakeAmount
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
        bytes32 indexed stateRoot,
        uint256 indexed blockNumber,
        uint256 disputeCount,
        address sequencer
    );

    /// @notice Emitted when state commitment is finalized
    event StateCommitmentFinalized(
        bytes32 indexed stateRoot,
        uint256 indexed blockNumber
    );

    /// @notice Emitted when fraud proof is submitted
    event FraudProofSubmitted(
        bytes32 indexed claimedRoot,
        uint256 indexed disputeId,
        address challenger
    );

    /// @notice Emitted when fraud proof is validated
    event FraudProofValidated(
        bytes32 indexed claimedRoot,
        address indexed challenger,
        uint256 reward
    );

    /// @notice Emitted when sequencer is updated
    event SequencerUpdated(
        address indexed oldSequencer,
        address indexed newSequencer
    );

    /// @notice Emitted when bridge status changes
    event BridgeStatusChanged(
        BridgeStatus oldStatus,
        BridgeStatus newStatus
    );

    /// @notice Fraud proof commitment for MEV protection
    struct FraudProofCommitment {
        bytes32 commitHash;         // Hash of fraud proof data
        address challenger;          // Committer address
        uint256 bond;               // Bond amount
        uint256 commitTime;         // Block timestamp of commit
        bool revealed;              // Whether proof has been revealed
    }

    // ============ Events (Commit-Reveal) ============

    /// @notice Emitted when fraud proof commitment is submitted
    event FraudProofCommitted(
        bytes32 indexed commitHash,
        bytes32 indexed stateRoot,
        address indexed challenger,
        uint256 bond
    );

    /// @notice Emitted when fraud proof is revealed
    event FraudProofRevealed(
        bytes32 indexed commitHash,
        bytes32 indexed claimedRoot,
        address indexed challenger
    );

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
    error NotCommitter(address caller, address committer);
    error AlreadyRevealed();
    error InvalidCommitment();

    // ============ Bridge Operations ============

    /**
     * @notice Bridge a dispute from L2 to L3 for high-throughput processing
     * @dev Called by ILRM when dispute is fully staked
     * @param message Dispute initiation data
     * @return l3DisputeId The assigned L3 dispute ID
     */
    function bridgeDisputeToL3(
        DisputeInitiationMessage calldata message
    ) external returns (uint256 l3DisputeId);

    /**
     * @notice Process settlement from L3 back to L2
     * @dev Called by sequencer with finalized state proof
     * @param message Settlement data with proof
     */
    function processSettlementFromL3(
        DisputeSettlementMessage calldata message
    ) external;

    /**
     * @notice Batch process multiple settlements
     * @dev More gas efficient for multiple resolutions
     * @param messages Array of settlement messages
     */
    function batchProcessSettlements(
        DisputeSettlementMessage[] calldata messages
    ) external;

    // ============ State Commitments ============

    /**
     * @notice Submit state commitment from L3 sequencer
     * @dev Starts challenge period before finalization
     * @param commitment State root and metadata
     */
    function submitStateCommitment(
        StateCommitment calldata commitment
    ) external;

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
    function getLatestFinalizedState() external view returns (
        bytes32 stateRoot,
        uint256 blockNumber
    );

    /**
     * @notice Check if a state root is finalized
     * @param stateRoot The root to check
     * @return True if finalized
     */
    function isStateFinalized(bytes32 stateRoot) external view returns (bool);

    // ============ Fraud Proofs (Commit-Reveal for MEV Protection) ============

    /**
     * @notice Commit to a fraud proof (Phase 1 of commit-reveal)
     * @dev Prevents MEV front-running by hiding proof until reveal
     * @param commitHash Hash of (fraud proof data + salt)
     * @param stateRoot The state root being challenged
     */
    function commitFraudProof(bytes32 commitHash, bytes32 stateRoot) external payable;

    /**
     * @notice Reveal a committed fraud proof (Phase 2 of commit-reveal)
     * @dev Must be called by original committer after reveal delay
     * @param proof The fraud proof data
     * @param salt Random salt used in commitment
     */
    function revealFraudProof(FraudProof calldata proof, bytes32 salt) external;

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
    function verifyDisputeState(
        bytes32 stateRoot,
        L3DisputeSummary calldata summary,
        bytes32[] calldata merkleProof
    ) external view returns (bool valid);

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
     * @param commitHash The commitment hash
     * @return commitment The commitment data
     */
    function getFraudProofCommitment(bytes32 commitHash) external view returns (FraudProofCommitment memory);

    /**
     * @notice Check if commit-reveal mode is enabled
     * @return True if enabled
     */
    function isCommitRevealEnabled() external view returns (bool);
}
