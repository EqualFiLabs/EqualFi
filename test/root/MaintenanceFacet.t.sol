// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MaintenanceFacet} from "../../src/core/MaintenanceFacet.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {Types} from "../../src/libraries/Types.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract MaintenanceHarness is MaintenanceFacet {
    function configurePool(uint256 pid, address underlying, uint256 totalDeposits, uint16 rateBps, uint64 lastTimestamp)
        external
    {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.totalDeposits = totalDeposits;
        p.trackedBalance = totalDeposits; // Initialize tracked balance
        p.poolConfig.maintenanceRateBps = rateBps;
        p.lastMaintenanceTimestamp = lastTimestamp;
    }

    function setTrackedBalance(uint256 pid, uint256 trackedBalance) external {
        LibAppStorage.s().pools[pid].trackedBalance = trackedBalance;
    }

    function setFoundationReceiver(address receiver) external {
        LibAppStorage.s().foundationReceiver = receiver;
    }

    function maintenanceState(uint256 pid) external view returns (uint64 lastTimestamp, uint256 pending) {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        return (p.lastMaintenanceTimestamp, p.pendingMaintenance);
    }
}

contract MaintenanceFacetTest is Test {
    MaintenanceHarness internal facet;
    MockERC20 internal token;
    address internal constant FOUNDATION = address(0xBEEF);
    uint256 internal constant PID = 1;

    function setUp() public {
        facet = new MaintenanceHarness();
        token = new MockERC20("Mock", "MOCK", 18, 0);
        facet.setFoundationReceiver(FOUNDATION);
    }

    function testPokeMaintenanceAccruesAndPays() public {
        vm.warp(120 days);
        uint64 lastTs = uint64(block.timestamp - 1 days);
        facet.configurePool(PID, address(token), 1_000 ether, 100, lastTs);
        token.mint(address(facet), 10 ether);
        assertEq(token.balanceOf(address(facet)), 10 ether);

        vm.prank(address(this));
        facet.pokeMaintenance(PID);

        // 1% annual => ~0.00274% per day on 1,000 ether => ~0.0274 ether
        uint256 numerator = 1_000 ether * 100;
        uint256 expected = numerator / (365 * 10_000);
        assertEq(token.balanceOf(FOUNDATION), expected);
        (uint64 updatedTs, uint256 pending) = facet.maintenanceState(PID);
        assertEq(pending, 0);
        assertGt(updatedTs, lastTs);
    }

    function testSettleMaintenancePaysPendingWhenFundsArrive() public {
        vm.warp(180 days);
        uint64 lastTs = uint64(block.timestamp - 60 days);
        facet.configurePool(PID, address(token), 2_000 ether, 100, lastTs);
        // No funds yet; poke accrues but cannot pay.
        facet.pokeMaintenance(PID);
        (, uint256 pendingBefore) = facet.maintenanceState(PID);
        assertGt(pendingBefore, 0);
        assertEq(token.balanceOf(FOUNDATION), 0);

        // Fund contract later and settle.
        token.mint(address(facet), 5 ether);
        facet.settleMaintenance(PID);
        (, uint256 pendingAfter) = facet.maintenanceState(PID);
        assertEq(pendingAfter, 0);
        uint256 numerator = 2_000 ether * 100 * 60; // 60 days
        uint256 expected = numerator / (365 * 10_000);
        assertEq(token.balanceOf(FOUNDATION), expected);
    }

    function testSettleMaintenancePaysPartialWhenContractShort() public {
        vm.warp(400 days);
        uint64 lastTs = uint64(block.timestamp - 365 days);
        facet.configurePool(PID, address(token), 1_000 ether, 100, lastTs);

        // Accrue pending maintenance with zero contract balance.
        facet.pokeMaintenance(PID);
        (, uint256 pendingBefore) = facet.maintenanceState(PID);
        uint256 expected = (1_000 ether * 100) / 10_000;
        assertEq(pendingBefore, expected);

        // Fund less than pending and settle.
        token.mint(address(facet), 3 ether);
        facet.settleMaintenance(PID);
        (, uint256 pendingAfter) = facet.maintenanceState(PID);
        assertEq(token.balanceOf(FOUNDATION), 3 ether);
        assertEq(pendingAfter, expected - 3 ether);
    }

    function testPokeMaintenanceCappedByTrackedBalance() public {
        vm.warp(400 days);
        uint64 lastTs = uint64(block.timestamp - 365 days);
        facet.configurePool(PID, address(token), 1_000 ether, 100, lastTs);
        facet.setTrackedBalance(PID, 2 ether);
        token.mint(address(facet), 10 ether);

        facet.pokeMaintenance(PID);

        (, uint256 pending) = facet.maintenanceState(PID);
        uint256 expected = (1_000 ether * 100) / 10_000;
        assertEq(token.balanceOf(FOUNDATION), 2 ether);
        assertEq(pending, expected - 2 ether);
    }

    function testMultiEpochAccrualHandlesLargeElapsedTime() public {
        vm.warp(200 days);
        uint64 lastTs = uint64(block.timestamp - 120 days); // 120 days elapsed
        facet.configurePool(PID, address(token), 500 ether, 100, lastTs);
        token.mint(address(facet), 10 ether);

        facet.pokeMaintenance(PID);

        uint256 numerator = 500 ether * 100 * 120; // 120 days
        uint256 expected = numerator / (365 * 10_000);
        assertEq(token.balanceOf(FOUNDATION), expected);
        (, uint256 pending) = facet.maintenanceState(PID);
        assertEq(pending, 0);
    }

    function testZeroTvlSkipsAccrual() public {
        vm.warp(120 days);
        uint64 lastTs = uint64(block.timestamp - 60 days);
        facet.configurePool(PID, address(token), 0, 100, lastTs);
        token.mint(address(facet), 10 ether);

        facet.pokeMaintenance(PID);

        (, uint256 pending) = facet.maintenanceState(PID);
        assertEq(pending, 0);
        assertEq(token.balanceOf(FOUNDATION), 0);
    }

    function testPokeRevertsWhenReceiverUnset() public {
        facet.setFoundationReceiver(address(0));
        vm.expectRevert("Maintenance: receiver not set");
        facet.pokeMaintenance(PID);
    }

    function testMaintenanceRespectsFoundationUpdates() public {
        vm.warp(120 days);
        uint64 lastTs = uint64(block.timestamp - 1 days);
        facet.configurePool(PID, address(token), 1_000 ether, 100, lastTs);
        token.mint(address(facet), 10 ether);

        facet.pokeMaintenance(PID);

        address newReceiver = address(0xCAFE);
        facet.setFoundationReceiver(newReceiver);
        token.mint(address(facet), 10 ether);
        vm.warp(block.timestamp + 1 days);

        vm.prank(address(this));
        facet.pokeMaintenance(PID);

        assertGt(token.balanceOf(newReceiver), 0);
    }
}
