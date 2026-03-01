// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IlmTypes} from "./IlmTypes.sol";

/// @notice Health-factor and liquidation math for ILM pooled behavior.
library LibIlmLiquidation {
    /// @notice Compute health factor. Returns max uint256 when debt is zero.
    function computeHealthFactor(
        uint256 collateralAmount,
        uint256 oraclePriceRay,
        uint16 liquidationThresholdBps,
        uint256 debtValue
    ) internal pure returns (uint256 hf) {
        if (debtValue == 0) {
            return type(uint256).max;
        }

        uint256 collateralValue = Math.mulDiv(collateralAmount, oraclePriceRay, IlmTypes.RAY);
        uint256 thresholdValue = Math.mulDiv(collateralValue, liquidationThresholdBps, IlmTypes.BPS);
        return Math.mulDiv(thresholdValue, IlmTypes.HF_PRECISION, debtValue);
    }

    /// @notice Determine close factor based on health factor severity.
    function determineCloseFactor(uint256 hf) internal pure returns (uint16 closeFactorBps) {
        if (hf < IlmTypes.CLOSE_FACTOR_HF_THRESHOLD) {
            return uint16(IlmTypes.BPS);
        }
        return IlmTypes.DEFAULT_CLOSE_FACTOR_BPS;
    }

    /// @notice Compute gross seized collateral, protocol fee, and net seized collateral.
    function computeLiquidationAmounts(
        uint256 actualDebtToLiquidate,
        uint256 oraclePriceRay,
        uint16 liquidationBonusBps,
        uint16 liquidationProtocolFeeBps
    ) internal pure returns (uint256 grossSeized, uint256 protocolFeeCollateral, uint256 netSeized) {
        uint256 seizedValueInLoanAsset = Math.mulDiv(
            actualDebtToLiquidate,
            IlmTypes.BPS + uint256(liquidationBonusBps),
            IlmTypes.BPS
        );
        grossSeized = Math.mulDiv(seizedValueInLoanAsset, IlmTypes.RAY, oraclePriceRay);

        uint256 feeBps = liquidationProtocolFeeBps > IlmTypes.BPS
            ? IlmTypes.BPS
            : uint256(liquidationProtocolFeeBps);
        protocolFeeCollateral = Math.mulDiv(grossSeized, feeBps, IlmTypes.BPS);
        netSeized = grossSeized - protocolFeeCollateral;
    }
}
