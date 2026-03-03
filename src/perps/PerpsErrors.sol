// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

error Perps_MarketNotFound(bytes32 marketId);
error Perps_MarketAlreadyExists(bytes32 marketId);
error Perps_NotGovernance(address caller);
error Perps_GenesisConfigIncomplete(bytes32 marketId, uint8 got, uint8 required);
error Perps_AccountNotFound(bytes32 accountId);
error Perps_Unauthorized(bytes32 accountId, address caller);
error Perps_InvalidIntent();
error Perps_IntentCanceled(bytes32 intentHash);
error Perps_IntentExpired(uint64 deadline, uint64 nowTs);
error Perps_BadSignature();
error Perps_NonceMismatch(uint64 expected, uint64 got);
error Perps_NonceInvalidated(uint64 minValidNonce, uint64 intentNonce);
error Perps_PriceStale(uint256 updatedAt, uint256 maxStaleness);
error Perps_PriceOutOfBounds();
error Perps_RiskLimitExceeded();
error Perps_InsufficientMargin(uint256 required, uint256 actual);
error Perps_InsufficientPerpsLiquidity(uint256 required, uint256 available);
error Perps_PositionHealthy();
error Perps_IncreasePaused(bytes32 marketId);
error Perps_DecreasePaused(bytes32 marketId);
error Perps_LiquidationPaused(bytes32 marketId);
error Perps_SyncPaused(bytes32 marketId);
error Perps_IsolationViolation();
