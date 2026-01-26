// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {PositionNFT} from "../nft/PositionNFT.sol";
import {LibAccess} from "../libraries/LibAccess.sol";
import {DirectTypes} from "../libraries/DirectTypes.sol";
import {LibDirectHelpers} from "../libraries/LibDirectHelpers.sol";
import {LibDirectStorage} from "../libraries/LibDirectStorage.sol";
import {DirectError_InvalidOffer} from "../libraries/Errors.sol";

/// @notice Read-only and config entrypoints for EqualLend direct lending
contract EqualLendDirectViewFacet {
    event DirectConfigUpdated(
        uint16 platformFeeBps,
        uint16 interestLenderBps,
        uint16 platformFeeLenderBps,
        uint16 defaultLenderBps,
        uint40 minInterestDuration
    );

    struct DirectOfferSummary {
        uint256 offerId;
        address lender;
        address borrower;
        uint256 lenderPositionId;
        uint256 borrowerPositionId;
        uint256 lenderPoolId;
        uint256 collateralPoolId;
        address collateralAsset;
        address borrowAsset;
        uint256 principal;
        uint16 aprBps;
        uint64 durationSeconds;
        uint256 collateralLockAmount;
        bool allowEarlyRepay;
        bool allowEarlyExercise;
        bool allowLenderCall;
        bool cancelled;
        bool filled;
        bool isBorrowerOffer;
    }

    function setDirectConfig(DirectTypes.DirectConfig calldata config) external {
        LibAccess.enforceOwnerOrTimelock();
        LibDirectHelpers._validateConfig(config);
        LibDirectStorage.directStorage().config = config;
        emit DirectConfigUpdated(
            config.platformFeeBps,
            config.interestLenderBps,
            config.platformFeeLenderBps,
            config.defaultLenderBps,
            config.minInterestDuration
        );
    }

    function getBorrowerOffer(uint256 offerId) external view returns (DirectTypes.DirectBorrowerOffer memory) {
        return LibDirectStorage.directStorage().borrowerOffers[offerId];
    }

    function getRatioTrancheOffer(uint256 offerId) external view returns (DirectTypes.DirectRatioTrancheOffer memory) {
        return LibDirectStorage.directStorage().ratioOffers[offerId];
    }

    function getBorrowerRatioTrancheOffer(uint256 offerId) external view returns (DirectTypes.DirectBorrowerRatioTrancheOffer memory) {
        return LibDirectStorage.directStorage().borrowerRatioOffers[offerId];
    }

    function getOffer(uint256 offerId) external view returns (DirectTypes.DirectOffer memory) {
        return LibDirectStorage.directStorage().offers[offerId];
    }

    function getOfferSummary(uint256 offerId) external view returns (DirectOfferSummary memory summary) {
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        DirectTypes.DirectBorrowerOffer storage borrowerOffer = ds.borrowerOffers[offerId];
        if (borrowerOffer.borrower != address(0)) {
            summary = DirectOfferSummary({
                offerId: borrowerOffer.offerId,
                lender: address(0),
                borrower: borrowerOffer.borrower,
                lenderPositionId: 0,
                borrowerPositionId: borrowerOffer.borrowerPositionId,
                lenderPoolId: borrowerOffer.lenderPoolId,
                collateralPoolId: borrowerOffer.collateralPoolId,
                collateralAsset: borrowerOffer.collateralAsset,
                borrowAsset: borrowerOffer.borrowAsset,
                principal: borrowerOffer.principal,
                aprBps: borrowerOffer.aprBps,
                durationSeconds: borrowerOffer.durationSeconds,
                collateralLockAmount: borrowerOffer.collateralLockAmount,
                allowEarlyRepay: borrowerOffer.allowEarlyRepay,
                allowEarlyExercise: borrowerOffer.allowEarlyExercise,
                allowLenderCall: borrowerOffer.allowLenderCall,
                cancelled: borrowerOffer.cancelled,
                filled: borrowerOffer.filled,
                isBorrowerOffer: true
            });
            return summary;
        }

        DirectTypes.DirectRatioTrancheOffer storage ratioOffer = ds.ratioOffers[offerId];
        if (ratioOffer.lender != address(0)) {
            summary = DirectOfferSummary({
                offerId: ratioOffer.offerId,
                lender: ratioOffer.lender,
                borrower: address(0),
                lenderPositionId: ratioOffer.lenderPositionId,
                borrowerPositionId: 0,
                lenderPoolId: ratioOffer.lenderPoolId,
                collateralPoolId: ratioOffer.collateralPoolId,
                collateralAsset: ratioOffer.collateralAsset,
                borrowAsset: ratioOffer.borrowAsset,
                principal: ratioOffer.principalRemaining,
                aprBps: ratioOffer.aprBps,
                durationSeconds: ratioOffer.durationSeconds,
                collateralLockAmount: ratioOffer.priceNumerator,
                allowEarlyRepay: ratioOffer.allowEarlyRepay,
                allowEarlyExercise: ratioOffer.allowEarlyExercise,
                allowLenderCall: ratioOffer.allowLenderCall,
                cancelled: ratioOffer.cancelled,
                filled: ratioOffer.filled,
                isBorrowerOffer: false
            });
            return summary;
        }

        DirectTypes.DirectOffer storage offer = ds.offers[offerId];
        if (offer.lender == address(0)) revert DirectError_InvalidOffer();

        summary = DirectOfferSummary({
            offerId: offer.offerId,
            lender: offer.lender,
            borrower: address(0),
            lenderPositionId: offer.lenderPositionId,
            borrowerPositionId: 0,
            lenderPoolId: offer.lenderPoolId,
            collateralPoolId: offer.collateralPoolId,
            collateralAsset: offer.collateralAsset,
            borrowAsset: offer.borrowAsset,
            principal: offer.principal,
            aprBps: offer.aprBps,
            durationSeconds: offer.durationSeconds,
            collateralLockAmount: offer.collateralLockAmount,
            allowEarlyRepay: offer.allowEarlyRepay,
            allowEarlyExercise: offer.allowEarlyExercise,
            allowLenderCall: offer.allowLenderCall,
            cancelled: offer.cancelled,
            filled: offer.filled,
            isBorrowerOffer: false
        });
    }

    function getAgreement(uint256 agreementId) external view returns (DirectTypes.DirectAgreement memory) {
        return LibDirectStorage.directStorage().agreements[agreementId];
    }

    function getPositionDirectState(uint256 positionId, uint256 poolId)
        external
        view
        returns (uint256 locked, uint256 lent)
    {
        PositionNFT nft = LibDirectHelpers._positionNFT();
        bytes32 positionKey = nft.getPositionKey(positionId);
        DirectTypes.PositionDirectState memory state = LibDirectStorage.positionState(positionKey, poolId);
        return (state.directLockedPrincipal, state.directLentPrincipal);
    }

    function getPoolActiveDirectLent(uint256 poolId) external view returns (uint256) {
        return LibDirectStorage.directStorage().activeDirectLentPerPool[poolId];
    }

    function getBorrowerAgreements(uint256 positionId, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory agreements)
    {
        PositionNFT nft = LibDirectHelpers._positionNFT();
        bytes32 positionKey = nft.getPositionKey(positionId);
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        (agreements,) = LibDirectStorage.borrowerAgreementsPage(ds, positionKey, offset, limit);
    }

    function getBorrowerOffers(uint256 positionId, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory offers, uint256 total)
    {
        PositionNFT nft = LibDirectHelpers._positionNFT();
        bytes32 positionKey = nft.getPositionKey(positionId);
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        (offers, total) = LibDirectStorage.borrowerOffersPage(ds, positionKey, offset, limit);
    }

    function getLenderOffers(uint256 positionId, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory offers, uint256 total)
    {
        PositionNFT nft = LibDirectHelpers._positionNFT();
        bytes32 positionKey = nft.getPositionKey(positionId);
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        (offers, total) = LibDirectStorage.lenderOffersPage(ds, positionKey, offset, limit);
    }

    function getRatioLenderOffers(uint256 positionId, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory offers, uint256 total)
    {
        PositionNFT nft = LibDirectHelpers._positionNFT();
        bytes32 positionKey = nft.getPositionKey(positionId);
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        (offers, total) = LibDirectStorage.ratioLenderOffersPage(ds, positionKey, offset, limit);
    }

    function getRatioBorrowerOffers(uint256 positionId, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory offers, uint256 total)
    {
        PositionNFT nft = LibDirectHelpers._positionNFT();
        bytes32 positionKey = nft.getPositionKey(positionId);
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        (offers, total) = LibDirectStorage.ratioBorrowerOffersPage(ds, positionKey, offset, limit);
    }

    function isTrancheOffer(uint256 offerId) external view returns (bool) {
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        DirectTypes.DirectOffer storage offer = ds.offers[offerId];
        if (offer.lender == address(0)) revert DirectError_InvalidOffer();
        return offer.isTranche;
    }

    function fillsRemaining(uint256 offerId) public view returns (uint256) {
        DirectTypes.DirectTrancheView memory status = _trancheStatus(offerId);
        return status.fillsRemaining;
    }

    function isTrancheDepleted(uint256 offerId) external view returns (bool) {
        DirectTypes.DirectTrancheView memory status = _trancheStatus(offerId);
        return status.isDepleted;
    }

    function getOfferTranche(uint256 offerId) external view returns (DirectTypes.DirectTrancheView memory) {
        return _trancheStatus(offerId);
    }

    function getTrancheStatus(uint256 offerId) external view returns (DirectTypes.DirectTrancheView memory) {
        return _trancheStatus(offerId);
    }

    function _trancheStatus(uint256 offerId) internal view returns (DirectTypes.DirectTrancheView memory viewData) {
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        DirectTypes.DirectOffer storage offer = ds.offers[offerId];
        if (offer.lender == address(0)) revert DirectError_InvalidOffer();
        uint256 trancheRemaining = offer.isTranche ? ds.trancheRemaining[offerId] : 0;
        bool isDepleted = offer.isTranche ? trancheRemaining == 0 : (offer.cancelled || offer.filled);
        uint256 fills = offer.isTranche ? trancheRemaining / offer.principal : (isDepleted ? 0 : 1);

        viewData = DirectTypes.DirectTrancheView({
            isTranche: offer.isTranche,
            trancheAmount: offer.trancheAmount,
            trancheRemaining: trancheRemaining,
            principalPerFill: offer.principal,
            fillsRemaining: fills,
            isDepleted: isDepleted,
            cancelled: offer.cancelled,
            filled: offer.filled
        });
    }

    function getRatioTrancheStatus(uint256 offerId) external view returns (DirectTypes.DirectRatioTrancheView memory) {
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        DirectTypes.DirectRatioTrancheOffer storage offer = ds.ratioOffers[offerId];
        if (offer.lender == address(0)) revert DirectError_InvalidOffer();
        return DirectTypes.DirectRatioTrancheView({
            principalCap: offer.principalCap,
            principalRemaining: offer.principalRemaining,
            priceNumerator: offer.priceNumerator,
            priceDenominator: offer.priceDenominator,
            minPrincipalPerFill: offer.minPrincipalPerFill,
            aprBps: offer.aprBps,
            durationSeconds: offer.durationSeconds,
            cancelled: offer.cancelled,
            filled: offer.filled
        });
    }
}
