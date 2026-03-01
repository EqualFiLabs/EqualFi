// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IlmTypes} from "./IlmTypes.sol";

/// @notice Kinked-rate helpers for ILM pooled behavior.
library LibIlmInterestRate {
    /// @notice Compute variable borrow rate from kinked model.
    /// @dev All rates/utilization are ray-scaled per-year values.
    function computeVariableBorrowRate(
        uint256 utilizationRay,
        uint256 optimalUtilizationRay,
        uint256 baseVariableRateRay,
        uint256 slope1Ray,
        uint256 slope2Ray
    ) internal pure returns (uint256 rateRay) {
        uint256 u = utilizationRay > IlmTypes.RAY ? IlmTypes.RAY : utilizationRay;

        if (u == 0) {
            return baseVariableRateRay;
        }

        if (optimalUtilizationRay == 0) {
            return baseVariableRateRay + slope1Ray + slope2Ray;
        }

        if (u <= optimalUtilizationRay) {
            return baseVariableRateRay + Math.mulDiv(slope1Ray, u, optimalUtilizationRay);
        }

        uint256 denom = IlmTypes.RAY - optimalUtilizationRay;
        if (denom == 0) {
            return baseVariableRateRay + slope1Ray + slope2Ray;
        }

        uint256 excess = u - optimalUtilizationRay;
        return baseVariableRateRay + slope1Ray + Math.mulDiv(slope2Ray, excess, denom);
    }

    /// @notice Compute supplier liquidity rate from borrow rate and utilization.
    /// @dev Formula: borrowRate * U / RAY * (1 - reserveFactorBps / 10000).
    function computeLiquidityRate(uint256 variableBorrowRateRay, uint256 utilizationRay, uint256 reserveFactorBps)
        internal
        pure
        returns (uint256 rateRay)
    {
        uint256 u = utilizationRay > IlmTypes.RAY ? IlmTypes.RAY : utilizationRay;
        uint256 rfBps = reserveFactorBps > IlmTypes.BPS ? IlmTypes.BPS : reserveFactorBps;

        uint256 reserveFactorRay = Math.mulDiv(rfBps, IlmTypes.RAY, IlmTypes.BPS);
        uint256 beforeReserve = Math.mulDiv(variableBorrowRateRay, u, IlmTypes.RAY);
        return Math.mulDiv(beforeReserve, IlmTypes.RAY - reserveFactorRay, IlmTypes.RAY);
    }
}
