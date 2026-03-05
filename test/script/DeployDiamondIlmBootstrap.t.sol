// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Diamond} from "../../src/core/Diamond.sol";
import {DiamondCutFacet} from "../../src/core/DiamondCutFacet.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {ModuleRegistryFacet} from "../../src/modules/ModuleRegistryFacet.sol";
import {ILMIsolatedAdminFacet} from "../../src/ilm-isolated/facets/ILMIsolatedAdminFacet.sol";
import {ILMIsolatedViewFacet} from "../../src/ilm-isolated/facets/ILMIsolatedViewFacet.sol";
import {IlmManagedFixedRateIrm} from "../../src/ilm-isolated/irm/IlmManagedFixedRateIrm.sol";
import {ChainlinkPairIsolatedOracleAdapter} from "../../src/ilm-isolated/oracles/ChainlinkPairIsolatedOracleAdapter.sol";
import {IlmIsolatedTypes} from "../../src/ilm-isolated/types/IlmIsolatedTypes.sol";
import {LibIlmIsolatedStorage} from "../../src/ilm-isolated/libraries/LibIlmIsolatedStorage.sol";

contract MockChainlinkFeedForScript {
    uint8 public immutable decimals;
    int256 internal answer;
    uint256 internal updatedAt;
    uint80 internal roundId;
    uint80 internal answeredInRound;

    constructor(uint8 decimals_, int256 answer_, uint256 updatedAt_) {
        decimals = decimals_;
        answer = answer_;
        updatedAt = updatedAt_;
        roundId = 1;
        answeredInRound = 1;
    }

    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (roundId, answer, updatedAt, updatedAt, answeredInRound);
    }
}

contract IlmIsolatedInitHarnessForScript {
    function init(address owner_, uint256 maxStaleness_) external {
        LibIlmIsolatedStorage.IlmIsolatedStorageLayout storage ds = LibIlmIsolatedStorage.s();
        ds.owner = owner_;
        ds.maxStaleness = maxStaleness_;
    }
}

