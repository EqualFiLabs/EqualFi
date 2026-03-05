// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibClMath} from "src/libraries/LibClMath.sol";

contract LibClMathHarness {
    function getSqrtRatioAtTick(int24 tick) external pure returns (uint160) {
        return LibClMath.getSqrtRatioAtTick(tick);
    }

    function getTickAtSqrtRatio(uint160 sqrtPriceX96) external pure returns (int24) {
        return LibClMath.getTickAtSqrtRatio(sqrtPriceX96);
    }

    function computeSwapStep(
        uint160 sqrtRatioCurrentX96,
        uint160 sqrtRatioTargetX96,
        uint128 liquidity,
        int256 amountRemaining,
        uint24 feePips
    ) external pure returns (uint160 sqrtRatioNextX96, uint256 amountIn, uint256 amountOut, uint256 feeAmount) {
        return LibClMath.computeSwapStep(sqrtRatioCurrentX96, sqrtRatioTargetX96, liquidity, amountRemaining, feePips);
    }

    function getLiquidityForAmounts(
        uint160 sqrtRatioX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint256 amount0,
        uint256 amount1
    ) external pure returns (uint128 liquidity) {
        return LibClMath.getLiquidityForAmounts(sqrtRatioX96, sqrtRatioAX96, sqrtRatioBX96, amount0, amount1);
    }

    function getAmount0ForLiquidity(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity)
        external
        pure
        returns (uint256 amount0)
    {
        return LibClMath.getAmount0ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity);
    }

    function getAmount1ForLiquidity(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity)
        external
        pure
        returns (uint256 amount1)
    {
        return LibClMath.getAmount1ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity);
    }

    function minTick() external pure returns (int24) {
        return LibClMath.MIN_TICK;
    }

    function maxTick() external pure returns (int24) {
        return LibClMath.MAX_TICK;
    }

    function minSqrtRatio() external pure returns (uint160) {
        return LibClMath.MIN_SQRT_RATIO;
    }

    function maxSqrtRatio() external pure returns (uint160) {
        return LibClMath.MAX_SQRT_RATIO;
    }
}

