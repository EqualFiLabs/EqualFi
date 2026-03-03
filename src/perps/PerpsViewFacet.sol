// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibPerpsFees} from "./LibPerpsFees.sol";
import {LibPerpsOracle} from "./LibPerpsOracle.sol";
import {LibPerpsRisk} from "./LibPerpsRisk.sol";
import {LibPerpsStorage} from "./LibPerpsStorage.sol";
import {Perps_AccountNotFound, Perps_MarketNotFound, Perps_RiskLimitExceeded} from "./PerpsErrors.sol";

/// @notice Read-only monitoring, risk preview, and auditability surface for perps markets.
contract PerpsViewFacet {
    uint256 internal constant X18 = 1e18;
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    struct PreviewParams {
        bytes32 marketId;
        bytes32 accountId;
        int256 collateralDeltaUsdX18;
        int256 positionNotionalDeltaUsdX18;
        int256 unrealizedPnlDeltaUsdX18;
        int256 fundingAccruedDeltaUsdX18;
        uint256 feeDeltaUsdX18;
        uint256 executionPriceX18; // optional; 0 uses oracle mark
    }

    struct PreviewResult {
        bytes32 marketId;
        bytes32 accountId;
        uint256 markPriceX18;
        LibPerpsRisk.HealthState baseState;
        LibPerpsRisk.HealthResult baseHealth;
        LibPerpsRisk.HealthState postState;
        LibPerpsRisk.HealthResult postHealth;
    }

    struct SettlementSummary {
        bytes32 marketId;
        uint256 openInterestLong;
        uint256 openInterestShort;
        int256 skew;
        int256 cumulativeFundingLongX18;
        int256 cumulativeFundingShortX18;
        uint64 lastFundingTs;
        uint256 insuranceBalance;
        uint256 insuranceTarget;
        uint256 badDebt;
        uint256 reservedCollateral;
        uint256 realizedPnlOut;
        uint256 realizedPnlIn;
        uint256 lpFeeIndexX18;
        uint256 lpFeePendingDistribution;
        uint256 protocolFeesAccrued;
        uint256 isolatedTrackedBalance;
        uint256 isolatedLiabilities;
        uint256 isolatedEncumbered;
    }

    struct FeeRoutingAudit {
        bytes32 marketId;
        uint256 collateralPoolId;
        uint256 lpFeeIndexX18;
        uint256 lpFeePendingDistribution;
        uint256 protocolFeesAccrued;
        uint256 outboundRouterCredits;
        uint256 insuranceBalance;
        uint256 insuranceTarget;
        uint256 insuranceTargetGap;
        uint256 insuranceTargetProgressBps;
        uint256 feePoolTrackedBalance;
        uint256 feePoolYieldReserve;
        uint256 feePoolFeeIndexX18;
    }

    struct AccountLpFeeState {
        bytes32 marketId;
        bytes32 accountId;
        uint256 collateralShares;
        uint256 feeIndexX18;
        uint256 feeIndexCheckpointX18;
        uint256 accruedFees;
        uint256 pendingFees;
        uint256 totalClaimableFees;
    }

    struct IsolationProof {
        bytes32 marketId;
        uint256 nonPerpsTrackedBacking;
        uint256 isolatedTrackedBalance;
        uint256 isolatedLiabilities;
        uint256 marketInsuranceBalance;
        uint256 marketBadDebt;
        uint256 coveredByMarket;
        bool marketSolvent;
        uint256 totalInsuranceBalance;
        uint256 totalBadDebt;
        uint256 coveredGlobal;
        bool globalSolvent;
    }

    function getMarket(bytes32 marketId) external view returns (LibPerpsStorage.PerpsMarket memory market) {
        market = _requireMarket(marketId);
    }

    function getMarketState(bytes32 marketId) external view returns (LibPerpsStorage.PerpsMarketState memory state) {
        _requireMarket(marketId);
        state = LibPerpsStorage.s().marketState[marketId];
    }

    function getPerpsAccount(bytes32 accountId) external view returns (LibPerpsStorage.PerpsAccount memory account) {
        account = _requireAccount(accountId);
    }

    function getPerpsPosition(bytes32 marketId, bytes32 accountId, bool isLong)
        external
        view
        returns (LibPerpsStorage.PerpsPosition memory position)
    {
        _requireMarket(marketId);
        _requireAccount(accountId);
        position = LibPerpsStorage.s().positions[marketId][accountId][isLong];
    }

    function getPerpsAccountCollateral(bytes32 marketId, bytes32 accountId) external view returns (uint256 collateral) {
        _requireMarket(marketId);
        _requireAccount(accountId);
        collateral = LibPerpsStorage.s().accountCollateral[accountId][marketId];
    }

    function getPerpsAccountLpFeeState(bytes32 marketId, bytes32 accountId)
        external
        view
        returns (AccountLpFeeState memory state)
    {
        _requireMarket(marketId);
        _requireAccount(accountId);

        LibPerpsStorage.Layout storage ps = LibPerpsStorage.s();
        (uint256 accrued, uint256 pending, uint256 total) = LibPerpsFees.previewAccountLpFees(marketId, accountId);

        state.marketId = marketId;
        state.accountId = accountId;
        state.collateralShares = ps.accountCollateral[accountId][marketId];
        state.feeIndexX18 = ps.marketState[marketId].lpFeeIndexX18;
        state.feeIndexCheckpointX18 = ps.accountLpFeeIndexX18[accountId][marketId];
        state.accruedFees = accrued;
        state.pendingFees = pending;
        state.totalClaimableFees = total;
    }

    function previewHealth(bytes32 marketId, bytes32 accountId)
        external
        view
        returns (LibPerpsRisk.HealthResult memory health, LibPerpsRisk.HealthState memory state, uint256 markPriceX18)
    {
        LibPerpsStorage.PerpsMarket storage market = _requireMarket(marketId);
        _requireAccount(accountId);

        LibPerpsOracle.OraclePrice memory oraclePrice = LibPerpsOracle.validateOracleFreshness(market);
        markPriceX18 = oraclePrice.priceX18;
        state = _buildHealthState(marketId, accountId, markPriceX18);
        health = LibPerpsRisk.computeHealth(market, state);
    }

    function previewDelta(PreviewParams calldata p) external view returns (PreviewResult memory result) {
        LibPerpsStorage.PerpsMarket storage market = _requireMarket(p.marketId);
        _requireAccount(p.accountId);

        result.marketId = p.marketId;
        result.accountId = p.accountId;
        if (p.executionPriceX18 == 0) {
            result.markPriceX18 = LibPerpsOracle.validateOracleFreshness(market).priceX18;
        } else {
            LibPerpsOracle.validateExecutionPrice(market, p.executionPriceX18);
            result.markPriceX18 = p.executionPriceX18;
        }

        result.baseState = _buildHealthState(p.marketId, p.accountId, result.markPriceX18);
        result.baseHealth = LibPerpsRisk.computeHealth(market, result.baseState);
        (result.postHealth, result.postState) = LibPerpsRisk.previewHealth(
            market,
            result.baseState,
            LibPerpsRisk.HealthDelta({
                collateralDeltaUsdX18: p.collateralDeltaUsdX18,
                positionNotionalDeltaUsdX18: p.positionNotionalDeltaUsdX18,
                unrealizedPnlDeltaUsdX18: p.unrealizedPnlDeltaUsdX18,
                fundingAccruedDeltaUsdX18: p.fundingAccruedDeltaUsdX18,
                feeDeltaUsdX18: p.feeDeltaUsdX18
            })
        );
    }

    function getSettlementSummary(bytes32 marketId) external view returns (SettlementSummary memory summary) {
        _requireMarket(marketId);
        LibPerpsStorage.PerpsMarketState storage state = LibPerpsStorage.s().marketState[marketId];
        LibPerpsStorage.PerpsDomainState storage domainState = LibPerpsStorage.s().domainState;

        summary.marketId = marketId;
        summary.openInterestLong = state.openInterestLong;
        summary.openInterestShort = state.openInterestShort;
        summary.skew = state.skew;
        summary.cumulativeFundingLongX18 = state.cumulativeFundingLongX18;
        summary.cumulativeFundingShortX18 = state.cumulativeFundingShortX18;
        summary.lastFundingTs = state.lastFundingTs;
        summary.insuranceBalance = state.insuranceBalance;
        summary.insuranceTarget = state.insuranceTarget;
        summary.badDebt = state.badDebt;
        summary.reservedCollateral = state.reservedCollateral;
        summary.realizedPnlOut = state.realizedPnlOut;
        summary.realizedPnlIn = state.realizedPnlIn;
        summary.lpFeeIndexX18 = state.lpFeeIndexX18;
        summary.lpFeePendingDistribution = LibPerpsStorage.s().marketPendingLpFees[marketId];
        summary.protocolFeesAccrued = state.protocolFeesAccrued;
        summary.isolatedTrackedBalance = domainState.isolatedTrackedBalance;
        summary.isolatedLiabilities = domainState.isolatedLiabilities;
        summary.isolatedEncumbered = domainState.isolatedEncumbered;
    }

    function getFeeRoutingAudit(bytes32 marketId) external view returns (FeeRoutingAudit memory audit) {
        LibPerpsStorage.PerpsMarket storage market = _requireMarket(marketId);
        LibPerpsStorage.PerpsMarketState storage state = LibPerpsStorage.s().marketState[marketId];
        uint256 poolId = market.collateralPoolId;

        audit.marketId = marketId;
        audit.collateralPoolId = poolId;
        audit.lpFeeIndexX18 = state.lpFeeIndexX18;
        audit.lpFeePendingDistribution = LibPerpsStorage.s().marketPendingLpFees[marketId];
        audit.protocolFeesAccrued = state.protocolFeesAccrued;
        // In current perps flow protocol fees are routed immediately to fee rails.
        audit.outboundRouterCredits = state.protocolFeesAccrued;
        audit.insuranceBalance = state.insuranceBalance;
        audit.insuranceTarget = state.insuranceTarget;

        if (state.insuranceTarget > state.insuranceBalance) {
            audit.insuranceTargetGap = state.insuranceTarget - state.insuranceBalance;
        }
        if (state.insuranceTarget == 0) {
            audit.insuranceTargetProgressBps = BPS_DENOMINATOR;
        } else {
            uint256 bounded = state.insuranceBalance > state.insuranceTarget ? state.insuranceTarget : state.insuranceBalance;
            audit.insuranceTargetProgressBps = (bounded * BPS_DENOMINATOR) / state.insuranceTarget;
        }

        audit.feePoolTrackedBalance = LibAppStorage.s().pools[poolId].trackedBalance;
        audit.feePoolYieldReserve = LibAppStorage.s().pools[poolId].yieldReserve;
        audit.feePoolFeeIndexX18 = LibAppStorage.s().pools[poolId].feeIndex;
    }

    function proveIsolationInvariant(bytes32 marketId) external view returns (IsolationProof memory proof) {
        LibPerpsStorage.Layout storage ps = LibPerpsStorage.s();
        LibPerpsStorage.PerpsMarket storage market = _requireMarket(marketId);
        LibPerpsStorage.PerpsMarketState storage marketState = ps.marketState[marketId];
        LibPerpsStorage.PerpsDomainState storage domainState = ps.domainState;

        proof.marketId = marketId;
        proof.nonPerpsTrackedBacking = LibAppStorage.s().pools[market.collateralPoolId].trackedBalance;
        proof.isolatedTrackedBalance = domainState.isolatedTrackedBalance;
        proof.isolatedLiabilities = domainState.isolatedLiabilities;
        proof.marketInsuranceBalance = marketState.insuranceBalance;
        proof.marketBadDebt = marketState.badDebt;
        proof.coveredByMarket = domainState.isolatedTrackedBalance + marketState.insuranceBalance + marketState.badDebt;
        proof.marketSolvent = proof.coveredByMarket >= domainState.isolatedLiabilities;

        uint256 marketCount = ps.marketCount;
        for (uint256 i = 1; i <= marketCount; ++i) {
            bytes32 iterMarketId = ps.marketIds[i];
            LibPerpsStorage.PerpsMarketState storage iterState = ps.marketState[iterMarketId];
            proof.totalInsuranceBalance += iterState.insuranceBalance;
            proof.totalBadDebt += iterState.badDebt;
        }

        proof.coveredGlobal = domainState.isolatedTrackedBalance + proof.totalInsuranceBalance + proof.totalBadDebt;
        proof.globalSolvent = proof.coveredGlobal >= domainState.isolatedLiabilities;
    }

    function _buildHealthState(bytes32 marketId, bytes32 accountId, uint256 markPriceX18)
        internal
        view
        returns (LibPerpsRisk.HealthState memory healthState)
    {
        LibPerpsStorage.Layout storage ps = LibPerpsStorage.s();
        LibPerpsStorage.PerpsPosition storage longPosition = ps.positions[marketId][accountId][true];
        LibPerpsStorage.PerpsPosition storage shortPosition = ps.positions[marketId][accountId][false];
        LibPerpsStorage.PerpsMarketState storage marketState = ps.marketState[marketId];

        healthState.collateralValueUsdX18 = ps.accountCollateral[accountId][marketId];
        healthState.positionNotionalUsdX18 = longPosition.sizeUsdX18 + shortPosition.sizeUsdX18;
        healthState.unrealizedPnlUsdX18 =
            _positionPnl(longPosition, markPriceX18, true) + _positionPnl(shortPosition, markPriceX18, false);
        healthState.fundingAccruedUsdX18 =
            _positionFunding(longPosition, marketState.cumulativeFundingLongX18)
                + _positionFunding(shortPosition, marketState.cumulativeFundingShortX18);
        healthState.feesAccruedUsdX18 = 0;
    }

    function _positionPnl(LibPerpsStorage.PerpsPosition storage position, uint256 markPriceX18, bool isLong)
        internal
        view
        returns (int256 pnlX18)
    {
        if (position.sizeUsdX18 == 0) return 0;
        if (position.entryPriceX18 == 0 || markPriceX18 == 0) revert Perps_RiskLimitExceeded();

        if (isLong) {
            pnlX18 = (_toInt(position.sizeUsdX18) * (_toInt(markPriceX18) - _toInt(position.entryPriceX18)))
                / _toInt(position.entryPriceX18);
        } else {
            pnlX18 = (_toInt(position.sizeUsdX18) * (_toInt(position.entryPriceX18) - _toInt(markPriceX18)))
                / _toInt(position.entryPriceX18);
        }
    }

    function _positionFunding(LibPerpsStorage.PerpsPosition storage position, int256 currentFundingIndexX18)
        internal
        view
        returns (int256 fundingPaidX18)
    {
        if (position.sizeUsdX18 == 0) return 0;
        int256 fundingIndexDeltaX18 = currentFundingIndexX18 - position.entryFundingX18;
        if (fundingIndexDeltaX18 == 0) return 0;
        fundingPaidX18 = (_toInt(position.sizeUsdX18) * fundingIndexDeltaX18) / int256(X18);
    }

    function _toInt(uint256 value) internal pure returns (int256 signed) {
        if (value > uint256(type(int256).max)) revert Perps_RiskLimitExceeded();
        signed = int256(value);
    }

    function _requireAccount(bytes32 accountId) internal view returns (LibPerpsStorage.PerpsAccount storage account) {
        account = LibPerpsStorage.s().accounts[accountId];
        if (!account.exists) revert Perps_AccountNotFound(accountId);
    }

    function _requireMarket(bytes32 marketId) internal view returns (LibPerpsStorage.PerpsMarket storage market) {
        market = LibPerpsStorage.s().markets[marketId];
        if (!market.exists) revert Perps_MarketNotFound(marketId);
    }
}
