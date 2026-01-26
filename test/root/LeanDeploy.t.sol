// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IDiamondLoupe} from "../../src/interfaces/IDiamondLoupe.sol";
import {AmmAuctionFacet} from "../../src/EqualX/AmmAuctionFacet.sol";
import {CommunityAuctionFacet} from "../../src/EqualX/CommunityAuctionFacet.sol";
import {MamCurveCreationFacet} from "../../src/EqualX/MamCurveCreationFacet.sol";
import {PositionManagementFacet} from "../../src/equallend/PositionManagementFacet.sol";
import {EqualIndexViewFacetV3} from "../../src/views/EqualIndexViewFacetV3.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {LeanDeployScript} from "../../script/leanDeploy.s.sol";

contract LeanDeployTest is Test {
    function testLeanDeployCreatesIndexesAndFacets() public {
        LeanDeployScript script = new LeanDeployScript();
        LeanDeployScript.Deployment memory deployment =
            script.deployForTest(address(this), address(0xBEEF), address(0xCAFE));

        assertTrue(deployment.diamond != address(0));
        assertTrue(deployment.positionNFT != address(0));

        PositionNFT nft = PositionNFT(deployment.positionNFT);
        assertEq(nft.minter(), deployment.diamond);
        assertEq(nft.diamond(), deployment.diamond);

        EqualIndexViewFacetV3 viewFacet = EqualIndexViewFacetV3(deployment.diamond);
        EqualIndexViewFacetV3.IndexView memory idx0 = viewFacet.getIndex(0);
        EqualIndexViewFacetV3.IndexView memory idx1 = viewFacet.getIndex(1);
        EqualIndexViewFacetV3.IndexView memory idx2 = viewFacet.getIndex(2);

        assertEq(idx0.token, deployment.indexTokens[0]);
        assertEq(idx1.token, deployment.indexTokens[1]);
        assertEq(idx2.token, deployment.indexTokens[2]);

        assertEq(idx0.assets.length, 2);
        assertEq(idx1.assets.length, 2);
        assertEq(idx2.assets.length, 1);

        assertEq(idx0.assets[0], deployment.tokens[0]);
        assertEq(idx0.assets[1], deployment.tokens[1]);
        assertEq(idx1.assets[0], deployment.tokens[2]);
        assertEq(idx1.assets[1], deployment.tokens[3]);
        assertEq(idx2.assets[0], deployment.tokens[4]);

        IDiamondLoupe loupe = IDiamondLoupe(deployment.diamond);
        assertTrue(loupe.facetAddress(AmmAuctionFacet.createAuction.selector) != address(0));
        assertTrue(
            loupe.facetAddress(CommunityAuctionFacet.createCommunityAuction.selector) != address(0)
        );
        assertTrue(loupe.facetAddress(MamCurveCreationFacet.createCurve.selector) != address(0));
        assertTrue(loupe.facetAddress(PositionManagementFacet.mintPosition.selector) != address(0));
        assertTrue(
            loupe.facetAddress(bytes4(keccak256("openRollingFromPosition(uint256,uint256,uint256)")))
                != address(0)
        );
    }
}
