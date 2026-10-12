// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ComplianceEscrow} from "../contracts/modules/ComplianceEscrow.sol";
import {IComplianceEscrow} from "../contracts/interfaces/IComplianceEscrow.sol";

/// @dev Only disputeCounter() is used by ComplianceEscrow
contract DisputeCounterStub {
    uint256 public disputeCounter = 5;
}

/**
 * @title ComplianceEscrow existence checks
 * @notice Escrow and request ids are assigned from 0 upwards; an id exists iff it is below its counter. Pins the
 *         counter-based escrowExists / requestExists modifiers, including the id-0 edge case.
 */
contract ComplianceEscrowTest is Test {
    ComplianceEscrow internal escrow;

    address internal h1 = address(0x1001);
    address internal h2 = address(0x1002);
    address internal h3 = address(0x1003);

    function setUp() public {
        escrow = new ComplianceEscrow();
        escrow.setILRM(address(new DisputeCounterStub()));
    }

    function _createEscrow(uint256 disputeId) internal returns (uint256) {
        address[] memory holders = new address[](3);
        holders[0] = h1;
        holders[1] = h2;
        holders[2] = h3;
        IComplianceEscrow.HolderType[] memory types = new IComplianceEscrow.HolderType[](3);
        types[0] = IComplianceEscrow.HolderType.User;
        types[1] = IComplianceEscrow.HolderType.DAO;
        types[2] = IComplianceEscrow.HolderType.Auditor;
        return escrow.createEscrow(disputeId, keccak256("viewing key"), keccak256("data"), 2, 3, holders, types);
    }

    function test_NoEscrowOrRequestBeforeCreation() public {
        vm.expectRevert(abi.encodeWithSelector(IComplianceEscrow.EscrowNotFound.selector, 0));
        escrow.requestReveal(0, "subpoena", keccak256("doc"), 1 days);

        vm.prank(h1);
        vm.expectRevert(abi.encodeWithSelector(IComplianceEscrow.EscrowNotFound.selector, 0));
        escrow.submitShareCommitment(0, keccak256("share"));

        vm.prank(h1);
        vm.expectRevert(abi.encodeWithSelector(IComplianceEscrow.RequestNotFound.selector, 0));
        escrow.voteOnReveal(0, true);

        vm.expectRevert(abi.encodeWithSelector(IComplianceEscrow.RequestNotFound.selector, 0));
        escrow.expireRequest(0);
    }

    function test_IdZeroExistsAfterCreationAndNextIdDoesNot() public {
        assertEq(_createEscrow(1), 0);

        vm.prank(h1);
        escrow.submitShareCommitment(0, keccak256("share"));
        assertEq(escrow.requestReveal(0, "subpoena", keccak256("doc"), 1 days), 0);

        vm.prank(h1);
        escrow.voteOnReveal(0, true);
        assertTrue(escrow.hasVoted(0, h1));

        vm.expectRevert(abi.encodeWithSelector(IComplianceEscrow.EscrowNotFound.selector, 1));
        escrow.requestReveal(1, "subpoena", keccak256("doc"), 1 days);

        vm.prank(h2);
        vm.expectRevert(abi.encodeWithSelector(IComplianceEscrow.RequestNotFound.selector, 1));
        escrow.voteOnReveal(1, true);

        vm.prank(h2);
        vm.expectRevert(abi.encodeWithSelector(IComplianceEscrow.RequestNotFound.selector, 1));
        escrow.submitShareForReveal(1, 1, hex"01");

        vm.expectRevert(abi.encodeWithSelector(IComplianceEscrow.RequestNotFound.selector, 1));
        escrow.finalizeReveal(1, keccak256("key"));
    }

    function test_RevealFlowOnSecondEscrow() public {
        _createEscrow(1);
        assertEq(_createEscrow(2), 1);
        uint256 requestId = escrow.requestReveal(1, "court order", keccak256("doc"), 1 days);
        assertEq(requestId, 0);

        vm.prank(h1);
        escrow.voteOnReveal(requestId, true);
        vm.prank(h2);
        escrow.voteOnReveal(requestId, true);
        assertEq(uint256(escrow.getRevealRequest(requestId).status), uint256(IComplianceEscrow.RevealStatus.Approved));

        vm.prank(h1);
        escrow.submitShareForReveal(requestId, 0, hex"aa");
        vm.prank(h2);
        escrow.submitShareForReveal(requestId, 1, hex"bb");
        vm.prank(h3);
        escrow.finalizeReveal(requestId, keccak256("key"));

        assertTrue(escrow.getEscrow(1).revealed);
        assertFalse(escrow.getEscrow(0).revealed);
    }
}
