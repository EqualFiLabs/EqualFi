// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AdminFacet} from "../../src/admin/AdminFacet.sol";
import {AmmAuctionFacet} from "../../src/EqualX/AmmAuctionFacet.sol";
import {EqualIndexLendingFacet} from "../../src/equalindex/EqualIndexLendingFacet.sol";
import {ILMIsolatedAdminFacet} from "../../src/ilm-isolated/facets/ILMIsolatedAdminFacet.sol";
import {ILMPooledAdminFacet} from "../../src/ilm-pooled/facets/ILMPooledAdminFacet.sol";
import {LendingFacet} from "../../src/equallend/LendingFacet.sol";
import {MamCurveCreationFacet} from "../../src/EqualX/MamCurveCreationFacet.sol";
import {OptionsFacet} from "../../src/derivatives/OptionsFacet.sol";
import {PerpsAdminFacet} from "../../src/perps/PerpsAdminFacet.sol";
import {IDiamondLoupe} from "../../src/interfaces/IDiamondLoupe.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {EqualLendDirectOfferFacet} from "../../src/equallend-direct/EqualLendDirectOfferFacet.sol";
import {EqualLendDirectRollingPaymentFacet} from "../../src/equallend-direct/EqualLendDirectRollingPaymentFacet.sol";
import {ApplyManifestScript} from "../../script/ApplyManifest.s.sol";
import {ApplyReport, ManifestPlan} from "../../script/releases/ManifestTypes.sol";
import {ReleaseV1Manifest} from "../../script/releases/manifests/ReleaseV1.sol";
import {ReleaseV2Manifest} from "../../script/releases/manifests/ReleaseV2.sol";
import {ReleaseV3Manifest} from "../../script/releases/manifests/ReleaseV3.sol";
import {ReleaseV4Manifest} from "../../script/releases/manifests/ReleaseV4.sol";
import {ReleaseV5Manifest} from "../../script/releases/manifests/ReleaseV5.sol";

contract ApplyManifestTest is Test {
    ApplyManifestScript internal script;
    ReleaseV1Manifest internal v1Manifest;
    ReleaseV2Manifest internal v2Manifest;
    ReleaseV3Manifest internal v3Manifest;
    ReleaseV4Manifest internal v4Manifest;
    ReleaseV5Manifest internal v5Manifest;

    function setUp() public {
        script = new ApplyManifestScript();
        v1Manifest = new ReleaseV1Manifest();
        v2Manifest = new ReleaseV2Manifest();
        v3Manifest = new ReleaseV3Manifest();
        v4Manifest = new ReleaseV4Manifest();
        v5Manifest = new ReleaseV5Manifest();
    }

    function testDeployAndApplyV1SetsExpectedStageSelectors() public {
        ApplyManifestScript.ManifestDeployment memory deployment =
            script.deployAndApplyForTest(address(this), address(0xBEEF), v1Manifest);

        IDiamondLoupe loupe = IDiamondLoupe(deployment.diamond);

        assertEq(deployment.report.deployedFacetCount, 30);
        assertEq(deployment.report.reusedFacetCount, 0);
        assertEq(deployment.report.replaceCutCount, 0);
        assertEq(deployment.report.unchangedSelectorCount, 0);
        assertTrue(deployment.report.addedSelectorCount > 0);

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
        assertEq(v2Plan.report.reusedFacetCount, 30);
        assertEq(v2Plan.report.replaceCutCount, 0);
        assertEq(v2Plan.report.addedSelectorCount, 54);
        assertEq(v2Plan.report.unchangedSelectorCount, 239);

        ApplyReport memory v2Report = script.applyToDiamondForTest(deployment.diamond, v2Manifest, address(this));
        assertEq(v2Report.deployedFacetCount, 10);
        assertEq(v2Report.reusedFacetCount, 30);
        assertEq(v2Report.replaceCutCount, 0);
        assertEq(v2Report.addedSelectorCount, 54);
        assertEq(v2Report.unchangedSelectorCount, 239);

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
        assertEq(report.reusedFacetCount, 40);
        assertEq(report.addCutCount, 0);
        assertEq(report.replaceCutCount, 0);
        assertEq(report.addedSelectorCount, 0);
        assertEq(report.replacedSelectorCount, 0);
        assertEq(report.unchangedSelectorCount, 293);
    }
}
