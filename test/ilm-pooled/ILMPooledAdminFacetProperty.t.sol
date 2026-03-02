// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibDiamond} from "../../src/libraries/LibDiamond.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {
    IlmTypes,
    IlmInvalidRiskParams,
    IlmMarketNotFound,
    IlmNotGovernance
} from "../../src/ilm-pooled/libraries/IlmTypes.sol";
import {LibIlmStorage} from "../../src/ilm-pooled/libraries/LibIlmStorage.sol";
import {ILMPooledAdminFacet} from "../../src/ilm-pooled/facets/ILMPooledAdminFacet.sol";

contract ILMPooledAdminFacetHarness is ILMPooledAdminFacet {
    function setContractOwner(address owner) external {
        LibDiamond.setContractOwner(owner);
    }

    function setTimelock(address timelock_) external {
        LibAppStorage.s().timelock = timelock_;
    }

    function getNextMarketId() external view returns (uint256) {
        return LibIlmStorage.s().nextMarketId;
    }

    function getMarketModuleId(uint256 marketId) external view returns (uint256) {
        return LibIlmStorage.s().marketModuleId[marketId];
    }

    function getMarket(uint256 marketId) external view returns (IlmTypes.IlmMarket memory) {
        return LibIlmStorage.s().markets[marketId];
    }

    function getGlobalBounds() external view returns (uint16, uint16, uint16, uint16) {
        LibIlmStorage.IlmStorage storage ds = LibIlmStorage.s();
        return (ds.minLtvBps, ds.maxLtvBps, ds.minReserveFactorBps, ds.maxReserveFactorBps);
    }

    function getAdapters() external view returns (address oracleAdapter, address sentinelAdapter) {
        LibIlmStorage.IlmStorage storage ds = LibIlmStorage.s();
        return (ds.oracleAdapter, ds.sentinelAdapter);
    }
}

