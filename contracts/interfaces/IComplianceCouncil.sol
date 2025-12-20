// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/**
 * @title IComplianceCouncil
 * @notice Interface for decentralized compliance council with BLS threshold signatures
 * @dev Implements threshold decryption for legal compliance without central honeypot
 *
 * Architecture:
 * - Council members hold BLS key shares (m-of-n threshold)
 * - Legal warrants require governance vote to proceed
 * - Signature aggregation enables key reconstruction
 * - Transparent on-chain voting with event emission
 *
 * BLS Threshold Signatures:
 * - Uses BLS12-381 curve for signature aggregation
 * - Individual signatures can be verified independently
 * - Aggregated signature verifies against aggregated public key
 * - FROST-style key generation for secure distributed setup
 *
 * Legal Compliance Flow:
 * 1. Authority submits warrant request with legal documentation
 * 2. Council members vote (on-chain governance)
 * 3. Approved warrants trigger signature collection
 * 4. Threshold signatures aggregate to decrypt viewing key
 * 5. Decrypted data released to authorized party only
 *
 * Safety:
 * - No single point of failure (threshold requirement)
 * - Transparent voting prevents abuse
 * - Time-locked execution for appeal window
 * - Audit trail for all compliance actions
 */
interface IComplianceCouncil {
    // ============ Enums ============

    /// @notice Types of council members
    enum MemberRole {
        UserRepresentative,     // Elected by protocol users
        ProtocolGovernance,     // DAO governance multisig
        IndependentAuditor,     // Third-party auditor
        LegalCounsel,           // Legal advisor
        RegulatoryLiaison       // Regulatory body liaison
    }

    /// @notice Status of a warrant request
    enum WarrantStatus {
        Pending,            // Awaiting votes
        Approved,           // Threshold met, awaiting signatures
        Rejected,           // Vote failed
        Executing,          // Collecting signatures
        Executed,           // Key reconstructed and delivered
        Expired,            // Timed out
        Appealed            // Under appeal
    }

    /// @notice Types of legal requests
    enum RequestType {
        CourtOrder,         // Court-issued warrant
        RegulatorySubpoena, // Regulatory authority request
        LawEnforcement,     // Law enforcement request
        InternalAudit,      // Protocol internal audit
        UserConsent         // User-initiated disclosure
    }

    // ============ Structs ============

    /// @notice BLS public key on G1 curve (compressed)
    struct BLSPublicKey {
        bytes32 x;
        bytes32 y;
    }

    /// @notice BLS signature on G2 curve (compressed)
    struct BLSSignature {
        bytes32[2] x;  // x coordinate (Fp2)
        bytes32[2] y;  // y coordinate (Fp2)
    }

    /// @notice Aggregated threshold signature
    struct ThresholdSignature {
        BLSSignature aggregatedSig;
        uint256[] signerIndices;
        uint256 signatureCount;
    }

    /// @notice Council member details
    struct CouncilMember {
        address memberAddress;
        MemberRole role;
        BLSPublicKey publicKey;
        uint256 keyIndex;           // Index in threshold scheme (1-based)
        bool isActive;
        uint256 joinedAt;
        uint256 votesParticipated;
        uint256 signaturesProvided;
    }

    /// @notice Council configuration
    struct CouncilConfig {
        uint256 threshold;          // Minimum signatures required (m)
        uint256 totalMembers;       // Total council size (n)
        uint256 votingPeriod;       // Duration for voting (seconds)
        uint256 executionDelay;     // Delay after approval before execution
        uint256 appealWindow;       // Time to file appeal
        uint256 signatureTimeout;   // Time to collect signatures after approval
        bool requiresUserNotification; // Notify affected user before execution
    }

    /// @notice Legal warrant request
    struct WarrantRequest {
        uint256 id;
        RequestType requestType;
        address requester;              // Authority making request
        uint256 targetDisputeId;        // Dispute to reveal
        bytes32 documentHash;           // Hash of legal documentation
        string jurisdiction;            // Legal jurisdiction
        uint256 submittedAt;
        uint256 votingEndsAt;
        uint256 executionTime;          // When execution can begin
        WarrantStatus status;
        uint256 approvalsCount;
        uint256 rejectionsCount;
        bytes32 decryptedKeyHash;       // Set after successful execution
    }

