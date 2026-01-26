// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DirectDiamondTestBase} from "./DirectDiamondTestBase.sol";
import {DirectTypes} from "../../src/libraries/DirectTypes.sol";

/// @notice Feature: tranche-backed-offers, Property 1: Tranche offer initialization correctness
/// @notice Validates: Requirements 1.1, 1.2, 1.3
/// forge-config: default.fuzz.runs = 100
contract DirectTypesTranchePropertyTest is DirectDiamondTestBase {

    function setUp() public {
        setUpDiamond();
    }

    function testProperty_TrancheOfferInitializationCorrectness(
        address lender,
        uint256 lenderPositionId,
        uint256 lenderPoolId,
        uint256 collateralPoolId,
        address collateralAsset,
        address borrowAsset,
        uint256 principal,
        uint16 aprBps,
        uint64 durationSeconds,
        uint256 collateralLockAmount,
        uint256 trancheAmount,
        bool enforceDivisibility
    ) public {
        lenderPoolId = bound(lenderPoolId, 1, type(uint32).max);
        collateralPoolId = bound(collateralPoolId, 1, type(uint32).max);
        principal = bound(principal, 1, type(uint96).max);
        trancheAmount = bound(trancheAmount, principal, type(uint256).max - 1);
        collateralLockAmount = bound(collateralLockAmount, 1, type(uint96).max);

        uint256 maxDuration = type(uint64).max - block.timestamp;
        durationSeconds = uint64(bound(uint256(durationSeconds), 1, maxDuration));

        harness.setEnforceFixedSizeFills(enforceDivisibility);

        uint256 trancheOfferId = 1;
        DirectTypes.DirectOffer memory trancheOffer = DirectTypes.DirectOffer({
            offerId: trancheOfferId,
            lender: lender,
            lenderPositionId: lenderPositionId,
            lenderPoolId: lenderPoolId,
            collateralPoolId: collateralPoolId,
            collateralAsset: collateralAsset,
            borrowAsset: borrowAsset,
            principal: principal,
            aprBps: aprBps,
            durationSeconds: durationSeconds,
            collateralLockAmount: collateralLockAmount,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false,
            cancelled: false,
            filled: false,
            isTranche: true,
            trancheAmount: trancheAmount
        });

        harness.writeOffer(trancheOffer);
        harness.setTrancheRemaining(trancheOfferId, trancheAmount);

        DirectTypes.DirectOffer memory storedTranche = views.getOffer(trancheOfferId);
        assertTrue(storedTranche.isTranche, "tranche flag persisted");
        assertEq(storedTranche.trancheAmount, trancheAmount, "tranche amount persisted");
        assertEq(views.trancheRemaining(trancheOfferId), trancheAmount, "tranche remaining initialized");
        assertEq(views.enforceFixedSizeFills(), enforceDivisibility, "divisibility flag persisted");

        uint256 standardOfferId = trancheOfferId + 1;
        DirectTypes.DirectOffer memory standardOffer = DirectTypes.DirectOffer({
            offerId: standardOfferId,
            lender: lender,
            lenderPositionId: lenderPositionId,
            lenderPoolId: lenderPoolId,
            collateralPoolId: collateralPoolId,
            collateralAsset: collateralAsset,
            borrowAsset: borrowAsset,
            principal: principal,
            aprBps: aprBps,
            durationSeconds: durationSeconds,
            collateralLockAmount: collateralLockAmount,
            allowEarlyRepay: false,
            allowEarlyExercise: false,
            allowLenderCall: false,
            cancelled: false,
            filled: false,
            isTranche: false,
            trancheAmount: 0
        });

        harness.writeOffer(standardOffer);

        DirectTypes.DirectOffer memory storedStandard = views.getOffer(standardOfferId);
        assertFalse(storedStandard.isTranche, "standard offer not tranche");
        assertEq(storedStandard.trancheAmount, 0, "standard offer tranche amount zero");
        assertEq(views.trancheRemaining(standardOfferId), 0, "standard offer tranche remaining default zero");
    }
}
