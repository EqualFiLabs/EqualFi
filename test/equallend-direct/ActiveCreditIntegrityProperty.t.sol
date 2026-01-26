// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectDiamondTestBase} from "./DirectDiamondTestBase.sol";
import {LibActiveCreditIndex} from "../../src/libraries/LibActiveCreditIndex.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {Types} from "../../src/libraries/Types.sol";

/// **Feature: active-credit-index, Property 10: Fee Distribution Conservation**
/// Validates: Requirements 6.1
/// **Feature: active-credit-index, Property 11/12: FeeBase & Split Invariants**
/// Validates: Requirements 6.2, 6.3
/// **Feature: active-credit-index, Property 14: Proportional Distribution Under Scarcity**
/// Validates: Requirements 6.5
contract ActiveCreditIntegrityPropertyTest is DirectDiamondTestBase {
    bytes32 internal userA = keccak256("userA11CE");
    bytes32 internal userB = keccak256("userB0B");

    function setUp() public {
        setUpDiamond();
        vm.warp(7 days);
    }

    function testProperty_FeeDistributionConservation() public {
        uint256 amount = 40 ether;
        harness.seedActiveCreditPool(1, 1_000 ether, 0);
        harness.setEncumbranceState(1, userA, 100 ether, uint40(block.timestamp - LibActiveCreditIndex.TIME_GATE));
        harness.setEncumbranceState(1, userB, 100 ether, uint40(block.timestamp - LibActiveCreditIndex.TIME_GATE));

        harness.accrueActiveCredit(1, amount, bytes32("TEST"));
        harness.settleActive(1, userA);
        harness.settleActive(1, userB);

        uint256 totalAccrued = views.accruedYield(1, userA) + views.accruedYield(1, userB);
        assertEq(totalAccrued, amount, "payouts conserve allocation");
    }

    function testProperty_FeeBaseInvariantPreservation() public {
        harness.seedActiveCreditPool(2, 500 ether, 0);
        harness.setDebtState(2, userA, 200 ether, uint40(block.timestamp - LibActiveCreditIndex.TIME_GATE));
        Types.PoolData storage p = LibAppStorage.s().pools[2];
        p.userPrincipal[userA] = 300 ether;

        uint256 principalBefore = p.userPrincipal[userA];
        harness.accrueActiveCredit(2, 15 ether, bytes32("TEST"));
        harness.settleActive(2, userA);

        assertEq(p.userPrincipal[userA], principalBefore, "active credit operations leave fee base unchanged");
        assertEq(p.feeIndex, 0, "fee index untouched by active credit accruals");
    }

    function testProperty_ProportionalDistributionUnderScarcity() public {
        harness.seedActiveCreditPool(3, 1_000 ether, 0);
        harness.setEncumbranceState(3, userA, 300 ether, uint40(block.timestamp - LibActiveCreditIndex.TIME_GATE));
        harness.setEncumbranceState(3, userB, 700 ether, uint40(block.timestamp - LibActiveCreditIndex.TIME_GATE));

        uint256 amount = 50 ether;
        harness.accrueActiveCredit(3, amount, bytes32("TEST"));
        harness.settleActive(3, userA);
        harness.settleActive(3, userB);

        uint256 totalAccrued = views.accruedYield(3, userA) + views.accruedYield(3, userB);
        assertEq(totalAccrued, amount, "allocations bounded by funding");

        uint256 shareA = (amount * 300 ether) / (300 ether + 700 ether);
        uint256 shareB = amount - shareA;
        assertEq(views.accruedYield(3, userA), shareA, "proportional share A");
        assertEq(views.accruedYield(3, userB), shareB, "proportional share B");
    }
}
