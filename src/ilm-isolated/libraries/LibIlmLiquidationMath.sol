// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IlmIsolatedTypes} from "../types/IlmIsolatedTypes.sol";
import {LibIlmSharesMath} from "./LibIlmSharesMath.sol";

/// @notice Health checks and liquidation incentive computation for ILM isolated markets.
library LibIlmLiquidationMath {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant ORACLE_PRICE_SCALE = 1e36;
    uint256 internal constant LIQUIDATION_CURSOR = 3e17; // 0.3e18
    uint256 internal constant MAX_LIQUIDATION_INCENTIVE_FACTOR = 115e16; // 1.15e18

    /// @notice LLTV health check.
    function isHealthy(
        uint256 collateralAssets,
        uint256 borrowShares,
        uint256 totalBorrowAssets,
        uint256 totalBorrowShares,
        uint256 oraclePrice,
        uint256 lltv
    ) internal pure returns (bool) {
        uint256 borrowed = LibIlmSharesMath.toAssetsUp(borrowShares, totalBorrowAssets, totalBorrowShares);
        uint256 collateralValue = collateralAssets * oraclePrice / ORACLE_PRICE_SCALE;
        uint256 maxBorrow = collateralValue * lltv / WAD;
        return borrowShares == 0 || maxBorrow >= borrowed;
    }

    /// @notice Alias for renamed profile terminology.
    function isIsolatedHealthy(
        uint256 collateralAssets,
        uint256 borrowShares,
        uint256 totalBorrowAssets,
        uint256 totalBorrowShares,
        uint256 oraclePrice,
        uint256 lltv
    ) internal pure returns (bool) {
        return isHealthy(collateralAssets, borrowShares, totalBorrowAssets, totalBorrowShares, oraclePrice, lltv);
    }

    /// @notice Liquidation incentive factor.
    /// @dev min(MAX_LIF, WAD*WAD / (WAD*WAD - CURSOR*(WAD - lltv)))
    function computeLIF(uint256 lltv) internal pure returns (uint256 lif) {
        uint256 denom = WAD * WAD - LIQUIDATION_CURSOR * (WAD - lltv);
        uint256 uncapped = WAD * WAD / denom;
        return uncapped < MAX_LIQUIDATION_INCENTIVE_FACTOR ? uncapped : MAX_LIQUIDATION_INCENTIVE_FACTOR;
    }
}

