// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {
    DirectError_EarlyRepayNotAllowed,
    DirectError_GracePeriodExpired
} from "../../src/libraries/Errors.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {DirectTestUtils} from "./DirectTestUtils.sol";
import {DirectDiamondTestBase} from "./DirectDiamondTestBase.sol";

/// @notice Feature: direct-early-exercise-prepay, Property 2: Early repayment timing validation
/// @notice Validates: Requirements 1.2, 1.3, 3.4, 3.5
contract DirectRepayTimingPropertyTest is DirectDiamondTestBase {
    MockERC20 internal asset;
    address internal lenderOwner = address(0xA11CE);
    address internal borrowerOwner = address(0xB0B);

    function setUp() public {
        setUpDiamond();
        asset = new MockERC20("Test Token", "TEST", 18, 2_000_000 ether);

        DirectTypes.DirectConfig memory cfg = DirectTypes.DirectConfig({
            platformFeeBps: 0,
            interestLenderBps: 10_000,
            platformFeeLenderBps: 0,
            defaultLenderBps: 10_000,
            minInterestDuration: 0
        });
        harness.setConfig(cfg);
    }

    function testProperty_EarlyRepayTimingValidation() public {
        vm.warp(200 days);
        uint256 lenderPositionId = nft.mint(lenderOwner, 1);
        uint256 borrowerPositionId = nft.mint(borrowerOwner, 2);
        finalizePositionNFT();
        bytes32 lenderKey = nft.getPositionKey(lenderPositionId);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPositionId);

        harness.seedPoolWithMembership(1, address(asset), lenderKey, 500 ether, true);
        harness.seedPoolWithMembership(2, address(asset), borrowerKey, 40 ether, true);

        asset.transfer(lenderOwner, 500 ether);
        asset.transfer(borrowerOwner, 300 ether);
        vm.prank(lenderOwner);
        asset.approve(address(diamond), type(uint256).max);
        vm.prank(borrowerOwner);
        asset.approve(address(diamond), type(uint256).max);

        DirectTypes.DirectOfferParams memory disallowedParams = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPositionId,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(asset),
            borrowAsset: address(asset),
            principal: 100 ether,
            aprBps: 0,
            durationSeconds: 3 days,
            collateralLockAmount: 10 ether,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false});

        vm.prank(lenderOwner);
        uint256 offerId = offers.postOffer(disallowedParams);
        vm.prank(borrowerOwner);
        uint256 agreementId = agreements.acceptOffer(offerId, borrowerPositionId);
        uint256 acceptTimestamp = block.timestamp;
        uint256 dueTimestamp = DirectTestUtils.dueTimestamp(acceptTimestamp, disallowedParams.durationSeconds);

        vm.prank(borrowerOwner);
        vm.expectRevert(DirectError_EarlyRepayNotAllowed.selector);
        lifecycle.repay(agreementId);

        vm.warp(dueTimestamp - 12 hours);
        vm.prank(borrowerOwner);
        lifecycle.repay(agreementId);

        DirectTypes.DirectOfferParams memory allowedParams = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPositionId,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(asset),
            borrowAsset: address(asset),
            principal: 100 ether,
            aprBps: 0,
            durationSeconds: 3 days,
            collateralLockAmount: 10 ether,
            allowEarlyRepay: true,
            allowEarlyExercise: false,
            allowLenderCall: false});

        vm.prank(lenderOwner);
        uint256 allowedOfferId = offers.postOffer(allowedParams);
        vm.prank(borrowerOwner);
        uint256 allowedAgreementId = agreements.acceptOffer(allowedOfferId, borrowerPositionId);

        vm.prank(borrowerOwner);
        lifecycle.repay(allowedAgreementId);

        vm.prank(lenderOwner);
        uint256 expiredOfferId = offers.postOffer(allowedParams);
        vm.prank(borrowerOwner);
        uint256 expiredAgreementId = agreements.acceptOffer(expiredOfferId, borrowerPositionId);
        uint256 expiredDue = DirectTestUtils.dueTimestamp(block.timestamp, allowedParams.durationSeconds);

        vm.warp(expiredDue + 1 days + 1);
        vm.prank(borrowerOwner);
        vm.expectRevert(DirectError_GracePeriodExpired.selector);
        lifecycle.repay(expiredAgreementId);
    }
}

/// @notice Feature: direct-early-exercise-prepay, Property 4: Repayment functionality
/// @notice Validates: Requirements 3.1, 3.2, 3.3, 3.6
contract DirectRepayFunctionalityPropertyTest is DirectDiamondTestBase {
    MockERC20 internal asset;
    address internal lenderOwner = address(0xA11CE);
    address internal borrowerOwner = address(0xB0B);

    function setUp() public {
        setUpDiamond();
        asset = new MockERC20("Test Token", "TEST", 18, 2_000_000 ether);

        DirectTypes.DirectConfig memory cfg = DirectTypes.DirectConfig({
            platformFeeBps: 0,
            interestLenderBps: 10_000,
            platformFeeLenderBps: 0,
            defaultLenderBps: 10_000,
            minInterestDuration: 0
        });
        harness.setConfig(cfg);
    }

    function testProperty_RepayFunctionality() public {
        vm.warp(200 days);
        uint256 lenderPositionId = nft.mint(lenderOwner, 1);
        uint256 borrowerPositionId = nft.mint(borrowerOwner, 2);
        finalizePositionNFT();
        bytes32 lenderKey = nft.getPositionKey(lenderPositionId);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPositionId);

        harness.seedPoolWithMembership(1, address(asset), lenderKey, 500 ether, true);
        harness.seedPoolWithMembership(2, address(asset), borrowerKey, 20 ether, true);

        asset.transfer(lenderOwner, 500 ether);
        asset.transfer(borrowerOwner, 300 ether);
        vm.prank(lenderOwner);
        asset.approve(address(diamond), type(uint256).max);
        vm.prank(borrowerOwner);
        asset.approve(address(diamond), type(uint256).max);

        DirectTypes.DirectOfferParams memory params = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPositionId,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(asset),
            borrowAsset: address(asset),
            principal: 100 ether,
            aprBps: 800,
            durationSeconds: 3 days,
            collateralLockAmount: 10 ether,
            allowEarlyRepay: true,
            allowEarlyExercise: false,
            allowLenderCall: false});

        uint256 borrowerBalanceBefore = asset.balanceOf(borrowerOwner);

        vm.prank(lenderOwner);
        uint256 offerId = offers.postOffer(params);
        vm.prank(borrowerOwner);
        uint256 agreementId = agreements.acceptOffer(offerId, borrowerPositionId);

        uint256 interest = DirectTestUtils.annualizedInterest(params);

        vm.warp(block.timestamp + 1 hours);
        vm.prank(borrowerOwner);
        lifecycle.repay(agreementId);

        DirectTypes.DirectAgreement memory agreement = views.getAgreement(agreementId);
        assertEq(uint8(agreement.status), uint8(DirectTypes.DirectStatus.Repaid), "status repaid");

        assertEq(views.directLocked(borrowerKey, params.collateralPoolId), 0, "collateral unlocked");

        uint256 borrowerBalanceAfter = asset.balanceOf(borrowerOwner);
        assertEq(borrowerBalanceBefore - borrowerBalanceAfter, interest, "premium retained");
    }
}
