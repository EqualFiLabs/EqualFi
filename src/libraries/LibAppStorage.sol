// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Types} from "./Types.sol";

/// @notice Application storage anchor for EqualLend Diamond rebuild
library LibAppStorage {
    bytes32 internal constant APP_STORAGE_POSITION = keccak256("equal.lend.app.storage");
    uint16 internal constant DEFAULT_TREASURY_SHARE_BPS = 2000; // 20%
    // Default active credit share disabled; enable explicitly via governance when needed.
    uint16 internal constant DEFAULT_ACTIVE_CREDIT_SHARE_BPS = 0;
    uint16 internal constant DEFAULT_MANAGED_POOL_SYSTEM_SHARE_BPS = 2000; // 20%
    uint8 internal constant DEFAULT_ROLLING_DELINQUENCY_EPOCHS = 2;
    uint8 internal constant DEFAULT_ROLLING_PENALTY_EPOCHS = 3;

    struct FlashAgg {
        uint256 blockNumber;
        uint256 amount;
    }

    struct AppStorage {
        uint256 poolCount;
        mapping(uint256 => Types.PoolData) pools;
        mapping(address => uint256) permissionlessPoolForToken;
        mapping(address => uint256) assetToPoolId;
        Types.PoolConfig defaultPoolConfig;
        bool defaultPoolConfigSet;
        // Legacy GlobalVault / Points fields removed per ADR-017/018.
        mapping(address => mapping(uint256 => FlashAgg)) flashAgg; // receiver => pid => aggregate per block
        bool defaultFlashAntiSplit;
        address timelock;
        address treasury;
        uint16 treasuryShareBps;
        bool treasuryShareConfigured;
        uint128 actionFeeMin;
        uint128 actionFeeMax;
        bool actionFeeBoundsSet;
        address foundationReceiver;
        uint16 defaultMaintenanceRateBps;
        uint16 maxMaintenanceRateBps;
        uint256 __reservedIndexCreationFee; // preserves storage spacing for legacy slot assumptions
        uint256 indexCreationFee;
        uint256 poolCreationFee;
        uint8 rollingDelinquencyEpochs;
        uint8 rollingPenaltyEpochs;
        uint16 rollingMinPaymentBps;
        uint256 managedPoolCreationFee;
        uint16 activeCreditShareBps;
        bool activeCreditShareConfigured;
        uint16 managedPoolSystemShareBps;
        bool managedPoolSystemShareConfigured;
        uint8 transientCacheMode; // 0=default on, 1=on, 2=off
        uint256 nativeTrackedTotal;
        address positionMintFeeToken;
        uint256 positionMintFeeAmount;
    }

    function s() internal pure returns (AppStorage storage ds) {
        bytes32 position = APP_STORAGE_POSITION;
        assembly {
            ds.slot := position
        }
    }

    /// @notice Return timelock, honoring historical slot layout used in tests/scripts.
    function timelockAddress(AppStorage storage store) internal view returns (address tl) {
        tl = store.timelock;
        if (tl != address(0)) {
            return tl;
        }
        bytes32 slot = APP_STORAGE_POSITION;
        assembly {
            tl := sload(add(slot, 8))
        }
        if (tl != address(0)) {
            return tl;
        }
        assembly {
            tl := shr(8, sload(add(slot, 3)))
        }
    }

    /// @notice Return index creation fee with backward-compatible slot lookup.
    function indexCreationFee(AppStorage storage store) internal view returns (uint256 fee) {
        fee = store.indexCreationFee;
        if (fee != 0) {
            return fee;
        }
        bytes32 slot = APP_STORAGE_POSITION;
        assembly {
            fee := sload(add(slot, 9))
        }
    }

    /// @notice Return treasury, honoring historical slot layout used in tests/scripts.
    function treasuryAddress(AppStorage storage store) internal view returns (address treasury) {
        treasury = store.treasury;
        if (treasury != address(0)) {
            return treasury;
        }
        if (store.defaultPoolConfigSet) {
            return treasury;
        }
        bytes32 slot = APP_STORAGE_POSITION;
        assembly {
            treasury := sload(add(slot, 4))
        }
    }

    function treasurySplitBps(AppStorage storage store) internal view returns (uint16) {
        return store.treasuryShareConfigured ? store.treasuryShareBps : DEFAULT_TREASURY_SHARE_BPS;
    }

    function activeCreditSplitBps(AppStorage storage store) internal view returns (uint16) {
        return store.activeCreditShareConfigured ? store.activeCreditShareBps : DEFAULT_ACTIVE_CREDIT_SHARE_BPS;
    }

    function managedPoolSystemShareBps(AppStorage storage store) internal view returns (uint16) {
        return store.managedPoolSystemShareConfigured
            ? store.managedPoolSystemShareBps
            : DEFAULT_MANAGED_POOL_SYSTEM_SHARE_BPS;
    }
}
