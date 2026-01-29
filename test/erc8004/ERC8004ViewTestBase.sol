// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Diamond} from "../../src/core/Diamond.sol";
import {DiamondCutFacet} from "../../src/core/DiamondCutFacet.sol";
import {DiamondInit} from "../../src/core/DiamondInit.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {PositionNFTIdentityFacet} from "../../src/erc8004/PositionNFTIdentityFacet.sol";
import {PositionNFTWalletFacet} from "../../src/erc8004/PositionNFTWalletFacet.sol";
import {PositionNFTViewFacet} from "../../src/erc8004/PositionNFTViewFacet.sol";

abstract contract ERC8004ViewTestBase is Test {
    Diamond internal diamond;
    PositionNFT internal nft;
    PositionNFTIdentityFacet internal identity;
    PositionNFTWalletFacet internal wallet;
    PositionNFTViewFacet internal viewFacet;

    function setUp() public virtual {
        DiamondCutFacet cutFacet = new DiamondCutFacet();
        PositionNFTIdentityFacet identityFacet = new PositionNFTIdentityFacet();
        PositionNFTWalletFacet walletFacet = new PositionNFTWalletFacet();
        PositionNFTViewFacet viewFacetImpl = new PositionNFTViewFacet();
        DiamondInit initializer = new DiamondInit();

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](4);
        cuts[0] = _cut(address(cutFacet), _selectors(cutFacet));
        cuts[1] = _cut(address(identityFacet), _selectors(identityFacet));
        cuts[2] = _cut(address(walletFacet), _selectors(walletFacet));
        cuts[3] = _cut(address(viewFacetImpl), _selectors(viewFacetImpl));

        diamond = new Diamond(cuts, Diamond.DiamondArgs({owner: address(this)}));

        nft = new PositionNFT();

        IDiamondCut(address(diamond)).diamondCut(
            new IDiamondCut.FacetCut[](0),
            address(initializer),
            abi.encodeWithSelector(DiamondInit.init.selector, address(0xBEEF), address(nft))
        );

        identity = PositionNFTIdentityFacet(address(diamond));
        wallet = PositionNFTWalletFacet(address(diamond));
        viewFacet = PositionNFTViewFacet(address(diamond));
    }

    function _cut(address facet, bytes4[] memory selectors) internal pure returns (IDiamondCut.FacetCut memory c) {
        c.facetAddress = facet;
        c.action = IDiamondCut.FacetCutAction.Add;
        c.functionSelectors = selectors;
    }

    function _selectors(DiamondCutFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = DiamondCutFacet.diamondCut.selector;
    }

    function _selectors(PositionNFTIdentityFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](7);
        s[0] = bytes4(keccak256("register()"));
        s[1] = bytes4(keccak256("register(string)"));
        s[2] = bytes4(keccak256("register(string,(string,bytes)[])"));
        s[3] = PositionNFTIdentityFacet.setAgentURI.selector;
        s[4] = PositionNFTIdentityFacet.getAgentURI.selector;
        s[5] = PositionNFTIdentityFacet.setMetadata.selector;
        s[6] = PositionNFTIdentityFacet.getMetadata.selector;
    }

    function _selectors(PositionNFTWalletFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](4);
        s[0] = PositionNFTWalletFacet.setAgentWallet.selector;
        s[1] = PositionNFTWalletFacet.onAgentTransfer.selector;
        s[2] = PositionNFTWalletFacet.DOMAIN_SEPARATOR.selector;
        s[3] = bytes4(keccak256("SET_AGENT_WALLET_TYPEHASH()"));
    }

    function _selectors(PositionNFTViewFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](4);
        s[0] = PositionNFTViewFacet.getAgentWallet.selector;
        s[1] = PositionNFTViewFacet.getAgentNonce.selector;
        s[2] = PositionNFTViewFacet.getIdentityRegistry.selector;
        s[3] = PositionNFTViewFacet.isAgent.selector;
    }
}
