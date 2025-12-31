// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/**
 * @title IComplianceEscrow
 * @notice Interface for managing viewing key shares with threshold decryption
 * @dev Enables selective de-anonymization for regulatory compliance while
 *      maintaining default privacy through Shamir's Secret Sharing
 *
 * Architecture:
 * - Users encrypt dispute metadata with ECIES using a viewing key
 * - The viewing key is split into m-of-n shares using Shamir's Secret Sharing
 * - Shares are distributed to trusted escrow holders (e.g., user, DAO, auditors)
 * - Legal requests trigger governance vote to reconstruct key
 * - Reconstructed key decrypts metadata from IPFS/Arweave
 *
 * This creates a "no honeypot" design where:
 * - No single party holds the complete key
 * - Reconstruction requires cooperation of multiple parties
 * - All reveal requests are logged on-chain for transparency
 */
interface IComplianceEscrow {
    // ============ Enums ============

    /// @notice Status of a reveal request
    enum RevealStatus {
        Pending,      // Request submitted, awaiting votes
        Approved,     // Threshold reached, key reconstructable
        Rejected,     // Majority rejected
        Executed,     // Key reconstructed and revealed
        Expired       // Request timed out
    }

    /// @notice Type of escrow holder
    enum HolderType {
        User,         // The dispute party themselves
        DAO,          // Protocol governance
        Auditor,      // Independent auditor
        LegalCounsel, // Legal representative
        Regulator     // Regulatory body (opt-in)
    }

    // ============ Structs ============

    /// @notice Configuration for a viewing key escrow
    struct EscrowConfig {
        uint256 disputeId;           // Associated dispute
        bytes32 viewingKeyCommitment; // Pedersen commitment to viewing key
        bytes32 encryptedDataHash;   // IPFS/Arweave hash of encrypted data
        uint8 threshold;             // Required shares for reconstruction (m)
        uint8 totalShares;           // Total shares distributed (n)
        uint256 createdAt;           // Timestamp of creation
        bool revealed;               // Whether key has been reconstructed
    }

    /// @notice A share holder's information
    struct ShareHolder {
        address holder;              // Address of share holder
        HolderType holderType;       // Type of holder
        bytes32 shareCommitment;     // Commitment to the share (for verification)
        bool hasSubmitted;           // Whether share has been submitted for reveal
    }

    /// @notice A request to reveal viewing key
    struct RevealRequest {
        uint256 escrowId;            // The escrow being requested
        address requester;           // Who requested the reveal
        string reason;               // Legal/compliance reason
        bytes32 legalDocHash;        // Hash of supporting legal documents
        uint256 requestedAt;         // When request was made
        uint256 expiresAt;           // Deadline for votes
        RevealStatus status;         // Current status
        uint256 approvalsReceived;   // Number of approvals
        uint256 rejectionsReceived;  // Number of rejections
    }

    // ============ Events ============

    /// @notice Emitted when a new escrow is created
    event EscrowCreated(
        uint256 indexed escrowId,
        uint256 indexed disputeId,
        bytes32 viewingKeyCommitment,
        uint8 threshold,
        uint8 totalShares
    );

    /// @notice Emitted when a share holder is registered
    event ShareHolderRegistered(
        uint256 indexed escrowId,
        address indexed holder,
        HolderType holderType,
        uint256 shareIndex
    );

    /// @notice Emitted when a share commitment is submitted
    event ShareCommitmentSubmitted(
        uint256 indexed escrowId,
        address indexed holder,
        bytes32 shareCommitment
    );

    /// @notice Emitted when a reveal request is created
    event RevealRequested(
        uint256 indexed requestId,
        uint256 indexed escrowId,
        address indexed requester,
        string reason
    );

    /// @notice Emitted when a holder votes on a reveal request
    event RevealVoteCast(
        uint256 indexed requestId,
        address indexed voter,
        bool approved
    );

    /// @notice Emitted when a reveal request status changes
    event RevealStatusChanged(
        uint256 indexed requestId,
        RevealStatus oldStatus,
        RevealStatus newStatus
    );

    /// @notice Emitted when a share is submitted for reconstruction
    event ShareSubmittedForReveal(
        uint256 indexed requestId,
        address indexed holder,
        uint256 shareIndex
    );

    /// @notice Emitted when key is successfully reconstructed
    event KeyReconstructed(
        uint256 indexed requestId,
        uint256 indexed escrowId,
        bytes32 reconstructedKeyHash
    );

    // ============ Errors ============

