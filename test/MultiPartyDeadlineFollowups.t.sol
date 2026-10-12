// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/modules/MultiPartyILRM.sol";
import "../contracts/mocks/MockToken.sol";
import "../contracts/mocks/MockAssetRegistry.sol";
import "../contracts/mocks/MockOracle.sol";

/**
 * @title MultiPartyDeadlineFollowupsTest
 * @notice MultiPartyILRM follow-ups: rejectProposal has the same inclusive resolution-deadline check as the other
 *         dispute-changing calls, counterPropose clears every vote, and evidence is still accepted at the deadline.
 */
contract MultiPartyDeadlineFollowupsTest is Test {
    uint256 internal constant STAKE = 10 ether;
    bytes32 internal constant EV0 = keccak256("mp-followups-evidence-0");
    bytes32 internal constant EV1 = keccak256("mp-followups-evidence-1");
    string internal constant P0 = '{"mp-followups":"P0"}';
    string internal constant P1 = '{"mp-followups":"P1"}';

    MockToken internal token;
    MockAssetRegistry internal registry;
    MockOracle internal mockOracle;
    MultiPartyILRM internal mp; // signatures always verify

    address internal partyA = makeAddr("partyA");
    address internal partyB = makeAddr("partyB");
    address internal partyC = makeAddr("partyC");

    function setUp() public {
        token = new MockToken();
        registry = new MockAssetRegistry();
        mockOracle = new MockOracle();
        mp = new MultiPartyILRM(IERC20(address(token)), address(mockOracle), registry);

        address[3] memory parties = [partyA, partyB, partyC];
        for (uint256 i = 0; i < parties.length; i++) {
            token.mint(parties[i], 1000 ether);
            vm.prank(parties[i]);
            token.approve(address(mp), type(uint256).max);
        }
    }

    // ============ Helpers ============

    function _parties() internal view returns (address[] memory parties) {
        parties = new address[](3);
        parties[0] = partyA;
        parties[1] = partyB;
        parties[2] = partyC;
    }

    /// @dev Three parties, simple majority (2 of 3), every party staked
    function _createAllStaked() internal returns (uint256 id) {
        IMultiPartyILRM.DisputeConfig memory config = IMultiPartyILRM.DisputeConfig({
            quorumType: IMultiPartyILRM.QuorumType.SimpleMajority,
            customQuorumBps: 0,
            minParties: 2,
            maxParties: 20,
            stakeWindow: 0, // default 3 days
            resolutionTimeout: 0, // default 7 days
            allowLateJoin: false
        });
        IMultiPartyILRM.FallbackLicense memory fallbackLicense = IMultiPartyILRM.FallbackLicense({
            termsHash: keccak256("mp-followups-fallback"), duration: 365 days, royaltyCap: 500, nonExclusive: true
        });
        vm.prank(partyA);
        id = mp.createMultiPartyDispute(_parties(), STAKE, EV0, fallbackLicense, config);
        vm.prank(partyB);
        mp.depositStake(id);
        vm.prank(partyC);
        mp.depositStake(id);
    }

    function _deadline(uint256 id) internal view returns (uint256) {
        IMultiPartyILRM.MultiPartyDispute memory d = mp.getDispute(id);
        return d.startTime + d.config.stakeWindow + d.config.resolutionTimeout;
    }

    function _propose(uint256 id, string memory proposal) internal {
        vm.prank(address(mockOracle));
        mp.submitLLMProposal(id, proposal, hex"01");
    }

    function _counter(address party, uint256 id, bytes32 evidence) internal {
        uint256 fee = mp.COUNTER_FEE_BASE() << mp.getDispute(id).counterCount;
        vm.deal(party, fee);
        vm.prank(party);
        mp.counterPropose{value: fee}(id, evidence);
    }

    function _assertNoVotes(uint256 id) internal view {
        IMultiPartyILRM.MultiPartyDispute memory d = mp.getDispute(id);
        assertEq(d.acceptanceCount, 0, "acceptanceCount not cleared");
        assertEq(d.rejectionCount, 0, "rejectionCount not cleared");
        (, uint256 current,) = mp.checkQuorum(id);
        assertEq(current, 0, "checkQuorum still counts a cleared acceptance");

        address[] memory parties = _parties();
        for (uint256 i = 0; i < parties.length; i++) {
            IMultiPartyILRM.PartyInfo memory info = mp.getPartyInfo(id, parties[i]);
            assertFalse(info.hasAccepted, "party acceptance not cleared");
            assertFalse(info.hasRejected, "party rejection not cleared");
        }
        IMultiPartyILRM.PartyInfo[] memory all = mp.getParties(id);
        for (uint256 i = 0; i < all.length; i++) {
            assertFalse(all[i].hasAccepted || all[i].hasRejected, "getParties still shows a vote");
        }
    }

    // ============ rejectProposal deadline ============

    /// @notice REGRESSION: rejectProposal changed the dispute after the resolution deadline, where only
    ///         enforceTimeout may act
    function test_MP_RejectAfterDeadlineReverts() public {
        uint256 id = _createAllStaked();
        _propose(id, P0);
        vm.warp(_deadline(id) + 1);

        vm.prank(partyB);
        vm.expectRevert("Timeout passed");
        mp.rejectProposal(id);

        assertFalse(mp.getPartyInfo(id, partyB).hasRejected, "late rejection recorded");
        assertEq(mp.getDispute(id).rejectionCount, 0, "late rejection counted");

        mp.enforceTimeout(id);
        assertEq(uint256(mp.getDispute(id).outcome), uint256(IMultiPartyILRM.MultiPartyOutcome.TimeoutWithBurn));
    }

    /// @notice The deadline is inclusive, as for acceptProposal, counterPropose, submitEvidence and proposals
    function test_MP_RejectAtDeadlineAllowed() public {
        uint256 id = _createAllStaked();
        _propose(id, P0);
        vm.warp(_deadline(id));

        vm.prank(partyB);
        mp.rejectProposal(id);

        assertTrue(mp.getPartyInfo(id, partyB).hasRejected);
        assertEq(mp.getDispute(id).rejectionCount, 1);

        // The dispute is still open at the deadline, and enforceTimeout must wait until after it
        vm.expectRevert("Resolution window open");
        mp.enforceTimeout(id);
    }

    function test_MP_AcceptAndRejectShareTheDeadline() public {
        uint256 id = _createAllStaked();
        _propose(id, P0);
        vm.warp(_deadline(id) + 1);

        vm.prank(partyA);
        vm.expectRevert("Timeout passed");
        mp.acceptProposal(id);
        vm.prank(partyA);
        vm.expectRevert("Timeout passed");
        mp.rejectProposal(id);
    }

    // ============ counterPropose clears votes ============

    /// @notice A counter replaces the proposal, so every acceptance and rejection of it must be cleared
    function test_MP_CounterClearsVotes() public {
        uint256 id = _createAllStaked();
        _propose(id, P0);
        vm.prank(partyA);
        mp.acceptProposal(id);
        vm.prank(partyB);
        mp.rejectProposal(id);

        IMultiPartyILRM.MultiPartyDispute memory before = mp.getDispute(id);
        assertEq(before.acceptanceCount, 1);
        assertEq(before.rejectionCount, 1);
        assertTrue(mp.getPartyInfo(id, partyA).hasAccepted);
        assertTrue(mp.getPartyInfo(id, partyB).hasRejected);

        _counter(partyC, id, EV1);

        IMultiPartyILRM.MultiPartyDispute memory d = mp.getDispute(id);
        assertEq(d.counterCount, 1);
        assertEq(d.llmProposal, "");
        _assertNoVotes(id);

        // Every party votes afresh on the next round's proposal; one more acceptance alone does not reach quorum
        _propose(id, P1);
        vm.prank(partyB);
        mp.acceptProposal(id);
        assertFalse(mp.getDispute(id).resolved, "a vote from the previous round counted toward quorum");
        vm.prank(partyA);
        mp.acceptProposal(id);
        assertTrue(mp.getDispute(id).resolved);
        assertEq(uint256(mp.getDispute(id).outcome), uint256(IMultiPartyILRM.MultiPartyOutcome.QuorumAccepted));
    }

    // ============ submitEvidence deadline boundary ============

    function test_MP_EvidenceAtDeadlineAllowed() public {
        uint256 id = _createAllStaked();
        vm.warp(_deadline(id));

        bytes32 evidence = keccak256("at-deadline");
        vm.prank(partyB);
        mp.submitEvidence(id, evidence);

        assertEq(mp.getDispute(id).evidenceHash, keccak256(abi.encodePacked(EV0, evidence)));
        assertEq(mp.getPartyInfo(id, partyB).evidenceHash, evidence);

        vm.warp(_deadline(id) + 1);
        vm.prank(partyC);
        vm.expectRevert("Timeout passed");
        mp.submitEvidence(id, keccak256("after-deadline"));
    }
}
