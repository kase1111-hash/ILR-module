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
 * BLS Threshold Signatures (BLS12-381, verified with the EIP-2537 precompiles of Prague):
 * - Public keys are G1 points, signatures are G2 points (minimal-pubkey-size scheme)
 * - H(m) is RFC 9380 hash_to_curve to G2 (BLS12381G2_XMD:SHA-256_SSWU_RO_) with the DST
 *   "ILRM-COMPLIANCE-COUNCIL-V01-CS01-with-BLS12381G2_XMD:SHA-256_SSWU_RO_"
 * - A signature is valid iff e(pk, H(m)) * e(-G1, sig) == 1
 * - Precompiles: G1ADD 0x0b, G1MSM 0x0c, G2ADD 0x0d, PAIRING_CHECK 0x0f, MAP_FP2_TO_G2 0x11 (and MODEXP 0x05)
 * - Points use the EIP-2537 encoding: every Fp element is 64 bytes big-endian (16 zero bytes followed by
 *   the 48-byte value) and the all-zero encoding is the point at infinity
 * - Individual (partial) signatures verify against each member's key share
 * - The threshold signature verifies against the DKG group public key set by the admin
 * - The signed message is getSigningMessage(warrantId), bound to the chain id and the council address
 * - Member keys are Shamir shares: keyIndex is the share's evaluation point x_i, publicKey = g1^f(x_i), and the
 *   group key is g1^f(0). Key indices and keys are unique among active members and no member key equals the
 *   group key.
 * - A partial signature counts toward the threshold only while its signer still holds the key registration
 *   it was verified under: removing the member or rotating its key voids it
 *
 * The reconstructed key (decryptedKeyHash):
 * - BLS signatures are unique, so the group signature sigma = f(0) * H(m) on a warrant's message m is one
 *   well-defined G2 point, whichever t members sign. It is the warrant's threshold-extracted decryption key
 *   in the BLS identity-based-encryption sense (sigma is the private key of identity m under the group key).
 * - decryptedKeyHash = keccak256(256-byte EIP-2537 encoding of sigma). In STRICT_ONCHAIN executeReconstruction
 *   computes sigma on chain by Lagrange interpolation of threshold current partials and verifies it against
 *   the group key; in HYBRID_ATTESTED the operator attests the same hash after verifying off chain.
 *   The SDK's computeDecryptedKeyHash gives the same value from an off-chain aggregate.
 * - The partials are public (getSignatures), so anyone can derive sigma once the threshold is met:
 *   decryptedKeyHash is a public commitment, and data protected by a key derived from sigma alone is readable
 *   by everyone holding its ciphertext. Releasing data to the requester alone requires the ciphertext to be
 *   access-controlled or additionally encrypted to the requester.
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
        UserRepresentative, // Elected by protocol users
        ProtocolGovernance, // DAO governance multisig
        IndependentAuditor, // Third-party auditor
        LegalCounsel, // Legal advisor
        RegulatoryLiaison // Regulatory body liaison
    }

    /// @notice Status of a warrant request
    enum WarrantStatus {
        Pending, // Awaiting votes
        Approved, // Threshold met, awaiting signatures
        Rejected, // Vote failed
        Executing, // Collecting signatures
        Executed, // Key reconstructed and delivered
        Expired, // Timed out
        Appealed // Under appeal
    }

    /// @notice Types of legal requests
    enum RequestType {
        CourtOrder, // Court-issued warrant
        RegulatorySubpoena, // Regulatory authority request
        LawEnforcement, // Law enforcement request
        InternalAudit, // Protocol internal audit
        UserConsent // User-initiated disclosure
    }

    // ============ Structs ============

    /**
     * @notice BLS public key: an uncompressed G1 point in EIP-2537 encoding
     * @dev Each Fp coordinate is [hi, lo]: hi holds 16 zero bytes followed by the top 16 bytes of the value,
     *      lo holds the low 32 bytes. abi.encodePacked(pk.x, pk.y) is the 128-byte EIP-2537 G1 encoding.
     */
    struct BLSPublicKey {
        bytes32[2] x; // [hi, lo]
        bytes32[2] y; // [hi, lo]
    }

    /**
     * @notice BLS signature: an uncompressed G2 point in EIP-2537 encoding
     * @dev Each Fp2 coordinate is [c0.hi, c0.lo, c1.hi, c1.lo] (Fp words as in BLSPublicKey).
     *      abi.encodePacked(sig.x, sig.y) is the 256-byte EIP-2537 G2 encoding.
     */
    struct BLSSignature {
        bytes32[4] x; // [c0.hi, c0.lo, c1.hi, c1.lo]
        bytes32[4] y; // [c0.hi, c0.lo, c1.hi, c1.lo]
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
        uint256 keyIndex; // Shamir evaluation point of the key share, 1 <= keyIndex < r
        bool isActive;
        uint256 joinedAt;
        uint256 votesParticipated;
        uint256 signaturesProvided;
        uint256 keyId; // Registration id of publicKey, fresh on every add and rotation; 0 once removed
    }

    /// @notice Council configuration
    struct CouncilConfig {
        uint256 threshold; // Minimum signatures required (m)
        uint256 totalMembers; // Active council size (n), maintained by addMember / removeMember
        uint256 votingPeriod; // Duration for voting (seconds)
        uint256 executionDelay; // Delay after approval before execution
        uint256 appealWindow; // Time to file appeal
        uint256 signatureTimeout; // Time to collect signatures after approval
        bool requiresUserNotification; // Notify affected user before execution
    }

    /// @notice Legal warrant request
    struct WarrantRequest {
        uint256 id;
        RequestType requestType;
        address requester; // Authority making request
        uint256 targetDisputeId; // Dispute to reveal
        bytes32 documentHash; // Hash of legal documentation
        string jurisdiction; // Legal jurisdiction
        uint256 submittedAt;
        uint256 votingEndsAt;
        uint256 executionTime; // When execution can begin
        WarrantStatus status;
        uint256 approvalsCount;
        uint256 rejectionsCount;
        bytes32 decryptedKeyHash; // keccak256 of the group signature on the warrant, set on execution
    }

    /// @notice Vote record
    struct Vote {
        address voter;
        bool approved;
        uint256 timestamp;
        string reason;
    }

    /**
     * @notice Signature submission
     * @dev The submission counts toward the threshold while getMember(signer).keyId == keyId
     */
    struct SignatureSubmission {
        uint256 memberIndex; // Signer's key index
        BLSSignature signature;
        uint256 timestamp;
        bool verified;
        address signer; // Member that submitted
        uint256 keyId; // Signer's key registration id at submission
    }

    // ============ Events ============

    /// @notice Emitted when a new council member is added
    event MemberAdded(address indexed memberAddress, MemberRole role, uint256 keyIndex);

    /// @notice Emitted when a council member is removed
    event MemberRemoved(address indexed memberAddress, MemberRole role);

    /// @notice Emitted when a member's BLS key is rotated; keyId is the new registration id
    event MemberKeyRotated(address indexed memberAddress, uint256 keyId);

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
        uint256 indexed warrantId, address indexed voter, bool approved, uint256 approvalsCount, uint256 rejectionsCount
    );

    /// @notice Emitted when voting concludes
    event VotingConcluded(
        uint256 indexed warrantId, WarrantStatus status, uint256 approvalsCount, uint256 rejectionsCount
    );

    /// @notice Emitted when a signature is submitted; totalSignatures counts the submissions that currently count
    event SignatureSubmitted(
        uint256 indexed warrantId, address indexed signer, uint256 memberIndex, uint256 totalSignatures
    );

    /// @notice Emitted when threshold is reached
    event ThresholdReached(uint256 indexed warrantId, uint256 signatureCount);

    /// @notice Emitted when key is reconstructed
    event KeyReconstructed(uint256 indexed warrantId, bytes32 keyHash, address indexed recipient);

    /// @notice Emitted when an appeal is filed
    event AppealFiled(uint256 indexed warrantId, address indexed appellant, string reason);

    /// @notice Emitted when council configuration changes
    event ConfigUpdated(uint256 threshold, uint256 totalMembers, uint256 votingPeriod);

    /// @notice Emitted when the threshold group public key is set
    event AggregatedPublicKeyUpdated(BLSPublicKey groupKey, address indexed updatedBy);

    // ============ Member Management ============

    /**
     * @notice Add a new council member
     * @dev The key must be a valid G1 point (curve and subgroup checked when the precompiles are available,
     *      encoding checked otherwise), not held by another active member and not equal to the group key.
     *      At most one active member may hold a given key index.
     * @param member Member address
     * @param role Member's role
     * @param publicKey BLS public key share (G1)
     * @param keyIndex The share's DKG evaluation point: 1 <= keyIndex < r, the BLS12-381 group order (any
     *        distinct nonzero field elements support Lagrange interpolation, so the council size is not bounded
     *        by the threshold)
     */
    function addMember(address member, MemberRole role, BLSPublicKey calldata publicKey, uint256 keyIndex) external;

    /**
     * @notice Remove a council member
     * @dev Frees the member's key index and key and voids the partial signatures it submitted
     * @param member Member address to remove
     */
    function removeMember(address member) external;

    /**
     * @notice Update member's BLS public key (key rotation)
     * @dev Same key checks as addMember (the current key counts as in use). Voids the partial signatures made
     *      under the old key; the member may sign those warrants again with the new key.
     * @param member Member address
     * @param newPublicKey New BLS public key
     */
    function rotateMemberKey(address member, BLSPublicKey calldata newPublicKey) external;

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
     * @dev Caller must be an active member (added through addMember and not removed); MEMBER_ROLE alone is not
     *      enough
     * @param warrantId Warrant to vote on
     * @param approve True to approve, false to reject
     * @param reason Reason for vote
     */
    function castVote(uint256 warrantId, bool approve, string calldata reason) external;

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
     * @dev Signs getSigningMessage(warrantId). When the precompiles are available the signature must verify
     *      against the caller's registered key share. Caller must be an active member (MEMBER_ROLE alone is not
     *      enough). One submission per member and key registration: after a key rotation the member may submit
     *      again.
     * @param warrantId Approved warrant ID
     * @param signature BLS signature (G2)
     */
    function submitSignature(uint256 warrantId, BLSSignature calldata signature) external;

    /**
     * @notice Verify a BLS signature against member's public key
     * @dev The BLS message is the 32 bytes of `message`, hashed to G2 with the council DST. Returns false
     *      (never reverts) for malformed points, an infinity public key, or when the precompiles are absent.
     * @param message Message that was signed
     * @param signature BLS signature
     * @param publicKey Signer's public key
     * @return valid True if signature is valid
     */
    function verifySignature(bytes32 message, BLSSignature calldata signature, BLSPublicKey calldata publicKey)
        external
        view
        returns (bool valid);

    /**
     * @notice Aggregate multiple BLS signatures as a plain G2 sum
     * @dev Requires the BLS precompiles. Reverts unless every element (also a single one) is a canonical,
     *      non-infinity G2 point on the curve and in the prime-order subgroup. This is plain (non-threshold)
     *      aggregation; threshold (Lagrange) aggregation is done by the SDK and by executeReconstruction.
     * @param signatures Array of signatures to aggregate
     * @return aggregated The aggregated signature
     */
    function aggregateSignatures(BLSSignature[] calldata signatures)
        external
        view
        returns (BLSSignature memory aggregated);

    /**
     * @notice Verify aggregated threshold signature against the group public key
     * @dev The signer indices must be strictly increasing key indices of active members and their number must
     *      equal signatureCount (>= threshold). For shares of one DKG any valid t-subset yields the same
     *      signature, so a valid result proves that t shares signed, not which members did. Informational only:
     *      it never gates execution (in STRICT_ONCHAIN executeReconstruction runs the same check on the signature
     *      it interpolates from the submitted partials). Returns false without the precompiles, for an unknown
     *      warrant or while the group key is unset.
     * @param warrantId Warrant ID
     * @param thresholdSig Aggregated signature with signer info
     * @return valid True if threshold signature is valid
     */
    function verifyThresholdSignature(uint256 warrantId, ThresholdSignature calldata thresholdSig)
        external
        view
        returns (bool valid);

    /**
     * @notice Execute key reconstruction after threshold is met
     * @dev Needs threshold partial signatures that still count (signer not removed, key not rotated since).
     *      STRICT_ONCHAIN: Lagrange-combines the first threshold of them into the group signature, which must
     *      verify against the group key ("Invalid threshold signature" otherwise, e.g. while the group key is
     *      unset). HYBRID_ATTESTED: requires the operator attestation. See the contract header for the meaning
     *      of decryptedKeyHash.
     * @param warrantId Warrant with sufficient signatures
     * @return decryptedKeyHash keccak256 of the 256-byte EIP-2537 encoding of the warrant's group signature
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
     * @notice Get the threshold group public key used by verifyThresholdSignature
     * @return aggregatedKey The group public key (all-zero until setAggregatedPublicKey is called)
     */
    function getAggregatedPublicKey() external view returns (BLSPublicKey memory aggregatedKey);

    /**
     * @notice Get the 32-byte message council members sign for a warrant
     * @dev keccak256(abi.encode(keccak256("COMPLIANCE_REVEAL"), block.chainid, address(this), warrantId,
     *      targetDisputeId, documentHash, executionTime)). The bytes of this hash are the BLS message.
     * @param warrantId Warrant ID
     * @return message The signing message
     */
    function getSigningMessage(uint256 warrantId) external view returns (bytes32 message);

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
     * @notice Check if member has a submitted signature that currently counts
     * @dev False again once the member is removed or rotates its key
     * @param warrantId Warrant ID
     * @param member Member address
     * @return hasSubmitted True if the member's submission under its current key exists
     */
    function hasSubmittedSignature(uint256 warrantId, address member) external view returns (bool hasSubmitted);

    // ============ Admin Functions ============

    /**
     * @notice Update council configuration
     * @dev config.totalMembers is ignored: the member count is maintained by addMember / removeMember.
     *      The threshold may not exceed the current member count (any threshold while there are no members).
     * @param config New configuration
     */
    function updateConfig(CouncilConfig calldata config) external;

    /**
     * @notice Set the threshold group public key
     * @dev The DKG group key g1^f(0) (the SDK's DKGOutput.aggregatedPublicKey). Must be a valid G1 point that
     *      no active member holds as its key share.
     * @param groupKey Group public key (G1)
     */
    function setAggregatedPublicKey(BLSPublicKey calldata groupKey) external;

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
