// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibPerpsRisk} from "../../src/perps/LibPerpsRisk.sol";
import {LibPerpsStorage} from "../../src/perps/LibPerpsStorage.sol";
import {Perps_InsufficientMargin, Perps_PositionHealthy, Perps_RiskLimitExceeded} from "../../src/perps/PerpsErrors.sol";

contract PerpsRiskHarness {
    function computeHealth(LibPerpsStorage.PerpsMarket calldata market, LibPerpsRisk.HealthState calldata state)
        external
        pure
        returns (LibPerpsRisk.HealthResult memory)
    {
        return LibPerpsRisk.computeHealth(market, state);
    }

    function previewHealth(
        LibPerpsStorage.PerpsMarket calldata market,
        LibPerpsRisk.HealthState calldata state,
        LibPerpsRisk.HealthDelta calldata delta
    ) external pure returns (LibPerpsRisk.HealthResult memory result, LibPerpsRisk.HealthState memory postState) {
        return LibPerpsRisk.previewHealth(market, state, delta);
    }

    function enforceOpenRisk(LibPerpsStorage.PerpsMarket calldata market, LibPerpsRisk.HealthState calldata state)
        external
        pure
        returns (LibPerpsRisk.HealthResult memory)
    {
        return LibPerpsRisk.enforceOpenRisk(market, state);
    }

    function enforceMaintenanceMargin(LibPerpsStorage.PerpsMarket calldata market, LibPerpsRisk.HealthState calldata state)
        external
        pure
        returns (LibPerpsRisk.HealthResult memory)
    {
        return LibPerpsRisk.enforceMaintenanceMargin(market, state);
    }

    function enforceLiquidatable(LibPerpsStorage.PerpsMarket calldata market, LibPerpsRisk.HealthState calldata state)
        external
        pure
        returns (LibPerpsRisk.HealthResult memory)
    {
        return LibPerpsRisk.enforceLiquidatable(market, state);
    }

    function previewOpenInterestAfterDelta(
        LibPerpsStorage.PerpsMarket calldata market,
        LibPerpsStorage.PerpsMarketState calldata state,
        bool isLong,
        int256 sizeDeltaUsdX18
    ) external pure returns (LibPerpsRisk.OpenInterestPreview memory preview) {
        return LibPerpsRisk.previewOpenInterestAfterDelta(market, state, isLong, sizeDeltaUsdX18);
    }
}

