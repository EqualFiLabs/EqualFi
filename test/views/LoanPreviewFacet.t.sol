// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LoanPreviewFacet} from "../../src/views/LoanPreviewFacet.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {Types} from "../../src/libraries/Types.sol";

contract LoanPreviewFacetHarness is LoanPreviewFacet {
    function initPool(uint256 pid, address underlying, uint16 rollingApy) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.poolConfig.rollingApyBps = rollingApy;
    }

    function addFixedConfig(uint256 pid, uint40 durationSecs, uint16 apyBps) external {
        LibAppStorage.s().pools[pid].poolConfig.fixedTermConfigs.push(
            Types.FixedTermConfig({durationSecs: durationSecs, apyBps: apyBps})
        );
    }

    function seedFixedLoan(uint256 pid, uint256 loanId, bytes32 borrower, uint256 principalRemaining, bool closed, uint40 expiry)
        external
    {
        Types.FixedTermLoan storage loan = LibAppStorage.s().pools[pid].fixedTermLoans[loanId];
        loan.borrower = borrower;
        loan.principalRemaining = principalRemaining;
        loan.closed = closed;
        loan.expiry = expiry;
    }

    function seedRollingLoan(uint256 pid, bytes32 borrower, uint256 principalRemaining, uint16 apyBps, uint40 lastPayment)
        external
    {
        Types.RollingCreditLoan storage loan = LibAppStorage.s().pools[pid].rollingLoans[borrower];
        loan.principalRemaining = principalRemaining;
        loan.apyBps = apyBps;
        loan.lastPaymentTimestamp = lastPayment;
    }
}