contract DeployDiamondIlmBootstrapTest is Test {
    Diamond internal diamond;
    ILMIsolatedAdminFacet internal ilmAdmin;
    ILMIsolatedViewFacet internal ilmView;
    ModuleRegistryFacet internal moduleRegistry;

    function setUp() public {
        DiamondCutFacet cutFacet = new DiamondCutFacet();
        ModuleRegistryFacet moduleRegistryFacet = new ModuleRegistryFacet();
        ILMIsolatedAdminFacet ilmAdminFacet = new ILMIsolatedAdminFacet();
        ILMIsolatedViewFacet ilmViewFacet = new ILMIsolatedViewFacet();

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](4);
        cuts[0] = _cut(address(cutFacet), _selectorsCut());
        cuts[1] = _cut(address(moduleRegistryFacet), _selectorsModuleRegistry());
        cuts[2] = _cut(address(ilmAdminFacet), _selectorsIlmAdmin());
        cuts[3] = _cut(address(ilmViewFacet), _selectorsIlmView());

        diamond = new Diamond(cuts, Diamond.DiamondArgs({owner: address(this)}));

        IlmIsolatedInitHarnessForScript ilmInit = new IlmIsolatedInitHarnessForScript();
        IDiamondCut.FacetCut[] memory noCuts = new IDiamondCut.FacetCut[](0);
        IDiamondCut(address(diamond)).diamondCut(
            noCuts, address(ilmInit), abi.encodeWithSelector(IlmIsolatedInitHarnessForScript.init.selector, address(this), 1 days)
        );

        ilmAdmin = ILMIsolatedAdminFacet(address(diamond));
        ilmView = ILMIsolatedViewFacet(address(diamond));
        moduleRegistry = ModuleRegistryFacet(address(diamond));
    }

    function test_bootstrapFlow_deployAdapterEnableAndCreateMarket() public {
        MockChainlinkFeedForScript ethUsd = new MockChainlinkFeedForScript(8, int256(2000e8), block.timestamp);
        MockChainlinkFeedForScript usdcUsd = new MockChainlinkFeedForScript(8, int256(1e8), block.timestamp);

        ChainlinkPairIsolatedOracleAdapter adapter =
            new ChainlinkPairIsolatedOracleAdapter(address(ethUsd), address(usdcUsd), 18, 6);
        IlmManagedFixedRateIrm irm = new IlmManagedFixedRateIrm(32_000_000_000);

        ilmAdmin.enableIrm(address(irm));
        ilmAdmin.enableLltv(8e17);

        uint256 moduleId = moduleRegistry.registerModule(keccak256("ILM_ISOLATED_BOOTSTRAP"));
        assertGt(moduleId, 0);

        IlmIsolatedTypes.IlmIsolatedMarketParams memory params = IlmIsolatedTypes.IlmIsolatedMarketParams({
            loanPoolId: 5,
            collateralPoolId: 6,
            oracle: address(adapter),
            irm: address(irm),
            lltv: 8e17
        });

        bytes32 marketId = ilmAdmin.createIlmIsolatedMarket(params, moduleId);
        assertEq(marketId, keccak256(abi.encode(params)));

        IlmIsolatedTypes.IlmIsolatedMarketParams memory stored = ilmView.getIsolatedMarketParams(marketId);
        assertEq(stored.loanPoolId, 5);
        assertEq(stored.collateralPoolId, 6);
        assertEq(stored.oracle, address(adapter));
        assertEq(stored.irm, address(irm));
        assertEq(stored.lltv, 8e17);

        (uint256 price,) = adapter.getIsolatedPrice(address(adapter));
        assertEq(price, 2000e24);
    }

    function _cut(address facet, bytes4[] memory selectors) internal pure returns (IDiamondCut.FacetCut memory c) {
        c.facetAddress = facet;
        c.action = IDiamondCut.FacetCutAction.Add;
        c.functionSelectors = selectors;
    }

    function _selectorsCut() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = DiamondCutFacet.diamondCut.selector;
    }

    function _selectorsModuleRegistry() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](10);
        s[0] = ModuleRegistryFacet.registerModule.selector;
        s[1] = ModuleRegistryFacet.setModuleOwner.selector;
        s[2] = ModuleRegistryFacet.pauseModule.selector;
        s[3] = ModuleRegistryFacet.unpauseModule.selector;
        s[4] = ModuleRegistryFacet.setModuleCreationFee.selector;
        s[5] = ModuleRegistryFacet.setDefaultModuleAumBps.selector;
        s[6] = ModuleRegistryFacet.setModuleAumBps.selector;
        s[7] = ModuleRegistryFacet.setModuleAumBounds.selector;
        s[8] = ModuleRegistryFacet.setModuleDeactivationGraceEpochs.selector;
        s[9] = ModuleRegistryFacet.setModuleAciPaused.selector;
    }

    function _selectorsIlmAdmin() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](10);
        s[0] = ILMIsolatedAdminFacet.createIlmIsolatedMarket.selector;
        s[1] = ILMIsolatedAdminFacet.enableIrm.selector;
        s[2] = ILMIsolatedAdminFacet.setIrmManagedOnly.selector;
        s[3] = ILMIsolatedAdminFacet.enableLltv.selector;
        s[4] = ILMIsolatedAdminFacet.setFee.selector;
        s[5] = ILMIsolatedAdminFacet.setFeeRecipientPositionKey.selector;
        s[6] = ILMIsolatedAdminFacet.setMarketLiquidationFeeBps.selector;
        s[7] = ILMIsolatedAdminFacet.setMaxStaleness.selector;
        s[8] = ILMIsolatedAdminFacet.setOwner.selector;
        s[9] = ILMIsolatedAdminFacet.setAuthorization.selector;
    }

    function _selectorsIlmView() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](7);
        s[0] = ILMIsolatedViewFacet.getIsolatedMarket.selector;
        s[1] = ILMIsolatedViewFacet.getIsolatedMarketParams.selector;
        s[2] = ILMIsolatedViewFacet.getIsolatedPosition.selector;
        s[3] = ILMIsolatedViewFacet.getIsolatedMarketLiquidationFeeBps.selector;
        s[4] = ILMIsolatedViewFacet.getIsolatedMarketProtocolFeeAssets.selector;
        s[5] = ILMIsolatedViewFacet.isIlmIrmManagedOnly.selector;
        s[6] = ILMIsolatedViewFacet.isIsolatedHealthy.selector;
    }
}
