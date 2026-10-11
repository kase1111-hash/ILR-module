// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {CommonBase} from "forge-std/Base.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "../contracts/ILRM.sol";
import "../contracts/Oracle.sol";
import "../contracts/mocks/MockToken.sol";
import "../contracts/mocks/MockAssetRegistry.sol";

/**
 * @title OracleRoundsBase
 * @notice Real NatLangChainOracle + ILRM deployment and an independent EIP-712 signer.
 * @dev The proposal digest is computed here from the type string, never through the Oracle, and is cross-checked
 *      against oracle.proposalDigest on every live-context signature.
 */
abstract contract OracleRoundsBase is Test {
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant PROPOSAL_TYPEHASH_V2 =
        keccak256("Proposal(uint256 disputeId,uint256 round,bytes32 evidenceHash,bytes32 proposalHash,uint256 nonce)");

    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    uint256 internal constant STAKE = 10 ether;
    bytes32 internal constant EVIDENCE_0 = keccak256("evidence-0");

    ILRM internal ilrm;
    NatLangChainOracle internal oracle;
    MockToken internal token;
    MockAssetRegistry internal registry;

    address internal operator;
    uint256 internal operatorKey;
    address internal initiator = makeAddr("initiator");
    address internal counterparty = makeAddr("counterparty");
    address internal counterparty2 = makeAddr("counterparty2");

    function _deploy() internal {
        (operator, operatorKey) = makeAddrAndKey("operator");

        token = new MockToken();
        registry = new MockAssetRegistry();
        oracle = new NatLangChainOracle();
        ilrm = new ILRM(IERC20(address(token)), address(oracle), registry);

        oracle.setILRM(address(ilrm));
        oracle.registerOracle(operator, keccak256("operator-key"));

        _fund(initiator);
        _fund(counterparty);
        _fund(counterparty2);
    }

    function _fund(address party) internal {
        token.mint(party, 1000 ether);
        vm.prank(party);
        token.approve(address(ilrm), type(uint256).max);
    }

    // ============ Signing ============

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("NatLangChainOracle"), keccak256("1"), block.chainid, address(oracle))
        );
    }

    function _digestFor(uint256 id, uint256 round, bytes32 evidenceHash, bytes32 proposalHash, uint256 nonce)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(abi.encode(PROPOSAL_TYPEHASH_V2, id, round, evidenceHash, proposalHash, nonce));
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    function _signDigest(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Sign an explicit (round, evidence, nonce) context, e.g. a stale or wrong one
    function _signFor(
        uint256 key,
        uint256 id,
        uint256 round,
        bytes32 evidenceHash,
        string memory proposal,
        uint256 nonce
    ) internal view returns (bytes memory) {
        return _signDigest(key, _digestFor(id, round, evidenceHash, keccak256(bytes(proposal)), nonce));
    }

    /// @dev Sign the live context (ILRM counterCount, ILRM evidenceHash, Oracle nonce)
    function _signCurrent(uint256 key, uint256 id, string memory proposal) internal view returns (bytes memory) {
        IILRM.Dispute memory d = ilrm.disputes(id);
        bytes32 proposalHash = keccak256(bytes(proposal));
        bytes32 digest = _digestFor(id, d.counterCount, d.evidenceHash, proposalHash, oracle.getNonce(id));
        assertEq(digest, oracle.proposalDigest(id, proposalHash), "independent digest != oracle.proposalDigest");
        return _signDigest(key, digest);
    }

    function _submit(uint256 id, string memory proposal) internal {
        bytes memory sig = _signCurrent(operatorKey, id, proposal);
        vm.prank(operator);
        oracle.submitProposal(id, proposal, sig);
    }

    // ============ ILRM flow ============

    function _fallback() internal pure returns (IILRM.FallbackLicense memory) {
        return IILRM.FallbackLicense({
            termsHash: keccak256("fallback"), termDuration: 365 days, royaltyCapBps: 500, nonExclusive: true
        });
    }

    function _openDispute(address cp, bytes32 evidenceHash) internal returns (uint256 id) {
        vm.prank(initiator);
        id = ilrm.initiateBreachDispute(cp, STAKE, evidenceHash, _fallback());
        vm.prank(cp);
        ilrm.depositStake(id);
    }

    function _counter(address party, uint256 id, bytes32 newEvidenceHash) internal {
        uint256 fee = ilrm.COUNTER_FEE_BASE() << ilrm.disputes(id).counterCount;
        vm.deal(party, party.balance + fee);
        vm.prank(party);
        ilrm.counterPropose{value: fee}(id, newEvidenceHash);
    }

    function _accept(address party, uint256 id) internal {
        vm.prank(party);
        ilrm.acceptProposal(id);
    }

    function _hash(string memory s) internal pure returns (bytes32) {
        return keccak256(bytes(s));
    }
}

