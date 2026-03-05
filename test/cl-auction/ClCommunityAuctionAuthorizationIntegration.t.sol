// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LibClAuctionStorage} from "src/libraries/LibClAuctionStorage.sol";
import {ClAuction_Unauthorized} from "src/libraries/ClAuctionErrors.sol";
import {ClTestBase} from "test/cl-auction/helpers/ClTestBase.sol";

contract ClCommunityAuctionAuthorizationIntegration is ClTestBase {
    function setUp() public {
        setUpBase();
    }

    function test_ownerExecutionPaths_forAuthorizedMutations() public {
        uint256 futureAuctionId = _createFutureAuction();

        vm.prank(ALICE);
        cl.cancelClCommunityAuction(futureAuctionId);

        uint256 auctionId = _createActiveAuction();

        vm.prank(ALICE);
        (uint256 clPositionId,,,) = cl.mintClPosition(
            LibClAuctionStorage.MintClPositionParams({
                auctionId: auctionId,
                positionId: sourcePositionId,
                tickLower: -120,
                tickUpper: 120,
                amount0Desired: 120e18,
                amount1Desired: 120e18,
                amount0Min: 0,
                amount1Min: 0
            })
        );

        vm.prank(ALICE);
        cl.increaseClLiquidity(
            LibClAuctionStorage.IncreaseClLiquidityParams({
                clPositionId: clPositionId,
                amount0Desired: 20e18,
                amount1Desired: 20e18,
                amount0Min: 0,
                amount1Min: 0
            })
        );

        tokenA.mint(TRADER, 200e18);
        vm.prank(TRADER);
        tokenA.approve(address(diamond), type(uint256).max);
        vm.prank(TRADER);
        cl.swapExactIn(auctionId, address(tokenA), 120e18, 0, TRADER);

        vm.prank(ALICE);
        cl.collectClFees(
            LibClAuctionStorage.CollectClFeesParams({
                clPositionId: clPositionId,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        uint128 liquidityToRemove = clView.getClPosition(clPositionId).liquidity;

        vm.prank(ALICE);
        cl.decreaseClLiquidity(
            LibClAuctionStorage.DecreaseClLiquidityParams({
                clPositionId: clPositionId,
                liquidity: liquidityToRemove,
                amount0Min: 0,
                amount1Min: 0
            })
        );

        vm.prank(ALICE);
        cl.collectClFees(
            LibClAuctionStorage.CollectClFeesParams({
                clPositionId: clPositionId,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        vm.prank(ALICE);
        cl.burnClPosition(clPositionId);
    }

    function test_approvedOperatorExecutionPaths_forAuthorizedMutations() public {
        vm.prank(ALICE);
        positionNft.approve(BOB, sourcePositionId);

        uint256 futureAuctionId = _createFutureAuction();

        vm.prank(BOB);
        cl.cancelClCommunityAuction(futureAuctionId);

        uint256 auctionId = _createActiveAuction();

        vm.prank(BOB);
        (uint256 clPositionId,,,) = cl.mintClPosition(
            LibClAuctionStorage.MintClPositionParams({
                auctionId: auctionId,
                positionId: sourcePositionId,
                tickLower: -120,
                tickUpper: 120,
                amount0Desired: 100e18,
                amount1Desired: 100e18,
                amount0Min: 0,
                amount1Min: 0
            })
        );

        vm.prank(BOB);
        cl.increaseClLiquidity(
            LibClAuctionStorage.IncreaseClLiquidityParams({
                clPositionId: clPositionId,
                amount0Desired: 20e18,
                amount1Desired: 20e18,
                amount0Min: 0,
                amount1Min: 0
            })
        );

        tokenA.mint(TRADER, 200e18);
        vm.prank(TRADER);
        tokenA.approve(address(diamond), type(uint256).max);
        vm.prank(TRADER);
        cl.swapExactIn(auctionId, address(tokenA), 100e18, 0, TRADER);

        vm.prank(BOB);
        cl.collectClFees(
            LibClAuctionStorage.CollectClFeesParams({
                clPositionId: clPositionId,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        uint128 liquidityToRemove = clView.getClPosition(clPositionId).liquidity;

        vm.prank(BOB);
        cl.decreaseClLiquidity(
            LibClAuctionStorage.DecreaseClLiquidityParams({
                clPositionId: clPositionId,
                liquidity: liquidityToRemove,
                amount0Min: 0,
                amount1Min: 0
            })
        );

        vm.prank(BOB);
        cl.collectClFees(
            LibClAuctionStorage.CollectClFeesParams({
                clPositionId: clPositionId,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        vm.prank(BOB);
        cl.burnClPosition(clPositionId);
    }

    function test_tbaExecutionPaths_forAuthorizedMutations() public {
        address tba = _expectedTbaAddress(sourcePositionId);

        vm.prank(tba);
        uint256 futureAuctionId = cl.createClCommunityAuction(
            LibClAuctionStorage.CreateClAuctionParams({
                positionId: sourcePositionId,
                poolIdA: POOL_A,
                poolIdB: POOL_B,
                tickSpacing: 60,
                swapFee: 3_000,
                sqrtPriceX96: 79228162514264337593543950336,
                startTime: uint64(block.timestamp + 1 hours),
                endTime: uint64(block.timestamp + 2 hours)
            })
        );

        vm.prank(tba);
        cl.cancelClCommunityAuction(futureAuctionId);

        vm.prank(tba);
        uint256 auctionId = cl.createClCommunityAuction(
            LibClAuctionStorage.CreateClAuctionParams({
                positionId: sourcePositionId,
                poolIdA: POOL_A,
                poolIdB: POOL_B,
                tickSpacing: 60,
                swapFee: 3_000,
                sqrtPriceX96: 79228162514264337593543950336,
                startTime: uint64(block.timestamp),
                endTime: uint64(block.timestamp + 1 days)
            })
        );

        vm.prank(tba);
        (uint256 clPositionId,,,) = cl.mintClPosition(
            LibClAuctionStorage.MintClPositionParams({
                auctionId: auctionId,
                positionId: sourcePositionId,
                tickLower: -120,
                tickUpper: 120,
                amount0Desired: 100e18,
                amount1Desired: 100e18,
                amount0Min: 0,
                amount1Min: 0
            })
        );

        vm.prank(tba);
        cl.increaseClLiquidity(
            LibClAuctionStorage.IncreaseClLiquidityParams({
                clPositionId: clPositionId,
                amount0Desired: 20e18,
                amount1Desired: 20e18,
                amount0Min: 0,
                amount1Min: 0
            })
        );

        tokenA.mint(TRADER, 200e18);
        vm.prank(TRADER);
        tokenA.approve(address(diamond), type(uint256).max);
        vm.prank(TRADER);
        cl.swapExactIn(auctionId, address(tokenA), 100e18, 0, TRADER);

        vm.prank(tba);
        cl.collectClFees(
            LibClAuctionStorage.CollectClFeesParams({
                clPositionId: clPositionId,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        uint128 liquidityToRemove = clView.getClPosition(clPositionId).liquidity;

        vm.prank(tba);
        cl.decreaseClLiquidity(
            LibClAuctionStorage.DecreaseClLiquidityParams({
                clPositionId: clPositionId,
                liquidity: liquidityToRemove,
                amount0Min: 0,
                amount1Min: 0
            })
        );

        vm.prank(tba);
        cl.collectClFees(
            LibClAuctionStorage.CollectClFeesParams({
                clPositionId: clPositionId,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        vm.prank(tba);
        cl.burnClPosition(clPositionId);
    }

    function test_unauthorizedCallerReverts_forEachMutation() public {
        vm.prank(RANDO);
        vm.expectRevert(abi.encodeWithSelector(ClAuction_Unauthorized.selector, RANDO, sourcePositionId));
        cl.createClCommunityAuction(
            LibClAuctionStorage.CreateClAuctionParams({
                positionId: sourcePositionId,
                poolIdA: POOL_A,
                poolIdB: POOL_B,
                tickSpacing: 60,
                swapFee: 3_000,
                sqrtPriceX96: 79228162514264337593543950336,
                startTime: uint64(block.timestamp),
                endTime: uint64(block.timestamp + 1 days)
            })
        );

        uint256 futureAuctionId = _createFutureAuction();

        vm.prank(RANDO);
        vm.expectRevert(abi.encodeWithSelector(ClAuction_Unauthorized.selector, RANDO, sourcePositionId));
        cl.cancelClCommunityAuction(futureAuctionId);

        uint256 auctionId = _createActiveAuction();

        vm.prank(RANDO);
        vm.expectRevert(abi.encodeWithSelector(ClAuction_Unauthorized.selector, RANDO, sourcePositionId));
        cl.mintClPosition(
            LibClAuctionStorage.MintClPositionParams({
                auctionId: auctionId,
                positionId: sourcePositionId,
                tickLower: -120,
                tickUpper: 120,
                amount0Desired: 100e18,
                amount1Desired: 100e18,
                amount0Min: 0,
                amount1Min: 0
            })
        );

        (uint256 clPositionId,,,) = _mintDefaultPosition(auctionId);

        vm.prank(RANDO);
        vm.expectRevert(abi.encodeWithSelector(ClAuction_Unauthorized.selector, RANDO, sourcePositionId));
        cl.increaseClLiquidity(
            LibClAuctionStorage.IncreaseClLiquidityParams({
                clPositionId: clPositionId,
                amount0Desired: 1,
                amount1Desired: 1,
                amount0Min: 0,
                amount1Min: 0
            })
        );

        vm.prank(RANDO);
        vm.expectRevert(abi.encodeWithSelector(ClAuction_Unauthorized.selector, RANDO, sourcePositionId));
        cl.decreaseClLiquidity(
            LibClAuctionStorage.DecreaseClLiquidityParams({
                clPositionId: clPositionId,
                liquidity: 1,
                amount0Min: 0,
                amount1Min: 0
            })
        );

        vm.prank(RANDO);
        vm.expectRevert(abi.encodeWithSelector(ClAuction_Unauthorized.selector, RANDO, sourcePositionId));
        cl.collectClFees(
            LibClAuctionStorage.CollectClFeesParams({
                clPositionId: clPositionId,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        vm.prank(RANDO);
        vm.expectRevert(abi.encodeWithSelector(ClAuction_Unauthorized.selector, RANDO, sourcePositionId));
        cl.burnClPosition(clPositionId);
    }
}
