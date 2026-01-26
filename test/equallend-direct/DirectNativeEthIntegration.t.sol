// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectDiamondTestBase} from "./DirectDiamondTestBase.sol";
import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {DirectTestUtils} from "./DirectTestUtils.sol";

contract DirectNativeEthIntegrationTest is DirectDiamondTestBase {
    address internal lenderOwner = address(0x1111);
    address internal borrowerOwner = address(0x2222);
    address internal treasury = address(0xBEEF);

    uint256 internal lenderPositionId;
    uint256 internal borrowerPositionId;
    bytes32 internal lenderKey;
    bytes32 internal borrowerKey;

    uint256 internal constant LENDER_POOL = 1;
    uint256 internal constant COLLATERAL_POOL = 2;

    function setUp() public {
        setUpDiamond();

        lenderPositionId = nft.mint(lenderOwner, LENDER_POOL);
        borrowerPositionId = nft.mint(borrowerOwner, COLLATERAL_POOL);
        lenderKey = nft.getPositionKey(lenderPositionId);
        borrowerKey = nft.getPositionKey(borrowerPositionId);

        finalizePositionNFT();

        uint256 lenderPrincipal = 200 ether;
        uint256 borrowerPrincipal = 500 ether;
        harness.seedPoolWithMembership(LENDER_POOL, address(0), lenderKey, lenderPrincipal, false);
        harness.seedPoolWithMembership(COLLATERAL_POOL, address(0), borrowerKey, borrowerPrincipal, false);

        DirectTypes.DirectConfig memory cfg = DirectTypes.DirectConfig({
            platformFeeBps: 100,
            interestLenderBps: 0,
            platformFeeLenderBps: 0,
            defaultLenderBps: 10_000,
            minInterestDuration: 0
        });
        harness.setConfig(cfg);
        harness.setTreasuryShare(treasury, 2000);
        harness.setActiveCreditShare(0);

        uint256 trackedTotal = lenderPrincipal + borrowerPrincipal;
        harness.setNativeTrackedTotal(trackedTotal);
        vm.deal(address(diamond), trackedTotal + 100 ether);
    }

    /// Feature: native-eth-support, Integration 13.2: Direct lending native ETH flow
    function testIntegration_directNativeEthLifecycle() public {
        uint256 principal = 100 ether;
        uint256 collateralLockAmount = 150 ether;
        uint16 aprBps = 500;
        uint64 durationSeconds = 30 days;

        DirectTypes.DirectOfferParams memory params = DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPositionId,
            lenderPoolId: LENDER_POOL,
            collateralPoolId: COLLATERAL_POOL,
            collateralAsset: address(0),
            borrowAsset: address(0),
            principal: principal,
            aprBps: aprBps,
            durationSeconds: durationSeconds,
            collateralLockAmount: collateralLockAmount,
            allowEarlyRepay: true,
            allowEarlyExercise: true,
            allowLenderCall: false
        });

        DirectTypes.DirectTrancheOfferParams memory trancheParams = DirectTypes.DirectTrancheOfferParams({
            isTranche: false,
            trancheAmount: 0
        });

        vm.prank(lenderOwner);
        uint256 offerId = offers.postOffer(params, trancheParams);

        uint256 interest = DirectTestUtils.annualizedInterest(principal, aprBps, durationSeconds);
        uint256 platformFee = (principal * 100) / 10_000;
        uint256 totalFee = interest + platformFee;
        uint256 expectedTreasury = (totalFee * 2000) / 10_000;

        uint256 borrowerBefore = borrowerOwner.balance;
        uint256 lenderTrackedBefore = views.getTrackedBalance(LENDER_POOL);
        uint256 collateralTrackedBefore = views.getTrackedBalance(COLLATERAL_POOL);
        uint256 nativeTrackedBefore = harness.nativeTrackedTotal();

        vm.prank(borrowerOwner);
        uint256 agreementId = agreements.acceptOffer(offerId, borrowerPositionId);

        assertEq(
            borrowerOwner.balance - borrowerBefore,
            principal - totalFee,
            "borrower receives net principal"
        );
        assertEq(views.getTrackedBalance(LENDER_POOL), lenderTrackedBefore - principal, "lender tracked reduces");
        assertEq(
            views.getTrackedBalance(COLLATERAL_POOL),
            collateralTrackedBefore + (totalFee - expectedTreasury),
            "collateral pool accrues fees"
        );
        assertEq(
            harness.nativeTrackedTotal(),
            nativeTrackedBefore - principal + totalFee - expectedTreasury,
            "native tracked after accept"
        );

        vm.prank(borrowerOwner);
        lifecycle.repay(agreementId);

        assertEq(views.getTrackedBalance(LENDER_POOL), lenderTrackedBefore, "lender tracked restored");
        assertEq(
            harness.nativeTrackedTotal(),
            nativeTrackedBefore + totalFee - expectedTreasury,
            "native tracked after repay"
        );
        assertEq(uint8(views.getAgreement(agreementId).status), uint8(DirectTypes.DirectStatus.Repaid), "repaid");
    }
}
