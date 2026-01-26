// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {Types} from "../../src/libraries/Types.sol";

/// @notice Harness for stress testing
contract FeeIndexStressHarness {
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

    function addUser(uint256 pid, bytes32 user, uint256 principal) external {
        Types.PoolData storage p = s().pools[pid];
        p.userPrincipal[user] = principal;
        p.userFeeIndex[user] = p.feeIndex;
        p.userMaintenanceIndex[user] = p.maintenanceIndex;
        p.totalDeposits += principal;
        p.trackedBalance += principal;
    }

    function accrueFee(uint256 pid, uint256 amount) external {
        s().pools[pid].trackedBalance += amount;
        LibFeeIndex.accrueWithSource(pid, amount, bytes32("test"));
    }

    function settleUser(uint256 pid, bytes32 user) external {
        LibFeeIndex.settle(pid, user);
    }

    function settleMultiple(uint256 pid, bytes32[] calldata users) external {
        for (uint256 i = 0; i < users.length; i++) {
            LibFeeIndex.settle(pid, users[i]);
        }
    }

    function getUserAccruedYield(uint256 pid, bytes32 user) external view returns (uint256) {
        return s().pools[pid].userAccruedYield[user];
    }

    function getUserPrincipal(uint256 pid, bytes32 user) external view returns (uint256) {
        return s().pools[pid].userPrincipal[user];
    }

    function getFeeIndex(uint256 pid) external view returns (uint256) {
        return s().pools[pid].feeIndex;
    }

    function getTotalDeposits(uint256 pid) external view returns (uint256) {
        return s().pools[pid].totalDeposits;
    }
}

