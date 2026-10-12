// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/Oracle.sol";
import "../contracts/modules/MultiPartyILRM.sol";
import "../contracts/mocks/MockToken.sol";
import "../contracts/mocks/MockAssetRegistry.sol";
import "../contracts/mocks/MockOracle.sol";

/// @notice Etched at MultiPartyILRM.BURN_ADDRESS: records the dispute state it observes while the counter fee is burned
contract BurnProbe {
    MultiPartyILRM public mp;
    uint256 public disputeId;
    bool public seen;
    uint256 public seenCounterCount;
    bytes32 public seenEvidenceHash;

    function configure(MultiPartyILRM _mp, uint256 _disputeId) external {
        mp = _mp;
        disputeId = _disputeId;
    }

    receive() external payable {
        if (address(mp) == address(0)) return;
        IMultiPartyILRM.MultiPartyDispute memory d = mp.getDispute(disputeId);
        seen = true;
        seenCounterCount = d.counterCount;
        seenEvidenceHash = d.evidenceHash;
    }
}

/**
 * @title OracleMultiPartyTest
 * @notice NatLangChainOracle serves MultiPartyILRM through IOracleConsumer, and MultiPartyILRM carries the fixes
 *         made in ILRM: deadline checks, checks-effects-interactions in counterPropose, compare-and-clear void,
 *         hash-bound acceptance, bounded evidence changes and exact timeout dust.
 */
