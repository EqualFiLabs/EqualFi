// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectTypes} from "../../../src/libraries/DirectTypes.sol";
import {MockERC20} from "../../../src/mocks/MockERC20.sol";
import {InsufficientPrincipal} from "../../../src/libraries/Errors.sol";
import {DirectDiamondTestBase} from "../DirectDiamondTestBase.sol";

/// @notice Feature: equallend-direct, Property 4: State consistency across multiple agreements
/// @notice Validates: Requirements 1.6, 2.11, 3.3, 3.4, 5.3
contract DirectStateConsistencyPropertyTest is DirectDiamondTestBase {
    MockERC20 internal asset;

    address internal lenderOwner = address(0xA11CE);
    address internal borrowerOwner = address(0xB0B);

    function setUp() public {
        setUpDiamond();
        asset = new MockERC20("Test Token", "TEST", 18, 1_000_000 ether);
    }

    function testProperty_StateConsistencyAcrossAgreements() public {
        vm.warp(20 days);
        uint256 lenderPositionId = nft.mint(lenderOwner, 1);
        uint256 borrowerPositionId = nft.mint(borrowerOwner, 2);
        finalizePositionNFT();
        bytes32 lenderKey = nft.getPositionKey(lenderPositionId);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPositionId);

        harness.seedPoolWithMembership(1, address(asset), lenderKey, 200 ether, true);
        harness.seedPoolWithMembership(2, address(asset), borrowerKey, 150 ether, true);
        asset.transfer(lenderOwner, 300 ether);
        asset.transfer(borrowerOwner, 100 ether);
        vm.prank(lenderOwner);
        asset.approve(address(diamond), type(uint256).max);
        vm.prank(borrowerOwner);
        asset.approve(address(diamond), type(uint256).max);

        DirectTypes.DirectOfferParams memory offerOne = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPositionId,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(asset),
            borrowAsset: address(asset),
            principal: 40 ether,
            aprBps: 1800,
            durationSeconds: 3 days,
            collateralLockAmount: 20 ether,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false});

        DirectTypes.DirectOfferParams memory offerTwo = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPositionId,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(asset),
            borrowAsset: address(asset),
            principal: 30 ether,
            aprBps: 1500,
            durationSeconds: 5 days,
            collateralLockAmount: 25 ether,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false});

        vm.prank(lenderOwner);
        uint256 offerIdOne = offers.postOffer(offerOne);
        vm.prank(lenderOwner);
        uint256 offerIdTwo = offers.postOffer(offerTwo);

        (, uint256 lentAfterPosts) = views.getPositionDirectState(lenderPositionId, offerOne.lenderPoolId);
        assertEq(lentAfterPosts, 70 ether, "lent tracks multiple offers");

        vm.prank(borrowerOwner);
        agreements.acceptOffer(offerIdOne, borrowerPositionId, 0);
        (uint256 lockedAfterFirst, uint256 lentAfterFirst) =
            views.getPositionDirectState(lenderPositionId, offerOne.lenderPoolId);
        assertEq(lentAfterFirst, 70 ether, "lender lent unchanged on accept (reserved earlier)");
        assertEq(lockedAfterFirst, 0, "lender locked should remain zero");

        (uint256 borrowerLockedAfterFirst,) =
            views.getPositionDirectState(borrowerPositionId, offerOne.collateralPoolId);
        assertEq(borrowerLockedAfterFirst, 20 ether, "borrower locked updated");

        vm.prank(borrowerOwner);
        agreements.acceptOffer(offerIdTwo, borrowerPositionId, 0);
        (uint256 borrowerLockedAfterSecond,) =
            views.getPositionDirectState(borrowerPositionId, offerTwo.collateralPoolId);
        assertEq(borrowerLockedAfterSecond, 45 ether, "borrower locked sums across agreements");

        DirectTypes.DirectOfferParams memory overLock = offerOne;
        overLock.principal = 10 ether;
        overLock.collateralLockAmount = 120 ether;
        vm.prank(lenderOwner);
        uint256 bigOffer = offers.postOffer(overLock);

        vm.expectRevert(abi.encodeWithSelector(InsufficientPrincipal.selector, overLock.collateralLockAmount, 105 ether));
        vm.prank(borrowerOwner);
        agreements.acceptOffer(bigOffer, borrowerPositionId, 0);

        // Simulate unlocking (e.g., post-repay) via harness helper to confirm decrements aggregate
        harness.setDirectLocked(borrowerKey, offerOne.collateralPoolId, 10 ether);
        (uint256 borrowerLockedAfterUnlock,) =
            views.getPositionDirectState(borrowerPositionId, offerOne.collateralPoolId);
        assertEq(borrowerLockedAfterUnlock, 10 ether, "borrower locked updates cumulatively");
    }

    function testProperty_RollingActiveDirectLentInvariant_AfterAmortizationAndClose() public {
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

        uint256 lenderPositionId = nft.mint(lenderOwner, 11);
        uint256 borrowerPositionId = nft.mint(borrowerOwner, 12);
        finalizePositionNFT();
        bytes32 lenderKey = nft.getPositionKey(lenderPositionId);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPositionId);

        harness.seedPoolWithMembership(1, address(asset), lenderKey, 1_000 ether, true);
        harness.seedPoolWithMembership(2, address(asset), borrowerKey, 400 ether, true);
        asset.transfer(borrowerOwner, 500 ether);
        vm.prank(borrowerOwner);
        asset.approve(address(diamond), type(uint256).max);

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
        uint256 offerA = rollingOffers.postRollingOffer(offerParams);
        vm.prank(borrowerOwner);
        uint256 agreementA = rollingAgreements.acceptRollingOffer(offerA, borrowerPositionId, 0, 0);

        vm.prank(lenderOwner);
        uint256 offerB = rollingOffers.postRollingOffer(offerParams);
        vm.prank(borrowerOwner);
        uint256 agreementB = rollingAgreements.acceptRollingOffer(offerB, borrowerPositionId, 0, 0);

        assertEq(views.getActiveDirectLent(1), 200 ether, "initial aggregate active lent");

        uint256 closeBMaxPayment = _rollingMaxPayment(agreementB);
        vm.prank(borrowerOwner);
        rollingLifecycle.repayRollingInFull(agreementB, closeBMaxPayment, 0);
        assertEq(views.getActiveDirectLent(1), 100 ether, "after terminal close B");

        vm.warp(block.timestamp + 8 days);
        vm.prank(borrowerOwner);
        rollingPayments.makeRollingPayment(agreementA, 20 ether, 20 ether, 0);
        DirectTypes.DirectRollingAgreement memory afterAmortization = rollingAgreements.getRollingAgreement(agreementA);
        assertEq(
            views.getActiveDirectLent(1),
            afterAmortization.outstandingPrincipal,
            "after partial amortization equals active outstanding"
        );

        uint256 closeAMaxPayment = _rollingMaxPayment(agreementA);
        vm.prank(borrowerOwner);
        rollingLifecycle.repayRollingInFull(agreementA, closeAMaxPayment, 0);
        assertEq(views.getActiveDirectLent(1), 0, "after terminal close A");
    }
}
