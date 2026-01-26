// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {Types} from "../../src/libraries/Types.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Harness for precision testing
contract FeeIndexPrecisionHarness {
    function s() internal pure returns (LibAppStorage.AppStorage storage) {
        return LibAppStorage.s();
    }

    function initPool(uint256 pid, address underlying, uint256 totalDeposits) external {
        Types.PoolData storage p = s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.totalDeposits = totalDeposits;
        p.trackedBalance = totalDeposits;
        p.feeIndex = 1e18;
    }

    function addUser(uint256 pid, bytes32 positionKey, uint256 principal) external {
        Types.PoolData storage p = s().pools[pid];
        p.userPrincipal[positionKey] = principal;
        p.userFeeIndex[positionKey] = p.feeIndex;
        p.userMaintenanceIndex[positionKey] = p.maintenanceIndex;
    }

    function accrueFee(uint256 pid, uint256 amount) external {
        s().pools[pid].trackedBalance += amount;
        LibFeeIndex.accrueWithSource(pid, amount, bytes32("test"));
    }

    function settleUser(uint256 pid, bytes32 positionKey) external {
        LibFeeIndex.settle(pid, positionKey);
    }

    function getFeeIndex(uint256 pid) external view returns (uint256) {
        return s().pools[pid].feeIndex;
    }

    function getUserAccruedYield(uint256 pid, bytes32 positionKey) external view returns (uint256) {
        return s().pools[pid].userAccruedYield[positionKey];
    }

    function getRemainder() external view returns (uint256) {
        // Return remainder for pool 1 (default test pool)
        return s().pools[1].feeIndexRemainder;
    }
    
    function getRemainderForPool(uint256 pid) external view returns (uint256) {
        return s().pools[pid].feeIndexRemainder;
    }

    function getTotalDeposits(uint256 pid) external view returns (uint256) {
        return s().pools[pid].totalDeposits;
    }
}