    error EscrowNotFound(uint256 escrowId);
    error RequestNotFound(uint256 requestId);
    error NotShareHolder(address caller);
    error ShareAlreadySubmitted(address holder);
    error ThresholdNotMet(uint256 required, uint256 received);
    error RequestExpired(uint256 requestId);
    error RequestNotApproved(uint256 requestId);
    error AlreadyRevealed(uint256 escrowId);
    error InvalidThreshold(uint8 threshold, uint8 totalShares);
    error InvalidShareIndex(uint256 index);
    error AlreadyVoted(address voter);
    error InvalidCommitment();
    error Unauthorized();
    error DisputeNotFound(uint256 disputeId);
    error ILRMNotSet();

    // ============ Escrow Management ============

    /**
     * @notice Create a new viewing key escrow for a dispute
     * @param disputeId The associated dispute ID
     * @param viewingKeyCommitment Pedersen commitment to the viewing key
     * @param encryptedDataHash Hash of encrypted data location (IPFS/Arweave)
     * @param threshold Required shares for reconstruction (m)
     * @param totalShares Total shares to distribute (n)
     * @param holders Array of share holder addresses
     * @param holderTypes Array of holder types
     * @return escrowId The created escrow ID
     */
    function createEscrow(
        uint256 disputeId,
        bytes32 viewingKeyCommitment,
        bytes32 encryptedDataHash,
        uint8 threshold,
        uint8 totalShares,
        address[] calldata holders,
        HolderType[] calldata holderTypes
    ) external returns (uint256 escrowId);

    /**
     * @notice Submit a share commitment (proof holder has the share)
     * @param escrowId The escrow ID
     * @param shareCommitment Hash commitment to the share value
     */
    function submitShareCommitment(
        uint256 escrowId,
        bytes32 shareCommitment
    ) external;

    // ============ Reveal Request Management ============

    /**
     * @notice Request to reveal a viewing key (initiates voting)
     * @param escrowId The escrow to reveal
     * @param reason Legal/compliance reason for request
     * @param legalDocHash Hash of supporting legal documentation
     * @param votingPeriod Duration for voting in seconds
     * @return requestId The created request ID
     */
    function requestReveal(
        uint256 escrowId,
        string calldata reason,
        bytes32 legalDocHash,
        uint256 votingPeriod
    ) external returns (uint256 requestId);

    /**
     * @notice Vote on a reveal request
     * @param requestId The request to vote on
     * @param approve True to approve, false to reject
     */
    function voteOnReveal(
        uint256 requestId,
        bool approve
    ) external;

    /**
     * @notice Submit share for reconstruction after approval
     * @param requestId The approved request
     * @param shareIndex Index of the share (0 to n-1)
     * @param encryptedShare The share, encrypted to the reconstruction coordinator
     */
    function submitShareForReveal(
        uint256 requestId,
        uint256 shareIndex,
        bytes calldata encryptedShare
    ) external;

    /**
     * @notice Finalize reveal after threshold shares submitted
     * @dev Off-chain coordinator reconstructs key; this records the event
     * @param requestId The request being finalized
     * @param reconstructedKeyHash Hash of reconstructed key (for verification)
     */
    function finalizeReveal(
        uint256 requestId,
        bytes32 reconstructedKeyHash
    ) external;

    // ============ View Functions ============

    /**
     * @notice Get escrow configuration
     * @param escrowId The escrow ID
     * @return config The escrow configuration
     */
    function getEscrow(uint256 escrowId) external view returns (EscrowConfig memory config);

    /**
     * @notice Get share holders for an escrow
     * @param escrowId The escrow ID
     * @return holders Array of share holder info
     */
    function getShareHolders(uint256 escrowId) external view returns (ShareHolder[] memory holders);

    /**
     * @notice Get reveal request details
     * @param requestId The request ID
     * @return request The reveal request
     */
    function getRevealRequest(uint256 requestId) external view returns (RevealRequest memory request);

    /**
     * @notice Check if an address is a share holder for an escrow
     * @param escrowId The escrow ID
     * @param holder The address to check
     * @return True if holder, false otherwise
     */
    function isShareHolder(uint256 escrowId, address holder) external view returns (bool);

    /**
     * @notice Get number of shares submitted for a reveal request
     * @param requestId The request ID
     * @return count Number of shares submitted
     */
    function getSubmittedShareCount(uint256 requestId) external view returns (uint256 count);

    /**
     * @notice Check if reveal threshold is met for a request
     * @param requestId The request ID
     * @return True if threshold met
     */
    function isThresholdMet(uint256 requestId) external view returns (bool);
}
