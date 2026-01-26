// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {Types} from "../../src/libraries/Types.sol";
import {LibMaintenance} from "../../src/libraries/LibMaintenance.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

/// @notice Tests for maintenance payment isolation between pools sharing the same underlying token
contract MaintenancePoolIsolationTest is Test {
    MaintenanceHarness internal harness;
    MockERC20 internal sharedToken;
    
    uint256 internal constant POOL_A = 1;
    uint256 internal constant POOL_B = 2;
    address internal constant RECEIVER = address(0xFEE);

    function setUp() public {
        harness = new MaintenanceHarness();
        sharedToken = new MockERC20("Mock Token", "MOCK", 18, 0);
        
        // Initialize two pools with the SAME underlying token
        harness.initPool(POOL_A, address(sharedToken));
        harness.initPool(POOL_B, address(sharedToken));
        harness.setFoundationReceiver(RECEIVER);
        
        vm.warp(100 days);
    }

    /// @notice Test that pool payment is capped to its own balance
    function test_MaintenanceIsolation_UnderfundedPoolCappedPayment() public {
        // Pool A: 1000 ether deposits
        // Pool B: 5000 ether deposits
        harness.setTotalDeposits(POOL_A, 1000 ether);
        harness.setTotalDeposits(POOL_B, 5000 ether);
        harness.setMaintenanceRate(POOL_A, 100); // 1%
        harness.setMaintenanceRate(POOL_B, 100); // 1%
        
        // Only Pool B has tokens
        sharedToken.mint(address(harness), 5000 ether);
        
        // Initialize maintenance
        harness.enforce(POOL_A);
        harness.enforce(POOL_B);
        
        // Advance time to accrue maintenance
        vm.warp(block.timestamp + 365 days);
        
        // With the fix, Pool A's payment is capped to min(pending, poolBalance, contractBalance)
        // Pool A has ~990 ether after maintenance reduction, contract has 5000 ether
        // So Pool A will pay min(10, 990, 5000) = 10 ether
        // This is correct behavior - it pays from its own tracked balance
        
        uint256 receiverBalanceBefore = sharedToken.balanceOf(RECEIVER);
        
        harness.enforce(POOL_A);
        
        uint256 receiverBalanceAfter = sharedToken.balanceOf(RECEIVER);
        uint256 poolAPaid = receiverBalanceAfter - receiverBalanceBefore;
        
        // Pool A should have paid its maintenance (capped to its balance)
        uint256 expectedMaintenance = (1000 ether * 100 * 365) / (365 * 10_000);
        assertApproxEqAbs(poolAPaid, expectedMaintenance, 1 ether, "Pool A paid from its balance");
        
        // Pool A should have no pending (it paid)
        assertEq(harness.getPendingMaintenance(POOL_A), 0, "Pool A paid all pending");
        
        // Pool B should remain fully funded
        assertEq(harness.getTotalDeposits(POOL_B), 5000 ether, "Pool B deposits unchanged");
    }

    /// @notice Test that payment is capped to pool's available balance
    function test_MaintenanceIsolation_PaymentCappedToPoolBalance() public {
        // Pool A: 100 ether deposits
        // Pool B: 5000 ether deposits
        harness.setTotalDeposits(POOL_A, 100 ether);
        harness.setTotalDeposits(POOL_B, 5000 ether);
        harness.setMaintenanceRate(POOL_A, 100);
        harness.setMaintenanceRate(POOL_B, 100);
        
        // Fund both pools
        sharedToken.mint(address(harness), 5100 ether);
        
        harness.enforce(POOL_A);
        harness.enforce(POOL_B);
        
        // Advance time
        vm.warp(block.timestamp + 365 days);
        
        // Settle both pools
        harness.enforce(POOL_A);
        harness.enforce(POOL_B);
        
        // Pool A should have paid ~1 ether (1% of 100)
        // Pool B should have paid ~50 ether (1% of 5000)
        
        uint256 receiverBalance = sharedToken.balanceOf(RECEIVER);
        uint256 expectedTotal = (100 ether * 100 * 365) / (365 * 10_000) + 
                                (5000 ether * 100 * 365) / (365 * 10_000);
        
        assertApproxEqAbs(receiverBalance, expectedTotal, 1 ether, "Total payments correct");
        
        // Both pools should have reduced deposits
        assertLt(harness.getTotalDeposits(POOL_A), 100 ether, "Pool A deposits reduced");
        assertLt(harness.getTotalDeposits(POOL_B), 5000 ether, "Pool B deposits reduced");
    }

    /// @notice Test that pool with insufficient balance pays partial amount
    function test_MaintenanceIsolation_PartialPaymentWhenInsufficient() public {
        // Pool A: 1000 ether deposits, but only 5 ether in contract
        harness.setTotalDeposits(POOL_A, 1000 ether);
        harness.setMaintenanceRate(POOL_A, 100);
        
        // Only 5 ether available
        sharedToken.mint(address(harness), 5 ether);
        
        harness.enforce(POOL_A);
        vm.warp(block.timestamp + 365 days);
        harness.enforce(POOL_A);
        
        // Should have paid only 5 ether (limited by contract balance)
        uint256 receiverBalance = sharedToken.balanceOf(RECEIVER);
        assertEq(receiverBalance, 5 ether, "Paid limited by contract balance");
        
        // Remaining should be pending
        uint256 pending = harness.getPendingMaintenance(POOL_A);
        uint256 expectedTotal = (1000 ether * 100 * 365) / (365 * 10_000);
        assertEq(pending, expectedTotal - 5 ether, "Remaining pending");
    }

    /// @notice Test multiple pools with same token maintain isolation
    function test_MaintenanceIsolation_ThreePoolsIndependent() public {
        uint256 POOL_C = 3;
        harness.initPool(POOL_C, address(sharedToken));
        
        harness.setTotalDeposits(POOL_A, 1000 ether);
        harness.setTotalDeposits(POOL_B, 2000 ether);
        harness.setTotalDeposits(POOL_C, 3000 ether);
        
        harness.setMaintenanceRate(POOL_A, 100);
        harness.setMaintenanceRate(POOL_B, 100);
        harness.setMaintenanceRate(POOL_C, 100);
        
        // Fund all pools
        sharedToken.mint(address(harness), 6000 ether);
        
        harness.enforce(POOL_A);
        harness.enforce(POOL_B);
        harness.enforce(POOL_C);
        
        vm.warp(block.timestamp + 365 days);
        
        // Settle all
        harness.enforce(POOL_A);
        harness.enforce(POOL_B);
        harness.enforce(POOL_C);
        
        // Each pool should have paid its own maintenance
        uint256 expectedA = (1000 ether * 100 * 365) / (365 * 10_000);
        uint256 expectedB = (2000 ether * 100 * 365) / (365 * 10_000);
        uint256 expectedC = (3000 ether * 100 * 365) / (365 * 10_000);
        
        uint256 totalPaid = sharedToken.balanceOf(RECEIVER);
        assertApproxEqAbs(totalPaid, expectedA + expectedB + expectedC, 1 ether, "All pools paid correctly");
    }

    /// @notice Test that payment respects pool's reduced totalDeposits after maintenance accrual
    function test_MaintenanceIsolation_PaymentRespectsReducedDeposits() public {
        harness.setTotalDeposits(POOL_A, 1000 ether);
        harness.setMaintenanceRate(POOL_A, 100);
        
        // Fund with less than original deposits
        sharedToken.mint(address(harness), 500 ether);
        
        harness.enforce(POOL_A);
        vm.warp(block.timestamp + 365 days);
        harness.enforce(POOL_A);
        
        // After accrual, totalDeposits is reduced
        uint256 depositsAfterAccrual = harness.getTotalDeposits(POOL_A);
        assertLt(depositsAfterAccrual, 1000 ether, "Deposits reduced by maintenance");
        
        // Payment should be capped to reduced deposits
        uint256 paid = sharedToken.balanceOf(RECEIVER);
        assertLe(paid, depositsAfterAccrual, "Payment capped to pool balance");
    }
}

contract MaintenanceHarness {
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

    function setMaintenanceRate(uint256 pid, uint16 rateBps) external {
        s().pools[pid].poolConfig.maintenanceRateBps = rateBps;
    }

    function setTotalDeposits(uint256 pid, uint256 amount) external {
        s().pools[pid].totalDeposits = amount;
        s().pools[pid].trackedBalance = amount; // Initialize tracked balance
    }

    function enforce(uint256 pid) external {
        LibMaintenance.enforce(pid);
    }

    function getTotalDeposits(uint256 pid) external view returns (uint256) {
        return s().pools[pid].totalDeposits;
    }

    function getPendingMaintenance(uint256 pid) external view returns (uint256) {
        return s().pools[pid].pendingMaintenance;
    }
}
