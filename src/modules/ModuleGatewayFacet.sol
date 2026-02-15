// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IModuleGatewayFacet} from "../interfaces/IModuleGatewayFacet.sol";
import {LibActiveCreditIndex} from "../libraries/LibActiveCreditIndex.sol";
import {LibModuleAum} from "../libraries/LibModuleAum.sol";
import {LibModuleEncumbrance} from "../libraries/LibModuleEncumbrance.sol";
import {LibModuleRegistry} from "../libraries/LibModuleRegistry.sol";
import {LibPositionHelpers} from "../libraries/LibPositionHelpers.sol";
import {ReentrancyGuardModifiers} from "../libraries/LibReentrancyGuard.sol";
import {LibSolvencyChecks} from "../libraries/LibSolvencyChecks.sol";
import {Types} from "../libraries/Types.sol";
import {
    InsufficientUnencumberedPrincipal,
    ModuleInactive,
    ModuleNotFound,
    ModulePausedError
} from "../libraries/Errors.sol";

/// @notice Encumbrance gateway for module tuples.
contract ModuleGatewayFacet is IModuleGatewayFacet, ReentrancyGuardModifiers {
    function encumberPosition(uint256 positionId, uint256 poolId, uint256 moduleId, uint256 amount) external nonReentrant {
        LibModuleRegistry.Module storage m = _requireModule(moduleId);
        if (m.paused) {
            revert ModulePausedError(moduleId);
        }
        if (m.inactive) {
            revert ModuleInactive(moduleId);
        }

        (bytes32 positionKey, Types.PoolData storage pool) = _resolveOwnedPositionInPool(positionId, poolId);

        // Accrue tuple AUM before any new encumbrance mutation.
        LibModuleAum.accrue(positionKey, poolId, moduleId);

        uint256 available = LibSolvencyChecks.calculateAvailablePrincipal(pool, positionKey, poolId);
        if (amount > available) {
            revert InsufficientUnencumberedPrincipal(amount, available);
        }

        LibModuleEncumbrance.encumber(positionKey, poolId, moduleId, amount);

        if (!LibModuleRegistry.s().moduleAciPaused) {
            LibActiveCreditIndex.applyEncumbranceIncrease(pool, poolId, positionKey, amount);
        }
    }

    function unencumberPosition(uint256 positionId, uint256 poolId, uint256 moduleId, uint256 amount)
        external
        nonReentrant
    {
        _requireModule(moduleId);
        (bytes32 positionKey, Types.PoolData storage pool) = _resolveOwnedPositionInPool(positionId, poolId);

        // Accrue tuple AUM before any encumbrance mutation.
        LibModuleAum.accrue(positionKey, poolId, moduleId);

        LibModuleEncumbrance.unencumber(positionKey, poolId, moduleId, amount);
        LibActiveCreditIndex.applyEncumbranceDecrease(pool, poolId, positionKey, amount);
    }

    function pokeModuleAum(uint256 positionId, uint256 poolId, uint256 moduleId) external nonReentrant {
        _requireModule(moduleId);
        bytes32 positionKey = LibPositionHelpers.positionKey(positionId);
        LibPositionHelpers.pool(poolId);
        LibModuleAum.accrue(positionKey, poolId, moduleId);
    }

    function _resolveOwnedPositionInPool(uint256 positionId, uint256 poolId)
        internal
        returns (bytes32 positionKey, Types.PoolData storage pool)
    {
        LibPositionHelpers.requireOwnership(positionId);
        positionKey = LibPositionHelpers.positionKey(positionId);
        pool = LibPositionHelpers.pool(poolId);
        LibPositionHelpers.ensurePoolMembership(positionKey, poolId, false);
    }

    function _requireModule(uint256 moduleId) internal view returns (LibModuleRegistry.Module storage m) {
        LibModuleRegistry.ModuleStorage storage ms = LibModuleRegistry.s();
        uint256 next = ms.nextModuleId;
        if (moduleId == 0 || next == 0 || moduleId >= next) {
            revert ModuleNotFound(moduleId);
        }
        m = ms.modules[moduleId];
    }
}
