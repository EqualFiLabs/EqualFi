// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

// Custom errors for ERC-6551 Position Agent integration

// Access control errors
error PositionAgent_Unauthorized(address caller, uint256 positionTokenId);
error PositionAgent_NotAdmin(address caller);

// State errors
error PositionAgent_NotRegistered(uint256 positionTokenId);
error PositionAgent_AlreadyRegistered(uint256 positionTokenId);
error PositionAgent_InvalidAgentOwner(address expected, address actual);

// Signature errors
error PositionAgent_DeadlineExpired(uint256 deadline, uint256 currentTime);
error PositionAgent_InvalidSignature();

// Execution errors
error PositionAgent_ExecutionFailed(bytes reason);
