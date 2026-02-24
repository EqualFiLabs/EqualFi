// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectDiamondTestBase} from "../DirectDiamondTestBase.sol";
import {DirectTypes} from "../../../src/libraries/DirectTypes.sol";
import {DirectTestUtils} from "../DirectTestUtils.sol";
import {LibEncumbrance} from "../../../src/libraries/LibEncumbrance.sol";

/// @notice Feature: equallend-direct, Property 12: Data integrity preservation
/// @notice Validates: Requirements 1.3, 1.4, 1.5, 2.10
/// forge-config: default.fuzz.runs = 100
contract DirectStoragePropertyTest is DirectDiamondTestBase {

    function setUp() public {
        setUpDiamond();
    }

    function _rollingConfig() internal pure returns (DirectTypes.DirectRollingConfig memory cfg) {
        cfg = DirectTypes.DirectRollingConfig({
            minPaymentIntervalSeconds: 1 days,
            maxPaymentCount: 520,
            maxUpfrontPremiumBps: 5_000,
            minRollingApyBps: 1,
            maxRollingApyBps: 10_000,
            defaultPenaltyBps: 1_000,
            minPaymentBps: 1
        });
    }

    function testProperty_DataIntegrityPreservation(
        address lender,
        address borrower,
        address borrowAsset,
        uint256 lenderPositionId,
        uint256 borrowerPositionId,
        uint256 lenderPoolId,
        uint256 collateralPoolId,
        uint256 principal,
        uint16 aprBps,
        uint64 durationSeconds,
        uint256 collateralLockAmount,
        uint16 platformFeeBps,
        uint16 platformSplitLenderBps,
        uint16 platformSplitFeeIndexBps,
        uint16 defaultFeeIndexBps,
        uint16 defaultProtocolBps,
        address treasury,
        bool cancelled,
        bool filled,
        uint8 statusSelector,
        uint256 locked,
        uint256 lent,
        uint256 offerCounter,
        uint256 agreementCounter
    ) public {
        principal = bound(principal, 1, type(uint96).max);
        collateralLockAmount = bound(collateralLockAmount, 1, type(uint96).max);
        lenderPoolId = bound(lenderPoolId, 1, type(uint32).max);
        collateralPoolId = bound(collateralPoolId, 1, type(uint32).max);
        locked = bound(locked, 0, type(uint96).max);
        lent = bound(lent, 0, type(uint96).max);

        uint256 maxDuration = type(uint64).max - block.timestamp;
        durationSeconds = uint64(bound(uint256(durationSeconds), 1, maxDuration));
        aprBps = uint16(bound(aprBps, 0, type(uint16).max));
        uint256 userInterest = DirectTestUtils.annualizedInterest(principal, aprBps, durationSeconds);
        uint64 dueTimestamp = DirectTestUtils.dueTimestamp(block.timestamp, durationSeconds);

        platformFeeBps = uint16(bound(platformFeeBps, 0, 10_000));
        platformSplitLenderBps = uint16(bound(platformSplitLenderBps, 0, 10_000));
        platformSplitFeeIndexBps = uint16(bound(platformSplitFeeIndexBps, 0, 10_000 - platformSplitLenderBps));
        platformSplitFeeIndexBps;

        defaultFeeIndexBps = uint16(bound(defaultFeeIndexBps, 0, 10_000));
        defaultProtocolBps = uint16(bound(defaultProtocolBps, 0, 10_000 - defaultFeeIndexBps));
        uint16 defaultActiveCreditIndexBps = 0;
        treasury;

        uint256 offerId = bound(offerCounter, 1, type(uint256).max - 1);
        uint256 agreementId = bound(agreementCounter, 1, type(uint256).max - 1);
        uint256 nextOfferId = offerId + 1;
        uint256 nextAgreementId = agreementId + 1;

        DirectTypes.DirectConfig memory config = DirectTypes.DirectConfig({
            platformFeeBps: platformFeeBps,
            interestLenderBps: 10_000,
            platformFeeLenderBps: platformSplitLenderBps,
            defaultLenderBps: DirectTestUtils.defaultLenderBps(
                defaultFeeIndexBps, defaultProtocolBps, defaultActiveCreditIndexBps
            ),
            minInterestDuration: 0
        });

        DirectTypes.DirectOffer memory offer = DirectTypes.DirectOffer({
            offerId: offerId,
            lender: lender,
            lenderPositionId: lenderPositionId,
            lenderPoolId: lenderPoolId,
            collateralPoolId: 1,
            collateralAsset: borrowAsset,
            borrowAsset: borrowAsset,
            principal: principal,
            aprBps: aprBps,
            durationSeconds: durationSeconds,
            collateralLockAmount: collateralLockAmount,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false,
            cancelled: cancelled,
            filled: filled,
            isTranche: false,
            trancheAmount: 0
        });

        DirectTypes.DirectAgreement memory agreement = DirectTypes.DirectAgreement({
            agreementId: agreementId,
            lender: lender,
            borrower: borrower,
            lenderPositionId: lenderPositionId,
            lenderPoolId: lenderPoolId,
            borrowerPositionId: borrowerPositionId,
            collateralPoolId: collateralPoolId,
            collateralAsset: borrowAsset,
            borrowAsset: borrowAsset,
            principal: principal,
            userInterest: userInterest,
            dueTimestamp: dueTimestamp,
            collateralLockAmount: collateralLockAmount,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false,
            status: DirectTypes.DirectStatus(uint8(statusSelector % 4)),
            interestRealizedUpfront: true
        });

        bytes32 positionKey = keccak256(abi.encode(lender, borrower, offerId));

        harness.setConfig(config);
        harness.writeOffer(offer);
        harness.setAgreement(agreement);
        harness.setDirectState(positionKey, lenderPoolId, locked, lent, 0);
        harness.setCounters(nextOfferId, nextAgreementId);

        DirectTypes.DirectConfig memory storedConfig = views.getDirectConfig();
        assertEq(storedConfig.platformFeeBps, config.platformFeeBps, "config platform fee persisted");
        assertEq(storedConfig.platformFeeLenderBps, config.platformFeeLenderBps, "config platform lender split");
        assertEq(storedConfig.interestLenderBps, config.interestLenderBps, "config interest lender split");
        assertEq(storedConfig.defaultLenderBps, config.defaultLenderBps, "config default lender split");

        DirectTypes.DirectOffer memory storedOffer = views.getOffer(offerId);
        assertEq(storedOffer.offerId, offer.offerId, "offer id persisted");
        assertEq(storedOffer.lender, offer.lender, "offer lender persisted");
        assertEq(storedOffer.lenderPositionId, offer.lenderPositionId, "offer lender position persisted");
        assertEq(storedOffer.lenderPoolId, offer.lenderPoolId, "offer lender pool persisted");
        assertEq(storedOffer.borrowAsset, offer.borrowAsset, "offer asset persisted");
        assertEq(storedOffer.principal, offer.principal, "offer principal persisted");
        assertEq(storedOffer.aprBps, offer.aprBps, "offer apr persisted");
        assertEq(storedOffer.durationSeconds, offer.durationSeconds, "offer duration persisted");
        assertEq(storedOffer.collateralLockAmount, offer.collateralLockAmount, "offer collateral persisted");
        assertEq(storedOffer.cancelled, offer.cancelled, "offer cancelled flag persisted");
        assertEq(storedOffer.filled, offer.filled, "offer filled flag persisted");

        DirectTypes.DirectAgreement memory storedAgreement = views.getAgreement(agreementId);
        assertEq(storedAgreement.agreementId, agreement.agreementId, "agreement id persisted");
        assertEq(storedAgreement.lender, agreement.lender, "agreement lender persisted");
        assertEq(storedAgreement.borrower, agreement.borrower, "agreement borrower persisted");
        assertEq(storedAgreement.lenderPositionId, agreement.lenderPositionId, "agreement lender position persisted");
        assertEq(storedAgreement.lenderPoolId, agreement.lenderPoolId, "agreement lender pool persisted");
        assertEq(storedAgreement.borrowerPositionId, agreement.borrowerPositionId, "agreement borrower position persisted");
        assertEq(storedAgreement.collateralPoolId, agreement.collateralPoolId, "agreement collateral pool persisted");
        assertEq(storedAgreement.borrowAsset, agreement.borrowAsset, "agreement asset persisted");
        assertEq(storedAgreement.principal, agreement.principal, "agreement principal persisted");
        assertEq(storedAgreement.userInterest, agreement.userInterest, "agreement interest persisted");
        assertEq(storedAgreement.dueTimestamp, agreement.dueTimestamp, "agreement due timestamp persisted");
        assertEq(storedAgreement.collateralLockAmount, agreement.collateralLockAmount, "agreement collateral persisted");
        assertEq(uint8(storedAgreement.status), uint8(agreement.status), "agreement status persisted");
        assertTrue(storedAgreement.interestRealizedUpfront, "agreement upfront flag persisted");

        DirectTypes.PositionDirectState memory state = views.positionState(positionKey, lenderPoolId);
        assertEq(state.directLockedPrincipal, locked, "position locked principal persisted");
        assertEq(state.directLentPrincipal, lent, "position lent principal persisted");

        (uint256 storedNextOfferId, uint256 storedNextAgreementId) = views.directCounters();
        assertEq(storedNextOfferId, nextOfferId, "next offer id persisted");
        assertEq(storedNextAgreementId, nextAgreementId, "next agreement id persisted");
    }

    /// @notice Property: tranche storage operations and position state include escrow
    /// @notice Validates: Requirements 6.4
    function testProperty_TrancheStorageAccounting() public {
        address lender = address(0xBEEF);
        uint256 lenderPoolId = 1;
        uint256 locked = 10 ether;
        uint256 lent = 20 ether;
        uint256 escrowed = 30 ether;
        uint256 trancheRemaining = 40 ether;

        bytes32 positionKey = keccak256(abi.encode(lender, lenderPoolId));
        harness.setDirectState(positionKey, lenderPoolId, locked, lent, 0);
        harness.setOfferEscrow(positionKey, lenderPoolId, escrowed);
        uint256 offerId = uint256(keccak256(abi.encode(lender, lenderPoolId, locked, lent))) | 1;
        harness.setTrancheRemaining(offerId, trancheRemaining);

        DirectTypes.PositionDirectState memory state = views.positionState(positionKey, lenderPoolId);
        assertEq(state.directLockedPrincipal, locked, "locked persisted");
        assertEq(state.directLentPrincipal, lent + escrowed, "lent includes escrow");
        assertEq(views.trancheRemaining(offerId), trancheRemaining, "tranche remaining stored");
    }

    /// @notice Property: cancelOffersForPosition cleans tranche escrow and remaining
    /// @notice Validates: Requirements 6.4, 6.5
    function testProperty_TrancheCleanupOnCancel() public {
        bytes32 positionKey = bytes32(uint256(0xCAFE));
        uint256 lenderPoolId = 2;
        uint256 escrowed = 100 ether;
        uint256 remaining = 60 ether;

        uint256 offerId = uint256(keccak256(abi.encode(positionKey, lenderPoolId, escrowed, remaining))) | 1;
        DirectTypes.DirectOffer memory offer = DirectTypes.DirectOffer({
            offerId: offerId,
            lender: address(0xBEEF),
            lenderPositionId: 1,
            lenderPoolId: lenderPoolId,
            collateralPoolId: lenderPoolId,
            collateralAsset: address(0),
            borrowAsset: address(0),
            principal: remaining,
            aprBps: 0,
            durationSeconds: 0,
            collateralLockAmount: 0,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false,
            cancelled: false,
            filled: false,
            isTranche: true,
            trancheAmount: remaining
        });

        harness.writeOffer(offer);
        harness.trackLenderOffer(positionKey, offerId);
        harness.setTrancheRemaining(offerId, remaining);
        harness.setOfferEscrow(positionKey, lenderPoolId, escrowed);

        offers.cancelOffersForPosition(positionKey);

        DirectTypes.DirectOffer memory stored = views.getOffer(offerId);
        assertTrue(stored.cancelled, "offer cancelled");
        assertEq(views.trancheRemaining(offerId), 0, "tranche cleared");
        assertEq(views.offerEscrow(positionKey, lenderPoolId), escrowed - remaining, "escrow reduced");
    }

    function testProperty_RollingLenderOfferCleanupOnCancel() public {
        harness.setRollingConfig(_rollingConfig());

        address lenderOwner = address(0xAA11);
        uint256 lenderPositionId = nft.mint(lenderOwner, 1);
        finalizePositionNFT();
        bytes32 lenderKey = nft.getPositionKey(lenderPositionId);

        harness.seedPoolWithMembership(1, address(0x1234), lenderKey, 500 ether, false);
        harness.seedPoolWithMembership(2, address(0x1234), lenderKey, 500 ether, false);

        DirectTypes.DirectRollingOfferParams memory params = DirectTypes.DirectRollingOfferParams({
            lenderPositionId: lenderPositionId,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(0x1234),
            borrowAsset: address(0x1234),
            principal: 100 ether,
            collateralLockAmount: 25 ether,
            paymentIntervalSeconds: 7 days,
            rollingApyBps: 800,
            gracePeriodSeconds: 6 days,
            maxPaymentCount: 300,
            upfrontPremium: 0,
            allowAmortization: true,
            allowEarlyRepay: true,
            allowEarlyExercise: false
        });

        vm.prank(lenderOwner);
        uint256 offerId = rollingOffers.postRollingOffer(params);
        assertTrue(offers.hasOpenOffers(lenderKey), "rolling lender offer should be tracked");
        assertEq(views.offerEscrow(lenderKey, 1), 100 ether, "rolling lender offer should escrow principal");

        vm.prank(lenderOwner);
        offers.cancelOffersForPosition(lenderPositionId);

        DirectTypes.DirectRollingOffer memory stored = rollingOffers.getRollingOffer(offerId);
        assertTrue(stored.cancelled, "rolling lender offer should be cancelled");
        assertEq(views.offerEscrow(lenderKey, 1), 0, "rolling lender escrow should be released");
        assertFalse(offers.hasOpenOffers(lenderKey), "no outstanding offers should remain");
    }

    function testProperty_RollingBorrowerOfferCleanupOnCancel() public {
        harness.setRollingConfig(_rollingConfig());

        address borrowerOwner = address(0xBB22);
        uint256 borrowerPositionId = nft.mint(borrowerOwner, 2);
        finalizePositionNFT();
        bytes32 borrowerKey = nft.getPositionKey(borrowerPositionId);

        harness.seedPoolWithMembership(1, address(0x5678), borrowerKey, 500 ether, false);
        harness.seedPoolWithMembership(2, address(0x5678), borrowerKey, 500 ether, false);

        DirectTypes.DirectRollingBorrowerOfferParams memory params = DirectTypes.DirectRollingBorrowerOfferParams({
            borrowerPositionId: borrowerPositionId,
            lenderPoolId: 1,
            collateralPoolId: 2,
            collateralAsset: address(0x5678),
            borrowAsset: address(0x5678),
            principal: 80 ether,
            collateralLockAmount: 30 ether,
            paymentIntervalSeconds: 7 days,
            rollingApyBps: 750,
            gracePeriodSeconds: 6 days,
            maxPaymentCount: 200,
            upfrontPremium: 0,
            allowAmortization: false,
            allowEarlyRepay: true,
            allowEarlyExercise: true
        });

        vm.prank(borrowerOwner);
        uint256 offerId = rollingOffers.postBorrowerRollingOffer(params);
        assertTrue(offers.hasOpenOffers(borrowerKey), "rolling borrower offer should be tracked");
        assertEq(views.directLocked(borrowerKey, 2), 30 ether, "rolling borrower offer should lock collateral");

        vm.prank(borrowerOwner);
        offers.cancelOffersForPosition(borrowerPositionId);

        DirectTypes.DirectRollingBorrowerOffer memory stored = rollingOffers.getRollingBorrowerOffer(offerId);
        assertTrue(stored.cancelled, "rolling borrower offer should be cancelled");
        assertEq(views.directLocked(borrowerKey, 2), 0, "rolling borrower collateral should unlock");
        assertFalse(offers.hasOpenOffers(borrowerKey), "no outstanding offers should remain");
    }

    function testProperty_CancelOffersForPositionHighCardinalityLiveness() public {
        address lenderOwner = address(0xCC33);
        uint256 lenderPositionId = nft.mint(lenderOwner, 1);
        finalizePositionNFT();
        bytes32 lenderKey = nft.getPositionKey(lenderPositionId);

        address borrowAsset = address(0x7777);
        address collateralAsset = address(0x8888);
        harness.seedPoolWithMembership(1, borrowAsset, lenderKey, 10_000 ether, false);
        harness.seedPoolWithMembership(2, collateralAsset, lenderKey, 10_000 ether, false);

        uint256 directCount = 16;
        uint256 ratioCount = 16;
        uint256[] memory directIds = new uint256[](directCount);
        uint256[] memory ratioIds = new uint256[](ratioCount);

        vm.startPrank(lenderOwner);
        for (uint256 i = 0; i < directCount; i++) {
            DirectTypes.DirectOfferParams memory directParams = DirectTypes.DirectOfferParams({
                lenderPositionId: lenderPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                collateralAsset: collateralAsset,
                borrowAsset: borrowAsset,
                principal: 10 ether + i,
                aprBps: 0,
                durationSeconds: 7 days,
                collateralLockAmount: 10 ether + i,
                allowEarlyRepay: false,
                allowEarlyExercise: false,
                allowLenderCall: false
            });
            directIds[i] = offers.postOffer(directParams);
        }

        for (uint256 i = 0; i < ratioCount; i++) {
            DirectTypes.DirectRatioTrancheParams memory ratioParams = DirectTypes.DirectRatioTrancheParams({
                lenderPositionId: lenderPositionId,
                lenderPoolId: 1,
                collateralPoolId: 2,
                collateralAsset: collateralAsset,
                borrowAsset: borrowAsset,
                principalCap: 10 ether + i,
                priceNumerator: 2,
                priceDenominator: 1,
                minPrincipalPerFill: 1,
                aprBps: 0,
                durationSeconds: 7 days,
                allowEarlyRepay: false,
                allowEarlyExercise: false,
                allowLenderCall: false
            });
            ratioIds[i] = offers.postRatioTrancheOffer(ratioParams);
        }
        vm.stopPrank();

        assertTrue(offers.hasOpenOffers(lenderKey), "lender should have outstanding offers before bulk cancel");

        uint256 gasStart = gasleft();
        vm.prank(lenderOwner);
        offers.cancelOffersForPosition(lenderPositionId);
        uint256 gasUsed = gasStart - gasleft();

        assertLt(gasUsed, 12_000_000, "bulk cancellation should stay within practical gas bounds");
        assertFalse(offers.hasOpenOffers(lenderKey), "bulk cancel should clear all tracked offers");
        assertEq(views.offerEscrow(lenderKey, 1), 0, "bulk cancel should release lender escrow");

        assertTrue(views.getOffer(directIds[0]).cancelled, "first direct offer should be cancelled");
        assertTrue(views.getOffer(directIds[directCount - 1]).cancelled, "last direct offer should be cancelled");
        assertTrue(views.getRatioTrancheOffer(ratioIds[0]).cancelled, "first ratio offer should be cancelled");
        assertTrue(views.getRatioTrancheOffer(ratioIds[ratioCount - 1]).cancelled, "last ratio offer should be cancelled");
    }
}
