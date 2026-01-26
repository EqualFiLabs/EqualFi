// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title PositionNFTMetadataProperty
/// @notice Property-based tests for ERC-721 metadata compliance
/// @dev **Feature: position-nfts, Property 27: ERC-721 Compliance**
/// @dev **Validates: Requirements 12.4**
contract PositionNFTMetadataProperty is Test {
    PositionNFT positionNFT;

    address user1 = address(0x1);
    address user2 = address(0x2);
    address mockDiamond = address(0x9999);
    address mockToken = address(0x8888);

    uint256 constant POOL_ID = 1;

    function setUp() public {
        // Deploy Position NFT
        positionNFT = new PositionNFT();
        positionNFT.setMinter(address(this));
        
        // Mock the diamond to return a mock token address
        vm.mockCall(
            mockDiamond,
            abi.encodeWithSignature("getPoolUnderlying(uint256)", POOL_ID),
            abi.encode(mockToken)
        );
        
        positionNFT.setDiamond(mockDiamond);
    }

    /// @notice Property 27: ERC-721 Compliance
    /// @dev For any Position NFT, tokenURI should return valid base64-encoded JSON metadata
    function testFuzz_TokenURIReturnsValidBase64JSON(uint8 numTokens) public {
        vm.assume(numTokens > 0 && numTokens <= 10);

        uint256[] memory tokenIds = new uint256[](numTokens);

        // Mint multiple tokens
        for (uint256 i = 0; i < numTokens; i++) {
            tokenIds[i] = positionNFT.mint(user1, POOL_ID);
        }

        // Verify each token has valid metadata
        for (uint256 i = 0; i < numTokens; i++) {
            string memory uri = positionNFT.tokenURI(tokenIds[i]);

            // Should start with data URI prefix
            assertTrue(
                _startsWith(uri, "data:application/json;base64,"),
                "Token URI should start with data URI prefix"
            );

            // Extract base64 part
            string memory base64Part = _substring(uri, 29, bytes(uri).length);

            // Decode base64
            bytes memory decoded = Base64.decode(base64Part);
            string memory json = string(decoded);

            // Verify JSON contains required fields
            assertTrue(_contains(json, '"name"'), "JSON should contain name field");
            assertTrue(_contains(json, '"description"'), "JSON should contain description field");
            assertTrue(_contains(json, '"image"'), "JSON should contain image field");
            assertTrue(_contains(json, '"attributes"'), "JSON should contain attributes field");

            // Verify attributes contain required trait types
            assertTrue(_contains(json, '"trait_type":"Pool ID"'), "Should contain Pool ID trait");
            assertTrue(_contains(json, '"trait_type":"Underlying Asset"'), "Should contain Underlying Asset trait");
            assertTrue(_contains(json, '"trait_type":"Created At"'), "Should contain Created At trait");
            assertTrue(_contains(json, '"trait_type":"Position Key"'), "Should contain Position Key trait");

            // Verify token ID is in the name
            assertTrue(
                _contains(json, Strings.toString(tokenIds[i])),
                "JSON should contain token ID"
            );

            // Verify pool ID is in attributes
            assertTrue(
                _contains(json, Strings.toString(POOL_ID)),
                "JSON should contain pool ID"
            );
        }
    }

    /// @notice Property 27: Metadata includes pool ID
    /// @dev For any Position NFT, metadata should include the correct pool ID
    function testFuzz_MetadataIncludesPoolID(uint256 tokenId) public {
        vm.assume(tokenId > 0 && tokenId < 100);

        uint256 actualTokenId = positionNFT.mint(user1, POOL_ID);

        string memory uri = positionNFT.tokenURI(actualTokenId);
        string memory base64Part = _substring(uri, 29, bytes(uri).length);
        bytes memory decoded = Base64.decode(base64Part);
        string memory json = string(decoded);

        // Verify pool ID is present
        assertTrue(
            _contains(json, Strings.toString(POOL_ID)),
            "Metadata should include pool ID"
        );
    }

    /// @notice Property 27: Metadata includes underlying asset
    /// @dev For any Position NFT, metadata should include the underlying asset address
    function testFuzz_MetadataIncludesUnderlyingAsset(address randomUser) public {
        vm.assume(randomUser != address(0) && randomUser.code.length == 0);

        uint256 tokenId = positionNFT.mint(randomUser, POOL_ID);

        string memory uri = positionNFT.tokenURI(tokenId);
        string memory base64Part = _substring(uri, 29, bytes(uri).length);
        bytes memory decoded = Base64.decode(base64Part);
        string memory json = string(decoded);

        // Verify underlying asset address is present
        string memory expectedAddress = Strings.toHexString(uint160(mockToken), 20);
        assertTrue(
            _contains(json, expectedAddress),
            "Metadata should include underlying asset address"
        );
    }

    /// @notice Property 27: Metadata includes creation timestamp
    /// @dev For any Position NFT, metadata should include the creation timestamp
    function testFuzz_MetadataIncludesCreationTimestamp(uint256 warpTime) public {
        vm.assume(warpTime > block.timestamp && warpTime < block.timestamp + 365 days);

        vm.warp(warpTime);

        uint256 tokenId = positionNFT.mint(user1, POOL_ID);

        string memory uri = positionNFT.tokenURI(tokenId);
        string memory base64Part = _substring(uri, 29, bytes(uri).length);
        bytes memory decoded = Base64.decode(base64Part);
        string memory json = string(decoded);

        // Verify creation timestamp is present
        assertTrue(
            _contains(json, Strings.toString(warpTime)),
            "Metadata should include creation timestamp"
        );
    }

    /// @notice Property 27: Metadata includes position key
    /// @dev For any Position NFT, metadata should include the derived position key
    function testFuzz_MetadataIncludesPositionKey(address randomUser) public {
        vm.assume(randomUser != address(0) && randomUser.code.length == 0);

        uint256 tokenId = positionNFT.mint(randomUser, POOL_ID);

        bytes32 positionKey = positionNFT.getPositionKey(tokenId);
        string memory uri = positionNFT.tokenURI(tokenId);
        string memory base64Part = _substring(uri, 29, bytes(uri).length);
        bytes memory decoded = Base64.decode(base64Part);
        string memory json = string(decoded);

        // Verify position key is present
        string memory expectedKey = Strings.toHexString(uint256(positionKey), 32);
        assertTrue(
            _contains(json, expectedKey),
            "Metadata should include position key"
        );
    }

    /// @notice Property 27: Image is base64-encoded SVG
    /// @dev For any Position NFT, the image field should contain a base64-encoded SVG
    function testFuzz_ImageIsBase64EncodedSVG(uint8 numTokens) public {
        vm.assume(numTokens > 0 && numTokens <= 5);

        for (uint256 i = 0; i < numTokens; i++) {
            uint256 tokenId = positionNFT.mint(user1, POOL_ID);

            string memory uri = positionNFT.tokenURI(tokenId);
            string memory base64Part = _substring(uri, 29, bytes(uri).length);
            bytes memory decoded = Base64.decode(base64Part);
            string memory json = string(decoded);

            // Verify image field contains SVG data URI
            assertTrue(
                _contains(json, '"image":"data:image/svg+xml;base64,'),
                "Image should be base64-encoded SVG"
            );
        }
    }

    // Helper functions
    function _startsWith(string memory str, string memory prefix) internal pure returns (bool) {
        bytes memory strBytes = bytes(str);
        bytes memory prefixBytes = bytes(prefix);

        if (strBytes.length < prefixBytes.length) {
            return false;
        }

        for (uint256 i = 0; i < prefixBytes.length; i++) {
            if (strBytes[i] != prefixBytes[i]) {
                return false;
            }
        }

        return true;
    }

    function _substring(string memory str, uint256 start, uint256 end) internal pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        bytes memory result = new bytes(end - start);

        for (uint256 i = start; i < end; i++) {
            result[i - start] = strBytes[i];
        }

        return string(result);
    }

    function _contains(string memory str, string memory substr) internal pure returns (bool) {
        bytes memory strBytes = bytes(str);
        bytes memory substrBytes = bytes(substr);

        if (substrBytes.length > strBytes.length) {
            return false;
        }

        for (uint256 i = 0; i <= strBytes.length - substrBytes.length; i++) {
            bool found = true;
            for (uint256 j = 0; j < substrBytes.length; j++) {
                if (strBytes[i + j] != substrBytes[j]) {
                    found = false;
                    break;
                }
            }
            if (found) {
                return true;
            }
        }

        return false;
    }
}
