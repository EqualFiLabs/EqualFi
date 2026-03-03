// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibPerpsStorage} from "../../src/perps/LibPerpsStorage.sol";
import {LibPerpsSync} from "../../src/perps/LibPerpsSync.sol";
import {PerpsExecutionFacet} from "../../src/perps/PerpsExecutionFacet.sol";
import {PerpsLiquidationFacet} from "../../src/perps/PerpsLiquidationFacet.sol";
import {Perps_RiskLimitExceeded, Perps_SyncPaused} from "../../src/perps/PerpsErrors.sol";

contract PerpsSyncAccountHarness is PerpsExecutionFacet {
    function seedMarket(
        bytes32 marketId,
        uint256 collateralPoolId,
        address collateralAsset,
        uint256 maxSkewAbs,
        uint256 maxFundingVelocityBpsPerDay,
        bool pauseSync
    ) external {
        if (maxFundingVelocityBpsPerDay > type(uint32).max) revert Perps_RiskLimitExceeded();
        LibPerpsStorage.PerpsMarket storage market = LibPerpsStorage.s().markets[marketId];
        market.marketId = marketId;
        market.collateralPoolId = collateralPoolId;
        market.collateralAsset = collateralAsset;
        market.indexAsset = address(0xB0B);
        market.longEnabled = true;
        market.shortEnabled = true;
        market.maxLeverageBps = 50_000;
        market.initialMarginBps = 1_000;
        market.maintenanceMarginBps = 700;
        market.maxOpenInterest = 5_000_000e18;
        market.maxLongOpenInterest = 3_000_000e18;
        market.maxShortOpenInterest = 3_000_000e18;
        market.maxSkewAbs = maxSkewAbs;
        market.takerFeeBps = 100;
        market.maxFundingVelocityBpsPerDay = uint32(maxFundingVelocityBpsPerDay);
        market.pauseSync = pauseSync;
        market.exists = true;
    }

    function seedMarketState(
        bytes32 marketId,
        int256 skew,
        int256 cumulativeFundingLongX18,
        int256 cumulativeFundingShortX18,
        uint256 lastFundingTs,
        uint256 insuranceBalance,
        uint256 badDebt
    ) external {
        if (lastFundingTs > type(uint64).max) revert Perps_RiskLimitExceeded();
        LibPerpsStorage.PerpsMarketState storage state = LibPerpsStorage.s().marketState[marketId];
        state.skew = skew;
        state.cumulativeFundingLongX18 = cumulativeFundingLongX18;
        state.cumulativeFundingShortX18 = cumulativeFundingShortX18;
        state.lastFundingTs = uint64(lastFundingTs);
        state.insuranceBalance = insuranceBalance;
        state.badDebt = badDebt;
    }

    function seedAccount(bytes32 accountId, uint256 tokenId) external {
        LibPerpsStorage.PerpsAccount storage account = LibPerpsStorage.s().accounts[accountId];
        account.accountId = accountId;
        account.positionTokenId = tokenId;
        account.positionKey = keccak256(abi.encode(accountId, tokenId));
        account.exists = true;
    }

    function seedPosition(
        bytes32 marketId,
        bytes32 accountId,
        bool isLong,
        uint256 sizeUsdX18,
        int256 entryFundingX18
    ) external {
        LibPerpsStorage.PerpsPosition storage position = LibPerpsStorage.s().positions[marketId][accountId][isLong];
        position.isLong = isLong;
        position.sizeUsdX18 = sizeUsdX18;
        position.entryPriceX18 = 2_000e18;
        position.entryFundingX18 = entryFundingX18;
        position.lastIncreaseTs = uint64(block.timestamp);
    }

    function setAccountCollateral(bytes32 accountId, bytes32 marketId, uint256 amount) external {
        LibPerpsStorage.s().accountCollateral[accountId][marketId] = amount;
    }

    function setDomainState(uint256 isolatedTrackedBalance, uint256 isolatedLiabilities, uint256 isolatedEncumbered) external {
        LibPerpsStorage.PerpsDomainState storage ds = LibPerpsStorage.s().domainState;
        ds.isolatedTrackedBalance = isolatedTrackedBalance;
        ds.isolatedLiabilities = isolatedLiabilities;
        ds.isolatedEncumbered = isolatedEncumbered;
    }

    function setPoolTrackedBalance(uint256 poolId, uint256 trackedBalance) external {
        LibAppStorage.s().pools[poolId].initialized = true;
        LibAppStorage.s().pools[poolId].trackedBalance = trackedBalance;
    }

    function getMarketState(bytes32 marketId) external view returns (LibPerpsStorage.PerpsMarketState memory) {
        return LibPerpsStorage.s().marketState[marketId];
    }

    function readPosition(bytes32 marketId, bytes32 accountId, bool isLong)
        external
        view
        returns (LibPerpsStorage.PerpsPosition memory)
    {
        return LibPerpsStorage.s().positions[marketId][accountId][isLong];
    }

    function readAccountCollateral(bytes32 accountId, bytes32 marketId) external view returns (uint256) {
        return LibPerpsStorage.s().accountCollateral[accountId][marketId];
    }

    function getDomainState() external view returns (LibPerpsStorage.PerpsDomainState memory) {
        return LibPerpsStorage.s().domainState;
    }

    function getPoolTrackedBalance(uint256 poolId) external view returns (uint256) {
        return LibAppStorage.s().pools[poolId].trackedBalance;
    }
}

