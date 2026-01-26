// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibMaintenance} from "../../src/libraries/LibMaintenance.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {Types} from "../../src/libraries/Types.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract MaintenanceRateHarness {
    function configurePool(
        uint256 pid,
        address underlying,
        uint16 poolMaintenanceBps,
        uint16 defaultMaintenanceBps,
        uint16 maxMaintenanceBps,
        uint256 principal,
        uint64 lastTimestamp
    ) external {
        LibAppStorage.AppStorage storage s = LibAppStorage.s();
        s.foundationReceiver = address(0xFADE);
        s.defaultMaintenanceRateBps = defaultMaintenanceBps;
        s.maxMaintenanceRateBps = maxMaintenanceBps;
        Types.PoolData storage p = s.pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.poolConfig.maintenanceRateBps = poolMaintenanceBps;
        p.totalDeposits = principal;
        p.trackedBalance = principal;
        p.lastMaintenanceTimestamp = lastTimestamp;
    }

    function mint(address token, address to, uint256 amount) external {
        MockERC20(token).mint(to, amount);
    }

    function enforce(uint256 pid) external {
        LibMaintenance.enforce(pid);
    }

    function poolState(uint256 pid) external view returns (uint256 totalDeposits, uint256 trackedBalance, uint64 lastTs) {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        totalDeposits = p.totalDeposits;
        trackedBalance = p.trackedBalance;
        lastTs = p.lastMaintenanceTimestamp;
    }
}

contract MaintenanceRateDerivationTest is Test {
    MaintenanceRateHarness internal harness;
    MockERC20 internal token;
    uint256 internal constant PID = 1;
    uint256 internal constant PRINCIPAL = 1_000 ether;

    function setUp() public {
        harness = new MaintenanceRateHarness();
        token = new MockERC20("Token", "TKN", 18, 0);
        harness.mint(address(token), address(harness), PRINCIPAL);
        vm.warp(500 days); // ensure enough elapsed time to backdate lastMaintenanceTimestamp safely
    }

    function _assertAccrued(uint16 rateBps, uint64 lastTimestamp) internal {
        uint256 elapsedDays = (block.timestamp - lastTimestamp) / 1 days;
        uint256 expected = (PRINCIPAL * rateBps * elapsedDays) / (365 * 10_000);
        (uint256 totalDeposits, uint256 trackedBalance,) = harness.poolState(PID);
        assertEq(totalDeposits, PRINCIPAL - expected, "total deposits reduced by expected maintenance");
        assertEq(trackedBalance, PRINCIPAL - expected, "tracked balance reduced by expected maintenance");
    }

    function testUsesPoolMaintenanceRateWhenSet() public {
        uint64 last = uint64(block.timestamp - 365 days);
        harness.configurePool(PID, address(token), 150, 50, 10, PRINCIPAL, last);
        harness.enforce(PID);
        _assertAccrued(150, last);
    }

    function testFallsBackToDefaultWhenPoolRateZero() public {
        uint64 last = uint64(block.timestamp - 365 days);
        harness.configurePool(PID, address(token), 0, 200, 10, PRINCIPAL, last);
        harness.enforce(PID);
        _assertAccrued(200, last);
    }

    function testFallsBackToMaxWhenPoolAndDefaultZero() public {
        uint64 last = uint64(block.timestamp - 365 days);
        // When both pool and default are unset, LibMaintenance uses the max as a fallback (1% if max is zero).
        harness.configurePool(PID, address(token), 0, 0, 75, PRINCIPAL, last);
        harness.enforce(PID);
        _assertAccrued(100, last); // hardcoded 1% fallback
    }

    function testInitializesTimestampOnFirstAccrual() public {
        uint64 last = 0;
        harness.configurePool(PID, address(token), 100, 50, 10, PRINCIPAL, last);
        harness.enforce(PID);
        (uint256 totalDeposits, uint256 trackedBalance, uint64 lastTs) = harness.poolState(PID);
        assertEq(totalDeposits, PRINCIPAL, "no accrual on first set");
        assertEq(trackedBalance, PRINCIPAL, "tracked unchanged on first set");
        assertEq(lastTs, block.timestamp, "timestamp initialized");
    }
}
