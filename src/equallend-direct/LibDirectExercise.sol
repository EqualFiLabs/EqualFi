// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Types} from "../libraries/Types.sol";
import {DirectTypes} from "../libraries/DirectTypes.sol";
import {LibDirectHelpers} from "../libraries/LibDirectHelpers.sol";
import {LibPositionHelpers} from "../libraries/LibPositionHelpers.sol";
import {LibEncumbrance} from "../libraries/LibEncumbrance.sol";
import {LibDirectStorage} from "../libraries/LibDirectStorage.sol";
import {LibActiveCreditIndex} from "../libraries/LibActiveCreditIndex.sol";
import {LibFeeIndex} from "../libraries/LibFeeIndex.sol";
import {LibPoolMembership} from "../libraries/LibPoolMembership.sol";
import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibFeeRouter} from "../libraries/LibFeeRouter.sol";
import {InsufficientPrincipal} from "../libraries/Errors.sol";
import {
    DirectError_EarlyExerciseNotAllowed,
    DirectError_InvalidAgreementState,
    DirectError_InvalidConfiguration,
    DirectError_InvalidTimestamp
} from "../libraries/Errors.sol";

/// @notice Shared exercise helpers for EqualLend Direct agreements.
library LibDirectExercise {
    event DirectAgreementExercised(uint256 indexed agreementId, address indexed borrower);

    function calculateDefaultShares(
        DirectTypes.DirectAgreement storage agreement,
        Types.PoolData storage pool,
        DirectTypes.DirectConfig storage cfg,
        bytes32 borrowerKey
    ) internal returns (uint256 lenderShare, uint256 protocolShare, uint256 feeIndexShare, uint256 activeCreditShare) {
        uint256 lockAmount = agreement.collateralLockAmount;
        uint256 borrowerPrincipal = pool.userPrincipal[borrowerKey];
        uint256 collateralAvailable = borrowerPrincipal >= lockAmount ? lockAmount : borrowerPrincipal;
        if (collateralAvailable > 0) {
            pool.userPrincipal[borrowerKey] = borrowerPrincipal - collateralAvailable;
            pool.totalDeposits = pool.totalDeposits >= collateralAvailable ? pool.totalDeposits - collateralAvailable : 0;
        }
        lenderShare = (collateralAvailable * cfg.defaultLenderBps) / 10_000;
        if (lenderShare > collateralAvailable) {
            lenderShare = collateralAvailable;
        }
        uint256 remainder = collateralAvailable - lenderShare;
        (protocolShare, activeCreditShare, feeIndexShare) = LibFeeRouter.previewSplit(remainder);
    }

    function applyDefaultShares(
        DirectTypes.DirectAgreement storage agreement,
        Types.PoolData storage pool,
        Types.PoolData storage lenderPool,
        DirectTypes.DirectConfig storage cfg,
        bytes32 lenderKey,
        uint256 lenderShare,
        uint256 protocolShare,
        uint256 feeIndexShare,
        uint256 activeCreditShare
    ) internal {
        bool sameAsset = agreement.borrowAsset == agreement.collateralAsset;
        bool creditWithinCollateralPool = agreement.lenderPoolId == agreement.collateralPoolId;
        address treasury = LibAppStorage.treasuryAddress(LibAppStorage.s());
        bytes32 treasuryKey = LibPositionHelpers.systemPositionKey(treasury);

        if (creditWithinCollateralPool) {
            if (lenderShare > 0) {
                pool.userPrincipal[lenderKey] += lenderShare;
                pool.totalDeposits += lenderShare;
            }
            if (protocolShare > 0) {
                if (treasury == address(0)) revert DirectError_InvalidConfiguration();
                pool.userPrincipal[treasuryKey] += protocolShare;
                pool.totalDeposits += protocolShare;
            }
        } else if (sameAsset) {
            uint256 outflow = lenderShare + protocolShare;
            if (outflow > 0) {
                if (outflow > pool.trackedBalance) {
                    revert InsufficientPrincipal(outflow, pool.trackedBalance);
                }
                if (lenderShare > 0) {
                    pool.trackedBalance -= lenderShare;
                    lenderPool.trackedBalance += lenderShare;
                    lenderPool.userPrincipal[lenderKey] += lenderShare;
                    lenderPool.totalDeposits += lenderShare;
                }
                if (protocolShare > 0) {
                    if (treasury == address(0)) revert DirectError_InvalidConfiguration();
                    pool.trackedBalance -= protocolShare;
                    lenderPool.trackedBalance += protocolShare;
                    lenderPool.userPrincipal[treasuryKey] += protocolShare;
                    lenderPool.totalDeposits += protocolShare;
                }
            }
        } else {
            if (lenderShare > 0) {
                LibPoolMembership._ensurePoolMembership(lenderKey, agreement.collateralPoolId, true);
                pool.userPrincipal[lenderKey] += lenderShare;
                pool.totalDeposits += lenderShare;
            }
            if (protocolShare > 0) {
                if (treasury == address(0)) revert DirectError_InvalidConfiguration();
                LibPoolMembership._ensurePoolMembership(treasuryKey, agreement.collateralPoolId, true);
                pool.userPrincipal[treasuryKey] += protocolShare;
                pool.totalDeposits += protocolShare;
            }
        }
        if (feeIndexShare > 0) {
            LibFeeIndex.accrueWithSource(agreement.collateralPoolId, feeIndexShare, keccak256("DIRECT_DEFAULT"));
        }

        if (activeCreditShare > 0) {
            pool.trackedBalance += activeCreditShare;
            LibFeeRouter.accrueActiveCredit(
                agreement.collateralPoolId, activeCreditShare, keccak256("DIRECT_DEFAULT"), 0
            );
        }
    }

    function clearAgreementState(
        DirectTypes.DirectStorage storage ds,
        DirectTypes.DirectAgreement storage agreement,
        bytes32 borrowerKey,
        bytes32 lenderKey
    ) internal {
        Types.PoolData storage collateralPool = LibDirectHelpers._pool(agreement.collateralPoolId);
        Types.PoolData storage lenderPool = LibDirectHelpers._pool(agreement.lenderPoolId);
        uint256 borrowedBefore = ds.directBorrowedPrincipal[borrowerKey][agreement.lenderPoolId];
        uint256 lentBefore = LibEncumbrance.position(lenderKey, agreement.lenderPoolId).directLent;
        uint256 lockAmount = agreement.collateralLockAmount;
        uint256 borrowerEncBefore = LibEncumbrance.totalForActiveCredit(borrowerKey, agreement.collateralPoolId);
        uint256 locked = LibEncumbrance.position(borrowerKey, agreement.collateralPoolId).directLocked;
        LibEncumbrance.position(borrowerKey, agreement.collateralPoolId).directLocked =
            locked >= lockAmount ? locked - lockAmount : 0;
        uint256 borrowerEncAfter = LibEncumbrance.totalForActiveCredit(borrowerKey, agreement.collateralPoolId);
        LibActiveCreditIndex.applyEncumbranceDelta(
            collateralPool, agreement.collateralPoolId, borrowerKey, borrowerEncBefore, borrowerEncAfter
        );

        uint256 lenderEncBefore = LibEncumbrance.totalForActiveCredit(lenderKey, agreement.lenderPoolId);
        uint256 lent = LibEncumbrance.position(lenderKey, agreement.lenderPoolId).directLent;
        LibEncumbrance.position(lenderKey, agreement.lenderPoolId).directLent =
            lent >= agreement.principal ? lent - agreement.principal : 0;
        uint256 lenderEncAfter = LibEncumbrance.totalForActiveCredit(lenderKey, agreement.lenderPoolId);
        LibActiveCreditIndex.applyEncumbranceDelta(
            lenderPool, agreement.lenderPoolId, lenderKey, lenderEncBefore, lenderEncAfter
        );
        uint256 borrowed = ds.directBorrowedPrincipal[borrowerKey][agreement.lenderPoolId];
        ds.directBorrowedPrincipal[borrowerKey][agreement.lenderPoolId] =
            borrowed >= agreement.principal ? borrowed - agreement.principal : 0;
        // Lender encumbrance active credit is handled via encumbrance deltas.
        if (lentBefore - LibEncumbrance.position(lenderKey, agreement.lenderPoolId).directLent != agreement.principal) {
            revert DirectError_InvalidAgreementState();
        }
        if (borrowedBefore - ds.directBorrowedPrincipal[borrowerKey][agreement.lenderPoolId] != agreement.principal) {
            revert DirectError_InvalidAgreementState();
        }
        uint256 activeLent = ds.activeDirectLentPerPool[agreement.lenderPoolId];
        if (activeLent >= agreement.principal) {
            ds.activeDirectLentPerPool[agreement.lenderPoolId] = activeLent - agreement.principal;
        } else {
            ds.activeDirectLentPerPool[agreement.lenderPoolId] = 0;
        }
        // Lender encumbrance active credit is handled via encumbrance deltas.
        if (agreement.borrowAsset == agreement.collateralAsset) {
            Types.ActiveCreditState storage debtState = collateralPool.userActiveCreditStateDebt[borrowerKey];
            uint256 principalBefore = debtState.principal;
            uint256 decrease = principalBefore >= agreement.principal ? agreement.principal : principalBefore;
            if (collateralPool.activeCreditPrincipalTotal >= decrease) {
                collateralPool.activeCreditPrincipalTotal -= decrease;
            } else {
                collateralPool.activeCreditPrincipalTotal = 0;
            }
            LibActiveCreditIndex.applyPrincipalDecrease(collateralPool, debtState, decrease);
            if (principalBefore <= agreement.principal || debtState.principal == 0) {
                LibActiveCreditIndex.resetIfZeroWithGate(
                    debtState, agreement.collateralPoolId, borrowerKey, true
                );
            } else {
                debtState.indexSnapshot = collateralPool.activeCreditIndex;
            }
            ds.directSameAssetDebt[borrowerKey][agreement.borrowAsset] -= agreement.principal;
        }
        LibDirectStorage.removeBorrowerAgreement(ds, borrowerKey, agreement.agreementId);
        LibDirectStorage.removeLenderAgreement(ds, lenderKey, agreement.agreementId);
    }

    function exercise(
        DirectTypes.DirectStorage storage ds,
        uint256 agreementId,
        bytes32 borrowerKey,
        bytes32 lenderKey,
        address caller
    ) internal {
        DirectTypes.DirectAgreement storage agreement = ds.agreements[agreementId];
        if (agreement.status != DirectTypes.DirectStatus.Active) revert DirectError_InvalidAgreementState();

        uint256 dueTimestamp = agreement.dueTimestamp;
        uint256 gracePeriod = 1 days;
        if (block.timestamp < dueTimestamp && !agreement.allowEarlyExercise) {
            revert DirectError_EarlyExerciseNotAllowed();
        }
        if (block.timestamp > dueTimestamp + gracePeriod) {
            revert DirectError_InvalidTimestamp();
        }

        Types.PoolData storage pool = LibDirectHelpers._pool(agreement.collateralPoolId);
        Types.PoolData storage lenderPool = LibDirectHelpers._pool(agreement.lenderPoolId);
        DirectTypes.DirectConfig storage cfg = ds.config;

        LibActiveCreditIndex.settle(agreement.collateralPoolId, borrowerKey);
        LibActiveCreditIndex.settle(agreement.lenderPoolId, lenderKey);

        agreement.status = DirectTypes.DirectStatus.Exercised;

        (uint256 lenderShare, uint256 protocolShare, uint256 feeIndexShare, uint256 activeCreditShare) =
            calculateDefaultShares(agreement, pool, cfg, borrowerKey);
        applyDefaultShares(
            agreement, pool, lenderPool, cfg, lenderKey, lenderShare, protocolShare, feeIndexShare, activeCreditShare
        );
        clearAgreementState(ds, agreement, borrowerKey, lenderKey);

        emit DirectAgreementExercised(agreementId, caller);
    }
}
