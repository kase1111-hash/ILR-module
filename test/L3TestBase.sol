// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "../contracts/scaling/L3Bridge.sol";
import "../contracts/scaling/L3DisputeBatcher.sol";
import "../contracts/interfaces/IL3Bridge.sol";

/**
 * @title L3TestBase
 * @notice Shared helpers for the L3Bridge / L3DisputeBatcher suites (contains no tests)
 * @dev solc 0.8.20 has no qualified `emit IL3Bridge.Event(...)`, so the events checked with
 *      vm.expectEmit are re-declared here with identical signatures.
 */
abstract contract L3TestBase is Test {
    L3Bridge public l3Bridge;

    address public sequencer;
    uint256 internal sequencerKey;

    uint256 internal constant CHALLENGE_PERIOD = 7 days;

    // ============ Re-declared IL3Bridge events ============

    event DisputeBridgedToL3(
        uint256 indexed l2DisputeId, uint256 indexed l3DisputeId, address indexed initiator, uint256 stakeAmount
    );
    event DisputeSettledFromL3(
        uint256 indexed l2DisputeId,
        uint256 indexed l3DisputeId,
        IL3Bridge.L3DisputeState outcome,
        uint256 initiatorReturn,
        uint256 counterpartyReturn
    );
    event StateCommitmentFinalized(bytes32 indexed stateRoot, uint256 indexed blockNumber);
    event FraudProofSubmitted(bytes32 indexed claimedRoot, uint256 indexed disputeId, address challenger);
    event FraudProofValidated(bytes32 indexed claimedRoot, address indexed challenger, uint256 reward);
    event FraudProofCommitted(
        bytes32 indexed commitHash, bytes32 indexed stateRoot, address indexed challenger, uint256 bond
    );
    event FraudProofRevealed(bytes32 indexed commitHash, bytes32 indexed stateRoot, address indexed challenger);
    event FraudProofRefunded(
        bytes32 indexed commitHash, bytes32 indexed stateRoot, address indexed challenger, uint256 bond
    );
    event FraudProofForfeited(
        bytes32 indexed commitHash, bytes32 indexed stateRoot, address indexed challenger, uint256 bond
    );
    event CommittedChainRolledBack(bytes32 indexed rejectedRoot, bytes32 indexed newHead, uint256 newHeight);
    event DisputeBridgerUpdated(address indexed account, bool authorized);
    event SettlementRelayerUpdated(address indexed account, bool authorized);
    event DisputeBridgeSkipped(uint256 indexed l2DisputeId, uint256 existingL3DisputeId);
    event FeesWithdrawn(address indexed to, uint256 amount);

    // ============ Re-declared L3DisputeBatcher events ============

    event BatchSubmitted(uint256 indexed batchId, uint256 disputeCount, bytes32 batchHash);
    event SettlementBatchProcessed(uint256 indexed batchId, uint256 settlementCount);
    event AutoBatchFailed(uint256 pendingCount, bytes reason);
    event StaleSettlementsDiscarded(address indexed queuedBy, uint256 count);

    // ============ Deployment ============

    /// @notice Deploy the bridge (owned by this test) with a key-backed sequencer and a 7-day period
    function _deployBridge(address ilrm) internal {
        (sequencer, sequencerKey) = makeAddrAndKey("sequencer");
        l3Bridge = new L3Bridge(ilrm);
        l3Bridge.updateSequencerConfig(
            IL3Bridge.SequencerConfig({
                sequencerAddress: sequencer,
                commitmentInterval: 100,
                challengePeriod: CHALLENGE_PERIOD,
                minBatchSize: 1,
                maxBatchSize: 100
            })
        );
    }

    // ============ State Commitments ============

    function _signStateCommitment(bytes32 root, uint256 blockNumber, uint256 disputeCount, bytes32 previousRoot)
        internal
        view
        returns (bytes memory)
    {
        // EIP-191 signature over the packed commitment, as recovered by L3Bridge.submitStateCommitment
        bytes32 messageHash = keccak256(abi.encodePacked(root, blockNumber, disputeCount, previousRoot));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sequencerKey, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }

    function _buildCommitment(bytes32 root, uint256 blockNumber, bytes32 previousRoot)
        internal
        view
        returns (IL3Bridge.StateCommitment memory)
    {
        return IL3Bridge.StateCommitment({
            stateRoot: root,
            blockNumber: blockNumber,
            timestamp: block.timestamp,
            disputeCount: 0,
            previousRoot: previousRoot,
            sequencerSignature: _signStateCommitment(root, blockNumber, 0, previousRoot)
        });
    }

    /// @notice Sequencer submits `root` chained to `previousRoot`
    function _submitCommitment(bytes32 root, uint256 blockNumber, bytes32 previousRoot) internal {
        IL3Bridge.StateCommitment memory commitment = _buildCommitment(root, blockNumber, previousRoot);
        vm.prank(sequencer);
        l3Bridge.submitStateCommitment(commitment);
    }

    /// @notice Sequencer submits `root` on top of the current committed head
    function _submitOnHead(bytes32 root) internal {
        uint256 blockNumber = l3Bridge.latestCommittedHeight() + 1;
        bytes32 previousRoot = l3Bridge.latestCommittedRoot();
        _submitCommitment(root, blockNumber, previousRoot);
    }

    // ============ Fraud Proofs ============

    /// @notice A self-consistent fraud proof for root keccak256(data) with an empty Merkle path
    /// @dev L3Bridge._verifyFraudProof accepts keccak256(invalidStateData) == claimedRoot with an empty path
    function _proofFor(bytes memory invalidStateData) internal pure returns (IL3Bridge.FraudProof memory) {
        return IL3Bridge.FraudProof({
            claimedRoot: keccak256(invalidStateData),
            correctRoot: keccak256("correct_state"),
            merkleProof: new bytes32[](0),
            disputeId: 0,
            invalidStateData: invalidStateData
        });
    }

    /// @notice Sequencer commits a fraudulent root (root = keccak256(data)) on the head; returns a valid proof
    function _commitFraudulentState(bytes memory invalidStateData)
        internal
        returns (bytes32 stateRoot, IL3Bridge.FraudProof memory proof)
    {
        proof = _proofFor(invalidStateData);
        stateRoot = proof.claimedRoot;
        _submitOnHead(stateRoot);
    }

    /// @notice Independent mirror of L3Bridge's domain-separated, challenger-bound commit hash
    /// @dev Makes no external call, so it is safe to use as an argument after vm.prank
    function _commitHash(address challenger, IL3Bridge.FraudProof memory proof, bytes32 salt)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                keccak256(
                    "L3Bridge.FraudProofCommit(uint256 chainId,address bridge,address challenger,bytes32 proofHash,bytes32 salt)"
                ),
                block.chainid,
                address(l3Bridge),
                challenger,
                keccak256(abi.encode(proof)),
                salt
            )
        );
    }
}
