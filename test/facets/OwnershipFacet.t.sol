// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Diamond} from "../../src/core/Diamond.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {OwnershipFacet} from "../../src/core/OwnershipFacet.sol";

contract OwnershipFacetTest is Test {
    Diamond internal diamond;
    OwnershipFacet internal ownershipFacet;

    address internal constant OWNER = address(0xA11CE);
    address internal constant NOT_OWNER = address(0xBEEF);

    function setUp() public {
        ownershipFacet = new OwnershipFacet();

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = _cut(address(ownershipFacet), _selectors(ownershipFacet));

        diamond = new Diamond(cuts, Diamond.DiamondArgs({owner: OWNER}));
    }

    function test_owner_reportsDiamondOwner() public view {
        assertEq(OwnershipFacet(address(diamond)).owner(), OWNER);
    }

    function test_transferOwnership_onlyOwner() public {
        vm.prank(NOT_OWNER);
        vm.expectRevert(bytes("LibDiamond: must be owner"));
        OwnershipFacet(address(diamond)).transferOwnership(address(0x1234));
    }

    function test_transferOwnership_revertsOnZeroAddress() public {
        vm.prank(OWNER);
        vm.expectRevert(bytes("OwnershipFacet: zero address"));
        OwnershipFacet(address(diamond)).transferOwnership(address(0));
    }

    function test_transferOwnership_updatesOwner() public {
        address newOwner = address(0x1234);
        vm.prank(OWNER);
        OwnershipFacet(address(diamond)).transferOwnership(newOwner);

        assertEq(OwnershipFacet(address(diamond)).owner(), newOwner);
    }

    function _cut(address facet, bytes4[] memory selectors) internal pure returns (IDiamondCut.FacetCut memory c) {
        c.facetAddress = facet;
        c.action = IDiamondCut.FacetCutAction.Add;
        c.functionSelectors = selectors;
    }

    function _selectors(OwnershipFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = OwnershipFacet.transferOwnership.selector;
        s[1] = OwnershipFacet.owner.selector;
    }
}
