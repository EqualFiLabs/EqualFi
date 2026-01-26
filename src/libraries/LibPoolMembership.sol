// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {
    PoolMembershipRequired,
    MembershipAlreadyExists,
    CannotClearMembership,
    WhitelistRequired
} from "./Errors.sol";
import {LibAppStorage} from "./LibAppStorage.sol";
import {Types} from "./Types.sol";
import {LibDirectStorage} from "./LibDirectStorage.sol";
import {LibEncumbrance} from "./LibEncumbrance.sol";

/// @title LibPoolMembership
/// @notice Storage and helpers for managing position membership across pools
library LibPoolMembership {
    bytes32 internal constant POOL_MEMBERSHIP_STORAGE_POSITION =
        keccak256("equal.lend.pool.membership.storage");

    struct PoolMembershipStorage {
        mapping(bytes32 => mapping(uint256 => bool)) joined; // positionKey => poolId => joined
    }

    /// @notice Return pool membership storage
    function s() internal pure returns (PoolMembershipStorage storage ps) {
        bytes32 position = POOL_MEMBERSHIP_STORAGE_POSITION;
        assembly {
            ps.slot := position
        }
    }

    /// @notice Ensure a position is a member of the specified pool.
    /// @dev When allowAutoJoin is true, missing membership will be created; otherwise reverts.
    /// @return alreadyMember True if membership already existed before this call.
    function _ensurePoolMembership(bytes32 positionKey, uint256 pid, bool allowAutoJoin)
        internal
        returns (bool alreadyMember)
    {
        PoolMembershipStorage storage store = s();
        alreadyMember = store.joined[positionKey][pid];
        if (alreadyMember) {
            // Existing membership allows continued operations even if later removed from whitelist.
            return true;
        }

        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        if (p.isManagedPool && p.whitelistEnabled && !p.whitelist[positionKey]) {
            revert WhitelistRequired(positionKey, pid);
        }

        if (!allowAutoJoin) {
            revert PoolMembershipRequired(positionKey, pid);
        }
        store.joined[positionKey][pid] = true;
        return false;
    }

    /// @notice Explicitly join a pool for the given position key.
    function _joinPool(bytes32 positionKey, uint256 pid) internal {
        PoolMembershipStorage storage store = s();
        if (store.joined[positionKey][pid]) {
            revert MembershipAlreadyExists(positionKey, pid);
        }
        store.joined[positionKey][pid] = true;
    }

    /// @notice Clear membership for a position and pool combination.
    /// @dev Caller is responsible for ensuring balances and obligations are settled before clearing.
    function _leavePool(bytes32 positionKey, uint256 pid, bool canClear, string memory reason) internal {
        PoolMembershipStorage storage store = s();
        if (!store.joined[positionKey][pid]) {
            revert PoolMembershipRequired(positionKey, pid);
        }
        if (!canClear) {
            revert CannotClearMembership(positionKey, pid, reason);
        }
        delete store.joined[positionKey][pid];
    }

    /// @notice Check whether a position key is already a member of a pool.
    function isMember(bytes32 positionKey, uint256 pid) internal view returns (bool) {
        return s().joined[positionKey][pid];
    }

    /// @notice Determine if membership can be cleared based on balances and obligations.
    /// @dev Returns a reason string describing the first blocking condition.
    function canClearMembership(bytes32 positionKey, uint256 pid)
        internal
        view
        returns (bool canClear, string memory reason)
    {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        if (p.userPrincipal[positionKey] > 0) {
            return (false, "principal>0");
        }
        if (p.activeFixedLoanCount[positionKey] > 0) {
            return (false, "active fixed loans");
        }
        Types.RollingCreditLoan storage loan = p.rollingLoans[positionKey];
        if (loan.active && loan.principalRemaining > 0) {
            return (false, "rolling loan active");
        }
        LibEncumbrance.Encumbrance memory enc = LibEncumbrance.get(positionKey, pid);
        if (enc.directLocked > 0) {
            return (false, "locked direct principal");
        }
        if (LibDirectStorage.directStorage().directBorrowedPrincipal[positionKey][pid] > 0) {
            return (false, "direct borrowed principal");
        }
        if (enc.directLent > 0) {
            return (false, "direct lent principal");
        }
        if (enc.directOfferEscrow > 0) {
            return (false, "direct offer escrow");
        }
        return (true, "");
    }
}
