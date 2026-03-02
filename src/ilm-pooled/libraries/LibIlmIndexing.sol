// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IlmTypes, IlmInvalidRiskParams} from "./IlmTypes.sol";
import {LibIlmStorage} from "./LibIlmStorage.sol";
import {LibIlmInterestRate} from "./LibIlmInterestRate.sol";

/// @notice Index accrual and scaled-balance conversions for ILM pooled behavior.
library LibIlmIndexing {
    /// @notice Convert amount to scaled supply shares (floor).
    function toScaledSupply(uint256 amount, uint256 liquidityIndexRay) internal pure returns (uint256) {
        if (liquidityIndexRay == 0) revert IlmInvalidRiskParams();
        return Math.mulDiv(amount, IlmTypes.RAY, liquidityIndexRay);
    }

    /// @notice Convert withdraw amount to scaled supply burn (ceil).
    function toScaledWithdraw(uint256 amount, uint256 liquidityIndexRay) internal pure returns (uint256) {
        if (liquidityIndexRay == 0) revert IlmInvalidRiskParams();
        return Math.mulDiv(amount, IlmTypes.RAY, liquidityIndexRay, Math.Rounding.Ceil);
    }

    /// @notice Convert amount to scaled debt shares (ceil).
    function toScaledDebt(uint256 amount, uint256 variableBorrowIndexRay) internal pure returns (uint256) {
        if (variableBorrowIndexRay == 0) revert IlmInvalidRiskParams();
        return Math.mulDiv(amount, IlmTypes.RAY, variableBorrowIndexRay, Math.Rounding.Ceil);
    }

    /// @notice Convert repay amount to scaled debt burn (floor).
    function toScaledRepay(uint256 amount, uint256 variableBorrowIndexRay) internal pure returns (uint256) {
        if (variableBorrowIndexRay == 0) revert IlmInvalidRiskParams();
        return Math.mulDiv(amount, IlmTypes.RAY, variableBorrowIndexRay);
    }

    /// @notice Convert scaled supply to actual amount (floor).
    function fromScaledSupply(uint256 scaled, uint256 liquidityIndexRay) internal pure returns (uint256) {
        if (liquidityIndexRay == 0) revert IlmInvalidRiskParams();
        return Math.mulDiv(scaled, liquidityIndexRay, IlmTypes.RAY);
    }

    /// @notice Convert scaled debt to actual amount (ceil).
    function fromScaledDebt(uint256 scaled, uint256 variableBorrowIndexRay) internal pure returns (uint256) {
        if (variableBorrowIndexRay == 0) revert IlmInvalidRiskParams();
        return Math.mulDiv(scaled, variableBorrowIndexRay, IlmTypes.RAY, Math.Rounding.Ceil);
    }

    /// @notice Accrue market indexes/rates and deferred protocol fee claim.
    /// @return protocolFeeAccrued Loan-asset amount added to deferred claim.
    function accrueMarketState(LibIlmStorage.IlmStorage storage ds, uint256 marketId)
        internal
        returns (uint256 protocolFeeAccrued)
    {
        IlmTypes.IlmMarket storage market = ds.markets[marketId];

        uint256 elapsed = block.timestamp - uint256(market.lastUpdate);
        if (elapsed == 0) {
            return 0;
        }

        uint256 liquidityIndexRay = market.liquidityIndexRay;
        uint256 variableBorrowIndexRay = market.variableBorrowIndexRay;
        if (liquidityIndexRay == 0 || variableBorrowIndexRay == 0) {
            revert IlmInvalidRiskParams();
        }

        uint256 totalDebtBefore = fromScaledDebt(market.scaledVariableDebtTotal, variableBorrowIndexRay);
        uint256 utilizationRay = _computeUtilizationRay(totalDebtBefore, market.availableLiquidity);

        uint256 optimalUtilizationRay = Math.mulDiv(market.optimalUtilizationBps, IlmTypes.RAY, IlmTypes.BPS);
        uint256 variableBorrowRateRay = LibIlmInterestRate.computeVariableBorrowRate(
            utilizationRay,
            optimalUtilizationRay,
            market.baseVariableRateRayPerYear,
            market.variableSlope1RayPerYear,
            market.variableSlope2RayPerYear
        );
        uint256 liquidityRateRay =
            LibIlmInterestRate.computeLiquidityRate(variableBorrowRateRay, utilizationRay, market.reserveFactorBps);

        uint256 liquidityFactorRay = IlmTypes.RAY + Math.mulDiv(liquidityRateRay, elapsed, IlmTypes.SECONDS_PER_YEAR);
        uint256 variableBorrowFactorRay =
            IlmTypes.RAY + Math.mulDiv(variableBorrowRateRay, elapsed, IlmTypes.SECONDS_PER_YEAR);

        uint256 newLiquidityIndexRay = Math.mulDiv(liquidityIndexRay, liquidityFactorRay, IlmTypes.RAY);
        uint256 newVariableBorrowIndexRay = Math.mulDiv(variableBorrowIndexRay, variableBorrowFactorRay, IlmTypes.RAY);

        uint256 totalDebtAfter = fromScaledDebt(market.scaledVariableDebtTotal, newVariableBorrowIndexRay);
        uint256 debtIncrease = totalDebtAfter > totalDebtBefore ? totalDebtAfter - totalDebtBefore : 0;
        protocolFeeAccrued = Math.mulDiv(debtIncrease, market.reserveFactorBps, IlmTypes.BPS);

        if (newLiquidityIndexRay > type(uint128).max || newVariableBorrowIndexRay > type(uint128).max) {
            revert IlmInvalidRiskParams();
        }
        if (liquidityRateRay > type(uint128).max || variableBorrowRateRay > type(uint128).max) {
            revert IlmInvalidRiskParams();
        }
        if (block.timestamp > type(uint64).max) {
            revert IlmInvalidRiskParams();
        }

        market.liquidityIndexRay = uint128(newLiquidityIndexRay);
        market.variableBorrowIndexRay = uint128(newVariableBorrowIndexRay);
        market.currentLiquidityRateRay = uint128(liquidityRateRay);
        market.currentVariableBorrowRateRay = uint128(variableBorrowRateRay);
        market.lastUpdate = uint64(block.timestamp);

        if (protocolFeeAccrued > 0) {
            ds.marketProtocolFeeAssets[marketId] += protocolFeeAccrued;
        }
    }

    function _computeUtilizationRay(uint256 totalDebt, uint256 availableLiquidity) private pure returns (uint256) {
        if (totalDebt == 0) {
            return 0;
        }
        return Math.mulDiv(totalDebt, IlmTypes.RAY, totalDebt + availableLiquidity);
    }
}
