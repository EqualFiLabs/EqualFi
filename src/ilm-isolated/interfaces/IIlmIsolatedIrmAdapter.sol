// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IlmIsolatedTypes} from "../types/IlmIsolatedTypes.sol";

/// @notice Interest-rate model adapter for ILM isolated markets.
interface IIlmIsolatedIrmAdapter {
    /// @notice Returns borrow rate per second, WAD-scaled.
    function borrowRate(
        IlmIsolatedTypes.IlmIsolatedMarketParams calldata params,
        IlmIsolatedTypes.IlmIsolatedMarket calldata market
    ) external view returns (uint256 ratePerSecond);
}

