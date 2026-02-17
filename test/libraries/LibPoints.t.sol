// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibPoints} from "../../src/libraries/LibPoints.sol";

contract LibPointsHarness {
    function accrue(address user, bytes32 actionType) external {
        LibPoints.accrue(user, actionType);
    }

    function setPointsPerAction(bytes32 actionType, uint256 amount) external {
        LibPoints.setPointsPerAction(actionType, amount);
    }

    function getPoints(address user) external view returns (uint256) {
        return LibPoints.balanceOf(user);
    }

    function getPointsPerAction(bytes32 actionType) external view returns (uint256) {
        return LibPoints.pointsForAction(actionType);
    }
}

contract LibPointsTest is Test {
    event PointsAccrued(address indexed user, bytes32 indexed actionType, uint256 amount);
    event PointsPerActionUpdated(bytes32 indexed actionType, uint256 newAmount);

    LibPointsHarness internal h;

    bytes32 internal constant ACTION_A = keccak256("POINTS_ACTION_A");
    bytes32 internal constant ACTION_B = keccak256("POINTS_ACTION_B");
    bytes32 internal constant ACTION_C = keccak256("POINTS_ACTION_C");

    function setUp() public {
        h = new LibPointsHarness();
    }

    function test_setPointsPerAction_roundTripAndEvent() public {
        vm.expectEmit(true, false, false, true);
        emit PointsPerActionUpdated(ACTION_A, 42);
        h.setPointsPerAction(ACTION_A, 42);

        assertEq(h.getPointsPerAction(ACTION_A), 42);
    }

    /// **Feature: point-system, Property 1: Accrual increments by configured amount**
    function testFuzz_accrue_incrementsByConfiguredAmount(address user, bytes32 actionType, uint256 points) public {
        points = bound(points, 1, type(uint128).max);
        h.setPointsPerAction(actionType, points);

        uint256 beforeBal = h.getPoints(user);
        h.accrue(user, actionType);
        uint256 afterBal = h.getPoints(user);

        assertEq(afterBal - beforeBal, points);
    }

    /// **Feature: point-system, Property 2: Cumulative additivity**
    function testFuzz_accrue_isCumulative(
        address user,
        uint256 pointsA,
        uint256 pointsB,
        uint256 pointsC,
        uint8 countA,
        uint8 countB,
        uint8 countC
    ) public {
        pointsA = bound(pointsA, 1, type(uint64).max);
        pointsB = bound(pointsB, 1, type(uint64).max);
        pointsC = bound(pointsC, 1, type(uint64).max);

        h.setPointsPerAction(ACTION_A, pointsA);
        h.setPointsPerAction(ACTION_B, pointsB);
        h.setPointsPerAction(ACTION_C, pointsC);

        uint256 nA = uint256(bound(countA, 0, 32));
        uint256 nB = uint256(bound(countB, 0, 32));
        uint256 nC = uint256(bound(countC, 0, 32));

        for (uint256 i = 0; i < nA; i++) h.accrue(user, ACTION_A);
        for (uint256 i = 0; i < nB; i++) h.accrue(user, ACTION_B);
        for (uint256 i = 0; i < nC; i++) h.accrue(user, ACTION_C);

        uint256 expected = (nA * pointsA) + (nB * pointsB) + (nC * pointsC);
        assertEq(h.getPoints(user), expected);
    }

    /// **Feature: point-system, Property 5: Zero-config disables accrual**
    function testFuzz_accrue_zeroConfigDoesNotChangeBalance(address user, bytes32 actionType) public {
        assertEq(h.getPointsPerAction(actionType), 0);
        uint256 beforeBal = h.getPoints(user);

        vm.recordLogs();
        h.accrue(user, actionType);

        assertEq(h.getPoints(user), beforeBal);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    /// **Feature: point-system, Property 6: Accrual event emission**
    function testFuzz_accrue_emitsEvent(address user, bytes32 actionType, uint256 points) public {
        points = bound(points, 1, type(uint128).max);
        h.setPointsPerAction(actionType, points);

        vm.expectEmit(true, true, false, true);
        emit PointsAccrued(user, actionType, points);
        h.accrue(user, actionType);
    }

    function test_balanceOf_freshAddressReturnsZero() public {
        assertEq(h.getPoints(address(0xBEEF)), 0);
    }

    function test_accrue_addressZero_works() public {
        h.setPointsPerAction(ACTION_A, 7);
        h.accrue(address(0), ACTION_A);
        assertEq(h.getPoints(address(0)), 7);
    }
}
