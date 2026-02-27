// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {DerivativeTypes} from "./DerivativeTypes.sol";

/// @notice Shared swap math and fee splitting helpers for auction facets.
library LibAuctionSwap {
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant MAX_STABLE_ITERATIONS = 255;

    error LibAuctionSwap_InvalidStableInput();
    error LibAuctionSwap_StableNonConvergence();
    error LibAuctionSwap_UnsupportedDecimals(uint8 decimals);

    function computeSwap(
        DerivativeTypes.FeeAsset feeAsset,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 amountIn,
        uint16 feeBps
    ) internal pure returns (uint256 rawOut, uint256 feeAmount, uint256 outToRecipient) {
        if (reserveIn == 0 || reserveOut == 0) {
            return (0, 0, 0);
        }
        if (feeAsset == DerivativeTypes.FeeAsset.TokenOut) {
            rawOut = Math.mulDiv(reserveOut, amountIn, reserveIn + amountIn);
            feeAmount = Math.mulDiv(rawOut, feeBps, BPS_DENOMINATOR);
            outToRecipient = rawOut > feeAmount ? rawOut - feeAmount : 0;
        } else {
            uint256 amountInWithFee = Math.mulDiv(amountIn, BPS_DENOMINATOR - feeBps, BPS_DENOMINATOR);
            feeAmount = amountIn - amountInWithFee;
            rawOut = Math.mulDiv(reserveOut, amountInWithFee, reserveIn + amountInWithFee);
            outToRecipient = rawOut;
        }
    }

    function computeSwapByInvariant(
        DerivativeTypes.InvariantMode invariantMode,
        DerivativeTypes.FeeAsset feeAsset,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 amountIn,
        uint16 feeBps,
        uint8 decimalsIn,
        uint8 decimalsOut
    ) internal pure returns (uint256 rawOut, uint256 feeAmount, uint256 outToRecipient) {
        if (invariantMode == DerivativeTypes.InvariantMode.Volatile) {
            return computeSwap(feeAsset, reserveIn, reserveOut, amountIn, feeBps);
        }
        return _computeStableSwap(feeAsset, reserveIn, reserveOut, amountIn, feeBps, decimalsIn, decimalsOut, MAX_STABLE_ITERATIONS);
    }

    function computeStableSwap(
        DerivativeTypes.FeeAsset feeAsset,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 amountIn,
        uint16 feeBps,
        uint8 decimalsIn,
        uint8 decimalsOut,
        uint256 maxIterations
    ) internal pure returns (uint256 rawOut, uint256 feeAmount, uint256 outToRecipient) {
        return _computeStableSwap(feeAsset, reserveIn, reserveOut, amountIn, feeBps, decimalsIn, decimalsOut, maxIterations);
    }

    function validateStableDecimals(uint8 decimalsIn, uint8 decimalsOut) internal pure {
        _validateStableDecimal(decimalsIn);
        _validateStableDecimal(decimalsOut);
    }

    function splitFee(uint256 feeAmount, uint16 makerBps, uint16 indexBps)
        internal
        pure
        returns (uint256 makerFee, uint256 indexFee, uint256 treasuryFee, uint256 protocolFee)
    {
        if (feeAmount == 0) {
            return (0, 0, 0, 0);
        }
        makerFee = Math.mulDiv(feeAmount, makerBps, BPS_DENOMINATOR);
        indexFee = Math.mulDiv(feeAmount, indexBps, BPS_DENOMINATOR);
        treasuryFee = feeAmount - makerFee - indexFee;
        protocolFee = indexFee + treasuryFee;
    }

    function applyProtocolFee(
        DerivativeTypes.FeeAsset feeAsset,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 protocolFee
    ) internal pure returns (uint256 newReserveIn, uint256 newReserveOut, bool ok) {
        newReserveIn = reserveIn;
        newReserveOut = reserveOut;
        if (protocolFee == 0) {
            return (newReserveIn, newReserveOut, true);
        }
        if (feeAsset == DerivativeTypes.FeeAsset.TokenIn) {
            if (reserveIn < protocolFee) {
                return (newReserveIn, newReserveOut, false);
            }
            newReserveIn = reserveIn - protocolFee;
        } else {
            if (reserveOut < protocolFee) {
                return (newReserveIn, newReserveOut, false);
            }
            newReserveOut = reserveOut - protocolFee;
        }
        ok = true;
    }

    function _computeStableSwap(
        DerivativeTypes.FeeAsset feeAsset,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 amountIn,
        uint16 feeBps,
        uint8 decimalsIn,
        uint8 decimalsOut,
        uint256 maxIterations
    ) private pure returns (uint256 rawOut, uint256 feeAmount, uint256 outToRecipient) {
        if (reserveIn == 0 || reserveOut == 0 || amountIn == 0) {
            revert LibAuctionSwap_InvalidStableInput();
        }
        if (maxIterations == 0) {
            revert LibAuctionSwap_StableNonConvergence();
        }
        if (feeAsset == DerivativeTypes.FeeAsset.TokenOut) {
            rawOut = _stableOutAmount(reserveIn, reserveOut, amountIn, decimalsIn, decimalsOut, maxIterations);
            feeAmount = Math.mulDiv(rawOut, feeBps, BPS_DENOMINATOR);
            outToRecipient = rawOut > feeAmount ? rawOut - feeAmount : 0;
        } else {
            uint256 amountInWithFee = Math.mulDiv(amountIn, BPS_DENOMINATOR - feeBps, BPS_DENOMINATOR);
            feeAmount = amountIn - amountInWithFee;
            rawOut = _stableOutAmount(reserveIn, reserveOut, amountInWithFee, decimalsIn, decimalsOut, maxIterations);
            outToRecipient = rawOut;
        }
    }

    function _stableOutAmount(
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 amountIn,
        uint8 decimalsIn,
        uint8 decimalsOut,
        uint256 maxIterations
    ) private pure returns (uint256 amountOut) {
        if (amountIn == 0) {
            return 0;
        }
        uint256 x = _toWad(reserveIn, decimalsIn);
        uint256 y = _toWad(reserveOut, decimalsOut);
        uint256 dx = _toWad(amountIn, decimalsIn);
        if (x == 0 || y == 0 || dx == 0) {
            revert LibAuctionSwap_InvalidStableInput();
        }

        uint256 xy = _stableInvariant(x, y);
        uint256 xAfter = x + dx;
        uint256 yAfter = _solveStableY(xAfter, xy, y, maxIterations);
        if (yAfter >= y) {
            return 0;
        }

        uint256 outWad = y - yAfter;
        amountOut = _fromWad(outWad, decimalsOut);
    }

    function _stableInvariant(uint256 x, uint256 y) private pure returns (uint256) {
        uint256 x2 = Math.mulDiv(x, x, WAD);
        uint256 y2 = Math.mulDiv(y, y, WAD);
        if (x2 > type(uint256).max - y2) {
            revert LibAuctionSwap_InvalidStableInput();
        }
        uint256 x2PlusY2 = x2 + y2;
        uint256 xy = Math.mulDiv(x, y, WAD);
        return Math.mulDiv(xy, x2PlusY2, WAD);
    }

    function _stableF(uint256 x0, uint256 y) private pure returns (uint256) {
        uint256 y2 = Math.mulDiv(y, y, WAD);
        uint256 y3 = Math.mulDiv(y2, y, WAD);
        uint256 x2 = Math.mulDiv(x0, x0, WAD);
        uint256 x3 = Math.mulDiv(x2, x0, WAD);
        uint256 xTimesY3 = Math.mulDiv(x0, y3, WAD);
        uint256 x3TimesY = Math.mulDiv(x3, y, WAD);
        if (xTimesY3 > type(uint256).max - x3TimesY) {
            revert LibAuctionSwap_InvalidStableInput();
        }
        return xTimesY3 + x3TimesY;
    }

    function _stableDerivative(uint256 x0, uint256 y) private pure returns (uint256) {
        uint256 y2 = Math.mulDiv(y, y, WAD);
        uint256 xTimesY2 = Math.mulDiv(x0, y2, WAD);
        if (xTimesY2 > type(uint256).max / 3) {
            revert LibAuctionSwap_InvalidStableInput();
        }
        uint256 threeXy2 = xTimesY2 * 3;
        uint256 x2 = Math.mulDiv(x0, x0, WAD);
        uint256 x3 = Math.mulDiv(x2, x0, WAD);
        if (threeXy2 > type(uint256).max - x3) {
            revert LibAuctionSwap_InvalidStableInput();
        }
        return threeXy2 + x3;
    }

    function _solveStableY(uint256 x0, uint256 xy, uint256 y, uint256 maxIterations) private pure returns (uint256) {
        for (uint256 i; i < maxIterations; ++i) {
            uint256 yPrev = y;
            uint256 k = _stableF(x0, y);
            uint256 d = _stableDerivative(x0, y);
            if (d == 0) {
                revert LibAuctionSwap_InvalidStableInput();
            }

            uint256 dy;
            if (k < xy) {
                dy = Math.mulDiv(xy - k, WAD, d);
                y = y + dy;
            } else {
                dy = Math.mulDiv(k - xy, WAD, d);
                y = dy >= y ? 0 : y - dy;
            }

            if (y > yPrev) {
                if (y - yPrev <= 1) return y;
            } else if (yPrev - y <= 1) {
                return y;
            }
        }

        revert LibAuctionSwap_StableNonConvergence();
    }

    function _toWad(uint256 amount, uint8 decimals) private pure returns (uint256) {
        if (decimals == 18) return amount;
        if (decimals < 18) {
            uint256 upScale = _pow10(uint8(18 - decimals));
            if (amount > type(uint256).max / upScale) {
                revert LibAuctionSwap_InvalidStableInput();
            }
            return amount * upScale;
        }

        uint256 downScale = _pow10(uint8(decimals - 18));
        return amount / downScale;
    }

    function _fromWad(uint256 wadAmount, uint8 decimals) private pure returns (uint256) {
        if (decimals == 18) return wadAmount;
        if (decimals < 18) {
            uint256 downScale = _pow10(uint8(18 - decimals));
            return wadAmount / downScale;
        }

        uint256 upScale = _pow10(uint8(decimals - 18));
        if (wadAmount > type(uint256).max / upScale) {
            revert LibAuctionSwap_InvalidStableInput();
        }
        return wadAmount * upScale;
    }

    function _pow10(uint8 exp) private pure returns (uint256 value) {
        if (exp > 77) {
            revert LibAuctionSwap_UnsupportedDecimals(exp);
        }
        value = 1;
        for (uint8 i; i < exp; ++i) {
            value *= 10;
        }
    }

    function _validateStableDecimal(uint8 decimals) private pure {
        uint8 exp = decimals > 18 ? decimals - 18 : 18 - decimals;
        if (exp > 77) {
            revert LibAuctionSwap_UnsupportedDecimals(exp);
        }
    }
}
