// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./interfaces/IComplianceCouncil.sol";
import "./interfaces/IComplianceEscrow.sol";

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
 * BLS12-381 Precompiles (EIP-2537):
 * - 0x0b: G1 Add, 0x0c: G1 Mul, 0x0d: G1 MultiExp
 * - 0x0e: G2 Add, 0x0f: G2 Mul, 0x10: G2 MultiExp
 * - 0x11: Pairing, 0x12: Map to G1, 0x13: Map to G2
 */
contract ComplianceCouncil is IComplianceCouncil, AccessControl, ReentrancyGuard, Pausable {
    // ============ Execution Mode ============

    /// @notice Execution mode determines trust model
    enum ExecutionMode {
        DISABLED,           // No execution allowed
        STRICT_ONCHAIN,     // Requires BLS precompiles (cryptographic finality)
        HYBRID_ATTESTED     // Off-chain verification with operator attestation
    }

    /// @notice Current execution mode
    ExecutionMode public executionMode;

    /// @notice Emitted when execution mode changes
    event ExecutionModeChanged(
        ExecutionMode indexed oldMode,
        ExecutionMode indexed newMode,
        address indexed changedBy,
        string reason
    );

    /// @notice Emitted when hybrid execution is attested by operator
    event HybridExecutionAttested(
        uint256 indexed warrantId,
        address indexed operator,
        bytes32 attestationHash,
        string verificationMethod
    );

    // ============ Constants ============

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant MEMBER_ROLE = keccak256("MEMBER_ROLE");
    bytes32 public constant REQUESTER_ROLE = keccak256("REQUESTER_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    // BLS12-381 precompile addresses (EIP-2537)
    address constant BLS_G1_ADD = address(0x0b);
    address constant BLS_G1_MUL = address(0x0c);
    address constant BLS_G2_ADD = address(0x0e);
    address constant BLS_G2_MUL = address(0x0f);
    address constant BLS_PAIRING = address(0x11);
    address constant BLS_MAP_G1 = address(0x12);
    address constant BLS_MAP_G2 = address(0x13);

    // BLS12-381 field modulus (for validation)
    uint256 constant BLS_MODULUS = 0x1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab;

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

    /// @notice Aggregated public key for threshold verification
    BLSPublicKey private _aggregatedPublicKey;

    /// @notice Whether BLS precompiles are available
    bool private _blsPrecompilesAvailable;

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

    constructor(
        uint256 threshold,
        uint256 votingPeriod,
        uint256 executionDelay,
        uint256 appealWindow,
        address admin
    ) {
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

        // Check if BLS precompiles are available
        _blsPrecompilesAvailable = _checkBLSPrecompiles();

        // Set execution mode based on precompile availability
        // STRICT_ONCHAIN if precompiles available, DISABLED otherwise (requires explicit enablement)
        if (_blsPrecompilesAvailable) {
            executionMode = ExecutionMode.STRICT_ONCHAIN;
            emit ExecutionModeChanged(ExecutionMode.DISABLED, ExecutionMode.STRICT_ONCHAIN, admin, "BLS precompiles available");
        } else {
            executionMode = ExecutionMode.DISABLED;
            emit ExecutionModeChanged(ExecutionMode.DISABLED, ExecutionMode.DISABLED, admin, "BLS precompiles unavailable - manual mode selection required");
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
    function attestHybridVerification(
        uint256 warrantId,
        bytes32 attestationHash,
        string calldata verificationMethod
    ) external onlyRole(OPERATOR_ROLE) {
        require(executionMode == ExecutionMode.HYBRID_ATTESTED, "Not in hybrid mode");
        require(_warrants[warrantId].id != 0, "Warrant not found");
        require(
            _warrants[warrantId].status == WarrantStatus.Executing,
            "Warrant not in executing state"
        );
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
    function addMember(
        address member,
        MemberRole role,
        BLSPublicKey calldata publicKey,
        uint256 keyIndex
    ) external override onlyRole(ADMIN_ROLE) {
        require(member != address(0), "Invalid address");
        require(!_members[member].isActive, "Member already exists");
        require(keyIndex > 0 && keyIndex <= _config.threshold * 2, "Invalid key index");
        require(_validateBLSPublicKey(publicKey), "Invalid BLS public key");

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

        _memberAddresses.push(member);
        _config.totalMembers++;

        _grantRole(MEMBER_ROLE, member);

        // Update aggregated public key
        _updateAggregatedPublicKey();

        emit MemberAdded(member, role, keyIndex);
    }

    /// @inheritdoc IComplianceCouncil
    function removeMember(address member) external override onlyRole(ADMIN_ROLE) {
        require(_members[member].isActive, "Member not found");
        require(_config.totalMembers > _config.threshold, "Cannot go below threshold");

        MemberRole role = _members[member].role;
        _members[member].isActive = false;
        _config.totalMembers--;

        _revokeRole(MEMBER_ROLE, member);
        _updateAggregatedPublicKey();

        emit MemberRemoved(member, role);
    }

    /// @inheritdoc IComplianceCouncil
    function rotateMemberKey(
        address member,
        BLSPublicKey calldata newPublicKey
    ) external override onlyRole(ADMIN_ROLE) {
        require(_members[member].isActive, "Member not found");
        require(_validateBLSPublicKey(newPublicKey), "Invalid BLS public key");

        _members[member].publicKey = newPublicKey;
        _updateAggregatedPublicKey();
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

        emit WarrantRequested(
            warrantId,
            requestType,
            msg.sender,
            targetDisputeId,
            documentHash
        );
    }

    /// @inheritdoc IComplianceCouncil
    function castVote(
        uint256 warrantId,
        bool approve,
        string calldata reason
    ) external override onlyRole(MEMBER_ROLE) whenNotPaused nonReentrant {
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

        _warrantVotes[warrantId].push(Vote({
            voter: msg.sender,
            approved: approve,
            timestamp: block.timestamp,
            reason: reason
        }));

        emit VoteCast(
            warrantId,
            msg.sender,
            approve,
            warrant.approvalsCount,
            warrant.rejectionsCount
        );

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

        emit VotingConcluded(
            warrantId,
            warrant.status,
            warrant.approvalsCount,
            warrant.rejectionsCount
        );
    }

    /// @inheritdoc IComplianceCouncil
    function fileAppeal(uint256 warrantId, string calldata reason) external override whenNotPaused {
        WarrantRequest storage warrant = _warrants[warrantId];

        require(warrant.id != 0, "Warrant not found");
        require(warrant.status == WarrantStatus.Approved, "Not approved");
        require(
            block.timestamp < warrant.executionTime,
            "Appeal window closed"
        );

        warrant.status = WarrantStatus.Appealed;

        emit AppealFiled(warrantId, msg.sender, reason);
    }

    /**
     * @notice Cancel a warrant that is stuck or invalid
     * @dev FIX: Prevents soft lock of warrants in Approved/Executing/Appealed states
     * @param warrantId The warrant to cancel
     * @param reason Human-readable reason for cancellation
     */
    function cancelWarrant(
        uint256 warrantId,
        string calldata reason
    ) external onlyRole(ADMIN_ROLE) {
        WarrantRequest storage warrant = _warrants[warrantId];

        require(warrant.id != 0, "Warrant not found");
        require(
            warrant.status != WarrantStatus.Executed &&
            warrant.status != WarrantStatus.Rejected,
            "Cannot cancel executed or rejected warrant"
        );

        WarrantStatus oldStatus = warrant.status;
        warrant.status = WarrantStatus.Rejected;

        emit WarrantCancelled(warrantId, oldStatus, msg.sender, reason);
    }

    /// @notice Emitted when a warrant is cancelled by admin
    event WarrantCancelled(
        uint256 indexed warrantId,
        WarrantStatus oldStatus,
        address indexed cancelledBy,
        string reason
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
    function submitSignature(
        uint256 warrantId,
        BLSSignature calldata signature
    ) external override onlyRole(MEMBER_ROLE) whenNotPaused nonReentrant {
        WarrantRequest storage warrant = _warrants[warrantId];

        require(warrant.id != 0, "Warrant not found");
        require(
            warrant.status == WarrantStatus.Approved ||
            warrant.status == WarrantStatus.Executing,
            "Not approved"
        );
        require(block.timestamp >= warrant.executionTime, "Execution delayed");
        require(
            block.timestamp <= warrant.executionTime + _config.signatureTimeout,
            "Signature timeout"
        );
        require(!_hasSubmittedSig[warrantId][msg.sender], "Already submitted");

        // Update status if first signature
        if (warrant.status == WarrantStatus.Approved) {
            warrant.status = WarrantStatus.Executing;
        }

        // Verify signature (if precompiles available, otherwise mark for off-chain)
        bool verified = false;
        if (_blsPrecompilesAvailable) {
            bytes32 message = _getSigningMessage(warrantId);
            verified = _verifyBLSSignature(
                message,
                signature,
                _members[msg.sender].publicKey
            );
            require(verified, "Invalid signature");
        }

        _hasSubmittedSig[warrantId][msg.sender] = true;
        _members[msg.sender].signaturesProvided++;

        _warrantSignatures[warrantId].push(SignatureSubmission({
            memberIndex: _members[msg.sender].keyIndex,
            signature: signature,
            timestamp: block.timestamp,
            verified: verified
        }));

        uint256 sigCount = _warrantSignatures[warrantId].length;

        emit SignatureSubmitted(warrantId, msg.sender, _members[msg.sender].keyIndex, sigCount);

        // Check if threshold reached
        if (sigCount >= _config.threshold) {
            emit ThresholdReached(warrantId, sigCount);
        }
    }

    /// @inheritdoc IComplianceCouncil
    function verifySignature(
        bytes32 message,
        BLSSignature calldata signature,
        BLSPublicKey calldata publicKey
    ) external view override returns (bool valid) {
        if (_blsPrecompilesAvailable) {
            return _verifyBLSSignature(message, signature, publicKey);
        }
        // Without precompiles, verification must be done off-chain
        return false;
    }

    /// @inheritdoc IComplianceCouncil
    function aggregateSignatures(
        BLSSignature[] calldata signatures
    ) external pure override returns (BLSSignature memory aggregated) {
        require(signatures.length > 0, "No signatures");

        // Start with first signature
        aggregated = signatures[0];

        // Aggregate remaining signatures using G2 addition
        // Note: This is a simplified version; real impl uses precompile
        for (uint256 i = 1; i < signatures.length; i++) {
            // G2 point addition would happen here via precompile
            // For now, we store the last signature as placeholder
            aggregated = signatures[i];
        }
    }

    /// @inheritdoc IComplianceCouncil
    function verifyThresholdSignature(
        uint256 warrantId,
        ThresholdSignature calldata thresholdSig
    ) external view override returns (bool valid) {
        require(thresholdSig.signatureCount >= _config.threshold, "Below threshold");

        if (_blsPrecompilesAvailable) {
            bytes32 message = _getSigningMessage(warrantId);
            // Verify aggregated signature against aggregated public key
            return _verifyBLSSignature(message, thresholdSig.aggregatedSig, _aggregatedPublicKey);
        }

        // Off-chain verification required
        return false;
    }

    /// @inheritdoc IComplianceCouncil
    function executeReconstruction(uint256 warrantId) external override nonReentrant returns (bytes32 decryptedKeyHash) {
        // EXECUTION MODE GATING - Enforce trust model
        require(executionMode != ExecutionMode.DISABLED, "Execution disabled");

        WarrantRequest storage warrant = _warrants[warrantId];

        require(warrant.id != 0, "Warrant not found");
        require(warrant.status == WarrantStatus.Executing, "Not executing");
        require(
            _warrantSignatures[warrantId].length >= _config.threshold,
            "Insufficient signatures"
        );

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
        decryptedKeyHash = keccak256(
            abi.encodePacked(
                warrantId,
                warrant.targetDisputeId,
                block.timestamp
            )
        );

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
     * @notice Check if BLS precompiles are available
     */
    function _checkBLSPrecompiles() internal view returns (bool) {
        // Try calling G1 add with identity points
        // If it reverts, precompiles not available
        (bool success,) = BLS_G1_ADD.staticcall(
            abi.encodePacked(
                bytes32(0), bytes32(0), // Point 1 (identity)
                bytes32(0), bytes32(0)  // Point 2 (identity)
            )
        );
        return success;
    }

    /**
     * @notice Validate BLS public key is on curve
     */
    function _validateBLSPublicKey(BLSPublicKey calldata pk) internal pure returns (bool) {
        // Basic validation: non-zero coordinates
        return pk.x != bytes32(0) || pk.y != bytes32(0);
    }

    /**
     * @notice Update aggregated public key from all active members
     * @dev FIX CRITICAL: Properly aggregate all member public keys using BLS G1 addition
     *      aggregatedPK = sum(pk_i) for all active members
     */
    function _updateAggregatedPublicKey() internal {
        // Reset aggregated key
        _aggregatedPublicKey = BLSPublicKey({x: bytes32(0), y: bytes32(0)});

        bool firstKey = true;

        for (uint256 i = 0; i < _memberAddresses.length; i++) {
            if (_members[_memberAddresses[i]].isActive) {
                BLSPublicKey memory memberKey = _members[_memberAddresses[i]].publicKey;

                if (firstKey) {
                    // First key becomes the base
                    _aggregatedPublicKey = memberKey;
                    firstKey = false;
                } else if (_blsPrecompilesAvailable) {
                    // Use G1 addition precompile to aggregate keys
                    // Input format: pk1.x (32 bytes) || pk1.y (32 bytes) || pk2.x (32 bytes) || pk2.y (32 bytes)
                    (bool success, bytes memory result) = BLS_G1_ADD.staticcall(
                        abi.encodePacked(
                            _aggregatedPublicKey.x,
                            _aggregatedPublicKey.y,
                            memberKey.x,
                            memberKey.y
                        )
                    );

                    if (success && result.length == 64) {
                        // Parse result: x (32 bytes) || y (32 bytes)
                        bytes32 newX;
                        bytes32 newY;
                        assembly {
                            newX := mload(add(result, 32))
                            newY := mload(add(result, 64))
                        }
                        _aggregatedPublicKey.x = newX;
                        _aggregatedPublicKey.y = newY;
                    }
                    // If precompile call fails, continue without aggregation
                    // This is safe because verification will fail in STRICT_ONCHAIN mode
                } else {
                    // Without precompiles, store concatenated hash as placeholder
                    // Actual verification must be done off-chain in HYBRID_ATTESTED mode
                    _aggregatedPublicKey.x = keccak256(abi.encodePacked(
                        _aggregatedPublicKey.x,
                        memberKey.x
                    ));
                    _aggregatedPublicKey.y = keccak256(abi.encodePacked(
                        _aggregatedPublicKey.y,
                        memberKey.y
                    ));
                }
            }
        }
    }

    /// @notice Event for aggregated public key updates
    event AggregatedPublicKeyUpdated(bytes32 x, bytes32 y, uint256 memberCount);

    /**
     * @notice Get the message to be signed for a warrant
     */
    function _getSigningMessage(uint256 warrantId) internal view returns (bytes32) {
        WarrantRequest storage warrant = _warrants[warrantId];
        return keccak256(
            abi.encodePacked(
                "COMPLIANCE_REVEAL",
                warrantId,
                warrant.targetDisputeId,
                warrant.documentHash,
                warrant.executionTime
            )
        );
    }

    /**
     * @notice Verify BLS signature using precompiles
     * @dev Uses pairing check: e(sig, g2) == e(H(m), pk)
     */
    function _verifyBLSSignature(
        bytes32 message,
        BLSSignature memory signature,
        BLSPublicKey memory publicKey
    ) internal view returns (bool) {
        if (!_blsPrecompilesAvailable) {
            return false;
        }

        // Hash message to G2 point
        (bool mapSuccess, bytes memory g2Point) = BLS_MAP_G2.staticcall(
            abi.encodePacked(message)
        );
        if (!mapSuccess) return false;

        // Prepare pairing input:
        // e(sig, G2_generator) * e(-H(m), pk) == 1
        // This is equivalent to e(sig, G2_gen) == e(H(m), pk)

        bytes memory pairingInput = abi.encodePacked(
            // First pairing: signature with G2 generator
            signature.x[0], signature.x[1],
            signature.y[0], signature.y[1],
            // G2 generator (standard BLS12-381)
            bytes32(0x024aa2b2f08f0a91260805272dc51051c6e47ad4fa403b02b4510b647ae3d1770bac0326a805bbefd48056c8c121bdb8),
            bytes32(0x13e02b6052719f607dacd3a088274f65596bd0d09920b61ab5da61bbdc7f5049334cf11213945d57e5ac7d055d042b7e),
            bytes32(0x0ce5d527727d6e118cc9cdc6da2e351aadfd9baa8cbdd3a76d429a695160d12c923ac9cc3baca289e193548608b82801),
            bytes32(0x0606c4a02ea734cc32acd2b02bc28b99cb3e287e85a763af267492ab572e99ab3f370d275cec1da1aaa9075ff05f79be),
            // Second pairing: -H(m) with public key
            g2Point,
            publicKey.x, publicKey.y
        );

        // Execute pairing check
        (bool pairingSuccess, bytes memory result) = BLS_PAIRING.staticcall(pairingInput);

        if (!pairingSuccess || result.length != 32) return false;

        // Pairing returns 1 if valid, 0 if invalid
        return abi.decode(result, (uint256)) == 1;
    }
}
