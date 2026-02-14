// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IModuleViewFacet} from "../interfaces/IModuleViewFacet.sol";
import {LibEncumbrance} from "../libraries/LibEncumbrance.sol";
import {LibModuleAum} from "../libraries/LibModuleAum.sol";
import {LibModuleRegistry} from "../libraries/LibModuleRegistry.sol";
import {LibPositionHelpers} from "../libraries/LibPositionHelpers.sol";
import {ModuleNotFound} from "../libraries/Errors.sol";

/// @notice Read-only views for module config, tuple encumbrance, and AUM state.
contract ModuleViewFacet is IModuleViewFacet {
    function getModule(uint256 moduleId)
        external
        view
        returns (address owner, bytes32 metadataHash, bool paused, bool inactive, uint16 aumBps)
    {
        LibModuleRegistry.Module storage m = _requireModule(moduleId);
        return (m.owner, m.metadataHash, m.paused, m.inactive, m.aumBps);
    }

    function getModuleEncumbrance(uint256 positionId, uint256 poolId) external view returns (uint256 totalModuleEncumbered) {
        bytes32 positionKey = LibPositionHelpers.positionKey(positionId);
        LibPositionHelpers.pool(poolId);
        return LibEncumbrance.getModuleEncumbered(positionKey, poolId);
    }

    function getModuleEncumbranceForModule(uint256 positionId, uint256 poolId, uint256 moduleId)
        external
        view
        returns (uint256 encumbered)
    {
        _requireModule(moduleId);
        bytes32 positionKey = LibPositionHelpers.positionKey(positionId);
        LibPositionHelpers.pool(poolId);
        return LibEncumbrance.getModuleEncumberedForModule(positionKey, poolId, moduleId);
    }

    function getModuleAumState(uint256 positionId, uint256 poolId, uint256 moduleId)
        external
        view
        returns (
            uint64 lastAccruedEpoch,
            uint256 pendingEpochs_,
            bool delinquent,
            uint64 delinquentSince,
            uint256 lastShortfall,
            uint16 graceEpochs,
            uint256 delinquentEpochs_,
            bool graceSatisfied
        )
    {
        _requireModule(moduleId);
        bytes32 positionKey = LibPositionHelpers.positionKey(positionId);
        LibPositionHelpers.pool(poolId);

        LibModuleRegistry.ModuleStorage storage ms = LibModuleRegistry.s();
        LibModuleRegistry.TupleAumState storage st = ms.tupleAum[positionKey][poolId][moduleId];

        lastAccruedEpoch = st.lastAumEpoch;
        pendingEpochs_ = LibModuleAum.pendingEpochs(positionKey, poolId, moduleId);
        delinquent = st.delinquent;
        delinquentSince = st.delinquentSince;
        lastShortfall = st.lastShortfall;

        graceEpochs = ms.deactivationGraceEpochs;
        delinquentEpochs_ = LibModuleAum.delinquentEpochs(positionKey, poolId, moduleId);
        graceSatisfied = delinquent && delinquentEpochs_ >= graceEpochs;
    }

    function getModuleAumConfig()
        external
        view
        returns (uint16 defaultBps, uint16 minBps, uint16 maxBps, uint16 deactivationGraceEpochs)
    {
        LibModuleRegistry.ModuleStorage storage ms = LibModuleRegistry.s();
        return (ms.defaultModuleAumBps, ms.minModuleAumBps, ms.maxModuleAumBps, ms.deactivationGraceEpochs);
    }

    function isModuleAciPaused() external view returns (bool) {
        return LibModuleRegistry.s().moduleAciPaused;
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