/**
 * @title OracleRoundsTest
 * @notice One oracle proposal per negotiation round (ILRM counterCount), without admin action between rounds;
 *         round/evidence/nonce binding of signatures; owner recovery via resetProposal.
 */
contract OracleRoundsTest is OracleRoundsBase {
    // Oracle events
    event ProposalSubmittedToILRM(uint256 indexed disputeId, bytes32 proposalHash, address indexed oracle);
    event ProposalRoundFilled(uint256 indexed disputeId, uint256 indexed round, bytes32 proposalHash, uint256 nonce);
    event ProposalRoundReopened(uint256 indexed disputeId, uint256 indexed round, bytes32 voidedProposalHash);
    event ProposalReset(uint256 indexed disputeId, bytes32 oldProposalHash, string reason);
    event DisputeProcessed(uint256 indexed disputeId, bytes32 evidenceHash, bytes32 proposalHash);
    // ILRM event
    event ProposalSuperseded(
        uint256 indexed disputeId, uint256 indexed round, bytes32 previousProposalHash, bytes32 newProposalHash
    );

    string constant P1 = '{"terms":"P1"}';
    string constant P2 = '{"terms":"P2"}';
    string constant P3 = '{"terms":"P3"}';

    function setUp() public {
        _deploy();
    }

    function _roundText(uint256 r) internal pure returns (string memory) {
        return string(abi.encodePacked('{"round":', vm.toString(r), "}"));
    }

    function _expectAlreadyProcessed(uint256 id, uint256 round) internal {
        vm.expectRevert(abi.encodeWithSelector(NatLangChainOracle.ProposalAlreadyProcessed.selector, id, round));
    }

    // ============ Rounds ============

    /// @notice REGRESSION: every round opened by counterPropose takes a new proposal with no owner call
    function test_NewProposalEachRoundWithoutAdmin() public {
        uint256 id = _openDispute(counterparty, EVIDENCE_0);

        for (uint256 r = 0; r <= 3; r++) {
            string memory p = _roundText(r);
            bytes memory sig = _signCurrent(operatorKey, id, p);

            vm.expectEmit(true, true, false, true, address(oracle));
            emit ProposalRoundFilled(id, r, _hash(p), r);
            vm.prank(operator);
            oracle.submitProposal(id, p, sig);

            assertEq(ilrm.disputes(id).llmProposal, p);
            assertEq(oracle.roundProposals(id, r), _hash(p));

            if (r < 3) _counter(r % 2 == 0 ? initiator : counterparty, id, keccak256(abi.encode("evidence", r + 1)));
        }

        assertEq(ilrm.disputes(id).counterCount, 3);
        assertEq(oracle.getNonce(id), 4);

        _accept(initiator, id);
        _accept(counterparty, id);
        IILRM.Dispute memory d = ilrm.disputes(id);
        assertTrue(d.resolved);
        assertEq(uint256(d.outcome), uint256(IILRM.DisputeOutcome.AcceptedProposal));
        assertEq(d.llmProposal, _roundText(3));
    }

    /// @notice Integration Scenario 4 shape: proposal, two back-to-back counters, proposal
    function test_ProposalAfterBackToBackCounters() public {
        uint256 id = _openDispute(counterparty, EVIDENCE_0);
        _submit(id, '{"round":1}');

        _counter(initiator, id, keccak256("evidence-2"));
        _counter(counterparty, id, keccak256("evidence-3"));

        string memory compromise = '{"round":2,"compromise":true}';
        _submit(id, compromise);

        assertEq(oracle.roundProposals(id, 0), _hash('{"round":1}'));
        assertEq(oracle.roundProposals(id, 1), bytes32(0));
        assertEq(oracle.roundProposals(id, 2), _hash(compromise));
        assertEq(oracle.getNonce(id), 2);

        _accept(initiator, id);
        _accept(counterparty, id);
        IILRM.Dispute memory d = ilrm.disputes(id);
        assertTrue(d.resolved);
        assertEq(d.counterCount, 2);
        assertEq(d.llmProposal, compromise);
    }

    function test_FirstProposalMayFollowACounter() public {
        uint256 id = _openDispute(counterparty, EVIDENCE_0);
        _counter(initiator, id, keccak256("evidence-1"));

        _submit(id, P1);

        assertEq(oracle.roundProposals(id, 0), bytes32(0));
        assertEq(oracle.roundProposals(id, 1), _hash(P1));
        assertEq(oracle.getNonce(id), 1);
        assertEq(ilrm.disputes(id).llmProposal, P1);
    }

    function test_SecondProposalInSameRoundReverts() public {
        uint256 id = _openDispute(counterparty, EVIDENCE_0);
        _submit(id, P1);

        // Validly signed for the live context, but round 0 is already filled
        bytes memory sig = _signCurrent(operatorKey, id, P2);
        vm.prank(operator);
        _expectAlreadyProcessed(id, 0);
        oracle.submitProposal(id, P2, sig);

        assertEq(ilrm.disputes(id).llmProposal, P1);
        assertEq(oracle.roundProposals(id, 0), _hash(P1));
        assertEq(oracle.getNonce(id), 1);
    }

    function test_SecondProposalInLaterRoundReverts() public {
        uint256 id = _openDispute(counterparty, EVIDENCE_0);
        _submit(id, P1);
        _counter(initiator, id, keccak256("evidence-1"));
        _submit(id, P2);

        bytes memory sig = _signCurrent(operatorKey, id, P3);
        vm.prank(operator);
        _expectAlreadyProcessed(id, 1);
        oracle.submitProposal(id, P3, sig);

        assertEq(ilrm.disputes(id).llmProposal, P2);
        assertEq(oracle.getNonce(id), 2);
    }

    // ============ Stale and replayed signatures ============

    /// @notice REGRESSION: a signature made for round 0 is dead once a counter opens round 1, even with the SAME
    ///         evidence hash and an unchanged nonce (isolates the round binding)
    function test_StaleRoundSignatureRejected() public {
        uint256 id = _openDispute(counterparty, EVIDENCE_0);
        bytes memory staleSig = _signCurrent(operatorKey, id, P1);

        _counter(initiator, id, EVIDENCE_0);
        (uint256 round, bytes32 evidenceHash, uint256 nonce, bool open) = oracle.proposalContext(id);
        assertEq(round, 1);
        assertEq(evidenceHash, EVIDENCE_0);
        assertEq(nonce, 0);
        assertTrue(open);

        vm.prank(operator);
        vm.expectRevert(NatLangChainOracle.InvalidSignature.selector);
        oracle.submitProposal(id, P1, staleSig);

        // A fresh round-1 signature is accepted
        _submit(id, P1);
        assertEq(oracle.roundProposals(id, 1), _hash(P1));
        assertEq(ilrm.disputes(id).llmProposal, P1);
    }

    function test_EvidenceBinding() public {
        uint256 id = _openDispute(counterparty, EVIDENCE_0);

        bytes memory wrongEvidence = _signFor(operatorKey, id, 0, keccak256("other-evidence"), P1, 0);
        vm.prank(operator);
        vm.expectRevert(NatLangChainOracle.InvalidSignature.selector);
        oracle.submitProposal(id, P1, wrongEvidence);

        // After a counter, the previous evidence is dead even with the right round and nonce
        _counter(initiator, id, keccak256("evidence-1"));
        bytes memory oldEvidence = _signFor(operatorKey, id, 1, EVIDENCE_0, P1, 0);
        vm.prank(operator);
        vm.expectRevert(NatLangChainOracle.InvalidSignature.selector);
        oracle.submitProposal(id, P1, oldEvidence);

        assertEq(oracle.getNonce(id), 0);
        assertEq(oracle.roundProposals(id, 1), bytes32(0));
    }

    function test_PreviousRoundReplayRejected() public {
        uint256 id = _openDispute(counterparty, EVIDENCE_0);
        bytes memory sig0 = _signCurrent(operatorKey, id, P1);
        vm.prank(operator);
        oracle.submitProposal(id, P1, sig0);

        _counter(initiator, id, keccak256("evidence-1"));

        // Replaying the relayed round-0 signature into round 1
        vm.prank(operator);
        vm.expectRevert(NatLangChainOracle.InvalidSignature.selector);
        oracle.submitProposal(id, P1, sig0);

        // A round-0 signature at the current nonce is dead too
        bytes memory prevRound = _signFor(operatorKey, id, 0, EVIDENCE_0, P1, 1);
        vm.prank(operator);
        vm.expectRevert(NatLangChainOracle.InvalidSignature.selector);
        oracle.submitProposal(id, P1, prevRound);

        (,,, bool open) = oracle.proposalContext(id);
        assertTrue(open);
        assertEq(oracle.getNonce(id), 1);
    }

    function test_SignatureNotReplayableAcrossDisputes() public {
        uint256 a = _openDispute(counterparty, EVIDENCE_0);
        uint256 b = _openDispute(counterparty2, EVIDENCE_0);
        bytes memory sigA = _signCurrent(operatorKey, a, P1);

        // Same round, evidence and nonce, different dispute
        vm.prank(operator);
        vm.expectRevert(NatLangChainOracle.InvalidSignature.selector);
        oracle.submitProposal(b, P1, sigA);

        vm.prank(operator);
        oracle.submitProposal(a, P1, sigA);
        assertEq(oracle.getNonce(a), 1);
        assertEq(oracle.getNonce(b), 0);
        assertEq(bytes(ilrm.disputes(b).llmProposal).length, 0);
    }

    function test_UnregisteredSignerRejected() public {
        uint256 id = _openDispute(counterparty, EVIDENCE_0);
        (address rogue, uint256 rogueKey) = makeAddrAndKey("rogue");
        bytes memory rogueSig = _signCurrent(rogueKey, id, P1);

        // A registered operator relaying an unregistered key's signature
        vm.prank(operator);
        vm.expectRevert(NatLangChainOracle.InvalidSignature.selector);
        oracle.submitProposal(id, P1, rogueSig);

        // The unregistered key cannot relay at all
        vm.prank(rogue);
        vm.expectRevert(abi.encodeWithSelector(NatLangChainOracle.NotOracle.selector, rogue));
        oracle.submitProposal(id, P1, rogueSig);

        assertFalse(oracle.verifySignature(id, _hash(P1), rogueSig));
    }

    /// @notice C-02: an empty signature never bypasses verification
    function test_EmptySignatureRejected() public {
        uint256 id = _openDispute(counterparty, EVIDENCE_0);
        vm.prank(operator);
        vm.expectRevert(NatLangChainOracle.InvalidSignature.selector);
        oracle.submitProposal(id, P1, "");

        assertEq(oracle.getNonce(id), 0);
        assertEq(oracle.roundProposals(id, 0), bytes32(0));
    }

    function test_MalformedSignatureReverts() public {
        uint256 id = _openDispute(counterparty, EVIDENCE_0);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureLength.selector, 4));
        oracle.submitProposal(id, P1, hex"deadbeef");

        // Malleated (high-s) form of a valid signature
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorKey, oracle.proposalDigest(id, _hash(P1)));
        bytes32 highS = bytes32(SECP256K1_N - uint256(s));
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, highS));
        oracle.submitProposal(id, P1, abi.encodePacked(r, highS, v == 27 ? uint8(28) : uint8(27)));

        assertEq(oracle.getNonce(id), 0);
    }

    // ============ Reset and recovery ============

    /// @notice REGRESSION: the owner's reset lets exactly one replacement land, which voids prior acceptances
    function test_ResetAllowsExactlyOneReplacement() public {
        uint256 id = _openDispute(counterparty, EVIDENCE_0);
        _submit(id, P1);
        _accept(initiator, id);
        IILRM.Dispute memory before = ilrm.disputes(id);

        vm.expectEmit(true, false, false, true, address(oracle));
        emit ProposalReset(id, _hash(P1), "incorrect proposal");
        vm.expectEmit(true, true, false, true, address(oracle));
        emit ProposalRoundReopened(id, 0, _hash(P1));
        oracle.resetProposal(id, "incorrect proposal");

        // The voided text stays in ILRM until the replacement lands
        assertEq(ilrm.disputes(id).llmProposal, P1);
        (,, uint256 nonce, bool open) = oracle.proposalContext(id);
        assertTrue(open);
        assertEq(nonce, 2);

        bytes memory sig2 = _signCurrent(operatorKey, id, P2);
        vm.expectEmit(true, true, false, true, address(ilrm));
        emit ProposalSuperseded(id, 0, _hash(P1), _hash(P2));
        vm.expectEmit(true, true, false, true, address(oracle));
        emit ProposalRoundFilled(id, 0, _hash(P2), 2);
        vm.prank(operator);
        oracle.submitProposal(id, P2, sig2);

        IILRM.Dispute memory d = ilrm.disputes(id);
        assertEq(d.llmProposal, P2);
        assertFalse(d.initiatorAccepted, "acceptance of the voided proposal carried over");
        assertFalse(d.counterpartyAccepted);
        assertEq(d.counterCount, before.counterCount);
        assertEq(d.startTime, before.startTime);

        // Exactly one replacement per reset
        bytes memory sig3 = _signCurrent(operatorKey, id, P3);
        vm.prank(operator);
        _expectAlreadyProcessed(id, 0);
        oracle.submitProposal(id, P3, sig3);

        // The counterparty's acceptance alone does not resolve; the initiator must re-accept P2
        _accept(counterparty, id);
        assertFalse(ilrm.disputes(id).resolved);
        _accept(initiator, id);
        d = ilrm.disputes(id);
        assertTrue(d.resolved);
        assertEq(d.llmProposal, P2);
        assertEq(oracle.getNonce(id), 3);
    }

    function test_ResetInvalidatesPreResetSignatures() public {
        uint256 id = _openDispute(counterparty, EVIDENCE_0);
        bytes memory sig1 = _signCurrent(operatorKey, id, P1);
        vm.prank(operator);
        oracle.submitProposal(id, P1, sig1);

        // Pre-signed for the current nonce before the reset
        bytes memory preReset = _signCurrent(operatorKey, id, P2);
        assertTrue(oracle.verifySignature(id, _hash(P2), preReset));

        oracle.resetProposal(id, "recover");
        assertFalse(oracle.verifySignature(id, _hash(P2), preReset));

        vm.prank(operator);
        vm.expectRevert(NatLangChainOracle.InvalidSignature.selector);
        oracle.submitProposal(id, P2, preReset);

        vm.prank(operator);
        vm.expectRevert(NatLangChainOracle.InvalidSignature.selector);
        oracle.submitProposal(id, P1, sig1);

        // A signature made after the reset is accepted
        _submit(id, P2);
        assertEq(ilrm.disputes(id).llmProposal, P2);
    }

    function test_ResetRevertsForEarlierRoundProposal() public {
        uint256 id = _openDispute(counterparty, EVIDENCE_0);
        _submit(id, P1);
        _counter(initiator, id, keccak256("evidence-1"));

        vm.expectRevert(abi.encodeWithSelector(NatLangChainOracle.NoProposalToReset.selector, id));
        oracle.resetProposal(id, "round 0 is closed");

        assertEq(oracle.roundProposals(id, 0), _hash(P1));
        assertEq(oracle.getNonce(id), 1);
    }

    function test_ResetRevertsWithNoProposal() public {
        uint256 id = _openDispute(counterparty, EVIDENCE_0);
        vm.expectRevert(abi.encodeWithSelector(NatLangChainOracle.NoProposalToReset.selector, id));
        oracle.resetProposal(id, "nothing to reset");

        vm.expectRevert(abi.encodeWithSelector(NatLangChainOracle.NoProposalToReset.selector, 999));
        oracle.resetProposal(999, "unknown dispute");

        assertEq(oracle.getNonce(id), 0);
    }

    function test_ResetRevertsOnResolvedDispute() public {
        uint256 accepted = _openDispute(counterparty, EVIDENCE_0);
        _submit(accepted, P1);
        _accept(initiator, accepted);
        _accept(counterparty, accepted);
        assertTrue(ilrm.disputes(accepted).resolved);

        vm.expectRevert(abi.encodeWithSelector(NatLangChainOracle.DisputeAlreadyResolved.selector, accepted));
        oracle.resetProposal(accepted, "too late");

        uint256 timedOut = _openDispute(counterparty2, EVIDENCE_0);
        _submit(timedOut, P1);
        vm.warp(ilrm.disputes(timedOut).startTime + ilrm.RESOLUTION_TIMEOUT() + 1);
        ilrm.enforceTimeout(timedOut);

        vm.expectRevert(abi.encodeWithSelector(NatLangChainOracle.DisputeAlreadyResolved.selector, timedOut));
        oracle.resetProposal(timedOut, "too late");
    }

    function test_ResetOnlyOwner() public {
        uint256 id = _openDispute(counterparty, EVIDENCE_0);
        _submit(id, P1);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator));
        oracle.resetProposal(id, "not owner");

        assertEq(oracle.roundProposals(id, 0), _hash(P1));
    }

    function test_RevokedOperatorCannotRefill() public {
        uint256 id = _openDispute(counterparty, EVIDENCE_0);
        _submit(id, P1);

        // Emergency procedure: revoke first, then reset
        oracle.revokeOracle(operator);
        oracle.resetProposal(id, "compromised operator");

        bytes memory revokedSig = _signCurrent(operatorKey, id, P2);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(NatLangChainOracle.NotOracle.selector, operator));
        oracle.submitProposal(id, P2, revokedSig);

        (address operator2, uint256 operator2Key) = makeAddrAndKey("operator2");
        oracle.registerOracle(operator2, keccak256("operator2-key"));

        // Another operator cannot relay the revoked key's signature
        vm.prank(operator2);
        vm.expectRevert(NatLangChainOracle.InvalidSignature.selector);
        oracle.submitProposal(id, P2, revokedSig);

        bytes memory sig = _signCurrent(operator2Key, id, P2);
        vm.prank(operator2);
        oracle.submitProposal(id, P2, sig);
        assertEq(ilrm.disputes(id).llmProposal, P2);
    }

    function test_ResetDoesNotLeakIntoNextRound() public {
        uint256 id = _openDispute(counterparty, EVIDENCE_0);
        _submit(id, P1);
        oracle.resetProposal(id, "fix round 0");
        _submit(id, P2);

        _counter(initiator, id, keccak256("evidence-1"));

        // Round 1 is empty: nothing to reset yet
        vm.expectRevert(abi.encodeWithSelector(NatLangChainOracle.NoProposalToReset.selector, id));
        oracle.resetProposal(id, "empty round");

        _submit(id, P3);

        // Round 1 admits exactly one proposal despite the reset in round 0
        bytes memory sig = _signCurrent(operatorKey, id, P1);
        vm.prank(operator);
        _expectAlreadyProcessed(id, 1);
        oracle.submitProposal(id, P1, sig);

        assertEq(oracle.roundProposals(id, 0), _hash(P2));
        assertEq(oracle.roundProposals(id, 1), _hash(P3));
        // relay, reset, relay, relay
        assertEq(oracle.getNonce(id), 4);
    }

    // ============ H-01, atomicity and views ============

    /// @notice H-01: ILRM's own re-verification binds the round and the evidence
    function test_ILRMReverification_BindsRoundAndEvidence() public {
        uint256 id = _openDispute(counterparty, EVIDENCE_0);
        bytes32 evidence1 = keccak256("evidence-1");
        _counter(initiator, id, evidence1);

        bytes memory wrongRound = _signFor(operatorKey, id, 0, evidence1, P1, 0);
        vm.prank(address(oracle));
        vm.expectRevert("Invalid signature");
        ilrm.submitLLMProposal(id, P1, wrongRound);

        bytes memory wrongEvidence = _signFor(operatorKey, id, 1, EVIDENCE_0, P1, 0);
        vm.prank(address(oracle));
        vm.expectRevert("Invalid signature");
        ilrm.submitLLMProposal(id, P1, wrongEvidence);

        bytes memory good = _signCurrent(operatorKey, id, P1);
        vm.prank(address(oracle));
        ilrm.submitLLMProposal(id, P1, good);
        assertEq(ilrm.disputes(id).llmProposal, P1);
    }

    /// @notice The nonce is consumed after ILRM's re-check, so a relayed signature stops verifying afterwards
    function test_VerifySignatureFalseAfterRelay() public {
        uint256 id = _openDispute(counterparty, EVIDENCE_0);
        bytes memory sig = _signCurrent(operatorKey, id, P1);
        assertTrue(oracle.verifySignature(id, _hash(P1), sig));
        assertTrue(oracle.verifySignatureFrom(id, _hash(P1), sig, operator));

        vm.expectEmit(true, true, false, true, address(oracle));
        emit ProposalRoundFilled(id, 0, _hash(P1), 0);
        vm.expectEmit(true, false, false, true, address(oracle));
        emit DisputeProcessed(id, EVIDENCE_0, _hash(P1));
        vm.prank(operator);
        oracle.submitProposal(id, P1, sig);

        assertEq(oracle.getNonce(id), 1);
        assertFalse(oracle.verifySignature(id, _hash(P1), sig));
        assertFalse(oracle.verifySignatureFrom(id, _hash(P1), sig, operator));
    }

    function test_FailedIlrmCallRollsBack() public {
        // Not fully staked
        vm.prank(initiator);
        uint256 unstaked = ilrm.initiateBreachDispute(counterparty, STAKE, EVIDENCE_0, _fallback());
        vm.prank(address(ilrm));
        oracle.requestProposal(unstaked, EVIDENCE_0);
        assertTrue(oracle.isPending(unstaked));

        bytes memory sig = _signCurrent(operatorKey, unstaked, P1);
        vm.prank(operator);
        vm.expectRevert("Not fully staked");
        oracle.submitProposal(unstaked, P1, sig);

        assertEq(oracle.roundProposals(unstaked, 0), bytes32(0));
        assertEq(oracle.getNonce(unstaked), 0);
        assertTrue(oracle.isPending(unstaked));

        // Timed out
        uint256 id = _openDispute(counterparty2, EVIDENCE_0);
        vm.warp(ilrm.disputes(id).startTime + ilrm.RESOLUTION_TIMEOUT() + 1);
        sig = _signCurrent(operatorKey, id, P1);
        vm.prank(operator);
        vm.expectRevert("Timeout passed");
        oracle.submitProposal(id, P1, sig);

        assertEq(oracle.roundProposals(id, 0), bytes32(0));
        assertEq(oracle.getNonce(id), 0);
        assertEq(bytes(ilrm.disputes(id).llmProposal).length, 0);
    }

    function test_SubmitWithoutILRM_Reverts() public {
        NatLangChainOracle fresh = new NatLangChainOracle();
        fresh.registerOracle(operator, keccak256("operator-key"));

        vm.prank(operator);
        vm.expectRevert(NatLangChainOracle.ILRMNotSet.selector);
        fresh.submitProposal(0, P1, hex"01");

        vm.expectRevert(NatLangChainOracle.ILRMNotSet.selector);
        fresh.proposalDigest(0, _hash(P1));

        vm.expectRevert(NatLangChainOracle.ILRMNotSet.selector);
        fresh.proposalContext(0);

        vm.expectRevert(NatLangChainOracle.ILRMNotSet.selector);
        fresh.resetProposal(0, "no ilrm");

        assertEq(fresh.processedProposals(0), bytes32(0));
    }

    function test_VerifySignatureFalseWithoutILRM() public {
        NatLangChainOracle fresh = new NatLangChainOracle();
        fresh.registerOracle(operator, keccak256("operator-key"));
        bytes memory sig = _signDigest(operatorKey, keccak256("anything"));

        assertFalse(fresh.verifySignature(0, _hash(P1), sig));
        assertFalse(fresh.verifySignatureFrom(0, _hash(P1), sig, operator));
    }

    function test_ProcessedProposalsViewTracksCurrentRound() public {
        uint256 id = _openDispute(counterparty, EVIDENCE_0);
        assertEq(oracle.processedProposals(id), bytes32(0));

        _submit(id, P1);
        assertEq(oracle.processedProposals(id), _hash(P1));

        _counter(initiator, id, keccak256("evidence-1"));
        assertEq(oracle.processedProposals(id), bytes32(0));

        _submit(id, P2);
        assertEq(oracle.processedProposals(id), _hash(P2));

        oracle.resetProposal(id, "recover");
        assertEq(oracle.processedProposals(id), bytes32(0));
    }

    function test_ProposalContext() public {
        assertEq(oracle.PROPOSAL_TYPEHASH(), PROPOSAL_TYPEHASH_V2);
        assertEq(oracle.DOMAIN_SEPARATOR(), _domainSeparator());

        uint256 id = _openDispute(counterparty, EVIDENCE_0);
        (uint256 round, bytes32 evidenceHash, uint256 nonce, bool open) = oracle.proposalContext(id);
        assertEq(round, 0);
        assertEq(evidenceHash, EVIDENCE_0);
        assertEq(nonce, 0);
        assertTrue(open);

        _submit(id, P1);
        (round, evidenceHash, nonce, open) = oracle.proposalContext(id);
        assertEq(round, 0);
        assertEq(nonce, 1);
        assertFalse(open);

        bytes32 evidence1 = keccak256("evidence-1");
        _counter(counterparty, id, evidence1);
        (round, evidenceHash, nonce, open) = oracle.proposalContext(id);
        assertEq(round, 1);
        assertEq(evidenceHash, evidence1);
        assertEq(nonce, 1);
        assertTrue(open);

        assertEq(oracle.proposalDigest(id, _hash(P2)), _digestFor(id, 1, evidence1, _hash(P2), 1));
    }
}

