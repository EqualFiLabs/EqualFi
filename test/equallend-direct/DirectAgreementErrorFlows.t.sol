// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {
    DirectError_EarlyExerciseNotAllowed,
    DirectError_EarlyRepayNotAllowed,
    DirectError_GracePeriodActive,
    DirectError_InvalidOffer
} from "../../src/libraries/Errors.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {DirectTestUtils} from "./DirectTestUtils.sol";
import {DirectDiamondTestBase} from "./DirectDiamondTestBase.sol";

contract DirectAgreementErrorFlowsTest is DirectDiamondTestBase {
    MockERC20 internal asset;

    address internal lenderOwner = address(0xA11CE);
    address internal borrowerOwner = address(0xB0B);
    address internal protocolTreasury = address(0xF00D);

    function setUp() public {
        setUpDiamond();
        asset = new MockERC20("Test Token", "TEST", 18, 5_000_000 ether);

        DirectTypes.DirectConfig memory cfg = DirectTypes.DirectConfig({
            platformFeeBps: 0,
            interestLenderBps: 10_000,
            platformFeeLenderBps: 0,
            defaultLenderBps: 10_000,
            minInterestDuration: 0
        });
        harness.setConfig(cfg);
    }

    function _postAndAccept(bool allowEarlyRepay, bool allowEarlyExercise)
        internal
        returns (uint256 agreementId, DirectTypes.DirectOfferParams memory params)
    {
        vm.warp(50 days);
        uint256 lenderPositionId = nft.mint(lenderOwner, 1);
        uint256 borrowerPositionId = nft.mint(borrowerOwner, 2);
        finalizePositionNFT();
        bytes32 lenderKey = nft.getPositionKey(lenderPositionId);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPositionId);
        harness.seedPoolWithMembership(1, address(asset), lenderKey, 300 ether, true);
        harness.seedPoolWithMembership(2, address(asset), borrowerKey, 200 ether, true);

        asset.transfer(lenderOwner, 300 ether);
        asset.transfer(borrowerOwner, 200 ether);
        vm.prank(lenderOwner);
        asset.approve(address(diamond), type(uint256).max);
        vm.prank(borrowerOwner);
        asset.approve(address(diamond), type(uint256).max);

        params = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPositionId,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(asset),
            borrowAsset: address(asset),
            principal: 50 ether,
            aprBps: 0,
            durationSeconds: 2 days,
            collateralLockAmount: 20 ether,
            allowEarlyRepay: allowEarlyRepay,
            allowEarlyExercise: allowEarlyExercise,
            allowLenderCall: false});

        vm.prank(lenderOwner);
        uint256 offerId = offers.postOffer(params);
        vm.prank(borrowerOwner);
        agreementId = agreements.acceptOffer(offerId, borrowerPositionId);
    }

    function testEarlyExercisePathBlockedWhenDisallowed() public {
        (uint256 agreementId,) = _postAndAccept(true, false);
        vm.prank(borrowerOwner);
        vm.expectRevert(DirectError_EarlyExerciseNotAllowed.selector);
        lifecycle.exerciseDirect(agreementId);
    }

    function testEarlyRepayPathBlockedWhenDisallowed() public {
        (uint256 agreementId,) = _postAndAccept(false, true);
        vm.prank(borrowerOwner);
        vm.expectRevert(DirectError_EarlyRepayNotAllowed.selector);
        lifecycle.repay(agreementId);
    }

    function testRecoverRespectsGraceWindow() public {
        (uint256 agreementId, DirectTypes.DirectOfferParams memory params) = _postAndAccept(false, false);
        uint256 acceptedAt = block.timestamp;

        vm.expectRevert(DirectError_GracePeriodActive.selector);
        lifecycle.recover(agreementId);

        vm.warp(acceptedAt + params.durationSeconds + 1 days + 1);
        lifecycle.recover(agreementId);
    }

    function testCannotAcceptCancelledOffer() public {
        vm.warp(60 days);
        uint256 lenderPositionId = nft.mint(lenderOwner, 1);
        uint256 borrowerPositionId = nft.mint(borrowerOwner, 2);
        finalizePositionNFT();
        bytes32 lenderKey = nft.getPositionKey(lenderPositionId);
        harness.seedPoolWithMembership(1, address(asset), lenderKey, 100 ether, true);
        harness.seedPoolWithMembership(2, address(asset), nft.getPositionKey(borrowerPositionId), 80 ether, true);
        asset.transfer(lenderOwner, 150 ether);
        asset.transfer(borrowerOwner, 50 ether);
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
            principal: 10 ether,
            aprBps: 1200,
            durationSeconds: 1 days,
            collateralLockAmount: 5 ether,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false});

        vm.prank(lenderOwner);
        uint256 offerId = offers.postOffer(params);
        vm.prank(lenderOwner);
        offers.cancelOffer(offerId);

        vm.prank(borrowerOwner);
        vm.expectRevert(DirectError_InvalidOffer.selector);
        agreements.acceptOffer(offerId, borrowerPositionId);
    }
}
