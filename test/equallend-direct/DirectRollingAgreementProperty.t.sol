// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectDiamondTestBase} from "./DirectDiamondTestBase.sol";
import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

/// @notice Feature: p2p-rolling-loans, Property 2: Rolling Agreement Initialization Correctness
/// @notice Validates: Requirements 2.1, 2.2, 2.3
/// forge-config: default.fuzz.runs = 100
contract DirectRollingAgreementPropertyTest is DirectDiamondTestBase {
    MockERC20 internal asset;
    address internal lenderOwner = address(0xA11CE);
    address internal borrowerOwner = address(0xB0B);

    function setUp() public {
        setUpDiamond();
        asset = new MockERC20("Test Token", "TEST", 18, 3_000_000 ether);

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

    function testProperty_RollingAgreementInitialization_LenderOffer() public {
        vm.warp(1_000_000);
        uint256 lenderPositionId = nft.mint(lenderOwner, 1);
        uint256 borrowerPositionId = nft.mint(borrowerOwner, 2);
        finalizePositionNFT();
        bytes32 lenderKey = nft.getPositionKey(lenderPositionId);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPositionId);

        harness.seedPoolWithMembership(1, address(asset), lenderKey, 1_000 ether, true);
        harness.seedPoolWithMembership(2, address(asset), borrowerKey, 200 ether, true);

        DirectTypes.DirectRollingOfferParams memory offerParams = DirectTypes.DirectRollingOfferParams({
            lenderPositionId: lenderPositionId,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(asset),
            borrowAsset: address(asset),
            principal: 100 ether,
            collateralLockAmount: 50 ether,
            paymentIntervalSeconds: 604_800,
            rollingApyBps: 800,
            gracePeriodSeconds: 604_000,
            maxPaymentCount: 520,
            upfrontPremium: 5 ether,
            allowAmortization: true,
            allowEarlyRepay: true,
            allowEarlyExercise: false});

        vm.prank(lenderOwner);
        uint256 offerId = rollingOffers.postRollingOffer(offerParams);

        uint256 lenderBalanceBefore = asset.balanceOf(lenderOwner);
        uint256 borrowerBalanceBefore = asset.balanceOf(borrowerOwner);

        vm.prank(borrowerOwner);
        uint256 agreementId = rollingAgreements.acceptRollingOffer(offerId, borrowerPositionId);
        DirectTypes.DirectRollingAgreement memory agreement = rollingAgreements.getRollingAgreement(agreementId);

        assertTrue(agreement.isRolling, "rolling flag set");
        assertEq(agreement.outstandingPrincipal, offerParams.principal, "outstanding principal stored");
        assertEq(agreement.arrears, 0, "arrears zero");
        assertEq(agreement.paymentCount, 0, "paymentCount zero");
        assertEq(agreement.lastAccrualTimestamp, block.timestamp, "last accrual");
        assertEq(agreement.nextDue, block.timestamp + offerParams.paymentIntervalSeconds, "next due set");
        assertEq(views.offerEscrow(lenderKey, offerParams.lenderPoolId), 0, "escrow released");
        assertEq(views.directLocked(borrowerKey, offerParams.collateralPoolId), offerParams.collateralLockAmount, "collateral locked");
        assertEq(
            rollingAgreements.getRollingAgreement(agreementId).upfrontPremium,
            offerParams.upfrontPremium,
            "premium stored"
        );
        assertEq(asset.balanceOf(lenderOwner), lenderBalanceBefore + offerParams.upfrontPremium, "premium to lender");
        assertEq(
            asset.balanceOf(borrowerOwner),
            borrowerBalanceBefore + offerParams.principal - offerParams.upfrontPremium,
            "net principal to borrower"
        );
    }

    function testProperty_RollingAgreementInitialization_BorrowerOffer() public {
        vm.warp(2_000_000);
        uint256 lenderPositionId = nft.mint(lenderOwner, 3);
        uint256 borrowerPositionId = nft.mint(borrowerOwner, 4);
        finalizePositionNFT();
        bytes32 lenderKey = nft.getPositionKey(lenderPositionId);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPositionId);

        harness.seedPoolWithMembership(3, address(asset), lenderKey, 800 ether, true);
        harness.seedPoolWithMembership(4, address(asset), borrowerKey, 300 ether, true);

        DirectTypes.DirectRollingBorrowerOfferParams memory borrowerParams = DirectTypes.DirectRollingBorrowerOfferParams({
            borrowerPositionId: borrowerPositionId,
            lenderPoolId: 3,
            collateralPoolId: 4,
            collateralAsset: address(asset),
            borrowAsset: address(asset),
            principal: 120 ether,
            collateralLockAmount: 60 ether,
            paymentIntervalSeconds: 604_800,
            rollingApyBps: 900,
            gracePeriodSeconds: 604_000,
            maxPaymentCount: 400,
            upfrontPremium: 6 ether,
            allowAmortization: false,
            allowEarlyRepay: true,
            allowEarlyExercise: true});

        vm.prank(borrowerOwner);
        uint256 borrowerOfferId = rollingOffers.postBorrowerRollingOffer(borrowerParams);

        uint256 lenderBalanceBefore = asset.balanceOf(lenderOwner);
        uint256 borrowerBalanceBefore = asset.balanceOf(borrowerOwner);

        vm.prank(lenderOwner);
        uint256 agreementId = rollingAgreements.acceptRollingOffer(borrowerOfferId, lenderPositionId);
        DirectTypes.DirectRollingAgreement memory agreement = rollingAgreements.getRollingAgreement(agreementId);

        assertEq(agreement.outstandingPrincipal, borrowerParams.principal, "outstanding principal stored");
        assertEq(agreement.arrears, 0, "arrears zero");
        assertEq(agreement.paymentCount, 0, "paymentCount zero");
        assertEq(agreement.nextDue, block.timestamp + borrowerParams.paymentIntervalSeconds, "next due set");
        assertEq(agreement.borrowerPositionId, borrowerPositionId, "borrower position stored");
        assertEq(asset.balanceOf(lenderOwner), lenderBalanceBefore + borrowerParams.upfrontPremium, "premium to lender");
        assertEq(
            asset.balanceOf(borrowerOwner),
            borrowerBalanceBefore + borrowerParams.principal - borrowerParams.upfrontPremium,
            "net principal to borrower"
        );
    }
}
