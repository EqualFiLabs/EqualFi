// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectDiamondTestBase} from "./DirectDiamondTestBase.sol";
import {EqualLendDirectRollingOfferFacet} from "../../src/equallend-direct/EqualLendDirectRollingOfferFacet.sol";
import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

/// @notice Feature: p2p-rolling-loans, Property 2: Rolling Agreement Initialization Correctness (offer creation preconditions)
/// @notice Validates: Requirements 1.1, 1.2, 1.3, 1.5, 2.1, 2.2, 2.3
/// forge-config: default.fuzz.runs = 100
contract DirectRollingOfferPropertyTest is DirectDiamondTestBase {
    MockERC20 internal asset;
    address internal lenderOwner = address(0xA11CE);
    address internal borrowerOwner = address(0xB0B);

    function setUp() public {
        setUpDiamond();
        asset = new MockERC20("Test Token", "TEST", 18, 2_000_000 ether);

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

    function testProperty_RollingOfferCreationAndStorage() public {
        uint256 lenderPositionId = nft.mint(lenderOwner, 1);
        uint256 borrowerPositionId = nft.mint(borrowerOwner, 2);
        finalizePositionNFT();
        bytes32 lenderKey = nft.getPositionKey(lenderPositionId);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPositionId);

        harness.seedPoolWithMembership(1, address(asset), lenderKey, 500 ether, true);
        harness.seedPoolWithMembership(2, address(asset), borrowerKey, 100 ether, true);

        uint256 offerId = _postLenderRollingOffer(lenderPositionId);
        _assertLenderOfferStored(offerId, lenderKey);

        uint256 borrowerOfferId = _postBorrowerRollingOffer(borrowerPositionId);
        _assertBorrowerOfferStored(borrowerOfferId, borrowerKey);
    }

    /// @notice Feature: p2p-rolling-loans, Property 9: Event Emission Completeness (offer posting)
    /// @notice Validates: Requirements 1.4, 8.1
    function testProperty_RollingOfferEvents() public {
        uint256 lenderPositionId = nft.mint(lenderOwner, 3);
        finalizePositionNFT();
        bytes32 lenderKey = nft.getPositionKey(lenderPositionId);
        harness.seedPoolWithMembership(3, address(asset), lenderKey, 300 ether, true);

        _expectRollingOfferPosted(lenderPositionId);
        vm.prank(lenderOwner);
        rollingOffers.postRollingOffer(_rollingOfferParamsForEvents(lenderPositionId));
    }

    function _postLenderRollingOffer(uint256 lenderPositionId) internal returns (uint256 offerId) {
        DirectTypes.DirectRollingOfferParams memory offerParams = DirectTypes.DirectRollingOfferParams({
            lenderPositionId: lenderPositionId,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(asset),
            borrowAsset: address(asset),
            principal: 100 ether,
            collateralLockAmount: 20 ether,
            paymentIntervalSeconds: 604_800,
            rollingApyBps: 800,
            gracePeriodSeconds: 604_000,
            maxPaymentCount: 520,
            upfrontPremium: 10 ether,
            allowAmortization: true,
            allowEarlyRepay: true,
            allowEarlyExercise: false
        });

        vm.prank(lenderOwner);
        offerId = rollingOffers.postRollingOffer(offerParams);
    }

    function _assertLenderOfferStored(uint256 offerId, bytes32 lenderKey) internal {
        DirectTypes.DirectRollingOffer memory storedOffer = rollingOffers.getRollingOffer(offerId);
        assertTrue(storedOffer.isRolling, "rolling flag set");
        assertEq(storedOffer.allowAmortization, true, "amortization flag stored");
        assertEq(storedOffer.allowEarlyRepay, true, "allowEarlyRepay stored");
        assertEq(storedOffer.allowEarlyExercise, false, "allowEarlyExercise stored");
        assertEq(storedOffer.rollingApyBps, 800, "rolling APY stored");
        assertEq(storedOffer.paymentIntervalSeconds, 604_800, "payment interval stored");
        assertEq(storedOffer.maxPaymentCount, 520, "max payment count stored");
        assertEq(storedOffer.upfrontPremium, 10 ether, "upfront premium stored");
        assertEq(views.offerEscrow(lenderKey, 1), 100 ether, "escrow increased");
    }

    function _postBorrowerRollingOffer(uint256 borrowerPositionId) internal returns (uint256 offerId) {
        DirectTypes.DirectRollingBorrowerOfferParams memory borrowerParams = DirectTypes.DirectRollingBorrowerOfferParams({
            borrowerPositionId: borrowerPositionId,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(asset),
            borrowAsset: address(asset),
            principal: 50 ether,
            collateralLockAmount: 25 ether,
            paymentIntervalSeconds: 604_800,
            rollingApyBps: 750,
            gracePeriodSeconds: 604_000,
            maxPaymentCount: 520,
            upfrontPremium: 5 ether,
            allowAmortization: false,
            allowEarlyRepay: true,
            allowEarlyExercise: true
        });

        vm.prank(borrowerOwner);
        offerId = rollingOffers.postBorrowerRollingOffer(borrowerParams);
    }

    function _assertBorrowerOfferStored(uint256 borrowerOfferId, bytes32 borrowerKey) internal {
        DirectTypes.DirectRollingBorrowerOffer memory storedBorrowerOffer = rollingOffers.getRollingBorrowerOffer(borrowerOfferId);
        assertTrue(storedBorrowerOffer.isRolling, "borrower rolling flag set");
        assertEq(storedBorrowerOffer.allowAmortization, false, "borrower amortization flag stored");
        assertEq(storedBorrowerOffer.allowEarlyRepay, true, "borrower allowEarlyRepay stored");
        assertEq(
            views.directLocked(borrowerKey, 2),
            25 ether,
            "collateral locked"
        );
    }

    function _rollingOfferParamsForEvents(uint256 lenderPositionId)
        internal
        view
        returns (DirectTypes.DirectRollingOfferParams memory)
    {
        return DirectTypes.DirectRollingOfferParams({
            lenderPositionId: lenderPositionId,
            lenderPoolId: 3,
            collateralPoolId: 3,
            collateralAsset: address(asset),
            borrowAsset: address(asset),
            principal: 50 ether,
            collateralLockAmount: 5 ether,
            paymentIntervalSeconds: 604_800,
            rollingApyBps: 600,
            gracePeriodSeconds: 604_000,
            maxPaymentCount: 400,
            upfrontPremium: 2 ether,
            allowAmortization: true,
            allowEarlyRepay: false,
            allowEarlyExercise: false
        });
    }

    function _expectRollingOfferPosted(uint256 lenderPositionId) internal {
        uint256 expectedOfferId = 1; // first rolling offer uses pre-incremented counter
        vm.expectEmit(true, true, true, true);
        emit EqualLendDirectRollingOfferFacet.RollingOfferPosted(
            expectedOfferId,
            address(asset),
            3,
            lenderOwner,
            lenderPositionId,
            3,
            address(asset),
            50 ether,
            604_800,
            600,
            604_000,
            400,
            2 ether,
            true,
            false,
            false,
            5 ether
        );
    }
}
