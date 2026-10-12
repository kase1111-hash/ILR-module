// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "./L3TestBase.sol";
import "../contracts/scaling/L3StateVerifier.sol";

/**
 * @title L3KnownLimitationsTest
 * @notice Pins the KNOWN-UNSOUND behavior described in the L3Bridge security warning, so the warning is backed
 *         by executable evidence. These tests assert vulnerabilities, not desired behavior: the L3 contracts are
 *         not production-ready and must not be deployed. A real fraud-proof system will make them fail; when it
 *         does, update the warnings in L3Bridge, L3DisputeBatcher, SPEC.md and README.md together with them.
 */
contract L3KnownLimitationsTest is L3TestBase {
    uint256 internal constant BOND = 0.1 ether;

    address internal ilrm = makeAddr("ilrm");
    address internal anyone = makeAddr("anyone");

    function setUp() public {
        _deployBridge(ilrm);
        vm.deal(address(l3Bridge), 1 ether);
        vm.deal(anyone, 10 ether);
    }

    /// @notice Warning 1 + 2: anyone who knows an honest root's two children can "prove fraud" against it and is
    ///         paid for it; the sequencer posts no bond and loses nothing
    function test_KnownUnsound_HonestRootRejectedWithItsChildren() public {
        L3StateVerifier verifier = new L3StateVerifier(address(l3Bridge));
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = keccak256("honest dispute summary 1");
        leaves[1] = keccak256("honest dispute summary 2");
        bytes32 honestRoot = verifier.computeRoot(leaves);
        _submitOnHead(honestRoot);
        uint256 sequencerBalance = sequencer.balance;

        // The "invalid state" is just the root's preimage: its two children
        IL3Bridge.FraudProof memory proof = IL3Bridge.FraudProof({
            claimedRoot: honestRoot,
            correctRoot: keccak256("anything else"),
            merkleProof: new bytes32[](0),
            disputeId: 0,
            invalidStateData: abi.encodePacked(leaves[0], leaves[1])
        });
        bytes32 salt = keccak256("salt");
        vm.prank(anyone);
        l3Bridge.commitFraudProof{value: BOND}(_commitHash(anyone, proof, salt), honestRoot);
        vm.warp(block.timestamp + l3Bridge.MIN_REVEAL_DELAY());
        uint256 balanceBefore = anyone.balance;
        vm.prank(anyone);
        l3Bridge.revealFraudProof(proof, salt);

        assertEq(anyone.balance, balanceBefore + BOND + l3Bridge.FRAUD_PROOF_REWARD(), "attacker paid bond + reward");
        assertEq(l3Bridge.getActiveChallenger(honestRoot), anyone, "honest root rejected");
        assertFalse(l3Bridge.isStateCanonical(honestRoot));
        assertEq(sequencer.balance, sequencerBalance, "no sequencer bond at stake");
    }

    /// @notice Warning 3: a settlement with stateProof == 0 needs no committed, let alone finalized, root; a
    ///         settlement relayer's word is enough
    function test_KnownUnsound_SettlementNotTiedToFinalizedRoot() public {
        vm.prank(ilrm);
        uint256 l3Id = l3Bridge.bridgeDisputeToL3(_initiation(1));
        assertEq(l3Bridge.latestCommittedHeight(), 0, "no state root at all");

        address relayer = makeAddr("relayer");
        l3Bridge.setSettlementRelayer(relayer, true);
        IL3Bridge.DisputeSettlementMessage[] memory batch = new IL3Bridge.DisputeSettlementMessage[](1);
        batch[0] = _settlementMsg(1, l3Id, bytes32(0));
        batch[0].initiatorReturn = 1000 ether; // nothing checks the amounts either
        vm.prank(relayer);
        assertEq(l3Bridge.batchProcessSettlements(batch), 1);
        assertTrue(l3Bridge.isDisputeSettled(1));
    }

    /// @notice Warning 4: bridged disputes are never checked against the ILRM
    function test_KnownUnsound_BridgedDisputeNotValidatedAgainstIlrm() public {
        address bridger = makeAddr("bridger");
        l3Bridge.setDisputeBridger(bridger, true);

        // A dispute ID, parties and stake that no ILRM ever recorded (the "ILRM" here is not even a contract)
        IL3Bridge.DisputeInitiationMessage memory fake = _initiation(999_999);
        fake.stakeAmount = 1_000_000 ether;
        assertEq(ilrm.code.length, 0);
        vm.prank(bridger);
        assertEq(l3Bridge.bridgeDisputeToL3(fake), 1);
        assertEq(l3Bridge.getBridgedDispute(999_999).stakeAmount, 1_000_000 ether);
    }
}
