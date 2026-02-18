// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {LeanDeployScript} from "../script/leanDeploy.s.sol";
import {IDiamondLoupe} from "../src/interfaces/IDiamondLoupe.sol";
import {PointsAdminFacet} from "../src/admin/PointsAdminFacet.sol";
import {PointsViewFacet} from "../src/views/PointsViewFacet.sol";

contract LeanDeploySelectorsTest is Test {
    function testLeanDeployCutsPositionViewSelectors() public {
        LeanDeployScript script = new LeanDeployScript();
        LeanDeployScript.Deployment memory deployment =
            script.deployForTest(address(this), address(this), address(this));

        IDiamondLoupe loupe = IDiamondLoupe(deployment.diamond);

        bytes4 positionStateSelector = bytes4(keccak256("getPositionState(uint256,uint256)"));
        bytes4 membershipsSelector = bytes4(keccak256("getPositionPoolMemberships(uint256)"));
        bytes4 poolOnlySelector = bytes4(keccak256("getPositionPoolDataPoolOnly(uint256,uint256)"));
        bytes4 mintFromPositionSelector = bytes4(keccak256("mintFromPosition(uint256,uint256,uint256)"));
        bytes4 burnFromPositionSelector = bytes4(keccak256("burnFromPosition(uint256,uint256,uint256)"));
        bytes4 pendingActiveCreditSelector = bytes4(keccak256("pendingActiveCreditByPosition(uint256,uint256)"));

        assertTrue(loupe.facetAddress(positionStateSelector) != address(0), "missing getPositionState selector");
        assertTrue(loupe.facetAddress(membershipsSelector) != address(0), "missing memberships selector");
        assertTrue(loupe.facetAddress(poolOnlySelector) != address(0), "missing pool-only selector");
        assertTrue(
            loupe.facetAddress(mintFromPositionSelector) != address(0), "missing mintFromPosition selector"
        );
        assertTrue(
            loupe.facetAddress(burnFromPositionSelector) != address(0), "missing burnFromPosition selector"
        );
        assertTrue(
            loupe.facetAddress(pendingActiveCreditSelector) != address(0), "missing pendingActiveCredit selector"
        );
    }

    function testLeanDeployCutsAndCallsPointsSelectors() public {
        LeanDeployScript script = new LeanDeployScript();
        LeanDeployScript.Deployment memory deployment =
            script.deployForTest(address(this), address(this), address(this));

        IDiamondLoupe loupe = IDiamondLoupe(deployment.diamond);
        assertTrue(
            loupe.facetAddress(PointsAdminFacet.setPointsPerAction.selector) != address(0),
            "missing setPointsPerAction selector"
        );
        assertTrue(
            loupe.facetAddress(PointsAdminFacet.setPointsPerActionBatch.selector) != address(0),
            "missing setPointsPerActionBatch selector"
        );
        assertTrue(
            loupe.facetAddress(PointsAdminFacet.setDailyPointsCap.selector) != address(0),
            "missing setDailyPointsCap selector"
        );
        assertTrue(
            loupe.facetAddress(PointsAdminFacet.setAccrualCooldown.selector) != address(0),
            "missing setAccrualCooldown selector"
        );
        assertTrue(loupe.facetAddress(PointsViewFacet.getPoints.selector) != address(0), "missing getPoints selector");
        assertTrue(
            loupe.facetAddress(PointsViewFacet.getPointsPerAction.selector) != address(0),
            "missing getPointsPerAction selector"
        );
        assertTrue(
            loupe.facetAddress(PointsViewFacet.getPointsBatch.selector) != address(0),
            "missing getPointsBatch selector"
        );
        assertTrue(
            loupe.facetAddress(PointsViewFacet.getDailyPointsCap.selector) != address(0),
            "missing getDailyPointsCap selector"
        );
        assertTrue(
            loupe.facetAddress(PointsViewFacet.getPointsAccruedToday.selector) != address(0),
            "missing getPointsAccruedToday selector"
        );
        assertTrue(
            loupe.facetAddress(PointsViewFacet.getAccrualCooldown.selector) != address(0),
            "missing getAccrualCooldown selector"
        );

        PointsAdminFacet pointsAdmin = PointsAdminFacet(deployment.diamond);
        PointsViewFacet pointsView = PointsViewFacet(deployment.diamond);

        bytes32 actionTypeA = keccak256("POINTS_TEST_A");
        bytes32 actionTypeB = keccak256("POINTS_TEST_B");
        pointsAdmin.setPointsPerAction(actionTypeA, 111);
        assertEq(pointsView.getPointsPerAction(actionTypeA), 111, "single setter not callable");

        bytes32[] memory actionTypes = new bytes32[](2);
        actionTypes[0] = actionTypeA;
        actionTypes[1] = actionTypeB;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 333;
        amounts[1] = 777;
        pointsAdmin.setPointsPerActionBatch(actionTypes, amounts);

        assertEq(pointsView.getPointsPerAction(actionTypeA), 333, "batch setter not callable");
        assertEq(pointsView.getPointsPerAction(actionTypeB), 777, "batch setter not callable");
        assertEq(pointsView.getPoints(address(this)), 0, "unexpected non-zero points");

        address[] memory users = new address[](2);
        users[0] = address(this);
        users[1] = address(0xBEEF);
        uint256[] memory balances = pointsView.getPointsBatch(users);
        assertEq(balances.length, 2, "batch length");
        assertEq(balances[0], 0, "batch points self");
        assertEq(balances[1], 0, "batch points other");

        pointsAdmin.setDailyPointsCap(123);
        assertEq(pointsView.getDailyPointsCap(), 123, "daily cap setter not callable");
        assertEq(pointsView.getPointsAccruedToday(address(this)), 0, "unexpected accrued today");

        pointsAdmin.setAccrualCooldown(actionTypeA, 3600);
        assertEq(pointsView.getAccrualCooldown(actionTypeA), 3600, "cooldown setter not callable");
    }
}
