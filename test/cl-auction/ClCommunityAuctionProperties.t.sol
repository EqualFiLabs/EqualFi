// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {LibClAuctionStorage} from "src/libraries/LibClAuctionStorage.sol";
import {
    ClAuction_NotActive,
    ClAuction_Unauthorized,
    ClAuction_InputAmountMismatch
} from "src/libraries/ClAuctionErrors.sol";
import {ClTestBase} from "test/cl-auction/helpers/ClTestBase.sol";

contract FeeOnTransferToken is ERC20 {
    uint256 internal constant FEE_BPS = 100; // 1%

    constructor() ERC20("FeeToken", "FEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _spendAllowance(from, _msgSender(), amount);

        uint256 fee = (amount * FEE_BPS) / 10_000;
        uint256 receiveAmount = amount - fee;

        _transfer(from, to, receiveAmount);
        if (fee > 0) {
            _burn(from, fee);
        }
        return true;
    }
}

contract ClCommunityAuctionProperties is ClTestBase {
    function setUp() public {
        setUpBase();
    }

    /// @notice Property 1: Auction creation field consistency
    function testFuzz_property1_auctionCreationFieldConsistency(uint256 feeSeed, uint256 delaySeed, uint256 durationSeed)
        public
    {
        uint24 swapFee = uint24(bound(feeSeed, 1, 100_000));
        uint64 delay = uint64(bound(delaySeed, 0, 30 days));
        uint64 duration = uint64(bound(durationSeed, 1 hours, 30 days));

        vm.prank(ALICE);
        uint256 auctionId = cl.createClCommunityAuction(
            LibClAuctionStorage.CreateClAuctionParams({
                positionId: sourcePositionId,
                poolIdA: POOL_A,
                poolIdB: POOL_B,
                tickSpacing: 60,
                swapFee: swapFee,
                sqrtPriceX96: 79228162514264337593543950336,
                startTime: uint64(block.timestamp + delay),
                endTime: uint64(block.timestamp + delay + duration)
            })
        );

        LibClAuctionStorage.ClCommunityAuction memory auction = clView.getClAuction(auctionId);
        assertEq(auction.auctionId, auctionId);
        assertEq(auction.poolIdA, POOL_A);
        assertEq(auction.poolIdB, POOL_B);
        assertEq(auction.tokenA, address(tokenA));
        assertEq(auction.tokenB, address(tokenB));
        assertEq(auction.tickSpacing, 60);
        assertEq(auction.swapFee, swapFee);
        assertEq(auction.sqrtPriceX96, 79228162514264337593543950336);
        assertEq(auction.startTime, uint64(block.timestamp + delay));
        assertEq(auction.endTime, uint64(block.timestamp + delay + duration));
        assertEq(auction.creatorPositionId, sourcePositionId);
        assertEq(auction.creatorPositionKey, sourcePositionKey);
        assertTrue(auction.initialized);
        assertFalse(auction.cancelled);
        assertFalse(auction.finalized);
    }

    /// @notice Property 2: Cancel before start marks auction cancelled
    function test_property2_cancelBeforeStart_marksCancelled() public {
        uint256 auctionId = _createFutureAuction();

        vm.prank(ALICE);
        cl.cancelClCommunityAuction(auctionId);

        LibClAuctionStorage.ClCommunityAuction memory auction = clView.getClAuction(auctionId);
        assertTrue(auction.cancelled);
        assertFalse(auction.finalized);
    }

    /// @notice Property 3: Mint position correctness
    function testFuzz_property3_mintPositionCorrectness(uint256 amount0Seed, uint256 amount1Seed) public {
        uint256 amount0Desired = bound(amount0Seed, 1e12, 500e18);
        uint256 amount1Desired = bound(amount1Seed, 1e12, 500e18);

        uint256 auctionId = _createActiveAuction();

        vm.prank(ALICE);
        (uint256 clPositionId, uint128 liquidity, uint256 amount0, uint256 amount1) = cl.mintClPosition(
            LibClAuctionStorage.MintClPositionParams({
                auctionId: auctionId,
                positionId: sourcePositionId,
                tickLower: -120,
                tickUpper: 120,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: 0,
                amount1Min: 0
            })
        );

        LibClAuctionStorage.ClPosition memory position = clView.getClPosition(clPositionId);
        assertEq(position.auctionId, auctionId);
        assertEq(position.sourcePositionId, sourcePositionId);
        assertEq(position.tickLower, -120);
        assertEq(position.tickUpper, 120);
        assertEq(position.liquidity, liquidity);
        assertGt(position.liquidity, 0);
        assertLe(amount0, amount0Desired);
        assertLe(amount1, amount1Desired);
    }

    /// @notice Property 4: Lazy TBA deployment
    function test_property4_lazyTbaDeployment() public {
        uint256 auctionId = _createActiveAuction();
        address tba = _expectedTbaAddress(sourcePositionId);

        assertEq(tba.code.length, 0);
        assertFalse(clHarness.getTbaDeployed(sourcePositionId));

        (uint256 clPositionId,,,) = _mintDefaultPosition(auctionId);

        assertGt(tba.code.length, 0);
        assertTrue(clHarness.getTbaDeployed(sourcePositionId));
        assertEq(clPositionManager.ownerOf(clPositionId), tba);
    }

    /// @notice Property 5: CL NFT custody
    function test_property5_clNftCustody() public {
        uint256 auctionId = _createActiveAuction();
        (uint256 clPositionId,,,) = _mintDefaultPosition(auctionId);

        address tba = _expectedTbaAddress(sourcePositionId);
        assertEq(clPositionManager.ownerOf(clPositionId), tba);
        assertTrue(clPositionManager.ownerOf(clPositionId) != ALICE);
    }

    /// @notice Property 6: Increase liquidity correctness
    function test_property6_increaseLiquidityCorrectness() public {
        uint256 auctionId = _createActiveAuction();
        (uint256 clPositionId,,,) = _mintDefaultPosition(auctionId);

        LibClAuctionStorage.ClPosition memory beforePosition = clView.getClPosition(clPositionId);
        (uint256 lockABefore, uint256 lockBBefore) = clView.getClEncumbranceLock(clPositionId);

        vm.prank(ALICE);
        (uint128 addedLiquidity, uint256 amount0, uint256 amount1) = cl.increaseClLiquidity(
            LibClAuctionStorage.IncreaseClLiquidityParams({
                clPositionId: clPositionId,
                amount0Desired: 50e18,
                amount1Desired: 50e18,
                amount0Min: 0,
                amount1Min: 0
            })
        );

        LibClAuctionStorage.ClPosition memory afterPosition = clView.getClPosition(clPositionId);
        (uint256 lockAAfter, uint256 lockBAfter) = clView.getClEncumbranceLock(clPositionId);

        assertGt(addedLiquidity, 0);
        assertGt(amount0 + amount1, 0);
        assertGt(afterPosition.liquidity, beforePosition.liquidity);
        assertGe(lockAAfter, lockABefore);
        assertGe(lockBAfter, lockBBefore);
    }

    /// @notice Property 7: Swap execution and tick crossing
    function test_property7_swapExecutionAndTickCrossing() public {
        uint256 auctionId = _createActiveAuction();
        _mintDefaultPosition(auctionId);

        tokenA.mint(TRADER, 1_000e18);
        vm.prank(TRADER);
        tokenA.approve(address(diamond), type(uint256).max);

        (uint160 sqrtBefore, int24 tickBefore,) = clView.getClPoolState(auctionId);

        vm.prank(TRADER);
        uint256 amountOut = cl.swapExactIn(auctionId, address(tokenA), 500e18, 0, TRADER);

        (uint160 sqrtAfter, int24 tickAfter,) = clView.getClPoolState(auctionId);

        assertGt(amountOut, 0);
        assertLt(sqrtAfter, sqrtBefore);
        assertLt(tickAfter, tickBefore);
    }

    /// @notice Property 8: Swap fee conservation
    function test_property8_swapFeeConservation() public {
        uint256 auctionId = _createActiveAuction();
        _mintDefaultPosition(auctionId);

        tokenA.mint(TRADER, 250e18);
        vm.prank(TRADER);
        tokenA.approve(address(diamond), type(uint256).max);

        uint256 preTraderIn = tokenA.balanceOf(TRADER);
        uint256 preDiamondIn = tokenA.balanceOf(address(diamond));

        vm.prank(TRADER);
        uint256 amountOut = cl.swapExactIn(auctionId, address(tokenA), 250e18, 0, TRADER);

        uint256 postTraderIn = tokenA.balanceOf(TRADER);
        uint256 postDiamondIn = tokenA.balanceOf(address(diamond));

        uint256 traderSpent = preTraderIn - postTraderIn;
        uint256 diamondNetIn = postDiamondIn - preDiamondIn;

        assertGt(amountOut, 0);
        assertEq(traderSpent, diamondNetIn);
        assertLe(traderSpent, 250e18);
    }

    /// @notice Property 9: Swap protocol fee routing
    function test_property9_swapProtocolFeeRouting() public {
        uint256 auctionId = _createActiveAuction();
        _mintDefaultPosition(auctionId);

        LibClAuctionStorage.ClCommunityAuction memory beforeAuction = clView.getClAuction(auctionId);
        uint256 preYieldReserve = clHarness.getPoolYieldReserve(POOL_A);
        uint256 preTracked = clHarness.getPoolTrackedBalance(POOL_A);

        tokenA.mint(TRADER, 1_000e18);
        vm.prank(TRADER);
        tokenA.approve(address(diamond), type(uint256).max);

        vm.prank(TRADER);
        cl.swapExactIn(auctionId, address(tokenA), 1_000e18, 0, TRADER);

        LibClAuctionStorage.ClCommunityAuction memory afterAuction = clView.getClAuction(auctionId);
        uint256 postYieldReserve = clHarness.getPoolYieldReserve(POOL_A);
        uint256 postTracked = clHarness.getPoolTrackedBalance(POOL_A);

        assertEq(afterAuction.protocolFees0, beforeAuction.protocolFees0);
        assertGt(postYieldReserve, preYieldReserve);
        assertGt(postTracked, preTracked);
    }

    /// @notice Property 10: Decrease liquidity and encumbrance unlock
    function test_property10_decreaseLiquidityAndEncumbranceUnlock() public {
        uint256 auctionId = _createActiveAuction();
        (uint256 clPositionId,,,) = _mintDefaultPosition(auctionId);

        (uint256 lockABefore, uint256 lockBBefore) = clView.getClEncumbranceLock(clPositionId);
        assertGt(lockABefore + lockBBefore, 0);

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

        (uint256 lockAAfter, uint256 lockBAfter) = clView.getClEncumbranceLock(clPositionId);
        assertEq(lockAAfter, 0);
        assertEq(lockBAfter, 0);

        assertEq(clHarness.getModuleEncumbered(sourcePositionKey, POOL_A), 0);
        assertEq(clHarness.getModuleEncumbered(sourcePositionKey, POOL_B), 0);
        assertEq(clHarness.getModuleEncumberedForModule(sourcePositionKey, POOL_A, CL_COMMUNITY_AUCTION_MODULE_ID), 0);
        assertEq(clHarness.getModuleEncumberedForModule(sourcePositionKey, POOL_B, CL_COMMUNITY_AUCTION_MODULE_ID), 0);
    }

    /// @notice Property 11: Fee collection and settlement correctness
    function test_property11_feeCollectionAndSettlementCorrectness() public {
        uint256 auctionId = _createActiveAuction();
        (uint256 clPositionId,,,) = _mintDefaultPosition(auctionId);

        tokenA.mint(TRADER, 500e18);
        vm.prank(TRADER);
        tokenA.approve(address(diamond), type(uint256).max);
        vm.prank(TRADER);
        cl.swapExactIn(auctionId, address(tokenA), 500e18, 0, TRADER);

        uint256 yieldBeforeA = clHarness.getUserYield(POOL_A, sourcePositionKey);
        uint256 yieldBeforeB = clHarness.getUserYield(POOL_B, sourcePositionKey);

        vm.prank(ALICE);
        (uint256 collected0, uint256 collected1) = cl.collectClFees(
            LibClAuctionStorage.CollectClFeesParams({
                clPositionId: clPositionId,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        assertGt(collected0 + collected1, 0);
        assertGe(clHarness.getUserYield(POOL_A, sourcePositionKey) - yieldBeforeA, collected0);
        assertGe(clHarness.getUserYield(POOL_B, sourcePositionKey) - yieldBeforeB, collected1);
    }

    /// @notice Property 12: Burn clears position
    function test_property12_burnClearsPosition() public {
        uint256 auctionId = _createActiveAuction();
        (uint256 clPositionId,,,) = _mintDefaultPosition(auctionId);

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

        vm.expectRevert();
        clPositionManager.ownerOf(clPositionId);

        LibClAuctionStorage.ClPosition memory position = clView.getClPosition(clPositionId);
        assertEq(position.sourcePositionId, 0);

        (uint256 lockA, uint256 lockB) = clView.getClEncumbranceLock(clPositionId);
        assertEq(lockA, 0);
        assertEq(lockB, 0);
    }

    /// @notice Property 13: Finalization disables swaps
    function test_property13_finalizationDisablesSwaps() public {
        uint256 auctionId = _createActiveAuction();
        _mintDefaultPosition(auctionId);

        uint64 endTime = clView.getClAuction(auctionId).endTime;
        vm.warp(endTime + 1);
        cl.finalizeClCommunityAuction(auctionId);

        tokenA.mint(TRADER, 100e18);
        vm.prank(TRADER);
        tokenA.approve(address(diamond), type(uint256).max);

        vm.prank(TRADER);
        vm.expectRevert(abi.encodeWithSelector(ClAuction_NotActive.selector, auctionId));
        cl.swapExactIn(auctionId, address(tokenA), 100e18, 0, TRADER);
    }

    /// @notice Property 14: Post-finalization operations permitted
    function test_property14_postFinalizationOperationsPermitted() public {
        uint256 auctionId = _createActiveAuction();
        (uint256 clPositionId,,,) = _mintDefaultPosition(auctionId);

        uint64 endTime = clView.getClAuction(auctionId).endTime;
        vm.warp(endTime + 1);
        cl.finalizeClCommunityAuction(auctionId);

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

        vm.expectRevert();
        clPositionManager.ownerOf(clPositionId);
    }

    /// @notice Property 15: No orphan encumbrance locks (lifecycle invariant)
    function test_property15_noOrphanEncumbranceLocksLifecycleInvariant() public {
        uint256 auctionId = _createActiveAuction();
        (uint256 clPositionId,,,) = _mintDefaultPosition(auctionId);

        vm.prank(ALICE);
        cl.increaseClLiquidity(
            LibClAuctionStorage.IncreaseClLiquidityParams({
                clPositionId: clPositionId,
                amount0Desired: 50e18,
                amount1Desired: 50e18,
                amount0Min: 0,
                amount1Min: 0
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

        (uint256 lockA, uint256 lockB) = clView.getClEncumbranceLock(clPositionId);
        assertEq(lockA, 0);
        assertEq(lockB, 0);
        assertEq(clHarness.getModuleEncumbered(sourcePositionKey, POOL_A), 0);
        assertEq(clHarness.getModuleEncumbered(sourcePositionKey, POOL_B), 0);
    }

    /// @notice Property 16: Access control
    function test_property16_accessControl() public {
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
            LibClAuctionStorage.CollectClFeesParams({clPositionId: clPositionId, amount0Max: type(uint128).max, amount1Max: type(uint128).max})
        );

        vm.prank(RANDO);
        vm.expectRevert(abi.encodeWithSelector(ClAuction_Unauthorized.selector, RANDO, sourcePositionId));
        cl.burnClPosition(clPositionId);
    }

    /// @notice Property 20: Uncollected fees view accuracy
    function test_property20_uncollectedFeesViewAccuracy() public {
        uint256 auctionId = _createActiveAuction();
        (uint256 clPositionId,,,) = _mintDefaultPosition(auctionId);

        tokenA.mint(TRADER, 1_000e18);
        vm.prank(TRADER);
        tokenA.approve(address(diamond), type(uint256).max);
        vm.prank(TRADER);
        cl.swapExactIn(auctionId, address(tokenA), 1_000e18, 0, TRADER);

        (uint256 preview0, uint256 preview1) = clView.getClUnclaimedFees(clPositionId);

        vm.prank(ALICE);
        (uint256 collected0, uint256 collected1) = cl.collectClFees(
            LibClAuctionStorage.CollectClFeesParams({
                clPositionId: clPositionId,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        assertEq(collected0, preview0);
        assertEq(collected1, preview1);
    }

    /// @notice Property 21: Exact-input balance-delta enforcement
    function test_property21_exactInputBalanceDeltaEnforcement() public {
        FeeOnTransferToken feeToken = new FeeOnTransferToken();
        uint256 feePoolId = 11;

        clHarness.seedPool(feePoolId, address(feeToken), sourcePositionKey, 2_000_000e18, 2_000_000e18);
        feeToken.mint(address(diamond), 2_000_000e18);

        uint256 auctionId = _createAuction(uint64(block.timestamp), uint64(block.timestamp + 1 days), feePoolId, POOL_B);

        vm.prank(ALICE);
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

        feeToken.mint(TRADER, 100e18);
        vm.prank(TRADER);
        feeToken.approve(address(diamond), 100e18);

        vm.prank(TRADER);
        vm.expectRevert(abi.encodeWithSelector(ClAuction_InputAmountMismatch.selector, 100e18, 99e18));
        cl.swapExactIn(auctionId, address(feeToken), 100e18, 0, TRADER);
    }
}
