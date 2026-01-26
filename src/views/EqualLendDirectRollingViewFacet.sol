// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {DirectTypes} from "../libraries/DirectTypes.sol";
import {LibDirectStorage} from "../libraries/LibDirectStorage.sol";

/// @notice View helpers for rolling agreements: status, payment calculations, aggregates
contract EqualLendDirectRollingViewFacet {
    uint256 internal constant VIEW_YEAR_IN_SECONDS = 365 days;

    struct RollingStatus {
        bool isOverdue;
        bool inGracePeriod;
        bool canRecover;
        bool isAtPaymentCap;
    }

    struct RollingExposure {
        uint256 totalOutstandingPrincipal;
        uint256 totalArrears;
        uint64 nextPaymentDue; // earliest nextDue across borrower agreements
        uint256 activeAgreementCount;
    }

    /// @notice Calculate current interval interest due and total due (arrears + interest) for an agreement
    function calculateRollingPayment(uint256 agreementId)
        external
        view
        returns (uint256 currentInterestDue, uint256 totalDue)
    {
        DirectTypes.DirectRollingAgreement storage agreement = LibDirectStorage.directStorage().rollingAgreements[agreementId];
        currentInterestDue = _rollingInterestView(
            agreement.outstandingPrincipal, agreement.rollingApyBps, agreement.paymentIntervalSeconds
        );
        totalDue = agreement.arrears + currentInterestDue;
    }

    /// @notice Return status flags for an agreement
    function getRollingStatus(uint256 agreementId) external view returns (RollingStatus memory status) {
        DirectTypes.DirectRollingAgreement storage agreement = LibDirectStorage.directStorage().rollingAgreements[agreementId];
        bool overdue = block.timestamp > agreement.nextDue;
        bool grace = block.timestamp <= agreement.nextDue + agreement.gracePeriodSeconds;
        status.isOverdue = overdue;
        status.inGracePeriod = overdue && grace;
        status.canRecover = overdue && !grace;
        status.isAtPaymentCap = agreement.paymentCount >= agreement.maxPaymentCount;
    }

    /// @notice Aggregate borrower rolling exposure for a position key
    function aggregateRollingExposure(bytes32 borrowerKey) external view returns (RollingExposure memory agg) {
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        (uint256[] memory agreements, uint256 total) = LibDirectStorage.rollingBorrowerAgreementsPage(ds, borrowerKey, 0, 0);
        agg.activeAgreementCount = total;
        uint64 earliestDue = type(uint64).max;
        for (uint256 i = 0; i < agreements.length; i++) {
            DirectTypes.DirectRollingAgreement storage agreement = ds.rollingAgreements[agreements[i]];
            if (agreement.status != DirectTypes.DirectStatus.Active) continue;
            agg.totalOutstandingPrincipal += agreement.outstandingPrincipal;
            agg.totalArrears += agreement.arrears;
            if (agreement.nextDue < earliestDue) {
                earliestDue = agreement.nextDue;
            }
        }
        if (earliestDue != type(uint64).max) {
            agg.nextPaymentDue = earliestDue;
        }
    }

    function _rollingInterestView(uint256 principal, uint16 apyBps, uint256 durationSeconds) internal pure returns (uint256) {
        if (principal == 0 || apyBps == 0 || durationSeconds == 0) return 0;
        return Math.mulDiv(principal, uint256(apyBps) * durationSeconds, VIEW_YEAR_IN_SECONDS * 10_000, Math.Rounding.Ceil);
    }
}
