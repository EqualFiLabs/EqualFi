// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {PositionNFT} from "../nft/PositionNFT.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Types} from "../libraries/Types.sol";
import {LibFeeIndex} from "../libraries/LibFeeIndex.sol";
import {LibActiveCreditIndex} from "../libraries/LibActiveCreditIndex.sol";
import {LibAccess} from "../libraries/LibAccess.sol";
import {LibPoolMembership} from "../libraries/LibPoolMembership.sol";
import {ReentrancyGuardModifiers} from "../libraries/LibReentrancyGuard.sol";
import {InsufficientPrincipal, NotNFTOwner} from "../libraries/Errors.sol";
import {DirectTypes} from "../libraries/DirectTypes.sol";
import {LibDirectHelpers} from "../libraries/LibDirectHelpers.sol";
import {LibEncumbrance} from "../libraries/LibEncumbrance.sol";
import {LibDirectStorage} from "../libraries/LibDirectStorage.sol";
import {LibSolvencyChecks} from "../libraries/LibSolvencyChecks.sol";
import {IDirectOfferEvents} from "../interfaces/IDirectOfferEvents.sol";
import {
    DirectError_InvalidAsset,
    DirectError_InvalidOffer,
    DirectError_InvalidTrancheAmount
} from "../libraries/Errors.sol";

