// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibEncumbrance} from "./LibEncumbrance.sol";

/// @notice Library for tracking index-encumbered principal per position and pool.
library LibIndexEncumbrance {
    function encumber(bytes32 positionKey, uint256 poolId, uint256 indexId, uint256 amount) internal {
        LibEncumbrance.encumberIndex(positionKey, poolId, indexId, amount);
    }

    function unencumber(bytes32 positionKey, uint256 poolId, uint256 indexId, uint256 amount) internal {
        LibEncumbrance.unencumberIndex(positionKey, poolId, indexId, amount);
    }

    function getEncumbered(bytes32 positionKey, uint256 poolId) internal view returns (uint256) {
        return LibEncumbrance.getIndexEncumbered(positionKey, poolId);
    }

    function getEncumberedForIndex(bytes32 positionKey, uint256 poolId, uint256 indexId)
        internal
        view
        returns (uint256)
    {
        return LibEncumbrance.getIndexEncumberedForIndex(positionKey, poolId, indexId);
    }
}
