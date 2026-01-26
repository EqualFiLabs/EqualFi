// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

contract RevertingDiamond {
    function getPoolUnderlying(uint256) external pure returns (address) {
        revert("diamond call failed");
    }
}

/// @title PositionNFTMetadataUnit
/// @notice Unit tests for ERC-721 metadata compliance
/// @dev Tests Requirements 12.4
contract PositionNFTMetadataUnit is Test {
    PositionNFT positionNFT;

    address user1 = address(0x1);
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

    /// @notice Test tokenURI returns valid JSON
    function test_TokenURIReturnsValidJSON() public {
        uint256 tokenId = positionNFT.mint(user1, POOL_ID);

        string memory uri = positionNFT.tokenURI(tokenId);

        // Should start with data URI prefix
        assertTrue(
            _startsWith(uri, "data:application/json;base64,"),
            "Token URI should start with data URI prefix"
        );

        // Extract and decode base64
        string memory base64Part = _substring(uri, 29, bytes(uri).length);
        bytes memory decoded = Base64.decode(base64Part);
        string memory json = string(decoded);

        // Verify it's valid JSON by checking for required fields
        assertTrue(_contains(json, "{"), "Should contain opening brace");
        assertTrue(_contains(json, "}"), "Should contain closing brace");
        assertTrue(_contains(json, '"name"'), "Should contain name field");
        assertTrue(_contains(json, '"description"'), "Should contain description field");
    }

    /// @notice Test metadata includes all required fields
    function test_MetadataIncludesAllRequiredFields() public {
        uint256 tokenId = positionNFT.mint(user1, POOL_ID);

        string memory uri = positionNFT.tokenURI(tokenId);
        string memory base64Part = _substring(uri, 29, bytes(uri).length);
        bytes memory decoded = Base64.decode(base64Part);
        string memory json = string(decoded);

        // Check all required fields
        assertTrue(_contains(json, '"name"'), "Should contain name");
        assertTrue(_contains(json, '"description"'), "Should contain description");
        assertTrue(_contains(json, '"image"'), "Should contain image");
        assertTrue(_contains(json, '"attributes"'), "Should contain attributes");

        // Check required attributes
        assertTrue(_contains(json, '"trait_type":"Pool ID"'), "Should contain Pool ID");
        assertTrue(_contains(json, '"trait_type":"Underlying Asset"'), "Should contain Underlying Asset");
        assertTrue(_contains(json, '"trait_type":"Created At"'), "Should contain Created At");
        assertTrue(_contains(json, '"trait_type":"Position Key"'), "Should contain Position Key");
    }

    /// @notice Test metadata conforms to ERC-721 standard
    function test_MetadataConformsToERC721Standard() public {
        uint256 tokenId = positionNFT.mint(user1, POOL_ID);

        string memory uri = positionNFT.tokenURI(tokenId);

        // ERC-721 standard requires tokenURI to return a valid URI
        assertTrue(bytes(uri).length > 0, "URI should not be empty");

        // Should be a data URI with base64 encoding
        assertTrue(
            _startsWith(uri, "data:application/json;base64,"),
            "Should be a data URI with JSON and base64"
        );

        // Decode and verify structure
        string memory base64Part = _substring(uri, 29, bytes(uri).length);
        bytes memory decoded = Base64.decode(base64Part);
        string memory json = string(decoded);

        // ERC-721 metadata standard requires these fields
        assertTrue(_contains(json, '"name"'), "ERC-721 requires name");
        assertTrue(_contains(json, '"description"'), "ERC-721 requires description");
        assertTrue(_contains(json, '"image"'), "ERC-721 requires image");

        // Attributes are optional but should be properly formatted if present
        assertTrue(_contains(json, '"attributes":['), "Attributes should be an array");
    }

    /// @notice Test metadata includes pool ID
    function test_MetadataIncludesPoolID() public {
        uint256 tokenId = positionNFT.mint(user1, POOL_ID);

        string memory uri = positionNFT.tokenURI(tokenId);
        string memory base64Part = _substring(uri, 29, bytes(uri).length);
        bytes memory decoded = Base64.decode(base64Part);
        string memory json = string(decoded);

        // Should contain pool ID in attributes
        assertTrue(
            _contains(json, Strings.toString(POOL_ID)),
            "Should contain pool ID"
        );
        assertTrue(
            _contains(json, '"trait_type":"Pool ID"'),
            "Should have Pool ID trait"
        );
    }

    /// @notice Test metadata includes underlying asset
    function test_MetadataIncludesUnderlyingAsset() public {
        uint256 tokenId = positionNFT.mint(user1, POOL_ID);

        string memory uri = positionNFT.tokenURI(tokenId);
        string memory base64Part = _substring(uri, 29, bytes(uri).length);
        bytes memory decoded = Base64.decode(base64Part);
        string memory json = string(decoded);

        // Should contain underlying asset address
        string memory expectedAddress = Strings.toHexString(uint160(mockToken), 20);
        assertTrue(
            _contains(json, expectedAddress),
            "Should contain underlying asset address"
        );
        assertTrue(
            _contains(json, '"trait_type":"Underlying Asset"'),
            "Should have Underlying Asset trait"
        );
    }

    /// @notice Test metadata includes creation timestamp
    function test_MetadataIncludesCreationTimestamp() public {
        uint256 mintTime = block.timestamp;

        uint256 tokenId = positionNFT.mint(user1, POOL_ID);

        string memory uri = positionNFT.tokenURI(tokenId);
        string memory base64Part = _substring(uri, 29, bytes(uri).length);
        bytes memory decoded = Base64.decode(base64Part);
        string memory json = string(decoded);

        // Should contain creation timestamp
        assertTrue(
            _contains(json, Strings.toString(mintTime)),
            "Should contain creation timestamp"
        );
        assertTrue(
            _contains(json, '"trait_type":"Created At"'),
            "Should have Created At trait"
        );
    }

    /// @notice Test metadata includes position key
    function test_MetadataIncludesPositionKey() public {
        uint256 tokenId = positionNFT.mint(user1, POOL_ID);

        bytes32 positionKey = positionNFT.getPositionKey(tokenId);
        string memory uri = positionNFT.tokenURI(tokenId);
        string memory base64Part = _substring(uri, 29, bytes(uri).length);
        bytes memory decoded = Base64.decode(base64Part);
        string memory json = string(decoded);

        // Should contain position key
        string memory expectedKey = Strings.toHexString(uint256(positionKey), 32);
        assertTrue(
            _contains(json, expectedKey),
            "Should contain position key"
        );
        assertTrue(
            _contains(json, '"trait_type":"Position Key"'),
            "Should have Position Key trait"
        );
    }

    /// @notice Test image is base64-encoded SVG
    function test_ImageIsBase64EncodedSVG() public {
        uint256 tokenId = positionNFT.mint(user1, POOL_ID);

        string memory uri = positionNFT.tokenURI(tokenId);
        string memory base64Part = _substring(uri, 29, bytes(uri).length);
        bytes memory decoded = Base64.decode(base64Part);
        string memory json = string(decoded);

        // Image should be a data URI with base64-encoded SVG
        assertTrue(
            _contains(json, '"image":"data:image/svg+xml;base64,'),
            "Image should be base64-encoded SVG"
        );
    }

    /// @notice Test tokenURI reverts for non-existent token
    function test_TokenURIRevertsForNonExistentToken() public {
        vm.expectRevert();
        positionNFT.tokenURI(999);
    }

    /// @notice Test metadata is unique for different tokens
    function test_MetadataIsUniqueForDifferentTokens() public {
        uint256 tokenId1 = positionNFT.mint(user1, POOL_ID);

        vm.warp(block.timestamp + 1 days);

        uint256 tokenId2 = positionNFT.mint(user1, POOL_ID);

        string memory uri1 = positionNFT.tokenURI(tokenId1);
        string memory uri2 = positionNFT.tokenURI(tokenId2);

        // URIs should be different
        assertFalse(
            keccak256(bytes(uri1)) == keccak256(bytes(uri2)),
            "Different tokens should have different metadata"
        );
    }

    /// @notice Only the current minter can update the minter address
    function test_SetMinterRespectsMinterOnlyAuth() public {
        address attacker = address(0xAAAA);

        vm.prank(attacker);
        vm.expectRevert(bytes("PositionNFT: unauthorized"));
        positionNFT.setMinter(attacker);
    }

    /// @notice Only the minter can update the diamond address after initialization
    function test_SetDiamondRespectsMinterOnlyAuth() public {
        address attacker = address(0xBBBB);

        vm.prank(attacker);
        vm.expectRevert(bytes("PositionNFT: unauthorized"));
        positionNFT.setDiamond(attacker);
    }

    /// @notice tokenURI should not revert if diamond call fails and should fall back to zero address
    function test_TokenURIFallsBackWhenDiamondCallReverts() public {
        // Point diamond to a contract that reverts
        RevertingDiamond revertingDiamond = new RevertingDiamond();
        positionNFT.setDiamond(address(revertingDiamond));

        uint256 tokenId = positionNFT.mint(user1, POOL_ID);

        string memory uri = positionNFT.tokenURI(tokenId);
        string memory base64Part = _substring(uri, 29, bytes(uri).length);
        bytes memory decoded = Base64.decode(base64Part);
        string memory json = string(decoded);

        // Underlying asset trait should fall back to zero address
        string memory zeroAddr = Strings.toHexString(uint160(address(0)), 20);
        assertTrue(_contains(json, zeroAddr), "Should use zero address when diamond query fails");
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
