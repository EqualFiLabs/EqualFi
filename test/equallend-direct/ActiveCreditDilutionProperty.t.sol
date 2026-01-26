// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectDiamondTestBase} from "./DirectDiamondTestBase.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Types} from "../../src/libraries/Types.sol";
import {LibActiveCreditIndex} from "../../src/libraries/LibActiveCreditIndex.sol";

/// **Feature: active-credit-index, Property 3: Weighted Dilution Formula Correctness**
/// Validates: Requirements 2.1, 2.2, 3.3, 8.3, 8.4
contract ActiveCreditWeightedDilutionPropertyTest is DirectDiamondTestBase {
    uint256 internal constant PID = 1;
    bytes32 internal constant USER = keccak256("USER_A11CE");

    function setUp() public {
        setUpDiamond();
        vm.warp(100 days);
    }

    function testProperty_WeightedDilutionFormula(uint256 oldPrincipal, uint256 addPrincipal, uint256 oldCredit) public {
        oldPrincipal = bound(oldPrincipal, 1, 1e24);
        addPrincipal = bound(addPrincipal, 1, 1e24);
        oldCredit = bound(oldCredit, 1, LibActiveCreditIndex.TIME_GATE);

        uint40 startTime = uint40(block.timestamp - oldCredit);
        harness.setEncumbranceState(PID, USER, oldPrincipal, startTime);
        harness.applyActiveCreditIncrease(PID, USER, addPrincipal);

        Types.ActiveCreditState memory s = views.encumbranceActiveCreditState(PID, USER);
        uint256 expectedCredit = Math.mulDiv(oldPrincipal, oldCredit, oldPrincipal + addPrincipal);
        assertEq(block.timestamp - s.startTime, expectedCredit, "weighted time credit matches formula");
        assertLe(block.timestamp - s.startTime, LibActiveCreditIndex.TIME_GATE, "credit capped at gate");
        assertEq(s.principal, oldPrincipal + addPrincipal, "principal updated");
    }
}

/// **Feature: active-credit-index, Property 4: Time Gate Eligibility Rules**
/// Validates: Requirements 2.3, 2.4, 4.4
contract ActiveCreditTimeGatePropertyTest is DirectDiamondTestBase {
    uint256 internal constant PID = 2;
    bytes32 internal constant USER = keccak256("USER_BEEF");

    function setUp() public {
        setUpDiamond();
        vm.warp(100 days);
    }

    function testProperty_TimeGateZeroWeightUntilMature(uint256 principal, uint256 credit) public {
        principal = bound(principal, 1, 1e24);
        credit = bound(credit, 1, LibActiveCreditIndex.TIME_GATE - 1);
        harness.setEncumbranceState(PID, USER, principal, uint40(block.timestamp - credit));
        assertEq(views.activeCreditWeight(PID, USER), 0, "weight gated before maturity");
    }

    function testProperty_TimeGateFullWeightAfterMature(uint256 principal) public {
        principal = bound(principal, 1, 1e24);
        harness.setEncumbranceState(PID, USER, principal, uint40(block.timestamp - LibActiveCreditIndex.TIME_GATE));
        assertEq(views.activeCreditWeight(PID, USER), principal, "full weight after maturity");
    }
}

/// **Feature: active-credit-index, Property 5: Dust Priming Attack Prevention**
/// Validates: Requirements 7.5, 8.1, 8.5
contract ActiveCreditDustPrimingPropertyTest is DirectDiamondTestBase {
    uint256 internal constant PID = 3;
    bytes32 internal constant USER = keccak256("USER_CAFE");

    function setUp() public {
        setUpDiamond();
        vm.warp(100 days);
    }

    function testProperty_DustPrimingDilutesToNearZero(uint256 oldPrincipal, uint256 multiplier) public {
        oldPrincipal = bound(oldPrincipal, 1, 1e18);
        multiplier = bound(multiplier, 50, 5000); // large top-up
        uint256 addPrincipal = oldPrincipal * multiplier;

        harness.setEncumbranceState(PID, USER, oldPrincipal, uint40(block.timestamp - LibActiveCreditIndex.TIME_GATE));
        harness.applyActiveCreditIncrease(PID, USER, addPrincipal);
        Types.ActiveCreditState memory s = views.encumbranceActiveCreditState(PID, USER);

        uint256 newCredit = block.timestamp - s.startTime;
        // Expect strong dilution: credit shrinks proportional to old/(old+new) ~ 1/(1+multiplier)
        uint256 expectedMax = LibActiveCreditIndex.TIME_GATE / (multiplier / 2);
        assertLe(newCredit, expectedMax, "dust priming credit diluted near zero");
    }
}

/// **Feature: active-credit-index, Property 6: Legitimate Top-up Preservation**
/// Validates: Requirements 8.2
contract ActiveCreditLegitTopupPropertyTest is DirectDiamondTestBase {
    uint256 internal constant PID = 4;
    bytes32 internal constant USER = keccak256("USER_D00D");

    function setUp() public {
        setUpDiamond();
        vm.warp(100 days);
    }

    function testProperty_LegitTopupPreservesTimeCredit(uint256 oldPrincipal, uint256 addPrincipal) public {
        oldPrincipal = bound(oldPrincipal, 1e6, 1e24);
        addPrincipal = bound(addPrincipal, 1, oldPrincipal / 20); // small top-up (<=5%)

        harness.setEncumbranceState(PID, USER, oldPrincipal, uint40(block.timestamp - LibActiveCreditIndex.TIME_GATE));
        harness.applyActiveCreditIncrease(PID, USER, addPrincipal);
        Types.ActiveCreditState memory s = views.encumbranceActiveCreditState(PID, USER);

        uint256 newCredit = block.timestamp - s.startTime;
        // Expect most of the 24h credit preserved (>=95%)
        uint256 minExpected = (LibActiveCreditIndex.TIME_GATE * 19) / 20;
        assertGe(newCredit, minExpected, "large portion of time credit preserved");
    }
}
