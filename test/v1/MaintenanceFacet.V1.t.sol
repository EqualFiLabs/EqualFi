// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MaintenanceFacet} from "../../src/core/MaintenanceFacet.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {Types} from "../../src/libraries/Types.sol";

contract LocalMaintenanceMockERC20V1 is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MaintenanceV1Harness is MaintenanceFacet {
    function configurePool(
        uint256 pid,
        address underlying,
        uint256 totalDeposits,
        uint256 trackedBalance,
        uint256 maintenanceRateBps,
        uint256 lastTimestamp
    ) external {
        if (maintenanceRateBps > type(uint16).max) revert();
        if (lastTimestamp > type(uint64).max) revert();
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.totalDeposits = totalDeposits;
        p.trackedBalance = trackedBalance;
        p.poolConfig.maintenanceRateBps = uint16(maintenanceRateBps);
        p.lastMaintenanceTimestamp = uint64(lastTimestamp);
    }

    function setFoundationReceiver(address receiver) external {
        LibAppStorage.s().foundationReceiver = receiver;
    }

    function maintenanceState(uint256 pid) external view returns (uint64 lastTimestamp, uint256 pending) {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        return (p.lastMaintenanceTimestamp, p.pendingMaintenance);
    }
}

contract MaintenanceFacetV1Test is Test {
    MaintenanceV1Harness internal harness;
    LocalMaintenanceMockERC20V1 internal token;

    address internal constant FOUNDATION = address(0xBEEF);
    uint256 internal constant PID = 1;

    function setUp() public {
        harness = new MaintenanceV1Harness();
        token = new LocalMaintenanceMockERC20V1("Mock", "MOCK", 18);
        harness.setFoundationReceiver(FOUNDATION);
    }

    function test_pokeMaintenance_accruesAndPays() public {
        vm.warp(120 days);
        uint256 lastTs = block.timestamp - 1 days;
        harness.configurePool(PID, address(token), 1_000 ether, 1_000 ether, 100, lastTs);
        token.mint(address(harness), 10 ether);

        harness.pokeMaintenance(PID);

        uint256 expected = (uint256(1_000 ether) * 100) / (365 * 10_000);
        assertEq(token.balanceOf(FOUNDATION), expected);
        (uint64 updatedTs, uint256 pending) = harness.maintenanceState(PID);
        assertEq(pending, 0);
        assertGt(updatedTs, uint64(lastTs));
    }

    function test_settleMaintenance_paysPendingAfterFunding() public {
        vm.warp(180 days);
        uint256 lastTs = block.timestamp - 60 days;
        harness.configurePool(PID, address(token), 2_000 ether, 2_000 ether, 100, lastTs);

        harness.pokeMaintenance(PID);
        (, uint256 pendingBefore) = harness.maintenanceState(PID);
        assertGt(pendingBefore, 0);
        assertEq(token.balanceOf(FOUNDATION), 0);

        token.mint(address(harness), 5 ether);
        harness.settleMaintenance(PID);

        (, uint256 pendingAfter) = harness.maintenanceState(PID);
        assertEq(pendingAfter, 0);
        uint256 expected = (uint256(2_000 ether) * 100 * 60) / (365 * 10_000);
        assertEq(token.balanceOf(FOUNDATION), expected);
    }

    function test_pokeMaintenance_revertsWhenReceiverUnset() public {
        harness.setFoundationReceiver(address(0));
        vm.expectRevert("Maintenance: receiver not set");
        harness.pokeMaintenance(PID);
    }
}
