// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibAppStorage} from "./LibAppStorage.sol";
import {LibFeeIndex} from "./LibFeeIndex.sol";
import {LibActiveCreditIndex} from "./LibActiveCreditIndex.sol";
import {LibCurrency} from "./LibCurrency.sol";
import {LibMaintenance} from "./LibMaintenance.sol";
import {Types} from "./Types.sol";
import {InsufficientPoolLiquidity, InsufficientPrincipal} from "./Errors.sol";

/// @notice Central fee router for ACI/FI/Treasury splits.
library LibFeeRouter {
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    function previewSplit(uint256 amount)
        internal
        view
        returns (uint256 toTreasury, uint256 toActiveCredit, uint256 toFeeIndex)
    {
        if (amount == 0) return (0, 0, 0);
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        uint16 treasuryBps = LibAppStorage.treasurySplitBps(store);
        uint16 activeBps = LibAppStorage.activeCreditSplitBps(store);
        require(treasuryBps + activeBps <= BPS_DENOMINATOR, "FeeRouter: splits>100%");

        address treasury = LibAppStorage.treasuryAddress(store);
        toTreasury = treasury != address(0) ? (amount * treasuryBps) / BPS_DENOMINATOR : 0;
        toActiveCredit = (amount * activeBps) / BPS_DENOMINATOR;
        toFeeIndex = amount - toTreasury - toActiveCredit;
    }

    /// @notice Route a fee amount into ACI/FI/Treasury for a single pool.
    /// @dev Use extraBacking when fee assets are encumbered (e.g., auction reserves).
    function routeSamePool(
        uint256 pid,
        uint256 amount,
        bytes32 source,
        bool pullFromTracked,
        uint256 extraBacking
    ) internal returns (uint256 toTreasury, uint256 toActiveCredit, uint256 toFeeIndex) {
        if (amount == 0) return (0, 0, 0);
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        Types.PoolData storage pool = store.pools[pid];

        (toTreasury, toActiveCredit, toFeeIndex) = previewSplit(amount);

        if (toTreasury > 0) {
            _transferTreasury(pool, toTreasury, pullFromTracked);
        }
        if (toActiveCredit > 0) {
            _accrueActiveCredit(pool, pid, toActiveCredit, source, extraBacking);
        }
        if (toFeeIndex > 0) {
            if (extraBacking > 0) {
                LibFeeIndex.accrueWithSourceUsingBacking(pid, toFeeIndex, source, extraBacking);
            } else {
                LibFeeIndex.accrueWithSource(pid, toFeeIndex, source);
            }
        }
    }

    /// @notice Accrue active credit yield with yieldReserve backing.
    function accrueActiveCredit(uint256 pid, uint256 amount, bytes32 source, uint256 extraBacking) internal {
        Types.PoolData storage pool = LibAppStorage.s().pools[pid];
        _accrueActiveCredit(pool, pid, amount, source, extraBacking);
    }

    function _transferTreasury(Types.PoolData storage pool, uint256 amount, bool pullFromTracked) private {
        address treasury = LibAppStorage.treasuryAddress(LibAppStorage.s());
        if (treasury == address(0) || amount == 0) return;
        uint256 contractBal = LibCurrency.balanceOfSelf(pool.underlying);
        if (contractBal < amount) {
            revert InsufficientPrincipal(amount, contractBal);
        }
        if (pullFromTracked) {
            uint256 tracked = pool.trackedBalance;
            if (tracked < amount) {
                revert InsufficientPrincipal(amount, tracked);
            }
            pool.trackedBalance = tracked - amount;
            if (LibCurrency.isNative(pool.underlying)) {
                LibAppStorage.s().nativeTrackedTotal -= amount;
            }
        }
        LibCurrency.transfer(pool.underlying, treasury, amount);
    }

    function _accrueActiveCredit(
        Types.PoolData storage pool,
        uint256 pid,
        uint256 amount,
        bytes32 source,
        uint256 extraBacking
    ) private {
        if (amount == 0) return;
        _reserveYield(pool, pid, amount, extraBacking);
        LibActiveCreditIndex.accrueWithSource(pid, amount, source);
    }

    function _reserveYield(
        Types.PoolData storage pool,
        uint256 pid,
        uint256 amount,
        uint256 extraBacking
    ) private {
        if (amount == 0) return;
        LibMaintenance.enforce(pid);
        uint256 reserved = pool.totalDeposits + pool.yieldReserve;
        uint256 backing = pool.trackedBalance + pool.activeCreditPrincipalTotal + extraBacking;
        uint256 available = backing > reserved ? backing - reserved : extraBacking;
        if (amount > available) {
            revert InsufficientPoolLiquidity(amount, available);
        }
        pool.yieldReserve += amount;
    }
}
