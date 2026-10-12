// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "./L3TestBase.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title L3BridgeFraudProofTest
 * @notice Fraud-proof commit-reveal, bond accounting, canonical chain and finalization tests for L3Bridge
 */
contract L3BridgeFraudProofTest is L3TestBase {
    struct TrackedCommit {
        address challenger;
        bytes32 commitHash;
    }

    uint256 internal constant BOND = 0.1 ether;
    uint256 internal constant REWARD = 0.05 ether;
    uint256 internal constant REVEAL_DELAY = 2 minutes;
    uint256 internal constant REVEAL_EXPIRY = 2 minutes + 1 hours; // MIN_REVEAL_DELAY + MAX_REVEAL_WINDOW

    address internal ilrm = makeAddr("ilrm");
    address internal honest = makeAddr("honest");
    address internal griefer = makeAddr("griefer");
    address internal attacker = makeAddr("attacker");
    address internal challengerX = makeAddr("challengerX");
    address internal challengerY = makeAddr("challengerY");
    address internal keeper = makeAddr("keeper");

    address[] internal _actors;
    TrackedCommit[] internal _tracked;

    function setUp() public {
        _deployBridge(ilrm);
        vm.deal(address(l3Bridge), 10 ether); // Reward pool

        _actors.push(honest);
        _actors.push(griefer);
        _actors.push(attacker);
        _actors.push(challengerX);
        _actors.push(challengerY);
        _actors.push(keeper);
        for (uint256 i = 0; i < _actors.length; i++) {
            vm.deal(_actors[i], 10 ether);
        }
    }

    // ============ Helpers ============

    /// @notice Solvency and escrow invariants (I1, I2), checked at the end of every test
    modifier solvent() {
        _;
        _assertSolvent();
    }

    function _assertSolvent() internal view {
        uint256 escrowed = l3Bridge.totalEscrowedBonds();
        assertGe(address(l3Bridge).balance, escrowed, "I1: balance < escrowed bonds");

        uint256 sumChallengerBonds;
        for (uint256 i = 0; i < _actors.length; i++) {
            sumChallengerBonds += l3Bridge.challengerBonds(_actors[i]);
        }
        assertEq(sumChallengerBonds, escrowed, "I2: sum(challengerBonds) != totalEscrowedBonds");

        uint256 sumPending;
        for (uint256 i = 0; i < _tracked.length; i++) {
            IL3Bridge.FraudProofCommitment memory c =
                l3Bridge.getFraudProofCommitment(_tracked[i].challenger, _tracked[i].commitHash);
            if (c.status == IL3Bridge.CommitmentStatus.Pending) sumPending += c.bond;
        }
        assertEq(sumPending, escrowed, "I2: sum(Pending bonds) != totalEscrowedBonds");
    }

    function _commitRaw(address who, bytes32 commitHash, bytes32 root) internal {
        vm.prank(who);
        l3Bridge.commitFraudProof{value: BOND}(commitHash, root);
        _tracked.push(TrackedCommit(who, commitHash));
    }

    function _commit(address who, IL3Bridge.FraudProof memory proof, bytes32 salt, bytes32 root)
        internal
        returns (bytes32 commitHash)
    {
        commitHash = _commitHash(who, proof, salt);
        _commitRaw(who, commitHash, root);
    }

    function _reveal(address who, IL3Bridge.FraudProof memory proof, bytes32 salt) internal {
        vm.prank(who);
        l3Bridge.revealFraudProof(proof, salt);
    }

    function _status(address who, bytes32 commitHash) internal view returns (IL3Bridge.CommitmentStatus) {
        return l3Bridge.getFraudProofCommitment(who, commitHash).status;
    }

    function _assertStatus(address who, bytes32 commitHash, IL3Bridge.CommitmentStatus expected) internal view {
        assertEq(uint256(_status(who, commitHash)), uint256(expected), "commitment status");
    }

    // ============ Commit hash ============

    function test_CommitHashFormula() public view solvent {
        IL3Bridge.FraudProof memory proof = _proofFor(bytes("some_state"));
        bytes32 salt = keccak256("salt");

        assertEq(
            l3Bridge.FRAUD_PROOF_COMMIT_TYPEHASH(),
            keccak256(
                "L3Bridge.FraudProofCommit(uint256 chainId,address bridge,address challenger,bytes32 proofHash,bytes32 salt)"
            )
        );
        assertEq(l3Bridge.FRAUD_PROOF_REWARD(), REWARD);

        bytes32 commitHash = l3Bridge.computeFraudProofCommitHash(honest, proof, salt);
        assertEq(commitHash, _commitHash(honest, proof, salt));

        // Bound to the challenger, the salt and the full proof (including the Merkle path)
        assertTrue(commitHash != l3Bridge.computeFraudProofCommitHash(attacker, proof, salt));
        assertTrue(commitHash != l3Bridge.computeFraudProofCommitHash(honest, proof, keccak256("other_salt")));

        IL3Bridge.FraudProof memory otherPath = _proofFor(bytes("some_state"));
        otherPath.merkleProof = new bytes32[](1);
        otherPath.merkleProof[0] = keccak256("sibling");
        assertTrue(commitHash != l3Bridge.computeFraudProofCommitHash(honest, otherPath, salt));
    }

    // ============ Griefing ============

    function test_ConcurrentCommitments_GrieferCannotBlockHonest() public solvent {
        (bytes32 root, IL3Bridge.FraudProof memory proof) = _commitFraudulentState(bytes("fraud_state"));
        uint256 deadline = l3Bridge.getChallengeDeadline(root);

        // Griefer holds a live junk commitment on the root
        bytes32 junk = keccak256("junk");
        _commitRaw(griefer, junk, root);

        // Honest commit in the same block succeeds
        bytes32 salt = keccak256("honest_salt");
        bytes32 commitHash = _commit(honest, proof, salt, root);
        _assertStatus(griefer, junk, IL3Bridge.CommitmentStatus.Pending);
        _assertStatus(honest, commitHash, IL3Bridge.CommitmentStatus.Pending);
        assertEq(l3Bridge.totalEscrowedBonds(), 2 * BOND);

        vm.warp(block.timestamp + REVEAL_DELAY);
        uint256 balanceBefore = honest.balance;
        _reveal(honest, proof, salt);

        assertEq(honest.balance, balanceBefore + BOND + REWARD);
        _assertStatus(honest, commitHash, IL3Bridge.CommitmentStatus.Won);
        assertEq(l3Bridge.getActiveChallenger(root), honest);

        vm.warp(deadline);
        vm.expectRevert(abi.encodeWithSelector(IL3Bridge.InvalidStateRoot.selector, root));
        l3Bridge.finalizeStateCommitment(root);
    }

    function test_RollingGriefing_HonestCanAlwaysCommit() public solvent {
        (bytes32 root, IL3Bridge.FraudProof memory proof) = _commitFraudulentState(bytes("fraud_state"));

        // Griefer re-commits at every expiry for 5 cycles
        bytes32[] memory grieferHashes = new bytes32[](5);
        for (uint256 i = 0; i < 5; i++) {
            grieferHashes[i] = keccak256(abi.encode("junk", i));
            _commitRaw(griefer, grieferHashes[i], root);
            if (i < 4) vm.warp(block.timestamp + REVEAL_EXPIRY + 1);
        }
        uint256 lastGrieferCommit = block.timestamp;
        assertEq(l3Bridge.challengerBonds(griefer), 5 * BOND);

        // While the griefer's latest commitment is live, the honest commit still succeeds and wins
        vm.warp(block.timestamp + 60);
        bytes32 salt = keccak256("honest_salt");
        bytes32 commitHash = _commit(honest, proof, salt, root);

        vm.warp(block.timestamp + REVEAL_DELAY);
        uint256 balanceBefore = honest.balance;
        _reveal(honest, proof, salt);
        assertEq(honest.balance, balanceBefore + BOND + REWARD);
        _assertStatus(honest, commitHash, IL3Bridge.CommitmentStatus.Won);
        assertEq(l3Bridge.getActiveChallenger(root), honest);

        // Every griefer bond is forfeited by a third party once expired
        vm.warp(lastGrieferCommit + REVEAL_EXPIRY + 1);
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(keeper);
            l3Bridge.forfeitExpiredCommitment(griefer, grieferHashes[i]);
            _assertStatus(griefer, grieferHashes[i], IL3Bridge.CommitmentStatus.Forfeited);
        }
        assertEq(l3Bridge.totalEscrowedBonds(), 0);
        assertEq(l3Bridge.challengerBonds(griefer), 0);
    }

    function test_CopiedCommitHashCannotStealReveal() public solvent {
        (bytes32 root, IL3Bridge.FraudProof memory proof) = _commitFraudulentState(bytes("fraud_state"));
        bytes32 salt = keccak256("honest_salt");
        bytes32 honestHash = _commitHash(honest, proof, salt);

        // Attacker copies the honest hash from the mempool and commits it first
        _commitRaw(attacker, honestHash, root);
        uint256 attackerCommitTime = block.timestamp;

        // The honest commit still succeeds
        _commitRaw(honest, honestHash, root);

        // Attacker sees the honest proof + salt and reveals first: it does not match its own commitment
        vm.warp(block.timestamp + REVEAL_DELAY);
        vm.prank(attacker);
        vm.expectRevert(IL3Bridge.CommitmentNotFound.selector);
        l3Bridge.revealFraudProof(proof, salt);

        uint256 balanceBefore = honest.balance;
        _reveal(honest, proof, salt);
        assertEq(honest.balance, balanceBefore + BOND + REWARD);
        _assertStatus(honest, honestHash, IL3Bridge.CommitmentStatus.Won);
        assertEq(l3Bridge.getActiveChallenger(root), honest);

        // The attacker's copy can be forfeited after it expires
        vm.warp(attackerCommitTime + REVEAL_EXPIRY + 1);
        vm.prank(keeper);
        l3Bridge.forfeitExpiredCommitment(attacker, honestHash);
        _assertStatus(attacker, honestHash, IL3Bridge.CommitmentStatus.Forfeited);
        assertEq(l3Bridge.totalEscrowedBonds(), 0);
    }

    // ============ Reveal outcomes ============

    function test_RevealForDifferentRootIsForfeited() public solvent {
        (bytes32 rootA, IL3Bridge.FraudProof memory proofA) = _commitFraudulentState(bytes("fraud_state_A"));

        // Self-consistent proof for a root B that was never committed
        IL3Bridge.FraudProof memory proofB = _proofFor(bytes("fraud_state_B"));
        bytes32 rootB = proofB.claimedRoot;

        bytes32 salt = keccak256("attacker_salt");
        bytes32 commitHash = _commit(attacker, proofB, salt, rootA);
        uint256 freeBefore = l3Bridge.freeBalance();
        uint256 balanceBefore = attacker.balance;

        vm.warp(block.timestamp + REVEAL_DELAY);
        vm.expectEmit(address(l3Bridge));
        emit FraudProofRevealed(commitHash, rootA, attacker);
        vm.expectEmit(address(l3Bridge));
        emit FraudProofForfeited(commitHash, rootA, attacker, BOND);
        _reveal(attacker, proofB, salt);

        _assertStatus(attacker, commitHash, IL3Bridge.CommitmentStatus.Forfeited);
        assertEq(attacker.balance, balanceBefore);
        assertEq(l3Bridge.getActiveChallenger(rootA), address(0));
        assertEq(l3Bridge.getActiveChallenger(rootB), address(0));
        assertEq(l3Bridge.totalEscrowedBonds(), 0);
        assertEq(l3Bridge.freeBalance(), freeBefore + BOND);
        assertTrue(l3Bridge.isStateCanonical(rootA));

        // A different challenger can still commit against A and win
        bytes32 honestSalt = keccak256("honest_salt");
        bytes32 honestHash = _commit(honest, proofA, honestSalt, rootA);
        vm.warp(block.timestamp + REVEAL_DELAY);
        uint256 honestBefore = honest.balance;
        _reveal(honest, proofA, honestSalt);
        assertEq(honest.balance, honestBefore + BOND + REWARD);
        _assertStatus(honest, honestHash, IL3Bridge.CommitmentStatus.Won);
        assertEq(l3Bridge.getActiveChallenger(rootA), honest);
    }

    function test_InvalidProofRevealIsForfeitedNotReverted() public solvent {
        (bytes32 root,) = _commitFraudulentState(bytes("fraud_state"));

        // claimedRoot matches the committed root, but the data does not hash to it
        IL3Bridge.FraudProof memory badProof = _proofFor(bytes("unrelated_data"));
        badProof.claimedRoot = root;

        bytes32 salt = keccak256("attacker_salt");
        bytes32 commitHash = _commit(attacker, badProof, salt, root);
        uint256 balanceBefore = attacker.balance;
        uint256 freeBefore = l3Bridge.freeBalance();

        vm.warp(block.timestamp + REVEAL_DELAY);
        vm.expectEmit(address(l3Bridge));
        emit FraudProofForfeited(commitHash, root, attacker, BOND);
        _reveal(attacker, badProof, salt);

        _assertStatus(attacker, commitHash, IL3Bridge.CommitmentStatus.Forfeited);
        assertEq(attacker.balance, balanceBefore);
        assertEq(l3Bridge.getActiveChallenger(root), address(0));
        assertEq(l3Bridge.totalEscrowedBonds(), 0);
        assertEq(l3Bridge.freeBalance(), freeBefore + BOND);
        assertTrue(l3Bridge.isStateCanonical(root));
    }

    function test_SecondValidRevealRefunded() public solvent {
        (bytes32 root, IL3Bridge.FraudProof memory proof) = _commitFraudulentState(bytes("fraud_state"));

        bytes32 saltX = keccak256("x_salt");
        bytes32 saltY = keccak256("y_salt");
        bytes32 hashX = _commit(challengerX, proof, saltX, root);
        bytes32 hashY = _commit(challengerY, proof, saltY, root);

        vm.warp(block.timestamp + REVEAL_DELAY);
        uint256 xBefore = challengerX.balance;
        _reveal(challengerX, proof, saltX);
        assertEq(challengerX.balance, xBefore + BOND + REWARD);
        _assertStatus(challengerX, hashX, IL3Bridge.CommitmentStatus.Won);

        uint256 yBefore = challengerY.balance;
        vm.expectEmit(address(l3Bridge));
        emit FraudProofRefunded(hashY, root, challengerY, BOND);
        _reveal(challengerY, proof, saltY);
        assertEq(challengerY.balance, yBefore + BOND);
        _assertStatus(challengerY, hashY, IL3Bridge.CommitmentStatus.Refunded);

        assertEq(l3Bridge.getActiveChallenger(root), challengerX);
        assertEq(l3Bridge.totalEscrowedBonds(), 0);
    }

    function test_ForfeitExpiredCommitment() public solvent {
        (bytes32 root, IL3Bridge.FraudProof memory proof) = _commitFraudulentState(bytes("fraud_state"));
        bytes32 salt = keccak256("griefer_salt");
        bytes32 commitHash = _commit(griefer, proof, salt, root);
        uint256 expiry = block.timestamp + REVEAL_EXPIRY;

        assertEq(l3Bridge.totalEscrowedBonds(), BOND);
        assertEq(l3Bridge.challengerBonds(griefer), BOND);

        // Not forfeitable while the reveal window is open
        vm.expectRevert(abi.encodeWithSelector(IL3Bridge.CommitmentNotExpired.selector, REVEAL_EXPIRY + 1));
        l3Bridge.forfeitExpiredCommitment(griefer, commitHash);
        vm.warp(expiry);
        vm.expectRevert(abi.encodeWithSelector(IL3Bridge.CommitmentNotExpired.selector, 1));
        l3Bridge.forfeitExpiredCommitment(griefer, commitHash);

        // After expiry anyone can forfeit it
        vm.warp(expiry + 1);
        vm.expectEmit(address(l3Bridge));
        emit FraudProofForfeited(commitHash, root, griefer, BOND);
        vm.prank(keeper);
        l3Bridge.forfeitExpiredCommitment(griefer, commitHash);

        _assertStatus(griefer, commitHash, IL3Bridge.CommitmentStatus.Forfeited);
        assertEq(l3Bridge.totalEscrowedBonds(), 0);
        assertEq(l3Bridge.challengerBonds(griefer), 0);

        // A second forfeit and a late reveal both see a settled commitment
        vm.expectRevert(IL3Bridge.AlreadyRevealed.selector);
        l3Bridge.forfeitExpiredCommitment(griefer, commitHash);
        vm.prank(griefer);
        vm.expectRevert(IL3Bridge.AlreadyRevealed.selector);
        l3Bridge.revealFraudProof(proof, salt);

        // The record is kept, so the same (challenger, hash) cannot be reused
        vm.prank(griefer);
        vm.expectRevert(IL3Bridge.InvalidCommitment.selector);
        l3Bridge.commitFraudProof{value: BOND}(commitHash, root);

        // Unknown commitment
        vm.expectRevert(IL3Bridge.CommitmentNotFound.selector);
        l3Bridge.forfeitExpiredCommitment(griefer, keccak256("unknown"));
    }

    // ============ Bond escrow ============

    function test_RewardNeverPaidFromEscrow() public solvent {
        vm.deal(address(l3Bridge), 0); // No reward pool

        (bytes32 root1, IL3Bridge.FraudProof memory proof1) = _commitFraudulentState(bytes("fraud_state_1"));
        (bytes32 root2, IL3Bridge.FraudProof memory proof2) = _commitFraudulentState(bytes("fraud_state_2"));

        bytes32 saltX = keccak256("x_salt");
        bytes32 saltY = keccak256("y_salt");
        bytes32 hashX = _commit(challengerX, proof2, saltX, root2);
        bytes32 hashY = _commit(challengerY, proof1, saltY, root1);

        vm.warp(block.timestamp + REVEAL_DELAY);

        // X wins on R2, but there is no free balance for a reward: Y's escrowed bond is untouched
        uint256 xBefore = challengerX.balance;
        vm.expectEmit(address(l3Bridge));
        emit FraudProofValidated(root2, challengerX, 0);
        _reveal(challengerX, proof2, saltX);
        assertEq(challengerX.balance, xBefore + BOND);
        _assertStatus(challengerX, hashX, IL3Bridge.CommitmentStatus.Won);
        assertEq(l3Bridge.totalEscrowedBonds(), BOND);
        assertEq(address(l3Bridge).balance, BOND);

        // R1 is still canonical after the rollback; Y's reveal wins and is paid its bond
        assertTrue(l3Bridge.isStateCanonical(root1));
        assertEq(l3Bridge.latestCommittedRoot(), root1);
        uint256 yBefore = challengerY.balance;
        _reveal(challengerY, proof1, saltY);
        assertEq(challengerY.balance, yBefore + BOND);
        _assertStatus(challengerY, hashY, IL3Bridge.CommitmentStatus.Won);
        assertEq(l3Bridge.getActiveChallenger(root1), challengerY);
        assertEq(address(l3Bridge).balance, 0);
        assertEq(l3Bridge.totalEscrowedBonds(), 0);
    }

    function test_WithdrawFeesCannotTakeEscrow() public solvent {
        (bytes32 root, IL3Bridge.FraudProof memory proof) = _commitFraudulentState(bytes("fraud_state"));
        bytes32 salt = keccak256("honest_salt");
        bytes32 commitHash = _commit(honest, proof, salt, root);

        address feeRecipient = makeAddr("feeRecipient");
        uint256 balance = address(l3Bridge).balance;
        uint256 available = l3Bridge.freeBalance();
        assertEq(available, balance - BOND);

        vm.expectRevert(abi.encodeWithSelector(IL3Bridge.InsufficientFreeBalance.selector, balance, available));
        l3Bridge.withdrawFees(feeRecipient, balance);

        vm.expectEmit(address(l3Bridge));
        emit FeesWithdrawn(feeRecipient, available);
        l3Bridge.withdrawFees(feeRecipient, available);
        assertEq(feeRecipient.balance, available);
        assertEq(address(l3Bridge).balance, BOND);
        assertEq(l3Bridge.freeBalance(), 0);

        // The honest reveal is still paid (its bond; no free balance is left for a reward)
        vm.warp(block.timestamp + REVEAL_DELAY);
        uint256 balanceBefore = honest.balance;
        _reveal(honest, proof, salt);
        assertEq(honest.balance, balanceBefore + BOND);
        _assertStatus(honest, commitHash, IL3Bridge.CommitmentStatus.Won);
    }

    // ============ Deadlines ============

    function test_ChallengeDeadlineSnapshottedAtSubmission() public solvent {
        uint256 t0 = block.timestamp;
        bytes32 honestRoot = keccak256("honest_state");
        _submitOnHead(honestRoot);
        (bytes32 fraudRoot, IL3Bridge.FraudProof memory proof) = _commitFraudulentState(bytes("fraud_state"));
        assertEq(l3Bridge.getChallengeDeadline(honestRoot), t0 + CHALLENGE_PERIOD);

        // Owner shortens the period after submission; existing roots keep their deadline
        IL3Bridge.SequencerConfig memory config = l3Bridge.getSequencerConfig();
        config.challengePeriod = 1 days;
        l3Bridge.updateSequencerConfig(config);
        assertEq(l3Bridge.getChallengeDeadline(fraudRoot), t0 + CHALLENGE_PERIOD);

        vm.warp(t0 + 1 days + 1);
        vm.expectRevert(
            abi.encodeWithSelector(IL3Bridge.ChallengePeriodNotPassed.selector, CHALLENGE_PERIOD - 1 days - 1)
        );
        l3Bridge.finalizeStateCommitment(honestRoot);

        // Still challengeable two days in
        vm.warp(t0 + 2 days);
        bytes32 salt = keccak256("honest_salt");
        bytes32 commitHash = _commit(honest, proof, salt, fraudRoot);
        vm.warp(block.timestamp + REVEAL_DELAY);
        _reveal(honest, proof, salt);
        _assertStatus(honest, commitHash, IL3Bridge.CommitmentStatus.Won);
        assertEq(l3Bridge.getActiveChallenger(fraudRoot), honest);

        vm.warp(t0 + CHALLENGE_PERIOD);
        l3Bridge.finalizeStateCommitment(honestRoot);
        assertTrue(l3Bridge.isStateFinalized(honestRoot));
    }

    function testFuzz_NoRevealWindowOpenWhenFinalizable(uint256 offset) public solvent {
        offset = bound(offset, 0, CHALLENGE_PERIOD);
        uint256 t0 = block.timestamp;
        bytes32 root = keccak256("honest_state");
        _submitOnHead(root);

        IL3Bridge.FraudProof memory proof = _proofFor(bytes("not_this_root"));
        proof.claimedRoot = root;
        bytes32 salt = keccak256("salt");
        bytes32 commitHash = _commitHash(honest, proof, salt);

        vm.warp(t0 + offset);
        if (offset + REVEAL_EXPIRY >= CHALLENGE_PERIOD) {
            vm.prank(honest);
            vm.expectRevert(IL3Bridge.ChallengePeriodExpired.selector);
            l3Bridge.commitFraudProof{value: BOND}(commitHash, root);
            return;
        }

        _commitRaw(honest, commitHash, root);
        uint256 deadline = l3Bridge.getChallengeDeadline(root);
        assertLt(block.timestamp + REVEAL_EXPIRY, deadline, "I3: reveal window reaches the deadline");

        vm.warp(deadline);
        vm.prank(honest);
        vm.expectRevert(IL3Bridge.RevealTooLate.selector);
        l3Bridge.revealFraudProof(proof, salt);

        l3Bridge.finalizeStateCommitment(root);
        assertTrue(l3Bridge.isStateFinalized(root));
    }

    // ============ Canonical chain & finalization ============

    function test_DescendantOfChallengedRootNeverFinalizes() public solvent {
        (bytes32 root1, IL3Bridge.FraudProof memory proof1) = _commitFraudulentState(bytes("fraud_state_1"));
        bytes32 root2 = keccak256("state_2");
        bytes32 root3 = keccak256("state_3");
        _submitOnHead(root2);
        _submitOnHead(root3);
        assertEq(l3Bridge.latestCommittedHeight(), 3);

        bytes32 salt = keccak256("honest_salt");
        _commit(honest, proof1, salt, root1);
        vm.warp(block.timestamp + REVEAL_DELAY);
        vm.expectEmit(address(l3Bridge));
        emit CommittedChainRolledBack(root1, bytes32(0), 0);
        _reveal(honest, proof1, salt);

        assertEq(l3Bridge.latestCommittedRoot(), bytes32(0));
        assertEq(l3Bridge.latestCommittedHeight(), 0);
        assertFalse(l3Bridge.isStateCanonical(root1));
        assertFalse(l3Bridge.isStateCanonical(root2));
        assertFalse(l3Bridge.isStateCanonical(root3));

        // Orphaned descendants cannot be challenged...
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IL3Bridge.StateRootNotCanonical.selector, root3));
        l3Bridge.commitFraudProof{value: BOND}(keccak256("junk"), root3);

        // ...the sequencer rebuilds from the rejected root's parent
        bytes32 root1b = keccak256("state_1b");
        bytes32 root2b = keccak256("state_2b");
        _submitOnHead(root1b);
        _submitOnHead(root2b);
        assertEq(l3Bridge.getStateCommitment(root1b).previousRoot, bytes32(0));
        assertEq(l3Bridge.getRootHeight(root2b), 2);

        // ...and orphaned descendants never finalize
        vm.warp(block.timestamp + CHALLENGE_PERIOD);
        vm.expectRevert(abi.encodeWithSelector(IL3Bridge.StateRootNotCanonical.selector, root2));
        l3Bridge.finalizeStateCommitment(root2);
        vm.expectRevert(abi.encodeWithSelector(IL3Bridge.StateRootNotCanonical.selector, root3));
        l3Bridge.finalizeStateCommitment(root3);
        vm.expectRevert(abi.encodeWithSelector(IL3Bridge.InvalidStateRoot.selector, root1));
        l3Bridge.finalizeStateCommitment(root1);

        vm.expectRevert(abi.encodeWithSelector(IL3Bridge.ParentNotFinalized.selector, root1b));
        l3Bridge.finalizeStateCommitment(root2b);
        l3Bridge.finalizeStateCommitment(root1b);
        l3Bridge.finalizeStateCommitment(root2b);

        assertEq(l3Bridge.latestFinalizedHeight(), 2);
        assertEq(l3Bridge.latestFinalizedRoot(), root2b);
        assertFalse(l3Bridge.isStateFinalized(root2));
        assertFalse(l3Bridge.isStateFinalized(root3));
    }

    function test_MidChainChallengeRollsBackHead() public solvent {
        bytes32 root1 = keccak256("state_1");
        _submitOnHead(root1);
        (bytes32 root2, IL3Bridge.FraudProof memory proof2) = _commitFraudulentState(bytes("fraud_state_2"));
        bytes32 root3 = keccak256("state_3");
        _submitOnHead(root3);

        bytes32 salt = keccak256("honest_salt");
        _commit(honest, proof2, salt, root2);
        vm.warp(block.timestamp + REVEAL_DELAY);
        vm.expectEmit(address(l3Bridge));
        emit CommittedChainRolledBack(root2, root1, 1);
        _reveal(honest, proof2, salt);

        assertEq(l3Bridge.latestCommittedRoot(), root1);
        assertEq(l3Bridge.latestCommittedHeight(), 1);
        assertTrue(l3Bridge.isStateCanonical(root1));
        assertFalse(l3Bridge.isStateCanonical(root2));
        assertFalse(l3Bridge.isStateCanonical(root3));

        // The sequencer can rebuild on R1
        bytes32 root2b = keccak256("state_2b");
        _submitCommitment(root2b, 2, root1);
        assertEq(l3Bridge.latestCommittedRoot(), root2b);
        assertEq(l3Bridge.getRootHeight(root2b), 2);
        assertTrue(l3Bridge.isStateCanonical(root2b));
    }

    function test_OrphanedCommitmentRefunded() public solvent {
        (bytes32 root1, IL3Bridge.FraudProof memory proof1) = _commitFraudulentState(bytes("fraud_state_1"));
        (bytes32 root2, IL3Bridge.FraudProof memory proof2) = _commitFraudulentState(bytes("fraud_state_2"));

        // Y commits a valid proof on R2 before R1 is challenged
        bytes32 saltY = keccak256("y_salt");
        bytes32 hashY = _commit(challengerY, proof2, saltY, root2);
        bytes32 saltX = keccak256("x_salt");
        _commit(challengerX, proof1, saltX, root1);

        vm.warp(block.timestamp + REVEAL_DELAY);
        _reveal(challengerX, proof1, saltX);
        assertEq(l3Bridge.latestCommittedRoot(), bytes32(0));
        assertEq(l3Bridge.latestCommittedHeight(), 0);

        uint256 yBefore = challengerY.balance;
        vm.expectEmit(address(l3Bridge));
        emit FraudProofRefunded(hashY, root2, challengerY, BOND);
        _reveal(challengerY, proof2, saltY);

        assertEq(challengerY.balance, yBefore + BOND);
        _assertStatus(challengerY, hashY, IL3Bridge.CommitmentStatus.Refunded);
        assertEq(l3Bridge.getActiveChallenger(root2), address(0));
        // The head is unchanged by the refund
        assertEq(l3Bridge.latestCommittedRoot(), bytes32(0));
        assertEq(l3Bridge.latestCommittedHeight(), 0);
    }

    function test_FinalizeInChainOrder() public solvent {
        bytes32 root1 = keccak256("state_1");
        bytes32 root2 = keccak256("state_2");
        _submitOnHead(root1);
        _submitOnHead(root2);

        vm.warp(block.timestamp + CHALLENGE_PERIOD);
        vm.expectRevert(abi.encodeWithSelector(IL3Bridge.ParentNotFinalized.selector, root1));
        l3Bridge.finalizeStateCommitment(root2);

        l3Bridge.finalizeStateCommitment(root1);
        assertEq(l3Bridge.latestFinalizedRoot(), root1);
        assertEq(l3Bridge.latestFinalizedHeight(), 1);

        l3Bridge.finalizeStateCommitment(root2);
        assertEq(l3Bridge.latestFinalizedRoot(), root2);
        assertEq(l3Bridge.latestFinalizedHeight(), 2);

        // Re-finalizing an ancestor is a no-op and never moves the finalized head backwards
        l3Bridge.finalizeStateCommitment(root1);
        assertEq(l3Bridge.latestFinalizedRoot(), root2);
        assertEq(l3Bridge.latestFinalizedHeight(), 2);
        assertGe(l3Bridge.latestCommittedHeight(), l3Bridge.latestFinalizedHeight());
    }

    // ============ Pause ============

    function test_PauseFreezesFinalizeNotChallenges() public solvent {
        uint256 t0 = block.timestamp;
        bytes32 honestRoot = keccak256("honest_state");
        _submitOnHead(honestRoot);
        (bytes32 fraudRoot, IL3Bridge.FraudProof memory proof) = _commitFraudulentState(bytes("fraud_state"));

        l3Bridge.pause();

        // Commit works while paused
        bytes32 junk = keccak256("junk");
        _commitRaw(griefer, junk, fraudRoot);
        bytes32 salt = keccak256("honest_salt");
        bytes32 commitHash = _commit(honest, proof, salt, fraudRoot);

        // Reveal works while paused
        vm.warp(block.timestamp + REVEAL_DELAY);
        _reveal(honest, proof, salt);
        _assertStatus(honest, commitHash, IL3Bridge.CommitmentStatus.Won);

        // Forfeit works while paused
        vm.warp(t0 + REVEAL_EXPIRY + 1);
        vm.prank(keeper);
        l3Bridge.forfeitExpiredCommitment(griefer, junk);
        _assertStatus(griefer, junk, IL3Bridge.CommitmentStatus.Forfeited);

        // Legacy submission works while paused
        (bytes32 fraudRoot2, IL3Bridge.FraudProof memory proof2) = _commitFraudulentState(bytes("fraud_state_2"));
        l3Bridge.setCommitRevealEnabled(false);
        vm.prank(attacker);
        l3Bridge.submitFraudProof{value: BOND}(proof2);
        assertEq(l3Bridge.getActiveChallenger(fraudRoot2), attacker);

        // Finalization is frozen
        vm.warp(t0 + CHALLENGE_PERIOD);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        l3Bridge.finalizeStateCommitment(honestRoot);

        l3Bridge.unpause();
        l3Bridge.finalizeStateCommitment(honestRoot);
        assertTrue(l3Bridge.isStateFinalized(honestRoot));
    }

    // ============ Misc ============

    function test_ZeroStateRootRejected() public solvent {
        IL3Bridge.StateCommitment memory commitment = _buildCommitment(bytes32(0), 1, bytes32(0));
        vm.prank(sequencer);
        vm.expectRevert(abi.encodeWithSelector(IL3Bridge.InvalidStateRoot.selector, bytes32(0)));
        l3Bridge.submitStateCommitment(commitment);
        assertEq(l3Bridge.latestCommittedHeight(), 0);
    }

    function test_LegacySubmitFraudProofAccounting() public solvent {
        vm.deal(address(l3Bridge), 0.02 ether); // Free balance below the fixed reward

        (bytes32 root1, IL3Bridge.FraudProof memory proof1) = _commitFraudulentState(bytes("fraud_state_1"));
        (bytes32 root2, IL3Bridge.FraudProof memory proof2) = _commitFraudulentState(bytes("fraud_state_2"));

        // Another challenger's bond is escrowed under commit-reveal
        bytes32 saltY = keccak256("y_salt");
        bytes32 hashY = _commit(challengerY, proof1, saltY, root1);

        l3Bridge.setCommitRevealEnabled(false);
        vm.prank(honest);
        vm.expectRevert(bytes("Commit-reveal disabled"));
        l3Bridge.commitFraudProof{value: BOND}(keccak256("late"), root1);

        // An invalid proof still reverts on the legacy path
        IL3Bridge.FraudProof memory badProof = _proofFor(bytes("unrelated_data"));
        badProof.claimedRoot = root2;
        vm.prank(attacker);
        vm.expectRevert(IL3Bridge.InvalidFraudProof.selector);
        l3Bridge.submitFraudProof{value: BOND}(badProof);

        uint256 available = l3Bridge.freeBalance();
        assertEq(available, 0.02 ether);
        uint256 attackerBefore = attacker.balance;
        vm.expectEmit(address(l3Bridge));
        emit FraudProofValidated(root2, attacker, available);
        vm.prank(attacker);
        l3Bridge.submitFraudProof{value: BOND}(proof2);

        // Reward capped at free balance, escrow untouched
        assertEq(attacker.balance, attackerBefore + available);
        assertLe(available, REWARD);
        assertEq(l3Bridge.totalEscrowedBonds(), BOND);
        assertEq(l3Bridge.challengerBonds(challengerY), BOND);
        assertEq(address(l3Bridge).balance, BOND);
        assertEq(l3Bridge.getActiveChallenger(root2), attacker);
        assertEq(l3Bridge.latestCommittedRoot(), root1);

        // The earlier commitment can still be revealed after commit-reveal was disabled
        vm.warp(block.timestamp + REVEAL_DELAY);
        uint256 yBefore = challengerY.balance;
        _reveal(challengerY, proof1, saltY);
        assertEq(challengerY.balance, yBefore + BOND);
        _assertStatus(challengerY, hashY, IL3Bridge.CommitmentStatus.Won);
        assertEq(l3Bridge.totalEscrowedBonds(), 0);
    }

    function test_CommitInputValidation() public solvent {
        (bytes32 root,) = _commitFraudulentState(bytes("fraud_state"));

        vm.startPrank(honest);
        vm.expectRevert(IL3Bridge.InsufficientChallengerBond.selector);
        l3Bridge.commitFraudProof{value: BOND - 1}(keccak256("c"), root);

        vm.expectRevert(IL3Bridge.InvalidCommitment.selector);
        l3Bridge.commitFraudProof{value: BOND}(bytes32(0), root);

        bytes32 unknownRoot = keccak256("never_committed");
        vm.expectRevert(abi.encodeWithSelector(IL3Bridge.InvalidStateRoot.selector, unknownRoot));
        l3Bridge.commitFraudProof{value: BOND}(keccak256("c"), unknownRoot);
        vm.stopPrank();

        // A challenger cannot reuse its own live (challenger, hash)
        _commitRaw(honest, keccak256("c"), root);
        vm.prank(honest);
        vm.expectRevert(IL3Bridge.InvalidCommitment.selector);
        l3Bridge.commitFraudProof{value: BOND}(keccak256("c"), root);

        // Reveal timing is still enforced
        IL3Bridge.FraudProof memory proof = _proofFor(bytes("fraud_state"));
        bytes32 salt = keccak256("s");
        _commit(challengerX, proof, salt, root);
        vm.prank(challengerX);
        vm.expectRevert(abi.encodeWithSelector(IL3Bridge.RevealTooEarly.selector, REVEAL_DELAY));
        l3Bridge.revealFraudProof(proof, salt);
    }
}
