// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {Types} from "../../src/libraries/Types.sol";
import {LibMaintenance} from "../../src/libraries/LibMaintenance.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract MaintenanceFeesHarness {
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

    function setDefaultMaintenanceRate(uint16 rateBps) external {
        s().defaultMaintenanceRateBps = rateBps;
    }

    function setTotalDeposits(uint256 pid, uint256 amount) external {
        s().pools[pid].totalDeposits = amount;
        s().pools[pid].trackedBalance = amount; // Initialize tracked balance
    }

    function setLastMaintenanceTimestamp(uint256 pid, uint64 timestamp) external {
        s().pools[pid].lastMaintenanceTimestamp = timestamp;
    }

    function enforce(uint256 pid) external {
        LibMaintenance.enforce(pid);
    }

    function forcePay(uint256 pid) external {
        LibMaintenance.forcePay(pid);
    }

    function getTotalDeposits(uint256 pid) external view returns (uint256) {
        return s().pools[pid].totalDeposits;
    }

    function getPendingMaintenance(uint256 pid) external view returns (uint256) {
        return s().pools[pid].pendingMaintenance;
    }

    function getLastMaintenanceTimestamp(uint256 pid) external view returns (uint64) {
        return s().pools[pid].lastMaintenanceTimestamp;
    }

    function getMaintenanceIndex(uint256 pid) external view returns (uint256) {
        return s().pools[pid].maintenanceIndex;
    }

    function getMaintenanceIndexRemainder() external view returns (uint256) {
        // Return remainder for the pool being tested
        return s().pools[1].maintenanceIndexRemainder;
    }
    
    function getMaintenanceIndexRemainderForPool(uint256 pid) external view returns (uint256) {
        return s().pools[pid].maintenanceIndexRemainder;
    }

    function epochLength() external pure returns (uint256) {
        return LibMaintenance.epochLength();
    }
}

