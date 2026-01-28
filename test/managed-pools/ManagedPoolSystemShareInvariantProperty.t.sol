// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibFeeRouter} from "../../src/libraries/LibFeeRouter.sol";
import {Types} from "../../src/libraries/Types.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract ManagedPoolSystemShareInvariantHarness {
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

    function setTreasuryShareBps(uint16 bps) external {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        store.treasuryShareBps = bps;
        store.treasuryShareConfigured = true;
    }

    function setActiveCreditShareBps(uint16 bps) external {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        store.activeCreditShareBps = bps;
        store.activeCreditShareConfigured = true;
    }

    function setTreasury(address treasury) external {
        LibAppStorage.s().treasury = treasury;
    }

    function setFoundationReceiver(address receiver) external {
        LibAppStorage.s().foundationReceiver = receiver;
    }

    function setPoolState(
        uint256 pid,
        uint256 totalDeposits,
        uint256 trackedBalance,
        uint256 activeCreditPrincipal,
        uint256 yieldReserve
    ) external {
        Types.PoolData storage pool = LibAppStorage.s().pools[pid];
        pool.totalDeposits = totalDeposits;
        pool.trackedBalance = trackedBalance;
        pool.activeCreditPrincipalTotal = activeCreditPrincipal;
        pool.yieldReserve = yieldReserve;
    }

    function getPoolState(uint256 pid)
        external
        view
        returns (uint256 totalDeposits, uint256 trackedBalance, uint256 activeCreditPrincipal, uint256 yieldReserve)
    {
        Types.PoolData storage pool = LibAppStorage.s().pools[pid];
        return (pool.totalDeposits, pool.trackedBalance, pool.activeCreditPrincipalTotal, pool.yieldReserve);
    }

    function getPoolTrackedBalance(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].trackedBalance;
    }

    function routeManagedShare(uint256 pid, uint256 amount, bool pullFromTracked) external {
        LibFeeRouter.routeManagedShare(pid, amount, bytes32("test"), pullFromTracked, 0);
    }
}

contract ManagedPoolSystemShareInvariantPropertyTest is Test {
    uint256 private constant BASE_PID = 1;
    uint256 private constant MANAGED_PID = 2;

    /// **Feature: managed-pool-system-share, Property 13: Backing Adequacy Invariant**
    function testFuzz_backingAdequacyInvariant(uint256 amount, uint16 systemShareBps, uint16 activeCreditBps)
        public
    {
        amount = bound(amount, 1, 1e24);
        systemShareBps = uint16(bound(systemShareBps, 0, 10_000));
        activeCreditBps = uint16(bound(activeCreditBps, 0, 10_000));

        ManagedPoolSystemShareInvariantHarness harness = new ManagedPoolSystemShareInvariantHarness();
        MockERC20 token = new MockERC20("Test Token", "TEST", 18, 0);

        harness.initPools(address(token));
        harness.setManagedPoolSystemShareBps(systemShareBps);
        harness.setTreasuryShareBps(0);
        harness.setActiveCreditShareBps(activeCreditBps);
        harness.setTreasury(address(0));
        harness.setFoundationReceiver(address(0));

        uint256 totalDeposits = 1e24;
        uint256 trackedBalance = totalDeposits + amount + 1e18;
        harness.setPoolState(BASE_PID, totalDeposits, trackedBalance, 0, 0);
        harness.setPoolState(MANAGED_PID, totalDeposits, trackedBalance, 0, 0);

        harness.routeManagedShare(MANAGED_PID, amount, true);

        (uint256 baseDeposits, uint256 baseTracked, uint256 baseActive, uint256 baseYield) =
            harness.getPoolState(BASE_PID);
        (uint256 managedDeposits, uint256 managedTracked, uint256 managedActive, uint256 managedYield) =
            harness.getPoolState(MANAGED_PID);

        assertTrue(
            baseDeposits + baseYield <= baseTracked + baseActive,
            "base yield reserve exceeds backing"
        );
        assertTrue(
            managedDeposits + managedYield <= managedTracked + managedActive,
            "managed yield reserve exceeds backing"
        );
    }

    /// **Feature: managed-pool-system-share, Property 14: No Underflow on Treasury Fallback**
    function testFuzz_noUnderflowOnTreasuryFallback(uint256 amount, uint16 systemShareBps) public {
        amount = bound(amount, 1, 1e24);
        systemShareBps = uint16(bound(systemShareBps, 1, 10_000));
        uint256 systemShare = (amount * systemShareBps) / 10_000;
        vm.assume(systemShare > 0);

        ManagedPoolSystemShareInvariantHarness harness = new ManagedPoolSystemShareInvariantHarness();
        MockERC20 token = new MockERC20("Test Token", "TEST", 18, 0);

        harness.initPools(address(token));
        harness.setManagedPoolSystemShareBps(systemShareBps);
        harness.setTreasuryShareBps(0);
        harness.setActiveCreditShareBps(0);
        harness.setTreasury(address(0xBEEF));
        harness.setFoundationReceiver(address(0));

        uint256 totalDeposits = 1e24;
        uint256 trackedBalance = totalDeposits + amount;
        harness.setPoolState(BASE_PID, 0, 0, 0, 0);
        harness.setPoolState(MANAGED_PID, totalDeposits, trackedBalance, 0, 0);

        token.mint(address(harness), amount);

        uint256 trackedBefore = harness.getPoolTrackedBalance(MANAGED_PID);
        harness.routeManagedShare(MANAGED_PID, amount, true);
        uint256 trackedAfter = harness.getPoolTrackedBalance(MANAGED_PID);

        assertEq(trackedBefore - trackedAfter, systemShare, "trackedBalance underflow on fallback");
    }
}
