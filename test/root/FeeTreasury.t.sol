// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {LibFeeTreasury} from "../../src/libraries/LibFeeTreasury.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {Types} from "../../src/libraries/Types.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract FeeTreasuryHarness {
    using LibFeeTreasury for Types.PoolData;

    function configure(address underlying, address treasury, uint16 treasuryShareBps, uint16 activeShareBps) external {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        store.treasury = treasury;
        store.treasuryShareBps = treasuryShareBps;
        store.treasuryShareConfigured = true;
        store.activeCreditShareBps = activeShareBps;
        store.activeCreditShareConfigured = true;
        Types.PoolData storage p = store.pools[1];
        p.underlying = underlying;
        p.initialized = true;
    }

    function seedTrackedBalance(uint256 amount) external {
        LibAppStorage.s().pools[1].trackedBalance = amount;
    }

    function trackedBalance() external view returns (uint256) {
        return LibAppStorage.s().pools[1].trackedBalance;
    }

    function accrue(uint256 amount) external returns (uint256 toTreasury, uint256 toActive, uint256 toIndex) {
        Types.PoolData storage p = LibAppStorage.s().pools[1];
        p.trackedBalance += amount;
        return LibFeeTreasury.accrueWithTreasury(p, 1, amount, bytes32("test"));
    }
}

contract FeeTreasuryTest is Test {
    FeeTreasuryHarness internal harness;
    MockERC20 internal token;
    address internal treasury = address(0xBEEF);

    function setUp() public {
        harness = new FeeTreasuryHarness();
        token = new MockERC20("Mock", "MOCK", 18, 0);
        harness.configure(address(token), treasury, 2000, 1000); // 20% treasury, 10% active credit
        token.mint(address(harness), 100 ether);
    }

    function testSplitThreeWays() public {
        vm.prank(address(harness));
        (uint256 toTreasury, uint256 toActive, uint256 toIndex) = harness.accrue(100 ether);

        assertEq(toTreasury, 20 ether, "treasury share");
        assertEq(toActive, 10 ether, "active credit share");
        assertEq(toIndex, 70 ether, "fee index remainder");
        assertEq(token.balanceOf(treasury), 20 ether, "treasury received");
        assertEq(harness.trackedBalance(), 80 ether, "tracked balance debited for treasury");
    }
}
