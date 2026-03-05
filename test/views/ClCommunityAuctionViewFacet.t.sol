// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ClCommunityAuctionViewFacet} from "../../src/views/ClCommunityAuctionViewFacet.sol";
import {LibClAuctionStorage} from "../../src/libraries/LibClAuctionStorage.sol";

contract ClCommunityAuctionViewHarness is ClCommunityAuctionViewFacet {
    function seedAuction(
        uint256 auctionId,
        uint160 sqrtPriceX96,
        int24 tick,
        uint128 liquidity,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128
    ) external {
        LibClAuctionStorage.ClCommunityAuction storage a = LibClAuctionStorage.s().auctions[auctionId];
        a.auctionId = auctionId;
        a.sqrtPriceX96 = sqrtPriceX96;
        a.tick = tick;
        a.liquidity = liquidity;
        a.feeGrowthGlobal0X128 = feeGrowthGlobal0X128;
        a.feeGrowthGlobal1X128 = feeGrowthGlobal1X128;
        a.initialized = true;
    }

    function seedTick(
        uint256 auctionId,
        int24 tick,
        uint128 liquidityGross,
        int128 liquidityNet,
        uint256 feeGrowthOutside0X128,
        uint256 feeGrowthOutside1X128,
        bool initialized
    ) external {
        LibClAuctionStorage.TickInfo storage t = LibClAuctionStorage.s().ticks[auctionId][tick];
        t.liquidityGross = liquidityGross;
        t.liquidityNet = liquidityNet;
        t.feeGrowthOutside0X128 = feeGrowthOutside0X128;
        t.feeGrowthOutside1X128 = feeGrowthOutside1X128;
        t.initialized = initialized;
    }

    function seedPosition(
        uint256 clPositionId,
        uint256 auctionId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 feeGrowthInside0LastX128,
        uint256 feeGrowthInside1LastX128,
        uint128 tokensOwed0,
        uint128 tokensOwed1
    ) external {
        LibClAuctionStorage.ClPosition storage p = LibClAuctionStorage.s().positions[clPositionId];
        p.auctionId = auctionId;
        p.tickLower = tickLower;
        p.tickUpper = tickUpper;
        p.liquidity = liquidity;
        p.feeGrowthInside0LastX128 = feeGrowthInside0LastX128;
        p.feeGrowthInside1LastX128 = feeGrowthInside1LastX128;
        p.tokensOwed0 = tokensOwed0;
        p.tokensOwed1 = tokensOwed1;
    }

    function seedLock(uint256 clPositionId, uint256 lockedA, uint256 lockedB) external {
        LibClAuctionStorage.EncumbranceLock storage lockState = LibClAuctionStorage.s().encumbranceLocks[clPositionId];
        lockState.lockedA = lockedA;
        lockState.lockedB = lockedB;
    }

    function q128() external pure returns (uint256) {
        return 0x100000000000000000000000000000000;
    }
}

contract ClCommunityAuctionViewFacetTest is Test {
    ClCommunityAuctionViewHarness internal harness;

    function setUp() public {
        harness = new ClCommunityAuctionViewHarness();
    }

    function test_getters_returnSeededState() public {
        uint256 auctionId = 1;
        int24 tick = -120;
        uint160 sqrtPriceX96 = 79228162514264337593543950336;
        uint128 liquidity = 12345;
        uint256 feeGrowth0 = 11;
        uint256 feeGrowth1 = 22;

        harness.seedAuction(auctionId, sqrtPriceX96, tick, liquidity, feeGrowth0, feeGrowth1);
        harness.seedTick(auctionId, tick, 333, -7, 44, 55, true);
        harness.seedPosition(9, auctionId, -180, 180, 999, 66, 77, 88, 99);
        harness.seedLock(9, 555, 777);

        LibClAuctionStorage.ClCommunityAuction memory auction = harness.getClAuction(auctionId);
        assertEq(auction.auctionId, auctionId);
        assertEq(auction.sqrtPriceX96, sqrtPriceX96);
        assertEq(auction.tick, tick);
        assertEq(auction.liquidity, liquidity);

        LibClAuctionStorage.ClPosition memory position = harness.getClPosition(9);
        assertEq(position.auctionId, auctionId);
        assertEq(position.tickLower, -180);
        assertEq(position.tickUpper, 180);
        assertEq(position.liquidity, 999);
        assertEq(position.tokensOwed0, 88);
        assertEq(position.tokensOwed1, 99);

        LibClAuctionStorage.TickInfo memory tickInfo = harness.getClTick(auctionId, tick);
        assertEq(tickInfo.liquidityGross, 333);
        assertEq(tickInfo.liquidityNet, -7);
        assertEq(tickInfo.feeGrowthOutside0X128, 44);
        assertEq(tickInfo.feeGrowthOutside1X128, 55);
        assertTrue(tickInfo.initialized);

        (uint160 gotSqrt, int24 gotTick, uint128 gotLiquidity) = harness.getClPoolState(auctionId);
        assertEq(gotSqrt, sqrtPriceX96);
        assertEq(gotTick, tick);
        assertEq(gotLiquidity, liquidity);

        (uint256 gotFeeGrowth0, uint256 gotFeeGrowth1) = harness.getClFeeGrowthGlobals(auctionId);
        assertEq(gotFeeGrowth0, feeGrowth0);
        assertEq(gotFeeGrowth1, feeGrowth1);

        (uint256 lockedA, uint256 lockedB) = harness.getClEncumbranceLock(9);
        assertEq(lockedA, 555);
        assertEq(lockedB, 777);
    }

    function test_getClUnclaimedFees_computesPendingFeeGrowthInside() public {
        uint256 auctionId = 7;
        uint256 clPositionId = 77;

        uint256 q128 = harness.q128();

        // Current tick inside [-60, 60), so inside growth = global - lowerOutside - upperOutside.
        harness.seedAuction(auctionId, 1, 0, 1, 10 * q128, 20 * q128);
        harness.seedTick(auctionId, -60, 1, 0, 1 * q128, 4 * q128, true);
        harness.seedTick(auctionId, 60, 1, 0, 2 * q128, 5 * q128, true);

        // inside0 = 10 - 1 - 2 = 7 ; delta0 = 7 - 3 = 4 ; pending0 = 4 * 4 = 16
        // inside1 = 20 - 4 - 5 = 11; delta1 = 11 - 9 = 2 ; pending1 = 2 * 4 = 8
        harness.seedPosition(clPositionId, auctionId, -60, 60, 4, 3 * q128, 9 * q128, 5, 7);

        (uint256 amount0, uint256 amount1) = harness.getClUnclaimedFees(clPositionId);
        assertEq(amount0, 21);
        assertEq(amount1, 15);
    }

    function test_getClUnclaimedFees_zeroLiquidity_returnsTokensOwedOnly() public {
        uint256 auctionId = 11;
        uint256 clPositionId = 111;
        uint256 q128 = harness.q128();

        harness.seedAuction(auctionId, 1, 0, 0, 9 * q128, 9 * q128);
        harness.seedPosition(clPositionId, auctionId, -60, 60, 0, 0, 0, 123, 456);

        (uint256 amount0, uint256 amount1) = harness.getClUnclaimedFees(clPositionId);
        assertEq(amount0, 123);
        assertEq(amount1, 456);
    }
}
