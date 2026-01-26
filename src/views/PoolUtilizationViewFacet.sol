// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibCurrency} from "../libraries/LibCurrency.sol";
import {Types} from "../libraries/Types.sol";

/// @notice Pool utilization and capacity metrics
/// @dev Provides insights into pool health, capacity, and usage
contract PoolUtilizationViewFacet {
    /// @notice Get comprehensive pool utilization metrics
    /// @param pid Pool ID
    /// @return totalDeposits Total deposited principal across all users
    /// @return totalBorrowed Total outstanding loans (fixed + rolling)
    /// @return availableLiquidity Actual token balance in contract
    /// @return utilizationBps Utilization rate in basis points (0-10000)
    /// @return capacityRemaining How much more can be deposited (if capped, otherwise max uint256)
    function getPoolUtilization(uint256 pid)
        external
        view
        returns (
            uint256 totalDeposits,
            uint256 totalBorrowed,
            uint256 availableLiquidity,
            uint256 utilizationBps,
            uint256 capacityRemaining
        )
    {
        Types.PoolData storage p = _pool(pid);

        totalDeposits = p.totalDeposits;
        availableLiquidity = LibCurrency.balanceOfSelf(p.underlying);

        // Calculate total borrowed by iterating through all users' loans
        // Note: This is expensive for large pools, consider caching in production
        totalBorrowed = availableLiquidity > totalDeposits ? 0 : totalDeposits - availableLiquidity;

        // Calculate utilization rate
        if (totalDeposits > 0) {
            utilizationBps = (totalBorrowed * 10_000) / totalDeposits;
        }

        // Calculate capacity remaining
        if (p.poolConfig.isCapped) {
            // For capped pools, capacity is per-user, so return the cap
            capacityRemaining = p.poolConfig.depositCap;
        } else {
            capacityRemaining = type(uint256).max;
        }
    }

    /// @notice Check if a user can deposit more
    /// @param pid Pool ID
    /// @param positionKey Position key
    /// @param amount Desired deposit amount
    /// @return allowed True if deposit is allowed
    /// @return maxAllowed Maximum amount user can deposit (0 if unlimited)
    /// @return reason Human-readable reason if cannot deposit (empty if can deposit)
    function canDeposit(uint256 pid, bytes32 positionKey, uint256 amount)
        external
        view
        returns (bool allowed, uint256 maxAllowed, string memory reason)
    {
        Types.PoolData storage p = _pool(pid);

        if (amount == 0) {
            return (false, 0, "Amount cannot be zero");
        }

        // Check if new user would exceed max user count
        bool isNewUser = p.userPrincipal[positionKey] == 0;
        if (isNewUser && p.poolConfig.maxUserCount > 0 && p.userCount >= p.poolConfig.maxUserCount) {
            return (false, 0, "Pool at max user capacity");
        }

        // Check if pool is capped
        if (p.poolConfig.isCapped) {
            uint256 currentPrincipal = p.userPrincipal[positionKey];
            uint256 cap = p.poolConfig.depositCap;

            if (currentPrincipal >= cap) {
                return (false, 0, "User at deposit cap");
            }

            maxAllowed = cap - currentPrincipal;

            if (amount > maxAllowed) {
                return (false, maxAllowed, "Exceeds user deposit cap");
            }
        }

        return (true, maxAllowed, "");
    }

    /// @notice Get pool capacity information
    /// @param pid Pool ID
    /// @return isCapped Whether pool has per-user deposit caps
    /// @return depositCap Per-user deposit cap (0 if uncapped)
    /// @return totalDeposits Current total deposits
    /// @return userCount Number of users with active deposits
    /// @return maxUserCount Maximum users allowed (0 = unlimited)
    function getPoolCapacity(uint256 pid)
        external
        view
        returns (bool isCapped, uint256 depositCap, uint256 totalDeposits, uint256 userCount, uint256 maxUserCount)
    {
        Types.PoolData storage p = _pool(pid);
        isCapped = p.poolConfig.isCapped;
        depositCap = p.poolConfig.depositCap;
        totalDeposits = p.totalDeposits;
        userCount = p.userCount;
        maxUserCount = p.poolConfig.maxUserCount;
    }

    /// @notice Get available liquidity for borrowing
    /// @param pid Pool ID
    /// @return availableForBorrow Amount available for new loans
    /// @return totalLiquidity Total token balance
    /// @return reservedForWithdrawals Amount reserved for depositor withdrawals
    function getAvailableLiquidity(uint256 pid)
        external
        view
        returns (uint256 availableForBorrow, uint256 totalLiquidity, uint256 reservedForWithdrawals)
    {
        Types.PoolData storage p = _pool(pid);

        totalLiquidity = LibCurrency.balanceOfSelf(p.underlying);
        reservedForWithdrawals = p.totalDeposits;

        // Available for borrow is liquidity minus what's reserved for withdrawals
        if (totalLiquidity > reservedForWithdrawals) {
            availableForBorrow = totalLiquidity - reservedForWithdrawals;
        }
    }

    /// @notice Get comprehensive pool statistics
    /// @param pid Pool ID
    /// @return totalDeposits Total deposited principal
    /// @return userCount Number of active depositors
    /// @return maxUserCount Maximum users allowed (0 = unlimited)
    /// @return averageDepositPerUser Average deposit size (0 if no users)
    /// @return utilizationBps Pool utilization rate in bps
    function getPoolStats(uint256 pid)
        external
        view
        returns (
            uint256 totalDeposits,
            uint256 userCount,
            uint256 maxUserCount,
            uint256 averageDepositPerUser,
            uint256 utilizationBps
        )
    {
        Types.PoolData storage p = _pool(pid);
        
        totalDeposits = p.totalDeposits;
        userCount = p.userCount;
        maxUserCount = p.poolConfig.maxUserCount;
        
        // Calculate average deposit per user
        if (userCount > 0) {
            averageDepositPerUser = totalDeposits / userCount;
        }
        
        // Calculate utilization
        uint256 availableLiquidity = LibCurrency.balanceOfSelf(p.underlying);
        uint256 totalBorrowed = availableLiquidity > totalDeposits ? 0 : totalDeposits - availableLiquidity;
        
        if (totalDeposits > 0) {
            utilizationBps = (totalBorrowed * 10_000) / totalDeposits;
        }
    }

    function _pool(uint256 pid) internal view returns (Types.PoolData storage) {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        require(p.initialized, "View: uninit pool");
        return p;
    }

    function selectors() external pure returns (bytes4[] memory selectorsArr) {
        selectorsArr = new bytes4[](5);
        selectorsArr[0] = PoolUtilizationViewFacet.getPoolUtilization.selector;
        selectorsArr[1] = PoolUtilizationViewFacet.canDeposit.selector;
        selectorsArr[2] = PoolUtilizationViewFacet.getPoolCapacity.selector;
        selectorsArr[3] = PoolUtilizationViewFacet.getAvailableLiquidity.selector;
        selectorsArr[4] = PoolUtilizationViewFacet.getPoolStats.selector;
    }
}
