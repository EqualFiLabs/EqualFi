// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ClPositionManager} from "src/nft/ClPositionManager.sol";

contract ClPositionManagerTest is Test {
    address internal constant DIAMOND = address(0xD1A);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant RANDO = address(0xBAD);

    ClPositionManager internal manager;

    function setUp() public {
        manager = new ClPositionManager(DIAMOND);
    }

    function test_constructor_setsDiamond() public {
        assertEq(manager.diamond(), DIAMOND);
    }

    function test_constructor_revertsOnZeroDiamond() public {
        vm.expectRevert(ClPositionManager.ClPositionManager_InvalidDiamond.selector);
        new ClPositionManager(address(0));
    }

    function test_mint_onlyDiamond() public {
        vm.prank(RANDO);
        vm.expectRevert(abi.encodeWithSelector(ClPositionManager.ClPositionManager_OnlyDiamond.selector, RANDO));
        manager.mint(ALICE);

        vm.prank(DIAMOND);
        uint256 tokenId = manager.mint(ALICE);

        assertEq(tokenId, 1);
        assertEq(manager.ownerOf(tokenId), ALICE);
        assertEq(manager.totalSupply(), 1);
    }

    function test_mint_tokenIdSequencing() public {
        vm.startPrank(DIAMOND);
        uint256 first = manager.mint(ALICE);
        uint256 second = manager.mint(BOB);
        uint256 third = manager.mint(ALICE);
        vm.stopPrank();

        assertEq(first, 1);
        assertEq(second, 2);
        assertEq(third, 3);
        assertEq(manager.ownerOf(1), ALICE);
        assertEq(manager.ownerOf(2), BOB);
        assertEq(manager.ownerOf(3), ALICE);
        assertEq(manager.totalSupply(), 3);
    }

    function test_burn_onlyDiamond() public {
        vm.prank(DIAMOND);
        uint256 tokenId = manager.mint(ALICE);

        vm.prank(RANDO);
        vm.expectRevert(abi.encodeWithSelector(ClPositionManager.ClPositionManager_OnlyDiamond.selector, RANDO));
        manager.burn(tokenId);

        vm.prank(DIAMOND);
        manager.burn(tokenId);

        vm.expectRevert();
        manager.ownerOf(tokenId);
        assertEq(manager.totalSupply(), 0);
    }

    function test_burn_nonexistentByDiamond_reverts() public {
        vm.prank(DIAMOND);
        vm.expectRevert();
        manager.burn(404);
    }
}