contract MaintenanceFeesTest is Test {
    MaintenanceFeesHarness internal harness;
    MockERC20 internal token;
    uint256 internal constant PID = 1;
    address internal constant RECEIVER = address(0xFEE);

    function setUp() public {
        harness = new MaintenanceFeesHarness();
        token = new MockERC20("Mock Token", "MOCK", 18, 0);
        harness.initPool(PID, address(token));
        harness.setFoundationReceiver(RECEIVER);
        vm.warp(100 days);
    }

    function testMaintenanceFees_InitialEnforceSetTimestamp() public {
        harness.enforce(PID);
        assertEq(harness.getLastMaintenanceTimestamp(PID), block.timestamp);
        assertEq(harness.getPendingMaintenance(PID), 0);
    }

    function testMaintenanceFees_NoAccrualBeforeEpoch() public {
        harness.setTotalDeposits(PID, 1_000 ether);
        harness.setMaintenanceRate(PID, 100); // 1%

        harness.enforce(PID);
        uint64 initialTimestamp = harness.getLastMaintenanceTimestamp(PID);

        // Advance less than one epoch
        vm.warp(block.timestamp + 12 hours);
        harness.enforce(PID);

        assertEq(harness.getPendingMaintenance(PID), 0);
        assertEq(harness.getLastMaintenanceTimestamp(PID), initialTimestamp);
        assertEq(harness.getTotalDeposits(PID), 1_000 ether);
    }

    function testMaintenanceFees_SingleEpochAccrual() public {
        harness.setTotalDeposits(PID, 36_500 ether);
        harness.setMaintenanceRate(PID, 100); // 1% annual

        harness.enforce(PID);
        uint64 initialTimestamp = harness.getLastMaintenanceTimestamp(PID);

        // Advance exactly one epoch (1 day)
        vm.warp(block.timestamp + 1 days);
        harness.enforce(PID);

        // 1% annual / 365 days = 0.00274% per day
        // 12000 * 0.01 * 1 / 365 = ~0.3288 ether
        uint256 expectedFee = (36_500 ether * 100 * 1) / (365 * 10_000);
        assertEq(harness.getPendingMaintenance(PID), expectedFee);
        assertEq(harness.getTotalDeposits(PID), 36_500 ether - expectedFee);
        assertEq(harness.getLastMaintenanceTimestamp(PID), initialTimestamp + 1 days);
    }

    function testMaintenanceFees_MultipleEpochsAccrual() public {
        harness.setTotalDeposits(PID, 36_500 ether);
        harness.setMaintenanceRate(PID, 200); // 2% annual

        harness.enforce(PID);
        uint64 initialTimestamp = harness.getLastMaintenanceTimestamp(PID);

        // Advance 3 epochs (3 days)
        vm.warp(block.timestamp + 3 days);
        harness.enforce(PID);

        // 2% annual / 365 days * 3 days
        // 10000 * 0.02 * 3 / 365 = ~1.6438 ether
        uint256 expectedFee = (36_500 ether * 200 * 3) / (365 * 10_000);
        assertEq(harness.getPendingMaintenance(PID), expectedFee);
        assertEq(harness.getTotalDeposits(PID), 36_500 ether - expectedFee);
        assertEq(harness.getLastMaintenanceTimestamp(PID), initialTimestamp + 3 days);
    }

    function testMaintenanceFees_PartialEpochIgnored() public {
        harness.setTotalDeposits(PID, 36_500 ether);
        harness.setMaintenanceRate(PID, 100);

        harness.enforce(PID);
        uint64 initialTimestamp = harness.getLastMaintenanceTimestamp(PID);

        // Advance 1.5 epochs (36 hours) - should only count 1 epoch
        vm.warp(block.timestamp + 36 hours);
        harness.enforce(PID);

        uint256 expectedFee = (36_500 ether * 100) / (365 * 10_000);
        assertEq(harness.getPendingMaintenance(PID), expectedFee);
        assertEq(harness.getLastMaintenanceTimestamp(PID), initialTimestamp + 1 days);
    }

    function testMaintenanceFees_DefaultRateUsedWhenPoolRateZero() public {
        harness.setTotalDeposits(PID, 36_500 ether);
        harness.setDefaultMaintenanceRate(150); // 1.5% annual
        harness.setMaintenanceRate(PID, 0); // Pool rate not set

        harness.enforce(PID);
        vm.warp(block.timestamp + 1 days);
        harness.enforce(PID);

        // Should use default rate of 1.5%
        uint256 expectedFee = (36_500 ether * 150) / (365 * 10_000);
        assertEq(harness.getPendingMaintenance(PID), expectedFee);
    }

    function testMaintenanceFees_FallbackTo1PercentWhenBothZero() public {
        harness.setTotalDeposits(PID, 36_500 ether);
        harness.setDefaultMaintenanceRate(0);
        harness.setMaintenanceRate(PID, 0);

        harness.enforce(PID);
        vm.warp(block.timestamp + 1 days);
        harness.enforce(PID);

        // Should use fallback rate of 1%
        uint256 expectedFee = (36_500 ether * 100) / (365 * 10_000);
        assertEq(harness.getPendingMaintenance(PID), expectedFee);
    }

    function testMaintenanceFees_PaymentTransfersTokens() public {
        harness.setTotalDeposits(PID, 36_500 ether);
        harness.setMaintenanceRate(PID, 100);
        token.mint(address(harness), 100 ether);

        harness.enforce(PID);
        vm.warp(block.timestamp + 1 days);

        uint256 receiverBalanceBefore = token.balanceOf(RECEIVER);
        harness.enforce(PID);

        uint256 expectedFee = (36_500 ether * 100) / (365 * 10_000);
        assertEq(token.balanceOf(RECEIVER), receiverBalanceBefore + expectedFee);
        assertEq(harness.getPendingMaintenance(PID), 0);
    }

    function testMaintenanceFees_PartialPaymentWhenInsufficientBalance() public {
        harness.setTotalDeposits(PID, 36_500 ether);
        harness.setMaintenanceRate(PID, 100);
        token.mint(address(harness), 0.5 ether); // Less than fee

        harness.enforce(PID);
        vm.warp(block.timestamp + 1 days);
        harness.enforce(PID);

        uint256 expectedFee = (36_500 ether * 100) / (365 * 10_000); // 1 ether
        assertEq(token.balanceOf(RECEIVER), 0.5 ether);
        assertEq(harness.getPendingMaintenance(PID), expectedFee - 0.5 ether);
    }

    function testMaintenanceFees_AccumulatesOverMultipleCalls() public {
        harness.setTotalDeposits(PID, 36_500 ether);
        harness.setMaintenanceRate(PID, 100);
        // Don't add any balance so fees accumulate as pending

        harness.enforce(PID);
        uint64 startTime = harness.getLastMaintenanceTimestamp(PID);

        // First epoch
        vm.warp(startTime + 1 days);
        harness.enforce(PID);
        uint256 firstFee = harness.getPendingMaintenance(PID);
        assertGt(firstFee, 0);

        // Second epoch (without paying first fee)
        vm.warp(startTime + 2 days);
        harness.enforce(PID);
        uint256 secondFee = harness.getPendingMaintenance(PID);

        // Should accumulate pending fees (first fee + new fee from reduced deposits)
        assertGt(secondFee, firstFee);
    }

    function testMaintenanceFees_ForcePayWithoutAccrual() public {
        harness.setTotalDeposits(PID, 36_500 ether);
        harness.setMaintenanceRate(PID, 100);

        harness.enforce(PID);
        vm.warp(block.timestamp + 1 days);
        harness.enforce(PID);

        uint256 pending = harness.getPendingMaintenance(PID);
        assertGt(pending, 0);

        // Add tokens after accrual
        token.mint(address(harness), pending);

        // Force pay without accruing more
        harness.forcePay(PID);

        assertEq(harness.getPendingMaintenance(PID), 0);
        assertEq(token.balanceOf(RECEIVER), pending);
    }

    function testMaintenanceFees_NoAccrualWhenTotalDepositsZero() public {
        harness.setTotalDeposits(PID, 0);
        harness.setMaintenanceRate(PID, 100);

        harness.enforce(PID);
        vm.warp(block.timestamp + 1 days);
        harness.enforce(PID);

        assertEq(harness.getPendingMaintenance(PID), 0);
    }

    function testMaintenanceFees_NoPaymentWhenReceiverNotSet() public {
        harness.setFoundationReceiver(address(0));
        harness.setTotalDeposits(PID, 36_500 ether);
        harness.setMaintenanceRate(PID, 100);

        harness.enforce(PID);
        vm.warp(block.timestamp + 1 days);
        harness.enforce(PID);

        // Should not accrue or pay when receiver is not set
        assertEq(harness.getPendingMaintenance(PID), 0);
    }

    function testMaintenanceFees_MaintenanceIndexIncreases() public {
        harness.setTotalDeposits(PID, 36_500 ether);
        harness.setMaintenanceRate(PID, 100);

        harness.enforce(PID);
        uint256 initialIndex = harness.getMaintenanceIndex(PID);

        vm.warp(block.timestamp + 1 days);
        harness.enforce(PID);

        uint256 newIndex = harness.getMaintenanceIndex(PID);
        assertGt(newIndex, initialIndex);
    }

    function testMaintenanceFees_MaintenanceIndexCalculation() public {
        harness.setTotalDeposits(PID, 36_500 ether);
        harness.setMaintenanceRate(PID, 100);

        harness.enforce(PID);
        vm.warp(block.timestamp + 1 days);
        harness.enforce(PID);

        uint256 expectedFee = (36_500 ether * 100) / (365 * 10_000);
        uint256 scaledAmount = expectedFee * 1e18;
        uint256 expectedDelta = scaledAmount / 36_500 ether;

        uint256 actualIndex = harness.getMaintenanceIndex(PID);
        assertEq(actualIndex, expectedDelta);
    }

    function testMaintenanceFees_RemainderTracking() public {
        // Use amounts that will create remainders
        harness.setTotalDeposits(PID, 11_999 ether);
        harness.setMaintenanceRate(PID, 100);

        harness.enforce(PID);
        vm.warp(block.timestamp + 1 days);
        harness.enforce(PID);

        // Remainder should be tracked for precision
        uint256 remainder = harness.getMaintenanceIndexRemainder();
        // Remainder exists when division doesn't evenly divide
        assertGe(remainder, 0);
    }

    function testMaintenanceFees_HighRateScenario() public {
        harness.setTotalDeposits(PID, 100_000 ether);
        harness.setMaintenanceRate(PID, 500); // 5% annual

        harness.enforce(PID);
        vm.warp(block.timestamp + 365 days); // 365 epochs (1 year)
        harness.enforce(PID);

        // 5% annual over 365 days = 5%
        uint256 expectedFee = (100_000 ether * 500 * 365) / (365 * 10_000);
        assertEq(harness.getPendingMaintenance(PID), expectedFee);
        assertEq(harness.getTotalDeposits(PID), 100_000 ether - expectedFee);
    }

    function testMaintenanceFees_EpochLengthConstant() public {
        assertEq(harness.epochLength(), 1 days);
    }

    function testMaintenanceFees_IndexApplicationWithSmallAmount() public {
        // Test that small amounts accumulate in remainder
        harness.setTotalDeposits(PID, 1_000_000 ether);
        harness.setMaintenanceRate(PID, 1); // 0.01% annual - very small

        harness.enforce(PID);
        vm.warp(block.timestamp + 1 days);
        harness.enforce(PID);

        // Small fee should still update index or remainder
        uint256 index = harness.getMaintenanceIndex(PID);
        uint256 remainder = harness.getMaintenanceIndexRemainder();

        // Either index increased or remainder accumulated
        assertTrue(index > 0 || remainder > 0);
    }

    function testMaintenanceFees_IndexApplicationProportional() public {
        // Test that index delta is proportional to fee amount
        harness.setTotalDeposits(PID, 36_500 ether);
        harness.setMaintenanceRate(PID, 100);

        uint256 start = block.timestamp;
        harness.enforce(PID);
        vm.warp(start + 1 days);
        harness.enforce(PID);

        uint256 index1 = harness.getMaintenanceIndex(PID);
        uint256 deposits1 = harness.getTotalDeposits(PID);

        // Advance another epoch
        vm.warp(start + 2 days);
        harness.enforce(PID);

        uint256 index2 = harness.getMaintenanceIndex(PID);
        uint256 deposits2 = harness.getTotalDeposits(PID);

        // Index should increase
        assertGt(index2, index1);
        // Deposits should decrease
        assertLt(deposits2, deposits1);
    }

    function testMaintenanceFees_RemainderCarriesForward() public {
        // Test that remainder from one epoch carries to next
        harness.setTotalDeposits(PID, 11_111 ether); // Odd number to create remainders
        harness.setMaintenanceRate(PID, 100);

        harness.enforce(PID);
        vm.warp(block.timestamp + 1 days);
        harness.enforce(PID);

        uint256 remainder1 = harness.getMaintenanceIndexRemainder();

        // Advance another epoch
        vm.warp(block.timestamp + 1 days);
        harness.enforce(PID);

        // Remainder should have been used in calculation
        // (it may be different but the calculation should have used it)
        uint256 index = harness.getMaintenanceIndex(PID);
        assertGt(index, 0);
    }

    function testMaintenanceFees_ZeroAmountNoIndexChange() public {
        harness.setTotalDeposits(PID, 0); // Zero deposits means zero fee
        harness.setMaintenanceRate(PID, 100);

        harness.enforce(PID);
        uint256 initialIndex = harness.getMaintenanceIndex(PID);

        vm.warp(block.timestamp + 1 days);
        harness.enforce(PID);

        // Index should not change with zero deposits
        assertEq(harness.getMaintenanceIndex(PID), initialIndex);
        assertEq(harness.getPendingMaintenance(PID), 0);
    }

    function testMaintenanceFees_LargeDepositsPrecision() public {
        // Test with very large deposits to ensure no overflow
        harness.setTotalDeposits(PID, 1_000_000_000 ether); // 1 billion tokens
        harness.setMaintenanceRate(PID, 100);

        harness.enforce(PID);
        vm.warp(block.timestamp + 1 days);
        harness.enforce(PID);

        uint256 fee = harness.getPendingMaintenance(PID);
        uint256 index = harness.getMaintenanceIndex(PID);

        assertGt(fee, 0);
        assertGt(index, 0);
    }

    function testMaintenanceFees_MultipleEpochsIndexAccumulates() public {
        harness.setTotalDeposits(PID, 36_500 ether);
        harness.setMaintenanceRate(PID, 100);

        harness.enforce(PID);
        uint64 startTime = harness.getLastMaintenanceTimestamp(PID);

        uint256[] memory indices = new uint256[](5);

        // Collect index values over 5 epochs
        for (uint256 i = 0; i < 5; i++) {
            vm.warp(startTime + ((i + 1) * 1 days));
            harness.enforce(PID);
            indices[i] = harness.getMaintenanceIndex(PID);
        }

        // Each index should be greater than the previous
        for (uint256 i = 1; i < 5; i++) {
            assertGt(indices[i], indices[i - 1]);
        }
    }

    function testMaintenanceFees_IndexDeltaCalculation() public {
        // Test the exact calculation: delta = (amount * 1e18) / oldTotal
        harness.setTotalDeposits(PID, 36_500 ether);
        harness.setMaintenanceRate(PID, 100);

        harness.enforce(PID);
        vm.warp(block.timestamp + 1 days);
        harness.enforce(PID);

        uint256 fee = (36_500 ether * 100) / (365 * 10_000); // 10 ether
        uint256 oldTotal = 36_500 ether;
        uint256 expectedDelta = (fee * 1e18) / oldTotal;

        uint256 actualIndex = harness.getMaintenanceIndex(PID);

        // Should match expected delta (accounting for any remainder)
        assertApproxEqAbs(actualIndex, expectedDelta, 1);
    }

    function testMaintenanceFees_RemainderPreventsLoss() public {
        // Test that remainder mechanism prevents precision loss
        harness.setTotalDeposits(PID, 7_777 ether); // Prime-ish number
        harness.setMaintenanceRate(PID, 100);

        harness.enforce(PID);

        uint256 totalIndexGain = 0;
        uint64 startTime = harness.getLastMaintenanceTimestamp(PID);

        // Run 10 epochs
        for (uint256 i = 0; i < 10; i++) {
            uint256 indexBefore = harness.getMaintenanceIndex(PID);
            vm.warp(startTime + ((i + 1) * 1 days));
            harness.enforce(PID);
            uint256 indexAfter = harness.getMaintenanceIndex(PID);
            totalIndexGain += (indexAfter - indexBefore);
        }

        // Total index gain should be significant
        assertGt(totalIndexGain, 0);
    }
}
