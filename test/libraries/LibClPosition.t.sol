// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibClAuctionStorage} from "src/libraries/LibClAuctionStorage.sol";
import {LibClPosition} from "src/libraries/LibClPosition.sol";
import {
    ClAuction_LiquidityUnderflow,
    ClAuction_NotActive,
    ClAuction_InvalidTickRange,
    ClAuction_InputAmountMismatch
} from "src/libraries/ClAuctionErrors.sol";

contract LibClPositionHarness {
    function setAuction(uint256 auctionId, int24 tick, uint256 feeGrowthGlobal0X128, uint256 feeGrowthGlobal1X128) external {
        LibClAuctionStorage.ClCommunityAuction storage a = LibClAuctionStorage.s().auctions[auctionId];
        a.auctionId = auctionId;
        a.tick = tick;
        a.feeGrowthGlobal0X128 = feeGrowthGlobal0X128;
        a.feeGrowthGlobal1X128 = feeGrowthGlobal1X128;
    }

    function setTickInfo(
        uint256 auctionId,
        int24 tick,
        uint256 feeGrowthOutside0X128,
        uint256 feeGrowthOutside1X128,
        bool initialized
    ) external {
        LibClAuctionStorage.TickInfo storage t = LibClAuctionStorage.s().ticks[auctionId][tick];
        t.feeGrowthOutside0X128 = feeGrowthOutside0X128;
        t.feeGrowthOutside1X128 = feeGrowthOutside1X128;
        t.initialized = initialized;
    }

    function setPosition(
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

    function getFeeGrowthInside(
        uint256 auctionId,
        int24 tickLower,
        int24 tickUpper,
        int24 tickCurrent,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128
    ) external view returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) {
        return LibClPosition.getFeeGrowthInside(
            auctionId, tickLower, tickUpper, tickCurrent, feeGrowthGlobal0X128, feeGrowthGlobal1X128
        );
    }

    function updatePosition(uint256 clPositionId, int128 liquidityDelta)
        external
        returns (uint128 liquidity, uint256 fee0, uint256 fee1, uint128 owed0, uint128 owed1)
    {
        LibClAuctionStorage.ClPosition storage p = LibClPosition.updatePosition(clPositionId, liquidityDelta);
        return (
            p.liquidity, p.feeGrowthInside0LastX128, p.feeGrowthInside1LastX128, p.tokensOwed0, p.tokensOwed1
        );
    }

    function setStorageConfig(bool creationEnabled, bool swapPaused, uint24 swapFeeCap, address clPositionManager) external {
        LibClAuctionStorage.ClStorage storage cs = LibClAuctionStorage.s();
        cs.creationEnabled = creationEnabled;
        cs.swapPaused = swapPaused;
        cs.swapFeeCap = swapFeeCap;
        cs.clPositionManager = clPositionManager;
    }

    function getStorageConfig() external view returns (bool creationEnabled, bool swapPaused, uint24 swapFeeCap, address manager) {
        LibClAuctionStorage.ClStorage storage cs = LibClAuctionStorage.s();
        return (cs.creationEnabled, cs.swapPaused, cs.swapFeeCap, cs.clPositionManager);
    }

    function setStorageRoundTripFields(
        uint256 auctionId,
        int24 tick,
        uint256 clPositionId,
        uint256 sourcePositionId,
        uint256 lockA,
        uint256 lockB,
        uint24 tickSpacing,
        bool spacingAllowed,
        uint16 bitmapWordPos,
        uint256 bitmapWord
    ) external {
        LibClAuctionStorage.ClStorage storage cs = LibClAuctionStorage.s();
        cs.auctions[auctionId].tick = tick;
        cs.positions[clPositionId].sourcePositionId = sourcePositionId;
        cs.encumbranceLocks[clPositionId].lockedA = lockA;
        cs.encumbranceLocks[clPositionId].lockedB = lockB;
        cs.allowedTickSpacings[tickSpacing] = spacingAllowed;
        cs.tickBitmaps[auctionId][int16(bitmapWordPos)] = bitmapWord;
    }

    function getStorageRoundTripFields(
        uint256 auctionId,
        uint256 clPositionId,
        uint24 tickSpacing,
        uint16 bitmapWordPos
    )
        external
        view
        returns (
            int24 tick,
            uint256 sourcePositionId,
            uint256 lockA,
            uint256 lockB,
            bool spacingAllowed,
            uint256 bitmapWord
        )
    {
        LibClAuctionStorage.ClStorage storage cs = LibClAuctionStorage.s();
        return (
            cs.auctions[auctionId].tick,
            cs.positions[clPositionId].sourcePositionId,
            cs.encumbranceLocks[clPositionId].lockedA,
            cs.encumbranceLocks[clPositionId].lockedB,
            cs.allowedTickSpacings[tickSpacing],
            cs.tickBitmaps[auctionId][int16(bitmapWordPos)]
        );
    }

    function hashParamStructs() external pure returns (bytes32) {
        LibClAuctionStorage.CreateClAuctionParams memory createParams = LibClAuctionStorage.CreateClAuctionParams({
            positionId: 1,
            poolIdA: 11,
            poolIdB: 12,
            tickSpacing: 60,
            swapFee: 3000,
            sqrtPriceX96: 79228162514264337593543950336,
            startTime: 100,
            endTime: 200
        });

        LibClAuctionStorage.MintClPositionParams memory mintParams = LibClAuctionStorage.MintClPositionParams({
            auctionId: 1,
            positionId: 2,
            tickLower: -120,
            tickUpper: 120,
            amount0Desired: 10,
            amount1Desired: 20,
            amount0Min: 9,
            amount1Min: 19
        });

        LibClAuctionStorage.IncreaseClLiquidityParams memory increaseParams =
            LibClAuctionStorage.IncreaseClLiquidityParams({
                clPositionId: 9,
                amount0Desired: 30,
                amount1Desired: 40,
                amount0Min: 29,
                amount1Min: 39
            });

        LibClAuctionStorage.DecreaseClLiquidityParams memory decreaseParams =
            LibClAuctionStorage.DecreaseClLiquidityParams({clPositionId: 9, liquidity: 7, amount0Min: 1, amount1Min: 2});

        LibClAuctionStorage.CollectClFeesParams memory collectParams =
            LibClAuctionStorage.CollectClFeesParams({clPositionId: 9, amount0Max: 100, amount1Max: 200});

        return keccak256(abi.encode(createParams, mintParams, increaseParams, decreaseParams, collectParams));
    }
}

