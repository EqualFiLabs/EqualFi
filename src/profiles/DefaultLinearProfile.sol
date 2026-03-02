// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ICurveProfile} from "../interfaces/ICurveProfile.sol";
import {LibMamMath} from "../libraries/LibMamMath.sol";

/// @notice Default linear MAM profile backed by LibMamMath linear pricing.
contract DefaultLinearProfile is ICurveProfile {
    function computePrice(
        uint256 startPrice,
        uint256 endPrice,
        uint256 startTime,
        uint256 duration,
        uint256 currentTime,
        bytes32 /* profileParams */
    ) external pure override returns (uint256 price) {
        return LibMamMath.computePrice(startPrice, endPrice, startTime, duration, currentTime);
    }
}
