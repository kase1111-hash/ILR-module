// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "../interfaces/IComplianceCouncil.sol";
import "../interfaces/IComplianceEscrow.sol";
import {BLS12381} from "./libraries/BLS12381.sol";
import {BLS12381Verifier} from "./libraries/BLS12381Verifier.sol";

/**
 * @title ComplianceCouncil
 * @notice Decentralized compliance council with BLS threshold signatures
 * @dev Implements threshold decryption for legal compliance without central honeypot
 *
 * EXECUTION MODES (Trust Model):
 * - STRICT_ONCHAIN: Requires BLS precompiles. Cryptographic finality. Default for mainnet.
 * - HYBRID_ATTESTED: Allows off-chain verification with operator attestation. Audit trail required.
 * - DISABLED: No execution allowed. Emergency or pre-deployment state.
 *
 * BLS12-381 (EIP-2537 precompiles, Prague; math in libraries/BLS12381.sol):
 * - Final addresses: G1ADD 0x0b, G1MSM 0x0c, G2ADD 0x0d, G2MSM 0x0e, PAIRING_CHECK 0x0f, MAP_FP2_TO_G2 0x11
 *   (+ MODEXP 0x05)
 * - Public keys (member shares and the DKG group key) are G1 points; signatures are G2 points
 * - H(m) = RFC 9380 hash_to_curve to G2 with DST BLS_SIGNATURE_DST; valid iff e(pk, H(m)) * e(-G1, sig) == 1
 * - Hash-to-curve and the pairing check run in blsVerifier, a stateless BLS12381Verifier the constructor deploys
 *   (inlined they would push this contract past the EIP-170 size limit)
 * - Message: keccak256(abi.encode(keccak256("COMPLIANCE_REVEAL"), chainid, council, warrantId,
 *   targetDisputeId, documentHash, executionTime)), see getSigningMessage
 * - Availability is detected once at deployment by a known-answer test; without the precompiles every
 *   verification fails closed and STRICT_ONCHAIN cannot be selected
 * - Member keys are Shamir shares sk_i = f(keyIndex_i) of the group key sk = f(0); a partial signature counts
 *   only while its signer still holds the key it was verified against (not removed, key not rotated since).
 *   In STRICT_ONCHAIN, executeReconstruction Lagrange-combines threshold partials into the group signature
 *   sk * H(m), checks it against the group key and records keccak256 of it as the warrant's decryptedKeyHash.
 */
