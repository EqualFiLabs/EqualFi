// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibAccess} from "../libraries/LibAccess.sol";
import {LibEqualIndex} from "../libraries/LibEqualIndex.sol";
import {Types} from "../libraries/Types.sol";
import "../libraries/Errors.sol";

/// @notice Facet for managing unified action fees across pools and indexes
contract FeeFacet {
    bytes32 internal constant ACTION_BORROW = keccak256("ACTION_BORROW");
    bytes32 internal constant ACTION_REPAY = keccak256("ACTION_REPAY");
    bytes32 internal constant ACTION_FLASH = keccak256("ACTION_FLASH");
    bytes32 internal constant ACTION_WITHDRAW = keccak256("ACTION_WITHDRAW");
    bytes32 internal constant ACTION_CLOSE_ROLLING = keccak256("ACTION_CLOSE_ROLLING");

    struct ActionFeePreview {
        uint256 borrowFee;
        uint256 repayFee;
        uint256 withdrawFee;
        uint256 flashFee;
        uint256 closeRollingFee;
    }
    // Events
    event PoolActionFeeUpdated(
        uint256 indexed pid,
        bytes32 indexed action,
        uint128 oldAmount,
        uint128 newAmount,
        bool enabled
    );
    
    event IndexActionFeeUpdated(
        uint256 indexed indexId,
        bytes32 indexed action,
        uint128 oldAmount,
        uint128 newAmount,
        bool enabled
    );
    
    event ActionFeeBoundsUpdated(
        uint128 oldMin,
        uint128 oldMax,
        uint128 newMin,
        uint128 newMax
    );

    // Admin functions

    /// @notice Set action fee for a specific pool
    /// @param pid Pool ID
    /// @param action Action identifier (e.g., ACTION_BORROW, ACTION_REPAY)
    /// @param amount Fee amount in underlying token units
    /// @param enabled Whether the fee is active
    function setPoolActionFee(
        uint256 pid,
        bytes32 action,
        uint128 amount,
        bool enabled
    ) external {
        LibAccess.enforceOwnerOrTimelock();
        
        LibAppStorage.AppStorage storage s = LibAppStorage.s();
        
        // Validate pool exists
        if (pid >= s.poolCount) revert PoolNotInitialized(pid);
        
        // Validate fee bounds if configured
        if (s.actionFeeBoundsSet) {
            if (amount < s.actionFeeMin || amount > s.actionFeeMax) {
                revert ActionFeeBoundsViolation(amount, s.actionFeeMin, s.actionFeeMax);
            }
        }
        
        Types.PoolData storage pool = s.pools[pid];
        Types.ActionFeeConfig storage config = pool.actionFees[action];
        
        uint128 oldAmount = config.amount;
        
        config.amount = amount;
        config.enabled = enabled;
        
        emit PoolActionFeeUpdated(pid, action, oldAmount, amount, enabled);
    }
    
    /// @notice Set action fee for a specific index
    /// @param indexId Index ID
    /// @param action Action identifier (e.g., ACTION_INDEX_MINT, ACTION_INDEX_BURN)
    /// @param amount Fee amount in underlying token units
    /// @param enabled Whether the fee is active
    function setIndexActionFee(
        uint256 indexId,
        bytes32 action,
        uint128 amount,
        bool enabled
    ) external {
        LibAccess.enforceOwnerOrTimelock();
        
        LibAppStorage.AppStorage storage s = LibAppStorage.s();
        
        // Validate fee bounds if configured
        if (s.actionFeeBoundsSet) {
            if (amount < s.actionFeeMin || amount > s.actionFeeMax) {
                revert ActionFeeBoundsViolation(amount, s.actionFeeMin, s.actionFeeMax);
            }
        }
        
        LibEqualIndex.EqualIndexStorage storage eqStore = LibEqualIndex.s();
        
        // Validate index exists
        if (indexId >= eqStore.indexCount) revert IndexNotFound(indexId);
        
        Types.ActionFeeConfig storage config = eqStore.actionFees[indexId][action];
        
        uint128 oldAmount = config.amount;
        
        config.amount = amount;
        config.enabled = enabled;
        
        emit IndexActionFeeUpdated(indexId, action, oldAmount, amount, enabled);
    }
    
    /// @notice Set bounds for action fee amounts
    /// @param minAmount Minimum allowed fee amount
    /// @param maxAmount Maximum allowed fee amount
    function setActionFeeBounds(
        uint128 minAmount,
        uint128 maxAmount
    ) external {
        LibAccess.enforceOwnerOrTimelock();
        
        require(minAmount <= maxAmount, "FeeFacet: invalid bounds");
        
        LibAppStorage.AppStorage storage s = LibAppStorage.s();
        
        uint128 oldMin = s.actionFeeMin;
        uint128 oldMax = s.actionFeeMax;
        
        s.actionFeeMin = minAmount;
        s.actionFeeMax = maxAmount;
        s.actionFeeBoundsSet = true;
        
        emit ActionFeeBoundsUpdated(oldMin, oldMax, minAmount, maxAmount);
    }

    // Query functions

    /// @notice Get action fee configuration for a pool
    /// @param pid Pool ID
    /// @param action Action identifier
    /// @return amount Fee amount in underlying token units
    /// @return enabled Whether the fee is active
    function getPoolActionFee(
        uint256 pid,
        bytes32 action
    ) external view returns (uint128 amount, bool enabled) {
        LibAppStorage.AppStorage storage s = LibAppStorage.s();
        
        if (pid >= s.poolCount) revert PoolNotInitialized(pid);
        
        Types.ActionFeeConfig storage config = s.pools[pid].actionFees[action];
        return (config.amount, config.enabled);
    }
    
    /// @notice Get action fee configuration for an index
    /// @param indexId Index ID
    /// @param action Action identifier
    /// @return amount Fee amount in underlying token units
    /// @return enabled Whether the fee is active
    function getIndexActionFee(
        uint256 indexId,
        bytes32 action
    ) external view returns (uint128 amount, bool enabled) {
        LibEqualIndex.EqualIndexStorage storage eqStore = LibEqualIndex.s();
        
        if (indexId >= eqStore.indexCount) revert IndexNotFound(indexId);
        
        Types.ActionFeeConfig storage config = eqStore.actionFees[indexId][action];
        return (config.amount, config.enabled);
    }
    
    /// @notice Preview action fee for a pool operation
    /// @param pid Pool ID
    /// @param action Action identifier
    /// @return feeAmount Fee amount that would be charged (0 if disabled)
    function previewActionFee(
        uint256 pid,
        bytes32 action
    ) external view returns (uint256 feeAmount) {
        LibAppStorage.AppStorage storage s = LibAppStorage.s();
        
        if (pid >= s.poolCount) revert PoolNotInitialized(pid);
        
        Types.ActionFeeConfig storage config = s.pools[pid].actionFees[action];
        
        if (!config.enabled) {
            return 0;
        }
        
        return uint256(config.amount);
    }
    
    /// @notice Preview action fee for an index operation
    /// @param indexId Index ID
    /// @param action Action identifier
    /// @return feeAmount Fee amount that would be charged (0 if disabled)
    function previewIndexActionFee(
        uint256 indexId,
        bytes32 action
    ) external view returns (uint256 feeAmount) {
        LibEqualIndex.EqualIndexStorage storage eqStore = LibEqualIndex.s();
        
        if (indexId >= eqStore.indexCount) revert IndexNotFound(indexId);
        
        Types.ActionFeeConfig storage config = eqStore.actionFees[indexId][action];
        
        if (!config.enabled) {
            return 0;
        }
        
        return uint256(config.amount);
    }

    /// @notice Get effective action fee configs for a pool (mutable override, else immutable).
    function getPoolActionFees(uint256 pid)
        external
        view
        returns (Types.ActionFeeSet memory fees)
    {
        LibAppStorage.AppStorage storage s = LibAppStorage.s();
        if (pid >= s.poolCount) revert PoolNotInitialized(pid);

        Types.PoolData storage p = s.pools[pid];
        fees.borrowFee = _resolveActionFee(p, ACTION_BORROW);
        fees.repayFee = _resolveActionFee(p, ACTION_REPAY);
        fees.withdrawFee = _resolveActionFee(p, ACTION_WITHDRAW);
        fees.flashFee = _resolveActionFee(p, ACTION_FLASH);
        fees.closeRollingFee = _resolveActionFee(p, ACTION_CLOSE_ROLLING);
    }

    /// @notice Preview all pool action fees in one call.
    function previewActionFees(uint256 pid) external view returns (ActionFeePreview memory preview) {
        LibAppStorage.AppStorage storage s = LibAppStorage.s();
        if (pid >= s.poolCount) revert PoolNotInitialized(pid);

        Types.PoolData storage p = s.pools[pid];
        preview.borrowFee = _previewActionFee(p, ACTION_BORROW);
        preview.repayFee = _previewActionFee(p, ACTION_REPAY);
        preview.withdrawFee = _previewActionFee(p, ACTION_WITHDRAW);
        preview.flashFee = _previewActionFee(p, ACTION_FLASH);
        preview.closeRollingFee = _previewActionFee(p, ACTION_CLOSE_ROLLING);
    }

    function _previewActionFee(Types.PoolData storage p, bytes32 action) internal view returns (uint256) {
        Types.ActionFeeConfig memory cfg = _resolveActionFee(p, action);
        if (!cfg.enabled) {
            return 0;
        }
        return uint256(cfg.amount);
    }

    function _resolveActionFee(Types.PoolData storage p, bytes32 action)
        internal
        view
        returns (Types.ActionFeeConfig memory cfg)
    {
        Types.ActionFeeConfig storage mutableCfg = p.actionFees[action];
        if (mutableCfg.enabled) {
            return mutableCfg;
        }

        if (action == ACTION_BORROW) return p.poolConfig.borrowFee;
        if (action == ACTION_REPAY) return p.poolConfig.repayFee;
        if (action == ACTION_WITHDRAW) return p.poolConfig.withdrawFee;
        if (action == ACTION_FLASH) return p.poolConfig.flashFee;
        if (action == ACTION_CLOSE_ROLLING) return p.poolConfig.closeRollingFee;

        return Types.ActionFeeConfig(0, false);
    }
}
