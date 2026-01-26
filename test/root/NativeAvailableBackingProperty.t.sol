// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibCurrency} from "../../src/libraries/LibCurrency.sol";

contract NativeAvailableBackingHarness {
    function setNativeTrackedTotal(uint256 value) external {
        LibAppStorage.s().nativeTrackedTotal = value;
    }

    function nativeAvailable() external view returns (uint256) {
        return LibCurrency.nativeAvailable();
    }
}

contract NativeAvailableBackingPropertyTest is Test {
    NativeAvailableBackingHarness internal harness;

    function setUp() public {
        harness = new NativeAvailableBackingHarness();
    }

    /// Feature: native-eth-support, Property 7: Native Available Backing
    function testFuzz_nativeAvailableBacking(uint256 balance, uint256 tracked) public {
        balance = bound(balance, 0, 1_000 ether);
        tracked = bound(tracked, 0, type(uint256).max);

        vm.deal(address(harness), balance);
        harness.setNativeTrackedTotal(tracked);

        uint256 expected = balance > tracked ? balance - tracked : 0;
        assertEq(harness.nativeAvailable(), expected);
    }
}
