// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PositionNFT} from "../../nft/PositionNFT.sol";
import {LibPositionNFT} from "../../libraries/LibPositionNFT.sol";
import {IlmTypes, IlmMarketNotFound, IlmInvalidRiskParams} from "../libraries/IlmTypes.sol";
import {LibIlmStorage} from "../libraries/LibIlmStorage.sol";
import {LibIlmIndexing} from "../libraries/LibIlmIndexing.sol";
import {LibIlmInterestRate} from "../libraries/LibIlmInterestRate.sol";
import {LibModuleEncumbrance} from "../../libraries/LibModuleEncumbrance.sol";
import {IIlmOracleAdapter} from "../interfaces/IIlmOracleAdapter.sol";
import {IILMPooledViewFacet} from "../interfaces/IILMPooledViewFacet.sol";

/// @notice Read-only helpers for ILM pooled behavior markets.
contract ILMPooledViewFacet is IILMPooledViewFacet {
    function getPooledMarket(uint256 marketId) external view returns (IlmTypes.IlmMarket memory market) {
        market = LibIlmStorage.s().markets[marketId];
        if (market.lastUpdate == 0) {
            revert IlmMarketNotFound(marketId);
        }
    }

    function getPooledPosition(uint256 marketId, uint256 positionId)
        external
        view
        returns (IlmTypes.IlmPosition memory position)
    {
        _requireMarket(marketId);
        bytes32 positionKey = _positionKey(positionId);
        position = LibIlmStorage.s().positions[marketId][positionKey];
    }

    function previewHealthFactor(uint256 marketId, uint256 positionId) external view returns (uint256 hf) {
        LibIlmStorage.IlmStorage storage ds = LibIlmStorage.s();
        IlmTypes.IlmMarket storage market = _requireMarket(marketId, ds);
        bytes32 positionKey = _positionKey(positionId);
        IlmTypes.IlmPosition storage position = ds.positions[marketId][positionKey];

        (uint256 liquidityIndexRay, uint256 variableBorrowIndexRay) = _previewIndexes(market);
        uint256 debtValue = LibIlmIndexing.fromScaledDebt(position.scaledDebt, variableBorrowIndexRay);
        if (debtValue == 0) {
            return type(uint256).max;
        }

        uint256 supplyCollateralValue = 0;
        if (position.useAsCollateral && position.scaledSupply > 0) {
            supplyCollateralValue = LibIlmIndexing.fromScaledSupply(position.scaledSupply, liquidityIndexRay);
        }

        uint256 externalCollateralValue = 0;
        uint256 moduleId = ds.marketModuleId[marketId];
        uint256 externalCollateralAmount =
            LibModuleEncumbrance.getEncumberedForModule(positionKey, market.collateralPoolId, moduleId);
        if (externalCollateralAmount > 0) {
            uint256 priceRay = _getPrice(market.loanPoolId, market.collateralPoolId);
            externalCollateralValue = Math.mulDiv(externalCollateralAmount, priceRay, IlmTypes.RAY);
        }

        uint256 adjustedCollateral = Math.mulDiv(
            supplyCollateralValue + externalCollateralValue, market.liquidationThresholdBps, IlmTypes.BPS
        );
        hf = Math.mulDiv(adjustedCollateral, IlmTypes.HF_PRECISION, debtValue);
    }

    function previewSupplyBalance(uint256 marketId, uint256 positionId) external view returns (uint256 balance) {
        LibIlmStorage.IlmStorage storage ds = LibIlmStorage.s();
        IlmTypes.IlmMarket storage market = _requireMarket(marketId, ds);
        bytes32 positionKey = _positionKey(positionId);
        (uint256 liquidityIndexRay,) = _previewIndexes(market);
        balance = LibIlmIndexing.fromScaledSupply(ds.positions[marketId][positionKey].scaledSupply, liquidityIndexRay);
    }

    function previewDebtBalance(uint256 marketId, uint256 positionId) external view returns (uint256 debt) {
        LibIlmStorage.IlmStorage storage ds = LibIlmStorage.s();
        IlmTypes.IlmMarket storage market = _requireMarket(marketId, ds);
        bytes32 positionKey = _positionKey(positionId);
        (, uint256 variableBorrowIndexRay) = _previewIndexes(market);
        debt = LibIlmIndexing.fromScaledDebt(ds.positions[marketId][positionKey].scaledDebt, variableBorrowIndexRay);
    }

    function getPooledMarketProtocolFeeAssets(uint256 marketId) external view returns (uint256 feeAssets) {
        _requireMarket(marketId);
        feeAssets = LibIlmStorage.s().marketProtocolFeeAssets[marketId];
    }

    function _previewIndexes(IlmTypes.IlmMarket storage market)
        internal
        view
        returns (uint256 liquidityIndexRay, uint256 variableBorrowIndexRay)
    {
        liquidityIndexRay = market.liquidityIndexRay;
        variableBorrowIndexRay = market.variableBorrowIndexRay;
        if (liquidityIndexRay == 0 || variableBorrowIndexRay == 0) {
            revert IlmInvalidRiskParams();
        }

        uint256 elapsed = block.timestamp - uint256(market.lastUpdate);
        if (elapsed == 0) {
            return (liquidityIndexRay, variableBorrowIndexRay);
        }

        uint256 totalDebtBefore = LibIlmIndexing.fromScaledDebt(market.scaledVariableDebtTotal, variableBorrowIndexRay);
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

        liquidityIndexRay = Math.mulDiv(liquidityIndexRay, liquidityFactorRay, IlmTypes.RAY);
        variableBorrowIndexRay = Math.mulDiv(variableBorrowIndexRay, variableBorrowFactorRay, IlmTypes.RAY);
    }

    function _computeUtilizationRay(uint256 totalDebt, uint256 availableLiquidity) internal pure returns (uint256) {
        if (totalDebt == 0) {
            return 0;
        }
        return Math.mulDiv(totalDebt, IlmTypes.RAY, totalDebt + availableLiquidity);
    }

    function _getPrice(uint256 loanPoolId, uint256 collateralPoolId) internal view returns (uint256 priceRay) {
        address oracleAdapter = LibIlmStorage.s().oracleAdapter;
        if (oracleAdapter == address(0)) {
            revert IlmInvalidRiskParams();
        }
        priceRay = IIlmOracleAdapter(oracleAdapter).getPrice(loanPoolId, collateralPoolId);
        if (priceRay == 0) {
            revert IlmInvalidRiskParams();
        }
    }

    function _positionKey(uint256 positionId) internal view returns (bytes32 key) {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        if (!ns.nftModeEnabled || ns.positionNFTContract == address(0)) {
            revert IlmInvalidRiskParams();
        }
        key = PositionNFT(ns.positionNFTContract).getPositionKey(positionId);
    }

    function _requireMarket(uint256 marketId) internal view {
        if (LibIlmStorage.s().markets[marketId].lastUpdate == 0) {
            revert IlmMarketNotFound(marketId);
        }
    }

    function _requireMarket(uint256 marketId, LibIlmStorage.IlmStorage storage ds)
        internal
        view
        returns (IlmTypes.IlmMarket storage market)
    {
        market = ds.markets[marketId];
        if (market.lastUpdate == 0) {
            revert IlmMarketNotFound(marketId);
        }
    }
}
