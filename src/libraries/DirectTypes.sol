// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibPositionList} from "./LibPositionList.sol";

/// @notice Core data structures for EqualLend Direct facet
library DirectTypes {
    enum DirectStatus {
        Active,
        Repaid,
        Defaulted,
        Exercised
    }

    enum DirectCancelReason {
        Manual,
        AutoInsufficientTranche
    }

    struct DirectBorrowerOffer {
        uint256 offerId;
        address borrower;
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
    }

    struct DirectOffer {
        uint256 offerId;
        address lender;
        uint256 lenderPositionId;
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
        bool isTranche;
        uint256 trancheAmount;
    }

    struct DirectRatioTrancheOffer {
        uint256 offerId;
        address lender;
        uint256 lenderPositionId;
        uint256 lenderPoolId;
        uint256 collateralPoolId;
        address collateralAsset;
        address borrowAsset;
        uint256 principalCap;
        uint256 principalRemaining;
        uint256 priceNumerator;
        uint256 priceDenominator;
        uint256 minPrincipalPerFill;
        uint16 aprBps;
        uint64 durationSeconds;
        bool allowEarlyRepay;
        bool allowEarlyExercise;
        bool allowLenderCall;
        bool cancelled;
        bool filled;
    }

    /// @notice Borrower-posted ratio tranche offer for CLOB-style trading
    /// @dev Borrower locks collateralCap upfront; lenders fill variable amounts
    struct DirectBorrowerRatioTrancheOffer {
        uint256 offerId;
        address borrower;
        uint256 borrowerPositionId;
        uint256 lenderPoolId;
        uint256 collateralPoolId;
        address collateralAsset;
        address borrowAsset;
        uint256 collateralCap;           // Total collateral available for fills
        uint256 collateralRemaining;     // Unfilled collateral
        uint256 priceNumerator;          // principal = collateral * num / denom
        uint256 priceDenominator;
        uint256 minCollateralPerFill;    // Minimum collateral per fill
        uint16 aprBps;
        uint64 durationSeconds;
        bool allowEarlyRepay;
        bool allowEarlyExercise;
        bool allowLenderCall;
        bool cancelled;
        bool filled;
    }

    /// @notice Parameters for posting a borrower ratio tranche offer
    struct DirectBorrowerRatioTrancheParams {
        uint256 borrowerPositionId;
        uint256 lenderPoolId;
        uint256 collateralPoolId;
        address collateralAsset;
        address borrowAsset;
        uint256 collateralCap;
        uint256 priceNumerator;
        uint256 priceDenominator;
        uint256 minCollateralPerFill;
        uint16 aprBps;
        uint64 durationSeconds;
        bool allowEarlyRepay;
        bool allowEarlyExercise;
        bool allowLenderCall;
    }

    struct DirectAgreement {
        uint256 agreementId;
        address lender;
        address borrower;
        uint256 lenderPositionId;
        uint256 lenderPoolId;
        uint256 borrowerPositionId;
        uint256 collateralPoolId;
        address collateralAsset;
        address borrowAsset;
        uint256 principal;
        uint256 userInterest;
        uint64 dueTimestamp;
        uint256 collateralLockAmount;
        bool allowEarlyRepay;
        bool allowEarlyExercise;
        bool allowLenderCall;
        DirectStatus status;
        bool interestRealizedUpfront;
    }

    struct DirectBorrowerOfferParams {
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
    }

    struct DirectOfferParams {
        uint256 lenderPositionId;
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
    }

    struct DirectRatioTrancheParams {
        uint256 lenderPositionId;
        uint256 lenderPoolId;
        uint256 collateralPoolId;
        address collateralAsset;
        address borrowAsset;
        uint256 principalCap;
        uint256 priceNumerator;
        uint256 priceDenominator;
        uint256 minPrincipalPerFill;
        uint16 aprBps;
        uint64 durationSeconds;
        bool allowEarlyRepay;
        bool allowEarlyExercise;
        bool allowLenderCall;
    }

    struct DirectTrancheOfferParams {
        bool isTranche;
        uint256 trancheAmount;
    }

    struct DirectRollingOffer {
        uint256 offerId;
        bool isRolling;
        address lender;
        uint256 lenderPositionId;
        uint256 lenderPoolId;
        uint256 collateralPoolId;
        address collateralAsset;
        address borrowAsset;
        uint256 principal;
        uint256 collateralLockAmount;
        uint32 paymentIntervalSeconds;
        uint16 rollingApyBps;
        uint32 gracePeriodSeconds;
        uint16 maxPaymentCount;
        uint256 upfrontPremium;
        bool allowAmortization;
        bool allowEarlyRepay;
        bool allowEarlyExercise;
        bool cancelled;
        bool filled;
    }

    struct DirectRollingAgreement {
        uint256 agreementId;
        bool isRolling;
        address lender;
        address borrower;
        uint256 lenderPositionId;
        uint256 lenderPoolId;
        uint256 borrowerPositionId;
        uint256 collateralPoolId;
        address collateralAsset;
        address borrowAsset;
        uint256 principal;
        uint256 outstandingPrincipal;
        uint256 collateralLockAmount;
        uint256 upfrontPremium;
        uint64 nextDue;
        uint256 arrears;
        uint16 paymentCount;
        uint32 paymentIntervalSeconds;
        uint16 rollingApyBps;
        uint32 gracePeriodSeconds;
        uint16 maxPaymentCount;
        bool allowAmortization;
        bool allowEarlyRepay;
        bool allowEarlyExercise;
        uint64 lastAccrualTimestamp;
        DirectStatus status;
    }

    struct DirectRollingBorrowerOffer {
        uint256 offerId;
        bool isRolling;
        address borrower;
        uint256 borrowerPositionId;
        uint256 lenderPoolId;
        uint256 collateralPoolId;
        address collateralAsset;
        address borrowAsset;
        uint256 principal;
        uint256 collateralLockAmount;
        uint32 paymentIntervalSeconds;
        uint16 rollingApyBps;
        uint32 gracePeriodSeconds;
        uint16 maxPaymentCount;
        uint256 upfrontPremium;
        bool allowAmortization;
        bool allowEarlyRepay;
        bool allowEarlyExercise;
        bool cancelled;
        bool filled;
    }

    struct DirectRollingOfferParams {
        uint256 lenderPositionId;
        uint256 lenderPoolId;
        uint256 collateralPoolId;
        address collateralAsset;
        address borrowAsset;
        uint256 principal;
        uint256 collateralLockAmount;
        uint32 paymentIntervalSeconds;
        uint16 rollingApyBps;
        uint32 gracePeriodSeconds;
        uint16 maxPaymentCount;
        uint256 upfrontPremium;
        bool allowAmortization;
        bool allowEarlyRepay;
        bool allowEarlyExercise;
    }

    struct DirectRollingBorrowerOfferParams {
        uint256 borrowerPositionId;
        uint256 lenderPoolId;
        uint256 collateralPoolId;
        address collateralAsset;
        address borrowAsset;
        uint256 principal;
        uint256 collateralLockAmount;
        uint32 paymentIntervalSeconds;
        uint16 rollingApyBps;
        uint32 gracePeriodSeconds;
        uint16 maxPaymentCount;
        uint256 upfrontPremium;
        bool allowAmortization;
        bool allowEarlyRepay;
        bool allowEarlyExercise;
    }

    struct DirectRollingConfig {
        uint32 minPaymentIntervalSeconds; // e.g., 604800 (7 days)
        uint16 maxPaymentCount; // e.g., 520 payments
        uint16 maxUpfrontPremiumBps; // e.g., 5000 (50%)
        uint16 minRollingApyBps; // e.g., 1 (0.01%)
        uint16 maxRollingApyBps; // e.g., 10000 (100%)
        uint16 defaultPenaltyBps; // Penalty rate for defaults (bps)
        uint16 minPaymentBps; // Minimum payment as bps of outstanding principal
    }

    struct DirectConfig {
        uint16 platformFeeBps;
        uint16 interestLenderBps;
        uint16 platformFeeLenderBps;
        uint16 defaultLenderBps;
        uint40 minInterestDuration;
    }

    struct PositionDirectState {
        uint256 directLockedPrincipal;
        uint256 directLentPrincipal;
    }

    struct DirectTrancheView {
        bool isTranche;
        uint256 trancheAmount;
        uint256 trancheRemaining;
        uint256 principalPerFill;
        uint256 fillsRemaining;
        bool isDepleted;
        bool cancelled;
        bool filled;
    }

    struct DirectRatioTrancheView {
        uint256 principalCap;
        uint256 principalRemaining;
        uint256 priceNumerator;
        uint256 priceDenominator;
        uint256 minPrincipalPerFill;
        uint16 aprBps;
        uint64 durationSeconds;
        bool cancelled;
        bool filled;
    }

    struct DirectStorage {
        DirectConfig config;
        mapping(uint256 => DirectBorrowerOffer) borrowerOffers;
        mapping(uint256 => DirectOffer) offers;
        mapping(uint256 => DirectRatioTrancheOffer) ratioOffers;
        mapping(uint256 => DirectAgreement) agreements;
        uint256 nextOfferId;
        uint256 nextBorrowerOfferId;
        uint256 nextAgreementId;
        mapping(uint256 => uint256) trancheRemaining; // offerId => remaining tranche principal
        bool enforceFixedSizeFills; // enforce trancheAmount % principal == 0 when true
        mapping(bytes32 => mapping(uint256 => uint256)) directLockedPrincipal;
        mapping(bytes32 => mapping(uint256 => uint256)) directLentPrincipal;
        mapping(bytes32 => mapping(uint256 => uint256)) directBorrowedPrincipal;
        mapping(bytes32 => mapping(address => uint256)) directSameAssetDebt; // positionKey => asset => amount
        mapping(uint256 => uint256) activeDirectLentPerPool; // aggregate active lent principal per poolId
        mapping(bytes32 => mapping(uint256 => uint256)) directOfferEscrow;
        // Linked-list tracking for agreements/offers (per positionKey)
        LibPositionList.List borrowerAgreements;
        LibPositionList.List lenderAgreements;
        LibPositionList.List lenderOffers;
        LibPositionList.List borrowerOffersByPosition;
        LibPositionList.List ratioLenderOffers;

        // Rolling configuration and storage
        DirectRollingConfig rollingConfig;
        mapping(uint256 => DirectRollingOffer) rollingOffers;
        mapping(uint256 => DirectRollingAgreement) rollingAgreements;
        uint256 nextRollingOfferId;
        uint256 nextRollingAgreementId;
        LibPositionList.List rollingBorrowerAgreements;
        LibPositionList.List rollingLenderAgreements;
        LibPositionList.List rollingLenderOffers;
        mapping(uint256 => DirectRollingBorrowerOffer) rollingBorrowerOffers;
        uint256 nextRollingBorrowerOfferId;
        LibPositionList.List rollingBorrowerOffersByPosition;
        // Borrower ratio tranche offers
        mapping(uint256 => DirectBorrowerRatioTrancheOffer) borrowerRatioOffers;
        uint256 nextBorrowerRatioOfferId;
        LibPositionList.List ratioBorrowerOffers;

    }
}