    /// @notice Vote record
    struct Vote {
        address voter;
        bool approved;
        uint256 timestamp;
        string reason;
    }

    /// @notice Signature submission
    struct SignatureSubmission {
        uint256 memberIndex;
        BLSSignature signature;
        uint256 timestamp;
        bool verified;
    }

    // ============ Events ============

    /// @notice Emitted when a new council member is added
    event MemberAdded(
        address indexed memberAddress,
        MemberRole role,
        uint256 keyIndex
    );

    /// @notice Emitted when a council member is removed
    event MemberRemoved(
        address indexed memberAddress,
        MemberRole role
    );

    /// @notice Emitted when a warrant request is submitted
    event WarrantRequested(
        uint256 indexed warrantId,
        RequestType requestType,
        address indexed requester,
        uint256 indexed targetDisputeId,
        bytes32 documentHash
    );

    /// @notice Emitted when a council member votes
    event VoteCast(
        uint256 indexed warrantId,
        address indexed voter,
        bool approved,
        uint256 approvalsCount,
        uint256 rejectionsCount
    );

    /// @notice Emitted when voting concludes
    event VotingConcluded(
        uint256 indexed warrantId,
        WarrantStatus status,
        uint256 approvalsCount,
        uint256 rejectionsCount
    );

    /// @notice Emitted when a signature is submitted
    event SignatureSubmitted(
        uint256 indexed warrantId,
        address indexed signer,
        uint256 memberIndex,
        uint256 totalSignatures
    );

    /// @notice Emitted when threshold is reached
    event ThresholdReached(
        uint256 indexed warrantId,
        uint256 signatureCount
    );

    /// @notice Emitted when key is reconstructed
    event KeyReconstructed(
        uint256 indexed warrantId,
        bytes32 keyHash,
        address indexed recipient
    );

    /// @notice Emitted when an appeal is filed
    event AppealFiled(
        uint256 indexed warrantId,
        address indexed appellant,
        string reason
    );

    /// @notice Emitted when council configuration changes
    event ConfigUpdated(
        uint256 threshold,
        uint256 totalMembers,
        uint256 votingPeriod
    );

    // ============ Member Management ============

    /**
     * @notice Add a new council member
     * @param member Member address
     * @param role Member's role
     * @param publicKey BLS public key
     * @param keyIndex Index in threshold scheme
     */
    function addMember(
        address member,
        MemberRole role,
        BLSPublicKey calldata publicKey,
        uint256 keyIndex
    ) external;

    /**
     * @notice Remove a council member
     * @param member Member address to remove
     */
    function removeMember(address member) external;

    /**
     * @notice Update member's BLS public key (key rotation)
     * @param member Member address
     * @param newPublicKey New BLS public key
     */
    function rotateMemberKey(
        address member,
        BLSPublicKey calldata newPublicKey
    ) external;

    /**
     * @notice Check if address is an active council member
     * @param addr Address to check
     * @return isMember True if active member
     */
    function isMember(address addr) external view returns (bool isMember);

    /**
     * @notice Get member details
     * @param addr Member address
     * @return member Member details
     */
    function getMember(address addr) external view returns (CouncilMember memory member);

    /**
     * @notice Get all active council members
     * @return members Array of active members
     */
    function getActiveMembers() external view returns (CouncilMember[] memory members);

    // ============ Warrant Management ============

    /**
     * @notice Submit a warrant request
     * @param requestType Type of legal request
     * @param targetDisputeId Dispute to reveal
     * @param documentHash Hash of legal documentation
     * @param jurisdiction Legal jurisdiction
     * @return warrantId The warrant request ID
     */
    function submitWarrantRequest(
        RequestType requestType,
        uint256 targetDisputeId,
        bytes32 documentHash,
        string calldata jurisdiction
    ) external returns (uint256 warrantId);

    /**
     * @notice Cast vote on a warrant request
     * @param warrantId Warrant to vote on
     * @param approve True to approve, false to reject
     * @param reason Reason for vote
     */
    function castVote(
        uint256 warrantId,
        bool approve,
        string calldata reason
    ) external;

    /**
     * @notice Conclude voting on a warrant
     * @dev Can be called after voting period ends
     * @param warrantId Warrant to conclude
     */
    function concludeVoting(uint256 warrantId) external;

