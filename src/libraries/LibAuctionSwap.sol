// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {DerivativeTypes} from "./DerivativeTypes.sol";

/// @notice Shared swap math and fee splitting helpers for auction facets.
library LibAuctionSwap {
    uint256 internal constant BPS_DENOMINATOR = 10_000;

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
}
