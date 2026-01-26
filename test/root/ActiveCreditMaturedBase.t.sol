// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibActiveCreditIndex} from "../../src/libraries/LibActiveCreditIndex.sol";
import {Types} from "../../src/libraries/Types.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract ActiveCreditMaturedHarness {
    function initPool(uint256 pid, address underlying) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
    }

    function addEncumbrance(uint256 pid, bytes32 user, uint256 amount) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        LibActiveCreditIndex.applyEncumbranceIncrease(p, pid, user, amount);
    }

    function accrue(uint256 pid, uint256 amount) external {
        LibActiveCreditIndex.accrueWithSource(pid, amount, bytes32("test"));
    }

    function settle(uint256 pid, bytes32 user) external {
        LibActiveCreditIndex.settle(pid, user);
    }

    function activeCreditIndex(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].activeCreditIndex;
    }

    function maturedTotal(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].activeCreditMaturedTotal;
    }

    function pendingTotal(uint256 pid) external view returns (uint256 total) {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        for (uint256 i = 0; i < 24; i++) {
            total += p.activeCreditPendingBuckets[i];
        }
    }
}

contract ActiveCreditMaturedBaseTest is Test {
    ActiveCreditMaturedHarness internal harness;
    MockERC20 internal token;
    uint256 internal pid = 1;

    function setUp() public {
        harness = new ActiveCreditMaturedHarness();
        token = new MockERC20("Token", "TKN", 18, 0);
        harness.initPool(pid, address(token));
    }

    function test_ActiveCreditAccrualUsesMaturedBase() public {
        bytes32 userA = bytes32(uint256(0xA));
        bytes32 userB = bytes32(uint256(0xB));

        harness.addEncumbrance(pid, userA, 100 ether);
        vm.warp(block.timestamp + LibActiveCreditIndex.TIME_GATE + 1);
        harness.settle(pid, userA);

        assertEq(harness.maturedTotal(pid), 100 ether, "matured base after gate");

        harness.addEncumbrance(pid, userB, 100 ether);

        uint256 amount = 1_000 ether;
        harness.accrue(pid, amount);

        uint256 expectedDelta = Math.mulDiv(amount, LibActiveCreditIndex.INDEX_SCALE, 100 ether);
        assertEq(harness.activeCreditIndex(pid), expectedDelta, "index uses matured base");
    }

    function test_ActiveCreditPendingRollsIntoMatured() public {
        bytes32 user = bytes32(uint256(0xC));

        harness.addEncumbrance(pid, user, 50 ether);
        assertEq(harness.maturedTotal(pid), 0, "matured total starts at zero");
        assertEq(harness.pendingTotal(pid), 50 ether, "pending tracks immature");

        vm.warp(block.timestamp + LibActiveCreditIndex.TIME_GATE + 1);
        harness.settle(pid, user);

        assertEq(harness.maturedTotal(pid), 50 ether, "pending moved to matured");
        assertEq(harness.pendingTotal(pid), 0, "pending cleared after roll");
    }
}
