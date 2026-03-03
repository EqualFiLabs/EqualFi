// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibPerpsDomain} from "./LibPerpsDomain.sol";
import {LibPerpsFees} from "./LibPerpsFees.sol";
import {LibPerpsFunding} from "./LibPerpsFunding.sol";
import {LibPerpsOracle} from "./LibPerpsOracle.sol";
import {LibPerpsRisk} from "./LibPerpsRisk.sol";
import {LibPerpsSync} from "./LibPerpsSync.sol";
import {LibPerpsStorage} from "./LibPerpsStorage.sol";
import {
    Perps_AccountNotFound,
    Perps_LiquidationPaused,
    Perps_MarketNotFound,
    Perps_PositionHealthy,
    Perps_RiskLimitExceeded,
    Perps_SyncPaused
} from "./PerpsErrors.sol";

/// @notice Permissionless liquidation with deterministic close factor, waterfall handling, and settlement deltas.
contract PerpsLiquidationFacet {
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant FULL_CLOSE_BPS = 10_000;
    uint256 internal constant PARTIAL_CLOSE_BPS = 5_000;

    struct LiquidationParams {
        bytes32 marketId;
        bytes32 accountId;
        bool isLong;
        uint256 executionPriceX18;
        uint256 feePoolId;
    }

    event PositionLiquidated(bytes32 indexed marketId, bytes32 indexed accountId, address liquidator, uint256 closeSizeUsdX18);
    event MarketSynced(bytes32 indexed marketId);
    event SettlementDeltaEmitted(bytes32 indexed marketId, bytes32 indexed accountId, LibPerpsStorage.SettlementDelta delta);

    function liquidate(LiquidationParams calldata p)
        external
        returns (LibPerpsStorage.SettlementDelta memory delta, uint256 closeSizeUsdX18)
    {
        if (p.executionPriceX18 == 0) revert Perps_RiskLimitExceeded();

        LibPerpsStorage.Layout storage ps = LibPerpsStorage.s();
        LibPerpsStorage.PerpsMarket storage market = _requireMarket(p.marketId);
        if (!ps.globalLiquidationEnabled || market.pauseLiquidation) {
            revert Perps_LiquidationPaused(p.marketId);
        }
        LibPerpsOracle.validateExecutionPrice(market, p.executionPriceX18);

        _requireAccount(p.accountId);
        LibPerpsStorage.PerpsPosition storage position = ps.positions[p.marketId][p.accountId][p.isLong];
        if (position.sizeUsdX18 == 0) revert Perps_RiskLimitExceeded();

        uint256[] memory nonPerpsPoolIds = _singlePoolArray(market.collateralPoolId);
        LibPerpsDomain.IsolationSnapshot memory beforeSnap = LibPerpsDomain.snapshotIsolation(nonPerpsPoolIds);

        LibPerpsFunding.updateMarketFunding(p.marketId, uint64(block.timestamp));
        LibPerpsFunding.FundingSettlement memory fundingSettlement =
            LibPerpsFunding.settlePositionFunding(p.marketId, p.accountId, p.isLong);

        uint256 accountCollateralBefore = ps.accountCollateral[p.accountId][p.marketId];
        int256 fullUnrealizedPnlX18 =
            _realizedPnlX18(position.entryPriceX18, p.executionPriceX18, position.sizeUsdX18, p.isLong);

        LibPerpsRisk.HealthState memory healthState = LibPerpsRisk.HealthState({
            collateralValueUsdX18: accountCollateralBefore,
            positionNotionalUsdX18: position.sizeUsdX18,
            unrealizedPnlUsdX18: fullUnrealizedPnlX18,
            fundingAccruedUsdX18: fundingSettlement.fundingPaidX18,
            feesAccruedUsdX18: 0
        });

        LibPerpsRisk.HealthResult memory health = LibPerpsRisk.computeHealth(market, healthState);
        if (health.meetsMaintenanceMargin) {
            revert Perps_PositionHealthy();
        }

        uint256 closeFactorBps = _closeFactorBps(health);
        closeSizeUsdX18 = _closeSize(position.sizeUsdX18, closeFactorBps);

        int256 realizedPnlX18 = _realizedPnlX18(position.entryPriceX18, p.executionPriceX18, closeSizeUsdX18, p.isLong);
        uint256 liquidationProtocolFee = _boundedLiquidationProtocolFee(market, closeSizeUsdX18, accountCollateralBefore, realizedPnlX18);

        int256 baseAfterProtocol = _toInt(accountCollateralBefore) + realizedPnlX18 - fundingSettlement.fundingPaidX18
            - _toInt(liquidationProtocolFee);

        uint256 liquidatorReward = _boundedLiquidatorReward(market, closeSizeUsdX18, baseAfterProtocol);
        int256 finalAccountEquity = baseAfterProtocol - _toInt(liquidatorReward);

        uint256 insuranceUsed;
        uint256 badDebtDelta;
        uint256 accountCollateralAfter;

        LibPerpsStorage.PerpsMarketState storage state = ps.marketState[p.marketId];
        if (finalAccountEquity >= 0) {
            accountCollateralAfter = uint256(finalAccountEquity);
        } else {
            uint256 deficit = uint256(-finalAccountEquity);

            uint256 collateralConsumed = _min(accountCollateralBefore, deficit);
            accountCollateralAfter = accountCollateralBefore - collateralConsumed;
            deficit -= collateralConsumed;

            insuranceUsed = _min(state.insuranceBalance, deficit);
            state.insuranceBalance -= insuranceUsed;
            deficit -= insuranceUsed;

            badDebtDelta = deficit;
            state.badDebt += badDebtDelta;
        }

        // Route liquidation protocol fee: insurance-target first, overflow split 70/30.
        uint256 insuranceFromProtocol;
        uint256 overflowProtocolFee;
        {
            uint256 targetGap = state.insuranceTarget > state.insuranceBalance ? state.insuranceTarget - state.insuranceBalance : 0;
            insuranceFromProtocol = _min(liquidationProtocolFee, targetGap);
            state.insuranceBalance += insuranceFromProtocol;
            overflowProtocolFee = liquidationProtocolFee - insuranceFromProtocol;
        }

        LibPerpsFees.FeeSplit memory overflowSplit;
        uint256 explicitOutboundCredit;
        if (overflowProtocolFee > 0) {
            (overflowSplit, explicitOutboundCredit) = LibPerpsFees.applyTradingFee(
                p.marketId, overflowProtocolFee, p.feePoolId, keccak256("perps.liquidation.protocol")
            );
        }

        if (liquidatorReward > 0) {
            LibPerpsDomain.debitIsolatedTracked(liquidatorReward);
        }

        uint256 insuranceTotalUsed = insuranceUsed;
        if (insuranceFromProtocol > 0) {
            if (insuranceTotalUsed >= insuranceFromProtocol) {
                insuranceTotalUsed -= insuranceFromProtocol;
            } else {
                insuranceTotalUsed = 0;
            }
        }

        ps.accountCollateral[p.accountId][p.marketId] = accountCollateralAfter;

        LibPerpsRisk.OpenInterestPreview memory oiPreview =
            LibPerpsRisk.previewOpenInterestAfterDelta(market, state, p.isLong, -_toInt(closeSizeUsdX18));
        state.openInterestLong = oiPreview.openInterestLong;
        state.openInterestShort = oiPreview.openInterestShort;
        state.skew = oiPreview.skew;

        if (realizedPnlX18 > 0) {
            state.realizedPnlOut += uint256(realizedPnlX18);
        } else if (realizedPnlX18 < 0) {
            state.realizedPnlIn += uint256(-realizedPnlX18);
        }

        uint256 nextSizeUsdX18 = position.sizeUsdX18 - closeSizeUsdX18;
        if (nextSizeUsdX18 == 0) {
            delete ps.positions[p.marketId][p.accountId][p.isLong];
        } else {
            position.sizeUsdX18 = nextSizeUsdX18;
            position.collateralAmount = accountCollateralAfter;
        }

        delta.marketId = p.marketId;
        delta.accountId = p.accountId;
        delta.realizedPnl = realizedPnlX18;
        delta.fundingPaid = fundingSettlement.fundingPaidX18;
        delta.lpFee = overflowSplit.lpFee;
        delta.protocolFee = overflowSplit.protocolFee;
        delta.liquidationProtocolFee = liquidationProtocolFee;
        delta.liquidatorReward = liquidatorReward;
        delta.insuranceUsed = insuranceTotalUsed;
        delta.badDebtDelta = badDebtDelta;

        emit PositionLiquidated(p.marketId, p.accountId, msg.sender, closeSizeUsdX18);
        emit SettlementDeltaEmitted(p.marketId, p.accountId, delta);

        LibPerpsDomain.enforceDomainSolvency(state.insuranceBalance, state.badDebt);
        LibPerpsDomain.enforceNonPerpsBackingInvariant(nonPerpsPoolIds, beforeSnap, explicitOutboundCredit);
    }

    function previewCloseFactorBps(bytes32 marketId, bytes32 accountId, bool isLong, uint256 executionPriceX18)
        external
        view
        returns (uint256 closeFactorBps, LibPerpsRisk.HealthResult memory health)
    {
        if (executionPriceX18 == 0) revert Perps_RiskLimitExceeded();

        LibPerpsStorage.Layout storage ps = LibPerpsStorage.s();
        LibPerpsStorage.PerpsMarket storage market = _requireMarket(marketId);
        LibPerpsOracle.validateExecutionPrice(market, executionPriceX18);
        _requireAccount(accountId);
        LibPerpsStorage.PerpsPosition storage position = ps.positions[marketId][accountId][isLong];
        if (position.sizeUsdX18 == 0) revert Perps_RiskLimitExceeded();

        int256 unrealizedPnlX18 = _realizedPnlX18(position.entryPriceX18, executionPriceX18, position.sizeUsdX18, isLong);
        health = LibPerpsRisk.computeHealth(
            market,
            LibPerpsRisk.HealthState({
                collateralValueUsdX18: ps.accountCollateral[accountId][marketId],
                positionNotionalUsdX18: position.sizeUsdX18,
                unrealizedPnlUsdX18: unrealizedPnlX18,
                fundingAccruedUsdX18: 0,
                feesAccruedUsdX18: 0
            })
        );
        if (health.meetsMaintenanceMargin) {
            revert Perps_PositionHealthy();
        }

        closeFactorBps = _closeFactorBps(health);
    }

    function syncMarket(bytes32 marketId) external returns (LibPerpsSync.MarketSyncResult memory syncResult) {
        LibPerpsStorage.PerpsMarket storage market = _requireMarket(marketId);
        if (market.pauseSync) revert Perps_SyncPaused(marketId);

        uint256[] memory nonPerpsPoolIds = _singlePoolArray(market.collateralPoolId);
        LibPerpsDomain.IsolationSnapshot memory beforeSnap = LibPerpsDomain.snapshotIsolation(nonPerpsPoolIds);

        syncResult = LibPerpsSync.syncMarket(marketId, uint64(block.timestamp));

        LibPerpsStorage.PerpsMarketState storage state = LibPerpsStorage.s().marketState[marketId];
        LibPerpsDomain.enforceDomainSolvency(state.insuranceBalance, state.badDebt);
        LibPerpsDomain.enforceNonPerpsBackingInvariant(nonPerpsPoolIds, beforeSnap, 0);

        if (syncResult.stateChanged) {
            emit MarketSynced(marketId);
        }
    }

    function _closeFactorBps(LibPerpsRisk.HealthResult memory health) internal pure returns (uint256) {
        if (health.equityUsdX18 <= 0) {
            return FULL_CLOSE_BPS;
        }

        int256 severeThreshold = -_toInt(health.maintenanceMarginRequiredUsdX18 / 2);
        if (health.maintenanceBufferUsdX18 <= severeThreshold) {
            return FULL_CLOSE_BPS;
        }

        return PARTIAL_CLOSE_BPS;
    }

    function _closeSize(uint256 positionSizeUsdX18, uint256 closeFactorBps) internal pure returns (uint256) {
        if (closeFactorBps > BPS_DENOMINATOR || closeFactorBps == 0) {
            revert Perps_RiskLimitExceeded();
        }

        uint256 closeSize = (positionSizeUsdX18 * closeFactorBps) / BPS_DENOMINATOR;
        if (closeSize == 0) {
            return positionSizeUsdX18;
        }
        if (closeSize > positionSizeUsdX18) {
            return positionSizeUsdX18;
        }
        return closeSize;
    }

    function _boundedLiquidationProtocolFee(
        LibPerpsStorage.PerpsMarket storage market,
        uint256 closeSizeUsdX18,
        uint256 accountCollateralBefore,
        int256 realizedPnlX18
    ) internal view returns (uint256 protocolFee) {
        uint256 maxByConfig = (closeSizeUsdX18 * market.takerFeeBps) / BPS_DENOMINATOR;
        int256 availableSigned = _toInt(accountCollateralBefore) + realizedPnlX18;
        uint256 available = availableSigned > 0 ? uint256(availableSigned) : 0;
        protocolFee = _min(maxByConfig, available);
    }

    function _boundedLiquidatorReward(LibPerpsStorage.PerpsMarket storage market, uint256 closeSizeUsdX18, int256 afterProtocol)
        internal
        view
        returns (uint256 reward)
    {
        uint256 maxByConfig = (closeSizeUsdX18 * market.liquidationIncentiveBpsMax) / BPS_DENOMINATOR;
        uint256 available = afterProtocol > 0 ? uint256(afterProtocol) : 0;
        reward = _min(maxByConfig, available);
    }

    function _singlePoolArray(uint256 poolId) private pure returns (uint256[] memory poolIds) {
        poolIds = new uint256[](1);
        poolIds[0] = poolId;
    }

    function _realizedPnlX18(uint256 entryPriceX18, uint256 exitPriceX18, uint256 sizeDeltaUsdX18, bool isLong)
        internal
        pure
        returns (int256 pnlX18)
    {
        if (entryPriceX18 == 0) revert Perps_RiskLimitExceeded();
        if (isLong) {
            pnlX18 = (_toInt(sizeDeltaUsdX18) * (_toInt(exitPriceX18) - _toInt(entryPriceX18))) / _toInt(entryPriceX18);
        } else {
            pnlX18 = (_toInt(sizeDeltaUsdX18) * (_toInt(entryPriceX18) - _toInt(exitPriceX18))) / _toInt(entryPriceX18);
        }
    }

    function _toInt(uint256 value) internal pure returns (int256 signed) {
        if (value > uint256(type(int256).max)) revert Perps_RiskLimitExceeded();
        signed = int256(value);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a <= b ? a : b;
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
