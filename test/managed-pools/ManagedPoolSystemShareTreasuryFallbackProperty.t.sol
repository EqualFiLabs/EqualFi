// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibFeeRouter} from "../../src/libraries/LibFeeRouter.sol";
import {Types} from "../../src/libraries/Types.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract ManagedPoolSystemShareTreasuryFallbackPropertyHarness {
    function initPools(address underlying) external {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        store.assetToPoolId[underlying] = 1;

        Types.PoolData storage basePool = store.pools[1];
        basePool.initialized = true;
        basePool.underlying = underlying;

        Types.PoolData storage managedPool = store.pools[2];
        managedPool.initialized = true;
        managedPool.underlying = underlying;
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

    function getPoolState(uint256 pid) external view returns (uint256 tracked, uint256 feeIndex, uint256 activeIndex) {
        Types.PoolData storage pool = LibAppStorage.s().pools[pid];
        return (pool.trackedBalance, pool.feeIndex, pool.activeCreditIndex);
    }

    function routeManagedShare(uint256 pid, uint256 amount) external {
        LibFeeRouter.routeManagedShare(pid, amount, bytes32("test"), true, 0);
    }
}

contract ManagedPoolSystemShareTreasuryFallbackPropertyTest is Test {
    uint256 private constant BASE_PID = 1;
    uint256 private constant MANAGED_PID = 2;

    function testFuzz_treasuryFallbackPreservesBasePoolState(uint256 amount, uint16 bps) public {
        amount = bound(amount, 1, 1e24);
        bps = uint16(bound(bps, 0, 10_000));

        ManagedPoolSystemShareTreasuryFallbackPropertyHarness harness =
            new ManagedPoolSystemShareTreasuryFallbackPropertyHarness();
        MockERC20 token = new MockERC20("Test Token", "TEST", 18, 0);

        harness.initPools(address(token));
        harness.setManagedPoolSystemShareBps(bps);
        harness.setTreasury(address(0xBEEF));

        token.mint(address(harness), 1_000_000 ether);
        harness.setPoolBalances(BASE_PID, 0, 500 ether); // zero deposits to force fallback
        harness.setPoolBalances(MANAGED_PID, 1000 ether, 1000 ether + amount);

        (uint256 trackedBefore, uint256 feeIndexBefore, uint256 activeBefore) = harness.getPoolState(BASE_PID);

        harness.routeManagedShare(MANAGED_PID, amount);

        (uint256 trackedAfter, uint256 feeIndexAfter, uint256 activeAfter) = harness.getPoolState(BASE_PID);

        assertEq(trackedAfter, trackedBefore, "trackedBalance changed");
        assertEq(feeIndexAfter, feeIndexBefore, "feeIndex changed");
        assertEq(activeAfter, activeBefore, "activeCreditIndex changed");
    }
}
