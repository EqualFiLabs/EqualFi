// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IlmTypes} from "../../src/libraries/IlmTypes.sol";
import {LibIlmStorage} from "../../src/libraries/LibIlmStorage.sol";
import {LibIlmIndexing} from "../../src/libraries/LibIlmIndexing.sol";

contract LibIlmIndexingHarness {
    function toScaledSupply(uint256 amount, uint256 liquidityIndexRay) external pure returns (uint256) {
        return LibIlmIndexing.toScaledSupply(amount, liquidityIndexRay);
    }

    function toScaledWithdraw(uint256 amount, uint256 liquidityIndexRay) external pure returns (uint256) {
        return LibIlmIndexing.toScaledWithdraw(amount, liquidityIndexRay);
    }

    function toScaledDebt(uint256 amount, uint256 variableBorrowIndexRay) external pure returns (uint256) {
        return LibIlmIndexing.toScaledDebt(amount, variableBorrowIndexRay);
    }

    function toScaledRepay(uint256 amount, uint256 variableBorrowIndexRay) external pure returns (uint256) {
        return LibIlmIndexing.toScaledRepay(amount, variableBorrowIndexRay);
    }

    function fromScaledSupply(uint256 scaled, uint256 liquidityIndexRay) external pure returns (uint256) {
        return LibIlmIndexing.fromScaledSupply(scaled, liquidityIndexRay);
    }

    function fromScaledDebt(uint256 scaled, uint256 variableBorrowIndexRay) external pure returns (uint256) {
        return LibIlmIndexing.fromScaledDebt(scaled, variableBorrowIndexRay);
    }

    function setMarket(uint256 marketId, IlmTypes.IlmMarket calldata market) external {
        LibIlmStorage.s().markets[marketId] = market;
    }

    function getMarket(uint256 marketId) external view returns (IlmTypes.IlmMarket memory) {
        return LibIlmStorage.s().markets[marketId];
    }

    function setMarketProtocolFeeAssets(uint256 marketId, uint256 assets) external {
        LibIlmStorage.s().marketProtocolFeeAssets[marketId] = assets;
    }

    function getMarketProtocolFeeAssets(uint256 marketId) external view returns (uint256) {
        return LibIlmStorage.s().marketProtocolFeeAssets[marketId];
    }

    function accrueMarketState(uint256 marketId) external returns (uint256 protocolFeeAccrued) {
        return LibIlmIndexing.accrueMarketState(LibIlmStorage.s(), marketId);
    }
}