/**
 * @title OracleRoundsHandler
 * @notice Drives submit / accept / counter / reset / timeout / warp against a few real disputes and records ghost
 *         state for the round invariants.
 */
contract OracleRoundsHandler is CommonBase, StdCheats, StdUtils {
    ILRM internal immutable ilrm;
    NatLangChainOracle internal immutable oracle;
    address internal immutable owner;
    address internal immutable operator;
    uint256 internal immutable operatorKey;

    uint256[] internal ids;

    // Ghost state
    uint256 public seq;
    mapping(uint256 => uint256) public lastProposalSeq;
    mapping(uint256 => uint256) public initiatorAcceptSeq;
    mapping(uint256 => uint256) public counterpartyAcceptSeq;
    mapping(uint256 => mapping(uint256 => uint256)) public admitted;
    mapping(uint256 => mapping(uint256 => uint256)) public resets;
    mapping(uint256 => uint256) public totalAdmitted;
    mapping(uint256 => uint256) public totalResets;

    constructor(
        ILRM _ilrm,
        NatLangChainOracle _oracle,
        address _owner,
        address _operator,
        uint256 _operatorKey,
        uint256[] memory _ids
    ) {
        ilrm = _ilrm;
        oracle = _oracle;
        owner = _owner;
        operator = _operator;
        operatorKey = _operatorKey;
        ids = _ids;
    }

    function disputeIds() external view returns (uint256[] memory) {
        return ids;
    }

    function _pick(uint256 seed) internal view returns (uint256) {
        return ids[seed % ids.length];
    }

    function submit(uint256 disputeSeed, uint256 textSeed) external {
        uint256 id = _pick(disputeSeed);
        string memory proposal = string(abi.encodePacked("proposal-", vm.toString(textSeed % 6)));
        uint256 round = ilrm.disputes(id).counterCount;

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorKey, oracle.proposalDigest(id, keccak256(bytes(proposal))));
        vm.prank(operator);
        try oracle.submitProposal(id, proposal, abi.encodePacked(r, s, v)) {
            admitted[id][round]++;
            totalAdmitted[id]++;
            lastProposalSeq[id] = ++seq;
        } catch {}
    }

    function accept(uint256 disputeSeed, bool byInitiator) external {
        uint256 id = _pick(disputeSeed);
        IILRM.Dispute memory d = ilrm.disputes(id);
        vm.prank(byInitiator ? d.initiator : d.counterparty);
        try ilrm.acceptProposal(id) {
            if (byInitiator) initiatorAcceptSeq[id] = ++seq;
            else counterpartyAcceptSeq[id] = ++seq;
        } catch {}
    }

    function counter(uint256 disputeSeed, bool byInitiator, uint256 evidenceSeed) external {
        uint256 id = _pick(disputeSeed);
        IILRM.Dispute memory d = ilrm.disputes(id);
        if (d.counterCount >= ilrm.MAX_COUNTERS()) return;
        uint256 fee = ilrm.COUNTER_FEE_BASE() << d.counterCount;
        address party = byInitiator ? d.initiator : d.counterparty;
        vm.deal(party, fee);
        vm.prank(party);
        // A small evidence space also exercises counters that keep the same evidence hash
        try ilrm.counterPropose{value: fee}(id, keccak256(abi.encode(evidenceSeed % 3))) {} catch {}
    }

    function reset(uint256 disputeSeed) external {
        uint256 id = _pick(disputeSeed);
        uint256 round = ilrm.disputes(id).counterCount;
        vm.prank(owner);
        try oracle.resetProposal(id, "handler") {
            resets[id][round]++;
            totalResets[id]++;
        } catch {}
    }

    function timeout(uint256 disputeSeed) external {
        try ilrm.enforceTimeout(_pick(disputeSeed)) {} catch {}
    }

    function warp(uint256 secondsSeed) external {
        vm.warp(block.timestamp + _bound(secondsSeed, 0, 2 days));
    }
}

