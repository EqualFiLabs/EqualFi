// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibMaintenance} from "../../src/libraries/LibMaintenance.sol";
import {Types} from "../../src/libraries/Types.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract MaintenanceHarness {
    function seedPool(uint256 pid, address underlying, bytes32 positionKey, uint256 principal) external {
        LibAppStorage.AppStorage storage s = LibAppStorage.s();
        s.foundationReceiver = address(0xFADE);
        s.defaultMaintenanceRateBps = 100; // 1% annual
        Types.PoolData storage p = s.pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.userPrincipal[positionKey] = principal;
        p.totalDeposits = principal;
        p.trackedBalance = principal;
        p.lastMaintenanceTimestamp = uint64(block.timestamp - 365 days); // force one year of accrual
    }

    function enforce(uint256 pid) external {
        LibMaintenance.enforce(pid);
    }

    function state(uint256 pid, bytes32 positionKey)
        external
        view
        returns (uint256 principal, uint256 totalDeposits, uint256 trackedBalance)
    {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        principal = p.userPrincipal[positionKey];
        totalDeposits = p.totalDeposits;
        trackedBalance = p.trackedBalance;
    }
}

contract PoolIsolationMaintenanceTest is Test {
    MaintenanceHarness internal harness;
    MockERC20 internal token;
    bytes32 internal positionKey = bytes32(uint256(0xBEEF));
    uint256 internal pid = 1;

    function setUp() public {
        vm.warp(365 days + 1); // ensure timestamp large enough for backdating
        harness = new MaintenanceHarness();
        token = new MockERC20("Token", "TKN", 18, 0);
        uint256 principal = 1_000 ether;
        token.mint(address(harness), principal);
        harness.seedPool(pid, address(token), positionKey, principal);
    }

    function test_MaintenanceCanDropTrackedBelowPrincipal() public {
        (uint256 principalBefore, uint256 totalBefore, uint256 trackedBefore) = harness.state(pid, positionKey);
        assertEq(principalBefore, 1_000 ether, "principal before");
        assertEq(totalBefore, 1_000 ether, "total before");
        assertEq(trackedBefore, 1_000 ether, "tracked before");

        harness.enforce(pid); // accrues 1% yearly maintenance and pays it out

        (uint256 principalAfter, uint256 totalAfter, uint256 trackedAfter) = harness.state(pid, positionKey);
        // User principal remains 1,000 until settlement, but tracked balance paid out maintenance (10 ether)
        assertEq(principalAfter, 1_000 ether, "principal untouched");
        assertEq(totalAfter, 990 ether, "total deposits reduced by maintenance");
        assertEq(trackedAfter, 990 ether, "tracked balance reduced by maintenance payout");
        assertLt(trackedAfter, principalAfter, "tracked now below recorded principal");
    }
}
