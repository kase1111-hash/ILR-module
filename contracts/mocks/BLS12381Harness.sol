// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {BLS12381} from "../modules/libraries/BLS12381.sol";

/**
 * @title BLS12381Harness
 * @notice Test-only wrapper exposing the internal BLS12381 library functions
 */
contract BLS12381Harness {
    function precompilesAvailable() external view returns (bool) {
        return BLS12381.precompilesAvailable();
    }

    function isCanonicalG1(bytes calldata pt) external pure returns (bool) {
        return BLS12381.isCanonicalG1(pt);
    }

    function isValidG1(bytes calldata pt) external view returns (bool) {
        return BLS12381.isValidG1(pt);
    }

    function verify(bytes calldata pk, bytes calldata sig, bytes calldata msg_, bytes calldata dst)
        external
        view
        returns (bool)
    {
        return BLS12381.verify(pk, sig, msg_, dst);
    }

    function hashToG2(bytes calldata msg_, bytes calldata dst) external view returns (bool ok, bytes memory point) {
        return BLS12381.hashToG2(msg_, dst);
    }

    function expandMessageXmd(bytes calldata msg_, bytes calldata dst) external pure returns (bytes32[8] memory) {
        return BLS12381.expandMessageXmd(msg_, dst);
    }

    function g2Add(bytes calldata a, bytes calldata b) external view returns (bool ok, bytes memory sum) {
        return BLS12381.g2Add(a, b);
    }
}
