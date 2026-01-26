// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {DirectDiamondTestBase} from "./DirectDiamondTestBase.sol";

/// @notice Feature: direct-early-exercise-prepay, Property 1: Offer configuration storage
/// @notice Validates: Requirements 1.1
contract DirectOfferConfigPropertyTest is DirectDiamondTestBase {
    MockERC20 internal asset;
    address internal lenderOwner = address(0xA11CE);
    address internal borrowerOwner = address(0xB0B);

    function setUp() public {
        setUpDiamond();
        asset = new MockERC20("Test Token", "TEST", 18, 2_000_000 ether);

        harness.setConfig(
            DirectTypes.DirectConfig({
                platformFeeBps: 0,
                interestLenderBps: 10_000,
                platformFeeLenderBps: 0,
                defaultLenderBps: 10_000,
                minInterestDuration: 0
            })
        );
    }

    function _finalizeDiamondMinter() internal {
        nft.setDiamond(address(diamond));
        nft.setMinter(address(diamond));
    }

    function testProperty_OfferConfigurationStorage() public {
        uint256 lenderPositionId = nft.mint(lenderOwner, 1);
        uint256 borrowerPositionId = nft.mint(borrowerOwner, 2);
        _finalizeDiamondMinter();
        bytes32 lenderKey = nft.getPositionKey(lenderPositionId);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPositionId);

        harness.seedPoolWithMembership(1, address(asset), lenderKey, 500 ether, true);
        harness.seedPoolWithMembership(2, address(asset), borrowerKey, 20 ether, true);

        DirectTypes.DirectOfferParams memory offerParams = DirectTypes.DirectOfferParams({
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
            allowLenderCall: false
        });

        vm.prank(lenderOwner);
        uint256 offerId = offers.postOffer(offerParams, DirectTypes.DirectTrancheOfferParams({isTranche: false, trancheAmount: 0}));
        DirectTypes.DirectOffer memory offer = views.getOffer(offerId);
        assertEq(offer.allowEarlyRepay, true, "offer allowEarlyRepay stored");
        assertEq(offer.allowEarlyExercise, false, "offer allowEarlyExercise stored");

        DirectTypes.DirectBorrowerOfferParams memory borrowerParams = DirectTypes.DirectBorrowerOfferParams({
            borrowerPositionId: borrowerPositionId,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(asset),
            borrowAsset: address(asset),
            principal: 50 ether,
            aprBps: 900,
            durationSeconds: 2 days,
            collateralLockAmount: 10 ether,
            allowEarlyRepay: false,
            allowEarlyExercise: true,
            allowLenderCall: false
        });

        vm.prank(borrowerOwner);
        uint256 borrowerOfferId = offers.postBorrowerOffer(borrowerParams);
        DirectTypes.DirectBorrowerOffer memory borrowerOffer = views.getBorrowerOffer(borrowerOfferId);
        assertEq(borrowerOffer.allowEarlyRepay, false, "borrower offer allowEarlyRepay stored");
        assertEq(borrowerOffer.allowEarlyExercise, true, "borrower offer allowEarlyExercise stored");
    }
}
