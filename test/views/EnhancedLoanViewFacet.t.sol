// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {EnhancedLoanViewFacet} from "../../src/views/EnhancedLoanViewFacet.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {Types} from "../../src/libraries/Types.sol";

contract EnhancedLoanViewFacetHarness is EnhancedLoanViewFacet {
    function initPool(uint256 pid, address underlying, uint16 depositorLtvBps) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.poolConfig.depositorLTVBps = depositorLtvBps;
    }

    function addFixedConfig(uint256 pid, uint40 durationSecs, uint16 apyBps) external {
        LibAppStorage.s().pools[pid].poolConfig.fixedTermConfigs.push(
            Types.FixedTermConfig({durationSecs: durationSecs, apyBps: apyBps})
        );
    }

    function setUserPrincipal(uint256 pid, bytes32 user, uint256 principal) external {
        LibAppStorage.s().pools[pid].userPrincipal[user] = principal;
    }

    function seedRollingLoan(uint256 pid, bytes32 borrower, uint256 principalRemaining) external {
        Types.RollingCreditLoan storage loan = LibAppStorage.s().pools[pid].rollingLoans[borrower];
        loan.principalRemaining = principalRemaining;
        loan.active = principalRemaining > 0;
    }

    function seedFixedLoan(
        uint256 pid,
        bytes32 borrower,
        uint256 loanId,
        uint256 principal,
        uint256 principalRemaining,
        bool closed,
        uint40 expiry
    ) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        Types.FixedTermLoan storage loan = p.fixedTermLoans[loanId];
        loan.borrower = borrower;
        loan.principal = principal;
        loan.principalRemaining = principalRemaining;
        loan.closed = closed;
        loan.expiry = expiry;
    }

    function seedUserFixedLoanIds(uint256 pid, bytes32 borrower, uint256[] calldata loanIds) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        delete p.userFixedLoanIds[borrower];
        for (uint256 i; i < loanIds.length; i++) {
            p.userFixedLoanIds[borrower].push(loanIds[i]);
        }
    }
}

