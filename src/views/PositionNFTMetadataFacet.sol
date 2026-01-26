// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/Base64.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import {LibPositionNFT} from "../libraries/LibPositionNFT.sol";
import {LibPositionHelpers} from "../libraries/LibPositionHelpers.sol";
import {Types} from "../libraries/Types.sol";
import {DirectError_InvalidPositionNFT} from "../libraries/Errors.sol";
import {PositionNFT} from "../nft/PositionNFT.sol";

/// @title PositionNFTMetadataFacet
/// @notice Generates Position NFT metadata + SVG inside the Diamond for upgradeable rendering
contract PositionNFTMetadataFacet {
    /// @notice ERC-721 metadata renderer for Position NFTs
    function tokenURI(uint256 tokenId) external view returns (string memory) {
        PositionNFT nft = _positionNFT();
        uint256 poolId = nft.getPoolId(tokenId);
        uint40 createdAt = nft.getCreationTime(tokenId);
        bytes32 positionKey = LibPositionNFT.getPositionKey(address(nft), tokenId);

        Types.PoolData storage p = LibPositionHelpers.pool(poolId);
        address underlyingAsset = p.underlying;

        string memory json = string(
            abi.encodePacked(
                '{"name":"EqualLend Position #',
                Strings.toString(tokenId),
                '","description":"Isolated account container in EqualLend protocol. This NFT represents a position that can hold deposits, originate loans, and accrue yield. Transferring this NFT transfers all associated deposits and obligations.",',
                '"image":"data:image/svg+xml;base64,',
                _generateSVG(tokenId, poolId),
                '","attributes":[',
                '{"trait_type":"Pool ID","value":',
                Strings.toString(poolId),
                '},',
                '{"trait_type":"Underlying Asset","value":"',
                Strings.toHexString(uint160(underlyingAsset), 20),
                '"},',
                '{"trait_type":"Created At","value":',
                Strings.toString(uint256(createdAt)),
                '},',
                '{"trait_type":"Position Key","value":"',
                Strings.toHexString(uint256(positionKey), 32),
                '"}',
                ']}'
            )
        );

        return string(abi.encodePacked("data:application/json;base64,", Base64.encode(bytes(json))));
    }

    /// @notice Get function selectors for this facet
    function selectors() external pure returns (bytes4[] memory selectorsArr) {
        selectorsArr = new bytes4[](1);
        selectorsArr[0] = PositionNFTMetadataFacet.tokenURI.selector;
    }

    function _positionNFT() internal view returns (PositionNFT nft) {
        address nftAddr = LibPositionNFT.s().positionNFTContract;
        if (nftAddr == address(0)) {
            revert DirectError_InvalidPositionNFT();
        }
        nft = PositionNFT(nftAddr);
    }

    /// @notice Generate SVG image for the NFT
    /// @param tokenId The token ID
    /// @param poolId The pool ID
    /// @return Base64-encoded SVG
    function _generateSVG(uint256 tokenId, uint256 poolId) internal pure returns (string memory) {
        string memory svg = string(
            abi.encodePacked(
                '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400">',
                '<defs>',
                '<linearGradient id="grad" x1="0%" y1="0%" x2="100%" y2="100%">',
                '<stop offset="0%" style="stop-color:#667eea;stop-opacity:1" />',
                '<stop offset="100%" style="stop-color:#764ba2;stop-opacity:1" />',
                '</linearGradient>',
                '</defs>',
                '<rect width="400" height="400" fill="url(#grad)"/>',
                '<text x="200" y="150" font-family="Arial, sans-serif" font-size="24" fill="white" text-anchor="middle" font-weight="bold">EqualLend Position</text>',
                '<text x="200" y="200" font-family="Arial, sans-serif" font-size="48" fill="white" text-anchor="middle" font-weight="bold">#',
                Strings.toString(tokenId),
                '</text>',
                '<text x="200" y="250" font-family="Arial, sans-serif" font-size="18" fill="white" text-anchor="middle">Pool ',
                Strings.toString(poolId),
                '</text>',
                '</svg>'
            )
        );

        return Base64.encode(bytes(svg));
    }
}
