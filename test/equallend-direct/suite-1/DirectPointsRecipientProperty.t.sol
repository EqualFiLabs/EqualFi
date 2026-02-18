// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectTypes} from "../../../src/libraries/DirectTypes.sol";
import {LibPoints} from "../../../src/libraries/LibPoints.sol";
import {MockERC20} from "../../../src/mocks/MockERC20.sol";
import {DirectTestUtils} from "../DirectTestUtils.sol";
import {DirectDiamondTestBase} from "../DirectDiamondTestBase.sol";

/// @notice Property: Direct accept operator calls credit points to position owner
/// @notice Validates: point-system requirements 2.4, 2.5, 7.2
contract DirectPointsRecipientPropertyTest is DirectDiamondTestBase {
    MockERC20 internal asset;

    address internal lenderOwner = address(0xA11CE);
    address internal borrowerOwner = address(0xB0B);
    address internal operator = address(0x0B0);
    address internal protocolTreasury = address(0xF00D);

    uint256 internal constant ACCEPT_POINTS = 17;

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
        harness.setTreasuryShare(protocolTreasury, DirectTestUtils.treasurySplitFromLegacy(7000, 1000));
        harness.setActiveCreditShare(DirectTestUtils.activeSplitFromLegacy(7000, 0));
        harness.setPointsPerAction(LibPoints.ACTION_DIRECT_ACCEPT_LENDER_OFFER, ACCEPT_POINTS);
        harness.setPointsPerAction(LibPoints.ACTION_DIRECT_ACCEPT_ROLLING_OFFER, ACCEPT_POINTS);
        harness.setDailyPointsCap(0);

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
    }

    function _finalizeMinter() internal {
        nft.setDiamond(address(diamond));
        nft.setMinter(address(diamond));
    }

    function testProperty_AcceptOfferOperatorAccruesToOwner() public {
        vm.warp(200 days);

        uint256 lenderPositionId = nft.mint(lenderOwner, 1);
        uint256 borrowerPositionId = nft.mint(borrowerOwner, 2);
        _finalizeMinter();

        bytes32 lenderKey = nft.getPositionKey(lenderPositionId);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPositionId);

        harness.seedPoolWithMembership(1, address(asset), lenderKey, 500 ether, true);
        harness.seedPoolWithMembership(2, address(asset), borrowerKey, 200 ether, true);

        DirectTypes.DirectOfferParams memory params = DirectTypes.DirectOfferParams({
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
            allowEarlyExercise: true,
            allowLenderCall: false
        });

        vm.prank(lenderOwner);
        uint256 offerId =
            offers.postOffer(params, DirectTypes.DirectTrancheOfferParams({isTranche: false, trancheAmount: 0}));

        vm.prank(borrowerOwner);
        nft.approve(operator, borrowerPositionId);

        uint256 ownerPointsBefore = harness.pointsBalanceByKey(borrowerKey);
        uint256 operatorPointsBefore = harness.pointsBalance(operator);

        vm.prank(operator);
        uint256 agreementId = agreements.acceptOffer(offerId, borrowerPositionId, 0);

        assertEq(harness.pointsBalanceByKey(borrowerKey), ownerPointsBefore + ACCEPT_POINTS);
        assertEq(harness.pointsBalance(operator), operatorPointsBefore);
        assertEq(views.getAgreement(agreementId).borrower, borrowerOwner);
    }

    function testProperty_AcceptOfferSelfMatchDoesNotAccruePoints() public {
        address selfOwner = address(0xCAFE);

        uint256 lenderPositionId = nft.mint(selfOwner, 11);
        uint256 borrowerPositionId = nft.mint(selfOwner, 12);
        _finalizeMinter();

        bytes32 lenderKey = nft.getPositionKey(lenderPositionId);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPositionId);

        harness.seedPoolWithMembership(1, address(asset), lenderKey, 500 ether, true);
        harness.seedPoolWithMembership(2, address(asset), borrowerKey, 200 ether, true);

        DirectTypes.DirectOfferParams memory params = DirectTypes.DirectOfferParams({
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
            allowEarlyExercise: true,
            allowLenderCall: false
        });

        vm.prank(selfOwner);
        uint256 offerId =
            offers.postOffer(params, DirectTypes.DirectTrancheOfferParams({isTranche: false, trancheAmount: 0}));

        uint256 pointsBefore = harness.pointsBalanceByKey(borrowerKey);
        vm.prank(selfOwner);
        agreements.acceptOffer(offerId, borrowerPositionId, 0);

        assertEq(harness.pointsBalanceByKey(borrowerKey), pointsBefore);
    }

    function testProperty_AcceptRollingOfferSelfMatchDoesNotAccruePoints() public {
        address selfOwner = address(0xD00D);

        uint256 lenderPositionId = nft.mint(selfOwner, 21);
        uint256 borrowerPositionId = nft.mint(selfOwner, 22);
        _finalizeMinter();

        bytes32 lenderKey = nft.getPositionKey(lenderPositionId);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPositionId);

        harness.seedPoolWithMembership(1, address(asset), lenderKey, 1_000 ether, true);
        harness.seedPoolWithMembership(2, address(asset), borrowerKey, 300 ether, true);

        DirectTypes.DirectRollingOfferParams memory params = DirectTypes.DirectRollingOfferParams({
            lenderPositionId: lenderPositionId,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(asset),
            borrowAsset: address(asset),
            principal: 100 ether,
            collateralLockAmount: 50 ether,
            paymentIntervalSeconds: 604_800,
            rollingApyBps: 800,
            gracePeriodSeconds: 604_000,
            maxPaymentCount: 520,
            upfrontPremium: 5 ether,
            allowAmortization: true,
            allowEarlyRepay: true,
            allowEarlyExercise: false
        });

        vm.prank(selfOwner);
        uint256 offerId = rollingOffers.postRollingOffer(params);

        uint256 pointsBefore = harness.pointsBalanceByKey(borrowerKey);
        vm.prank(selfOwner);
        rollingAgreements.acceptRollingOffer(offerId, borrowerPositionId, 0, 0);

        assertEq(harness.pointsBalanceByKey(borrowerKey), pointsBefore);
    }
}
