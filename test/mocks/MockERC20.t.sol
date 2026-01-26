// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract MockERC20Test is Test {
    MockERC20 internal token;

    function setUp() public {
        token = new MockERC20("Mock Token", "MOCK", 18, 0);
    }

    function testMintIncreasesBalanceAndSupply() public {
        token.mint(address(this), 1_000 ether);
        assertEq(token.totalSupply(), 1_000 ether);
        assertEq(token.balanceOf(address(this)), 1_000 ether);
    }

    function testTransferAfterMint() public {
        token.mint(address(this), 100 ether);
        bool ok = token.transfer(address(0xBEEF), 40 ether);
        assertTrue(ok);
        assertEq(token.balanceOf(address(this)), 60 ether);
        assertEq(token.balanceOf(address(0xBEEF)), 40 ether);
    }
}
