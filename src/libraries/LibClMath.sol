// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Uniswap v3-style concentrated-liquidity math helpers.
/// @dev Tick/price conversion and swap/liquidity arithmetic using Q64.96 and Q128 fixed-point conventions.
library LibClMath {
    uint8 internal constant RESOLUTION = 96;
    uint256 internal constant Q96 = 0x1000000000000000000000000;
    uint256 internal constant Q128 = 0x100000000000000000000000000000000;
    uint24 internal constant FEE_UNITS = 1_000_000;

    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = 887272;

    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    error LibClMath_InvalidTick(int24 tick);
    error LibClMath_InvalidSqrtPrice(uint160 sqrtPriceX96);
    error LibClMath_InvalidFeePips(uint24 feePips);
    error LibClMath_InvalidPriceOrLiquidity();
    error LibClMath_LiquidityOverflow(uint256 liquidity);

    function getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        uint256 absTick = tick < 0 ? uint256(uint24(-tick)) : uint256(uint24(tick));
        if (absTick > uint256(uint24(MAX_TICK))) revert LibClMath_InvalidTick(tick);

        uint256 ratio = absTick & 0x1 != 0 ? 0xfffcb933bd6fad37aa2d162d1a594001 : 0x100000000000000000000000000000000;
        if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
        if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
        if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
        if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
        if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
        if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
        if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
        if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
        if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
        if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
        if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
        if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
        if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
        if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
        if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
        if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
        if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
        if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
        if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;

        if (tick > 0) ratio = type(uint256).max / ratio;

        sqrtPriceX96 = uint160((ratio >> 32) + ((ratio & ((1 << 32) - 1)) == 0 ? 0 : 1));
    }

    function getTickAtSqrtRatio(uint160 sqrtPriceX96) internal pure returns (int24 tick) {
        if (sqrtPriceX96 < MIN_SQRT_RATIO || sqrtPriceX96 > MAX_SQRT_RATIO) {
            revert LibClMath_InvalidSqrtPrice(sqrtPriceX96);
        }
        if (sqrtPriceX96 == MAX_SQRT_RATIO) return MAX_TICK;

        uint256 ratio = uint256(sqrtPriceX96) << 32;
        uint256 r = ratio;
        uint256 msb;

        assembly {
            let f := shl(7, gt(r, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := shl(6, gt(r, 0xFFFFFFFFFFFFFFFF))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := shl(5, gt(r, 0xFFFFFFFF))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := shl(4, gt(r, 0xFFFF))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := shl(3, gt(r, 0xFF))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := shl(2, gt(r, 0xF))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := shl(1, gt(r, 0x3))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := gt(r, 0x1)
            msb := or(msb, f)
        }

        if (msb >= 128) r = ratio >> (msb - 127);
        else r = ratio << (127 - msb);

        int256 log_2 = (int256(msb) - 128) << 64;

        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(63, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(62, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(61, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(60, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(59, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(58, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(57, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(56, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(55, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(54, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(53, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(52, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(51, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(50, f))
        }

        int256 logSqrt10001 = log_2 * 255738958999603826347141;
        int24 tickLow = int24((logSqrt10001 - 3402992956809132418596140100660247210) >> 128);
        int24 tickHi = int24((logSqrt10001 + 291339464771989622907027621153398088495) >> 128);

        tick = tickLow == tickHi ? tickLow : (getSqrtRatioAtTick(tickHi) <= sqrtPriceX96 ? tickHi : tickLow);
    }

    function computeSwapStep(
        uint160 sqrtRatioCurrentX96,
        uint160 sqrtRatioTargetX96,
        uint128 liquidity,
        int256 amountRemaining,
        uint24 feePips
    ) internal pure returns (uint160 sqrtRatioNextX96, uint256 amountIn, uint256 amountOut, uint256 feeAmount) {
        if (feePips >= FEE_UNITS) revert LibClMath_InvalidFeePips(feePips);

        bool zeroForOne = sqrtRatioCurrentX96 >= sqrtRatioTargetX96;
        bool exactIn = amountRemaining >= 0;

        if (exactIn) {
            uint256 amountRemainingLessFee = Math.mulDiv(uint256(amountRemaining), FEE_UNITS - feePips, FEE_UNITS);
            amountIn = zeroForOne
                ? _getAmount0Delta(sqrtRatioTargetX96, sqrtRatioCurrentX96, liquidity, true)
                : _getAmount1Delta(sqrtRatioCurrentX96, sqrtRatioTargetX96, liquidity, true);

            if (amountRemainingLessFee >= amountIn) {
                sqrtRatioNextX96 = sqrtRatioTargetX96;
            } else {
                sqrtRatioNextX96 = _getNextSqrtPriceFromInput(sqrtRatioCurrentX96, liquidity, amountRemainingLessFee, zeroForOne);
            }
        } else {
            uint256 amountRemainingAbs = _absInt256(amountRemaining);
            amountOut = zeroForOne
                ? _getAmount1Delta(sqrtRatioTargetX96, sqrtRatioCurrentX96, liquidity, false)
                : _getAmount0Delta(sqrtRatioCurrentX96, sqrtRatioTargetX96, liquidity, false);

            if (amountRemainingAbs >= amountOut) {
                sqrtRatioNextX96 = sqrtRatioTargetX96;
            } else {
                sqrtRatioNextX96 =
                    _getNextSqrtPriceFromOutput(sqrtRatioCurrentX96, liquidity, amountRemainingAbs, zeroForOne);
            }
        }

        bool reachedTarget = sqrtRatioNextX96 == sqrtRatioTargetX96;

        if (zeroForOne) {
            if (!(reachedTarget && exactIn)) {
                amountIn = _getAmount0Delta(sqrtRatioNextX96, sqrtRatioCurrentX96, liquidity, true);
            }
            if (!(reachedTarget && !exactIn)) {
                amountOut = _getAmount1Delta(sqrtRatioNextX96, sqrtRatioCurrentX96, liquidity, false);
            }
        } else {
            if (!(reachedTarget && exactIn)) {
                amountIn = _getAmount1Delta(sqrtRatioCurrentX96, sqrtRatioNextX96, liquidity, true);
            }
            if (!(reachedTarget && !exactIn)) {
                amountOut = _getAmount0Delta(sqrtRatioCurrentX96, sqrtRatioNextX96, liquidity, false);
            }
        }

        if (!exactIn) {
            uint256 amountRemainingAbs = _absInt256(amountRemaining);
            if (amountOut > amountRemainingAbs) {
                amountOut = amountRemainingAbs;
            }
        }

        if (exactIn && !reachedTarget) {
            feeAmount = uint256(amountRemaining) - amountIn;
        } else {
            feeAmount = _mulDivRoundingUp(amountIn, feePips, FEE_UNITS - feePips);
        }
    }

    function getLiquidityForAmounts(
        uint160 sqrtRatioX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        if (sqrtRatioX96 <= sqrtRatioAX96) {
            liquidity = _getLiquidityForAmount0(sqrtRatioAX96, sqrtRatioBX96, amount0);
        } else if (sqrtRatioX96 < sqrtRatioBX96) {
            uint128 liquidity0 = _getLiquidityForAmount0(sqrtRatioX96, sqrtRatioBX96, amount0);
            uint128 liquidity1 = _getLiquidityForAmount1(sqrtRatioAX96, sqrtRatioX96, amount1);
            liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        } else {
            liquidity = _getLiquidityForAmount1(sqrtRatioAX96, sqrtRatioBX96, amount1);
        }
    }

    /// @notice Returns token0 needed for liquidity in [sqrtRatioAX96, sqrtRatioBX96], rounded up.
    function getAmount0ForLiquidity(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0)
    {
        return _getAmount0Delta(sqrtRatioAX96, sqrtRatioBX96, liquidity, true);
    }

    /// @notice Returns token1 needed for liquidity in [sqrtRatioAX96, sqrtRatioBX96], rounded up.
    function getAmount1ForLiquidity(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity)
        internal
        pure
        returns (uint256 amount1)
    {
        return _getAmount1Delta(sqrtRatioAX96, sqrtRatioBX96, liquidity, true);
    }

    function _getLiquidityForAmount0(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint256 amount0)
        private
        pure
        returns (uint128)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        uint256 intermediate = Math.mulDiv(sqrtRatioAX96, sqrtRatioBX96, Q96);
        return _toUint128(Math.mulDiv(amount0, intermediate, sqrtRatioBX96 - sqrtRatioAX96));
    }

    function _getLiquidityForAmount1(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint256 amount1)
        private
        pure
        returns (uint128)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        return _toUint128(Math.mulDiv(amount1, Q96, sqrtRatioBX96 - sqrtRatioAX96));
    }

    function _toUint128(uint256 x) private pure returns (uint128 y) {
        y = uint128(x);
        if (y != x) revert LibClMath_LiquidityOverflow(x);
    }

    function _absInt256(int256 x) private pure returns (uint256) {
        if (x >= 0) return uint256(x);
        if (x == type(int256).min) return 1 << 255;
        return uint256(-x);
    }

    function _getNextSqrtPriceFromInput(uint160 sqrtPX96, uint128 liquidity, uint256 amountIn, bool zeroForOne)
        private
        pure
        returns (uint160)
    {
        if (sqrtPX96 == 0 || liquidity == 0) revert LibClMath_InvalidPriceOrLiquidity();
        return zeroForOne
            ? _getNextSqrtPriceFromAmount0RoundingUp(sqrtPX96, liquidity, amountIn, true)
            : _getNextSqrtPriceFromAmount1RoundingDown(sqrtPX96, liquidity, amountIn, true);
    }

    function _getNextSqrtPriceFromOutput(uint160 sqrtPX96, uint128 liquidity, uint256 amountOut, bool zeroForOne)
        private
        pure
        returns (uint160)
    {
        if (sqrtPX96 == 0 || liquidity == 0) revert LibClMath_InvalidPriceOrLiquidity();
        return zeroForOne
            ? _getNextSqrtPriceFromAmount1RoundingDown(sqrtPX96, liquidity, amountOut, false)
            : _getNextSqrtPriceFromAmount0RoundingUp(sqrtPX96, liquidity, amountOut, false);
    }

    function _getNextSqrtPriceFromAmount0RoundingUp(uint160 sqrtPX96, uint128 liquidity, uint256 amount, bool add)
        private
        pure
        returns (uint160)
    {
        if (amount == 0) return sqrtPX96;

        uint256 numerator1 = uint256(liquidity) << RESOLUTION;

        if (add) {
            if (amount <= type(uint256).max / sqrtPX96) {
                uint256 productAdd = amount * sqrtPX96;
                uint256 denominatorAdd = numerator1 + productAdd;
                if (denominatorAdd >= numerator1) {
                    return uint160(_mulDivRoundingUp(numerator1, sqrtPX96, denominatorAdd));
                }
            }
            return uint160(_divRoundingUp(numerator1, (numerator1 / sqrtPX96) + amount));
        }

        if (amount > type(uint256).max / sqrtPX96) revert LibClMath_InvalidPriceOrLiquidity();
        uint256 product = amount * sqrtPX96;
        if (numerator1 <= product) revert LibClMath_InvalidPriceOrLiquidity();

        uint256 denominator = numerator1 - product;
        uint256 next = _mulDivRoundingUp(numerator1, sqrtPX96, denominator);
        if (next > type(uint160).max) revert LibClMath_InvalidPriceOrLiquidity();
        return uint160(next);
    }

    function _getNextSqrtPriceFromAmount1RoundingDown(uint160 sqrtPX96, uint128 liquidity, uint256 amount, bool add)
        private
        pure
        returns (uint160)
    {
        if (add) {
            uint256 quotientAdd = amount <= type(uint160).max
                ? (amount << RESOLUTION) / liquidity
                : Math.mulDiv(amount, Q96, liquidity);
            uint256 next = uint256(sqrtPX96) + quotientAdd;
            if (next > type(uint160).max) revert LibClMath_InvalidPriceOrLiquidity();
            return uint160(next);
        }

        uint256 quotient = amount <= type(uint160).max
            ? _divRoundingUp(amount << RESOLUTION, liquidity)
            : _mulDivRoundingUp(amount, Q96, liquidity);

        if (sqrtPX96 <= quotient) revert LibClMath_InvalidPriceOrLiquidity();
        return uint160(uint256(sqrtPX96) - quotient);
    }

    function _getAmount0Delta(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity, bool roundUp)
        private
        pure
        returns (uint256 amount0)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        if (sqrtRatioAX96 == 0) revert LibClMath_InvalidPriceOrLiquidity();

        uint256 numerator1 = uint256(liquidity) << RESOLUTION;
        uint256 numerator2 = sqrtRatioBX96 - sqrtRatioAX96;

        if (roundUp) {
            return _divRoundingUp(_mulDivRoundingUp(numerator1, numerator2, sqrtRatioBX96), sqrtRatioAX96);
        }
        return Math.mulDiv(numerator1, numerator2, sqrtRatioBX96) / sqrtRatioAX96;
    }

    function _getAmount1Delta(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity, bool roundUp)
        private
        pure
        returns (uint256 amount1)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        return roundUp
            ? _mulDivRoundingUp(liquidity, sqrtRatioBX96 - sqrtRatioAX96, Q96)
            : Math.mulDiv(liquidity, sqrtRatioBX96 - sqrtRatioAX96, Q96);
    }

    function _mulDivRoundingUp(uint256 a, uint256 b, uint256 denominator) private pure returns (uint256) {
        return Math.mulDiv(a, b, denominator, Math.Rounding.Ceil);
    }

    function _divRoundingUp(uint256 x, uint256 y) private pure returns (uint256) {
        return x / y + (x % y == 0 ? 0 : 1);
    }
}
