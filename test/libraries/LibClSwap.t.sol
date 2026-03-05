// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibClSwap} from "src/libraries/LibClSwap.sol";
import {LibClMath} from "src/libraries/LibClMath.sol";
import {LibClTickBitmap} from "src/libraries/LibClTickBitmap.sol";
import {LibClAuctionStorage} from "src/libraries/LibClAuctionStorage.sol";

contract LibClSwapHarness {
    function setAuction(
        uint256 auctionId,
        uint24 tickSpacing,
        uint24 swapFee,
        uint160 sqrtPriceX96,
        int24 tick,
        uint128 liquidity,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128
    ) external {
        LibClAuctionStorage.ClCommunityAuction storage a = LibClAuctionStorage.s().auctions[auctionId];
        a.auctionId = auctionId;
        a.tickSpacing = tickSpacing;
        a.swapFee = swapFee;
        a.sqrtPriceX96 = sqrtPriceX96;
        a.tick = tick;
        a.liquidity = liquidity;
        a.feeGrowthGlobal0X128 = feeGrowthGlobal0X128;
        a.feeGrowthGlobal1X128 = feeGrowthGlobal1X128;
    }

    function setTickInfo(
        uint256 auctionId,
        int24 tick,
        int128 liquidityNet,
        uint256 feeGrowthOutside0X128,
        uint256 feeGrowthOutside1X128,
        bool initialized
    ) external {
        LibClAuctionStorage.TickInfo storage t = LibClAuctionStorage.s().ticks[auctionId][tick];
        t.liquidityNet = liquidityNet;
        t.feeGrowthOutside0X128 = feeGrowthOutside0X128;
        t.feeGrowthOutside1X128 = feeGrowthOutside1X128;
        t.initialized = initialized;
    }

    function flipTick(uint256 auctionId, int24 tick, int24 tickSpacing) external {
        LibClTickBitmap.flipTick(auctionId, tick, tickSpacing);
    }

    function executeSwap(uint256 auctionId, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96)
        external
        returns (int256 amount0, int256 amount1)
    {
        return LibClSwap.executeSwap(auctionId, zeroForOne, amountSpecified, sqrtPriceLimitX96);
    }

    function getAuction(uint256 auctionId)
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint128 liquidity,
            uint256 feeGrowthGlobal0X128,
            uint256 feeGrowthGlobal1X128,
            uint128 protocolFees0,
            uint128 protocolFees1
        )
    {
        LibClAuctionStorage.ClCommunityAuction storage a = LibClAuctionStorage.s().auctions[auctionId];
        return (
            a.sqrtPriceX96,
            a.tick,
            a.liquidity,
            a.feeGrowthGlobal0X128,
            a.feeGrowthGlobal1X128,
            a.protocolFees0,
            a.protocolFees1
        );
    }

    function getTickInfo(uint256 auctionId, int24 tick)
        external
        view
        returns (int128 liquidityNet, uint256 feeGrowthOutside0X128, uint256 feeGrowthOutside1X128)
    {
        LibClAuctionStorage.TickInfo storage t = LibClAuctionStorage.s().ticks[auctionId][tick];
        return (t.liquidityNet, t.feeGrowthOutside0X128, t.feeGrowthOutside1X128);
    }

    function sqrtAtTick(int24 tick) external pure returns (uint160) {
        return LibClMath.getSqrtRatioAtTick(tick);
    }
}

