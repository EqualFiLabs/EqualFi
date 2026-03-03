// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibPerpsStorage} from "../../src/perps/LibPerpsStorage.sol";
import {PerpsLiquidationFacet} from "../../src/perps/PerpsLiquidationFacet.sol";
import {
    Perps_LiquidationPaused,
    Perps_PriceOutOfBounds,
    Perps_PriceStale,
    Perps_PositionHealthy,
    Perps_RiskLimitExceeded
} from "../../src/perps/PerpsErrors.sol";

contract PerpsLiquidationHarness is PerpsLiquidationFacet {
    uint256 internal oraclePriceX18 = 2_000e18;
    uint256 internal oracleUpdatedAt = block.timestamp;
    uint256 internal oracleDeviationBps;

    function setOracleData(uint256 priceX18, uint256 updatedAt, uint256 deviationBps) external {
        oraclePriceX18 = priceX18;
        oracleUpdatedAt = updatedAt;
        oracleDeviationBps = deviationBps;
    }

    function getMarkPrice(bytes32, address) external view returns (uint256 priceX18, uint256 updatedAt, uint256 deviationBps) {
        return (oraclePriceX18, oracleUpdatedAt, oracleDeviationBps);
    }

    function setOracleConfig(bytes32 marketId, uint256 maxStaleness, uint256 maxDeviationBps) external {
        if (maxStaleness > type(uint32).max || maxDeviationBps > type(uint32).max) revert Perps_RiskLimitExceeded();
        LibPerpsStorage.PerpsMarket storage market = LibPerpsStorage.s().markets[marketId];
        market.maxStaleness = uint32(maxStaleness);
        market.maxDeviationBps = uint32(maxDeviationBps);
    }

    function setGlobalLiquidationEnabled(bool enabled) external {
        LibPerpsStorage.s().globalLiquidationEnabled = enabled;
    }

    function seedMarket(
        bytes32 marketId,
        uint256 collateralPoolId,
        address collateralAsset,
        uint256 initialMarginBps,
        uint256 maintenanceMarginBps,
        uint256 liquidationIncentiveBpsMax,
        uint256 maxOpenInterest,
        uint256 maxLongOpenInterest,
        uint256 maxShortOpenInterest,
        uint256 maxSkewAbs,
        uint256 takerFeeBps,
        bool pauseLiquidation
    ) external {
        if (
            initialMarginBps > type(uint32).max || maintenanceMarginBps > type(uint32).max
                || liquidationIncentiveBpsMax > type(uint32).max || takerFeeBps > type(uint32).max
        ) {
            revert Perps_RiskLimitExceeded();
        }

        LibPerpsStorage.PerpsMarket storage market = LibPerpsStorage.s().markets[marketId];
        market.marketId = marketId;
        market.collateralPoolId = collateralPoolId;
        market.collateralAsset = collateralAsset;
        market.indexAsset = address(0xB0B);
        market.longEnabled = true;
        market.shortEnabled = true;
        market.initialMarginBps = uint32(initialMarginBps);
        market.maintenanceMarginBps = uint32(maintenanceMarginBps);
        market.maxLeverageBps = 50_000;
        market.liquidationIncentiveBpsMax = uint32(liquidationIncentiveBpsMax);
        market.maxOpenInterest = maxOpenInterest;
        market.maxLongOpenInterest = maxLongOpenInterest;
        market.maxShortOpenInterest = maxShortOpenInterest;
        market.maxSkewAbs = maxSkewAbs;
        market.takerFeeBps = uint32(takerFeeBps);
        market.oracleAdapter = address(this);
        market.maxStaleness = type(uint32).max;
        market.maxDeviationBps = 2_000;
        market.pauseLiquidation = pauseLiquidation;
        market.exists = true;
    }

    function seedMarketState(
        bytes32 marketId,
        uint256 openInterestLong,
        uint256 openInterestShort,
        int256 skew,
        int256 cumulativeFundingLongX18,
        int256 cumulativeFundingShortX18,
        uint256 lastFundingTs,
        uint256 insuranceBalance,
        uint256 insuranceTarget,
        uint256 badDebt,
        uint256 lpFeeIndexX18,
        uint256 protocolFeesAccrued
    ) external {
        if (lastFundingTs > type(uint64).max) revert Perps_RiskLimitExceeded();
        LibPerpsStorage.PerpsMarketState storage state = LibPerpsStorage.s().marketState[marketId];
        state.openInterestLong = openInterestLong;
        state.openInterestShort = openInterestShort;
        state.skew = skew;
        state.cumulativeFundingLongX18 = cumulativeFundingLongX18;
        state.cumulativeFundingShortX18 = cumulativeFundingShortX18;
        state.lastFundingTs = uint64(lastFundingTs);
        state.insuranceBalance = insuranceBalance;
        state.insuranceTarget = insuranceTarget;
        state.badDebt = badDebt;
        state.lpFeeIndexX18 = lpFeeIndexX18;
        state.protocolFeesAccrued = protocolFeesAccrued;
    }

    function seedAccount(bytes32 accountId, uint256 tokenId, uint256 nonce, bool exists) external {
        if (nonce > type(uint64).max) revert Perps_RiskLimitExceeded();
        LibPerpsStorage.PerpsAccount storage account = LibPerpsStorage.s().accounts[accountId];
        account.accountId = accountId;
        account.positionKey = keccak256(abi.encode(accountId, tokenId));
        account.positionTokenId = tokenId;
        account.nonce = uint64(nonce);
        account.exists = exists;
    }

    function setAccountCollateral(bytes32 accountId, bytes32 marketId, uint256 amount) external {
        LibPerpsStorage.Layout storage ps = LibPerpsStorage.s();
        uint256 previous = ps.accountCollateral[accountId][marketId];
        ps.accountCollateral[accountId][marketId] = amount;

        LibPerpsStorage.PerpsMarketState storage state = ps.marketState[marketId];
        if (amount > previous) {
            state.reservedCollateral += amount - previous;
        } else if (amount < previous) {
            state.reservedCollateral -= previous - amount;
        }
    }

    function seedPosition(
        bytes32 marketId,
        bytes32 accountId,
        bool isLong,
        uint256 sizeUsdX18,
        uint256 entryPriceX18,
        int256 entryFundingX18
    ) external {
        LibPerpsStorage.PerpsPosition storage position = LibPerpsStorage.s().positions[marketId][accountId][isLong];
        position.isLong = isLong;
        position.sizeUsdX18 = sizeUsdX18;
        position.collateralAmount = LibPerpsStorage.s().accountCollateral[accountId][marketId];
        position.entryPriceX18 = entryPriceX18;
        position.entryFundingX18 = entryFundingX18;
        position.lastIncreaseTs = uint64(block.timestamp);
    }

    function setDomainState(uint256 isolatedTrackedBalance, uint256 isolatedLiabilities, uint256 isolatedEncumbered) external {
        LibPerpsStorage.PerpsDomainState storage ds = LibPerpsStorage.s().domainState;
        ds.isolatedTrackedBalance = isolatedTrackedBalance;
        ds.isolatedLiabilities = isolatedLiabilities;
        ds.isolatedEncumbered = isolatedEncumbered;
    }

    function seedFeePool(uint256 poolId, address underlying, uint256 totalDeposits, uint256 trackedBalance) external {
        LibAppStorage.s().pools[poolId].initialized = true;
        LibAppStorage.s().pools[poolId].underlying = underlying;
        LibAppStorage.s().pools[poolId].totalDeposits = totalDeposits;
        LibAppStorage.s().pools[poolId].trackedBalance = trackedBalance;
    }

    function configureFeeRouter(uint256 treasuryBps, uint256 activeCreditBps, address treasury) external {
        if (treasuryBps > type(uint16).max || activeCreditBps > type(uint16).max) {
            revert Perps_RiskLimitExceeded();
        }

        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        store.treasury = treasury;
        store.treasuryShareConfigured = true;
        store.treasuryShareBps = uint16(treasuryBps);
        store.activeCreditShareConfigured = true;
        store.activeCreditShareBps = uint16(activeCreditBps);
    }

    function getAccountCollateral(bytes32 accountId, bytes32 marketId) external view returns (uint256) {
        return LibPerpsStorage.s().accountCollateral[accountId][marketId];
    }

    function getMarketState(bytes32 marketId) external view returns (LibPerpsStorage.PerpsMarketState memory) {
        return LibPerpsStorage.s().marketState[marketId];
    }

    function getPosition(bytes32 marketId, bytes32 accountId, bool isLong)
        external
        view
        returns (LibPerpsStorage.PerpsPosition memory)
    {
        return LibPerpsStorage.s().positions[marketId][accountId][isLong];
    }

    function getDomainState() external view returns (LibPerpsStorage.PerpsDomainState memory) {
        return LibPerpsStorage.s().domainState;
    }

    function getPoolTrackedBalance(uint256 poolId) external view returns (uint256) {
        return LibAppStorage.s().pools[poolId].trackedBalance;
    }

    function getPoolYieldReserve(uint256 poolId) external view returns (uint256) {
        return LibAppStorage.s().pools[poolId].yieldReserve;
    }

    function getPoolFeeIndex(uint256 poolId) external view returns (uint256) {
        return LibAppStorage.s().pools[poolId].feeIndex;
    }
}

