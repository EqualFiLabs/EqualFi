// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibAppStorage} from "./LibAppStorage.sol";
import {LibMaintenance} from "./LibMaintenance.sol";
import {Types} from "./Types.sol";
import {LibNetEquity} from "./LibNetEquity.sol";
import {LibSolvencyChecks} from "./LibSolvencyChecks.sol";
import {InsufficientPoolLiquidity} from "./Errors.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Fee index accounting over internal principal ledger (1e18 scale)
library LibFeeIndex {
    uint256 internal constant INDEX_SCALE = 1e18;

    event FeeIndexAccrued(uint256 indexed pid, uint256 amount, uint256 delta, uint256 newIndex, bytes32 source);
    event YieldSettled(
        uint256 indexed pid,
        bytes32 indexed user,
        uint256 prevIndex,
        uint256 newIndex,
        uint256 addedYield,
        uint256 totalAccruedYield
    );

    /// @notice Fee base for same-asset domains (netted by debt).
    function calculateFeeBaseSameAsset(uint256 principal, uint256 sameAssetDebt) internal pure returns (uint256) {
        return LibNetEquity.calculateFeeBaseSameAsset(principal, sameAssetDebt);
    }

    /// @notice Fee base for cross-asset domains (locked collateral + unlocked principal).
    function calculateFeeBaseCrossAsset(uint256 lockedCollateral, uint256 unlockedPrincipal)
        internal
        pure
        returns (uint256)
    {
        return LibNetEquity.calculateFeeBaseCrossAsset(lockedCollateral, unlockedPrincipal);
    }

    /// @notice Fee base for a P2P borrower based on asset relationship.
    function calculateP2PBorrowerFeeBase(
        uint256 lockedCollateral,
        uint256 unlockedPrincipal,
        uint256 sameAssetDebt,
        bool isSameAsset
    ) internal pure returns (uint256 feeBase) {
        return LibNetEquity.calculateP2PBorrowerFeeBase(
            lockedCollateral,
            unlockedPrincipal,
            sameAssetDebt,
            isSameAsset
        );
    }

    /// @notice Accrue an underlying-denominated fee into the pool fee index with a source tag.
    /// @dev No-op if amount is zero or totalDeposits is zero; never decreases index.
    function accrueWithSource(uint256 pid, uint256 amount, bytes32 source) internal {
        if (amount == 0) return;
        LibMaintenance.enforce(pid);
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        Types.PoolData storage p = store.pools[pid];
        uint256 totalDeposits = p.totalDeposits;
        if (totalDeposits == 0) return;
        uint256 reserved = p.totalDeposits + p.yieldReserve;
        // Count outstanding credit as backing for fee accrual to avoid blocking when funds are lent out.
        uint256 backing = p.trackedBalance + p.activeCreditPrincipalTotal;
        uint256 available = backing > reserved ? backing - reserved : 0;
        if (amount > available) {
            revert InsufficientPoolLiquidity(amount, available);
        }
        p.yieldReserve += amount;
        uint256 scaledAmount = Math.mulDiv(amount, INDEX_SCALE, 1);
        // Use per-pool remainder instead of global
        uint256 dividend = scaledAmount + p.feeIndexRemainder;
        uint256 delta = dividend / totalDeposits;
        if (delta == 0) {
            p.feeIndexRemainder = dividend;
            return;
        }
        p.feeIndexRemainder = dividend - (delta * totalDeposits);
        uint256 newIndex = p.feeIndex + delta;
        p.feeIndex = newIndex;
        emit FeeIndexAccrued(pid, amount, delta, newIndex, source);
    }

    /// @notice Accrue fee index with additional temporary backing (e.g., encumbered auction reserves).
    function accrueWithSourceUsingBacking(uint256 pid, uint256 amount, bytes32 source, uint256 extraBacking)
        internal
    {
        if (amount == 0) return;
        LibMaintenance.enforce(pid);
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        Types.PoolData storage p = store.pools[pid];
        uint256 totalDeposits = p.totalDeposits;
        if (totalDeposits == 0) return;
        uint256 reserved = p.totalDeposits + p.yieldReserve;
        uint256 backing = p.trackedBalance + p.activeCreditPrincipalTotal + extraBacking;
        // Allow encumbered (flash) reserves to count toward available backing even when trackedBalance is unchanged.
        uint256 available = backing > reserved ? backing - reserved : extraBacking;
        if (amount > available) {
            revert InsufficientPoolLiquidity(amount, available);
        }
        p.yieldReserve += amount;
        uint256 scaledAmount = Math.mulDiv(amount, INDEX_SCALE, 1);
        uint256 dividend = scaledAmount + p.feeIndexRemainder;
        uint256 delta = dividend / totalDeposits;
        if (delta == 0) {
            p.feeIndexRemainder = dividend;
            return;
        }
        p.feeIndexRemainder = dividend - (delta * totalDeposits);
        uint256 newIndex = p.feeIndex + delta;
        p.feeIndex = newIndex;
        emit FeeIndexAccrued(pid, amount, delta, newIndex, source);
    }

    /// @notice Settle pending yield for a user into accrued ledger and checkpoint fee index.
    function settle(uint256 pid, bytes32 user) internal {
        LibMaintenance.enforce(pid);
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        Types.PoolData storage p = store.pools[pid];

        uint256 principal = p.userPrincipal[user];
        if (principal == 0) {
            // Update checkpoints even if no principal
            p.userFeeIndex[user] = p.feeIndex;
            p.userMaintenanceIndex[user] = p.maintenanceIndex;
            return;
        }

        // Apply maintenance fee reduction first (negative yield)
        uint256 globalMaintenanceIndex = p.maintenanceIndex;
        uint256 prevMaintenanceIndex = p.userMaintenanceIndex[user];
        if (globalMaintenanceIndex > prevMaintenanceIndex) {
            uint256 maintenanceDelta = globalMaintenanceIndex - prevMaintenanceIndex;
            uint256 maintenanceFee = Math.mulDiv(principal, maintenanceDelta, INDEX_SCALE);
            if (maintenanceFee > 0) {
                if (maintenanceFee >= principal) {
                    principal = 0;
                    p.userPrincipal[user] = 0;
                } else {
                    principal -= maintenanceFee;
                    p.userPrincipal[user] = principal;
                }
            }
            p.userMaintenanceIndex[user] = globalMaintenanceIndex;
        }

        // Apply positive yield (after maintenance reduction)
        uint256 globalIndex = p.feeIndex;
        uint256 prevIndex = p.userFeeIndex[user];
        uint256 added;
        if (globalIndex > prevIndex && principal > 0) {
            uint256 delta = globalIndex - prevIndex;
            uint256 sameAssetDebt = LibSolvencyChecks.calculateSameAssetDebt(p, user, p.underlying);
            uint256 feeBase = LibNetEquity.calculateFeeBaseSameAsset(principal, sameAssetDebt);
            added = Math.mulDiv(feeBase, delta, INDEX_SCALE);
            if (added > 0) {
                p.userAccruedYield[user] += added;
            }
        }
        p.userFeeIndex[user] = globalIndex;

        emit YieldSettled(pid, user, prevIndex, globalIndex, added, p.userAccruedYield[user]);
    }

    /// @notice View helper returning accrued + pending yield for a user.
    function pendingYield(uint256 pid, bytes32 user) internal view returns (uint256) {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        Types.PoolData storage p = store.pools[pid];
        uint256 amount = p.userAccruedYield[user];
        uint256 principal = p.userPrincipal[user];

        if (principal == 0) return amount;

        // Apply pending maintenance fee reduction first
        uint256 globalMaintenanceIndex = p.maintenanceIndex;
        uint256 userMaintenanceIndex = p.userMaintenanceIndex[user];
        if (globalMaintenanceIndex > userMaintenanceIndex) {
            uint256 maintenanceDelta = globalMaintenanceIndex - userMaintenanceIndex;
            uint256 maintenanceFee = Math.mulDiv(principal, maintenanceDelta, INDEX_SCALE);
            if (maintenanceFee >= principal) {
                principal = 0;
            } else {
                principal -= maintenanceFee;
            }
        }

        // Apply pending positive yield (on reduced principal)
        uint256 globalIndex = p.feeIndex;
        uint256 userIndex = p.userFeeIndex[user];
        if (globalIndex > userIndex && principal > 0) {
            uint256 delta = globalIndex - userIndex;
            uint256 sameAssetDebt = LibSolvencyChecks.calculateSameAssetDebt(p, user, p.underlying);
            uint256 feeBase = LibNetEquity.calculateFeeBaseSameAsset(principal, sameAssetDebt);
            amount += Math.mulDiv(feeBase, delta, INDEX_SCALE);
        }

        return amount;
    }
}
