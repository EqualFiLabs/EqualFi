// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibDerivativeStorage} from "../libraries/LibDerivativeStorage.sol";
import {DerivativeTypes} from "../libraries/DerivativeTypes.sol";
import {LibPositionNFT} from "../libraries/LibPositionNFT.sol";
import {PositionNFT} from "../nft/PositionNFT.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice View aggregation for Position NFT derivative state.
contract DerivativeViewFacet {
    function getAmmAuction(uint256 auctionId) external view returns (DerivativeTypes.AmmAuction memory) {
        return LibDerivativeStorage.derivativeStorage().auctions[auctionId];
    }

    function getAuctionFees(uint256 auctionId) external view returns (uint256 makerFeeA, uint256 makerFeeB) {
        DerivativeTypes.AmmAuction storage auction = LibDerivativeStorage.derivativeStorage().auctions[auctionId];
        return (auction.makerFeeAAccrued, auction.makerFeeBAccrued);
    }

    function getOptionSeries(uint256 seriesId) external view returns (DerivativeTypes.OptionSeries memory) {
        return LibDerivativeStorage.derivativeStorage().optionSeries[seriesId];
    }

    function getOptionSeriesCollateral(uint256 seriesId)
        external
        view
        returns (uint256 collateralLocked, uint256 remaining)
    {
        DerivativeTypes.OptionSeries storage series = LibDerivativeStorage.derivativeStorage().optionSeries[seriesId];
        return (series.collateralLocked, series.remaining);
    }

    function getFuturesSeries(uint256 seriesId) external view returns (DerivativeTypes.FuturesSeries memory) {
        return LibDerivativeStorage.derivativeStorage().futuresSeries[seriesId];
    }

    function getFuturesCollateral(uint256 seriesId)
        external
        view
        returns (uint256 underlyingLocked, uint256 remaining)
    {
        DerivativeTypes.FuturesSeries storage series = LibDerivativeStorage.derivativeStorage().futuresSeries[seriesId];
        return (series.underlyingLocked, series.remaining);
    }

    function getGraceUnlockTime(uint256 seriesId) external view returns (uint64) {
        return LibDerivativeStorage.derivativeStorage().futuresSeries[seriesId].graceUnlockTime;
    }

    function getAuctionsByPosition(bytes32 positionKey, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory ids, uint256 total)
    {
        return LibDerivativeStorage.auctionsPage(positionKey, offset, limit);
    }

    function getAuctionsByPositionId(uint256 positionId, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory ids, uint256 total)
    {
        return LibDerivativeStorage.auctionsPage(_positionKey(positionId), offset, limit);
    }

    function getActiveAuctions(uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory ids, uint256 total)
    {
        return LibDerivativeStorage.auctionsGlobalPage(offset, limit);
    }

    function getAuctionsByPool(uint256 poolId, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory ids, uint256 total)
    {
        return LibDerivativeStorage.auctionsByPoolPage(poolId, offset, limit);
    }

    function getAuctionsByToken(address token, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory ids, uint256 total)
    {
        return LibDerivativeStorage.auctionsByTokenPage(token, offset, limit);
    }

    function getAuctionsByPair(address tokenA, address tokenB, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory ids, uint256 total)
    {
        return LibDerivativeStorage.auctionsByPairPage(tokenA, tokenB, offset, limit);
    }

    function getAuctionMeta(uint256 auctionId)
        external
        view
        returns (
            bool active,
            bool expired,
            uint64 startTime,
            uint64 endTime,
            address tokenA,
            address tokenB,
            uint256 reserveA,
            uint256 reserveB,
            uint256 priceAInB,
            uint256 priceBInA,
            uint256 timeRemaining
        )
    {
        DerivativeTypes.AmmAuction storage auction = LibDerivativeStorage.derivativeStorage().auctions[auctionId];
        active = auction.active && !auction.finalized;
        startTime = auction.startTime;
        endTime = auction.endTime;
        tokenA = auction.tokenA;
        tokenB = auction.tokenB;
        reserveA = auction.reserveA;
        reserveB = auction.reserveB;
        expired = block.timestamp >= endTime;
        if (reserveA > 0) {
            priceAInB = Math.mulDiv(reserveB, 1e18, reserveA);
        }
        if (reserveB > 0) {
            priceBInA = Math.mulDiv(reserveA, 1e18, reserveB);
        }
        if (block.timestamp < endTime) {
            timeRemaining = endTime - block.timestamp;
        }
    }

    function previewSwapWithSlippage(
        uint256 auctionId,
        address tokenIn,
        uint256 amountIn,
        uint16 slippageBps
    ) external view returns (uint256 amountOut, uint256 feeAmount, uint256 minOut) {
        (amountOut, feeAmount) = _previewAuctionSwap(auctionId, tokenIn, amountIn);
        if (amountOut == 0) {
            return (0, feeAmount, 0);
        }
        if (slippageBps > 10_000) {
            slippageBps = 10_000;
        }
        minOut = Math.mulDiv(amountOut, 10_000 - slippageBps, 10_000);
    }

    function findBestAuctionExactIn(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 offset,
        uint256 limit
    ) external view returns (uint256 bestAuctionId, uint256 bestAmountOut, uint256 checked) {
        (uint256[] memory ids, uint256 total) = LibDerivativeStorage.auctionsByPairPage(
            tokenIn,
            tokenOut,
            offset,
            limit
        );
        uint256 count = ids.length;
        checked = count;
        if (count == 0 || total == 0) {
            return (0, 0, checked);
        }
        for (uint256 i = 0; i < count; i++) {
            uint256 auctionId = ids[i];
            (uint256 out,) = _previewAuctionSwapWithWindow(auctionId, tokenIn, amountIn);
            if (out > bestAmountOut) {
                bestAmountOut = out;
                bestAuctionId = auctionId;
            }
        }
    }

    function getOptionSeriesByPosition(bytes32 positionKey, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory ids, uint256 total)
    {
        return LibDerivativeStorage.optionSeriesPage(positionKey, offset, limit);
    }

    function getOptionSeriesByPositionId(uint256 positionId, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory ids, uint256 total)
    {
        return LibDerivativeStorage.optionSeriesPage(_positionKey(positionId), offset, limit);
    }

    function getFuturesSeriesByPosition(bytes32 positionKey, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory ids, uint256 total)
    {
        return LibDerivativeStorage.futuresSeriesPage(positionKey, offset, limit);
    }

    function getFuturesSeriesByPositionId(uint256 positionId, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory ids, uint256 total)
    {
        return LibDerivativeStorage.futuresSeriesPage(_positionKey(positionId), offset, limit);
    }

    function selectors() external pure returns (bytes4[] memory selectorsArr) {
        selectorsArr = new bytes4[](20);
        selectorsArr[0] = DerivativeViewFacet.getAmmAuction.selector;
        selectorsArr[1] = DerivativeViewFacet.getAuctionFees.selector;
        selectorsArr[2] = DerivativeViewFacet.getOptionSeries.selector;
        selectorsArr[3] = DerivativeViewFacet.getOptionSeriesCollateral.selector;
        selectorsArr[4] = DerivativeViewFacet.getFuturesSeries.selector;
        selectorsArr[5] = DerivativeViewFacet.getFuturesCollateral.selector;
        selectorsArr[6] = DerivativeViewFacet.getGraceUnlockTime.selector;
        selectorsArr[7] = DerivativeViewFacet.getAuctionsByPosition.selector;
        selectorsArr[8] = DerivativeViewFacet.getAuctionsByPositionId.selector;
        selectorsArr[9] = DerivativeViewFacet.getActiveAuctions.selector;
        selectorsArr[10] = DerivativeViewFacet.getAuctionsByPool.selector;
        selectorsArr[11] = DerivativeViewFacet.getAuctionsByToken.selector;
        selectorsArr[12] = DerivativeViewFacet.getAuctionsByPair.selector;
        selectorsArr[13] = DerivativeViewFacet.getAuctionMeta.selector;
        selectorsArr[14] = DerivativeViewFacet.previewSwapWithSlippage.selector;
        selectorsArr[15] = DerivativeViewFacet.findBestAuctionExactIn.selector;
        selectorsArr[16] = DerivativeViewFacet.getOptionSeriesByPosition.selector;
        selectorsArr[17] = DerivativeViewFacet.getOptionSeriesByPositionId.selector;
        selectorsArr[18] = DerivativeViewFacet.getFuturesSeriesByPosition.selector;
        selectorsArr[19] = DerivativeViewFacet.getFuturesSeriesByPositionId.selector;
    }

    function _positionKey(uint256 positionId) private view returns (bytes32) {
        LibPositionNFT.PositionNFTStorage storage ns = LibPositionNFT.s();
        require(ns.nftModeEnabled && ns.positionNFTContract != address(0), "DerivativeView: position NFT disabled");
        PositionNFT nft = PositionNFT(ns.positionNFTContract);
        return nft.getPositionKey(positionId);
    }

    function _previewAuctionSwap(uint256 auctionId, address tokenIn, uint256 amountIn)
        private
        view
        returns (uint256 amountOut, uint256 feeAmount)
    {
        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        DerivativeTypes.AmmAuction storage auction = ds.auctions[auctionId];
        if (!auction.active || auction.finalized) {
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
        (uint256 rawOut, uint256 fee, uint256 outToRecipient) =
            _computeAuctionSwap(auction.feeAsset, reserveIn, reserveOut, amountIn, auction.feeBps);
        rawOut;
        feeAmount = fee;
        amountOut = outToRecipient;
    }

    function _previewAuctionSwapWithWindow(uint256 auctionId, address tokenIn, uint256 amountIn)
        private
        view
        returns (uint256 amountOut, uint256 feeAmount)
    {
        LibDerivativeStorage.DerivativeStorage storage ds = LibDerivativeStorage.derivativeStorage();
        DerivativeTypes.AmmAuction storage auction = ds.auctions[auctionId];
        if (!auction.active || auction.finalized) {
            return (0, 0);
        }
        if (block.timestamp < auction.startTime || block.timestamp >= auction.endTime) {
            return (0, 0);
        }
        return _previewAuctionSwap(auctionId, tokenIn, amountIn);
    }

    function _computeAuctionSwap(
        DerivativeTypes.FeeAsset feeAsset,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 amountIn,
        uint16 feeBps
    ) private pure returns (uint256 rawOut, uint256 feeAmount, uint256 outToRecipient) {
        if (reserveIn == 0 || reserveOut == 0) {
            return (0, 0, 0);
        }
        if (feeAsset == DerivativeTypes.FeeAsset.TokenOut) {
            rawOut = Math.mulDiv(reserveOut, amountIn, reserveIn + amountIn);
            feeAmount = Math.mulDiv(rawOut, feeBps, 10_000);
            outToRecipient = rawOut > feeAmount ? rawOut - feeAmount : 0;
        } else {
            uint256 amountInWithFee = Math.mulDiv(amountIn, 10_000 - feeBps, 10_000);
            feeAmount = amountIn - amountInWithFee;
            rawOut = Math.mulDiv(reserveOut, amountInWithFee, reserveIn + amountInWithFee);
            outToRecipient = rawOut;
        }
    }
}
