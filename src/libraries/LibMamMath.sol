// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MamTypes} from "./MamTypes.sol";

/// @notice Fixed point math for linear Dutch curve pricing.
/// @dev All math uses 1e18 scaling for price.
library LibMamMath {
    uint256 internal constant WAD = 1e18;

    /// @notice Compute linear Dutch price between start and end, based on timestamp.
    function computePrice(
        uint256 startPrice,
        uint256 endPrice,
        uint256 start,
        uint256 duration,
        uint256 t
    ) internal pure returns (uint256) {
        if (t <= start) return startPrice;
        uint256 end = start + duration;
        if (t >= end) return endPrice;
        uint256 elapsed = t - start;

        // Linear interpolation: start + (end - start) * elapsed / duration
        uint256 delta = (endPrice > startPrice) ? (endPrice - startPrice) : (startPrice - endPrice);
        uint256 adj = Math.mulDiv(delta, elapsed, duration);
        return (endPrice >= startPrice) ? (startPrice + adj) : (startPrice - adj);
    }

    /// @notice Compute required amountIn for a given base fill at current price.
    function amountInForFill(uint256 baseFill, uint256 price) internal pure returns (uint256) {
        return Math.mulDiv(baseFill, price, WAD);
    }

    /// @notice Compute amountOut for a given base fill at current price.
    function amountOutForFill(uint256 baseFill, uint256 price) internal pure returns (uint256) {
        return Math.mulDiv(baseFill, WAD, price);
    }

    /// @notice Fee computation in basis points.
    function computeFeeBps(uint256 amount, uint256 bps) internal pure returns (uint256) {
        return Math.mulDiv(amount, bps, 10_000);
    }

    /// @notice Compute price directly from a descriptor.
    function computePriceFromDescriptor(MamTypes.CurveDescriptor memory desc, uint256 t)
        internal
        pure
        returns (uint256)
    {
        return computePrice(desc.startPrice, desc.endPrice, desc.startTime, desc.duration, t);
    }
}
