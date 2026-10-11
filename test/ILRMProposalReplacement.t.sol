// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/ILRM.sol";
import "../contracts/mocks/MockOracle.sol";
import "../contracts/mocks/MockToken.sol";
import "../contracts/mocks/MockAssetRegistry.sol";

/**
 * @title ILRMProposalReplacementTest
 * @notice ILRM.submitLLMProposal semantics, independent of the Oracle's signing scheme: storing a proposal voids
 *         both acceptances, replacing a live proposal emits ProposalSuperseded, and proposals after the resolution
 *         deadline are rejected.
 * @dev The oracle is contracts/mocks/MockOracle; proposals are relayed by pranking as its address.
 */
contract ILRMProposalReplacementTest is Test {
    /// @dev Mirrors IILRM.ProposalSuperseded (declared locally so the expectation matches on topic0 alone)
    event ProposalSuperseded(
        uint256 indexed disputeId, uint256 indexed round, bytes32 previousProposalHash, bytes32 newProposalHash
    );
    event ProposalSubmitted(uint256 indexed disputeId, string proposal);

    ILRM ilrm;
    MockOracle oracle;
    MockToken token;
    MockAssetRegistry registry;

    address initiator = makeAddr("initiator");
    address counterparty = makeAddr("counterparty");

    uint256 constant STAKE = 10 ether;
    string constant P1 = '{"terms":"P1"}';
    string constant P2 = '{"terms":"P2"}';

    bytes32 constant SUPERSEDED_TOPIC = keccak256("ProposalSuperseded(uint256,uint256,bytes32,bytes32)");

    function setUp() public {
        token = new MockToken();
        registry = new MockAssetRegistry();
        oracle = new MockOracle();
        ilrm = new ILRM(IERC20(address(token)), address(oracle), registry);

        token.mint(initiator, 1000 ether);
        token.mint(counterparty, 1000 ether);
        vm.prank(initiator);
        token.approve(address(ilrm), type(uint256).max);
        vm.prank(counterparty);
        token.approve(address(ilrm), type(uint256).max);
        vm.deal(initiator, 10 ether);
        vm.deal(counterparty, 10 ether);
    }

    // ============ Helpers ============

    function _openDispute() internal returns (uint256 id) {
        IILRM.FallbackLicense memory fb = IILRM.FallbackLicense({
            termsHash: keccak256("fallback"), termDuration: 365 days, royaltyCapBps: 500, nonExclusive: true
        });
        vm.prank(initiator);
        id = ilrm.initiateBreachDispute(counterparty, STAKE, keccak256("evidence-0"), fb);
        vm.prank(counterparty);
        ilrm.depositStake(id);
    }

    function _propose(uint256 id, string memory proposal) internal {
        vm.prank(address(oracle));
        ilrm.submitLLMProposal(id, proposal, hex"01");
    }

    function _accept(address party, uint256 id) internal {
        vm.prank(party);
        ilrm.acceptProposal(id);
    }

    function _counter(address party, uint256 id) internal {
        uint256 count = ilrm.disputes(id).counterCount;
        uint256 fee = ilrm.COUNTER_FEE_BASE() << count;
        bytes32 evidence = keccak256(abi.encode("evidence", count + 1));
        vm.prank(party);
        ilrm.counterPropose{value: fee}(id, evidence);
    }

    function _supersededCount() internal view returns (uint256 n) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(ilrm) && logs[i].topics[0] == SUPERSEDED_TOPIC) n++;
        }
    }

    // ============ Tests ============

    /// @notice REGRESSION: an acceptance of P1 must not count for P2
    function test_ReplacementVoidsAcceptances() public {
        uint256 id = _openDispute();
        _propose(id, P1);
        _accept(initiator, id);
        assertTrue(ilrm.disputes(id).initiatorAccepted);

        _propose(id, P2);
        IILRM.Dispute memory d = ilrm.disputes(id);
        assertEq(d.llmProposal, P2);
        assertFalse(d.initiatorAccepted, "acceptance of P1 carried over to P2");
        assertFalse(d.counterpartyAccepted);

        // The counterparty's acceptance alone must not resolve the dispute on P2
        _accept(counterparty, id);
        d = ilrm.disputes(id);
        assertFalse(d.resolved, "resolved on P2 with an acceptance given for P1");
        assertTrue(d.counterpartyAccepted);

        // The initiator must accept P2 explicitly
        _accept(initiator, id);
        d = ilrm.disputes(id);
        assertTrue(d.resolved);
        assertEq(uint256(d.outcome), uint256(IILRM.DisputeOutcome.AcceptedProposal));
        assertEq(d.llmProposal, P2);
    }

    /// @notice A counterparty-first acceptance is voided the same way
    function test_ReplacementVoidsCounterpartyAcceptance() public {
        uint256 id = _openDispute();
        _propose(id, P1);
        _accept(counterparty, id);

        _propose(id, P2);
        assertFalse(ilrm.disputes(id).counterpartyAccepted);

        _accept(initiator, id);
        assertFalse(ilrm.disputes(id).resolved);
    }

    /// @notice REGRESSION: replacing a live proposal emits ProposalSuperseded(id, round, hash(P1), hash(P2))
    function test_ReplacementEmitsSuperseded() public {
        uint256 id = _openDispute();
        _propose(id, P1);

        vm.expectEmit(true, true, false, true, address(ilrm));
        emit ProposalSuperseded(id, 0, keccak256(bytes(P1)), keccak256(bytes(P2)));
        vm.expectEmit(true, false, false, true, address(ilrm));
        emit ProposalSubmitted(id, P2);
        _propose(id, P2);
    }

    /// @notice The round in ProposalSuperseded is the dispute's counterCount
    function test_ReplacementAfterCounterEmitsSupersededWithRound() public {
        uint256 id = _openDispute();
        _counter(initiator, id);
        _propose(id, P1);

        vm.expectEmit(true, true, false, true, address(ilrm));
        emit ProposalSuperseded(id, 1, keccak256(bytes(P1)), keccak256(bytes(P2)));
        _propose(id, P2);
    }

    function test_FirstProposalOfRoundDoesNotEmitSuperseded() public {
        uint256 id = _openDispute();

        vm.recordLogs();
        _propose(id, P1);
        assertEq(_supersededCount(), 0, "first proposal of round 0 emitted ProposalSuperseded");

        // counterPropose clears the live proposal, so the next round's first proposal supersedes nothing
        _counter(initiator, id);
        vm.recordLogs();
        _propose(id, P2);
        assertEq(_supersededCount(), 0, "first proposal of round 1 emitted ProposalSuperseded");
        assertEq(ilrm.disputes(id).llmProposal, P2);
    }

    /// @notice REGRESSION: no proposal may land after the resolution deadline
    function test_ProposalAfterTimeoutRejected() public {
        uint256 id = _openDispute();
        uint256 deadline = ilrm.disputes(id).startTime + ilrm.RESOLUTION_TIMEOUT();

        vm.warp(deadline + 1);
        vm.prank(address(oracle));
        vm.expectRevert("Timeout passed");
        ilrm.submitLLMProposal(id, P1, hex"01");

        assertEq(bytes(ilrm.disputes(id).llmProposal).length, 0);
    }

    /// @notice A proposal exactly at the deadline is still accepted (same boundary as acceptProposal)
    function test_ProposalAtDeadlineAccepted() public {
        uint256 id = _openDispute();
        vm.warp(ilrm.disputes(id).startTime + ilrm.RESOLUTION_TIMEOUT());
        _propose(id, P1);
        assertEq(ilrm.disputes(id).llmProposal, P1);
    }

    /// @notice The deadline follows counter-proposal extensions
    function test_ProposalDeadlineFollowsCounterExtension() public {
        uint256 id = _openDispute();
        uint256 originalDeadline = ilrm.disputes(id).startTime + ilrm.RESOLUTION_TIMEOUT();
        _counter(initiator, id);

        vm.warp(originalDeadline + 1);
        _propose(id, P1);
        assertEq(ilrm.disputes(id).llmProposal, P1);
    }

    function test_RejectedProposalChangesNothing() public {
        uint256 id = _openDispute();
        _propose(id, P1);
        _accept(initiator, id);

        oracle.setVerify(false);
        vm.prank(address(oracle));
        vm.expectRevert("Invalid signature");
        ilrm.submitLLMProposal(id, P2, hex"01");

        IILRM.Dispute memory d = ilrm.disputes(id);
        assertEq(d.llmProposal, P1);
        assertTrue(d.initiatorAccepted);
        assertFalse(d.counterpartyAccepted);
    }

    function test_OnlyOracleCanSubmit() public {
        uint256 id = _openDispute();
        vm.prank(initiator);
        vm.expectRevert("Only oracle");
        ilrm.submitLLMProposal(id, P1, hex"01");
    }
}
