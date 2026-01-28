// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibFeeRouter} from "../../src/libraries/LibFeeRouter.sol";
import {Types} from "../../src/libraries/Types.sol";

contract ManagedPoolSystemShareHarness {
    function initPools(address underlying) external {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        store.poolCount = 3;
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

    function setFoundationReceiver(address receiver) external {
        LibAppStorage.s().foundationReceiver = receiver;
    }

    function setPoolBalances(uint256 pid, uint256 totalDeposits, uint256 trackedBalance) external {
        Types.PoolData storage pool = LibAppStorage.s().pools[pid];
        pool.totalDeposits = totalDeposits;
        pool.trackedBalance = trackedBalance;
    }

    function getPoolTrackedBalance(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].trackedBalance;
    }

    function routeManagedShare(uint256 pid, uint256 amount, bool pullFromTracked)
        external
        returns (uint256 toTreasury, uint256 toActiveCredit, uint256 toFeeIndex)
    {
        return LibFeeRouter.routeManagedShare(pid, amount, bytes32("test"), pullFromTracked, 0);
    }
}

contract ManagedPoolSystemSharePropertyTest is Test {
    uint256 private constant BASE_PID = 1;
    uint256 private constant MANAGED_PID = 2;
    address private constant UNDERLYING = address(0xBEEF);

    function testFuzz_feeSplitConservation(uint256 amount, uint16 bps) public {
        amount = bound(amount, 1, 1e30);
        bps = uint16(bound(bps, 0, 10_000));

        uint256 systemShare = (amount * bps) / 10_000;
        uint256 managedShare = amount - systemShare;

        assertEq(systemShare + managedShare, amount, "fee split conservation");
    }

    function testFuzz_trackedBalanceConservation(uint256 amount, uint16 bps) public {
        amount = bound(amount, 1, 1e24);
        bps = uint16(bound(bps, 0, 10_000));

        ManagedPoolSystemShareHarness harness = new ManagedPoolSystemShareHarness();
        harness.initPools(UNDERLYING);
        harness.setTreasury(address(0));
        harness.setFoundationReceiver(address(0));
        harness.setManagedPoolSystemShareBps(bps);

        uint256 totalDeposits = 1e24;
        uint256 trackedBalance = totalDeposits + amount;
        harness.setPoolBalances(BASE_PID, totalDeposits, trackedBalance);
        harness.setPoolBalances(MANAGED_PID, totalDeposits, trackedBalance);

        uint256 baseBefore = harness.getPoolTrackedBalance(BASE_PID);
        uint256 managedBefore = harness.getPoolTrackedBalance(MANAGED_PID);

        harness.routeManagedShare(MANAGED_PID, amount, true);

        uint256 baseAfter = harness.getPoolTrackedBalance(BASE_PID);
        uint256 managedAfter = harness.getPoolTrackedBalance(MANAGED_PID);

        uint256 systemShare = (amount * bps) / 10_000;

        assertEq(managedBefore - managedAfter, systemShare, "managed decrease != system share");
        assertEq(baseAfter - baseBefore, systemShare, "base increase != system share");
    }
}
