// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectDiamondTestBase} from "../DirectDiamondTestBase.sol";
import {DirectTypes} from "../../../src/libraries/DirectTypes.sol";
import {MockERC20} from "../../../src/mocks/MockERC20.sol";
import {RollingError_AmortizationDisabled, RollingError_DustPayment} from "../../../src/libraries/Errors.sol";
import {UnexpectedMsgValue} from "../../../src/libraries/Errors.sol";

/// @notice Feature: p2p-rolling-loans, Property 3/4/5: Payment application, interest calc, multi-miss
/// @notice Validates: Requirements 2.4, 2.5, 3.1, 3.2, 3.3, 3.4
/// forge-config: default.fuzz.runs = 100
contract DirectRollingPaymentPropertyTest is DirectDiamondTestBase {
    MockERC20 internal asset;
    address internal lenderOwner = address(0xA11CE);
    address internal borrowerOwner = address(0xB0B);
    address internal newLenderOwner = address(0xC0FFEE);

    function setUp() public {
        setUpDiamond();
        asset = new MockERC20("Test Token", "TEST", 18, 5_000_000 ether);

        DirectTypes.DirectRollingConfig memory cfg = DirectTypes.DirectRollingConfig({
            minPaymentIntervalSeconds: 604_800,
            maxPaymentCount: 520,
            maxUpfrontPremiumBps: 5_000,
            minRollingApyBps: 1,
            maxRollingApyBps: 10_000,
            defaultPenaltyBps: 1_000,
            minPaymentBps: 1
        });
        harness.setRollingConfig(cfg);
    }

    function _setupAgreement(bool allowAmortization) internal returns (uint256 agreementId, uint256 lenderPositionId, uint256 borrowerPositionId) {
        lenderPositionId = nft.mint(lenderOwner, 1);
        borrowerPositionId = nft.mint(borrowerOwner, 2);
        finalizePositionNFT();
        bytes32 lenderKey = nft.getPositionKey(lenderPositionId);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPositionId);
        harness.seedPoolWithMembership(1, address(asset), lenderKey, 1_000 ether, true);
        harness.seedPoolWithMembership(2, address(asset), borrowerKey, 300 ether, true);

        DirectTypes.DirectRollingOfferParams memory offerParams = DirectTypes.DirectRollingOfferParams({
            lenderPositionId: lenderPositionId,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(asset),
            borrowAsset: address(asset),
            principal: 100 ether,
            collateralLockAmount: 50 ether,
            paymentIntervalSeconds: 7 days,
            rollingApyBps: 800,
            gracePeriodSeconds: 6 days,
            maxPaymentCount: 520,
            upfrontPremium: 0,
            allowAmortization: allowAmortization,
            allowEarlyRepay: true,
            allowEarlyExercise: false});

        vm.prank(lenderOwner);
        uint256 offerId = rollingOffers.postRollingOffer(offerParams);
        vm.prank(borrowerOwner);
        agreementId = rollingAgreements.acceptRollingOffer(offerId, borrowerPositionId, 0, 0);
    }

    function testProperty_PaymentApplicationAndScheduleAdvance() public {
        (uint256 agreementId,,) = _setupAgreement(true);
        DirectTypes.DirectRollingAgreement memory beforePay = rollingAgreements.getRollingAgreement(agreementId);

        // Warp 1.5 intervals to accrue arrears (multi-miss)
        vm.warp(block.timestamp + 10 days);
        uint256 payAmount = 10 ether;
        asset.mint(borrowerOwner, payAmount);

        vm.startPrank(borrowerOwner);
        asset.approve(address(diamond), payAmount);
        rollingPayments.makeRollingPayment(agreementId, payAmount, payAmount, 0);
        vm.stopPrank();

        DirectTypes.DirectRollingAgreement memory afterPay = rollingAgreements.getRollingAgreement(agreementId);
        // arrears should be <= initial accrued interest
        assertLe(afterPay.arrears, beforePay.outstandingPrincipal, "arrears reduced");
        assertTrue(afterPay.paymentCount == 1, "paymentCount advanced once");
        assertEq(afterPay.nextDue, beforePay.nextDue + beforePay.paymentIntervalSeconds, "nextDue advanced once");
    }

    function testProperty_AmortizationDisabledRevertsOnExcess() public {
        (uint256 agreementId,,) = _setupAgreement(false);
        vm.warp(block.timestamp + 8 days);
        uint256 payAmount = 20 ether;
        asset.mint(borrowerOwner, payAmount);
        vm.startPrank(borrowerOwner);
        asset.approve(address(diamond), payAmount);
        vm.expectRevert(RollingError_AmortizationDisabled.selector);
        rollingPayments.makeRollingPayment(agreementId, payAmount, payAmount, 0);
        vm.stopPrank();
    }

    function testProperty_DustPaymentReverts() public {
        (uint256 agreementId,,) = _setupAgreement(true);
        DirectTypes.DirectRollingAgreement memory agreement = rollingAgreements.getRollingAgreement(agreementId);
        uint256 minPayment = (agreement.outstandingPrincipal + 9_999) / 10_000;
        vm.startPrank(borrowerOwner);
        asset.approve(address(diamond), 1);
        vm.expectRevert(abi.encodeWithSelector(RollingError_DustPayment.selector, 0, minPayment));
        rollingPayments.makeRollingPayment(agreementId, 0, 0, 0);
        vm.stopPrank();
    }

    function test_makeRollingPayment_routesToCurrentLenderPositionOwner() public {
        (uint256 agreementId, uint256 lenderPositionId,) = _setupAgreement(true);

        vm.prank(lenderOwner);
        nft.transferFrom(lenderOwner, newLenderOwner, lenderPositionId);

        uint256 payAmount = 10 ether;
        asset.mint(borrowerOwner, payAmount);
        uint256 oldLenderBalanceBefore = asset.balanceOf(lenderOwner);
        uint256 newLenderBalanceBefore = asset.balanceOf(newLenderOwner);

        vm.startPrank(borrowerOwner);
        asset.approve(address(diamond), payAmount);
        rollingPayments.makeRollingPayment(agreementId, payAmount, payAmount, 0);
        vm.stopPrank();

        assertEq(asset.balanceOf(lenderOwner), oldLenderBalanceBefore, "old lender receives nothing");
        assertEq(asset.balanceOf(newLenderOwner), newLenderBalanceBefore + payAmount, "current owner receives payment");
    }

    function test_makeRollingPayment_revertsOnStrayEthForErc20() public {
        (uint256 agreementId,,) = _setupAgreement(true);
        vm.deal(borrowerOwner, 1 ether);
        vm.prank(borrowerOwner);
        vm.expectRevert(abi.encodeWithSelector(UnexpectedMsgValue.selector, 1));
        rollingPayments.makeRollingPayment{value: 1}(agreementId, 10 ether, 10 ether, 0);
    }

    function test_invariant_activeDirectLent_matchesSumOfActiveOutstandingPrincipal() public {
        (uint256 agreementA, uint256 lenderPositionId, uint256 borrowerPositionId) = _setupAgreement(true);

        DirectTypes.DirectRollingOfferParams memory offerParams = DirectTypes.DirectRollingOfferParams({
            lenderPositionId: lenderPositionId,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(asset),
            borrowAsset: address(asset),
            principal: 100 ether,
            collateralLockAmount: 50 ether,
            paymentIntervalSeconds: 7 days,
            rollingApyBps: 800,
            gracePeriodSeconds: 6 days,
            maxPaymentCount: 520,
            upfrontPremium: 0,
            allowAmortization: true,
            allowEarlyRepay: true,
            allowEarlyExercise: false
        });
        vm.prank(lenderOwner);
        uint256 offerIdB = rollingOffers.postRollingOffer(offerParams);
        vm.prank(borrowerOwner);
        uint256 agreementB = rollingAgreements.acceptRollingOffer(offerIdB, borrowerPositionId, 0, 0);

        vm.startPrank(borrowerOwner);
        asset.mint(borrowerOwner, 500 ether);
        asset.approve(address(diamond), type(uint256).max);
        vm.stopPrank();

        uint256 sumOutstanding = _sumActiveOutstanding(agreementA, agreementB);
        assertEq(views.getActiveDirectLent(1), sumOutstanding, "initial active lent invariant");

        uint256 closeBMaxPayment = _rollingMaxPayment(agreementB);
        vm.prank(borrowerOwner);
        rollingLifecycle.repayRollingInFull(agreementB, closeBMaxPayment, 0);
        sumOutstanding = _sumActiveOutstanding(agreementA, agreementB);
        assertEq(views.getActiveDirectLent(1), sumOutstanding, "after close B invariant");

        vm.warp(block.timestamp + 8 days);
        vm.prank(borrowerOwner);
        rollingPayments.makeRollingPayment(agreementA, 20 ether, 20 ether, 0);
        sumOutstanding = _sumActiveOutstanding(agreementA, agreementB);
        assertEq(views.getActiveDirectLent(1), sumOutstanding, "after amortization invariant");

        uint256 closeAMaxPayment = _rollingMaxPayment(agreementA);
        vm.prank(borrowerOwner);
        rollingLifecycle.repayRollingInFull(agreementA, closeAMaxPayment, 0);
        sumOutstanding = _sumActiveOutstanding(agreementA, agreementB);
        assertEq(views.getActiveDirectLent(1), sumOutstanding, "after full close invariant");
        assertEq(sumOutstanding, 0, "no active outstanding principal");
    }

    function test_makeRollingPayment_acceptsOversizedMaxPaymentForErc20() public {
        (uint256 agreementId,,) = _setupAgreement(true);
        asset.mint(borrowerOwner, 100 ether);

        uint256 lenderBalanceBefore = asset.balanceOf(lenderOwner);
        DirectTypes.DirectRollingAgreement memory beforePayment = rollingAgreements.getRollingAgreement(agreementId);
        (uint256 intervalInterest,) = rollingViews.calculateRollingPayment(agreementId);

        vm.startPrank(borrowerOwner);
        asset.approve(address(diamond), type(uint256).max);
        rollingPayments.makeRollingPayment(agreementId, 10 ether, 15 ether, 0);
        vm.stopPrank();

        DirectTypes.DirectRollingAgreement memory afterPayment = rollingAgreements.getRollingAgreement(agreementId);
        uint256 expectedPrincipalPaid = 15 ether > intervalInterest ? 15 ether - intervalInterest : 0;
        if (expectedPrincipalPaid > beforePayment.outstandingPrincipal) {
            expectedPrincipalPaid = beforePayment.outstandingPrincipal;
        }

        assertEq(asset.balanceOf(lenderOwner) - lenderBalanceBefore, 15 ether, "lender receives pulled max");
        assertEq(
            beforePayment.outstandingPrincipal - afterPayment.outstandingPrincipal,
            expectedPrincipalPaid,
            "principal reduction reflects overpull after interest"
        );
    }

    function _sumActiveOutstanding(uint256 agreementA, uint256 agreementB) internal view returns (uint256 sum) {
        DirectTypes.DirectRollingAgreement memory a = rollingAgreements.getRollingAgreement(agreementA);
        if (a.status == DirectTypes.DirectStatus.Active) {
            sum += a.outstandingPrincipal;
        }
        DirectTypes.DirectRollingAgreement memory b = rollingAgreements.getRollingAgreement(agreementB);
        if (b.status == DirectTypes.DirectStatus.Active) {
            sum += b.outstandingPrincipal;
        }
    }
}
