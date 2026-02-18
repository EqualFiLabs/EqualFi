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

    function burn(address user, uint256 amount, bytes32 reason) external {
        LibPoints.burn(user, amount, reason);
    }

    function setRedemptionToken(address token) external {
        LibPoints.setRedemptionToken(token);
    }

    function setRedemptionEnabled(bool enabled) external {
        LibPoints.setRedemptionEnabled(enabled);
    }

    function setRedemptionRate(uint256 tokensPerPointWad) external {
        LibPoints.setRedemptionRate(tokensPerPointWad);
    }

    function setRedemptionGlobalMintCap(uint256 newCap) external {
        LibPoints.setRedemptionGlobalMintCap(newCap);
    }

    function setRedemptionEpochConfig(uint64 epochLengthSecs, uint256 epochMintCap) external {
        LibPoints.setRedemptionEpochConfig(epochLengthSecs, epochMintCap);
    }

    function consumeRedemption(address user, uint256 pointsIn) external returns (address token, uint256 tokenOut) {
        return LibPoints.consumeRedemption(user, pointsIn);
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

    function test_getPointsEarnedAndBurned_roundTrip() public {
        address user = address(0xABCD);
        facet.setPointsPerAction(ACTION_A, 9);
        facet.accrue(user, ACTION_A);
        facet.accrue(user, ACTION_A);
        facet.burn(user, 7, keccak256("POINTS_VIEW_BURN"));

        assertEq(facet.getPoints(user), 11);
        assertEq(facet.getPointsEarned(user), 18);
        assertEq(facet.getPointsBurned(user), 7);
    }

    function test_getTotalPoints_roundTrip() public {
        address userA = address(0xA11CE);
        address userB = address(0xBEEF);
        facet.setPointsPerAction(ACTION_A, 5);
        facet.accrue(userA, ACTION_A);
        facet.accrue(userB, ACTION_A);
        facet.accrue(userB, ACTION_A);
        facet.burn(userB, 3, keccak256("POINTS_VIEW_BURN_TOTAL"));

        assertEq(facet.getTotalPointsEarned(), 15);
        assertEq(facet.getTotalPointsBurned(), 3);
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

    function test_previewRedeem_usesConfiguredRate() public {
        facet.setRedemptionRate(25e17); // 2.5 token per point
        assertEq(facet.previewRedeem(4), 10);
    }

    function test_getRedemptionConfig_roundTrip() public {
        address user = address(0xD00D);
        facet.setPointsPerAction(ACTION_A, 100);
        facet.accrue(user, ACTION_A);

        facet.setRedemptionToken(address(0xCAFE));
        facet.setRedemptionEnabled(true);
        facet.setRedemptionRate(2e18);
        facet.setRedemptionGlobalMintCap(1_000);
        facet.setRedemptionEpochConfig(1 days, 500);

        facet.consumeRedemption(user, 40); // mints 80

        (
            address token,
            bool enabled,
            uint256 tokensPerPointWad,
            uint256 globalMintCap,
            uint256 totalMinted,
            uint64 epochLengthSecs,
            uint256 epochMintCap,
            uint256 epochMintedCurrent
        ) = facet.getRedemptionConfig();

        assertEq(token, address(0xCAFE));
        assertEq(enabled, true);
        assertEq(tokensPerPointWad, 2e18);
        assertEq(globalMintCap, 1_000);
        assertEq(totalMinted, 80);
        assertEq(epochLengthSecs, 1 days);
        assertEq(epochMintCap, 500);
        assertEq(epochMintedCurrent, 80);
    }
}
