// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {BLS12381} from "./BLS12381.sol";

/**
 * @title BLS12381Verifier
 * @notice Stateless contract exposing BLS12381.verify (RFC 9380 hash-to-G2 and the pairing check)
 * @dev ComplianceCouncil deploys one in its constructor and calls it instead of inlining the library's
 *      hash-to-curve and pairing code (about 2.4 KB), which would push the council past the EIP-170 size limit.
 *      Same semantics as BLS12381.verify: returns false (never reverts) for malformed points, an infinity
 *      public key or missing precompiles; reverts only for an empty or over-long DST.
 */
contract BLS12381Verifier {
    /// @notice BLS12381.verify(pk, sig, msg_, dst)
    function verify(bytes calldata pk, bytes calldata sig, bytes calldata msg_, bytes calldata dst)
        external
        view
        returns (bool)
    {
        return BLS12381.verify(pk, sig, msg_, dst);
    }
}