contract EnhancedLoanViewFacetTest is Test {
    EnhancedLoanViewFacetHarness internal viewFacet;

    uint256 internal constant PID = 1;
    bytes32 internal constant BORROWER = keccak256("BORROWER");

    function setUp() public {
        viewFacet = new EnhancedLoanViewFacetHarness();
        viewFacet.initPool(PID, address(0xCAFE), 8000);
    }

    function test_getUserLoanSummary_countsOnlyActiveFixed_andAddsRolling() public {
        uint256[] memory ids = new uint256[](3);
        ids[0] = 1;
        ids[1] = 2;
        ids[2] = 3;
        viewFacet.seedUserFixedLoanIds(PID, BORROWER, ids);

        viewFacet.seedFixedLoan(PID, BORROWER, 1, 50 ether, 40 ether, false, uint40(block.timestamp + 30 days));
        viewFacet.seedFixedLoan(PID, BORROWER, 2, 20 ether, 0 ether, true, uint40(block.timestamp + 30 days));
        viewFacet.seedFixedLoan(PID, BORROWER, 3, 10 ether, 7 ether, false, uint40(block.timestamp + 30 days));

        viewFacet.seedRollingLoan(PID, BORROWER, 5 ether);

        (uint256 fixedBorrowed, uint256 fixedCount, uint256 rollingBorrowed, uint256 totalBorrowed) =
            viewFacet.getUserLoanSummary(PID, BORROWER);

        assertEq(fixedBorrowed, 47 ether);
        assertEq(fixedCount, 2);
        assertEq(rollingBorrowed, 5 ether);
        assertEq(totalBorrowed, 52 ether);
    }

    function test_getUserFixedLoansDetailed_returnsActiveOnly_andTotalsMatch() public {
        uint256[] memory ids = new uint256[](2);
        ids[0] = 11;
        ids[1] = 12;
        viewFacet.seedUserFixedLoanIds(PID, BORROWER, ids);

        viewFacet.seedFixedLoan(PID, BORROWER, 11, 100 ether, 60 ether, false, uint40(block.timestamp + 30 days));
        viewFacet.seedFixedLoan(PID, BORROWER, 12, 50 ether, 0 ether, true, uint40(block.timestamp + 30 days));

        (Types.FixedTermLoan[] memory loans, uint256 totalPrincipal, uint256 totalRemaining) =
            viewFacet.getUserFixedLoansDetailed(PID, BORROWER);

        assertEq(loans.length, 1);
        assertEq(loans[0].principal, 100 ether);
        assertEq(loans[0].principalRemaining, 60 ether);
        assertEq(totalPrincipal, 100 ether);
        assertEq(totalRemaining, 60 ether);
    }

    function test_getUserFixedLoansPaginated_returnsRawLoansAndTotalCount() public {
        uint256[] memory ids = new uint256[](3);
        ids[0] = 1;
        ids[1] = 2;
        ids[2] = 3;
        viewFacet.seedUserFixedLoanIds(PID, BORROWER, ids);

        viewFacet.seedFixedLoan(PID, BORROWER, 1, 10 ether, 10 ether, false, uint40(block.timestamp + 30 days));
        viewFacet.seedFixedLoan(PID, BORROWER, 2, 20 ether, 0 ether, true, uint40(block.timestamp + 30 days));
        viewFacet.seedFixedLoan(PID, BORROWER, 3, 30 ether, 25 ether, false, uint40(block.timestamp + 30 days));

        (Types.FixedTermLoan[] memory page, uint256 total) = viewFacet.getUserFixedLoansPaginated(PID, BORROWER, 1, 2);
        assertEq(total, 3);
        assertEq(page.length, 2);
        assertEq(page[0].principal, 20 ether);
        assertTrue(page[0].closed);
        assertEq(page[1].principal, 30 ether);
        assertFalse(page[1].closed);
    }

    function testFuzz_getUserFixedLoansPaginated_isWindow(uint256 offset, uint256 limit) public {
        uint256[] memory ids = new uint256[](7);
        for (uint256 i; i < ids.length; i++) {
            ids[i] = i + 1;
        }
        viewFacet.seedUserFixedLoanIds(PID, BORROWER, ids);

        for (uint256 i; i < ids.length; i++) {
            // principal and remaining are unique per loanId for easy comparison
            viewFacet.seedFixedLoan(
                PID,
                BORROWER,
                ids[i],
                (10 ether) + i,
                (5 ether) + i,
                (i % 2 == 0),
                uint40(block.timestamp + 30 days)
            );
        }

        offset = bound(offset, 0, 20);
        limit = bound(limit, 0, 20);

        (Types.FixedTermLoan[] memory page, uint256 total) = viewFacet.getUserFixedLoansPaginated(PID, BORROWER, offset, limit);
        assertEq(total, ids.length);

        if (offset >= ids.length) {
            assertEq(page.length, 0);
            return;
        }

        uint256 remaining = ids.length - offset;
        uint256 expectedLen = limit > remaining ? remaining : limit;
        assertEq(page.length, expectedLen);

        for (uint256 i; i < page.length; i++) {
            uint256 loanId = ids[offset + i];
            assertEq(page[i].principal, (10 ether) + (loanId - 1));
            assertEq(page[i].principalRemaining, (5 ether) + (loanId - 1));
        }
    }

    function test_getUserHealthMetrics_handlesZeroCollateralAndDebtCorrectly() public {
        viewFacet.setUserPrincipal(PID, BORROWER, 0);
        viewFacet.seedRollingLoan(PID, BORROWER, 0);

        (uint256 currentLtv, uint256 maxLtv, uint256 availableToBorrow, bool isHealthy,, uint256 totalDebt) =
            viewFacet.getUserHealthMetrics(PID, BORROWER);

        assertEq(currentLtv, 0);
        assertEq(maxLtv, 8000);
        assertEq(availableToBorrow, 0);
        assertTrue(isHealthy);
        assertEq(totalDebt, 0);

        viewFacet.seedRollingLoan(PID, BORROWER, 1 ether);
        (currentLtv,, availableToBorrow, isHealthy,, totalDebt) = viewFacet.getUserHealthMetrics(PID, BORROWER);

        assertEq(currentLtv, type(uint256).max);
        assertEq(availableToBorrow, 0);
        assertFalse(isHealthy);
        assertEq(totalDebt, 1 ether);
    }

    function test_getUserHealthMetrics_availableToBorrow_matchesApyZeroCase() public {
        viewFacet.addFixedConfig(PID, 30 days, 0);
        viewFacet.setUserPrincipal(PID, BORROWER, 100 ether);
        viewFacet.seedRollingLoan(PID, BORROWER, 20 ether);

        (uint256 currentLtv, uint256 maxLtv, uint256 availableToBorrow, bool isHealthy,, uint256 totalDebt) =
            viewFacet.getUserHealthMetrics(PID, BORROWER);

        assertEq(maxLtv, 8000);
        assertEq(totalDebt, 20 ether);
        uint256 netCollateral = 80 ether;
        assertEq(currentLtv, (20 ether * 10_000) / netCollateral);
        assertTrue(isHealthy);

        uint256 expectedMaxDebt = (netCollateral * 8000) / 10_000;
        uint256 expectedAvailable = expectedMaxDebt > 20 ether ? expectedMaxDebt - 20 ether : 0;
        assertEq(availableToBorrow, expectedAvailable);
    }

    function test_previewBorrowFixed_returnsZeroWhenNoFixedConfigs() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = 9;
        viewFacet.seedUserFixedLoanIds(PID, BORROWER, ids);
        viewFacet.seedFixedLoan(PID, BORROWER, 9, 10 ether, 7 ether, false, uint40(block.timestamp + 30 days));

        (uint256 maxBorrow, uint256 existingBorrowed) = viewFacet.previewBorrowFixed(PID, BORROWER);
        assertEq(existingBorrowed, 7 ether);
        assertEq(maxBorrow, 0);
    }

    function test_canOpenFixedLoan_validatesInputsAndLimits() public {
        viewFacet.setUserPrincipal(PID, BORROWER, 100 ether);
        viewFacet.addFixedConfig(PID, 30 days, 0);

        (bool ok, uint256 maxAllowed, string memory reason) = viewFacet.canOpenFixedLoan(PID, BORROWER, 0, 0);
        assertFalse(ok);
        assertEq(reason, "Principal cannot be zero");
        assertEq(maxAllowed, 80 ether);

        (ok, maxAllowed, reason) = viewFacet.canOpenFixedLoan(PID, BORROWER, 81 ether, 0);
        assertFalse(ok);
        assertEq(reason, "Exceeds LTV limit");
        assertEq(maxAllowed, 80 ether);

        (ok,, reason) = viewFacet.canOpenFixedLoan(PID, BORROWER, 80 ether, 0);
        assertTrue(ok);
        assertEq(reason, "");

        (ok,, reason) = viewFacet.canOpenFixedLoan(PID, BORROWER, 1 ether, 123);
        assertFalse(ok);
        assertEq(reason, "Invalid term ID");
    }

    function test_getFixedLoanAccrued_and_previewRepayFixed_matchUpfrontModel() public {
        uint256 loanId = 77;
        uint40 expiry = uint40(block.timestamp + 1 days);
        viewFacet.seedFixedLoan(PID, BORROWER, loanId, 100 ether, 25 ether, false, expiry);

        (uint256 accrued, uint256 minFee, uint256 totalDue, bool isExpired) = viewFacet.getFixedLoanAccrued(PID, loanId);
        assertEq(accrued, 0);
        assertEq(minFee, 0);
        assertEq(totalDue, 25 ether);
        assertFalse(isExpired);

        (uint256 principalPaid, uint256 feePaid, uint256 remaining, bool closed) = viewFacet.previewRepayFixed(PID, loanId, 100 ether);
        assertEq(feePaid, 0);
        assertEq(principalPaid, 25 ether);
        assertEq(remaining, 0);
        assertTrue(closed);

        vm.warp(expiry + 1);
        (,,, isExpired) = viewFacet.getFixedLoanAccrued(PID, loanId);
        assertTrue(isExpired);
    }
}
