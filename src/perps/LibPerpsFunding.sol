// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibPerpsStorage} from "./LibPerpsStorage.sol";
import {Perps_RiskLimitExceeded} from "./PerpsErrors.sol";

/// @notice Cumulative per-market funding updates and per-position funding settlement helpers.
library LibPerpsFunding {
    uint256 internal constant X18 = 1e18;
    uint256 internal constant DAY = 1 days;
    uint256 internal constant BPS_TO_X18 = 1e14;

    struct FundingComputation {
        uint64 elapsed;
        int256 skewRatioX18;
        int256 fundingVelocityX18PerDay;
        int256 fundingDeltaX18;
    }

    struct FundingSettlement {
        int256 fundingPaidX18;
        int256 previousFundingIndexX18;
        int256 currentFundingIndexX18;
    }

    function updateMarketFunding(bytes32 marketId, uint64 nowTs)
        internal
        returns (FundingComputation memory computation, int256 nextLongFundingX18, int256 nextShortFundingX18)
    {
        LibPerpsStorage.Layout storage ps = LibPerpsStorage.s();
        LibPerpsStorage.PerpsMarket storage market = ps.markets[marketId];
        LibPerpsStorage.PerpsMarketState storage state = ps.marketState[marketId];

        (computation, nextLongFundingX18, nextShortFundingX18) = previewMarketFunding(market, state, nowTs);

        if (state.lastFundingTs == 0) {
            state.lastFundingTs = nowTs;
            return (computation, state.cumulativeFundingLongX18, state.cumulativeFundingShortX18);
        }
        if (computation.elapsed == 0) {
            return (computation, state.cumulativeFundingLongX18, state.cumulativeFundingShortX18);
        }

        state.cumulativeFundingLongX18 = nextLongFundingX18;
        state.cumulativeFundingShortX18 = nextShortFundingX18;
        state.lastFundingTs = nowTs;
    }

    function previewMarketFunding(
        LibPerpsStorage.PerpsMarket memory market,
        LibPerpsStorage.PerpsMarketState memory state,
        uint64 nowTs
    ) internal pure returns (FundingComputation memory computation, int256 nextLongFundingX18, int256 nextShortFundingX18) {
        nextLongFundingX18 = state.cumulativeFundingLongX18;
        nextShortFundingX18 = state.cumulativeFundingShortX18;

        if (state.lastFundingTs == 0 || nowTs <= state.lastFundingTs) {
            return (computation, nextLongFundingX18, nextShortFundingX18);
        }

        computation.elapsed = nowTs - state.lastFundingTs;
        computation.skewRatioX18 = _skewRatioX18(state.skew, market.maxSkewAbs);
        computation.fundingVelocityX18PerDay = _fundingVelocityX18PerDay(computation.skewRatioX18, market.maxFundingVelocityBpsPerDay);
        computation.fundingDeltaX18 = (computation.fundingVelocityX18PerDay * int256(uint256(computation.elapsed))) / int256(DAY);

        nextLongFundingX18 = state.cumulativeFundingLongX18 + computation.fundingDeltaX18;
        nextShortFundingX18 = state.cumulativeFundingShortX18 - computation.fundingDeltaX18;
    }

    function settlePositionFunding(bytes32 marketId, bytes32 accountId, bool isLong)
        internal
        returns (FundingSettlement memory settlement)
    {
        LibPerpsStorage.Layout storage ps = LibPerpsStorage.s();
        LibPerpsStorage.PerpsPosition storage position = ps.positions[marketId][accountId][isLong];
        int256 currentFundingIndexX18 =
            isLong ? ps.marketState[marketId].cumulativeFundingLongX18 : ps.marketState[marketId].cumulativeFundingShortX18;

        settlement.previousFundingIndexX18 = position.entryFundingX18;
        settlement.currentFundingIndexX18 = currentFundingIndexX18;

        int256 fundingIndexDeltaX18 = currentFundingIndexX18 - position.entryFundingX18;
        if (position.sizeUsdX18 != 0 && fundingIndexDeltaX18 != 0) {
            settlement.fundingPaidX18 = (_toInt(position.sizeUsdX18) * fundingIndexDeltaX18) / int256(X18);
        }

        position.entryFundingX18 = currentFundingIndexX18;
    }

    function previewPositionFunding(
        LibPerpsStorage.PerpsPosition memory position,
        int256 currentFundingIndexX18
    ) internal pure returns (FundingSettlement memory settlement) {
        settlement.previousFundingIndexX18 = position.entryFundingX18;
        settlement.currentFundingIndexX18 = currentFundingIndexX18;

        int256 fundingIndexDeltaX18 = currentFundingIndexX18 - position.entryFundingX18;
        if (position.sizeUsdX18 != 0 && fundingIndexDeltaX18 != 0) {
            settlement.fundingPaidX18 = (_toInt(position.sizeUsdX18) * fundingIndexDeltaX18) / int256(X18);
        }
    }

    function _skewRatioX18(int256 skew, uint256 maxSkewAbs) private pure returns (int256 ratioX18) {
        uint256 denom = maxSkewAbs == 0 ? 1 : maxSkewAbs;
        ratioX18 = (skew * int256(X18)) / _toInt(denom);
        if (ratioX18 > int256(X18)) return int256(X18);
        if (ratioX18 < -int256(X18)) return -int256(X18);
    }

    function _fundingVelocityX18PerDay(int256 skewRatioX18, uint32 maxFundingVelocityBpsPerDay)
        private
        pure
        returns (int256)
    {
        int256 raw = (skewRatioX18 * int256(uint256(maxFundingVelocityBpsPerDay)) * int256(BPS_TO_X18)) / int256(X18);
        int256 bound = int256(uint256(maxFundingVelocityBpsPerDay)) * int256(BPS_TO_X18);
        if (raw > bound) return bound;
        if (raw < -bound) return -bound;
        return raw;
    }

    function _toInt(uint256 value) private pure returns (int256 signed) {
        if (value > uint256(type(int256).max)) revert Perps_RiskLimitExceeded();
        signed = int256(value);
    }
}
