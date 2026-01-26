// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PositionNFT} from "../nft/PositionNFT.sol";
import {LibPositionNFT} from "./LibPositionNFT.sol";
import {LibAppStorage} from "./LibAppStorage.sol";
import {LibActiveCreditIndex} from "./LibActiveCreditIndex.sol";
import {LibDirectHelpers} from "./LibDirectHelpers.sol";
import {LibEncumbrance} from "./LibEncumbrance.sol";
import {Types} from "./Types.sol";

error DerivativeError_InvalidAmount(uint256 amount);
error DerivativeError_InvalidTimeWindow(uint64 start, uint64 end);
error DerivativeError_InsufficientPrincipal(uint256 available, uint256 required);
error DerivativeError_UnlockExceedsLocked(uint256 locked, uint256 amount);
error DerivativeError_UnlockExceedsLent(uint256 lent, uint256 amount);

/// @notice Shared internal helpers for Position NFT derivative facets
library LibDerivativeHelpers {
    function _requirePositionOwnership(uint256 positionId) internal view returns (bytes32 positionKey) {
        PositionNFT nft = LibDirectHelpers._positionNFT();
        LibDirectHelpers._requireBorrowerAuthority(nft, positionId);
        positionKey = LibPositionNFT.getPositionKey(address(nft), positionId);
    }

    function _validateTimeWindow(uint64 startTime, uint64 endTime) internal pure {
        if (endTime <= startTime) {
            revert DerivativeError_InvalidTimeWindow(startTime, endTime);
        }
    }

    function _lockCollateral(bytes32 positionKey, uint256 poolId, uint256 amount) internal {
        if (amount == 0) revert DerivativeError_InvalidAmount(amount);
        Types.PoolData storage pool = LibAppStorage.s().pools[poolId];

        LibActiveCreditIndex.settle(poolId, positionKey);

        uint256 userPrincipal = pool.userPrincipal[positionKey];
        LibEncumbrance.Encumbrance storage enc = LibEncumbrance.position(positionKey, poolId);
        uint256 currentLocked = enc.directLocked;
        uint256 currentLent = enc.directLent;
        uint256 used = currentLocked + currentLent;
        uint256 available = userPrincipal > used ? userPrincipal - used : 0;

        if (available < amount) {
            revert DerivativeError_InsufficientPrincipal(available, amount);
        }

        enc.directLocked = currentLocked + amount;
        LibActiveCreditIndex.applyEncumbranceIncrease(pool, poolId, positionKey, amount);
    }

    function _unlockCollateral(bytes32 positionKey, uint256 poolId, uint256 amount) internal {
        if (amount == 0) revert DerivativeError_InvalidAmount(amount);
        LibActiveCreditIndex.settle(poolId, positionKey);
        LibEncumbrance.Encumbrance storage enc = LibEncumbrance.position(positionKey, poolId);
        uint256 currentLocked = enc.directLocked;

        if (currentLocked < amount) {
            revert DerivativeError_UnlockExceedsLocked(currentLocked, amount);
        }

        enc.directLocked = currentLocked - amount;
        LibActiveCreditIndex.applyEncumbranceDecrease(LibAppStorage.s().pools[poolId], poolId, positionKey, amount);
    }

    function _lockAmmReserves(bytes32 positionKey, uint256 poolId, uint256 amount) internal {
        if (amount == 0) revert DerivativeError_InvalidAmount(amount);
        Types.PoolData storage pool = LibAppStorage.s().pools[poolId];

        LibActiveCreditIndex.settle(poolId, positionKey);

        uint256 userPrincipal = pool.userPrincipal[positionKey];
        LibEncumbrance.Encumbrance storage enc = LibEncumbrance.position(positionKey, poolId);
        uint256 currentLocked = enc.directLocked;
        uint256 currentLent = enc.directLent;
        uint256 used = currentLocked + currentLent;
        uint256 available = userPrincipal > used ? userPrincipal - used : 0;

        if (available < amount) {
            revert DerivativeError_InsufficientPrincipal(available, amount);
        }

        enc.directLent = currentLent + amount;
        LibActiveCreditIndex.applyEncumbranceIncrease(pool, poolId, positionKey, amount);
    }

    function _unlockAmmReserves(bytes32 positionKey, uint256 poolId, uint256 amount) internal {
        if (amount == 0) revert DerivativeError_InvalidAmount(amount);
        LibEncumbrance.Encumbrance storage enc = LibEncumbrance.position(positionKey, poolId);
        uint256 currentLent = enc.directLent;

        if (currentLent < amount) {
            revert DerivativeError_UnlockExceedsLent(currentLent, amount);
        }

        enc.directLent = currentLent - amount;
    }

    function _normalizePrice(
        uint256 underlyingAmount,
        uint256 price,
        uint8 underlyingDecimals,
        uint8 quoteDecimals
    ) internal pure returns (uint256 quoteAmount) {
        uint256 underlyingScale = 10 ** uint256(underlyingDecimals);
        uint256 quoteScale = 10 ** uint256(quoteDecimals);
        uint256 normalizedUnderlying = Math.mulDiv(underlyingAmount, price, underlyingScale);
        quoteAmount = Math.mulDiv(normalizedUnderlying, quoteScale, 1e18);
    }
}
