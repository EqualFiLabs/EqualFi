// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibCurrency} from "../libraries/LibCurrency.sol";
import {LibFeeIndex} from "../libraries/LibFeeIndex.sol";
import {Types} from "../libraries/Types.sol";

/// @notice Read-only views for liquidity, balances, and fee index
contract LiquidityViewFacet {
    function totalAvailableLiquidity(uint256 pid) external view returns (uint256) {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        require(p.initialized, "View: uninit pool");
        return LibCurrency.balanceOfSelf(p.underlying);
    }

    function getTotalPoolDeposits(uint256 pid) external view returns (uint256) {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        require(p.initialized, "View: uninit pool");
        return p.totalDeposits;
    }

    function pendingYield(uint256 pid, bytes32 user) external view returns (uint256) {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        require(p.initialized, "View: uninit pool");
        return LibFeeIndex.pendingYield(pid, user);
    }

    /// @notice Sum accrued yield for a list of positions in a pool.
    /// @dev Helps compare ledgered yield against the pool's yieldReserve/backing.
    function sumAccruedYield(uint256 pid, bytes32[] calldata users) external view returns (uint256 totalAccrued) {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        require(p.initialized, "View: uninit pool");
        uint256 len = users.length;
        for (uint256 i = 0; i < len; i++) {
            totalAccrued += p.userAccruedYield[users[i]];
        }
    }

    function getUserBalances(uint256 pid, bytes32 user)
        external
        view
        returns (uint256 principal, uint256 accruedYield, uint256 userFeeIndex, uint256 globalFeeIndex)
    {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        require(p.initialized, "View: uninit pool");
        principal = p.userPrincipal[user];
        accruedYield = p.userAccruedYield[user];
        userFeeIndex = p.userFeeIndex[user];
        globalFeeIndex = p.feeIndex;
    }

    function selectors() external pure returns (bytes4[] memory selectorsArr) {
        selectorsArr = new bytes4[](5);
        selectorsArr[0] = LiquidityViewFacet.totalAvailableLiquidity.selector;
        selectorsArr[1] = LiquidityViewFacet.getTotalPoolDeposits.selector;
        selectorsArr[2] = LiquidityViewFacet.pendingYield.selector;
        selectorsArr[3] = LiquidityViewFacet.getUserBalances.selector;
        selectorsArr[4] = LiquidityViewFacet.sumAccruedYield.selector;
    }
}
