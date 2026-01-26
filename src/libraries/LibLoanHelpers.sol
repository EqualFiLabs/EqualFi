// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibAppStorage} from "./LibAppStorage.sol";
import {LibLoanManager} from "./LibLoanManager.sol";
import {LibLoanManagerStorage} from "./LibLoanManagerStorage.sol";
import {Types} from "./Types.sol";

/// @title LibLoanHelpers
/// @notice Shared helpers for loan state, delinquency tracking, and interest calculations
library LibLoanHelpers {
    using LibLoanManager for LibLoanManager.LoanManager;

    /// @notice Calculate missed payment epochs since last timestamp (storage loan)
    function calculateMissedEpochs(Types.RollingCreditLoan storage loan) internal view returns (uint256) {
        if (!loan.active) return 0;
        uint256 interval = loan.paymentIntervalSecs;
        if (interval == 0 || block.timestamp <= loan.lastPaymentTimestamp) {
            return 0;
        }
        return (block.timestamp - loan.lastPaymentTimestamp) / interval;
    }

    /// @notice View helper for missed epochs on a memory loan copy
    function calculateMissedEpochsView(Types.RollingCreditLoan memory loan) internal view returns (uint256) {
        if (!loan.active) return 0;
        uint256 interval = loan.paymentIntervalSecs;
        if (interval == 0 || block.timestamp <= loan.lastPaymentTimestamp) {
            return 0;
        }
        return (block.timestamp - loan.lastPaymentTimestamp) / interval;
    }

    /// @notice Get delinquency thresholds with defaults applied and penalty >= delinquency
    function delinquencyThresholds() internal view returns (uint8 delinquentEpochs, uint8 penaltyEpochs) {
        LibAppStorage.AppStorage storage store = LibAppStorage.s();
        delinquentEpochs = store.rollingDelinquencyEpochs;
        if (delinquentEpochs == 0) {
            delinquentEpochs = LibAppStorage.DEFAULT_ROLLING_DELINQUENCY_EPOCHS;
        }
        penaltyEpochs = store.rollingPenaltyEpochs;
        if (penaltyEpochs == 0) {
            penaltyEpochs = LibAppStorage.DEFAULT_ROLLING_PENALTY_EPOCHS;
        }
        // ensure penalty threshold is at least delinquency to avoid accidental inversion
        if (penaltyEpochs < delinquentEpochs) {
            penaltyEpochs = delinquentEpochs;
        }
    }

    /// @notice Sync missed payments based on elapsed epochs (non-saturating down)
    function syncMissedPayments(Types.RollingCreditLoan storage loan) internal {
        uint256 missedEpochs = calculateMissedEpochs(loan);
        if (missedEpochs > loan.missedPayments) {
            uint256 capped = missedEpochs > 3 ? 3 : missedEpochs;
            loan.missedPayments = uint8(capped);
        }
    }

    /// @notice Calculate accrued interest on a rolling credit loan
    /// @param principal The principal amount
    /// @param apyBps The APY in basis points
    /// @param elapsed The time elapsed in seconds
    /// @return The accrued interest amount
    function calculateAccruedInterest(uint256 principal, uint16 apyBps, uint256 elapsed)
        internal
        pure
        returns (uint256)
    {
        return (principal * apyBps * elapsed) / (10_000 * 365 days);
    }

    /// @notice Calculate the default penalty for a loan based on original principal
    /// @param principalAtOpen The principal basis recorded at loan origination
    /// @return The default penalty amount (5% of principalAtOpen)
    function calculatePenalty(uint256 principalAtOpen) internal pure returns (uint256) {
        require(principalAtOpen <= type(uint256).max / 500, "LoanHelpers: penalty overflow");
        return (principalAtOpen * 500) / 10_000;
    }

    /// @notice Accessor for the loan manager of a pool
    function loanManager(uint256 pid) internal view returns (LibLoanManager.LoanManager storage manager) {
        return LibLoanManagerStorage.s().managers[pid];
    }

    /// @notice Add a loan ID to the user's loan array and index mapping
    function addLoanIdWithIndex(
        Types.PoolData storage p,
        uint256 pid,
        bytes32 positionKey,
        uint256 loanId
    ) internal {
        LibLoanManager.LoanManager storage manager = loanManager(pid);
        // Maintain LibLoanManager list for future filtering/sorting while preserving legacy array behavior
        manager.addLoan(positionKey, loanId);

        uint256 index = p.userFixedLoanIds[positionKey].length;
        p.userFixedLoanIds[positionKey].push(loanId);
        p.loanIdToIndex[positionKey][loanId] = index;
    }

    /// @notice Remove a loan ID from the user's loan array using the stored index mapping
    function removeLoanIdByIndex(
        Types.PoolData storage p,
        uint256 pid,
        bytes32 positionKey,
        uint256 loanId,
        uint256 loanIndex
    ) internal {
        LibLoanManager.LoanManager storage manager = loanManager(pid);
        (,, bool exists) = manager.getNode(positionKey, loanId);
        if (exists) {
            manager.removeLoan(positionKey, loanId);
        }

        uint256[] storage loanIds = p.userFixedLoanIds[positionKey];
        uint256 length = loanIds.length;
        require(loanIndex < length, "PositionNFT: bad loanIndex");
        require(loanIds[loanIndex] == loanId, "PositionNFT: loan/index mismatch");

        uint256 lastIndex = length - 1;
        if (loanIndex != lastIndex) {
            uint256 lastLoanId = loanIds[lastIndex];
            loanIds[loanIndex] = lastLoanId;
            p.loanIdToIndex[positionKey][lastLoanId] = loanIndex;
        }
        loanIds.pop();
        delete p.loanIdToIndex[positionKey][loanId];
    }
}
