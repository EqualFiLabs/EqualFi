// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {Types} from "../../src/libraries/Types.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

/// @notice Harness for testing fee index invariants
contract FeeIndexInvariantHarness {
    function s() internal pure returns (LibAppStorage.AppStorage storage) {
        return LibAppStorage.s();
    }

    function initPool(uint256 pid, address underlying, uint256 totalDeposits) external {
        Types.PoolData storage p = s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.totalDeposits = totalDeposits;
        p.trackedBalance = totalDeposits;
        p.feeIndex = 1e18; // Start at 1.0
    }

    function addUser(uint256 pid, bytes32 user, uint256 principal) external {
        Types.PoolData storage p = s().pools[pid];
        p.userPrincipal[user] = principal;
        p.userFeeIndex[user] = p.feeIndex;
        p.userMaintenanceIndex[user] = p.maintenanceIndex;
    }

    function accrueFee(uint256 pid, uint256 amount) external {
        s().pools[pid].trackedBalance += amount;
        LibFeeIndex.accrueWithSource(pid, amount, bytes32("test"));
    }

    function settleUser(uint256 pid, bytes32 user) external {
        LibFeeIndex.settle(pid, user);
    }

    function getFeeIndex(uint256 pid) external view returns (uint256) {
        return s().pools[pid].feeIndex;
    }

    function getTotalDeposits(uint256 pid) external view returns (uint256) {
        return s().pools[pid].totalDeposits;
    }

    function getUserPrincipal(uint256 pid, bytes32 user) external view returns (uint256) {
        return s().pools[pid].userPrincipal[user];
    }

    function getUserAccruedYield(uint256 pid, bytes32 user) external view returns (uint256) {
        return s().pools[pid].userAccruedYield[user];
    }

    function getPendingYield(uint256 pid, bytes32 user) external view returns (uint256) {
        return LibFeeIndex.pendingYield(pid, user);
    }

    function getRemainder() external view returns (uint256) {
        // Return remainder for pool 1 (default test pool)
        return s().pools[1].feeIndexRemainder;
    }
    
    function getRemainderForPool(uint256 pid) external view returns (uint256) {
        return s().pools[pid].feeIndexRemainder;
    }
}

