// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IPerpsOracleAdapter} from "./IPerpsOracleAdapter.sol";
import {LibPerpsStorage} from "./LibPerpsStorage.sol";
import {Perps_PriceOutOfBounds, Perps_PriceStale} from "./PerpsErrors.sol";

/// @notice Oracle adapter checks for perps execution and liquidation paths.
library LibPerpsOracle {
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    struct OraclePrice {
        uint256 priceX18;
        uint256 updatedAt;
        uint256 deviationOrConfidenceBps;
    }

    function validateExecutionPrice(LibPerpsStorage.PerpsMarket storage market, uint256 executionPriceX18)
        internal
        view
        returns (OraclePrice memory oraclePrice)
    {
        oraclePrice = _readAndValidateOracle(market);
        _enforceExecutionDeviation(market.maxDeviationBps, executionPriceX18, oraclePrice.priceX18);
    }

    function validateOracleFreshness(LibPerpsStorage.PerpsMarket storage market)
        internal
        view
        returns (OraclePrice memory oraclePrice)
    {
        oraclePrice = _readAndValidateOracle(market);
    }

    function _readAndValidateOracle(LibPerpsStorage.PerpsMarket storage market)
        private
        view
        returns (OraclePrice memory oraclePrice)
    {
        if (market.oracleAdapter == address(0)) revert Perps_PriceOutOfBounds();
        (oraclePrice.priceX18, oraclePrice.updatedAt, oraclePrice.deviationOrConfidenceBps) =
            IPerpsOracleAdapter(market.oracleAdapter).getMarkPrice(market.marketId, market.indexAsset);
        if (oraclePrice.priceX18 == 0) revert Perps_PriceOutOfBounds();
        if (oraclePrice.updatedAt > block.timestamp || block.timestamp - oraclePrice.updatedAt > market.maxStaleness) {
            revert Perps_PriceStale(oraclePrice.updatedAt, market.maxStaleness);
        }

        if (market.maxDeviationBps != 0 && oraclePrice.deviationOrConfidenceBps > market.maxDeviationBps) {
            revert Perps_PriceOutOfBounds();
        }
    }

    function _enforceExecutionDeviation(uint32 maxDeviationBps, uint256 executionPriceX18, uint256 oraclePriceX18)
        private
        pure
    {
        if (maxDeviationBps == 0) return;
        if (executionPriceX18 == 0 || oraclePriceX18 == 0) revert Perps_PriceOutOfBounds();

        uint256 diff = executionPriceX18 > oraclePriceX18 ? executionPriceX18 - oraclePriceX18 : oraclePriceX18 - executionPriceX18;
        uint256 observedDeviationBps = (diff * BPS_DENOMINATOR) / oraclePriceX18;
        if (observedDeviationBps > maxDeviationBps) revert Perps_PriceOutOfBounds();
    }
}
