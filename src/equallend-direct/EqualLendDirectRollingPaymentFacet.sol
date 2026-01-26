// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PositionNFT} from "../nft/PositionNFT.sol";
import {Types} from "../libraries/Types.sol";
import {LibActiveCreditIndex} from "../libraries/LibActiveCreditIndex.sol";
import {ReentrancyGuardModifiers} from "../libraries/LibReentrancyGuard.sol";
import {DirectTypes} from "../libraries/DirectTypes.sol";
import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibCurrency} from "../libraries/LibCurrency.sol";
import {LibDirectHelpers} from "../libraries/LibDirectHelpers.sol";
import {LibEncumbrance} from "../libraries/LibEncumbrance.sol";
import {LibDirectStorage} from "../libraries/LibDirectStorage.sol";
import {
    RollingError_AmortizationDisabled,
    RollingError_InvalidInterval,
    RollingError_DustPayment
} from "../libraries/Errors.sol";
import {DirectError_InvalidAgreementState} from "../libraries/Errors.sol";

/// @notice Rolling payment processing with arrears and amortization controls
contract EqualLendDirectRollingPaymentFacet is ReentrancyGuardModifiers {
    event RollingPaymentMade(
        uint256 indexed agreementId,
        address indexed payer,
        uint256 paymentAmount,
        uint256 arrearsReduction,
        uint256 interestPaid,
        uint256 principalReduction,
        uint64 nextDue,
        uint16 paymentCount,
        uint256 newOutstandingPrincipal,
        uint256 newArrears
    );

    uint256 internal constant YEAR_IN_SECONDS = 365 days;
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    function makeRollingPayment(uint256 agreementId, uint256 amount) external payable nonReentrant {
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();

        DirectTypes.DirectRollingAgreement storage agreement = ds.rollingAgreements[agreementId];
        if (agreement.status != DirectTypes.DirectStatus.Active) revert DirectError_InvalidAgreementState();

        PositionNFT nft = LibDirectHelpers._positionNFT();
        LibDirectHelpers._requireNFTOwnership(nft, agreement.borrowerPositionId);

        Types.PoolData storage lenderPool = LibDirectHelpers._pool(agreement.lenderPoolId);
        Types.PoolData storage collateralPool = LibDirectHelpers._pool(agreement.collateralPoolId);
        bytes32 borrowerKey = nft.getPositionKey(agreement.borrowerPositionId);
        bytes32 lenderKey = nft.getPositionKey(agreement.lenderPositionId);

        // Settle indices to avoid stale accounting
        LibActiveCreditIndex.settle(agreement.lenderPoolId, lenderKey);
        LibActiveCreditIndex.settle(agreement.collateralPoolId, borrowerKey);

        uint256 minPayment = Math.mulDiv(
            agreement.outstandingPrincipal,
            ds.rollingConfig.minPaymentBps,
            BPS_DENOMINATOR,
            Math.Rounding.Ceil
        );
        if (amount == 0) revert RollingError_DustPayment(amount, minPayment);
        if (amount < minPayment) revert RollingError_DustPayment(amount, minPayment);
        LibCurrency.assertMsgValue(agreement.borrowAsset, amount);

        // Accrue arrears for elapsed time since last accrual (multi-miss)
        uint256 elapsed = block.timestamp - agreement.lastAccrualTimestamp;
        if (elapsed > 0) {
            uint256 accrued = _rollingInterest(agreement.outstandingPrincipal, agreement.rollingApyBps, elapsed);
            agreement.arrears += accrued;
            agreement.lastAccrualTimestamp = uint64(block.timestamp);
        }

        uint256 currentIntervalInterest =
            _rollingInterest(agreement.outstandingPrincipal, agreement.rollingApyBps, agreement.paymentIntervalSeconds);

        // Pull funds
        uint256 received = LibCurrency.pull(agreement.borrowAsset, msg.sender, amount);
        require(received == amount, "Direct: insufficient amount received");

        uint256 remaining = amount;
        uint256 arrearsPaid = _min(remaining, agreement.arrears);
        agreement.arrears -= arrearsPaid;
        remaining -= arrearsPaid;

        uint256 interestPaid = _min(remaining, currentIntervalInterest);
        remaining -= interestPaid;

        uint256 principalPaid;
        if (remaining > 0) {
            if (!agreement.allowAmortization) revert RollingError_AmortizationDisabled();
            if (remaining > agreement.outstandingPrincipal) {
                principalPaid = agreement.outstandingPrincipal;
            } else {
                principalPaid = remaining;
            }
            agreement.outstandingPrincipal -= principalPaid;
            // Sync borrowed/lent principal for amortization
            ds.directBorrowedPrincipal[borrowerKey][agreement.lenderPoolId] -= principalPaid;
            uint256 lenderEncBefore = LibEncumbrance.totalForActiveCredit(lenderKey, agreement.lenderPoolId);
            LibEncumbrance.position(lenderKey, agreement.lenderPoolId).directLent -= principalPaid;
            uint256 lenderEncAfter = LibEncumbrance.totalForActiveCredit(lenderKey, agreement.lenderPoolId);
            LibActiveCreditIndex.applyEncumbranceDelta(
                lenderPool, agreement.lenderPoolId, lenderKey, lenderEncBefore, lenderEncAfter
            );
            if (collateralPool.activeCreditPrincipalTotal >= principalPaid) {
                collateralPool.activeCreditPrincipalTotal -= principalPaid;
            } else {
                collateralPool.activeCreditPrincipalTotal = 0;
            }
            Types.ActiveCreditState storage debtState = collateralPool.userActiveCreditStateDebt[borrowerKey];
            uint256 debtBefore = debtState.principal;
            LibActiveCreditIndex.applyPrincipalDecrease(collateralPool, debtState, principalPaid);
            if (debtBefore <= principalPaid || debtState.principal == 0) {
                LibActiveCreditIndex.resetIfZeroWithGate(
                    debtState, agreement.collateralPoolId, borrowerKey, true
                );
            } else {
                debtState.indexSnapshot = collateralPool.activeCreditIndex;
            }
        }

        // Advance schedule only if arrears + current interest fully covered
        if (agreement.arrears == 0 && interestPaid == currentIntervalInterest) {
            uint256 nextDueCalc = uint256(agreement.nextDue) + agreement.paymentIntervalSeconds;
            if (nextDueCalc > type(uint64).max) {
                revert RollingError_InvalidInterval(
                    uint32(agreement.paymentIntervalSeconds), ds.rollingConfig.minPaymentIntervalSeconds
                );
            }
            agreement.nextDue = uint64(nextDueCalc);
            agreement.paymentCount += 1;
        }

        // Pay lender
        LibCurrency.transfer(agreement.borrowAsset, agreement.lender, amount);
        if (LibCurrency.isNative(agreement.borrowAsset) && amount > 0) {
            LibAppStorage.s().nativeTrackedTotal -= amount;
        }

        emit RollingPaymentMade(
            agreementId,
            msg.sender,
            amount,
            arrearsPaid,
            interestPaid,
            principalPaid,
            agreement.nextDue,
            agreement.paymentCount,
            agreement.outstandingPrincipal,
            agreement.arrears
        );
    }

    function _rollingInterest(uint256 principal, uint16 apyBps, uint256 durationSeconds) internal pure returns (uint256) {
        if (principal == 0 || apyBps == 0 || durationSeconds == 0) return 0;
        return Math.mulDiv(principal, uint256(apyBps) * durationSeconds, YEAR_IN_SECONDS * 10_000, Math.Rounding.Ceil);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
