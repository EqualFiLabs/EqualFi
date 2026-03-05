// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibClAuctionStorage} from "./LibClAuctionStorage.sol";
import {LibEncumbrance} from "./LibEncumbrance.sol";
import {EncumbranceUnderflow} from "./Errors.sol";

/// @notice Bridge between CL positions and module encumbrance accounting.
library LibClEncumbranceBridge {
    uint256 internal constant CL_COMMUNITY_AUCTION_MODULE_ID =
        uint256(keccak256("equalis.cl.community.auction.module.v1"));

    function lock(
        bytes32 positionKey,
        uint256 poolIdA,
        uint256 amountA,
        uint256 poolIdB,
        uint256 amountB,
        uint256 clPositionId
    ) internal {
        LibClAuctionStorage.EncumbranceLock storage lockState = LibClAuctionStorage.s().encumbranceLocks[clPositionId];

        if (amountA > 0) {
            LibEncumbrance.encumberModule(positionKey, poolIdA, CL_COMMUNITY_AUCTION_MODULE_ID, amountA);
            lockState.lockedA += amountA;
        }

        if (amountB > 0) {
            LibEncumbrance.encumberModule(positionKey, poolIdB, CL_COMMUNITY_AUCTION_MODULE_ID, amountB);
            lockState.lockedB += amountB;
        }
    }

    function unlock(
        bytes32 positionKey,
        uint256 poolIdA,
        uint256 amountA,
        uint256 poolIdB,
        uint256 amountB,
        uint256 clPositionId
    ) internal {
        LibClAuctionStorage.EncumbranceLock storage lockState = LibClAuctionStorage.s().encumbranceLocks[clPositionId];

        if (amountA > 0) {
            uint256 lockedA = lockState.lockedA;
            if (amountA > lockedA) revert EncumbranceUnderflow(amountA, lockedA);
            LibEncumbrance.unencumberModule(positionKey, poolIdA, CL_COMMUNITY_AUCTION_MODULE_ID, amountA);
            unchecked {
                lockState.lockedA = lockedA - amountA;
            }
        }

        if (amountB > 0) {
            uint256 lockedB = lockState.lockedB;
            if (amountB > lockedB) revert EncumbranceUnderflow(amountB, lockedB);
            LibEncumbrance.unencumberModule(positionKey, poolIdB, CL_COMMUNITY_AUCTION_MODULE_ID, amountB);
            unchecked {
                lockState.lockedB = lockedB - amountB;
            }
        }
    }
}
