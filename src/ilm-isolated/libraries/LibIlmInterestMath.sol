// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IlmIsolatedTypes} from "../types/IlmIsolatedTypes.sol";
import {IIlmIsolatedIrmAdapter} from "../interfaces/IIlmIsolatedIrmAdapter.sol";
import {IlmIsolatedInvalidInput} from "../errors/IlmIsolatedErrors.sol";

/// @notice Interest accrual helpers for ILM isolated markets.
library LibIlmInterestMath {
    uint256 internal constant WAD = 1e18;

    /// @notice Taylor-compounded approximation: e^(rate * time) - 1.
    /// @dev Uses first 3 terms: x + x^2/2 + x^3/6 where x = rate * time.
    function wTaylorCompounded(uint256 ratePerSecond, uint256 elapsedSeconds) internal pure returns (uint256) {
        uint256 x = ratePerSecond * elapsedSeconds;
        uint256 x2 = x * x / WAD;
        uint256 x3 = x2 * x / WAD;
        return x + (x2 / 2) + (x3 / 6);
    }

    /// @notice Accrue gross borrow interest and compute protocol-fee accrual.
    function accrueInterest(
        IlmIsolatedTypes.IlmIsolatedMarket storage market,
        IlmIsolatedTypes.IlmIsolatedMarketParams storage params,
        uint256 fee
    ) internal returns (uint256 grossInterest, uint256 protocolFeeAccrued) {
        uint256 elapsed = block.timestamp - uint256(market.lastUpdate);
        if (elapsed == 0) {
            return (0, 0);
        }

        IlmIsolatedTypes.IlmIsolatedMarketParams memory paramsMem = params;
        IlmIsolatedTypes.IlmIsolatedMarket memory marketMem = market;
        uint256 ratePerSecond = IIlmIsolatedIrmAdapter(params.irm).borrowRate(paramsMem, marketMem);

        uint256 interestFactor = wTaylorCompounded(ratePerSecond, elapsed);
        grossInterest = uint256(market.totalBorrowAssets) * interestFactor / WAD;
        protocolFeeAccrued = grossInterest * fee / WAD;

        uint256 newTotalBorrowAssets = uint256(market.totalBorrowAssets) + grossInterest;
        uint256 newTotalSupplyAssets = uint256(market.totalSupplyAssets) + grossInterest - protocolFeeAccrued;

        if (newTotalBorrowAssets > type(uint128).max || newTotalSupplyAssets > type(uint128).max) {
            revert IlmIsolatedInvalidInput();
        }

        market.totalBorrowAssets = uint128(newTotalBorrowAssets);
        market.totalSupplyAssets = uint128(newTotalSupplyAssets);

        if (block.timestamp > type(uint128).max) {
            revert IlmIsolatedInvalidInput();
        }
        market.lastUpdate = uint128(block.timestamp);
    }
}
