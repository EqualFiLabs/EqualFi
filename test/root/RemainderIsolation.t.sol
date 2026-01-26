// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {Types} from "../../src/libraries/Types.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {LibMaintenance} from "../../src/libraries/LibMaintenance.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

/// @notice Tests that fee and maintenance index remainders are isolated per pool
contract RemainderIsolationTest is Test {
    RemainderHarness internal harness;
    MockERC20 internal token;
    
    uint256 internal constant POOL_A = 1;
    uint256 internal constant POOL_B = 2;
    address internal constant RECEIVER = address(0xFEE);

    function setUp() public {
        harness = new RemainderHarness();
        token = new MockERC20("Mock Token", "MOCK", 18, 0);
        
        harness.initPool(POOL_A, address(token));
        harness.initPool(POOL_B, address(token));
        harness.setFoundationReceiver(RECEIVER);
        
        vm.warp(100 days);
    }

    /// @notice Test that fee index remainders don't cross-contaminate between pools
    function test_FeeIndexRemainder_PoolIsolation() public {
        // Pool A: Setup to create a remainder
        harness.setTotalDeposits(POOL_A, 3 ether);
        
        // Pool B: Different setup
        harness.setTotalDeposits(POOL_B, 5 ether);
        
        // Accrue small fee in Pool A that creates remainder
        harness.accrueFee(POOL_A, 1); // 1 wei fee on 3 ether = creates remainder
        
        uint256 poolARemainder = harness.getFeeIndexRemainder(POOL_A);
        uint256 poolBRemainder = harness.getFeeIndexRemainder(POOL_B);
        
        // Pool A should have remainder, Pool B should not
        assertGt(poolARemainder, 0, "Pool A should have remainder");
        assertEq(poolBRemainder, 0, "Pool B should have no remainder");
        
        // Now accrue fee in Pool B
        harness.accrueFee(POOL_B, 1);
        
        uint256 poolARemainderAfter = harness.getFeeIndexRemainder(POOL_A);
        uint256 poolBRemainderAfter = harness.getFeeIndexRemainder(POOL_B);
        
        // Pool A's remainder should be unchanged
        assertEq(poolARemainderAfter, poolARemainder, "Pool A remainder unchanged");
        
        // Pool B now has its own remainder
        assertGt(poolBRemainderAfter, 0, "Pool B has its own remainder");
        
        // Remainders are independent - they can be equal by coincidence but Pool A's shouldn't change
        // The key test is that Pool A's remainder didn't change when Pool B accrued
    }

    /// @notice Test that maintenance index remainders don't cross-contaminate
    function test_MaintenanceRemainder_PoolIsolation() public {
        // Pool A: Setup with odd number to create remainder
        harness.setTotalDeposits(POOL_A, 7_777 ether);
        harness.setMaintenanceRate(POOL_A, 100);
        
        // Pool B: Different setup
        harness.setTotalDeposits(POOL_B, 11_111 ether);
        harness.setMaintenanceRate(POOL_B, 100);
        
        // Initialize maintenance
        harness.enforceMaintenance(POOL_A);
        harness.enforceMaintenance(POOL_B);
        
        // Advance time and accrue maintenance in Pool A
        vm.warp(block.timestamp + 1 days);
        harness.enforceMaintenance(POOL_A);
        
        uint256 poolARemainder = harness.getMaintenanceRemainder(POOL_A);
        uint256 poolBRemainder = harness.getMaintenanceRemainder(POOL_B);
        
        // Pool A may have remainder, Pool B should still be 0
        assertEq(poolBRemainder, 0, "Pool B should have no remainder yet");
        
        // Now accrue maintenance in Pool B
        harness.enforceMaintenance(POOL_B);
        
        uint256 poolARemainderAfter = harness.getMaintenanceRemainder(POOL_A);
        uint256 poolBRemainderAfter = harness.getMaintenanceRemainder(POOL_B);
        
        // Pool A's remainder should be unchanged
        assertEq(poolARemainderAfter, poolARemainder, "Pool A remainder unchanged");
        
        // Remainders are independent
        assertTrue(poolARemainderAfter != poolBRemainderAfter || poolARemainderAfter == 0, "Remainders are independent");
    }

    /// @notice Test that Pool A's remainder doesn't boost Pool B's index
    function test_RemainderDoesNotBoostOtherPool() public {
        // Pool A: Create large remainder
        harness.setTotalDeposits(POOL_A, 1_000_000 ether);
        harness.accrueFee(POOL_A, 1); // Creates remainder
        
        uint256 poolARemainder = harness.getFeeIndexRemainder(POOL_A);
        assertGt(poolARemainder, 0, "Pool A has remainder");
        
        // Pool B: Should not inherit Pool A's remainder
        harness.setTotalDeposits(POOL_B, 1000 ether);
        
        uint256 poolBIndexBefore = harness.getFeeIndex(POOL_B);
        
        // Accrue fee in Pool B
        harness.accrueFee(POOL_B, 1000 ether);
        
        uint256 poolBIndexAfter = harness.getFeeIndex(POOL_B);
        uint256 poolBRemainder = harness.getFeeIndexRemainder(POOL_B);
        
        // Pool B's index should be based only on its own accrual
        uint256 expectedDelta = (1000 ether * 1e18) / 1000 ether; // 1e18
        assertEq(poolBIndexAfter - poolBIndexBefore, expectedDelta, "Pool B index correct");
        
        // Pool B should not have inherited Pool A's remainder
        assertEq(poolBRemainder, 0, "Pool B has no remainder from Pool A");
    }

    /// @notice Test multiple pools with different remainder patterns
    function test_MultiplePoolsIndependentRemainders() public {
        uint256 POOL_C = 3;
        harness.initPool(POOL_C, address(token));
        
        // Setup three pools with different characteristics
        harness.setTotalDeposits(POOL_A, 3 ether);
        harness.setTotalDeposits(POOL_B, 7 ether);
        harness.setTotalDeposits(POOL_C, 11 ether);
        
        // Accrue fees that create different remainders
        harness.accrueFee(POOL_A, 1);
        harness.accrueFee(POOL_B, 2);
        harness.accrueFee(POOL_C, 3);
        
        uint256 remainderA = harness.getFeeIndexRemainder(POOL_A);
        uint256 remainderB = harness.getFeeIndexRemainder(POOL_B);
        uint256 remainderC = harness.getFeeIndexRemainder(POOL_C);
        
        // All should have their own remainders
        assertTrue(remainderA != remainderB || remainderA == 0, "A and B different");
        assertTrue(remainderB != remainderC || remainderB == 0, "B and C different");
        assertTrue(remainderA != remainderC || remainderA == 0, "A and C different");
        
        // Accrue more in Pool B
        harness.accrueFee(POOL_B, 5);
        
        // Pool A and C remainders should be unchanged
        assertEq(harness.getFeeIndexRemainder(POOL_A), remainderA, "Pool A unchanged");
        assertEq(harness.getFeeIndexRemainder(POOL_C), remainderC, "Pool C unchanged");
    }

    /// @notice Test that remainder accumulation works correctly per pool
    function test_RemainderAccumulationPerPool() public {
        harness.setTotalDeposits(POOL_A, 1_000_000 ether);
        harness.setTotalDeposits(POOL_B, 1_000_000 ether);
        
        // Accrue many small fees in Pool A
        for (uint256 i = 0; i < 10; i++) {
            harness.accrueFee(POOL_A, 1);
        }
        
        uint256 poolARemainder = harness.getFeeIndexRemainder(POOL_A);
        uint256 poolBRemainder = harness.getFeeIndexRemainder(POOL_B);
        
        // Pool A accumulated remainder, Pool B has none
        assertGt(poolARemainder, 0, "Pool A accumulated remainder");
        assertEq(poolBRemainder, 0, "Pool B has no remainder");
        
        // Now accrue in Pool B
        for (uint256 i = 0; i < 5; i++) {
            harness.accrueFee(POOL_B, 1);
        }
        
        uint256 poolBRemainderAfter = harness.getFeeIndexRemainder(POOL_B);
        
        // Pool B has its own accumulated remainder
        assertGt(poolBRemainderAfter, 0, "Pool B accumulated its own remainder");
        
        // Pool A's remainder is still the same
        assertEq(harness.getFeeIndexRemainder(POOL_A), poolARemainder, "Pool A remainder preserved");
    }
}

