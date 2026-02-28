// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @notice Core types and constants for ILM isolated behavior.
library IlmIsolatedTypes {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant ORACLE_PRICE_SCALE = 1e36;
    uint256 internal constant LIQUIDATION_CURSOR = 3e17; // 0.3e18
    uint256 internal constant MAX_LIQUIDATION_INCENTIVE_FACTOR = 115e16; // 1.15e18
    uint256 internal constant MAX_FEE = 25e16; // 0.25e18
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;

    struct IlmIsolatedMarketParams {
        uint256 loanPoolId;
        uint256 collateralPoolId;
        address oracle;
        address irm;
        uint256 lltv; // WAD-scaled, < 1e18
    }

    struct IlmIsolatedMarket {
        uint128 totalSupplyAssets;
        uint128 totalSupplyShares;
        uint128 totalBorrowAssets;
        uint128 totalBorrowShares;
        uint128 lastUpdate;
        uint128 fee; // WAD-scaled, <= MAX_FEE
    }

    struct IlmIsolatedPosition {
        uint256 supplyShares;
        uint128 borrowShares;
        uint128 collateralAssets;
    }
}

