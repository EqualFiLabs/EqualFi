// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectDiamondTestBase} from "./DirectDiamondTestBase.sol";
import {EqualLendDirectRollingViewFacet} from "../../src/views/EqualLendDirectRollingViewFacet.sol";
import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

/// @notice Feature: p2p-rolling-loans, Property 10: View Function Accuracy
/// @notice Validates: Requirements 9.1, 9.2, 9.3, 9.4, 9.5
/// forge-config: default.fuzz.runs = 100
contract DirectRollingViewPropertyTest is DirectDiamondTestBase {
    MockERC20 internal asset;
    address internal lenderOwner = address(0xA11CE);
    address internal borrowerOwner = address(0xB0B);

    function setUp() public {
        setUpDiamond();
        asset = new MockERC20("Test Token", "TEST", 18, 5_000_000 ether);

        DirectTypes.DirectRollingConfig memory rollingCfg = DirectTypes.DirectRollingConfig({
            minPaymentIntervalSeconds: 604_800,
            maxPaymentCount: 520,
            maxUpfrontPremiumBps: 5_000,
            minRollingApyBps: 1,
            maxRollingApyBps: 10_000,
            defaultPenaltyBps: 1_000,
            minPaymentBps: 1
        });
        harness.setRollingConfig(rollingCfg);
    }

    function _setupAgreement()
        internal
        returns (uint256 agreementId, bytes32 lenderKey, bytes32 borrowerKey, uint256 lenderPos, uint256 borrowerPos)
    {
        lenderPos = nft.mint(lenderOwner, 1);
        borrowerPos = nft.mint(borrowerOwner, 2);
        finalizePositionNFT();
        lenderKey = nft.getPositionKey(lenderPos);
        borrowerKey = nft.getPositionKey(borrowerPos);

        harness.seedPoolWithMembership(1, address(asset), lenderKey, 1_000 ether, true);
        harness.seedPoolWithMembership(1, address(asset), borrowerKey, 300 ether, true);

        DirectTypes.DirectRollingOfferParams memory offerParams = DirectTypes.DirectRollingOfferParams({
            lenderPositionId: lenderPos,
            lenderPoolId: 1,
            collateralPoolId: 1,
            collateralAsset: address(asset),
            borrowAsset: address(asset),
            principal: 100 ether,
            collateralLockAmount: 200 ether,
            paymentIntervalSeconds: 7 days,
            rollingApyBps: 800,
            gracePeriodSeconds: 6 days,
            maxPaymentCount: 520,
            upfrontPremium: 0,
            allowAmortization: true,
            allowEarlyRepay: true,
            allowEarlyExercise: true});

        vm.prank(lenderOwner);
        uint256 offerId = rollingOffers.postRollingOffer(offerParams);
        vm.prank(borrowerOwner);
        agreementId = rollingAgreements.acceptRollingOffer(offerId, borrowerPos);
    }

    function testProperty_ViewAccuracy() public {
        (uint256 agreementId, bytes32 lenderKey, bytes32 borrowerKey,,) = _setupAgreement();
        DirectTypes.DirectRollingAgreement memory ag = rollingAgreements.getRollingAgreement(agreementId);

        (uint256 interestDue, uint256 totalDue) = rollingViews.calculateRollingPayment(agreementId);
        uint256 expectedInterest =
            (ag.outstandingPrincipal * ag.rollingApyBps * ag.paymentIntervalSeconds + (365 days * 10_000 - 1))
                / (365 days * 10_000);
        assertEq(interestDue, expectedInterest, "interest due matches ceil formula");
        assertEq(totalDue, interestDue + ag.arrears, "total due sums arrears + interest");

        // Status pre-due
        EqualLendDirectRollingViewFacet.RollingStatus memory status = rollingViews.getRollingStatus(agreementId);
        assertFalse(status.isOverdue, "not overdue initially");
        assertFalse(status.inGracePeriod, "not in grace initially");
        assertFalse(status.canRecover, "cannot recover initially");
        assertFalse(status.isAtPaymentCap, "not at cap");

        // Warp past due but within grace
        vm.warp(ag.nextDue + 1);
        status = rollingViews.getRollingStatus(agreementId);
        assertTrue(status.isOverdue, "overdue");
        assertTrue(status.inGracePeriod, "in grace");
        assertFalse(status.canRecover, "cannot recover yet");

        // Warp past grace
        vm.warp(ag.nextDue + ag.gracePeriodSeconds + 10);
        status = rollingViews.getRollingStatus(agreementId);
        assertTrue(status.isOverdue, "overdue still");
        assertFalse(status.inGracePeriod, "not in grace");
        assertTrue(status.canRecover, "can recover");

        // Payment cap
        harness.setPaymentCount(agreementId, ag.maxPaymentCount);
        status = rollingViews.getRollingStatus(agreementId);
        assertTrue(status.isAtPaymentCap, "at cap");

        // Aggregate exposure (borrower side)
        EqualLendDirectRollingViewFacet.RollingExposure memory exposure = rollingViews.aggregateRollingExposure(borrowerKey);
        assertEq(exposure.totalOutstandingPrincipal, ag.outstandingPrincipal, "aggregate principal");
        assertEq(exposure.totalArrears, ag.arrears, "aggregate arrears");
        assertEq(exposure.nextPaymentDue, ag.nextDue, "next due");
        assertEq(exposure.activeAgreementCount, 1, "count");
        // Lender exposure unaffected by borrower aggregation
        exposure = rollingViews.aggregateRollingExposure(lenderKey);
        assertEq(exposure.totalOutstandingPrincipal, 0, "lender as borrower zero");
    }
}
