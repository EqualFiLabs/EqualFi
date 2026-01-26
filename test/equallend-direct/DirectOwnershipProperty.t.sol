// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {NotNFTOwner} from "../../src/libraries/Errors.sol";
import {DirectError_InvalidOffer} from "../../src/libraries/Errors.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {DirectDiamondTestBase} from "./DirectDiamondTestBase.sol";

/// @notice Feature: equallend-direct, Property 1: Ownership validation consistency
/// @notice Validates: Requirements 1.1, 2.1, 6.1
/// forge-config: default.fuzz.runs = 100
contract DirectOwnershipPropertyTest is DirectDiamondTestBase {
    MockERC20 internal asset;

    address internal lenderOwner = address(0xA11CE);
    address internal borrowerOwner = address(0xB0B);
    address internal nonOwner = address(0xCAFE);

    function setUp() public {
        setUpDiamond();
        asset = new MockERC20("Test Token", "TEST", 18, 1_000_000 ether);
    }

    function _finalizeDiamondMinter() internal {
        nft.setDiamond(address(diamond));
        nft.setMinter(address(diamond));
    }

    function testProperty_OwnershipValidationConsistency() public {
        vm.warp(1 days);
        uint256 lenderPositionId = nft.mint(lenderOwner, 1);
        uint256 borrowerPositionId = nft.mint(borrowerOwner, 2);
        _finalizeDiamondMinter();
        bytes32 lenderKey = nft.getPositionKey(lenderPositionId);

        harness.seedPoolWithMembership(1, address(asset), lenderKey, 100 ether, true);
        harness.seedPoolWithMembership(2, address(asset), nft.getPositionKey(borrowerPositionId), 50 ether, true);

        DirectTypes.DirectOfferParams memory params = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPositionId,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(asset),
            borrowAsset: address(asset),
            principal: 1 ether,
            aprBps: 500,
            durationSeconds: 1 days,
            collateralLockAmount: 1 ether,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false
        });

        asset.transfer(lenderOwner, 10 ether);
        asset.transfer(borrowerOwner, 5 ether);
        vm.prank(lenderOwner);
        asset.approve(address(diamond), type(uint256).max);
        vm.prank(borrowerOwner);
        asset.approve(address(diamond), type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(NotNFTOwner.selector, nonOwner, lenderPositionId));
        vm.prank(nonOwner);
        offers.postOffer(params);

        vm.prank(lenderOwner);
        uint256 offerId = offers.postOffer(params);

        vm.expectRevert(abi.encodeWithSelector(NotNFTOwner.selector, nonOwner, lenderPositionId));
        vm.prank(nonOwner);
        offers.cancelOffer(offerId);

        vm.prank(lenderOwner);
        offers.cancelOffer(offerId);

        vm.prank(lenderOwner);
        uint256 offerIdForAccept = offers.postOffer(params);

        vm.expectRevert(abi.encodeWithSelector(NotNFTOwner.selector, nonOwner, borrowerPositionId));
        vm.prank(nonOwner);
        agreements.acceptOffer(offerIdForAccept, borrowerPositionId);

        vm.prank(borrowerOwner);
        uint256 agreementId = agreements.acceptOffer(offerIdForAccept, borrowerPositionId);

        DirectTypes.DirectAgreement memory agreement = views.getAgreement(agreementId);
        assertEq(agreement.borrower, borrowerOwner);
        assertEq(agreement.borrowerPositionId, borrowerPositionId);
        assertEq(agreement.lender, lenderOwner);
    }

    function test_acceptOfferRevertsWhenBorrowerUsesLenderPosition() public {
        uint256 lenderPositionId = nft.mint(lenderOwner, 1);
        _finalizeDiamondMinter();
        bytes32 positionKey = nft.getPositionKey(lenderPositionId);
        harness.seedPoolWithMembership(1, address(asset), positionKey, 100 ether, true);
        harness.seedPoolWithMembership(2, address(asset), positionKey, 50 ether, true);

        DirectTypes.DirectOfferParams memory params = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPositionId,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(asset),
            borrowAsset: address(asset),
            principal: 1 ether,
            aprBps: 500,
            durationSeconds: 1 days,
            collateralLockAmount: 1 ether,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false
        });

        vm.prank(lenderOwner);
        uint256 offerId = offers.postOffer(params);

        vm.expectRevert(DirectError_InvalidOffer.selector);
        vm.prank(lenderOwner);
        agreements.acceptOffer(offerId, lenderPositionId);
    }

    function test_acceptBorrowerOfferRevertsWhenLenderUsesBorrowerPosition() public {
        uint256 positionId = nft.mint(lenderOwner, 1);
        _finalizeDiamondMinter();
        bytes32 positionKey = nft.getPositionKey(positionId);
        harness.seedPoolWithMembership(1, address(asset), positionKey, 100 ether, true);
        harness.seedPoolWithMembership(2, address(asset), positionKey, 50 ether, true);

        DirectTypes.DirectBorrowerOfferParams memory params = DirectTypes.DirectBorrowerOfferParams({
            borrowerPositionId: positionId,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(asset),
            borrowAsset: address(asset),
            principal: 1 ether,
            aprBps: 500,
            durationSeconds: 1 days,
            collateralLockAmount: 1 ether,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false
        });

        vm.prank(lenderOwner);
        uint256 offerId = offers.postBorrowerOffer(params);

        vm.expectRevert(DirectError_InvalidOffer.selector);
        vm.prank(lenderOwner);
        agreements.acceptBorrowerOffer(offerId, positionId);
    }
}
