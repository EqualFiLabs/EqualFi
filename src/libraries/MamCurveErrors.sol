// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

error MamCurve_InvalidAmount(uint256 amount);
error MamCurve_InvalidPool(uint256 poolId);
error MamCurve_InvalidDescriptor();
error MamCurve_InvalidTime(uint64 startTime, uint64 duration);
error MamCurve_NotActive(uint256 curveId);
error MamCurve_Expired(uint256 curveId);
error MamCurve_NotExpired(uint256 curveId);
error MamCurve_InsufficientVolume(uint256 requested, uint256 available);
error MamCurve_Slippage(uint256 minOut, uint256 actualOut);
error MamCurve_NotMaker(address caller, uint256 positionId);
error MamCurve_Paused();
