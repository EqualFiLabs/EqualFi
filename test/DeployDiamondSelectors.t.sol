// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {DeployDiamondScript} from "../script/DeployDiamond.s.sol";
import {ILMPooledAdminFacet} from "../src/ilm-pooled/facets/ILMPooledAdminFacet.sol";
import {ILMPooledFacet} from "../src/ilm-pooled/facets/ILMPooledFacet.sol";
import {ILMPooledLiquidationFacet} from "../src/ilm-pooled/facets/ILMPooledLiquidationFacet.sol";
import {ILMPooledViewFacet} from "../src/ilm-pooled/facets/ILMPooledViewFacet.sol";
import {PerpsAdminFacet} from "../src/perps/PerpsAdminFacet.sol";
import {PerpsExecutionFacet} from "../src/perps/PerpsExecutionFacet.sol";
import {PerpsLiquidationFacet} from "../src/perps/PerpsLiquidationFacet.sol";
import {PerpsViewFacet} from "../src/perps/PerpsViewFacet.sol";

contract DeployDiamondSelectorHarness is DeployDiamondScript {
    function moreFacetCutCount() external pure returns (uint256) {
        return MORE_FACET_CUT_COUNT;
    }

    function ilmPooledAdminSelectors() external pure returns (bytes4[] memory) {
        return _selectors(ILMPooledAdminFacet(address(0)));
    }

    function ilmPooledSelectors() external pure returns (bytes4[] memory) {
        return _selectors(ILMPooledFacet(address(0)));
    }

    function ilmPooledLiquidationSelectors() external pure returns (bytes4[] memory) {
        return _selectors(ILMPooledLiquidationFacet(address(0)));
    }

    function ilmPooledViewSelectors() external pure returns (bytes4[] memory) {
        return _selectors(ILMPooledViewFacet(address(0)));
    }

    function perpsAdminSelectors() external pure returns (bytes4[] memory) {
        return _selectors(PerpsAdminFacet(address(0)));
    }

    function perpsExecutionSelectors() external pure returns (bytes4[] memory) {
        return _selectors(PerpsExecutionFacet(address(0)));
    }

    function perpsLiquidationSelectors() external pure returns (bytes4[] memory) {
        return _selectors(PerpsLiquidationFacet(address(0)));
    }

    function perpsViewSelectors() external pure returns (bytes4[] memory) {
        return _selectors(PerpsViewFacet(address(0)));
    }
}

contract DeployDiamondSelectorsTest is Test {
    DeployDiamondSelectorHarness internal harness;

    function setUp() public {
        harness = new DeployDiamondSelectorHarness();
    }

    function testMoreFacetCutCountIncludesIlmPooledAndPerpsCuts() public {
        assertEq(harness.moreFacetCutCount(), 58);
    }

    function testIlmPooledSelectorsPresent() public {
        bytes4[] memory adminSelectors = harness.ilmPooledAdminSelectors();
        assertEq(adminSelectors.length, 8);
        _assertContains(adminSelectors, ILMPooledAdminFacet.createPooledMarket.selector);
        _assertContains(adminSelectors, ILMPooledAdminFacet.setPooledGlobalBounds.selector);

        bytes4[] memory coreSelectors = harness.ilmPooledSelectors();
        assertEq(coreSelectors.length, 6);
        _assertContains(coreSelectors, ILMPooledFacet.pooledSupply.selector);
        _assertContains(coreSelectors, ILMPooledFacet.pooledWithdraw.selector);
        _assertContains(coreSelectors, ILMPooledFacet.pooledBorrow.selector);
        _assertContains(coreSelectors, ILMPooledFacet.pooledRepay.selector);

        bytes4[] memory liqSelectors = harness.ilmPooledLiquidationSelectors();
        assertEq(liqSelectors.length, 1);
        _assertContains(liqSelectors, ILMPooledLiquidationFacet.pooledLiquidationCall.selector);

        bytes4[] memory viewSelectors = harness.ilmPooledViewSelectors();
        assertEq(viewSelectors.length, 6);
        _assertContains(viewSelectors, ILMPooledViewFacet.getPooledMarket.selector);
        _assertContains(viewSelectors, ILMPooledViewFacet.previewHealthFactor.selector);
        _assertContains(viewSelectors, ILMPooledViewFacet.getPooledMarketProtocolFeeAssets.selector);
    }

    function testPerpsSelectorsPresent() public {
        bytes4[] memory adminSelectors = harness.perpsAdminSelectors();
        assertEq(adminSelectors.length, 14);
        _assertContains(adminSelectors, PerpsAdminFacet.createMarket.selector);
        _assertContains(adminSelectors, PerpsAdminFacet.setGlobalConfig.selector);
        _assertContains(adminSelectors, PerpsAdminFacet.isMarketLiquidationEnabled.selector);

        bytes4[] memory executionSelectors = harness.perpsExecutionSelectors();
        assertEq(executionSelectors.length, 15);
        _assertContains(executionSelectors, PerpsExecutionFacet.createAccount.selector);
        _assertContains(executionSelectors, PerpsExecutionFacet.openOrIncrease.selector);
        _assertContains(executionSelectors, PerpsExecutionFacet.decreaseOrClose.selector);
        _assertContains(executionSelectors, PerpsExecutionFacet.executeIntent.selector);
        _assertContains(executionSelectors, PerpsExecutionFacet.cancelIntent.selector);
        _assertContains(executionSelectors, PerpsExecutionFacet.syncAccount.selector);

        bytes4[] memory liquidationSelectors = harness.perpsLiquidationSelectors();
        assertEq(liquidationSelectors.length, 3);
        _assertContains(liquidationSelectors, PerpsLiquidationFacet.liquidate.selector);
        _assertContains(liquidationSelectors, PerpsLiquidationFacet.syncMarket.selector);

        bytes4[] memory viewSelectors = harness.perpsViewSelectors();
        assertEq(viewSelectors.length, 10);
        _assertContains(viewSelectors, PerpsViewFacet.getMarket.selector);
        _assertContains(viewSelectors, PerpsViewFacet.previewHealth.selector);
        _assertContains(viewSelectors, PerpsViewFacet.getFeeRoutingAudit.selector);
        _assertContains(viewSelectors, PerpsViewFacet.proveIsolationInvariant.selector);
    }

    function _assertContains(bytes4[] memory selectors, bytes4 expected) internal pure {
        for (uint256 i; i < selectors.length; ++i) {
            if (selectors[i] == expected) {
                return;
            }
        }
        revert("selector missing");
    }
}
