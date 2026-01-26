// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Types} from "./Types.sol";
import {LibAppStorage} from "./LibAppStorage.sol";
import {LibCurrency} from "./LibCurrency.sol";
import {LibFeeTreasury} from "./LibFeeTreasury.sol";
import {LibFeeIndex} from "./LibFeeIndex.sol";
import "./Errors.sol";

/// @notice Helper for charging per-action flat fees defined in ADR-018.
library LibActionFees {
    bytes32 internal constant ACTION_BORROW = keccak256("ACTION_BORROW");
    bytes32 internal constant ACTION_REPAY = keccak256("ACTION_REPAY");
    bytes32 internal constant ACTION_FLASH = keccak256("ACTION_FLASH");
    bytes32 internal constant ACTION_WITHDRAW = keccak256("ACTION_WITHDRAW");
    bytes32 internal constant ACTION_CLOSE_ROLLING = keccak256("ACTION_CLOSE_ROLLING");

    event ActionFeeApplied(
        uint256 indexed pid, bytes32 indexed action, bytes32 indexed payer, uint256 amount, uint256 treasuryPortion
    );

    function chargeFromUser(Types.PoolData storage p, uint256 pid, bytes32 action, bytes32 payer)
        internal
        returns (uint256 feeAmount)
    {
        feeAmount = _preview(p, pid, action);
        if (feeAmount == 0) {
            return 0;
        }

        // Fees must be paid from the position's principal so costs are not socialized.
        LibFeeIndex.settle(pid, payer);
        uint256 updatedPrincipal = p.userPrincipal[payer];
        require(updatedPrincipal >= feeAmount, "ActionFee: insufficient balance");
        p.userPrincipal[payer] = updatedPrincipal - feeAmount;
        p.totalDeposits -= feeAmount;
        (uint256 toTreasury,,) = LibFeeTreasury.accrueWithTreasuryFromPrincipal(p, pid, feeAmount, action);

        // Only the treasury portion leaves the pool; feeIndex portion stays in trackedBalance
        if (toTreasury > 0) {
            require(p.trackedBalance >= toTreasury, "ActionFee: insufficient trackedBalance");
            p.trackedBalance -= toTreasury;
            if (LibCurrency.isNative(p.underlying)) {
                LibAppStorage.s().nativeTrackedTotal -= toTreasury;
            }
        }
        emit ActionFeeApplied(pid, action, payer, feeAmount, toTreasury);
    }

    function chargeFromPoolBalance(Types.PoolData storage p, uint256 pid, bytes32 action)
        internal
        returns (uint256 feeAmount)
    {
        feeAmount = _preview(p, pid, action);
        if (feeAmount == 0) {
            return 0;
        }
        (uint256 toTreasury,,) = LibFeeTreasury.accrueWithTreasury(p, pid, feeAmount, action);
        emit ActionFeeApplied(pid, action, bytes32(0), feeAmount, toTreasury);
    }

    function preview(Types.PoolData storage p, uint256 pid, bytes32 action) internal view returns (uint256) {
        return _previewView(p, pid, action);
    }

    function _preview(Types.PoolData storage p, uint256 pid, bytes32 action) private view returns (uint256) {
        return _previewView(p, pid, action);
    }

    function _previewView(Types.PoolData storage p, uint256 pid, bytes32 action) private view returns (uint256) {
        // First check mutable config (admin override)
        Types.ActionFeeConfig storage mutableCfg = p.actionFees[action];
        if (mutableCfg.enabled) {
            uint256 amount = uint256(mutableCfg.amount);
            if (amount == 0) {
                revert ActionFeeDisabled(pid, action);
            }
            return amount;
        }
        
        // Fall back to immutable config (set at pool creation)
        Types.ActionFeeConfig memory immutableCfg = _getImmutableActionFee(p, action);
        if (!immutableCfg.enabled) {
            return 0;
        }
        uint256 immutableAmount = uint256(immutableCfg.amount);
        if (immutableAmount == 0) {
            revert ActionFeeDisabled(pid, action);
        }
        return immutableAmount;
    }
    
    /// @notice Get immutable action fee config for a specific action
    function _getImmutableActionFee(Types.PoolData storage p, bytes32 action) 
        private 
        view 
        returns (Types.ActionFeeConfig memory) 
    {
        if (action == ACTION_BORROW) return p.poolConfig.borrowFee;
        if (action == ACTION_REPAY) return p.poolConfig.repayFee;
        if (action == ACTION_WITHDRAW) return p.poolConfig.withdrawFee;
        if (action == ACTION_FLASH) return p.poolConfig.flashFee;
        if (action == ACTION_CLOSE_ROLLING) return p.poolConfig.closeRollingFee;
        
        // Return a disabled config for unknown actions
        return Types.ActionFeeConfig(0, false);
    }
}
