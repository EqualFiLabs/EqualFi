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
    }

    struct EncumbranceStorage {
        mapping(bytes32 => mapping(uint256 => Encumbrance)) encumbrance;
        mapping(bytes32 => mapping(uint256 => mapping(uint256 => uint256))) encumberedByIndex;
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
        return enc.directLocked + enc.directLent + enc.directOfferEscrow + enc.indexEncumbered;
    }

    function totalForActiveCredit(bytes32 positionKey, uint256 poolId) internal view returns (uint256) {
        Encumbrance storage enc = s().encumbrance[positionKey][poolId];
        return enc.directLocked + enc.directLent + enc.directOfferEscrow;
    }

    function getIndexEncumbered(bytes32 positionKey, uint256 poolId) internal view returns (uint256) {
        return s().encumbrance[positionKey][poolId].indexEncumbered;
    }

    function getIndexEncumberedForIndex(bytes32 positionKey, uint256 poolId, uint256 indexId)
        internal
        view
        returns (uint256)
    {
        return s().encumberedByIndex[positionKey][poolId][indexId];
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
}
