// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

error ClAuction_NotActive(uint256 auctionId);
error ClAuction_Expired(uint256 auctionId);
error ClAuction_InvalidTickRange(int24 tickLower, int24 tickUpper);
error ClAuction_InvalidTickSpacing(uint24 tickSpacing);
error ClAuction_InvalidSqrtPrice(uint160 sqrtPriceX96);
error ClAuction_Slippage(uint256 amountOut, uint256 amountOutMin);
error ClAuction_Unauthorized(address caller, uint256 positionId);
error ClAuction_InsufficientPrincipal(uint256 required, uint256 available);
error ClAuction_PositionNotClear(uint256 clPositionId);
error ClAuction_Paused();
error ClAuction_CreationDisabled();
error ClAuction_AlreadyInitialized(uint256 auctionId);
error ClAuction_AlreadyFinalized(uint256 auctionId);
error ClAuction_NotFinalized(uint256 auctionId);
error ClAuction_InvalidTimeWindow(uint64 startTime, uint64 endTime);
error ClAuction_TBADeploymentFailed(address expected, address actual);
error ClAuction_LiquidityUnderflow(uint128 requested, uint128 available);
error ClAuction_InputAmountMismatch(uint256 expected, uint256 actual);
error ClAuction_InvalidSwapFee(uint24 swapFee, uint24 maxFee);
error ClAuction_InvalidToken(address token);
error ClAuction_InvalidAmount(uint256 amount);
