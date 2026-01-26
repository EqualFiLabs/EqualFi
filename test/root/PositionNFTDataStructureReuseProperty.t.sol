// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {LibPositionNFT} from "../../src/libraries/LibPositionNFT.sol";
import {LibPositionHelpers} from "../../src/libraries/LibPositionHelpers.sol";
import {Types} from "../../src/libraries/Types.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import "../../src/libraries/Errors.sol";

/// @notice Property-based tests for Position NFT data structure reuse
/// @notice **Feature: position-nfts, Property 23: Data Structure Reuse**
/// @notice **Validates: Requirements 10.1, 10.2, 10.3, 10.4**
/// forge-config: default.fuzz.runs = 100
contract PositionNFTDataStructureReusePropertyTest is Test {
    PositionNFT public nft;
    MockERC20 public token;
    
    address public user1 = address(0x1111);
    address public user2 = address(0x2222);
    
    uint256 constant POOL_ID = 1;
    
    function setUp() public {
        nft = new PositionNFT();
        token = new MockERC20("Test Token", "TEST", 18, 1000000 ether);
        // Set test contract as minter for direct testing
        nft.setMinter(address(this));
    }
    
    /// @notice Property 23: Data Structure Reuse - Position Key Derivation
    /// @notice For any Position NFT, the position key should be derived deterministically from NFT contract and token ID
    /// @notice This demonstrates that the same key derivation mechanism is used for all data structure access
    function testProperty_DataStructureReuse_PositionKeyDerivation(
        uint256 tokenId1,
        uint256 tokenId2
    ) public {
        tokenId1 = bound(tokenId1, 1, 200);
        tokenId2 = bound(tokenId2, 1, 200);
        vm.assume(tokenId1 != tokenId2);
        
        // Mint NFTs
        uint256 maxTokenId = tokenId1 > tokenId2 ? tokenId1 : tokenId2;
        for (uint256 i = 1; i <= maxTokenId; i++) {
            nft.mint(user1, POOL_ID);
        }
        
        // Get position keys
        bytes32 key1 = nft.getPositionKey(tokenId1);
        bytes32 key2 = nft.getPositionKey(tokenId2);
        
        // Verify keys are different for different token IDs
        assertTrue(key1 != key2, "Different token IDs should produce different position keys");
        
        // Verify keys match the library function (same derivation mechanism)
        bytes32 expectedKey1 = LibPositionNFT.getPositionKey(address(nft), tokenId1);
        bytes32 expectedKey2 = LibPositionNFT.getPositionKey(address(nft), tokenId2);
        
        assertEq(key1, expectedKey1, "Position key should match library derivation");
        assertEq(key2, expectedKey2, "Position key should match library derivation");
        
        // Verify keys are deterministic (calling multiple times gives same result)
        assertEq(nft.getPositionKey(tokenId1), key1, "Position key should be deterministic");
        assertEq(nft.getPositionKey(tokenId2), key2, "Position key should be deterministic");
    }
    
    /// @notice Property 23: Data Structure Reuse - Position Key Uniqueness
    /// @notice For any set of Position NFTs, all position keys should be unique
    /// @notice This ensures no collisions when using keys in existing mappings
    function testProperty_DataStructureReuse_PositionKeyUniqueness(uint8 mintCount) public {
        mintCount = uint8(bound(mintCount, 2, 50));
        
        // Mint multiple NFTs
        bytes32[] memory keys = new bytes32[](mintCount);
        for (uint256 i = 0; i < mintCount; i++) {
            uint256 tokenId = nft.mint(user1, POOL_ID);
            keys[i] = nft.getPositionKey(tokenId);
        }
        
        // Verify all keys are unique
        for (uint256 i = 0; i < mintCount; i++) {
            for (uint256 j = i + 1; j < mintCount; j++) {
                assertTrue(
                    keys[i] != keys[j],
                    "All position keys must be unique to avoid mapping collisions"
                );
            }
        }
    }
    
    /// @notice Property 23: Data Structure Reuse - Position Key Non-Zero
    /// @notice For any Position NFT, the position key should never be the zero key
    /// @notice This ensures compatibility with existing mapping checks
    function testProperty_DataStructureReuse_PositionKeyNonZero(uint256 tokenId) public {
        tokenId = bound(tokenId, 1, 500);
        
        // Mint NFTs up to tokenId
        for (uint256 i = 1; i <= tokenId; i++) {
            nft.mint(user1, POOL_ID);
        }
        
        // Get position key
        bytes32 key = nft.getPositionKey(tokenId);
        
        // Verify key is not zero key
        assertTrue(key != bytes32(0), "Position key should never be zero");
        
        // Verify library function also produces non-zero
        bytes32 libKey = LibPositionNFT.getPositionKey(address(nft), tokenId);
        assertTrue(libKey != bytes32(0), "Library position key should never be zero");
    }
    
    /// @notice Property 23: Data Structure Reuse - Same Mapping Structure
    /// @notice Demonstrates that NFT positions would use the same mapping structure as address-based positions
    /// @notice This is a conceptual test showing the design principle
    function testProperty_DataStructureReuse_MappingStructure() public {
        // Mint an NFT
        uint256 tokenId = nft.mint(user1, POOL_ID);
        bytes32 positionKey = nft.getPositionKey(tokenId);
        
        // In the actual implementation, both address-based and NFT-based positions use:
        // - userPrincipal[key] for principal storage
        // - userFeeIndex[key] for fee index checkpoints
        // - userMaintenanceIndex[key] for maintenance index checkpoints
        // - userAccruedYield[key] for accrued yield
        // - rollingLoans[key] for rolling credit loans
        // - fixedTermLoans[loanId] for fixed-term loans (with borrower = key)
        // - userFixedLoanIds[key] for loan ID arrays
        // - externalCollateral[key] for external collateral
        
        // For address-based: key = msg.sender (user address)
        // For NFT-based: key = positionKey (derived from NFT)
        
        // This test verifies the position key is a valid non-zero key for mapping use
        assertTrue(positionKey != bytes32(0), "Position key is valid for mapping use");
        assertTrue(positionKey != LibPositionHelpers.systemPositionKey(user1), "Position key is distinct from user key");
        
        // The key insight: the SAME mappings are reused, just with different keys
        // This is the core of Property 23: Data Structure Reuse
    }
}
