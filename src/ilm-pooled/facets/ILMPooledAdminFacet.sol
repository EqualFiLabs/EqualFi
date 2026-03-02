// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibDiamond} from "../../libraries/LibDiamond.sol";
import {LibAppStorage} from "../../libraries/LibAppStorage.sol";
import {IlmTypes, IlmMarketNotFound, IlmInvalidRiskParams, IlmNotGovernance} from "../libraries/IlmTypes.sol";
import {LibIlmStorage} from "../libraries/LibIlmStorage.sol";
import {IILMPooledAdminFacet} from "../interfaces/IILMPooledAdminFacet.sol";

/// @notice Governance controls for ILM pooled markets.
contract ILMPooledAdminFacet is IILMPooledAdminFacet {
    event IlmMarketCreated(uint256 indexed marketId, uint256 indexed loanPoolId, uint256 indexed collateralPoolId);
    event IlmPooledMarketFlagsSet(uint256 indexed marketId, bool active, bool paused, bool frozen);
    event IlmPooledMarketCapsSet(uint256 indexed marketId, uint256 supplyCap, uint256 borrowCap);
    event IlmPooledRiskParamsSet(
        uint256 indexed marketId,
        uint16 ltvBps,
        uint16 liquidationThresholdBps,
        uint16 liquidationBonusBps,
        uint16 liquidationProtocolFeeBps
    );
    event IlmPooledRateStrategySet(
        uint256 indexed marketId,
        uint16 reserveFactorBps,
        uint16 optimalUtilizationBps,
        uint32 baseVariableRateRayPerYear,
        uint32 variableSlope1RayPerYear,
        uint32 variableSlope2RayPerYear
    );
    event IlmPooledOracleAdapterSet(address indexed oracleAdapter);
    event IlmPooledSentinelAdapterSet(address indexed sentinelAdapter);
    event IlmPooledGlobalBoundsSet(
        uint16 minLtvBps, uint16 maxLtvBps, uint16 minReserveFactorBps, uint16 maxReserveFactorBps
    );

    function createPooledMarket(IlmTypes.IlmCreateParams calldata params) external returns (uint256 marketId) {
        _onlyGovernance();
        LibIlmStorage.IlmStorage storage ds = LibIlmStorage.s();

        _validateLtvBounds(params.ltvBps, ds.minLtvBps, ds.maxLtvBps);
        if (params.liquidationThresholdBps <= params.ltvBps) {
            revert IlmInvalidRiskParams();
        }
        _validateReserveFactorBounds(params.reserveFactorBps, ds.minReserveFactorBps, ds.maxReserveFactorBps);
        if (params.moduleId == 0) {
            revert IlmInvalidRiskParams();
        }
        if (params.optimalUtilizationBps > IlmTypes.BPS || params.liquidationProtocolFeeBps > IlmTypes.BPS) {
            revert IlmInvalidRiskParams();
        }
        if (block.timestamp > type(uint64).max) {
            revert IlmInvalidRiskParams();
        }

        marketId = _nextMarketId(ds);
        ds.marketModuleId[marketId] = params.moduleId;

        IlmTypes.IlmMarket storage market = ds.markets[marketId];
        market.loanPoolId = params.loanPoolId;
        market.collateralPoolId = params.collateralPoolId;
        market.ltvBps = params.ltvBps;
        market.liquidationThresholdBps = params.liquidationThresholdBps;
        market.liquidationBonusBps = params.liquidationBonusBps;
        market.liquidationProtocolFeeBps = params.liquidationProtocolFeeBps;
        market.reserveFactorBps = params.reserveFactorBps;
        market.optimalUtilizationBps = params.optimalUtilizationBps;
        market.baseVariableRateRayPerYear = params.baseVariableRateRayPerYear;
        market.variableSlope1RayPerYear = params.variableSlope1RayPerYear;
        market.variableSlope2RayPerYear = params.variableSlope2RayPerYear;
        market.supplyCap = params.supplyCap;
        market.borrowCap = params.borrowCap;
        market.active = true;
        market.paused = false;
        market.frozen = false;
        market.liquidityIndexRay = uint128(IlmTypes.RAY);
        market.variableBorrowIndexRay = uint128(IlmTypes.RAY);
        market.lastUpdate = uint64(block.timestamp);

        emit IlmMarketCreated(marketId, params.loanPoolId, params.collateralPoolId);
    }

    function setPooledMarketFlags(uint256 marketId, bool active, bool paused, bool frozen) external {
        _onlyGovernance();
        IlmTypes.IlmMarket storage market = _requireMarket(marketId);
        market.active = active;
        market.paused = paused;
        market.frozen = frozen;
        emit IlmPooledMarketFlagsSet(marketId, active, paused, frozen);
    }

    function setPooledMarketCaps(uint256 marketId, uint256 supplyCap, uint256 borrowCap) external {
        _onlyGovernance();
        IlmTypes.IlmMarket storage market = _requireMarket(marketId);
        market.supplyCap = supplyCap;
        market.borrowCap = borrowCap;
        emit IlmPooledMarketCapsSet(marketId, supplyCap, borrowCap);
    }

    function setPooledRiskParams(
        uint256 marketId,
        uint16 ltvBps,
        uint16 liquidationThresholdBps,
        uint16 liquidationBonusBps,
        uint16 liquidationProtocolFeeBps
    ) external {
        _onlyGovernance();

        LibIlmStorage.IlmStorage storage ds = LibIlmStorage.s();
        _validateLtvBounds(ltvBps, ds.minLtvBps, ds.maxLtvBps);
        if (liquidationThresholdBps <= ltvBps || liquidationProtocolFeeBps > IlmTypes.BPS) {
            revert IlmInvalidRiskParams();
        }

        IlmTypes.IlmMarket storage market = _requireMarket(marketId);
        market.ltvBps = ltvBps;
        market.liquidationThresholdBps = liquidationThresholdBps;
        market.liquidationBonusBps = liquidationBonusBps;
        market.liquidationProtocolFeeBps = liquidationProtocolFeeBps;

        emit IlmPooledRiskParamsSet(
            marketId, ltvBps, liquidationThresholdBps, liquidationBonusBps, liquidationProtocolFeeBps
        );
    }

    function setPooledRateStrategy(
        uint256 marketId,
        uint16 reserveFactorBps,
        uint16 optimalUtilizationBps,
        uint32 baseVariableRateRayPerYear,
        uint32 variableSlope1RayPerYear,
        uint32 variableSlope2RayPerYear
    ) external {
        _onlyGovernance();

        LibIlmStorage.IlmStorage storage ds = LibIlmStorage.s();
        _validateReserveFactorBounds(reserveFactorBps, ds.minReserveFactorBps, ds.maxReserveFactorBps);
        if (optimalUtilizationBps > IlmTypes.BPS) {
            revert IlmInvalidRiskParams();
        }

        IlmTypes.IlmMarket storage market = _requireMarket(marketId);
        market.reserveFactorBps = reserveFactorBps;
        market.optimalUtilizationBps = optimalUtilizationBps;
        market.baseVariableRateRayPerYear = baseVariableRateRayPerYear;
        market.variableSlope1RayPerYear = variableSlope1RayPerYear;
        market.variableSlope2RayPerYear = variableSlope2RayPerYear;

        emit IlmPooledRateStrategySet(
            marketId,
            reserveFactorBps,
            optimalUtilizationBps,
            baseVariableRateRayPerYear,
            variableSlope1RayPerYear,
            variableSlope2RayPerYear
        );
    }

    function setPooledOracleAdapter(address oracleAdapter) external {
        _onlyGovernance();
        LibIlmStorage.s().oracleAdapter = oracleAdapter;
        emit IlmPooledOracleAdapterSet(oracleAdapter);
    }

    function setPooledSentinelAdapter(address sentinelAdapter) external {
        _onlyGovernance();
        LibIlmStorage.s().sentinelAdapter = sentinelAdapter;
        emit IlmPooledSentinelAdapterSet(sentinelAdapter);
    }

    function setPooledGlobalBounds(
        uint16 minLtvBps,
        uint16 maxLtvBps,
        uint16 minReserveFactorBps,
        uint16 maxReserveFactorBps
    ) external {
        _onlyGovernance();
        if (
            minLtvBps > maxLtvBps || minReserveFactorBps > maxReserveFactorBps || maxLtvBps > IlmTypes.BPS
                || maxReserveFactorBps > IlmTypes.BPS
        ) {
            revert IlmInvalidRiskParams();
        }

        LibIlmStorage.IlmStorage storage ds = LibIlmStorage.s();
        ds.minLtvBps = minLtvBps;
        ds.maxLtvBps = maxLtvBps;
        ds.minReserveFactorBps = minReserveFactorBps;
        ds.maxReserveFactorBps = maxReserveFactorBps;

        emit IlmPooledGlobalBoundsSet(minLtvBps, maxLtvBps, minReserveFactorBps, maxReserveFactorBps);
    }

    function _nextMarketId(LibIlmStorage.IlmStorage storage ds) internal returns (uint256 marketId) {
        uint256 next = ds.nextMarketId;
        if (next == 0) {
            next = 1;
        }
        marketId = next;
        ds.nextMarketId = next + 1;
    }

    function _requireMarket(uint256 marketId) internal view returns (IlmTypes.IlmMarket storage market) {
        market = LibIlmStorage.s().markets[marketId];
        if (market.lastUpdate == 0) {
            revert IlmMarketNotFound(marketId);
        }
    }

    function _validateLtvBounds(uint16 ltvBps, uint16 minLtvBps, uint16 maxLtvBps) internal pure {
        if (ltvBps < minLtvBps || ltvBps > maxLtvBps) {
            revert IlmInvalidRiskParams();
        }
    }

    function _validateReserveFactorBounds(uint16 reserveFactorBps, uint16 minReserveFactorBps, uint16 maxReserveFactorBps)
        internal
        pure
    {
        if (reserveFactorBps < minReserveFactorBps || reserveFactorBps > maxReserveFactorBps) {
            revert IlmInvalidRiskParams();
        }
    }

    function _onlyGovernance() internal view {
        address sender = msg.sender;
        if (sender == LibDiamond.diamondStorage().contractOwner) {
            return;
        }
        if (sender == LibAppStorage.timelockAddress(LibAppStorage.s())) {
            return;
        }
        revert IlmNotGovernance();
    }
}