contract PerpsSyncMarketHarness is PerpsLiquidationFacet {
    function seedMarket(
        bytes32 marketId,
        uint256 collateralPoolId,
        uint256 maxSkewAbs,
        uint256 maxFundingVelocityBpsPerDay,
        bool pauseSync
    ) external {
        if (maxFundingVelocityBpsPerDay > type(uint32).max) revert Perps_RiskLimitExceeded();
        LibPerpsStorage.PerpsMarket storage market = LibPerpsStorage.s().markets[marketId];
        market.marketId = marketId;
        market.collateralPoolId = collateralPoolId;
        market.collateralAsset = address(0xC011A7);
        market.indexAsset = address(0xB0B);
        market.longEnabled = true;
        market.shortEnabled = true;
        market.maxLeverageBps = 50_000;
        market.initialMarginBps = 1_000;
        market.maintenanceMarginBps = 700;
        market.maxOpenInterest = 5_000_000e18;
        market.maxLongOpenInterest = 3_000_000e18;
        market.maxShortOpenInterest = 3_000_000e18;
        market.maxSkewAbs = maxSkewAbs;
        market.maxFundingVelocityBpsPerDay = uint32(maxFundingVelocityBpsPerDay);
        market.pauseSync = pauseSync;
        market.exists = true;
    }

    function seedMarketState(
        bytes32 marketId,
        int256 skew,
        int256 cumulativeFundingLongX18,
        int256 cumulativeFundingShortX18,
        uint256 lastFundingTs,
        uint256 insuranceBalance,
        uint256 badDebt
    ) external {
        if (lastFundingTs > type(uint64).max) revert Perps_RiskLimitExceeded();
        LibPerpsStorage.PerpsMarketState storage state = LibPerpsStorage.s().marketState[marketId];
        state.skew = skew;
        state.cumulativeFundingLongX18 = cumulativeFundingLongX18;
        state.cumulativeFundingShortX18 = cumulativeFundingShortX18;
        state.lastFundingTs = uint64(lastFundingTs);
        state.insuranceBalance = insuranceBalance;
        state.badDebt = badDebt;
    }

    function setDomainState(uint256 isolatedTrackedBalance, uint256 isolatedLiabilities, uint256 isolatedEncumbered) external {
        LibPerpsStorage.PerpsDomainState storage ds = LibPerpsStorage.s().domainState;
        ds.isolatedTrackedBalance = isolatedTrackedBalance;
        ds.isolatedLiabilities = isolatedLiabilities;
        ds.isolatedEncumbered = isolatedEncumbered;
    }

    function setPoolTrackedBalance(uint256 poolId, uint256 trackedBalance) external {
        LibAppStorage.s().pools[poolId].initialized = true;
        LibAppStorage.s().pools[poolId].trackedBalance = trackedBalance;
    }

    function getMarketState(bytes32 marketId) external view returns (LibPerpsStorage.PerpsMarketState memory) {
        return LibPerpsStorage.s().marketState[marketId];
    }

    function getDomainState() external view returns (LibPerpsStorage.PerpsDomainState memory) {
        return LibPerpsStorage.s().domainState;
    }

    function getPoolTrackedBalance(uint256 poolId) external view returns (uint256) {
        return LibAppStorage.s().pools[poolId].trackedBalance;
    }
}

