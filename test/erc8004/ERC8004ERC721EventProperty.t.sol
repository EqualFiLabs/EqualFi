// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Diamond} from "../../src/core/Diamond.sol";
import {DiamondCutFacet} from "../../src/core/DiamondCutFacet.sol";
import {DiamondInit} from "../../src/core/DiamondInit.sol";
import {IDiamondCut} from "../../src/interfaces/IDiamondCut.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {PositionNFTIdentityFacet} from "../../src/erc8004/PositionNFTIdentityFacet.sol";
import {PositionNFTWalletFacet} from "../../src/erc8004/PositionNFTWalletFacet.sol";
import {PositionNFTViewFacet} from "../../src/erc8004/PositionNFTViewFacet.sol";

contract PositionNFTBurnable is PositionNFT {
    function burn(uint256 tokenId) external {
        require(ownerOf(tokenId) == msg.sender, "PositionNFT: not owner");
        _burn(tokenId);
    }
}

contract DirectOfferMockFacet {
    function hasOpenOffers(bytes32) external pure returns (bool) {
        return false;
    }
}

contract ERC8004ERC721EventPropertyTest is Test {
    Diamond internal diamond;
    PositionNFTBurnable internal nft;
    PositionNFTIdentityFacet internal identity;

    function setUp() public {
        DiamondCutFacet cutFacet = new DiamondCutFacet();
        PositionNFTIdentityFacet identityFacet = new PositionNFTIdentityFacet();
        PositionNFTWalletFacet walletFacet = new PositionNFTWalletFacet();
        PositionNFTViewFacet viewFacetImpl = new PositionNFTViewFacet();
        DirectOfferMockFacet offerFacet = new DirectOfferMockFacet();
        DiamondInit initializer = new DiamondInit();

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](5);
        cuts[0] = _cut(address(cutFacet), _selectors(cutFacet));
        cuts[1] = _cut(address(identityFacet), _selectors(identityFacet));
        cuts[2] = _cut(address(walletFacet), _selectors(walletFacet));
        cuts[3] = _cut(address(viewFacetImpl), _selectors(viewFacetImpl));
        cuts[4] = _cut(address(offerFacet), _selectors(offerFacet));

        diamond = new Diamond(cuts, Diamond.DiamondArgs({owner: address(this)}));
        nft = new PositionNFTBurnable();

        IDiamondCut(address(diamond)).diamondCut(
            new IDiamondCut.FacetCut[](0),
            address(initializer),
            abi.encodeWithSelector(DiamondInit.init.selector, address(0xBEEF), address(nft))
        );

        identity = PositionNFTIdentityFacet(address(diamond));
    }

    // Feature: erc8004-position-nft, Property 11: ERC-721 Event Compliance
    // Validates: Requirements 8.4
    function test_erc721TransferEvents() public {
        address owner = address(0xBEEF);
        address recipient = address(0xCAFE);
        bytes32 transferSig = keccak256("Transfer(address,address,uint256)");

        vm.startPrank(owner);
        vm.recordLogs();
        uint256 agentId = identity.register();
        vm.stopPrank();

        _expectTransferEvent(transferSig, address(0), owner, agentId);

        vm.startPrank(owner);
        vm.recordLogs();
        nft.transferFrom(owner, recipient, agentId);
        vm.stopPrank();

        _expectTransferEvent(transferSig, owner, recipient, agentId);

        vm.startPrank(recipient);
        vm.recordLogs();
        nft.burn(agentId);
        vm.stopPrank();

        _expectTransferEvent(transferSig, recipient, address(0), agentId);
    }

    function _expectTransferEvent(bytes32 sig, address from, address to, uint256 tokenId) internal {
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < entries.length; i++) {
            Vm.Log memory log = entries[i];
            if (log.emitter != address(nft)) {
                continue;
            }
            if (log.topics.length != 4) {
                continue;
            }
            if (log.topics[0] != sig) {
                continue;
            }
            if (address(uint160(uint256(log.topics[1]))) != from) {
                continue;
            }
            if (address(uint160(uint256(log.topics[2]))) != to) {
                continue;
            }
            if (uint256(log.topics[3]) != tokenId) {
                continue;
            }
            found = true;
            break;
        }
        assertTrue(found, "Transfer event not found");
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
        s = new bytes4[](3);
        s[0] = PositionNFTViewFacet.getAgentWallet.selector;
        s[1] = PositionNFTViewFacet.getAgentNonce.selector;
        s[2] = PositionNFTViewFacet.getIdentityRegistry.selector;
    }

    function _selectors(DirectOfferMockFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = DirectOfferMockFacet.hasOpenOffers.selector;
    }
}
