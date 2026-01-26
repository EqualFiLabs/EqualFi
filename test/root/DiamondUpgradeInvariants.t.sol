// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Diamond} from "../../src/core/Diamond.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../../src/interfaces/IDiamondLoupe.sol";
import {DiamondCutFacet} from "../../src/core/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../../src/core/DiamondLoupeFacet.sol";

interface IFoo {
    function foo() external returns (uint256);
}

contract FooFacetV1 is IFoo {
    function foo() external pure returns (uint256) {
        return 1;
    }
}

contract FooFacetV2 is IFoo {
    function foo() external pure returns (uint256) {
        return 2;
    }
}

contract DiamondUpgradeInvariantsTest is Test {
    Diamond internal diamond;
    DiamondCutFacet internal cutFacet;
    DiamondLoupeFacet internal loupeFacet;
    FooFacetV1 internal foo1;
    FooFacetV2 internal foo2;

    function setUp() public {
        cutFacet = new DiamondCutFacet();
        loupeFacet = new DiamondLoupeFacet();
        foo1 = new FooFacetV1();
        foo2 = new FooFacetV2();

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](2);
        cuts[0] = _cut(address(cutFacet), _selectors(cutFacet), IDiamondCut.FacetCutAction.Add);
        cuts[1] = _cut(address(loupeFacet), _selectors(loupeFacet), IDiamondCut.FacetCutAction.Add);

        diamond = new Diamond(cuts, Diamond.DiamondArgs({owner: address(this)}));
    }

    function test_facetAddress_matchesExpectedFacetAcrossAddAndReplace() public {
        _diamondCutAdd(address(foo1), _selectors(foo1));
        assertEq(IDiamondLoupe(address(diamond)).facetAddress(IFoo.foo.selector), address(foo1));
        assertEq(IFoo(address(diamond)).foo(), 1);

        _diamondCutReplace(address(foo2), _selectors(foo2));
        assertEq(IDiamondLoupe(address(diamond)).facetAddress(IFoo.foo.selector), address(foo2));
        assertEq(IFoo(address(diamond)).foo(), 2);
    }

    function test_diamondCut_preventsSelectorCollisionsOnAdd() public {
        _diamondCutAdd(address(foo1), _selectors(foo1));

        IDiamondCut.FacetCut[] memory addAgain = new IDiamondCut.FacetCut[](1);
        addAgain[0] = _cut(address(foo2), _selectors(foo2), IDiamondCut.FacetCutAction.Add);

        vm.expectRevert(bytes("LibDiamond: exists"));
        IDiamondCut(address(diamond)).diamondCut(addAgain, address(0), "");
    }

    function _diamondCutAdd(address facet, bytes4[] memory selectors) internal {
        IDiamondCut.FacetCut[] memory addCuts = new IDiamondCut.FacetCut[](1);
        addCuts[0] = _cut(facet, selectors, IDiamondCut.FacetCutAction.Add);
        IDiamondCut(address(diamond)).diamondCut(addCuts, address(0), "");
    }

    function _diamondCutReplace(address facet, bytes4[] memory selectors) internal {
        IDiamondCut.FacetCut[] memory replaceCuts = new IDiamondCut.FacetCut[](1);
        replaceCuts[0] = _cut(facet, selectors, IDiamondCut.FacetCutAction.Replace);
        IDiamondCut(address(diamond)).diamondCut(replaceCuts, address(0), "");
    }

    function _cut(address facet, bytes4[] memory selectors, IDiamondCut.FacetCutAction action)
        internal
        pure
        returns (IDiamondCut.FacetCut memory c)
    {
        c.facetAddress = facet;
        c.action = action;
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

    function _selectors(FooFacetV1) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = IFoo.foo.selector;
    }

    function _selectors(FooFacetV2) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = IFoo.foo.selector;
    }
}

