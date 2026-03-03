// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibDiamond} from "../../src/libraries/LibDiamond.sol";
import {LibPerpsIdentity} from "../../src/perps/LibPerpsIdentity.sol";
import {LibPerpsStorage} from "../../src/perps/LibPerpsStorage.sol";
import {PerpsAdminFacet} from "../../src/perps/PerpsAdminFacet.sol";
import {
    Perps_MarketAlreadyExists,
    Perps_NotGovernance,
    Perps_GenesisConfigIncomplete,
    Perps_RiskLimitExceeded
} from "../../src/perps/PerpsErrors.sol";

contract PerpsAdminHarness is PerpsAdminFacet {
    function setGovernance(address owner, address timelock) external {
        LibDiamond.setContractOwner(owner);
        LibAppStorage.s().timelock = timelock;
    }

    function getMarket(bytes32 marketId) external view returns (LibPerpsStorage.PerpsMarket memory) {
        return LibPerpsStorage.s().markets[marketId];
    }

    function getMarketState(bytes32 marketId) external view returns (LibPerpsStorage.PerpsMarketState memory) {
        return LibPerpsStorage.s().marketState[marketId];
    }

    function deriveMarketId(PerpsAdminFacet.CreatePerpsMarketParams calldata p) external pure returns (bytes32) {
        return LibPerpsIdentity.deriveMarketId(
            LibPerpsIdentity.MarketIdParams({
                collateralPoolId: p.collateralPoolId,
                collateralAsset: p.collateralAsset,
                indexAsset: p.indexAsset
            })
        );
    }
}

