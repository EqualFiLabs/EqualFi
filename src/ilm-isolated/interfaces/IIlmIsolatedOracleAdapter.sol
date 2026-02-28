// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @notice Oracle adapter for ILM isolated markets.
interface IIlmIsolatedOracleAdapter {
    /// @notice Returns normalized price and freshness timestamp.
    /// @dev Price is ORACLE_PRICE_SCALE (1e36).
    function getIsolatedPrice(address oracle) external view returns (uint256 price, uint256 updatedAt);
}

