// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LibClAuctionStorage} from "src/libraries/LibClAuctionStorage.sol";
import {ClTestBase} from "test/cl-auction/helpers/ClTestBase.sol";

contract ClCommunityAuctionLifecycleIntegration is ClTestBase {
    event ClCommunityAuctionCreated(
        uint256 indexed auctionId,
        bytes32 indexed creatorPositionKey,
        uint256 indexed positionId,
        uint256 poolIdA,
        uint256 poolIdB,
        address tokenA,
        address tokenB,
        uint24 tickSpacing,
        uint24 swapFee,
        uint160 sqrtPriceX96,
        int24 tick,
        uint64 startTime,
        uint64 endTime
    );

    event ClPositionMinted(
        uint256 indexed clPositionId,
        uint256 indexed auctionId,
        uint256 indexed sourcePositionId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1,
        address tba
    );

    event ClLiquidityDecreased(
        uint256 indexed clPositionId,
        uint128 liquidityDelta,
        uint128 liquidityAfter,
        uint256 amount0,
        uint256 amount1
    );

    event ClFeesCollected(uint256 indexed clPositionId, uint256 amount0, uint256 amount1);
    event ClPositionBurned(uint256 indexed clPositionId);
    event ClCommunityAuctionFinalized(uint256 indexed auctionId);
    event ClSwap(
        uint256 indexed auctionId,
        address indexed sender,
        address indexed tokenIn,
        uint256 amountIn,
        uint256 amountOut,
        address recipient
    );

    function setUp() public {
        setUpBase();
    }

    function test_fullLifecycle_createMintSwapCollectDecreaseBurnFinalize_withEvents() public {
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = uint64(block.timestamp + 1 days);

        vm.expectEmit(true, true, true, false, address(diamond));
        emit ClCommunityAuctionCreated(
            1,
            sourcePositionKey,
            sourcePositionId,
            POOL_A,
            POOL_B,
            address(tokenA),
            address(tokenB),
            60,
            3_000,
            79228162514264337593543950336,
            0,
            startTime,
            endTime
        );

        uint256 auctionId = _createAuction(startTime, endTime, POOL_A, POOL_B);
        assertEq(auctionId, 1);

        vm.expectEmit(false, true, true, false, address(diamond));
        emit ClPositionMinted(0, auctionId, sourcePositionId, 0, 0, 0, 0, 0, address(0));

        (uint256 clPositionId, uint128 mintedLiquidity,,) = _mintDefaultPosition(auctionId);
        assertGt(mintedLiquidity, 0);

        tokenA.mint(TRADER, 400e18);
        vm.prank(TRADER);
        tokenA.approve(address(diamond), type(uint256).max);

        vm.expectEmit(true, true, true, false, address(diamond));
        emit ClSwap(auctionId, TRADER, address(tokenA), 250e18, 0, TRADER);

        vm.prank(TRADER);
        uint256 amountOut = cl.swapExactIn(auctionId, address(tokenA), 250e18, 0, TRADER);
        assertGt(amountOut, 0);

        vm.expectEmit(true, false, false, false, address(diamond));
        emit ClFeesCollected(clPositionId, 0, 0);

        vm.prank(ALICE);
        cl.collectClFees(
            LibClAuctionStorage.CollectClFeesParams({
                clPositionId: clPositionId,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        uint128 liquidityToRemove = clView.getClPosition(clPositionId).liquidity;

        vm.expectEmit(true, false, false, false, address(diamond));
        emit ClLiquidityDecreased(clPositionId, 0, 0, 0, 0);

        vm.prank(ALICE);
        cl.decreaseClLiquidity(
            LibClAuctionStorage.DecreaseClLiquidityParams({
                clPositionId: clPositionId,
                liquidity: liquidityToRemove,
                amount0Min: 0,
                amount1Min: 0
            })
        );

        vm.expectEmit(true, false, false, false, address(diamond));
        emit ClPositionBurned(clPositionId);

        vm.prank(ALICE);
        cl.burnClPosition(clPositionId);

        vm.expectRevert();
        clPositionManager.ownerOf(clPositionId);

        vm.warp(endTime + 1);

        vm.expectEmit(true, false, false, false, address(diamond));
        emit ClCommunityAuctionFinalized(auctionId);

        cl.finalizeClCommunityAuction(auctionId);

        LibClAuctionStorage.ClCommunityAuction memory auction = clView.getClAuction(auctionId);
        assertTrue(auction.finalized);
    }
}
