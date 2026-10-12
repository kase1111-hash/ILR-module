// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "./L3TestBase.sol";

/**
 * @notice Stateful-fuzzing handler for L3Bridge: random interleavings of state commitments, fraud-proof commits,
 *         reveals, forfeits, legacy submissions, finalization, pause, fee withdrawals, dispute bridging and
 *         (single and batched, valid and invalid) settlements. Ghost variables record what the invariants
 *         cannot read back from the bridge directly.
 */
contract L3BridgeHandler is Test {
    struct Commit {
        address challenger;
        bytes32 commitHash;
        bytes32 root; // root the bond was posted against
        bytes32 claimedRoot; // proof.claimedRoot
        bytes invalidStateData;
        bytes32 salt;
        bool revealable; // false for a bare hash with no known proof (can only expire)
    }

    uint256 internal constant BOND = 0.1 ether;
    uint256 internal constant REVEAL_DELAY = 2 minutes;
    bytes32 internal constant CORRECT_ROOT = keccak256("correct_state");

    L3Bridge public immutable bridge;
    address public immutable owner;
    address public immutable sequencer;
    uint256 internal immutable _sequencerKey;
    address public immutable ilrm;
    address public immutable feeSink;

    address[] internal _actors;
    bytes32[] internal _roots;
    mapping(bytes32 => bytes) internal _fraudData; // preimage of roots committed as keccak256(data)
    Commit[] internal _commits;
    mapping(uint256 => IL3Bridge.CommitmentStatus) internal _seenStatus;

    // ============ Ghosts ============

    /// @notice Successful challenges per root (Won reveals + legacy submissions)
    mapping(bytes32 => uint256) public wins;
    mapping(bytes32 => bool) public everFinalized;
    bool public terminalStatusChanged;
    bool public finalizedHeightDecreased;
    bool public finalizedRootUnfinalized;
    uint256 public maxFinalizedHeight;

    uint256 public constant DISPUTE_ID_SPACE = 12;
    mapping(uint256 => bool) public everBridged;
    mapping(uint256 => uint256) public bridgedL3Id;
    bool public bridgedIdChanged;
    mapping(uint256 => bool) public everSettled;
    bool public settlementUndone;
    uint256 public distinctBridged;
    uint256 public distinctSettled;

    constructor(L3Bridge _bridge, address _owner, address _sequencer, uint256 sequencerKey, address _ilrm) {
        bridge = _bridge;
        owner = _owner;
        sequencer = _sequencer;
        _sequencerKey = sequencerKey;
        ilrm = _ilrm;
        feeSink = makeAddr("feeSink");
        for (uint256 i = 0; i < 4; i++) {
            address actor = makeAddr(string(abi.encodePacked("actor", vm.toString(i))));
            vm.deal(actor, 1000 ether);
            _actors.push(actor);
        }
        vm.deal(address(this), 1000 ether);
    }

    // ============ Views for the invariants ============

    function actorCount() external view returns (uint256) {
        return _actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return _actors[i];
    }

    function rootCount() external view returns (uint256) {
        return _roots.length;
    }

    function rootAt(uint256 i) external view returns (bytes32) {
        return _roots[i];
    }

    function commitCount() external view returns (uint256) {
        return _commits.length;
    }

    function commitAt(uint256 i) external view returns (address challenger, bytes32 commitHash, bytes32 root) {
        Commit storage c = _commits[i];
        return (c.challenger, c.commitHash, c.root);
    }

    // ============ Actions: state roots ============

    function submitRoot(bool fraudulent, uint256 salt) external {
        bytes memory data = abi.encode("state", _roots.length, salt);
        bytes32 root = fraudulent ? keccak256(data) : keccak256(abi.encode("honest", _roots.length, salt));
        if (bridge.getRootHeight(root) != 0) return;

        uint256 blockNumber = bridge.latestCommittedHeight() + 1;
        bytes32 previousRoot = bridge.latestCommittedRoot();
        bytes32 messageHash = keccak256(abi.encodePacked(root, blockNumber, uint256(0), previousRoot));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_sequencerKey, MessageHashUtils.toEthSignedMessageHash(messageHash));
        IL3Bridge.StateCommitment memory commitment = IL3Bridge.StateCommitment({
            stateRoot: root,
            blockNumber: blockNumber,
            timestamp: block.timestamp,
            disputeCount: 0,
            previousRoot: previousRoot,
            sequencerSignature: abi.encodePacked(r, s, v)
        });

        vm.prank(sequencer);
        bridge.submitStateCommitment(commitment);
        _roots.push(root);
        if (fraudulent) _fraudData[root] = data;
        _sync();
    }

    function finalize(uint256 rootSeed) external {
        if (_roots.length == 0) return;
        try bridge.finalizeStateCommitment(_roots[rootSeed % _roots.length]) {} catch {}
        _sync();
    }

    /// @notice Warp to the deadline of the next root in chain order (if any) and try to finalize it
    function finalizeNext() external {
        uint256 next = bridge.latestFinalizedHeight() + 1;
        for (uint256 i = 0; i < _roots.length; i++) {
            bytes32 root = _roots[i];
            if (bridge.getRootHeight(root) == next && bridge.isStateCanonical(root)) {
                uint256 deadline = bridge.getChallengeDeadline(root);
                if (block.timestamp < deadline) vm.warp(deadline);
                try bridge.finalizeStateCommitment(root) {} catch {}
                break;
            }
        }
        _sync();
    }

    function warp(uint256 secondsForward) external {
        // Mostly within a reveal window, sometimes far beyond it
        uint256 maxStep = secondsForward % 4 == 0 ? 2 days : 30 minutes;
        vm.warp(block.timestamp + _bound(secondsForward, 1, maxStep));
        _sync();
    }

    // ============ Actions: fraud proofs ============

    function commit(uint256 actorSeed, uint256 rootSeed, uint256 kind, uint256 saltSeed, uint256 extraBond) external {
        if (_roots.length == 0) return;
        Commit memory c;
        c.challenger = _actors[actorSeed % _actors.length];
        c.root = _roots[rootSeed % _roots.length];
        c.salt = keccak256(abi.encode(saltSeed, _commits.length));

        kind = kind % 4;
        if (kind == 0) {
            // Valid proof: prefer a root with a known preimage (otherwise it is invalid and will be forfeited)
            for (uint256 i = 0; i < _roots.length && _fraudData[c.root].length == 0; i++) {
                c.root = _roots[(rootSeed + i) % _roots.length];
            }
            c.claimedRoot = c.root;
            c.invalidStateData = _fraudData[c.root];
            c.revealable = true;
        } else if (kind == 1) {
            // A proof for another root: mismatched, forfeited on reveal
            bytes32 other = _roots[(rootSeed / 7 + 1) % _roots.length];
            c.claimedRoot = other;
            c.invalidStateData = _fraudData[other];
            c.revealable = true;
        } else if (kind == 2) {
            // Claims the root, but the data does not hash to it
            c.claimedRoot = c.root;
            c.invalidStateData = abi.encode("junk", saltSeed);
            c.revealable = true;
        }

        c.commitHash = c.revealable
            ? bridge.computeFraudProofCommitHash(c.challenger, _proof(c), c.salt)
            : keccak256(abi.encode("bare", saltSeed, _commits.length));
        uint256 bond = BOND + _bound(extraBond, 0, 0.1 ether);

        vm.prank(c.challenger);
        try bridge.commitFraudProof{value: bond}(c.commitHash, c.root) {
            _commits.push(c);
        } catch {}
        _sync();
    }

    function reveal(uint256 commitSeed, uint256 offset) external {
        // Reveal the first Pending, revealable commitment from a random starting point
        uint256 len = _commits.length;
        Commit memory c;
        IL3Bridge.FraudProofCommitment memory info;
        for (uint256 i = 0; i < len; i++) {
            c = _commits[(commitSeed + i) % len];
            info = bridge.getFraudProofCommitment(c.challenger, c.commitHash);
            if (c.revealable && info.status == IL3Bridge.CommitmentStatus.Pending) break;
        }
        if (!c.revealable || info.status != IL3Bridge.CommitmentStatus.Pending) return;

        // Move into the reveal window if it has not opened yet (time only moves forward)
        uint256 opens = info.commitTime + REVEAL_DELAY;
        if (block.timestamp < opens) vm.warp(opens + _bound(offset, 0, 1 hours));

        IL3Bridge.FraudProof memory proof = _proof(c);
        vm.prank(c.challenger);
        try bridge.revealFraudProof(proof, c.salt) {} catch {}
        _sync();
    }

    function forfeit(uint256 commitSeed, uint256 callerSeed) external {
        if (_commits.length == 0) return;
        Commit memory c = _commits[commitSeed % _commits.length];
        vm.prank(_actors[callerSeed % _actors.length]);
        try bridge.forfeitExpiredCommitment(c.challenger, c.commitHash) {} catch {}
        _sync();
    }

    function legacySubmit(uint256 actorSeed, uint256 rootSeed) external {
        if (_roots.length == 0 || bridge.commitRevealEnabled()) return;
        bytes32 root = _roots[rootSeed % _roots.length];
        if (_fraudData[root].length == 0) return;
        Commit memory c;
        c.claimedRoot = root;
        c.invalidStateData = _fraudData[root];
        IL3Bridge.FraudProof memory proof = _proof(c);

        vm.prank(_actors[actorSeed % _actors.length]);
        try bridge.submitFraudProof{value: BOND}(proof) {
            wins[root]++;
        } catch {}
        _sync();
    }

    // ============ Actions: owner ============

    /// @notice Re-enable commit-reveal, or (one time in four) disable it to open the legacy path
    function toggleCommitReveal(uint256 seed) external {
        bool enabled = bridge.commitRevealEnabled();
        if (enabled && seed % 4 != 0) return;
        vm.prank(owner);
        bridge.setCommitRevealEnabled(!enabled);
        _sync();
    }

    function togglePause() external {
        bool paused = bridge.paused();
        vm.prank(owner);
        if (paused) bridge.unpause();
        else bridge.pause();
        _sync();
    }

    function withdrawFees(uint256 amountSeed) external {
        uint256 amount = _bound(amountSeed, 0, bridge.freeBalance());
        vm.prank(owner);
        bridge.withdrawFees(feeSink, amount);
        _sync();
    }

    function donate(uint256 amountSeed) external {
        (bool ok,) = address(bridge).call{value: _bound(amountSeed, 0, 1 ether)}("");
        require(ok, "donation failed");
        _sync();
    }

    // ============ Actions: disputes and settlements ============

    function bridgeDisputes(uint256 seed, bool single) external {
        uint256 n = single ? 1 : 1 + (seed % 5);
        IL3Bridge.DisputeInitiationMessage[] memory messages = new IL3Bridge.DisputeInitiationMessage[](n);
        for (uint256 i = 0; i < n; i++) {
            uint256 l2Id = 1 + (uint256(keccak256(abi.encode(seed, i))) % DISPUTE_ID_SPACE);
            messages[i] = _initiationFor(l2Id);
        }

        vm.prank(ilrm);
        if (single) {
            try bridge.bridgeDisputeToL3(messages[0]) {} catch {}
        } else {
            try bridge.bridgeDisputeBatchToL3(messages) {} catch {}
        }
        _sync();
    }

    function settle(uint256 seed, bool single) external {
        uint256 n = single ? 1 : 1 + (seed % 6);
        IL3Bridge.DisputeSettlementMessage[] memory messages = new IL3Bridge.DisputeSettlementMessage[](n);
        for (uint256 i = 0; i < n; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i, "settle")));
            uint256 l2Id = 1 + (r % (DISPUTE_ID_SPACE + 2)); // includes ids that are never bridged
            uint256 l3Id = bridge.getL3DisputeId(l2Id);
            if ((r >> 8) % 5 == 0) l3Id += 1; // occasional L3 ID mismatch
            bytes32 stateProof;
            uint256 p = (r >> 16) % 4;
            if (p == 1 && _roots.length != 0) stateProof = _roots[(r >> 24) % _roots.length]; // any root
            else if (p == 2) stateProof = bridge.latestFinalizedRoot(); // zero before the first finalization
            else if (p == 3) stateProof = keccak256(abi.encode("unknown", r));
            messages[i] = IL3Bridge.DisputeSettlementMessage({
                l2DisputeId: l2Id,
                l3DisputeId: l3Id,
                outcome: IL3Bridge.L3DisputeState.Accepted,
                initiatorReturn: 1 ether,
                counterpartyReturn: 1 ether,
                burnAmount: 0,
                proposalHash: bytes32(r),
                stateProof: stateProof
            });
        }

        vm.prank(sequencer);
        if (single) {
            try bridge.processSettlementFromL3(messages[0]) {} catch {}
        } else {
            try bridge.batchProcessSettlements(messages) {} catch {}
        }
        _sync();
    }

    // ============ Internal ============

    function _proof(Commit memory c) internal pure returns (IL3Bridge.FraudProof memory) {
        return IL3Bridge.FraudProof({
            claimedRoot: c.claimedRoot,
            correctRoot: CORRECT_ROOT,
            merkleProof: new bytes32[](0),
            disputeId: 0,
            invalidStateData: c.invalidStateData
        });
    }

    function _initiationFor(uint256 l2Id) internal view returns (IL3Bridge.DisputeInitiationMessage memory) {
        return IL3Bridge.DisputeInitiationMessage({
            l2DisputeId: l2Id,
            initiator: address(uint160(0x1000 + l2Id)),
            counterparty: address(uint160(0x2000 + l2Id)),
            stakeAmount: 1 ether,
            evidenceHash: keccak256(abi.encode("evidence", l2Id)),
            fallbackTermsHash: bytes32(0),
            l2BlockNumber: block.number
        });
    }

    /// @notice Update the ghosts after every action
    function _sync() internal {
        for (uint256 i = 0; i < _commits.length; i++) {
            Commit storage c = _commits[i];
            IL3Bridge.CommitmentStatus status = bridge.getFraudProofCommitment(c.challenger, c.commitHash).status;
            IL3Bridge.CommitmentStatus seen = _seenStatus[i];
            if (status != seen) {
                // Only Pending may change, and only to a terminal outcome
                if (seen != IL3Bridge.CommitmentStatus.Pending && seen != IL3Bridge.CommitmentStatus.None) {
                    terminalStatusChanged = true;
                }
                if (status == IL3Bridge.CommitmentStatus.Won) wins[c.root]++;
                _seenStatus[i] = status;
            }
        }

        uint256 finalizedHeight = bridge.latestFinalizedHeight();
        if (finalizedHeight < maxFinalizedHeight) finalizedHeightDecreased = true;
        else maxFinalizedHeight = finalizedHeight;
        for (uint256 i = 0; i < _roots.length; i++) {
            bytes32 root = _roots[i];
            if (bridge.isStateFinalized(root)) everFinalized[root] = true;
            else if (everFinalized[root]) finalizedRootUnfinalized = true;
        }

        for (uint256 id = 1; id <= DISPUTE_ID_SPACE + 2; id++) {
            uint256 l3Id = bridge.getL3DisputeId(id);
            if (l3Id != 0 && !everBridged[id]) {
                everBridged[id] = true;
                bridgedL3Id[id] = l3Id;
                distinctBridged++;
            } else if (everBridged[id] && l3Id != bridgedL3Id[id]) {
                bridgedIdChanged = true;
            }
            if (bridge.isDisputeSettled(id)) {
                if (!everSettled[id]) {
                    everSettled[id] = true;
                    distinctSettled++;
                }
            } else if (everSettled[id]) {
                settlementUndone = true;
            }
        }
    }
}