    /**
     * @notice File an appeal against an approved warrant
     * @param warrantId Warrant to appeal
     * @param reason Appeal reason
     */
    function fileAppeal(uint256 warrantId, string calldata reason) external;

    /**
     * @notice Get warrant details
     * @param warrantId Warrant ID
     * @return warrant Warrant details
     */
    function getWarrant(uint256 warrantId) external view returns (WarrantRequest memory warrant);

    /**
     * @notice Get votes for a warrant
     * @param warrantId Warrant ID
     * @return votes Array of votes
     */
    function getWarrantVotes(uint256 warrantId) external view returns (Vote[] memory votes);

    // ============ Threshold Signature Functions ============

    /**
     * @notice Submit a partial signature for key reconstruction
     * @param warrantId Approved warrant ID
     * @param signature BLS signature
     */
    function submitSignature(
        uint256 warrantId,
        BLSSignature calldata signature
    ) external;

    /**
     * @notice Verify a BLS signature against member's public key
     * @param message Message that was signed
     * @param signature BLS signature
     * @param publicKey Signer's public key
     * @return valid True if signature is valid
     */
    function verifySignature(
        bytes32 message,
        BLSSignature calldata signature,
        BLSPublicKey calldata publicKey
    ) external view returns (bool valid);

    /**
     * @notice Aggregate multiple BLS signatures
     * @param signatures Array of signatures to aggregate
     * @return aggregated The aggregated signature
     */
    function aggregateSignatures(
        BLSSignature[] calldata signatures
    ) external pure returns (BLSSignature memory aggregated);

    /**
     * @notice Verify aggregated threshold signature
     * @param warrantId Warrant ID
     * @param thresholdSig Aggregated signature with signer info
     * @return valid True if threshold signature is valid
     */
    function verifyThresholdSignature(
        uint256 warrantId,
        ThresholdSignature calldata thresholdSig
    ) external view returns (bool valid);

    /**
     * @notice Execute key reconstruction after threshold is met
     * @param warrantId Warrant with sufficient signatures
     * @return decryptedKeyHash Hash of reconstructed key
     */
    function executeReconstruction(uint256 warrantId) external returns (bytes32 decryptedKeyHash);

    /**
     * @notice Get signatures collected for a warrant
     * @param warrantId Warrant ID
     * @return submissions Array of signature submissions
     */
    function getSignatures(uint256 warrantId) external view returns (SignatureSubmission[] memory submissions);

    // ============ View Functions ============

    /**
     * @notice Get council configuration
     * @return config Council configuration
     */
    function getConfig() external view returns (CouncilConfig memory config);

    /**
     * @notice Get aggregated public key for threshold verification
     * @return aggregatedKey The aggregated public key
     */
    function getAggregatedPublicKey() external view returns (BLSPublicKey memory aggregatedKey);

    /**
     * @notice Get pending warrant count
     * @return count Number of pending warrants
     */
    function getPendingWarrantCount() external view returns (uint256 count);

    /**
     * @notice Get warrants by status
     * @param status Status to filter by
     * @return warrantIds Array of warrant IDs
     */
    function getWarrantsByStatus(WarrantStatus status) external view returns (uint256[] memory warrantIds);

    /**
     * @notice Check if member has voted on warrant
     * @param warrantId Warrant ID
     * @param member Member address
     * @return hasVoted True if member has voted
     */
    function hasVoted(uint256 warrantId, address member) external view returns (bool hasVoted);

    /**
     * @notice Check if member has submitted signature
     * @param warrantId Warrant ID
     * @param member Member address
     * @return hasSubmitted True if signature submitted
     */
    function hasSubmittedSignature(uint256 warrantId, address member) external view returns (bool hasSubmitted);

    // ============ Admin Functions ============

    /**
     * @notice Update council configuration
     * @param config New configuration
     */
    function updateConfig(CouncilConfig calldata config) external;

    /**
     * @notice Emergency pause for all warrant operations
     */
    function pause() external;

    /**
     * @notice Unpause warrant operations
     */
    function unpause() external;

    /**
     * @notice Set authorized requesters (courts, regulators)
     * @param requester Requester address
     * @param authorized Whether authorized
     */
    function setAuthorizedRequester(address requester, bool authorized) external;
}