contract PerpsSyncFacetTest is Test {
    bytes32 internal constant MARKET_ID = keccak256("perps.market.sync");
    bytes32 internal constant ACCOUNT_ID = keccak256("perps.account.sync");
    uint256 internal constant COLLATERAL_POOL_ID = 111;

    address internal constant KEEPER_A = address(0xAA01);
    address internal constant KEEPER_B = address(0xBB02);

    event AccountSynced(bytes32 indexed marketId, bytes32 indexed accountId);
    event MarketSynced(bytes32 indexed marketId);

    function test_syncAccount_idempotentAndPermissionless() public {
        PerpsSyncAccountHarness h = new PerpsSyncAccountHarness();
        _seedAccountSyncScenario(h, false, 100, int256(200_000e18), 0, 10_000e18, 0);

        vm.warp(100 + 1 days);
        vm.expectEmit(true, true, false, false);
        emit AccountSynced(MARKET_ID, ACCOUNT_ID);
        vm.prank(KEEPER_A);
        (LibPerpsStorage.SettlementDelta memory delta1, LibPerpsSync.AccountSyncResult memory result1) =
            h.syncAccount(ACCOUNT_ID, MARKET_ID);

        assertTrue(result1.stateChanged);
        assertTrue(result1.marketFundingUpdated);
        assertEq(delta1.fundingPaid, int256(200e18));
        assertEq(result1.longFundingPaidX18, int256(200e18));
        assertEq(result1.shortFundingPaidX18, 0);
        assertEq(h.readPosition(MARKET_ID, ACCOUNT_ID, true).entryFundingX18, int256(2e16));

        vm.recordLogs();
        vm.prank(KEEPER_B);
        (LibPerpsStorage.SettlementDelta memory delta2, LibPerpsSync.AccountSyncResult memory result2) =
            h.syncAccount(ACCOUNT_ID, MARKET_ID);
        Vm.Log[] memory secondLogs = vm.getRecordedLogs();

        assertFalse(result2.stateChanged);
        assertFalse(result2.marketFundingUpdated);
        assertEq(delta2.fundingPaid, 0);
        assertEq(secondLogs.length, 0, "idempotent sync must not emit when unchanged");
        assertEq(h.getPoolTrackedBalance(COLLATERAL_POOL_ID), 5_000_000e18, "sync cannot debit non-perps tracked balance");
    }

    function test_syncAccount_revertsWhenPaused() public {
        PerpsSyncAccountHarness h = new PerpsSyncAccountHarness();
        _seedAccountSyncScenario(h, true, 100, int256(0), 0, 1_000e18, 0);

        vm.prank(KEEPER_A);
        vm.expectRevert(abi.encodeWithSelector(Perps_SyncPaused.selector, MARKET_ID));
        h.syncAccount(ACCOUNT_ID, MARKET_ID);
    }

    function test_syncMarket_idempotentAndPermissionless() public {
        PerpsSyncMarketHarness h = new PerpsSyncMarketHarness();
        _seedMarketSyncScenario(h, false, 200, int256(-300_000e18), int256(0), int256(0));

        vm.warp(200 + 12 hours);
        vm.expectEmit(true, false, false, false);
        emit MarketSynced(MARKET_ID);
        vm.prank(KEEPER_A);
        LibPerpsSync.MarketSyncResult memory first = h.syncMarket(MARKET_ID);

        assertTrue(first.stateChanged);
        assertTrue(first.marketFundingUpdated);
        assertEq(first.previousFundingTs, 200);
        assertEq(first.currentFundingTs, 200 + 12 hours);
        assertEq(h.getMarketState(MARKET_ID).lastFundingTs, 200 + 12 hours);

        vm.recordLogs();
        vm.prank(KEEPER_B);
        LibPerpsSync.MarketSyncResult memory second = h.syncMarket(MARKET_ID);
        Vm.Log[] memory secondLogs = vm.getRecordedLogs();

        assertFalse(second.stateChanged);
        assertFalse(second.marketFundingUpdated);
        assertEq(secondLogs.length, 0, "idempotent sync must not emit when unchanged");
        assertEq(h.getPoolTrackedBalance(COLLATERAL_POOL_ID), 9_000_000e18, "sync cannot debit non-perps tracked balance");
    }

    function test_syncMarket_revertsWhenPaused() public {
        PerpsSyncMarketHarness h = new PerpsSyncMarketHarness();
        _seedMarketSyncScenario(h, true, 100, int256(0), int256(0), int256(0));

        vm.prank(KEEPER_A);
        vm.expectRevert(abi.encodeWithSelector(Perps_SyncPaused.selector, MARKET_ID));
        h.syncMarket(MARKET_ID);
    }

    /// @dev Property 5: Sync Idempotence and Executor Convergence
    /// Validates: Requirements 13.3, 20.5, 20.6
    function testFuzz_property5_syncAccountIdempotenceAndExecutorConvergence(
        uint96 longSizeSeed,
        uint96 shortSizeSeed,
        uint96 collateralSeed,
        uint96 maxSkewSeed,
        uint96 skewSeed,
        bool positiveSkew,
        uint16 maxFundingVelocitySeed,
        uint32 elapsedSeed
    ) public {
        uint256 longSize = bound(uint256(longSizeSeed), 0, 1_000_000e18);
        uint256 shortSize = bound(uint256(shortSizeSeed), 0, 1_000_000e18);
        if (longSize == 0 && shortSize == 0) longSize = 1e18;

        uint256 collateral = bound(uint256(collateralSeed), 0, 1_000_000e18);
        uint256 maxSkewAbs = bound(uint256(maxSkewSeed), 1e18, 1_000_000e18);
        uint256 skewAbs = bound(uint256(skewSeed), 0, maxSkewAbs);
        int256 skew = positiveSkew ? int256(skewAbs) : -int256(skewAbs);
        uint256 maxFundingVelocity = bound(uint256(maxFundingVelocitySeed), 1, 10_000);
        uint256 elapsed = bound(uint256(elapsedSeed), 1, 7 days);

        PerpsSyncAccountHarness hA = new PerpsSyncAccountHarness();
        PerpsSyncAccountHarness hB = new PerpsSyncAccountHarness();

        _seedAccountSyncScenario(hA, false, 500, skew, 0, longSize, shortSize);
        _seedAccountSyncScenario(hB, false, 500, skew, 0, longSize, shortSize);

        hA.seedMarket(MARKET_ID, COLLATERAL_POOL_ID, address(0xC011A7), maxSkewAbs, maxFundingVelocity, false);
        hB.seedMarket(MARKET_ID, COLLATERAL_POOL_ID, address(0xC011A7), maxSkewAbs, maxFundingVelocity, false);
        hA.setAccountCollateral(ACCOUNT_ID, MARKET_ID, collateral);
        hB.setAccountCollateral(ACCOUNT_ID, MARKET_ID, collateral);

        vm.warp(500 + elapsed);
        vm.prank(KEEPER_A);
        (LibPerpsStorage.SettlementDelta memory deltaA1, LibPerpsSync.AccountSyncResult memory resA1) =
            hA.syncAccount(ACCOUNT_ID, MARKET_ID);
        vm.prank(KEEPER_B);
        (LibPerpsStorage.SettlementDelta memory deltaB1, LibPerpsSync.AccountSyncResult memory resB1) =
            hB.syncAccount(ACCOUNT_ID, MARKET_ID);

        assertEq(keccak256(abi.encode(resA1)), keccak256(abi.encode(resB1)));
        assertEq(keccak256(abi.encode(deltaA1)), keccak256(abi.encode(deltaB1)));
        assertEq(keccak256(abi.encode(hA.getMarketState(MARKET_ID))), keccak256(abi.encode(hB.getMarketState(MARKET_ID))));
        assertEq(
            keccak256(abi.encode(hA.readPosition(MARKET_ID, ACCOUNT_ID, true))),
            keccak256(abi.encode(hB.readPosition(MARKET_ID, ACCOUNT_ID, true)))
        );
        assertEq(
            keccak256(abi.encode(hA.readPosition(MARKET_ID, ACCOUNT_ID, false))),
            keccak256(abi.encode(hB.readPosition(MARKET_ID, ACCOUNT_ID, false)))
        );
        assertEq(hA.readAccountCollateral(ACCOUNT_ID, MARKET_ID), hB.readAccountCollateral(ACCOUNT_ID, MARKET_ID));
        assertEq(keccak256(abi.encode(hA.getDomainState())), keccak256(abi.encode(hB.getDomainState())));

        vm.prank(KEEPER_B);
        (LibPerpsStorage.SettlementDelta memory deltaA2, LibPerpsSync.AccountSyncResult memory resA2) =
            hA.syncAccount(ACCOUNT_ID, MARKET_ID);
        vm.prank(KEEPER_A);
        (LibPerpsStorage.SettlementDelta memory deltaB2, LibPerpsSync.AccountSyncResult memory resB2) =
            hB.syncAccount(ACCOUNT_ID, MARKET_ID);

        assertFalse(resA2.stateChanged);
        assertFalse(resB2.stateChanged);
        assertEq(keccak256(abi.encode(resA2)), keccak256(abi.encode(resB2)));
        assertEq(keccak256(abi.encode(deltaA2)), keccak256(abi.encode(deltaB2)));
    }

    /// @dev Property 5: Sync Idempotence and Executor Convergence
    /// Validates: Requirements 13.3, 20.5, 20.6
    function testFuzz_property5_syncMarketIdempotenceAndExecutorConvergence(
        uint96 maxSkewSeed,
        uint96 skewSeed,
        bool positiveSkew,
        uint16 maxFundingVelocitySeed,
        uint32 elapsedSeed
    ) public {
        uint256 maxSkewAbs = bound(uint256(maxSkewSeed), 1e18, 1_000_000e18);
        uint256 skewAbs = bound(uint256(skewSeed), 0, maxSkewAbs);
        int256 skew = positiveSkew ? int256(skewAbs) : -int256(skewAbs);
        uint256 maxFundingVelocity = bound(uint256(maxFundingVelocitySeed), 1, 10_000);
        uint256 elapsed = bound(uint256(elapsedSeed), 1, 7 days);

        PerpsSyncMarketHarness hA = new PerpsSyncMarketHarness();
        PerpsSyncMarketHarness hB = new PerpsSyncMarketHarness();

        hA.seedMarket(MARKET_ID, COLLATERAL_POOL_ID, maxSkewAbs, maxFundingVelocity, false);
        hB.seedMarket(MARKET_ID, COLLATERAL_POOL_ID, maxSkewAbs, maxFundingVelocity, false);
        hA.seedMarketState(MARKET_ID, skew, int256(0), int256(0), 1_000, 25e18, 0);
        hB.seedMarketState(MARKET_ID, skew, int256(0), int256(0), 1_000, 25e18, 0);
        hA.setDomainState(2_000_000e18, 0, 0);
        hB.setDomainState(2_000_000e18, 0, 0);
        hA.setPoolTrackedBalance(COLLATERAL_POOL_ID, 9_000_000e18);
        hB.setPoolTrackedBalance(COLLATERAL_POOL_ID, 9_000_000e18);

        vm.warp(1_000 + elapsed);
        vm.prank(KEEPER_A);
        LibPerpsSync.MarketSyncResult memory resA1 = hA.syncMarket(MARKET_ID);
        vm.prank(KEEPER_B);
        LibPerpsSync.MarketSyncResult memory resB1 = hB.syncMarket(MARKET_ID);

        assertEq(keccak256(abi.encode(resA1)), keccak256(abi.encode(resB1)));
        assertEq(keccak256(abi.encode(hA.getMarketState(MARKET_ID))), keccak256(abi.encode(hB.getMarketState(MARKET_ID))));
        assertEq(keccak256(abi.encode(hA.getDomainState())), keccak256(abi.encode(hB.getDomainState())));

        vm.prank(KEEPER_B);
        LibPerpsSync.MarketSyncResult memory resA2 = hA.syncMarket(MARKET_ID);
        vm.prank(KEEPER_A);
        LibPerpsSync.MarketSyncResult memory resB2 = hB.syncMarket(MARKET_ID);

        assertFalse(resA2.stateChanged);
        assertFalse(resB2.stateChanged);
        assertEq(keccak256(abi.encode(resA2)), keccak256(abi.encode(resB2)));
    }

    function _seedAccountSyncScenario(
        PerpsSyncAccountHarness h,
        bool pauseSync,
        uint256 lastFundingTs,
        int256 skew,
        int256 entryFundingLong,
        uint256 longSizeUsdX18,
        uint256 shortSizeUsdX18
    ) internal {
        h.seedMarket(MARKET_ID, COLLATERAL_POOL_ID, address(0xC011A7), 1_000_000e18, 1_000, pauseSync);
        h.seedMarketState(MARKET_ID, skew, 0, 0, lastFundingTs, 50e18, 0);
        h.seedAccount(ACCOUNT_ID, 1);
        h.seedPosition(MARKET_ID, ACCOUNT_ID, true, longSizeUsdX18, entryFundingLong);
        h.seedPosition(MARKET_ID, ACCOUNT_ID, false, shortSizeUsdX18, 0);
        h.setAccountCollateral(ACCOUNT_ID, MARKET_ID, 100_000e18);
        h.setDomainState(2_000_000e18, 0, 0);
        h.setPoolTrackedBalance(COLLATERAL_POOL_ID, 5_000_000e18);
    }

    function _seedMarketSyncScenario(
        PerpsSyncMarketHarness h,
        bool pauseSync,
        uint256 lastFundingTs,
        int256 skew,
        int256 cumulativeFundingLongX18,
        int256 cumulativeFundingShortX18
    ) internal {
        h.seedMarket(MARKET_ID, COLLATERAL_POOL_ID, 1_000_000e18, 1_000, pauseSync);
        h.seedMarketState(
            MARKET_ID, skew, cumulativeFundingLongX18, cumulativeFundingShortX18, lastFundingTs, 100e18, 0
        );
        h.setDomainState(2_000_000e18, 0, 0);
        h.setPoolTrackedBalance(COLLATERAL_POOL_ID, 9_000_000e18);
    }
}