/**
 * @title L3BridgeInvariantTest
 * @notice L3Bridge invariants under stateful fuzzing. I1-I3 carry the labels already used in L3FraudProofs.t.sol;
 *         this suite checks them, and I4-I7, directly after every handler call:
 *   I1 Solvency: the balance always covers the escrowed bonds.
 *   I2 Escrow accounting: sum(challengerBonds) == totalEscrowedBonds == sum(bonds of Pending commitments).
 *   I3 No reveal window is open at a root's deadline: every Pending commitment's window closes before it.
 *   I4 Only canonical, unchallenged roots finalize: a finalized root is canonical, unchallenged and at or below
 *      the finalized height; a challenged root is neither canonical nor finalized; and every canonical root at
 *      or below the finalized height is finalized (the finalized roots are exactly the canonical prefix).
 *   I5 Bond outcomes are final and unique: Won, Refunded and Forfeited never change, and each root is
 *      successfully challenged at most once (and is then the root's active challenge).
 *   I6 Chain heads: latestFinalizedHeight <= latestCommittedHeight; the finalized height never decreases and a
 *      finalized root is never un-finalized; latestFinalizedRoot / latestCommittedRoot are the canonical roots
 *      at those heights (zero at height 0).
 *   I7 Settlement accounting: each dispute is bridged and settled at most once (its L3 ID never changes),
 *      totalBridgedDisputes / totalSettlements count distinct disputes, only bridged disputes settle, and
 *      pendingSettlementsCount == totalBridgedDisputes - totalSettlements.
 */
