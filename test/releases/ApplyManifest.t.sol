// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AdminFacet} from "../../src/admin/AdminFacet.sol";
import {AmmAuctionFacet} from "../../src/EqualX/AmmAuctionFacet.sol";
import {CommunityAuctionFacet} from "../../src/EqualX/CommunityAuctionFacet.sol";
import {EqualIndexLendingFacet} from "../../src/equalindex/EqualIndexLendingFacet.sol";
import {ILMIsolatedAdminFacet} from "../../src/ilm-isolated/facets/ILMIsolatedAdminFacet.sol";
import {ILMPooledAdminFacet} from "../../src/ilm-pooled/facets/ILMPooledAdminFacet.sol";
import {LendingFacet} from "../../src/equallend/LendingFacet.sol";
import {MamCurveCreationFacet} from "../../src/EqualX/MamCurveCreationFacet.sol";
import {ModuleRegistryFacet} from "../../src/modules/ModuleRegistryFacet.sol";
import {OptionsFacet} from "../../src/derivatives/OptionsFacet.sol";
import {OptionToken} from "../../src/derivatives/OptionToken.sol";
import {PerpsAdminFacet} from "../../src/perps/PerpsAdminFacet.sol";
import {PointsAdminFacet} from "../../src/admin/PointsAdminFacet.sol";
import {PositionAgentConfigFacet} from "../../src/agent-wallet/erc6551/PositionAgentConfigFacet.sol";
import {PositionAgentViewFacet} from "../../src/agent-wallet/erc6551/PositionAgentViewFacet.sol";
import {MockERC6551Registry} from "../../src/agent-wallet/erc6551/MockERC6551Registry.sol";
import {IDiamondLoupe} from "../../src/interfaces/IDiamondLoupe.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {EqualLendDirectOfferFacet} from "../../src/equallend-direct/EqualLendDirectOfferFacet.sol";
import {EqualLendDirectRollingPaymentFacet} from "../../src/equallend-direct/EqualLendDirectRollingPaymentFacet.sol";
import {PointsViewFacet} from "../../src/views/PointsViewFacet.sol";
import {ApplyManifestScript} from "../../script/ApplyManifest.s.sol";
import {ApplyReport, ManifestPlan} from "../../script/releases/ManifestTypes.sol";
import {ReleaseV1Manifest} from "../../script/releases/manifests/ReleaseV1.sol";
import {ReleaseV2Manifest} from "../../script/releases/manifests/ReleaseV2.sol";
import {ReleaseV3Manifest} from "../../script/releases/manifests/ReleaseV3.sol";
import {ReleaseV4Manifest} from "../../script/releases/manifests/ReleaseV4.sol";
import {ReleaseV5Manifest} from "../../script/releases/manifests/ReleaseV5.sol";

contract MockEntryPoint {}

contract MockIdentityRegistry {}

contract MockERC6551Implementation {}

