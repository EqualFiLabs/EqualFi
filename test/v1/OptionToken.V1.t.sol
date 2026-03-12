// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {OptionToken} from "../../src/derivatives/OptionToken.sol";

contract OptionTokenV1Test is Test {
    address internal constant OWNER = address(0xA11CE);
    address internal constant MANAGER = address(0xBEEF);
    address internal constant ALICE = address(0x1111);
    address internal constant BOB = address(0x2222);

    OptionToken internal token;

    function setUp() public {
        token = new OptionToken("ipfs://base/options", OWNER, MANAGER);
    }

    function test_onlyManager_controlsMintBurnAndSeriesUri() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(OptionToken.DerivativeToken_NotManager.selector, ALICE));
        token.managerMint(ALICE, 1, 5, "");

        vm.prank(MANAGER);
        token.managerMint(ALICE, 1, 5, "");
        assertEq(token.balanceOf(ALICE, 1), 5);

        vm.prank(MANAGER);
        token.setSeriesURI(1, "ipfs://series/1");
        assertEq(token.uri(1), "ipfs://series/1");
        assertEq(token.uri(2), "ipfs://base/options");

        vm.prank(MANAGER);
        token.managerBurn(ALICE, 1, 2);
        assertEq(token.balanceOf(ALICE, 1), 3);

        vm.prank(MANAGER);
        token.managerMint(ALICE, 2, 4, "");
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1;
        amounts[1] = 3;
        vm.prank(MANAGER);
        token.managerBurnBatch(ALICE, ids, amounts);
        assertEq(token.balanceOf(ALICE, 1), 2);
        assertEq(token.balanceOf(ALICE, 2), 1);
    }

    function test_manager_canBeUpdatedByOwnerOnly() public {
        vm.prank(ALICE);
        vm.expectRevert();
        token.setManager(BOB);

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(OptionToken.DerivativeToken_InvalidManager.selector, address(0)));
        token.setManager(address(0));

        vm.prank(OWNER);
        token.setManager(BOB);
        assertEq(token.manager(), BOB);

        vm.prank(BOB);
        token.managerMint(ALICE, 7, 9, "");
        assertEq(token.balanceOf(ALICE, 7), 9);
    }

    function test_transferFreedom_forHolders() public {
        vm.prank(MANAGER);
        token.managerMint(ALICE, 3, 6, "");

        vm.prank(ALICE);
        token.safeTransferFrom(ALICE, BOB, 3, 4, "");

        assertEq(token.balanceOf(ALICE, 3), 2);
        assertEq(token.balanceOf(BOB, 3), 4);
    }
}
