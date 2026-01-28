// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibMaintenance} from "../../src/libraries/LibMaintenance.sol";
import {LibFeeRouter} from "../../src/libraries/LibFeeRouter.sol";
import {Types} from "../../src/libraries/Types.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract MaintenanceRoutingHarness {
    function seedPool(uint256 pid, address underlying, uint256 principal) external {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        store.foundationReceiver = address(0xFADE);
        store.defaultMaintenanceRateBps = 100;
        Types.PoolData storage p = store.pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.totalDeposits = principal;
        p.trackedBalance = principal;
        p.lastMaintenanceTimestamp = uint64(block.timestamp - 365 days);
    }

    function setManagedPoolSystemShareBps(uint16 bps) external {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        store.managedPoolSystemShareBps = bps;
        store.managedPoolSystemShareConfigured = true;
    }

    function setTreasury(address treasury) external {
        LibAppStorage.s().treasury = treasury;
    }

    function enforce(uint256 pid) external {
        LibMaintenance.enforce(pid);
    }

    function feeIndex(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].feeIndex;
    }

    function routeManagedShare(uint256 pid, uint256 amount) external {
        LibFeeRouter.routeManagedShare(pid, amount, bytes32("test"), true, 0);
    }
}

contract MaintenanceRoutingVerificationTest is Test {
    MaintenanceRoutingHarness internal harness;
    MockERC20 internal token;

    function setUp() public {
        vm.warp(365 days + 1);
        harness = new MaintenanceRoutingHarness();
        token = new MockERC20("Token", "TKN", 18, 0);
        token.mint(address(harness), 1_000 ether);
        harness.seedPool(1, address(token), 1_000 ether);
    }

    function testMaintenanceDoesNotUseManagedShareRouter() public {
        uint256 feeIndexBefore = harness.feeIndex(1);
        harness.setManagedPoolSystemShareBps(2000);
        harness.setTreasury(address(0xBEEF));

        harness.enforce(1);

        uint256 feeIndexAfter = harness.feeIndex(1);
        assertEq(feeIndexAfter, feeIndexBefore, "maintenance should not accrue feeIndex");
    }
}
