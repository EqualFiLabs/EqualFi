// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {EqualIndexLendingFacet} from "../../src/equalindex/EqualIndexLendingFacet.sol";
import {UpgradeEqualIndexLendingFacet} from "../../script/UpgradeEqualIndexLendingFacet.s.sol";

contract MockLoupeFacetAddress {
    mapping(bytes4 => address) internal _facets;

    function setFacet(bytes4 selector, address facet) external {
        _facets[selector] = facet;
    }

    function facetAddress(bytes4 selector) external view returns (address) {
        return _facets[selector];
    }
}

contract UpgradeEqualIndexLendingFacetHarness is UpgradeEqualIndexLendingFacet {
    function buildCuts(address diamond, address facet, bytes4[] memory selectors)
        external
        view
        returns (IDiamondCut.FacetCut[] memory cuts)
    {
        cuts = new IDiamondCut.FacetCut[](2);
        uint256 i = _appendCuts(cuts, 0, diamond, facet, selectors);
        assembly {
            mstore(cuts, i)
        }
    }
}

contract UpgradeEqualIndexLendingFacetScriptTest is Test {
    UpgradeEqualIndexLendingFacetHarness internal harness;

    function setUp() public {
        harness = new UpgradeEqualIndexLendingFacetHarness();
    }

    function test_lendingSelectorSet_isComplete() public {
        bytes4[] memory sels = harness.lendingSelectors();
        assertEq(sels.length, 12, "selector count");
        assertEq(sels[0], EqualIndexLendingFacet.configureLending.selector, "configure selector");
        assertEq(sels[4], EqualIndexLendingFacet.recoverExpired.selector, "recover selector");
        assertEq(sels[11], EqualIndexLendingFacet.lendingModuleId.selector, "module id selector");
    }

    function test_buildCuts_allAddWhenSelectorsMissing() public {
        MockLoupeFacetAddress loupe = new MockLoupeFacetAddress();
        address facet = address(new EqualIndexLendingFacet());
        bytes4[] memory sels = harness.lendingSelectors();

        IDiamondCut.FacetCut[] memory cuts = harness.buildCuts(address(loupe), facet, sels);
        assertEq(cuts.length, 1, "single add cut");
        assertEq(uint8(cuts[0].action), uint8(IDiamondCut.FacetCutAction.Add), "add action");
        assertEq(cuts[0].facetAddress, facet, "facet address");
        assertEq(cuts[0].functionSelectors.length, sels.length, "all selectors added");
    }

    function test_buildCuts_allReplaceWhenSelectorsExistOnDifferentFacet() public {
        MockLoupeFacetAddress loupe = new MockLoupeFacetAddress();
        bytes4[] memory sels = harness.lendingSelectors();
        address oldFacet = address(0xBEEF);
        for (uint256 i; i < sels.length; i++) {
            loupe.setFacet(sels[i], oldFacet);
        }

        address newFacet = address(new EqualIndexLendingFacet());
        IDiamondCut.FacetCut[] memory cuts = harness.buildCuts(address(loupe), newFacet, sels);
        assertEq(cuts.length, 1, "single replace cut");
        assertEq(uint8(cuts[0].action), uint8(IDiamondCut.FacetCutAction.Replace), "replace action");
        assertEq(cuts[0].facetAddress, newFacet, "facet address");
        assertEq(cuts[0].functionSelectors.length, sels.length, "all selectors replaced");
    }

    function test_buildCuts_mixedAddReplaceAndNoopForSameFacet() public {
        MockLoupeFacetAddress loupe = new MockLoupeFacetAddress();
        bytes4[] memory sels = harness.lendingSelectors();
        address oldFacet = address(0xCAFE);
        address newFacet = address(new EqualIndexLendingFacet());

        // First selector exists on old facet => replace.
        loupe.setFacet(sels[0], oldFacet);
        // Second selector already on new facet => no-op for this selector.
        loupe.setFacet(sels[1], newFacet);
        // Remaining selectors missing => add.

        IDiamondCut.FacetCut[] memory cuts = harness.buildCuts(address(loupe), newFacet, sels);
        assertEq(cuts.length, 2, "replace + add cuts");

        assertEq(uint8(cuts[0].action), uint8(IDiamondCut.FacetCutAction.Replace), "first is replace");
        assertEq(cuts[0].functionSelectors.length, 1, "one selector replaced");
        assertEq(cuts[0].functionSelectors[0], sels[0], "replaced selector");

        assertEq(uint8(cuts[1].action), uint8(IDiamondCut.FacetCutAction.Add), "second is add");
        assertEq(cuts[1].functionSelectors.length, sels.length - 2, "remaining selectors added");
    }
}

