// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {MamTypes} from "./MamTypes.sol";

/// @notice Shared hashing helpers for commitment-based MAM curves.
library LibMamCurveHasher {
    /// @dev Domain separator ensures descriptor hashes cannot collide with other structs.
    bytes32 internal constant CURVE_DOMAIN_SEPARATOR = keccak256("MAM_CURVE_V1");

    /// @notice Compute the canonical commitment hash for a descriptor.
    function curveHash(MamTypes.CurveDescriptor memory desc) internal pure returns (bytes32) {
        return keccak256(abi.encode(CURVE_DOMAIN_SEPARATOR, desc));
    }

    /// @notice Convenience helper for computing the descriptor end timestamp.
    function curveEndTime(MamTypes.CurveDescriptor memory desc) internal pure returns (uint256) {
        return uint256(desc.startTime) + uint256(desc.duration);
    }
}