contract RemainderHarness {
    function s() internal pure returns (LibAppStorage.AppStorage storage) {
        return LibAppStorage.s();
    }

    function initPool(uint256 pid, address token) external {
        Types.PoolData storage p = s().pools[pid];
        p.underlying = token;
        p.initialized = true;
    }

    function setFoundationReceiver(address receiver) external {
        s().foundationReceiver = receiver;
    }

    function setTotalDeposits(uint256 pid, uint256 amount) external {
        s().pools[pid].totalDeposits = amount;
        s().pools[pid].trackedBalance = amount; // Initialize tracked balance
    }

    function setMaintenanceRate(uint256 pid, uint16 rateBps) external {
        s().pools[pid].poolConfig.maintenanceRateBps = rateBps;
    }

    function accrueFee(uint256 pid, uint256 amount) external {
        s().pools[pid].trackedBalance += amount;
        LibFeeIndex.accrueWithSource(pid, amount, bytes32("test"));
    }

    function enforceMaintenance(uint256 pid) external {
        LibMaintenance.enforce(pid);
    }

    function getFeeIndex(uint256 pid) external view returns (uint256) {
        return s().pools[pid].feeIndex;
    }

    function getFeeIndexRemainder(uint256 pid) external view returns (uint256) {
        return s().pools[pid].feeIndexRemainder;
    }

    function getMaintenanceRemainder(uint256 pid) external view returns (uint256) {
        return s().pools[pid].maintenanceIndexRemainder;
    }
}
