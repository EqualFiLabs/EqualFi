// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibSolvencyChecks} from "../../src/libraries/LibSolvencyChecks.sol";

contract FeeBaseInvariantPropertyTest is Test {
    /// Feature: principal-accounting-normalization, Property 7: Fee Base Invariant for Same-Asset Domains
    function testFuzz_feeBaseInvariant(uint256 principal, uint256 sameAssetDebt) public {
        bool ok = LibSolvencyChecks.checkFeeBaseInvariant(principal, sameAssetDebt);
        assertTrue(ok, "fee base invariant violated");
    }
}
