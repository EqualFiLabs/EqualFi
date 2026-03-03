// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/Base64.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import {LibPositionAgentStorage} from "../libraries/LibPositionAgentStorage.sol";
import {LibPositionNFT} from "../libraries/LibPositionNFT.sol";
import {DirectError_InvalidPositionNFT} from "../libraries/Errors.sol";
import {PositionNFT} from "../nft/PositionNFT.sol";
import {IERC6551Registry} from "@agent-wallet-core/interfaces/IERC6551Registry.sol";

interface IIdentityRegistryMetadata {
    function ownerOf(uint256 tokenId) external view returns (address);
    function tokenURI(uint256 tokenId) external view returns (string memory);
}

/// @title PositionNFTMetadataFacet
/// @notice Generates unique generative cypherpunk SVG art for Position NFTs
/// @dev Uses deterministic pseudo-randomness from tokenId to create glitch grid patterns
contract PositionNFTMetadataFacet {
    /// @notice Returns a data URI for the Position NFT metadata.
    function getPositionTokenURI(uint256 positionTokenId) external view returns (string memory) {
        _requireExistingPosition(positionTokenId);

        string memory svgData = _generateSVG(positionTokenId);
        string memory imageURI = string(abi.encodePacked("data:image/svg+xml;base64,", Base64.encode(bytes(svgData))));

        string memory json = string(abi.encodePacked(
            '{"name":"Equalis Position #', Strings.toString(positionTokenId), '",',
            '"description":"Equalis Protocol Position NFT",',
            '"image":"', imageURI, '"}'
        ));

        return string(abi.encodePacked("data:application/json;base64,", Base64.encode(bytes(json))));
    }

    /// @notice Returns canonical ERC-8004 tokenURI for the linked agent if the link is valid.
    /// @dev Returns an empty string when no valid agent registration is linked to this Position NFT.
    function getAgentTokenURI(uint256 positionTokenId) external view returns (string memory) {
        address positionNFT = address(_requireExistingPosition(positionTokenId));
        (address identityRegistry, uint256 agentId, bool linked) = _resolveLinkedAgent(positionNFT, positionTokenId);
        if (!linked) {
            return "";
        }

        try IIdentityRegistryMetadata(identityRegistry).tokenURI(agentId) returns (string memory uri) {
            return uri;
        } catch {
            return "";
        }
    }

    /// @notice Returns the configured ERC-8004 agentId for a Position NFT (0 when unregistered).
    function getAgentIdOf(uint256 positionTokenId) external view returns (uint256) {
        _requireExistingPosition(positionTokenId);
        return LibPositionAgentStorage.s().positionToAgentId[positionTokenId];
    }

    /// @notice Returns true when positionTokenId has a valid agent registration owned by its computed TBA.
    function isAgentLinked(uint256 positionTokenId) external view returns (bool) {
        address positionNFT = address(_requireExistingPosition(positionTokenId));
        (, , bool linked) = _resolveLinkedAgent(positionNFT, positionTokenId);
        return linked;
    }

    /// @notice Returns a data URI for the Position NFT SVG image
    function tokenImageURI(uint256 tokenId) external view returns (string memory) {
        _requireExistingPosition(tokenId);
        return string(abi.encodePacked("data:image/svg+xml;base64,", Base64.encode(bytes(_generateSVG(tokenId)))));
    }

    /// @notice Get function selectors for this facet
    function selectors() external pure returns (bytes4[] memory selectorsArr) {
        selectorsArr = new bytes4[](5);
        selectorsArr[0] = PositionNFTMetadataFacet.getPositionTokenURI.selector;
        selectorsArr[1] = PositionNFTMetadataFacet.getAgentTokenURI.selector;
        selectorsArr[2] = PositionNFTMetadataFacet.getAgentIdOf.selector;
        selectorsArr[3] = PositionNFTMetadataFacet.isAgentLinked.selector;
        selectorsArr[4] = PositionNFTMetadataFacet.tokenImageURI.selector;
    }

    function _requireExistingPosition(uint256 tokenId) internal view returns (PositionNFT nft) {
        nft = _positionNFT();
        // Revert on invalid token by querying the position key.
        nft.getPositionKey(tokenId);
    }

    function _positionNFT() internal view returns (PositionNFT nft) {
        address nftAddr = LibPositionNFT.s().positionNFTContract;
        if (nftAddr == address(0)) {
            revert DirectError_InvalidPositionNFT();
        }
        nft = PositionNFT(nftAddr);
    }

    function _resolveLinkedAgent(address positionNFT, uint256 positionTokenId)
        internal
        view
        returns (address identityRegistry, uint256 agentId, bool linked)
    {
        LibPositionAgentStorage.AgentStorage storage ds = LibPositionAgentStorage.s();
        agentId = ds.positionToAgentId[positionTokenId];
        identityRegistry = ds.identityRegistry;
        address registry = ds.erc6551Registry;
        address implementation = ds.erc6551Implementation;

        if (agentId == 0 || identityRegistry == address(0) || registry == address(0) || implementation == address(0)) {
            return (identityRegistry, agentId, false);
        }

        address tbaAddress = IERC6551Registry(registry).account(
            implementation,
            ds.tbaSalt,
            block.chainid,
            positionNFT,
            positionTokenId
        );

        try IIdentityRegistryMetadata(identityRegistry).ownerOf(agentId) returns (address registryOwner) {
            linked = registryOwner == tbaAddress;
        } catch {
            linked = false;
        }
    }

    /// @notice Generate SVG image for the NFT with cypherpunk glitch aesthetic
    /// @param tokenId The token ID
    /// @return SVG string
    function _generateSVG(uint256 tokenId) internal pure returns (string memory) {
        uint256 rand = uint256(keccak256(abi.encodePacked(tokenId)));
        
        // RGB split offset for glitch effect
        uint256 offsetX = (rand >> 200) % 3 + 1;
        
        // Grid lines (neon green matrix background)
        string memory grid = string(abi.encodePacked(
            '<line x1="0" y1="100" x2="400" y2="100" stroke="#00ff41" stroke-width="0.5" opacity="0.4"/>',
            '<line x1="0" y1="200" x2="400" y2="200" stroke="#00ff41" stroke-width="0.5" opacity="0.4"/>',
            '<line x1="0" y1="300" x2="400" y2="300" stroke="#00ff41" stroke-width="0.5" opacity="0.4"/>',
            '<line x1="100" y1="0" x2="100" y2="400" stroke="#00ff41" stroke-width="0.5" opacity="0.4"/>',
            '<line x1="200" y1="0" x2="200" y2="400" stroke="#00ff41" stroke-width="0.5" opacity="0.4"/>',
            '<line x1="300" y1="0" x2="300" y2="400" stroke="#00ff41" stroke-width="0.5" opacity="0.4"/>'
        ));
        
        // Glitch blocks
        string memory glitchBlocks = string(abi.encodePacked(
            '<rect x="', Strings.toString(30 + ((rand >> 16) % 120)), '" y="', Strings.toString(40 + ((rand >> 24) % 80)),
            '" width="', Strings.toString(40 + ((rand >> 32) % 60)), '" height="', Strings.toString(5 + ((rand >> 40) % 15)),
            '" fill="#00ff41" opacity="0.', Strings.toString(15 + ((rand >> 48) % 20)), '"/>',
            '<rect x="', Strings.toString(180 + ((rand >> 56) % 140)), '" y="', Strings.toString(100 + ((rand >> 64) % 80)),
            '" width="', Strings.toString(30 + ((rand >> 72) % 50)), '" height="', Strings.toString(6 + ((rand >> 80) % 12)),
            '" fill="#ff0040" opacity="0.', Strings.toString(20 + ((rand >> 88) % 25)), '"/>',
            '<rect x="', Strings.toString(50 + ((rand >> 96) % 150)), '" y="', Strings.toString(200 + ((rand >> 104) % 100)),
            '" width="', Strings.toString(60 + ((rand >> 112) % 80)), '" height="', Strings.toString(4 + ((rand >> 120) % 10)),
            '" fill="#00d4ff" opacity="0.', Strings.toString(18 + ((rand >> 128) % 22)), '"/>'
        ));
        
        string memory moreBlocks = string(abi.encodePacked(
            '<rect x="', Strings.toString(200 + ((rand >> 136) % 100)), '" y="', Strings.toString(50 + ((rand >> 144) % 120)),
            '" width="', Strings.toString(35 + ((rand >> 152) % 45)), '" height="', Strings.toString(7 + ((rand >> 160) % 13)),
            '" fill="#b967ff" opacity="0.', Strings.toString(16 + ((rand >> 168) % 18)), '"/>',
            '<rect x="', Strings.toString(80 + ((rand >> 176) % 160)), '" y="', Strings.toString(280 + ((rand >> 184) % 80)),
            '" width="', Strings.toString(50 + ((rand >> 192) % 70)), '" height="', Strings.toString(5 + ((rand >> 200) % 12)),
            '" fill="#ff6b35" opacity="0.', Strings.toString(17 + ((rand >> 208) % 20)), '"/>'
        ));
        
        // Binary strings
        string memory binary = string(abi.encodePacked(
            '<text x="20" y="30" font-family="Courier New, monospace" font-size="8" fill="#00ff41" opacity="0.3">',
            ((rand >> 0) % 2 == 0 ? '10110101' : '01001110'), '</text>',
            '<text x="320" y="370" font-family="Courier New, monospace" font-size="8" fill="#00ff41" opacity="0.3">',
            ((rand >> 8) % 2 == 0 ? '11010011' : '00101101'), '</text>'
        ));
        
        // Hex fragments
        string memory hexFragments = string(abi.encodePacked(
            '<text x="', Strings.toString(30 + ((rand >> 216) % 80)), '" y="', Strings.toString(60 + ((rand >> 224) % 100)),
            '" font-family="Courier New, monospace" font-size="10" fill="#00ff41" opacity="0.4">0x', _toHex(uint16((rand >> 0) & 0xFFFF)), '</text>',
            '<text x="', Strings.toString(250 + ((rand >> 232) % 100)), '" y="', Strings.toString(120 + ((rand >> 240) % 120)),
            '" font-family="Courier New, monospace" font-size="10" fill="#ff0040" opacity="0.35">0x', _toHex(uint16((rand >> 16) & 0xFFFF)), '</text>',
            '<text x="', Strings.toString(100 + ((rand >> 248) % 150)), '" y="', Strings.toString(300 + ((rand >> 8) % 60)),
            '" font-family="Courier New, monospace" font-size="10" fill="#00d4ff" opacity="0.4">0x', _toHex(uint16((rand >> 32) & 0xFFFF)), '</text>'
        ));
        
        // Scanlines (light CRT effect)
        string memory scanlines = '<line x1="0" y1="150" x2="400" y2="150" stroke="#000000" stroke-width="1" opacity="0.3"/><line x1="0" y1="250" x2="400" y2="250" stroke="#000000" stroke-width="1" opacity="0.3"/>';
        
        return string(abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400">',
            '<rect width="400" height="400" fill="#0a0a0a"/>',
            grid, glitchBlocks, moreBlocks, binary, hexFragments, scanlines,
            // RGB split text effect
            '<text x="', Strings.toString(200 + offsetX), '" y="180" font-family="Courier New, monospace" font-size="18" fill="#ff0040" text-anchor="middle" opacity="0.7">EQUALIS POSITION</text>',
            '<text x="', Strings.toString(200 - offsetX), '" y="180" font-family="Courier New, monospace" font-size="18" fill="#00d4ff" text-anchor="middle" opacity="0.7">EQUALIS POSITION</text>',
            '<text x="200" y="180" font-family="Courier New, monospace" font-size="18" fill="#ffffff" text-anchor="middle" font-weight="bold">EQUALIS POSITION</text>',
            // Token ID with glow
            '<text x="200" y="240" font-family="Courier New, monospace" font-size="56" fill="#00ff41" text-anchor="middle" font-weight="bold">#',
            Strings.toString(tokenId), '</text>',
            '</svg>'
        ));
    }

    /// @notice Convert uint16 to 4-char hex string
    function _toHex(uint16 value) internal pure returns (string memory) {
        bytes memory hexChars = "0123456789abcdef";
        bytes memory result = new bytes(4);
        result[0] = hexChars[uint8(value >> 12)];
        result[1] = hexChars[uint8((value >> 8) & 0x0F)];
        result[2] = hexChars[uint8((value >> 4) & 0x0F)];
        result[3] = hexChars[uint8(value & 0x0F)];
        return string(result);
    }
}
