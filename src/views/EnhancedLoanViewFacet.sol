// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {Types} from "../libraries/Types.sol";
import {LibEncumbrance} from "../libraries/LibEncumbrance.sol";
import {LibSolvencyChecks} from "../libraries/LibSolvencyChecks.sol";
import {LibNetEquity} from "../libraries/LibNetEquity.sol";

/// @notice Enhanced read-only views for loan aggregation and health metrics
/// @dev These functions reduce UI call count from 10+ to 1-2 calls
contract EnhancedLoanViewFacet {
    /// @notice Get aggregate loan statistics for a user in a single call
    /// @param pid Pool ID
    /// @param borrower Address of the borrower
    /// @return totalFixedBorrowed Sum of all active fixed loan principals remaining
    /// @return totalFixedLoans Count of active fixed loans
    /// @return rollingBorrowed Current rolling credit utilization
    /// @return totalBorrowed Combined fixed + rolling borrowed amount
    function getUserLoanSummary(uint256 pid, bytes32 borrower)
        external
        view
        returns (uint256 totalFixedBorrowed, uint256 totalFixedLoans, uint256 rollingBorrowed, uint256 totalBorrowed)
    {
        Types.PoolData storage p = _pool(pid);

        // Calculate fixed-term loans total
        uint256[] storage loanIds = p.userFixedLoanIds[borrower];
        for (uint256 i = 0; i < loanIds.length; i++) {
            Types.FixedTermLoan storage loan = p.fixedTermLoans[loanIds[i]];
            if (!loan.closed) {
                totalFixedBorrowed += loan.principalRemaining;
                totalFixedLoans++;
            }
        }

        // Get rolling credit utilization
        Types.RollingCreditLoan storage rollingLoan = p.rollingLoans[borrower];
        rollingBorrowed = rollingLoan.principalRemaining;

        // Calculate total
        totalBorrowed = totalFixedBorrowed + rollingBorrowed;
    }

    /// @notice Get detailed fixed loan data in a single call
    /// @param pid Pool ID
    /// @param borrower Address of borrower
    /// @return loans Array of all active fixed loans with full details
    /// @return totalPrincipal Sum of all loan original principals
    /// @return totalRemaining Sum of all remaining principals
    function getUserFixedLoansDetailed(uint256 pid, bytes32 borrower)
        external
        view
        returns (Types.FixedTermLoan[] memory loans, uint256 totalPrincipal, uint256 totalRemaining)
    {
        Types.PoolData storage p = _pool(pid);
        uint256[] storage loanIds = p.userFixedLoanIds[borrower];

        // Count active loans first
        uint256 activeCount = 0;
        for (uint256 i = 0; i < loanIds.length; i++) {
            if (!p.fixedTermLoans[loanIds[i]].closed) {
                activeCount++;
            }
        }

        // Allocate array for active loans only
        loans = new Types.FixedTermLoan[](activeCount);
        uint256 index = 0;

        // Populate array and calculate totals
        for (uint256 i = 0; i < loanIds.length; i++) {
            Types.FixedTermLoan storage loan = p.fixedTermLoans[loanIds[i]];
            if (!loan.closed) {
                loans[index] = loan;
                totalPrincipal += loan.principal;
                totalRemaining += loan.principalRemaining;
                index++;
            }
        }
    }

    /// @notice Get paginated fixed loans with full details (not just IDs)
    /// @param pid Pool ID
    /// @param borrower Address of the borrower
    /// @param offset Starting index (0-based)
    /// @param limit Maximum number of loans to return
    /// @return loans Array of loan details for the requested page
    /// @return total Total number of loans (active + closed) for this borrower
    function getUserFixedLoansPaginated(uint256 pid, bytes32 borrower, uint256 offset, uint256 limit)
        external
        view
        returns (Types.FixedTermLoan[] memory loans, uint256 total)
    {
        Types.PoolData storage p = _pool(pid);
        uint256[] storage loanIds = p.userFixedLoanIds[borrower];
        total = loanIds.length;

        if (offset >= total) {
            return (new Types.FixedTermLoan[](0), total);
        }

        uint256 remaining = total - offset;
        if (limit > remaining) {
            limit = remaining;
        }

        loans = new Types.FixedTermLoan[](limit);
        for (uint256 i = 0; i < limit; i++) {
            loans[i] = p.fixedTermLoans[loanIds[offset + i]];
        }
    }

    /// @notice Get comprehensive health metrics for a borrower
    /// @param pid Pool ID
    /// @param borrower Address of the borrower
    /// @return currentLTV Current loan-to-value ratio in bps (0-10000+)
    /// @return maxLTV Maximum allowed LTV in bps
    /// @return availableToBorrow Remaining borrowing capacity in underlying tokens
    /// @return isHealthy True if within LTV limits
    /// @return collateralValue Total collateral value (user principal)
    /// @return totalDebt Total outstanding debt (fixed + rolling)
    function getUserHealthMetrics(uint256 pid, bytes32 borrower)
        external
        view
        returns (
            uint256 currentLTV,
            uint256 maxLTV,
            uint256 availableToBorrow,
            bool isHealthy,
            uint256 collateralValue,
            uint256 totalDebt
        )
    {
        Types.PoolData storage p = _pool(pid);

        // Get collateral value (net equity for same-asset domains)
        uint256 grossCollateral = p.userPrincipal[borrower];
        LibEncumbrance.Encumbrance memory enc = LibEncumbrance.get(borrower, pid);
        uint256 encumbered = enc.directLocked + enc.directLent + enc.directOfferEscrow + enc.indexEncumbered;
        if (grossCollateral > encumbered) {
            grossCollateral -= encumbered;
        } else {
            grossCollateral = 0;
        }

        // Calculate total debt
        uint256[] storage loanIds = p.userFixedLoanIds[borrower];
        for (uint256 i = 0; i < loanIds.length; i++) {
            Types.FixedTermLoan storage loan = p.fixedTermLoans[loanIds[i]];
            if (!loan.closed) {
                totalDebt += loan.principalRemaining;
            }
        }
        totalDebt += p.rollingLoans[borrower].principalRemaining;

        uint256 sameAssetDebt = LibSolvencyChecks.calculateSameAssetDebt(p, borrower, p.underlying);
        collateralValue = LibNetEquity.calculateNetEquity(grossCollateral, sameAssetDebt);

        // Calculate LTV
        maxLTV = p.poolConfig.depositorLTVBps;
        if (collateralValue > 0) {
            currentLTV = (totalDebt * 10_000) / collateralValue;
            isHealthy = currentLTV <= maxLTV;

            // Calculate available to borrow using term 0 config (if present), accounting for upfront interest
            if (p.poolConfig.fixedTermConfigs.length > 0) {
                Types.FixedTermConfig storage cfg = p.poolConfig.fixedTermConfigs[0];
                availableToBorrow = _maxBorrowAfterUpfrontInterest(
                    collateralValue, totalDebt, maxLTV, cfg.apyBps, cfg.durationSecs
                );
            }
        } else {
            currentLTV = totalDebt > 0 ? type(uint256).max : 0;
            isHealthy = totalDebt == 0;
            availableToBorrow = 0;
        }
    }

    /// @notice Preview fixed-term borrow capacity accounting for existing loans
    /// @param pid Pool ID
    /// @param borrower Address of the borrower
    /// @return maxBorrow Maximum amount that can be borrowed for a new fixed loan
    /// @return existingBorrowed Total currently borrowed across all fixed loans
    function previewBorrowFixed(uint256 pid, bytes32 borrower)
        external
        view
        returns (uint256 maxBorrow, uint256 existingBorrowed)
    {
        Types.PoolData storage p = _pool(pid);

        // Calculate existing borrowed amount
        uint256[] storage loanIds = p.userFixedLoanIds[borrower];
        for (uint256 i = 0; i < loanIds.length; i++) {
            Types.FixedTermLoan storage loan = p.fixedTermLoans[loanIds[i]];
            if (!loan.closed) {
                existingBorrowed += loan.principalRemaining;
            }
        }

        // Calculate max borrow based on collateral, LTV, and upfront interest (using term 0)
        uint256 grossCollateral = p.userPrincipal[borrower];
        LibEncumbrance.Encumbrance memory enc = LibEncumbrance.get(borrower, pid);
        uint256 encumbered = enc.directLocked + enc.directLent + enc.directOfferEscrow + enc.indexEncumbered;
        if (grossCollateral > encumbered) {
            grossCollateral -= encumbered;
        } else {
            grossCollateral = 0;
        }
        if (p.poolConfig.fixedTermConfigs.length == 0) {
            return (0, existingBorrowed);
        }
        Types.FixedTermConfig storage cfg = p.poolConfig.fixedTermConfigs[0];
        uint256 sameAssetDebt = LibSolvencyChecks.calculateSameAssetDebt(p, borrower, p.underlying);
        uint256 collateralValue = LibNetEquity.calculateNetEquity(grossCollateral, sameAssetDebt);
        uint256 maxBorrowTotal = _maxBorrowAfterUpfrontInterest(
            collateralValue, existingBorrowed, p.poolConfig.depositorLTVBps, cfg.apyBps, cfg.durationSecs
        );

        // Available to borrow is total allowed minus already borrowed
        maxBorrow = maxBorrowTotal;
    }

    /// @notice Check if a user can open a new fixed-term loan
    /// @param pid Pool ID
    /// @param borrower Address of the borrower
    /// @param principal Desired loan amount
    /// @param termId Term configuration ID
    /// @return canBorrow True if loan would be within LTV limits
    /// @return maxAllowed Maximum amount that can be borrowed
    /// @return reason Human-readable reason if cannot borrow (empty if can borrow)
    function canOpenFixedLoan(uint256 pid, bytes32 borrower, uint256 principal, uint256 termId)
        external
        view
        returns (bool canBorrow, uint256 maxAllowed, string memory reason)
    {
        Types.PoolData storage p = _pool(pid);

        // Check if term exists
        if (termId >= p.poolConfig.fixedTermConfigs.length) {
            return (false, 0, "Invalid term ID");
        }

        Types.FixedTermConfig storage cfg = p.poolConfig.fixedTermConfigs[termId];
        if (cfg.durationSecs == 0) {
            return (false, 0, "Term not configured");
        }

        // Check collateral
        uint256 grossCollateral = p.userPrincipal[borrower];
        LibEncumbrance.Encumbrance memory enc = LibEncumbrance.get(borrower, pid);
        uint256 encumbered = enc.directLocked + enc.directLent + enc.directOfferEscrow + enc.indexEncumbered;
        if (grossCollateral > encumbered) {
            grossCollateral -= encumbered;
        } else {
            grossCollateral = 0;
        }
        uint256 sameAssetDebt = LibSolvencyChecks.calculateSameAssetDebt(p, borrower, p.underlying);
        uint256 collateralValue = LibNetEquity.calculateNetEquity(grossCollateral, sameAssetDebt);
        if (collateralValue == 0) {
            return (false, 0, "No collateral deposited");
        }

        // Calculate existing borrowed
        uint256 existingBorrowed = 0;
        uint256[] storage loanIds = p.userFixedLoanIds[borrower];
        for (uint256 i = 0; i < loanIds.length; i++) {
            Types.FixedTermLoan storage loan = p.fixedTermLoans[loanIds[i]];
            if (!loan.closed) {
                existingBorrowed += loan.principalRemaining;
            }
        }

        // Calculate max allowed accounting for upfront interest
        maxAllowed = _maxBorrowAfterUpfrontInterest(
            collateralValue, existingBorrowed, p.poolConfig.depositorLTVBps, cfg.apyBps, cfg.durationSecs
        );

        // Check if requested amount is within limit
        if (principal == 0) {
            return (false, maxAllowed, "Principal cannot be zero");
        }

        if (principal > maxAllowed) {
            return (false, maxAllowed, "Exceeds LTV limit");
        }

        return (true, maxAllowed, "");
    }

    /// @notice Calculate current interest and fees accrued on a fixed loan
    /// @param pid Pool ID
    /// @param loanId Loan ID
    /// @return accruedInterest Interest accrued to current timestamp (always 0 for upfront-interest model)
    /// @return minFeeDue Minimum fee due (deprecated, always 0 - no initiation fees)
    /// @return totalDue Total amount due to fully close the loan (principal only)
    /// @return isExpired True if loan has passed expiry
    function getFixedLoanAccrued(uint256 pid, uint256 loanId)
        external
        view
        returns (uint256 accruedInterest, uint256 minFeeDue, uint256 totalDue, bool isExpired)
    {
        Types.PoolData storage p = _pool(pid);
        Types.FixedTermLoan storage loan = p.fixedTermLoans[loanId];

        require(loan.borrower != bytes32(0), "Loan does not exist");

        if (loan.closed) {
            return (0, 0, 0, false);
        }

        // Upfront-interest: no accrual post-creation
        accruedInterest = 0;
        minFeeDue = 0;
        isExpired = block.timestamp > loan.expiry;

        // Total due = remaining principal
        totalDue = loan.principalRemaining;
    }

    /// @notice Preview repayment breakdown for a fixed loan
    /// @param pid Pool ID
    /// @param loanId Loan ID
    /// @param repayAmount Amount user wants to repay
    /// @return principalPaid Amount that will go to principal
    /// @return feePaid Amount that will go to fees
    /// @return remainingPrincipal Principal left after repayment
    /// @return loanClosed Whether loan will be fully closed
    function previewRepayFixed(uint256 pid, uint256 loanId, uint256 repayAmount)
        external
        view
        returns (uint256 principalPaid, uint256 feePaid, uint256 remainingPrincipal, bool loanClosed)
    {
        Types.PoolData storage p = _pool(pid);
        Types.FixedTermLoan storage loan = p.fixedTermLoans[loanId];

        require(loan.borrower != bytes32(0), "Loan does not exist");
        require(!loan.closed, "Loan already closed");

        // Upfront-interest model: no fees due at repayment (no initiation fees)
        uint256 feeDue = 0;

        // Calculate split
        if (repayAmount <= feeDue) {
            feePaid = repayAmount;
            principalPaid = 0;
        } else {
            feePaid = feeDue;
            principalPaid = repayAmount - feeDue;
            if (principalPaid > loan.principalRemaining) {
                principalPaid = loan.principalRemaining;
            }
        }

        remainingPrincipal = loan.principalRemaining - principalPaid;
        loanClosed = remainingPrincipal == 0;
    }

    function _pool(uint256 pid) internal view returns (Types.PoolData storage) {
        Types.PoolData storage p = LibAppStorage.s().pools[pid];
        require(p.initialized, "View: uninit pool");
        return p;
    }

    function _maxBorrowAfterUpfrontInterest(
        uint256 collateralValue,
        uint256 existingBorrowed,
        uint256 ltvBps,
        uint256 apyBps,
        uint40 durationSecs
    ) internal pure returns (uint256) {
        if (ltvBps == 0 || collateralValue == 0) {
            return 0;
        }

        // Calculate interest rate factor: r = (apyBps * durationSecs) / (365 days * 10_000)
        uint256 rNum = uint256(apyBps) * durationSecs;
        uint256 rDen = 365 days * 10_000;

        // Maximum total debt allowed: maxDebt = collateralValue * ltvBps / 10_000
        uint256 maxTotalDebt = (collateralValue * ltvBps) / 10_000;
        
        // If existing debt already exceeds limit, no additional borrowing allowed
        if (existingBorrowed >= maxTotalDebt) {
            return 0;
        }

        // Available debt capacity before considering upfront interest
        uint256 availableDebtCapacity = maxTotalDebt - existingBorrowed;

        // For upfront interest model: newLoan + (newLoan * rNum / rDen) <= availableDebtCapacity
        // Solving for newLoan: newLoan * (1 + rNum/rDen) <= availableDebtCapacity
        // newLoan <= availableDebtCapacity / (1 + rNum/rDen)
        // newLoan <= (availableDebtCapacity * rDen) / (rDen + rNum)
        
        uint256 denominator = rDen + rNum;
        if (denominator == 0) {
            return 0;
        }
        
        return (availableDebtCapacity * rDen) / denominator;
    }

    function selectors() external pure returns (bytes4[] memory selectorsArr) {
        selectorsArr = new bytes4[](8);
        selectorsArr[0] = EnhancedLoanViewFacet.getUserLoanSummary.selector;
        selectorsArr[1] = EnhancedLoanViewFacet.getUserFixedLoansDetailed.selector;
        selectorsArr[2] = EnhancedLoanViewFacet.getUserFixedLoansPaginated.selector;
        selectorsArr[3] = EnhancedLoanViewFacet.getUserHealthMetrics.selector;
        selectorsArr[4] = EnhancedLoanViewFacet.previewBorrowFixed.selector;
        selectorsArr[5] = EnhancedLoanViewFacet.canOpenFixedLoan.selector;
        selectorsArr[6] = EnhancedLoanViewFacet.getFixedLoanAccrued.selector;
        selectorsArr[7] = EnhancedLoanViewFacet.previewRepayFixed.selector;
    }
}