/// @notice Offer and cancellation entrypoints for EqualLend direct lending
contract EqualLendDirectOfferFacet is ReentrancyGuardModifiers, IDirectOfferEvents {
    event BorrowerOfferPosted(
        uint256 indexed offerId,
        address indexed borrowAsset,
        uint256 indexed collateralPoolId,
        address borrower,
        uint256 borrowerPositionId,
        uint256 lenderPoolId,
        address collateralAsset,
        uint256 principal,
        uint16 aprBps,
        uint64 durationSeconds,
        uint256 collateralLockAmount
    );

    event BorrowerOfferLocator(
        address indexed borrower,
        uint256 indexed borrowerPositionId,
        uint256 indexed offerId,
        uint256 lenderPoolId,
        uint256 collateralPoolId
    );

    event BorrowerOfferCancelled(uint256 indexed offerId, address indexed borrower, uint256 indexed borrowerPositionId);

    event DirectOfferPosted(
        uint256 indexed offerId,
        address indexed borrowAsset,
        uint256 indexed collateralPoolId,
        address lender,
        uint256 lenderPositionId,
        uint256 lenderPoolId,
        address collateralAsset,
        uint256 principal,
        uint16 aprBps,
        uint64 durationSeconds,
        uint256 collateralLockAmount,
        bool isTranche,
        uint256 trancheAmount,
        uint256 trancheRemainingAfter,
        uint256 fillsRemaining,
        uint256 maxFills,
        bool isDepleted
    );

    event DirectOfferLocator(
        address indexed lender,
        uint256 indexed lenderPositionId,
        uint256 indexed offerId,
        uint256 lenderPoolId,
        uint256 collateralPoolId
    );

    function postBorrowerOffer(DirectTypes.DirectBorrowerOfferParams calldata params)
        external
        returns (uint256 offerId)
    {
        PositionNFT nft = LibDirectHelpers._positionNFT();
        LibDirectHelpers._requireNFTOwnership(nft, params.borrowerPositionId);
        LibDirectHelpers._validateBorrowerOfferParams(params);

        Types.PoolData storage lenderPool = LibDirectHelpers._pool(params.lenderPoolId);
        Types.PoolData storage collateralPool = LibDirectHelpers._pool(params.collateralPoolId);
        if (params.borrowAsset != lenderPool.underlying) revert DirectError_InvalidAsset();
        if (params.collateralAsset != collateralPool.underlying) revert DirectError_InvalidAsset();

        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
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

        uint256 currentBorrowerDebt = LibSolvencyChecks.calculateTotalDebt(collateralPool, positionKey, params.collateralPoolId);
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

        offerId = ++ds.nextBorrowerOfferId;

        ds.borrowerOffers[offerId] = DirectTypes.DirectBorrowerOffer({
            offerId: offerId,
            borrower: msg.sender,
            borrowerPositionId: params.borrowerPositionId,
            lenderPoolId: params.lenderPoolId,
            collateralPoolId: params.collateralPoolId,
            collateralAsset: params.collateralAsset,
            borrowAsset: params.borrowAsset,
            principal: params.principal,
            aprBps: params.aprBps,
            durationSeconds: params.durationSeconds,
            collateralLockAmount: params.collateralLockAmount,
            allowEarlyRepay: params.allowEarlyRepay,
            allowEarlyExercise: params.allowEarlyExercise,
            allowLenderCall: params.allowLenderCall,
            cancelled: false,
            filled: false
        });
        LibDirectStorage.trackBorrowerOffer(ds, positionKey, offerId);

        emit BorrowerOfferPosted(
            offerId,
            params.borrowAsset,
            params.collateralPoolId,
            msg.sender,
            params.borrowerPositionId,
            params.lenderPoolId,
            params.collateralAsset,
            params.principal,
            params.aprBps,
            params.durationSeconds,
            params.collateralLockAmount
        );

        emit BorrowerOfferLocator(
            msg.sender,
            params.borrowerPositionId,
            offerId,
            params.lenderPoolId,
            params.collateralPoolId
        );
    }

    function cancelBorrowerOffer(uint256 offerId) external nonReentrant {
        PositionNFT nft = LibDirectHelpers._positionNFT();
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        DirectTypes.DirectBorrowerOffer storage offer = ds.borrowerOffers[offerId];
        if (offer.borrower == address(0) || offer.cancelled || offer.filled) {
            revert DirectError_InvalidOffer();
        }
        if (offer.borrower != msg.sender) {
            revert NotNFTOwner(msg.sender, offer.borrowerPositionId);
        }
        LibDirectHelpers._requireNFTOwnership(nft, offer.borrowerPositionId);

        offer.cancelled = true;
        bytes32 positionKey = nft.getPositionKey(offer.borrowerPositionId);
        LibActiveCreditIndex.settle(offer.collateralPoolId, positionKey);
        Types.PoolData storage collateralPool = LibDirectHelpers._pool(offer.collateralPoolId);
        uint256 locked = LibEncumbrance.position(positionKey, offer.collateralPoolId).directLocked;
        uint256 encBefore = LibEncumbrance.totalForActiveCredit(positionKey, offer.collateralPoolId);
        if (locked >= offer.collateralLockAmount) {
            LibEncumbrance.position(positionKey, offer.collateralPoolId).directLocked = locked - offer.collateralLockAmount;
        } else {
            LibEncumbrance.position(positionKey, offer.collateralPoolId).directLocked = 0;
        }
        uint256 encAfter = LibEncumbrance.totalForActiveCredit(positionKey, offer.collateralPoolId);
        LibActiveCreditIndex.applyEncumbranceDelta(
            collateralPool, offer.collateralPoolId, positionKey, encBefore, encAfter
        );
        LibDirectStorage.untrackBorrowerOffer(ds, positionKey, offerId);

        emit BorrowerOfferCancelled(offerId, msg.sender, offer.borrowerPositionId);
    }

    function postOffer(DirectTypes.DirectOfferParams calldata params) external nonReentrant returns (uint256 offerId) {
        DirectTypes.DirectTrancheOfferParams memory tranche =
            DirectTypes.DirectTrancheOfferParams({isTranche: false, trancheAmount: 0});
        offerId = _postOffer(params, tranche);
    }

    function postOffer(
        DirectTypes.DirectOfferParams calldata params,
        DirectTypes.DirectTrancheOfferParams calldata tranche
    ) external nonReentrant returns (uint256 offerId) {
        offerId = _postOffer(params, tranche);
    }

    function _postOffer(
        DirectTypes.DirectOfferParams calldata params,
        DirectTypes.DirectTrancheOfferParams memory tranche
    ) internal returns (uint256 offerId) {
        PositionNFT nft = LibDirectHelpers._positionNFT();
        LibDirectHelpers._requireNFTOwnership(nft, params.lenderPositionId);
        LibDirectHelpers._validateOfferParams(params);

        Types.PoolData storage lenderPool = LibDirectHelpers._pool(params.lenderPoolId);
        Types.PoolData storage collateralPool = LibDirectHelpers._pool(params.collateralPoolId);
        if (params.borrowAsset != lenderPool.underlying) revert DirectError_InvalidAsset();
        if (params.collateralAsset != collateralPool.underlying) revert DirectError_InvalidAsset();

        if (tranche.isTranche) {
            if (tranche.trancheAmount == 0 || tranche.trancheAmount < params.principal) {
                revert DirectError_InvalidTrancheAmount();
            }
            if (LibDirectStorage.directStorage().enforceFixedSizeFills) {
                if (tranche.trancheAmount % params.principal != 0) {
                    revert DirectError_InvalidTrancheAmount();
                }
            }
        }

        bytes32 positionKey = nft.getPositionKey(params.lenderPositionId);
        // Settle fee indices before availability checks to avoid stale principal usage
        LibFeeIndex.settle(params.lenderPoolId, positionKey);
        LibActiveCreditIndex.settle(params.lenderPoolId, positionKey);
        if (!LibPoolMembership.isMember(positionKey, params.lenderPoolId)) {
            revert DirectError_InvalidOffer();
        }
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        uint256 currentPrincipal = lenderPool.userPrincipal[positionKey];
        uint256 offerEscrow = LibEncumbrance.position(positionKey, params.lenderPoolId).directOfferEscrow;
        if (offerEscrow > currentPrincipal) {
            revert InsufficientPrincipal(offerEscrow, currentPrincipal);
        }
        uint256 principalAvailable = currentPrincipal - offerEscrow;
        uint256 escrowAmount = tranche.isTranche ? tranche.trancheAmount : params.principal;
        if (escrowAmount > principalAvailable) {
            revert InsufficientPrincipal(escrowAmount, principalAvailable);
        }

        uint256 newLenderPrincipal = currentPrincipal - (offerEscrow + escrowAmount);
        uint256 currentLenderDebt = LibSolvencyChecks.calculateTotalDebt(lenderPool, positionKey, params.lenderPoolId);
        require(
            LibSolvencyChecks.checkSolvency(lenderPool, positionKey, newLenderPrincipal, currentLenderDebt),
            "SolvencyViolation: Lender LTV"
        );

        uint256 encBefore = LibEncumbrance.totalForActiveCredit(positionKey, params.lenderPoolId);
        LibEncumbrance.position(positionKey, params.lenderPoolId).directOfferEscrow = offerEscrow + escrowAmount;
        uint256 encAfter = LibEncumbrance.totalForActiveCredit(positionKey, params.lenderPoolId);
        LibActiveCreditIndex.applyEncumbranceDelta(
            lenderPool, params.lenderPoolId, positionKey, encBefore, encAfter
        );
        offerId = ++ds.nextOfferId;

        ds.offers[offerId] = DirectTypes.DirectOffer({
            offerId: offerId,
            lender: msg.sender,
            lenderPositionId: params.lenderPositionId,
            lenderPoolId: params.lenderPoolId,
            collateralPoolId: params.collateralPoolId,
            collateralAsset: params.collateralAsset,
            borrowAsset: params.borrowAsset,
            principal: params.principal,
            aprBps: params.aprBps,
            durationSeconds: params.durationSeconds,
            collateralLockAmount: params.collateralLockAmount,
            allowEarlyRepay: params.allowEarlyRepay,
            allowEarlyExercise: params.allowEarlyExercise,
            allowLenderCall: params.allowLenderCall,
            cancelled: false,
            filled: false,
            isTranche: tranche.isTranche,
            trancheAmount: tranche.isTranche ? tranche.trancheAmount : 0
        });
        if (tranche.isTranche) {
            ds.trancheRemaining[offerId] = tranche.trancheAmount;
        }
        LibDirectStorage.trackLenderOffer(ds, positionKey, offerId);

        uint256 trancheRemainingAfter = tranche.isTranche ? tranche.trancheAmount : 0;
        uint256 fillsRemaining = tranche.isTranche ? tranche.trancheAmount / params.principal : 1;
        uint256 maxFills = fillsRemaining;
        bool isDepleted = tranche.isTranche ? trancheRemainingAfter == 0 : false;

        emit DirectOfferPosted(
            offerId,
            params.borrowAsset,
            params.collateralPoolId,
            msg.sender,
            params.lenderPositionId,
            params.lenderPoolId,
            params.collateralAsset,
            params.principal,
            params.aprBps,
            params.durationSeconds,
            params.collateralLockAmount,
            tranche.isTranche,
            tranche.isTranche ? tranche.trancheAmount : 0,
            trancheRemainingAfter,
            fillsRemaining,
            maxFills,
            isDepleted
        );

        emit DirectOfferLocator(
            msg.sender,
            params.lenderPositionId,
            offerId,
            params.lenderPoolId,
            params.collateralPoolId
        );
    }

    


function postRatioTrancheOffer(DirectTypes.DirectRatioTrancheParams calldata params)
        external
        nonReentrant
        returns (uint256 offerId)
    {
        PositionNFT nft = LibDirectHelpers._positionNFT();
        LibDirectHelpers._requireNFTOwnership(nft, params.lenderPositionId);
        LibDirectHelpers._validateRatioTrancheParams(params);

        Types.PoolData storage lenderPool = LibDirectHelpers._pool(params.lenderPoolId);
        if (params.borrowAsset != lenderPool.underlying) revert DirectError_InvalidAsset();
        if (params.collateralAsset != LibDirectHelpers._pool(params.collateralPoolId).underlying) {
            revert DirectError_InvalidAsset();
        }

        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        bytes32 positionKey = nft.getPositionKey(params.lenderPositionId);
        LibFeeIndex.settle(params.lenderPoolId, positionKey);
        LibActiveCreditIndex.settle(params.lenderPoolId, positionKey);
        if (!LibPoolMembership.isMember(positionKey, params.lenderPoolId)) revert DirectError_InvalidOffer();

        uint256 currentPrincipal = lenderPool.userPrincipal[positionKey];
        uint256 offerEscrow = LibEncumbrance.position(positionKey, params.lenderPoolId).directOfferEscrow;
        if (offerEscrow > currentPrincipal) revert InsufficientPrincipal(offerEscrow, currentPrincipal);
        if (params.principalCap > currentPrincipal - offerEscrow) {
            revert InsufficientPrincipal(params.principalCap, currentPrincipal - offerEscrow);
        }

        require(
            LibSolvencyChecks.checkSolvency(
                lenderPool,
                positionKey,
                currentPrincipal - (offerEscrow + params.principalCap),
                LibSolvencyChecks.calculateTotalDebt(lenderPool, positionKey, params.lenderPoolId)
            ),
            "SolvencyViolation: Lender LTV"
        );

        uint256 encBefore = LibEncumbrance.totalForActiveCredit(positionKey, params.lenderPoolId);
        LibEncumbrance.position(positionKey, params.lenderPoolId).directOfferEscrow = offerEscrow + params.principalCap;
        uint256 encAfter = LibEncumbrance.totalForActiveCredit(positionKey, params.lenderPoolId);
        LibActiveCreditIndex.applyEncumbranceDelta(
            lenderPool, params.lenderPoolId, positionKey, encBefore, encAfter
        );
        offerId = ++ds.nextOfferId;
        DirectTypes.DirectRatioTrancheOffer storage ro = ds.ratioOffers[offerId];
        ro.offerId = offerId;
        ro.lender = msg.sender;
        ro.lenderPositionId = params.lenderPositionId;
        ro.lenderPoolId = params.lenderPoolId;
        ro.collateralPoolId = params.collateralPoolId;
        ro.collateralAsset = params.collateralAsset;
        ro.borrowAsset = params.borrowAsset;
        ro.principalCap = params.principalCap;
        ro.principalRemaining = params.principalCap;
        ro.priceNumerator = params.priceNumerator;
        ro.priceDenominator = params.priceDenominator;
        ro.minPrincipalPerFill = params.minPrincipalPerFill;
        ro.aprBps = params.aprBps;
        ro.durationSeconds = params.durationSeconds;
        ro.allowEarlyRepay = params.allowEarlyRepay;
        ro.allowEarlyExercise = params.allowEarlyExercise;
        ro.allowLenderCall = params.allowLenderCall;
        ro.cancelled = false;
        ro.filled = false;

        LibDirectStorage.trackRatioLenderOffer(ds, positionKey, offerId);

        emit RatioTrancheOfferPosted(
            offerId,
            msg.sender,
            params.lenderPositionId,
            params.lenderPoolId,
            params.collateralPoolId,
            params.borrowAsset,
            params.collateralAsset,
            params.principalCap,
            params.principalCap,
            params.priceNumerator,
            params.priceDenominator,
            params.minPrincipalPerFill,
            params.aprBps,
            params.durationSeconds
        );
    }

function cancelOffer(uint256 offerId) external nonReentrant {
        PositionNFT nft = LibDirectHelpers._positionNFT();
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        DirectTypes.DirectOffer storage offer = ds.offers[offerId];
        if (offer.lender == address(0) || offer.cancelled || offer.filled) {
            revert DirectError_InvalidOffer();
        }
        if (offer.lender != msg.sender) {
            revert NotNFTOwner(msg.sender, offer.lenderPositionId);
        }
        LibDirectHelpers._requireNFTOwnership(nft, offer.lenderPositionId);

        offer.cancelled = true;
        bytes32 positionKey = nft.getPositionKey(offer.lenderPositionId);
        LibActiveCreditIndex.settle(offer.lenderPoolId, positionKey);
        Types.PoolData storage lenderPool = LibDirectHelpers._pool(offer.lenderPoolId);
        uint256 escrowed = LibEncumbrance.position(positionKey, offer.lenderPoolId).directOfferEscrow;
        uint256 release = offer.isTranche ? ds.trancheRemaining[offerId] : offer.principal;
        if (release > escrowed) {
            release = escrowed;
        }
        uint256 encBefore = LibEncumbrance.totalForActiveCredit(positionKey, offer.lenderPoolId);
        LibEncumbrance.position(positionKey, offer.lenderPoolId).directOfferEscrow = escrowed - release;
        uint256 encAfter = LibEncumbrance.totalForActiveCredit(positionKey, offer.lenderPoolId);
        LibActiveCreditIndex.applyEncumbranceDelta(
            lenderPool, offer.lenderPoolId, positionKey, encBefore, encAfter
        );
        if (offer.isTranche) {
            ds.trancheRemaining[offerId] = 0;
        }
        LibDirectStorage.untrackLenderOffer(ds, positionKey, offerId);

        emit DirectOfferCancelled(
            offerId,
            msg.sender,
            offer.lenderPositionId,
            DirectTypes.DirectCancelReason.Manual,
            offer.trancheAmount,
            offer.isTranche ? ds.trancheRemaining[offerId] : 0,
            release,
            0,
            true
        );
    }

    function cancelRatioTrancheOffer(uint256 offerId) external nonReentrant {
        PositionNFT nft = LibDirectHelpers._positionNFT();
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        DirectTypes.DirectRatioTrancheOffer storage offer = ds.ratioOffers[offerId];
        if (offer.lender == address(0) || offer.cancelled || offer.filled) {
            revert DirectError_InvalidOffer();
        }
        if (offer.lender != msg.sender) {
            revert NotNFTOwner(msg.sender, offer.lenderPositionId);
        }
        LibDirectHelpers._requireNFTOwnership(nft, offer.lenderPositionId);

        offer.cancelled = true;
        offer.filled = true;
        bytes32 positionKey = nft.getPositionKey(offer.lenderPositionId);
        LibActiveCreditIndex.settle(offer.lenderPoolId, positionKey);
        Types.PoolData storage lenderPool = LibDirectHelpers._pool(offer.lenderPoolId);
        uint256 escrowed = LibEncumbrance.position(positionKey, offer.lenderPoolId).directOfferEscrow;
        uint256 release = offer.principalRemaining;
        if (release > escrowed) {
            release = escrowed;
        }
        offer.principalRemaining = 0;
        uint256 encBefore = LibEncumbrance.totalForActiveCredit(positionKey, offer.lenderPoolId);
        LibEncumbrance.position(positionKey, offer.lenderPoolId).directOfferEscrow = escrowed - release;
        uint256 encAfter = LibEncumbrance.totalForActiveCredit(positionKey, offer.lenderPoolId);
        LibActiveCreditIndex.applyEncumbranceDelta(
            lenderPool, offer.lenderPoolId, positionKey, encBefore, encAfter
        );
        LibDirectStorage.untrackRatioLenderOffer(ds, positionKey, offerId);

        emit RatioTrancheOfferCancelled(
            offerId, msg.sender, offer.lenderPositionId, DirectTypes.DirectCancelReason.Manual, release
        );
    }

    /// @notice External hook for PositionNFT transfers to cancel outstanding offers.
    /// @notice Cancel offers by position key (NFT hook entrypoint)
    /// @dev Allows the PositionNFT contract to cancel on transfer; owner/timelock may also call.
    function cancelOffersForPosition(bytes32 positionKey) external nonReentrant {
        address nftAddr = address(LibDirectHelpers._positionNFT());
        if (msg.sender != nftAddr) {
            LibAccess.enforceOwnerOrTimelock();
        }
        LibDirectStorage.cancelOffersForPosition(positionKey);
    }

    /// @notice Cancel offers by positionId (user/timelock entrypoint)
    function cancelOffersForPosition(uint256 positionId) external nonReentrant {
        PositionNFT nft = LibDirectHelpers._positionNFT();
        if (nft.ownerOf(positionId) != msg.sender) {
            LibAccess.enforceOwnerOrTimelock();
        }
        bytes32 positionKey = nft.getPositionKey(positionId);
        LibDirectStorage.cancelOffersForPosition(positionKey);
    }

    /// @notice Check whether a position has any outstanding direct or rolling offers.
    /// @dev Used by the PositionNFT transfer hook to block transfers with open offers.
    function hasOpenOffers(bytes32 positionKey) external view returns (bool) {
        return LibDirectStorage.hasOutstandingOffers(positionKey);
    }

    /// @notice Post a borrower ratio tranche offer for CLOB-style trading
    /// @dev Borrower locks collateralCap upfront; lenders can fill variable amounts
    function postBorrowerRatioTrancheOffer(DirectTypes.DirectBorrowerRatioTrancheParams calldata params)
        external
        nonReentrant
        returns (uint256 offerId)
    {
        PositionNFT nft = LibDirectHelpers._positionNFT();
        LibDirectHelpers._requireNFTOwnership(nft, params.borrowerPositionId);
        LibDirectHelpers._validateBorrowerRatioTrancheParams(params);

        Types.PoolData storage lenderPool = LibDirectHelpers._pool(params.lenderPoolId);
        Types.PoolData storage collateralPool = LibDirectHelpers._pool(params.collateralPoolId);
        if (params.borrowAsset != lenderPool.underlying) revert DirectError_InvalidAsset();
        if (params.collateralAsset != collateralPool.underlying) revert DirectError_InvalidAsset();

        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
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
        if (params.collateralCap > available) {
            revert InsufficientPrincipal(params.collateralCap, available);
        }

        uint256 currentBorrowerDebt = LibSolvencyChecks.calculateTotalDebt(collateralPool, positionKey, params.collateralPoolId);
        require(
            LibSolvencyChecks.checkSolvency(collateralPool, positionKey, principal, currentBorrowerDebt + params.collateralCap),
            "SolvencyViolation: Borrower LTV"
        );

        uint256 encBefore = LibEncumbrance.totalForActiveCredit(positionKey, params.collateralPoolId);
        LibEncumbrance.position(positionKey, params.collateralPoolId).directLocked = locked + params.collateralCap;
        uint256 encAfter = LibEncumbrance.totalForActiveCredit(positionKey, params.collateralPoolId);
        LibActiveCreditIndex.applyEncumbranceDelta(
            collateralPool, params.collateralPoolId, positionKey, encBefore, encAfter
        );

        offerId = ++ds.nextBorrowerRatioOfferId;

        DirectTypes.DirectBorrowerRatioTrancheOffer storage ro = ds.borrowerRatioOffers[offerId];
        ro.offerId = offerId;
        ro.borrower = msg.sender;
        ro.borrowerPositionId = params.borrowerPositionId;
        ro.lenderPoolId = params.lenderPoolId;
        ro.collateralPoolId = params.collateralPoolId;
        ro.collateralAsset = params.collateralAsset;
        ro.borrowAsset = params.borrowAsset;
        ro.collateralCap = params.collateralCap;
        ro.collateralRemaining = params.collateralCap;
        ro.priceNumerator = params.priceNumerator;
        ro.priceDenominator = params.priceDenominator;
        ro.minCollateralPerFill = params.minCollateralPerFill;
        ro.aprBps = params.aprBps;
        ro.durationSeconds = params.durationSeconds;
        ro.allowEarlyRepay = params.allowEarlyRepay;
        ro.allowEarlyExercise = params.allowEarlyExercise;
        ro.allowLenderCall = params.allowLenderCall;
        ro.cancelled = false;
        ro.filled = false;

        LibDirectStorage.trackRatioBorrowerOffer(ds, positionKey, offerId);

        emit BorrowerRatioTrancheOfferPosted(
            offerId,
            msg.sender,
            params.borrowerPositionId,
            params.lenderPoolId,
            params.collateralPoolId,
            params.borrowAsset,
            params.collateralAsset,
            params.collateralCap,
            params.collateralCap,
            params.priceNumerator,
            params.priceDenominator,
            params.minCollateralPerFill,
            params.aprBps,
            params.durationSeconds
        );
    }

    /// @notice Cancel a borrower ratio tranche offer
    function cancelBorrowerRatioTrancheOffer(uint256 offerId) external nonReentrant {
        PositionNFT nft = LibDirectHelpers._positionNFT();
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        DirectTypes.DirectBorrowerRatioTrancheOffer storage offer = ds.borrowerRatioOffers[offerId];
        if (offer.borrower == address(0) || offer.cancelled || offer.filled) {
            revert DirectError_InvalidOffer();
        }
        if (offer.borrower != msg.sender) {
            revert NotNFTOwner(msg.sender, offer.borrowerPositionId);
        }
        LibDirectHelpers._requireNFTOwnership(nft, offer.borrowerPositionId);

        offer.cancelled = true;
        offer.filled = true;
        bytes32 positionKey = nft.getPositionKey(offer.borrowerPositionId);
        LibActiveCreditIndex.settle(offer.collateralPoolId, positionKey);
        Types.PoolData storage collateralPool = LibDirectHelpers._pool(offer.collateralPoolId);
        uint256 locked = LibEncumbrance.position(positionKey, offer.collateralPoolId).directLocked;
        uint256 release = offer.collateralRemaining;
        if (release > locked) {
            release = locked;
        }
        offer.collateralRemaining = 0;
        uint256 encBefore = LibEncumbrance.totalForActiveCredit(positionKey, offer.collateralPoolId);
        LibEncumbrance.position(positionKey, offer.collateralPoolId).directLocked = locked - release;
        uint256 encAfter = LibEncumbrance.totalForActiveCredit(positionKey, offer.collateralPoolId);
        LibActiveCreditIndex.applyEncumbranceDelta(
            collateralPool, offer.collateralPoolId, positionKey, encBefore, encAfter
        );
        LibDirectStorage.untrackRatioBorrowerOffer(ds, positionKey, offerId);

        emit BorrowerRatioTrancheOfferCancelled(
            offerId, msg.sender, offer.borrowerPositionId, DirectTypes.DirectCancelReason.Manual, release
        );
    }
}