contract OracleMultiPartyTest is Test {
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant PROPOSAL_TYPEHASH_V2 =
        keccak256("Proposal(uint256 disputeId,uint256 round,bytes32 evidenceHash,bytes32 proposalHash,uint256 nonce)");

    address internal constant BURN = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant STAKE = 10 ether;
    uint256 internal constant FUNDS = 1000 ether;
    bytes32 internal constant EV0 = keccak256("mp-evidence-0");
    bytes32 internal constant EV1 = keccak256("mp-evidence-1");

    string constant P0 = '{"mp":"P0"}';
    string constant P1 = '{"mp":"P1"}';
    string constant P2 = '{"mp":"P2"}';

    // MultiPartyILRM / IOracleConsumer events
    event ProposalSubmitted(uint256 indexed disputeId, string proposal);
    event ProposalSuperseded(
        uint256 indexed disputeId, uint256 indexed round, bytes32 previousProposalHash, bytes32 newProposalHash
    );
    event ProposalVoided(uint256 indexed disputeId, uint256 indexed round, bytes32 proposalHash);
    event CounterProposed(uint256 indexed disputeId, address indexed party, uint256 counterNumber);
    event MultiPartyResolved(uint256 indexed disputeId, IMultiPartyILRM.MultiPartyOutcome outcome, uint256 burnAmount);
    // Oracle events
    event ProposalRoundFilled(uint256 indexed disputeId, uint256 indexed round, bytes32 proposalHash, uint256 nonce);

    MockToken internal token;
    MockAssetRegistry internal registry;
    NatLangChainOracle internal oracle;
    MultiPartyILRM internal mp; // served by the real Oracle
    MockOracle internal mockOracle;
    MultiPartyILRM internal mpMock; // signatures always verify

    address internal operator;
    uint256 internal operatorKey;
    address internal partyA = makeAddr("partyA");
    address internal partyB = makeAddr("partyB");
    address internal partyC = makeAddr("partyC");

    function setUp() public {
        (operator, operatorKey) = makeAddrAndKey("mp-operator");
        token = new MockToken();
        registry = new MockAssetRegistry();

        oracle = new NatLangChainOracle();
        mp = new MultiPartyILRM(IERC20(address(token)), address(oracle), registry);
        oracle.setILRM(address(mp));
        oracle.registerOracle(operator, keccak256("mp-operator-key"));

        mockOracle = new MockOracle();
        mpMock = new MultiPartyILRM(IERC20(address(token)), address(mockOracle), registry);

        address[3] memory parties = [partyA, partyB, partyC];
        for (uint256 i = 0; i < parties.length; i++) {
            token.mint(parties[i], FUNDS);
            vm.startPrank(parties[i]);
            token.approve(address(mp), type(uint256).max);
            token.approve(address(mpMock), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ============ Helpers ============

    function _hash(string memory s) internal pure returns (bytes32) {
        return keccak256(bytes(s));
    }

    function _config() internal pure returns (IMultiPartyILRM.DisputeConfig memory) {
        return IMultiPartyILRM.DisputeConfig({
            quorumType: IMultiPartyILRM.QuorumType.SimpleMajority,
            customQuorumBps: 0,
            minParties: 2,
            maxParties: 20,
            stakeWindow: 0, // default 3 days
            resolutionTimeout: 0, // default 7 days
            allowLateJoin: false
        });
    }

    function _fallback() internal pure returns (IMultiPartyILRM.FallbackLicense memory) {
        return IMultiPartyILRM.FallbackLicense({
            termsHash: keccak256("mp-fallback"), duration: 365 days, royaltyCap: 500, nonExclusive: true
        });
    }

    function _parties() internal view returns (address[] memory parties) {
        parties = new address[](3);
        parties[0] = partyA;
        parties[1] = partyB;
        parties[2] = partyC;
    }

    function _create(MultiPartyILRM m) internal returns (uint256 id) {
        vm.prank(partyA);
        id = m.createMultiPartyDispute(_parties(), STAKE, EV0, _fallback(), _config());
    }

    function _createAllStaked(MultiPartyILRM m) internal returns (uint256 id) {
        id = _create(m);
        vm.prank(partyB);
        m.depositStake(id);
        vm.prank(partyC);
        m.depositStake(id);
    }

    function _deadline(MultiPartyILRM m, uint256 id) internal view returns (uint256) {
        IMultiPartyILRM.MultiPartyDispute memory d = m.getDispute(id);
        return d.startTime + d.config.stakeWindow + d.config.resolutionTimeout;
    }

    function _counter(MultiPartyILRM m, address party, uint256 id, bytes32 evidence) internal {
        uint256 fee = m.COUNTER_FEE_BASE() << m.getDispute(id).counterCount;
        vm.deal(party, fee);
        vm.prank(party);
        m.counterPropose{value: fee}(id, evidence);
    }

    /// @dev Independent EIP-712 digest of the dispute's live MultiPartyILRM context, cross-checked with the Oracle
    function _signCurrent(uint256 id, string memory proposal) internal view returns (bytes memory) {
        IMultiPartyILRM.MultiPartyDispute memory d = mp.getDispute(id);
        bytes32 domain = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("NatLangChainOracle"), keccak256("1"), block.chainid, address(oracle))
        );
        bytes32 structHash = keccak256(
            abi.encode(PROPOSAL_TYPEHASH_V2, id, d.counterCount, d.evidenceHash, _hash(proposal), oracle.getNonce(id))
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domain, structHash));
        assertEq(digest, oracle.proposalDigest(id, _hash(proposal)), "independent digest != oracle.proposalDigest");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _relay(uint256 id, string memory proposal) internal {
        bytes memory sig = _signCurrent(id, proposal);
        vm.prank(operator);
        oracle.submitProposal(id, proposal, sig);
    }

    function _info(MultiPartyILRM m, uint256 id, address party)
        internal
        view
        returns (IMultiPartyILRM.PartyInfo memory)
    {
        return m.getPartyInfo(id, party);
    }

    // ============ End to end through the real Oracle ============

    /// @notice REGRESSION: the Oracle decoded IILRM.Dispute and could not serve MultiPartyILRM at all
    function test_OracleServesMultiPartyEndToEnd() public {
        uint256 id = _createAllStaked(mp);

        (uint256 round, bytes32 evidenceHash, bool resolved, uint256 deadline) = mp.oracleContext(id);
        assertEq(round, 0);
        assertEq(evidenceHash, EV0);
        assertFalse(resolved);
        assertEq(deadline, _deadline(mp, id));

        // Round 0
        vm.expectEmit(true, false, false, true, address(mp));
        emit ProposalSubmitted(id, P0);
        _relay(id, P0);
        assertEq(mp.getDispute(id).llmProposal, P0);
        assertEq(oracle.roundProposals(id, 0), _hash(P0));

        // A counter opens round 1, whose relay needs no admin call
        _counter(mp, partyA, id, EV1);
        (uint256 r, bytes32 ev, uint256 nonce, bool open) = oracle.proposalContext(id);
        assertEq(r, 1);
        assertEq(ev, EV1);
        assertEq(nonce, 1);
        assertTrue(open);
        _relay(id, P1);
        assertEq(oracle.roundProposals(id, 1), _hash(P1));

        // Votes on P1
        vm.prank(partyA);
        mp.acceptProposalWithHash(id, _hash(P1));
        vm.prank(partyB);
        mp.rejectProposal(id);
        assertEq(mp.getDispute(id).acceptanceCount, 1);
        assertEq(mp.getDispute(id).rejectionCount, 1);

        // The owner's reset voids the text, the counts and every flag in the same transaction
        vm.expectEmit(true, true, false, true, address(mp));
        emit ProposalVoided(id, 1, _hash(P1));
        oracle.resetProposal(id, "bad P1");
        IMultiPartyILRM.MultiPartyDispute memory d = mp.getDispute(id);
        assertEq(d.llmProposal, "");
        assertEq(d.acceptanceCount, 0);
        assertEq(d.rejectionCount, 0);
        assertFalse(_info(mp, id, partyA).hasAccepted);
        assertFalse(_info(mp, id, partyB).hasRejected);
        assertEq(oracle.getNonce(id), 3);

        // The replacement lands without superseding anything
        vm.expectEmit(true, true, false, true, address(oracle));
        emit ProposalRoundFilled(id, 1, _hash(P2), 3);
        _relay(id, P2);
        assertEq(mp.getDispute(id).llmProposal, P2);

        // An acceptance of the voided proposal cannot land on P2
        vm.prank(partyC);
        vm.expectRevert("Proposal changed");
        mp.acceptProposalWithHash(id, _hash(P1));

        // Quorum (simple majority of 3 = 2) accepts P2
        vm.prank(partyA);
        mp.acceptProposalWithHash(id, _hash(P2));
        vm.expectEmit(true, false, false, true, address(mp));
        emit MultiPartyResolved(id, IMultiPartyILRM.MultiPartyOutcome.QuorumAccepted, 0);
        vm.prank(partyB);
        mp.acceptProposalWithHash(id, _hash(P2));

        d = mp.getDispute(id);
        assertTrue(d.resolved);
        assertEq(uint256(d.outcome), uint256(IMultiPartyILRM.MultiPartyOutcome.QuorumAccepted));

        // No tokens or ETH left behind; every stake returned
        assertEq(token.balanceOf(address(mp)), 0);
        assertEq(address(mp).balance, 0);
        assertEq(token.balanceOf(partyA), FUNDS);
        assertEq(token.balanceOf(partyB), FUNDS);
        assertEq(token.balanceOf(partyC), FUNDS);
    }

    function test_OracleRejectsLateProposalForMultiParty() public {
        uint256 id = _createAllStaked(mp);
        vm.warp(_deadline(mp, id) + 1);
        bytes memory sig = _signCurrent(id, P0);

        vm.prank(operator);
        vm.expectRevert("Timeout passed");
        oracle.submitProposal(id, P0, sig);
        assertEq(oracle.roundProposals(id, 0), bytes32(0));
        assertEq(oracle.getNonce(id), 0);
    }

    /// @notice REGRESSION: a reset after the deadline could never be followed by a replacement
    function test_MP_ResetAfterDeadlineRejected() public {
        uint256 id = _createAllStaked(mp);
        _relay(id, P0);
        uint256 deadline = _deadline(mp, id);
        vm.warp(deadline + 1);

        vm.expectRevert(abi.encodeWithSelector(NatLangChainOracle.ResolutionDeadlinePassed.selector, id, deadline));
        oracle.resetProposal(id, "too late");
        assertEq(mp.getDispute(id).llmProposal, P0);
        assertEq(oracle.getNonce(id), 1);
    }

    // ============ Deadlines and staking ============

    /// @notice REGRESSION: a counter after the deadline revived a timed-out dispute
    function test_MP_CounterAfterDeadlineReverts() public {
        uint256 id = _createAllStaked(mpMock);
        uint256 start = mpMock.getDispute(id).startTime;
        vm.warp(_deadline(mpMock, id) + 1);

        uint256 fee = mpMock.COUNTER_FEE_BASE();
        vm.deal(partyB, fee);
        vm.prank(partyB);
        vm.expectRevert("Timeout passed");
        mpMock.counterPropose{value: fee}(id, EV1);
        assertEq(mpMock.getDispute(id).startTime, start);

        mpMock.enforceTimeout(id);
        assertEq(uint256(mpMock.getDispute(id).outcome), uint256(IMultiPartyILRM.MultiPartyOutcome.TimeoutWithBurn));
    }

    function test_MP_CounterAtDeadlineAllowed() public {
        uint256 id = _createAllStaked(mpMock);
        uint256 start = mpMock.getDispute(id).startTime;
        vm.warp(_deadline(mpMock, id));

        vm.expectEmit(true, true, false, true, address(mpMock));
        emit CounterProposed(id, partyB, 1);
        _counter(mpMock, partyB, id, EV1);
        assertEq(mpMock.getDispute(id).startTime, start + 1 days);
    }

    /// @notice REGRESSION: a counter before every party staked moved the stake window
    function test_MP_CounterRequiresAllPartiesStaked() public {
        uint256 id = _create(mpMock);
        vm.prank(partyB);
        mpMock.depositStake(id);
        uint256 start = mpMock.getDispute(id).startTime;

        uint256 fee = mpMock.COUNTER_FEE_BASE();
        vm.deal(partyA, fee);
        vm.prank(partyA);
        vm.expectRevert("Not all parties staked");
        mpMock.counterPropose{value: fee}(id, EV1);

        assertEq(mpMock.getDispute(id).startTime, start, "stake window moved");
        assertEq(mpMock.getDispute(id).counterCount, 0);

        // The stake window still closes on time
        vm.warp(start + 3 days + 1);
        vm.prank(partyC);
        vm.expectRevert("Stake window closed");
        mpMock.depositStake(id);
    }

    /// @notice REGRESSION: proposals were admitted after the resolution deadline
    function test_MP_SubmitAfterDeadlineReverts() public {
        uint256 id = _createAllStaked(mpMock);
        vm.warp(_deadline(mpMock, id) + 1);

        vm.prank(address(mockOracle));
        vm.expectRevert("Timeout passed");
        mpMock.submitLLMProposal(id, P0, hex"01");
        assertEq(mpMock.getDispute(id).llmProposal, "");
    }

    function test_MP_SubmitAtDeadlineAllowed() public {
        uint256 id = _createAllStaked(mpMock);
        vm.warp(_deadline(mpMock, id));

        vm.prank(address(mockOracle));
        mpMock.submitLLMProposal(id, P0, hex"01");
        assertEq(mpMock.getDispute(id).llmProposal, P0);
    }

    /// @notice REGRESSION (Slither reentrancy-eth): every state update lands before the fee burn
    function test_MP_CounterBurnsAfterStateUpdates() public {
        uint256 id = _createAllStaked(mpMock);
        vm.etch(BURN, address(new BurnProbe()).code);
        BurnProbe(payable(BURN)).configure(mpMock, id);

        _counter(mpMock, partyA, id, EV1);

        BurnProbe probe = BurnProbe(payable(BURN));
        assertTrue(probe.seen(), "fee not burned through BURN_ADDRESS");
        assertEq(probe.seenCounterCount(), 1, "counterCount not updated before the burn");
        assertEq(probe.seenEvidenceHash(), EV1, "evidence not updated before the burn");
        assertEq(BURN.balance, mpMock.COUNTER_FEE_BASE());
    }

    function test_MP_SubmitClearsVotesAndSupersedes() public {
        uint256 id = _createAllStaked(mpMock);
        vm.prank(address(mockOracle));
        mpMock.submitLLMProposal(id, P0, hex"01");
        vm.prank(partyA);
        mpMock.acceptProposal(id);
        vm.prank(partyB);
        mpMock.rejectProposal(id);

        vm.expectEmit(true, true, false, true, address(mpMock));
        emit ProposalSuperseded(id, 0, _hash(P0), _hash(P1));
        vm.expectEmit(true, false, false, true, address(mpMock));
        emit ProposalSubmitted(id, P1);
        vm.prank(address(mockOracle));
        mpMock.submitLLMProposal(id, P1, hex"01");

        IMultiPartyILRM.MultiPartyDispute memory d = mpMock.getDispute(id);
        assertEq(d.acceptanceCount, 0);
        assertEq(d.rejectionCount, 0);
        assertFalse(_info(mpMock, id, partyA).hasAccepted);
        assertFalse(_info(mpMock, id, partyB).hasRejected);
    }

    // ============ The void hook ============

    function test_MP_VoidOnlyOracle() public {
        uint256 id = _createAllStaked(mp);
        _relay(id, P0);

        vm.prank(partyA);
        vm.expectRevert("Only oracle");
        mp.voidLLMProposal(id, _hash(P0));
        vm.prank(operator);
        vm.expectRevert("Only oracle");
        mp.voidLLMProposal(id, _hash(P0));
        assertEq(mp.getDispute(id).llmProposal, P0);
    }

    function test_MP_VoidGuards() public {
        uint256 id = _createAllStaked(mpMock);

        // Nothing live: no-op without logs
        vm.recordLogs();
        vm.prank(address(mockOracle));
        mpMock.voidLLMProposal(id, _hash(P0));
        assertEq(vm.getRecordedLogs().length, 0);

        vm.prank(address(mockOracle));
        mpMock.submitLLMProposal(id, P0, hex"01");
        vm.prank(partyA);
        mpMock.acceptProposal(id);

        vm.prank(address(mockOracle));
        vm.expectRevert("Proposal mismatch");
        mpMock.voidLLMProposal(id, _hash(P1));
        assertEq(mpMock.getDispute(id).acceptanceCount, 1);

        vm.warp(_deadline(mpMock, id) + 1);
        vm.prank(address(mockOracle));
        vm.expectRevert("Timeout passed");
        mpMock.voidLLMProposal(id, _hash(P0));

        mpMock.enforceTimeout(id);
        vm.prank(address(mockOracle));
        vm.expectRevert("Dispute resolved");
        mpMock.voidLLMProposal(id, _hash(P0));
    }

    function test_MP_VoidWorksWhilePaused() public {
        uint256 id = _createAllStaked(mp);
        _relay(id, P0);
        mp.pause();

        oracle.resetProposal(id, "paused recovery");
        assertEq(mp.getDispute(id).llmProposal, "");
        _relay(id, P1);
        assertEq(mp.getDispute(id).llmProposal, P1);
    }

    // ============ Evidence ============

    function test_MP_EvidenceOncePerRound() public {
        uint256 id = _createAllStaked(mpMock);

        vm.prank(partyB);
        mpMock.submitEvidence(id, keccak256("b-0"));
        bytes32 aggregate = mpMock.getDispute(id).evidenceHash;

        vm.prank(partyB);
        vm.expectRevert("Evidence already submitted");
        mpMock.submitEvidence(id, keccak256("b-0-again"));
        assertEq(mpMock.getDispute(id).evidenceHash, aggregate);

        // Another party still has its own change this round
        vm.prank(partyC);
        mpMock.submitEvidence(id, keccak256("c-0"));

        // A counter opens a new round with a fresh allowance
        _counter(mpMock, partyA, id, EV1);
        vm.prank(partyB);
        mpMock.submitEvidence(id, keccak256("b-1"));
        assertEq(mpMock.getDispute(id).evidenceHash, keccak256(abi.encodePacked(EV1, keccak256("b-1"))));
    }

    function test_MP_EvidenceFrozenWhileProposalLive() public {
        uint256 id = _createAllStaked(mp);
        _relay(id, P0);

        vm.prank(partyB);
        vm.expectRevert("Proposal live");
        mp.submitEvidence(id, keccak256("b-0"));

        // After a void the round is open again and evidence may change (the next signature binds it)
        oracle.resetProposal(id, "void");
        vm.prank(partyB);
        mp.submitEvidence(id, keccak256("b-0"));
        _relay(id, P1);
        assertEq(mp.getDispute(id).llmProposal, P1);
    }

    function test_MP_EvidenceAfterDeadlineReverts() public {
        uint256 id = _createAllStaked(mpMock);
        vm.warp(_deadline(mpMock, id) + 1);
        vm.prank(partyB);
        vm.expectRevert("Timeout passed");
        mpMock.submitEvidence(id, keccak256("late"));
    }

    // ============ Timeout accounting ============

    /// @notice Timeout burns exactly half plus the division dust and returns the rest evenly; nothing is stuck
    function testFuzz_MP_TimeoutConservesTokens(uint8 nSeed, uint256 stake) public {
        uint256 n = bound(nSeed, 2, 12);
        stake = bound(stake, 1, 1e30);

        address[] memory parties = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            parties[i] = address(uint160(0x10000 + i));
            token.mint(parties[i], stake);
            vm.prank(parties[i]);
            token.approve(address(mpMock), type(uint256).max);
        }
        vm.prank(parties[0]);
        uint256 id = mpMock.createMultiPartyDispute(parties, stake, EV0, _fallback(), _config());
        for (uint256 i = 1; i < n; i++) {
            vm.prank(parties[i]);
            mpMock.depositStake(id);
        }

        vm.warp(_deadline(mpMock, id) + 1);
        uint256 burnedBefore = token.balanceOf(BURN);
        mpMock.enforceTimeout(id);

        uint256 total = stake * n;
        uint256 burn = (total * mpMock.BURN_PERCENTAGE()) / 100;
        uint256 remainder = total - burn;
        assertEq(token.balanceOf(address(mpMock)), 0, "tokens stuck in MultiPartyILRM");
        assertEq(token.balanceOf(BURN) - burnedBefore, burn + (remainder % n), "burn + dust");
        for (uint256 i = 0; i < n; i++) {
            assertEq(token.balanceOf(parties[i]), remainder / n);
        }
    }
}
