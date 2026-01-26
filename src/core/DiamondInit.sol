// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibPositionNFT} from "../libraries/LibPositionNFT.sol";
import {PositionNFT} from "../nft/PositionNFT.sol";

/// @notice Initialization logic executed via diamondCut
contract DiamondInit {
    function init(address timelock_, address positionNFTContract_) external {
        LibAppStorage.AppStorage storage s = LibAppStorage.s();
        s.timelock = timelock_;
        
        // Initialize Position NFT storage only if a contract address is provided
        if (positionNFTContract_ != address(0)) {
            LibPositionNFT.PositionNFTStorage storage nftStorage = LibPositionNFT.s();
            nftStorage.positionNFTContract = positionNFTContract_;
            nftStorage.nftModeEnabled = true;
            
            // Set the Diamond as the minter for the PositionNFT contract
            PositionNFT(positionNFTContract_).setMinter(address(this));
            
            // Set the Diamond address in the PositionNFT contract for pool data queries
            PositionNFT(positionNFTContract_).setDiamond(address(this));
        }
    }
}
