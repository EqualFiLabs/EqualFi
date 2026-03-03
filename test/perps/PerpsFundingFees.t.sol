// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {Types} from "../../src/libraries/Types.sol";
import {LibPerpsDomain} from "../../src/perps/LibPerpsDomain.sol";
import {LibPerpsFees} from "../../src/perps/LibPerpsFees.sol";
import {LibPerpsFunding} from "../../src/perps/LibPerpsFunding.sol";
import {LibPerpsStorage} from "../../src/perps/LibPerpsStorage.sol";
import {Perps_RiskLimitExceeded} from "../../src/perps/PerpsErrors.sol";

contract PerpsFundingFeesHarness {
    function seedMarket(bytes32 marketId, uint256 maxSkewAbs, uint256 maxFundingVelocityBpsPerDay) external {
        if (maxFundingVelocityBpsPerDay > type(uint32).max) revert Perps_RiskLimitExceeded();
        LibPerpsStorage.PerpsMarket storage market = LibPerpsStorage.s().markets[marketId];
        market.marketId = marketId;
        market.maxSkewAbs = maxSkewAbs;
        market.maxFundingVelocityBpsPerDay = uint32(maxFundingVelocityBpsPerDay);
        market.exists = true;
    }

    function seedMarketState(
        bytes32 marketId,
        int256 skew,
        int256 cumulativeFundingLongX18,
        int256 cumulativeFundingShortX18,
        uint256 lastFundingTs,
        uint256 lpFeeIndexX18,
        uint256 protocolFeesAccrued
    ) external {
        if (lastFundingTs > type(uint64).max) revert Perps_RiskLimitExceeded();
        LibPerpsStorage.PerpsMarketState storage state = LibPerpsStorage.s().marketState[marketId];
        state.skew = skew;
        state.cumulativeFundingLongX18 = cumulativeFundingLongX18;
        state.cumulativeFundingShortX18 = cumulativeFundingShortX18;
        state.lastFundingTs = uint64(lastFundingTs);
        state.lpFeeIndexX18 = lpFeeIndexX18;
        state.protocolFeesAccrued = protocolFeesAccrued;
    }

    function setReservedCollateral(bytes32 marketId, uint256 reservedCollateral) external {
        LibPerpsStorage.s().marketState[marketId].reservedCollateral = reservedCollateral;
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
        position.entryFundingX18 = entryFundingX18;
        position.lastIncreaseTs = uint64(block.timestamp);
    }

    function setDomainState(uint256 isolatedTrackedBalance, uint256 isolatedLiabilities, uint256 isolatedEncumbered) external {
        LibPerpsStorage.PerpsDomainState storage ds = LibPerpsStorage.s().domainState;
        ds.isolatedTrackedBalance = isolatedTrackedBalance;
        ds.isolatedLiabilities = isolatedLiabilities;
        ds.isolatedEncumbered = isolatedEncumbered;
    }

    function seedFeePool(uint256 pid, address underlying, uint256 totalDeposits, uint256 trackedBalance) external {
        Types.PoolData storage pool = LibAppStorage.s().pools[pid];
        pool.underlying = underlying;
        pool.totalDeposits = totalDeposits;
        pool.trackedBalance = trackedBalance;
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

    function previewFunding(bytes32 marketId, uint256 nowTs)
        external
        view
        returns (LibPerpsFunding.FundingComputation memory computation, int256 nextLongFundingX18, int256 nextShortFundingX18)
    {
        if (nowTs > type(uint64).max) revert Perps_RiskLimitExceeded();
        LibPerpsStorage.Layout storage ps = LibPerpsStorage.s();
        return LibPerpsFunding.previewMarketFunding(ps.markets[marketId], ps.marketState[marketId], uint64(nowTs));
    }

    function updateFunding(bytes32 marketId, uint256 nowTs)
        external
        returns (LibPerpsFunding.FundingComputation memory computation, int256 nextLongFundingX18, int256 nextShortFundingX18)
    {
        if (nowTs > type(uint64).max) revert Perps_RiskLimitExceeded();
        return LibPerpsFunding.updateMarketFunding(marketId, uint64(nowTs));
    }

    function settleFunding(bytes32 marketId, bytes32 accountId, bool isLong)
        external
        returns (LibPerpsFunding.FundingSettlement memory)
    {
        return LibPerpsFunding.settlePositionFunding(marketId, accountId, isLong);
    }

    function applyTradingFee(bytes32 marketId, uint256 totalFee, uint256 feePoolId, bytes32 source)
        external
        returns (LibPerpsFees.FeeSplit memory split, uint256 explicitOutboundCredit)
    {
        return LibPerpsFees.applyTradingFee(marketId, totalFee, feePoolId, source);
    }

    function applyExecutorFee(uint256 requestedExecutorFee, uint256 signerApprovedMaxExecutorFee)
        external
        returns (uint256)
    {
        return LibPerpsFees.applyExecutorFee(requestedExecutorFee, signerApprovedMaxExecutorFee);
    }

    function snapshotSinglePool(uint256 poolId) external view returns (uint256 nonPerpsTrackedBefore, uint256 isolatedTrackedBefore) {
        uint256[] memory poolIds = new uint256[](1);
        poolIds[0] = poolId;
        LibPerpsDomain.IsolationSnapshot memory snap = LibPerpsDomain.snapshotIsolation(poolIds);
        return (snap.nonPerpsTrackedTotal, snap.isolatedTrackedBalance);
    }

    function enforceInvariantSinglePool(
        uint256 poolId,
        uint256 beforeTracked,
        uint256 beforeIsolatedTracked,
        uint256 explicitOutboundCredit
    ) external view returns (uint256) {
        uint256[] memory poolIds = new uint256[](1);
        poolIds[0] = poolId;
        LibPerpsDomain.IsolationSnapshot memory snap =
            LibPerpsDomain.IsolationSnapshot({nonPerpsTrackedTotal: beforeTracked, isolatedTrackedBalance: beforeIsolatedTracked});
        return LibPerpsDomain.enforceNonPerpsBackingInvariant(poolIds, snap, explicitOutboundCredit);
    }

    function getMarketState(bytes32 marketId) external view returns (LibPerpsStorage.PerpsMarketState memory) {
        return LibPerpsStorage.s().marketState[marketId];
    }

    function getPendingLpFees(bytes32 marketId) external view returns (uint256) {
        return LibPerpsStorage.s().marketPendingLpFees[marketId];
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

    function getPoolFeeState(uint256 pid)
        external
        view
        returns (uint256 trackedBalance, uint256 yieldReserve, uint256 feeIndex)
    {
        Types.PoolData storage pool = LibAppStorage.s().pools[pid];
        return (pool.trackedBalance, pool.yieldReserve, pool.feeIndex);
    }
}

contract PerpsFundingFeesTest is Test {
    PerpsFundingFeesHarness internal h;

    bytes32 internal constant MARKET_ID = keccak256("perps.market.funding.fees");
    bytes32 internal constant ACCOUNT_ID = keccak256("perps.account.funding.fees");
    uint256 internal constant FEE_POOL_ID = 99;

    function setUp() public {
        h = new PerpsFundingFeesHarness();
    }

    function test_fundingUpdate_deterministicAndFundingDoesNotRouteFees() public {
        h.seedMarket(MARKET_ID, 1_000_000e18, 1_000);
        h.seedMarketState(
            MARKET_ID,
            int256(200_000e18), // 20% skew utilization
            int256(0),
            int256(0),
            100,
            123,
            456
        );
        h.setDomainState(5_000e18, 0, 5_000e18);
        h.seedFeePool(FEE_POOL_ID, address(0xC011A7), 1_000e18, 2_000e18);

        (uint256 trackedBefore, uint256 reserveBefore, uint256 feeIndexBefore) = h.getPoolFeeState(FEE_POOL_ID);
        LibPerpsStorage.PerpsDomainState memory domainBefore = h.getDomainState();

        (
            LibPerpsFunding.FundingComputation memory previewComputation,
            int256 previewNextLongFundingX18,
            int256 previewNextShortFundingX18
        ) = h.previewFunding(MARKET_ID, 100 + 12 hours);

        assertEq(previewComputation.elapsed, 12 hours);
        assertEq(previewComputation.skewRatioX18, int256(2e17));
        assertEq(previewComputation.fundingVelocityX18PerDay, int256(2e16));
        assertEq(previewComputation.fundingDeltaX18, int256(1e16));

        (LibPerpsFunding.FundingComputation memory updateComputation, int256 nextLongFundingX18, int256 nextShortFundingX18) =
            h.updateFunding(MARKET_ID, 100 + 12 hours);

        assertEq(updateComputation.elapsed, previewComputation.elapsed);
        assertEq(updateComputation.fundingDeltaX18, previewComputation.fundingDeltaX18);
        assertEq(nextLongFundingX18, previewNextLongFundingX18);
        assertEq(nextShortFundingX18, previewNextShortFundingX18);

        LibPerpsStorage.PerpsMarketState memory state = h.getMarketState(MARKET_ID);
        assertEq(state.cumulativeFundingLongX18, int256(1e16));
        assertEq(state.cumulativeFundingShortX18, -int256(1e16));
        assertEq(state.protocolFeesAccrued, 456, "funding must not route protocol fee");
        assertEq(state.lpFeeIndexX18, 123, "funding must not route lp fee");

        (uint256 trackedAfter, uint256 reserveAfter, uint256 feeIndexAfter) = h.getPoolFeeState(FEE_POOL_ID);
        assertEq(trackedAfter, trackedBefore, "funding must not touch non-perps tracked");
        assertEq(reserveAfter, reserveBefore, "funding must not touch non-perps reserve");
        assertEq(feeIndexAfter, feeIndexBefore, "funding must not touch fee index");

        LibPerpsStorage.PerpsDomainState memory domainAfter = h.getDomainState();
        assertEq(domainAfter.isolatedTrackedBalance, domainBefore.isolatedTrackedBalance);
        assertEq(domainAfter.isolatedLiabilities, domainBefore.isolatedLiabilities);
        assertEq(domainAfter.isolatedEncumbered, domainBefore.isolatedEncumbered);
    }

    function test_settleFunding_isDeterministicAndIdempotent() public {
        h.seedMarket(MARKET_ID, 1_000_000e18, 1_000);
        h.seedMarketState(MARKET_ID, int256(0), int256(1e16), -int256(1e16), 200, 0, 0);
        h.seedPosition(MARKET_ID, ACCOUNT_ID, true, 25_000e18, int256(0));

        LibPerpsFunding.FundingSettlement memory first = h.settleFunding(MARKET_ID, ACCOUNT_ID, true);
        assertEq(first.previousFundingIndexX18, int256(0));
        assertEq(first.currentFundingIndexX18, int256(1e16));
        assertEq(first.fundingPaidX18, int256(250e18));

        LibPerpsStorage.PerpsPosition memory positionAfterFirst = h.getPosition(MARKET_ID, ACCOUNT_ID, true);
        assertEq(positionAfterFirst.entryFundingX18, int256(1e16));

        LibPerpsFunding.FundingSettlement memory second = h.settleFunding(MARKET_ID, ACCOUNT_ID, true);
        assertEq(second.previousFundingIndexX18, int256(1e16));
        assertEq(second.currentFundingIndexX18, int256(1e16));
        assertEq(second.fundingPaidX18, 0, "second settlement with unchanged index must be zero");
    }

    function test_applyTradingFee_routes7030_andReconcilesAccounting() public {
        h.seedMarket(MARKET_ID, 1_000_000e18, 1_000);
        h.seedMarketState(MARKET_ID, int256(0), int256(0), int256(0), 0, 0, 0);
        h.setReservedCollateral(MARKET_ID, 2_000e18);
        h.setDomainState(5_000e18, 0, 5_000e18);
        h.seedFeePool(FEE_POOL_ID, address(0xC011A7), 1_000e18, 2_000e18);
        h.configureFeeRouter(0, 0, address(0));

        (uint256 beforeTracked, uint256 beforeIsolated) = h.snapshotSinglePool(FEE_POOL_ID);
        (uint256 poolTrackedBefore,, uint256 poolFeeIndexBefore) = h.getPoolFeeState(FEE_POOL_ID);

        (LibPerpsFees.FeeSplit memory split, uint256 explicitCredit) =
            h.applyTradingFee(MARKET_ID, 1_000e18, FEE_POOL_ID, keccak256("perps.trade"));

        assertEq(split.totalFee, 1_000e18);
        assertEq(split.lpFee, 700e18);
        assertEq(split.protocolFee, 300e18);
        assertEq(explicitCredit, 300e18, "explicit outbound credit must match protocol share");

        LibPerpsStorage.PerpsMarketState memory marketState = h.getMarketState(MARKET_ID);
        assertEq(marketState.lpFeeIndexX18, 350_000_000_000_000_000);
        assertEq(marketState.protocolFeesAccrued, 300e18);
        assertEq(h.getPendingLpFees(MARKET_ID), 0);

        LibPerpsStorage.PerpsDomainState memory domain = h.getDomainState();
        assertEq(domain.isolatedTrackedBalance, 4_700e18, "protocol share leaves perps domain only");
        assertEq(domain.isolatedEncumbered, 5_000e18, "fee routing should not change encumbrance");

        (uint256 poolTrackedAfter, uint256 poolYieldReserveAfter, uint256 poolFeeIndexAfter) = h.getPoolFeeState(FEE_POOL_ID);
        assertEq(poolTrackedAfter, poolTrackedBefore + explicitCredit, "non-perps pool receives explicit credit");
        assertEq(poolYieldReserveAfter, 300e18, "credited protocol share is reserved into fee rails");
        assertEq(poolFeeIndexAfter - poolFeeIndexBefore, 3e17, "fee index delta matches 300/1000");

        uint256 nonPerpsAfter = h.enforceInvariantSinglePool(FEE_POOL_ID, beforeTracked, beforeIsolated, explicitCredit);
        assertEq(nonPerpsAfter, beforeTracked + explicitCredit);
    }

    function test_applyTradingFee_revertsWhenFeePoolMissing() public {
        h.seedMarket(MARKET_ID, 1_000_000e18, 1_000);
        h.seedMarketState(MARKET_ID, int256(0), int256(0), int256(0), 0, 0, 0);

        vm.expectRevert(Perps_RiskLimitExceeded.selector);
        h.applyTradingFee(MARKET_ID, 100e18, 0, bytes32("missing.pool"));
    }

    function test_applyExecutorFee_enforcesMaxAndDebitsIsolatedDomain() public {
        h.setDomainState(1_000e18, 0, 1_000e18);

        vm.expectRevert(Perps_RiskLimitExceeded.selector);
        h.applyExecutorFee(101e18, 100e18);

        uint256 charged = h.applyExecutorFee(80e18, 100e18);
        assertEq(charged, 80e18);
        assertEq(h.getDomainState().isolatedTrackedBalance, 920e18);
    }
}
