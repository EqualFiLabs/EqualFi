// SPDX-License-Identifier: MIT
// forge-config: default.optimizer = true
pragma solidity ^0.8.20;

// Note: This test used to exercise the full Direct borrower index via the
// diamond + view facets, but that path triggers a memoryguard stack-depth
// issue in Solc 0.8.33. Instead, we now test the underlying index
// implementation directly via LibPositionList / LibLoanManager.

import {Test} from "forge-std/Test.sol";
import {LibPositionList} from "../../../src/libraries/LibPositionList.sol";

contract BorrowerIndexHarness {
    using LibPositionList for LibPositionList.List;

    LibPositionList.List internal list;

    function add(bytes32 key, uint256 id) external {
        list.add(key, id);
    }

    function remove(bytes32 key, uint256 id) external {
        list.remove(key, id);
    }

    function page(bytes32 key, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory ids, uint256 total)
    {
        return list.page(key, offset, limit);
    }
}

contract DirectBorrowerIndexTest is Test {
    BorrowerIndexHarness internal harness;
    bytes32 internal borrowerKey = keccak256("borrower-1");

    function setUp() public {
        harness = new BorrowerIndexHarness();
    }

    function test_BorrowerIndexTracksLifecycle() public {
        // Add a single agreement
        harness.add(borrowerKey, 1);

        (uint256[] memory ids, uint256 total) = harness.page(borrowerKey, 0, 10);
        assertEq(total, 1, "one agreement tracked in total");
        assertEq(ids.length, 1, "page length");
        assertEq(ids[0], 1, "agreement id stored");

        // Remove the agreement
        harness.remove(borrowerKey, 1);

        (ids, total) = harness.page(borrowerKey, 0, 10);
        assertEq(total, 0, "no agreements after removal");
        assertEq(ids.length, 0, "page empty after removal");
    }

    function test_Pagination() public {
        // Add 3 agreements in order
        harness.add(borrowerKey, 1);
        harness.add(borrowerKey, 2);
        harness.add(borrowerKey, 3);

        (uint256[] memory page1, uint256 total) = harness.page(borrowerKey, 0, 2);
        (uint256[] memory page2, )             = harness.page(borrowerKey, 2, 2);

        assertEq(total, 3, "total agreements");
        assertEq(page1.length, 2, "page1 size");
        assertEq(page2.length, 1, "page2 size");

        // Optional: check ordering explicitly
        assertEq(page1[0], 1, "page1[0]");
        assertEq(page1[1], 2, "page1[1]");
        assertEq(page2[0], 3, "page2[0]");
    }
}
