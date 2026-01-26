// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PositionNFT} from "../nft/PositionNFT.sol";
import {Types} from "../libraries/Types.sol";
import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibCurrency} from "../libraries/LibCurrency.sol";
import {LibFeeIndex} from "../libraries/LibFeeIndex.sol";
import {LibPoolMembership} from "../libraries/LibPoolMembership.sol";
import {ReentrancyGuardModifiers} from "../libraries/LibReentrancyGuard.sol";
import {LibActiveCreditIndex} from "../libraries/LibActiveCreditIndex.sol";
import {InsufficientPrincipal} from "../libraries/Errors.sol";
import {DirectTypes} from "../libraries/DirectTypes.sol";
import {LibDirectHelpers} from "../libraries/LibDirectHelpers.sol";
import {LibEncumbrance} from "../libraries/LibEncumbrance.sol";
import {LibDirectStorage} from "../libraries/LibDirectStorage.sol";
import {LibSolvencyChecks} from "../libraries/LibSolvencyChecks.sol";
import {LibFeeRouter} from "../libraries/LibFeeRouter.sol";
import {IDirectOfferEvents} from "../interfaces/IDirectOfferEvents.sol";
import {
    DirectError_InvalidAsset,
    DirectError_InvalidConfiguration,
    DirectError_InvalidOffer,
    DirectError_InvalidRatio,
    DirectError_InvalidTimestamp,
    DirectError_InvalidTrancheAmount,
    DirectError_InvalidFillAmount,
    DirectError_TrancheInsufficient
} from "../libraries/Errors.sol";

