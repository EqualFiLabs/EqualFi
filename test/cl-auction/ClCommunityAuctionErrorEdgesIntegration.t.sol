// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {LibClAuctionStorage} from "src/libraries/LibClAuctionStorage.sol";
import {
    ClAuction_NotActive,
    ClAuction_InvalidTickSpacing,
    ClAuction_InvalidSwapFee,
    ClAuction_InvalidSqrtPrice,
    ClAuction_InvalidTimeWindow,
    ClAuction_InsufficientPrincipal,
    ClAuction_PositionNotClear,
    ClAuction_Slippage,
    ClAuction_InputAmountMismatch,
    ClAuction_InvalidToken
} from "src/libraries/ClAuctionErrors.sol";
import {ClTestBase} from "test/cl-auction/helpers/ClTestBase.sol";

contract FeeOnTransferTokenEdge is ERC20 {
    uint256 internal constant FEE_BPS = 100; // 1%

    constructor() ERC20("FeeTokenEdge", "FEEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _spendAllowance(from, _msgSender(), amount);

        uint256 fee = (amount * FEE_BPS) / 10_000;
        uint256 receiveAmount = amount - fee;

        _transfer(from, to, receiveAmount);
        if (fee > 0) _burn(from, fee);
        return true;
    }
}

contract ClCommunityAuctionErrorEdgesIntegration is ClTestBase {
    function setUp() public {
        setUpBase();
    }

    function test_revert_invalidTickSpacing() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(ClAuction_InvalidTickSpacing.selector, 30));
        cl.createClCommunityAuction(
            LibClAuctionStorage.CreateClAuctionParams({
                positionId: sourcePositionId,
                poolIdA: POOL_A,
                poolIdB: POOL_B,
                tickSpacing: 30,
                swapFee: 3_000,
                sqrtPriceX96: 79228162514264337593543950336,
                startTime: uint64(block.timestamp),
                endTime: uint64(block.timestamp + 1 days)
            })
        );
    }

    function test_revert_feeCapExceeded() public {
        clAdmin.setClSwapFeeCap(1_000);

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(ClAuction_InvalidSwapFee.selector, 3_000, 1_000));
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
    }

    function test_revert_invalidSqrtPrice() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(ClAuction_InvalidSqrtPrice.selector, uint160(1)));
        cl.createClCommunityAuction(
            LibClAuctionStorage.CreateClAuctionParams({
                positionId: sourcePositionId,
                poolIdA: POOL_A,
                poolIdB: POOL_B,
                tickSpacing: 60,
                swapFee: 3_000,
                sqrtPriceX96: 1,
                startTime: uint64(block.timestamp),
                endTime: uint64(block.timestamp + 1 days)
            })
        );
    }

    function test_revert_badTimeWindow_startAfterEnd() public {
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                ClAuction_InvalidTimeWindow.selector,
                uint64(block.timestamp + 2 days),
                uint64(block.timestamp + 1 days)
            )
        );
        cl.createClCommunityAuction(
            LibClAuctionStorage.CreateClAuctionParams({
                positionId: sourcePositionId,
                poolIdA: POOL_A,
                poolIdB: POOL_B,
                tickSpacing: 60,
                swapFee: 3_000,
                sqrtPriceX96: 79228162514264337593543950336,
                startTime: uint64(block.timestamp + 2 days),
                endTime: uint64(block.timestamp + 1 days)
            })
        );
    }

    function test_revert_badTimeWindow_startInPast() public {
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                ClAuction_InvalidTimeWindow.selector,
                uint64(block.timestamp - 1),
                uint64(block.timestamp + 1 days)
            )
        );
        cl.createClCommunityAuction(
            LibClAuctionStorage.CreateClAuctionParams({
                positionId: sourcePositionId,
                poolIdA: POOL_A,
                poolIdB: POOL_B,
                tickSpacing: 60,
                swapFee: 3_000,
                sqrtPriceX96: 79228162514264337593543950336,
                startTime: uint64(block.timestamp - 1),
                endTime: uint64(block.timestamp + 1 days)
            })
        );
    }

    function test_revert_insufficientPrincipal() public {
        uint256 auctionId = _createActiveAuction();

        vm.prank(ALICE);
        vm.expectRevert();
        cl.mintClPosition(
            LibClAuctionStorage.MintClPositionParams({
                auctionId: auctionId,
                positionId: sourcePositionId,
                tickLower: -120,
                tickUpper: 120,
                amount0Desired: 100_000_000e18,
                amount1Desired: 100_000_000e18,
                amount0Min: 0,
                amount1Min: 0
            })
        );
    }

    function test_revert_positionNotClear_onBurn() public {
        uint256 auctionId = _createActiveAuction();
        (uint256 clPositionId,,,) = _mintDefaultPosition(auctionId);

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(ClAuction_PositionNotClear.selector, clPositionId));
        cl.burnClPosition(clPositionId);
    }

    function test_revert_slippage_onMint() public {
        uint256 auctionId = _createActiveAuction();

        vm.prank(ALICE);
        vm.expectRevert();
        cl.mintClPosition(
            LibClAuctionStorage.MintClPositionParams({
                auctionId: auctionId,
                positionId: sourcePositionId,
                tickLower: -120,
                tickUpper: 120,
                amount0Desired: 100e18,
                amount1Desired: 100e18,
                amount0Min: type(uint256).max,
                amount1Min: 0
            })
        );
    }

    function test_revert_slippage_onSwap() public {
        uint256 auctionId = _createActiveAuction();
        _mintDefaultPosition(auctionId);

        tokenA.mint(TRADER, 200e18);
        vm.prank(TRADER);
        tokenA.approve(address(diamond), type(uint256).max);

        vm.prank(TRADER);
        vm.expectRevert();
        cl.swapExactIn(auctionId, address(tokenA), 100e18, type(uint256).max, TRADER);
    }

    function test_revert_phaseViolations() public {
        uint256 futureAuctionId = _createFutureAuction();

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(ClAuction_NotActive.selector, futureAuctionId));
        cl.mintClPosition(
            LibClAuctionStorage.MintClPositionParams({
                auctionId: futureAuctionId,
                positionId: sourcePositionId,
                tickLower: -120,
                tickUpper: 120,
                amount0Desired: 100e18,
                amount1Desired: 100e18,
                amount0Min: 0,
                amount1Min: 0
            })
        );

        vm.warp(clView.getClAuction(futureAuctionId).startTime);

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(ClAuction_NotActive.selector, futureAuctionId));
        cl.cancelClCommunityAuction(futureAuctionId);

        vm.expectRevert(abi.encodeWithSelector(ClAuction_NotActive.selector, futureAuctionId));
        cl.finalizeClCommunityAuction(futureAuctionId);
    }

    function test_revert_invalidTokenInSwap() public {
        uint256 auctionId = _createActiveAuction();
        _mintDefaultPosition(auctionId);

        vm.prank(TRADER);
        vm.expectRevert(abi.encodeWithSelector(ClAuction_InvalidToken.selector, RANDO));
        cl.swapExactIn(auctionId, RANDO, 1e18, 0, TRADER);
    }

    function test_revert_balanceDeltaMismatch_feeOnTransfer() public {
        FeeOnTransferTokenEdge feeToken = new FeeOnTransferTokenEdge();
        uint256 feePoolId = 88;

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

    function test_revert_insufficientPrincipal_customErrorShape() public {
        uint256 auctionId = _createActiveAuction();

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(ClAuction_InsufficientPrincipal.selector, 3_000_000e18, 2_000_000e18));
        cl.mintClPosition(
            LibClAuctionStorage.MintClPositionParams({
                auctionId: auctionId,
                positionId: sourcePositionId,
                tickLower: -120,
                tickUpper: 120,
                amount0Desired: 3_000_000e18,
                amount1Desired: 3_000_000e18,
                amount0Min: 0,
                amount1Min: 0
            })
        );
    }
}
