// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "./L3TestBase.sol";

/**
 * @title L3BridgeBoundaryTest
 * @notice Exact-boundary tests for L3Bridge checks that only fuzz or happy-path tests touched before:
 *         the commit cutoff (`>=`), the legacy submitFraudProof deadline, and DisputeAlreadyBridged on the
 *         single-dispute path
 */
contract L3BridgeBoundaryTest is L3TestBase {
    uint256 internal constant BOND = 0.1 ether;
    uint256 internal constant REVEAL_EXPIRY = 2 minutes + 1 hours; // MIN_REVEAL_DELAY + MAX_REVEAL_WINDOW

    address internal ilrm = makeAddr("ilrm");
    address internal challenger = makeAddr("challenger");
    address internal bridger = makeAddr("bridger");

    function setUp() public {
        _deployBridge(ilrm);
        vm.deal(address(l3Bridge), 1 ether);
        vm.deal(challenger, 10 ether);
    }

    // ============ Commit cutoff ============

    /// @notice Commits close at block.timestamp + MIN_REVEAL_DELAY + MAX_REVEAL_WINDOW >= deadline, inclusive
    function test_CommitCutoffIsInclusive() public {
        assertEq(l3Bridge.MIN_REVEAL_DELAY() + l3Bridge.MAX_REVEAL_WINDOW(), REVEAL_EXPIRY);
        (bytes32 root, IL3Bridge.FraudProof memory proof) = _commitFraudulentState(bytes("fraud_state"));
        uint256 deadline = l3Bridge.getChallengeDeadline(root);
        uint256 cutoff = deadline - REVEAL_EXPIRY;
        bytes32 salt = keccak256("salt");
        bytes32 commitHash = _commitHash(challenger, proof, salt);

        // At the cutoff a reveal window would still be open at the deadline, when the root is finalizable
        vm.warp(cutoff);
        vm.prank(challenger);
        vm.expectRevert(IL3Bridge.ChallengePeriodExpired.selector);
        l3Bridge.commitFraudProof{value: BOND}(commitHash, root);

        vm.warp(cutoff + 1);
        vm.prank(challenger);
        vm.expectRevert(IL3Bridge.ChallengePeriodExpired.selector);
        l3Bridge.commitFraudProof{value: BOND}(commitHash, root);
    }

    /// @notice One second before the cutoff the commit is accepted and its whole reveal window ends before the deadline
    function test_CommitOneSecondBeforeCutoff() public {
        (bytes32 root, IL3Bridge.FraudProof memory proof) = _commitFraudulentState(bytes("fraud_state"));
        uint256 deadline = l3Bridge.getChallengeDeadline(root);
        bytes32 salt = keccak256("salt");

        vm.warp(deadline - REVEAL_EXPIRY - 1);
        vm.prank(challenger);
        l3Bridge.commitFraudProof{value: BOND}(_commitHash(challenger, proof, salt), root);

        // The last second of the reveal window is deadline - 1: the root cannot be finalized yet
        vm.warp(deadline - 1);
        vm.expectRevert(abi.encodeWithSelector(IL3Bridge.ChallengePeriodNotPassed.selector, 1));
        l3Bridge.finalizeStateCommitment(root);

        vm.prank(challenger);
        l3Bridge.revealFraudProof(proof, salt);
        assertEq(l3Bridge.getActiveChallenger(root), challenger);

        vm.warp(deadline);
        vm.expectRevert(abi.encodeWithSelector(IL3Bridge.InvalidStateRoot.selector, root));
        l3Bridge.finalizeStateCommitment(root);
    }

    // ============ Legacy submitFraudProof deadline ============

    function test_LegacySubmitFraudProofDeadline() public {
        l3Bridge.setCommitRevealEnabled(false);

        // Two fraudulent roots in one block share a deadline; R2 is a child of R1
        (bytes32 root1, IL3Bridge.FraudProof memory proof1) = _commitFraudulentState(bytes("fraud_state_1"));
        (bytes32 root2, IL3Bridge.FraudProof memory proof2) = _commitFraudulentState(bytes("fraud_state_2"));
        uint256 deadline = l3Bridge.getChallengeDeadline(root1);
        assertEq(l3Bridge.getChallengeDeadline(root2), deadline);

        // Last challengeable second
        vm.warp(deadline - 1);
        vm.prank(challenger);
        l3Bridge.submitFraudProof{value: BOND}(proof2);
        assertEq(l3Bridge.getActiveChallenger(root2), challenger);
        assertEq(l3Bridge.latestCommittedRoot(), root1);

        // At the deadline R1 is finalizable but not finalized yet: the legacy path must already be closed
        vm.warp(deadline);
        assertFalse(l3Bridge.isStateFinalized(root1));
        uint256 balanceBefore = challenger.balance;
        vm.prank(challenger);
        vm.expectRevert(IL3Bridge.ChallengePeriodExpired.selector);
        l3Bridge.submitFraudProof{value: BOND}(proof1);

        vm.warp(deadline + 1 days);
        vm.prank(challenger);
        vm.expectRevert(IL3Bridge.ChallengePeriodExpired.selector);
        l3Bridge.submitFraudProof{value: BOND}(proof1);

        assertEq(challenger.balance, balanceBefore);
        assertEq(l3Bridge.getActiveChallenger(root1), address(0));
        l3Bridge.finalizeStateCommitment(root1);
        assertTrue(l3Bridge.isStateFinalized(root1));
    }

    // ============ DisputeAlreadyBridged ============

    function test_SingleBridgeRejectsAlreadyBridged() public {
        IL3Bridge.DisputeInitiationMessage memory message = _initiation(42);
        vm.prank(ilrm);
        assertEq(l3Bridge.bridgeDisputeToL3(message), 1);

        // Same dispute again, even with different data
        message.stakeAmount = 5 ether;
        vm.prank(ilrm);
        vm.expectRevert(abi.encodeWithSelector(IL3Bridge.DisputeAlreadyBridged.selector, 42));
        l3Bridge.bridgeDisputeToL3(message);

        // A dispute bridged by the batch path is rejected on the single path too
        l3Bridge.setDisputeBridger(bridger, true);
        IL3Bridge.DisputeInitiationMessage[] memory batch = new IL3Bridge.DisputeInitiationMessage[](1);
        batch[0] = _initiation(43);
        vm.prank(bridger);
        l3Bridge.bridgeDisputeBatchToL3(batch);
        IL3Bridge.DisputeInitiationMessage memory again = _initiation(43);
        vm.prank(bridger);
        vm.expectRevert(abi.encodeWithSelector(IL3Bridge.DisputeAlreadyBridged.selector, 43));
        l3Bridge.bridgeDisputeToL3(again);

        // Nothing was overwritten or double counted
        assertEq(l3Bridge.getL3DisputeId(42), 1);
        assertEq(l3Bridge.getL3DisputeId(43), 2);
        assertEq(l3Bridge.getL2DisputeId(3), 0);
        assertEq(l3Bridge.getBridgedDispute(42).stakeAmount, 1 ether);
        assertEq(l3Bridge.getTotalBridgedDisputes(), 2);
        assertEq(l3Bridge.getPendingSettlementsCount(), 2);
    }
}
