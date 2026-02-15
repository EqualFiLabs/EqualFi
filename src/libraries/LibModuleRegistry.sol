// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @notice Module registry storage + events for module encumbrance.
library LibModuleRegistry {
    bytes32 internal constant MODULE_REGISTRY_STORAGE_POSITION = keccak256("equallend.module.registry.storage");

    struct Module {
        address owner;
        bytes32 metadataHash;
        bool paused;
        bool inactive;
        uint16 aumBps;
    }

    struct TupleAumState {
        uint64 lastAumEpoch;
        bool delinquent;
        uint64 delinquentSince;
        uint256 lastShortfall;
    }

    struct ModuleStorage {
        uint256 nextModuleId;
        uint256 moduleCreationFee;

        uint16 defaultModuleAumBps;
        uint16 minModuleAumBps;
        uint16 maxModuleAumBps;
        uint16 deactivationGraceEpochs;

        bool moduleAciPaused;

        mapping(uint256 => Module) modules;
        mapping(bytes32 => mapping(uint256 => mapping(uint256 => TupleAumState))) tupleAum;
    }

    event ModuleRegistered(uint256 indexed moduleId, address indexed owner, bytes32 metadataHash, uint16 aumBps);
    event ModuleOwnerUpdated(uint256 indexed moduleId, address indexed oldOwner, address indexed newOwner);
    event ModulePauseUpdated(uint256 indexed moduleId, bool paused);
    event ModuleAumAccrued(
        uint256 indexed moduleId,
        bytes32 indexed positionKey,
        uint256 indexed poolId,
        uint256 epochs,
        uint256 feeDue,
        uint256 charged,
        uint256 shortfall,
        uint64 newLastAumEpoch
    );
    event ModuleAumDelinquent(
        uint256 indexed moduleId,
        bytes32 indexed positionKey,
        uint256 indexed poolId,
        uint256 feeDue,
        uint256 chargeablePrincipal,
        uint256 shortfall
    );
    event ModulePermanentlyDeactivated(
        uint256 indexed moduleId,
        bytes32 indexed positionKey,
        uint256 indexed poolId,
        uint256 feeDue,
        uint256 chargeablePrincipal,
        uint256 shortfall
    );
    event ModuleAciPauseToggled(bool paused);

    function s() internal pure returns (ModuleStorage storage ms) {
        bytes32 position = MODULE_REGISTRY_STORAGE_POSITION;
        assembly {
            ms.slot := position
        }
    }

    function module(uint256 moduleId) internal view returns (Module storage m) {
        m = s().modules[moduleId];
    }

    function tupleAumState(bytes32 positionKey, uint256 poolId, uint256 moduleId)
        internal
        view
        returns (TupleAumState storage state)
    {
        state = s().tupleAum[positionKey][poolId][moduleId];
    }

    function emitModuleRegistered(uint256 moduleId, address owner, bytes32 metadataHash, uint16 aumBps) internal {
        emit ModuleRegistered(moduleId, owner, metadataHash, aumBps);
    }

    function emitModuleOwnerUpdated(uint256 moduleId, address oldOwner, address newOwner) internal {
        emit ModuleOwnerUpdated(moduleId, oldOwner, newOwner);
    }

    function emitModulePauseUpdated(uint256 moduleId, bool paused) internal {
        emit ModulePauseUpdated(moduleId, paused);
    }

    function emitModuleAumAccrued(
        uint256 moduleId,
        bytes32 positionKey,
        uint256 poolId,
        uint256 epochs,
        uint256 feeDue,
        uint256 charged,
        uint256 shortfall,
        uint64 newLastAumEpoch
    ) internal {
        emit ModuleAumAccrued(moduleId, positionKey, poolId, epochs, feeDue, charged, shortfall, newLastAumEpoch);
    }

    function emitModuleAumDelinquent(
        uint256 moduleId,
        bytes32 positionKey,
        uint256 poolId,
        uint256 feeDue,
        uint256 chargeablePrincipal,
        uint256 shortfall
    ) internal {
        emit ModuleAumDelinquent(moduleId, positionKey, poolId, feeDue, chargeablePrincipal, shortfall);
    }

    function emitModulePermanentlyDeactivated(
        uint256 moduleId,
        bytes32 positionKey,
        uint256 poolId,
        uint256 feeDue,
        uint256 chargeablePrincipal,
        uint256 shortfall
    ) internal {
        emit ModulePermanentlyDeactivated(moduleId, positionKey, poolId, feeDue, chargeablePrincipal, shortfall);
    }

    function emitModuleAciPauseToggled(bool paused) internal {
        emit ModuleAciPauseToggled(paused);
    }
}
