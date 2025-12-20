// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "./interfaces/IOracle.sol";
import "./interfaces/IILRM.sol";

/**
 * @title NatLangChainOracle
 * @notice Trusted off-chain executor that bridges LLM proposals to ILRM
 * @dev Implements EIP-712 signature verification for proposal authenticity
 *
 * The Oracle is responsible for:
 * - Receiving proposal requests from ILRM
 * - Coordinating with off-chain LLM Engine
 * - Signing and submitting verified proposals
 * - Ensuring proposal integrity via cryptographic signatures
 */
contract NatLangChainOracle is IOracle, Ownable {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ============ Constants ============

    /// @notice EIP-712 domain separator
    bytes32 public immutable DOMAIN_SEPARATOR;

    /// @notice EIP-712 typehash for proposals
    bytes32 public constant PROPOSAL_TYPEHASH =
        keccak256("Proposal(uint256 disputeId,bytes32 proposalHash,uint256 nonce)");

    // ============ State Variables ============

    /// @notice The ILRM contract this oracle serves
    address public override ilrmContract;

    /// @notice Registered oracle operators
    mapping(address => bool) private _isOracle;

    /// @notice Oracle public key hashes for verification
    mapping(address => bytes32) public override oraclePublicKeyHash;

    /// @notice Nonce per dispute to prevent replay attacks
    mapping(uint256 => uint256) public proposalNonces;

    /// @notice Pending proposal requests
    mapping(uint256 => bool) public pendingRequests;

    /// @notice Processed proposals
    mapping(uint256 => bytes32) public processedProposals;

    // ============ Events ============

    /// @notice Emitted when a proposal is requested
    event ProposalRequested(
        uint256 indexed disputeId,
        bytes32 evidenceHash,
        uint256 timestamp
    );

    /// @notice Emitted when proposal is submitted to ILRM
    event ProposalSubmittedToILRM(
        uint256 indexed disputeId,
        bytes32 proposalHash,
        address indexed oracle
    );

    // ============ Errors ============

    error NotILRM(address caller);
    error NotOracle(address caller);
    error InvalidSignature();
    error ProposalAlreadyProcessed(uint256 disputeId);
    error NoRequestPending(uint256 disputeId);
    error InvalidAddress();

    // ============ Constructor ============

    constructor() Ownable(msg.sender) {
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("NatLangChainOracle"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );

        // Register deployer as initial oracle
        _isOracle[msg.sender] = true;
        emit OracleRegistered(msg.sender, bytes32(0));
    }

    // ============ Modifiers ============

    modifier onlyILRM() {
        if (msg.sender != ilrmContract) revert NotILRM(msg.sender);
        _;
    }

    modifier onlyOracle() {
        if (!_isOracle[msg.sender]) revert NotOracle(msg.sender);
        _;
    }

    // ============ Core Functions ============

    /**
     * @inheritdoc IOracle
     * @dev Called by ILRM when dispute enters Active state
     */
    function requestProposal(
        uint256 disputeId,
        bytes32 evidenceHash
    ) external override onlyILRM {
        pendingRequests[disputeId] = true;

        emit ProposalRequested(disputeId, evidenceHash, block.timestamp);
        emit DisputeProcessed(disputeId, evidenceHash, bytes32(0));
    }

    /**
     * @inheritdoc IOracle
     * @dev Called by oracle operator after LLM processing
     */
    function submitProposal(
        uint256 disputeId,
        string calldata proposal,
        bytes calldata signature
    ) external override onlyOracle {
        if (processedProposals[disputeId] != bytes32(0)) {
            revert ProposalAlreadyProcessed(disputeId);
        }

        bytes32 proposalHash = keccak256(bytes(proposal));

        // FIX C-02: Signature is REQUIRED, not optional
        // Empty signature must revert - no bypass allowed
        if (signature.length == 0) {
            revert InvalidSignature();
        }
        if (!verifySignature(disputeId, proposalHash, signature)) {
            revert InvalidSignature();
        }

        // Mark as processed
        processedProposals[disputeId] = proposalHash;
        pendingRequests[disputeId] = false;
        proposalNonces[disputeId]++;

        // Submit to ILRM
        IILRM(ilrmContract).submitLLMProposal(disputeId, proposal, signature);

        emit ProposalSubmittedToILRM(disputeId, proposalHash, msg.sender);
        emit DisputeProcessed(disputeId, bytes32(0), proposalHash);
    }

    /**
     * @inheritdoc IOracle
     */
    function verifySignature(
        uint256 disputeId,
        bytes32 proposalHash,
        bytes calldata signature
    ) public view override returns (bool valid) {
        bytes32 structHash = keccak256(
            abi.encode(
                PROPOSAL_TYPEHASH,
                disputeId,
                proposalHash,
                proposalNonces[disputeId]
            )
        );

        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash)
        );

        address signer = digest.recover(signature);
        return _isOracle[signer];
    }

    /**
     * @notice Verify signature with explicit signer check
     * @param disputeId The dispute ID
     * @param proposalHash Hash of the proposal
     * @param signature Signature to verify
     * @param expectedSigner Expected signer address
     * @return valid True if signature is valid from expected signer
     */
    function verifySignatureFrom(
        uint256 disputeId,
        bytes32 proposalHash,
        bytes calldata signature,
        address expectedSigner
    ) external view returns (bool valid) {
        if (!_isOracle[expectedSigner]) return false;

        bytes32 structHash = keccak256(
            abi.encode(
                PROPOSAL_TYPEHASH,
                disputeId,
                proposalHash,
                proposalNonces[disputeId]
            )
        );

        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash)
        );

        address signer = digest.recover(signature);
        return signer == expectedSigner;
    }

    // ============ View Functions ============

    /**
     * @inheritdoc IOracle
     */
    function isOracle(address account) external view override returns (bool) {
        return _isOracle[account];
    }

    /**
     * @notice Check if a proposal request is pending
     * @param disputeId The dispute ID
     * @return True if request is pending
     */
    function isPending(uint256 disputeId) external view returns (bool) {
        return pendingRequests[disputeId];
    }

    /**
     * @notice Get the current nonce for a dispute
     * @param disputeId The dispute ID
     * @return Current nonce
     */
    function getNonce(uint256 disputeId) external view returns (uint256) {
        return proposalNonces[disputeId];
    }

    // ============ Admin Functions ============

    /**
     * @notice Set the ILRM contract address
     * @param _ilrm New ILRM address
     */
    function setILRM(address _ilrm) external onlyOwner {
        if (_ilrm == address(0)) revert InvalidAddress();
        ilrmContract = _ilrm;
    }

    /**
     * @notice Register a new oracle operator
     * @param oracle Oracle address
     * @param publicKeyHash Hash of oracle's public key
     */
    function registerOracle(
        address oracle,
        bytes32 publicKeyHash
    ) external onlyOwner {
        if (oracle == address(0)) revert InvalidAddress();
        _isOracle[oracle] = true;
        oraclePublicKeyHash[oracle] = publicKeyHash;
        emit OracleRegistered(oracle, publicKeyHash);
    }

    /**
     * @notice Revoke an oracle operator
     * @param oracle Oracle address to revoke
     */
    function revokeOracle(address oracle) external onlyOwner {
        _isOracle[oracle] = false;
        oraclePublicKeyHash[oracle] = bytes32(0);
    }

    /**
     * @notice Update oracle's public key hash
     * @param oracle Oracle address
     * @param publicKeyHash New public key hash
     */
    function updateOracleKey(
        address oracle,
        bytes32 publicKeyHash
    ) external onlyOwner {
        if (!_isOracle[oracle]) revert NotOracle(oracle);
        oraclePublicKeyHash[oracle] = publicKeyHash;
        emit OracleRegistered(oracle, publicKeyHash);
    }
}
