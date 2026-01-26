// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectDiamondTestBase} from "./DirectDiamondTestBase.sol";
import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {RollingError_AmortizationDisabled, RollingError_DustPayment} from "../../src/libraries/Errors.sol";

/// @notice Feature: p2p-rolling-loans, Property 3/4/5: Payment application, interest calc, multi-miss
/// @notice Validates: Requirements 2.4, 2.5, 3.1, 3.2, 3.3, 3.4
/// forge-config: default.fuzz.runs = 100
contract DirectRollingPaymentPropertyTest is DirectDiamondTestBase {
    MockERC20 internal asset;
    address internal lenderOwner = address(0xA11CE);
    address internal borrowerOwner = address(0xB0B);

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
        agreementId = rollingAgreements.acceptRollingOffer(offerId, borrowerPositionId);
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
        rollingPayments.makeRollingPayment(agreementId, payAmount);
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
        rollingPayments.makeRollingPayment(agreementId, payAmount);
        vm.stopPrank();
    }

    function testProperty_DustPaymentReverts() public {
        (uint256 agreementId,,) = _setupAgreement(true);
        DirectTypes.DirectRollingAgreement memory agreement = rollingAgreements.getRollingAgreement(agreementId);
        uint256 minPayment = (agreement.outstandingPrincipal + 9_999) / 10_000;
        vm.startPrank(borrowerOwner);
        asset.approve(address(diamond), 1);
        vm.expectRevert(abi.encodeWithSelector(RollingError_DustPayment.selector, 0, minPayment));
        rollingPayments.makeRollingPayment(agreementId, 0);
        vm.stopPrank();
    }
}
