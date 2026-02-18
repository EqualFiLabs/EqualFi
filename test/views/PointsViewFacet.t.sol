// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PointsViewFacet} from "../../src/views/PointsViewFacet.sol";
import {LibPoints} from "../../src/libraries/LibPoints.sol";

contract PointsViewHarness is PointsViewFacet {
    function setPointsPerAction(bytes32 actionType, uint256 amount) external {
        LibPoints.setPointsPerAction(actionType, amount);
    }

    function accrue(address user, bytes32 actionType) external {
        LibPoints.accrue(user, actionType);
    }

    function setDailyPointsCap(uint256 amount) external {
        LibPoints.setDailyPointsCap(amount);
    }

    function setAccrualCooldown(bytes32 actionType, uint256 cooldownSecs) external {
        LibPoints.setAccrualCooldown(actionType, cooldownSecs);
    }
}

contract PointsViewFacetTest is Test {
    PointsViewHarness internal facet;

    bytes32 internal constant ACTION_A = keccak256("POINTS_VIEW_ACTION_A");

    function setUp() public {
        facet = new PointsViewHarness();
    }

    function test_getPoints_singleAddressQuery() public {
        address user = address(0xA11CE);
        facet.setPointsPerAction(ACTION_A, 7);
        facet.accrue(user, ACTION_A);
        facet.accrue(user, ACTION_A);

        assertEq(facet.getPoints(user), 14);
    }

    function test_getPointsBatch_multipleAddresses() public {
        address userA = address(0xA11CE);
        address userB = address(0xBEEF);
        facet.setPointsPerAction(ACTION_A, 5);
        facet.accrue(userA, ACTION_A);
        facet.accrue(userB, ACTION_A);
        facet.accrue(userB, ACTION_A);

        address[] memory users = new address[](2);
        users[0] = userA;
        users[1] = userB;
        uint256[] memory balances = facet.getPointsBatch(users);

        assertEq(balances.length, 2);
        assertEq(balances[0], 5);
        assertEq(balances[1], 10);
    }

    function test_getPoints_zeroBalanceAddress() public {
        assertEq(facet.getPoints(address(0xCAFE)), 0);
    }

    function test_getDailyPointsCap_roundTrip() public {
        facet.setDailyPointsCap(1234);
        assertEq(facet.getDailyPointsCap(), 1234);
    }

    function test_getPointsAccruedToday_tracksCurrentDay() public {
        address user = address(0xABCD);
        facet.setPointsPerAction(ACTION_A, 7);
        facet.setDailyPointsCap(100);

        facet.accrue(user, ACTION_A);
        facet.accrue(user, ACTION_A);

        assertEq(facet.getPointsAccruedToday(user), 14);
        vm.warp(block.timestamp + 1 days);
        assertEq(facet.getPointsAccruedToday(user), 0);
    }

    function test_getAccrualCooldown_roundTrip() public {
        facet.setAccrualCooldown(ACTION_A, 30 minutes);
        assertEq(facet.getAccrualCooldown(ACTION_A), 30 minutes);
    }
}
