// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IlmTypes} from "../libraries/IlmTypes.sol";

interface IILMPooledAdminFacet {
    function createPooledMarket(IlmTypes.IlmCreateParams calldata params) external returns (uint256 marketId);

    function setPooledMarketFlags(uint256 marketId, bool active, bool paused, bool frozen) external;

    function setPooledMarketCaps(uint256 marketId, uint256 supplyCap, uint256 borrowCap) external;

    function setPooledRiskParams(
        uint256 marketId,
        uint16 ltvBps,
        uint16 liquidationThresholdBps,
        uint16 liquidationBonusBps,
        uint16 liquidationProtocolFeeBps
    ) external;

    function setPooledRateStrategy(
        uint256 marketId,
        uint16 reserveFactorBps,
        uint16 optimalUtilizationBps,
        uint32 baseVariableRateRayPerYear,
        uint32 variableSlope1RayPerYear,
        uint32 variableSlope2RayPerYear
    ) external;

    function setPooledOracleAdapter(address oracleAdapter) external;

    function setPooledSentinelAdapter(address sentinelAdapter) external;

    function setPooledGlobalBounds(
        uint16 minLtvBps,
        uint16 maxLtvBps,
        uint16 minReserveFactorBps,
        uint16 maxReserveFactorBps
    ) external;
}
