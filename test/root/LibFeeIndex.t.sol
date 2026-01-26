// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {Types} from "../../src/libraries/Types.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract LibFeeIndexHarness {
    function s() internal pure returns (LibAppStorage.AppStorage storage) {
        return LibAppStorage.s();
    }

    function setPool(uint256 pid, address underlying, uint256 totalDeposits) external {
        Types.PoolData storage p = s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.totalDeposits = totalDeposits;
        p.trackedBalance = totalDeposits;
    }

    function setUser(uint256 pid, bytes32 user, uint256 principal, uint256 userIndex, uint256 accrued) external {
        Types.PoolData storage p = s().pools[pid];
        p.userPrincipal[user] = principal;
        p.userFeeIndex[user] = userIndex;
        p.userAccruedYield[user] = accrued;
    }

    function setFeeIndex(uint256 pid, uint256 feeIndex) external {
        s().pools[pid].feeIndex = feeIndex;
    }

    function accrue(uint256 pid, uint256 amount, bytes32 source) external {
        s().pools[pid].trackedBalance += amount;
        LibFeeIndex.accrueWithSource(pid, amount, source);
    }

    function settle(uint256 pid, bytes32 user) external {
        LibFeeIndex.settle(pid, user);
    }

    function pending(uint256 pid, bytes32 user) external view returns (uint256) {
        return LibFeeIndex.pendingYield(pid, user);
    }

    function pool(uint256 pid) external view returns (uint256 totalDeposits, uint256 feeIndex) {
        Types.PoolData storage p = s().pools[pid];
        totalDeposits = p.totalDeposits;
        feeIndex = p.feeIndex;
    }

    function userState(uint256 pid, bytes32 user) external view returns (uint256 userIndex, uint256 accrued) {
        Types.PoolData storage p = s().pools[pid];
        userIndex = p.userFeeIndex[user];
        accrued = p.userAccruedYield[user];
    }

    function remainder() external view returns (uint256) {
        // Return remainder for pool 1 (default test pool)
        return s().pools[1].feeIndexRemainder;
    }
    
    function remainderForPool(uint256 pid) external view returns (uint256) {
        return s().pools[pid].feeIndexRemainder;
    }
}

