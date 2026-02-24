// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../src/interfaces/IDiamondLoupe.sol";
import {PositionNFTMetadataFacet} from "../src/views/PositionNFTMetadataFacet.sol";

contract UpgradeMetadataFacet is Script {
    function run() external {
        address diamond = vm.envAddress("DIAMOND_ADDRESS");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        console2.log("Diamond address:", diamond);
        console2.log("Broadcaster address:", vm.addr(deployerPrivateKey));
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy new facet
        PositionNFTMetadataFacet newFacet = new PositionNFTMetadataFacet();
        console2.log("New PositionNFTMetadataFacet deployed at:", address(newFacet));
        
        // Get selectors
        bytes4[] memory selectors = newFacet.selectors();
        
        // Separate selectors into Add and Replace
        bytes4[] memory addSelectors = new bytes4[](selectors.length);
        bytes4[] memory replaceSelectors = new bytes4[](selectors.length);
        uint256 addCount = 0;
        uint256 replaceCount = 0;
        
        for (uint256 i = 0; i < selectors.length; i++) {
            try IDiamondLoupe(diamond).facetAddress(selectors[i]) returns (address existingFacet) {
                if (existingFacet != address(0)) {
                    replaceSelectors[replaceCount++] = selectors[i];
                } else {
                    addSelectors[addCount++] = selectors[i];
                }
            } catch {
                addSelectors[addCount++] = selectors[i];
            }
        }
        
        // Build cuts array
        uint256 cutCount = 0;
        if (addCount > 0) cutCount++;
        if (replaceCount > 0) cutCount++;
        
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](cutCount);
        uint256 cutIndex = 0;
        
        if (addCount > 0) {
            bytes4[] memory finalAddSelectors = new bytes4[](addCount);
            for (uint256 i = 0; i < addCount; i++) {
                finalAddSelectors[i] = addSelectors[i];
            }
            cut[cutIndex++] = IDiamondCut.FacetCut({
                facetAddress: address(newFacet),
                action: IDiamondCut.FacetCutAction.Add,
                functionSelectors: finalAddSelectors
            });
        }
        
        if (replaceCount > 0) {
            bytes4[] memory finalReplaceSelectors = new bytes4[](replaceCount);
            for (uint256 i = 0; i < replaceCount; i++) {
                finalReplaceSelectors[i] = replaceSelectors[i];
            }
            cut[cutIndex++] = IDiamondCut.FacetCut({
                facetAddress: address(newFacet),
                action: IDiamondCut.FacetCutAction.Replace,
                functionSelectors: finalReplaceSelectors
            });
        }
        
        // Execute upgrade
        IDiamondCut(diamond).diamondCut(cut, address(0), "");
        console2.log("PositionNFTMetadataFacet upgraded successfully");
        console2.log("Added selectors:", addCount);
        console2.log("Replaced selectors:", replaceCount);
        
        vm.stopBroadcast();
    }
}
