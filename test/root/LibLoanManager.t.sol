// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibLoanManager} from "../../src/libraries/LibLoanManager.sol";

contract LoanManagerHarness {
    using LibLoanManager for LibLoanManager.LoanManager;

    LibLoanManager.LoanManager internal manager;

    function addLoan(bytes32 positionKey, uint256 loanId) external {
        manager.addLoan(positionKey, loanId);
    }

    function removeLoan(bytes32 positionKey, uint256 loanId) external {
        manager.removeLoan(positionKey, loanId);
    }

    function getLoans(bytes32 positionKey, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory loanIds, uint256 total)
    {
        return manager.getLoansByPosition(positionKey, offset, limit);
    }

    function getListMeta(bytes32 positionKey)
        external
        view
        returns (uint256 head, uint256 tail, uint256 length)
    {
        return manager.getListMeta(positionKey);
    }

    function getNode(bytes32 positionKey, uint256 loanId)
        external
        view
        returns (uint256 prev, uint256 next, bool exists)
    {
        return manager.getNode(positionKey, loanId);
    }
}

contract LibLoanManagerTest is Test {
    LoanManagerHarness public harness;
    bytes32 public constant POSITION = bytes32(uint256(0x1234));

    function setUp() public {
        harness = new LoanManagerHarness();
    }

    function test_AddLoansAndIteratePreservesOrder() public {
        harness.addLoan(POSITION, 1);
        harness.addLoan(POSITION, 2);
        harness.addLoan(POSITION, 3);

        (uint256 head, uint256 tail, uint256 length) = harness.getListMeta(POSITION);
        assertEq(head, 1, "Head should be first loan");
        assertEq(tail, 3, "Tail should be last loan");
        assertEq(length, 3, "Length should be 3");

        (uint256[] memory ids, uint256 total) = harness.getLoans(POSITION, 0, 10);
        assertEq(total, 3, "Total loans should be 3");
        assertEq(ids.length, 3, "Returned length should be 3");
        assertEq(ids[0], 1);
        assertEq(ids[1], 2);
        assertEq(ids[2], 3);
    }

    function test_RemoveHeadUpdatesLinks() public {
        harness.addLoan(POSITION, 1);
        harness.addLoan(POSITION, 2);
        harness.addLoan(POSITION, 3);

        harness.removeLoan(POSITION, 1);

        (uint256 head, uint256 tail, uint256 length) = harness.getListMeta(POSITION);
        assertEq(head, 2, "Head should move to second loan");
        assertEq(tail, 3, "Tail should remain last loan");
        assertEq(length, 2, "Length should be 2");

        (uint256[] memory ids,) = harness.getLoans(POSITION, 0, 10);
        assertEq(ids.length, 2);
        assertEq(ids[0], 2);
        assertEq(ids[1], 3);
    }

    function test_RemoveTailUpdatesLinks() public {
        harness.addLoan(POSITION, 1);
        harness.addLoan(POSITION, 2);
        harness.addLoan(POSITION, 3);

        harness.removeLoan(POSITION, 3);

        (uint256 head, uint256 tail, uint256 length) = harness.getListMeta(POSITION);
        assertEq(head, 1, "Head unchanged");
        assertEq(tail, 2, "Tail moves to second loan");
        assertEq(length, 2, "Length should be 2");

        (uint256[] memory ids,) = harness.getLoans(POSITION, 0, 10);
        assertEq(ids.length, 2);
        assertEq(ids[0], 1);
        assertEq(ids[1], 2);
    }

    function test_RemoveMiddleUpdatesLinks() public {
        harness.addLoan(POSITION, 1);
        harness.addLoan(POSITION, 2);
        harness.addLoan(POSITION, 3);

        harness.removeLoan(POSITION, 2);

        (uint256 head, uint256 tail, uint256 length) = harness.getListMeta(POSITION);
        assertEq(head, 1);
        assertEq(tail, 3);
        assertEq(length, 2);

        (uint256[] memory ids,) = harness.getLoans(POSITION, 0, 10);
        assertEq(ids.length, 2);
        assertEq(ids[0], 1);
        assertEq(ids[1], 3);

        // Check node links
        (uint256 prev,, bool exists) = harness.getNode(POSITION, 3);
        assertTrue(exists, "Tail node should exist");
        assertEq(prev, 1, "Tail prev should be head");
    }

    function test_GetLoansByPositionPagination() public {
        for (uint256 i = 1; i <= 5; i++) {
            harness.addLoan(POSITION, i);
        }

        (uint256[] memory page, uint256 total) = harness.getLoans(POSITION, 2, 2);
        assertEq(total, 5, "Total should be 5");
        assertEq(page.length, 2, "Page size should be 2");
        assertEq(page[0], 3);
        assertEq(page[1], 4);

        // Offset beyond end
        (uint256[] memory emptyPage, uint256 total2) = harness.getLoans(POSITION, 10, 2);
        assertEq(total2, 5);
        assertEq(emptyPage.length, 0, "No loans beyond end");
    }

    function test_AddDuplicateLoanReverts() public {
        harness.addLoan(POSITION, 1);
        vm.expectRevert("LoanManager: exists");
        harness.addLoan(POSITION, 1);
    }

    function test_RemoveMissingLoanReverts() public {
        vm.expectRevert("LoanManager: missing");
        harness.removeLoan(POSITION, 42);
    }

    /// @notice Simple gas exercise for adding and removing many loans
    function test_Gas_AddAndRemoveManyLoans() public {
        uint256 count = 50;
        for (uint256 i = 1; i <= count; i++) {
            harness.addLoan(POSITION, i);
        }
        for (uint256 i = 1; i <= count; i++) {
            harness.removeLoan(POSITION, i);
        }
    }
}
