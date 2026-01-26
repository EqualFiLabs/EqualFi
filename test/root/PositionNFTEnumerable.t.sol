// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/nft/PositionNFT.sol";

contract PositionNFTEnumerableTest is Test {
    PositionNFT nft;
    address user1 = address(0x1);
    address user2 = address(0x2);

    function setUp() public {
        nft = new PositionNFT();
        nft.setMinter(address(this));
    }

    function test_EnumerableFunctions() public {
        // Mint 3 NFTs to user1
        nft.mint(user1, 1);
        nft.mint(user1, 1);
        nft.mint(user1, 1);
        
        // Mint 2 NFTs to user2
        nft.mint(user2, 2);
        nft.mint(user2, 2);

        // Check balances
        assertEq(nft.balanceOf(user1), 3);
        assertEq(nft.balanceOf(user2), 2);
        
        // Check total supply
        assertEq(nft.totalSupply(), 5);
        
        // Check tokenOfOwnerByIndex for user1
        assertEq(nft.tokenOfOwnerByIndex(user1, 0), 1);
        assertEq(nft.tokenOfOwnerByIndex(user1, 1), 2);
        assertEq(nft.tokenOfOwnerByIndex(user1, 2), 3);
        
        // Check tokenOfOwnerByIndex for user2
        assertEq(nft.tokenOfOwnerByIndex(user2, 0), 4);
        assertEq(nft.tokenOfOwnerByIndex(user2, 1), 5);
        
        // Check tokenByIndex (global)
        assertEq(nft.tokenByIndex(0), 1);
        assertEq(nft.tokenByIndex(4), 5);
    }
    
    function test_EnumerableAfterTransfer() public {
        // Mint 2 NFTs to user1
        uint256 token1 = nft.mint(user1, 1);
        uint256 token2 = nft.mint(user1, 1);
        
        assertEq(nft.balanceOf(user1), 2);
        assertEq(nft.balanceOf(user2), 0);
        
        // Transfer one to user2
        vm.prank(user1);
        nft.transferFrom(user1, user2, token1);
        
        // Check balances updated
        assertEq(nft.balanceOf(user1), 1);
        assertEq(nft.balanceOf(user2), 1);
        
        // Check enumeration updated
        assertEq(nft.tokenOfOwnerByIndex(user1, 0), token2);
        assertEq(nft.tokenOfOwnerByIndex(user2, 0), token1);
    }
}
