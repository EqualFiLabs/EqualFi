// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LoanViewFacet} from "../../src/views/LoanViewFacet.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {Types} from "../../src/libraries/Types.sol";

contract LoanViewFacetHarness is LoanViewFacet {
    function initPool(uint256 pid, address underlying, uint16 depositorLtvBps) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        p.underlying = underlying;
        p.initialized = true;
        p.poolConfig.depositorLTVBps = depositorLtvBps;
    }

    function setUserPrincipal(uint256 pid, bytes32 user, uint256 principal) external {
        LibAppStorage.s().pools[pid].userPrincipal[user] = principal;
    }

    function seedRollingLoan(uint256 pid, bytes32 borrower, uint256 principalRemaining) external {
        Types.RollingCreditLoan storage loan = LibAppStorage.s().pools[pid].rollingLoans[borrower];
        loan.principalRemaining = principalRemaining;
        loan.active = principalRemaining > 0;
    }

    function seedFixedLoan(uint256 pid, uint256 loanId, bytes32 borrower, uint256 principalRemaining, bool closed)
        external
    {
        Types.FixedTermLoan storage loan = LibAppStorage.s().pools[pid].fixedTermLoans[loanId];
        loan.borrower = borrower;
        loan.principalRemaining = principalRemaining;
        loan.closed = closed;
    }

    function seedUserFixedLoanIds(uint256 pid, bytes32 borrower, uint256[] calldata loanIds) external {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        delete p.userFixedLoanIds[borrower];
        for (uint256 i; i < loanIds.length; i++) {
            p.userFixedLoanIds[borrower].push(loanIds[i]);
        }
    }

    function getAllUserFixedLoanIds(uint256 pid, bytes32 borrower) external view returns (uint256[] memory) {
        return LibAppStorage.s().pools[pid].userFixedLoanIds[borrower];
    }
}

contract LoanViewFacetTest is Test {
    LoanViewFacetHarness internal viewFacet;

    uint256 internal constant PID = 1;
    bytes32 internal constant BORROWER = keccak256("BORROWER");

    function setUp() public {
        viewFacet = new LoanViewFacetHarness();
    }

    function test_previewBorrowRolling_usesDepositorLtv() public {
        viewFacet.initPool(PID, address(0xCAFE), 8000);
        viewFacet.setUserPrincipal(PID, BORROWER, 100 ether);

        uint256 maxBorrow = viewFacet.previewBorrowRolling(PID, BORROWER);
        assertEq(maxBorrow, 80 ether);
    }

    function test_getUserFixedLoanIdsPaginated_slicesCorrectly() public {
        viewFacet.initPool(PID, address(0xCAFE), 8000);

        uint256[] memory ids = new uint256[](4);
        ids[0] = 11;
        ids[1] = 22;
        ids[2] = 33;
        ids[3] = 44;
        viewFacet.seedUserFixedLoanIds(PID, BORROWER, ids);

        (uint256[] memory page, uint256 total) = viewFacet.getUserFixedLoanIdsPaginated(PID, BORROWER, 1, 2);
        assertEq(total, 4);
        assertEq(page.length, 2);
        assertEq(page[0], 22);
        assertEq(page[1], 33);
    }

    function test_getUserFixedLoanIdsPaginated_offsetPastEndReturnsEmpty() public {
        viewFacet.initPool(PID, address(0xCAFE), 8000);

        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        viewFacet.seedUserFixedLoanIds(PID, BORROWER, ids);

        (uint256[] memory page, uint256 total) = viewFacet.getUserFixedLoanIdsPaginated(PID, BORROWER, 2, 10);
        assertEq(total, 2);
        assertEq(page.length, 0);
    }

    function testFuzz_getUserFixedLoanIdsPaginated_matchesSlice(uint256 offset, uint256 limit) public {
        viewFacet.initPool(PID, address(0xCAFE), 8000);

        uint256[] memory ids = new uint256[](5);
        for (uint256 i; i < ids.length; i++) ids[i] = 100 + i;
        viewFacet.seedUserFixedLoanIds(PID, BORROWER, ids);

        offset = bound(offset, 0, 10);
        limit = bound(limit, 0, 10);

        (uint256[] memory page, uint256 total) = viewFacet.getUserFixedLoanIdsPaginated(PID, BORROWER, offset, limit);
        assertEq(total, ids.length);

        if (offset >= ids.length) {
            assertEq(page.length, 0);
            return;
        }

        uint256 remaining = ids.length - offset;
        uint256 expectedLen = limit > remaining ? remaining : limit;
        assertEq(page.length, expectedLen);
        for (uint256 i; i < page.length; i++) {
            assertEq(page[i], ids[offset + i]);
        }
    }

    function test_getRollingLoan_and_getFixedLoan_roundTripSeededState() public {
        viewFacet.initPool(PID, address(0xCAFE), 8000);
        viewFacet.seedRollingLoan(PID, BORROWER, 12 ether);
        viewFacet.seedFixedLoan(PID, 7, BORROWER, 34 ether, false);

        Types.RollingCreditLoan memory rolling = viewFacet.getRollingLoan(PID, BORROWER);
        assertEq(rolling.principalRemaining, 12 ether);
        assertTrue(rolling.active);

        Types.FixedTermLoan memory fixedLoan = viewFacet.getFixedLoan(PID, 7);
        assertEq(fixedLoan.borrower, BORROWER);
        assertEq(fixedLoan.principalRemaining, 34 ether);
        assertFalse(fixedLoan.closed);
    }

    function test_revertsOnUninitializedPool() public {
        vm.expectRevert(bytes("View: uninit pool"));
        viewFacet.previewBorrowRolling(PID, BORROWER);
    }
}
