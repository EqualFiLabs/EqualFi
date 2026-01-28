// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

// Access control errors
error ERC8004_Unauthorized(address caller, uint256 agentId);
error ERC8004_InvalidAgent(uint256 agentId);

// Metadata errors
error ERC8004_ReservedMetadataKey(string key);

// Signature errors
error ERC8004_DeadlineExpired(uint256 deadline, uint256 currentTime);
error ERC8004_InvalidSignature();
error ERC8004_InvalidSignatureLength(uint256 length);
error ERC8004_NonceAlreadyUsed(uint256 agentId, uint256 nonce);

// ERC-1271 errors
error ERC8004_ERC1271ValidationFailed(address wallet);
