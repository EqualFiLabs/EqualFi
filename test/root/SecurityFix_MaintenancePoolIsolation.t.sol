// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MaintenanceFacet} from "../../src/core/MaintenanceFacet.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {Types} from "../../src/libraries/Types.sol";

contract MaintenanceIsolationMockERC20 is ERC20 {
    constructor() ERC20("Maintenance", "MNT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MaintenanceIsolationHarness is MaintenanceFacet {
    function setFoundationReceiver(address receiver) external {
        LibAppStorage.s().foundationReceiver = receiver;
    }

    function configurePool(
        uint256 pid,
        address underlying,
        uint256 trackedBalance,
        uint256 pendingMaintenance
    ) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.initialized = true;
        p.underlying = underlying;
        p.trackedBalance = trackedBalance;
        p.pendingMaintenance = pendingMaintenance;
    }

    function trackedBalanceOf(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].trackedBalance;
    }

    function pendingMaintenanceOf(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].pendingMaintenance;
    }
}

contract SecurityFixMaintenancePoolIsolationTest is Test {
    uint256 internal constant PID_A = 1;
    uint256 internal constant PID_B = 2;
    address internal constant FOUNDATION = address(0xF00D);

    MaintenanceIsolationHarness internal harness;
    MaintenanceIsolationMockERC20 internal token;

    function setUp() public {
        harness = new MaintenanceIsolationHarness();
        token = new MaintenanceIsolationMockERC20();
        harness.setFoundationReceiver(FOUNDATION);
    }

    function test_settleMaintenance_usesPerPoolTrackedBalanceCap() public {
        harness.configurePool(PID_A, address(token), 1 ether, 5 ether);
        harness.configurePool(PID_B, address(token), 100 ether, 0);

        token.mint(address(harness), 200 ether);

        harness.settleMaintenance(PID_A);

        assertEq(token.balanceOf(FOUNDATION), 1 ether);
        assertEq(harness.pendingMaintenanceOf(PID_A), 4 ether);
        assertEq(harness.trackedBalanceOf(PID_A), 0);
        assertEq(harness.trackedBalanceOf(PID_B), 100 ether);

        // Even with contract-level liquidity available, pool A cannot pay more once its tracked balance is zero.
        harness.settleMaintenance(PID_A);
        assertEq(token.balanceOf(FOUNDATION), 1 ether);
        assertEq(harness.pendingMaintenanceOf(PID_A), 4 ether);
    }
}
