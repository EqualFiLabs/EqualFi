// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/Base64.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import {LibPositionNFT} from "../libraries/LibPositionNFT.sol";
import {DirectError_InvalidPositionNFT} from "../libraries/Errors.sol";
import {PositionNFT} from "../nft/PositionNFT.sol";

/// @title PositionNFTMetadataFacet
/// @notice Generates SVG image data for Position NFTs inside the Diamond
contract PositionNFTMetadataFacet {
    /// @notice Returns a data URI for the Position NFT SVG image
    function tokenImageURI(uint256 tokenId) external view returns (string memory) {
        PositionNFT nft = _positionNFT();
        // Revert on invalid token by querying the position key.
        nft.getPositionKey(tokenId);
        return string(abi.encodePacked("data:image/svg+xml;base64,", Base64.encode(bytes(_generateSVG(tokenId)))));
    }

    /// @notice Get function selectors for this facet
    function selectors() external pure returns (bytes4[] memory selectorsArr) {
        selectorsArr = new bytes4[](1);
        selectorsArr[0] = PositionNFTMetadataFacet.tokenImageURI.selector;
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
    /// @return Base64-encoded SVG
    function _generateSVG(uint256 tokenId) internal pure returns (string memory) {
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
                '<text x="200" y="250" font-family="Arial, sans-serif" font-size="18" fill="white" text-anchor="middle">Position NFT</text>',
                '</svg>'
            )
        );

        return svg;
    }
}
