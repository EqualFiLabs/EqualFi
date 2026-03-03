// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibPerpsIdentity} from "./LibPerpsIdentity.sol";
import {LibPerpsStorage} from "./LibPerpsStorage.sol";
import {
    Perps_MarketAlreadyExists,
    Perps_MarketNotFound,
    Perps_NotGovernance,
    Perps_GenesisConfigIncomplete,
    Perps_RiskLimitExceeded
} from "./PerpsErrors.sol";

/// @notice Governance controls for isolated perps market configuration and genesis enable gating.
contract PerpsAdminFacet {
    uint8 internal constant CONFIG_RISK = 1 << 0;
    uint8 internal constant CONFIG_CAPS = 1 << 1;
    uint8 internal constant CONFIG_ORACLE = 1 << 2;
    uint8 internal constant CONFIG_PAUSE = 1 << 3;
    uint8 internal constant CONFIG_FEE = 1 << 4;
    uint8 internal constant CONFIG_INSURANCE = 1 << 5;
    uint8 internal constant CONFIG_REQUIRED_MASK =
        CONFIG_RISK | CONFIG_CAPS | CONFIG_ORACLE | CONFIG_PAUSE | CONFIG_FEE | CONFIG_INSURANCE;

    struct CreatePerpsMarketParams {
        uint256 collateralPoolId;
        address collateralAsset;
        address indexAsset;
        bool longEnabled;
        bool shortEnabled;
    }

    struct MarketRiskParams {
        uint32 maxLeverageBps;
        uint32 initialMarginBps;
        uint32 maintenanceMarginBps;
        uint32 liquidationIncentiveBpsMax;
    }

    struct MarketCapParams {
        uint256 maxOpenInterest;
        uint256 maxLongOpenInterest;
        uint256 maxShortOpenInterest;
        uint256 maxSkewAbs;
    }

    struct OracleConfig {
        address oracleAdapter;
        uint32 maxStaleness;
        uint32 maxDeviationBps;
    }

    struct PauseFlags {
        bool pauseIncrease;
        bool pauseDecrease;
        bool pauseLiquidation;
        bool pauseSync;
    }

    struct FeeConfig {
        uint32 takerFeeBps;
        uint32 makerFeeBps;
        uint32 maxFundingVelocityBpsPerDay;
    }

    struct InsuranceConfig {
        uint256 insuranceTarget;
    }

    struct GlobalPerpsConfig {
        bool publicExecutionEnabled;
        bool publicLiquidationEnabled;
    }

    event PerpsMarketCreated(bytes32 indexed marketId, uint256 collateralPoolId, address collateralAsset, address indexAsset);
    event PerpsMarketRiskUpdated(bytes32 indexed marketId, MarketRiskParams previousConfig, MarketRiskParams newConfig);
    event PerpsMarketCapsUpdated(bytes32 indexed marketId, MarketCapParams previousConfig, MarketCapParams newConfig);
    event PerpsOracleConfigUpdated(bytes32 indexed marketId, OracleConfig previousConfig, OracleConfig newConfig);
    event PerpsPauseFlagsUpdated(bytes32 indexed marketId, PauseFlags previousFlags, PauseFlags newFlags);
    event PerpsFeeConfigUpdated(bytes32 indexed marketId, FeeConfig previousConfig, FeeConfig newConfig);
    event PerpsInsuranceConfigUpdated(bytes32 indexed marketId, InsuranceConfig previousConfig, InsuranceConfig newConfig);
    event PerpsGlobalConfigUpdated(GlobalPerpsConfig previousConfig, GlobalPerpsConfig newConfig);

    function createMarket(CreatePerpsMarketParams calldata p) external returns (bytes32 marketId) {
        _onlyGovernance();

        if (p.collateralAsset == address(0) || p.indexAsset == address(0) || (!p.longEnabled && !p.shortEnabled)) {
            revert Perps_RiskLimitExceeded();
        }

        marketId = LibPerpsIdentity.deriveMarketId(
            LibPerpsIdentity.MarketIdParams({
                collateralPoolId: p.collateralPoolId,
                collateralAsset: p.collateralAsset,
                indexAsset: p.indexAsset
            })
        );

        LibPerpsStorage.Layout storage ps = LibPerpsStorage.s();
        if (ps.markets[marketId].exists) {
            revert Perps_MarketAlreadyExists(marketId);
        }

        LibPerpsStorage.PerpsMarket storage market = ps.markets[marketId];
        market.marketId = marketId;
        market.collateralPoolId = p.collateralPoolId;
        market.collateralAsset = p.collateralAsset;
        market.indexAsset = p.indexAsset;
        market.longEnabled = p.longEnabled;
        market.shortEnabled = p.shortEnabled;
        market.exists = true;

        uint256 nextCount = ps.marketCount + 1;
        ps.marketCount = nextCount;
        ps.marketIds[nextCount] = marketId;

        emit PerpsMarketCreated(marketId, p.collateralPoolId, p.collateralAsset, p.indexAsset);
    }

    function setMarketRisk(bytes32 marketId, MarketRiskParams calldata p) external {
        _onlyGovernance();
        LibPerpsStorage.PerpsMarket storage market = _requireMarket(marketId);
        _validateRiskParams(p);

        MarketRiskParams memory previous = MarketRiskParams({
            maxLeverageBps: market.maxLeverageBps,
            initialMarginBps: market.initialMarginBps,
            maintenanceMarginBps: market.maintenanceMarginBps,
            liquidationIncentiveBpsMax: market.liquidationIncentiveBpsMax
        });

        market.maxLeverageBps = p.maxLeverageBps;
        market.initialMarginBps = p.initialMarginBps;
        market.maintenanceMarginBps = p.maintenanceMarginBps;
        market.liquidationIncentiveBpsMax = p.liquidationIncentiveBpsMax;

        _markConfigured(marketId, CONFIG_RISK);
        emit PerpsMarketRiskUpdated(marketId, previous, p);
    }

    function setMarketCaps(bytes32 marketId, MarketCapParams calldata p) external {
        _onlyGovernance();
        LibPerpsStorage.PerpsMarket storage market = _requireMarket(marketId);
        _validateCapParams(p);

        MarketCapParams memory previous = MarketCapParams({
            maxOpenInterest: market.maxOpenInterest,
            maxLongOpenInterest: market.maxLongOpenInterest,
            maxShortOpenInterest: market.maxShortOpenInterest,
            maxSkewAbs: market.maxSkewAbs
        });

        market.maxOpenInterest = p.maxOpenInterest;
        market.maxLongOpenInterest = p.maxLongOpenInterest;
        market.maxShortOpenInterest = p.maxShortOpenInterest;
        market.maxSkewAbs = p.maxSkewAbs;

        _markConfigured(marketId, CONFIG_CAPS);
        emit PerpsMarketCapsUpdated(marketId, previous, p);
    }

    function setOracleConfig(bytes32 marketId, OracleConfig calldata p) external {
        _onlyGovernance();
        LibPerpsStorage.PerpsMarket storage market = _requireMarket(marketId);
        if (p.oracleAdapter == address(0) || p.maxStaleness == 0 || p.maxDeviationBps > 10_000) {
            revert Perps_RiskLimitExceeded();
        }

        OracleConfig memory previous = OracleConfig({
            oracleAdapter: market.oracleAdapter,
            maxStaleness: market.maxStaleness,
            maxDeviationBps: market.maxDeviationBps
        });

        market.oracleAdapter = p.oracleAdapter;
        market.maxStaleness = p.maxStaleness;
        market.maxDeviationBps = p.maxDeviationBps;

        _markConfigured(marketId, CONFIG_ORACLE);
        emit PerpsOracleConfigUpdated(marketId, previous, p);
    }

    function setPauseFlags(bytes32 marketId, PauseFlags calldata p) external {
        _onlyGovernance();
        LibPerpsStorage.PerpsMarket storage market = _requireMarket(marketId);

        PauseFlags memory previous = PauseFlags({
            pauseIncrease: market.pauseIncrease,
            pauseDecrease: market.pauseDecrease,
            pauseLiquidation: market.pauseLiquidation,
            pauseSync: market.pauseSync
        });

        market.pauseIncrease = p.pauseIncrease;
        market.pauseDecrease = p.pauseDecrease;
        market.pauseLiquidation = p.pauseLiquidation;
        market.pauseSync = p.pauseSync;

        _markConfigured(marketId, CONFIG_PAUSE);
        emit PerpsPauseFlagsUpdated(marketId, previous, p);
    }

    function setFeeConfig(bytes32 marketId, FeeConfig calldata p) external {
        _onlyGovernance();
        LibPerpsStorage.PerpsMarket storage market = _requireMarket(marketId);
        if (p.takerFeeBps > 10_000 || p.makerFeeBps > 10_000) {
            revert Perps_RiskLimitExceeded();
        }

        FeeConfig memory previous = FeeConfig({
            takerFeeBps: market.takerFeeBps,
            makerFeeBps: market.makerFeeBps,
            maxFundingVelocityBpsPerDay: market.maxFundingVelocityBpsPerDay
        });

        market.takerFeeBps = p.takerFeeBps;
        market.makerFeeBps = p.makerFeeBps;
        market.maxFundingVelocityBpsPerDay = p.maxFundingVelocityBpsPerDay;

        _markConfigured(marketId, CONFIG_FEE);
        emit PerpsFeeConfigUpdated(marketId, previous, p);
    }

    function setInsuranceConfig(bytes32 marketId, InsuranceConfig calldata p) external {
        _onlyGovernance();
        _requireMarket(marketId);

        LibPerpsStorage.PerpsMarketState storage state = LibPerpsStorage.s().marketState[marketId];
        InsuranceConfig memory previous = InsuranceConfig({insuranceTarget: state.insuranceTarget});
        state.insuranceTarget = p.insuranceTarget;

        _markConfigured(marketId, CONFIG_INSURANCE);
        emit PerpsInsuranceConfigUpdated(marketId, previous, p);
    }

    function setGlobalConfig(GlobalPerpsConfig calldata p) external {
        _onlyGovernance();
        if (p.publicExecutionEnabled || p.publicLiquidationEnabled) {
            _requireAllMarketsGenesisConfigured();
        }

        LibPerpsStorage.Layout storage ps = LibPerpsStorage.s();
        GlobalPerpsConfig memory previous =
            GlobalPerpsConfig({publicExecutionEnabled: ps.globalExecutionEnabled, publicLiquidationEnabled: ps.globalLiquidationEnabled});

        ps.globalExecutionEnabled = p.publicExecutionEnabled;
        ps.globalLiquidationEnabled = p.publicLiquidationEnabled;
        emit PerpsGlobalConfigUpdated(previous, p);
    }

    function getGlobalConfig() external view returns (GlobalPerpsConfig memory config) {
        LibPerpsStorage.Layout storage ps = LibPerpsStorage.s();
        config.publicExecutionEnabled = ps.globalExecutionEnabled;
        config.publicLiquidationEnabled = ps.globalLiquidationEnabled;
    }

    function getMarketConfigMask(bytes32 marketId) external view returns (uint8) {
        return LibPerpsStorage.s().marketConfigMask[marketId];
    }

    function getRequiredGenesisConfigMask() external pure returns (uint8) {
        return CONFIG_REQUIRED_MASK;
    }

    function isMarketExecutionEnabled(bytes32 marketId) external view returns (bool) {
        LibPerpsStorage.Layout storage ps = LibPerpsStorage.s();
        return ps.globalExecutionEnabled && _isMarketGenesisConfigured(marketId);
    }

    function isMarketLiquidationEnabled(bytes32 marketId) external view returns (bool) {
        LibPerpsStorage.Layout storage ps = LibPerpsStorage.s();
        LibPerpsStorage.PerpsMarket storage market = ps.markets[marketId];
        return ps.globalLiquidationEnabled && _isMarketGenesisConfigured(marketId) && !market.pauseLiquidation;
    }

    function perpsAdminVersion() external pure returns (bytes32) {
        return keccak256("equalis.perps.admin.v1");
    }

    function _requireAllMarketsGenesisConfigured() internal view {
        LibPerpsStorage.Layout storage ps = LibPerpsStorage.s();
        uint256 count = ps.marketCount;
        for (uint256 i = 1; i <= count; ++i) {
            bytes32 marketId = ps.marketIds[i];
            if (!_isMarketGenesisConfigured(marketId)) {
                revert Perps_GenesisConfigIncomplete(marketId, ps.marketConfigMask[marketId], CONFIG_REQUIRED_MASK);
            }
        }
    }

    function _isMarketGenesisConfigured(bytes32 marketId) internal view returns (bool) {
        LibPerpsStorage.Layout storage ps = LibPerpsStorage.s();
        if (!ps.markets[marketId].exists) {
            return false;
        }
        return ps.marketConfigMask[marketId] == CONFIG_REQUIRED_MASK;
    }

    function _markConfigured(bytes32 marketId, uint8 bit) internal {
        LibPerpsStorage.Layout storage ps = LibPerpsStorage.s();
        ps.marketConfigMask[marketId] = ps.marketConfigMask[marketId] | bit;
    }

    function _requireMarket(bytes32 marketId) internal view returns (LibPerpsStorage.PerpsMarket storage market) {
        market = LibPerpsStorage.s().markets[marketId];
        if (!market.exists) {
            revert Perps_MarketNotFound(marketId);
        }
    }

    function _validateRiskParams(MarketRiskParams calldata p) internal pure {
        if (
            p.maxLeverageBps == 0 || p.initialMarginBps == 0 || p.maintenanceMarginBps == 0 || p.initialMarginBps > 10_000
                || p.maintenanceMarginBps > 10_000 || p.maintenanceMarginBps > p.initialMarginBps
                || p.liquidationIncentiveBpsMax > 10_000
        ) {
            revert Perps_RiskLimitExceeded();
        }
    }

    function _validateCapParams(MarketCapParams calldata p) internal pure {
        if (
            (p.maxLongOpenInterest > p.maxOpenInterest && p.maxOpenInterest != 0)
                || (p.maxShortOpenInterest > p.maxOpenInterest && p.maxOpenInterest != 0)
        ) {
            revert Perps_RiskLimitExceeded();
        }
    }

    function _onlyGovernance() internal view {
        address sender = msg.sender;
        if (sender == LibDiamond.diamondStorage().contractOwner || sender == LibAppStorage.timelockAddress(LibAppStorage.s())) {
            return;
        }
        revert Perps_NotGovernance(sender);
    }
}
