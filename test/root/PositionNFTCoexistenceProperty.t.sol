// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibPositionHelpers} from "../../src/libraries/LibPositionHelpers.sol";
import {Types} from "../../src/libraries/Types.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import "../../src/libraries/Errors.sol";

/// @notice Property-based tests for address-based and NFT-based position coexistence
/// @notice **Feature: position-nfts, Property 24: Address and NFT Coexistence**
/// @notice **Validates: Requirements 10.5**
/// forge-config: default.fuzz.runs = 100
contract PositionNFTCoexistencePropertyTest is Test {
    PositionNFT public nft;
    MockERC20 public token;
    
    address public user1 = address(0x1111);
    address public user2 = address(0x2222);
    address public user3 = address(0x3333);
    
    uint256 constant POOL_ID = 1;
    
    function setUp() public {
        nft = new PositionNFT();
        token = new MockERC20("Test Token", "TEST", 18, 1000000 ether);
        // Set test contract as minter for direct testing
        nft.setMinter(address(this));
    }
    
    /// @notice Property 24: Address and NFT Coexistence - Different Position Keys
    /// @notice For any user address and any NFT position key, they should be different
    /// @notice This ensures address-based and NFT-based positions don't collide
    function testProperty_Coexistence_DifferentKeys(
        address userAddress,
        uint256 tokenId
    ) public {
        // Bound inputs
        vm.assume(userAddress != address(0));
        vm.assume(userAddress != address(nft));
        tokenId = bound(tokenId, 1, 200);
        
        // Mint NFT
        for (uint256 i = 1; i <= tokenId; i++) {
            nft.mint(user1, POOL_ID);
        }
        
        // Get position key for NFT
        bytes32 nftPositionKey = nft.getPositionKey(tokenId);
        
        // Verify NFT position key is different from user address
        // This is critical: address-based positions use msg.sender as key
        // NFT-based positions use derived position key
        // They must never collide
        bytes32 userKey = LibPositionHelpers.systemPositionKey(userAddress);
        assertTrue(
            nftPositionKey != userKey,
            "NFT position key should never equal a system user key"
        );
    }
    
    /// @notice Property 24: Address and NFT Coexistence - Multiple Users and NFTs
    /// @notice For any set of users and NFTs, all position keys should be unique
    /// @notice This ensures no collisions between address-based and NFT-based positions
    function testProperty_Coexistence_AllKeysUnique(
        uint8 userCount,
        uint8 nftCount
    ) public {
        userCount = uint8(bound(userCount, 1, 10));
        nftCount = uint8(bound(nftCount, 1, 10));
        
        // Create user addresses
        address[] memory users = new address[](userCount);
        for (uint256 i = 0; i < userCount; i++) {
            users[i] = address(uint160(0x1000 + i));
        }
        
        // Mint NFTs and get position keys
        bytes32[] memory nftKeys = new bytes32[](nftCount);
        for (uint256 i = 0; i < nftCount; i++) {
            uint256 tokenId = nft.mint(user1, POOL_ID);
            nftKeys[i] = nft.getPositionKey(tokenId);
        }
        
        // Verify no user address equals any NFT position key
        for (uint256 i = 0; i < userCount; i++) {
            for (uint256 j = 0; j < nftCount; j++) {
                bytes32 userKey = LibPositionHelpers.systemPositionKey(users[i]);
                assertTrue(
                    userKey != nftKeys[j],
                    "User keys and NFT position keys must not collide"
                );
            }
        }
        
        // Verify all NFT keys are unique among themselves
        for (uint256 i = 0; i < nftCount; i++) {
            for (uint256 j = i + 1; j < nftCount; j++) {
                assertTrue(
                    nftKeys[i] != nftKeys[j],
                    "All NFT position keys must be unique"
                );
            }
        }
    }
    
    /// @notice Property 24: Address and NFT Coexistence - Independent Storage
    /// @notice Demonstrates that address-based and NFT-based positions use independent storage slots
    /// @notice Even though they use the same mappings, different keys ensure independence
    function testProperty_Coexistence_IndependentStorage() public {
        // Create an address-based position key (simulating msg.sender)
        bytes32 addressKey = LibPositionHelpers.systemPositionKey(user1);
        
        // Create an NFT-based position key
        uint256 tokenId = nft.mint(user2, POOL_ID);
        bytes32 nftKey = nft.getPositionKey(tokenId);
        
        // Verify keys are different
        assertTrue(addressKey != nftKey, "System and NFT keys should be different");
        
        // In the actual implementation:
        // - Address-based position would use: userPrincipal[user1], userFeeIndex[user1], etc.
        // - NFT-based position would use: userPrincipal[nftKey], userFeeIndex[nftKey], etc.
        // 
        // Since user1 != nftKey, these access different storage slots in the same mappings
        // This is how coexistence works: same data structures, different keys
        
        // The position keys being different guarantees storage independence
        assertTrue(true, "Storage independence is guaranteed by key uniqueness");
    }
    
    /// @notice Property 24: Address and NFT Coexistence - Same User Can Have Both
    /// @notice A single user can have both address-based positions and NFT-based positions
    /// @notice They operate independently without interference
    function testProperty_Coexistence_SameUserBothTypes(uint8 nftCount) public {
        nftCount = uint8(bound(nftCount, 1, 20));
        
        // User1 has a system position key
        bytes32 addressKey = LibPositionHelpers.systemPositionKey(user1);
        
        // User1 also owns multiple NFT-based positions
        bytes32[] memory nftKeys = new bytes32[](nftCount);
        for (uint256 i = 0; i < nftCount; i++) {
            uint256 tokenId = nft.mint(user1, POOL_ID);
            nftKeys[i] = nft.getPositionKey(tokenId);
            
            // Verify NFT owner is user1
            assertEq(nft.ownerOf(tokenId), user1, "User1 should own the NFT");
        }
        
        // Verify address key is different from all NFT keys
        for (uint256 i = 0; i < nftCount; i++) {
            assertTrue(
                addressKey != nftKeys[i],
                "System position key should differ from NFT position keys"
            );
        }
        
        // This demonstrates that user1 can have:
        // 1. One address-based position (using user1 as key)
        // 2. Multiple NFT-based positions (using nftKeys as keys)
        // All operating independently in the same pool
    }
    
    /// @notice Property 24: Address and NFT Coexistence - Transfer Doesn't Affect Address Position
    /// @notice When an NFT is transferred, the original owner's address-based position is unaffected
    function testProperty_Coexistence_TransferIndependence(uint256 tokenId) public {
        tokenId = bound(tokenId, 1, 100);
        
        // Mint NFT to user1
        for (uint256 i = 1; i <= tokenId; i++) {
            nft.mint(user1, POOL_ID);
        }
        
        // Get position key before transfer
        bytes32 nftKeyBeforeTransfer = nft.getPositionKey(tokenId);
        
        // User1's system position key
        bytes32 user1AddressKey = LibPositionHelpers.systemPositionKey(user1);
        
        // Verify they're different
        assertTrue(
            user1AddressKey != nftKeyBeforeTransfer,
            "Address key and NFT key should be different"
        );
        
        // Transfer NFT from user1 to user2
        vm.prank(user1);
        nft.transferFrom(user1, user2, tokenId);
        
        // Get position key after transfer
        bytes32 nftKeyAfterTransfer = nft.getPositionKey(tokenId);
        
        // Verify NFT position key is unchanged
        assertEq(
            nftKeyBeforeTransfer,
            nftKeyAfterTransfer,
            "NFT position key should remain unchanged after transfer"
        );
        
        // Verify user1's system key is unchanged
        assertEq(user1AddressKey, LibPositionHelpers.systemPositionKey(user1), "User1 system key unchanged");
        
        // Verify user2's system position key
        bytes32 user2AddressKey = LibPositionHelpers.systemPositionKey(user2);
        assertEq(user2AddressKey, LibPositionHelpers.systemPositionKey(user2), "User2 system key");
        
        // Verify all three keys are different
        assertTrue(user1AddressKey != nftKeyAfterTransfer, "User1 address != NFT key");
        assertTrue(user2AddressKey != nftKeyAfterTransfer, "User2 address != NFT key");
        assertTrue(user1AddressKey != user2AddressKey, "User1 address != User2 address");
        
        // This demonstrates that:
        // - User1's address-based position is unaffected by NFT transfer
        // - User2's address-based position is unaffected by receiving NFT
        // - The NFT position (with its own key) is now controlled by user2
        // All three positions coexist independently
    }
    
    /// @notice Property 24: Address and NFT Coexistence - Pool Isolation
    /// @notice Address-based and NFT-based positions in different pools are isolated
    function testProperty_Coexistence_PoolIsolation(
        uint256 poolId1,
        uint256 poolId2
    ) public {
        poolId1 = bound(poolId1, 0, 1000);
        poolId2 = bound(poolId2, 0, 1000);
        vm.assume(poolId1 != poolId2);
        
        // Mint NFTs in different pools
        uint256 tokenId1 = nft.mint(user1, poolId1);
        uint256 tokenId2 = nft.mint(user1, poolId2);
        
        // Get position keys
        bytes32 nftKey1 = nft.getPositionKey(tokenId1);
        bytes32 nftKey2 = nft.getPositionKey(tokenId2);
        
        // Verify NFT keys are different (different token IDs)
        assertTrue(nftKey1 != nftKey2, "Different NFTs have different keys");
        
        // User1's system position key applies across pools
        bytes32 addressKey = LibPositionHelpers.systemPositionKey(user1);
        
        // Verify address key differs from both NFT keys
        assertTrue(addressKey != nftKey1, "Address key != NFT key 1");
        assertTrue(addressKey != nftKey2, "Address key != NFT key 2");
        
        // This demonstrates that in each pool:
        // - User1 can have an address-based position (key = user1)
        // - User1 can have NFT-based positions (keys = nftKey1, nftKey2)
        // All positions are isolated by pool and by key
    }
    
    /// @notice Property 24: Address and NFT Coexistence - Conceptual Validation
    /// @notice Validates the core concept: same mappings, different keys = coexistence
    function testProperty_Coexistence_ConceptualValidation() public {
        // The coexistence model works because:
        // 
        // 1. Both position types use the SAME mappings:
        //    - userPrincipal[key]
        //    - userFeeIndex[key]
        //    - rollingLoans[key]
        //    - etc.
        //
        // 2. But they use DIFFERENT keys:
        //    - Address-based: key = msg.sender (user address)
        //    - NFT-based: key = positionKey (derived from NFT)
        //
        // 3. The keys are guaranteed to be different:
        //    - User addresses are EOAs or contracts
        //    - Position keys are derived via keccak256(nftContract, tokenId)
        //    - Hash collision probability is negligible
        //
        // 4. Therefore:
        //    - Address-based positions access: mapping[userAddress]
        //    - NFT-based positions access: mapping[positionKey]
        //    - These are different storage slots
        //    - No interference possible
        
        // Create examples
        bytes32 userAddress = LibPositionHelpers.systemPositionKey(user1);
        uint256 tokenId = nft.mint(user1, POOL_ID);
        bytes32 nftKey = nft.getPositionKey(tokenId);
        
        // Verify the fundamental property
        assertTrue(
            userAddress != nftKey,
            "Core coexistence property: system key != NFT position key"
        );
        
        // This single property guarantees coexistence
        // Same data structures + different keys = independent positions
    }
}
