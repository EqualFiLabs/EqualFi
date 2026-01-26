// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {DirectTypes} from "./DirectTypes.sol";
import {LibActiveCreditIndex} from "./LibActiveCreditIndex.sol";
import {LibAppStorage} from "./LibAppStorage.sol";
import {LibEncumbrance} from "./LibEncumbrance.sol";
import {LibPositionList} from "./LibPositionList.sol";
import {Types} from "./Types.sol";

/// @notice Diamond storage accessors for EqualLend Direct facet
library LibDirectStorage {
    using LibPositionList for LibPositionList.List;
    bytes32 internal constant DIRECT_STORAGE_POSITION = keccak256("equallend.direct.storage");

    function directStorage() internal pure returns (DirectTypes.DirectStorage storage ds) {
        bytes32 position = DIRECT_STORAGE_POSITION;
        assembly {
            ds.slot := position
        }
    }

    function positionState(bytes32 positionKey, uint256 pid) internal view returns (DirectTypes.PositionDirectState memory) {
        LibEncumbrance.Encumbrance memory enc = LibEncumbrance.get(positionKey, pid);
        return
            DirectTypes.PositionDirectState({
                directLockedPrincipal: enc.directLocked,
                directLentPrincipal: enc.directLent + enc.directOfferEscrow
            });
    }

    /// @notice Track an agreement for a borrower position key.
    function addBorrowerAgreement(
        DirectTypes.DirectStorage storage ds,
        bytes32 borrowerKey,
        uint256 agreementId
    ) internal {
        ds.borrowerAgreements.add(borrowerKey, agreementId);
    }

    /// @notice Track an agreement for a lender position key.
    function addLenderAgreement(
        DirectTypes.DirectStorage storage ds,
        bytes32 lenderKey,
        uint256 agreementId
    ) internal {
        ds.lenderAgreements.add(lenderKey, agreementId);
    }

    /// @notice Remove an agreement from a borrower position key using swap-and-pop.
    function removeBorrowerAgreement(
        DirectTypes.DirectStorage storage ds,
        bytes32 borrowerKey,
        uint256 agreementId
    ) internal {
        ds.borrowerAgreements.remove(borrowerKey, agreementId);
    }

    /// @notice Remove an agreement from a lender position key using swap-and-pop.
    function removeLenderAgreement(
        DirectTypes.DirectStorage storage ds,
        bytes32 lenderKey,
        uint256 agreementId
    ) internal {
        ds.lenderAgreements.remove(lenderKey, agreementId);
    }

    /// @notice Return a paginated slice of borrower agreements for a position key.
    function borrowerAgreementsPage(
        DirectTypes.DirectStorage storage ds,
        bytes32 borrowerKey,
        uint256 offset,
        uint256 limit
    ) internal view returns (uint256[] memory agreements, uint256 total) {
        return ds.borrowerAgreements.page(borrowerKey, offset, limit);
    }

    /// @notice Return a paginated slice of lender agreements for a position key.
    function lenderAgreementsPage(
        DirectTypes.DirectStorage storage ds,
        bytes32 lenderKey,
        uint256 offset,
        uint256 limit
    ) internal view returns (uint256[] memory agreements, uint256 total) {
        return ds.lenderAgreements.page(lenderKey, offset, limit);
    }

    /// @notice Return a paginated slice of lender offers for a position key.
    function lenderOffersPage(
        DirectTypes.DirectStorage storage ds,
        bytes32 positionKey,
        uint256 offset,
        uint256 limit
    ) internal view returns (uint256[] memory offers, uint256 total) {
        return ds.lenderOffers.page(positionKey, offset, limit);
    }

    /// @notice Return a paginated slice of borrower-originated offers for a position key.
    function borrowerOffersPage(
        DirectTypes.DirectStorage storage ds,
        bytes32 positionKey,
        uint256 offset,
        uint256 limit
    ) internal view returns (uint256[] memory offers, uint256 total) {
        return ds.borrowerOffersByPosition.page(positionKey, offset, limit);
    }

    /// @notice Return a paginated slice of ratio tranche lender offers for a position key.
    function ratioLenderOffersPage(
        DirectTypes.DirectStorage storage ds,
        bytes32 positionKey,
        uint256 offset,
        uint256 limit
    ) internal view returns (uint256[] memory offers, uint256 total) {
        return ds.ratioLenderOffers.page(positionKey, offset, limit);
    }

    /// @notice Track a rolling agreement for a borrower position key.
    function addRollingBorrowerAgreement(
        DirectTypes.DirectStorage storage ds,
        bytes32 borrowerKey,
        uint256 agreementId
    ) internal {
        ds.rollingBorrowerAgreements.add(borrowerKey, agreementId);
    }

    /// @notice Track a rolling agreement for a lender position key.
    function addRollingLenderAgreement(
        DirectTypes.DirectStorage storage ds,
        bytes32 lenderKey,
        uint256 agreementId
    ) internal {
        ds.rollingLenderAgreements.add(lenderKey, agreementId);
    }

    /// @notice Remove a rolling agreement from a borrower position key using swap-and-pop.
    function removeRollingBorrowerAgreement(
        DirectTypes.DirectStorage storage ds,
        bytes32 borrowerKey,
        uint256 agreementId
    ) internal {
        ds.rollingBorrowerAgreements.remove(borrowerKey, agreementId);
    }

    /// @notice Remove a rolling agreement from a lender position key using swap-and-pop.
    function removeRollingLenderAgreement(
        DirectTypes.DirectStorage storage ds,
        bytes32 lenderKey,
        uint256 agreementId
    ) internal {
        ds.rollingLenderAgreements.remove(lenderKey, agreementId);
    }

    /// @notice Return a paginated slice of rolling borrower agreements for a position key.
    function rollingBorrowerAgreementsPage(
        DirectTypes.DirectStorage storage ds,
        bytes32 borrowerKey,
        uint256 offset,
        uint256 limit
    ) internal view returns (uint256[] memory agreements, uint256 total) {
        return ds.rollingBorrowerAgreements.page(borrowerKey, offset, limit);
    }

    /// @notice Return a paginated slice of rolling lender agreements for a position key.
    function rollingLenderAgreementsPage(
        DirectTypes.DirectStorage storage ds,
        bytes32 lenderKey,
        uint256 offset,
        uint256 limit
    ) internal view returns (uint256[] memory agreements, uint256 total) {
        return ds.rollingLenderAgreements.page(lenderKey, offset, limit);
    }

    /// @notice Return a paginated slice of rolling lender offers for a position key.
    function rollingLenderOffersPage(
        DirectTypes.DirectStorage storage ds,
        bytes32 positionKey,
        uint256 offset,
        uint256 limit
    ) internal view returns (uint256[] memory offers, uint256 total) {
        return ds.rollingLenderOffers.page(positionKey, offset, limit);
    }

    /// @notice Return a paginated slice of rolling borrower-originated offers for a position key.
    function rollingBorrowerOffersPage(
        DirectTypes.DirectStorage storage ds,
        bytes32 positionKey,
        uint256 offset,
        uint256 limit
    ) internal view returns (uint256[] memory offers, uint256 total) {
        return ds.rollingBorrowerOffersByPosition.page(positionKey, offset, limit);
    }

    /// @notice Determine whether a position has any outstanding direct or rolling offers.
    function hasOutstandingOffers(bytes32 positionKey) internal view returns (bool) {
        DirectTypes.DirectStorage storage ds = directStorage();
        (, , uint256 lenderOfferCount) = ds.lenderOffers.meta(positionKey);
        (, , uint256 ratioLenderOfferCount) = ds.ratioLenderOffers.meta(positionKey);
        (, , uint256 borrowerOfferCount) = ds.borrowerOffersByPosition.meta(positionKey);
        (, , uint256 rollingLenderOfferCount) = ds.rollingLenderOffers.meta(positionKey);
        (, , uint256 rollingBorrowerOfferCount) = ds.rollingBorrowerOffersByPosition.meta(positionKey);
        (, , uint256 ratioBorrowerOfferCount) = ds.ratioBorrowerOffers.meta(positionKey);
        return lenderOfferCount > 0
            || ratioLenderOfferCount > 0
            || borrowerOfferCount > 0
            || rollingLenderOfferCount > 0
            || rollingBorrowerOfferCount > 0
            || ratioBorrowerOfferCount > 0;
    }

    function trackLenderOffer(DirectTypes.DirectStorage storage ds, bytes32 positionKey, uint256 offerId) internal {
        ds.lenderOffers.add(positionKey, offerId);
    }

    function trackRatioLenderOffer(DirectTypes.DirectStorage storage ds, bytes32 positionKey, uint256 offerId) internal {
        ds.ratioLenderOffers.add(positionKey, offerId);
    }

    function trackBorrowerOffer(DirectTypes.DirectStorage storage ds, bytes32 positionKey, uint256 offerId) internal {
        ds.borrowerOffersByPosition.add(positionKey, offerId);
    }

    function untrackLenderOffer(DirectTypes.DirectStorage storage ds, bytes32 positionKey, uint256 offerId) internal {
        ds.lenderOffers.remove(positionKey, offerId);
    }

    function untrackRatioLenderOffer(DirectTypes.DirectStorage storage ds, bytes32 positionKey, uint256 offerId) internal {
        ds.ratioLenderOffers.remove(positionKey, offerId);
    }

    function untrackBorrowerOffer(DirectTypes.DirectStorage storage ds, bytes32 positionKey, uint256 offerId) internal {
        ds.borrowerOffersByPosition.remove(positionKey, offerId);
    }

    function trackRollingLenderOffer(
        DirectTypes.DirectStorage storage ds,
        bytes32 positionKey,
        uint256 offerId
    ) internal {
        ds.rollingLenderOffers.add(positionKey, offerId);
    }

    function trackRollingBorrowerOffer(
        DirectTypes.DirectStorage storage ds,
        bytes32 positionKey,
        uint256 offerId
    ) internal {
        ds.rollingBorrowerOffersByPosition.add(positionKey, offerId);
    }

    function untrackRollingLenderOffer(
        DirectTypes.DirectStorage storage ds,
        bytes32 positionKey,
        uint256 offerId
    ) internal {
        ds.rollingLenderOffers.remove(positionKey, offerId);
    }

    function untrackRollingBorrowerOffer(
        DirectTypes.DirectStorage storage ds,
        bytes32 positionKey,
        uint256 offerId
    ) internal {
        ds.rollingBorrowerOffersByPosition.remove(positionKey, offerId);
    }

    function trackRatioBorrowerOffer(DirectTypes.DirectStorage storage ds, bytes32 positionKey, uint256 offerId) internal {
        ds.ratioBorrowerOffers.add(positionKey, offerId);
    }

    function untrackRatioBorrowerOffer(DirectTypes.DirectStorage storage ds, bytes32 positionKey, uint256 offerId) internal {
        ds.ratioBorrowerOffers.remove(positionKey, offerId);
    }

    /// @notice Return a paginated slice of borrower ratio tranche offers for a position key.
    function ratioBorrowerOffersPage(
        DirectTypes.DirectStorage storage ds,
        bytes32 positionKey,
        uint256 offset,
        uint256 limit
    ) internal view returns (uint256[] memory offers, uint256 total) {
        return ds.ratioBorrowerOffers.page(positionKey, offset, limit);
    }

    /// @notice Cancel all outstanding lender and borrower offers for a position (used on NFT transfer).
    function cancelOffersForPosition(bytes32 positionKey) internal {
        DirectTypes.DirectStorage storage ds = directStorage();
        (uint256[] memory lenderList, ) = ds.lenderOffers.page(positionKey, 0, 0);
        for (uint256 i = 0; i < lenderList.length; i++) {
            uint256 offerId = lenderList[i];
            untrackLenderOffer(ds, positionKey, offerId);
            DirectTypes.DirectOffer storage offer = ds.offers[offerId];
            if (offer.lenderPositionId == 0 || offer.cancelled || offer.filled) {
                continue;
            }
            offer.cancelled = true;
            Types.PoolData storage lenderPool = LibAppStorage.s().pools[offer.lenderPoolId];
            LibActiveCreditIndex.settle(offer.lenderPoolId, positionKey);
            LibEncumbrance.Encumbrance storage enc = LibEncumbrance.position(positionKey, offer.lenderPoolId);
            uint256 encBefore = LibEncumbrance.totalForActiveCredit(positionKey, offer.lenderPoolId);
            uint256 escrowed = enc.directOfferEscrow;
            uint256 release = offer.isTranche ? ds.trancheRemaining[offerId] : offer.principal;
            if (release > escrowed) {
                release = escrowed;
            }
            enc.directOfferEscrow = escrowed - release;
            uint256 encAfter = LibEncumbrance.totalForActiveCredit(positionKey, offer.lenderPoolId);
            LibActiveCreditIndex.applyEncumbranceDelta(
                lenderPool, offer.lenderPoolId, positionKey, encBefore, encAfter
            );
            if (offer.isTranche) {
                ds.trancheRemaining[offerId] = 0;
            }
        }

        (uint256[] memory borrowerList, ) = ds.borrowerOffersByPosition.page(positionKey, 0, 0);
        for (uint256 i = 0; i < borrowerList.length; i++) {
            uint256 offerId = borrowerList[i];
            untrackBorrowerOffer(ds, positionKey, offerId);
            DirectTypes.DirectBorrowerOffer storage offer = ds.borrowerOffers[offerId];
            if (offer.borrowerPositionId == 0 || offer.cancelled || offer.filled) {
                continue;
            }
            offer.cancelled = true;
            Types.PoolData storage collateralPool = LibAppStorage.s().pools[offer.collateralPoolId];
            LibActiveCreditIndex.settle(offer.collateralPoolId, positionKey);
            LibEncumbrance.Encumbrance storage enc = LibEncumbrance.position(positionKey, offer.collateralPoolId);
            uint256 encBefore = LibEncumbrance.totalForActiveCredit(positionKey, offer.collateralPoolId);
            uint256 locked = enc.directLocked;
            if (locked >= offer.collateralLockAmount) {
                enc.directLocked = locked - offer.collateralLockAmount;
            } else {
                enc.directLocked = 0;
            }
            uint256 encAfter = LibEncumbrance.totalForActiveCredit(positionKey, offer.collateralPoolId);
            LibActiveCreditIndex.applyEncumbranceDelta(
                collateralPool, offer.collateralPoolId, positionKey, encBefore, encAfter
            );
        }

        (uint256[] memory ratioList, ) = ds.ratioLenderOffers.page(positionKey, 0, 0);
        for (uint256 i = 0; i < ratioList.length; i++) {
            uint256 offerId = ratioList[i];
            untrackRatioLenderOffer(ds, positionKey, offerId);
            DirectTypes.DirectRatioTrancheOffer storage offer = ds.ratioOffers[offerId];
            if (offer.lenderPositionId == 0 || offer.cancelled || offer.filled) {
                continue;
            }
            offer.cancelled = true;
            offer.filled = true;
            Types.PoolData storage lenderPool = LibAppStorage.s().pools[offer.lenderPoolId];
            LibActiveCreditIndex.settle(offer.lenderPoolId, positionKey);
            LibEncumbrance.Encumbrance storage enc = LibEncumbrance.position(positionKey, offer.lenderPoolId);
            uint256 encBefore = LibEncumbrance.totalForActiveCredit(positionKey, offer.lenderPoolId);
            uint256 escrowed = enc.directOfferEscrow;
            uint256 release = offer.principalRemaining;
            if (release > escrowed) {
                release = escrowed;
            }
            offer.principalRemaining = 0;
            enc.directOfferEscrow = escrowed - release;
            uint256 encAfter = LibEncumbrance.totalForActiveCredit(positionKey, offer.lenderPoolId);
            LibActiveCreditIndex.applyEncumbranceDelta(
                lenderPool, offer.lenderPoolId, positionKey, encBefore, encAfter
            );
        }

        // Cancel borrower ratio tranche offers
        (uint256[] memory borrowerRatioList, ) = ds.ratioBorrowerOffers.page(positionKey, 0, 0);
        for (uint256 i = 0; i < borrowerRatioList.length; i++) {
            uint256 offerId = borrowerRatioList[i];
            untrackRatioBorrowerOffer(ds, positionKey, offerId);
            DirectTypes.DirectBorrowerRatioTrancheOffer storage offer = ds.borrowerRatioOffers[offerId];
            if (offer.borrowerPositionId == 0 || offer.cancelled || offer.filled) {
                continue;
            }
            offer.cancelled = true;
            offer.filled = true;
            Types.PoolData storage collateralPool = LibAppStorage.s().pools[offer.collateralPoolId];
            LibActiveCreditIndex.settle(offer.collateralPoolId, positionKey);
            LibEncumbrance.Encumbrance storage enc = LibEncumbrance.position(positionKey, offer.collateralPoolId);
            uint256 encBefore = LibEncumbrance.totalForActiveCredit(positionKey, offer.collateralPoolId);
            uint256 locked = enc.directLocked;
            uint256 release = offer.collateralRemaining;
            if (release > locked) {
                release = locked;
            }
            offer.collateralRemaining = 0;
            enc.directLocked = locked - release;
            uint256 encAfter = LibEncumbrance.totalForActiveCredit(positionKey, offer.collateralPoolId);
            LibActiveCreditIndex.applyEncumbranceDelta(
                collateralPool, offer.collateralPoolId, positionKey, encBefore, encAfter
            );
        }

    }
}
