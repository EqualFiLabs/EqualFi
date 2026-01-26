// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {EnhancedLoanViewFacet} from "../../src/views/EnhancedLoanViewFacet.sol";
import {LoanViewFacet} from "../../src/views/LoanViewFacet.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {Types} from "../../src/libraries/Types.sol";

contract EnhancedLoanSummaryHarness is EnhancedLoanViewFacet {
    function initPool(uint256 pid, address underlying, uint16 depositorLtvBps) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.poolConfig.depositorLTVBps = depositorLtvBps;
    }

    function seedUserFixedLoanIds(uint256 pid, bytes32 borrower, uint256[] calldata loanIds) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        delete p.userFixedLoanIds[borrower];
        for (uint256 i; i < loanIds.length; i++) {
            p.userFixedLoanIds[borrower].push(loanIds[i]);
        }
    }

    function seedFixedLoan(uint256 pid, uint256 loanId, bytes32 borrower, uint256 principalRemaining, bool closed)
        external
    {
        Types.FixedTermLoan storage loan = LibAppStorage.s().pools[pid].fixedTermLoans[loanId];
        loan.borrower = borrower;
        loan.principalRemaining = principalRemaining;
        loan.closed = closed;
    }

    function seedRolling(uint256 pid, bytes32 borrower, uint256 principalRemaining) external {
        Types.RollingCreditLoan storage loan = LibAppStorage.s().pools[pid].rollingLoans[borrower];
        loan.principalRemaining = principalRemaining;
        loan.active = principalRemaining > 0;
    }
}

contract LoanViewPaginationHarness is LoanViewFacet {
    function initPool(uint256 pid, address underlying) external {
        LibAppStorage.s().pools[pid].underlying = underlying;
        LibAppStorage.s().pools[pid].initialized = true;
    }

    function seedUserFixedLoanIds(uint256 pid, bytes32 borrower, uint256[] calldata loanIds) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        delete p.userFixedLoanIds[borrower];
        for (uint256 i; i < loanIds.length; i++) {
            p.userFixedLoanIds[borrower].push(loanIds[i]);
        }
    }
}

contract EnhancedLoanSummaryInvariantTest is Test {
    EnhancedLoanSummaryHarness internal facet;

    uint256 internal constant PID = 1;
    bytes32 internal constant BORROWER = keccak256("BORROWER");

    function setUp() public {
        facet = new EnhancedLoanSummaryHarness();
        facet.initPool(PID, address(0xCAFE), 8000);
    }

    function testFuzz_userLoanSummary_equalsSumActiveFixedPlusRolling(
        uint256[5] memory fixedRemaining,
        bool[5] memory fixedClosed,
        uint256 rollingRemaining
    ) public {
        uint256[] memory loanIds = new uint256[](5);
        for (uint256 i; i < 5; i++) {
            loanIds[i] = i + 1;
        }
        facet.seedUserFixedLoanIds(PID, BORROWER, loanIds);

        uint256 expectedFixedBorrowed;
        uint256 expectedFixedCount;
        for (uint256 i; i < 5; i++) {
            uint256 rem = bound(fixedRemaining[i], 0, 1_000_000 ether);
            bool closed = fixedClosed[i];
            facet.seedFixedLoan(PID, i + 1, BORROWER, rem, closed);
            if (!closed) {
                expectedFixedBorrowed += rem;
                expectedFixedCount += 1;
            }
        }

        rollingRemaining = bound(rollingRemaining, 0, 1_000_000 ether);
        facet.seedRolling(PID, BORROWER, rollingRemaining);

        (uint256 fixedBorrowed, uint256 fixedCount, uint256 rollingBorrowed, uint256 totalBorrowed) =
            facet.getUserLoanSummary(PID, BORROWER);

        assertEq(fixedBorrowed, expectedFixedBorrowed, "fixedBorrowed sum mismatch");
        assertEq(fixedCount, expectedFixedCount, "fixedCount mismatch");
        assertEq(rollingBorrowed, rollingRemaining, "rollingBorrowed mismatch");
        assertEq(totalBorrowed, expectedFixedBorrowed + rollingRemaining, "totalBorrowed mismatch");
    }

    /// @dev Gas-path snapshot of summary for a seeded user.
    function test_gas_UserLoanSummarySnapshot() public {
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        facet.seedUserFixedLoanIds(PID, BORROWER, ids);
        facet.seedFixedLoan(PID, 1, BORROWER, 40 ether, false);
        facet.seedFixedLoan(PID, 2, BORROWER, 20 ether, false);
        facet.seedRolling(PID, BORROWER, 10 ether);

        facet.getUserLoanSummary(PID, BORROWER);
    }
}

contract LoanViewPaginationInvariantTest is Test {
    LoanViewPaginationHarness internal facet;

    uint256 internal constant PID = 1;
    bytes32 internal constant BORROWER = keccak256("BORROWER");

    function setUp() public {
        facet = new LoanViewPaginationHarness();
        facet.initPool(PID, address(0xCAFE));
    }

    function testFuzz_getUserFixedLoanIdsPaginated_isPureWindow(uint256 seed, uint256 offset, uint256 limit) public {
        uint256 len = 10;
        uint256[] memory ids = new uint256[](len);
        seed = bound(seed, 1, type(uint256).max - len - 1);
        for (uint256 i; i < len; i++) {
            ids[i] = seed + i;
        }
        facet.seedUserFixedLoanIds(PID, BORROWER, ids);

        // Full array should match what we seeded.
        uint256[] memory full = facet.getUserFixedLoanIds(PID, BORROWER);
        assertEq(full.length, ids.length);
        for (uint256 i; i < len; i++) {
            assertEq(full[i], ids[i]);
        }

        // Paginated call must be an exact slice.
        offset = bound(offset, 0, 50);
        limit = bound(limit, 0, 50);
        (uint256[] memory page, uint256 total) = facet.getUserFixedLoanIdsPaginated(PID, BORROWER, offset, limit);
        assertEq(total, len);

        if (offset >= len) {
            assertEq(page.length, 0);
            return;
        }

        uint256 remaining = len - offset;
        uint256 expectedLen = limit > remaining ? remaining : limit;
        assertEq(page.length, expectedLen);
        for (uint256 i; i < expectedLen; i++) {
            assertEq(page[i], ids[offset + i]);
        }
    }
}