contract LibClSwapTest is Test {
    LibClSwapHarness internal h;

    function setUp() public {
        h = new LibClSwapHarness();
    }

    function test_executeSwap_zeroForOneExactIn_updatesFeeGrowthProtocolAndCrossesTick() public {
        uint256 auctionId = 1;
        uint160 sqrtPriceStart = h.sqrtAtTick(100);
        uint160 sqrtPriceLimit = h.sqrtAtTick(80);

        h.setAuction(auctionId, 1, 3000, sqrtPriceStart, 100, 1_000_000e18, 0, 0);

        h.setTickInfo(auctionId, 90, -500_000e18, 0, 0, true);
        h.flipTick(auctionId, 90, 1);

        (int256 amount0, int256 amount1) = h.executeSwap(auctionId, true, int256(1_000_000e18), sqrtPriceLimit);

        (
            uint160 sqrtAfter,
            int24 tickAfter,
            uint128 liquidityAfter,
            uint256 feeGrowth0,
            uint256 feeGrowth1,
            uint128 protocolFees0,
            uint128 protocolFees1
        ) = h.getAuction(auctionId);

        assertGt(amount0, 0);
        assertLt(amount1, 0);
        assertLt(sqrtAfter, sqrtPriceStart);
        assertLe(tickAfter, 100);
        assertGt(liquidityAfter, 0);

        assertGt(feeGrowth0, 0);
        assertEq(feeGrowth1, 0);
        assertGt(protocolFees0, 0);
        assertEq(protocolFees1, 0);

        (, uint256 feeGrowthOutside0, uint256 feeGrowthOutside1) = h.getTickInfo(auctionId, 90);
        assertGt(feeGrowthOutside0, 0);
        assertEq(feeGrowthOutside1, 0);
    }

    function test_executeSwap_oneForZeroExactIn_updatesFeeGrowthAndProtocolOnToken1() public {
        uint256 auctionId = 2;
        uint160 sqrtPriceStart = h.sqrtAtTick(100);
        uint160 sqrtPriceLimit = h.sqrtAtTick(120);

        h.setAuction(auctionId, 1, 3000, sqrtPriceStart, 100, 1_000_000e18, 0, 0);

        (int256 amount0, int256 amount1) = h.executeSwap(auctionId, false, int256(500_000e18), sqrtPriceLimit);

        (, int24 tickAfter,, uint256 feeGrowth0, uint256 feeGrowth1, uint128 protocolFees0, uint128 protocolFees1) =
            h.getAuction(auctionId);

        assertLt(amount0, 0);
        assertGt(amount1, 0);
        assertGe(tickAfter, 100);

        assertEq(feeGrowth0, 0);
        assertGt(feeGrowth1, 0);
        assertEq(protocolFees0, 0);
        assertGt(protocolFees1, 0);
    }

    function test_executeSwap_zeroForOneExactOut_signsAndStateUpdate() public {
        uint256 auctionId = 3;
        uint160 sqrtPriceStart = h.sqrtAtTick(50);
        uint160 sqrtPriceLimit = h.sqrtAtTick(30);

        h.setAuction(auctionId, 1, 3000, sqrtPriceStart, 50, 500_000e18, 0, 0);

        (int256 amount0, int256 amount1) = h.executeSwap(auctionId, true, -int256(1_000e18), sqrtPriceLimit);

        (uint160 sqrtAfter,,,,,,) = h.getAuction(auctionId);
        assertGt(amount0, 0);
        assertLt(amount1, 0);
        assertLt(sqrtAfter, sqrtPriceStart);
    }

    function test_executeSwap_revertsOnInvalidLimit() public {
        uint256 auctionId = 4;
        uint160 sqrtPriceStart = h.sqrtAtTick(100);

        h.setAuction(auctionId, 1, 3000, sqrtPriceStart, 100, 1_000_000e18, 0, 0);

        vm.expectRevert(abi.encodeWithSelector(LibClSwap.LibClSwap_InvalidSqrtPriceLimit.selector, sqrtPriceStart));
        h.executeSwap(auctionId, true, int256(1_000e18), sqrtPriceStart);

        vm.expectRevert(abi.encodeWithSelector(LibClSwap.LibClSwap_InvalidSqrtPriceLimit.selector, sqrtPriceStart));
        h.executeSwap(auctionId, false, int256(1_000e18), sqrtPriceStart);
    }
}
