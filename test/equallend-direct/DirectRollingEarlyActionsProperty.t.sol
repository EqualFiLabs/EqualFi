// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectDiamondTestBase} from "./DirectDiamondTestBase.sol";
import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {DirectError_EarlyExerciseNotAllowed, DirectError_EarlyRepayNotAllowed} from "../../src/libraries/Errors.sol";

/// @notice Feature: p2p-rolling-loans, Property 8: Early Action Conditions
/// @notice Validates: Requirements 6.1, 6.2, 6.3, 6.4, 6.5
/// forge-config: default.fuzz.runs = 100
contract DirectRollingEarlyActionsPropertyTest is DirectDiamondTestBase {
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

        DirectTypes.DirectConfig memory cfg = DirectTypes.DirectConfig({
            platformFeeBps: 0,
            interestLenderBps: 10_000,
            platformFeeLenderBps: 10_000,
            defaultLenderBps: 10_000,
            minInterestDuration: 0
        });
        views.setDirectConfig(cfg);
    }

    function _setupAgreement(bool allowEarlyExercise, bool allowEarlyRepay)
        internal
        returns (uint256 agreementId, bytes32 lenderKey, bytes32 borrowerKey)
    {
        uint256 lenderPositionId = nft.mint(lenderOwner, 1);
        uint256 borrowerPositionId = nft.mint(borrowerOwner, 2);
        finalizePositionNFT();
        lenderKey = nft.getPositionKey(lenderPositionId);
        borrowerKey = nft.getPositionKey(borrowerPositionId);

        harness.seedPoolWithMembership(1, address(asset), lenderKey, 1_000 ether, true);
        harness.seedPoolWithMembership(1, address(asset), borrowerKey, 300 ether, true);

        DirectTypes.DirectRollingOfferParams memory offerParams = DirectTypes.DirectRollingOfferParams({
            lenderPositionId: lenderPositionId,
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
            allowAmortization: false,
            allowEarlyRepay: allowEarlyRepay,
            allowEarlyExercise: allowEarlyExercise});

        vm.prank(lenderOwner);
        uint256 offerId = rollingOffers.postRollingOffer(offerParams);
        vm.prank(borrowerOwner);
        agreementId = rollingAgreements.acceptRollingOffer(offerId, borrowerPositionId);
    }

    function testProperty_EarlyExerciseAllowed() public {
        (uint256 agreementId, bytes32 lenderKey, bytes32 borrowerKey) = _setupAgreement(true, false);
        harness.setArrears(agreementId, 20 ether);

        uint256 borrowerPrincipalBefore = views.getUserPrincipal(1, borrowerKey);
        uint256 lenderPrincipalBefore = views.getUserPrincipal(1, lenderKey);

        vm.prank(borrowerOwner);
        rollingLifecycle.exerciseRolling(agreementId);

        DirectTypes.DirectRollingAgreement memory afterState = rollingAgreements.getRollingAgreement(agreementId);
        assertEq(uint256(afterState.status), uint256(DirectTypes.DirectStatus.Exercised), "status exercised");
        assertEq(afterState.arrears, 0, "arrears cleared");
        assertEq(afterState.outstandingPrincipal, 0, "principal cleared");
        assertEq(views.directLocked(borrowerKey, afterState.collateralPoolId), 0, "collateral unlocked");

        // Debt covered from collateral: 120; refund: 80 (collateral 200)
        assertEq(
            views.getUserPrincipal(1, lenderKey) - lenderPrincipalBefore,
            120 ether,
            "lender receives arrears+principal"
        );
        assertEq(
            views.getUserPrincipal(1, borrowerKey),
            borrowerPrincipalBefore - 200 ether + 80 ether,
            "borrower refunded remainder"
        );
    }

    function testProperty_EarlyExerciseNotAllowedReverts() public {
        (uint256 agreementId,,) = _setupAgreement(false, false);
        vm.prank(borrowerOwner);
        vm.expectRevert(DirectError_EarlyExerciseNotAllowed.selector);
        rollingLifecycle.exerciseRolling(agreementId);
    }

    function testProperty_EarlyRepayAllowed() public {
        (uint256 agreementId, bytes32 lenderKey, bytes32 borrowerKey) = _setupAgreement(true, true);
        harness.setArrears(agreementId, 10 ether);
        asset.mint(borrowerOwner, 200 ether);

        uint256 lenderBalanceBefore = asset.balanceOf(lenderOwner);

        vm.startPrank(borrowerOwner);
        asset.approve(address(diamond), type(uint256).max);
        rollingLifecycle.repayRollingInFull(agreementId);
        vm.stopPrank();

        DirectTypes.DirectRollingAgreement memory afterState = rollingAgreements.getRollingAgreement(agreementId);
        assertEq(uint256(afterState.status), uint256(DirectTypes.DirectStatus.Repaid), "status repaid");
        assertEq(afterState.outstandingPrincipal, 0, "principal cleared");
        assertEq(afterState.arrears, 0, "arrears cleared");
        assertEq(views.directLocked(borrowerKey, afterState.collateralPoolId), 0, "collateral unlocked");
        assertEq(asset.balanceOf(lenderOwner) - lenderBalanceBefore, 110 ether, "lender paid principal+arrears");
        // Borrower pool principal remains the same; only locked flag cleared
        assertEq(views.getUserPrincipal(1, borrowerKey), 300 ether, "borrower deposits unchanged");
    }

    function testProperty_EarlyRepayNotAllowedReverts() public {
        (uint256 agreementId,,) = _setupAgreement(false, false);
        asset.mint(borrowerOwner, 200 ether);
        vm.startPrank(borrowerOwner);
        asset.approve(address(diamond), type(uint256).max);
        vm.expectRevert(DirectError_EarlyRepayNotAllowed.selector);
        rollingLifecycle.repayRollingInFull(agreementId);
        vm.stopPrank();
    }
}
