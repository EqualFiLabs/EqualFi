// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibAppStorage} from "./LibAppStorage.sol";
import {Types} from "./Types.sol";
import {InsufficientPoolLiquidity} from "./Errors.sol";

    /// @notice Helper for batching pool field reads/writes used during AMM swaps.
    library SwapPoolStorage {
        struct SwapState {
            uint256 trackedBalance;
            uint256 totalDeposits;
            uint256 yieldReserve;
        }

        /// @notice Load swap-relevant pool state into memory.
        function load(uint256 pid) internal view returns (SwapState memory state, Types.PoolData storage pool) {
            pool = LibAppStorage.s().pools[pid];
            state.trackedBalance = pool.trackedBalance;
            state.totalDeposits = pool.totalDeposits;
            state.yieldReserve = pool.yieldReserve;
        }

        /// @notice Commit swap-relevant pool state back to storage.
        function store(uint256 pid, SwapState memory state) internal {
            Types.PoolData storage pool = LibAppStorage.s().pools[pid];
            pool.trackedBalance = state.trackedBalance;
            pool.totalDeposits = state.totalDeposits;
            pool.yieldReserve = state.yieldReserve;
        }

        /// @notice Apply a trackedBalance delta to a cached state, reverting on underflow.
        function applyTrackedDelta(SwapState memory state, uint256 oldReserve, uint256 newReserve)
            internal
            pure
            returns (SwapState memory)
        {
            if (newReserve == oldReserve) return state;
            if (newReserve > oldReserve) {
                state.trackedBalance += newReserve - oldReserve;
            } else {
                uint256 delta = oldReserve - newReserve;
                if (state.trackedBalance < delta) {
                    revert InsufficientPoolLiquidity(delta, state.trackedBalance);
                }
                state.trackedBalance -= delta;
            }
            return state;
        }
    }
