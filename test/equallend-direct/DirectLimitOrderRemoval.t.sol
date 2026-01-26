// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IDiamondLoupe} from "../../src/interfaces/IDiamondLoupe.sol";
import {DirectDiamondTestBase} from "./DirectDiamondTestBase.sol";

contract DirectLimitOrderRemovalTest is DirectDiamondTestBase {
    function setUp() public {
        setUpDiamond();
    }

    function testLimitOrderSelectorsRemoved() public {
        bytes4 postSelector = bytes4(
            keccak256("postLimitOrder((uint256,uint256,address,address,uint256,uint256,uint256,uint256,bool))")
        );
        bytes4 acceptSelector = bytes4(keccak256("acceptLimitOrder(uint256,uint256,uint256,uint256)"));
        bytes4 cancelSelector = bytes4(keccak256("cancelLimitOrder(uint256)"));

        assertEq(IDiamondLoupe(address(diamond)).facetAddress(postSelector), address(0));
        assertEq(IDiamondLoupe(address(diamond)).facetAddress(acceptSelector), address(0));
        assertEq(IDiamondLoupe(address(diamond)).facetAddress(cancelSelector), address(0));
    }
}