contract LoanPreviewFacetTest is Test {
    LoanPreviewFacetHarness internal viewFacet;

    uint256 internal constant PID = 1;
    bytes32 internal constant BORROWER = keccak256("BORROWER");

    function setUp() public {
        viewFacet = new LoanPreviewFacetHarness();
        viewFacet.initPool(PID, address(0xCAFE), 900);
    }

    function test_previewFixedLoanCosts_revertsOnInvalidTerm() public {
        vm.expectRevert(bytes("Invalid term ID"));
        viewFacet.previewFixedLoanCosts(PID, 100 ether, 0);
    }

    function test_previewFixedLoanCosts_revertsOnUnconfiguredTerm() public {
        viewFacet.addFixedConfig(PID, 0, 1000);
        vm.expectRevert(bytes("Term not configured"));
        viewFacet.previewFixedLoanCosts(PID, 100 ether, 0);
    }

    function test_previewFixedLoanCosts_matchesExpectedInterestMath() public {
        viewFacet.addFixedConfig(PID, 30 days, 1000);
        (uint256 totalInterest, uint256 minFee, uint256 totalCost, uint256 netReceived) =
            viewFacet.previewFixedLoanCosts(PID, 100 ether, 0);

        uint256 principal = 100 ether;
        uint256 expected = (principal * 1000 * 30 days) / (365 days * 10_000);
        assertEq(totalInterest, expected);
        assertEq(minFee, 0);
        assertEq(totalCost, expected);
        assertEq(netReceived, 100 ether);
    }

    function test_previewRollingLoanCosts_switchesApyByCollateralType() public {
        uint256 amount = 100 ether;

        (uint256 monthlyDep, uint256 annualDep) = viewFacet.previewRollingLoanCosts(PID, amount, true);
        uint256 expectedAnnualDep = (amount * 900) / 10_000;
        uint256 expectedMonthlyDep = (amount * 900 * 30 days) / (10_000 * 365 days);
        assertEq(annualDep, expectedAnnualDep);
        assertEq(monthlyDep, expectedMonthlyDep);

        vm.expectRevert(bytes("LoanPreview: external collateral not supported"));
        viewFacet.previewRollingLoanCosts(PID, amount, false);
    }

    /// @dev Deterministic snapshot for gas reporting.
    function test_gas_RollingPayoffPreview() public {
        uint40 lastPayment = uint40(block.timestamp);
        viewFacet.seedRollingLoan(PID, BORROWER, 200 ether, 1200, lastPayment);
        vm.warp(block.timestamp + 15 days);
        viewFacet.calculateRollingLoanPayoff(PID, BORROWER);
    }

    function test_calculateFixedLoanPayoff_revertsWhenMissingOrClosed() public {
        vm.expectRevert(bytes("Loan does not exist"));
        viewFacet.calculateFixedLoanPayoff(PID, 1);

        viewFacet.seedFixedLoan(PID, 1, BORROWER, 10 ether, true, uint40(block.timestamp + 1 days));
        vm.expectRevert(bytes("Loan already closed"));
        viewFacet.calculateFixedLoanPayoff(PID, 1);
    }

    function test_calculateFixedLoanPayoff_returnsPrincipalOnly_andExpiredFlag() public {
        uint40 expiry = uint40(block.timestamp + 1 days);
        viewFacet.seedFixedLoan(PID, 2, BORROWER, 10 ether, false, expiry);

        (uint256 totalDue, uint256 principalRemaining, uint256 feesAccrued, LoanPreviewFacet.PayoffBreakdown memory b) =
            viewFacet.calculateFixedLoanPayoff(PID, 2);
        assertEq(totalDue, 10 ether);
        assertEq(principalRemaining, 10 ether);
        assertEq(feesAccrued, 0);
        assertEq(b.principal, 10 ether);
        assertEq(b.accruedInterest, 0);
        assertEq(b.minFee, 0);
        assertEq(b.totalFees, 0);
        assertFalse(b.isExpired);

        vm.warp(expiry + 1);
        (,,, b) = viewFacet.calculateFixedLoanPayoff(PID, 2);
        assertTrue(b.isExpired);
    }

    function test_calculateRollingLoanPayoff_accruesInterestFromLastPayment() public {
        vm.warp(20 days);
        uint40 lastPayment = uint40(block.timestamp - 10 days);
        viewFacet.seedRollingLoan(PID, BORROWER, 100 ether, 1000, lastPayment);

        (uint256 totalDue, uint256 principalRemaining, uint256 accruedInterest) =
            viewFacet.calculateRollingLoanPayoff(PID, BORROWER);

        uint256 principal = 100 ether;
        uint256 expected = (principal * 1000 * 10 days) / (10_000 * 365 days);
        assertEq(principalRemaining, 100 ether);
        assertEq(accruedInterest, expected);
        assertEq(totalDue, 100 ether + expected);
    }

    function test_previewFixedRepaymentImpact_capsPrincipalReduction() public {
        viewFacet.seedFixedLoan(PID, 3, BORROWER, 25 ether, false, uint40(block.timestamp + 30 days));

        (bool willClose, uint256 principalReduction, uint256 feesPaid, uint256 newPrincipal, uint256 additionalNeeded) =
            viewFacet.previewFixedRepaymentImpact(PID, 3, 100 ether);

        assertTrue(willClose);
        assertEq(principalReduction, 25 ether);
        assertEq(feesPaid, 0);
        assertEq(newPrincipal, 0);
        assertEq(additionalNeeded, 0);
    }

    function test_previewFixedRepaymentImpact_additionalNeeded_matchesImplementation() public {
        viewFacet.seedFixedLoan(PID, 4, BORROWER, 100 ether, false, uint40(block.timestamp + 30 days));

        (bool willClose,, uint256 feesPaid, uint256 newPrincipal, uint256 additionalNeeded) =
            viewFacet.previewFixedRepaymentImpact(PID, 4, 40 ether);

        assertFalse(willClose);
        assertEq(feesPaid, 0);
        assertEq(newPrincipal, 60 ether);
        assertEq(additionalNeeded, 20 ether);
    }

    function testFuzz_calculateRollingLoanPayoff_isMonotonicInTime(
        uint256 principalRemaining,
        uint16 apyBps,
        uint256 elapsed1,
        uint256 elapsed2
    ) public {
        principalRemaining = bound(principalRemaining, 0, 1_000_000 ether);
        // keep within a reasonable range; the function supports any uint16, this just avoids huge numbers
        apyBps = uint16(bound(uint256(apyBps), 0, 20_000));
        elapsed1 = bound(elapsed1, 0, 365 days);
        elapsed2 = bound(elapsed2, elapsed1, 365 days);

        uint40 start = uint40(block.timestamp);
        viewFacet.seedRollingLoan(PID, BORROWER, principalRemaining, apyBps, start);

        vm.warp(uint256(start) + elapsed1);
        (uint256 total1,, uint256 interest1) = viewFacet.calculateRollingLoanPayoff(PID, BORROWER);

        vm.warp(uint256(start) + elapsed2);
        (uint256 total2,, uint256 interest2) = viewFacet.calculateRollingLoanPayoff(PID, BORROWER);

        assertGe(interest2, interest1, "interest should not decrease with time");
        assertGe(total2, total1, "total due should not decrease with time");
    }

    function testFuzz_calculateRollingLoanPayoff_freshLoanHasZeroInterest(uint256 principalRemaining, uint16 apyBps)
        public
    {
        principalRemaining = bound(principalRemaining, 0, 1_000_000 ether);
        apyBps = uint16(bound(uint256(apyBps), 0, 20_000));

        uint40 nowTs = uint40(block.timestamp);
        viewFacet.seedRollingLoan(PID, BORROWER, principalRemaining, apyBps, nowTs);

        (uint256 totalDue, uint256 principalOut, uint256 accruedInterest) =
            viewFacet.calculateRollingLoanPayoff(PID, BORROWER);
        assertEq(principalOut, principalRemaining);
        assertEq(accruedInterest, 0);
        assertEq(totalDue, principalRemaining);
    }
}