contract L3BridgeInvariantTest is L3TestBase {
    L3BridgeHandler internal handler;

    function setUp() public {
        address ilrm = makeAddr("ilrm");
        _deployBridge(ilrm);
        vm.deal(address(l3Bridge), 5 ether); // reward pool
        handler = new L3BridgeHandler(l3Bridge, address(this), sequencer, sequencerKey, ilrm);

        bytes4[] memory selectors = new bytes4[](16);
        selectors[0] = L3BridgeHandler.submitRoot.selector;
        selectors[1] = L3BridgeHandler.submitRoot.selector; // weighted: roots drive everything else
        selectors[2] = L3BridgeHandler.finalize.selector;
        selectors[3] = L3BridgeHandler.finalizeNext.selector;
        selectors[4] = L3BridgeHandler.warp.selector;
        selectors[5] = L3BridgeHandler.commit.selector;
        selectors[6] = L3BridgeHandler.commit.selector;
        selectors[7] = L3BridgeHandler.reveal.selector;
        selectors[8] = L3BridgeHandler.forfeit.selector;
        selectors[9] = L3BridgeHandler.legacySubmit.selector;
        selectors[10] = L3BridgeHandler.toggleCommitReveal.selector;
        selectors[11] = L3BridgeHandler.togglePause.selector;
        selectors[12] = L3BridgeHandler.withdrawFees.selector;
        selectors[13] = L3BridgeHandler.bridgeDisputes.selector;
        selectors[14] = L3BridgeHandler.settle.selector;
        selectors[15] = L3BridgeHandler.donate.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 80
    /// forge-config: ci.invariant.runs = 48
    /// forge-config: ci.invariant.depth = 80
    function invariant_I1_BalanceCoversEscrow() public view {
        assertGe(address(l3Bridge).balance, l3Bridge.totalEscrowedBonds(), "I1: balance < escrowed bonds");
        assertEq(l3Bridge.freeBalance(), address(l3Bridge).balance - l3Bridge.totalEscrowedBonds(), "I1: free");
    }

    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 80
    /// forge-config: ci.invariant.runs = 48
    /// forge-config: ci.invariant.depth = 80
    function invariant_I2_EscrowAccounting() public view {
        uint256 escrowed = l3Bridge.totalEscrowedBonds();

        uint256 sumChallengerBonds;
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            sumChallengerBonds += l3Bridge.challengerBonds(handler.actorAt(i));
        }
        assertEq(sumChallengerBonds, escrowed, "I2: sum(challengerBonds) != totalEscrowedBonds");

        uint256 sumPending;
        for (uint256 i = 0; i < handler.commitCount(); i++) {
            (address challenger, bytes32 commitHash,) = handler.commitAt(i);
            IL3Bridge.FraudProofCommitment memory c = l3Bridge.getFraudProofCommitment(challenger, commitHash);
            if (c.status == IL3Bridge.CommitmentStatus.Pending) sumPending += c.bond;
        }
        assertEq(sumPending, escrowed, "I2: sum(Pending bonds) != totalEscrowedBonds");
    }

    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 80
    /// forge-config: ci.invariant.runs = 48
    /// forge-config: ci.invariant.depth = 80
    function invariant_I3_NoRevealWindowOpenAtDeadline() public view {
        uint256 window = l3Bridge.MIN_REVEAL_DELAY() + l3Bridge.MAX_REVEAL_WINDOW();
        for (uint256 i = 0; i < handler.commitCount(); i++) {
            (address challenger, bytes32 commitHash, bytes32 root) = handler.commitAt(i);
            IL3Bridge.FraudProofCommitment memory c = l3Bridge.getFraudProofCommitment(challenger, commitHash);
            if (c.status != IL3Bridge.CommitmentStatus.Pending) continue;
            assertEq(c.stateRoot, root);
            assertLt(c.commitTime + window, l3Bridge.getChallengeDeadline(root), "I3: reveal window reaches deadline");
        }
    }

    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 80
    /// forge-config: ci.invariant.runs = 48
    /// forge-config: ci.invariant.depth = 80
    function invariant_I4_OnlyCanonicalUnchallengedRootsFinalize() public view {
        uint256 finalizedHeight = l3Bridge.latestFinalizedHeight();
        for (uint256 i = 0; i < handler.rootCount(); i++) {
            bytes32 root = handler.rootAt(i);
            bool finalized = l3Bridge.isStateFinalized(root);
            bool canonical = l3Bridge.isStateCanonical(root);
            bool challenged = l3Bridge.getActiveChallenger(root) != address(0);
            uint256 height = l3Bridge.getRootHeight(root);

            if (finalized) {
                assertFalse(challenged, "I4: challenged root finalized");
                assertTrue(canonical, "I4: non-canonical root finalized");
                assertLe(height, finalizedHeight, "I4: finalized root above the finalized height");
            }
            if (challenged) {
                assertFalse(canonical, "I4: challenged root still canonical");
                assertFalse(finalized, "I4: challenged root finalized");
            }
            if (canonical && height <= finalizedHeight) {
                assertTrue(finalized, "I4: gap in the finalized canonical prefix");
            }
        }
    }

    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 80
    /// forge-config: ci.invariant.runs = 48
    /// forge-config: ci.invariant.depth = 80
    function invariant_I5_BondOutcomesFinalAndUnique() public view {
        assertFalse(handler.terminalStatusChanged(), "I5: a terminal bond outcome changed");
        for (uint256 i = 0; i < handler.rootCount(); i++) {
            bytes32 root = handler.rootAt(i);
            uint256 wins = handler.wins(root);
            assertLe(wins, 1, "I5: root successfully challenged twice");
            assertEq(wins == 1, l3Bridge.getActiveChallenger(root) != address(0), "I5: win without active challenge");
        }
    }

    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 80
    /// forge-config: ci.invariant.runs = 48
    /// forge-config: ci.invariant.depth = 80
    function invariant_I6_ChainHeadsConsistent() public view {
        uint256 finalizedHeight = l3Bridge.latestFinalizedHeight();
        uint256 committedHeight = l3Bridge.latestCommittedHeight();
        assertLe(finalizedHeight, committedHeight, "I6: finalized head above committed head");
        assertFalse(handler.finalizedHeightDecreased(), "I6: finalized height decreased");
        assertFalse(handler.finalizedRootUnfinalized(), "I6: finalized root un-finalized");

        bytes32 finalizedRoot = l3Bridge.latestFinalizedRoot();
        if (finalizedHeight == 0) {
            assertEq(finalizedRoot, bytes32(0), "I6: finalized root without height");
        } else {
            assertEq(l3Bridge.getRootHeight(finalizedRoot), finalizedHeight, "I6: finalized root height");
            assertTrue(l3Bridge.isStateCanonical(finalizedRoot), "I6: finalized head not canonical");
            assertTrue(l3Bridge.isStateFinalized(finalizedRoot), "I6: finalized head not finalized");
        }

        bytes32 committedRoot = l3Bridge.latestCommittedRoot();
        if (committedHeight == 0) {
            assertEq(committedRoot, bytes32(0), "I6: committed root without height");
        } else {
            assertEq(l3Bridge.getRootHeight(committedRoot), committedHeight, "I6: committed root height");
            assertTrue(l3Bridge.isStateCanonical(committedRoot), "I6: committed head not canonical");
        }
    }

    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 80
    /// forge-config: ci.invariant.runs = 48
    /// forge-config: ci.invariant.depth = 80
    function invariant_I7_SettlementAccounting() public view {
        assertFalse(handler.bridgedIdChanged(), "I7: bridged dispute re-bridged");
        assertFalse(handler.settlementUndone(), "I7: settlement undone");

        uint256 bridged = l3Bridge.getTotalBridgedDisputes();
        uint256 settled = l3Bridge.getTotalSettlements();
        assertEq(bridged, handler.distinctBridged(), "I7: totalBridgedDisputes != distinct bridged disputes");
        assertEq(settled, handler.distinctSettled(), "I7: totalSettlements != distinct settled disputes");
        assertEq(l3Bridge.getPendingSettlementsCount(), bridged - settled, "I7: pending != bridged - settled");

        for (uint256 id = 1; id <= handler.DISPUTE_ID_SPACE() + 2; id++) {
            if (l3Bridge.isDisputeSettled(id)) assertTrue(l3Bridge.isDisputeBridged(id), "I7: unbridged settled");
            uint256 l3Id = l3Bridge.getL3DisputeId(id);
            if (l3Id != 0) assertEq(l3Bridge.getL2DisputeId(l3Id), id, "I7: L2/L3 ID maps disagree");
        }
    }
}
