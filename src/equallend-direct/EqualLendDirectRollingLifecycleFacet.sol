// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {PositionNFT} from "../nft/PositionNFT.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Types} from "../libraries/Types.sol";
import {LibFeeIndex} from "../libraries/LibFeeIndex.sol";
import {LibActiveCreditIndex} from "../libraries/LibActiveCreditIndex.sol";
import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibCurrency} from "../libraries/LibCurrency.sol";
import {LibFeeRouter} from "../libraries/LibFeeRouter.sol";
import {LibPoolMembership} from "../libraries/LibPoolMembership.sol";
import {ReentrancyGuardModifiers} from "../libraries/LibReentrancyGuard.sol";
import {InsufficientPrincipal} from "../libraries/Errors.sol";
import {DirectTypes} from "../libraries/DirectTypes.sol";
import {LibDirectHelpers} from "../libraries/LibDirectHelpers.sol";
import {LibEncumbrance} from "../libraries/LibEncumbrance.sol";
import {LibDirectStorage} from "../libraries/LibDirectStorage.sol";
import {LibPositionHelpers} from "../libraries/LibPositionHelpers.sol";
import {
    DirectError_InvalidAgreementState,
    DirectError_InvalidConfiguration,
    DirectError_EarlyExerciseNotAllowed,
    DirectError_EarlyRepayNotAllowed,
    RollingError_RecoveryNotEligible
} from "../libraries/Errors.sol";

