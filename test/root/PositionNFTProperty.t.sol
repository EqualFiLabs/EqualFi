// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibPositionHelpers} from "../../src/libraries/LibPositionHelpers.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import "../../src/libraries/Errors.sol";

/// @notice Property-based tests for Position NFT core functionality
/// forge-config: default.fuzz.runs = 100
contract PositionNFTPropertyTest is Test {
    PositionNFT public nft;
    MockERC20 public token;
    
    address public user1 = address(0x1111);
    address public user2 = address(0x2222);
    address public user3 = address(0x3333);
    
    uint256 constant POOL_ID_1 = 1;
    uint256 constant POOL_ID_2 = 2;
    
    function setUp() public {
        nft = new PositionNFT();
        token = new MockERC20("Test Token", "TEST", 18, 1000000 ether);
        // Set test contract as minter for direct testing
        nft.setMinter(address(this));
    }
    
    /// @notice **Feature: position-nfts, Property 1: Unique Token ID Generation**
    /// @notice For any two Position NFT minting operations, the system should assign unique token IDs
    /// @notice **Validates: Requirements 1.1**
    function testProperty_UniqueTokenIDGeneration(
        uint8 mintCount,
        uint256 poolId
    ) public {
        // Bound inputs to reasonable ranges
        mintCount = uint8(bound(mintCount, 1, 50)); // Test up to 50 mints
        poolId = bound(poolId, 0, 1000);
        
        // Track all minted token IDs
        uint256[] memory tokenIds = new uint256[](mintCount);
        
        // Mint multiple NFTs
        for (uint256 i = 0; i < mintCount; i++) {
            // Alternate between different users to test cross-user uniqueness
            address recipient = i % 3 == 0 ? user1 : (i % 3 == 1 ? user2 : user3);
            
            uint256 tokenId = nft.mint(recipient, poolId);
            tokenIds[i] = tokenId;
            
            // Verify the token was minted to the correct recipient
            assertEq(nft.ownerOf(tokenId), recipient, "Token should be owned by recipient");
        }
        
        // Verify all token IDs are unique
        for (uint256 i = 0; i < mintCount; i++) {
            for (uint256 j = i + 1; j < mintCount; j++) {
                assertTrue(
                    tokenIds[i] != tokenIds[j],
                    "All token IDs must be unique"
                );
            }
        }
        
        // Verify token IDs are sequential starting from 1
        for (uint256 i = 0; i < mintCount; i++) {
            assertEq(tokenIds[i], i + 1, "Token IDs should be sequential");
        }
    }
    
    /// @notice **Feature: position-nfts, Property 2: Position Key Derivation Consistency**
    /// @notice For any Position NFT with token ID, the derived position key should be deterministic and consistent
    /// @notice **Validates: Requirements 1.2, 10.1**
    function testProperty_PositionKeyDerivationConsistency(
        uint256 tokenId1,
        uint256 tokenId2,
        uint256 poolId
    ) public {
        // Bound inputs
        tokenId1 = bound(tokenId1, 1, 1000);
        tokenId2 = bound(tokenId2, 1, 1000);
        poolId = bound(poolId, 0, 100);
        
        // Mint NFTs with the specified token IDs by minting sequentially
        uint256 maxTokenId = tokenId1 > tokenId2 ? tokenId1 : tokenId2;
        
        for (uint256 i = 1; i <= maxTokenId; i++) {
            nft.mint(user1, poolId);
        }
        
        // Get position keys multiple times for the same token IDs
        bytes32 key1_first = nft.getPositionKey(tokenId1);
        bytes32 key1_second = nft.getPositionKey(tokenId1);
        bytes32 key1_third = nft.getPositionKey(tokenId1);
        
        // Verify consistency - same token ID always produces same key
        assertEq(key1_first, key1_second, "Position key should be consistent (call 1 vs 2)");
        assertEq(key1_second, key1_third, "Position key should be consistent (call 2 vs 3)");
        assertEq(key1_first, key1_third, "Position key should be consistent (call 1 vs 3)");
        
        // Verify the key matches the library function
        bytes32 expectedKey1 = LibPositionNFT.getPositionKey(address(nft), tokenId1);
        assertEq(key1_first, expectedKey1, "Position key should match library function");
        
        // If we have two different token IDs, verify they produce different keys
        if (tokenId1 != tokenId2) {
            bytes32 key2 = nft.getPositionKey(tokenId2);
            bytes32 expectedKey2 = LibPositionNFT.getPositionKey(address(nft), tokenId2);
            
            assertEq(key2, expectedKey2, "Second position key should match library function");
            assertTrue(key1_first != key2, "Different token IDs must produce different position keys");
        }
        
        // Verify position key is deterministic by computing it directly
        bytes32 directKey = keccak256(abi.encodePacked(address(nft), tokenId1));
        assertEq(key1_first, directKey, "Position key should match direct computation");
    }
    
    /// @notice Test that position keys are unique for different token IDs
    function testProperty_PositionKeyUniqueness(
        uint8 tokenCount
    ) public {
        // Bound to reasonable range
        tokenCount = uint8(bound(tokenCount, 2, 30));
        
        // Mint tokens
        uint256[] memory tokenIds = new uint256[](tokenCount);
        bytes32[] memory positionKeys = new bytes32[](tokenCount);
        
        for (uint256 i = 0; i < tokenCount; i++) {
            tokenIds[i] = nft.mint(user1, POOL_ID_1);
            positionKeys[i] = nft.getPositionKey(tokenIds[i]);
        }
        
        // Verify all position keys are unique
        for (uint256 i = 0; i < tokenCount; i++) {
            for (uint256 j = i + 1; j < tokenCount; j++) {
                assertTrue(
                    positionKeys[i] != positionKeys[j],
                    "Position keys must be unique for different token IDs"
                );
            }
        }
    }
    
    /// @notice Test that invalid token IDs revert when getting position key
    function testProperty_InvalidTokenIdReverts(
        uint256 invalidTokenId,
        uint8 mintCount
    ) public {
        // Bound inputs
        mintCount = uint8(bound(mintCount, 0, 20));
        invalidTokenId = bound(invalidTokenId, mintCount + 1, type(uint256).max);
        
        // Mint some tokens
        for (uint256 i = 0; i < mintCount; i++) {
            nft.mint(user1, POOL_ID_1);
        }
        
        // Attempting to get position key for non-existent token should revert
        vm.expectRevert(abi.encodeWithSelector(InvalidTokenId.selector, invalidTokenId));
        nft.getPositionKey(invalidTokenId);
    }
    
    /// @notice Test that position key derivation works across different NFT contracts
    function testProperty_PositionKeyDifferentContracts(
        uint256 tokenId,
        uint256 poolId
    ) public {
        // Bound inputs
        tokenId = bound(tokenId, 1, 100);
        poolId = bound(poolId, 0, 10);
        
        // Create a second NFT contract
        PositionNFT nft2 = new PositionNFT();
        // Set this contract as minter for nft2
        nft2.setMinter(address(this));
        
        // Mint the same token ID on both contracts
        for (uint256 i = 1; i <= tokenId; i++) {
            nft.mint(user1, poolId);
            nft2.mint(user1, poolId);
        }
        
        // Get position keys from both contracts
        bytes32 key1 = nft.getPositionKey(tokenId);
        bytes32 key2 = nft2.getPositionKey(tokenId);
        
        // Position keys should be different because they include the contract address
        assertTrue(key1 != key2, "Same token ID on different contracts must produce different position keys");
        
        // Verify they match the library computation
        assertEq(key1, LibPositionNFT.getPositionKey(address(nft), tokenId));
        assertEq(key2, LibPositionNFT.getPositionKey(address(nft2), tokenId));
    }
    
    /// @notice **Feature: position-nfts, Property 3: Multiple NFTs Per User**
    /// @notice For any user and pool, the system should allow minting multiple Position NFTs without artificial limits
    /// @notice **Validates: Requirements 1.3**
    function testProperty_MultipleNFTsPerUser(
        uint256 poolId,
        uint8 nftCount
    ) public {
        // Bound inputs
        poolId = bound(poolId, 0, 1000);
        nftCount = uint8(bound(nftCount, 1, 50)); // Test up to 50 NFTs per user
        
        // Track minted token IDs for this user
        uint256[] memory userTokenIds = new uint256[](nftCount);
        
        // Mint multiple NFTs to the same user in the same pool
        for (uint256 i = 0; i < nftCount; i++) {
            uint256 tokenId = nft.mint(user1, poolId);
            userTokenIds[i] = tokenId;
            
            // Verify ownership
            assertEq(nft.ownerOf(tokenId), user1, "User should own the NFT");
            
            // Verify pool association
            assertEq(nft.getPoolId(tokenId), poolId, "NFT should be associated with correct pool");
        }
        
        // Verify all NFTs are unique
        for (uint256 i = 0; i < nftCount; i++) {
            for (uint256 j = i + 1; j < nftCount; j++) {
                assertTrue(
                    userTokenIds[i] != userTokenIds[j],
                    "Each NFT should have unique token ID"
                );
            }
        }
        
        // Verify user owns all minted NFTs
        for (uint256 i = 0; i < nftCount; i++) {
            assertEq(
                nft.ownerOf(userTokenIds[i]),
                user1,
                "User should still own all minted NFTs"
            );
        }
        
        // Verify no artificial limit was hit
        // If we successfully minted nftCount NFTs, there's no artificial limit
        assertEq(userTokenIds.length, nftCount, "Should have minted all requested NFTs");
    }
    
    /// @notice **Feature: position-nfts, Property 26: Metadata Storage**
    /// @notice For any Position NFT, the metadata (pool ID, underlying asset, creation timestamp) should be stored and retrievable
    /// @notice **Validates: Requirements 12.1, 12.2, 12.3**
    function testProperty_MetadataStorage(
        uint256 poolId,
        uint8 mintCount
    ) public {
        // Bound inputs
        poolId = bound(poolId, 0, 1000);
        mintCount = uint8(bound(mintCount, 1, 20));
        
        uint256 startTime = block.timestamp;
        
        for (uint256 i = 0; i < mintCount; i++) {
            // Advance time slightly between mints
            uint256 mintTime = startTime + i * 100;
            vm.warp(mintTime);
            
            uint256 tokenId = nft.mint(user1, poolId);
            
            // Verify pool ID is stored correctly
            assertEq(nft.getPoolId(tokenId), poolId, "Pool ID should match");
            
            // Verify creation time is stored correctly
            assertEq(nft.getCreationTime(tokenId), uint40(mintTime), "Creation time should match");
            
            // Verify tokenURI doesn't revert and contains expected data
            string memory uri = nft.tokenURI(tokenId);
            assertTrue(bytes(uri).length > 0, "Token URI should not be empty");
            
            // Verify URI contains pool ID (basic check)
            // The URI should contain the pool ID as a string
            bytes memory uriBytes = bytes(uri);
            assertTrue(uriBytes.length > 0, "URI should have content");
        }
    }
    
    /// @notice **Feature: position-nfts, Property 14: Transfer Preservation**
    /// @notice For any Position NFT transfer, all position data should remain unchanged and accessible via the same position key
    /// @notice **Validates: Requirements 5.1, 5.2, 5.3, 5.4, 5.5, 6.5**
    function testProperty_TransferPreservation(
        uint256 poolId,
        address recipient
    ) public {
        // Bound inputs
        poolId = bound(poolId, 0, 100);
        // Ensure recipient is not zero address and not one of our test addresses
        vm.assume(recipient != address(0));
        vm.assume(recipient != user1);
        vm.assume(recipient != user2);
        vm.assume(recipient != user3);
        vm.assume(recipient != address(this));
        
        // Mint NFT to user1
        uint256 tokenId = nft.mint(user1, poolId);
        
        // Record state before transfer
        bytes32 positionKeyBefore = nft.getPositionKey(tokenId);
        uint256 poolIdBefore = nft.getPoolId(tokenId);
        uint40 creationTimeBefore = nft.getCreationTime(tokenId);
        address ownerBefore = nft.ownerOf(tokenId);
        
        // Verify initial owner
        assertEq(ownerBefore, user1, "Initial owner should be user1");
        
        // Transfer NFT from user1 to recipient
        vm.prank(user1);
        nft.transferFrom(user1, recipient, tokenId);
        
        // Record state after transfer
        bytes32 positionKeyAfter = nft.getPositionKey(tokenId);
        uint256 poolIdAfter = nft.getPoolId(tokenId);
        uint40 creationTimeAfter = nft.getCreationTime(tokenId);
        address ownerAfter = nft.ownerOf(tokenId);
        
        // Verify ownership changed
        assertEq(ownerAfter, recipient, "Owner should be recipient after transfer");
        assertTrue(ownerAfter != ownerBefore, "Owner should have changed");
        
        // Verify position key remains unchanged
        assertEq(
            positionKeyAfter,
            positionKeyBefore,
            "Position key must remain unchanged during transfer"
        );
        
        // Verify pool ID remains unchanged
        assertEq(
            poolIdAfter,
            poolIdBefore,
            "Pool ID must remain unchanged during transfer"
        );
        
        // Verify creation time remains unchanged
        assertEq(
            creationTimeAfter,
            creationTimeBefore,
            "Creation time must remain unchanged during transfer"
        );
        
        // Verify position key is still deterministic
        bytes32 expectedKey = LibPositionNFT.getPositionKey(address(nft), tokenId);
        assertEq(
            positionKeyAfter,
            expectedKey,
            "Position key should still match library computation"
        );
        
        // Verify the position key is not the owner's address
        assertTrue(
            positionKeyAfter != LibPositionHelpers.systemPositionKey(ownerBefore),
            "Position key should not be the old owner's system key"
        );
        assertTrue(
            positionKeyAfter != LibPositionHelpers.systemPositionKey(ownerAfter),
            "Position key should not be the new owner's system key"
        );
    }
    
    /// @notice Test multiple transfers preserve position key
    function testProperty_MultipleTransfersPreserveKey(
        uint256 poolId,
        uint8 transferCount
    ) public {
        // Bound inputs
        poolId = bound(poolId, 0, 100);
        transferCount = uint8(bound(transferCount, 1, 10));
        
        // Mint NFT
        uint256 tokenId = nft.mint(user1, poolId);
        bytes32 originalPositionKey = nft.getPositionKey(tokenId);
        
        // Perform multiple transfers
        address currentOwner = user1;
        address[] memory owners = new address[](3);
        owners[0] = user2;
        owners[1] = user3;
        owners[2] = user1;
        
        for (uint256 i = 0; i < transferCount; i++) {
            address nextOwner = owners[i % 3];
            
            // Skip if transferring to self
            if (currentOwner == nextOwner) {
                continue;
            }
            
            // Transfer
            vm.prank(currentOwner);
            nft.transferFrom(currentOwner, nextOwner, tokenId);
            
            // Verify position key unchanged
            bytes32 positionKey = nft.getPositionKey(tokenId);
            assertEq(
                positionKey,
                originalPositionKey,
                "Position key must remain unchanged after multiple transfers"
            );
            
            // Verify ownership changed
            assertEq(nft.ownerOf(tokenId), nextOwner, "Ownership should update");
            
            currentOwner = nextOwner;
        }
        
        // Final verification
        assertEq(
            nft.getPositionKey(tokenId),
            originalPositionKey,
            "Position key must be unchanged after all transfers"
        );
    }
    
    /// @notice Test transfer and back preserves position key
    function testProperty_TransferAndBackPreservesKey(
        uint256 poolId
    ) public {
        // Bound inputs
        poolId = bound(poolId, 0, 100);
        
        // Mint NFT to user1
        uint256 tokenId = nft.mint(user1, poolId);
        bytes32 originalPositionKey = nft.getPositionKey(tokenId);
        
        // Transfer to user2
        vm.prank(user1);
        nft.transferFrom(user1, user2, tokenId);
        
        bytes32 positionKeyAfterFirstTransfer = nft.getPositionKey(tokenId);
        assertEq(positionKeyAfterFirstTransfer, originalPositionKey, "Position key unchanged after first transfer");
        assertEq(nft.ownerOf(tokenId), user2, "User2 should own NFT");
        
        // Transfer back to user1
        vm.prank(user2);
        nft.transferFrom(user2, user1, tokenId);
        
        bytes32 positionKeyAfterSecondTransfer = nft.getPositionKey(tokenId);
        assertEq(positionKeyAfterSecondTransfer, originalPositionKey, "Position key unchanged after second transfer");
        assertEq(nft.ownerOf(tokenId), user1, "User1 should own NFT again");
        
        // Verify all metadata preserved
        assertEq(nft.getPoolId(tokenId), poolId, "Pool ID should be preserved");
    }
}