contract LibFeeIndexTest is Test {
    LibFeeIndexHarness internal harness;
    uint256 internal constant PID = 1;
    bytes32 internal constant USER = keccak256("USER");
    uint256 internal constant SCALE = 1e18;

    function setUp() public {
        harness = new LibFeeIndexHarness();
        harness.setPool(PID, address(0xA11CE), 1_000 ether);
    }

    function testAccrueIncreasesIndex() public {
        vm.recordLogs();
        harness.accrue(PID, 100 ether, bytes32("repay"));
        (, uint256 feeIndex) = harness.pool(PID);
        assertGt(feeIndex, 0);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < entries.length; i++) {
            if (
                entries[i].topics.length > 0
                    && entries[i].topics[0] == keccak256("FeeIndexAccrued(uint256,uint256,uint256,uint256,bytes32)")
            ) {
                found = true;
            }
        }
        assertTrue(found, "FeeIndexAccrued not emitted");
    }

    function testAccrueNoDepositsNoop() public {
        harness.setPool(2, address(0xA11CE), 0);
        harness.accrue(2, 100 ether, bytes32("repay"));
        (, uint256 feeIndex) = harness.pool(2);
        assertEq(feeIndex, 0);
    }

    function testSettleAccruesYieldAndCheckpoints() public {
        harness.setFeeIndex(PID, 2e18); // global index
        harness.setUser(PID, USER, 100 ether, 1e18, 0);

        vm.recordLogs();
        harness.settle(PID, USER);

        // pending = 100 * (2e18 - 1e18) / 1e18 = 100
        (uint256 userIndex, uint256 accrued) = harness.userState(PID, USER);
        assertEq(accrued, 100 ether);
        assertEq(userIndex, 2e18);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < entries.length; i++) {
            if (
                entries[i].topics.length > 0
                    && entries[i].topics[0]
                        == keccak256("YieldSettled(uint256,bytes32,uint256,uint256,uint256,uint256)")
            ) {
                found = true;
            }
        }
        assertTrue(found, "YieldSettled not emitted");
    }

    function testPendingYieldIncludesAccruedAndUnsettled() public {
        harness.setFeeIndex(PID, 3e18);
        harness.setUser(PID, USER, 50 ether, 1e18, 5 ether);

        uint256 pending = harness.pending(PID, USER);
        // accrued 5 + pending (50 * (3-1) / 1e18) = 5 + 100 = 105
        assertEq(pending, 105 ether);
    }

    function testAccrueHandlesHugeDeposits() public {
        uint256 largeDeposits = type(uint192).max;
        harness.setPool(PID, address(0xAAAA), largeDeposits);
        uint256 amount = type(uint192).max - 1;
        harness.accrue(PID, amount, bytes32("huge"));
        (, uint256 feeIndex) = harness.pool(PID);
        uint256 expected = Math.mulDiv(amount, SCALE, largeDeposits);
        assertEq(feeIndex, expected);
    }

    function testAccrueAccumulatesRemainders() public {
        harness.setPool(PID, address(0xBBBB), 2 * SCALE);
        harness.accrue(PID, 1, bytes32("tiny"));
        (, uint256 feeIndexFirst) = harness.pool(PID);
        assertEq(feeIndexFirst, 0);
        assertEq(harness.remainder(), SCALE);

        harness.accrue(PID, 1, bytes32("tiny"));
        (, uint256 feeIndexSecond) = harness.pool(PID);
        assertEq(feeIndexSecond, 1);
        assertEq(harness.remainder(), 0);
    }

    function testFuzzAccrueMonotonic(uint256 totalDeposits, uint256 amount, uint256 initialIndex) public {
        // guard against division overflow in delta calculation
        vm.assume(totalDeposits > 0);
        vm.assume(totalDeposits <= type(uint256).max - amount);
        vm.assume(amount < type(uint256).max / SCALE);
        // keep indices in a safe range to avoid overflow when adding delta
        vm.assume(initialIndex < 1e38);

        harness.setPool(PID, address(0xBEEF), totalDeposits);
        harness.setFeeIndex(PID, initialIndex);

        uint256 expectedDelta = (amount * SCALE) / totalDeposits;
        vm.assume(initialIndex <= type(uint256).max - expectedDelta);

        harness.accrue(PID, amount, bytes32("fuzz"));

        (, uint256 feeIndex) = harness.pool(PID);
        assertGe(feeIndex, initialIndex);

        if (expectedDelta > 0) {
            assertEq(feeIndex, initialIndex + expectedDelta);
        } else {
            assertEq(feeIndex, initialIndex);
        }
    }

    function testFuzzSettleAccruesYieldAndUpdatesCheckpoint(
        uint256 principal,
        uint256 globalIndex,
        uint256 userIndex,
        uint256 startingAccrued
    ) public {
        vm.assume(globalIndex >= userIndex);
        vm.assume(globalIndex < 1e38 && userIndex < 1e38);
        vm.assume(principal < type(uint256).max / SCALE);
        vm.assume(globalIndex - userIndex < type(uint256).max / (principal == 0 ? 1 : principal));
        vm.assume(startingAccrued < 1e38);

        harness.setPool(PID, address(0xC0FFEE), 1_000 ether);
        harness.setFeeIndex(PID, globalIndex);
        harness.setUser(PID, USER, principal, userIndex, startingAccrued);

        harness.settle(PID, USER);

        (uint256 newUserIndex, uint256 accrued) = harness.userState(PID, USER);
        uint256 accruedDelta = (principal * (globalIndex - userIndex)) / SCALE;
        vm.assume(startingAccrued <= type(uint256).max - accruedDelta);
        uint256 expectedAccrued = startingAccrued + accruedDelta;
        assertEq(accrued, expectedAccrued);
        assertEq(newUserIndex, globalIndex);
    }

    function testFuzzSettleIdempotent(uint256 principal, uint256 globalIndex, uint256 userIndex) public {
        vm.assume(globalIndex >= userIndex);
        vm.assume(globalIndex < 1e38 && userIndex < 1e38);
        vm.assume(principal < type(uint256).max / SCALE);
        vm.assume(globalIndex - userIndex < type(uint256).max / (principal == 0 ? 1 : principal));

        harness.setPool(PID, address(0xD00D), 1_000 ether);
        harness.setFeeIndex(PID, globalIndex);
        harness.setUser(PID, USER, principal, userIndex, 0);

        harness.settle(PID, USER);
        (uint256 idxAfterFirst, uint256 accruedAfterFirst) = harness.userState(PID, USER);
        harness.settle(PID, USER);
        (uint256 idxAfterSecond, uint256 accruedAfterSecond) = harness.userState(PID, USER);

        assertEq(idxAfterSecond, idxAfterFirst);
        assertEq(accruedAfterSecond, accruedAfterFirst);
    }

    function testFuzzPendingMatchesSettleView(uint256 principal, uint256 globalIndex, uint256 userIndex) public {
        vm.assume(globalIndex >= userIndex);
        vm.assume(globalIndex < 1e38 && userIndex < 1e38);
        vm.assume(principal < type(uint256).max / SCALE);
        vm.assume(globalIndex - userIndex < type(uint256).max / (principal == 0 ? 1 : principal));

        harness.setPool(PID, address(0xFEE1), 1_000 ether);
        harness.setFeeIndex(PID, globalIndex);
        harness.setUser(PID, USER, principal, userIndex, 0);

        uint256 pending = harness.pending(PID, USER);
        harness.settle(PID, USER);
        (, uint256 accrued) = harness.userState(PID, USER);

        assertEq(pending, accrued);
    }
}
