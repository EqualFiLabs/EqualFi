// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {LibMaintenance} from "../../src/libraries/LibMaintenance.sol";
import {Types} from "../../src/libraries/Types.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

/// @notice Simplified harness for cross-system testing
contract CrossSystemHarness {
    function s() internal pure returns (LibAppStorage.AppStorage storage) {
        return LibAppStorage.s();
    }

    function initPool(uint256 pid, address underlying) external {
        Types.PoolData storage p = s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.poolConfig.maintenanceRateBps = 100; // 1% annual
        p.lastMaintenanceTimestamp = uint64(block.timestamp);
        p.feeIndex = 1e18;
    }

    function setFoundationReceiver(address receiver) external {
        s().foundationReceiver = receiver;
    }

    function addDepositor(uint256 pid, bytes32 user, uint256 principal) external {
        Types.PoolData storage p = s().pools[pid];
        p.userPrincipal[user] = principal;
        p.userFeeIndex[user] = p.feeIndex;
        p.userMaintenanceIndex[user] = p.maintenanceIndex;
        p.totalDeposits += principal;
        p.trackedBalance += principal;
    }

    function accrueFee(uint256 pid, uint256 amount) external {
        s().pools[pid].trackedBalance += amount;
        LibFeeIndex.accrueWithSource(pid, amount, bytes32("test"));
    }

    function applyMaintenance(uint256 pid) external {
        LibMaintenance.enforce(pid);
    }

    function settleUser(uint256 pid, bytes32 user) external {
        LibFeeIndex.settle(pid, user);
    }

    function getUserPrincipal(uint256 pid, bytes32 user) external view returns (uint256) {
        return s().pools[pid].userPrincipal[user];
    }

    function getUserAccruedYield(uint256 pid, bytes32 user) external view returns (uint256) {
        return s().pools[pid].userAccruedYield[user];
    }

    function getFeeIndex(uint256 pid) external view returns (uint256) {
        return s().pools[pid].feeIndex;
    }

    function getMaintenanceIndex(uint256 pid) external view returns (uint256) {
        return s().pools[pid].maintenanceIndex;
    }

    function getTotalDeposits(uint256 pid) external view returns (uint256) {
        return s().pools[pid].totalDeposits;
    }

    function getPendingYield(uint256 pid, bytes32 user) external view returns (uint256) {
        return LibFeeIndex.pendingYield(pid, user);
    }
}

/// @notice Tests interaction between FeeIndex and MaintenanceIndex
contract FeeIndexCrossSystemTest is Test {
    CrossSystemHarness internal harness;
    MockERC20 internal token;

    uint256 internal constant PID = 1;
    bytes32 internal constant USER_A = keccak256("USER_A");
    bytes32 internal constant USER_B = keccak256("USER_B");
    address internal constant FOUNDATION = address(0xFEE);

    function setUp() public {
        harness = new CrossSystemHarness();
        token = new MockERC20("Mock Token", "MOCK", 18, 0);

        harness.initPool(PID, address(token));
        harness.setFoundationReceiver(FOUNDATION);

        token.mint(address(harness), 1_000 ether); // For maintenance payments

        vm.warp(365 days);
    }

    /// @notice Test that positive yield and negative maintenance work together
    function testPositiveYieldAndNegativeMaintenance() public {
        // User A deposits
        harness.addDepositor(PID, USER_A, 1000 ether);

        // Accrue positive yield (fees)
        harness.accrueFee(PID, 100 ether);

        uint256 feeIndexAfter = harness.getFeeIndex(PID);
        assertGt(feeIndexAfter, 1e18);

        // Apply maintenance (negative yield)
        vm.warp(block.timestamp + 365 days);
        harness.applyMaintenance(PID);

        uint256 maintenanceIndex = harness.getMaintenanceIndex(PID);
        assertGt(maintenanceIndex, 0);

        // Settle user
        harness.settleUser(PID, USER_A);

        // User should have reduced principal but positive yield
        uint256 principal = harness.getUserPrincipal(PID, USER_A);
        uint256 yield = harness.getUserAccruedYield(PID, USER_A);

        assertLt(principal, 1000 ether); // Reduced by maintenance
        assertGt(yield, 0); // Has positive yield from fees

        // Net value should be positive (yield > maintenance)
        assertGt(principal + yield, 1000 ether);
    }

    /// @notice Test that maintenance doesn't affect fee index
    function testMaintenanceDoesNotAffectFeeIndex() public {
        harness.addDepositor(PID, USER_A, 1000 ether);

        // Accrue fees
        harness.accrueFee(PID, 50 ether);
        uint256 feeIndexBefore = harness.getFeeIndex(PID);

        // Apply maintenance
        vm.warp(block.timestamp + 365 days);
        harness.applyMaintenance(PID);

        // Fee index should be unchanged
        uint256 feeIndexAfter = harness.getFeeIndex(PID);
        assertEq(feeIndexAfter, feeIndexBefore);

        // But maintenance index should have increased
        assertGt(harness.getMaintenanceIndex(PID), 0);
    }

    /// @notice Test multiple users with different join times
    function testMultipleUsersStaggeredJoins() public {
        // User A joins first
        harness.addDepositor(PID, USER_A, 1000 ether);

        // Generate fees
        harness.accrueFee(PID, 50 ether);

        // User B joins after fees
        harness.addDepositor(PID, USER_B, 1000 ether);

        // Apply maintenance
        vm.warp(block.timestamp + 365 days);
        harness.applyMaintenance(PID);

        // Settle both
        harness.settleUser(PID, USER_A);
        harness.settleUser(PID, USER_B);

        // User A should have yield from first fee round
        uint256 yieldA = harness.getUserAccruedYield(PID, USER_A);
        uint256 yieldB = harness.getUserAccruedYield(PID, USER_B);

        assertGt(yieldA, yieldB); // A got fees before B joined

        // Both should have reduced principal from maintenance
        assertLt(harness.getUserPrincipal(PID, USER_A), 1000 ether);
        assertLt(harness.getUserPrincipal(PID, USER_B), 1000 ether);
    }

    /// @notice Test extreme time periods
    function testExtremeLongPeriod() public {
        harness.addDepositor(PID, USER_A, 1000 ether);

        // Accrue fees
        harness.accrueFee(PID, 100 ether);

        // Wait 10 years
        vm.warp(block.timestamp + 3650 days);
        harness.applyMaintenance(PID);

        // Settle user first
        harness.settleUser(PID, USER_A);

        // User should still have some principal
        uint256 principal = harness.getUserPrincipal(PID, USER_A);
        assertGt(principal, 0);
        assertLt(principal, 1000 ether);

        // Should still have yield
        uint256 yield = harness.getPendingYield(PID, USER_A);
        assertGt(yield, 0);
    }

    /// @notice Test that fee index grows monotonically despite maintenance
    function testFeeIndexMonotonicDespiteMaintenance() public {
        harness.addDepositor(PID, USER_A, 1000 ether);

        uint256 previousFeeIndex = harness.getFeeIndex(PID);

        for (uint256 i = 0; i < 10; i++) {
            // Accrue fees
            harness.accrueFee(PID, 10 ether);

            // Apply maintenance
            vm.warp(block.timestamp + 365 days);
            harness.applyMaintenance(PID);

            // Fee index should never decrease
            uint256 currentFeeIndex = harness.getFeeIndex(PID);
            assertGe(currentFeeIndex, previousFeeIndex);
            previousFeeIndex = currentFeeIndex;
        }
    }
}
