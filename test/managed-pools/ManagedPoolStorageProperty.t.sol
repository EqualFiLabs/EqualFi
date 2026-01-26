// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Types} from "../../src/libraries/Types.sol";
import {LibPositionHelpers} from "../../src/libraries/LibPositionHelpers.sol";

contract ManagedPoolStorageHarness {
    Types.PoolData internal pool;

    function setImmutableConfig(address underlying, uint16 rollingApyBps, uint256 minDepositAmount) external {
        pool.underlying = underlying;
        pool.initialized = true;
        pool.poolConfig.rollingApyBps = rollingApyBps;
        pool.poolConfig.minDepositAmount = minDepositAmount;
    }

    function setManagedConfig(
        address manager,
        uint16 rollingApyBps,
        uint256 minDepositAmount,
        bool whitelistEnabled
    ) external {
        pool.manager = manager;
        pool.managedConfig.manager = manager;
        pool.managedConfig.rollingApyBps = rollingApyBps;
        pool.managedConfig.minDepositAmount = minDepositAmount;
        pool.whitelistEnabled = whitelistEnabled;
        pool.managedConfig.whitelistEnabled = whitelistEnabled;
    }

    function setLedger(bytes32 positionKey, uint256 principal) external {
        pool.userPrincipal[positionKey] = principal;
    }

    function setWhitelist(bytes32 positionKey, bool allowed) external {
        pool.whitelist[positionKey] = allowed;
    }

    function setIsManagedPool(bool managed) external {
        pool.isManagedPool = managed;
    }

    function selectedRollingApy() external view returns (uint16) {
        return pool.isManagedPool ? pool.managedConfig.rollingApyBps : pool.poolConfig.rollingApyBps;
    }

    function selectedMinDeposit() external view returns (uint256) {
        return pool.isManagedPool ? pool.managedConfig.minDepositAmount : pool.poolConfig.minDepositAmount;
    }

    function ledgerOf(bytes32 positionKey) external view returns (uint256) {
        return pool.userPrincipal[positionKey];
    }

    function whitelistStatus(bytes32 positionKey) external view returns (bool) {
        return pool.whitelist[positionKey];
    }

    function managers() external view returns (address poolManager, address configManager) {
        return (pool.manager, pool.managedConfig.manager);
    }

    function whitelistFlags() external view returns (bool poolFlag, bool configFlag) {
        return (pool.whitelistEnabled, pool.managedConfig.whitelistEnabled);
    }
}

/// **Feature: managed-pools, Property 13: Storage isolation and configuration branching**
/// **Validates: Requirements 10.1, 10.3, 10.5**
contract ManagedPoolStoragePropertyTest is Test {
    ManagedPoolStorageHarness internal harness;

    function setUp() public {
        harness = new ManagedPoolStorageHarness();
    }

    function testProperty_StorageIsolationAndBranching(
        address underlying,
        address manager,
        address user,
        uint16 immutableApy,
        uint16 managedApy,
        uint256 immutableMinDeposit,
        uint256 managedMinDeposit,
        uint256 principal
    ) public {
        immutableApy = uint16(bound(immutableApy, 1, 10_000));
        managedApy = uint16(bound(managedApy, 1, 10_000));
        vm.assume(immutableApy != managedApy);

        immutableMinDeposit = bound(immutableMinDeposit, 1, 1e36);
        managedMinDeposit = bound(managedMinDeposit, 1, 1e36);
        vm.assume(immutableMinDeposit != managedMinDeposit);
        principal = bound(principal, 0, 1e36);

        harness.setImmutableConfig(underlying, immutableApy, immutableMinDeposit);
        harness.setManagedConfig(manager, managedApy, managedMinDeposit, true);
        bytes32 userKey = LibPositionHelpers.systemPositionKey(user);
        harness.setLedger(userKey, principal);
        harness.setWhitelist(userKey, true);

        harness.setIsManagedPool(false);
        assertEq(harness.selectedRollingApy(), immutableApy, "immutable rolling APY used for unmanaged pools");
        assertEq(harness.selectedMinDeposit(), immutableMinDeposit, "immutable min deposit used for unmanaged pools");

        harness.setWhitelist(userKey, false);
        assertEq(harness.ledgerOf(userKey), principal, "whitelist writes do not mutate ledger entries");

        harness.setIsManagedPool(true);
        assertEq(harness.selectedRollingApy(), managedApy, "managed pools branch to managed config");
        assertEq(harness.selectedMinDeposit(), managedMinDeposit, "managed pools read managed thresholds");

        (address poolManager, address configManager) = harness.managers();
        assertEq(poolManager, manager, "pool manager stored");
        assertEq(configManager, manager, "managed config manager stored");

        (bool poolWhitelistFlag, bool configWhitelistFlag) = harness.whitelistFlags();
        assertTrue(poolWhitelistFlag, "pool whitelist flag preserved");
        assertTrue(configWhitelistFlag, "config whitelist flag preserved");
        assertFalse(harness.whitelistStatus(userKey), "whitelist mapping isolated from pool selection");
    }
}