contract LibClMathTest is Test {
    LibClMathHarness internal h;

    function setUp() public {
        h = new LibClMathHarness();
    }

    /// @notice Feature: cl-community-auction, Property 17: Tick-price round trip
    function testFuzz_tickPriceRoundTrip(int24 tickSeed) public {
        int24 tick = _boundTick(tickSeed);
        uint160 sqrtPriceX96 = h.getSqrtRatioAtTick(tick);
        int24 roundTripTick = h.getTickAtSqrtRatio(sqrtPriceX96);
        assertEq(roundTripTick, tick);
    }

    /// @notice Feature: cl-community-auction, Property 18: Liquidity-amount math consistency
    function testFuzz_liquidityAmountMathConsistency(
        int24 lowerSeed,
        int24 upperSeed,
        uint120 liquiditySeed
    ) public {
        (int24 tickLower, int24 tickUpper) = _validTickRange(lowerSeed, upperSeed);
        vm.assume(tickLower > LibClMath.MIN_TICK + 1_000);
        vm.assume(tickUpper < LibClMath.MAX_TICK - 1_000);
        vm.assume(tickUpper - tickLower >= 10);

        uint160 sqrtRatioAX96 = h.getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBX96 = h.getSqrtRatioAtTick(tickUpper);

        uint128 liquidity = uint128(bound(uint256(liquiditySeed), 1, type(uint80).max));
        uint256 amount0 = h.getAmount0ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity);
        uint256 amount1 = h.getAmount1ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity);

        int24 currentTick = tickLower + (tickUpper - tickLower) / 2;

        uint160 sqrtRatioX96 = h.getSqrtRatioAtTick(currentTick);
        uint128 recomputedLiquidity = h.getLiquidityForAmounts(sqrtRatioX96, sqrtRatioAX96, sqrtRatioBX96, amount0, amount1);

        assertGe(recomputedLiquidity, liquidity);
    }

    function test_minAndMaxTickMappings() public {
        assertEq(h.getSqrtRatioAtTick(h.minTick()), h.minSqrtRatio());
        assertEq(h.getSqrtRatioAtTick(h.maxTick()), h.maxSqrtRatio());
    }

    function test_getSqrtRatioAtTick_revertsOutsideBounds() public {
        int24 belowMinTick = h.minTick() - 1;
        int24 aboveMaxTick = h.maxTick() + 1;

        vm.expectRevert(abi.encodeWithSelector(LibClMath.LibClMath_InvalidTick.selector, belowMinTick));
        h.getSqrtRatioAtTick(belowMinTick);

        vm.expectRevert(abi.encodeWithSelector(LibClMath.LibClMath_InvalidTick.selector, aboveMaxTick));
        h.getSqrtRatioAtTick(aboveMaxTick);
    }

    function test_getTickAtSqrtRatio_boundaryValues() public {
        uint160 minSqrt = h.minSqrtRatio();
        uint160 maxSqrt = h.maxSqrtRatio();
        int24 minTick = h.minTick();
        int24 maxTick = h.maxTick();

        assertEq(h.getTickAtSqrtRatio(minSqrt), minTick);
        assertEq(h.getTickAtSqrtRatio(maxSqrt), maxTick);

        int24 highTick = h.getTickAtSqrtRatio(maxSqrt - 1);
        assertLe(highTick, maxTick);

        vm.expectRevert(abi.encodeWithSelector(LibClMath.LibClMath_InvalidSqrtPrice.selector, uint160(minSqrt - 1)));
        h.getTickAtSqrtRatio(minSqrt - 1);

        vm.expectRevert(abi.encodeWithSelector(LibClMath.LibClMath_InvalidSqrtPrice.selector, uint160(maxSqrt + 1)));
        h.getTickAtSqrtRatio(maxSqrt + 1);
    }

    function test_zeroLiquidityAndZeroAmounts() public {
        uint160 sqrtRatioAX96 = h.getSqrtRatioAtTick(-120);
        uint160 sqrtRatioBX96 = h.getSqrtRatioAtTick(120);
        uint160 sqrtRatioX96 = h.getSqrtRatioAtTick(0);

        assertEq(h.getAmount0ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, 0), 0);
        assertEq(h.getAmount1ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, 0), 0);
        assertEq(h.getLiquidityForAmounts(sqrtRatioX96, sqrtRatioAX96, sqrtRatioBX96, 0, 0), 0);
    }

    function test_maxUint128LiquidityAmounts() public {
        uint160 sqrtRatioAX96 = h.getSqrtRatioAtTick(-60);
        uint160 sqrtRatioBX96 = h.getSqrtRatioAtTick(60);

        uint256 amount0 = h.getAmount0ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, type(uint128).max);
        uint256 amount1 = h.getAmount1ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, type(uint128).max);

        assertGt(amount0, 0);
        assertGt(amount1, 0);
    }

    function test_computeSwapStep_zeroRemainingIsNoop() public {
        uint160 sqrtCurrent = h.getSqrtRatioAtTick(100);
        uint160 sqrtTarget = h.getSqrtRatioAtTick(90);

        (uint160 sqrtNext, uint256 amountIn, uint256 amountOut, uint256 feeAmount) =
            h.computeSwapStep(sqrtCurrent, sqrtTarget, 1e18, 0, 500);

        assertEq(sqrtNext, sqrtCurrent);
        assertEq(amountIn, 0);
        assertEq(amountOut, 0);
        assertEq(feeAmount, 0);
    }

    function test_computeSwapStep_exactInBoundaryAmount() public {
        uint160 sqrtCurrent = h.getSqrtRatioAtTick(200);
        uint160 sqrtTarget = h.getSqrtRatioAtTick(100);

        (, uint256 maxStepAmountIn,,) = h.computeSwapStep(sqrtCurrent, sqrtTarget, 2e18, type(int256).max, 0);
        assertGt(maxStepAmountIn, 0);

        (uint160 sqrtNext, uint256 amountIn, uint256 amountOut, uint256 feeAmount) =
            h.computeSwapStep(sqrtCurrent, sqrtTarget, 2e18, int256(maxStepAmountIn), 0);

        assertEq(sqrtNext, sqrtTarget);
        assertEq(amountIn, maxStepAmountIn);
        assertGt(amountOut, 0);
        assertEq(feeAmount, 0);
    }

    function test_computeSwapStep_exactOutBoundaryAmount() public {
        uint160 sqrtCurrent = h.getSqrtRatioAtTick(200);
        uint160 sqrtTarget = h.getSqrtRatioAtTick(100);

        (, , uint256 maxStepAmountOut,) = h.computeSwapStep(sqrtCurrent, sqrtTarget, 2e18, -type(int256).max, 0);
        assertGt(maxStepAmountOut, 0);

        (uint160 sqrtNext, uint256 amountIn, uint256 amountOut, uint256 feeAmount) =
            h.computeSwapStep(sqrtCurrent, sqrtTarget, 2e18, -int256(maxStepAmountOut), 0);

        assertEq(sqrtNext, sqrtTarget);
        assertGt(amountIn, 0);
        assertEq(amountOut, maxStepAmountOut);
        assertEq(feeAmount, 0);
    }

    function _boundTick(int24 tick) private pure returns (int24) {
        if (tick < LibClMath.MIN_TICK) return LibClMath.MIN_TICK;
        if (tick > LibClMath.MAX_TICK) return LibClMath.MAX_TICK;
        return tick;
    }

    function _validTickRange(int24 lowerSeed, int24 upperSeed) private pure returns (int24 tickLower, int24 tickUpper) {
        int24 a = _boundTick(lowerSeed);
        int24 b = _boundTick(upperSeed);

        if (a == b) {
            if (b < LibClMath.MAX_TICK) {
                b += 1;
            } else {
                a -= 1;
            }
        }

        if (a < b) {
            tickLower = a;
            tickUpper = b;
        } else {
            tickLower = b;
            tickUpper = a;
        }

        if (tickUpper - tickLower < 2) {
            if (tickUpper < LibClMath.MAX_TICK) {
                tickUpper += 1;
            } else {
                tickLower -= 1;
            }
        }
    }
}
