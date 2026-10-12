// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import "../interfaces/IOracle.sol";

/**
 * @title MockOracle - Minimal oracle for ILRM testing
 * @dev ILRM calls back verifySignature() on its oracle, so the oracle must be a contract.
 *      Signature checks pass by default; toggle with setVerify() to test rejection.
 */
contract MockOracle is IOracle {
    bool public shouldVerify = true;

    function setVerify(bool _verify) external {
        shouldVerify = _verify;
    }

    function requestProposal(uint256, bytes32) external override {}

    function submitProposal(uint256, string calldata, bytes calldata) external override {}

    function verifySignature(uint256, bytes32, bytes calldata) external view override returns (bool) {
        return shouldVerify;
    }

    function ilrmContract() external pure override returns (address) {
        return address(0);
    }

    function isOracle(address) external pure override returns (bool) {
        return true;
    }

    function oraclePublicKeyHash(address) external pure override returns (bytes32) {
        return bytes32(0);
    }
}
