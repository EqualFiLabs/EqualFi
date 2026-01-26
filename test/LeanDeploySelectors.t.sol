// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {LeanDeployScript} from "../script/leanDeploy.s.sol";
import {IDiamondLoupe} from "../src/interfaces/IDiamondLoupe.sol";

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
}
