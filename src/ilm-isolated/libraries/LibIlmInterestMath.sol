// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IlmIsolatedTypes} from "../types/IlmIsolatedTypes.sol";
import {IIlmIsolatedIrmAdapter} from "../interfaces/IIlmIsolatedIrmAdapter.sol";
import {LibIlmSharesMath} from "./LibIlmSharesMath.sol";
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

    /// @notice Accrue interest for a market and mint fee shares when configured.
    function accrueInterest(
        IlmIsolatedTypes.IlmIsolatedMarket storage market,
        IlmIsolatedTypes.IlmIsolatedMarketParams storage params,
        bytes32 feeRecipientPositionKey,
        uint256 fee,
        mapping(bytes32 => IlmIsolatedTypes.IlmIsolatedPosition) storage positions
    ) internal returns (uint256 interest, uint256 feeShares) {
        uint256 elapsed = block.timestamp - uint256(market.lastUpdate);
        if (elapsed == 0) {
            return (0, 0);
        }

        IlmIsolatedTypes.IlmIsolatedMarketParams memory paramsMem = params;
        IlmIsolatedTypes.IlmIsolatedMarket memory marketMem = market;
        uint256 ratePerSecond = IIlmIsolatedIrmAdapter(params.irm).borrowRate(paramsMem, marketMem);

        uint256 interestFactor = wTaylorCompounded(ratePerSecond, elapsed);
        interest = uint256(market.totalBorrowAssets) * interestFactor / WAD;

        uint256 newTotalBorrowAssets = uint256(market.totalBorrowAssets) + interest;
        uint256 newTotalSupplyAssets = uint256(market.totalSupplyAssets) + interest;

        if (newTotalBorrowAssets > type(uint128).max || newTotalSupplyAssets > type(uint128).max) {
            revert IlmIsolatedInvalidInput();
        }

        market.totalBorrowAssets = uint128(newTotalBorrowAssets);
        market.totalSupplyAssets = uint128(newTotalSupplyAssets);

        if (fee > 0 && feeRecipientPositionKey != bytes32(0)) {
            uint256 feeAmount = interest * fee / WAD;
            feeShares = LibIlmSharesMath.toSharesDown(
                feeAmount, uint256(market.totalSupplyAssets) - feeAmount, uint256(market.totalSupplyShares)
            );

            uint256 newTotalSupplyShares = uint256(market.totalSupplyShares) + feeShares;
            if (newTotalSupplyShares > type(uint128).max) {
                revert IlmIsolatedInvalidInput();
            }
            market.totalSupplyShares = uint128(newTotalSupplyShares);
            positions[feeRecipientPositionKey].supplyShares += feeShares;
        }

        if (block.timestamp > type(uint128).max) {
            revert IlmIsolatedInvalidInput();
        }
        market.lastUpdate = uint128(block.timestamp);
    }
}

