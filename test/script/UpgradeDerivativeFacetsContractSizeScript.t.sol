// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {OptionsFacet} from "../../src/derivatives/OptionsFacet.sol";
import {FuturesFacet} from "../../src/derivatives/FuturesFacet.sol";
import {UpgradeDerivativeFacetsContractSize} from "../../script/UpgradeDerivativeFacetsContractSize.s.sol";

contract MockLoupeFacetAddress {
    mapping(bytes4 => address) internal _facets;

    function setFacet(bytes4 selector, address facet) external {
        _facets[selector] = facet;
    }

    function facetAddress(bytes4 selector) external view returns (address) {
        return _facets[selector];
    }
}

contract UpgradeDerivativeFacetsContractSizeHarness is UpgradeDerivativeFacetsContractSize {
    function optionSelectors() external pure returns (bytes4[] memory) {
        return _selectors(OptionsFacet(address(0)));
    }

    function futuresSelectors() external pure returns (bytes4[] memory) {
        return _selectors(FuturesFacet(address(0)));
    }

    function legacyOptionSelector() external pure returns (bytes4) {
        return LEGACY_CREATE_OPTION_SELECTOR;
    }

    function legacyFuturesSelector() external pure returns (bytes4) {
        return LEGACY_CREATE_FUTURES_SELECTOR;
    }

    function legacySelectorsToRemove(address diamond) external view returns (bytes4[] memory) {
        return _legacySelectorsToRemove(diamond);
    }
}

contract UpgradeDerivativeFacetsContractSizeScriptTest is Test {
    UpgradeDerivativeFacetsContractSizeHarness internal harness;

    function setUp() public {
        harness = new UpgradeDerivativeFacetsContractSizeHarness();
    }

    function test_optionAndFuturesSelectorSets() public {
        bytes4[] memory optionSels = harness.optionSelectors();
        bytes4[] memory futuresSels = harness.futuresSelectors();

        assertEq(optionSels.length, 7, "options selector count");
        assertEq(futuresSels.length, 7, "futures selector count");
        assertEq(optionSels[2], OptionsFacet.createOptionSeries.selector, "options create selector");
        assertEq(optionSels[5], OptionsFacet.previewExercisePayment.selector, "options preview selector");
        assertEq(futuresSels[2], FuturesFacet.createFuturesSeries.selector, "futures create selector");
        assertEq(futuresSels[5], FuturesFacet.previewSettlePayment.selector, "futures preview selector");
    }

    function test_legacySelectorsAreDistinctFromCurrentCreateSelectors() public {
        assertTrue(
            harness.legacyOptionSelector() != OptionsFacet.createOptionSeries.selector, "legacy option selector differs"
        );
        assertTrue(
            harness.legacyFuturesSelector() != FuturesFacet.createFuturesSeries.selector,
            "legacy futures selector differs"
        );
    }

    function test_legacySelectorsToRemove_detectsInstalledLegacySelectors() public {
        MockLoupeFacetAddress loupe = new MockLoupeFacetAddress();
        loupe.setFacet(harness.legacyOptionSelector(), address(0xBEEF));
        loupe.setFacet(harness.legacyFuturesSelector(), address(0xCAFE));

        bytes4[] memory removeSelectors = harness.legacySelectorsToRemove(address(loupe));
        assertEq(removeSelectors.length, 2, "remove both legacy selectors");
        assertEq(removeSelectors[0], harness.legacyOptionSelector(), "first remove option selector");
        assertEq(removeSelectors[1], harness.legacyFuturesSelector(), "second remove futures selector");
    }

    function test_legacySelectorsToRemove_emptyWhenNoLegacySelectors() public {
        MockLoupeFacetAddress loupe = new MockLoupeFacetAddress();
        bytes4[] memory removeSelectors = harness.legacySelectorsToRemove(address(loupe));
        assertEq(removeSelectors.length, 0, "no removals");
    }
}
