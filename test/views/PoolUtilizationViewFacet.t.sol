// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PoolUtilizationViewFacet} from "../../src/views/PoolUtilizationViewFacet.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {Types} from "../../src/libraries/Types.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract PoolUtilizationViewFacetHarness is PoolUtilizationViewFacet {
    function initPool(uint256 pid, address underlying) external {
        LibAppStorage.s().pools[pid].underlying = underlying;
        LibAppStorage.s().pools[pid].initialized = true;
    }

    function setConfig(uint256 pid, bool isCapped, uint256 depositCap, uint256 maxUserCount) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.poolConfig.isCapped = isCapped;
        p.poolConfig.depositCap = depositCap;
        p.poolConfig.maxUserCount = maxUserCount;
    }

    function setTotals(uint256 pid, uint256 totalDeposits, uint256 userCount) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.totalDeposits = totalDeposits;
        p.userCount = userCount;
    }

    function setUserPrincipal(uint256 pid, bytes32 positionKey, uint256 principal) external {
        LibAppStorage.s().pools[pid].userPrincipal[positionKey] = principal;
    }
}

contract PoolUtilizationViewFacetTest is Test {
    PoolUtilizationViewFacetHarness internal viewFacet;
    MockERC20 internal token;

    uint256 internal constant PID = 1;
    bytes32 internal constant POSITION_KEY = bytes32(uint256(0xA11CE));

    function setUp() public {
        viewFacet = new PoolUtilizationViewFacetHarness();
        token = new MockERC20("Token", "TOK", 18, 0);
        viewFacet.initPool(PID, address(token));
    }

    function test_getPoolUtilization_computesBorrowedAndUtilization() public {
        // deposits = 100, contract balance = 60 => borrowed = 40, util = 40%
        viewFacet.setTotals(PID, 100 ether, 0);
        deal(address(token), address(viewFacet), 60 ether);

        (uint256 totalDeposits, uint256 totalBorrowed, uint256 availableLiquidity, uint256 utilizationBps,) =
            viewFacet.getPoolUtilization(PID);

        assertEq(totalDeposits, 100 ether);
        assertEq(availableLiquidity, 60 ether);
        assertEq(totalBorrowed, 40 ether);
        assertEq(utilizationBps, 4000);
    }

    function test_getPoolUtilization_whenBalanceExceedsDepositsBorrowedIsZero() public {
        viewFacet.setTotals(PID, 100 ether, 0);
        deal(address(token), address(viewFacet), 150 ether);

        (, uint256 totalBorrowed,, uint256 utilizationBps,) = viewFacet.getPoolUtilization(PID);
        assertEq(totalBorrowed, 0);
        assertEq(utilizationBps, 0);
    }

    function test_getPoolUtilization_capacityRemaining_isMaxUnlessCapped() public {
        viewFacet.setTotals(PID, 0, 0);
        viewFacet.setConfig(PID, false, 0, 0);
        (,,,, uint256 capRemaining) = viewFacet.getPoolUtilization(PID);
        assertEq(capRemaining, type(uint256).max);

        viewFacet.setConfig(PID, true, 123 ether, 0);
        (,,,, capRemaining) = viewFacet.getPoolUtilization(PID);
        assertEq(capRemaining, 123 ether);
    }

    function test_canDeposit_rejectsZeroAmount() public {
        viewFacet.setConfig(PID, false, 0, 0);
        (bool allowed, uint256 maxAllowed, string memory reason) = viewFacet.canDeposit(PID, POSITION_KEY, 0);
        assertFalse(allowed);
        assertEq(maxAllowed, 0);
        assertEq(reason, "Amount cannot be zero");
    }

    function test_canDeposit_enforcesMaxUserCountForNewUser() public {
        viewFacet.setConfig(PID, false, 0, 1);
        viewFacet.setTotals(PID, 0, 1);

        (bool allowed,, string memory reason) = viewFacet.canDeposit(PID, POSITION_KEY, 1 ether);
        assertFalse(allowed);
        assertEq(reason, "Pool at max user capacity");

        // Existing user should not be gated by maxUserCount.
        viewFacet.setUserPrincipal(PID, POSITION_KEY, 1 ether);
        (allowed,, reason) = viewFacet.canDeposit(PID, POSITION_KEY, 1 ether);
        assertTrue(allowed);
        assertEq(reason, "");
    }

    function test_canDeposit_cappedPool_reasonsAndMaxAllowed() public {
        viewFacet.setConfig(PID, true, 10 ether, 0);

        // user at cap
        viewFacet.setUserPrincipal(PID, POSITION_KEY, 10 ether);
        (bool allowed, uint256 maxAllowed, string memory reason) = viewFacet.canDeposit(PID, POSITION_KEY, 1 ether);
        assertFalse(allowed);
        assertEq(maxAllowed, 0);
        assertEq(reason, "User at deposit cap");

        // user below cap
        viewFacet.setUserPrincipal(PID, POSITION_KEY, 6 ether);
        (allowed, maxAllowed, reason) = viewFacet.canDeposit(PID, POSITION_KEY, 10 ether);
        assertFalse(allowed);
        assertEq(maxAllowed, 4 ether);
        assertEq(reason, "Exceeds user deposit cap");

        (allowed, maxAllowed, reason) = viewFacet.canDeposit(PID, POSITION_KEY, 4 ether);
        assertTrue(allowed);
        assertEq(maxAllowed, 4 ether);
        assertEq(reason, "");
    }

    function test_getAvailableLiquidity_respectsReservedDeposits() public {
        viewFacet.setTotals(PID, 100 ether, 0);
        deal(address(token), address(viewFacet), 100 ether);

        (uint256 availableForBorrow, uint256 totalLiquidity, uint256 reservedForWithdrawals) =
            viewFacet.getAvailableLiquidity(PID);
        assertEq(totalLiquidity, 100 ether);
        assertEq(reservedForWithdrawals, 100 ether);
        assertEq(availableForBorrow, 0);

        // If contract holds more (e.g., fees), borrowing capacity exists.
        deal(address(token), address(viewFacet), 130 ether);
        (availableForBorrow, totalLiquidity, reservedForWithdrawals) = viewFacet.getAvailableLiquidity(PID);
        assertEq(totalLiquidity, 130 ether);
        assertEq(reservedForWithdrawals, 100 ether);
        assertEq(availableForBorrow, 30 ether);
    }

    /// @dev Deterministic snapshot for gas reporting.
    function test_gas_UtilizationAndDepositChecks() public {
        viewFacet.setTotals(PID, 500 ether, 10);
        viewFacet.setConfig(PID, true, 100 ether, 100);
        viewFacet.setUserPrincipal(PID, POSITION_KEY, 20 ether);
        deal(address(token), address(viewFacet), 400 ether);

        viewFacet.getPoolUtilization(PID);
        viewFacet.canDeposit(PID, POSITION_KEY, 30 ether);
    }

    function testFuzz_utilizationWithinBoundsWhenDepositsPositive(uint256 deposits, uint256 balance) public {
        deposits = bound(deposits, 1, 1_000_000 ether);
        balance = bound(balance, 0, 1_000_000 ether);

        viewFacet.setTotals(PID, deposits, 0);
        deal(address(token), address(viewFacet), balance);

        (,, uint256 availableLiquidity, uint256 utilizationBps,) = viewFacet.getPoolUtilization(PID);
        assertEq(availableLiquidity, balance);
        assertLe(utilizationBps, 10_000);
    }

    function testFuzz_getPoolUtilization_matchesFormula(uint256 deposits, uint256 balance) public {
        deposits = bound(deposits, 0, 1_000_000 ether);
        balance = bound(balance, 0, 1_000_000 ether);

        viewFacet.setTotals(PID, deposits, 0);
        deal(address(token), address(viewFacet), balance);

        (uint256 totalDeposits, uint256 totalBorrowed,, uint256 utilizationBps,) = viewFacet.getPoolUtilization(PID);
        assertEq(totalDeposits, deposits);

        uint256 expectedBorrowed = balance > deposits ? 0 : deposits - balance;
        assertEq(totalBorrowed, expectedBorrowed);

        uint256 expectedUtil = 0;
        if (deposits > 0) {
            expectedUtil = (expectedBorrowed * 10_000) / deposits;
        }
        assertEq(utilizationBps, expectedUtil);
        assertLe(utilizationBps, 10_000);
    }

    function testFuzz_canDeposit_cappedPool_maxAllowedConsistent(uint256 cap, uint256 principal, uint256 amount) public {
        cap = bound(cap, 1, 1_000_000 ether);
        principal = bound(principal, 0, cap + 10 ether);
        amount = bound(amount, 0, 1_000_000 ether);

        viewFacet.setConfig(PID, true, cap, 0);
        viewFacet.setTotals(PID, 0, 0);
        viewFacet.setUserPrincipal(PID, POSITION_KEY, principal);

        (bool allowed, uint256 maxAllowed, string memory reason) = viewFacet.canDeposit(PID, POSITION_KEY, amount);

        if (amount == 0) {
            assertFalse(allowed);
            assertEq(maxAllowed, 0);
            assertEq(reason, "Amount cannot be zero");
            return;
        }

        if (principal >= cap) {
            assertFalse(allowed);
            assertEq(maxAllowed, 0);
            assertEq(reason, "User at deposit cap");
            return;
        }

        uint256 expectedMax = cap - principal;
        assertEq(maxAllowed, expectedMax);

        if (amount > expectedMax) {
            assertFalse(allowed);
            assertEq(reason, "Exceeds user deposit cap");
        } else {
            assertTrue(allowed);
            assertEq(reason, "");
        }
    }
}
