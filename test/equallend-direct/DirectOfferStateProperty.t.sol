// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {DirectError_InvalidOffer} from "../../src/libraries/Errors.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {NotNFTOwner} from "../../src/libraries/Errors.sol";
import {DirectDiamondTestBase} from "./DirectDiamondTestBase.sol";

/// @notice Feature: equallend-direct, Property 8: Offer state validation
/// @notice Validates: Requirements 2.9, 6.2
contract DirectOfferStatePropertyTest is DirectDiamondTestBase {
    MockERC20 internal asset;
    address internal lenderOwner = address(0xA11CE);
    address internal borrowerOwner = address(0xB0B);
    address internal stranger = address(0xCAFE);

    function setUp() public {
        setUpDiamond();
        asset = new MockERC20("Test Token", "TEST", 18, 1_000_000 ether);
    }

    function testProperty_OfferStateValidation() public {
        vm.warp(10 days);
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

        vm.expectRevert(DirectError_InvalidOffer.selector);
        vm.prank(stranger);
        offers.cancelOffer(999);

        vm.prank(lenderOwner);
        uint256 offerId = offers.postOffer(params);

        vm.expectRevert(abi.encodeWithSelector(NotNFTOwner.selector, stranger, lenderPositionId));
        vm.prank(stranger);
        offers.cancelOffer(offerId);

        vm.prank(borrowerOwner);
        uint256 agreementId = agreements.acceptOffer(offerId, borrowerPositionId);
        DirectTypes.DirectAgreement memory agreement = views.getAgreement(agreementId);
        assertTrue(agreement.interestRealizedUpfront);
        assertTrue(views.getOffer(offerId).filled);

        vm.expectRevert(DirectError_InvalidOffer.selector);
        vm.prank(borrowerOwner);
        agreements.acceptOffer(offerId, borrowerPositionId);

        vm.expectRevert(DirectError_InvalidOffer.selector);
        vm.prank(lenderOwner);
        offers.cancelOffer(offerId);

        vm.prank(lenderOwner);
        uint256 secondOffer = offers.postOffer(params);
        vm.prank(lenderOwner);
        offers.cancelOffer(secondOffer);
        vm.expectRevert(DirectError_InvalidOffer.selector);
        vm.prank(borrowerOwner);
        agreements.acceptOffer(secondOffer, borrowerPositionId);
        assertTrue(views.getOffer(secondOffer).cancelled);
    }
}
