// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {Types} from "../libraries/Types.sol";

/// @notice Preview functions for loan costs and repayments
/// @dev Helps users understand costs before committing to transactions
contract LoanPreviewFacet {
    /// @notice Preview fixed-term loan costs
    /// @param pid Pool ID
    /// @param principal Loan amount
    /// @param termId Term configuration ID
    /// @return totalInterest Interest over full term at APY
    /// @return minFee Minimum fee due at repayment (deprecated, always 0)
    /// @return totalCost Total cost (interest only, excluding principal)
    /// @return netReceived Amount borrower actually receives (always equals principal)
    function previewFixedLoanCosts(uint256 pid, uint256 principal, uint256 termId)
        external
        view
        returns (
            uint256 totalInterest,
            uint256 minFee,
            uint256 totalCost,
            uint256 netReceived
        )
    {
        Types.PoolData storage p = _pool(pid);
        require(termId < p.poolConfig.fixedTermConfigs.length, "Invalid term ID");

        Types.FixedTermConfig storage cfg = p.poolConfig.fixedTermConfigs[termId];
        require(cfg.durationSecs > 0, "Term not configured");

        // Net received by borrower (no initiation fee)
        netReceived = principal; // Borrower receives full principal

        // Interest over full term
        totalInterest = (principal * cfg.apyBps * cfg.durationSecs) / (365 days * 10_000);

        // Minimum fee deprecated
        minFee = 0;

        // Total cost
        totalCost = totalInterest;
    }

    /// @notice Preview rolling credit loan costs
    /// @param pid Pool ID
    /// @param amount Loan amount
    /// @param useDeposits Whether using deposits as collateral (must be true)
    /// @return estimatedMonthlyInterest Estimated interest for 30 days
    /// @return estimatedAnnualInterest Estimated interest for 1 year
    function previewRollingLoanCosts(uint256 pid, uint256 amount, bool useDeposits)
        external
        view
        returns (uint256 estimatedMonthlyInterest, uint256 estimatedAnnualInterest)
    {
        Types.PoolData storage p = _pool(pid);
        require(useDeposits, "LoanPreview: external collateral not supported");

        uint16 apyBps = p.poolConfig.rollingApyBps;
        estimatedMonthlyInterest = (amount * apyBps * 30 days) / (10_000 * 365 days);
        estimatedAnnualInterest = (amount * apyBps) / 10_000;
    }

    /// @notice Calculate exact repayment amount needed to close a fixed loan
    /// @param pid Pool ID
    /// @param loanId Loan ID
    /// @return totalDue Exact amount needed to fully close the loan
    /// @return principalRemaining Remaining principal
    /// @return feesAccrued Accrued interest + min fee (always 0 under upfront-interest)
    /// @return breakdown Detailed breakdown of fees
    function calculateFixedLoanPayoff(uint256 pid, uint256 loanId)
        external
        view
        returns (
            uint256 totalDue,
            uint256 principalRemaining,
            uint256 feesAccrued,
            PayoffBreakdown memory breakdown
        )
    {
        Types.PoolData storage p = _pool(pid);
        Types.FixedTermLoan storage loan = p.fixedTermLoans[loanId];

        require(loan.borrower != bytes32(0), "Loan does not exist");
        require(!loan.closed, "Loan already closed");

        principalRemaining = loan.principalRemaining;

        // Upfront-interest: no post-creation accrual
        breakdown.accruedInterest = 0;
        breakdown.minFee = 0;
        feesAccrued = 0;
        breakdown.isExpired = block.timestamp > loan.expiry;

        // Total due
        totalDue = principalRemaining;

        breakdown.principal = principalRemaining;
        breakdown.totalFees = feesAccrued;
    }

    /// @notice Calculate exact repayment amount needed to close a rolling loan
    /// @param pid Pool ID
    /// @param borrower Borrower position key
    /// @return totalDue Exact amount needed to fully close the loan
    /// @return principalRemaining Remaining principal
    /// @return accruedInterest Interest accrued since last payment
    function calculateRollingLoanPayoff(uint256 pid, bytes32 borrower)
        external
        view
        returns (uint256 totalDue, uint256 principalRemaining, uint256 accruedInterest)
    {
        Types.PoolData storage p = _pool(pid);
        Types.RollingCreditLoan storage loan = p.rollingLoans[borrower];

        principalRemaining = loan.principalRemaining;
        
        uint256 elapsed = block.timestamp - loan.lastPaymentTimestamp;
        accruedInterest = (loan.principalRemaining * loan.apyBps * elapsed) / (10_000 * 365 days);
        
        totalDue = principalRemaining + accruedInterest;
    }

    /// @notice Preview what happens with a specific repayment amount
    /// @param pid Pool ID
    /// @param loanId Loan ID
    /// @param repayAmount Amount to repay
    /// @return willClose Whether loan will be fully closed
    /// @return principalReduction Amount of principal paid down
    /// @return feesPaid Amount going to fees
    /// @return newPrincipal Principal remaining after repayment
    /// @return additionalNeeded Additional amount needed to close (0 if will close)
    function previewFixedRepaymentImpact(uint256 pid, uint256 loanId, uint256 repayAmount)
        external
        view
        returns (
            bool willClose,
            uint256 principalReduction,
            uint256 feesPaid,
            uint256 newPrincipal,
            uint256 additionalNeeded
        )
    {
        Types.PoolData storage p = _pool(pid);
        Types.FixedTermLoan storage loan = p.fixedTermLoans[loanId];

        require(loan.borrower != bytes32(0), "Loan does not exist");
        require(!loan.closed, "Loan already closed");

        // Upfront-interest: no additional fees due
        uint256 feeDue = 0;

        // Calculate split
        if (repayAmount <= feeDue) {
            feesPaid = repayAmount;
            principalReduction = 0;
        } else {
            feesPaid = feeDue;
            principalReduction = repayAmount - feeDue;
            if (principalReduction > loan.principalRemaining) {
                principalReduction = loan.principalRemaining;
            }
        }

        newPrincipal = loan.principalRemaining - principalReduction;
        willClose = newPrincipal == 0;

        if (!willClose) {
            additionalNeeded = newPrincipal + feeDue - repayAmount;
        }
    }

    struct PayoffBreakdown {
        uint256 principal;
        uint256 accruedInterest;
        uint256 minFee;
        uint256 totalFees;
        bool isExpired;
    }

    function _pool(uint256 pid) internal view returns (Types.PoolData storage) {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        require(p.initialized, "View: uninit pool");
        return p;
    }

    function selectors() external pure returns (bytes4[] memory selectorsArr) {
        selectorsArr = new bytes4[](6);
        selectorsArr[0] = LoanPreviewFacet.previewFixedLoanCosts.selector;
        selectorsArr[1] = LoanPreviewFacet.previewRollingLoanCosts.selector;
        selectorsArr[2] = LoanPreviewFacet.calculateFixedLoanPayoff.selector;
        selectorsArr[3] = LoanPreviewFacet.calculateRollingLoanPayoff.selector;
        selectorsArr[4] = LoanPreviewFacet.previewFixedRepaymentImpact.selector;
        selectorsArr[5] = bytes4(keccak256("PayoffBreakdown(uint256,uint256,uint256,uint256,bool)"));
    }
}
