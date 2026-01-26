// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {PositionNFT} from "../nft/PositionNFT.sol";
import {Types} from "../libraries/Types.sol";
import {LibActiveCreditIndex} from "../libraries/LibActiveCreditIndex.sol";
import {ReentrancyGuardModifiers} from "../libraries/LibReentrancyGuard.sol";
import {DirectTypes} from "../libraries/DirectTypes.sol";
import {LibCurrency} from "../libraries/LibCurrency.sol";
import {LibDirectHelpers} from "../libraries/LibDirectHelpers.sol";
import {LibEncumbrance} from "../libraries/LibEncumbrance.sol";
import {LibDirectStorage} from "../libraries/LibDirectStorage.sol";
import {LibDirectExercise} from "./LibDirectExercise.sol";
import {
    DirectError_EarlyExerciseNotAllowed,
    DirectError_EarlyRepayNotAllowed,
    DirectError_GracePeriodActive,
    DirectError_GracePeriodExpired,
    DirectError_LenderCallNotAllowed,
    DirectError_InvalidAgreementState,
    DirectError_InvalidConfiguration,
    DirectError_InvalidTimestamp
} from "../libraries/Errors.sol";

/// @notice Agreement lifecycle entrypoints for EqualLend direct lending
contract EqualLendDirectLifecycleFacet is ReentrancyGuardModifiers {
    event DirectAgreementRepaid(uint256 indexed agreementId, address indexed borrower, uint256 principalRepaid);

    event DirectAgreementRecovered(
        uint256 indexed agreementId,
        address indexed executor,
        uint256 lenderShare,
        uint256 protocolShare,
        uint256 feeIndexShare
    );

    event DirectAgreementExercised(uint256 indexed agreementId, address indexed borrower);
    event DirectAgreementCalled(uint256 indexed agreementId, uint256 indexed lenderPositionId, uint64 newDueTimestamp);

    function _calculateDefaultShares(
        DirectTypes.DirectAgreement storage agreement,
        Types.PoolData storage pool,
        DirectTypes.DirectConfig storage cfg,
        bytes32 borrowerKey
    ) internal returns (uint256 lenderShare, uint256 protocolShare, uint256 feeIndexShare, uint256 activeCreditShare) {
        return LibDirectExercise.calculateDefaultShares(agreement, pool, cfg, borrowerKey);
    }

    function _applyDefaultShares(
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
        LibDirectExercise.applyDefaultShares(
            agreement, pool, lenderPool, cfg, lenderKey, lenderShare, protocolShare, feeIndexShare, activeCreditShare
        );
    }

    function _clearAgreementState(
        DirectTypes.DirectStorage storage ds,
        DirectTypes.DirectAgreement storage agreement,
        bytes32 borrowerKey,
        bytes32 lenderKey
    ) internal {
        LibDirectExercise.clearAgreementState(ds, agreement, borrowerKey, lenderKey);
    }

    function repay(uint256 agreementId) external payable nonReentrant {
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        DirectTypes.DirectAgreement storage agreement = ds.agreements[agreementId];
        if (agreement.status != DirectTypes.DirectStatus.Active) revert DirectError_InvalidAgreementState();
        PositionNFT nft = LibDirectHelpers._positionNFT();
        LibDirectHelpers._requireBorrowerAuthority(nft, agreement.borrowerPositionId);
        uint256 dueTimestamp = agreement.dueTimestamp;
        uint256 gracePeriod = 1 days;
        if (block.timestamp > dueTimestamp + gracePeriod) {
            revert DirectError_GracePeriodExpired();
        }
        if (!agreement.allowEarlyRepay && dueTimestamp > gracePeriod) {
            if (block.timestamp < dueTimestamp - gracePeriod) {
                revert DirectError_EarlyRepayNotAllowed();
            }
        }

        Types.PoolData storage lenderPool = LibDirectHelpers._pool(agreement.lenderPoolId);
        Types.PoolData storage collateralPool = LibDirectHelpers._pool(agreement.collateralPoolId); // ensure collateral pool still exists

        bytes32 borrowerKey = nft.getPositionKey(agreement.borrowerPositionId);
        bytes32 lenderKey = nft.getPositionKey(agreement.lenderPositionId);

        LibActiveCreditIndex.settle(agreement.collateralPoolId, borrowerKey);
        LibActiveCreditIndex.settle(agreement.lenderPoolId, lenderKey);

        uint256 principal = agreement.principal;
        LibCurrency.assertMsgValue(agreement.borrowAsset, principal);
        uint256 received = LibCurrency.pull(agreement.borrowAsset, msg.sender, principal);
        require(received == principal, "Direct: insufficient amount received");

        uint256 borrowedBefore = ds.directBorrowedPrincipal[borrowerKey][agreement.lenderPoolId];
        uint256 lentBefore = LibEncumbrance.position(lenderKey, agreement.lenderPoolId).directLent;
        lenderPool.trackedBalance += principal;
        lenderPool.userPrincipal[lenderKey] += principal;
        lenderPool.totalDeposits += principal;
        uint256 activeLent = ds.activeDirectLentPerPool[agreement.lenderPoolId];
        if (activeLent >= principal) {
            ds.activeDirectLentPerPool[agreement.lenderPoolId] = activeLent - principal;
        } else {
            ds.activeDirectLentPerPool[agreement.lenderPoolId] = 0;
        }
        // Lender encumbrance active credit is handled via encumbrance deltas.
        agreement.status = DirectTypes.DirectStatus.Repaid;

        uint256 borrowerEncBefore = LibEncumbrance.totalForActiveCredit(borrowerKey, agreement.collateralPoolId);
        if (LibEncumbrance.position(borrowerKey, agreement.collateralPoolId).directLocked >= agreement.collateralLockAmount) {
            LibEncumbrance.position(borrowerKey, agreement.collateralPoolId).directLocked -= agreement.collateralLockAmount;
        } else {
            LibEncumbrance.position(borrowerKey, agreement.collateralPoolId).directLocked = 0;
        }
        uint256 borrowerEncAfter = LibEncumbrance.totalForActiveCredit(borrowerKey, agreement.collateralPoolId);
        LibActiveCreditIndex.applyEncumbranceDelta(
            collateralPool, agreement.collateralPoolId, borrowerKey, borrowerEncBefore, borrowerEncAfter
        );

        uint256 lenderEncBefore = LibEncumbrance.totalForActiveCredit(lenderKey, agreement.lenderPoolId);
        if (LibEncumbrance.position(lenderKey, agreement.lenderPoolId).directLent >= agreement.principal) {
            LibEncumbrance.position(lenderKey, agreement.lenderPoolId).directLent -= agreement.principal;
        } else {
            LibEncumbrance.position(lenderKey, agreement.lenderPoolId).directLent = 0;
        }
        uint256 lenderEncAfter = LibEncumbrance.totalForActiveCredit(lenderKey, agreement.lenderPoolId);
        LibActiveCreditIndex.applyEncumbranceDelta(
            lenderPool, agreement.lenderPoolId, lenderKey, lenderEncBefore, lenderEncAfter
        );
        uint256 borrowed = ds.directBorrowedPrincipal[borrowerKey][agreement.lenderPoolId];
        if (borrowed >= agreement.principal) {
            ds.directBorrowedPrincipal[borrowerKey][agreement.lenderPoolId] = borrowed - agreement.principal;
        } else {
            ds.directBorrowedPrincipal[borrowerKey][agreement.lenderPoolId] = 0;
        }
        if (lentBefore - LibEncumbrance.position(lenderKey, agreement.lenderPoolId).directLent != agreement.principal) {
            revert DirectError_InvalidAgreementState();
        }
        if (borrowedBefore - ds.directBorrowedPrincipal[borrowerKey][agreement.lenderPoolId] != agreement.principal) {
            revert DirectError_InvalidAgreementState();
        }

        if (agreement.borrowAsset == agreement.collateralAsset) {
            LibActiveCreditIndex.settle(agreement.collateralPoolId, borrowerKey);
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

        LibDirectStorage.removeBorrowerAgreement(ds, borrowerKey, agreementId);
        LibDirectStorage.removeLenderAgreement(ds, lenderKey, agreementId);

        emit DirectAgreementRepaid(agreementId, msg.sender, agreement.principal);
    }

    function exerciseDirect(uint256 agreementId) external payable nonReentrant {
        LibCurrency.assertZeroMsgValue();
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        DirectTypes.DirectAgreement storage agreement = ds.agreements[agreementId];
        if (agreement.status != DirectTypes.DirectStatus.Active) revert DirectError_InvalidAgreementState();
        PositionNFT nft = LibDirectHelpers._positionNFT();
        LibDirectHelpers._requireBorrowerAuthority(nft, agreement.borrowerPositionId);
        bytes32 borrowerKey = nft.getPositionKey(agreement.borrowerPositionId);
        bytes32 lenderKey = nft.getPositionKey(agreement.lenderPositionId);

        LibDirectExercise.exercise(ds, agreementId, borrowerKey, lenderKey, msg.sender);
    }

    /// @notice Lender-initiated call to accelerate the due timestamp when allowed.
    function callDirect(uint256 agreementId) external payable nonReentrant {
        LibCurrency.assertZeroMsgValue();
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        DirectTypes.DirectAgreement storage agreement = ds.agreements[agreementId];
        if (agreement.status != DirectTypes.DirectStatus.Active) revert DirectError_InvalidAgreementState();
        if (!agreement.allowLenderCall) revert DirectError_LenderCallNotAllowed();
        if (block.timestamp >= agreement.dueTimestamp) revert DirectError_InvalidTimestamp();
        PositionNFT nft = LibDirectHelpers._positionNFT();
        LibDirectHelpers._requireNFTOwnership(nft, agreement.lenderPositionId);

        uint64 newDue = uint64(block.timestamp);
        agreement.dueTimestamp = newDue;

        emit DirectAgreementCalled(agreementId, agreement.lenderPositionId, newDue);
    }

    function recover(uint256 agreementId) external payable nonReentrant {
        LibCurrency.assertZeroMsgValue();
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        DirectTypes.DirectAgreement storage agreement = ds.agreements[agreementId];
        if (agreement.status != DirectTypes.DirectStatus.Active) revert DirectError_InvalidAgreementState();
        if (block.timestamp < agreement.dueTimestamp + 1 days) {
            revert DirectError_GracePeriodActive();
        }

        PositionNFT nft = LibDirectHelpers._positionNFT();
        bytes32 borrowerKey = nft.getPositionKey(agreement.borrowerPositionId);
        bytes32 lenderKey = nft.getPositionKey(agreement.lenderPositionId);

        Types.PoolData storage pool = LibDirectHelpers._pool(agreement.collateralPoolId);
        Types.PoolData storage lenderPool = LibDirectHelpers._pool(agreement.lenderPoolId);

        DirectTypes.DirectConfig storage cfg = ds.config;

        LibActiveCreditIndex.settle(agreement.collateralPoolId, borrowerKey);
        LibActiveCreditIndex.settle(agreement.lenderPoolId, lenderKey);

        // Mark agreement defaulted before any external interactions
        agreement.status = DirectTypes.DirectStatus.Defaulted;

        (uint256 lenderShare, uint256 protocolShare, uint256 feeIndexShare, uint256 activeCreditShare) =
            _calculateDefaultShares(agreement, pool, cfg, borrowerKey);
        _applyDefaultShares(
            agreement, pool, lenderPool, cfg, lenderKey, lenderShare, protocolShare, feeIndexShare, activeCreditShare
        );
        _clearAgreementState(ds, agreement, borrowerKey, lenderKey);

        emit DirectAgreementRecovered(agreementId, msg.sender, lenderShare, protocolShare, feeIndexShare);
    }
}
