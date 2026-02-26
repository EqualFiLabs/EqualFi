// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../../src/interfaces/IDiamondLoupe.sol";
import {Diamond} from "../../src/core/Diamond.sol";
import {DiamondCutFacet} from "../../src/core/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../../src/core/DiamondLoupeFacet.sol";
import {OwnershipFacet} from "../../src/core/OwnershipFacet.sol";
import {PositionAgentTBAFacet} from "../../src/agent-wallet/erc6551/PositionAgentTBAFacet.sol";
import {PositionAgentConfigFacet} from "../../src/agent-wallet/erc6551/PositionAgentConfigFacet.sol";
import {UpgradePositionAgentFacets} from "../../script/UpgradePositionAgentFacets.s.sol";

contract UpgradePositionAgentFacetsScriptTest is Test {
    Diamond internal diamond;
    UpgradePositionAgentFacets internal scriptHarness;

    function setUp() public {
        DiamondCutFacet cutFacet = new DiamondCutFacet();
        DiamondLoupeFacet loupeFacet = new DiamondLoupeFacet();
        OwnershipFacet ownershipFacet = new OwnershipFacet();

        IDiamondCut.FacetCut[] memory baseCuts = new IDiamondCut.FacetCut[](3);
        baseCuts[0] = _cut(address(cutFacet), _selectors(cutFacet), IDiamondCut.FacetCutAction.Add);
        baseCuts[1] = _cut(address(loupeFacet), _selectors(loupeFacet), IDiamondCut.FacetCutAction.Add);
        baseCuts[2] = _cut(address(ownershipFacet), _selectors(ownershipFacet), IDiamondCut.FacetCutAction.Add);
        diamond = new Diamond(baseCuts, Diamond.DiamondArgs({owner: address(this)}));

        scriptHarness = new UpgradePositionAgentFacets();
    }

    function test_buildCuts_replacesExistingPositionAgentFacets() public {
        PositionAgentTBAFacet oldTBAFacet = new PositionAgentTBAFacet();
        PositionAgentConfigFacet oldConfigFacet = new PositionAgentConfigFacet();
        _addAgentFacets(address(oldTBAFacet), address(oldConfigFacet));

        PositionAgentTBAFacet newTBAFacet = new PositionAgentTBAFacet();
        PositionAgentConfigFacet newConfigFacet = new PositionAgentConfigFacet();

        IDiamondCut.FacetCut[] memory cuts =
            scriptHarness.buildCutsForTesting(address(diamond), address(newTBAFacet), address(newConfigFacet));

        assertEq(cuts.length, 2, "expected replace cuts for two facets");
        assertEq(uint256(cuts[0].action), uint256(IDiamondCut.FacetCutAction.Replace), "TBA action");
        assertEq(uint256(cuts[1].action), uint256(IDiamondCut.FacetCutAction.Replace), "Config action");

        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");

        bytes4[] memory tbaSels = scriptHarness.tbaSelectors();
        bytes4[] memory cfgSels = scriptHarness.configSelectors();
        for (uint256 i; i < tbaSels.length; i++) {
            assertEq(IDiamondLoupe(address(diamond)).facetAddress(tbaSels[i]), address(newTBAFacet), "TBA selector owner");
        }
        for (uint256 i; i < cfgSels.length; i++) {
            assertEq(
                IDiamondLoupe(address(diamond)).facetAddress(cfgSels[i]),
                address(newConfigFacet),
                "Config selector owner"
            );
        }
    }

    function test_buildCuts_addsMissingPositionAgentFacets() public {
        PositionAgentTBAFacet newTBAFacet = new PositionAgentTBAFacet();
        PositionAgentConfigFacet newConfigFacet = new PositionAgentConfigFacet();

        IDiamondCut.FacetCut[] memory cuts =
            scriptHarness.buildCutsForTesting(address(diamond), address(newTBAFacet), address(newConfigFacet));

        assertEq(cuts.length, 2, "expected add cuts for two facets");
        assertEq(uint256(cuts[0].action), uint256(IDiamondCut.FacetCutAction.Add), "TBA action");
        assertEq(uint256(cuts[1].action), uint256(IDiamondCut.FacetCutAction.Add), "Config action");

        IDiamondCut(address(diamond)).diamondCut(cuts, address(0), "");

        bytes4[] memory tbaSels = scriptHarness.tbaSelectors();
        bytes4[] memory cfgSels = scriptHarness.configSelectors();
        for (uint256 i; i < tbaSels.length; i++) {
            assertEq(IDiamondLoupe(address(diamond)).facetAddress(tbaSels[i]), address(newTBAFacet), "TBA selector owner");
        }
        for (uint256 i; i < cfgSels.length; i++) {
            assertEq(
                IDiamondLoupe(address(diamond)).facetAddress(cfgSels[i]),
                address(newConfigFacet),
                "Config selector owner"
            );
        }
    }

    function _addAgentFacets(address tbaFacet, address configFacet) internal {
        IDiamondCut.FacetCut[] memory addCuts = new IDiamondCut.FacetCut[](2);
        addCuts[0] = _cut(tbaFacet, scriptHarness.tbaSelectors(), IDiamondCut.FacetCutAction.Add);
        addCuts[1] = _cut(configFacet, scriptHarness.configSelectors(), IDiamondCut.FacetCutAction.Add);
        IDiamondCut(address(diamond)).diamondCut(addCuts, address(0), "");
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
        s = new bytes4[](5);
        s[0] = DiamondLoupeFacet.facets.selector;
        s[1] = DiamondLoupeFacet.facetFunctionSelectors.selector;
        s[2] = DiamondLoupeFacet.facetAddresses.selector;
        s[3] = DiamondLoupeFacet.facetAddress.selector;
        s[4] = DiamondLoupeFacet.supportsInterface.selector;
    }

    function _selectors(OwnershipFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = OwnershipFacet.transferOwnership.selector;
        s[1] = OwnershipFacet.owner.selector;
    }
}

