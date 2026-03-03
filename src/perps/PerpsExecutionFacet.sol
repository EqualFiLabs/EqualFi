// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibPositionNFT} from "../libraries/LibPositionNFT.sol";
import {LibPerpsDomain} from "./LibPerpsDomain.sol";
import {LibPerpsFees} from "./LibPerpsFees.sol";
import {LibPerpsFunding} from "./LibPerpsFunding.sol";
import {LibPerpsIdentity} from "./LibPerpsIdentity.sol";
import {LibPerpsIntent} from "./LibPerpsIntent.sol";
import {LibPerpsOracle} from "./LibPerpsOracle.sol";
import {LibPerpsRisk} from "./LibPerpsRisk.sol";
import {LibPerpsSync} from "./LibPerpsSync.sol";
import {LibPerpsStorage} from "./LibPerpsStorage.sol";
import {
    Perps_AccountNotFound,
    Perps_DecreasePaused,
    Perps_IncreasePaused,
    Perps_InsufficientPerpsLiquidity,
    Perps_MarketNotFound,
    Perps_RiskLimitExceeded,
    Perps_SyncPaused
} from "./PerpsErrors.sol";

interface IPerpsExecutionPositionNFT {
    function getPositionKey(uint256 tokenId) external view returns (bytes32);
}