/**
 * @title OracleRoundsInvariantTest
 * @notice (I1) an acceptance flag implies acceptProposal ran after the last stored proposal;
 *         (I2) admitted proposals per round <= 1 + resets in that round;
 *         (I3) nonce == admitted proposals + resets;
 *         (I4) a filled current-round slot == keccak256(ILRM.llmProposal).
 */
contract OracleRoundsInvariantTest is OracleRoundsBase {
    OracleRoundsHandler internal handler;
    uint256[] internal ids;

    function setUp() public {
        _deploy();
        address counterparty3 = makeAddr("counterparty3");
        _fund(counterparty3);

        ids.push(_openDispute(counterparty, EVIDENCE_0));
        ids.push(_openDispute(counterparty2, EVIDENCE_0));
        ids.push(_openDispute(counterparty3, keccak256("evidence-x")));

        handler = new OracleRoundsHandler(ilrm, oracle, address(this), operator, operatorKey, ids);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    /// forge-config: ci.invariant.runs = 64
    /// forge-config: ci.invariant.depth = 40
    function invariant_AcceptanceRefersToLiveProposal() public view {
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];
            IILRM.Dispute memory d = ilrm.disputes(id);
            if (d.initiatorAccepted) {
                assertGt(handler.initiatorAcceptSeq(id), handler.lastProposalSeq(id), "stale initiator acceptance");
            }
            if (d.counterpartyAccepted) {
                assertGt(
                    handler.counterpartyAcceptSeq(id), handler.lastProposalSeq(id), "stale counterparty acceptance"
                );
            }
        }
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    /// forge-config: ci.invariant.runs = 64
    /// forge-config: ci.invariant.depth = 40
    function invariant_AdmissionsBoundedAndNonceAccounted() public view {
        uint256 maxRound = ilrm.MAX_COUNTERS();
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];
            for (uint256 r = 0; r <= maxRound; r++) {
                assertLe(handler.admitted(id, r), 1 + handler.resets(id, r), "too many proposals in a round");
            }
            assertEq(oracle.getNonce(id), handler.totalAdmitted(id) + handler.totalResets(id), "nonce accounting");
        }
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    /// forge-config: ci.invariant.runs = 64
    /// forge-config: ci.invariant.depth = 40
    function invariant_FilledSlotMatchesLiveProposal() public view {
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];
            IILRM.Dispute memory d = ilrm.disputes(id);
            bytes32 slot = oracle.roundProposals(id, d.counterCount);
            if (slot != bytes32(0)) {
                assertEq(slot, keccak256(bytes(d.llmProposal)), "slot != live proposal");
            }
        }
    }
}
