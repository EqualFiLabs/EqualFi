// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MutableIsolatedOracleAdapter} from "../../src/ilm-isolated/oracles/MutableIsolatedOracleAdapter.sol";

contract MutableIsolatedOracleAdapterTest is Test {
    MutableIsolatedOracleAdapter internal adapter;

    address internal owner = address(this);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        vm.warp(1_700_000_000);
        adapter = new MutableIsolatedOracleAdapter(123e36);
    }

    function test_constructor_setsOwnerAndInitialPrice() public {
        assertEq(adapter.owner(), owner);

        (uint256 price, uint256 updatedAt) = adapter.getIsolatedPrice(address(adapter));
        assertEq(price, 123e36);
        assertEq(updatedAt, 1_700_000_000);
    }

    function test_setPrice_updatesDefaultKeyAtCurrentTimestamp() public {
        vm.warp(1_700_000_111);
        adapter.setPrice(456e36);

        (uint256 price, uint256 updatedAt) = adapter.getIsolatedPrice(address(adapter));
        assertEq(price, 456e36);
        assertEq(updatedAt, 1_700_000_111);
    }

    function test_setPriceWithTimestamp_usesProvidedTimestamp() public {
        adapter.setPriceWithTimestamp(789e36, 1_700_000_222);

        (uint256 price, uint256 updatedAt) = adapter.getIsolatedPrice(address(adapter));
        assertEq(price, 789e36);
        assertEq(updatedAt, 1_700_000_222);
    }

    function test_setPriceFor_setsSpecificOracleKey() public {
        vm.warp(1_700_000_333);
        adapter.setPriceFor(alice, 100e36);

        (uint256 storedPrice, uint256 storedUpdatedAt) = adapter.getPriceData(alice);
        assertEq(storedPrice, 100e36);
        assertEq(storedUpdatedAt, 1_700_000_333);

        (uint256 price, uint256 updatedAt) = adapter.getIsolatedPrice(alice);
        assertEq(price, 100e36);
        assertEq(updatedAt, 1_700_000_333);
    }

    function test_setPriceForWithTimestamp_setsSpecificOracleKey() public {
        adapter.setPriceForWithTimestamp(alice, 111e36, 1_700_000_444);

        (uint256 price, uint256 updatedAt) = adapter.getIsolatedPrice(alice);
        assertEq(price, 111e36);
        assertEq(updatedAt, 1_700_000_444);
    }

    function test_getIsolatedPrice_fallsBackToDefaultWhenKeyMissing() public {
        adapter.setPrice(222e36);

        (uint256 price, uint256 updatedAt) = adapter.getIsolatedPrice(bob);
        assertEq(price, 222e36);
        assertEq(updatedAt, block.timestamp);
    }

    function test_transferOwnership_allowsNewOwnerToSetPrice() public {
        adapter.transferOwnership(alice);

        vm.prank(alice);
        vm.warp(1_700_000_555);
        adapter.setPrice(333e36);

        (uint256 price, uint256 updatedAt) = adapter.getIsolatedPrice(address(adapter));
        assertEq(price, 333e36);
        assertEq(updatedAt, 1_700_000_555);
    }

    function test_transferOwnership_revertOnZeroAddress() public {
        vm.expectRevert(MutableIsolatedOracleAdapter.ZeroAddress.selector);
        adapter.transferOwnership(address(0));
    }

    function test_setPriceFor_revertOnZeroOracleAddress() public {
        vm.expectRevert(MutableIsolatedOracleAdapter.ZeroAddress.selector);
        adapter.setPriceFor(address(0), 1e36);
    }

    function test_onlyOwner_revertsForStateMutations() public {
        vm.startPrank(alice);

        vm.expectRevert(MutableIsolatedOracleAdapter.NotOwner.selector);
        adapter.setPrice(1e36);

        vm.expectRevert(MutableIsolatedOracleAdapter.NotOwner.selector);
        adapter.setPriceWithTimestamp(1e36, 1_700_000_666);

        vm.expectRevert(MutableIsolatedOracleAdapter.NotOwner.selector);
        adapter.setPriceFor(bob, 1e36);

        vm.expectRevert(MutableIsolatedOracleAdapter.NotOwner.selector);
        adapter.setPriceForWithTimestamp(bob, 1e36, 1_700_000_777);

        vm.expectRevert(MutableIsolatedOracleAdapter.NotOwner.selector);
        adapter.transferOwnership(bob);

        vm.stopPrank();
    }
}
