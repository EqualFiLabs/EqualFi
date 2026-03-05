// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LibClAuctionStorage} from "src/libraries/LibClAuctionStorage.sol";
import {
    ClAuction_CreationDisabled,
    ClAuction_InvalidSwapFee,
    ClAuction_InvalidTickSpacing,
    ClAuction_Paused
} from "src/libraries/ClAuctionErrors.sol";
import {ClTestBase} from "test/cl-auction/helpers/ClTestBase.sol";

contract ClCommunityAuctionGovernanceIntegration is ClTestBase {
    address internal constant TIMELOCK = address(0xBEEF1234);

    function setUp() public {
        setUpBase();
        clHarness.setTimelock(TIMELOCK);
    }

    function test_adminGovernance_enableDisableCreation_feeCap_tickSpacing_pauseUnpause() public {
        vm.prank(address(this));
        clAdmin.setClCreationEnabled(false);

        vm.prank(ALICE);
        vm.expectRevert(ClAuction_CreationDisabled.selector);
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

        vm.prank(TIMELOCK);
        clAdmin.setClCreationEnabled(true);

        vm.prank(address(this));
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

        vm.prank(TIMELOCK);
        clAdmin.setClSwapFeeCap(100_000);

        vm.prank(address(this));
        clAdmin.setClTickSpacingAllowed(60, false);

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(ClAuction_InvalidTickSpacing.selector, 60));
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

        vm.prank(TIMELOCK);
        clAdmin.setClTickSpacingAllowed(60, true);

        uint256 auctionId = _createActiveAuction();
        _mintDefaultPosition(auctionId);

        tokenA.mint(TRADER, 100e18);
        vm.prank(TRADER);
        tokenA.approve(address(diamond), type(uint256).max);

        vm.prank(address(this));
        clAdmin.setClSwapPaused(true);

        vm.prank(TRADER);
        vm.expectRevert(ClAuction_Paused.selector);
        cl.swapExactIn(auctionId, address(tokenA), 100e18, 0, TRADER);

        vm.prank(TIMELOCK);
        clAdmin.setClSwapPaused(false);

        vm.prank(TRADER);
        uint256 amountOut = cl.swapExactIn(auctionId, address(tokenA), 100e18, 0, TRADER);
        assertGt(amountOut, 0);
    }
}
