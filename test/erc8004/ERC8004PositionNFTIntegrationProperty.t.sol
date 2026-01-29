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

contract ERC8004PositionNFTIntegrationPropertyTest is Test {
    Diamond internal diamond;
    PositionNFTBurnable internal nft;
    PositionNFTIdentityFacet internal identity;
    PositionNFTWalletFacet internal wallet;
    PositionNFTViewFacet internal viewFacet;

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
        wallet = PositionNFTWalletFacet(address(diamond));
        viewFacet = PositionNFTViewFacet(address(diamond));
    }

    // Feature: erc8004-position-nft, Property 8: Transfer Resets Agent Wallet
    // Validates: Requirements 5.1, 5.2
    function test_transferResetsAgentWallet(bytes32 seed) public {
        address owner = address(0xBEEF);
        address newOwner = address(0xCAFE);
        uint256 pk = _boundedKey(seed, SECP256K1_ORDER - 2);
        address newWallet = vm.addr(pk);

        vm.startPrank(owner);
        uint256 agentId = identity.register();

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _digest(agentId, newWallet, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        wallet.setAgentWallet(agentId, newWallet, deadline, sig);

        assertEq(viewFacet.getAgentWallet(agentId), newWallet);
        assertEq(viewFacet.getAgentNonce(agentId), 1);

        nft.transferFrom(owner, newOwner, agentId);
        vm.stopPrank();

        assertEq(viewFacet.getAgentWallet(agentId), address(0));
        assertEq(viewFacet.getAgentNonce(agentId), 2);
    }

    // Feature: erc8004-position-nft, Property 9: Mint and Burn Preserve State
    // Validates: Requirements 5.3, 5.4
    function test_mintAndBurnPreserveState(bytes32 seed) public {
        address owner = address(0xBEEF);
        uint256 pk = _boundedKey(seed, SECP256K1_ORDER - 1);
        address newWallet = vm.addr(pk);

        vm.startPrank(owner);
        uint256 agentId = identity.register();

        // Mint should not change nonce or wallet.
        assertEq(viewFacet.getAgentWallet(agentId), address(0));
        assertEq(viewFacet.getAgentNonce(agentId), 0);

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _digest(agentId, newWallet, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        wallet.setAgentWallet(agentId, newWallet, deadline, sig);

        uint256 nonceBefore = viewFacet.getAgentNonce(agentId);
        address walletBefore = viewFacet.getAgentWallet(agentId);

        nft.burn(agentId);
        vm.stopPrank();

        assertEq(viewFacet.getAgentWallet(agentId), walletBefore);
        assertEq(viewFacet.getAgentNonce(agentId), nonceBefore);
    }

    // Feature: erc8004-position-nft, Property 8: tokenURI returns registration file
    // Validates: Requirements 2.4
    function test_tokenURIReturnsAgentURI(string memory agentURI) public {
        address owner = address(0xBEEF);
        vm.startPrank(owner);
        uint256 agentId = identity.register();
        identity.setAgentURI(agentId, agentURI);
        vm.stopPrank();

        assertEq(nft.tokenURI(agentId), agentURI);
    }

    function _digest(uint256 agentId, address newWallet, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(wallet.SET_AGENT_WALLET_TYPEHASH(), agentId, newWallet, nonce, deadline)
        );
        return keccak256(abi.encodePacked("\x19\x01", wallet.DOMAIN_SEPARATOR(), structHash));
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

    function _selectors(DirectOfferMockFacet) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = DirectOfferMockFacet.hasOpenOffers.selector;
    }

    function _boundedKey(bytes32 seed, uint256 max) internal pure returns (uint256) {
        uint256 pk = uint256(seed);
        if (pk == 0) {
            return 1;
        }
        if (max == 0) {
            return 1;
        }
        return 1 + (pk % max);
    }
}
