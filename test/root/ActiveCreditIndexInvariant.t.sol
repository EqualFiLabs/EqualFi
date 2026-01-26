// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibActiveCreditIndex} from "../../src/libraries/LibActiveCreditIndex.sol";
import {Types} from "../../src/libraries/Types.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract ActiveCreditIndexInvariantHarness {
    function initPool(uint256 pid, address underlying) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
    }

    function addEncumbrance(uint256 pid, bytes32 user, uint256 amount) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        LibActiveCreditIndex.applyEncumbranceIncrease(p, pid, user, amount);
    }

    function addDebt(uint256 pid, bytes32 user, uint256 amount) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        Types.ActiveCreditState storage state = p.userActiveCreditStateDebt[user];
        p.activeCreditPrincipalTotal += amount;
        LibActiveCreditIndex.applyWeightedIncreaseWithGate(p, state, amount, pid, user, true);
        state.indexSnapshot = p.activeCreditIndex;
    }

    function accrue(uint256 pid, uint256 amount) external {
        LibActiveCreditIndex.accrueWithSource(pid, amount, bytes32("test"));
    }

    function settle(uint256 pid, bytes32 user) external {
        LibActiveCreditIndex.settle(pid, user);
    }

    function pendingActiveCredit(uint256 pid, bytes32 user) external view returns (uint256) {
        return LibActiveCreditIndex.pendingActiveCredit(pid, user);
    }

    function accruedYield(uint256 pid, bytes32 user) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userAccruedYield[user];
    }

    function timeCredit(uint256 pid, bytes32 user, bool debt) external view returns (uint256) {
        Types.ActiveCreditState storage state = debt
            ? LibAppStorage.s().pools[pid].userActiveCreditStateDebt[user]
            : LibAppStorage.s().pools[pid].userActiveCreditStateEncumbrance[user];
        return LibActiveCreditIndex.timeCredit(state);
    }

    function activeWeight(uint256 pid, bytes32 user, bool debt) external view returns (uint256) {
        Types.ActiveCreditState storage state = debt
            ? LibAppStorage.s().pools[pid].userActiveCreditStateDebt[user]
            : LibAppStorage.s().pools[pid].userActiveCreditStateEncumbrance[user];
        return LibActiveCreditIndex.activeWeight(state);
    }

    function pendingTotal(uint256 pid) external view returns (uint256 total) {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        for (uint256 i = 0; i < 24; i++) {
            total += p.activeCreditPendingBuckets[i];
        }
    }

    function maturedTotal(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].activeCreditMaturedTotal;
    }

    function activeCreditIndex(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].activeCreditIndex;
    }

    function indexRemainder(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].activeCreditIndexRemainder;
    }

    function principalOf(uint256 pid, bytes32 user, bool debt) external view returns (uint256) {
        Types.ActiveCreditState storage state = debt
            ? LibAppStorage.s().pools[pid].userActiveCreditStateDebt[user]
            : LibAppStorage.s().pools[pid].userActiveCreditStateEncumbrance[user];
        return state.principal;
    }
}

contract ActiveCreditIndexInvariantTest is Test {
    ActiveCreditIndexInvariantHarness internal harness;
    MockERC20 internal token;
    uint256 internal constant PID = 1;

    function setUp() public {
        harness = new ActiveCreditIndexInvariantHarness();
        token = new MockERC20("Token", "TKN", 18, 0);
        harness.initPool(PID, address(token));
    }

    function test_TimeGateWeighting() public {
        bytes32 user = bytes32(uint256(0xA11CE));
        harness.addEncumbrance(PID, user, 100 ether);

        assertEq(harness.activeWeight(PID, user, false), 0, "weight pre-gate");
        assertTrue(harness.timeCredit(PID, user, false) < LibActiveCreditIndex.TIME_GATE, "credit pre-gate");

        vm.warp(block.timestamp + LibActiveCreditIndex.TIME_GATE - 1);
        assertEq(harness.activeWeight(PID, user, false), 0, "weight before gate");

        vm.warp(block.timestamp + 1);
        assertEq(harness.activeWeight(PID, user, false), 100 ether, "weight at gate");
        assertEq(harness.timeCredit(PID, user, false), LibActiveCreditIndex.TIME_GATE, "credit capped");
    }

    function test_BucketTotalsMatchPrincipal() public {
        bytes32 userA = bytes32(uint256(0xBEEF));
        bytes32 userB = bytes32(uint256(0xC0DE));

        harness.addEncumbrance(PID, userA, 10 ether);
        harness.addDebt(PID, userB, 20 ether);

        uint256 totalPrincipal =
            harness.principalOf(PID, userA, false) + harness.principalOf(PID, userB, true);
        assertEq(harness.pendingTotal(PID) + harness.maturedTotal(PID), totalPrincipal, "pending + matured");

        vm.warp(block.timestamp + LibActiveCreditIndex.TIME_GATE + 2);
        harness.settle(PID, userA);
        harness.settle(PID, userB);

        assertEq(harness.pendingTotal(PID), 0, "pending cleared");
        assertEq(harness.maturedTotal(PID), totalPrincipal, "matured equals total");
    }

    function test_SettleClearsPendingYield() public {
        bytes32 user = bytes32(uint256(0xD00D));
        harness.addEncumbrance(PID, user, 50 ether);

        vm.warp(block.timestamp + LibActiveCreditIndex.TIME_GATE + 1);
        harness.accrue(PID, 100 ether);

        uint256 pendingBefore = harness.pendingActiveCredit(PID, user);
        assertTrue(pendingBefore > 0, "pending before settle");

        harness.settle(PID, user);
        assertEq(harness.pendingActiveCredit(PID, user), 0, "pending after settle");
        assertTrue(harness.accruedYield(PID, user) > 0, "yield accrued");
    }

    function test_RemainderWithinBase() public {
        bytes32 user = bytes32(uint256(0xCAFE));
        harness.addEncumbrance(PID, user, 100 ether);

        vm.warp(block.timestamp + LibActiveCreditIndex.TIME_GATE + 1);
        harness.settle(PID, user);

        uint256 base = harness.maturedTotal(PID);
        harness.accrue(PID, 1 ether);
        if (base > 0) {
            assertTrue(harness.indexRemainder(PID) < base, "remainder bounded");
        }
    }

    function testFuzz_TimeCreditCapped(uint96 amount, uint64 warpBy) public {
        uint256 boundedAmount = bound(uint256(amount), 1 ether, 1_000_000 ether);
        uint256 boundedWarp = bound(uint256(warpBy), 0, LibActiveCreditIndex.TIME_GATE * 2);
        bytes32 user = bytes32(uint256(0x1234));
        harness.addDebt(PID, user, boundedAmount);

        vm.warp(block.timestamp + boundedWarp);
        uint256 credit = harness.timeCredit(PID, user, true);
        assertTrue(credit <= LibActiveCreditIndex.TIME_GATE, "credit capped");
    }
}