contract ComplianceCouncil is IComplianceCouncil, AccessControl, ReentrancyGuard, Pausable {
    // ============ Execution Mode ============

    /// @notice Execution mode determines trust model
    enum ExecutionMode {
        DISABLED, // No execution allowed
        STRICT_ONCHAIN, // Requires BLS precompiles (cryptographic finality)
        HYBRID_ATTESTED // Off-chain verification with operator attestation
    }

    /// @notice Current execution mode
    ExecutionMode public executionMode;

    /// @notice Emitted when execution mode changes
    event ExecutionModeChanged(
        ExecutionMode indexed oldMode, ExecutionMode indexed newMode, address indexed changedBy, string reason
    );

    /// @notice Emitted when hybrid execution is attested by operator
    event HybridExecutionAttested(
        uint256 indexed warrantId, address indexed operator, bytes32 attestationHash, string verificationMethod
    );

    // ============ Constants ============

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant MEMBER_ROLE = keccak256("MEMBER_ROLE");
    bytes32 public constant REQUESTER_ROLE = keccak256("REQUESTER_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    /// @notice RFC 9380 domain separation tag for hashing warrant messages to G2 (must match the SDK)
    bytes public constant BLS_SIGNATURE_DST = "ILRM-COMPLIANCE-COUNCIL-V01-CS01-with-BLS12381G2_XMD:SHA-256_SSWU_RO_";

    /// @dev Domain tag of the warrant signing message
    bytes32 private constant WARRANT_MESSAGE_TAG = keccak256("COMPLIANCE_REVEAL");

    // ============ State Variables ============

    /// @notice Council configuration
    CouncilConfig private _config;

    /// @notice Warrant counter
    uint256 private _warrantCounter;

    /// @notice Council member registry
    mapping(address => CouncilMember) private _members;
    address[] private _memberAddresses;

    /// @notice Warrant requests (ids 1.._warrantCounter)
    mapping(uint256 => WarrantRequest) private _warrants;

    /// @notice Votes per warrant
    mapping(uint256 => Vote[]) private _warrantVotes;
    mapping(uint256 => mapping(address => bool)) private _hasVoted;

    /// @notice Signatures per warrant
    mapping(uint256 => SignatureSubmission[]) private _warrantSignatures;

    /// @notice Key registration id of each member's latest submission per warrant (0 = none)
    mapping(uint256 => mapping(address => uint256)) private _submittedKeyId;

    /// @notice Threshold group public key (DKG output), set by the admin; all-zero until set
    BLSPublicKey private _aggregatedPublicKey;

    /// @notice Active member holding each key index (keyIndex => member)
    mapping(uint256 => address) private _keyIndexHolder;

    /// @notice Active member holding each BLS key (keccak256 of its canonical 128-byte encoding => member)
    mapping(bytes32 => address) private _keyHolder;

    /// @notice Last key registration id handed out (see CouncilMember.keyId)
    uint256 private _keyIdCounter;

    /// @notice Whether BLS precompiles are available (detected once at deployment)
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    bool private immutable _blsPrecompilesAvailable;

    /// @notice Stateless BLS12381.verify wrapper deployed by the constructor (see the contract header)
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    BLS12381Verifier public immutable blsVerifier;

    /// @notice Compliance escrow reference
    IComplianceEscrow public complianceEscrow;

    /// @notice Hybrid attestations: warrantId => attested decryptedKeyHash (0 = not attested)
    mapping(uint256 => bytes32) private _hybridAttestations;

    /// @notice Governance timelock address for emergency mode override
    address public governanceTimelock;

    /// @notice Emitted when governance timelock is set
    event GovernanceTimelockSet(address indexed oldTimelock, address indexed newTimelock);

    // ============ Constructor ============

    constructor(uint256 threshold, uint256 votingPeriod, uint256 executionDelay, uint256 appealWindow, address admin) {
        require(threshold > 0, "Threshold must be positive");
        require(votingPeriod >= 1 hours, "Voting period too short");

        _config = CouncilConfig({
            threshold: threshold,
            totalMembers: 0,
            votingPeriod: votingPeriod,
            executionDelay: executionDelay,
            appealWindow: appealWindow,
            signatureTimeout: 7 days,
            requiresUserNotification: true
        });

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);

        // Check if BLS precompiles are available (immutables cannot be read during construction)
        bool avail = BLS12381.precompilesAvailable();
        _blsPrecompilesAvailable = avail;
        blsVerifier = new BLS12381Verifier();

        // Set execution mode based on precompile availability
        // STRICT_ONCHAIN if precompiles available, DISABLED otherwise (requires explicit enablement)
        if (avail) {
            executionMode = ExecutionMode.STRICT_ONCHAIN;
            emit ExecutionModeChanged(
                ExecutionMode.DISABLED, ExecutionMode.STRICT_ONCHAIN, admin, "BLS precompiles available"
            );
        } else {
            executionMode = ExecutionMode.DISABLED;
            emit ExecutionModeChanged(
                ExecutionMode.DISABLED,
                ExecutionMode.DISABLED,
                admin,
                "BLS precompiles unavailable - manual mode selection required"
            );
        }
    }

    // ============ Execution Mode Management ============

    /**
     * @notice Set execution mode (governance controlled)
     * @dev STRICT_ONCHAIN requires BLS precompiles to be available
     * @param newMode The new execution mode
     * @param reason Human-readable reason for mode change
     */
    function setExecutionMode(ExecutionMode newMode, string calldata reason) external onlyRole(ADMIN_ROLE) {
        _setExecutionMode(newMode, reason);
    }

    /**
     * @notice Set governance timelock address
     * @dev FIX: Enables governance override if admin key is lost
     * @param _timelock New governance timelock address
     */
    function setGovernanceTimelock(address _timelock) external onlyRole(ADMIN_ROLE) {
        require(_timelock != address(0), "Invalid timelock address");
        emit GovernanceTimelockSet(governanceTimelock, _timelock);
        governanceTimelock = _timelock;
    }

    /**
     * @notice Emergency governance override for execution mode
     * @dev FIX: Allows governance timelock to recover from DISABLED mode if admin key is lost
     * @param newMode The new execution mode
     * @param reason Human-readable reason for override
     */
    function governanceOverrideMode(ExecutionMode newMode, string calldata reason) external {
        // msg.sender is never address(0), so an unset timelock matches no caller
        require(msg.sender == governanceTimelock, "Only governance timelock");
        _setExecutionMode(newMode, reason);
    }

    /// @dev STRICT_ONCHAIN requires the BLS precompiles
    function _setExecutionMode(ExecutionMode newMode, string calldata reason) private {
        if (newMode == ExecutionMode.STRICT_ONCHAIN) {
            require(_blsPrecompilesAvailable, "BLS precompiles required for STRICT_ONCHAIN");
        }
        emit ExecutionModeChanged(executionMode, newMode, msg.sender, reason);
        executionMode = newMode;
    }

    /**
     * @notice Attest to off-chain signature verification for hybrid mode
     * @dev Required before execution in HYBRID_ATTESTED mode. The operator aggregates the partial signatures
     *      off chain, verifies the result against the group key and attests keccak256 of the 256-byte EIP-2537
     *      encoding of that group signature (sdk computeDecryptedKeyHash): the value STRICT_ONCHAIN computes on
     *      chain. executeReconstruction records it as the warrant's decryptedKeyHash.
     * @param warrantId The warrant being attested
     * @param attestationHash keccak256 of the verified threshold signature (nonzero)
     * @param verificationMethod Description of verification method used
     */
    function attestHybridVerification(uint256 warrantId, bytes32 attestationHash, string calldata verificationMethod)
        external
        onlyRole(OPERATOR_ROLE)
    {
        require(executionMode == ExecutionMode.HYBRID_ATTESTED, "Not in hybrid mode");
        require(_existingWarrant(warrantId).status == WarrantStatus.Executing, "Warrant not in executing state");
        require(attestationHash != bytes32(0), "Invalid attestation");
        require(_hybridAttestations[warrantId] == bytes32(0), "Already attested");

        _hybridAttestations[warrantId] = attestationHash;

        emit HybridExecutionAttested(warrantId, msg.sender, attestationHash, verificationMethod);
    }

    /**
     * @notice Check if BLS precompiles are currently available
     * @return available True if precompiles can be used
     */
    function areBLSPrecompilesAvailable() external view returns (bool available) {
        return _blsPrecompilesAvailable;
    }

    /**
     * @notice Get hybrid attestation for a warrant
     * @param warrantId The warrant ID
     * @return attested Whether the warrant has been attested
     * @return attestationHash The attestation hash if attested
     */
    function getHybridAttestation(uint256 warrantId) external view returns (bool attested, bytes32 attestationHash) {
        attestationHash = _hybridAttestations[warrantId];
        attested = attestationHash != bytes32(0);
    }

    // ============ Member Management ============

    /// @inheritdoc IComplianceCouncil
    function addMember(address member, MemberRole role, BLSPublicKey calldata publicKey, uint256 keyIndex)
        external
        override
        onlyRole(ADMIN_ROLE)
    {
        require(member != address(0), "Invalid address");
        require(!_members[member].isActive, "Member already exists");
        // The key index is the share's Shamir evaluation point: a nonzero element of the scalar field F_r.
        // Together with uniqueness this is exactly what Lagrange interpolation needs (see BLS12381.R).
        require(keyIndex > 0 && keyIndex < BLS12381.R, "Invalid key index");
        require(_keyIndexHolder[keyIndex] == address(0), "Key index in use");

        // Validates the key and reserves it for the member
        uint256 keyId = _registerKey(member, publicKey);

        // A removed member keeps its struct, so re-adding it must not push a duplicate address
        bool firstAdd = _members[member].memberAddress == address(0);

        _members[member] = CouncilMember({
            memberAddress: member,
            role: role,
            publicKey: publicKey,
            keyIndex: keyIndex,
            isActive: true,
            joinedAt: block.timestamp,
            votesParticipated: 0,
            signaturesProvided: 0,
            keyId: keyId
        });

        if (firstAdd) _memberAddresses.push(member);
        _keyIndexHolder[keyIndex] = member;
        _config.totalMembers++;

        _grantRole(MEMBER_ROLE, member);

        emit MemberAdded(member, role, keyIndex);
    }

    /// @inheritdoc IComplianceCouncil
    function removeMember(address member) external override onlyRole(ADMIN_ROLE) {
        CouncilMember storage m = _members[member];
        require(m.isActive, "Member not found");
        require(_config.totalMembers > _config.threshold, "Cannot go below threshold");

        m.isActive = false;
        // Voids the member's submitted partial signatures (see _isCurrent)
        m.keyId = 0;
        delete _keyIndexHolder[m.keyIndex];
        delete _keyHolder[_keyHash(m.publicKey)];
        _config.totalMembers--;

        _revokeRole(MEMBER_ROLE, member);

        emit MemberRemoved(member, m.role);
    }

    /// @inheritdoc IComplianceCouncil
    function rotateMemberKey(address member, BLSPublicKey calldata newPublicKey)
        external
        override
        onlyRole(ADMIN_ROLE)
    {
        CouncilMember storage m = _members[member];
        require(m.isActive, "Member not found");

        bytes32 oldKey = _keyHash(m.publicKey);
        // Also rejects rotating to the current key, which is still reserved here
        uint256 keyId = _registerKey(member, newPublicKey);
        delete _keyHolder[oldKey];
        m.publicKey = newPublicKey;
        // Voids the partial signatures made under the old key; the member may sign those warrants again
        m.keyId = keyId;

        emit MemberKeyRotated(member, keyId);
    }

    /// @inheritdoc IComplianceCouncil
    function isMember(address addr) external view override returns (bool) {
        return _members[addr].isActive;
    }

    /// @inheritdoc IComplianceCouncil
    function getMember(address addr) external view override returns (CouncilMember memory) {
        return _members[addr];
    }

    /// @inheritdoc IComplianceCouncil
    function getActiveMembers() external view override returns (CouncilMember[] memory members) {
        uint256 activeCount = _config.totalMembers;
        members = new CouncilMember[](activeCount);

        uint256 index = 0;
        for (uint256 i = 0; i < _memberAddresses.length && index < activeCount; i++) {
            if (_members[_memberAddresses[i]].isActive) {
                members[index] = _members[_memberAddresses[i]];
                index++;
            }
        }
    }

    // ============ Warrant Management ============

    /// @inheritdoc IComplianceCouncil
    function submitWarrantRequest(
        RequestType requestType,
        uint256 targetDisputeId,
        bytes32 documentHash,
        string calldata jurisdiction
    ) external override whenNotPaused nonReentrant returns (uint256 warrantId) {
        // User consent requests don't require authorization
        if (requestType != RequestType.UserConsent) {
            require(hasRole(REQUESTER_ROLE, msg.sender), "Not authorized requester");
        }
        require(documentHash != bytes32(0), "Document hash required");

        warrantId = ++_warrantCounter;

        _warrants[warrantId] = WarrantRequest({
            id: warrantId,
            requestType: requestType,
            requester: msg.sender,
            targetDisputeId: targetDisputeId,
            documentHash: documentHash,
            jurisdiction: jurisdiction,
            submittedAt: block.timestamp,
            votingEndsAt: block.timestamp + _config.votingPeriod,
            executionTime: 0,
            status: WarrantStatus.Pending,
            approvalsCount: 0,
            rejectionsCount: 0,
            decryptedKeyHash: bytes32(0)
        });

        emit WarrantRequested(warrantId, requestType, msg.sender, targetDisputeId, documentHash);
    }

    /// @inheritdoc IComplianceCouncil
    function castVote(uint256 warrantId, bool approve, string calldata reason)
        external
        override
        onlyRole(MEMBER_ROLE)
        whenNotPaused
        nonReentrant
    {
        WarrantRequest storage warrant = _existingWarrant(warrantId);
        CouncilMember storage m = _activeMember();

        require(warrant.status == WarrantStatus.Pending, "Not pending");
        require(block.timestamp <= warrant.votingEndsAt, "Voting ended");
        require(!_hasVoted[warrantId][msg.sender], "Already voted");

        _hasVoted[warrantId][msg.sender] = true;
        m.votesParticipated++;

        if (approve) {
            warrant.approvalsCount++;
        } else {
            warrant.rejectionsCount++;
        }

        _warrantVotes[warrantId].push(
            Vote({voter: msg.sender, approved: approve, timestamp: block.timestamp, reason: reason})
        );

        emit VoteCast(warrantId, msg.sender, approve, warrant.approvalsCount, warrant.rejectionsCount);

        // Auto-conclude if all members voted
        if (warrant.approvalsCount + warrant.rejectionsCount >= _config.totalMembers) {
            _concludeVoting(warrantId);
        }
    }

    /// @inheritdoc IComplianceCouncil
    function concludeVoting(uint256 warrantId) external override whenNotPaused {
        WarrantRequest storage warrant = _existingWarrant(warrantId);

        require(warrant.status == WarrantStatus.Pending, "Not pending");
        require(block.timestamp > warrant.votingEndsAt, "Voting not ended");

        _concludeVoting(warrantId);
    }

    function _concludeVoting(uint256 warrantId) internal {
        WarrantRequest storage warrant = _warrants[warrantId];

        // Require threshold approvals
        if (warrant.approvalsCount >= _config.threshold) {
            warrant.status = WarrantStatus.Approved;
            warrant.executionTime = block.timestamp + _config.executionDelay;
        } else {
            warrant.status = WarrantStatus.Rejected;
        }

        emit VotingConcluded(warrantId, warrant.status, warrant.approvalsCount, warrant.rejectionsCount);
    }

    /// @inheritdoc IComplianceCouncil
    function fileAppeal(uint256 warrantId, string calldata reason) external override whenNotPaused {
        WarrantRequest storage warrant = _existingWarrant(warrantId);

        require(warrant.status == WarrantStatus.Approved, "Not approved");
        require(block.timestamp < warrant.executionTime, "Appeal window closed");

        warrant.status = WarrantStatus.Appealed;

        emit AppealFiled(warrantId, msg.sender, reason);
    }

    /**
     * @notice Cancel a warrant that is stuck or invalid
     * @dev FIX: Prevents soft lock of warrants in Approved/Executing/Appealed states
     * @param warrantId The warrant to cancel
     * @param reason Human-readable reason for cancellation
     */
    function cancelWarrant(uint256 warrantId, string calldata reason) external onlyRole(ADMIN_ROLE) {
        WarrantRequest storage warrant = _existingWarrant(warrantId);

        require(
            warrant.status != WarrantStatus.Executed && warrant.status != WarrantStatus.Rejected,
            "Cannot cancel executed or rejected warrant"
        );

        WarrantStatus oldStatus = warrant.status;
        warrant.status = WarrantStatus.Rejected;

        emit WarrantCancelled(warrantId, oldStatus, msg.sender, reason);
    }

    /// @notice Emitted when a warrant is cancelled by admin
    event WarrantCancelled(
        uint256 indexed warrantId, WarrantStatus oldStatus, address indexed cancelledBy, string reason
    );

    /// @inheritdoc IComplianceCouncil
    function getWarrant(uint256 warrantId) external view override returns (WarrantRequest memory) {
        return _warrants[warrantId];
    }

    /// @inheritdoc IComplianceCouncil
    function getWarrantVotes(uint256 warrantId) external view override returns (Vote[] memory) {
        return _warrantVotes[warrantId];
    }

    // ============ Threshold Signature Functions ============

    /// @inheritdoc IComplianceCouncil
    function submitSignature(uint256 warrantId, BLSSignature calldata signature)
        external
        override
        onlyRole(MEMBER_ROLE)
        whenNotPaused
        nonReentrant
    {
        WarrantRequest storage warrant = _existingWarrant(warrantId);
        // Active, so keyId != 0: a removed member's submission would otherwise carry keyId 0 and match its
        // zeroed CouncilMember.keyId in _isCurrent
        CouncilMember storage m = _activeMember();
        uint256 keyId = m.keyId;

        require(warrant.status == WarrantStatus.Approved || warrant.status == WarrantStatus.Executing, "Not approved");
        require(block.timestamp >= warrant.executionTime, "Execution delayed");
        require(block.timestamp <= warrant.executionTime + _config.signatureTimeout, "Signature timeout");
        // One submission per key registration: a member signs again only after a key rotation
        require(_submittedKeyId[warrantId][msg.sender] != keyId, "Already submitted");

        // Update status if first signature
        if (warrant.status == WarrantStatus.Approved) {
            warrant.status = WarrantStatus.Executing;
        }

        // Verify signature (if precompiles available, otherwise mark for off-chain)
        bool verified = false;
        if (_blsPrecompilesAvailable) {
            verified = _verifyBLSSignature(_getSigningMessage(warrantId), abi.encode(signature), m.publicKey);
            require(verified, "Invalid signature");
        }

        _submittedKeyId[warrantId][msg.sender] = keyId;
        m.signaturesProvided++;

        _warrantSignatures[warrantId].push(
            SignatureSubmission({
                memberIndex: m.keyIndex,
                signature: signature,
                timestamp: block.timestamp,
                verified: verified,
                signer: msg.sender,
                keyId: keyId
            })
        );

        uint256 sigCount = _currentSignatureCount(warrantId);

        emit SignatureSubmitted(warrantId, msg.sender, m.keyIndex, sigCount);

        // Check if threshold reached
        if (sigCount >= _config.threshold) {
            emit ThresholdReached(warrantId, sigCount);
        }
    }

    /// @inheritdoc IComplianceCouncil
    function verifySignature(bytes32 message, BLSSignature calldata signature, BLSPublicKey calldata publicKey)
        external
        view
        override
        returns (bool valid)
    {
        // Without precompiles this fails closed: verification must be done off-chain
        return _verifyBLSSignature(message, abi.encode(signature), publicKey);
    }

    /// @inheritdoc IComplianceCouncil
    function aggregateSignatures(BLSSignature[] calldata signatures)
        external
        view
        override
        returns (BLSSignature memory aggregated)
    {
        require(signatures.length > 0, "No signatures");
        require(_blsPrecompilesAvailable, "BLS precompiles required");

        // Every element, a lone one included, must be a canonical non-infinity G2 point (checked here) on the
        // curve and in the subgroup (checked by G2MSM, which G2ADD does not do); the sum is G2MSM with scalars 1
        bytes memory pairs = "";
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory sig = abi.encode(signatures[i]);
            require(BLS12381.isCanonicalG2(sig), "Invalid signature");
            pairs = bytes.concat(pairs, sig, bytes32(uint256(1)));
        }
        (bool ok, bytes memory sum) = BLS12381.g2Msm(pairs);
        require(ok, "Invalid signature");
        return abi.decode(sum, (BLSSignature));
    }

    /// @inheritdoc IComplianceCouncil
    function verifyThresholdSignature(uint256 warrantId, ThresholdSignature calldata thresholdSig)
        external
        view
        override
        returns (bool valid)
    {
        require(thresholdSig.signatureCount >= _config.threshold, "Below threshold");
        require(thresholdSig.signerIndices.length == thresholdSig.signatureCount, "Signer count mismatch");

        // Strictly increasing indices of active members: also rejects index 0 and duplicates
        uint256 prev = 0;
        for (uint256 i = 0; i < thresholdSig.signerIndices.length; i++) {
            uint256 idx = thresholdSig.signerIndices[i];
            require(idx > prev, "Unsorted signers");
            require(_keyIndexHolder[idx] != address(0), "Unknown signer");
            prev = idx;
        }

        // Unknown warrant (ids are 1.._warrantCounter): its signing message is still well defined, so check here
        if (warrantId == 0 || warrantId > _warrantCounter) return false;

        // An unset (all-zero) group key is rejected by the library's infinity check
        return _verifyBLSSignature(
            _getSigningMessage(warrantId), abi.encode(thresholdSig.aggregatedSig), _aggregatedPublicKey
        );
    }

    /// @inheritdoc IComplianceCouncil
    function executeReconstruction(uint256 warrantId)
        external
        override
        nonReentrant
        returns (bytes32 decryptedKeyHash)
    {
        // EXECUTION MODE GATING - Enforce trust model
        ExecutionMode mode = executionMode;
        require(mode != ExecutionMode.DISABLED, "Execution disabled");

        WarrantRequest storage warrant = _existingWarrant(warrantId);

        require(warrant.status == WarrantStatus.Executing, "Not executing");
        // Only partials whose signer still holds the key they were made under count
        require(_currentSignatureCount(warrantId) >= _config.threshold, "Insufficient signatures");

        if (mode == ExecutionMode.STRICT_ONCHAIN) {
            // STRICT_ONCHAIN implies the precompiles (see _setExecutionMode and the constructor)
            decryptedKeyHash = keccak256(_reconstructThresholdSignature(warrantId));
        } else {
            // HYBRID_ATTESTED: the operator attested the same hash after verifying off chain
            decryptedKeyHash = _hybridAttestations[warrantId];
            require(decryptedKeyHash != bytes32(0), "Hybrid attestation required");
        }

        warrant.status = WarrantStatus.Executed;
        warrant.decryptedKeyHash = decryptedKeyHash;

        emit KeyReconstructed(warrantId, decryptedKeyHash, warrant.requester);
    }

    /// @inheritdoc IComplianceCouncil
    function getSignatures(uint256 warrantId) external view override returns (SignatureSubmission[] memory) {
        return _warrantSignatures[warrantId];
    }

    // ============ View Functions ============

    /// @inheritdoc IComplianceCouncil
    function getConfig() external view override returns (CouncilConfig memory) {
        return _config;
    }

    /// @inheritdoc IComplianceCouncil
    function getAggregatedPublicKey() external view override returns (BLSPublicKey memory) {
        return _aggregatedPublicKey;
    }

    /// @inheritdoc IComplianceCouncil
    function getSigningMessage(uint256 warrantId) external view override returns (bytes32) {
        return _getSigningMessage(warrantId);
    }

    /// @inheritdoc IComplianceCouncil
    function getPendingWarrantCount() external view override returns (uint256 count) {
        return _warrantsByStatus(WarrantStatus.Pending).length;
    }

    /// @inheritdoc IComplianceCouncil
    function getWarrantsByStatus(WarrantStatus status) external view override returns (uint256[] memory warrantIds) {
        return _warrantsByStatus(status);
    }

    /// @inheritdoc IComplianceCouncil
    function hasVoted(uint256 warrantId, address member) external view override returns (bool) {
        return _hasVoted[warrantId][member];
    }

    /// @inheritdoc IComplianceCouncil
    function hasSubmittedSignature(uint256 warrantId, address member) external view override returns (bool) {
        uint256 keyId = _submittedKeyId[warrantId][member];
        // Key ids are counters, not timestamps: Slither taints all of _members because it also stores joinedAt
        // slither-disable-next-line incorrect-equality
        return keyId != 0 && keyId == _members[member].keyId;
    }

    // ============ Admin Functions ============

    /// @inheritdoc IComplianceCouncil
    function updateConfig(CouncilConfig calldata config) external override onlyRole(ADMIN_ROLE) {
        // totalMembers is derived state kept by addMember / removeMember: config.totalMembers is ignored
        uint256 members = _config.totalMembers;
        require(config.threshold > 0, "Invalid threshold");
        require(config.threshold <= members || members == 0, "Threshold > members");
        require(config.votingPeriod >= 1 hours, "Voting period too short");

        _config = config;
        _config.totalMembers = members;

        emit ConfigUpdated(config.threshold, members, config.votingPeriod);
    }

    /// @inheritdoc IComplianceCouncil
    function setAggregatedPublicKey(BLSPublicKey calldata groupKey) external override onlyRole(ADMIN_ROLE) {
        require(_validateBLSPublicKey(groupKey), "Invalid BLS public key");
        // A member share equal to the group key would make that member's partial a full threshold signature
        _requireKeyFree(_keyHash(groupKey), bytes32(0));
        _aggregatedPublicKey = groupKey;
        emit AggregatedPublicKeyUpdated(groupKey, msg.sender);
    }

    /// @inheritdoc IComplianceCouncil
    function pause() external override onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /// @inheritdoc IComplianceCouncil
    function unpause() external override onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    /// @inheritdoc IComplianceCouncil
    function setAuthorizedRequester(address requester, bool authorized) external override onlyRole(ADMIN_ROLE) {
        if (authorized) {
            _grantRole(REQUESTER_ROLE, requester);
        } else {
            _revokeRole(REQUESTER_ROLE, requester);
        }
    }

    /**
     * @notice Set compliance escrow contract reference
     * @param escrow Escrow contract address
     */
    function setComplianceEscrow(address escrow) external onlyRole(ADMIN_ROLE) {
        complianceEscrow = IComplianceEscrow(escrow);
    }

    // ============ Internal Functions ============

    /**
     * @notice Validate a BLS public key (G1 point, EIP-2537 encoding)
     * @dev With the precompiles: canonical encoding, on the curve, in the subgroup, not infinity.
     *      Without them only the encoding can be checked; that is acceptable because STRICT_ONCHAIN cannot be
     *      selected there and every later use goes through the pairing, which fails closed.
     */
    function _validateBLSPublicKey(BLSPublicKey memory pk) internal view returns (bool) {
        bytes memory enc = abi.encode(pk);
        return _blsPrecompilesAvailable ? BLS12381.isValidG1(enc) : BLS12381.isCanonicalG1(enc);
    }

    /// @dev Identifies a key: validated keys have a unique canonical encoding, so equal hashes mean equal points
    function _keyHash(BLSPublicKey memory pk) private pure returns (bytes32) {
        return keccak256(abi.encode(pk));
    }

    /// @dev No active member holds the key, and it is not `reserved` (the group key when registering a share)
    function _requireKeyFree(bytes32 key, bytes32 reserved) private view {
        require(_keyHolder[key] == address(0) && key != reserved, "BLS key in use");
    }

    /// @dev The warrant, which must exist
    function _existingWarrant(uint256 warrantId) private view returns (WarrantRequest storage warrant) {
        warrant = _warrants[warrantId];
        require(warrant.id != 0, "Warrant not found");
    }

    /**
     * @dev The caller's member record, which must be active. MEMBER_ROLE alone is not membership: its role admin
     *      can grant it directly, without addMember, also back to a removed member (inactive, keyId 0).
     */
    function _activeMember() private view returns (CouncilMember storage m) {
        m = _members[msg.sender];
        require(m.isActive, "Not a member");
    }

    /**
     * @dev Validates `pk`, reserves it for `member` and returns a fresh key registration id. Rejects a key held
     *      by an active member or equal to the group key.
     */
    function _registerKey(address member, BLSPublicKey calldata pk) private returns (uint256) {
        require(_validateBLSPublicKey(pk), "Invalid BLS public key");
        bytes32 key = _keyHash(pk);
        _requireKeyFree(key, _keyHash(_aggregatedPublicKey));
        _keyHolder[key] = member;
        return ++_keyIdCounter;
    }

    /**
     * @dev A submission counts while its signer still holds the key registration it was verified under:
     *      removal zeroes CouncilMember.keyId and rotation replaces it. Only active members (keyId != 0) submit;
     *      the keyId != 0 test keeps a removed member's zeroed keyId from ever matching regardless.
     */
    function _isCurrent(SignatureSubmission storage sub) private view returns (bool) {
        uint256 keyId = sub.keyId;
        // Key ids are counters, not timestamps: Slither taints all of _members because it also stores joinedAt
        // slither-disable-next-line incorrect-equality
        return keyId != 0 && keyId == _members[sub.signer].keyId;
    }

    /// @dev Number of submissions that currently count toward the threshold (at most one per member)
    function _currentSignatureCount(uint256 warrantId) private view returns (uint256 count) {
        SignatureSubmission[] storage subs = _warrantSignatures[warrantId];
        for (uint256 i = 0; i < subs.length; i++) {
            if (_isCurrent(subs[i])) count++;
        }
    }

    /**
     * @dev Lagrange-combines the first `threshold` current, verified partial signatures (sk_i * H(m) at the
     *      signers' key indices) into the group signature sk * H(m) and checks it against the group key. BLS
     *      signatures are unique, so the result does not depend on which partials are used. Reverts if they do
     *      not interpolate to a valid group signature (unset group key, or a member key that is not a share of it).
     * @return sigma 256-byte EIP-2537 encoding of the group signature
     */
    function _reconstructThresholdSignature(uint256 warrantId) private view returns (bytes memory sigma) {
        uint256 t = _config.threshold;
        SignatureSubmission[] storage subs = _warrantSignatures[warrantId];
        uint256[] memory xs = new uint256[](t);
        bytes memory pairs = "";
        uint256 n = 0;
        for (uint256 i = 0; i < subs.length && n < t; i++) {
            SignatureSubmission storage sub = subs[i];
            if (sub.verified && _isCurrent(sub)) {
                // G2MSM input; the scalar slot is filled in by interpolateG2AtZero
                pairs = abi.encodePacked(pairs, sub.signature.x, sub.signature.y, uint256(0));
                // Distinct: at most one current submission per member, one active member per key index
                xs[n++] = sub.memberIndex;
            }
        }

        // Fewer than t verified partials (unreachable: with the precompiles every submission is verified)
        // leave pairs shorter than t entries, which interpolateG2AtZero rejects
        bool ok;
        (ok, sigma) = BLS12381.interpolateG2AtZero(pairs, xs);
        require(
            ok && _verifyBLSSignature(_getSigningMessage(warrantId), sigma, _aggregatedPublicKey),
            "Invalid threshold signature"
        );
    }

    /// @dev Ids of the warrants with `status`, ascending
    function _warrantsByStatus(WarrantStatus status) private view returns (uint256[] memory ids) {
        uint256 total = _warrantCounter;
        ids = new uint256[](total);
        uint256 n = 0;
        for (uint256 id = 1; id <= total; id++) {
            // An enum compare, not a timestamp: Slither taints all of _warrants because it also stores timestamps
            // slither-disable-next-line incorrect-equality
            if (_warrants[id].status == status) ids[n++] = id;
        }
        // Shrink to the number of matches
        assembly ("memory-safe") {
            mstore(ids, n)
        }
    }

    /**
     * @notice Get the message to be signed for a warrant
     * @dev Bound to the chain and this council so signatures cannot be replayed across deployments
     */
    function _getSigningMessage(uint256 warrantId) internal view returns (bytes32) {
        WarrantRequest storage warrant = _warrants[warrantId];
        return keccak256(
            abi.encode(
                WARRANT_MESSAGE_TAG,
                block.chainid,
                address(this),
                warrantId,
                warrant.targetDisputeId,
                warrant.documentHash,
                warrant.executionTime
            )
        );
    }

    /**
     * @notice Verify a BLS signature using the EIP-2537 precompiles
     * @dev e(pk, H(message)) * e(-G1, sig) == 1 with H the RFC 9380 hash to G2 under BLS_SIGNATURE_DST
     * @param signature 256-byte EIP-2537 G2 encoding (abi.encode of a BLSSignature)
     */
    function _verifyBLSSignature(bytes32 message, bytes memory signature, BLSPublicKey memory publicKey)
        internal
        view
        returns (bool)
    {
        return _blsPrecompilesAvailable
            && blsVerifier.verify(abi.encode(publicKey), signature, abi.encodePacked(message), BLS_SIGNATURE_DST);
    }
}
