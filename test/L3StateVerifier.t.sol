// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "./L3TestBase.sol";
import "../contracts/scaling/L3StateVerifier.sol";

/**
 * @title L3StateVerifierTest
 * @notice computeRoot (rewritten to clear Slither's divide-before-multiply) against an independent recursive
 *         reference, and round trips of its roots through the verifier's index-ordered proof checks
 */
contract L3StateVerifierTest is L3TestBase {
    L3StateVerifier public verifier;

    function setUp() public {
        _deployBridge(makeAddr("ilrm"));
        verifier = new L3StateVerifier(address(l3Bridge));
    }

    // ============ Reference ============

    function _width(uint256 n) internal pure returns (uint256 width) {
        width = 1;
        while (width < n) width <<= 1;
    }

    /// @notice Root of the zero-padded subtree of `width` leaves starting at `start`
    function _refNode(bytes32[] memory leaves, uint256 start, uint256 width) internal pure returns (bytes32) {
        if (width == 1) return start < leaves.length ? leaves[start] : bytes32(0);
        uint256 half = width >> 1;
        return keccak256(abi.encodePacked(_refNode(leaves, start, half), _refNode(leaves, start + half, half)));
    }

    function _refRoot(bytes32[] memory leaves) internal pure returns (bytes32) {
        return _refNode(leaves, 0, _width(leaves.length));
    }

    /// @notice Bottom-up sibling path for leaf `index`
    function _refProof(bytes32[] memory leaves, uint256 index) internal pure returns (bytes32[] memory proof) {
        uint256 width = _width(leaves.length);
        uint256 depth;
        while ((uint256(1) << depth) < width) depth++;
        proof = new bytes32[](depth);
        for (uint256 level = 0; level < depth; level++) {
            uint256 sibling = (index >> level) ^ 1;
            proof[level] = _refNode(leaves, sibling << level, uint256(1) << level);
        }
    }

    function _leaves(uint256 seed, uint256 n) internal pure returns (bytes32[] memory leaves) {
        leaves = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            leaves[i] = keccak256(abi.encode(seed, i));
        }
    }

    function _summary(uint256 i) internal pure returns (IL3Bridge.L3DisputeSummary memory) {
        return IL3Bridge.L3DisputeSummary({
            l3DisputeId: i + 1,
            l2DisputeId: 100 + i,
            state: IL3Bridge.L3DisputeState.Accepted,
            counterCount: i % 3,
            initiatorAccepted: true,
            counterpartyAccepted: i % 2 == 0,
            currentProposalHash: keccak256(abi.encode("proposal", i)),
            lastUpdateBlock: 1000 + i
        });
    }

    // ============ computeRoot ============

    function test_ComputeRootSmallTrees() public view {
        bytes32 a = keccak256("a");
        bytes32 b = keccak256("b");
        bytes32 c = keccak256("c");
        bytes32 d = keccak256("d");
        bytes32 e = keccak256("e");

        bytes32[] memory one = new bytes32[](1);
        one[0] = a;
        assertEq(verifier.computeRoot(one), a);

        bytes32[] memory two = new bytes32[](2);
        two[0] = a;
        two[1] = b;
        bytes32 ab = keccak256(abi.encodePacked(a, b));
        assertEq(verifier.computeRoot(two), ab);

        bytes32[] memory three = new bytes32[](3);
        three[0] = a;
        three[1] = b;
        three[2] = c;
        bytes32 c0 = keccak256(abi.encodePacked(c, bytes32(0)));
        assertEq(verifier.computeRoot(three), keccak256(abi.encodePacked(ab, c0)));

        bytes32[] memory five = new bytes32[](5);
        five[0] = a;
        five[1] = b;
        five[2] = c;
        five[3] = d;
        five[4] = e;
        bytes32 abcd = keccak256(abi.encodePacked(ab, keccak256(abi.encodePacked(c, d))));
        bytes32 e000 = keccak256(abi.encodePacked(keccak256(abi.encodePacked(e, bytes32(0))), verifier.getZeroHash(1)));
        assertEq(verifier.computeRoot(five), keccak256(abi.encodePacked(abcd, e000)));

        // An all-empty tree of width 2^k is the k-th zero hash
        assertEq(verifier.computeRoot(new bytes32[](8)), verifier.getZeroHash(3));
    }

    function test_ComputeRootRejectsEmpty() public {
        vm.expectRevert(bytes("Empty leaves"));
        verifier.computeRoot(new bytes32[](0));
    }

    function testFuzz_ComputeRootMatchesReference(uint256 seed, uint256 n) public view {
        n = bound(n, 1, 70);
        bytes32[] memory leaves = _leaves(seed, n);
        assertEq(verifier.computeRoot(leaves), _refRoot(leaves));
    }

    // ============ Round trip ============

    function test_ComputeRootProofsVerify() public {
        uint256 n = 6;
        bytes32[] memory leaves = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            leaves[i] = verifier.computeDisputeLeaf(_summary(i));
        }
        bytes32 root = verifier.computeRoot(leaves);

        _submitOnHead(root);
        vm.warp(l3Bridge.getChallengeDeadline(root));
        l3Bridge.finalizeStateCommitment(root);

        for (uint256 i = 0; i < n; i++) {
            bytes32[] memory proof = _refProof(leaves, i);
            assertTrue(verifier.verifyDisputeInclusion(root, i + 1, _summary(i), i, proof), "inclusion");
            // The index is bound into the path
            assertFalse(verifier.verifyDisputeInclusion(root, i + 1, _summary(i), i ^ 1, proof), "wrong index");
        }

        // The padded positions 6 and 7 prove empty
        for (uint256 i = n; i < _width(n); i++) {
            assertTrue(verifier.verifyExclusion(root, 0, i, _refProof(leaves, i)), "exclusion");
        }
        assertFalse(verifier.verifyExclusion(root, 0, 0, _refProof(leaves, 0)), "occupied leaf proved empty");
    }
}
