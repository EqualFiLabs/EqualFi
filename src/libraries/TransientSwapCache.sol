// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibAppStorage} from "./LibAppStorage.sol";

/// @notice Thin wrapper around transient storage for swap hot paths.
/// @dev Guarded by USE_TSTORE flag for chains lacking TSTORE/TLOAD support.
library TransientSwapCache {
    bool internal constant USE_TSTORE = true;
    bytes32 private constant SLOT_RES_IN = keccak256("swap.cache.reserveIn");
    bytes32 private constant SLOT_RES_OUT = keccak256("swap.cache.reserveOut");
    bytes32 private constant SLOT_FEE_POOL = keccak256("swap.cache.feePoolId");

    function enabled() internal view returns (bool) {
        if (!USE_TSTORE) return false;
        uint8 mode = LibAppStorage.s().transientCacheMode;
        // mode: 0 (unset/default on), 1 (on), 2 (off)
        return mode != 2;
    }

    function tstore(bytes32 slot, uint256 value) internal {
        if (!enabled()) return;
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }

    function tload(bytes32 slot) internal view returns (uint256 value) {
        if (!enabled()) return 0;
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }

    function cacheReserves(uint256 reserveIn, uint256 reserveOut) internal {
        tstore(SLOT_RES_IN, reserveIn);
        tstore(SLOT_RES_OUT, reserveOut);
    }

    function loadReserves() internal view returns (uint256 reserveIn, uint256 reserveOut) {
        reserveIn = tload(SLOT_RES_IN);
        reserveOut = tload(SLOT_RES_OUT);
    }

    function cacheFeePool(uint256 feePoolId) internal {
        tstore(SLOT_FEE_POOL, feePoolId);
    }

    function loadFeePool() internal view returns (uint256) {
        return tload(SLOT_FEE_POOL);
    }
}
