// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibEncumbrance} from "./LibEncumbrance.sol";

/// @notice Library for tracking module-encumbered principal per position and pool.
library LibModuleEncumbrance {
    function encumber(bytes32 positionKey, uint256 poolId, uint256 moduleId, uint256 amount) internal {
        LibEncumbrance.encumberModule(positionKey, poolId, moduleId, amount);
    }

    function unencumber(bytes32 positionKey, uint256 poolId, uint256 moduleId, uint256 amount) internal {
        LibEncumbrance.unencumberModule(positionKey, poolId, moduleId, amount);
    }

    function getEncumbered(bytes32 positionKey, uint256 poolId) internal view returns (uint256) {
        return LibEncumbrance.getModuleEncumbered(positionKey, poolId);
    }

    function getEncumberedForModule(bytes32 positionKey, uint256 poolId, uint256 moduleId)
        internal
        view
        returns (uint256)
    {
        return LibEncumbrance.getModuleEncumberedForModule(positionKey, poolId, moduleId);
    }
}