contract ApplyManifestTest is Test {
    address internal constant ENTRYPOINT_V07 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address internal constant ERC6551_REGISTRY = 0x000000006551c19487814612e58FE06813775758;
    address internal constant ERC8004_MAINNET = 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;

    ApplyManifestScript internal script;
    ReleaseV1Manifest internal v1Manifest;
    ReleaseV2Manifest internal v2Manifest;
    ReleaseV3Manifest internal v3Manifest;
    ReleaseV4Manifest internal v4Manifest;
    ReleaseV5Manifest internal v5Manifest;
    MockEntryPoint internal entryPoint;
    MockERC6551Registry internal registry;
    MockIdentityRegistry internal identityRegistry;
    MockERC6551Implementation internal configuredImplementation;

    function setUp() public {
        script = new ApplyManifestScript();
        v1Manifest = new ReleaseV1Manifest();
        v2Manifest = new ReleaseV2Manifest();
        v3Manifest = new ReleaseV3Manifest();
        v4Manifest = new ReleaseV4Manifest();
        v5Manifest = new ReleaseV5Manifest();
        entryPoint = new MockEntryPoint();
        registry = new MockERC6551Registry();
        identityRegistry = new MockIdentityRegistry();
        configuredImplementation = new MockERC6551Implementation();

        vm.chainId(1);
        vm.etch(ENTRYPOINT_V07, address(entryPoint).code);
        vm.etch(ERC6551_REGISTRY, address(registry).code);
        vm.etch(ERC8004_MAINNET, address(identityRegistry).code);
        vm.setEnv("ERC6551_IMPLEMENTATION", vm.toString(address(configuredImplementation)));
    }

    function testDeployAndApplyV1SetsExpectedStageSelectors() public {
        ApplyManifestScript.ManifestDeployment memory deployment =
            script.deployAndApplyForTest(address(this), address(0xBEEF), v1Manifest);

        IDiamondLoupe loupe = IDiamondLoupe(deployment.diamond);

        assertEq(deployment.report.deployedFacetCount, 42);
        assertEq(deployment.report.reusedFacetCount, 0);
        assertEq(deployment.report.replaceCutCount, 0);
        assertEq(deployment.report.unchangedSelectorCount, 0);
        assertEq(deployment.report.addedSelectorCount, 315);
        assertEq(deployment.entryPoint, ENTRYPOINT_V07);
        assertEq(deployment.erc6551Registry, ERC6551_REGISTRY);
        assertEq(deployment.identityRegistry, ERC8004_MAINNET);
        assertTrue(deployment.erc6551Implementation != address(0), "missing erc6551 implementation");
        assertTrue(deployment.optionToken != address(0), "missing option token deployment");
        assertEq(OptionToken(deployment.optionToken).manager(), deployment.diamond, "option manager mismatch");

        assertTrue(loupe.facetAddress(AdminFacet.setTimelock.selector) != address(0), "missing admin selector");
        assertTrue(
            loupe.facetAddress(LendingFacet.openRollingFromPosition.selector) != address(0),
            "missing lending selector"
        );
        assertTrue(
            loupe.facetAddress(EqualIndexLendingFacet.borrowFromPosition.selector) != address(0),
            "missing equalindex lending selector"
        );
        assertTrue(
            loupe.facetAddress(AmmAuctionFacet.createAuction.selector) != address(0),
            "missing amm auction selector"
        );
        assertTrue(
            loupe.facetAddress(MamCurveCreationFacet.createCurve.selector) != address(0),
            "missing mam curve selector"
        );
        assertTrue(
            loupe.facetAddress(OptionsFacet.createOptionSeries.selector) != address(0),
            "missing options selector"
        );
        assertTrue(
            loupe.facetAddress(PointsAdminFacet.setPointsPerAction.selector) != address(0),
            "missing points admin selector"
        );
        assertTrue(
            loupe.facetAddress(PointsViewFacet.getPoints.selector) != address(0),
            "missing points view selector"
        );
        assertTrue(
            loupe.facetAddress(CommunityAuctionFacet.createCommunityAuction.selector) != address(0),
            "missing community auction selector"
        );
        assertTrue(
            loupe.facetAddress(PositionAgentConfigFacet.setIdentityRegistry.selector) != address(0),
            "missing agent config selector"
        );
        assertTrue(
            loupe.facetAddress(PositionAgentViewFacet.getCanonicalRegistries.selector) != address(0),
            "missing agent view selector"
        );
        assertTrue(
            loupe.facetAddress(ModuleRegistryFacet.registerModule.selector) != address(0),
            "missing module registry selector"
        );
        assertEq(loupe.facetAddress(EqualLendDirectOfferFacet.postBorrowerOffer.selector), address(0));
        assertEq(loupe.facetAddress(ILMIsolatedAdminFacet.createIlmIsolatedMarket.selector), address(0));
        assertEq(loupe.facetAddress(ILMPooledAdminFacet.createPooledMarket.selector), address(0));
        assertEq(loupe.facetAddress(PerpsAdminFacet.createMarket.selector), address(0));

        PositionNFT nft = PositionNFT(deployment.positionNFT);
        assertEq(nft.minter(), deployment.diamond);
        assertEq(nft.diamond(), deployment.diamond);
    }

    function testApplyReleaseStagesAddModulesCumulatively() public {
        ApplyManifestScript.ManifestDeployment memory deployment =
            script.deployAndApplyForTest(address(this), address(0xBEEF), v1Manifest);

        assertEq(IDiamondLoupe(deployment.diamond).facetAddress(EqualLendDirectOfferFacet.postBorrowerOffer.selector), address(0));
        assertEq(IDiamondLoupe(deployment.diamond).facetAddress(ILMIsolatedAdminFacet.createIlmIsolatedMarket.selector), address(0));
        assertEq(IDiamondLoupe(deployment.diamond).facetAddress(ILMPooledAdminFacet.createPooledMarket.selector), address(0));
        assertEq(IDiamondLoupe(deployment.diamond).facetAddress(PerpsAdminFacet.createMarket.selector), address(0));

        ManifestPlan memory v2Plan = script.planForTest(deployment.diamond, v2Manifest);
        assertEq(v2Plan.report.deployedFacetCount, 10);
        assertEq(v2Plan.report.reusedFacetCount, 42);
        assertEq(v2Plan.report.replaceCutCount, 0);
        assertEq(v2Plan.report.addedSelectorCount, 54);
        assertEq(v2Plan.report.unchangedSelectorCount, 315);

        ApplyReport memory v2Report = script.applyToDiamondForTest(deployment.diamond, v2Manifest, address(this));
        assertEq(v2Report.deployedFacetCount, 10);
        assertEq(v2Report.reusedFacetCount, 42);
        assertEq(v2Report.replaceCutCount, 0);
        assertEq(v2Report.addedSelectorCount, 54);
        assertEq(v2Report.unchangedSelectorCount, 315);

        IDiamondLoupe loupe = IDiamondLoupe(deployment.diamond);
        assertTrue(
            loupe.facetAddress(EqualLendDirectOfferFacet.postBorrowerOffer.selector) != address(0),
            "missing direct offer selector"
        );
        assertTrue(
            loupe.facetAddress(EqualLendDirectRollingPaymentFacet.makeRollingPayment.selector) != address(0),
            "missing rolling payment selector"
        );
        assertTrue(
            loupe.facetAddress(LendingFacet.openRollingFromPosition.selector) != address(0),
            "launch selector regressed"
        );
        assertTrue(
            loupe.facetAddress(EqualIndexLendingFacet.borrowFromPosition.selector) != address(0),
            "launch index selector regressed"
        );
        assertEq(loupe.facetAddress(ILMIsolatedAdminFacet.createIlmIsolatedMarket.selector), address(0));
        assertEq(loupe.facetAddress(ILMPooledAdminFacet.createPooledMarket.selector), address(0));
        assertEq(loupe.facetAddress(PerpsAdminFacet.createMarket.selector), address(0));

        script.applyToDiamondForTest(deployment.diamond, v3Manifest, address(this));
        assertTrue(
            loupe.facetAddress(ILMIsolatedAdminFacet.createIlmIsolatedMarket.selector) != address(0),
            "missing isolated ilm selector"
        );
        assertEq(loupe.facetAddress(ILMPooledAdminFacet.createPooledMarket.selector), address(0));
        assertEq(loupe.facetAddress(PerpsAdminFacet.createMarket.selector), address(0));

        script.applyToDiamondForTest(deployment.diamond, v4Manifest, address(this));
        assertTrue(
            loupe.facetAddress(ILMPooledAdminFacet.createPooledMarket.selector) != address(0),
            "missing pooled ilm selector"
        );
        assertEq(loupe.facetAddress(PerpsAdminFacet.createMarket.selector), address(0));

        script.applyToDiamondForTest(deployment.diamond, v5Manifest, address(this));
        assertTrue(
            loupe.facetAddress(PerpsAdminFacet.createMarket.selector) != address(0),
            "missing perps selector"
        );
    }

    function testReapplyingSameManifestIsNoOp() public {
        ApplyManifestScript.ManifestDeployment memory deployment =
            script.deployAndApplyForTest(address(this), address(0xBEEF), v2Manifest);

        ApplyReport memory report = script.applyToDiamondForTest(deployment.diamond, v2Manifest, address(this));

        assertEq(report.deployedFacetCount, 0);
        assertEq(report.reusedFacetCount, 52);
        assertEq(report.addCutCount, 0);
        assertEq(report.replaceCutCount, 0);
        assertEq(report.addedSelectorCount, 0);
        assertEq(report.replacedSelectorCount, 0);
        assertEq(report.unchangedSelectorCount, 369);
    }

    function testDeployV1RevertsWithoutConfiguredCanonicalDependencies() public {
        vm.etch(ENTRYPOINT_V07, bytes(""));
        vm.etch(ERC6551_REGISTRY, bytes(""));
        vm.etch(ERC8004_MAINNET, bytes(""));

        vm.expectRevert(bytes("FacetCatalog: ERC4337 entrypoint missing"));
        script.deployAndApplyForTest(address(this), address(0xBEEF), v1Manifest);
    }
}
