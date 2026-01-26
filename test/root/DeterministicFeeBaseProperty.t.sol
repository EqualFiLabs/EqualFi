// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibNetEquity} from "../../src/libraries/LibNetEquity.sol";

contract DeterministicFeeBasePropertyTest is Test {
    /// Feature: principal-accounting-normalization, Property 10: Deterministic Fee Base Calculation
    function testFuzz_feeBaseDeterministic(
        uint256 lockedCollateral,
        uint256 unlockedPrincipal,
        uint256 sameAssetDebt
    ) public {
        vm.assume(lockedCollateral <= type(uint256).max - unlockedPrincipal);
        uint256 feeBaseA = LibNetEquity.calculateP2PBorrowerFeeBase(
            lockedCollateral,
            unlockedPrincipal,
            sameAssetDebt,
            true
        );
        uint256 feeBaseB = LibNetEquity.calculateP2PBorrowerFeeBase(
            lockedCollateral,
            unlockedPrincipal,
            sameAssetDebt,
            true
        );
        assertEq(feeBaseA, feeBaseB, "same-asset fee base not deterministic");

        uint256 feeBaseCrossA = LibNetEquity.calculateP2PBorrowerFeeBase(
            lockedCollateral,
            unlockedPrincipal,
            sameAssetDebt,
            false
        );
        uint256 feeBaseCrossB = LibNetEquity.calculateP2PBorrowerFeeBase(
            lockedCollateral,
            unlockedPrincipal,
            sameAssetDebt,
            false
        );
        assertEq(feeBaseCrossA, feeBaseCrossB, "cross-asset fee base not deterministic");
    }
}
