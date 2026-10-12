// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {BLS12381} from "../modules/libraries/BLS12381.sol";

/**
 * @title BLS12381ThresholdHarness
 * @notice Test-only wrapper exposing the BLS12381 G2 checks, G2MSM and the Lagrange interpolation
 */
contract BLS12381ThresholdHarness {
    function isCanonicalG2(bytes calldata pt) external pure returns (bool) {
        return BLS12381.isCanonicalG2(pt);
    }

    function g2Msm(bytes calldata pairs) external view returns (bool ok, bytes memory sum) {
        return BLS12381.g2Msm(pairs);
    }

    function interpolateG2AtZero(bytes calldata pairs, uint256[] calldata xs)
        external
        view
        returns (bool ok, bytes memory sum)
    {
        return BLS12381.interpolateG2AtZero(pairs, xs);
    }

    /// @dev The scalars interpolateG2AtZero writes into `pairs` (read back from its in-place update)
    function lagrangeScalars(bytes calldata pairs, uint256[] calldata xs)
        external
        view
        returns (bool ok, uint256[] memory scalars)
    {
        bytes memory buf = pairs;
        (ok,) = BLS12381.interpolateG2AtZero(buf, xs);
        scalars = new uint256[](xs.length);
        for (uint256 i = 0; i < xs.length && buf.length == xs.length * 288; i++) {
            uint256 s;
            assembly ("memory-safe") {
                s := mload(add(buf, add(mul(i, 288), 288)))
            }
            scalars[i] = s;
        }
    }
}