/// @notice Property-based tests ensuring conservation of value and no yield fabrication
contract FeeIndexInvariantsTest is Test {
    FeeIndexInvariantHarness internal harness;
    MockERC20 internal token;

    uint256 internal constant PID = 1;
    uint256 internal constant SCALE = 1e18;
    bytes32 internal constant USER_A = keccak256("userA");
    bytes32 internal constant USER_B = keccak256("userB");
    bytes32 internal constant USER_C = keccak256("userC");

    function setUp() public {
        harness = new FeeIndexInvariantHarness();
        token = new MockERC20("Mock Token", "MOCK", 18, 0);
    }

    /// @notice Invariant: Total yield distributed never exceeds total fees accrued
    function testInvariant_NoYieldFabrication() public {
        harness.initPool(PID, address(token), 1000 ether);

        // Add users with different principals
        harness.addUser(PID, keccak256("userA"), 500 ether);
        harness.addUser(PID, keccak256("userB"), 300 ether);
        harness.addUser(PID, keccak256("userC"), 200 ether);

        uint256 totalFeesAccrued;

        // Accrue fees multiple times
        for (uint256 i = 0; i < 5; i++) {
            harness.accrueFee(PID, (i + 1) * 10 ether);
            totalFeesAccrued += (i + 1) * 10 ether;
        }

        // Settle all users and check invariant
        harness.settleUser(PID, keccak256("userA"));
        harness.settleUser(PID, keccak256("userB"));
        harness.settleUser(PID, keccak256("userC"));

        uint256 yieldA = harness.getUserAccruedYield(PID, keccak256("userA"));
        uint256 yieldB = harness.getUserAccruedYield(PID, keccak256("userB"));
        uint256 yieldC = harness.getUserAccruedYield(PID, keccak256("userC"));
        uint256 remainder = harness.getRemainder();

        // Invariant: totalYieldDistributed + remainder <= totalFeesAccrued
        assertLe(yieldA + yieldB + yieldC, totalFeesAccrued);
        assertLe(yieldA + yieldB + yieldC + remainder, totalFeesAccrued + SCALE);
    }

    /// @notice Invariant: Yield is proportional to principal
    function testInvariant_ProportionalYield() public {
        harness.initPool(PID, address(token), 1000 ether);

        bytes32 userA = keccak256("userA");
        bytes32 userB = keccak256("userB");

        // User A has 2x principal of user B
        harness.addUser(PID, userA, 600 ether);
        harness.addUser(PID, userB, 300 ether);

        // Accrue fees
        harness.accrueFee(PID, 90 ether);

        // Settle both
        harness.settleUser(PID, userA);
        harness.settleUser(PID, userB);

        uint256 yieldA = harness.getUserAccruedYield(PID, userA);
        uint256 yieldB = harness.getUserAccruedYield(PID, userB);

        // User A should have ~2x yield of user B (within rounding)
        assertApproxEqRel(yieldA, yieldB * 2, 0.01e18); // 1% tolerance
    }

    /// @notice Invariant: Fee index is monotonically increasing
    function testInvariant_MonotonicFeeIndex() public {
        harness.initPool(PID, address(token), 1000 ether);
        harness.addUser(PID, USER_A, 1000 ether);

        uint256 previousIndex = harness.getFeeIndex(PID);

        for (uint256 i = 0; i < 10; i++) {
            harness.accrueFee(PID, 10 ether);
            uint256 currentIndex = harness.getFeeIndex(PID);

            // Index should never decrease
            assertGe(currentIndex, previousIndex);
            previousIndex = currentIndex;
        }
    }

    /// @notice Invariant: Settlement is idempotent
    function testInvariant_SettlementIdempotent() public {
        harness.initPool(PID, address(token), 1000 ether);
        harness.addUser(PID, USER_A, 1000 ether);

        harness.accrueFee(PID, 50 ether);

        // First settlement
        harness.settleUser(PID, USER_A);
        uint256 yieldAfterFirst = harness.getUserAccruedYield(PID, USER_A);

        // Second settlement (no new fees)
        harness.settleUser(PID, USER_A);
        uint256 yieldAfterSecond = harness.getUserAccruedYield(PID, USER_A);

        // Yield should be unchanged
        assertEq(yieldAfterFirst, yieldAfterSecond);
    }

    /// @notice Invariant: Pending yield view matches actual settlement
    function testInvariant_PendingYieldMatchesSettlement() public {
        harness.initPool(PID, address(token), 1000 ether);
        harness.addUser(PID, USER_A, 1000 ether);

        harness.accrueFee(PID, 50 ether);

        uint256 pendingBefore = harness.getPendingYield(PID, USER_A);

        harness.settleUser(PID, USER_A);
        uint256 accruedAfter = harness.getUserAccruedYield(PID, USER_A);

        // Pending should match accrued (within rounding)
        assertApproxEqAbs(pendingBefore, accruedAfter, 1);
    }

    /// @notice Invariant: No yield loss over many operations
    function testInvariant_NoYieldLossOverManyOperations() public {
        harness.initPool(PID, address(token), 1000 ether);
        harness.addUser(PID, USER_A, 1000 ether);

        uint256 totalFeesAccrued = 0;

        // Accrue many small fees
        for (uint256 i = 0; i < 100; i++) {
            harness.accrueFee(PID, 1 ether);
            totalFeesAccrued += 1 ether;
        }

        harness.settleUser(PID, USER_A);
        uint256 yieldDistributed = harness.getUserAccruedYield(PID, USER_A);
        uint256 remainder = harness.getRemainder();

        // Total distributed + remainder should be close to total accrued
        // Allow for small precision loss
        assertApproxEqAbs(yieldDistributed + remainder, totalFeesAccrued, 100);
    }

    /// @notice Invariant: User joining after fees doesn't get past yield
    function testInvariant_NoRetroactiveYield() public {
        harness.initPool(PID, address(token), 1000 ether);
        harness.addUser(PID, USER_A, 1000 ether);

        // Accrue fees before user B joins
        harness.accrueFee(PID, 50 ether);

        // User B joins after fees
        harness.addUser(PID, USER_B, 500 ether);

        // Settle both
        harness.settleUser(PID, USER_A);
        harness.settleUser(PID, USER_B);

        uint256 yieldA = harness.getUserAccruedYield(PID, USER_A);
        uint256 yieldB = harness.getUserAccruedYield(PID, USER_B);

        // User A should have all the yield
        assertEq(yieldA, 50 ether);
        // User B should have none
        assertEq(yieldB, 0);
    }

    /// @notice Fuzz test: Conservation of value with random operations
    function testFuzz_ConservationOfValue(uint256 seed) public {
        seed = bound(seed, 1, type(uint128).max);

        harness.initPool(PID, address(token), 0); // Start with 0, will add users

        // Add users with random principals (reduced to 3 to save stack)
        bytes32 user0 = keccak256("user0");
        bytes32 user1 = keccak256("user1");
        bytes32 user2 = keccak256("user2");

        harness.addUser(PID, user0, bound(uint256(keccak256(abi.encode(seed, 0))), 100 ether, 1000 ether));
        harness.addUser(PID, user1, bound(uint256(keccak256(abi.encode(seed, 1))), 100 ether, 1000 ether));
        harness.addUser(PID, user2, bound(uint256(keccak256(abi.encode(seed, 2))), 100 ether, 1000 ether));

        // Accrue random fees
        uint256 totalFees;
        for (uint256 i = 0; i < 10; i++) {
            uint256 fee = bound(uint256(keccak256(abi.encode(seed, i + 100))), 1 ether, 100 ether);
            harness.accrueFee(PID, fee);
            totalFees += fee;
        }

        // Settle all users
        harness.settleUser(PID, user0);
        harness.settleUser(PID, user1);
        harness.settleUser(PID, user2);

        // Check invariant
        uint256 yield0 = harness.getUserAccruedYield(PID, user0);
        uint256 yield1 = harness.getUserAccruedYield(PID, user1);
        uint256 yield2 = harness.getUserAccruedYield(PID, user2);
        uint256 remainder = harness.getRemainder();

        assertLe(yield0 + yield1 + yield2, totalFees);
        assertLe(yield0 + yield1 + yield2 + remainder, totalFees + (SCALE * 3));
    }

    /// @notice Test extreme precision scenarios
    function testInvariant_ExtremePrecisionScenarios() public {
        // Very large deposits, very small fee
        harness.initPool(PID, address(token), 1_000_000_000 ether);
        harness.addUser(PID, USER_A, 1_000_000_000 ether);

        // Accrue 1 wei fee
        harness.accrueFee(PID, 1);

        // Should not revert
        harness.settleUser(PID, USER_A);

        // Yield might be 0 due to rounding, but remainder should capture it
        uint256 yield = harness.getUserAccruedYield(PID, USER_A);
        uint256 remainder = harness.getRemainder();

        // Either yield is 1 or remainder captured it
        assertTrue(yield == 1 || remainder >= SCALE);
    }

    /// @notice Test that zero fees don't change state
    function testInvariant_ZeroFeesNoOp() public {
        harness.initPool(PID, address(token), 1000 ether);
        harness.addUser(PID, USER_A, 1000 ether);

        uint256 indexBefore = harness.getFeeIndex(PID);

        // Accrue zero fee
        harness.accrueFee(PID, 0);

        uint256 indexAfter = harness.getFeeIndex(PID);

        // Index should be unchanged
        assertEq(indexBefore, indexAfter);
    }
}
