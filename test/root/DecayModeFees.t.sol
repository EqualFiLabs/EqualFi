// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// DEPRECATED: This test file tests the old decay mode functionality which is being removed
// in favor of the monthly payment model. This file will be removed in task 6.
// Temporarily commented out to allow compilation.

/*
import {Test} from "forge-std/Test.sol";
import {RollingCreditFacet} from "../../src/equalcredit/RollingCreditFacet.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";
import {Types} from "../../src/libraries/Types.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

/// @notice Harness for testing decay mode fee accrual
contract DecayModeFeeHarness is RollingCreditFacet {
    function initPool(uint256 pid, address underlying) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.poolConfig.depositorLTVBps = 8000;
        p.minPaymentBpsFee = 500; // 5% min fee
        p.minPaymentBpsPrincipal = 1000; // 10% min principal
        p.minPaymentIntervalSecs = 30 days;
        p.decayRatePpm = 100_000; // 10% daily decay
        p.liquidationRunwayDays = 30;
    }

    function setTreasury(address treasury) external {
        LibAppStorage.s().treasury = treasury;
    }

    function setTreasuryShare(uint16 bps) external {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        store.treasuryShareBps = bps;
        store.treasuryShareConfigured = true;
    }

    function seedPrincipal(uint256 pid, address user, uint256 principal) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.userPrincipal[user] = principal;
        p.totalDeposits += principal;
        p.userFeeIndex[user] = p.feeIndex;
    }

    function getFeeIndex(uint256 pid) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].feeIndex;
    }

    function getUserAccruedYield(uint256 pid, address user) external view returns (uint256) {
        return LibAppStorage.s().pools[pid].userAccruedYield[user];
    }

    function getPendingYield(uint256 pid, address user) external view returns (uint256) {
        return LibFeeIndex.pendingYield(pid, user);
    }

    function getLoanState(uint256 pid, address borrower)
        external
        view
        returns (uint256 principal, uint256 principalRemaining, uint256 openedAt, uint256 lastAccrualTs, bool inDecay)
    {
        Types.RollingCreditLoan storage loan = LibAppStorage.s().pools[pid].rollingLoans[borrower];
        return (loan.principal, loan.principalRemaining, loan.openedAt, loan.lastAccrualTs, loan.inDecay);
    }
}

/// @notice Tests for decay mode fee accrual to feeIndex
contract DecayModeFeesTest is Test {
    DecayModeFeeHarness internal facet;
    MockERC20 internal token;

    uint256 internal constant PID = 1;
    address internal constant DEPOSITOR = address(0xA);
    address internal constant BORROWER = address(0xB);
    address internal constant TREASURY = address(0xFEE);

    function setUp() public {
        facet = new DecayModeFeeHarness();
        token = new MockERC20("Mock Token", "MOCK", 18, 0);

        facet.initPool(PID, address(token));
        facet.setTreasury(TREASURY);
        facet.setTreasuryShare(2000); // 20%

        // Mint tokens
        token.mint(DEPOSITOR, 10_000 ether);
        token.mint(BORROWER, 10_000 ether);
        token.mint(address(facet), 10_000 ether);

        vm.warp(365 days);
    }

    /// @notice Test minimum payment in decay mode accrues fees to feeIndex
    function testDecayModeMinimumPaymentAccruesFees() public {
        // Setup: Depositor provides liquidity
        facet.seedPrincipal(PID, DEPOSITOR, 1000 ether);

        // Borrower takes loan
        vm.startPrank(BORROWER);
        token.approve(address(facet), type(uint256).max);
        facet.seedPrincipal(PID, BORROWER, 500 ether);
        facet.openRolling(PID, 400 ether, true, 0);
        vm.stopPrank();

        // Miss payment deadline -> enter decay mode
        vm.warp(block.timestamp + 31 days);

        // Trigger decay
        facet.checkDecay(PID, BORROWER);

        (,,,, bool inDecay) = facet.getLoanState(PID, BORROWER);
        assertTrue(inDecay);

        uint256 feeIndexBefore = facet.getFeeIndex(PID);

        // Make minimum payment (10% principal + 5% fee)
        uint256 minPrincipal = (400 ether * 1000) / 10_000; // 10%
        uint256 minFee = (400 ether * 500) / 10_000; // 5%

        vm.startPrank(BORROWER);
        facet.repayRolling(PID, minPrincipal + minFee);
        vm.stopPrank();

        // Fee should accrue to feeIndex
        uint256 feeIndexAfter = facet.getFeeIndex(PID);
        assertGt(feeIndexAfter, feeIndexBefore);

        // Treasury should receive 20% of fee
        uint256 expectedTreasury = (minFee * 2000) / 10_000;
        assertApproxEqAbs(token.balanceOf(TREASURY), expectedTreasury, 0.01 ether);
    }

    /// @notice Test depositor receives yield from decay mode payments
    function testDepositorReceivesYieldFromDecayPayments() public {
        // Two depositors
        facet.seedPrincipal(PID, DEPOSITOR, 1000 ether);
        facet.seedPrincipal(PID, address(0xC), 1000 ether);

        // Borrower takes loan and enters decay
        vm.startPrank(BORROWER);
        token.approve(address(facet), type(uint256).max);
        facet.seedPrincipal(PID, BORROWER, 500 ether);
        facet.openRolling(PID, 400 ether, true, 0);
        vm.stopPrank();

        vm.warp(block.timestamp + 31 days);
        facet.checkDecay(PID, BORROWER);

        // Make minimum payment
        uint256 minPrincipal = (400 ether * 1000) / 10_000;
        uint256 minFee = (400 ether * 500) / 10_000;

        vm.startPrank(BORROWER);
        facet.repayRolling(PID, minPrincipal + minFee);
        vm.stopPrank();

        // Depositor should have pending yield
        uint256 yieldDepositor = facet.getPendingYield(PID, DEPOSITOR);
        assertGt(yieldDepositor, 0);

        // Should be proportional based on totalDeposits (1000 + 1000 + 500 = 2500)
        // Fee to index = 80% of 20 ether = 16 ether
        // Depositor has 1000/2500 = 40% of deposits
        uint256 feeToIndex = (minFee * 8000) / 10_000; // 80% to index
        uint256 expectedYield = (feeToIndex * 1000 ether) / 2500 ether; // Proportional to deposits
        assertApproxEqRel(yieldDepositor, expectedYield, 0.01e18);
    }

    /// @notice Test multiple decay payments accumulate fees
    function testMultipleDecayPaymentsAccumulateFees() public {
        facet.seedPrincipal(PID, DEPOSITOR, 1000 ether);

        // Borrower takes loan and enters decay
        vm.startPrank(BORROWER);
        token.approve(address(facet), type(uint256).max);
        facet.seedPrincipal(PID, BORROWER, 500 ether);
        facet.openRolling(PID, 400 ether, true, 0);
        vm.stopPrank();

        vm.warp(block.timestamp + 31 days);
        facet.checkDecay(PID, BORROWER);

        uint256 feeIndexStart = facet.getFeeIndex(PID);

        // Make 3 minimum payments
        for (uint256 i = 0; i < 3; i++) {
            (, uint256 remaining,,,) = facet.getLoanState(PID, BORROWER);
            uint256 minPrincipal = (remaining * 1000) / 10_000;
            uint256 minFee = (remaining * 500) / 10_000;

            vm.startPrank(BORROWER);
            facet.repayRolling(PID, minPrincipal + minFee);
            vm.stopPrank();

            // Advance time for next payment
            if (i < 2) {
                vm.warp(block.timestamp + 30 days);
            }
        }

        // Fee index should have increased from all payments
        uint256 feeIndexEnd = facet.getFeeIndex(PID);
        assertGt(feeIndexEnd, feeIndexStart);

        // Depositor should have accumulated yield
        uint256 depositorYield = facet.getPendingYield(PID, DEPOSITOR);
        assertGt(depositorYield, 0);
    }

    /// @notice Test decay mode exit after full repayment
    function testDecayModeExitAfterFullRepayment() public {
        facet.seedPrincipal(PID, DEPOSITOR, 1000 ether);

        vm.startPrank(BORROWER);
        token.approve(address(facet), type(uint256).max);
        facet.seedPrincipal(PID, BORROWER, 500 ether);
        facet.openRolling(PID, 400 ether, true, 0);
        vm.stopPrank();

        vm.warp(block.timestamp + 31 days);
        facet.checkDecay(PID, BORROWER);

        (,,,, bool inDecayBefore) = facet.getLoanState(PID, BORROWER);
        assertTrue(inDecayBefore);

        // Full repayment (principal + 5% fee)
        vm.startPrank(BORROWER);
        facet.repayRolling(PID, 420 ether);
        vm.stopPrank();

        // Should exit decay mode (loan closed)
        (uint256 principal,,,,) = facet.getLoanState(PID, BORROWER);
        assertEq(principal, 0);

        // Fee should have accrued
        assertGt(facet.getFeeIndex(PID), 0);
    }

    /// @notice Test decay reduces collateral but fees still accrue
    function testDecayReducesCollateralButFeesAccrue() public {
        facet.seedPrincipal(PID, DEPOSITOR, 1000 ether);

        vm.startPrank(BORROWER);
        token.approve(address(facet), type(uint256).max);
        facet.seedPrincipal(PID, BORROWER, 500 ether);
        facet.openRolling(PID, 400 ether, true, 0);
        vm.stopPrank();

        vm.warp(block.timestamp + 31 days);
        facet.checkDecay(PID, BORROWER);

        // Wait for decay to reduce collateral
        vm.warp(block.timestamp + 5 days);

        uint256 feeIndexBefore = facet.getFeeIndex(PID);

        // Make payment
        (, uint256 remaining,,,) = facet.getLoanState(PID, BORROWER);
        uint256 minPrincipal = (remaining * 1000) / 10_000;
        uint256 minFee = (remaining * 500) / 10_000;

        vm.startPrank(BORROWER);
        facet.repayRolling(PID, minPrincipal + minFee);
        vm.stopPrank();

        // Fees should still accrue despite decay
        assertGt(facet.getFeeIndex(PID), feeIndexBefore);
    }

    /// @notice Test minimum fee percentage applied correctly in decay
    function testMinimumFeePercentageInDecay() public {
        facet.seedPrincipal(PID, DEPOSITOR, 1000 ether);

        vm.startPrank(BORROWER);
        token.approve(address(facet), type(uint256).max);
        facet.seedPrincipal(PID, BORROWER, 500 ether);
        facet.openRolling(PID, 400 ether, true, 0);
        vm.stopPrank();

        vm.warp(block.timestamp + 31 days);
        facet.checkDecay(PID, BORROWER);

        // Min fee is 5% of remaining principal
        (, uint256 remaining,,,) = facet.getLoanState(PID, BORROWER);
        uint256 expectedMinFee = (remaining * 500) / 10_000;

        uint256 feeIndexBefore = facet.getFeeIndex(PID);

        // Make payment with exact min fee
        uint256 minPrincipal = (remaining * 1000) / 10_000;
        vm.startPrank(BORROWER);
        facet.repayRolling(PID, minPrincipal + expectedMinFee);
        vm.stopPrank();

        // Fee index should increase by (80% of expectedMinFee) / totalDeposits
        // totalDeposits = 1000 (DEPOSITOR) + 500 (BORROWER) = 1500 ether
        uint256 feeToIndex = (expectedMinFee * 8000) / 10_000;
        uint256 expectedDelta = (feeToIndex * 1e18) / 1500 ether;

        uint256 feeIndexAfter = facet.getFeeIndex(PID);
        assertApproxEqAbs(feeIndexAfter - feeIndexBefore, expectedDelta, 1e15);
    }

    /// @notice Test decay mode with external collateral
    function testDecayModeWithExternalCollateral() public {
        facet.seedPrincipal(PID, DEPOSITOR, 1000 ether);

        // Borrower uses external collateral
        vm.startPrank(BORROWER);
        token.approve(address(facet), type(uint256).max);
        facet.openRolling(PID, 400 ether, false, 500 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 31 days);
        facet.checkDecay(PID, BORROWER);

        uint256 feeIndexBefore = facet.getFeeIndex(PID);

        // Make minimum payment
        uint256 minPrincipal = (400 ether * 1000) / 10_000;
        uint256 minFee = (400 ether * 500) / 10_000;

        vm.startPrank(BORROWER);
        facet.repayRolling(PID, minPrincipal + minFee);
        vm.stopPrank();

        // Fees should still accrue to feeIndex
        assertGt(facet.getFeeIndex(PID), feeIndexBefore);

        // Depositor should receive yield
        assertGt(facet.getPendingYield(PID, DEPOSITOR), 0);
    }

    /// @notice Test that insufficient payment in decay mode reverts
    function testInsufficientPaymentInDecayReverts() public {
        facet.seedPrincipal(PID, DEPOSITOR, 1000 ether);

        vm.startPrank(BORROWER);
        token.approve(address(facet), type(uint256).max);
        facet.seedPrincipal(PID, BORROWER, 500 ether);
        facet.openRolling(PID, 400 ether, true, 0);
        vm.stopPrank();

        vm.warp(block.timestamp + 31 days);
        facet.checkDecay(PID, BORROWER);

        // Try to pay less than minimum
        uint256 minPrincipal = (400 ether * 1000) / 10_000;
        uint256 minFee = (400 ether * 500) / 10_000;
        uint256 insufficient = (minPrincipal + minFee) / 2;

        vm.startPrank(BORROWER);
        vm.expectRevert();
        facet.repayRolling(PID, insufficient);
        vm.stopPrank();
    }

    /// @notice Fuzz test: Decay mode payments with random amounts
    function testFuzz_DecayModePaymentsWithRandomAmounts(uint256 principal) public {
        principal = bound(principal, 100 ether, 1000 ether);

        facet.seedPrincipal(PID, DEPOSITOR, 2000 ether);

        vm.startPrank(BORROWER);
        token.approve(address(facet), type(uint256).max);
        facet.seedPrincipal(PID, BORROWER, principal * 2);
        facet.openRolling(PID, principal, true, 0);
        vm.stopPrank();

        vm.warp(block.timestamp + 31 days);
        facet.checkDecay(PID, BORROWER);

        uint256 minPrincipal = (principal * 1000) / 10_000;
        uint256 minFee = (principal * 500) / 10_000;

        uint256 feeIndexBefore = facet.getFeeIndex(PID);

        vm.startPrank(BORROWER);
        facet.repayRolling(PID, minPrincipal + minFee);
        vm.stopPrank();

        // Fee index should always increase
        assertGt(facet.getFeeIndex(PID), feeIndexBefore);

        // Depositor should have yield
        assertGt(facet.getPendingYield(PID, DEPOSITOR), 0);
    }
}
*/
