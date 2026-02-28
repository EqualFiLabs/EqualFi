// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IlmIsolatedTypes} from "../types/IlmIsolatedTypes.sol";

/// @notice Share/asset conversion helpers with directional rounding.
library LibIlmSharesMath {
    function toSharesDown(uint256 assets, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        uint256 adjustedShares = totalShares + IlmIsolatedTypes.VIRTUAL_SHARES;
        uint256 adjustedAssets = totalAssets + IlmIsolatedTypes.VIRTUAL_ASSETS;
        return assets * adjustedShares / adjustedAssets;
    }

    function toSharesUp(uint256 assets, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        uint256 adjustedShares = totalShares + IlmIsolatedTypes.VIRTUAL_SHARES;
        uint256 adjustedAssets = totalAssets + IlmIsolatedTypes.VIRTUAL_ASSETS;
        return _mulDivUp(assets, adjustedShares, adjustedAssets);
    }

    function toAssetsDown(uint256 shares, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        uint256 adjustedShares = totalShares + IlmIsolatedTypes.VIRTUAL_SHARES;
        uint256 adjustedAssets = totalAssets + IlmIsolatedTypes.VIRTUAL_ASSETS;
        return shares * adjustedAssets / adjustedShares;
    }

    function toAssetsUp(uint256 shares, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        uint256 adjustedShares = totalShares + IlmIsolatedTypes.VIRTUAL_SHARES;
        uint256 adjustedAssets = totalAssets + IlmIsolatedTypes.VIRTUAL_ASSETS;
        return _mulDivUp(shares, adjustedAssets, adjustedShares);
    }

    function _mulDivUp(uint256 a, uint256 b, uint256 d) private pure returns (uint256) {
        if (a == 0) {
            return 0;
        }
        return (a * b - 1) / d + 1;
    }
}

