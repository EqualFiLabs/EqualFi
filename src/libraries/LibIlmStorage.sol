// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IlmTypes} from "./IlmTypes.sol";

/// @notice Diamond storage accessor for ILM pooled behavior profile.
library LibIlmStorage {
    bytes32 internal constant STORAGE_POSITION = keccak256("equalis.ilm.pooled.storage");

    struct IlmStorage {
        uint256 nextMarketId;
        mapping(uint256 => uint256) marketModuleId;
        mapping(uint256 => IlmTypes.IlmMarket) markets;
        mapping(uint256 => mapping(bytes32 => IlmTypes.IlmPosition)) positions;
        mapping(uint256 => uint256) marketProtocolFeeAssets;
        mapping(bytes32 => mapping(address => bool)) isAuthorizedOperator;
        address oracleAdapter;
        address sentinelAdapter;
        uint16 minLtvBps;
        uint16 maxLtvBps;
        uint16 minReserveFactorBps;
        uint16 maxReserveFactorBps;
    }

    function s() internal pure returns (IlmStorage storage ds) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            ds.slot := position
        }
    }
}
