// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {LibDirectStorage} from "./LibDirectStorage.sol";
import {DirectTypes} from "./DirectTypes.sol";
import {Types} from "./Types.sol";
import {LibNetEquity} from "./LibNetEquity.sol";
import {SameAssetDebtMismatch} from "./Errors.sol";
import {LibPositionHelpers} from "./LibPositionHelpers.sol";
import {LibEncumbrance} from "./LibEncumbrance.sol";

/// @title LibSolvencyChecks
/// @notice Shared utilities for deterministic solvency and debt calculations
library LibSolvencyChecks {
    /// @notice Check solvency for a position using only on-chain deterministic data
    /// @dev This function ensures NRF compliance by using only immutable pool config and on-chain state
    /// @param p The pool data storage reference
    /// @param positionKey The position key to check
    /// @param newPrincipal The principal amount after the proposed operation
    /// @param newDebt The total debt after the proposed operation
    /// @return isSolvent True if the position is solvent
    function checkSolvency(
        Types.PoolData storage p,
        bytes32 positionKey,
        uint256 newPrincipal,
        uint256 newDebt
    ) internal view returns (bool isSolvent) {
        // Parameter retained for consistent signature; unused in deterministic check
        positionKey;
        // If no debt, position is always solvent
        if (newDebt == 0) {
            return true;
        }

        // Calculate max borrowable using ONLY immutable pool config (no oracles).
        // LTV must be set to a non-zero value; zero disables borrowing.
        uint16 ltvBps = p.poolConfig.depositorLTVBps;
        if (ltvBps == 0) {
            return false;
        }
        uint256 maxBorrowable = (newPrincipal * ltvBps) / 10_000;

        // Position is solvent if debt does not exceed max borrowable
        return newDebt <= maxBorrowable;
    }

    /// @notice Calculate current loan debts (rolling + fixed-term) for a position
    function calculateLoanDebts(
        Types.PoolData storage p,
        bytes32 positionKey
    )
        internal
        view
        returns (uint256 rollingDebt, uint256 fixedDebt, uint256 totalLoanDebt)
    {
        // Rolling loan debt
        Types.RollingCreditLoan storage rolling = p.rollingLoans[positionKey];
        if (rolling.active) {
            rollingDebt = rolling.principalRemaining;
        }

        // Fixed-term loan debt (cached aggregate)
        fixedDebt = p.fixedTermPrincipalRemaining[positionKey];

        totalLoanDebt = rollingDebt + fixedDebt;
    }

    /// @notice Calculate current loan debts (rolling + fixed-term) for a positionId.
    function calculateLoanDebtsById(
        Types.PoolData storage p,
        uint256 positionId
    )
        internal
        view
        returns (uint256 rollingDebt, uint256 fixedDebt, uint256 totalLoanDebt)
    {
        bytes32 positionKey = LibPositionHelpers.positionKey(positionId);
        return calculateLoanDebts(p, positionKey);
    }

    /// @notice Calculate same-asset debt for fee base calculations.
    function calculateSameAssetDebt(
        Types.PoolData storage p,
        bytes32 positionKey,
        address poolAsset
    ) internal view returns (uint256 sameAssetDebt) {
        (uint256 rollingDebt, uint256 fixedDebt,) = calculateLoanDebts(p, positionKey);
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        sameAssetDebt = rollingDebt + fixedDebt + ds.directSameAssetDebt[positionKey][poolAsset];
    }

    /// @notice Calculate same-asset debt for fee base calculations by positionId.
    function calculateSameAssetDebtById(
        Types.PoolData storage p,
        uint256 positionId,
        address poolAsset
    ) internal view returns (uint256 sameAssetDebt) {
        bytes32 positionKey = LibPositionHelpers.positionKey(positionId);
        return calculateSameAssetDebt(p, positionKey, poolAsset);
    }

    /// @notice Calculate same-asset and cross-asset debt totals by positionId.
    function calculateDebtByAsset(
        Types.PoolData storage p,
        uint256 positionId,
        address poolAsset
    ) internal view returns (uint256 sameAssetDebt, uint256 crossAssetDebt, uint256 totalDebt) {
        bytes32 positionKey = LibPositionHelpers.positionKey(positionId);
        (uint256 rollingDebt, uint256 fixedDebt,) = calculateLoanDebts(p, positionKey);
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        sameAssetDebt = rollingDebt + fixedDebt + ds.directSameAssetDebt[positionKey][poolAsset];

        (uint256[] memory agreements,) = LibDirectStorage.borrowerAgreementsPage(ds, positionKey, 0, 0);
        for (uint256 i = 0; i < agreements.length; i++) {
            DirectTypes.DirectAgreement storage agreement = ds.agreements[agreements[i]];
            if (agreement.status != DirectTypes.DirectStatus.Active) {
                continue;
            }
            if (agreement.borrowAsset != poolAsset) {
                crossAssetDebt += agreement.principal;
            }
        }

        totalDebt = sameAssetDebt + crossAssetDebt;
    }

    /// @notice Calculate total debt for a position using only on-chain data
    /// @dev Returns the sum of all active loan principals (rolling + fixed-term + direct)
    function calculateTotalDebt(
        Types.PoolData storage p,
        bytes32 positionKey,
        uint256 pid
    ) internal view returns (uint256 totalDebt) {
        (,, uint256 loanDebt) = calculateLoanDebts(p, positionKey);
        DirectTypes.DirectStorage storage ds = LibDirectStorage.directStorage();
        uint256 directDebt = ds.directBorrowedPrincipal[positionKey][pid];
        // Direct locks reduce withdrawable collateral but are not debt; only include active borrowed principal.
        totalDebt = loanDebt + directDebt;
    }

    /// @notice Calculate withdrawable principal after direct locks and offer escrow.
    function calculateWithdrawablePrincipal(
        Types.PoolData storage p,
        bytes32 positionKey,
        uint256 pid
    ) internal view returns (uint256 withdrawable) {
        return calculateAvailablePrincipal(p, positionKey, pid);
    }

    /// @notice Calculate available principal after direct locks, offer escrow, and index encumbrance.
    function calculateAvailablePrincipal(
        Types.PoolData storage p,
        bytes32 positionKey,
        uint256 pid
    ) internal view returns (uint256 available) {
        uint256 principal = p.userPrincipal[positionKey];
        LibEncumbrance.Encumbrance memory enc = LibEncumbrance.get(positionKey, pid);
        uint256 totalEncumbered =
            enc.directLocked + enc.directLent + enc.directOfferEscrow + enc.indexEncumbered;
        if (totalEncumbered >= principal) {
            return 0;
        }
        available = principal - totalEncumbered;
    }

    /// @notice Fee base invariant for same-asset domains.
    function checkFeeBaseInvariant(uint256 principal, uint256 sameAssetDebt) internal pure returns (bool) {
        uint256 feeBase = LibNetEquity.calculateFeeBaseSameAsset(principal, sameAssetDebt);
        if (sameAssetDebt >= principal) {
            return feeBase == 0;
        }
        return feeBase <= principal - sameAssetDebt;
    }

    /// @notice Validate debt snapshot consistency.
    function validateSameAssetDebt(uint256 expected, uint256 actual) internal pure {
        if (expected != actual) {
            revert SameAssetDebtMismatch(expected, actual);
        }
    }
}
