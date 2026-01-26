// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {DirectError_InvalidAgreementState, DirectError_GracePeriodActive} from "../../src/libraries/Errors.sol";
import {PositionNFT} from "../../src/nft/PositionNFT.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {DirectDiamondTestBase} from "./DirectDiamondTestBase.sol";
import {DirectTestUtils} from "./DirectTestUtils.sol";

/// @notice Feature: equallend-direct, Property 5: Agreement lifecycle integrity
/// @notice Validates: Requirements 3.5, 4.5, 6.3
contract DirectAgreementLifecyclePropertyTest is DirectDiamondTestBase {
    MockERC20 internal asset;
    MockERC20 internal otherAsset;

    address internal lenderOwner = address(0xA11CE);
    address internal borrowerOwner = address(0xB0B);
    address internal protocolTreasury = address(0xF00D);

    function setUp() public {
        setUpDiamond();
        asset = new MockERC20("Test Token", "TEST", 18, 5_000_000 ether);
        otherAsset = new MockERC20("Other Token", "OTHR", 18, 5_000_000 ether);

        DirectTypes.DirectConfig memory cfg = DirectTypes.DirectConfig({
            platformFeeBps: 500,
            interestLenderBps: 10_000,
            platformFeeLenderBps: 5000,
            defaultLenderBps: 10_000,
            minInterestDuration: 0
        });
        harness.setConfig(cfg);
        harness.setTreasuryShare(protocolTreasury, DirectTestUtils.treasurySplitFromLegacy(5000, 2000));
        harness.setActiveCreditShare(DirectTestUtils.activeSplitFromLegacy(5000, 0));
    }

    function testProperty_AgreementLifecycleIntegrity() public {
        vm.warp(100 days);
        uint256 lenderPositionId = nft.mint(lenderOwner, 1);
        uint256 borrowerPositionId = nft.mint(borrowerOwner, 2);
        finalizePositionNFT();
        bytes32 lenderKey = nft.getPositionKey(lenderPositionId);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPositionId);
        harness.seedPoolWithMembership(1, address(asset), lenderKey, 500 ether, true);
        harness.seedPoolWithMembership(2, address(asset), borrowerKey, 400 ether, true);

        asset.transfer(lenderOwner, 500 ether);
        asset.transfer(borrowerOwner, 200 ether);
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
            aprBps: 1200,
            durationSeconds: 3 days,
            collateralLockAmount: 40 ether,
            allowEarlyRepay: true,
            allowEarlyExercise: false,
            allowLenderCall: false});

        vm.prank(lenderOwner);
        uint256 offerId = offers.postOffer(params);
        vm.prank(borrowerOwner);
        uint256 agreementId = agreements.acceptOffer(offerId, borrowerPositionId);
        uint256 acceptTimestamp = block.timestamp;

        DirectTypes.DirectAgreement memory agreement = views.getAgreement(agreementId);
        assertEq(uint8(agreement.status), uint8(DirectTypes.DirectStatus.Active));

        (uint256 borrowerLocked, uint256 borrowerLent) =
            views.getPositionDirectState(borrowerPositionId, params.collateralPoolId);
        assertEq(borrowerLocked, params.collateralLockAmount, "collateral locked");
        assertEq(borrowerLent, 0, "borrower lent remains zero");
        (, uint256 lenderLent) = views.getPositionDirectState(lenderPositionId, params.lenderPoolId);
        assertEq(lenderLent, params.principal, "lent tracked");

        uint256 lenderBefore = asset.balanceOf(lenderOwner);
        uint256 borrowerBefore = asset.balanceOf(borrowerOwner);

        vm.prank(borrowerOwner);
        lifecycle.repay(agreementId);
        agreement = views.getAgreement(agreementId);
        assertEq(uint8(agreement.status), uint8(DirectTypes.DirectStatus.Repaid), "repaid status");

        (borrowerLocked, borrowerLent) =
            views.getPositionDirectState(borrowerPositionId, params.collateralPoolId);
        assertEq(borrowerLocked, 0, "collateral unlocked");
        assertEq(borrowerLent, 0, "borrower lent cleared");
        (, lenderLent) = views.getPositionDirectState(lenderPositionId, params.lenderPoolId);
        assertEq(lenderLent, 0, "lent cleared");
        assertEq(asset.balanceOf(lenderOwner), lenderBefore, "lender balance unchanged on repay");
        assertEq(asset.balanceOf(borrowerOwner), borrowerBefore - params.principal, "borrower paid principal");

        vm.expectRevert(DirectError_InvalidAgreementState.selector);
        vm.prank(borrowerOwner);
        lifecycle.repay(agreementId);

        // New agreement to exercise default path
        params.durationSeconds = 1 days;
        vm.prank(lenderOwner);
        offerId = offers.postOffer(params);
        vm.prank(borrowerOwner);
        agreementId = agreements.acceptOffer(offerId, borrowerPositionId);
        acceptTimestamp = block.timestamp;
        vm.expectRevert(DirectError_GracePeriodActive.selector);
        lifecycle.recover(agreementId);

        vm.warp(acceptTimestamp + params.durationSeconds + 1 days);
        vm.prank(lenderOwner);
        lifecycle.recover(agreementId);

        agreement = views.getAgreement(agreementId);
        assertEq(uint8(agreement.status), uint8(DirectTypes.DirectStatus.Defaulted), "defaulted status");

        (borrowerLocked, borrowerLent) =
            views.getPositionDirectState(borrowerPositionId, params.collateralPoolId);
        assertEq(borrowerLocked, 0, "locked cleared on default");
        assertEq(borrowerLent, 0, "borrower lent cleared on default");
        (, lenderLent) = views.getPositionDirectState(lenderPositionId, params.lenderPoolId);
        assertEq(lenderLent, 0, "lender lent cleared on default");
    }

    function test_crossAssetDefaultKeepsLenderPrincipalAndCreditsCollateralPool() public {
        vm.warp(200 days);
        uint256 lenderPositionId = nft.mint(lenderOwner, 1);
        uint256 borrowerPositionId = nft.mint(borrowerOwner, 2);
        finalizePositionNFT();
        bytes32 lenderKey = nft.getPositionKey(lenderPositionId);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPositionId);
        harness.seedPoolWithLtv(1, address(asset), lenderKey, 500 ether, 10_000, true);
        harness.seedPoolWithLtv(2, address(otherAsset), borrowerKey, 400 ether, 10_000, true);

        asset.transfer(lenderOwner, 500 ether);
        asset.transfer(borrowerOwner, 200 ether);
        vm.prank(lenderOwner);
        asset.approve(address(diamond), type(uint256).max);
        vm.prank(borrowerOwner);
        asset.approve(address(diamond), type(uint256).max);
        vm.prank(borrowerOwner);
        otherAsset.approve(address(diamond), type(uint256).max);

        DirectTypes.DirectOfferParams memory params = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPositionId,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(otherAsset),
            borrowAsset: address(asset),
            principal: 100 ether,
            aprBps: 0,
            durationSeconds: 1 days,
            collateralLockAmount: 120 ether,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false});

        vm.prank(lenderOwner);
        uint256 offerId = offers.postOffer(params);
        vm.prank(borrowerOwner);
        uint256 agreementId = agreements.acceptOffer(offerId, borrowerPositionId);

        // Locked collateral reduces withdrawable collateral in the collateral pool (not treated as debt)
        assertEq(views.getTotalDebt(2, borrowerKey), 0, "collateral lock excluded from debt");
        (uint256 borrowerLocked,) = views.getPositionDirectState(borrowerPositionId, params.collateralPoolId);
        assertEq(borrowerLocked, params.collateralLockAmount, "collateral locked");
        uint256 collateralEscrow = views.getDirectOfferEscrow(2, borrowerKey);
        assertEq(collateralEscrow, 0, "no collateral offer escrow for borrower");
        uint256 withdrawable = views.getWithdrawablePrincipal(2, borrowerKey);
        uint256 borrowerPrincipal = views.getUserPrincipal(2, borrowerKey);
        assertEq(
            withdrawable + params.collateralLockAmount,
            borrowerPrincipal,
            "collateral lock encumbers principal"
        );
        assertEq(views.getActiveDirectLent(1), params.principal, "active lent tracked");

        vm.warp(block.timestamp + params.durationSeconds + 1 days);
        vm.prank(lenderOwner);
        lifecycle.recover(agreementId);

        assertEq(views.getUserPrincipal(2, borrowerKey), 280 ether, "borrower collateral reduced");
        assertEq(views.getUserPrincipal(2, lenderKey), 120 ether, "lender credited in collateral pool");
        assertTrue(views.isMember(lenderKey, 2), "lender joined collateral pool");

        assertEq(views.getUserPrincipal(1, lenderKey), 400 ether, "lender principal written off in borrow pool");

        (, uint256 lentAfter) = views.getPositionDirectState(lenderPositionId, params.lenderPoolId);
        assertEq(lentAfter, 0, "lender lent cleared");
        assertEq(views.getActiveDirectLent(1), 0, "active lent cleared");
    }

    function test_crossAssetDefaultShortfallWritesDownLenderPrincipal() public {
        vm.warp(300 days);
        uint256 lenderPositionId = nft.mint(lenderOwner, 1);
        uint256 borrowerPositionId = nft.mint(borrowerOwner, 2);
        finalizePositionNFT();
        bytes32 lenderKey = nft.getPositionKey(lenderPositionId);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPositionId);
        harness.seedPoolWithMembership(1, address(asset), lenderKey, 500 ether, true);
        harness.seedPoolWithMembership(2, address(otherAsset), borrowerKey, 50 ether, true);

        asset.transfer(lenderOwner, 500 ether);
        asset.transfer(borrowerOwner, 200 ether);
        vm.prank(lenderOwner);
        asset.approve(address(diamond), type(uint256).max);
        vm.prank(borrowerOwner);
        asset.approve(address(diamond), type(uint256).max);
        vm.prank(borrowerOwner);
        otherAsset.approve(address(diamond), type(uint256).max);

        DirectTypes.DirectOfferParams memory params = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPositionId,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(otherAsset),
            borrowAsset: address(asset),
            principal: 100 ether,
            aprBps: 0,
            durationSeconds: 1 days,
            collateralLockAmount: 30 ether,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false});

        vm.prank(lenderOwner);
        uint256 offerId = offers.postOffer(params);
        vm.prank(borrowerOwner);
        uint256 agreementId = agreements.acceptOffer(offerId, borrowerPositionId);

        vm.warp(block.timestamp + params.durationSeconds + 1 days);
        vm.prank(lenderOwner);
        lifecycle.recover(agreementId);

        assertEq(views.getUserPrincipal(2, borrowerKey), 20 ether, "borrower collateral reduced");
        assertEq(views.getUserPrincipal(2, lenderKey), 30 ether, "lender credited collateral");

        assertEq(views.getUserPrincipal(1, lenderKey), 400 ether, "lender principal written down by full principal");
        assertEq(views.getActiveDirectLent(1), 0, "active lent cleared on default");
    }

    function test_crossAssetPlatformFeeAccruesToBorrowPool() public {
        vm.warp(400 days);
        uint256 lenderPositionId = nft.mint(lenderOwner, 1);
        uint256 borrowerPositionId = nft.mint(borrowerOwner, 2);
        finalizePositionNFT();
        bytes32 lenderKey = nft.getPositionKey(lenderPositionId);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPositionId);
        harness.seedPoolWithMembership(1, address(asset), lenderKey, 500 ether, true);
        harness.seedPoolWithMembership(2, address(otherAsset), borrowerKey, 400 ether, true);

        asset.transfer(lenderOwner, 500 ether);
        asset.transfer(borrowerOwner, 200 ether);
        vm.prank(lenderOwner);
        asset.approve(address(diamond), type(uint256).max);
        vm.prank(borrowerOwner);
        asset.approve(address(diamond), type(uint256).max);

        DirectTypes.DirectOfferParams memory params = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPositionId,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(otherAsset),
            borrowAsset: address(asset),
            principal: 100 ether,
            aprBps: 0,
            durationSeconds: 3 days,
            collateralLockAmount: 40 ether,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false});

        vm.prank(lenderOwner);
        uint256 offerId = offers.postOffer(params);
        uint256 feeIndexBefore = views.getFeeIndex(1);
        uint256 trackedBefore = views.getTrackedBalance(1);
        uint256 collateralFeeIndexBefore = views.getFeeIndex(2);
        vm.prank(borrowerOwner);
        agreements.acceptOffer(offerId, borrowerPositionId);

        uint256 platformFee = (params.principal * 500) / 10_000;
        uint256 lenderPlatformShare = (platformFee * 5000) / 10_000;
        uint256 feeIndexShare = (platformFee * 3000) / 10_000;
        assertEq(
            views.getTrackedBalance(1),
            trackedBefore - params.principal + lenderPlatformShare + feeIndexShare,
            "tracked balance debited then fee added"
        );
        assertGt(views.getFeeIndex(1), feeIndexBefore, "fee index advanced in borrow pool");
        assertEq(views.getFeeIndex(2), collateralFeeIndexBefore, "collateral pool fee index unchanged");
    }
}
