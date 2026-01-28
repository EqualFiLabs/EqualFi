// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibFeeRouter} from "../../src/libraries/LibFeeRouter.sol";
import {Types} from "../../src/libraries/Types.sol";

contract ManagedPoolNativeTrackedInvariantHarness {
    function initPools() external {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        store.assetToPoolId[address(0)] = 1;

        Types.PoolData storage basePool = store.pools[1];
        basePool.initialized = true;
        basePool.underlying = address(0);

        Types.PoolData storage managedPool = store.pools[2];
        managedPool.initialized = true;
        managedPool.underlying = address(0);
        managedPool.isManagedPool = true;
    }

    function setManagedPoolSystemShareBps(uint16 bps) external {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        store.managedPoolSystemShareBps = bps;
        store.managedPoolSystemShareConfigured = true;
    }

    function setTreasury(address treasury) external {
        LibAppStorage.s().treasury = treasury;
    }

    function setPoolBalances(uint256 pid, uint256 totalDeposits, uint256 trackedBalance) external {
        Types.PoolData storage pool = LibAppStorage.s().pools[pid];
        pool.totalDeposits = totalDeposits;
        pool.trackedBalance = trackedBalance;
    }

    function setNativeTrackedTotal(uint256 total) external {
        LibAppStorage.s().nativeTrackedTotal = total;
    }

    function getNativeTrackedTotal() external view returns (uint256) {
        return LibAppStorage.s().nativeTrackedTotal;
    }

    function routeManagedShare(uint256 pid, uint256 amount) external {
        LibFeeRouter.routeManagedShare(pid, amount, bytes32("test"), true, 0);
    }
}

contract ManagedPoolNativeTrackedInvariantPropertyTest is Test {
    uint256 private constant BASE_PID = 1;
    uint256 private constant MANAGED_PID = 2;

    function testFuzz_nativeTrackedTotalInvariant(uint256 amount, uint16 bps) public {
        amount = bound(amount, 1, 1e24);
        bps = uint16(bound(bps, 0, 10_000));

        ManagedPoolNativeTrackedInvariantHarness harness = new ManagedPoolNativeTrackedInvariantHarness();
        harness.initPools();
        harness.setManagedPoolSystemShareBps(bps);
        harness.setTreasury(address(0));

        harness.setPoolBalances(BASE_PID, 1000 ether, 1000 ether + amount);
        harness.setPoolBalances(MANAGED_PID, 1000 ether, 1000 ether + amount);

        uint256 nativeBefore = 5000 ether;
        harness.setNativeTrackedTotal(nativeBefore);

        harness.routeManagedShare(MANAGED_PID, amount);

        uint256 nativeAfter = harness.getNativeTrackedTotal();
        assertEq(nativeAfter, nativeBefore, "nativeTrackedTotal changed");
    }
}
