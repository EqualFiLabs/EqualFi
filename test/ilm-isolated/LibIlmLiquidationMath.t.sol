// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IlmIsolatedTypes} from "../../src/ilm-isolated/types/IlmIsolatedTypes.sol";
import {LibIlmSharesMath} from "../../src/ilm-isolated/libraries/LibIlmSharesMath.sol";
import {LibIlmLiquidationMath} from "../../src/ilm-isolated/libraries/LibIlmLiquidationMath.sol";

contract LibIlmLiquidationMathHarness {
    function isHealthy(
        uint256 collateralAssets,
        uint256 borrowShares,
        uint256 totalBorrowAssets,
        uint256 totalBorrowShares,
        uint256 oraclePrice,
        uint256 lltv
    ) external pure returns (bool) {
        return LibIlmLiquidationMath.isHealthy(
            collateralAssets, borrowShares, totalBorrowAssets, totalBorrowShares, oraclePrice, lltv
        );
    }

    function isIsolatedHealthy(
        uint256 collateralAssets,
        uint256 borrowShares,
        uint256 totalBorrowAssets,
        uint256 totalBorrowShares,
        uint256 oraclePrice,
        uint256 lltv
    ) external pure returns (bool) {
        return LibIlmLiquidationMath.isIsolatedHealthy(
            collateralAssets, borrowShares, totalBorrowAssets, totalBorrowShares, oraclePrice, lltv
        );
    }

    function computeLIF(uint256 lltv) external pure returns (uint256) {
        return LibIlmLiquidationMath.computeLIF(lltv);
    }
}

contract LibIlmLiquidationMathTest is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant ORACLE_PRICE_SCALE = 1e36;
    uint256 internal constant LIQUIDATION_CURSOR = 3e17;
    uint256 internal constant MAX_LIF = 115e16;

    LibIlmLiquidationMathHarness internal h;

    function setUp() public {
        h = new LibIlmLiquidationMathHarness();
    }

    /// @dev Property 11: Health Check Formula Correctness
    /// Validates: Requirements 9.1, 9.2, 9.3, 9.4, 9.5
    function testFuzz_property11_healthCheckFormulaCorrectness(
        uint128 collateralAssetsRaw,
        uint128 borrowSharesRaw,
        uint128 totalBorrowAssetsRaw,
        uint128 totalBorrowSharesRaw,
        uint128 oraclePriceRaw,
        uint128 lltvRaw
    ) public {
        uint256 collateralAssets = _clamp(uint256(collateralAssetsRaw), 0, 1e24);
        uint256 borrowShares = _clamp(uint256(borrowSharesRaw), 0, 1e24);
        uint256 totalBorrowAssets = _clamp(uint256(totalBorrowAssetsRaw), 0, 1e24);
        uint256 totalBorrowShares = _clamp(uint256(totalBorrowSharesRaw), 0, 1e24);
        uint256 oraclePrice = _clamp(uint256(oraclePriceRaw), 1, 1e36);
        uint256 lltv = _clamp(uint256(lltvRaw), 0, WAD - 1);

        uint256 borrowed = LibIlmSharesMath.toAssetsUp(borrowShares, totalBorrowAssets, totalBorrowShares);
        uint256 collateralValue = collateralAssets * oraclePrice / ORACLE_PRICE_SCALE;
        uint256 maxBorrow = collateralValue * lltv / WAD;
        bool expected = borrowShares == 0 || maxBorrow >= borrowed;

        bool gotHealthy = h.isHealthy(collateralAssets, borrowShares, totalBorrowAssets, totalBorrowShares, oraclePrice, lltv);
        bool gotAlias =
            h.isIsolatedHealthy(collateralAssets, borrowShares, totalBorrowAssets, totalBorrowShares, oraclePrice, lltv);

        assertEq(gotHealthy, expected);
        assertEq(gotAlias, expected);
    }

    /// @dev Property 13: LIF Formula Correctness
    /// Validates: Requirement 10.2
    function testFuzz_property13_lifFormulaCorrectness(uint128 lltvRaw, uint64 deltaRaw) public {
        uint256 lltv = _clamp(uint256(lltvRaw), 0, WAD - 1);

        uint256 denom = WAD * WAD - LIQUIDATION_CURSOR * (WAD - lltv);
        uint256 expected = _min(MAX_LIF, WAD * WAD / denom);
        uint256 lif = h.computeLIF(lltv);

        assertEq(lif, expected);
        assertLe(lif, MAX_LIF);

        // Formula-derived monotonicity (non-increasing with larger LLTV).
        uint256 delta = _clamp(uint256(deltaRaw), 0, (WAD - 1) - lltv);
        uint256 lltv2 = lltv + delta;
        uint256 lif2 = h.computeLIF(lltv2);
        assertLe(lif2, lif);
    }

    function _clamp(uint256 x, uint256 minValue, uint256 maxValue) internal pure returns (uint256) {
        if (minValue == maxValue) {
            return minValue;
        }
        return minValue + (x % (maxValue - minValue + 1));
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
