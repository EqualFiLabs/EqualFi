// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {
    DirectError_EarlyExerciseNotAllowed,
    DirectError_InvalidTimestamp
} from "../../src/libraries/Errors.sol";
import {LibAppStorage} from "../../src/libraries/LibAppStorage.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {LibPositionHelpers} from "../../src/libraries/LibPositionHelpers.sol";
import {DirectTestUtils} from "./DirectTestUtils.sol";
import {DirectDiamondTestBase} from "./DirectDiamondTestBase.sol";

/// @notice Feature: direct-early-exercise-prepay, Property 3: Early exercise functionality
/// @notice Validates: Requirements 1.4, 1.5, 2.1, 2.2, 2.3, 2.4
contract DirectExercisePropertyTest is DirectDiamondTestBase {
    MockERC20 internal asset;
    address internal lenderOwner = address(0xA11CE);
    address internal borrowerOwner = address(0xB0B);
    address internal protocolTreasury = address(0xF00D);
    uint16 internal treasurySplitBps;
    uint16 internal activeSplitBps;

    function setUp() public {
        setUpDiamond();
        asset = new MockERC20("Test Token", "TEST", 18, 2_000_000 ether);

        DirectTypes.DirectConfig memory cfg = DirectTypes.DirectConfig({
            platformFeeBps: 0,
            interestLenderBps: 10_000,
            platformFeeLenderBps: 0,
            defaultLenderBps: 7000,
            minInterestDuration: 0
        });
        harness.setConfig(cfg);
        treasurySplitBps = DirectTestUtils.treasurySplitFromLegacy(7000, 1000);
        activeSplitBps = DirectTestUtils.activeSplitFromLegacy(7000, 0);
        harness.setTreasuryShare(protocolTreasury, treasurySplitBps);
        harness.setActiveCreditShare(activeSplitBps);
    }

    function testProperty_EarlyExerciseFunctionality() public {
        vm.warp(200 days);
        uint256 lenderPositionId = nft.mint(lenderOwner, 1);
        uint256 borrowerPositionId = nft.mint(borrowerOwner, 2);
        finalizePositionNFT();
        bytes32 lenderKey = nft.getPositionKey(lenderPositionId);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPositionId);

        harness.seedPoolWithMembership(1, address(asset), lenderKey, 500 ether, true);
        harness.seedPoolWithMembership(2, address(asset), borrowerKey, 30 ether, true);

        asset.transfer(lenderOwner, 500 ether);
        asset.transfer(borrowerOwner, 50 ether);
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
            aprBps: 800,
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

        vm.prank(borrowerOwner);
        vm.expectRevert(DirectError_EarlyExerciseNotAllowed.selector);
        lifecycle.exerciseDirect(agreementId);

        DirectTypes.DirectOfferParams memory allowedParams = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPositionId,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(asset),
            borrowAsset: address(asset),
            principal: 100 ether,
            aprBps: 800,
            durationSeconds: 3 days,
            collateralLockAmount: 10 ether,
            allowEarlyRepay: false,
            allowEarlyExercise: true,
            allowLenderCall: false});

        vm.prank(lenderOwner);
        uint256 allowedOfferId = offers.postOffer(allowedParams);
        vm.prank(borrowerOwner);
        uint256 allowedAgreementId = agreements.acceptOffer(allowedOfferId, borrowerPositionId);

        vm.warp(acceptTimestamp + 1 days);
        uint256 lenderPrincipalBefore = LibAppStorage.s().pools[1].userPrincipal[lenderKey];
        uint256 borrowerPrincipalBefore = LibAppStorage.s().pools[2].userPrincipal[borrowerKey];
        uint256 feeIndexBefore = LibAppStorage.s().pools[2].feeIndex;
        uint256 trackedBefore = LibAppStorage.s().pools[2].trackedBalance;

        vm.prank(borrowerOwner);
        lifecycle.exerciseDirect(allowedAgreementId);

        DirectTypes.DirectAgreement memory agreement = views.getAgreement(allowedAgreementId);
        assertEq(uint8(agreement.status), uint8(DirectTypes.DirectStatus.Exercised), "status exercised");

        uint256 collateralAvailable = borrowerPrincipalBefore >= allowedParams.collateralLockAmount
            ? allowedParams.collateralLockAmount
            : borrowerPrincipalBefore;
        uint256 lenderShare = (collateralAvailable * 7000) / 10_000;
        uint256 remainder = collateralAvailable > lenderShare ? collateralAvailable - lenderShare : 0;
        (uint256 protocolShare, uint256 activeShare, uint256 feeIndexShare) =
            DirectTestUtils.previewSplit(remainder, treasurySplitBps, activeSplitBps, true);

        assertEq(
            LibAppStorage.s().pools[1].userPrincipal[lenderKey],
            lenderPrincipalBefore + lenderShare,
            "lender principal increased"
        );
        assertEq(
            LibAppStorage.s().pools[1].userPrincipal[LibPositionHelpers.systemPositionKey(protocolTreasury)],
            protocolShare,
            "protocol principal increased in lender pool"
        );
        assertEq(
            LibAppStorage.s().pools[2].userPrincipal[borrowerKey],
            borrowerPrincipalBefore - collateralAvailable,
            "borrower collateral deducted"
        );
        assertEq(
            LibAppStorage.s().pools[2].trackedBalance,
            trackedBefore - lenderShare - protocolShare + activeShare,
            "tracked reduced"
        );

        uint256 expectedDelta = collateralAvailable == 0
            ? 0
            : (feeIndexShare * 1e18) / LibAppStorage.s().pools[2].totalDeposits;
        assertEq(LibAppStorage.s().pools[2].feeIndex, feeIndexBefore + expectedDelta, "fee index accrues");

        vm.prank(lenderOwner);
        uint256 lateOfferId = offers.postOffer(allowedParams);
        vm.prank(borrowerOwner);
        uint256 lateAgreementId = agreements.acceptOffer(lateOfferId, borrowerPositionId);
        uint256 lateAcceptTimestamp = block.timestamp;

        vm.warp(DirectTestUtils.dueTimestamp(lateAcceptTimestamp, allowedParams.durationSeconds) + 1 days + 1);
        vm.prank(borrowerOwner);
        vm.expectRevert(DirectError_InvalidTimestamp.selector);
        lifecycle.exerciseDirect(lateAgreementId);
    }
}