contract ILMPooledAdminFacetPropertyTest is Test {
    ILMPooledAdminFacetHarness internal h;
    address internal constant TIMELOCK = address(0xBEEF);

    function setUp() public {
        h = new ILMPooledAdminFacetHarness();
        h.setContractOwner(address(this));
        h.setTimelock(TIMELOCK);
        h.setPooledGlobalBounds(1_000, 9_000, 100, 5_000);
    }

    /// @dev Property 1: Market Creation Round-Trip
    /// Validates: Requirements 1.1, 1.5, 1.6, 1.7, 11.7
    function testFuzz_property1_marketCreationRoundTrip(
        uint256 loanPoolIdRaw,
        uint256 collateralPoolIdRaw,
        uint256 moduleIdRaw,
        uint16 ltvBpsRaw,
        uint16 liquidationThresholdBpsRaw,
        uint16 liquidationBonusBpsRaw,
        uint16 liquidationProtocolFeeBpsRaw,
        uint16 reserveFactorBpsRaw,
        uint16 optimalUtilizationBpsRaw,
        uint32 baseVariableRateRayPerYear,
        uint32 variableSlope1RayPerYear,
        uint32 variableSlope2RayPerYear,
        uint256 supplyCap,
        uint256 borrowCap
    ) public {
        uint256 loanPoolId = bound(loanPoolIdRaw, 1, type(uint64).max);
        uint256 collateralPoolId = bound(collateralPoolIdRaw, 1, type(uint64).max);
        uint256 moduleId = bound(moduleIdRaw, 1, type(uint64).max);

        uint16 ltvBps = uint16(bound(uint256(ltvBpsRaw), 1_000, 8_999));
        uint16 liquidationThresholdBps =
            uint16(bound(uint256(liquidationThresholdBpsRaw), uint256(ltvBps) + 1, 10_000));
        uint16 liquidationBonusBps = uint16(bound(uint256(liquidationBonusBpsRaw), 0, 10_000));
        uint16 liquidationProtocolFeeBps = uint16(bound(uint256(liquidationProtocolFeeBpsRaw), 0, 10_000));
        uint16 reserveFactorBps = uint16(bound(uint256(reserveFactorBpsRaw), 100, 5_000));
        uint16 optimalUtilizationBps = uint16(bound(uint256(optimalUtilizationBpsRaw), 0, 10_000));

        IlmTypes.IlmCreateParams memory params = IlmTypes.IlmCreateParams({
            loanPoolId: loanPoolId,
            collateralPoolId: collateralPoolId,
            moduleId: moduleId,
            ltvBps: ltvBps,
            liquidationThresholdBps: liquidationThresholdBps,
            liquidationBonusBps: liquidationBonusBps,
            liquidationProtocolFeeBps: liquidationProtocolFeeBps,
            reserveFactorBps: reserveFactorBps,
            optimalUtilizationBps: optimalUtilizationBps,
            baseVariableRateRayPerYear: baseVariableRateRayPerYear,
            variableSlope1RayPerYear: variableSlope1RayPerYear,
            variableSlope2RayPerYear: variableSlope2RayPerYear,
            supplyCap: supplyCap,
            borrowCap: borrowCap
        });

        uint256 marketId = h.createPooledMarket(params);
        assertEq(marketId, 1);
        assertEq(h.getNextMarketId(), 2);
        assertEq(h.getMarketModuleId(marketId), moduleId);

        IlmTypes.IlmMarket memory created = h.getMarket(marketId);
        assertEq(created.loanPoolId, loanPoolId);
        assertEq(created.collateralPoolId, collateralPoolId);
        assertEq(created.ltvBps, ltvBps);
        assertEq(created.liquidationThresholdBps, liquidationThresholdBps);
        assertEq(created.liquidationBonusBps, liquidationBonusBps);
        assertEq(created.liquidationProtocolFeeBps, liquidationProtocolFeeBps);
        assertEq(created.reserveFactorBps, reserveFactorBps);
        assertEq(created.optimalUtilizationBps, optimalUtilizationBps);
        assertEq(created.baseVariableRateRayPerYear, baseVariableRateRayPerYear);
        assertEq(created.variableSlope1RayPerYear, variableSlope1RayPerYear);
        assertEq(created.variableSlope2RayPerYear, variableSlope2RayPerYear);
        assertEq(created.supplyCap, supplyCap);
        assertEq(created.borrowCap, borrowCap);
        assertTrue(created.active);
        assertFalse(created.paused);
        assertFalse(created.frozen);
        assertEq(created.liquidityIndexRay, IlmTypes.RAY);
        assertEq(created.variableBorrowIndexRay, IlmTypes.RAY);
        assertEq(created.currentLiquidityRateRay, 0);
        assertEq(created.currentVariableBorrowRateRay, 0);
        assertEq(created.lastUpdate, block.timestamp);

        params.loanPoolId = loanPoolId + 1;
        params.collateralPoolId = collateralPoolId + 1;
        params.moduleId = moduleId + 1;
        uint256 marketId2 = h.createPooledMarket(params);
        assertEq(marketId2, 2);
        assertEq(h.getNextMarketId(), 3);
        assertEq(h.getMarketModuleId(marketId2), moduleId + 1);
    }

    /// @dev Property 2: Invalid Market Creation Rejection
    /// Validates: Requirements 1.2, 1.3, 1.4
    function testFuzz_property2_invalidMarketCreationRejection(uint256 invalidCaseRaw, uint256 seedRaw) public {
        uint256 invalidCase = bound(invalidCaseRaw, 0, 3);
        uint256 seed = bound(seedRaw, 1, type(uint64).max);

        IlmTypes.IlmCreateParams memory params = IlmTypes.IlmCreateParams({
            loanPoolId: seed,
            collateralPoolId: seed + 1,
            moduleId: 1,
            ltvBps: 7_000,
            liquidationThresholdBps: 8_000,
            liquidationBonusBps: 500,
            liquidationProtocolFeeBps: 100,
            reserveFactorBps: 1_000,
            optimalUtilizationBps: 8_000,
            baseVariableRateRayPerYear: 1_000_000_000,
            variableSlope1RayPerYear: 2_000_000_000,
            variableSlope2RayPerYear: 3_000_000_000,
            supplyCap: 1_000_000e18,
            borrowCap: 800_000e18
        });

        if (invalidCase == 0) {
            params.moduleId = 0;
        } else if (invalidCase == 1) {
            params.ltvBps = 9_001;
        } else if (invalidCase == 2) {
            params.liquidationThresholdBps = params.ltvBps;
        } else {
            params.reserveFactorBps = 5_001;
        }

        vm.expectRevert(IlmInvalidRiskParams.selector);
        h.createPooledMarket(params);
    }

    /// @dev Property 26: Admin Parameter Round-Trip
    /// Validates: Requirements 11.1, 11.4, 11.5, 11.6
    function testFuzz_property26_adminParameterRoundTrip(
        bool active,
        bool paused,
        bool frozen,
        uint256 supplyCap,
        uint256 borrowCap,
        uint16 minLtvBpsRaw,
        uint16 maxLtvBpsRaw,
        uint16 minReserveFactorBpsRaw,
        uint16 maxReserveFactorBpsRaw,
        uint16 ltvBpsRaw,
        uint16 liquidationThresholdBpsRaw,
        uint16 liquidationBonusBpsRaw,
        uint16 liquidationProtocolFeeBpsRaw,
        uint16 reserveFactorBpsRaw,
        uint16 optimalUtilizationBpsRaw,
        uint32 baseVariableRateRayPerYear,
        uint32 variableSlope1RayPerYear,
        uint32 variableSlope2RayPerYear,
        address oracleAdapter,
        address sentinelAdapter
    ) public {
        IlmTypes.IlmCreateParams memory params = IlmTypes.IlmCreateParams({
            loanPoolId: 1,
            collateralPoolId: 2,
            moduleId: 3,
            ltvBps: 7_000,
            liquidationThresholdBps: 8_000,
            liquidationBonusBps: 500,
            liquidationProtocolFeeBps: 100,
            reserveFactorBps: 1_000,
            optimalUtilizationBps: 8_000,
            baseVariableRateRayPerYear: 1_000_000_000,
            variableSlope1RayPerYear: 2_000_000_000,
            variableSlope2RayPerYear: 3_000_000_000,
            supplyCap: 1_000_000e18,
            borrowCap: 700_000e18
        });
        uint256 marketId = h.createPooledMarket(params);

        uint16 minLtvBps = uint16(bound(uint256(minLtvBpsRaw), 0, 9_999));
        uint16 maxLtvBps = uint16(bound(uint256(maxLtvBpsRaw), uint256(minLtvBps), 9_999));
        uint16 minReserveFactorBps = uint16(bound(uint256(minReserveFactorBpsRaw), 0, 10_000));
        uint16 maxReserveFactorBps =
            uint16(bound(uint256(maxReserveFactorBpsRaw), uint256(minReserveFactorBps), 10_000));
        h.setPooledGlobalBounds(minLtvBps, maxLtvBps, minReserveFactorBps, maxReserveFactorBps);

        uint16 ltvBps = uint16(bound(uint256(ltvBpsRaw), uint256(minLtvBps), uint256(maxLtvBps)));
        uint16 liquidationThresholdBps =
            uint16(bound(uint256(liquidationThresholdBpsRaw), uint256(ltvBps) + 1, 10_000));
        uint16 liquidationBonusBps = uint16(bound(uint256(liquidationBonusBpsRaw), 0, 10_000));
        uint16 liquidationProtocolFeeBps = uint16(bound(uint256(liquidationProtocolFeeBpsRaw), 0, 10_000));
        uint16 reserveFactorBps =
            uint16(bound(uint256(reserveFactorBpsRaw), uint256(minReserveFactorBps), uint256(maxReserveFactorBps)));
        uint16 optimalUtilizationBps = uint16(bound(uint256(optimalUtilizationBpsRaw), 0, 10_000));

        h.setPooledMarketFlags(marketId, active, paused, frozen);
        h.setPooledMarketCaps(marketId, supplyCap, borrowCap);
        h.setPooledRiskParams(
            marketId, ltvBps, liquidationThresholdBps, liquidationBonusBps, liquidationProtocolFeeBps
        );
        h.setPooledRateStrategy(
            marketId,
            reserveFactorBps,
            optimalUtilizationBps,
            baseVariableRateRayPerYear,
            variableSlope1RayPerYear,
            variableSlope2RayPerYear
        );
        h.setPooledOracleAdapter(oracleAdapter);
        h.setPooledSentinelAdapter(sentinelAdapter);

        IlmTypes.IlmMarket memory market = h.getMarket(marketId);
        assertEq(market.active, active);
        assertEq(market.paused, paused);
        assertEq(market.frozen, frozen);
        assertEq(market.supplyCap, supplyCap);
        assertEq(market.borrowCap, borrowCap);
        assertEq(market.ltvBps, ltvBps);
        assertEq(market.liquidationThresholdBps, liquidationThresholdBps);
        assertEq(market.liquidationBonusBps, liquidationBonusBps);
        assertEq(market.liquidationProtocolFeeBps, liquidationProtocolFeeBps);
        assertEq(market.reserveFactorBps, reserveFactorBps);
        assertEq(market.optimalUtilizationBps, optimalUtilizationBps);
        assertEq(market.baseVariableRateRayPerYear, baseVariableRateRayPerYear);
        assertEq(market.variableSlope1RayPerYear, variableSlope1RayPerYear);
        assertEq(market.variableSlope2RayPerYear, variableSlope2RayPerYear);

        (uint16 gotMinLtv, uint16 gotMaxLtv, uint16 gotMinReserveFactor, uint16 gotMaxReserveFactor) =
            h.getGlobalBounds();
        assertEq(gotMinLtv, minLtvBps);
        assertEq(gotMaxLtv, maxLtvBps);
        assertEq(gotMinReserveFactor, minReserveFactorBps);
        assertEq(gotMaxReserveFactor, maxReserveFactorBps);

        (address gotOracle, address gotSentinel) = h.getAdapters();
        assertEq(gotOracle, oracleAdapter);
        assertEq(gotSentinel, sentinelAdapter);
    }

    function test_settersAndCreate_rejectNonGovernance() public {
        IlmTypes.IlmCreateParams memory params = IlmTypes.IlmCreateParams({
            loanPoolId: 1,
            collateralPoolId: 2,
            moduleId: 1,
            ltvBps: 7_000,
            liquidationThresholdBps: 8_000,
            liquidationBonusBps: 500,
            liquidationProtocolFeeBps: 100,
            reserveFactorBps: 1_000,
            optimalUtilizationBps: 8_000,
            baseVariableRateRayPerYear: 1_000_000_000,
            variableSlope1RayPerYear: 2_000_000_000,
            variableSlope2RayPerYear: 3_000_000_000,
            supplyCap: 1_000_000e18,
            borrowCap: 700_000e18
        });

        vm.prank(address(0xAAAA));
        vm.expectRevert(IlmNotGovernance.selector);
        h.createPooledMarket(params);

        vm.prank(address(0xAAAA));
        vm.expectRevert(IlmNotGovernance.selector);
        h.setPooledGlobalBounds(1_000, 9_000, 100, 5_000);
    }

    function test_timelockCanCallGovernanceFunctions() public {
        vm.prank(TIMELOCK);
        h.setPooledGlobalBounds(900, 9_100, 50, 4_500);

        (uint16 minLtv, uint16 maxLtv, uint16 minReserveFactor, uint16 maxReserveFactor) = h.getGlobalBounds();
        assertEq(minLtv, 900);
        assertEq(maxLtv, 9_100);
        assertEq(minReserveFactor, 50);
        assertEq(maxReserveFactor, 4_500);
    }

    function test_settersRevertForUnknownMarket() public {
        vm.expectRevert(abi.encodeWithSelector(IlmMarketNotFound.selector, 999));
        h.setPooledMarketFlags(999, true, false, false);

        vm.expectRevert(abi.encodeWithSelector(IlmMarketNotFound.selector, 999));
        h.setPooledMarketCaps(999, 1, 1);

        vm.expectRevert(abi.encodeWithSelector(IlmMarketNotFound.selector, 999));
        h.setPooledRiskParams(999, 1_000, 1_001, 100, 10);

        vm.expectRevert(abi.encodeWithSelector(IlmMarketNotFound.selector, 999));
        h.setPooledRateStrategy(999, 100, 8_000, 1, 2, 3);
    }
}
