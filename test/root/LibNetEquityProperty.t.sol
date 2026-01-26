// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibNetEquity} from "../../src/libraries/LibNetEquity.sol";
import {LibFeeIndex} from "../../src/libraries/LibFeeIndex.sol";

contract LibNetEquityPropertyTest is Test {
    /// Feature: principal-accounting-normalization, Property 1: Fee Base Calculation Correctness
    function testFuzz_feeBaseSameAsset(uint256 principal, uint256 sameAssetDebt) public {
        uint256 expected = principal > sameAssetDebt ? principal - sameAssetDebt : 0;
        uint256 netEquity = LibNetEquity.calculateNetEquity(principal, sameAssetDebt);
        uint256 feeBase = LibFeeIndex.calculateFeeBaseSameAsset(principal, sameAssetDebt);

        assertEq(netEquity, expected, "net equity mismatch");
        assertEq(feeBase, expected, "fee base mismatch");
    }
}
