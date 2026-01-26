// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectDiamondTestBase} from "./DirectDiamondTestBase.sol";
import {DirectTypes} from "../../src/libraries/DirectTypes.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {DirectTestUtils} from "./DirectTestUtils.sol";

/// @notice Integration tests for tranche offers with other flows
contract DirectTrancheIntegrationTest is DirectDiamondTestBase {
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    uint256 internal constant LENDER_POOL = 1;
    uint256 internal constant COLLATERAL_POOL = 2;

    function setUp() public {
        setUpDiamond();
        tokenA = new MockERC20("Token A", "TKA", 18, 10_000_000 ether);
        tokenB = new MockERC20("Token B", "TKB", 18, 10_000_000 ether);

        DirectTypes.DirectConfig memory cfg = DirectTypes.DirectConfig({
            platformFeeBps: 500,
            interestLenderBps: 10_000,
            platformFeeLenderBps: 5000,
            defaultLenderBps: 8000,
            minInterestDuration: 0
        });
        views.setDirectConfig(cfg);
        harness.setTreasuryShare(address(0xFEE1), DirectTestUtils.treasurySplitFromLegacy(5000, 2000));
        harness.setActiveCreditShare(DirectTestUtils.activeSplitFromLegacy(5000, 0));

        DirectTypes.DirectRollingConfig memory rollingCfg = DirectTypes.DirectRollingConfig({
            minPaymentIntervalSeconds: 1 days,
            maxPaymentCount: 520,
            maxUpfrontPremiumBps: 10_000,
            minRollingApyBps: 1,
            maxRollingApyBps: 20_000,
            defaultPenaltyBps: 0,
            minPaymentBps: 1
        });
        harness.setRollingConfig(rollingCfg);
    }

    function _offerParams(uint256 lenderPos, uint256 principal) internal pure returns (DirectTypes.DirectOfferParams memory) {
        return DirectTypes.DirectOfferParams({
            lenderPositionId: lenderPos,
            lenderPoolId: LENDER_POOL,
            collateralPoolId: COLLATERAL_POOL,
            collateralAsset: address(0), // set later
            borrowAsset: address(0), // set later
            principal: principal,
            aprBps: 1000,
            durationSeconds: 7 days,
            collateralLockAmount: principal,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false
        });
    }

    function testIntegration_TrancheAndStandardFlow() public {
        address lender = address(0xA11CE);
        address borrower = address(0xB0B0B0);
        uint256 lenderPos = nft.mint(lender, LENDER_POOL);
        uint256 borrowerPos = nft.mint(borrower, COLLATERAL_POOL);
        finalizePositionNFT();
        bytes32 lenderKey = nft.getPositionKey(lenderPos);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPos);

        uint256 balance = 1_000 ether;
        harness.seedPoolWithMembership(LENDER_POOL, address(tokenA), lenderKey, balance, true);
        harness.seedPoolWithMembership(COLLATERAL_POOL, address(tokenB), borrowerKey, balance, true);

        DirectTypes.DirectOfferParams memory params = _offerParams(lenderPos, 100 ether);
        params.borrowAsset = address(tokenA);
        params.collateralAsset = address(tokenB);

        // Standard offer
        vm.prank(lender);
        uint256 standardOfferId = offers.postOffer(params);
        vm.prank(borrower);
        agreements.acceptOffer(standardOfferId, borrowerPos);

        // Tranche offer
        DirectTypes.DirectTrancheOfferParams memory tranche =
            DirectTypes.DirectTrancheOfferParams({isTranche: true, trancheAmount: 200 ether});
        vm.prank(lender);
        uint256 trancheOfferId = offers.postOffer(params, tranche);
        vm.prank(borrower);
        agreements.acceptOffer(trancheOfferId, borrowerPos);

        assertEq(views.trancheRemaining(trancheOfferId), 100 ether, "tranche remaining after one fill");
        vm.prank(borrower);
        agreements.acceptOffer(trancheOfferId, borrowerPos);
        assertEq(views.trancheRemaining(trancheOfferId), 0, "tranche depleted");
        assertEq(views.offerEscrow(lenderKey, LENDER_POOL), 0, "escrow zero after full consumption");
        assertEq(views.getActiveDirectLent(LENDER_POOL), 300 ether, "active lent tracks both offers");
    }

    function testIntegration_PositionTransferCancelsTranche() public {
        address lender = address(0xA11CE);
        address newOwner = address(0xB0B);
        uint256 lenderPos = nft.mint(lender, LENDER_POOL);
        finalizePositionNFT();
        bytes32 lenderKey = nft.getPositionKey(lenderPos);
        harness.seedPoolWithMembership(LENDER_POOL, address(tokenA), lenderKey, 300 ether, true);
        harness.seedPoolWithMembership(COLLATERAL_POOL, address(tokenB), lenderKey, 300 ether, true);

        DirectTypes.DirectOfferParams memory params = _offerParams(lenderPos, 50 ether);
        params.borrowAsset = address(tokenA);
        params.collateralAsset = address(tokenB);
        DirectTypes.DirectTrancheOfferParams memory tranche =
            DirectTypes.DirectTrancheOfferParams({isTranche: true, trancheAmount: 150 ether});

        vm.prank(lender);
        uint256 offerId = offers.postOffer(params, tranche);
        assertEq(views.offerEscrow(lenderKey, LENDER_POOL), 150 ether, "escrowed tranche");

        vm.prank(lender);
        offers.cancelOffersForPosition(lenderPos);

        vm.prank(lender);
        nft.transferFrom(lender, newOwner, lenderPos);

        assertEq(views.trancheRemaining(offerId), 0, "tranche cleared on transfer");
        assertEq(views.offerEscrow(lenderKey, LENDER_POOL), 0, "escrow released on transfer");
        DirectTypes.DirectOffer memory stored = views.getOffer(offerId);
        assertTrue(stored.cancelled, "offer cancelled on transfer");
    }

    function testIntegration_TrancheIsolatedFromRollingOffers() public {
        address lender = address(0xDAD);
        address borrower = address(0xB0B0B0);
        uint256 lenderPos = nft.mint(lender, LENDER_POOL);
        uint256 borrowerPos = nft.mint(borrower, COLLATERAL_POOL);
        finalizePositionNFT();
        bytes32 lenderKey = nft.getPositionKey(lenderPos);
        bytes32 borrowerKey = nft.getPositionKey(borrowerPos);
        harness.seedPoolWithMembership(LENDER_POOL, address(tokenA), lenderKey, 1_000 ether, true);
        harness.seedPoolWithMembership(COLLATERAL_POOL, address(tokenB), lenderKey, 1_000 ether, true);

        // Post rolling offer
        DirectTypes.DirectRollingOfferParams memory rolling = DirectTypes.DirectRollingOfferParams({
            lenderPositionId: lenderPos,
            lenderPoolId: LENDER_POOL,
            collateralPoolId: COLLATERAL_POOL,
            collateralAsset: address(tokenB),
            borrowAsset: address(tokenA),
            principal: 100 ether,
            collateralLockAmount: 50 ether,
            paymentIntervalSeconds: 7 days,
            rollingApyBps: 1200,
            gracePeriodSeconds: 1 days,
            maxPaymentCount: 10,
            upfrontPremium: 10 ether,
            allowAmortization: true,
            allowEarlyRepay: true,
            allowEarlyExercise: false
        });
        vm.prank(lender);
        uint256 rollingId = rollingOffers.postRollingOffer(rolling);

        // Post tranche offer
        DirectTypes.DirectOfferParams memory params = _offerParams(lenderPos, 100 ether);
        params.borrowAsset = address(tokenA);
        params.collateralAsset = address(tokenB);
        DirectTypes.DirectTrancheOfferParams memory tranche =
            DirectTypes.DirectTrancheOfferParams({isTranche: true, trancheAmount: 200 ether});

        vm.prank(lender);
        uint256 trancheOfferId = offers.postOffer(params, tranche);

        // Accept tranche once
        harness.seedPoolWithMembership(COLLATERAL_POOL, address(tokenB), borrowerKey, 500 ether, true);
        vm.prank(borrower);
        agreements.acceptOffer(trancheOfferId, borrowerPos);

        // Rolling offer remains intact
        DirectTypes.DirectRollingOffer memory rollingOffer = rollingOffers.getRollingOffer(rollingId);
        assertFalse(rollingOffer.cancelled, "rolling offer not cancelled");
        assertFalse(rollingOffer.filled, "rolling offer not filled");
        assertEq(views.trancheRemaining(trancheOfferId), 100 ether, "tranche decremented independently");
    }
}
