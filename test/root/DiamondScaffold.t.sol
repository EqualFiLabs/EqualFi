// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Diamond} from "../../src/core/Diamond.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../../src/interfaces/IDiamondLoupe.sol";
import {DiamondCutFacet} from "../../src/core/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../../src/core/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../../src/core/OwnershipFacet.sol";
import {AdminFacet} from "../../src/admin/AdminFacet.sol";
import {DiamondInit} from "../../src/core/DiamondInit.sol";

contract DiamondScaffoldTest is Test {
    Diamond diamond;
    DiamondCutFacet cutFacet;
    DiamondLoupeFacet loupeFacet;
    OwnershipFacet ownershipFacet;
    AdminFacet adminFacet;
    DiamondInit initializer;

    function setUp() public {
        cutFacet = new DiamondCutFacet();
        loupeFacet = new DiamondLoupeFacet();
        ownershipFacet = new OwnershipFacet();
        adminFacet = new AdminFacet();
        initializer = new DiamondInit();

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](4);
        cuts[0] = _cut(address(cutFacet), _selectors(cutFacet));
        cuts[1] = _cut(address(loupeFacet), _selectors(loupeFacet));
        cuts[2] = _cut(address(ownershipFacet), _selectors(ownershipFacet));
        cuts[3] = _cut(address(adminFacet), _selectors(adminFacet));

        diamond = new Diamond(cuts, Diamond.DiamondArgs({owner: address(this)}));

        // run init to set timelock (pass address(0) for positionNFTContract since we're not testing NFTs here)
        IDiamondCut(address(diamond))
            .diamondCut(
                new IDiamondCut.FacetCut[](0),
                address(initializer),
                abi.encodeWithSelector(DiamondInit.init.selector, address(0xBEEF), address(0))
            );
    }

    function testOwnerSet() public {
        assertEq(OwnershipFacet(address(diamond)).owner(), address(this));
    }

    function testLoupeSelectorsRegistered() public {
        IDiamondLoupe.Facet[] memory facets = IDiamondLoupe(address(diamond)).facets();
        // expect 4 facets with selectors
        assertEq(facets.length, 4);
        // ensure at least diamondCut selector present
        bool foundCut;
        for (uint256 i; i < facets.length; i++) {
            bytes4[] memory sels = facets[i].functionSelectors;
            for (uint256 j; j < sels.length; j++) {
                if (sels[j] == IDiamondCut.diamondCut.selector) {
                    foundCut = true;
                }
            }
        }
        assertTrue(foundCut, "diamondCut selector missing");
    }

    function testTimelockInitialized() public {
        assertEq(AdminFacet(address(diamond)).timelock(), address(0xBEEF));
    }

    function _cut(address facet, bytes4[] memory selectors) internal pure returns (IDiamondCut.FacetCut memory c) {
        c.facetAddress = facet;
        c.action = IDiamondCut.FacetCutAction.Add;
        c.functionSelectors = selectors;
    }

    function _selectors(DiamondCutFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = DiamondCutFacet.diamondCut.selector;
    }

    function _selectors(DiamondLoupeFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](4);
        s[0] = DiamondLoupeFacet.facets.selector;
        s[1] = DiamondLoupeFacet.facetFunctionSelectors.selector;
        s[2] = DiamondLoupeFacet.facetAddresses.selector;
        s[3] = DiamondLoupeFacet.facetAddress.selector;
    }

    function _selectors(OwnershipFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = OwnershipFacet.transferOwnership.selector;
        s[1] = OwnershipFacet.owner.selector;
    }

    function _selectors(AdminFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = AdminFacet.setTimelock.selector;
        s[1] = AdminFacet.timelock.selector;
    }
}
