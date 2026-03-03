// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibPerpsStorage} from "./LibPerpsStorage.sol";

/// @notice Canonical deterministic ID derivation helpers for perps markets/accounts/positions.
library LibPerpsIdentity {
    bytes32 internal constant MARKET_ID_NAMESPACE = keccak256("equalis.perps.market.id.v1");
    bytes32 internal constant ACCOUNT_ID_NAMESPACE = keccak256("equalis.perps.account.id.v1");
    bytes32 internal constant POSITION_ID_NAMESPACE = keccak256("equalis.perps.position.id.v1");
    bytes32 internal constant DEFAULT_MODULE_NAMESPACE = keccak256("equalis.perps.gmxstyle.module.v1");

    struct MarketIdParams {
        uint256 collateralPoolId;
        address collateralAsset;
        address indexAsset;
    }

    function deriveMarketId(MarketIdParams memory params) internal pure returns (bytes32) {
        return keccak256(abi.encode(MARKET_ID_NAMESPACE, params.collateralPoolId, params.collateralAsset, params.indexAsset));
    }

    function deriveMarketId(LibPerpsStorage.PerpsMarket memory market) internal pure returns (bytes32) {
        return keccak256(abi.encode(MARKET_ID_NAMESPACE, market.collateralPoolId, market.collateralAsset, market.indexAsset));
    }

    function deriveAccountId(bytes32 positionKey, uint256 subaccountNonce) internal pure returns (bytes32) {
        return deriveAccountId(positionKey, DEFAULT_MODULE_NAMESPACE, subaccountNonce);
    }

    function deriveAccountId(bytes32 positionKey, bytes32 moduleNamespace, uint256 subaccountNonce)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(ACCOUNT_ID_NAMESPACE, positionKey, moduleNamespace, subaccountNonce));
    }

    function derivePositionId(bytes32 marketId, bytes32 accountId, bool isLong) internal pure returns (bytes32) {
        return keccak256(abi.encode(POSITION_ID_NAMESPACE, marketId, accountId, isLong));
    }
}
