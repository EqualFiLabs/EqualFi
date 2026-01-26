// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {EqualIndexBaseV3} from "../equalindex/EqualIndexBaseV3.sol";

/// @notice View-only selectors for EqualIndex V3.
contract EqualIndexViewFacetV3 is EqualIndexBaseV3 {
    /// @notice Get paginated asset configuration for an index
    /// @param indexId Index identifier
    /// @param offset Starting asset index (0-based)
    /// @param limit Maximum number of assets to return (0 = until end)
    function getIndexAssets(uint256 indexId, uint256 offset, uint256 limit)
        external
        view
        indexExists(indexId)
        returns (
            address[] memory assets,
            uint256[] memory bundleAmounts,
            uint16[] memory mintFeeBps,
            uint16[] memory burnFeeBps
        )
    {
        Index storage idx = s().indexes[indexId];
        return _getIndexAssetsPaginated(idx, offset, limit);
    }

    /// @notice Get number of assets configured for an index
    function getIndexAssetCount(uint256 indexId) external view indexExists(indexId) returns (uint256) {
        return s().indexes[indexId].assets.length;
    }

    function getIndex(uint256 indexId) external view indexExists(indexId) returns (IndexView memory index_) {
        Index storage idx = s().indexes[indexId];
        (index_.assets, index_.bundleAmounts, index_.mintFeeBps, index_.burnFeeBps) =
            _getIndexAssetsPaginated(idx, 0, 0);
        index_.flashFeeBps = idx.flashFeeBps;
        index_.totalUnits = idx.totalUnits;
        index_.token = idx.token;
        index_.paused = idx.paused;
    }

    function getVaultBalance(uint256 indexId, address asset) external view returns (uint256) {
        return s().vaultBalances[indexId][asset];
    }

    function getFeePot(uint256 indexId, address asset) external view returns (uint256) {
        return s().feePots[indexId][asset];
    }

    function getProtocolBalance(address asset) external view returns (uint256) {
        asset;
        return 0;
    }
}
