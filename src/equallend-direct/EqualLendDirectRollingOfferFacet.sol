// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {PositionNFT} from "../nft/PositionNFT.sol";
import {Types} from "../libraries/Types.sol";
import {LibFeeIndex} from "../libraries/LibFeeIndex.sol";
import {LibActiveCreditIndex} from "../libraries/LibActiveCreditIndex.sol";
import {LibPoolMembership} from "../libraries/LibPoolMembership.sol";
import {ReentrancyGuardModifiers} from "../libraries/LibReentrancyGuard.sol";
import {InsufficientPrincipal, NotNFTOwner} from "../libraries/Errors.sol";
import {DirectTypes} from "../libraries/DirectTypes.sol";
import {LibDirectHelpers} from "../libraries/LibDirectHelpers.sol";
import {LibEncumbrance} from "../libraries/LibEncumbrance.sol";
import {LibDirectStorage} from "../libraries/LibDirectStorage.sol";
import {LibSolvencyChecks} from "../libraries/LibSolvencyChecks.sol";
import {LibDirectRolling} from "../libraries/LibDirectRolling.sol";
import {DirectError_InvalidAsset, DirectError_InvalidOffer, DirectError_ZeroAmount} from "../libraries/Errors.sol";

/// @notice Rolling-offer entrypoints for EqualLend Direct
contract EqualLendDirectRollingOfferFacet is ReentrancyGuardModifiers {
    event RollingBorrowerOfferPosted(
        uint256 indexed offerId,
        address indexed borrowAsset,
        uint256 indexed collateralPoolId,
        address borrower,
        uint256 borrowerPositionId,
        uint256 lenderPoolId,
        address collateralAsset,
        uint256 principal,
        uint32 paymentIntervalSeconds,
        uint16 rollingApyBps,
        uint32 gracePeriodSeconds,
        uint16 maxPaymentCount,
        uint256 upfrontPremium,
        bool allowAmortization,
        bool allowEarlyRepay,
        bool allowEarlyExercise,
        uint256 collateralLockAmount
    );

    event RollingBorrowerOfferLocator(
        address indexed borrower,
        uint256 indexed borrowerPositionId,
        uint256 indexed offerId,
        uint256 lenderPoolId,
        uint256 collateralPoolId
    );

    event RollingOfferPosted(
        uint256 indexed offerId,
        address indexed borrowAsset,
        uint256 indexed collateralPoolId,
        address lender,
        uint256 lenderPositionId,
        uint256 lenderPoolId,
        address collateralAsset,
        uint256 principal,
        uint32 paymentIntervalSeconds,
        uint16 rollingApyBps,
        uint32 gracePeriodSeconds,
        uint16 maxPaymentCount,
        uint256 upfrontPremium,
        bool allowAmortization,
        bool allowEarlyRepay,
        bool allowEarlyExercise,
        uint256 collateralLockAmount
    );

    event RollingOfferLocator(
        address indexed lender,
        uint256 indexed lenderPositionId,
        uint256 indexed offerId,
        uint256 lenderPoolId,
        uint256 collateralPoolId
    );

    event RollingOfferCancelled(uint256 indexed offerId, bool indexed isBorrowerOffer, address indexed caller);

    function postBorrowerRollingOffer(DirectTypes.DirectRollingBorrowerOfferParams calldata params)
        external
        nonReentrant
        returns (uint256 offerId)
    {
        PositionNFT nft = LibDirectHelpers._positionNFT();
        LibDirectHelpers._requireNFTOwnership(nft, params.borrowerPositionId);
        _validateRollingOfferFlags(params.allowEarlyRepay, params.allowEarlyExercise, params.allowAmortization);
        _validateRollingAmounts(params.principal, params.collateralLockAmount, params.borrowAsset, params.collateralAsset);

        Types.PoolData storage lenderPool = LibDirectHelpers._pool(params.lenderPoolId);
        Types.PoolData storage collateralPool = LibDirectHelpers._pool(params.collateralPoolId);
        if (params.borrowAsset != lenderPool.underlying) revert DirectError_InvalidAsset();
        if (params.collateralAsset != collateralPool.underlying) revert DirectError_InvalidAsset();

        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        LibDirectRolling.validateRollingOfferParams(_asOfferParams(params), ds.rollingConfig);

        bytes32 positionKey = nft.getPositionKey(params.borrowerPositionId);
        LibFeeIndex.settle(params.collateralPoolId, positionKey);
        LibActiveCreditIndex.settle(params.collateralPoolId, positionKey);
        if (!LibPoolMembership.isMember(positionKey, params.collateralPoolId)) {
            revert DirectError_InvalidOffer();
        }

        uint256 principal = collateralPool.userPrincipal[positionKey];
        uint256 locked = LibEncumbrance.position(positionKey, params.collateralPoolId).directLocked;
        if (locked > principal) {
            revert InsufficientPrincipal(locked, principal);
        }
        uint256 available = principal - locked;
        if (params.collateralLockAmount > available) {
            revert InsufficientPrincipal(params.collateralLockAmount, available);
        }

        uint256 currentBorrowerDebt =
            LibSolvencyChecks.calculateTotalDebt(collateralPool, positionKey, params.collateralPoolId);
        require(
            LibSolvencyChecks.checkSolvency(collateralPool, positionKey, principal, currentBorrowerDebt),
            "SolvencyViolation: Borrower LTV"
        );

        uint256 encBefore = LibEncumbrance.totalForActiveCredit(positionKey, params.collateralPoolId);
        LibEncumbrance.position(positionKey, params.collateralPoolId).directLocked = locked + params.collateralLockAmount;
        uint256 encAfter = LibEncumbrance.totalForActiveCredit(positionKey, params.collateralPoolId);
        LibActiveCreditIndex.applyEncumbranceDelta(
            collateralPool, params.collateralPoolId, positionKey, encBefore, encAfter
        );

        offerId = ++ds.nextRollingBorrowerOfferId;

        ds.rollingBorrowerOffers[offerId] = DirectTypes.DirectRollingBorrowerOffer({
            offerId: offerId,
            isRolling: true,
            borrower: msg.sender,
            borrowerPositionId: params.borrowerPositionId,
            lenderPoolId: params.lenderPoolId,
            collateralPoolId: params.collateralPoolId,
            collateralAsset: params.collateralAsset,
            borrowAsset: params.borrowAsset,
            principal: params.principal,
            collateralLockAmount: params.collateralLockAmount,
            paymentIntervalSeconds: params.paymentIntervalSeconds,
            rollingApyBps: params.rollingApyBps,
            gracePeriodSeconds: params.gracePeriodSeconds,
            maxPaymentCount: params.maxPaymentCount,
            upfrontPremium: params.upfrontPremium,
            allowAmortization: params.allowAmortization,
            allowEarlyRepay: params.allowEarlyRepay,
            allowEarlyExercise: params.allowEarlyExercise,
            cancelled: false,
            filled: false
        });
        LibDirectStorage.trackRollingBorrowerOffer(ds, positionKey, offerId);

        emit RollingBorrowerOfferPosted(
            offerId,
            params.borrowAsset,
            params.collateralPoolId,
            msg.sender,
            params.borrowerPositionId,
            params.lenderPoolId,
            params.collateralAsset,
            params.principal,
            params.paymentIntervalSeconds,
            params.rollingApyBps,
            params.gracePeriodSeconds,
            params.maxPaymentCount,
            params.upfrontPremium,
            params.allowAmortization,
            params.allowEarlyRepay,
            params.allowEarlyExercise,
            params.collateralLockAmount
        );

        emit RollingBorrowerOfferLocator(
            msg.sender,
            params.borrowerPositionId,
            offerId,
            params.lenderPoolId,
            params.collateralPoolId
        );
    }

    function postRollingOffer(DirectTypes.DirectRollingOfferParams calldata params)
        external
        nonReentrant
        returns (uint256 offerId)
    {
        PositionNFT nft = LibDirectHelpers._positionNFT();
        LibDirectHelpers._requireNFTOwnership(nft, params.lenderPositionId);
        _validateRollingOfferFlags(params.allowEarlyRepay, params.allowEarlyExercise, params.allowAmortization);
        _validateRollingAmounts(params.principal, params.collateralLockAmount, params.borrowAsset, params.collateralAsset);

        Types.PoolData storage lenderPool = LibDirectHelpers._pool(params.lenderPoolId);
        Types.PoolData storage collateralPool = LibDirectHelpers._pool(params.collateralPoolId);
        if (params.borrowAsset != lenderPool.underlying) revert DirectError_InvalidAsset();
        if (params.collateralAsset != collateralPool.underlying) revert DirectError_InvalidAsset();

        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        LibDirectRolling.validateRollingOfferParams(params, ds.rollingConfig);

        bytes32 positionKey = nft.getPositionKey(params.lenderPositionId);
        LibFeeIndex.settle(params.lenderPoolId, positionKey);
        LibActiveCreditIndex.settle(params.lenderPoolId, positionKey);
        if (!LibPoolMembership.isMember(positionKey, params.lenderPoolId)) {
            revert DirectError_InvalidOffer();
        }

        uint256 currentPrincipal = lenderPool.userPrincipal[positionKey];
        uint256 offerEscrow = LibEncumbrance.position(positionKey, params.lenderPoolId).directOfferEscrow;
        if (offerEscrow > currentPrincipal) {
            revert InsufficientPrincipal(offerEscrow, currentPrincipal);
        }
        uint256 principalAvailable = currentPrincipal - offerEscrow;
        if (params.principal > principalAvailable) {
            revert InsufficientPrincipal(params.principal, principalAvailable);
        }

        uint256 newLenderPrincipal = currentPrincipal - (offerEscrow + params.principal);
        uint256 currentLenderDebt = LibSolvencyChecks.calculateTotalDebt(lenderPool, positionKey, params.lenderPoolId);
        require(
            LibSolvencyChecks.checkSolvency(lenderPool, positionKey, newLenderPrincipal, currentLenderDebt),
            "SolvencyViolation: Lender LTV"
        );

        uint256 encBefore = LibEncumbrance.totalForActiveCredit(positionKey, params.lenderPoolId);
        LibEncumbrance.position(positionKey, params.lenderPoolId).directOfferEscrow = offerEscrow + params.principal;
        uint256 encAfter = LibEncumbrance.totalForActiveCredit(positionKey, params.lenderPoolId);
        LibActiveCreditIndex.applyEncumbranceDelta(
            lenderPool, params.lenderPoolId, positionKey, encBefore, encAfter
        );
        offerId = ++ds.nextRollingOfferId;

        ds.rollingOffers[offerId] = DirectTypes.DirectRollingOffer({
            offerId: offerId,
            isRolling: true,
            lender: msg.sender,
            lenderPositionId: params.lenderPositionId,
            lenderPoolId: params.lenderPoolId,
            collateralPoolId: params.collateralPoolId,
            collateralAsset: params.collateralAsset,
            borrowAsset: params.borrowAsset,
            principal: params.principal,
            collateralLockAmount: params.collateralLockAmount,
            paymentIntervalSeconds: params.paymentIntervalSeconds,
            rollingApyBps: params.rollingApyBps,
            gracePeriodSeconds: params.gracePeriodSeconds,
            maxPaymentCount: params.maxPaymentCount,
            upfrontPremium: params.upfrontPremium,
            allowAmortization: params.allowAmortization,
            allowEarlyRepay: params.allowEarlyRepay,
            allowEarlyExercise: params.allowEarlyExercise,
            cancelled: false,
            filled: false
        });
        LibDirectStorage.trackRollingLenderOffer(ds, positionKey, offerId);

        emit RollingOfferPosted(
            offerId,
            params.borrowAsset,
            params.collateralPoolId,
            msg.sender,
            params.lenderPositionId,
            params.lenderPoolId,
            params.collateralAsset,
            params.principal,
            params.paymentIntervalSeconds,
            params.rollingApyBps,
            params.gracePeriodSeconds,
            params.maxPaymentCount,
            params.upfrontPremium,
            params.allowAmortization,
            params.allowEarlyRepay,
            params.allowEarlyExercise,
            params.collateralLockAmount
        );

        emit RollingOfferLocator(
            msg.sender,
            params.lenderPositionId,
            offerId,
            params.lenderPoolId,
            params.collateralPoolId
        );
    }

    function cancelRollingOffer(uint256 offerId) external nonReentrant {
        PositionNFT nft = LibDirectHelpers._positionNFT();
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        DirectTypes.DirectRollingOffer storage offer = ds.rollingOffers[offerId];

        if (offer.lender != address(0)) {
            if (offer.cancelled || offer.filled) revert DirectError_InvalidOffer();
            LibDirectHelpers._requireNFTOwnership(nft, offer.lenderPositionId);
            if (offer.lender != msg.sender) {
                revert NotNFTOwner(msg.sender, offer.lenderPositionId);
            }
            offer.cancelled = true;
            bytes32 positionKey = nft.getPositionKey(offer.lenderPositionId);
            LibActiveCreditIndex.settle(offer.lenderPoolId, positionKey);
            Types.PoolData storage lenderPool = LibDirectHelpers._pool(offer.lenderPoolId);
            uint256 escrowed = LibEncumbrance.position(positionKey, offer.lenderPoolId).directOfferEscrow;
            uint256 encBefore = LibEncumbrance.totalForActiveCredit(positionKey, offer.lenderPoolId);
            if (escrowed >= offer.principal) {
                LibEncumbrance.position(positionKey, offer.lenderPoolId).directOfferEscrow = escrowed - offer.principal;
            } else {
                LibEncumbrance.position(positionKey, offer.lenderPoolId).directOfferEscrow = 0;
            }
            uint256 encAfter = LibEncumbrance.totalForActiveCredit(positionKey, offer.lenderPoolId);
            LibActiveCreditIndex.applyEncumbranceDelta(
                lenderPool, offer.lenderPoolId, positionKey, encBefore, encAfter
            );
            LibDirectStorage.untrackRollingLenderOffer(ds, positionKey, offerId);
            emit RollingOfferCancelled(offerId, false, msg.sender);
            return;
        }

        DirectTypes.DirectRollingBorrowerOffer storage borrowerOffer = ds.rollingBorrowerOffers[offerId];
        if (borrowerOffer.borrower == address(0) || borrowerOffer.cancelled || borrowerOffer.filled) {
            revert DirectError_InvalidOffer();
        }
        LibDirectHelpers._requireNFTOwnership(nft, borrowerOffer.borrowerPositionId);
        if (borrowerOffer.borrower != msg.sender) {
            revert NotNFTOwner(msg.sender, borrowerOffer.borrowerPositionId);
        }

        borrowerOffer.cancelled = true;
        bytes32 borrowerKey = nft.getPositionKey(borrowerOffer.borrowerPositionId);
        LibActiveCreditIndex.settle(borrowerOffer.collateralPoolId, borrowerKey);
        Types.PoolData storage collateralPool = LibDirectHelpers._pool(borrowerOffer.collateralPoolId);
        uint256 locked = LibEncumbrance.position(borrowerKey, borrowerOffer.collateralPoolId).directLocked;
        uint256 encBefore = LibEncumbrance.totalForActiveCredit(borrowerKey, borrowerOffer.collateralPoolId);
        if (locked >= borrowerOffer.collateralLockAmount) {
            LibEncumbrance.position(borrowerKey, borrowerOffer.collateralPoolId).directLocked = locked - borrowerOffer.collateralLockAmount;
        } else {
            LibEncumbrance.position(borrowerKey, borrowerOffer.collateralPoolId).directLocked = 0;
        }
        uint256 encAfter = LibEncumbrance.totalForActiveCredit(borrowerKey, borrowerOffer.collateralPoolId);
        LibActiveCreditIndex.applyEncumbranceDelta(
            collateralPool, borrowerOffer.collateralPoolId, borrowerKey, encBefore, encAfter
        );
        LibDirectStorage.untrackRollingBorrowerOffer(ds, borrowerKey, offerId);
        emit RollingOfferCancelled(offerId, true, msg.sender);
    }

    function getRollingOffer(uint256 offerId) external view returns (DirectTypes.DirectRollingOffer memory) {
        return LibDirectStorage.directStorage().rollingOffers[offerId];
    }

    function getRollingBorrowerOffer(uint256 offerId) external view returns (DirectTypes.DirectRollingBorrowerOffer memory) {
        return LibDirectStorage.directStorage().rollingBorrowerOffers[offerId];
    }

    function _validateRollingOfferFlags(bool allowEarlyRepay, bool allowEarlyExercise, bool /* allowAmortization */ )
        internal
        pure
    {
        if (allowEarlyRepay || allowEarlyExercise) {}
    }

    function _validateRollingAmounts(uint256 principal, uint256 collateralLockAmount, address borrowAsset, address collateralAsset)
        internal
        pure
    {
        if (borrowAsset == address(0) || collateralAsset == address(0)) revert DirectError_InvalidAsset();
        if (principal == 0 || collateralLockAmount == 0) revert DirectError_ZeroAmount();
    }

    function _asOfferParams(DirectTypes.DirectRollingBorrowerOfferParams memory params)
        internal
        pure
        returns (DirectTypes.DirectRollingOfferParams memory)
    {
        return DirectTypes.DirectRollingOfferParams({
            lenderPositionId: params.borrowerPositionId, // not used for validation ranges
            lenderPoolId: params.lenderPoolId,
            collateralPoolId: params.collateralPoolId,
            collateralAsset: params.collateralAsset,
            borrowAsset: params.borrowAsset,
            principal: params.principal,
            collateralLockAmount: params.collateralLockAmount,
            paymentIntervalSeconds: params.paymentIntervalSeconds,
            rollingApyBps: params.rollingApyBps,
            gracePeriodSeconds: params.gracePeriodSeconds,
            maxPaymentCount: params.maxPaymentCount,
            upfrontPremium: params.upfrontPremium,
            allowAmortization: params.allowAmortization,
            allowEarlyRepay: params.allowEarlyRepay,
            allowEarlyExercise: params.allowEarlyExercise
        });
    }
}
