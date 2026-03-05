// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LibClMath} from "./LibClMath.sol";
import {LibClTickBitmap} from "./LibClTickBitmap.sol";
import {LibClAuctionStorage} from "./LibClAuctionStorage.sol";
import {ClAuction_LiquidityUnderflow} from "./ClAuctionErrors.sol";

/// @notice Stepwise concentrated-liquidity swap executor.
library LibClSwap {
    uint256 internal constant Q128 = 0x100000000000000000000000000000000;
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant PROTOCOL_FEE_BPS = 1_000; // 10% of swap-step fee

    error LibClSwap_InvalidAmountSpecified();
    error LibClSwap_InvalidSqrtPriceLimit(uint160 sqrtPriceLimitX96);
    error LibClSwap_ProtocolFeeOverflow(uint256 protocolFeeAmount);

    struct SwapState {
        int256 amountSpecifiedRemaining;
        int256 amountCalculated;
        uint160 sqrtPriceX96;
        int24 tick;
        uint256 feeGrowthGlobalX128;
        uint128 protocolFee;
        uint128 liquidity;
    }

    struct StepComputations {
        uint160 sqrtPriceStartX96;
        int24 tickNext;
        bool initialized;
        uint160 sqrtPriceNextX96;
        uint256 amountIn;
        uint256 amountOut;
        uint256 feeAmount;
    }

    function executeSwap(uint256 auctionId, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96)
        internal
        returns (int256 amount0, int256 amount1)
    {
        if (amountSpecified == 0) revert LibClSwap_InvalidAmountSpecified();

        LibClAuctionStorage.ClStorage storage cs = LibClAuctionStorage.s();
        LibClAuctionStorage.ClCommunityAuction storage auction = cs.auctions[auctionId];

        _validateSqrtPriceLimit(zeroForOne, auction.sqrtPriceX96, sqrtPriceLimitX96);

        bool exactInput = amountSpecified > 0;

        SwapState memory state = SwapState({
            amountSpecifiedRemaining: amountSpecified,
            amountCalculated: 0,
            sqrtPriceX96: auction.sqrtPriceX96,
            tick: auction.tick,
            feeGrowthGlobalX128: zeroForOne ? auction.feeGrowthGlobal0X128 : auction.feeGrowthGlobal1X128,
            protocolFee: 0,
            liquidity: auction.liquidity
        });

        while (state.amountSpecifiedRemaining != 0 && state.sqrtPriceX96 != sqrtPriceLimitX96) {
            StepComputations memory step;
            step.sqrtPriceStartX96 = state.sqrtPriceX96;

            (step.tickNext, step.initialized) =
                LibClTickBitmap.nextInitializedTickWithinOneWord(auctionId, state.tick, int24(auction.tickSpacing), zeroForOne);

            if (step.tickNext < LibClMath.MIN_TICK) {
                step.tickNext = LibClMath.MIN_TICK;
            } else if (step.tickNext > LibClMath.MAX_TICK) {
                step.tickNext = LibClMath.MAX_TICK;
            }

            step.sqrtPriceNextX96 = LibClMath.getSqrtRatioAtTick(step.tickNext);

            uint160 swapTarget = zeroForOne
                ? (step.sqrtPriceNextX96 < sqrtPriceLimitX96 ? sqrtPriceLimitX96 : step.sqrtPriceNextX96)
                : (step.sqrtPriceNextX96 > sqrtPriceLimitX96 ? sqrtPriceLimitX96 : step.sqrtPriceNextX96);

            (state.sqrtPriceX96, step.amountIn, step.amountOut, step.feeAmount) = LibClMath.computeSwapStep(
                state.sqrtPriceX96,
                swapTarget,
                state.liquidity,
                state.amountSpecifiedRemaining,
                auction.swapFee
            );

            if (exactInput) {
                state.amountSpecifiedRemaining -= _toInt256(step.amountIn + step.feeAmount);
                state.amountCalculated -= _toInt256(step.amountOut);
            } else {
                state.amountSpecifiedRemaining += _toInt256(step.amountOut);
                state.amountCalculated += _toInt256(step.amountIn + step.feeAmount);
            }

            uint256 protocolFeeDelta = (step.feeAmount * PROTOCOL_FEE_BPS) / BPS_DENOMINATOR;
            uint256 lpFee = step.feeAmount - protocolFeeDelta;

            if (protocolFeeDelta > 0) {
                uint256 protocolSum = uint256(state.protocolFee) + protocolFeeDelta;
                if (protocolSum > type(uint128).max) revert LibClSwap_ProtocolFeeOverflow(protocolSum);
                state.protocolFee = uint128(protocolSum);
            }

            if (state.liquidity > 0 && lpFee > 0) {
                state.feeGrowthGlobalX128 += Math.mulDiv(lpFee, Q128, state.liquidity);
            }

            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                if (step.initialized) {
                    LibClAuctionStorage.TickInfo storage tickInfo = cs.ticks[auctionId][step.tickNext];

                    uint256 feeGrowthGlobal0X128 = zeroForOne ? state.feeGrowthGlobalX128 : auction.feeGrowthGlobal0X128;
                    uint256 feeGrowthGlobal1X128 = zeroForOne ? auction.feeGrowthGlobal1X128 : state.feeGrowthGlobalX128;

                    tickInfo.feeGrowthOutside0X128 = feeGrowthGlobal0X128 - tickInfo.feeGrowthOutside0X128;
                    tickInfo.feeGrowthOutside1X128 = feeGrowthGlobal1X128 - tickInfo.feeGrowthOutside1X128;

                    int128 liquidityNet = tickInfo.liquidityNet;
                    if (zeroForOne) {
                        liquidityNet = -liquidityNet;
                    }

                    state.liquidity = _addLiquidityDelta(state.liquidity, liquidityNet);
                }

                state.tick = zeroForOne ? step.tickNext - 1 : step.tickNext;
            } else if (state.sqrtPriceX96 != step.sqrtPriceStartX96) {
                state.tick = LibClMath.getTickAtSqrtRatio(state.sqrtPriceX96);
            }
        }

        auction.sqrtPriceX96 = state.sqrtPriceX96;
        auction.tick = state.tick;
        auction.liquidity = state.liquidity;

        if (zeroForOne) {
            auction.feeGrowthGlobal0X128 = state.feeGrowthGlobalX128;
            if (state.protocolFee > 0) {
                auction.protocolFees0 = _addProtocolFee(auction.protocolFees0, state.protocolFee);
            }
        } else {
            auction.feeGrowthGlobal1X128 = state.feeGrowthGlobalX128;
            if (state.protocolFee > 0) {
                auction.protocolFees1 = _addProtocolFee(auction.protocolFees1, state.protocolFee);
            }
        }

        (amount0, amount1) = zeroForOne == exactInput
            ? (amountSpecified - state.amountSpecifiedRemaining, state.amountCalculated)
            : (state.amountCalculated, amountSpecified - state.amountSpecifiedRemaining);
    }

    function _validateSqrtPriceLimit(bool zeroForOne, uint160 sqrtPriceCurrentX96, uint160 sqrtPriceLimitX96)
        private
        pure
    {
        if (zeroForOne) {
            if (
                sqrtPriceLimitX96 >= sqrtPriceCurrentX96 || sqrtPriceLimitX96 < LibClMath.MIN_SQRT_RATIO
                    || sqrtPriceLimitX96 > LibClMath.MAX_SQRT_RATIO
            ) {
                revert LibClSwap_InvalidSqrtPriceLimit(sqrtPriceLimitX96);
            }
        } else {
            if (
                sqrtPriceLimitX96 <= sqrtPriceCurrentX96 || sqrtPriceLimitX96 < LibClMath.MIN_SQRT_RATIO
                    || sqrtPriceLimitX96 > LibClMath.MAX_SQRT_RATIO
            ) {
                revert LibClSwap_InvalidSqrtPriceLimit(sqrtPriceLimitX96);
            }
        }
    }

    function _toInt256(uint256 x) private pure returns (int256 y) {
        if (x > uint256(type(int256).max)) revert LibClSwap_InvalidAmountSpecified();
        y = int256(x);
    }

    function _addProtocolFee(uint128 current, uint128 delta) private pure returns (uint128) {
        uint256 sum = uint256(current) + uint256(delta);
        if (sum > type(uint128).max) revert LibClSwap_ProtocolFeeOverflow(sum);
        return uint128(sum);
    }

    function _addLiquidityDelta(uint128 liquidity, int128 liquidityDelta) private pure returns (uint128) {
        if (liquidityDelta < 0) {
            uint128 deltaAbs = uint128(uint128(-liquidityDelta));
            if (deltaAbs > liquidity) {
                revert ClAuction_LiquidityUnderflow(deltaAbs, liquidity);
            }
            unchecked {
                return liquidity - deltaAbs;
            }
        }

        uint128 delta = uint128(uint128(liquidityDelta));
        return liquidity + delta;
    }
}