contract PerpsLiquidationFacetTest is Test {
    bytes32 internal constant MARKET_A = keccak256("perps.market.liq.a");
    bytes32 internal constant MARKET_B = keccak256("perps.market.liq.b");
    bytes32 internal constant ACCOUNT = keccak256("perps.account.liq");
    uint256 internal constant FEE_POOL = 101;

    function test_liquidate_revertsWhenHealthy() public {
        PerpsLiquidationHarness h = new PerpsLiquidationHarness();
        _seedBaseMarket(h, MARKET_A, 0, 500);
        h.seedAccount(ACCOUNT, 1, 0, true);
        h.setAccountCollateral(ACCOUNT, MARKET_A, 200e18);
        h.seedPosition(MARKET_A, ACCOUNT, true, 1_000e18, 2_000e18, 0);
        h.seedMarketState(MARKET_A, 1_000e18, 0, int256(1_000e18), 0, 0, 0, 0, 0, 0, 0, 0);
        h.setDomainState(1_000_000e18, 0, 0);

        vm.expectRevert(Perps_PositionHealthy.selector);
        h.liquidate(
            PerpsLiquidationFacet.LiquidationParams({
                marketId: MARKET_A,
                accountId: ACCOUNT,
                isLong: true,
                executionPriceX18: 2_000e18,
                feePoolId: FEE_POOL
            })
        );
    }

    function test_liquidate_revertsWhenGlobalOrMarketPause() public {
        PerpsLiquidationHarness h = new PerpsLiquidationHarness();
        _seedBaseMarket(h, MARKET_A, 0, 500);
        h.seedAccount(ACCOUNT, 1, 0, true);
        h.setAccountCollateral(ACCOUNT, MARKET_A, 10e18);
        h.seedPosition(MARKET_A, ACCOUNT, true, 1_000e18, 2_000e18, 0);
        h.seedMarketState(MARKET_A, 1_000e18, 0, int256(1_000e18), 0, 0, 0, 0, 0, 0, 0, 0);

        h.setGlobalLiquidationEnabled(false);
        vm.expectRevert(abi.encodeWithSelector(Perps_LiquidationPaused.selector, MARKET_A));
        h.liquidate(
            PerpsLiquidationFacet.LiquidationParams({
                marketId: MARKET_A,
                accountId: ACCOUNT,
                isLong: true,
                executionPriceX18: 2_000e18,
                feePoolId: FEE_POOL
            })
        );

        h.seedMarket(MARKET_A, FEE_POOL, address(0xC011A7), 1000, 700, 500, 5_000_000e18, 3_000_000e18, 3_000_000e18, 1_000_000e18, 0, true);
        h.setGlobalLiquidationEnabled(true);
        vm.expectRevert(abi.encodeWithSelector(Perps_LiquidationPaused.selector, MARKET_A));
        h.liquidate(
            PerpsLiquidationFacet.LiquidationParams({
                marketId: MARKET_A,
                accountId: ACCOUNT,
                isLong: true,
                executionPriceX18: 2_000e18,
                feePoolId: FEE_POOL
            })
        );
    }

    function test_liquidate_revertsWhenOracleStale() public {
        PerpsLiquidationHarness h = new PerpsLiquidationHarness();
        _seedBaseMarket(h, MARKET_A, 0, 500);
        h.seedAccount(ACCOUNT, 1, 0, true);
        h.setAccountCollateral(ACCOUNT, MARKET_A, 10e18);
        h.seedPosition(MARKET_A, ACCOUNT, true, 1_000e18, 2_000e18, 0);
        h.seedMarketState(MARKET_A, 1_000e18, 0, int256(1_000e18), 0, 0, 0, 0, 0, 0, 0, 0);
        h.setDomainState(1_000_000e18, 0, 0);

        vm.warp(100);
        h.setOracleConfig(MARKET_A, 1, 2_000);
        h.setOracleData(2_000e18, 98, 0);
        vm.expectRevert(abi.encodeWithSelector(Perps_PriceStale.selector, 98, uint32(1)));
        h.liquidate(
            PerpsLiquidationFacet.LiquidationParams({
                marketId: MARKET_A,
                accountId: ACCOUNT,
                isLong: true,
                executionPriceX18: 2_000e18,
                feePoolId: FEE_POOL
            })
        );
    }

    function test_liquidate_revertsWhenOracleOutOfBounds() public {
        PerpsLiquidationHarness h = new PerpsLiquidationHarness();
        _seedBaseMarket(h, MARKET_A, 0, 500);
        h.seedAccount(ACCOUNT, 1, 0, true);
        h.setAccountCollateral(ACCOUNT, MARKET_A, 10e18);
        h.seedPosition(MARKET_A, ACCOUNT, true, 1_000e18, 2_000e18, 0);
        h.seedMarketState(MARKET_A, 1_000e18, 0, int256(1_000e18), 0, 0, 0, 0, 0, 0, 0, 0);
        h.setDomainState(1_000_000e18, 0, 0);

        h.setOracleConfig(MARKET_A, 1 days, 500);
        h.setOracleData(2_000e18, block.timestamp, 0);
        vm.expectRevert(Perps_PriceOutOfBounds.selector);
        h.liquidate(
            PerpsLiquidationFacet.LiquidationParams({
                marketId: MARKET_A,
                accountId: ACCOUNT,
                isLong: true,
                executionPriceX18: 2_300e18,
                feePoolId: FEE_POOL
            })
        );

        h.setOracleData(2_300e18, block.timestamp, 700);
        vm.expectRevert(Perps_PriceOutOfBounds.selector);
        h.liquidate(
            PerpsLiquidationFacet.LiquidationParams({
                marketId: MARKET_A,
                accountId: ACCOUNT,
                isLong: true,
                executionPriceX18: 2_300e18,
                feePoolId: FEE_POOL
            })
        );
    }

    function test_liquidate_partialClose_rewardBoundedByConfig() public {
        PerpsLiquidationHarness h = new PerpsLiquidationHarness();
        _seedBaseMarket(h, MARKET_A, 0, 500);
        h.seedAccount(ACCOUNT, 1, 0, true);
        h.setAccountCollateral(ACCOUNT, MARKET_A, 60e18);
        h.seedPosition(MARKET_A, ACCOUNT, true, 1_000e18, 2_000e18, 0);
        h.seedMarketState(MARKET_A, 1_000e18, 0, int256(1_000e18), 0, 0, 0, 0, 0, 0, 0, 0);
        h.setDomainState(1_000_000e18, 0, 0);

        (LibPerpsStorage.SettlementDelta memory delta, uint256 closeSize) = h.liquidate(
            PerpsLiquidationFacet.LiquidationParams({
                marketId: MARKET_A,
                accountId: ACCOUNT,
                isLong: true,
                executionPriceX18: 2_000e18,
                feePoolId: FEE_POOL
            })
        );

        assertEq(closeSize, 500e18, "partial deterministic close expected");
        assertEq(delta.liquidatorReward, 25e18, "5% reward cap on closed notional");

        LibPerpsStorage.PerpsPosition memory remaining = h.getPosition(MARKET_A, ACCOUNT, true);
        assertEq(remaining.sizeUsdX18, 500e18);
        assertEq(h.getAccountCollateral(ACCOUNT, MARKET_A), 35e18);
    }

    function test_liquidate_deficitWaterfall_collateralThenInsuranceThenBadDebt_marketLocal() public {
        PerpsLiquidationHarness h = new PerpsLiquidationHarness();
        _seedBaseMarket(h, MARKET_A, 0, 0);
        _seedBaseMarket(h, MARKET_B, 0, 0);

        h.seedAccount(ACCOUNT, 1, 0, true);
        h.setAccountCollateral(ACCOUNT, MARKET_A, 50e18);
        h.seedPosition(MARKET_A, ACCOUNT, true, 1_000e18, 2_000e18, 0);

        h.seedMarketState(MARKET_A, 1_000e18, 0, int256(1_000e18), 0, 0, 0, 80e18, 80e18, 0, 0, 0);
        h.seedMarketState(MARKET_B, 0, 0, 0, 0, 0, 0, 0, 0, 123e18, 0, 0);
        h.setDomainState(1_000_000e18, 0, 0);
        h.setOracleData(1_000e18, block.timestamp, 0);

        (LibPerpsStorage.SettlementDelta memory delta, uint256 closeSize) = h.liquidate(
            PerpsLiquidationFacet.LiquidationParams({
                marketId: MARKET_A,
                accountId: ACCOUNT,
                isLong: true,
                executionPriceX18: 1_000e18,
                feePoolId: FEE_POOL
            })
        );

        assertEq(closeSize, 1_000e18, "full close expected");
        assertEq(delta.realizedPnl, -int256(500e18));
        assertEq(delta.insuranceUsed, 80e18);
        assertEq(delta.badDebtDelta, 320e18);

        assertEq(h.getAccountCollateral(ACCOUNT, MARKET_A), 0);

        LibPerpsStorage.PerpsMarketState memory a = h.getMarketState(MARKET_A);
        LibPerpsStorage.PerpsMarketState memory b = h.getMarketState(MARKET_B);
        assertEq(a.insuranceBalance, 0);
        assertEq(a.badDebt, 320e18);
        assertEq(b.badDebt, 123e18, "other market bad debt must remain untouched");
    }

    function test_liquidate_protocolFeeInsurancePriority_thenOverflow7030() public {
        PerpsLiquidationHarness h = new PerpsLiquidationHarness();
        _seedBaseMarket(h, MARKET_A, 800, 0);
        h.seedFeePool(FEE_POOL, address(0xC011A7), 1_000e18, 2_000_000e18);
        h.configureFeeRouter(0, 0, address(0));

        h.seedAccount(ACCOUNT, 1, 0, true);
        h.setAccountCollateral(ACCOUNT, MARKET_A, 60e18);
        h.seedPosition(MARKET_A, ACCOUNT, true, 1_000e18, 2_000e18, 0);
        h.seedMarketState(MARKET_A, 1_000e18, 0, int256(1_000e18), 0, 0, 0, 90e18, 100e18, 0, 0, 0);
        h.setDomainState(1_000_000e18, 0, 0);

        uint256 trackedBefore = h.getPoolTrackedBalance(FEE_POOL);
        uint256 feeIndexBefore = h.getPoolFeeIndex(FEE_POOL);

        (LibPerpsStorage.SettlementDelta memory delta,) = h.liquidate(
            PerpsLiquidationFacet.LiquidationParams({
                marketId: MARKET_A,
                accountId: ACCOUNT,
                isLong: true,
                executionPriceX18: 2_000e18,
                feePoolId: FEE_POOL
            })
        );

        assertEq(delta.liquidationProtocolFee, 40e18);
        assertEq(delta.lpFee, 21e18);
        assertEq(delta.protocolFee, 9e18);

        LibPerpsStorage.PerpsMarketState memory state = h.getMarketState(MARKET_A);
        assertEq(state.insuranceBalance, 100e18, "insurance target should be filled first");
        assertEq(state.lpFeeIndexX18, 1_050_000_000_000_000_000, "overflow LP share index");
        assertEq(state.protocolFeesAccrued, 9e18, "overflow protocol share");

        assertEq(h.getPoolTrackedBalance(FEE_POOL), trackedBefore + 9e18, "explicit outbound credit from perps domain");
        assertEq(h.getPoolYieldReserve(FEE_POOL), 9e18);
        assertEq(h.getPoolFeeIndex(FEE_POOL) - feeIndexBefore, 9e15);
    }

    /// @dev Property 4: Liquidation Executor Convergence
    /// Validates: Requirements 20.5, 20.6
    function testFuzz_property4_liquidationExecutorConvergence(
        uint96 collateralSeed,
        uint96 sizeSeed,
        uint16 dropBpsSeed,
        uint96 insuranceSeed,
        uint96 insuranceTargetSeed,
        uint16 liqFeeBpsSeed,
        uint16 liqRewardBpsSeed
    ) public {
        uint256 collateral = bound(uint256(collateralSeed), 10e18, 2_000e18);
        uint256 sizeUsdX18 = bound(uint256(sizeSeed), 100e18, 10_000e18);
        uint256 dropBps = bound(uint256(dropBpsSeed), 0, 5_000);
        uint256 insurance = bound(uint256(insuranceSeed), 0, 2_000e18);
        uint256 insuranceTarget = bound(uint256(insuranceTargetSeed), insurance, insurance + 2_000e18);
        uint256 liqFeeBps = bound(uint256(liqFeeBpsSeed), 0, 1_500);
        uint256 liqRewardBps = bound(uint256(liqRewardBpsSeed), 0, 1_000);

        uint256 entryPriceX18 = 2_000e18;
        uint256 executionPriceX18 = (entryPriceX18 * (10_000 - dropBps)) / 10_000;

        int256 unrealizedPnl = -int256((sizeUsdX18 * dropBps) / 10_000);
        int256 equity = int256(collateral) + unrealizedPnl;
        int256 maintenance = int256((sizeUsdX18 * 700) / 10_000);
        vm.assume(equity < maintenance);

        PerpsLiquidationHarness hA = new PerpsLiquidationHarness();
        PerpsLiquidationHarness hB = new PerpsLiquidationHarness();

        _seedConvergenceScenario(hA, sizeUsdX18, collateral, insurance, insuranceTarget, liqFeeBps, liqRewardBps);
        _seedConvergenceScenario(hB, sizeUsdX18, collateral, insurance, insuranceTarget, liqFeeBps, liqRewardBps);
        hA.setOracleData(executionPriceX18, block.timestamp, 0);
        hB.setOracleData(executionPriceX18, block.timestamp, 0);

        address liquidatorA = address(0xAAA1);
        address liquidatorB = address(0xBBB2);

        vm.prank(liquidatorA);
        (LibPerpsStorage.SettlementDelta memory deltaA, uint256 closeA) = hA.liquidate(
            PerpsLiquidationFacet.LiquidationParams({
                marketId: MARKET_A,
                accountId: ACCOUNT,
                isLong: true,
                executionPriceX18: executionPriceX18,
                feePoolId: FEE_POOL
            })
        );

        vm.prank(liquidatorB);
        (LibPerpsStorage.SettlementDelta memory deltaB, uint256 closeB) = hB.liquidate(
            PerpsLiquidationFacet.LiquidationParams({
                marketId: MARKET_A,
                accountId: ACCOUNT,
                isLong: true,
                executionPriceX18: executionPriceX18,
                feePoolId: FEE_POOL
            })
        );

        assertEq(closeA, closeB);

        assertEq(deltaA.realizedPnl, deltaB.realizedPnl);
        assertEq(deltaA.fundingPaid, deltaB.fundingPaid);
        assertEq(deltaA.lpFee, deltaB.lpFee);
        assertEq(deltaA.protocolFee, deltaB.protocolFee);
        assertEq(deltaA.liquidationProtocolFee, deltaB.liquidationProtocolFee);
        assertEq(deltaA.liquidatorReward, deltaB.liquidatorReward);
        assertEq(deltaA.insuranceUsed, deltaB.insuranceUsed);
        assertEq(deltaA.badDebtDelta, deltaB.badDebtDelta);

        assertEq(hA.getAccountCollateral(ACCOUNT, MARKET_A), hB.getAccountCollateral(ACCOUNT, MARKET_A));

        LibPerpsStorage.PerpsMarketState memory mA = hA.getMarketState(MARKET_A);
        LibPerpsStorage.PerpsMarketState memory mB = hB.getMarketState(MARKET_A);
        assertEq(mA.openInterestLong, mB.openInterestLong);
        assertEq(mA.openInterestShort, mB.openInterestShort);
        assertEq(mA.skew, mB.skew);
        assertEq(mA.insuranceBalance, mB.insuranceBalance);
        assertEq(mA.badDebt, mB.badDebt);
        assertEq(mA.lpFeeIndexX18, mB.lpFeeIndexX18);
        assertEq(mA.protocolFeesAccrued, mB.protocolFeesAccrued);

        LibPerpsStorage.PerpsPosition memory pA = hA.getPosition(MARKET_A, ACCOUNT, true);
        LibPerpsStorage.PerpsPosition memory pB = hB.getPosition(MARKET_A, ACCOUNT, true);
        assertEq(pA.sizeUsdX18, pB.sizeUsdX18);
        assertEq(pA.entryPriceX18, pB.entryPriceX18);

        LibPerpsStorage.PerpsDomainState memory dA = hA.getDomainState();
        LibPerpsStorage.PerpsDomainState memory dB = hB.getDomainState();
        assertEq(dA.isolatedTrackedBalance, dB.isolatedTrackedBalance);
        assertEq(dA.isolatedLiabilities, dB.isolatedLiabilities);
        assertEq(dA.isolatedEncumbered, dB.isolatedEncumbered);

        assertEq(hA.getPoolTrackedBalance(FEE_POOL), hB.getPoolTrackedBalance(FEE_POOL));
        assertEq(hA.getPoolYieldReserve(FEE_POOL), hB.getPoolYieldReserve(FEE_POOL));
        assertEq(hA.getPoolFeeIndex(FEE_POOL), hB.getPoolFeeIndex(FEE_POOL));
    }

    function _seedBaseMarket(PerpsLiquidationHarness h, bytes32 marketId, uint256 takerFeeBps, uint256 liquidationIncentiveBps)
        internal
    {
        h.seedMarket(
            marketId,
            FEE_POOL,
            address(0xC011A7),
            1_000,
            700,
            liquidationIncentiveBps,
            5_000_000e18,
            3_000_000e18,
            3_000_000e18,
            1_000_000e18,
            takerFeeBps,
            false
        );
        h.setGlobalLiquidationEnabled(true);
    }

    function _seedConvergenceScenario(
        PerpsLiquidationHarness h,
        uint256 sizeUsdX18,
        uint256 collateral,
        uint256 insurance,
        uint256 insuranceTarget,
        uint256 liqFeeBps,
        uint256 liqRewardBps
    ) internal {
        _seedBaseMarket(h, MARKET_A, liqFeeBps, liqRewardBps);
        h.seedFeePool(FEE_POOL, address(0xC011A7), 1_000e18, 2_000_000e18);
        h.configureFeeRouter(0, 0, address(0));

        h.seedAccount(ACCOUNT, 1, 0, true);
        h.setAccountCollateral(ACCOUNT, MARKET_A, collateral);
        h.seedPosition(MARKET_A, ACCOUNT, true, sizeUsdX18, 2_000e18, 0);
        h.seedMarketState(MARKET_A, sizeUsdX18, 0, int256(sizeUsdX18), 0, 0, 0, insurance, insuranceTarget, 0, 0, 0);
        h.setDomainState(5_000_000e18, 0, 0);
    }
}
