// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {PositionNFT} from "../nft/PositionNFT.sol";
import {Types} from "../libraries/Types.sol";
import {LibFeeIndex} from "../libraries/LibFeeIndex.sol";
import {LibActiveCreditIndex} from "../libraries/LibActiveCreditIndex.sol";
import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibCurrency} from "../libraries/LibCurrency.sol";
import {LibPoolMembership} from "../libraries/LibPoolMembership.sol";
import {ReentrancyGuardModifiers} from "../libraries/LibReentrancyGuard.sol";
import {InsufficientPrincipal} from "../libraries/Errors.sol";
import {DirectTypes} from "../libraries/DirectTypes.sol";
import {LibDirectHelpers} from "../libraries/LibDirectHelpers.sol";
import {LibEncumbrance} from "../libraries/LibEncumbrance.sol";
import {LibDirectStorage} from "../libraries/LibDirectStorage.sol";
import {LibSolvencyChecks} from "../libraries/LibSolvencyChecks.sol";
import {DirectError_InvalidAsset, DirectError_InvalidOffer, DirectError_InvalidTimestamp} from "../libraries/Errors.sol";

/// @notice Rolling agreement acceptance and initialization
contract EqualLendDirectRollingAgreementFacet is ReentrancyGuardModifiers {
    event RollingOfferAccepted(uint256 indexed offerId, uint256 indexed agreementId, address indexed borrower);

    function acceptRollingOffer(uint256 offerId, uint256 callerPositionId)
        external
        payable
        nonReentrant
        returns (uint256 agreementId)
    {
        LibCurrency.assertZeroMsgValue();
        PositionNFT nft = LibDirectHelpers._positionNFT();
        LibDirectHelpers._requireNFTOwnership(nft, callerPositionId);

        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();

        DirectTypes.DirectRollingOffer storage lenderOffer = ds.rollingOffers[offerId];
        bool isLenderOffer = lenderOffer.lender != address(0);

        address borrower;
        if (isLenderOffer) {
            agreementId = _acceptLenderRollingOffer(nft, ds, lenderOffer, callerPositionId);
            borrower = nft.ownerOf(callerPositionId);
        } else {
            DirectTypes.DirectRollingBorrowerOffer storage borrowerOffer = ds.rollingBorrowerOffers[offerId];
            agreementId = _acceptBorrowerRollingOffer(nft, ds, borrowerOffer, callerPositionId);
            borrower = borrowerOffer.borrower;
        }

        emit RollingOfferAccepted(offerId, agreementId, borrower);
    }

    function getRollingAgreement(uint256 agreementId) external view returns (DirectTypes.DirectRollingAgreement memory) {
        return LibDirectStorage.directStorage().rollingAgreements[agreementId];
    }

    function _acceptLenderRollingOffer(
        PositionNFT nft,
        DirectTypes.DirectStorage storage ds,
        DirectTypes.DirectRollingOffer storage offer,
        uint256 borrowerPositionId
    ) internal returns (uint256 agreementId) {
        if (offer.lender == address(0) || offer.cancelled || offer.filled) {
            revert DirectError_InvalidOffer();
        }
        if (offer.lenderPositionId == borrowerPositionId) revert DirectError_InvalidOffer();

        Types.PoolData storage lenderPool = LibDirectHelpers._pool(offer.lenderPoolId);
        Types.PoolData storage collateralPool = LibDirectHelpers._pool(offer.collateralPoolId);
        if (offer.borrowAsset != lenderPool.underlying) revert DirectError_InvalidAsset();
        if (offer.collateralAsset != collateralPool.underlying) revert DirectError_InvalidAsset();

        bytes32 lenderKey = nft.getPositionKey(offer.lenderPositionId);
        LibFeeIndex.settle(offer.lenderPoolId, lenderKey);
        LibActiveCreditIndex.settle(offer.lenderPoolId, lenderKey);
        if (!LibPoolMembership.isMember(lenderKey, offer.lenderPoolId)) revert DirectError_InvalidOffer();

        uint256 currentPrincipal = lenderPool.userPrincipal[lenderKey];
        uint256 offerEscrow = LibEncumbrance.position(lenderKey, offer.lenderPoolId).directOfferEscrow;
        if (offerEscrow < offer.principal) revert InsufficientPrincipal(offer.principal, offerEscrow);
        if (currentPrincipal < offer.principal) revert InsufficientPrincipal(offer.principal, currentPrincipal);

        bytes32 borrowerKey = nft.getPositionKey(borrowerPositionId);
        LibFeeIndex.settle(offer.collateralPoolId, borrowerKey);
        LibActiveCreditIndex.settle(offer.collateralPoolId, borrowerKey);
        if (!LibPoolMembership.isMember(borrowerKey, offer.collateralPoolId)) revert DirectError_InvalidOffer();
        uint256 borrowerPrincipal = collateralPool.userPrincipal[borrowerKey];
        uint256 locked = LibEncumbrance.position(borrowerKey, offer.collateralPoolId).directLocked;
        if (locked > borrowerPrincipal) revert InsufficientPrincipal(locked, borrowerPrincipal);
        uint256 available = borrowerPrincipal - locked;
        if (offer.collateralLockAmount > available) revert InsufficientPrincipal(offer.collateralLockAmount, available);

        uint256 currentBorrowerDebt =
            LibSolvencyChecks.calculateTotalDebt(collateralPool, borrowerKey, offer.collateralPoolId);
        uint256 newBorrowerDebt = currentBorrowerDebt + offer.collateralLockAmount;
        require(
            LibSolvencyChecks.checkSolvency(collateralPool, borrowerKey, borrowerPrincipal, newBorrowerDebt),
            "SolvencyViolation: Borrower LTV"
        );

        if (offer.paymentIntervalSeconds == 0) revert DirectError_InvalidTimestamp();
        uint256 nextDueCalc = block.timestamp + offer.paymentIntervalSeconds;
        if (nextDueCalc > type(uint64).max) revert DirectError_InvalidTimestamp();

        // Effects
        uint256 borrowerEncBefore = LibEncumbrance.totalForActiveCredit(borrowerKey, offer.collateralPoolId);
        LibEncumbrance.position(borrowerKey, offer.collateralPoolId).directLocked = locked + offer.collateralLockAmount;
        uint256 borrowerEncAfter = LibEncumbrance.totalForActiveCredit(borrowerKey, offer.collateralPoolId);
        LibActiveCreditIndex.applyEncumbranceDelta(
            collateralPool, offer.collateralPoolId, borrowerKey, borrowerEncBefore, borrowerEncAfter
        );

        uint256 lenderEncBefore = LibEncumbrance.totalForActiveCredit(lenderKey, offer.lenderPoolId);
        LibEncumbrance.position(lenderKey, offer.lenderPoolId).directOfferEscrow = offerEscrow - offer.principal;
        lenderPool.trackedBalance -= offer.principal;
        if (LibCurrency.isNative(lenderPool.underlying) && offer.principal > 0) {
            LibAppStorage.s().nativeTrackedTotal -= offer.principal;
        }
        ds.activeDirectLentPerPool[offer.lenderPoolId] += offer.principal;
        LibEncumbrance.position(lenderKey, offer.lenderPoolId).directLent += offer.principal;
        ds.directBorrowedPrincipal[borrowerKey][offer.lenderPoolId] += offer.principal;
        uint256 lenderEncAfter = LibEncumbrance.totalForActiveCredit(lenderKey, offer.lenderPoolId);
        LibActiveCreditIndex.applyEncumbranceDelta(
            lenderPool, offer.lenderPoolId, lenderKey, lenderEncBefore, lenderEncAfter
        );
        lenderPool.userPrincipal[lenderKey] = currentPrincipal - offer.principal;
        lenderPool.totalDeposits = lenderPool.totalDeposits >= offer.principal
            ? lenderPool.totalDeposits - offer.principal
            : 0;
        // Lender encumbrance active credit is handled via encumbrance deltas.

        offer.filled = true;
        agreementId = ++ds.nextRollingAgreementId;
        LibDirectStorage.untrackRollingLenderOffer(ds, lenderKey, offer.offerId);

        ds.rollingAgreements[agreementId] = DirectTypes.DirectRollingAgreement({
            agreementId: agreementId,
            isRolling: true,
            lender: offer.lender,
            borrower: nft.ownerOf(borrowerPositionId),
            lenderPositionId: offer.lenderPositionId,
            lenderPoolId: offer.lenderPoolId,
            borrowerPositionId: borrowerPositionId,
            collateralPoolId: offer.collateralPoolId,
            collateralAsset: offer.collateralAsset,
            borrowAsset: offer.borrowAsset,
            principal: offer.principal,
            outstandingPrincipal: offer.principal,
            collateralLockAmount: offer.collateralLockAmount,
            upfrontPremium: offer.upfrontPremium,
            nextDue: uint64(nextDueCalc),
            arrears: 0,
            paymentCount: 0,
            paymentIntervalSeconds: offer.paymentIntervalSeconds,
            rollingApyBps: offer.rollingApyBps,
            gracePeriodSeconds: offer.gracePeriodSeconds,
            maxPaymentCount: offer.maxPaymentCount,
            allowAmortization: offer.allowAmortization,
            allowEarlyRepay: offer.allowEarlyRepay,
            allowEarlyExercise: offer.allowEarlyExercise,
            lastAccrualTimestamp: uint64(block.timestamp),
            status: DirectTypes.DirectStatus.Active
        });
        LibDirectStorage.addBorrowerAgreement(ds, borrowerKey, agreementId);
        LibDirectStorage.addLenderAgreement(ds, lenderKey, agreementId);
        LibDirectStorage.addRollingBorrowerAgreement(ds, borrowerKey, agreementId);
        LibDirectStorage.addRollingLenderAgreement(ds, lenderKey, agreementId);

        // Transfers: upfront premium to lender, remainder to borrower
        if (offer.upfrontPremium > 0) {
            LibCurrency.transfer(offer.borrowAsset, offer.lender, offer.upfrontPremium);
        }
        uint256 netToBorrower = offer.principal - offer.upfrontPremium;
        LibCurrency.transfer(offer.borrowAsset, nft.ownerOf(borrowerPositionId), netToBorrower);
    }

    function _acceptBorrowerRollingOffer(
        PositionNFT nft,
        DirectTypes.DirectStorage storage ds,
        DirectTypes.DirectRollingBorrowerOffer storage offer,
        uint256 lenderPositionId
    ) internal returns (uint256 agreementId) {
        if (offer.borrower == address(0) || offer.cancelled || offer.filled) {
            revert DirectError_InvalidOffer();
        }
        if (offer.borrowerPositionId == lenderPositionId) revert DirectError_InvalidOffer();

        Types.PoolData storage lenderPool = LibDirectHelpers._pool(offer.lenderPoolId);
        Types.PoolData storage collateralPool = LibDirectHelpers._pool(offer.collateralPoolId);
        if (offer.borrowAsset != lenderPool.underlying) revert DirectError_InvalidAsset();
        if (offer.collateralAsset != collateralPool.underlying) revert DirectError_InvalidAsset();

        bytes32 lenderKey = nft.getPositionKey(lenderPositionId);
        LibFeeIndex.settle(offer.lenderPoolId, lenderKey);
        LibActiveCreditIndex.settle(offer.lenderPoolId, lenderKey);
        if (!LibPoolMembership.isMember(lenderKey, offer.lenderPoolId)) revert DirectError_InvalidOffer();

        uint256 currentPrincipal = lenderPool.userPrincipal[lenderKey];
        if (currentPrincipal < offer.principal) revert InsufficientPrincipal(offer.principal, currentPrincipal);

        bytes32 borrowerKey = nft.getPositionKey(offer.borrowerPositionId);
        LibFeeIndex.settle(offer.collateralPoolId, borrowerKey);
        LibActiveCreditIndex.settle(offer.collateralPoolId, borrowerKey);
        if (!LibPoolMembership.isMember(borrowerKey, offer.collateralPoolId)) revert DirectError_InvalidOffer();
        uint256 borrowerPrincipal = collateralPool.userPrincipal[borrowerKey];
        uint256 locked = LibEncumbrance.position(borrowerKey, offer.collateralPoolId).directLocked;
        if (locked < offer.collateralLockAmount) revert InsufficientPrincipal(offer.collateralLockAmount, locked);

        uint256 currentBorrowerDebt =
            LibSolvencyChecks.calculateTotalDebt(collateralPool, borrowerKey, offer.collateralPoolId);
        require(
            LibSolvencyChecks.checkSolvency(collateralPool, borrowerKey, borrowerPrincipal, currentBorrowerDebt),
            "SolvencyViolation: Borrower LTV"
        );

        if (offer.paymentIntervalSeconds == 0) revert DirectError_InvalidTimestamp();
        uint256 nextDueCalc = block.timestamp + offer.paymentIntervalSeconds;
        if (nextDueCalc > type(uint64).max) revert DirectError_InvalidTimestamp();

        // Effects
        uint256 lenderEncBefore = LibEncumbrance.totalForActiveCredit(lenderKey, offer.lenderPoolId);
        lenderPool.trackedBalance -= offer.principal;
        if (LibCurrency.isNative(lenderPool.underlying) && offer.principal > 0) {
            LibAppStorage.s().nativeTrackedTotal -= offer.principal;
        }
        ds.activeDirectLentPerPool[offer.lenderPoolId] += offer.principal;
        LibEncumbrance.position(lenderKey, offer.lenderPoolId).directLent += offer.principal;
        ds.directBorrowedPrincipal[borrowerKey][offer.lenderPoolId] += offer.principal;
        uint256 lenderEncAfter = LibEncumbrance.totalForActiveCredit(lenderKey, offer.lenderPoolId);
        LibActiveCreditIndex.applyEncumbranceDelta(
            lenderPool, offer.lenderPoolId, lenderKey, lenderEncBefore, lenderEncAfter
        );
        lenderPool.userPrincipal[lenderKey] = currentPrincipal - offer.principal;
        lenderPool.totalDeposits = lenderPool.totalDeposits >= offer.principal
            ? lenderPool.totalDeposits - offer.principal
            : 0;
        // Lender encumbrance active credit is handled via encumbrance deltas.

        offer.filled = true;
        agreementId = ++ds.nextRollingAgreementId;
        LibDirectStorage.untrackRollingBorrowerOffer(ds, borrowerKey, offer.offerId);

        ds.rollingAgreements[agreementId] = DirectTypes.DirectRollingAgreement({
            agreementId: agreementId,
            isRolling: true,
            lender: nft.ownerOf(lenderPositionId),
            borrower: offer.borrower,
            lenderPositionId: lenderPositionId,
            lenderPoolId: offer.lenderPoolId,
            borrowerPositionId: offer.borrowerPositionId,
            collateralPoolId: offer.collateralPoolId,
            collateralAsset: offer.collateralAsset,
            borrowAsset: offer.borrowAsset,
            principal: offer.principal,
            outstandingPrincipal: offer.principal,
            collateralLockAmount: offer.collateralLockAmount,
            upfrontPremium: offer.upfrontPremium,
            nextDue: uint64(nextDueCalc),
            arrears: 0,
            paymentCount: 0,
            paymentIntervalSeconds: offer.paymentIntervalSeconds,
            rollingApyBps: offer.rollingApyBps,
            gracePeriodSeconds: offer.gracePeriodSeconds,
            maxPaymentCount: offer.maxPaymentCount,
            allowAmortization: offer.allowAmortization,
            allowEarlyRepay: offer.allowEarlyRepay,
            allowEarlyExercise: offer.allowEarlyExercise,
            lastAccrualTimestamp: uint64(block.timestamp),
            status: DirectTypes.DirectStatus.Active
        });
        LibDirectStorage.addBorrowerAgreement(ds, borrowerKey, agreementId);
        LibDirectStorage.addLenderAgreement(ds, lenderKey, agreementId);
        LibDirectStorage.addRollingBorrowerAgreement(ds, borrowerKey, agreementId);
        LibDirectStorage.addRollingLenderAgreement(ds, lenderKey, agreementId);

        if (offer.upfrontPremium > 0) {
            LibCurrency.transfer(offer.borrowAsset, nft.ownerOf(lenderPositionId), offer.upfrontPremium);
        }
        uint256 netToBorrower = offer.principal - offer.upfrontPremium;
        LibCurrency.transfer(offer.borrowAsset, offer.borrower, netToBorrower);
    }
}
