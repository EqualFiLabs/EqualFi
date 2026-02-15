// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {EncumbranceUnderflow} from "./Errors.sol";

/// @notice Central storage and helpers for all encumbrance components per position and pool.
library LibEncumbrance {
    bytes32 internal constant STORAGE_POSITION = keccak256("equallend.encumbrance.storage");

    struct Encumbrance {
        uint256 directLocked;
        uint256 directLent;
        uint256 directOfferEscrow;
        uint256 indexEncumbered;
        uint256 moduleEncumbered;
    }

    struct EncumbranceStorage {
        mapping(bytes32 => mapping(uint256 => Encumbrance)) encumbrance;
        mapping(bytes32 => mapping(uint256 => mapping(uint256 => uint256))) encumberedByIndex;
        mapping(bytes32 => mapping(uint256 => mapping(uint256 => uint256))) encumberedByModule;
    }

    event EncumbranceIncreased(
        bytes32 indexed positionKey,
        uint256 indexed poolId,
        uint256 indexed indexId,
        uint256 amount,
        uint256 totalEncumbered,
        uint256 indexEncumbered
    );
    event EncumbranceDecreased(
        bytes32 indexed positionKey,
        uint256 indexed poolId,
        uint256 indexed indexId,
        uint256 amount,
        uint256 totalEncumbered,
        uint256 indexEncumbered
    );
    event ModuleEncumbranceIncreased(
        bytes32 indexed positionKey,
        uint256 indexed poolId,
        uint256 indexed moduleId,
        uint256 amount,
        uint256 totalEncumbered,
        uint256 moduleEncumbered
    );
    event ModuleEncumbranceDecreased(
        bytes32 indexed positionKey,
        uint256 indexed poolId,
        uint256 indexed moduleId,
        uint256 amount,
        uint256 totalEncumbered,
        uint256 moduleEncumbered
    );

    function s() internal pure returns (EncumbranceStorage storage es) {
        bytes32 storagePosition = STORAGE_POSITION;
        assembly {
            es.slot := storagePosition
        }
    }

    function position(bytes32 positionKey, uint256 poolId) internal view returns (Encumbrance storage enc) {
        enc = s().encumbrance[positionKey][poolId];
    }

    function get(bytes32 positionKey, uint256 poolId) internal view returns (Encumbrance memory enc) {
        enc = s().encumbrance[positionKey][poolId];
    }

    function total(bytes32 positionKey, uint256 poolId) internal view returns (uint256) {
        Encumbrance storage enc = s().encumbrance[positionKey][poolId];
        return enc.directLocked + enc.directLent + enc.directOfferEscrow + enc.indexEncumbered + enc.moduleEncumbered;
    }

    function totalForActiveCredit(bytes32 positionKey, uint256 poolId) internal view returns (uint256) {
        Encumbrance storage enc = s().encumbrance[positionKey][poolId];
        return enc.directLocked + enc.directLent + enc.directOfferEscrow;
    }

    function getIndexEncumbered(bytes32 positionKey, uint256 poolId) internal view returns (uint256) {
        return s().encumbrance[positionKey][poolId].indexEncumbered;
    }

    function getModuleEncumbered(bytes32 positionKey, uint256 poolId) internal view returns (uint256) {
        return s().encumbrance[positionKey][poolId].moduleEncumbered;
    }

    function getIndexEncumberedForIndex(bytes32 positionKey, uint256 poolId, uint256 indexId)
        internal
        view
        returns (uint256)
    {
        return s().encumberedByIndex[positionKey][poolId][indexId];
    }

    function getModuleEncumberedForModule(bytes32 positionKey, uint256 poolId, uint256 moduleId)
        internal
        view
        returns (uint256)
    {
        return s().encumberedByModule[positionKey][poolId][moduleId];
    }

    function encumberIndex(bytes32 positionKey, uint256 poolId, uint256 indexId, uint256 amount) internal {
        EncumbranceStorage storage es = s();
        Encumbrance storage enc = es.encumbrance[positionKey][poolId];
        uint256 newTotal = enc.indexEncumbered + amount;
        enc.indexEncumbered = newTotal;
        uint256 newIndexTotal = es.encumberedByIndex[positionKey][poolId][indexId] + amount;
        es.encumberedByIndex[positionKey][poolId][indexId] = newIndexTotal;
        emit EncumbranceIncreased(positionKey, poolId, indexId, amount, newTotal, newIndexTotal);
    }

    function unencumberIndex(bytes32 positionKey, uint256 poolId, uint256 indexId, uint256 amount) internal {
        EncumbranceStorage storage es = s();
        Encumbrance storage enc = es.encumbrance[positionKey][poolId];
        uint256 currentIndex = es.encumberedByIndex[positionKey][poolId][indexId];
        if (amount > currentIndex) {
            revert EncumbranceUnderflow(amount, currentIndex);
        }
        uint256 currentTotal = enc.indexEncumbered;
        if (amount > currentTotal) {
            revert EncumbranceUnderflow(amount, currentTotal);
        }
        uint256 newTotal = currentTotal - amount;
        uint256 newIndexTotal = currentIndex - amount;
        enc.indexEncumbered = newTotal;
        es.encumberedByIndex[positionKey][poolId][indexId] = newIndexTotal;
        emit EncumbranceDecreased(positionKey, poolId, indexId, amount, newTotal, newIndexTotal);
    }

    function encumberModule(bytes32 positionKey, uint256 poolId, uint256 moduleId, uint256 amount) internal {
        EncumbranceStorage storage es = s();
        Encumbrance storage enc = es.encumbrance[positionKey][poolId];
        uint256 newTotal = enc.moduleEncumbered + amount;
        enc.moduleEncumbered = newTotal;
        uint256 newModuleTotal = es.encumberedByModule[positionKey][poolId][moduleId] + amount;
        es.encumberedByModule[positionKey][poolId][moduleId] = newModuleTotal;
        emit ModuleEncumbranceIncreased(positionKey, poolId, moduleId, amount, newTotal, newModuleTotal);
    }

    function unencumberModule(bytes32 positionKey, uint256 poolId, uint256 moduleId, uint256 amount) internal {
        EncumbranceStorage storage es = s();
        Encumbrance storage enc = es.encumbrance[positionKey][poolId];
        uint256 currentModule = es.encumberedByModule[positionKey][poolId][moduleId];
        if (amount > currentModule) {
            revert EncumbranceUnderflow(amount, currentModule);
        }
        uint256 currentTotal = enc.moduleEncumbered;
        if (amount > currentTotal) {
            revert EncumbranceUnderflow(amount, currentTotal);
        }
        uint256 newTotal = currentTotal - amount;
        uint256 newModuleTotal = currentModule - amount;
        enc.moduleEncumbered = newTotal;
        es.encumberedByModule[positionKey][poolId][moduleId] = newModuleTotal;
        emit ModuleEncumbranceDecreased(positionKey, poolId, moduleId, amount, newTotal, newModuleTotal);
    }
}
