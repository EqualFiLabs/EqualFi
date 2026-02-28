// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {DerivativeTypes} from "../libraries/DerivativeTypes.sol";
import {LibDerivativeStorage} from "../libraries/LibDerivativeStorage.sol";
import {LibCommunityAuctionFeeIndex} from "../libraries/LibCommunityAuctionFeeIndex.sol";
import {LibAuctionSwap} from "../libraries/LibAuctionSwap.sol";

/// @notice Read-only community auction helpers split out to keep execution facet bytecode under the limit.
contract CommunityAuctionViewFacet {
    function getCommunityAuction(uint256 auctionId) external view returns (DerivativeTypes.CommunityAuction memory) {
        return LibDerivativeStorage.derivativeStorage().communityAuctions[auctionId];
    }

    function getMakerShare(uint256 auctionId, bytes32 positionKey)
        external
        view
        returns (uint256 share, uint256 pendingFeesA, uint256 pendingFeesB)
    {
        DerivativeTypes.MakerPosition storage maker =
            LibDerivativeStorage.derivativeStorage().communityAuctionMakers[auctionId][positionKey];
        share = maker.share;
        (pendingFeesA, pendingFeesB) = LibCommunityAuctionFeeIndex.pendingFees(auctionId, positionKey);
    }

    function previewJoin(uint256 auctionId, uint256 amountA) external view returns (uint256 requiredB) {
        if (amountA == 0) return 0;
        DerivativeTypes.CommunityAuction storage auction =
            LibDerivativeStorage.derivativeStorage().communityAuctions[auctionId];
        if (auction.reserveA == 0 || auction.reserveB == 0) {
            return 0;
        }
        requiredB = Math.mulDiv(amountA, auction.reserveB, auction.reserveA);
    }

    function previewCommunitySwap(uint256 auctionId, address tokenIn, uint256 amountIn)
        external
        view
        returns (uint256 amountOut, uint256 feeAmount)
    {
        if (amountIn == 0) return (0, 0);
        DerivativeTypes.CommunityAuction storage auction =
            LibDerivativeStorage.derivativeStorage().communityAuctions[auctionId];
        if (
            !auction.active || auction.finalized || auction.totalShares == 0 || block.timestamp < auction.startTime
                || block.timestamp >= auction.endTime
        ) {
            return (0, 0);
        }
        bool inIsA;
        if (tokenIn == auction.tokenA) {
            inIsA = true;
        } else if (tokenIn == auction.tokenB) {
            inIsA = false;
        } else {
            return (0, 0);
        }
        uint256 reserveIn = inIsA ? auction.reserveA : auction.reserveB;
        uint256 reserveOut = inIsA ? auction.reserveB : auction.reserveA;
        uint8 decimalsIn = inIsA ? auction.tokenADecimals : auction.tokenBDecimals;
        uint8 decimalsOut = inIsA ? auction.tokenBDecimals : auction.tokenADecimals;
        (uint256 rawOut, uint256 fee, uint256 outToRecipient) = LibAuctionSwap.computeSwapByInvariant(
            auction.invariantMode,
            auction.feeAsset,
            reserveIn,
            reserveOut,
            amountIn,
            auction.feeBps,
            decimalsIn,
            decimalsOut
        );
        rawOut;
        feeAmount = fee;
        amountOut = outToRecipient;
    }

    function previewLeave(uint256 auctionId, bytes32 positionKey)
        external
        view
        returns (uint256 withdrawA, uint256 withdrawB, uint256 feesA, uint256 feesB)
    {
        DerivativeTypes.CommunityAuction storage auction =
            LibDerivativeStorage.derivativeStorage().communityAuctions[auctionId];
        DerivativeTypes.MakerPosition storage maker =
            LibDerivativeStorage.derivativeStorage().communityAuctionMakers[auctionId][positionKey];
        if (auction.totalShares == 0 || maker.share == 0) {
            return (0, 0, 0, 0);
        }
        uint256 reservedA = auction.indexFeeAAccrued + auction.activeCreditFeeAAccrued;
        uint256 reservedB = auction.indexFeeBAccrued + auction.activeCreditFeeBAccrued;
        uint256 withdrawableReserveA = auction.reserveA > reservedA ? auction.reserveA - reservedA : 0;
        uint256 withdrawableReserveB = auction.reserveB > reservedB ? auction.reserveB - reservedB : 0;
        withdrawA = Math.mulDiv(withdrawableReserveA, maker.share, auction.totalShares);
        withdrawB = Math.mulDiv(withdrawableReserveB, maker.share, auction.totalShares);
        (feesA, feesB) = LibCommunityAuctionFeeIndex.pendingFees(auctionId, positionKey);
    }

    function getTotalMakers(uint256 auctionId) external view returns (uint256) {
        return LibDerivativeStorage.derivativeStorage().communityAuctions[auctionId].makerCount;
    }
}
