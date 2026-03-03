// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibPerpsFunding} from "./LibPerpsFunding.sol";
import {LibPerpsStorage} from "./LibPerpsStorage.sol";

/// @notice Idempotent account/market reconciliation helpers for permissionless sync checkpoints.
library LibPerpsSync {
    struct AccountSyncResult {
        bool stateChanged;
        bool marketFundingUpdated;
        int256 fundingPaidX18;
        int256 longFundingPaidX18;
        int256 shortFundingPaidX18;
    }

    struct MarketSyncResult {
        bool stateChanged;
        bool marketFundingUpdated;
        uint64 previousFundingTs;
        uint64 currentFundingTs;
        int256 previousFundingLongX18;
        int256 previousFundingShortX18;
        int256 nextFundingLongX18;
        int256 nextFundingShortX18;
    }

    function syncMarket(bytes32 marketId, uint64 nowTs) internal returns (MarketSyncResult memory result) {
        LibPerpsStorage.Layout storage ps = LibPerpsStorage.s();
        LibPerpsStorage.PerpsMarketState storage state = ps.marketState[marketId];

        result.previousFundingTs = state.lastFundingTs;
        result.previousFundingLongX18 = state.cumulativeFundingLongX18;
        result.previousFundingShortX18 = state.cumulativeFundingShortX18;

        (, result.nextFundingLongX18, result.nextFundingShortX18) = LibPerpsFunding.updateMarketFunding(marketId, nowTs);

        result.currentFundingTs = state.lastFundingTs;
        result.marketFundingUpdated = result.currentFundingTs != result.previousFundingTs
            || result.nextFundingLongX18 != result.previousFundingLongX18
            || result.nextFundingShortX18 != result.previousFundingShortX18;
        result.stateChanged = result.marketFundingUpdated;
    }

    function syncAccount(bytes32 marketId, bytes32 accountId, uint64 nowTs)
        internal
        returns (AccountSyncResult memory result, LibPerpsStorage.SettlementDelta memory delta)
    {
        delta.marketId = marketId;
        delta.accountId = accountId;

        MarketSyncResult memory marketSync = syncMarket(marketId, nowTs);
        result.stateChanged = marketSync.stateChanged;
        result.marketFundingUpdated = marketSync.marketFundingUpdated;

        LibPerpsStorage.Layout storage ps = LibPerpsStorage.s();
        LibPerpsStorage.PerpsPosition storage longPosition = ps.positions[marketId][accountId][true];
        LibPerpsStorage.PerpsPosition storage shortPosition = ps.positions[marketId][accountId][false];

        if (longPosition.sizeUsdX18 != 0) {
            int256 previousLongFunding = longPosition.entryFundingX18;
            LibPerpsFunding.FundingSettlement memory longSettlement = LibPerpsFunding.settlePositionFunding(marketId, accountId, true);
            result.longFundingPaidX18 = longSettlement.fundingPaidX18;
            if (longPosition.entryFundingX18 != previousLongFunding || longSettlement.fundingPaidX18 != 0) {
                result.stateChanged = true;
            }
        }

        if (shortPosition.sizeUsdX18 != 0) {
            int256 previousShortFunding = shortPosition.entryFundingX18;
            LibPerpsFunding.FundingSettlement memory shortSettlement =
                LibPerpsFunding.settlePositionFunding(marketId, accountId, false);
            result.shortFundingPaidX18 = shortSettlement.fundingPaidX18;
            if (shortPosition.entryFundingX18 != previousShortFunding || shortSettlement.fundingPaidX18 != 0) {
                result.stateChanged = true;
            }
        }

        result.fundingPaidX18 = result.longFundingPaidX18 + result.shortFundingPaidX18;
        delta.fundingPaid = result.fundingPaidX18;
    }
}
