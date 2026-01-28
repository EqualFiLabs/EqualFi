// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../src/interfaces/IDiamondLoupe.sol";
import {PositionNFTIdentityFacet} from "../src/erc8004/PositionNFTIdentityFacet.sol";
import {PositionNFTWalletFacet} from "../src/erc8004/PositionNFTWalletFacet.sol";
import {PositionNFTViewFacet} from "../src/erc8004/PositionNFTViewFacet.sol";
import {PositionNFTMetadataFacet} from "../src/views/PositionNFTMetadataFacet.sol";
import {PositionNFT} from "../src/nft/PositionNFT.sol";

interface IOwnershipFacet {
    function owner() external view returns (address);
}

/// @notice Deploy and wire ERC-8004 facets into an existing Diamond.
contract DeployERC8004Facets is Script {
    function run() external {
        address diamond = vm.envAddress("DIAMOND");
        address pnft = vm.envAddress("POSITION_NFT");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address sender = vm.addr(pk);

        address diamondOwner = IOwnershipFacet(diamond).owner();
        console2.log("Diamond:", diamond);
        console2.log("PositionNFT:", pnft);
        console2.log("Sender:", sender);
        console2.log("Diamond owner:", diamondOwner);
        require(sender == diamondOwner, "ERC8004: sender is not diamond owner");

        vm.startBroadcast(pk);

        PositionNFTIdentityFacet identity = new PositionNFTIdentityFacet();
        PositionNFTWalletFacet wallet = new PositionNFTWalletFacet();
        PositionNFTViewFacet viewFacet = new PositionNFTViewFacet();
        PositionNFTMetadataFacet metadata = new PositionNFTMetadataFacet();

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](8);
        uint256 i;
        i = _appendCuts(cuts, i, diamond, address(identity), _selectors(identity));
        i = _appendCuts(cuts, i, diamond, address(wallet), _selectors(wallet));
        i = _appendCuts(cuts, i, diamond, address(viewFacet), _selectors(viewFacet));
        i = _appendCuts(cuts, i, diamond, address(metadata), _selectors(metadata));

        assembly {
            mstore(cuts, i)
        }

        IDiamondCut(diamond).diamondCut(cuts, address(0), "");

        PositionNFT nft = PositionNFT(pnft);
        address currentMinter = nft.minter();
        address currentDiamond = nft.diamond();

        if (currentMinter == address(0)) {
            nft.setMinter(diamond);
        } else {
            require(currentMinter == diamond, "ERC8004: PositionNFT minter not diamond");
        }

        if (currentDiamond != diamond) {
            require(currentMinter == diamond, "ERC8004: PositionNFT diamond mismatch and minter not diamond");
            nft.setDiamond(diamond);
        }

        console2.log("ERC-8004 facet wiring complete");
        vm.stopBroadcast();
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

    function _selectors(PositionNFTMetadataFacet viewFacet) internal pure returns (bytes4[] memory s) {
        s = viewFacet.selectors();
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

    function _appendCuts(
        IDiamondCut.FacetCut[] memory cuts,
        uint256 idx,
        address diamond,
        address facet,
        bytes4[] memory selectors
    ) internal view returns (uint256 newIdx) {
        IDiamondLoupe loupe = IDiamondLoupe(diamond);
        uint256 addCount;
        uint256 replaceCount;
        for (uint256 j; j < selectors.length; j++) {
            bytes4 sel = selectors[j];
            address existing = loupe.facetAddress(sel);
            if (existing == address(0)) {
                addCount++;
            } else if (existing != facet) {
                replaceCount++;
            }
        }

        if (replaceCount > 0) {
            bytes4[] memory replaceSelectors = new bytes4[](replaceCount);
            uint256 r;
            for (uint256 j; j < selectors.length; j++) {
                bytes4 sel = selectors[j];
                address existing = loupe.facetAddress(sel);
                if (existing != address(0) && existing != facet) {
                    replaceSelectors[r++] = sel;
                }
            }
            cuts[idx++] = _cut(facet, replaceSelectors, IDiamondCut.FacetCutAction.Replace);
        }

        if (addCount > 0) {
            bytes4[] memory addSelectors = new bytes4[](addCount);
            uint256 a;
            for (uint256 j; j < selectors.length; j++) {
                bytes4 sel = selectors[j];
                address existing = loupe.facetAddress(sel);
                if (existing == address(0)) {
                    addSelectors[a++] = sel;
                }
            }
            cuts[idx++] = _cut(facet, addSelectors, IDiamondCut.FacetCutAction.Add);
        }

        return idx;
    }
}
