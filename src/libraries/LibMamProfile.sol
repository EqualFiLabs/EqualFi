// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ICurveProfile} from "../interfaces/ICurveProfile.sol";
import {LibDerivativeStorage} from "./LibDerivativeStorage.sol";
import {LibMamMath} from "./LibMamMath.sol";
import "./MamCurveErrors.sol";

/// @notice Helpers for profile-id based MAM pricing and validation.
library LibMamProfile {
    uint16 internal constant BUILTIN_LINEAR_PROFILE_ID = 1;

    function enforceProfileApprovedForMutation(
        LibDerivativeStorage.DerivativeStorage storage ds,
        uint16 profileId
    ) internal view {
        if (profileId == 0) revert MamCurve_InvalidProfileId(profileId);
        if (profileId == BUILTIN_LINEAR_PROFILE_ID) return;

        LibDerivativeStorage.CurveProfileRegistryEntry storage entry = ds.curveProfiles[profileId];
        if (!entry.approved) revert MamCurve_ProfileNotApproved(profileId);
        if (entry.impl == address(0)) {
            revert MamCurve_InvalidProfileId(profileId);
        }
    }

    function computePrice(
        LibDerivativeStorage.DerivativeStorage storage ds,
        LibDerivativeStorage.CurvePricing storage pricing,
        uint16 profileId,
        bytes32 profileParams
    ) internal view returns (uint256 price) {
        if (profileId == BUILTIN_LINEAR_PROFILE_ID) {
            return LibMamMath.computePrice(
                pricing.startPrice,
                pricing.endPrice,
                pricing.startTime,
                pricing.duration,
                block.timestamp
            );
        }

        address impl = ds.curveProfiles[profileId].impl;
        if (impl == address(0)) revert MamCurve_InvalidProfileId(profileId);

        (bool success, bytes memory ret) = impl.staticcall(
            abi.encodeCall(
                ICurveProfile.computePrice,
                (
                    pricing.startPrice,
                    pricing.endPrice,
                    pricing.startTime,
                    pricing.duration,
                    block.timestamp,
                    profileParams
                )
            )
        );
        if (!success) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        price = abi.decode(ret, (uint256));
    }

    function tryComputePrice(
        LibDerivativeStorage.DerivativeStorage storage ds,
        LibDerivativeStorage.CurvePricing storage pricing,
        uint16 profileId,
        bytes32 profileParams
    ) internal view returns (bool success, uint256 price) {
        if (profileId == BUILTIN_LINEAR_PROFILE_ID) {
            return (
                true,
                LibMamMath.computePrice(
                    pricing.startPrice,
                    pricing.endPrice,
                    pricing.startTime,
                    pricing.duration,
                    block.timestamp
                )
            );
        }

        address impl = ds.curveProfiles[profileId].impl;
        if (impl == address(0)) return (false, 0);

        bytes memory ret;
        (success, ret) = impl.staticcall(
            abi.encodeCall(
                ICurveProfile.computePrice,
                (
                    pricing.startPrice,
                    pricing.endPrice,
                    pricing.startTime,
                    pricing.duration,
                    block.timestamp,
                    profileParams
                )
            )
        );
        if (!success || ret.length < 32) return (false, 0);
        price = abi.decode(ret, (uint256));
    }
}