contract PerpsRiskPropertyTest is Test {
    PerpsRiskHarness internal h;

    function setUp() public {
        h = new PerpsRiskHarness();
    }

    function test_marginAndLeverage_checksAndReverts() public {
        LibPerpsStorage.PerpsMarket memory market = _defaultRiskMarket();
        LibPerpsRisk.HealthState memory state = LibPerpsRisk.HealthState({
            collateralValueUsdX18: 2_000e18,
            positionNotionalUsdX18: 5_000e18,
            unrealizedPnlUsdX18: 0,
            fundingAccruedUsdX18: 0,
            feesAccruedUsdX18: 0
        });

        LibPerpsRisk.HealthResult memory result = h.computeHealth(market, state);
        assertEq(result.initialMarginRequiredUsdX18, 500e18);
        assertEq(result.maintenanceMarginRequiredUsdX18, 350e18);
        assertEq(result.minEquityForLeverageUsdX18, 1_000e18);
        assertEq(result.openingMarginRequiredUsdX18, 1_000e18);
        assertTrue(result.meetsInitialMargin);
        assertTrue(result.meetsMaintenanceMargin);

        h.enforceOpenRisk(market, state);

        state.collateralValueUsdX18 = 900e18;
        vm.expectRevert(abi.encodeWithSelector(Perps_InsufficientMargin.selector, 1_000e18, 900e18));
        h.enforceOpenRisk(market, state);
    }

    function test_liquidatable_revertsWhenHealthy_andPassesWhenBelowMaintenance() public {
        LibPerpsStorage.PerpsMarket memory market = _defaultRiskMarket();
        LibPerpsRisk.HealthState memory healthy = LibPerpsRisk.HealthState({
            collateralValueUsdX18: 1_200e18,
            positionNotionalUsdX18: 5_000e18,
            unrealizedPnlUsdX18: 0,
            fundingAccruedUsdX18: 0,
            feesAccruedUsdX18: 0
        });

        vm.expectRevert(Perps_PositionHealthy.selector);
        h.enforceLiquidatable(market, healthy);

        LibPerpsRisk.HealthState memory unhealthy = LibPerpsRisk.HealthState({
            collateralValueUsdX18: 300e18,
            positionNotionalUsdX18: 5_000e18,
            unrealizedPnlUsdX18: -100e18,
            fundingAccruedUsdX18: 0,
            feesAccruedUsdX18: 0
        });
        LibPerpsRisk.HealthResult memory result = h.enforceLiquidatable(market, unhealthy);
        assertFalse(result.meetsMaintenanceMargin);
    }

    /// @dev Property 2: Health Monotonicity
    /// Validates: Requirements 10.1, 18.2
    function testFuzz_property2_healthMonotonicity_equityImprovementsNeverWorsenBuffer(
        uint96 collateralSeed,
        uint96 notionalSeed,
        uint96 feesSeed,
        uint96 fundingSeed,
        uint96 pnlGainSeed,
        uint96 pnlLossSeed,
        uint96 collateralBoostSeed,
        uint96 pnlBoostSeed
    ) public {
        LibPerpsStorage.PerpsMarket memory market = _defaultRiskMarket();

        uint256 collateral = bound(uint256(collateralSeed), 1e18, 1e26);
        uint256 notional = bound(uint256(notionalSeed), 1e18, 1e26);
        uint256 fees = bound(uint256(feesSeed), 0, 5e24);
        uint256 funding = bound(uint256(fundingSeed), 0, 5e24);
        int256 pnl = int256(bound(uint256(pnlGainSeed), 0, 5e24)) - int256(bound(uint256(pnlLossSeed), 0, 5e24));
        uint256 collateralBoost = bound(uint256(collateralBoostSeed), 1, 5e24);
        int256 pnlBoost = int256(bound(uint256(pnlBoostSeed), 0, 5e24));

        LibPerpsRisk.HealthState memory baseState = LibPerpsRisk.HealthState({
            collateralValueUsdX18: collateral,
            positionNotionalUsdX18: notional,
            unrealizedPnlUsdX18: pnl,
            fundingAccruedUsdX18: int256(funding),
            feesAccruedUsdX18: fees
        });

        LibPerpsRisk.HealthResult memory base = h.computeHealth(market, baseState);
        LibPerpsRisk.HealthDelta memory delta = LibPerpsRisk.HealthDelta({
            collateralDeltaUsdX18: int256(collateralBoost),
            positionNotionalDeltaUsdX18: 0,
            unrealizedPnlDeltaUsdX18: pnlBoost,
            fundingAccruedDeltaUsdX18: 0,
            feeDeltaUsdX18: 0
        });

        (LibPerpsRisk.HealthResult memory improved,) = h.previewHealth(market, baseState, delta);
        assertGe(improved.equityUsdX18, base.equityUsdX18);
        assertEq(improved.maintenanceMarginRequiredUsdX18, base.maintenanceMarginRequiredUsdX18);
        assertGe(improved.maintenanceBufferUsdX18, base.maintenanceBufferUsdX18);
    }

    /// @dev Property 2: Health Monotonicity
    /// Validates: Requirements 10.1, 18.2
    function testFuzz_property2_healthMonotonicity_notionalReductionImprovesRisk(
        uint96 collateralSeed,
        uint96 notionalSeed,
        uint96 reductionSeed,
        uint96 feesSeed,
        uint96 fundingSeed,
        uint96 pnlGainSeed,
        uint96 pnlLossSeed
    ) public {
        LibPerpsStorage.PerpsMarket memory market = _defaultRiskMarket();

        uint256 collateral = bound(uint256(collateralSeed), 1e18, 1e26);
        uint256 notional = bound(uint256(notionalSeed), 1e18, 1e26);
        uint256 reduction = bound(uint256(reductionSeed), 1, notional);
        uint256 fees = bound(uint256(feesSeed), 0, 5e24);
        uint256 funding = bound(uint256(fundingSeed), 0, 5e24);
        int256 pnl = int256(bound(uint256(pnlGainSeed), 0, 5e24)) - int256(bound(uint256(pnlLossSeed), 0, 5e24));

        LibPerpsRisk.HealthState memory baseState = LibPerpsRisk.HealthState({
            collateralValueUsdX18: collateral,
            positionNotionalUsdX18: notional,
            unrealizedPnlUsdX18: pnl,
            fundingAccruedUsdX18: int256(funding),
            feesAccruedUsdX18: fees
        });

        LibPerpsRisk.HealthResult memory base = h.computeHealth(market, baseState);
        LibPerpsRisk.HealthDelta memory reduceNotional = LibPerpsRisk.HealthDelta({
            collateralDeltaUsdX18: 0,
            positionNotionalDeltaUsdX18: -int256(reduction),
            unrealizedPnlDeltaUsdX18: 0,
            fundingAccruedDeltaUsdX18: 0,
            feeDeltaUsdX18: 0
        });

        (LibPerpsRisk.HealthResult memory improved,) = h.previewHealth(market, baseState, reduceNotional);
        assertLe(improved.maintenanceMarginRequiredUsdX18, base.maintenanceMarginRequiredUsdX18);
        assertLe(improved.openingMarginRequiredUsdX18, base.openingMarginRequiredUsdX18);
        assertGe(improved.maintenanceBufferUsdX18, base.maintenanceBufferUsdX18);
    }

    /// @dev Property 3: OI/Skew Cap Enforcement
    /// Validates: Requirements 10.1, 15.1
    function testFuzz_property3_oiSkewCapEnforcement_matchesExpectedOutcome(
        uint96 longSeed,
        uint96 shortSeed,
        uint96 maxLongSeed,
        uint96 maxShortSeed,
        uint96 maxOpenSeed,
        uint96 maxSkewSeed,
        uint96 deltaSeed,
        bool isLong
    ) public {
        LibPerpsStorage.PerpsMarket memory market = _defaultRiskMarket();
        market.maxLongOpenInterest = bound(uint256(maxLongSeed), 1e18, 1e26);
        market.maxShortOpenInterest = bound(uint256(maxShortSeed), 1e18, 1e26);
        market.maxOpenInterest = bound(uint256(maxOpenSeed), 1e18, 2e26);
        market.maxSkewAbs = bound(uint256(maxSkewSeed), 1e18, 1e26);

        uint256 longOi = bound(uint256(longSeed), 0, market.maxLongOpenInterest);
        uint256 shortOi = bound(uint256(shortSeed), 0, market.maxShortOpenInterest);

        if (longOi + shortOi > market.maxOpenInterest) {
            market.maxOpenInterest = longOi + shortOi;
        }

        uint256 delta = bound(uint256(deltaSeed), 0, 5e24);
        uint256 nextLong = isLong ? longOi + delta : longOi;
        uint256 nextShort = isLong ? shortOi : shortOi + delta;
        uint256 nextTotal = nextLong + nextShort;
        uint256 nextSkewAbs = _absDiff(nextLong, nextShort);

        bool exceeds = (market.maxOpenInterest != 0 && nextTotal > market.maxOpenInterest)
            || (market.maxLongOpenInterest != 0 && nextLong > market.maxLongOpenInterest)
            || (market.maxShortOpenInterest != 0 && nextShort > market.maxShortOpenInterest)
            || (market.maxSkewAbs != 0 && nextSkewAbs > market.maxSkewAbs);

        LibPerpsStorage.PerpsMarketState memory state;
        state.openInterestLong = longOi;
        state.openInterestShort = shortOi;
        state.skew = int256(longOi) - int256(shortOi);

        if (exceeds) {
            vm.expectRevert(Perps_RiskLimitExceeded.selector);
            h.previewOpenInterestAfterDelta(market, state, isLong, int256(delta));
            return;
        }

        LibPerpsRisk.OpenInterestPreview memory preview = h.previewOpenInterestAfterDelta(market, state, isLong, int256(delta));
        assertEq(preview.openInterestLong, nextLong);
        assertEq(preview.openInterestShort, nextShort);
        assertEq(preview.openInterestTotal, nextTotal);
    }

    function test_oiSkewCapEnforcement_revertsOnOverDecrease() public {
        LibPerpsStorage.PerpsMarket memory market = _defaultRiskMarket();
        LibPerpsStorage.PerpsMarketState memory state;
        state.openInterestLong = 100e18;
        state.openInterestShort = 50e18;
        state.skew = int256(50e18);

        vm.expectRevert(Perps_RiskLimitExceeded.selector);
        h.previewOpenInterestAfterDelta(market, state, true, -int256(101e18));
    }

    function _defaultRiskMarket() internal pure returns (LibPerpsStorage.PerpsMarket memory market) {
        market.maxLeverageBps = 50_000;
        market.initialMarginBps = 1_000;
        market.maintenanceMarginBps = 700;
        market.maxOpenInterest = 5_000_000e18;
        market.maxLongOpenInterest = 3_000_000e18;
        market.maxShortOpenInterest = 3_000_000e18;
        market.maxSkewAbs = 1_000_000e18;
    }

    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? a - b : b - a;
    }
}
