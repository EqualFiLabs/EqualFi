// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {FacetCatalog} from "../../script/releases/FacetCatalog.sol";
import {FacetId} from "../../script/releases/ManifestTypes.sol";

contract FacetCatalogHarness is FacetCatalog {
    function deployFacetForTest(FacetId facetId) external returns (address facet, uint256 selectorCount) {
        bytes4[] memory selectors;
        (facet, selectors) = _deployFacet(facetId);
        selectorCount = selectors.length;
    }
}

contract FacetCatalogCoverageTest is Test {
    FacetCatalogHarness internal harness;

    function setUp() public {
        harness = new FacetCatalogHarness();
    }

    function testAllFacetIdsMapToDeployableFacets() public {
        uint256 facetCount = uint256(type(FacetId).max) + 1;

        for (uint256 i; i < facetCount; ++i) {
            (address facet, uint256 selectorCount) = harness.deployFacetForTest(FacetId(i));
            assertTrue(facet != address(0), "facet not deployed");
            assertTrue(selectorCount > 0, "facet selectors missing");
        }
    }
}
