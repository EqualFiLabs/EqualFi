// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IlmIsolatedTypes} from "../types/IlmIsolatedTypes.sol";

/// @notice Diamond storage accessor for ILM isolated behavior profile.
library LibIlmIsolatedStorage {
    bytes32 internal constant STORAGE_POSITION = keccak256("equalis.ilm.isolated.storage");

    struct IlmIsolatedStorageLayout {
        address owner;
        bytes32 feeRecipientPositionKey;
        uint256 maxStaleness;
        mapping(address => bool) isIrmEnabled;
        mapping(address => bool) isIrmManagedOnly;
        mapping(uint256 => bool) isLltvEnabled;
        mapping(bytes32 => IlmIsolatedTypes.IlmIsolatedMarketParams) marketParams;
        mapping(bytes32 => IlmIsolatedTypes.IlmIsolatedMarket) market;
        mapping(bytes32 => mapping(bytes32 => IlmIsolatedTypes.IlmIsolatedPosition)) position;
        mapping(bytes32 => mapping(address => bool)) isAuthorizedOperator;
        mapping(bytes32 => uint256) marketModuleId;
        mapping(bytes32 => uint16) marketLiquidationFeeBps;
        mapping(bytes32 => uint256) marketProtocolFeeAssets;
    }

    function s() internal pure returns (IlmIsolatedStorageLayout storage ds) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            ds.slot := position
        }
    }

    /// @notice Deterministic market ID hash for isolated markets.
    function deriveMarketId(IlmIsolatedTypes.IlmIsolatedMarketParams memory params) internal pure returns (bytes32) {
        return keccak256(abi.encode(params));
    }
}
