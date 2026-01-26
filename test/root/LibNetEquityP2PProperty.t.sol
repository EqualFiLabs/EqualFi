// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibNetEquity} from "../../src/libraries/LibNetEquity.sol";

contract LibNetEquityP2PPropertyTest is Test {
    /// Feature: principal-accounting-normalization, Property 4: Same-Asset P2P Fee Base Limitation
    function testFuzz_sameAssetP2PFeeBaseLimit(
        uint256 lockedCollateral,
        uint256 unlockedPrincipal,
        uint256 sameAssetDebt
    ) public {
        vm.assume(lockedCollateral <= type(uint256).max - unlockedPrincipal);
        uint256 principal = lockedCollateral + unlockedPrincipal;
        uint256 expected = principal > sameAssetDebt ? principal - sameAssetDebt : 0;

        uint256 feeBase = LibNetEquity.calculateP2PBorrowerFeeBase(
            lockedCollateral,
            unlockedPrincipal,
            sameAssetDebt,
            true
        );

        assertEq(feeBase, expected, "same-asset fee base mismatch");
    }

    /// Feature: principal-accounting-normalization, Property 5: Cross-Asset P2P Fee Base Allowance
    function testFuzz_crossAssetP2PFeeBaseAllowance(uint256 lockedCollateral, uint256 unlockedPrincipal) public {
        vm.assume(lockedCollateral <= type(uint256).max - unlockedPrincipal);
        uint256 expected = lockedCollateral + unlockedPrincipal;

        uint256 feeBase = LibNetEquity.calculateP2PBorrowerFeeBase(
            lockedCollateral,
            unlockedPrincipal,
            0,
            false
        );

        assertEq(feeBase, expected, "cross-asset fee base mismatch");
    }
}
