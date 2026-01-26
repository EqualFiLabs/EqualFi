// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {LibAppStorage} from "./LibAppStorage.sol";
import {LibFeeRouter} from "./LibFeeRouter.sol";
import {Types} from "./Types.sol";

/// @notice Fee helper to divert the configured treasury share and accrue the rest to the fee index.
library LibFeeTreasury {
    using SafeERC20 for IERC20;

    /// @dev Splits amount into treasury share and fee index remainder if treasury configured.
    ///      Returns (toTreasury, toActiveCredit, toIndexAccrued).
    function accrueWithTreasury(Types.PoolData storage p, uint256 pid, uint256 amount, bytes32 source)
        internal
        returns (uint256 toTreasury, uint256 toActiveCredit, uint256 toIndex)
    {
        return _accrue(p, pid, amount, source, true);
    }

    /// @dev Split amount without pulling again from trackedBalance.
    ///      Use when the caller already debited trackedBalance/user principal for this `amount`.
    function accrueWithTreasuryFromPrincipal(
        Types.PoolData storage p,
        uint256 pid,
        uint256 amount,
        bytes32 source
    ) internal returns (uint256 toTreasury, uint256 toActiveCredit, uint256 toIndex) {
        return _accrue(p, pid, amount, source, false);
    }

    function _accrue(
        Types.PoolData storage p,
        uint256 pid,
        uint256 amount,
        bytes32 source,
        bool pullFromTracked
    ) private returns (uint256 toTreasury, uint256 toActiveCredit, uint256 toIndex) {
        p;
        return LibFeeRouter.routeSamePool(pid, amount, source, pullFromTracked, 0);
    }
}