/// @notice Stress tests with many users and operations
contract FeeIndexStressTest is Test {
    FeeIndexStressHarness internal harness;

    uint256 internal constant PID = 1;
    uint256 internal constant SCALE = 1e18;

    function setUp() public {
        harness = new FeeIndexStressHarness();
        harness.initPool(PID, address(0x1), 0);
    }

    function _userKey(uint256 seed) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("user", seed));
    }

    /// @notice Test 100 users with equal principals
    function test100UsersEqualPrincipals() public {
        // Add 100 users
        for (uint256 i = 0; i < 100; i++) {
            harness.addUser(PID, _userKey(0x1000 + i), 100 ether);
        }

        assertEq(harness.getTotalDeposits(PID), 10_000 ether);

        // Accrue fees and settle
        harness.accrueFee(PID, 1000 ether);

        // Settle and check each user
        uint256 totalDistributed;
        for (uint256 i = 0; i < 100; i++) {
            bytes32 user = _userKey(0x1000 + i);
            harness.settleUser(PID, user);
            uint256 userYield = harness.getUserAccruedYield(PID, user);
            assertApproxEqAbs(userYield, 10 ether, 0.01 ether);
            totalDistributed += userYield;
        }

        // Total distributed should equal total fees (within rounding)
        assertApproxEqAbs(totalDistributed, 1000 ether, 100);
    }

    /// @notice Test whale (99%) vs minnows (1%)
    function testWhaleVsMinnows() public {
        bytes32 whale = keccak256("whale");
        harness.addUser(PID, whale, 9900 ether);

        bytes32[] memory minnows = new bytes32[](99);
        for (uint256 i = 0; i < 99; i++) {
            minnows[i] = _userKey(0x2000 + i);
            harness.addUser(PID, minnows[i], 1 ether);
        }

        // Total: 9900 + 99 = 9999 ether
        assertEq(harness.getTotalDeposits(PID), 9999 ether);

        // Accrue fees
        harness.accrueFee(PID, 1000 ether);

        // Settle whale
        harness.settleUser(PID, whale);
        uint256 whaleYield = harness.getUserAccruedYield(PID, whale);

        // Settle minnows
        harness.settleMultiple(PID, minnows);
        uint256 totalMinnowYield = 0;
        for (uint256 i = 0; i < 99; i++) {
            totalMinnowYield += harness.getUserAccruedYield(PID, minnows[i]);
        }

        // Whale should get ~99% of fees
        assertApproxEqRel(whaleYield, 990 ether, 0.001e18);

        // Minnows should get ~1% of fees total
        assertApproxEqRel(totalMinnowYield, 10 ether, 0.01e18);

        // Total should equal fees
        assertApproxEqAbs(whaleYield + totalMinnowYield, 1000 ether, 1 ether);
    }

    /// @notice Test many small fees over many users
    function testManySmallFeesOverManyUsers() public {
        bytes32[] memory users = new bytes32[](50);

        // Add 50 users with varying principals
        for (uint256 i = 0; i < 50; i++) {
            users[i] = _userKey(0x3000 + i);
            uint256 principal = (i + 1) * 10 ether; // 10, 20, 30, ... 500 ether
            harness.addUser(PID, users[i], principal);
        }

        // Accrue 100 small fees
        uint256 totalFees = 0;
        for (uint256 i = 0; i < 100; i++) {
            uint256 fee = (i + 1) * 1 ether;
            harness.accrueFee(PID, fee);
            totalFees += fee;
        }

        // Settle all users
        harness.settleMultiple(PID, users);

        // Verify proportional distribution
        uint256 totalDistributed = 0;
        for (uint256 i = 0; i < 50; i++) {
            uint256 yield = harness.getUserAccruedYield(PID, users[i]);
            totalDistributed += yield;
        }

        // Total distributed should be close to total fees (within rounding tolerance)
        // With many small fees and many users, rounding errors accumulate
        assertApproxEqRel(totalDistributed, totalFees, 0.01e18);

        // Verify that larger principals get more yield
        uint256 yield10 = harness.getUserAccruedYield(PID, users[10]);
        uint256 yield0 = harness.getUserAccruedYield(PID, users[0]);
        assertGt(yield10, yield0); // User with 11x principal should have more yield
    }

    /// @notice Test users joining and leaving over time
    function testUsersJoiningAndLeaving() public {
        bytes32[] memory users = new bytes32[](20);

        // Phase 1: First 5 users join
        for (uint256 i = 0; i < 5; i++) {
            users[i] = _userKey(0x4000 + i);
            harness.addUser(PID, users[i], 100 ether);
        }

        // Accrue fees
        harness.accrueFee(PID, 50 ether);

        // Phase 2: Next 10 users join
        for (uint256 i = 5; i < 15; i++) {
            users[i] = _userKey(0x4000 + i);
            harness.addUser(PID, users[i], 100 ether);
        }

        // Accrue more fees
        harness.accrueFee(PID, 150 ether);

        // Phase 3: Last 5 users join
        for (uint256 i = 15; i < 20; i++) {
            users[i] = _userKey(0x4000 + i);
            harness.addUser(PID, users[i], 100 ether);
        }

        // Accrue final fees
        harness.accrueFee(PID, 200 ether);

        // Settle all
        harness.settleMultiple(PID, users);

        // First 5 users should have most yield (got all 3 fee rounds)
        uint256 yield0 = harness.getUserAccruedYield(PID, users[0]);
        uint256 yield7 = harness.getUserAccruedYield(PID, users[7]);
        uint256 yield17 = harness.getUserAccruedYield(PID, users[17]);

        assertGt(yield0, yield7); // User 0 got more rounds
        assertGt(yield7, yield17); // User 7 got more rounds than 17
    }

    /// @notice Test concurrent settlements don't interfere
    function testConcurrentSettlements() public {
        bytes32[] memory users = new bytes32[](10);

        for (uint256 i = 0; i < 10; i++) {
            users[i] = _userKey(0x5000 + i);
            harness.addUser(PID, users[i], 100 ether);
        }

        // Accrue fees
        harness.accrueFee(PID, 100 ether);

        // Settle users one by one
        for (uint256 i = 0; i < 10; i++) {
            harness.settleUser(PID, users[i]);
        }

        uint256[] memory yields = new uint256[](10);
        for (uint256 i = 0; i < 10; i++) {
            yields[i] = harness.getUserAccruedYield(PID, users[i]);
        }

        // All yields should be equal (same principal, same fees)
        for (uint256 i = 1; i < 10; i++) {
            assertEq(yields[i], yields[0]);
        }
    }

    /// @notice Test extreme user count (gas test)
    function testExtremeUserCount() public {
        uint256 userCount = 200;
        // Add many users
        for (uint256 i = 0; i < userCount; i++) {
            harness.addUser(PID, _userKey(0x6000 + i), 10 ether);
        }

        // Accrue fees
        harness.accrueFee(PID, 200 ether);

        // Settle all users individually
        for (uint256 i = 0; i < userCount; i++) {
            harness.settleUser(PID, _userKey(0x6000 + i));
        }

        // Verify distribution
        uint256 totalDistributed;
        for (uint256 i = 0; i < userCount; i++) {
            totalDistributed += harness.getUserAccruedYield(PID, _userKey(0x6000 + i));
        }

        assertApproxEqAbs(totalDistributed, 200 ether, 200);
    }

    /// @notice Test repeated fee accruals and settlements
    function testRepeatedAccrualsAndSettlements() public {
        bytes32[] memory users = new bytes32[](10);

        for (uint256 i = 0; i < 10; i++) {
            users[i] = _userKey(0x7000 + i);
            harness.addUser(PID, users[i], 100 ether);
        }

        uint256 totalFeesAccrued = 0;

        // Repeat 50 times: accrue then settle
        for (uint256 round = 0; round < 50; round++) {
            uint256 fee = (round + 1) * 1 ether;
            harness.accrueFee(PID, fee);
            totalFeesAccrued += fee;

            // Settle random user
            uint256 userIndex = round % 10;
            harness.settleUser(PID, users[userIndex]);
        }

        // Final settlement for all
        harness.settleMultiple(PID, users);

        // Verify total distribution
        uint256 totalDistributed = 0;
        for (uint256 i = 0; i < 10; i++) {
            totalDistributed += harness.getUserAccruedYield(PID, users[i]);
        }

        assertApproxEqAbs(totalDistributed, totalFeesAccrued, 100);
    }

    /// @notice Test fee index monotonicity with many operations
    function testFeeIndexMonotonicityWithManyOps() public {
        bytes32 user = _userKey(0x8000);
        harness.addUser(PID, user, 1000 ether);

        uint256 previousIndex = harness.getFeeIndex(PID);

        // Accrue fees 1000 times
        for (uint256 i = 0; i < 1000; i++) {
            harness.accrueFee(PID, 1 ether);
            uint256 currentIndex = harness.getFeeIndex(PID);

            // Index should never decrease
            assertGe(currentIndex, previousIndex);
            previousIndex = currentIndex;
        }
    }

    /// @notice Test precision maintained with uneven principals
    function testPrecisionWithUnevenPrincipals() public {
        bytes32[] memory users = new bytes32[](10);
        uint256[] memory principals = new uint256[](10);

        // Create users with exponentially increasing principals
        for (uint256 i = 0; i < 10; i++) {
            users[i] = _userKey(0x9000 + i);
            principals[i] = (2 ** i) * 1 ether; // 1, 2, 4, 8, 16, ... 512 ether
            harness.addUser(PID, users[i], principals[i]);
        }

        // Accrue fees
        uint256 totalFees = 1000 ether;
        harness.accrueFee(PID, totalFees);

        // Settle all
        harness.settleMultiple(PID, users);

        // Verify proportional distribution
        uint256 totalPrincipal = harness.getTotalDeposits(PID);
        uint256 totalDistributed = 0;

        for (uint256 i = 0; i < 10; i++) {
            uint256 yield = harness.getUserAccruedYield(PID, users[i]);
            totalDistributed += yield;

            // Expected yield = (principal / totalPrincipal) * totalFees
            uint256 expectedYield = (principals[i] * totalFees) / totalPrincipal;
            assertApproxEqRel(yield, expectedYield, 0.01e18);
        }

        // Allow for rounding errors across multiple users
        assertApproxEqRel(totalDistributed, totalFees, 0.001e18);
    }

    /// @notice Fuzz test: Random user operations (simplified to avoid stack too deep)
    function testFuzz_RandomUserOperations(uint256 seed) public {
        vm.assume(seed > 0 && seed < type(uint128).max);

        uint256 userCount = 10; // Fixed count to avoid stack issues
        bytes32[] memory users = new bytes32[](userCount);

        // Add users with random principals
        for (uint256 i = 0; i < userCount; i++) {
            users[i] = _userKey(0x1000 + i);
            uint256 principal = ((seed + i) % 100 ether) + 10 ether;
            harness.addUser(PID, users[i], principal);
        }

        // Accrue fees
        uint256 totalFees = (seed % 100 ether) + 10 ether;
        harness.accrueFee(PID, totalFees);

        // Settle all users
        harness.settleMultiple(PID, users);

        // Verify conservation of value
        uint256 totalDistributed = 0;
        for (uint256 i = 0; i < userCount; i++) {
            totalDistributed += harness.getUserAccruedYield(PID, users[i]);
        }

        assertLe(totalDistributed, totalFees);
    }
}
