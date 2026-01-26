// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {DirectTypes} from "../libraries/DirectTypes.sol";

/// @notice Shared events for EqualLend Direct offer lifecycle
interface IDirectOfferEvents {
    event DirectOfferCancelled(
        uint256 indexed offerId,
        address indexed lender,
        uint256 indexed lenderPositionId,
        DirectTypes.DirectCancelReason reason,
        uint256 trancheAmount,
        uint256 trancheRemainingAfter,
        uint256 amountReturned,
        uint256 fillsRemaining,
        bool isDepleted
    );

    event RatioTrancheOfferPosted(
        uint256 indexed offerId,
        address indexed lender,
        uint256 indexed lenderPositionId,
        uint256 lenderPoolId,
        uint256 collateralPoolId,
        address borrowAsset,
        address collateralAsset,
        uint256 principalCap,
        uint256 principalRemainingAfter,
        uint256 priceNumerator,
        uint256 priceDenominator,
        uint256 minPrincipalPerFill,
        uint16 aprBps,
        uint64 durationSeconds
    );

    event RatioTrancheOfferAccepted(
        uint256 indexed offerId,
        uint256 indexed agreementId,
        uint256 indexed borrowerPositionId,
        uint256 principalFilled,
        uint256 principalRemainingAfter,
        uint256 collateralLocked
    );

    event RatioTrancheOfferCancelled(
        uint256 indexed offerId,
        address indexed lender,
        uint256 indexed lenderPositionId,
        DirectTypes.DirectCancelReason reason,
        uint256 principalReleased
    );

    event BorrowerRatioTrancheOfferPosted(
        uint256 indexed offerId,
        address indexed borrower,
        uint256 indexed borrowerPositionId,
        uint256 lenderPoolId,
        uint256 collateralPoolId,
        address borrowAsset,
        address collateralAsset,
        uint256 collateralCap,
        uint256 collateralRemainingAfter,
        uint256 priceNumerator,
        uint256 priceDenominator,
        uint256 minCollateralPerFill,
        uint16 aprBps,
        uint64 durationSeconds
    );

    event BorrowerRatioTrancheOfferAccepted(
        uint256 indexed offerId,
        uint256 indexed agreementId,
        uint256 indexed lenderPositionId,
        uint256 collateralFilled,
        uint256 collateralRemainingAfter,
        uint256 principalAmount
    );

    event BorrowerRatioTrancheOfferCancelled(
        uint256 indexed offerId,
        address indexed borrower,
        uint256 indexed borrowerPositionId,
        DirectTypes.DirectCancelReason reason,
        uint256 collateralReleased
    );
}
