// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "../interfaces/IComplianceCouncil.sol";
import "../interfaces/IComplianceEscrow.sol";
import {BLS12381} from "./libraries/BLS12381.sol";

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
 * - Final addresses: G1ADD 0x0b, G1MSM 0x0c, G2ADD 0x0d, PAIRING_CHECK 0x0f, MAP_FP2_TO_G2 0x11 (+ MODEXP 0x05)
 * - Public keys (member shares and the DKG group key) are G1 points; signatures are G2 points
 * - H(m) = RFC 9380 hash_to_curve to G2 with DST BLS_SIGNATURE_DST; valid iff e(pk, H(m)) * e(-G1, sig) == 1
 * - Message: keccak256(abi.encode(keccak256("COMPLIANCE_REVEAL"), chainid, council, warrantId,
 *   targetDisputeId, documentHash, executionTime)), see getSigningMessage
 * - Availability is detected once at deployment by a known-answer test; without the precompiles every
 *   verification fails closed and STRICT_ONCHAIN cannot be selected
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

    /// @notice Warrant requests
    mapping(uint256 => WarrantRequest) private _warrants;
    uint256[] private _warrantIds;

    /// @notice Votes per warrant
    mapping(uint256 => Vote[]) private _warrantVotes;
    mapping(uint256 => mapping(address => bool)) private _hasVoted;

    /// @notice Signatures per warrant
    mapping(uint256 => SignatureSubmission[]) private _warrantSignatures;
    mapping(uint256 => mapping(address => bool)) private _hasSubmittedSig;

    /// @notice Threshold group public key (DKG output), set by the admin; all-zero until set
    BLSPublicKey private _aggregatedPublicKey;

    /// @notice Active member holding each key index (keyIndex => member)
    mapping(uint256 => address) private _keyIndexHolder;

    /// @notice Whether BLS precompiles are available (detected once at deployment)
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    bool private immutable _blsPrecompilesAvailable;

    /// @notice Compliance escrow reference
    IComplianceEscrow public complianceEscrow;

    /// @notice Hybrid attestations: warrantId => attestation hash
    mapping(uint256 => bytes32) private _hybridAttestations;

    /// @notice Whether warrant has been attested in hybrid mode
    mapping(uint256 => bool) private _isHybridAttested;

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
        ExecutionMode oldMode = executionMode;

        // STRICT_ONCHAIN requires BLS precompiles
        if (newMode == ExecutionMode.STRICT_ONCHAIN) {
            require(_blsPrecompilesAvailable, "BLS precompiles required for STRICT_ONCHAIN");
        }

        executionMode = newMode;
        emit ExecutionModeChanged(oldMode, newMode, msg.sender, reason);
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
        require(msg.sender == governanceTimelock, "Only governance timelock");
        require(governanceTimelock != address(0), "Governance timelock not set");

        ExecutionMode oldMode = executionMode;

        // STRICT_ONCHAIN still requires BLS precompiles
        if (newMode == ExecutionMode.STRICT_ONCHAIN) {
            require(_blsPrecompilesAvailable, "BLS precompiles required for STRICT_ONCHAIN");
        }

        executionMode = newMode;
        emit ExecutionModeChanged(oldMode, newMode, msg.sender, reason);
    }

    /**
     * @notice Attest to off-chain signature verification for hybrid mode
     * @dev Required before execution in HYBRID_ATTESTED mode
     * @param warrantId The warrant being attested
     * @param attestationHash Hash of off-chain verification artifacts
     * @param verificationMethod Description of verification method used
     */
    function attestHybridVerification(uint256 warrantId, bytes32 attestationHash, string calldata verificationMethod)
        external
        onlyRole(OPERATOR_ROLE)
    {
        require(executionMode == ExecutionMode.HYBRID_ATTESTED, "Not in hybrid mode");
        require(_warrants[warrantId].id != 0, "Warrant not found");
        require(_warrants[warrantId].status == WarrantStatus.Executing, "Warrant not in executing state");
        require(!_isHybridAttested[warrantId], "Already attested");

        _hybridAttestations[warrantId] = attestationHash;
        _isHybridAttested[warrantId] = true;

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
        return (_isHybridAttested[warrantId], _hybridAttestations[warrantId]);
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
        require(keyIndex > 0 && keyIndex <= _config.threshold * 2, "Invalid key index");
        require(_keyIndexHolder[keyIndex] == address(0), "Key index in use");
        require(_validateBLSPublicKey(publicKey), "Invalid BLS public key");

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
            signaturesProvided: 0
        });

        if (firstAdd) _memberAddresses.push(member);
        _keyIndexHolder[keyIndex] = member;
        _config.totalMembers++;

        _grantRole(MEMBER_ROLE, member);

        emit MemberAdded(member, role, keyIndex);
    }

    /// @inheritdoc IComplianceCouncil
    function removeMember(address member) external override onlyRole(ADMIN_ROLE) {
        require(_members[member].isActive, "Member not found");
        require(_config.totalMembers > _config.threshold, "Cannot go below threshold");

        MemberRole role = _members[member].role;
        _members[member].isActive = false;
        delete _keyIndexHolder[_members[member].keyIndex];
        _config.totalMembers--;

        _revokeRole(MEMBER_ROLE, member);

        emit MemberRemoved(member, role);
    }

    /// @inheritdoc IComplianceCouncil
    function rotateMemberKey(address member, BLSPublicKey calldata newPublicKey)
        external
        override
        onlyRole(ADMIN_ROLE)
    {
        require(_members[member].isActive, "Member not found");
        require(_validateBLSPublicKey(newPublicKey), "Invalid BLS public key");

        _members[member].publicKey = newPublicKey;
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

        _warrantIds.push(warrantId);

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
        WarrantRequest storage warrant = _warrants[warrantId];

        require(warrant.id != 0, "Warrant not found");
        require(warrant.status == WarrantStatus.Pending, "Not pending");
        require(block.timestamp <= warrant.votingEndsAt, "Voting ended");
        require(!_hasVoted[warrantId][msg.sender], "Already voted");

        _hasVoted[warrantId][msg.sender] = true;
        _members[msg.sender].votesParticipated++;

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
        WarrantRequest storage warrant = _warrants[warrantId];

        require(warrant.id != 0, "Warrant not found");
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
        WarrantRequest storage warrant = _warrants[warrantId];

        require(warrant.id != 0, "Warrant not found");
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
        WarrantRequest storage warrant = _warrants[warrantId];

        require(warrant.id != 0, "Warrant not found");
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
        WarrantRequest storage warrant = _warrants[warrantId];

        require(warrant.id != 0, "Warrant not found");
        require(warrant.status == WarrantStatus.Approved || warrant.status == WarrantStatus.Executing, "Not approved");
        require(block.timestamp >= warrant.executionTime, "Execution delayed");
        require(block.timestamp <= warrant.executionTime + _config.signatureTimeout, "Signature timeout");
        require(!_hasSubmittedSig[warrantId][msg.sender], "Already submitted");

        // Update status if first signature
        if (warrant.status == WarrantStatus.Approved) {
            warrant.status = WarrantStatus.Executing;
        }

        // Verify signature (if precompiles available, otherwise mark for off-chain)
        bool verified = false;
        if (_blsPrecompilesAvailable) {
            bytes32 message = _getSigningMessage(warrantId);
            verified = _verifyBLSSignature(message, signature, _members[msg.sender].publicKey);
            require(verified, "Invalid signature");
        }

        _hasSubmittedSig[warrantId][msg.sender] = true;
        _members[msg.sender].signaturesProvided++;

        _warrantSignatures[warrantId].push(
            SignatureSubmission({
                memberIndex: _members[msg.sender].keyIndex,
                signature: signature,
                timestamp: block.timestamp,
                verified: verified
            })
        );

        uint256 sigCount = _warrantSignatures[warrantId].length;

        emit SignatureSubmitted(warrantId, msg.sender, _members[msg.sender].keyIndex, sigCount);

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
        if (_blsPrecompilesAvailable) {
            return _verifyBLSSignature(message, signature, publicKey);
        }
        // Without precompiles, verification must be done off-chain
        return false;
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

        bytes memory sum = abi.encodePacked(signatures[0].x, signatures[0].y);
        bool ok;
        for (uint256 i = 1; i < signatures.length; i++) {
            (ok, sum) = BLS12381.g2Add(sum, abi.encodePacked(signatures[i].x, signatures[i].y));
            require(ok, "Invalid signature");
        }
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

        if (!_blsPrecompilesAvailable || _warrants[warrantId].id == 0) return false;

        // An unset (all-zero) group key is rejected by the library's infinity check
        return _verifyBLSSignature(_getSigningMessage(warrantId), thresholdSig.aggregatedSig, _aggregatedPublicKey);
    }

    /// @inheritdoc IComplianceCouncil
    function executeReconstruction(uint256 warrantId)
        external
        override
        nonReentrant
        returns (bytes32 decryptedKeyHash)
    {
        // EXECUTION MODE GATING - Enforce trust model
        require(executionMode != ExecutionMode.DISABLED, "Execution disabled");

        WarrantRequest storage warrant = _warrants[warrantId];

        require(warrant.id != 0, "Warrant not found");
        require(warrant.status == WarrantStatus.Executing, "Not executing");
        require(_warrantSignatures[warrantId].length >= _config.threshold, "Insufficient signatures");

        // Mode-specific verification requirements
        if (executionMode == ExecutionMode.STRICT_ONCHAIN) {
            // STRICT_ONCHAIN: Require cryptographically verified signatures
            require(_blsPrecompilesAvailable, "BLS precompiles required");
            uint256 verifiedCount = 0;
            SignatureSubmission[] storage sigs = _warrantSignatures[warrantId];
            for (uint256 i = 0; i < sigs.length; i++) {
                if (sigs[i].verified) {
                    verifiedCount++;
                }
            }
            require(verifiedCount >= _config.threshold, "Insufficient verified signatures");
        } else if (executionMode == ExecutionMode.HYBRID_ATTESTED) {
            // HYBRID_ATTESTED: Require operator attestation for off-chain verification
            require(_isHybridAttested[warrantId], "Hybrid attestation required");
        }

        // Mark as executed
        warrant.status = WarrantStatus.Executed;

        // Generate key hash from collected signatures
        // In practice, this triggers off-chain key reconstruction
        decryptedKeyHash = keccak256(abi.encodePacked(warrantId, warrant.targetDisputeId, block.timestamp));

        warrant.decryptedKeyHash = decryptedKeyHash;

        emit KeyReconstructed(warrantId, decryptedKeyHash, warrant.requester);

        return decryptedKeyHash;
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
        for (uint256 i = 0; i < _warrantIds.length; i++) {
            if (_warrants[_warrantIds[i]].status == WarrantStatus.Pending) {
                count++;
            }
        }
    }

    /// @inheritdoc IComplianceCouncil
    function getWarrantsByStatus(WarrantStatus status) external view override returns (uint256[] memory warrantIds) {
        // Count matching warrants
        uint256 count = 0;
        for (uint256 i = 0; i < _warrantIds.length; i++) {
            if (_warrants[_warrantIds[i]].status == status) {
                count++;
            }
        }

        // Populate result array
        warrantIds = new uint256[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < _warrantIds.length && index < count; i++) {
            if (_warrants[_warrantIds[i]].status == status) {
                warrantIds[index] = _warrantIds[i];
                index++;
            }
        }
    }

    /// @inheritdoc IComplianceCouncil
    function hasVoted(uint256 warrantId, address member) external view override returns (bool) {
        return _hasVoted[warrantId][member];
    }

    /// @inheritdoc IComplianceCouncil
    function hasSubmittedSignature(uint256 warrantId, address member) external view override returns (bool) {
        return _hasSubmittedSig[warrantId][member];
    }

    // ============ Admin Functions ============

    /// @inheritdoc IComplianceCouncil
    function updateConfig(CouncilConfig calldata config) external override onlyRole(ADMIN_ROLE) {
        require(config.threshold > 0, "Invalid threshold");
        require(config.threshold <= config.totalMembers || config.totalMembers == 0, "Threshold > members");
        require(config.votingPeriod >= 1 hours, "Voting period too short");

        _config = config;

        emit ConfigUpdated(config.threshold, config.totalMembers, config.votingPeriod);
    }

    /// @inheritdoc IComplianceCouncil
    function setAggregatedPublicKey(BLSPublicKey calldata groupKey) external override onlyRole(ADMIN_ROLE) {
        require(_validateBLSPublicKey(groupKey), "Invalid BLS public key");
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
        bytes memory enc = abi.encodePacked(pk.x, pk.y);
        return _blsPrecompilesAvailable ? BLS12381.isValidG1(enc) : BLS12381.isCanonicalG1(enc);
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
     */
    function _verifyBLSSignature(bytes32 message, BLSSignature memory signature, BLSPublicKey memory publicKey)
        internal
        view
        returns (bool)
    {
        if (!_blsPrecompilesAvailable) return false;
        return BLS12381.verify(
            abi.encodePacked(publicKey.x, publicKey.y),
            abi.encodePacked(signature.x, signature.y),
            abi.encodePacked(message),
            BLS_SIGNATURE_DST
        );
    }
}