/// @notice Account lifecycle and collateral reservation entry points for perps participants.
contract PerpsExecutionFacet {
    uint8 internal constant ACTION_OPEN_INCREASE = 1;
    uint8 internal constant ACTION_DECREASE_CLOSE = 2;
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    struct AddCollateralParams {
        bytes32 marketId;
        bytes32 accountId;
        address collateralAsset;
        uint256 amount;
    }

    struct RemoveCollateralParams {
        bytes32 marketId;
        bytes32 accountId;
        address collateralAsset;
        uint256 amount;
    }

    struct OpenIncreaseParams {
        bytes32 marketId;
        bytes32 accountId;
        bool isLong;
        uint256 sizeDeltaUsdX18;
        uint256 executionPriceX18;
        uint256 limitPriceX18;
        uint256 maxSlippageBps;
        uint256 feePoolId;
        uint256 executorFee;
    }

    struct DecreaseCloseParams {
        bytes32 marketId;
        bytes32 accountId;
        bool isLong;
        uint256 sizeDeltaUsdX18;
        uint256 executionPriceX18;
        uint256 limitPriceX18;
        uint256 maxSlippageBps;
        uint256 feePoolId;
        uint256 executorFee;
    }

    struct IntentExecutionParams {
        address signer;
        uint256 executionPriceX18;
        uint256 feePoolId;
        uint256 executorFee;
    }

    event PerpsAccountCreated(bytes32 indexed accountId, bytes32 indexed positionKey, uint256 indexed positionTokenId);
    event PerpsCollateralAdded(bytes32 indexed marketId, bytes32 indexed accountId, address collateralAsset, uint256 amount);
    event PerpsCollateralRemoved(bytes32 indexed marketId, bytes32 indexed accountId, address collateralAsset, uint256 amount);
    event PerpsIntentExecuted(bytes32 indexed marketId, bytes32 indexed accountId, uint8 action, address executor);
    event PositionIncreased(bytes32 indexed marketId, bytes32 indexed accountId, bool isLong, uint256 sizeDeltaUsdX18);
    event PositionDecreased(bytes32 indexed marketId, bytes32 indexed accountId, bool isLong, uint256 sizeDeltaUsdX18);
    event PositionClosed(bytes32 indexed marketId, bytes32 indexed accountId, bool isLong);
    event AccountSynced(bytes32 indexed marketId, bytes32 indexed accountId);
    event SettlementDeltaEmitted(bytes32 indexed marketId, bytes32 indexed accountId, LibPerpsStorage.SettlementDelta delta);

    function createAccount(uint256 positionId, uint256 subaccountNonce) external returns (bytes32 accountId) {
        LibPerpsIntent.requirePositionAuthority(positionId);

        bytes32 positionKey = _positionNft().getPositionKey(positionId);
        accountId = LibPerpsIdentity.deriveAccountId(positionKey, subaccountNonce);

        LibPerpsStorage.Layout storage ps = LibPerpsStorage.s();
        LibPerpsStorage.PerpsAccount storage account = ps.accounts[accountId];
        if (!account.exists) {
            account.accountId = accountId;
            account.positionKey = positionKey;
            account.positionTokenId = positionId;
            account.nonce = ps.minValidNonce[accountId];
            account.exists = true;
            ps.accountCount += 1;
            emit PerpsAccountCreated(accountId, positionKey, positionId);
        }
    }

    function addCollateral(AddCollateralParams calldata p) external {
        if (p.amount == 0) revert Perps_RiskLimitExceeded();

        LibPerpsStorage.PerpsMarket storage market = _requireMarket(p.marketId);
        if (p.collateralAsset != market.collateralAsset) revert Perps_RiskLimitExceeded();

        _requireAccount(p.accountId);
        LibPerpsIntent.requireDirectCallAuthority(p.accountId);

        uint256[] memory nonPerpsPoolIds = _singlePoolArray(market.collateralPoolId);
        LibPerpsDomain.IsolationSnapshot memory beforeSnap = LibPerpsDomain.snapshotIsolation(nonPerpsPoolIds);

        LibPerpsStorage.Layout storage ps = LibPerpsStorage.s();
        ps.accountCollateral[p.accountId][p.marketId] += p.amount;
        ps.marketState[p.marketId].reservedCollateral += p.amount;
        LibPerpsDomain.reserveIsolatedBacking(p.amount);

        LibPerpsDomain.enforceNonPerpsBackingInvariant(nonPerpsPoolIds, beforeSnap, 0);
        emit PerpsCollateralAdded(p.marketId, p.accountId, p.collateralAsset, p.amount);
    }

    function removeCollateral(RemoveCollateralParams calldata p) external {
        if (p.amount == 0) revert Perps_RiskLimitExceeded();

        LibPerpsStorage.PerpsMarket storage market = _requireMarket(p.marketId);
        if (market.pauseDecrease) revert Perps_DecreasePaused(p.marketId);
        if (p.collateralAsset != market.collateralAsset) revert Perps_RiskLimitExceeded();

        LibPerpsStorage.Layout storage ps = LibPerpsStorage.s();
        _requireAccount(p.accountId);
        LibPerpsIntent.requireDirectCallAuthority(p.accountId);

        uint256 currentCollateral = ps.accountCollateral[p.accountId][p.marketId];
        if (currentCollateral < p.amount) {
            revert Perps_InsufficientPerpsLiquidity(p.amount, currentCollateral);
        }

        uint256[] memory nonPerpsPoolIds = _singlePoolArray(market.collateralPoolId);
        LibPerpsDomain.IsolationSnapshot memory beforeSnap = LibPerpsDomain.snapshotIsolation(nonPerpsPoolIds);

        ps.accountCollateral[p.accountId][p.marketId] = currentCollateral - p.amount;
        ps.marketState[p.marketId].reservedCollateral -= p.amount;
        LibPerpsDomain.releaseIsolatedBacking(p.amount);

        LibPerpsStorage.PerpsMarketState storage state = ps.marketState[p.marketId];
        LibPerpsDomain.enforceDomainSolvency(state.insuranceBalance, state.badDebt);
        LibPerpsDomain.enforceNonPerpsBackingInvariant(nonPerpsPoolIds, beforeSnap, 0);

        emit PerpsCollateralRemoved(p.marketId, p.accountId, p.collateralAsset, p.amount);
    }

    function openOrIncrease(OpenIncreaseParams calldata p) external returns (LibPerpsStorage.SettlementDelta memory delta) {
        _requireAccount(p.accountId);
        LibPerpsIntent.requireDirectCallAuthority(p.accountId);
        delta = _openOrIncrease(p, p.executorFee);
    }

    function decreaseOrClose(DecreaseCloseParams calldata p) external returns (LibPerpsStorage.SettlementDelta memory delta) {
        _requireAccount(p.accountId);
        LibPerpsIntent.requireDirectCallAuthority(p.accountId);
        delta = _decreaseOrClose(p, p.executorFee);
    }

    function executeIntent(
        LibPerpsStorage.PerpsIntent calldata intent,
        IntentExecutionParams calldata exec,
        bytes calldata signature
    ) external returns (LibPerpsStorage.SettlementDelta memory delta) {
        LibPerpsIntent.validateIntentAndSignature(intent, exec.signer, signature);

        if (intent.action == ACTION_OPEN_INCREASE) {
            if (intent.collateralDelta != 0 || intent.sizeDeltaUsdX18 == 0) revert Perps_RiskLimitExceeded();
            OpenIncreaseParams memory p = OpenIncreaseParams({
                marketId: intent.marketId,
                accountId: intent.accountId,
                isLong: intent.isLong,
                sizeDeltaUsdX18: intent.sizeDeltaUsdX18,
                executionPriceX18: exec.executionPriceX18,
                limitPriceX18: intent.limitPriceX18,
                maxSlippageBps: intent.maxSlippageBps,
                feePoolId: exec.feePoolId,
                executorFee: exec.executorFee
            });
            delta = _openOrIncrease(p, intent.maxExecutorFee);
        } else if (intent.action == ACTION_DECREASE_CLOSE) {
            if (intent.collateralDelta != 0 || intent.sizeDeltaUsdX18 == 0) revert Perps_RiskLimitExceeded();
            DecreaseCloseParams memory p = DecreaseCloseParams({
                marketId: intent.marketId,
                accountId: intent.accountId,
                isLong: intent.isLong,
                sizeDeltaUsdX18: intent.sizeDeltaUsdX18,
                executionPriceX18: exec.executionPriceX18,
                limitPriceX18: intent.limitPriceX18,
                maxSlippageBps: intent.maxSlippageBps,
                feePoolId: exec.feePoolId,
                executorFee: exec.executorFee
            });
            delta = _decreaseOrClose(p, intent.maxExecutorFee);
        } else {
            revert Perps_RiskLimitExceeded();
        }

        LibPerpsIntent.consumeIntentNonce(intent.accountId, intent.nonce);
        emit PerpsIntentExecuted(intent.marketId, intent.accountId, intent.action, msg.sender);
    }

    function cancelIntent(bytes32 accountId, bytes32 intentHash) external {
        LibPerpsIntent.cancelIntent(accountId, intentHash);
    }

    function invalidateNoncesUpTo(bytes32 accountId, uint64 nonceUpperBound) external {
        LibPerpsIntent.invalidateNoncesUpTo(accountId, nonceUpperBound);
    }

    function syncAccount(bytes32 accountId, bytes32 marketId)
        external
        returns (LibPerpsStorage.SettlementDelta memory delta, LibPerpsSync.AccountSyncResult memory syncResult)
    {
        LibPerpsStorage.PerpsMarket storage market = _requireMarket(marketId);
        _requireAccount(accountId);
        if (market.pauseSync) revert Perps_SyncPaused(marketId);

        uint256[] memory nonPerpsPoolIds = _singlePoolArray(market.collateralPoolId);
        LibPerpsDomain.IsolationSnapshot memory beforeSnap = LibPerpsDomain.snapshotIsolation(nonPerpsPoolIds);

        (syncResult, delta) = LibPerpsSync.syncAccount(marketId, accountId, uint64(block.timestamp));

        LibPerpsStorage.PerpsMarketState storage state = LibPerpsStorage.s().marketState[marketId];
        LibPerpsDomain.enforceDomainSolvency(state.insuranceBalance, state.badDebt);
        LibPerpsDomain.enforceNonPerpsBackingInvariant(nonPerpsPoolIds, beforeSnap, 0);

        if (syncResult.stateChanged) {
            emit AccountSynced(marketId, accountId);
            emit SettlementDeltaEmitted(marketId, accountId, delta);
        }
    }

    function deriveAccountIdForPosition(uint256 positionId, uint256 subaccountNonce) external view returns (bytes32) {
        bytes32 positionKey = _positionNft().getPositionKey(positionId);
        return LibPerpsIdentity.deriveAccountId(positionKey, subaccountNonce);
    }

    function accountExists(bytes32 accountId) external view returns (bool) {
        return LibPerpsStorage.s().accounts[accountId].exists;
    }

    function getAccount(bytes32 accountId) external view returns (LibPerpsStorage.PerpsAccount memory) {
        return _requireAccount(accountId);
    }

    function getAccountCollateral(bytes32 marketId, bytes32 accountId) external view returns (uint256) {
        _requireMarket(marketId);
        _requireAccount(accountId);
        return LibPerpsStorage.s().accountCollateral[accountId][marketId];
    }

    function getPosition(bytes32 marketId, bytes32 accountId, bool isLong)
        external
        view
        returns (LibPerpsStorage.PerpsPosition memory)
    {
        _requireMarket(marketId);
        _requireAccount(accountId);
        return LibPerpsStorage.s().positions[marketId][accountId][isLong];
    }

    function intentDigest(LibPerpsStorage.PerpsIntent calldata intent) external view returns (bytes32) {
        return LibPerpsIntent.intentDigest(intent);
    }

    function _openOrIncrease(OpenIncreaseParams memory p, uint256 executorFeeCap)
        internal
        returns (LibPerpsStorage.SettlementDelta memory delta)
    {
        if (p.sizeDeltaUsdX18 == 0 || p.executionPriceX18 == 0 || p.limitPriceX18 == 0) revert Perps_RiskLimitExceeded();

        LibPerpsStorage.Layout storage ps = LibPerpsStorage.s();
        LibPerpsStorage.PerpsMarket storage market = _requireMarket(p.marketId);
        _requireAccount(p.accountId);

        if (market.pauseIncrease) revert Perps_IncreasePaused(p.marketId);
        if (p.isLong && !market.longEnabled) revert Perps_RiskLimitExceeded();
        if (!p.isLong && !market.shortEnabled) revert Perps_RiskLimitExceeded();
        LibPerpsOracle.validateExecutionPrice(market, p.executionPriceX18);
        _enforcePriceBounds(p.limitPriceX18, p.executionPriceX18, p.maxSlippageBps);

        uint256[] memory nonPerpsPoolIds = _singlePoolArray(market.collateralPoolId);
        LibPerpsDomain.IsolationSnapshot memory beforeSnap = LibPerpsDomain.snapshotIsolation(nonPerpsPoolIds);

        LibPerpsFunding.updateMarketFunding(p.marketId, uint64(block.timestamp));
        LibPerpsFunding.FundingSettlement memory fundingSettlement =
            LibPerpsFunding.settlePositionFunding(p.marketId, p.accountId, p.isLong);

        uint256 tradingFee = (p.sizeDeltaUsdX18 * market.takerFeeBps) / BPS_DENOMINATOR;
        (LibPerpsFees.FeeSplit memory feeSplit, uint256 explicitOutboundCredit) =
            LibPerpsFees.applyTradingFee(p.marketId, tradingFee, p.feePoolId, keccak256("perps.trade"));
        uint256 executorFee = LibPerpsFees.applyExecutorFee(p.executorFee, executorFeeCap);

        LibPerpsStorage.PerpsPosition storage position = ps.positions[p.marketId][p.accountId][p.isLong];
        uint256 currentSize = position.sizeUsdX18;
        uint256 nextSize = currentSize + p.sizeDeltaUsdX18;

        LibPerpsRisk.HealthState memory healthState = LibPerpsRisk.HealthState({
            collateralValueUsdX18: ps.accountCollateral[p.accountId][p.marketId],
            positionNotionalUsdX18: nextSize,
            unrealizedPnlUsdX18: 0,
            fundingAccruedUsdX18: fundingSettlement.fundingPaidX18,
            feesAccruedUsdX18: tradingFee + executorFee
        });
        LibPerpsRisk.enforceOpenRisk(market, healthState);

        LibPerpsRisk.OpenInterestPreview memory oiPreview = LibPerpsRisk.previewOpenInterestAfterDelta(
            market, ps.marketState[p.marketId], p.isLong, _toInt(p.sizeDeltaUsdX18)
        );
        _storeOpenInterestPreview(ps.marketState[p.marketId], oiPreview);

        if (currentSize == 0) {
            position.isLong = p.isLong;
            position.entryPriceX18 = p.executionPriceX18;
            position.realizedPnlX18 = 0;
        } else {
            position.entryPriceX18 =
                ((position.entryPriceX18 * currentSize) + (p.executionPriceX18 * p.sizeDeltaUsdX18)) / nextSize;
        }
        position.sizeUsdX18 = nextSize;
        position.collateralAmount = ps.accountCollateral[p.accountId][p.marketId];
        position.lastIncreaseTs = uint64(block.timestamp);

        delta.marketId = p.marketId;
        delta.accountId = p.accountId;
        delta.fundingPaid = fundingSettlement.fundingPaidX18;
        delta.takerFee = tradingFee;
        delta.lpFee = feeSplit.lpFee;
        delta.protocolFee = feeSplit.protocolFee;
        delta.executorFee = executorFee;

        emit PositionIncreased(p.marketId, p.accountId, p.isLong, p.sizeDeltaUsdX18);
        emit SettlementDeltaEmitted(p.marketId, p.accountId, delta);
        LibPerpsDomain.enforceNonPerpsBackingInvariant(nonPerpsPoolIds, beforeSnap, explicitOutboundCredit);
    }

    function _decreaseOrClose(DecreaseCloseParams memory p, uint256 executorFeeCap)
        internal
        returns (LibPerpsStorage.SettlementDelta memory delta)
    {
        if (p.sizeDeltaUsdX18 == 0 || p.executionPriceX18 == 0 || p.limitPriceX18 == 0) revert Perps_RiskLimitExceeded();

        LibPerpsStorage.Layout storage ps = LibPerpsStorage.s();
        LibPerpsStorage.PerpsMarket storage market = _requireMarket(p.marketId);
        _requireAccount(p.accountId);

        if (market.pauseDecrease) revert Perps_DecreasePaused(p.marketId);
        LibPerpsOracle.validateExecutionPrice(market, p.executionPriceX18);
        _enforcePriceBounds(p.limitPriceX18, p.executionPriceX18, p.maxSlippageBps);

        LibPerpsStorage.PerpsPosition storage position = ps.positions[p.marketId][p.accountId][p.isLong];
        uint256 currentSize = position.sizeUsdX18;
        if (currentSize == 0 || p.sizeDeltaUsdX18 > currentSize) revert Perps_RiskLimitExceeded();

        uint256[] memory nonPerpsPoolIds = _singlePoolArray(market.collateralPoolId);
        LibPerpsDomain.IsolationSnapshot memory beforeSnap = LibPerpsDomain.snapshotIsolation(nonPerpsPoolIds);

        LibPerpsFunding.updateMarketFunding(p.marketId, uint64(block.timestamp));
        LibPerpsFunding.FundingSettlement memory fundingSettlement =
            LibPerpsFunding.settlePositionFunding(p.marketId, p.accountId, p.isLong);

        uint256 tradingFee = (p.sizeDeltaUsdX18 * market.takerFeeBps) / BPS_DENOMINATOR;
        (LibPerpsFees.FeeSplit memory feeSplit, uint256 explicitOutboundCredit) =
            LibPerpsFees.applyTradingFee(p.marketId, tradingFee, p.feePoolId, keccak256("perps.trade"));
        uint256 executorFee = LibPerpsFees.applyExecutorFee(p.executorFee, executorFeeCap);

        int256 realizedPnl = _realizedPnlX18(position.entryPriceX18, p.executionPriceX18, p.sizeDeltaUsdX18, p.isLong);
        int256 netPayout = realizedPnl - fundingSettlement.fundingPaidX18 - _toInt(tradingFee + executorFee);
        if (netPayout > 0) {
            LibPerpsDomain.debitIsolatedTracked(uint256(netPayout));
        } else if (netPayout < 0) {
            LibPerpsDomain.creditIsolatedTracked(uint256(-netPayout));
        }

        LibPerpsRisk.OpenInterestPreview memory oiPreview = LibPerpsRisk.previewOpenInterestAfterDelta(
            market, ps.marketState[p.marketId], p.isLong, -_toInt(p.sizeDeltaUsdX18)
        );
        LibPerpsStorage.PerpsMarketState storage state = ps.marketState[p.marketId];
        _storeOpenInterestPreview(state, oiPreview);

        if (realizedPnl > 0) {
            state.realizedPnlOut += uint256(realizedPnl);
        } else if (realizedPnl < 0) {
            state.realizedPnlIn += uint256(-realizedPnl);
        }

        uint256 nextSize = currentSize - p.sizeDeltaUsdX18;
        if (nextSize == 0) {
            delete ps.positions[p.marketId][p.accountId][p.isLong];
            emit PositionClosed(p.marketId, p.accountId, p.isLong);
        } else {
            position.sizeUsdX18 = nextSize;
            emit PositionDecreased(p.marketId, p.accountId, p.isLong, p.sizeDeltaUsdX18);
        }

        delta.marketId = p.marketId;
        delta.accountId = p.accountId;
        delta.collateralInOut = netPayout;
        delta.realizedPnl = realizedPnl;
        delta.fundingPaid = fundingSettlement.fundingPaidX18;
        delta.takerFee = tradingFee;
        delta.lpFee = feeSplit.lpFee;
        delta.protocolFee = feeSplit.protocolFee;
        delta.executorFee = executorFee;

        emit SettlementDeltaEmitted(p.marketId, p.accountId, delta);
        LibPerpsDomain.enforceNonPerpsBackingInvariant(nonPerpsPoolIds, beforeSnap, explicitOutboundCredit);
    }

    function _storeOpenInterestPreview(
        LibPerpsStorage.PerpsMarketState storage state,
        LibPerpsRisk.OpenInterestPreview memory preview
    ) internal {
        state.openInterestLong = preview.openInterestLong;
        state.openInterestShort = preview.openInterestShort;
        state.skew = preview.skew;
    }

    function _enforcePriceBounds(uint256 limitPriceX18, uint256 executionPriceX18, uint256 maxSlippageBps) internal pure {
        if (maxSlippageBps > BPS_DENOMINATOR) revert Perps_RiskLimitExceeded();
        uint256 tolerance = (limitPriceX18 * maxSlippageBps) / BPS_DENOMINATOR;
        uint256 lower = limitPriceX18 > tolerance ? limitPriceX18 - tolerance : 0;
        uint256 upper = limitPriceX18 + tolerance;
        if (executionPriceX18 < lower || executionPriceX18 > upper) revert Perps_RiskLimitExceeded();
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

    function _singlePoolArray(uint256 poolId) private pure returns (uint256[] memory poolIds) {
        poolIds = new uint256[](1);
        poolIds[0] = poolId;
    }

    function _positionNft() internal view returns (IPerpsExecutionPositionNFT nft) {
        address nftAddress = LibPositionNFT.s().positionNFTContract;
        if (nftAddress == address(0)) revert Perps_RiskLimitExceeded();
        return IPerpsExecutionPositionNFT(nftAddress);
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
