// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibFeeTreasury} from "../../src/libraries/LibFeeTreasury.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {Types} from "../../src/libraries/Types.sol";
import {InsufficientPrincipal} from "../../src/libraries/Errors.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract FeeTreasuryHarness {
    function s() internal pure returns (LibAppStorage.AppStorage storage) {
        return LibAppStorage.s();
    }

    function seedPool(uint256 pid, address underlying, uint256 tracked, uint256 total) external {
        LibAppStorage.AppStorage storage store = s();
        Types.PoolData storage p = store.pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.trackedBalance = tracked;
        p.totalDeposits = total;
    }

    function setTreasury(address treasury, uint16 shareBps) external {
        LibAppStorage.AppStorage storage store = s();
        store.treasury = treasury;
        store.treasuryShareBps = shareBps;
        store.treasuryShareConfigured = true;
        store.activeCreditShareBps = 0;
        store.activeCreditShareConfigured = true;
    }

    function accrue(uint256 pid, uint256 amount, bytes32 source)
        external
        returns (uint256 toTreasury, uint256 toActive, uint256 toIndex)
    {
        LibAppStorage.AppStorage storage store = s();
        Types.PoolData storage p = store.pools[pid];
        return LibFeeTreasury.accrueWithTreasury(p, pid, amount, source);
    }

    function poolState(uint256 pid) external view returns (uint256 tracked, uint256 total) {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        return (p.trackedBalance, p.totalDeposits);
    }
}

contract LibFeeTreasuryIsolationTest is Test {
    FeeTreasuryHarness internal harness;
    MockERC20 internal token;
    address internal treasury = address(0xF00D);
    uint256 internal pid = 1;

    function setUp() public {
        harness = new FeeTreasuryHarness();
        token = new MockERC20("USDC", "USDC", 18, 0);
        harness.setTreasury(treasury, 5000); // 50% to treasury
    }

    function test_RevertsWhenTrackedInsufficient() public {
        // contract has enough balance, but tracked balance cannot cover treasury share
        harness.seedPool(pid, address(token), 2 ether, 10 ether);
        token.mint(address(harness), 10 ether);
        vm.expectRevert(abi.encodeWithSelector(InsufficientPrincipal.selector, 10 ether, 2 ether));
        harness.accrue(pid, 20 ether, "fee");
    }

    function test_RevertsWhenContractBalanceInsufficient() public {
        // tracked 10, contract holds 2 (< treasury share of 5)
        harness.seedPool(pid, address(token), 10 ether, 10 ether);
        token.mint(address(harness), 2 ether);
        vm.expectRevert(abi.encodeWithSelector(InsufficientPrincipal.selector, 5 ether, 2 ether));
        harness.accrue(pid, 10 ether, "fee");
    }

    function test_SucceedsWhenBalancesSufficient() public {
        harness.seedPool(pid, address(token), 30 ether, 20 ether);
        token.mint(address(harness), 30 ether);
        (uint256 toTreasury, uint256 toActive, uint256 toIndex) = harness.accrue(pid, 10 ether, "fee");
        assertEq(toTreasury, 5 ether, "treasury portion");
        assertEq(toActive, 0, "active credit portion");
        assertEq(toIndex, 5 ether, "index portion");
        (uint256 tracked,) = harness.poolState(pid);
        assertEq(tracked, 25 ether, "tracked reduced by treasury payment");
        assertEq(token.balanceOf(treasury), 5 ether, "treasury received");
    }
}
