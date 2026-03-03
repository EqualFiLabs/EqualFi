// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibPerpsStorage} from "./LibPerpsStorage.sol";
import {Perps_InsufficientPerpsLiquidity, Perps_IsolationViolation} from "./PerpsErrors.sol";

/// @notice Perps isolation accounting helpers and non-perps backing invariant hooks.
library LibPerpsDomain {
    struct IsolationSnapshot {
        uint256 nonPerpsTrackedTotal;
        uint256 isolatedTrackedBalance;
    }

    function snapshotIsolation(uint256[] memory nonPerpsPoolIds) internal view returns (IsolationSnapshot memory snap) {
        snap.nonPerpsTrackedTotal = totalNonPerpsTracked(nonPerpsPoolIds);
        snap.isolatedTrackedBalance = LibPerpsStorage.s().domainState.isolatedTrackedBalance;
    }

    /// @notice Invariant hook used after a mutating perps operation.
    /// @dev Enforces:
    ///  - non-perps tracked backing cannot decrease
    ///  - any increase must equal explicit outbound perps fee credits
    function enforceNonPerpsBackingInvariant(
        uint256[] memory nonPerpsPoolIds,
        IsolationSnapshot memory beforeSnap,
        uint256 explicitOutboundCredit
    ) internal view returns (uint256 afterTrackedTotal) {
        afterTrackedTotal = totalNonPerpsTracked(nonPerpsPoolIds);
        if (afterTrackedTotal < beforeSnap.nonPerpsTrackedTotal) {
            revert Perps_IsolationViolation();
        }

        uint256 observedIncrease = afterTrackedTotal - beforeSnap.nonPerpsTrackedTotal;
        if (observedIncrease != explicitOutboundCredit) {
            revert Perps_IsolationViolation();
        }
    }

    function totalNonPerpsTracked(uint256[] memory nonPerpsPoolIds) internal view returns (uint256 totalTracked) {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        uint256 length = nonPerpsPoolIds.length;
        for (uint256 i; i < length; ++i) {
            totalTracked += store.pools[nonPerpsPoolIds[i]].trackedBalance;
        }
    }

    function reserveIsolatedBacking(uint256 amount) internal {
        if (amount == 0) return;
        LibPerpsStorage.PerpsDomainState storage ds = LibPerpsStorage.s().domainState;
        ds.isolatedTrackedBalance += amount;
        ds.isolatedEncumbered += amount;
    }

    function releaseIsolatedBacking(uint256 amount) internal {
        if (amount == 0) return;
        LibPerpsStorage.PerpsDomainState storage ds = LibPerpsStorage.s().domainState;
        if (ds.isolatedTrackedBalance < amount) {
            revert Perps_InsufficientPerpsLiquidity(amount, ds.isolatedTrackedBalance);
        }
        if (ds.isolatedEncumbered < amount) {
            revert Perps_InsufficientPerpsLiquidity(amount, ds.isolatedEncumbered);
        }
        ds.isolatedTrackedBalance -= amount;
        ds.isolatedEncumbered -= amount;
    }

    function creditIsolatedTracked(uint256 amount) internal {
        if (amount == 0) return;
        LibPerpsStorage.s().domainState.isolatedTrackedBalance += amount;
    }

    function debitIsolatedTracked(uint256 amount) internal {
        if (amount == 0) return;
        LibPerpsStorage.PerpsDomainState storage ds = LibPerpsStorage.s().domainState;
        if (ds.isolatedTrackedBalance < amount) {
            revert Perps_InsufficientPerpsLiquidity(amount, ds.isolatedTrackedBalance);
        }
        ds.isolatedTrackedBalance -= amount;
    }

    function increaseLiabilities(uint256 amount) internal {
        if (amount == 0) return;
        LibPerpsStorage.s().domainState.isolatedLiabilities += amount;
    }

    function decreaseLiabilities(uint256 amount) internal {
        if (amount == 0) return;
        LibPerpsStorage.PerpsDomainState storage ds = LibPerpsStorage.s().domainState;
        if (ds.isolatedLiabilities < amount) {
            revert Perps_InsufficientPerpsLiquidity(amount, ds.isolatedLiabilities);
        }
        ds.isolatedLiabilities -= amount;
    }

    /// @notice Records explicit one-way outbound fee credit from perps domain.
    function routeOutboundFeeCredit(uint256 amount) internal returns (uint256 credited) {
        debitIsolatedTracked(amount);
        return amount;
    }

    function availableIsolatedBacking() internal view returns (uint256 available) {
        LibPerpsStorage.PerpsDomainState storage ds = LibPerpsStorage.s().domainState;
        if (ds.isolatedTrackedBalance > ds.isolatedLiabilities) {
            available = ds.isolatedTrackedBalance - ds.isolatedLiabilities;
        }
    }

    /// @notice Domain solvency guard: isolated assets + insurance + badDebtRecorded >= liabilities.
    function enforceDomainSolvency(uint256 insuranceBalance, uint256 badDebtRecorded) internal view {
        LibPerpsStorage.PerpsDomainState storage ds = LibPerpsStorage.s().domainState;
        uint256 covered = ds.isolatedTrackedBalance + insuranceBalance + badDebtRecorded;
        if (covered < ds.isolatedLiabilities) {
            revert Perps_IsolationViolation();
        }
    }
}
