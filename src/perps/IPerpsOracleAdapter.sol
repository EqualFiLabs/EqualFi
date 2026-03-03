// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @notice Perps oracle adapter returning mark price metadata used for fail-closed validation.
interface IPerpsOracleAdapter {
    /// @return priceX18 Mark price scaled to 1e18.
    /// @return updatedAt Last oracle update timestamp.
    /// @return deviationOrConfidenceBps Adapter-reported deviation/confidence value in bps.
    function getMarkPrice(bytes32 marketId, address indexAsset)
        external
        view
        returns (uint256 priceX18, uint256 updatedAt, uint256 deviationOrConfidenceBps);
}
