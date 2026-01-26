// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {OptionToken} from "../../src/derivatives/OptionToken.sol";
import {FuturesToken} from "../../src/derivatives/FuturesToken.sol";

/// @notice Unit tests for ERC-1155 transfer freedom
/// @notice Validates: Requirements 13.5
contract DerivativeTokenTransferTest is Test {
    address internal constant MANAGER = address(0xBEEF);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    OptionToken internal optionToken;
    FuturesToken internal futuresToken;

    function setUp() public {
        optionToken = new OptionToken("", address(this), MANAGER);
        futuresToken = new FuturesToken("", address(this), MANAGER);
    }

    function testOptionTokenTransferFreedom() public {
        uint256 id = 1;
        uint256 amount = 5;

        vm.prank(MANAGER);
        optionToken.managerMint(ALICE, id, amount, "");

        vm.prank(ALICE);
        optionToken.safeTransferFrom(ALICE, BOB, id, amount, "");

        assertEq(optionToken.balanceOf(ALICE, id), 0, "alice balance cleared");
        assertEq(optionToken.balanceOf(BOB, id), amount, "bob balance received");
    }

    function testFuturesTokenTransferFreedom() public {
        uint256 id = 2;
        uint256 amount = 3;

        vm.prank(MANAGER);
        futuresToken.managerMint(ALICE, id, amount, "");

        vm.prank(ALICE);
        futuresToken.safeTransferFrom(ALICE, BOB, id, amount, "");

        assertEq(futuresToken.balanceOf(ALICE, id), 0, "alice balance cleared");
        assertEq(futuresToken.balanceOf(BOB, id), amount, "bob balance received");
    }
}