contract PerpsAdminFacetTest is Test {
    PerpsAdminHarness internal h;

    address internal owner = address(0xA11CE);
    address internal timelock = address(0xBEEF);
    address internal outsider = address(0xDEAD);

    function setUp() public {
        h = new PerpsAdminHarness();
        h.setGovernance(owner, timelock);
    }

    function test_governanceAccessControl_restrictsAdminCalls() public {
        PerpsAdminFacet.CreatePerpsMarketParams memory createParams = _defaultCreateParams();

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(Perps_NotGovernance.selector, outsider));
        h.createMarket(createParams);

        vm.prank(owner);
        bytes32 marketId = h.createMarket(createParams);

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(Perps_NotGovernance.selector, outsider));
        h.setMarketRisk(marketId, _defaultRiskParams());
    }

    function test_createMarket_deterministicIdAndDuplicateRevert() public {
        PerpsAdminFacet.CreatePerpsMarketParams memory createParams = _defaultCreateParams();
        bytes32 expectedMarketId = h.deriveMarketId(createParams);

        vm.prank(owner);
        bytes32 marketId = h.createMarket(createParams);

        assertEq(marketId, expectedMarketId);

        LibPerpsStorage.PerpsMarket memory market = h.getMarket(marketId);
        assertEq(market.marketId, marketId);
        assertEq(market.collateralPoolId, createParams.collateralPoolId);
        assertEq(market.collateralAsset, createParams.collateralAsset);
        assertEq(market.indexAsset, createParams.indexAsset);
        assertEq(market.longEnabled, createParams.longEnabled);
        assertEq(market.shortEnabled, createParams.shortEnabled);
        assertTrue(market.exists);

        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(Perps_MarketAlreadyExists.selector, marketId));
        h.createMarket(createParams);
    }

    function test_adminSetters_roundTripAndMaskProgression() public {
        vm.prank(owner);
        bytes32 marketId = h.createMarket(_defaultCreateParams());

        vm.prank(owner);
        h.setMarketRisk(marketId, _defaultRiskParams());
        vm.prank(owner);
        h.setMarketCaps(marketId, _defaultCapParams());
        vm.prank(owner);
        h.setOracleConfig(marketId, _defaultOracleConfig());
        vm.prank(owner);
        h.setPauseFlags(marketId, _defaultPauseFlags());
        vm.prank(owner);
        h.setFeeConfig(marketId, _defaultFeeConfig());
        vm.prank(owner);
        h.setInsuranceConfig(marketId, PerpsAdminFacet.InsuranceConfig({insuranceTarget: 250_000e18}));

        uint8 requiredMask = h.getRequiredGenesisConfigMask();
        assertEq(h.getMarketConfigMask(marketId), requiredMask);

        LibPerpsStorage.PerpsMarket memory market = h.getMarket(marketId);
        assertEq(market.maxLeverageBps, 50_000);
        assertEq(market.initialMarginBps, 1_000);
        assertEq(market.maintenanceMarginBps, 700);
        assertEq(market.maxOpenInterest, 5_000_000e18);
        assertEq(market.oracleAdapter, address(0x1111));
        assertEq(market.maxStaleness, 120);
        assertEq(market.maxDeviationBps, 100);
        assertEq(market.takerFeeBps, 15);
        assertEq(market.makerFeeBps, 5);
        assertFalse(market.pauseIncrease);
        assertFalse(market.pauseDecrease);

        LibPerpsStorage.PerpsMarketState memory state = h.getMarketState(marketId);
        assertEq(state.insuranceTarget, 250_000e18);
    }

    function test_preEnableGate_blocksGlobalEnableUntilConfigured_thenAllows() public {
        vm.prank(owner);
        bytes32 marketId = h.createMarket(_defaultCreateParams());
        uint8 requiredMask = h.getRequiredGenesisConfigMask();

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(Perps_GenesisConfigIncomplete.selector, marketId, uint8(0), requiredMask)
        );
        h.setGlobalConfig(PerpsAdminFacet.GlobalPerpsConfig({publicExecutionEnabled: true, publicLiquidationEnabled: true}));

        _configureMarketAll(marketId);

        vm.prank(timelock);
        h.setGlobalConfig(PerpsAdminFacet.GlobalPerpsConfig({publicExecutionEnabled: true, publicLiquidationEnabled: true}));

        assertTrue(h.isMarketExecutionEnabled(marketId));
        assertTrue(h.isMarketLiquidationEnabled(marketId));

        vm.prank(owner);
        h.setPauseFlags(
            marketId,
            PerpsAdminFacet.PauseFlags({
                pauseIncrease: false,
                pauseDecrease: false,
                pauseLiquidation: true,
                pauseSync: false
            })
        );

        assertTrue(h.isMarketExecutionEnabled(marketId));
        assertFalse(h.isMarketLiquidationEnabled(marketId));
    }

    function test_validationReverts_onInvalidRiskCapsOracleAndFees() public {
        vm.prank(owner);
        bytes32 marketId = h.createMarket(_defaultCreateParams());

        vm.prank(owner);
        vm.expectRevert(Perps_RiskLimitExceeded.selector);
        h.setMarketRisk(
            marketId,
            PerpsAdminFacet.MarketRiskParams({
                maxLeverageBps: 50_000,
                initialMarginBps: 700,
                maintenanceMarginBps: 900,
                liquidationIncentiveBpsMax: 500
            })
        );

        vm.prank(owner);
        vm.expectRevert(Perps_RiskLimitExceeded.selector);
        h.setMarketCaps(
            marketId,
            PerpsAdminFacet.MarketCapParams({
                maxOpenInterest: 1_000e18,
                maxLongOpenInterest: 2_000e18,
                maxShortOpenInterest: 500e18,
                maxSkewAbs: 250e18
            })
        );

        vm.prank(owner);
        vm.expectRevert(Perps_RiskLimitExceeded.selector);
        h.setOracleConfig(
            marketId,
            PerpsAdminFacet.OracleConfig({oracleAdapter: address(0), maxStaleness: 120, maxDeviationBps: 100})
        );

        vm.prank(owner);
        vm.expectRevert(Perps_RiskLimitExceeded.selector);
        h.setFeeConfig(
            marketId,
            PerpsAdminFacet.FeeConfig({takerFeeBps: 10_001, makerFeeBps: 5, maxFundingVelocityBpsPerDay: 1_000})
        );
    }

    function _configureMarketAll(bytes32 marketId) internal {
        vm.prank(owner);
        h.setMarketRisk(marketId, _defaultRiskParams());
        vm.prank(owner);
        h.setMarketCaps(marketId, _defaultCapParams());
        vm.prank(owner);
        h.setOracleConfig(marketId, _defaultOracleConfig());
        vm.prank(owner);
        h.setPauseFlags(marketId, _defaultPauseFlags());
        vm.prank(owner);
        h.setFeeConfig(marketId, _defaultFeeConfig());
        vm.prank(owner);
        h.setInsuranceConfig(marketId, PerpsAdminFacet.InsuranceConfig({insuranceTarget: 1_000e18}));
    }

    function _defaultCreateParams() internal pure returns (PerpsAdminFacet.CreatePerpsMarketParams memory p) {
        p.collateralPoolId = 77;
        p.collateralAsset = address(0xC011A7);
        p.indexAsset = address(0xBEEF1);
        p.longEnabled = true;
        p.shortEnabled = true;
    }

    function _defaultRiskParams() internal pure returns (PerpsAdminFacet.MarketRiskParams memory p) {
        p.maxLeverageBps = 50_000;
        p.initialMarginBps = 1_000;
        p.maintenanceMarginBps = 700;
        p.liquidationIncentiveBpsMax = 500;
    }

    function _defaultCapParams() internal pure returns (PerpsAdminFacet.MarketCapParams memory p) {
        p.maxOpenInterest = 5_000_000e18;
        p.maxLongOpenInterest = 3_000_000e18;
        p.maxShortOpenInterest = 3_000_000e18;
        p.maxSkewAbs = 1_000_000e18;
    }

    function _defaultOracleConfig() internal pure returns (PerpsAdminFacet.OracleConfig memory p) {
        p.oracleAdapter = address(0x1111);
        p.maxStaleness = 120;
        p.maxDeviationBps = 100;
    }

    function _defaultPauseFlags() internal pure returns (PerpsAdminFacet.PauseFlags memory p) {
        p.pauseIncrease = false;
        p.pauseDecrease = false;
        p.pauseLiquidation = false;
        p.pauseSync = false;
    }

    function _defaultFeeConfig() internal pure returns (PerpsAdminFacet.FeeConfig memory p) {
        p.takerFeeBps = 15;
        p.makerFeeBps = 5;
        p.maxFundingVelocityBpsPerDay = 1_000;
    }
}
