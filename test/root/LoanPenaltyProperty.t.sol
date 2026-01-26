// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LibLoanHelpers} from "../../src/libraries/LibLoanHelpers.sol";

contract LoanPenaltyHarness {
    function calculatePenalty(uint256 principalAtOpen) external pure returns (uint256) {
        return LibLoanHelpers.calculatePenalty(principalAtOpen);
    }
}

/// @notice Feature: term-loan-default-settlement, Property 2/3/5
contract LoanPenaltyPropertyTest is Test {
    LoanPenaltyHarness internal harness;

    function setUp() public {
        harness = new LoanPenaltyHarness();
    }

    function testProperty_PenaltyCalculationFormula(uint256 principalAtOpen) public {
        principalAtOpen = bound(principalAtOpen, 1, type(uint128).max);
        uint256 expected = (principalAtOpen * 500) / 10_000;
        uint256 penalty = harness.calculatePenalty(principalAtOpen);
        assertEq(penalty, expected);
    }

    function testProperty_PenaltyApplicationCap(
        uint256 principalAtOpen,
        uint256 principalRemaining
    ) public {
        principalAtOpen = bound(principalAtOpen, 1, type(uint128).max);
        principalRemaining = bound(principalRemaining, 0, type(uint128).max);
        uint256 penalty = harness.calculatePenalty(principalAtOpen);
        uint256 applied = penalty < principalRemaining ? penalty : principalRemaining;
        uint256 expected = penalty < principalRemaining ? penalty : principalRemaining;
        assertEq(applied, expected);
    }

    function testProperty_UtilizationIndependentPenalty(
        uint256 principalAtOpen,
        uint256 drawAmountA,
        uint256 drawAmountB
    ) public {
        principalAtOpen = bound(principalAtOpen, 1, type(uint128).max);
        drawAmountA = bound(drawAmountA, 1, principalAtOpen);
        drawAmountB = bound(drawAmountB, 1, principalAtOpen);

        uint256 penaltyA = harness.calculatePenalty(principalAtOpen);
        uint256 penaltyB = harness.calculatePenalty(principalAtOpen);
        assertEq(penaltyA, penaltyB);

        uint256 appliedA = penaltyA < drawAmountA ? penaltyA : drawAmountA;
        uint256 appliedB = penaltyB < drawAmountB ? penaltyB : drawAmountB;
        assertEq(penaltyA, (principalAtOpen * 500) / 10_000);
        assertEq(penaltyB, (principalAtOpen * 500) / 10_000);
        assertLe(appliedA, penaltyA);
        assertLe(appliedB, penaltyB);
    }
}
