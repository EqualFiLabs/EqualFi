// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibAppStorage} from "./LibAppStorage.sol";
import {LibCurrency} from "./LibCurrency.sol";
import {Types} from "./Types.sol";

/// @notice Helper for deterministic pool-level maintenance accrual and payouts.
library LibMaintenance {
    uint256 internal constant MAINTENANCE_EPOCH = 1 days;

    event MaintenanceCharged(
        uint256 indexed pid,
        address indexed receiver,
        uint256 epochsCharged,
        uint256 amountAccrued,
        uint256 amountPaid,
        uint256 outstanding
    );

    function enforce(uint256 pid) internal {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        Types.PoolData storage p = store.pools[pid];
        if (!p.initialized) {
            return;
        }
        address receiver = store.foundationReceiver;
        if (receiver == address(0)) {
            return;
        }

        (uint256 amountAccrued, uint256 epochs) = _accrue(store, p);
        uint256 paid = _pay(p, receiver);

        if (amountAccrued > 0 || paid > 0) {
            emit MaintenanceCharged(pid, receiver, epochs, amountAccrued, paid, p.pendingMaintenance);
        }
    }

    function forcePay(uint256 pid) internal {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        Types.PoolData storage p = store.pools[pid];
        if (!p.initialized) return;
        address receiver = store.foundationReceiver;
        if (receiver == address(0)) return;
        uint256 paid = _pay(p, receiver);
        if (paid > 0) {
            emit MaintenanceCharged(pid, receiver, 0, 0, paid, p.pendingMaintenance);
        }
    }

    function _accrue(LibAppStorage.AppStorage storage store, Types.PoolData storage p)
        private
        returns (uint256 amountAccrued, uint256 epochs)
    {
        uint16 rateBps = p.poolConfig.maintenanceRateBps;
        if (rateBps == 0) {
            rateBps = store.defaultMaintenanceRateBps;
            if (rateBps == 0) {
                rateBps = 100; // default 1% when unset
            }
        }

        uint64 lastTimestamp = p.lastMaintenanceTimestamp;
        uint64 nowTs = uint64(block.timestamp);
        if (lastTimestamp == 0) {
            p.lastMaintenanceTimestamp = nowTs;
            return (0, 0);
        }

        if (nowTs <= lastTimestamp) {
            return (0, 0);
        }

        uint256 elapsed = nowTs - lastTimestamp;
        epochs = elapsed / MAINTENANCE_EPOCH;
        if (epochs == 0) {
            return (0, 0);
        }

        p.lastMaintenanceTimestamp = lastTimestamp + uint64(epochs * MAINTENANCE_EPOCH);

        uint256 tvl = p.totalDeposits;
        if (tvl == 0) {
            return (0, epochs);
        }

        amountAccrued = (tvl * rateBps * epochs) / (365 * 10_000);
        if (amountAccrued == 0) {
            return (0, epochs);
        }

        // Reduce totalDeposits to reflect maintenance fee taken from depositors
        if (p.totalDeposits >= amountAccrued) {
            p.totalDeposits -= amountAccrued;
        } else {
            amountAccrued = p.totalDeposits;
            p.totalDeposits = 0;
        }

        // Apply negative fee index to proportionally reduce all user principals
        // This works like negative yield - reducing everyone's balance proportionally
        _applyMaintenanceToIndex(store, p, amountAccrued);

        p.pendingMaintenance += amountAccrued;
        return (amountAccrued, epochs);
    }

    function _applyMaintenanceToIndex(LibAppStorage.AppStorage storage, Types.PoolData storage p, uint256 amount)
        private
    {
        if (amount == 0) return;
        // Note: totalDeposits has already been reduced, so we use the OLD value for calculation
        uint256 oldTotal = p.totalDeposits + amount;
        if (oldTotal == 0) return;

        // Calculate the reduction ratio: amount / oldTotal
        // We'll reduce each user's principal by this ratio when they settle
        // Using the fee index mechanism: negative delta reduces principal
        uint256 scaledAmount = (amount * 1e18) / 1;
        // Use per-pool remainder instead of global
        uint256 dividend = scaledAmount + p.maintenanceIndexRemainder;
        uint256 delta = dividend / oldTotal;

        if (delta == 0) {
            p.maintenanceIndexRemainder = dividend;
            return;
        }

        p.maintenanceIndexRemainder = dividend - (delta * oldTotal);
        p.maintenanceIndex += delta;
    }

    function _pay(Types.PoolData storage p, address receiver) private returns (uint256 paid) {
        uint256 outstanding = p.pendingMaintenance;
        if (outstanding == 0) {
            return 0;
        }
        
        // Use tracked balance for pool isolation - prevents draining other pools
        uint256 poolAvailable = p.trackedBalance;
        uint256 contractBalance = LibCurrency.balanceOfSelf(p.underlying);
        
        // Can only pay up to the minimum of: outstanding, pool's tracked balance, and contract balance
        paid = outstanding;
        if (paid > poolAvailable) {
            paid = poolAvailable;
        }
        if (paid > contractBalance) {
            paid = contractBalance;
        }
        
        if (paid == 0) {
            return 0;
        }
        
        p.pendingMaintenance = outstanding - paid;
        if (p.trackedBalance >= paid) {
            p.trackedBalance -= paid; // Decrease tracked balance
        }
        if (LibCurrency.isNative(p.underlying)) {
            LibAppStorage.s().nativeTrackedTotal -= paid;
        }
        LibCurrency.transfer(p.underlying, receiver, paid);
        return paid;
    }

    function epochLength() internal pure returns (uint256) {
        return MAINTENANCE_EPOCH;
    }
}
