// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {DerivativeTypes} from "../libraries/DerivativeTypes.sol";
import {LibDerivativeStorage} from "../libraries/LibDerivativeStorage.sol";
import {LibAuctionSwap} from "../libraries/LibAuctionSwap.sol";

/// @notice Read-only AMM auction helpers split out to keep execution facet bytecode under the limit.
contract AmmAuctionViewFacet {
    function getAuction(uint256 auctionId) external view returns (DerivativeTypes.AmmAuction memory) {
        return LibDerivativeStorage.derivativeStorage().auctions[auctionId];
    }

    function previewSwap(uint256 auctionId, address tokenIn, uint256 amountIn)
        external
        view
        returns (uint256 amountOut, uint256 feeAmount)
    {
        if (amountIn == 0) return (0, 0);
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
}
