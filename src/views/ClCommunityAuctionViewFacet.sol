// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LibClAuctionStorage} from "../libraries/LibClAuctionStorage.sol";
import {LibClPosition} from "../libraries/LibClPosition.sol";

/// @notice Read-only concentrated-liquidity auction state views.
contract ClCommunityAuctionViewFacet {
    uint256 internal constant Q128 = 0x100000000000000000000000000000000;

    function getClAuction(uint256 auctionId) external view returns (LibClAuctionStorage.ClCommunityAuction memory) {
        return LibClAuctionStorage.s().auctions[auctionId];
    }

    function getClPosition(uint256 clPositionId) external view returns (LibClAuctionStorage.ClPosition memory) {
        return LibClAuctionStorage.s().positions[clPositionId];
    }

    function getClTick(uint256 auctionId, int24 tick) external view returns (LibClAuctionStorage.TickInfo memory) {
        return LibClAuctionStorage.s().ticks[auctionId][tick];
    }

    function getClPoolState(uint256 auctionId) external view returns (uint160 sqrtPriceX96, int24 tick, uint128 liquidity) {
        LibClAuctionStorage.ClCommunityAuction storage auction = LibClAuctionStorage.s().auctions[auctionId];
        return (auction.sqrtPriceX96, auction.tick, auction.liquidity);
    }

    function getClFeeGrowthGlobals(uint256 auctionId) external view returns (uint256 feeGrowth0, uint256 feeGrowth1) {
        LibClAuctionStorage.ClCommunityAuction storage auction = LibClAuctionStorage.s().auctions[auctionId];
        return (auction.feeGrowthGlobal0X128, auction.feeGrowthGlobal1X128);
    }

    function getClUnclaimedFees(uint256 clPositionId) external view returns (uint256 amount0, uint256 amount1) {
        LibClAuctionStorage.ClStorage storage cs = LibClAuctionStorage.s();
        LibClAuctionStorage.ClPosition storage position = cs.positions[clPositionId];

        amount0 = position.tokensOwed0;
        amount1 = position.tokensOwed1;

        uint128 liquidity = position.liquidity;
        if (liquidity == 0) {
            return (amount0, amount1);
        }

        LibClAuctionStorage.ClCommunityAuction storage auction = cs.auctions[position.auctionId];
        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) = LibClPosition.getFeeGrowthInside(
            position.auctionId,
            position.tickLower,
            position.tickUpper,
            auction.tick,
            auction.feeGrowthGlobal0X128,
            auction.feeGrowthGlobal1X128
        );

        uint256 pending0 = Math.mulDiv(feeGrowthInside0X128 - position.feeGrowthInside0LastX128, liquidity, Q128);
        uint256 pending1 = Math.mulDiv(feeGrowthInside1X128 - position.feeGrowthInside1LastX128, liquidity, Q128);

        amount0 += pending0;
        amount1 += pending1;
    }

    function getClEncumbranceLock(uint256 clPositionId) external view returns (uint256 lockedA, uint256 lockedB) {
        LibClAuctionStorage.EncumbranceLock storage lockState = LibClAuctionStorage.s().encumbranceLocks[clPositionId];
        return (lockState.lockedA, lockState.lockedB);
    }
}
