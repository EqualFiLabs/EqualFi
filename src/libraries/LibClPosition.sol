// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LibClAuctionStorage} from "./LibClAuctionStorage.sol";
import {ClAuction_LiquidityUnderflow} from "./ClAuctionErrors.sol";

library LibClPosition {
    uint256 internal constant Q128 = 0x100000000000000000000000000000000;
    error LibClPosition_FeeOverflow(uint256 sum);

    function getFeeGrowthInside(
        uint256 auctionId,
        int24 tickLower,
        int24 tickUpper,
        int24 tickCurrent,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128
    ) internal view returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) {
        LibClAuctionStorage.ClStorage storage cs = LibClAuctionStorage.s();
        LibClAuctionStorage.TickInfo storage lower = cs.ticks[auctionId][tickLower];
        LibClAuctionStorage.TickInfo storage upper = cs.ticks[auctionId][tickUpper];

        uint256 feeGrowthBelow0X128;
        uint256 feeGrowthBelow1X128;
        if (tickCurrent >= tickLower) {
            feeGrowthBelow0X128 = lower.feeGrowthOutside0X128;
            feeGrowthBelow1X128 = lower.feeGrowthOutside1X128;
        } else {
            feeGrowthBelow0X128 = feeGrowthGlobal0X128 - lower.feeGrowthOutside0X128;
            feeGrowthBelow1X128 = feeGrowthGlobal1X128 - lower.feeGrowthOutside1X128;
        }

        uint256 feeGrowthAbove0X128;
        uint256 feeGrowthAbove1X128;
        if (tickCurrent < tickUpper) {
            feeGrowthAbove0X128 = upper.feeGrowthOutside0X128;
            feeGrowthAbove1X128 = upper.feeGrowthOutside1X128;
        } else {
            feeGrowthAbove0X128 = feeGrowthGlobal0X128 - upper.feeGrowthOutside0X128;
            feeGrowthAbove1X128 = feeGrowthGlobal1X128 - upper.feeGrowthOutside1X128;
        }

        feeGrowthInside0X128 = feeGrowthGlobal0X128 - feeGrowthBelow0X128 - feeGrowthAbove0X128;
        feeGrowthInside1X128 = feeGrowthGlobal1X128 - feeGrowthBelow1X128 - feeGrowthAbove1X128;
    }

    function updatePosition(uint256 clPositionId, int128 liquidityDelta)
        internal
        returns (LibClAuctionStorage.ClPosition storage position)
    {
        LibClAuctionStorage.ClStorage storage cs = LibClAuctionStorage.s();
        position = cs.positions[clPositionId];

        LibClAuctionStorage.ClCommunityAuction storage auction = cs.auctions[position.auctionId];
        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) = getFeeGrowthInside(
            position.auctionId,
            position.tickLower,
            position.tickUpper,
            auction.tick,
            auction.feeGrowthGlobal0X128,
            auction.feeGrowthGlobal1X128
        );

        uint128 liquidityBefore = position.liquidity;
        uint128 liquidityNext = liquidityDelta == 0 ? liquidityBefore : _addLiquidityDelta(liquidityBefore, liquidityDelta);

        uint256 tokensOwed0 =
            Math.mulDiv(feeGrowthInside0X128 - position.feeGrowthInside0LastX128, liquidityBefore, Q128);
        uint256 tokensOwed1 =
            Math.mulDiv(feeGrowthInside1X128 - position.feeGrowthInside1LastX128, liquidityBefore, Q128);

        if (liquidityDelta != 0) {
            position.liquidity = liquidityNext;
        }
        position.feeGrowthInside0LastX128 = feeGrowthInside0X128;
        position.feeGrowthInside1LastX128 = feeGrowthInside1X128;

        if (tokensOwed0 > 0) {
            position.tokensOwed0 = _addUint128(position.tokensOwed0, tokensOwed0);
        }
        if (tokensOwed1 > 0) {
            position.tokensOwed1 = _addUint128(position.tokensOwed1, tokensOwed1);
        }
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

    function _addUint128(uint128 a, uint256 b) private pure returns (uint128) {
        uint256 sum = uint256(a) + b;
        if (sum > type(uint128).max) revert LibClPosition_FeeOverflow(sum);
        return uint128(sum);
    }
}