/// @notice Recovery handling for rolling direct agreements
contract EqualLendDirectRollingLifecycleFacet is ReentrancyGuardModifiers {
    struct RecoveryBreakdown {
        uint256 collateralSeized;
        uint256 penaltyPaid;
        uint256 arrearsPaid;
        uint256 principalPaid;
        uint256 borrowerRefund;
        uint256 amountForDebt;
    }

    event RollingAgreementRecovered(
        uint256 indexed agreementId,
        address indexed executor,
        uint256 penaltyPaid,
        uint256 arrearsPaid,
        uint256 principalRecovered,
        uint256 borrowerRefund,
        uint256 protocolShare,
        uint256 feeIndexShare,
        uint256 activeCreditShare
    );

    event RollingAgreementExercised(
        uint256 indexed agreementId,
        address indexed borrower,
        uint256 arrearsPaid,
        uint256 principalRecovered,
        uint256 borrowerRefund
    );

    event RollingAgreementRepaid(
        uint256 indexed agreementId,
        address indexed borrower,
        uint256 repaymentAmount,
        uint256 arrearsCleared,
        uint256 principalCleared
    );

    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant YEAR_IN_SECONDS = 365 days;

    function recoverRolling(uint256 agreementId) external payable nonReentrant {
        LibCurrency.assertZeroMsgValue();
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        DirectTypes.DirectRollingAgreement storage agreement = ds.rollingAgreements[agreementId];
        if (agreement.status != DirectTypes.DirectStatus.Active || !agreement.isRolling) {
            revert DirectError_InvalidAgreementState();
        }
        if (block.timestamp <= agreement.nextDue + agreement.gracePeriodSeconds) {
            revert RollingError_RecoveryNotEligible();
        }

        PositionNFT nft = LibDirectHelpers._positionNFT();
        bytes32 borrowerKey = nft.getPositionKey(agreement.borrowerPositionId);
        bytes32 lenderKey = nft.getPositionKey(agreement.lenderPositionId);
        Types.PoolData storage collateralPool = LibDirectHelpers._pool(agreement.collateralPoolId);
        Types.PoolData storage lenderPool = LibDirectHelpers._pool(agreement.lenderPoolId);

        LibActiveCreditIndex.settle(agreement.collateralPoolId, borrowerKey);
        LibActiveCreditIndex.settle(agreement.lenderPoolId, lenderKey);

        RecoveryBreakdown memory breakdown;
        breakdown.collateralSeized = _seizeCollateral(ds, agreement, collateralPool, borrowerKey);

        uint256 penaltyBase = agreement.outstandingPrincipal + agreement.arrears;
        breakdown.penaltyPaid = (penaltyBase * ds.rollingConfig.defaultPenaltyBps) / BPS_DENOMINATOR;
        if (breakdown.penaltyPaid > breakdown.collateralSeized) {
            breakdown.penaltyPaid = breakdown.collateralSeized;
        }
        uint256 remainingAfterPenalty = breakdown.collateralSeized - breakdown.penaltyPaid;

        uint256 totalDebt = agreement.arrears + agreement.outstandingPrincipal;
        breakdown.amountForDebt = remainingAfterPenalty < totalDebt ? remainingAfterPenalty : totalDebt;
        breakdown.arrearsPaid = breakdown.amountForDebt < agreement.arrears ? breakdown.amountForDebt : agreement.arrears;
        breakdown.principalPaid =
            breakdown.amountForDebt > breakdown.arrearsPaid ? breakdown.amountForDebt - breakdown.arrearsPaid : 0;
        if (breakdown.principalPaid > agreement.outstandingPrincipal) {
            breakdown.principalPaid = agreement.outstandingPrincipal;
        }
        breakdown.borrowerRefund = remainingAfterPenalty - breakdown.amountForDebt;

        DirectTypes.DirectConfig storage cfg = ds.config;
        (uint256 lenderShare, uint256 protocolShare, uint256 feeIndexShare, uint256 activeCreditShare) =
            _splitDefaultShares(breakdown.amountForDebt, cfg);

        _applyRollingShares(
            agreement,
            collateralPool,
            lenderPool,
            cfg,
            lenderKey,
            lenderShare,
            protocolShare,
            feeIndexShare,
            activeCreditShare
        );

        // Protocol penalty share is credited before borrower refunds.
        if (breakdown.penaltyPaid > 0) {
            address treasury = LibAppStorage.treasuryAddress(LibAppStorage.s());
            if (treasury == address(0)) revert DirectError_InvalidConfiguration();
            bytes32 treasuryKey = LibPositionHelpers.systemPositionKey(treasury);
            LibPoolMembership._ensurePoolMembership(treasuryKey, agreement.collateralPoolId, true);
            collateralPool.userPrincipal[treasuryKey] += breakdown.penaltyPaid;
            collateralPool.totalDeposits += breakdown.penaltyPaid;
        }

        if (breakdown.borrowerRefund > 0) {
            collateralPool.userPrincipal[borrowerKey] += breakdown.borrowerRefund;
            collateralPool.totalDeposits += breakdown.borrowerRefund;
        }

        _clearRollingState(
            ds, agreement, lenderPool, collateralPool, borrowerKey, lenderKey, agreement.outstandingPrincipal, DirectTypes.DirectStatus.Defaulted
        );

        emit RollingAgreementRecovered(
            agreementId,
            msg.sender,
            breakdown.penaltyPaid,
            breakdown.arrearsPaid,
            breakdown.principalPaid,
            breakdown.borrowerRefund,
            protocolShare + breakdown.penaltyPaid,
            feeIndexShare,
            activeCreditShare
        );
    }

    /// @notice Borrower forfeits collateral without penalty, distributes to cover arrears+principal then refunds remainder.
    function exerciseRolling(uint256 agreementId) external payable nonReentrant {
        LibCurrency.assertZeroMsgValue();
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        DirectTypes.DirectRollingAgreement storage agreement = ds.rollingAgreements[agreementId];
        if (agreement.status != DirectTypes.DirectStatus.Active || !agreement.isRolling) {
            revert DirectError_InvalidAgreementState();
        }
        if (!agreement.allowEarlyExercise) {
            revert DirectError_EarlyExerciseNotAllowed();
        }

        PositionNFT nft = LibDirectHelpers._positionNFT();
        LibDirectHelpers._requireBorrowerAuthority(nft, agreement.borrowerPositionId);
        bytes32 borrowerKey = nft.getPositionKey(agreement.borrowerPositionId);
        bytes32 lenderKey = nft.getPositionKey(agreement.lenderPositionId);

        Types.PoolData storage collateralPool = LibDirectHelpers._pool(agreement.collateralPoolId);
        Types.PoolData storage lenderPool = LibDirectHelpers._pool(agreement.lenderPoolId);

        LibActiveCreditIndex.settle(agreement.collateralPoolId, borrowerKey);
        LibActiveCreditIndex.settle(agreement.lenderPoolId, lenderKey);

        uint256 collateralSeized = _seizeCollateral(ds, agreement, collateralPool, borrowerKey);
        uint256 totalDebt = agreement.arrears + agreement.outstandingPrincipal;
        uint256 amountForDebt = collateralSeized < totalDebt ? collateralSeized : totalDebt;
        uint256 arrearsPaid = amountForDebt < agreement.arrears ? amountForDebt : agreement.arrears;
        uint256 principalPaid = amountForDebt > arrearsPaid ? amountForDebt - arrearsPaid : 0;
        if (principalPaid > agreement.outstandingPrincipal) {
            principalPaid = agreement.outstandingPrincipal;
        }
        uint256 borrowerRefund = collateralSeized - amountForDebt;

        DirectTypes.DirectConfig storage cfg = ds.config;
        (uint256 lenderShare, uint256 protocolShare, uint256 feeIndexShare, uint256 activeCreditShare) =
            _splitDefaultShares(amountForDebt, cfg);

        _applyRollingShares(
            agreement, collateralPool, lenderPool, cfg, lenderKey, lenderShare, protocolShare, feeIndexShare, activeCreditShare
        );

        if (borrowerRefund > 0) {
            collateralPool.userPrincipal[borrowerKey] += borrowerRefund;
            collateralPool.totalDeposits += borrowerRefund;
        }

        _clearRollingState(
            ds, agreement, lenderPool, collateralPool, borrowerKey, lenderKey, agreement.outstandingPrincipal, DirectTypes.DirectStatus.Exercised
        );

        emit RollingAgreementExercised(agreementId, msg.sender, arrearsPaid, principalPaid, borrowerRefund);
    }

    /// @notice Borrower repays outstanding principal + arrears in full (early or scheduled) to close agreement.
    function repayRollingInFull(uint256 agreementId) external payable nonReentrant {
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        DirectTypes.DirectRollingAgreement storage agreement = ds.rollingAgreements[agreementId];
        if (agreement.status != DirectTypes.DirectStatus.Active || !agreement.isRolling) {
            revert DirectError_InvalidAgreementState();
        }
        if (!agreement.allowEarlyRepay && agreement.paymentCount < agreement.maxPaymentCount) {
            revert DirectError_EarlyRepayNotAllowed();
        }

        PositionNFT nft = LibDirectHelpers._positionNFT();
        LibDirectHelpers._requireBorrowerAuthority(nft, agreement.borrowerPositionId);
        bytes32 borrowerKey = nft.getPositionKey(agreement.borrowerPositionId);
        bytes32 lenderKey = nft.getPositionKey(agreement.lenderPositionId);

        Types.PoolData storage lenderPool = LibDirectHelpers._pool(agreement.lenderPoolId);
        Types.PoolData storage collateralPool = LibDirectHelpers._pool(agreement.collateralPoolId);

        LibActiveCreditIndex.settle(agreement.collateralPoolId, borrowerKey);
        LibActiveCreditIndex.settle(agreement.lenderPoolId, lenderKey);

        // Accrue arrears up to now before repayment
        uint256 elapsed = block.timestamp - agreement.lastAccrualTimestamp;
        if (elapsed > 0) {
            uint256 accrued = _rollingInterest(agreement.outstandingPrincipal, agreement.rollingApyBps, elapsed);
            agreement.arrears += accrued;
            agreement.lastAccrualTimestamp = uint64(block.timestamp);
        }

        uint256 arrearsDue = agreement.arrears;
        uint256 principalDue = agreement.outstandingPrincipal;
        uint256 repaymentAmount = principalDue + arrearsDue;
        LibCurrency.assertMsgValue(agreement.borrowAsset, repaymentAmount);
        uint256 received = LibCurrency.pull(agreement.borrowAsset, msg.sender, repaymentAmount);
        require(received == repaymentAmount, "Direct: insufficient amount received");
        LibCurrency.transfer(agreement.borrowAsset, agreement.lender, repaymentAmount);
        if (LibCurrency.isNative(agreement.borrowAsset) && repaymentAmount > 0) {
            LibAppStorage.s().nativeTrackedTotal -= repaymentAmount;
        }

        _clearRollingState(
            ds, agreement, lenderPool, collateralPool, borrowerKey, lenderKey, principalDue, DirectTypes.DirectStatus.Repaid
        );

        emit RollingAgreementRepaid(
            agreementId, msg.sender, repaymentAmount, arrearsDue, principalDue
        );
    }

    function _seizeCollateral(
        DirectTypes.DirectStorage storage ds,
        DirectTypes.DirectRollingAgreement storage agreement,
        Types.PoolData storage collateralPool,
        bytes32 borrowerKey
    ) internal returns (uint256 collateralSeized) {
        uint256 locked = LibEncumbrance.position(borrowerKey, agreement.collateralPoolId).directLocked;
        uint256 borrowerPrincipal = collateralPool.userPrincipal[borrowerKey];
        collateralSeized = agreement.collateralLockAmount;
        if (collateralSeized > locked) {
            collateralSeized = locked;
        }
        if (collateralSeized > borrowerPrincipal) {
            collateralSeized = borrowerPrincipal;
        }
        if (collateralSeized > 0) {
            collateralPool.userPrincipal[borrowerKey] = borrowerPrincipal - collateralSeized;
            collateralPool.totalDeposits =
                collateralPool.totalDeposits >= collateralSeized ? collateralPool.totalDeposits - collateralSeized : 0;
        }
    }

    function _splitDefaultShares(uint256 amount, DirectTypes.DirectConfig storage cfg)
        internal
        view
        returns (uint256 lenderShare, uint256 protocolShare, uint256 feeIndexShare, uint256 activeCreditShare)
    {
        if (amount == 0) {
            return (0, 0, 0, 0);
        }
        lenderShare = (amount * cfg.defaultLenderBps) / BPS_DENOMINATOR;
        if (lenderShare > amount) {
            lenderShare = amount;
        }
        uint256 remainder = amount - lenderShare;
        (protocolShare, activeCreditShare, feeIndexShare) = LibFeeRouter.previewSplit(remainder);
    }

    function _applyRollingShares(
        DirectTypes.DirectRollingAgreement storage agreement,
        Types.PoolData storage collateralPool,
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
                collateralPool.userPrincipal[lenderKey] += lenderShare;
                collateralPool.totalDeposits += lenderShare;
            }
            if (protocolShare > 0) {
                if (treasury == address(0)) revert DirectError_InvalidConfiguration();
                LibPoolMembership._ensurePoolMembership(treasuryKey, agreement.collateralPoolId, true);
                collateralPool.userPrincipal[treasuryKey] += protocolShare;
                collateralPool.totalDeposits += protocolShare;
            }
        } else if (sameAsset) {
            uint256 outflow = lenderShare + protocolShare;
            if (outflow > 0) {
                if (outflow > collateralPool.trackedBalance) {
                    revert InsufficientPrincipal(outflow, collateralPool.trackedBalance);
                }
                collateralPool.trackedBalance -= outflow;
                lenderPool.trackedBalance += outflow;
                if (lenderShare > 0) {
                    lenderPool.userPrincipal[lenderKey] += lenderShare;
                    lenderPool.totalDeposits += lenderShare;
                }
                if (protocolShare > 0) {
                    if (treasury == address(0)) revert DirectError_InvalidConfiguration();
                    lenderPool.userPrincipal[treasuryKey] += protocolShare;
                    lenderPool.totalDeposits += protocolShare;
                }
            }
        } else {
            if (lenderShare > 0) {
                LibPoolMembership._ensurePoolMembership(lenderKey, agreement.collateralPoolId, true);
                collateralPool.userPrincipal[lenderKey] += lenderShare;
                collateralPool.totalDeposits += lenderShare;
            }
            if (protocolShare > 0) {
                if (treasury == address(0)) revert DirectError_InvalidConfiguration();
                LibPoolMembership._ensurePoolMembership(treasuryKey, agreement.collateralPoolId, true);
                collateralPool.userPrincipal[treasuryKey] += protocolShare;
                collateralPool.totalDeposits += protocolShare;
            }
        }

        if (feeIndexShare > 0) {
            LibFeeIndex.accrueWithSource(agreement.collateralPoolId, feeIndexShare, keccak256("ROLLING_RECOVERY"));
        }
        if (activeCreditShare > 0) {
            collateralPool.trackedBalance += activeCreditShare;
            LibFeeRouter.accrueActiveCredit(
                agreement.collateralPoolId, activeCreditShare, keccak256("ROLLING_RECOVERY"), 0
            );
        }
    }

    function _clearRollingState(
        DirectTypes.DirectStorage storage ds,
        DirectTypes.DirectRollingAgreement storage agreement,
        Types.PoolData storage lenderPool,
        Types.PoolData storage collateralPool,
        bytes32 borrowerKey,
        bytes32 lenderKey,
        uint256 outstandingAmount,
        DirectTypes.DirectStatus endStatus
    ) internal {
        uint256 lockAmount = agreement.collateralLockAmount;
        uint256 borrowerEncBefore = LibEncumbrance.totalForActiveCredit(borrowerKey, agreement.collateralPoolId);
        uint256 locked = LibEncumbrance.position(borrowerKey, agreement.collateralPoolId).directLocked;
        LibEncumbrance.position(borrowerKey, agreement.collateralPoolId).directLocked =
            locked >= lockAmount ? locked - lockAmount : 0;
        uint256 borrowerEncAfter = LibEncumbrance.totalForActiveCredit(borrowerKey, agreement.collateralPoolId);
        LibActiveCreditIndex.applyEncumbranceDelta(
            collateralPool, agreement.collateralPoolId, borrowerKey, borrowerEncBefore, borrowerEncAfter
        );

        uint256 borrowed = ds.directBorrowedPrincipal[borrowerKey][agreement.lenderPoolId];
        ds.directBorrowedPrincipal[borrowerKey][agreement.lenderPoolId] =
            borrowed >= outstandingAmount ? borrowed - outstandingAmount : 0;

        uint256 lenderEncBefore = LibEncumbrance.totalForActiveCredit(lenderKey, agreement.lenderPoolId);
        uint256 lent = LibEncumbrance.position(lenderKey, agreement.lenderPoolId).directLent;
        LibEncumbrance.position(lenderKey, agreement.lenderPoolId).directLent =
            lent >= outstandingAmount ? lent - outstandingAmount : 0;
        uint256 lenderEncAfter = LibEncumbrance.totalForActiveCredit(lenderKey, agreement.lenderPoolId);
        LibActiveCreditIndex.applyEncumbranceDelta(
            lenderPool, agreement.lenderPoolId, lenderKey, lenderEncBefore, lenderEncAfter
        );

        uint256 activeLent = ds.activeDirectLentPerPool[agreement.lenderPoolId];
        ds.activeDirectLentPerPool[agreement.lenderPoolId] =
            activeLent >= outstandingAmount ? activeLent - outstandingAmount : 0;

        // Lender encumbrance active credit is handled via encumbrance deltas.

        if (agreement.borrowAsset == agreement.collateralAsset) {
            Types.ActiveCreditState storage debtState = collateralPool.userActiveCreditStateDebt[borrowerKey];
            uint256 principalBefore = debtState.principal;
            uint256 decrease = principalBefore >= outstandingAmount ? outstandingAmount : principalBefore;
            if (collateralPool.activeCreditPrincipalTotal >= decrease) {
                collateralPool.activeCreditPrincipalTotal -= decrease;
            } else {
                collateralPool.activeCreditPrincipalTotal = 0;
            }
            LibActiveCreditIndex.applyPrincipalDecrease(collateralPool, debtState, decrease);
            if (principalBefore <= outstandingAmount || debtState.principal == 0) {
                LibActiveCreditIndex.resetIfZeroWithGate(
                    debtState, agreement.collateralPoolId, borrowerKey, true
                );
            } else {
                debtState.indexSnapshot = collateralPool.activeCreditIndex;
            }
            uint256 sameAssetDebt = ds.directSameAssetDebt[borrowerKey][agreement.borrowAsset];
            ds.directSameAssetDebt[borrowerKey][agreement.borrowAsset] =
                sameAssetDebt >= outstandingAmount ? sameAssetDebt - outstandingAmount : 0;
        }

        LibDirectStorage.removeRollingBorrowerAgreement(ds, borrowerKey, agreement.agreementId);
        LibDirectStorage.removeRollingLenderAgreement(ds, lenderKey, agreement.agreementId);

        agreement.arrears = 0;
        agreement.outstandingPrincipal = 0;
        agreement.status = endStatus;
        agreement.nextDue = uint64(block.timestamp);
    }

    function _rollingInterest(uint256 principal, uint16 apyBps, uint256 durationSeconds) internal pure returns (uint256) {
        if (principal == 0 || apyBps == 0 || durationSeconds == 0) return 0;
        return Math.mulDiv(principal, uint256(apyBps) * durationSeconds, YEAR_IN_SECONDS * 10_000, Math.Rounding.Ceil);
    }
}