contract LibClPositionTest is Test {
    uint256 internal constant Q128 = 0x100000000000000000000000000000000;

    LibClPositionHarness internal h;

    function setUp() public {
        h = new LibClPositionHarness();
    }

    function test_storageAccessor_roundTrip() public {
        h.setStorageConfig(true, true, 1234, address(0xBEEF));
        (bool creationEnabled, bool swapPaused, uint24 swapFeeCap, address manager) = h.getStorageConfig();

        assertTrue(creationEnabled);
        assertTrue(swapPaused);
        assertEq(swapFeeCap, 1234);
        assertEq(manager, address(0xBEEF));

        h.setStorageRoundTripFields(42, -10, 9, 777, 111, 222, 60, true, 3, 0xDEAD);
        (
            int24 tick,
            uint256 sourcePositionId,
            uint256 lockA,
            uint256 lockB,
            bool spacingAllowed,
            uint256 bitmapWord
        ) = h.getStorageRoundTripFields(42, 9, 60, 3);

        assertEq(tick, -10);
        assertEq(sourcePositionId, 777);
        assertEq(lockA, 111);
        assertEq(lockB, 222);
        assertTrue(spacingAllowed);
        assertEq(bitmapWord, 0xDEAD);
    }

    function test_paramStructs_existAndEncode() public {
        assertTrue(h.hashParamStructs() != bytes32(0));
    }

    function test_getFeeGrowthInside_currentInsideRange() public {
        uint256 auctionId = 1;
        h.setTickInfo(auctionId, -10, 10, 20, true);
        h.setTickInfo(auctionId, 10, 30, 50, true);

        (uint256 inside0, uint256 inside1) = h.getFeeGrowthInside(auctionId, -10, 10, 0, 100, 200);
        assertEq(inside0, 60);
        assertEq(inside1, 130);
    }

    function test_getFeeGrowthInside_currentAboveRange() public {
        uint256 auctionId = 2;
        h.setTickInfo(auctionId, -10, 10, 20, true);
        h.setTickInfo(auctionId, 10, 70, 150, true);

        (uint256 inside0, uint256 inside1) = h.getFeeGrowthInside(auctionId, -10, 10, 12, 100, 200);
        assertEq(inside0, 60);
        assertEq(inside1, 130);
    }

    function test_updatePosition_accruesFeesAndUpdatesLiquidity() public {
        uint256 auctionId = 3;
        uint256 clPositionId = 33;

        h.setAuction(auctionId, 0, 3 * Q128, 2 * Q128);
        h.setTickInfo(auctionId, -10, 0, 0, true);
        h.setTickInfo(auctionId, 10, 0, 0, true);
        h.setPosition(clPositionId, auctionId, -10, 10, 10, 0, 0, 0, 0);

        (uint128 liquidity, uint256 fee0, uint256 fee1, uint128 owed0, uint128 owed1) = h.updatePosition(clPositionId, 5);

        assertEq(liquidity, 15);
        assertEq(fee0, 3 * Q128);
        assertEq(fee1, 2 * Q128);
        assertEq(owed0, 30);
        assertEq(owed1, 20);
    }

    function test_updatePosition_zeroDeltaOnlyAccrues() public {
        uint256 auctionId = 4;
        uint256 clPositionId = 44;

        h.setAuction(auctionId, 0, 1 * Q128, 1 * Q128);
        h.setTickInfo(auctionId, -5, 0, 0, true);
        h.setTickInfo(auctionId, 5, 0, 0, true);
        h.setPosition(clPositionId, auctionId, -5, 5, 7, 0, 0, 1, 2);

        (uint128 liquidity,, , uint128 owed0, uint128 owed1) = h.updatePosition(clPositionId, 0);

        assertEq(liquidity, 7);
        assertEq(owed0, 8);
        assertEq(owed1, 9);
    }

    function test_updatePosition_revertsOnLiquidityUnderflow() public {
        uint256 auctionId = 5;
        uint256 clPositionId = 55;

        h.setAuction(auctionId, 0, 0, 0);
        h.setTickInfo(auctionId, -1, 0, 0, true);
        h.setTickInfo(auctionId, 1, 0, 0, true);
        h.setPosition(clPositionId, auctionId, -1, 1, 5, 0, 0, 0, 0);

        vm.expectRevert(abi.encodeWithSelector(ClAuction_LiquidityUnderflow.selector, uint128(6), uint128(5)));
        h.updatePosition(clPositionId, -6);
    }

    function test_clAuctionErrors_selectorsPresent() public {
        assertEq(ClAuction_NotActive.selector, bytes4(keccak256("ClAuction_NotActive(uint256)")));
        assertEq(
            ClAuction_InvalidTickRange.selector,
            bytes4(keccak256("ClAuction_InvalidTickRange(int24,int24)"))
        );
        assertEq(
            ClAuction_InputAmountMismatch.selector,
            bytes4(keccak256("ClAuction_InputAmountMismatch(uint256,uint256)"))
        );
    }
}
