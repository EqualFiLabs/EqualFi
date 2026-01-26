// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @title LibPositionNFT
/// @notice Library for Position NFT storage and position key derivation
/// @dev Position keys enable reuse of existing PoolData mappings for NFT-based positions
library LibPositionNFT {
    bytes32 internal constant POSITION_NFT_STORAGE_POSITION = 
        keccak256("equal.lend.position.nft.storage");

    struct PositionNFTStorage {
        address positionNFTContract;
        bool nftModeEnabled;
    }

    /// @notice Get the Position NFT storage
    /// @return ds The Position NFT storage struct
    function s() internal pure returns (PositionNFTStorage storage ds) {
        bytes32 position = POSITION_NFT_STORAGE_POSITION;
        assembly {
            ds.slot := position
        }
    }

    /// @notice Derive a position key from NFT contract address and token ID
    /// @dev Uses keccak256 hash to create a deterministic address-like key
    /// @param nftContract The address of the Position NFT contract
    /// @param tokenId The token ID of the Position NFT
    /// @return The derived position key as a bytes32 hash
    function getPositionKey(address nftContract, uint256 tokenId) 
        internal 
        pure 
        returns (bytes32) 
    {
        return keccak256(abi.encodePacked(nftContract, tokenId));
    }

    /// @notice Check if an address is an NFT position key
    /// @dev This is a placeholder - actual implementation would require reverse mapping
    /// @param key The address to check
    /// @return True if the address is an NFT position key
    function isNFTPosition(bytes32 key) internal view returns (bool) {
        // This would require additional storage to track which keys are NFT positions
        // For now, we rely on the NFT contract to manage this
        return s().nftModeEnabled && key != bytes32(0);
    }
}