/// @notice Agreement acceptance entrypoints for EqualLend direct lending
contract EqualLendDirectAgreementFacet is ReentrancyGuardModifiers, IDirectOfferEvents {
    event BorrowerOfferAccepted(uint256 indexed offerId, uint256 indexed agreementId, uint256 indexed lenderPositionId);
    event DirectOfferAccepted(
        uint256 indexed offerId,
        uint256 indexed agreementId,
        uint256 indexed borrowerPositionId,
        uint256 principalFilled,
        uint256 trancheAmount,
        uint256 trancheRemainingAfter,
        uint256 fillsRemaining,
        bool isDepleted
    );

    struct TrancheCheckResult {
        uint256 trancheAmount;
        uint256 trancheRemainingBefore;
        uint256 trancheRemainingAfter;
        bool autoCancelled;
    }

    struct FeeVars {
        uint256 platformFee;
        uint256 interestAmount;
        uint256 totalFee;
        uint64 dueTimestamp;
    }

    bytes32 internal constant DIRECT_PLATFORM_FEE_SOURCE = keccak256("DIRECT_PLATFORM_FEE");
    bytes32 internal constant DIRECT_INTEREST_FEE_SOURCE = keccak256("DIRECT_INTEREST_FEE");

    function _calculateDirectFees(
        uint256 principal,
        uint16 aprBps,
        uint64 durationSeconds,
        DirectTypes.DirectConfig storage cfg
    ) internal view returns (uint256 platformFee, uint256 interestAmount, uint256 totalFee, uint64 dueTimestamp) {
        platformFee = (principal * cfg.platformFeeBps) / 10_000;
        uint64 effectiveDuration = durationSeconds < cfg.minInterestDuration ? cfg.minInterestDuration : durationSeconds;
        interestAmount = LibDirectHelpers._annualizedInterestAmount(principal, aprBps, effectiveDuration);
        uint256 dueTimestampCalc = block.timestamp + durationSeconds;
        if (dueTimestampCalc > type(uint64).max) revert DirectError_InvalidTimestamp();
        dueTimestamp = uint64(dueTimestampCalc);
        totalFee = interestAmount + platformFee;
    }

    function _distributeDirectFees(
        Types.PoolData storage lenderPool,
        bytes32 lenderKey,
        DirectTypes.DirectConfig storage cfg,
        address borrowAsset,
        address collateralAsset,
        uint256 lenderPoolId,
        uint256 collateralPoolId,
        uint256 interestAmount,
        uint256 platformFee
    ) internal {
        uint256 lenderInterestShare = (interestAmount * cfg.interestLenderBps) / 10_000;
        uint256 lenderPlatformShare = (platformFee * cfg.platformFeeLenderBps) / 10_000;
        uint256 lenderAmount = lenderInterestShare + lenderPlatformShare;
        if (lenderAmount > 0) {
            lenderPool.userAccruedYield[lenderKey] += lenderAmount;
            lenderPool.trackedBalance += lenderAmount;
            if (LibCurrency.isNative(lenderPool.underlying)) {
                LibAppStorage.s().nativeTrackedTotal += lenderAmount;
            }
        }

        uint256 feePid = borrowAsset == collateralAsset ? collateralPoolId : lenderPoolId;
        Types.PoolData storage feePool = LibDirectHelpers._pool(feePid);

        uint256 interestRemainder = interestAmount - lenderInterestShare;
        if (interestRemainder > 0) {
            feePool.trackedBalance += interestRemainder;
            if (LibCurrency.isNative(feePool.underlying)) {
                LibAppStorage.s().nativeTrackedTotal += interestRemainder;
            }
            _routeDirectFee(feePool, feePid, interestRemainder, DIRECT_INTEREST_FEE_SOURCE);
        }

        uint256 platformRemainder = platformFee - lenderPlatformShare;
        if (platformRemainder > 0) {
            feePool.trackedBalance += platformRemainder;
            if (LibCurrency.isNative(feePool.underlying)) {
                LibAppStorage.s().nativeTrackedTotal += platformRemainder;
            }
            _routeDirectFee(feePool, feePid, platformRemainder, DIRECT_PLATFORM_FEE_SOURCE);
        }
    }

    function _routeDirectFee(Types.PoolData storage feePool, uint256 pid, uint256 amount, bytes32 source) internal {
        if (amount == 0) return;
        (uint256 toTreasury, uint256 toActiveCredit, uint256 toFeeIndex) = LibFeeRouter.previewSplit(amount);
        if (toTreasury > 0) {
            address treasury = LibAppStorage.treasuryAddress(LibAppStorage.s());
            if (treasury != address(0)) {
                uint256 tracked = feePool.trackedBalance;
                if (tracked < toTreasury) {
                    revert InsufficientPrincipal(toTreasury, tracked);
                }
                uint256 contractBal = LibCurrency.balanceOfSelf(feePool.underlying);
                if (contractBal < toTreasury) {
                    revert InsufficientPrincipal(toTreasury, contractBal);
                }
                feePool.trackedBalance = tracked - toTreasury;
                if (LibCurrency.isNative(feePool.underlying)) {
                    LibAppStorage.s().nativeTrackedTotal -= toTreasury;
                }
                LibCurrency.transfer(feePool.underlying, treasury, toTreasury);
            }
        }
        if (toActiveCredit > 0) {
            LibFeeRouter.accrueActiveCredit(pid, toActiveCredit, source, 0);
        }
        if (toFeeIndex > 0) {
            LibFeeIndex.accrueWithSource(pid, toFeeIndex, source);
        }
    }

    function acceptBorrowerOffer(uint256 offerId, uint256 lenderPositionId)
        external
        nonReentrant
        returns (uint256 agreementId)
    {
        PositionNFT nft = LibDirectHelpers._positionNFT();
        LibDirectHelpers._requireNFTOwnership(nft, lenderPositionId);

        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        DirectTypes.DirectBorrowerOffer storage offer = ds.borrowerOffers[offerId];
        if (offer.borrower == address(0) || offer.cancelled || offer.filled) {
            revert DirectError_InvalidOffer();
        }
        if (offer.borrowerPositionId == lenderPositionId) {
            revert DirectError_InvalidOffer();
        }
        Types.PoolData storage lenderPool = LibDirectHelpers._pool(offer.lenderPoolId);
        Types.PoolData storage collateralPool = LibDirectHelpers._pool(offer.collateralPoolId);
        if (offer.borrowAsset != lenderPool.underlying) revert DirectError_InvalidAsset();
        if (offer.collateralAsset != collateralPool.underlying) revert DirectError_InvalidAsset();

        bytes32 lenderKey = nft.getPositionKey(lenderPositionId);
        LibFeeIndex.settle(offer.lenderPoolId, lenderKey);
        LibActiveCreditIndex.settle(offer.lenderPoolId, lenderKey);
        if (!LibPoolMembership.isMember(lenderKey, offer.lenderPoolId)) {
            revert DirectError_InvalidOffer();
        }
        uint256 currentPrincipal = lenderPool.userPrincipal[lenderKey];
        uint256 offerEscrow = LibEncumbrance.position(lenderKey, offer.lenderPoolId).directOfferEscrow;
        if (offerEscrow > currentPrincipal) {
            revert InsufficientPrincipal(offerEscrow, currentPrincipal);
        }
        if (offer.principal > currentPrincipal - offerEscrow) {
            revert InsufficientPrincipal(offer.principal, currentPrincipal - offerEscrow);
        }

        uint256 currentLenderDebt = LibSolvencyChecks.calculateTotalDebt(lenderPool, lenderKey, offer.lenderPoolId);
        require(
            LibSolvencyChecks.checkSolvency(
                lenderPool,
                lenderKey,
                currentPrincipal - offer.principal,
                currentLenderDebt
            ),
            "SolvencyViolation: Lender LTV"
        );

        bytes32 borrowerKey = nft.getPositionKey(offer.borrowerPositionId);
        LibFeeIndex.settle(offer.collateralPoolId, borrowerKey);
        LibActiveCreditIndex.settle(offer.collateralPoolId, borrowerKey);
        if (!LibPoolMembership.isMember(borrowerKey, offer.collateralPoolId)) {
            revert DirectError_InvalidOffer();
        }
        uint256 borrowerPrincipal = collateralPool.userPrincipal[borrowerKey];
        uint256 locked = LibEncumbrance.position(borrowerKey, offer.collateralPoolId).directLocked;
        if (locked > borrowerPrincipal) {
            revert InsufficientPrincipal(locked, borrowerPrincipal);
        }
        if (offer.collateralLockAmount > locked) {
            revert InsufficientPrincipal(offer.collateralLockAmount, locked);
        }

        // The lock was recorded during postBorrowerOffer; avoid double-counting it as debt.
        require(
            LibSolvencyChecks.checkSolvency(
                collateralPool,
                borrowerKey,
                borrowerPrincipal,
                LibSolvencyChecks.calculateTotalDebt(collateralPool, borrowerKey, offer.collateralPoolId)
            ),
            "SolvencyViolation: Borrower LTV"
        );

        DirectTypes.DirectConfig storage cfg = ds.config;
        (uint256 platformFee, uint256 interestAmount, uint256 totalFee, uint64 dueTimestamp) =
            _calculateDirectFees(offer.principal, offer.aprBps, offer.durationSeconds, cfg);
        if (totalFee > offer.principal) revert DirectError_InvalidOffer();

        uint256 borrowedBefore = ds.directBorrowedPrincipal[borrowerKey][offer.lenderPoolId];
        uint256 lenderEncBefore = LibEncumbrance.totalForActiveCredit(lenderKey, offer.lenderPoolId);
        uint256 lenderPrincipalBefore = lenderPool.userPrincipal[lenderKey];
        if (offer.principal > lenderPool.trackedBalance) {
            revert InsufficientPrincipal(offer.principal, lenderPool.trackedBalance);
        }
        lenderPool.trackedBalance -= offer.principal;
        if (LibCurrency.isNative(lenderPool.underlying) && offer.principal > 0) {
            LibAppStorage.s().nativeTrackedTotal -= offer.principal;
        }
        ds.activeDirectLentPerPool[offer.lenderPoolId] += offer.principal;
        LibEncumbrance.position(lenderKey, offer.lenderPoolId).directLent += offer.principal;
        ds.directBorrowedPrincipal[borrowerKey][offer.lenderPoolId] = borrowedBefore + offer.principal;
        LibActiveCreditIndex.applyEncumbranceDelta(
            lenderPool,
            offer.lenderPoolId,
            lenderKey,
            lenderEncBefore,
            LibEncumbrance.totalForActiveCredit(lenderKey, offer.lenderPoolId)
        );
        if (lenderPrincipalBefore < offer.principal) {
            revert InsufficientPrincipal(offer.principal, lenderPrincipalBefore);
        }
        lenderPool.userPrincipal[lenderKey] = lenderPrincipalBefore - offer.principal;
        lenderPool.totalDeposits = lenderPool.totalDeposits >= offer.principal
            ? lenderPool.totalDeposits - offer.principal
            : 0;
        if (lenderPrincipalBefore - lenderPool.userPrincipal[lenderKey] != offer.principal) {
            revert DirectError_InvalidOffer();
        }
        if (ds.directBorrowedPrincipal[borrowerKey][offer.lenderPoolId] - borrowedBefore != offer.principal) {
            revert DirectError_InvalidOffer();
        }

        if (offer.borrowAsset == offer.collateralAsset) {
            Types.ActiveCreditState storage debtState = collateralPool.userActiveCreditStateDebt[borrowerKey];
            collateralPool.activeCreditPrincipalTotal += offer.principal;
            LibActiveCreditIndex.applyWeightedIncreaseWithGate(
                collateralPool, debtState, offer.principal, offer.collateralPoolId, borrowerKey, true
            );
            debtState.indexSnapshot = collateralPool.activeCreditIndex;
            ds.directSameAssetDebt[borrowerKey][offer.borrowAsset] += offer.principal;
        }

        offer.filled = true;
        agreementId = ++ds.nextAgreementId;
        LibDirectStorage.untrackBorrowerOffer(ds, borrowerKey, offerId);

        ds.agreements[agreementId] = DirectTypes.DirectAgreement({
            agreementId: agreementId,
            lender: msg.sender,
            borrower: offer.borrower,
            lenderPositionId: lenderPositionId,
            lenderPoolId: offer.lenderPoolId,
            borrowerPositionId: offer.borrowerPositionId,
            collateralPoolId: offer.collateralPoolId,
            collateralAsset: offer.collateralAsset,
            borrowAsset: offer.borrowAsset,
            principal: offer.principal,
            userInterest: interestAmount,
            dueTimestamp: dueTimestamp,
            collateralLockAmount: offer.collateralLockAmount,
            allowEarlyRepay: offer.allowEarlyRepay,
            allowEarlyExercise: offer.allowEarlyExercise,
            allowLenderCall: offer.allowLenderCall,
            status: DirectTypes.DirectStatus.Active,
            interestRealizedUpfront: true
        });
        LibDirectStorage.addBorrowerAgreement(ds, borrowerKey, agreementId);
        LibDirectStorage.addLenderAgreement(ds, lenderKey, agreementId);

        LibCurrency.transfer(offer.borrowAsset, offer.borrower, offer.principal - totalFee);

        if (totalFee > 0) {
            _distributeDirectFees(
                lenderPool,
                lenderKey,
                cfg,
                offer.borrowAsset,
                offer.collateralAsset,
                offer.lenderPoolId,
                offer.collateralPoolId,
                interestAmount,
                platformFee
            );
        }

        emit BorrowerOfferAccepted(offerId, agreementId, lenderPositionId);
    }

    function acceptOffer(uint256 offerId, uint256 borrowerPositionId)
        external
        nonReentrant
        returns (uint256 agreementId)
    {
        LibDirectHelpers._requireNFTOwnership(LibDirectHelpers._positionNFT(), borrowerPositionId);

        PositionNFT nft = LibDirectHelpers._positionNFT();
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        DirectTypes.DirectOffer storage offer = ds.offers[offerId];
        if (offer.lender == address(0) || offer.cancelled || offer.filled) {
            revert DirectError_InvalidOffer();
        }
        if (offer.lenderPositionId == borrowerPositionId) {
            revert DirectError_InvalidOffer();
        }
        Types.PoolData storage lenderPool = LibDirectHelpers._pool(offer.lenderPoolId);
        if (offer.borrowAsset != lenderPool.underlying) revert DirectError_InvalidAsset();
        Types.PoolData storage pool = LibDirectHelpers._pool(offer.collateralPoolId);
        if (offer.collateralAsset != pool.underlying) revert DirectError_InvalidAsset();

        bytes32 lenderKey = nft.getPositionKey(offer.lenderPositionId);
        LibFeeIndex.settle(offer.lenderPoolId, lenderKey);
        LibActiveCreditIndex.settle(offer.lenderPoolId, lenderKey);
        if (!LibPoolMembership.isMember(lenderKey, offer.lenderPoolId)) {
            revert DirectError_InvalidOffer();
        }
        uint256 currentPrincipal = lenderPool.userPrincipal[lenderKey];
        uint256 offerEscrow = LibEncumbrance.position(lenderKey, offer.lenderPoolId).directOfferEscrow;
        if (offerEscrow < offer.principal) {
            revert InsufficientPrincipal(offer.principal, offerEscrow);
        }
        if (currentPrincipal < offer.principal) {
            revert InsufficientPrincipal(offer.principal, currentPrincipal);
        }

        TrancheCheckResult memory tranche;
        if (offer.isTranche) {
            tranche = _checkAndConsumeTranche(ds, offer, lenderKey, offerEscrow);
            if (tranche.autoCancelled) {
                return 0;
            }
        }

        bytes32 borrowerKey = nft.getPositionKey(borrowerPositionId);
        // Settle borrower in collateral pool before locking
        LibFeeIndex.settle(offer.collateralPoolId, borrowerKey);
        LibActiveCreditIndex.settle(offer.collateralPoolId, borrowerKey);
        if (!LibPoolMembership.isMember(borrowerKey, offer.collateralPoolId)) {
            revert DirectError_InvalidOffer();
        }
        uint256 borrowerPrincipal = pool.userPrincipal[borrowerKey];
        uint256 locked = LibEncumbrance.position(borrowerKey, offer.collateralPoolId).directLocked;
        if (locked > borrowerPrincipal) {
            revert InsufficientPrincipal(locked, borrowerPrincipal);
        }
        if (offer.collateralLockAmount > borrowerPrincipal - locked) {
            revert InsufficientPrincipal(offer.collateralLockAmount, borrowerPrincipal - locked);
        }

        require(
            LibSolvencyChecks.checkSolvency(
                pool,
                borrowerKey,
                borrowerPrincipal,
                LibSolvencyChecks.calculateTotalDebt(pool, borrowerKey, offer.collateralPoolId)
                    + offer.collateralLockAmount
            ),
            "SolvencyViolation: Borrower LTV"
        );

        uint256 borrowerEncBefore = LibEncumbrance.totalForActiveCredit(borrowerKey, offer.collateralPoolId);
        LibEncumbrance.position(borrowerKey, offer.collateralPoolId).directLocked = locked + offer.collateralLockAmount;
        LibActiveCreditIndex.applyEncumbranceDelta(
            pool,
            offer.collateralPoolId,
            borrowerKey,
            borrowerEncBefore,
            LibEncumbrance.totalForActiveCredit(borrowerKey, offer.collateralPoolId)
        );

        DirectTypes.DirectConfig storage cfg = ds.config;
        (uint256 platformFee, uint256 interestAmount, uint256 totalFee, uint64 dueTimestamp) =
            _calculateDirectFees(offer.principal, offer.aprBps, offer.durationSeconds, cfg);
        if (totalFee > offer.principal) revert DirectError_InvalidOffer();

        // Effects before interactions
        uint256 borrowedBefore = ds.directBorrowedPrincipal[borrowerKey][offer.lenderPoolId];
        uint256 lenderPrincipalBefore = lenderPool.userPrincipal[lenderKey];
        if (offer.principal > lenderPool.trackedBalance) {
            revert InsufficientPrincipal(offer.principal, lenderPool.trackedBalance);
        }

        uint256 currentLenderDebt = LibSolvencyChecks.calculateTotalDebt(lenderPool, lenderKey, offer.lenderPoolId);
        require(
            LibSolvencyChecks.checkSolvency(
                lenderPool,
                lenderKey,
                lenderPrincipalBefore - offer.principal,
                currentLenderDebt
            ),
            "SolvencyViolation: Lender LTV"
        );

        // Reflect liquidity leaving the pool and reduce lender principal at acceptance
        uint256 lenderEncBefore = LibEncumbrance.totalForActiveCredit(lenderKey, offer.lenderPoolId);
        lenderPool.trackedBalance -= offer.principal;
        if (LibCurrency.isNative(lenderPool.underlying) && offer.principal > 0) {
            LibAppStorage.s().nativeTrackedTotal -= offer.principal;
        }
        ds.activeDirectLentPerPool[offer.lenderPoolId] += offer.principal;
        LibEncumbrance.position(lenderKey, offer.lenderPoolId).directOfferEscrow = offerEscrow - offer.principal;
        LibEncumbrance.position(lenderKey, offer.lenderPoolId).directLent += offer.principal;
        ds.directBorrowedPrincipal[borrowerKey][offer.lenderPoolId] = borrowedBefore + offer.principal;
        LibActiveCreditIndex.applyEncumbranceDelta(
            lenderPool,
            offer.lenderPoolId,
            lenderKey,
            lenderEncBefore,
            LibEncumbrance.totalForActiveCredit(lenderKey, offer.lenderPoolId)
        );
        // Lender principal adjustment in pool base
        if (lenderPrincipalBefore < offer.principal) {
            revert InsufficientPrincipal(offer.principal, lenderPrincipalBefore);
        }
        lenderPool.userPrincipal[lenderKey] = lenderPrincipalBefore - offer.principal;
        lenderPool.totalDeposits = lenderPool.totalDeposits >= offer.principal
            ? lenderPool.totalDeposits - offer.principal
            : 0;
        if (lenderPrincipalBefore - lenderPool.userPrincipal[lenderKey] != offer.principal) {
            revert DirectError_InvalidOffer();
        }
        if (ds.directBorrowedPrincipal[borrowerKey][offer.lenderPoolId] - borrowedBefore != offer.principal) {
            revert DirectError_InvalidOffer();
        }

        if (offer.borrowAsset == offer.collateralAsset) {
            Types.ActiveCreditState storage debtState = pool.userActiveCreditStateDebt[borrowerKey];
            pool.activeCreditPrincipalTotal += offer.principal;
            LibActiveCreditIndex.applyWeightedIncreaseWithGate(
                pool, debtState, offer.principal, offer.collateralPoolId, borrowerKey, true
            );
            debtState.indexSnapshot = pool.activeCreditIndex;
            ds.directSameAssetDebt[borrowerKey][offer.borrowAsset] += offer.principal;
        }

        if (!offer.isTranche) {
            offer.filled = true;
        }
        agreementId = ++ds.nextAgreementId;
        if (!offer.isTranche || ds.trancheRemaining[offerId] == 0) {
            LibDirectStorage.untrackLenderOffer(ds, lenderKey, offerId);
        }

        ds.agreements[agreementId] = DirectTypes.DirectAgreement({
            agreementId: agreementId,
            lender: offer.lender,
            borrower: msg.sender,
            lenderPositionId: offer.lenderPositionId,
            lenderPoolId: offer.lenderPoolId,
            borrowerPositionId: borrowerPositionId,
            collateralPoolId: offer.collateralPoolId,
            collateralAsset: offer.collateralAsset,
            borrowAsset: offer.borrowAsset,
            principal: offer.principal,
            userInterest: interestAmount,
            dueTimestamp: dueTimestamp,
            collateralLockAmount: offer.collateralLockAmount,
            allowEarlyRepay: offer.allowEarlyRepay,
            allowEarlyExercise: offer.allowEarlyExercise,
            allowLenderCall: offer.allowLenderCall,
            status: DirectTypes.DirectStatus.Active,
            interestRealizedUpfront: true
        });
        LibDirectStorage.addBorrowerAgreement(ds, borrowerKey, agreementId);
        LibDirectStorage.addLenderAgreement(ds, lenderKey, agreementId);

        // Transfer net principal from lender pool liquidity to the borrower
        LibCurrency.transfer(offer.borrowAsset, msg.sender, offer.principal - totalFee);

        if (totalFee > 0) {
            _distributeDirectFees(
                lenderPool,
                lenderKey,
                cfg,
                offer.borrowAsset,
                offer.collateralAsset,
                offer.lenderPoolId,
                offer.collateralPoolId,
                interestAmount,
                platformFee
            );
        }

        emit DirectOfferAccepted(
            offerId,
            agreementId,
            borrowerPositionId,
            offer.principal,
            offer.isTranche ? tranche.trancheAmount : 0,
            offer.isTranche ? tranche.trancheRemainingAfter : 0,
            offer.isTranche ? tranche.trancheRemainingAfter / offer.principal : 0,
            offer.isTranche ? tranche.trancheRemainingAfter == 0 : true
        );
    }

    


function acceptRatioTrancheOffer(uint256 offerId, uint256 borrowerPositionId, uint256 principalAmount)
        external
        nonReentrant
        returns (uint256 agreementId)
    {
        if (principalAmount == 0) revert DirectError_InvalidFillAmount();

        LibDirectHelpers._requireNFTOwnership(LibDirectHelpers._positionNFT(), borrowerPositionId);

        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        DirectTypes.DirectRatioTrancheOffer storage offer = ds.ratioOffers[offerId];
        if (offer.lender == address(0) || offer.cancelled || offer.filled) revert DirectError_InvalidOffer();
        if (offer.lenderPositionId == borrowerPositionId) revert DirectError_InvalidOffer();
        if (principalAmount < offer.minPrincipalPerFill || principalAmount > offer.principalRemaining) {
            revert DirectError_InvalidFillAmount();
        }

        Types.PoolData storage lenderPool = LibDirectHelpers._pool(offer.lenderPoolId);
        if (offer.borrowAsset != lenderPool.underlying) revert DirectError_InvalidAsset();

        bytes32 lenderKey = LibDirectHelpers._positionNFT().getPositionKey(offer.lenderPositionId);
        LibFeeIndex.settle(offer.lenderPoolId, lenderKey);
        LibActiveCreditIndex.settle(offer.lenderPoolId, lenderKey);
        if (!LibPoolMembership.isMember(lenderKey, offer.lenderPoolId)) revert DirectError_InvalidOffer();
        uint256 offerEscrow = LibEncumbrance.position(lenderKey, offer.lenderPoolId).directOfferEscrow;
        if (offerEscrow < principalAmount) revert InsufficientPrincipal(principalAmount, offerEscrow);
        uint256 lenderPrincipalBefore = lenderPool.userPrincipal[lenderKey];
        if (lenderPrincipalBefore < principalAmount) revert InsufficientPrincipal(principalAmount, lenderPrincipalBefore);

        bytes32 borrowerKey = LibDirectHelpers._positionNFT().getPositionKey(borrowerPositionId);
        LibFeeIndex.settle(offer.collateralPoolId, borrowerKey);
        LibActiveCreditIndex.settle(offer.collateralPoolId, borrowerKey);
        Types.PoolData storage pool = LibDirectHelpers._pool(offer.collateralPoolId);
        if (offer.collateralAsset != pool.underlying) revert DirectError_InvalidAsset();
        if (!LibPoolMembership.isMember(borrowerKey, offer.collateralPoolId)) revert DirectError_InvalidOffer();
        uint256 borrowerPrincipal = pool.userPrincipal[borrowerKey];
        uint256 locked = LibEncumbrance.position(borrowerKey, offer.collateralPoolId).directLocked;
        if (locked > borrowerPrincipal) revert InsufficientPrincipal(locked, borrowerPrincipal);
        uint256 collateralRequired = Math.mulDiv(principalAmount, offer.priceNumerator, offer.priceDenominator);
        if (collateralRequired == 0) revert DirectError_InvalidRatio();
        if (collateralRequired > borrowerPrincipal - locked) revert InsufficientPrincipal(collateralRequired, borrowerPrincipal - locked);

        require(
            LibSolvencyChecks.checkSolvency(
                pool,
                borrowerKey,
                borrowerPrincipal,
                LibSolvencyChecks.calculateTotalDebt(pool, borrowerKey, offer.collateralPoolId) + collateralRequired
            ),
            "SolvencyViolation: Borrower LTV"
        );

        uint256 borrowerEncBefore = LibEncumbrance.totalForActiveCredit(borrowerKey, offer.collateralPoolId);
        LibEncumbrance.position(borrowerKey, offer.collateralPoolId).directLocked = locked + collateralRequired;
        LibActiveCreditIndex.applyEncumbranceDelta(
            pool,
            offer.collateralPoolId,
            borrowerKey,
            borrowerEncBefore,
            LibEncumbrance.totalForActiveCredit(borrowerKey, offer.collateralPoolId)
        );

        DirectTypes.DirectConfig storage cfg = ds.config;
        (uint256 platformFee, uint256 interestAmount, uint256 totalFee, uint64 dueTimestamp) =
            _calculateDirectFees(principalAmount, offer.aprBps, offer.durationSeconds, cfg);
        if (totalFee > principalAmount) revert DirectError_InvalidOffer();

        if (principalAmount > lenderPool.trackedBalance) revert InsufficientPrincipal(principalAmount, lenderPool.trackedBalance);

        require(
            LibSolvencyChecks.checkSolvency(
                lenderPool,
                lenderKey,
                lenderPrincipalBefore - principalAmount,
                LibSolvencyChecks.calculateTotalDebt(lenderPool, lenderKey, offer.lenderPoolId)
            ),
            "SolvencyViolation: Lender LTV"
        );

        uint256 lenderEncBefore = LibEncumbrance.totalForActiveCredit(lenderKey, offer.lenderPoolId);
        lenderPool.trackedBalance -= principalAmount;
        if (LibCurrency.isNative(lenderPool.underlying) && principalAmount > 0) {
            LibAppStorage.s().nativeTrackedTotal -= principalAmount;
        }
        ds.activeDirectLentPerPool[offer.lenderPoolId] += principalAmount;
        LibEncumbrance.position(lenderKey, offer.lenderPoolId).directOfferEscrow = offerEscrow - principalAmount;
        LibEncumbrance.position(lenderKey, offer.lenderPoolId).directLent += principalAmount;
        ds.directBorrowedPrincipal[borrowerKey][offer.lenderPoolId] += principalAmount;
        LibActiveCreditIndex.applyEncumbranceDelta(
            lenderPool,
            offer.lenderPoolId,
            lenderKey,
            lenderEncBefore,
            LibEncumbrance.totalForActiveCredit(lenderKey, offer.lenderPoolId)
        );
        lenderPool.userPrincipal[lenderKey] = lenderPrincipalBefore - principalAmount;
        lenderPool.totalDeposits = lenderPool.totalDeposits >= principalAmount
            ? lenderPool.totalDeposits - principalAmount
            : 0;

        if (offer.borrowAsset == offer.collateralAsset) {
            Types.ActiveCreditState storage debtState = pool.userActiveCreditStateDebt[borrowerKey];
            pool.activeCreditPrincipalTotal += principalAmount;
            LibActiveCreditIndex.applyWeightedIncreaseWithGate(
                pool, debtState, principalAmount, offer.collateralPoolId, borrowerKey, true
            );
            debtState.indexSnapshot = pool.activeCreditIndex;
            ds.directSameAssetDebt[borrowerKey][offer.borrowAsset] += principalAmount;
        }

        agreementId = ++ds.nextAgreementId;
        offer.principalRemaining = offer.principalRemaining - principalAmount;
        if (offer.principalRemaining == 0) {
            offer.filled = true;
            LibDirectStorage.untrackRatioLenderOffer(ds, lenderKey, offerId);
        }

        ds.agreements[agreementId] = DirectTypes.DirectAgreement({
            agreementId: agreementId,
            lender: offer.lender,
            borrower: msg.sender,
            lenderPositionId: offer.lenderPositionId,
            lenderPoolId: offer.lenderPoolId,
            borrowerPositionId: borrowerPositionId,
            collateralPoolId: offer.collateralPoolId,
            collateralAsset: offer.collateralAsset,
            borrowAsset: offer.borrowAsset,
            principal: principalAmount,
            userInterest: interestAmount,
            dueTimestamp: dueTimestamp,
            collateralLockAmount: collateralRequired,
            allowEarlyRepay: offer.allowEarlyRepay,
            allowEarlyExercise: offer.allowEarlyExercise,
            allowLenderCall: offer.allowLenderCall,
            status: DirectTypes.DirectStatus.Active,
            interestRealizedUpfront: true
        });
        LibDirectStorage.addBorrowerAgreement(ds, borrowerKey, agreementId);
        LibDirectStorage.addLenderAgreement(ds, lenderKey, agreementId);

        LibCurrency.transfer(offer.borrowAsset, msg.sender, principalAmount - totalFee);

        if (totalFee > 0) {
            _distributeDirectFees(
                lenderPool,
                lenderKey,
                cfg,
                offer.borrowAsset,
                offer.collateralAsset,
                offer.lenderPoolId,
                offer.collateralPoolId,
                interestAmount,
                platformFee
            );
        }

        emit RatioTrancheOfferAccepted(
            offerId, agreementId, borrowerPositionId, principalAmount, offer.principalRemaining, collateralRequired
        );

    }

function _checkAndConsumeTranche(
        DirectTypes.DirectStorage storage ds,
        DirectTypes.DirectOffer storage offer,
        bytes32 lenderKey,
        uint256 offerEscrow
    ) internal returns (TrancheCheckResult memory result) {
        uint256 trancheRemainingBefore = ds.trancheRemaining[offer.offerId];
        result.trancheAmount = offer.trancheAmount;
        result.trancheRemainingBefore = trancheRemainingBefore;
        if (trancheRemainingBefore < offer.principal) {
            _autoCancelTrancheOffer(ds, lenderKey, offer.offerId, offerEscrow, trancheRemainingBefore);
            result.autoCancelled = true;
            return result;
        }
        uint256 trancheRemainingAfter = trancheRemainingBefore - offer.principal;
        result.trancheRemainingAfter = trancheRemainingAfter;
        ds.trancheRemaining[offer.offerId] = trancheRemainingAfter;
        if (trancheRemainingAfter == 0) {
            offer.filled = true;
        }
    }

    function _autoCancelTrancheOffer(
        DirectTypes.DirectStorage storage ds,
        bytes32 lenderKey,
        uint256 offerId,
        uint256 offerEscrow,
        uint256 trancheRemaining
    ) internal {
        DirectTypes.DirectOffer storage offer = ds.offers[offerId];
        Types.PoolData storage lenderPool = LibDirectHelpers._pool(offer.lenderPoolId);
        offer.cancelled = true;
        offer.filled = true;
        uint256 amountReturned = trancheRemaining;
        uint256 trancheAmount = offer.trancheAmount;
        ds.trancheRemaining[offerId] = 0;
        uint256 lenderEncBefore = LibEncumbrance.totalForActiveCredit(lenderKey, offer.lenderPoolId);
        LibEncumbrance.position(lenderKey, offer.lenderPoolId).directOfferEscrow = 0;
        LibActiveCreditIndex.applyEncumbranceDelta(
            lenderPool,
            offer.lenderPoolId,
            lenderKey,
            lenderEncBefore,
            LibEncumbrance.totalForActiveCredit(lenderKey, offer.lenderPoolId)
        );
        LibDirectStorage.untrackLenderOffer(ds, lenderKey, offerId);
        emit DirectOfferCancelled(
            offerId,
            offer.lender,
            offer.lenderPositionId,
            DirectTypes.DirectCancelReason.AutoInsufficientTranche,
            trancheAmount,
            0,
            amountReturned,
            0,
            true
        );
    }

    /// @notice Accept a borrower ratio tranche offer (lender fills variable collateral amount)
    /// @param offerId The borrower ratio tranche offer to accept
    /// @param lenderPositionId The lender's position NFT providing principal
    /// @param collateralAmount The amount of collateral to fill (borrower's collateral)
    function acceptBorrowerRatioTrancheOffer(uint256 offerId, uint256 lenderPositionId, uint256 collateralAmount)
        external
        nonReentrant
        returns (uint256 agreementId)
    {
        if (collateralAmount == 0) revert DirectError_InvalidFillAmount();

        PositionNFT nft = LibDirectHelpers._positionNFT();
        LibDirectHelpers._requireNFTOwnership(nft, lenderPositionId);

        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        DirectTypes.DirectBorrowerRatioTrancheOffer storage offer = ds.borrowerRatioOffers[offerId];
        if (offer.borrower == address(0) || offer.cancelled || offer.filled) revert DirectError_InvalidOffer();
        if (offer.borrowerPositionId == lenderPositionId) revert DirectError_InvalidOffer();
        if (collateralAmount < offer.minCollateralPerFill || collateralAmount > offer.collateralRemaining) {
            revert DirectError_InvalidFillAmount();
        }

        // Calculate principal from collateral: principal = collateral * priceNumerator / priceDenominator
        uint256 principalAmount = Math.mulDiv(collateralAmount, offer.priceNumerator, offer.priceDenominator);
        if (principalAmount == 0) revert DirectError_InvalidRatio();

        Types.PoolData storage lenderPool = LibDirectHelpers._pool(offer.lenderPoolId);
        if (offer.borrowAsset != lenderPool.underlying) revert DirectError_InvalidAsset();

        bytes32 lenderKey = nft.getPositionKey(lenderPositionId);
        LibFeeIndex.settle(offer.lenderPoolId, lenderKey);
        LibActiveCreditIndex.settle(offer.lenderPoolId, lenderKey);
        if (!LibPoolMembership.isMember(lenderKey, offer.lenderPoolId)) revert DirectError_InvalidOffer();

        uint256 lenderPrincipalBefore = lenderPool.userPrincipal[lenderKey];
        if (lenderPrincipalBefore < principalAmount) revert InsufficientPrincipal(principalAmount, lenderPrincipalBefore);

        bytes32 borrowerKey = nft.getPositionKey(offer.borrowerPositionId);
        LibFeeIndex.settle(offer.collateralPoolId, borrowerKey);
        LibActiveCreditIndex.settle(offer.collateralPoolId, borrowerKey);
        Types.PoolData storage collateralPool = LibDirectHelpers._pool(offer.collateralPoolId);
        if (offer.collateralAsset != collateralPool.underlying) revert DirectError_InvalidAsset();
        if (!LibPoolMembership.isMember(borrowerKey, offer.collateralPoolId)) revert DirectError_InvalidOffer();

        // Collateral was already locked when offer was posted, verify it's still locked
        uint256 locked = LibEncumbrance.position(borrowerKey, offer.collateralPoolId).directLocked;
        if (locked < collateralAmount) revert InsufficientPrincipal(collateralAmount, locked);

        DirectTypes.DirectConfig storage cfg = ds.config;
        (uint256 platformFee, uint256 interestAmount, uint256 totalFee, uint64 dueTimestamp) =
            _calculateDirectFees(principalAmount, offer.aprBps, offer.durationSeconds, cfg);
        if (totalFee > principalAmount) revert DirectError_InvalidOffer();

        if (principalAmount > lenderPool.trackedBalance) revert InsufficientPrincipal(principalAmount, lenderPool.trackedBalance);

        require(
            LibSolvencyChecks.checkSolvency(
                lenderPool,
                lenderKey,
                lenderPrincipalBefore - principalAmount,
                LibSolvencyChecks.calculateTotalDebt(lenderPool, lenderKey, offer.lenderPoolId)
            ),
            "SolvencyViolation: Lender LTV"
        );

        // Effects
        uint256 lenderEncBefore = LibEncumbrance.totalForActiveCredit(lenderKey, offer.lenderPoolId);
        lenderPool.trackedBalance -= principalAmount;
        if (LibCurrency.isNative(lenderPool.underlying) && principalAmount > 0) {
            LibAppStorage.s().nativeTrackedTotal -= principalAmount;
        }
        ds.activeDirectLentPerPool[offer.lenderPoolId] += principalAmount;
        LibEncumbrance.position(lenderKey, offer.lenderPoolId).directLent += principalAmount;
        ds.directBorrowedPrincipal[borrowerKey][offer.lenderPoolId] += principalAmount;
        LibActiveCreditIndex.applyEncumbranceDelta(
            lenderPool,
            offer.lenderPoolId,
            lenderKey,
            lenderEncBefore,
            LibEncumbrance.totalForActiveCredit(lenderKey, offer.lenderPoolId)
        );
        lenderPool.userPrincipal[lenderKey] = lenderPrincipalBefore - principalAmount;
        lenderPool.totalDeposits = lenderPool.totalDeposits >= principalAmount
            ? lenderPool.totalDeposits - principalAmount
            : 0;

        if (offer.borrowAsset == offer.collateralAsset) {
            Types.ActiveCreditState storage debtState = collateralPool.userActiveCreditStateDebt[borrowerKey];
            collateralPool.activeCreditPrincipalTotal += principalAmount;
            LibActiveCreditIndex.applyWeightedIncreaseWithGate(
                collateralPool, debtState, principalAmount, offer.collateralPoolId, borrowerKey, true
            );
            debtState.indexSnapshot = collateralPool.activeCreditIndex;
            ds.directSameAssetDebt[borrowerKey][offer.borrowAsset] += principalAmount;
        }

        agreementId = ++ds.nextAgreementId;
        offer.collateralRemaining = offer.collateralRemaining - collateralAmount;
        if (offer.collateralRemaining == 0) {
            offer.filled = true;
            LibDirectStorage.untrackRatioBorrowerOffer(ds, borrowerKey, offerId);
        }

        ds.agreements[agreementId] = DirectTypes.DirectAgreement({
            agreementId: agreementId,
            lender: msg.sender,
            borrower: offer.borrower,
            lenderPositionId: lenderPositionId,
            lenderPoolId: offer.lenderPoolId,
            borrowerPositionId: offer.borrowerPositionId,
            collateralPoolId: offer.collateralPoolId,
            collateralAsset: offer.collateralAsset,
            borrowAsset: offer.borrowAsset,
            principal: principalAmount,
            userInterest: interestAmount,
            dueTimestamp: dueTimestamp,
            collateralLockAmount: collateralAmount,
            allowEarlyRepay: offer.allowEarlyRepay,
            allowEarlyExercise: offer.allowEarlyExercise,
            allowLenderCall: offer.allowLenderCall,
            status: DirectTypes.DirectStatus.Active,
            interestRealizedUpfront: true
        });
        LibDirectStorage.addBorrowerAgreement(ds, borrowerKey, agreementId);
        LibDirectStorage.addLenderAgreement(ds, lenderKey, agreementId);

        LibCurrency.transfer(offer.borrowAsset, offer.borrower, principalAmount - totalFee);

        if (totalFee > 0) {
            _distributeDirectFees(
                lenderPool,
                lenderKey,
                cfg,
                offer.borrowAsset,
                offer.collateralAsset,
                offer.lenderPoolId,
                offer.collateralPoolId,
                interestAmount,
                platformFee
            );
        }

        emit BorrowerRatioTrancheOfferAccepted(
            offerId, agreementId, lenderPositionId, collateralAmount, offer.collateralRemaining, principalAmount
        );

    }
}
