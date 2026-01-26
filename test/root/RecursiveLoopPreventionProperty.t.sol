// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibNetEquity} from "../../src/libraries/LibNetEquity.sol";

contract RecursiveLoopPreventionPropertyTest is Test {
    /// Feature: principal-accounting-normalization, Property 8: Recursive Loop Prevention
    function testFuzz_recursiveBorrowDepositDoesNotInflateFeeBase(uint256 principal, uint256 borrowed) public {
        vm.assume(principal <= type(uint256).max - borrowed);
        uint256 totalPrincipal = principal + borrowed;
        uint256 feeBase = LibNetEquity.calculateFeeBaseSameAsset(totalPrincipal, borrowed);
        assertLe(feeBase, principal, "fee base inflated by borrow/deposit loop");
    }
}