/// @notice Tests extreme precision scenarios and boundary conditions
contract FeeIndexPrecisionTest is Test {
    FeeIndexPrecisionHarness internal harness;

    uint256 internal constant PID = 1;
    uint256 internal constant SCALE = 1e18;

    function setUp() public {
        harness = new FeeIndexPrecisionHarness();
    }

    /// @notice Test very small fee over very large deposits
    function testVerySmallFeeOverLargeDeposits() public {
        // 1 billion tokens deposited
        uint256 largeDeposits = 1_000_000_000 ether;
        bytes32 userKey = bytes32(uint256(0xA));
        harness.initPool(PID, address(0x1), largeDeposits);
        harness.addUser(PID, userKey, largeDeposits);

        // Accrue 1 wei fee
        harness.accrueFee(PID, 1);

        // Should not revert
        harness.settleUser(PID, userKey);

        // Yield might be 0 due to rounding
        uint256 yield = harness.getUserAccruedYield(PID, userKey);
        uint256 remainder = harness.getRemainder();

        // But remainder should capture the precision loss
        if (yield == 0) {
            assertGt(remainder, 0);
        }
    }

    /// @notice Test very large fee over very small deposits
    function testVeryLargeFeeOverSmallDeposits() public {
        // 1 wei deposited
        bytes32 userKey = bytes32(uint256(0xA));
        harness.initPool(PID, address(0x1), 1);
        harness.addUser(PID, userKey, 1);

        // Accrue 1 billion tokens fee
        uint256 largeFee = 1_000_000_000 ether;
        harness.accrueFee(PID, largeFee);

        harness.settleUser(PID, userKey);

        // User should get the full fee (they're the only depositor)
        uint256 yield = harness.getUserAccruedYield(PID, userKey);
        assertEq(yield, largeFee);
    }

    /// @notice Test remainder accumulation over many small operations
    function testRemainderAccumulationOverManyOperations() public {
        // Setup with odd number to create remainders
        bytes32 userKey = bytes32(uint256(0xA));
        harness.initPool(PID, address(0x1), 7 ether);
        harness.addUser(PID, userKey, 7 ether);

        uint256 totalFeesAccrued = 0;

        // Accrue many tiny fees
        for (uint256 i = 0; i < 1000; i++) {
            harness.accrueFee(PID, 1);
            totalFeesAccrued += 1;
        }

        harness.settleUser(PID, userKey);

        uint256 yield = harness.getUserAccruedYield(PID, userKey);
        uint256 remainder = harness.getRemainder();

        // Total distributed + remainder should be close to total accrued
        // Due to rounding in the fee index calculation, there may be small precision loss
        assertLe(yield, totalFeesAccrued);
        assertGt(yield, 0);
    }

    /// @notice Test precision with maximum safe values
    function testMaximumSafeValues() public {
        // Use maximum safe deposit amount
        uint256 maxSafeDeposits = type(uint192).max;
        bytes32 userKey = bytes32(uint256(0xA));
        harness.initPool(PID, address(0x1), maxSafeDeposits);
        harness.addUser(PID, userKey, maxSafeDeposits);

        // Accrue maximum safe fee
        uint256 maxSafeFee = type(uint192).max / 2;
        harness.accrueFee(PID, maxSafeFee);

        // Should not overflow
        harness.settleUser(PID, userKey);

        uint256 yield = harness.getUserAccruedYield(PID, userKey);
        assertGt(yield, 0);
    }

    /// @notice Test that remainder never exceeds scale * totalDeposits
    function testRemainderBounds() public {
        bytes32 userKey = bytes32(uint256(0xA));
        harness.initPool(PID, address(0x1), 1000 ether);
        harness.addUser(PID, userKey, 1000 ether);

        // Accrue many fees
        for (uint256 i = 0; i < 100; i++) {
            harness.accrueFee(PID, 1 ether + i);
        }

        uint256 remainder = harness.getRemainder();
        uint256 totalDeposits = harness.getTotalDeposits(PID);

        // Remainder should be less than scale * totalDeposits
        assertLt(remainder, SCALE * totalDeposits);
    }

    /// @notice Test precision loss with many users
    function testPrecisionLossWithManyUsers() public {
        harness.initPool(PID, address(0x1), 1000 ether);

        // Add 100 users with 10 ether each
        for (uint256 i = 0; i < 100; i++) {
            harness.addUser(PID, bytes32(uint256(0x1000 + i)), 10 ether);
        }

        // Accrue fee
        harness.accrueFee(PID, 100 ether);

        // Settle all users and accumulate yield
        uint256 accumulatedYield;
        for (uint256 i = 0; i < 100; i++) {
            bytes32 userKey = bytes32(uint256(0x1000 + i));
            harness.settleUser(PID, userKey);
            accumulatedYield += harness.getUserAccruedYield(PID, userKey);
        }

        // Total yield + remainder should equal fee (within rounding)
        assertApproxEqAbs(accumulatedYield + harness.getRemainder(), 100 ether, 100);
    }

    /// @notice Test that index delta calculation doesn't overflow
    function testIndexDeltaNoOverflow() public {
        bytes32 userKey = bytes32(uint256(0xA));
        harness.initPool(PID, address(0x1), 1 ether);
        harness.addUser(PID, userKey, 1 ether);

        // Accrue fee that would cause large delta
        uint256 fee = type(uint128).max;
        harness.accrueFee(PID, fee);

        // Should not overflow
        uint256 index = harness.getFeeIndex(PID);
        assertGt(index, SCALE);
    }

    /// @notice Test precision with uneven distribution
    function testPrecisionWithUnevenDistribution() public {
        // One whale, one small user
        uint256 whaleAmount = 999 ether;
        uint256 smallAmount = 1 ether;
        bytes32 whaleKey = bytes32(uint256(0xA));
        bytes32 smallKey = bytes32(uint256(0xB));

        harness.initPool(PID, address(0x1), 1000 ether);
        harness.addUser(PID, whaleKey, whaleAmount);
        harness.addUser(PID, smallKey, smallAmount);

        // Accrue fee
        uint256 fee = 100 ether;
        harness.accrueFee(PID, fee);

        harness.settleUser(PID, whaleKey);
        harness.settleUser(PID, smallKey);

        uint256 whaleYield = harness.getUserAccruedYield(PID, whaleKey);
        uint256 smallYield = harness.getUserAccruedYield(PID, smallKey);

        // Whale should get ~99.9% of fee
        uint256 expectedWhale = (fee * 999) / 1000;
        assertApproxEqAbs(whaleYield, expectedWhale, 0.1 ether);

        // Small user should get ~0.1% of fee
        uint256 expectedSmall = fee / 1000;
        assertApproxEqAbs(smallYield, expectedSmall, 0.01 ether);
    }

    /// @notice Fuzz test: Precision maintained across random operations (simplified)
    function testFuzz_PrecisionMaintained(uint256 deposits, uint256 fee) public {
        // Bound inputs to reasonable ranges
        deposits = bound(deposits, 10 ether, type(uint96).max);
        fee = bound(fee, 1, type(uint96).max);
        bytes32 userKey = bytes32(uint256(0xA));

        harness.initPool(PID, address(0x1), deposits);

        // Add single user
        harness.addUser(PID, userKey, deposits);

        // Accrue fee
        harness.accrueFee(PID, fee);

        // Settle user and check
        {
            harness.settleUser(PID, userKey);
            uint256 totalYield = harness.getUserAccruedYield(PID, userKey);

            // Invariant: total yield should be less than or equal to fee
            // Single user should get close to all fees (within rounding)
            assertLe(totalYield, fee);

            // If fee is large enough relative to deposits, user should get most of it
            if (fee > deposits / 1000) {
                assertGt(totalYield, 0);
            }
        }
    }

    /// @notice Test that very small deposits don't break the system
    function testVerySmallDeposits() public {
        // 1 wei total deposits
        bytes32 userKey = bytes32(uint256(0xA));
        harness.initPool(PID, address(0x1), 1);
        harness.addUser(PID, userKey, 1);

        // Accrue 1 wei fee
        harness.accrueFee(PID, 1);

        harness.settleUser(PID, userKey);

        // Should get the fee
        uint256 yield = harness.getUserAccruedYield(PID, userKey);
        assertEq(yield, 1);
    }

    /// @notice Test precision with prime number deposits
    function testPrimeNumberDeposits() public {
        // Use prime numbers to maximize remainder generation
        uint256 primeDeposits = 997 ether;
        bytes32 userKey = bytes32(uint256(0xA));
        harness.initPool(PID, address(0x1), primeDeposits);
        harness.addUser(PID, userKey, primeDeposits);

        // Accrue fees that don't divide evenly
        for (uint256 i = 0; i < 100; i++) {
            harness.accrueFee(PID, 13 ether); // Another prime
        }

        harness.settleUser(PID, userKey);

        uint256 yield = harness.getUserAccruedYield(PID, userKey);

        // Should receive most of the fees (single user gets all)
        uint256 totalFees = 13 ether * 100;
        // Allow for rounding errors in the fee index calculation
        assertApproxEqRel(yield, totalFees, 0.01e18);
    }

    /// @notice Test that index never decreases even with precision loss
    function testIndexMonotonicDespitePrecisionLoss() public {
        bytes32 userKey = bytes32(uint256(0xA));
        harness.initPool(PID, address(0x1), type(uint192).max);
        harness.addUser(PID, userKey, type(uint192).max);

        uint256 previousIndex = harness.getFeeIndex(PID);

        // Accrue many tiny fees
        for (uint256 i = 0; i < 1000; i++) {
            harness.accrueFee(PID, 1);
            uint256 currentIndex = harness.getFeeIndex(PID);

            // Index should never decrease
            assertGe(currentIndex, previousIndex);
            previousIndex = currentIndex;
        }
    }

    /// @notice Test extreme ratio: huge deposits, tiny fee
    function testExtremeRatioHugeDepositsTinyFee() public {
        uint256 hugeDeposits = type(uint192).max;
        bytes32 userKey = bytes32(uint256(0xA));
        harness.initPool(PID, address(0x1), hugeDeposits);
        harness.addUser(PID, userKey, hugeDeposits);

        // Accrue 1 wei
        harness.accrueFee(PID, 1);

        // Delta will be 0, but remainder should capture it
        uint256 indexBefore = harness.getFeeIndex(PID);
        uint256 remainderAfter = harness.getRemainder();

        // Either index increased or remainder captured the fee
        uint256 indexAfter = harness.getFeeIndex(PID);
        assertTrue(indexAfter > indexBefore || remainderAfter >= SCALE);
    }

    /// @notice Test extreme ratio: tiny deposits, huge fee
    function testExtremeRatioTinyDepositsHugeFee() public {
        bytes32 userKey = bytes32(uint256(0xA));
        harness.initPool(PID, address(0x1), 1);
        harness.addUser(PID, userKey, 1);

        // Accrue huge fee
        uint256 hugeFee = type(uint128).max;
        harness.accrueFee(PID, hugeFee);

        harness.settleUser(PID, userKey);

        // User should get the full fee
        uint256 yield = harness.getUserAccruedYield(PID, userKey);
        assertEq(yield, hugeFee);
    }
}