contract LibIlmIndexingPropertyTest is Test {
    uint256 internal constant MARKET_ID = 1;

    LibIlmIndexingHarness internal h;

    function setUp() public {
        h = new LibIlmIndexingHarness();
        vm.warp(100_000_000);
    }

    /// @dev Property 27: Rounding Directionality
    /// Validates: Requirements 12.1, 12.2, 12.3, 12.4, 12.5, 12.6
    function testFuzz_property27_roundingDirectionality(
        uint256 amountRaw,
        uint256 scaledRaw,
        uint256 liquidityIndexRaw,
        uint256 variableBorrowIndexRaw
    ) public {
        uint256 amount = bound(amountRaw, 0, 1e36);
        uint256 scaled = bound(scaledRaw, 0, 1e36);
        uint256 liquidityIndexRay = bound(liquidityIndexRaw, IlmTypes.RAY, 1e36);
        uint256 variableBorrowIndexRay = bound(variableBorrowIndexRaw, IlmTypes.RAY, 1e36);

        uint256 supplyFloorExpected = Math.mulDiv(amount, IlmTypes.RAY, liquidityIndexRay);
        uint256 withdrawCeilExpected = Math.mulDiv(amount, IlmTypes.RAY, liquidityIndexRay, Math.Rounding.Ceil);
        uint256 debtCeilExpected = Math.mulDiv(amount, IlmTypes.RAY, variableBorrowIndexRay, Math.Rounding.Ceil);
        uint256 repayFloorExpected = Math.mulDiv(amount, IlmTypes.RAY, variableBorrowIndexRay);
        uint256 fromSupplyFloorExpected = Math.mulDiv(scaled, liquidityIndexRay, IlmTypes.RAY);
        uint256 fromDebtCeilExpected = Math.mulDiv(scaled, variableBorrowIndexRay, IlmTypes.RAY, Math.Rounding.Ceil);

        uint256 supplyFloor = h.toScaledSupply(amount, liquidityIndexRay);
        uint256 withdrawCeil = h.toScaledWithdraw(amount, liquidityIndexRay);
        uint256 debtCeil = h.toScaledDebt(amount, variableBorrowIndexRay);
        uint256 repayFloor = h.toScaledRepay(amount, variableBorrowIndexRay);
        uint256 fromSupplyFloor = h.fromScaledSupply(scaled, liquidityIndexRay);
        uint256 fromDebtCeil = h.fromScaledDebt(scaled, variableBorrowIndexRay);

        assertEq(supplyFloor, supplyFloorExpected);
        assertEq(withdrawCeil, withdrawCeilExpected);
        assertEq(debtCeil, debtCeilExpected);
        assertEq(repayFloor, repayFloorExpected);
        assertEq(fromSupplyFloor, fromSupplyFloorExpected);
        assertEq(fromDebtCeil, fromDebtCeilExpected);

        assertGe(withdrawCeil, supplyFloor);
        assertGe(debtCeil, repayFloor);
        assertGe(fromDebtCeil, Math.mulDiv(scaled, variableBorrowIndexRay, IlmTypes.RAY));
        assertLe(fromSupplyFloor, Math.mulDiv(scaled, liquidityIndexRay, IlmTypes.RAY, Math.Rounding.Ceil));
    }

    /// @dev Property 14: Index Accrual Correctness
    /// Validates: Requirements 7.5, 7.6, 7.7, 10.1
    function testFuzz_property14_indexAccrualCorrectness(
        uint128 scaledVariableDebtTotalRaw,
        uint128 availableLiquidityRaw,
        uint128 liquidityIndexRaw,
        uint128 variableBorrowIndexRaw,
        uint16 reserveFactorBpsRaw,
        uint16 optimalUtilizationBpsRaw,
        uint128 baseVariableRateRaw,
        uint128 slope1Raw,
        uint128 slope2Raw,
        uint32 elapsedRaw,
        uint128 initialClaimRaw
    ) public {
        uint256 scaledVariableDebtTotal = bound(uint256(scaledVariableDebtTotalRaw), 0, 1e24);
        uint256 availableLiquidity = bound(uint256(availableLiquidityRaw), 0, 1e24);
        uint256 liquidityIndexRay = bound(uint256(liquidityIndexRaw), IlmTypes.RAY, 2e27);
        uint256 variableBorrowIndexRay = bound(uint256(variableBorrowIndexRaw), IlmTypes.RAY, 2e27);
        uint256 reserveFactorBps = bound(uint256(reserveFactorBpsRaw), 0, IlmTypes.BPS);
        uint256 optimalUtilizationBps = bound(uint256(optimalUtilizationBpsRaw), 1, IlmTypes.BPS - 1);
        uint256 baseVariableRate = bound(uint256(baseVariableRateRaw), 0, type(uint32).max);
        uint256 slope1 = bound(uint256(slope1Raw), 0, type(uint32).max);
        uint256 slope2 = bound(uint256(slope2Raw), 0, type(uint32).max);
        uint256 elapsed = bound(uint256(elapsedRaw), 1, 30 days);
        uint256 initialClaim = bound(uint256(initialClaimRaw), 0, 1e24);

        uint256 totalDebtBefore = Math.mulDiv(
            scaledVariableDebtTotal, variableBorrowIndexRay, IlmTypes.RAY, Math.Rounding.Ceil
        );

        uint256 utilizationRay;
        if (totalDebtBefore == 0) {
            utilizationRay = 0;
        } else {
            utilizationRay = Math.mulDiv(totalDebtBefore, IlmTypes.RAY, totalDebtBefore + availableLiquidity);
        }

        uint256 optimalUtilizationRay = Math.mulDiv(optimalUtilizationBps, IlmTypes.RAY, IlmTypes.BPS);
        uint256 variableBorrowRateRay = _expectedVariableBorrowRate(
            utilizationRay, optimalUtilizationRay, baseVariableRate, slope1, slope2
        );
        uint256 liquidityRateRay = _expectedLiquidityRate(variableBorrowRateRay, utilizationRay, reserveFactorBps);

        uint256 liquidityFactorRay = IlmTypes.RAY + Math.mulDiv(liquidityRateRay, elapsed, IlmTypes.SECONDS_PER_YEAR);
        uint256 variableBorrowFactorRay =
            IlmTypes.RAY + Math.mulDiv(variableBorrowRateRay, elapsed, IlmTypes.SECONDS_PER_YEAR);

        uint256 expectedLiquidityIndex = Math.mulDiv(liquidityIndexRay, liquidityFactorRay, IlmTypes.RAY);
        uint256 expectedVariableBorrowIndex =
            Math.mulDiv(variableBorrowIndexRay, variableBorrowFactorRay, IlmTypes.RAY);

        vm.assume(expectedLiquidityIndex <= type(uint128).max);
        vm.assume(expectedVariableBorrowIndex <= type(uint128).max);
        vm.assume(liquidityRateRay <= type(uint128).max);
        vm.assume(variableBorrowRateRay <= type(uint128).max);

        uint256 totalDebtAfter = Math.mulDiv(
            scaledVariableDebtTotal, expectedVariableBorrowIndex, IlmTypes.RAY, Math.Rounding.Ceil
        );
        uint256 debtIncrease = totalDebtAfter > totalDebtBefore ? totalDebtAfter - totalDebtBefore : 0;
        uint256 expectedProtocolFeeAccrued = Math.mulDiv(debtIncrease, reserveFactorBps, IlmTypes.BPS);

        IlmTypes.IlmMarket memory market = IlmTypes.IlmMarket({
            loanPoolId: 10,
            collateralPoolId: 20,
            ltvBps: 7000,
            liquidationThresholdBps: 8000,
            liquidationBonusBps: 500,
            liquidationProtocolFeeBps: 100,
            reserveFactorBps: uint16(reserveFactorBps),
            optimalUtilizationBps: uint16(optimalUtilizationBps),
            baseVariableRateRayPerYear: uint32(baseVariableRate),
            variableSlope1RayPerYear: uint32(slope1),
            variableSlope2RayPerYear: uint32(slope2),
            supplyCap: type(uint128).max,
            borrowCap: type(uint128).max,
            active: true,
            paused: false,
            frozen: false,
            liquidityIndexRay: uint128(liquidityIndexRay),
            variableBorrowIndexRay: uint128(variableBorrowIndexRay),
            currentLiquidityRateRay: 0,
            currentVariableBorrowRateRay: 0,
            lastUpdate: uint64(block.timestamp - elapsed),
            scaledSupplyTotal: 0,
            scaledVariableDebtTotal: scaledVariableDebtTotal,
            availableLiquidity: availableLiquidity,
            badDebt: 0
        });

        h.setMarket(MARKET_ID, market);
        h.setMarketProtocolFeeAssets(MARKET_ID, initialClaim);

        uint256 protocolFeeAccrued = h.accrueMarketState(MARKET_ID);

        IlmTypes.IlmMarket memory got = h.getMarket(MARKET_ID);
        assertEq(protocolFeeAccrued, expectedProtocolFeeAccrued);
        assertEq(got.liquidityIndexRay, expectedLiquidityIndex);
        assertEq(got.variableBorrowIndexRay, expectedVariableBorrowIndex);
        assertEq(got.currentLiquidityRateRay, liquidityRateRay);
        assertEq(got.currentVariableBorrowRateRay, variableBorrowRateRay);
        assertEq(got.lastUpdate, block.timestamp);
        assertGe(got.liquidityIndexRay, liquidityIndexRay);
        assertGe(got.variableBorrowIndexRay, variableBorrowIndexRay);

        assertEq(h.getMarketProtocolFeeAssets(MARKET_ID), initialClaim + expectedProtocolFeeAccrued);
    }

    function test_property14_zeroElapsed_isNoOp() public {
        IlmTypes.IlmMarket memory market = IlmTypes.IlmMarket({
            loanPoolId: 10,
            collateralPoolId: 20,
            ltvBps: 7000,
            liquidationThresholdBps: 8000,
            liquidationBonusBps: 500,
            liquidationProtocolFeeBps: 100,
            reserveFactorBps: 1000,
            optimalUtilizationBps: 8000,
            baseVariableRateRayPerYear: 1_000_000_000,
            variableSlope1RayPerYear: 2_000_000_000,
            variableSlope2RayPerYear: 3_000_000_000,
            supplyCap: type(uint128).max,
            borrowCap: type(uint128).max,
            active: true,
            paused: false,
            frozen: false,
            liquidityIndexRay: uint128(IlmTypes.RAY),
            variableBorrowIndexRay: uint128(IlmTypes.RAY),
            currentLiquidityRateRay: 0,
            currentVariableBorrowRateRay: 0,
            lastUpdate: uint64(block.timestamp),
            scaledSupplyTotal: 0,
            scaledVariableDebtTotal: 1e18,
            availableLiquidity: 1e18,
            badDebt: 0
        });

        h.setMarket(MARKET_ID, market);
        h.setMarketProtocolFeeAssets(MARKET_ID, 1234);

        uint256 protocolFeeAccrued = h.accrueMarketState(MARKET_ID);
        assertEq(protocolFeeAccrued, 0);

        IlmTypes.IlmMarket memory got = h.getMarket(MARKET_ID);
        assertEq(got.liquidityIndexRay, market.liquidityIndexRay);
        assertEq(got.variableBorrowIndexRay, market.variableBorrowIndexRay);
        assertEq(got.lastUpdate, market.lastUpdate);
        assertEq(h.getMarketProtocolFeeAssets(MARKET_ID), 1234);
    }

    function _expectedVariableBorrowRate(
        uint256 utilizationRay,
        uint256 optimalUtilizationRay,
        uint256 baseVariableRateRay,
        uint256 slope1Ray,
        uint256 slope2Ray
    ) internal pure returns (uint256) {
        if (utilizationRay == 0) {
            return baseVariableRateRay;
        }
        if (utilizationRay <= optimalUtilizationRay) {
            return baseVariableRateRay + Math.mulDiv(slope1Ray, utilizationRay, optimalUtilizationRay);
        }
        uint256 excess = utilizationRay - optimalUtilizationRay;
        uint256 excessDenominator = IlmTypes.RAY - optimalUtilizationRay;
        return baseVariableRateRay + slope1Ray + Math.mulDiv(slope2Ray, excess, excessDenominator);
    }

    function _expectedLiquidityRate(uint256 variableBorrowRateRay, uint256 utilizationRay, uint256 reserveFactorBps)
        internal
        pure
        returns (uint256)
    {
        uint256 reserveFactorRay = Math.mulDiv(reserveFactorBps, IlmTypes.RAY, IlmTypes.BPS);
        uint256 beforeReserve = Math.mulDiv(variableBorrowRateRay, utilizationRay, IlmTypes.RAY);
        return Math.mulDiv(beforeReserve, IlmTypes.RAY - reserveFactorRay, IlmTypes.RAY);
    }
}
