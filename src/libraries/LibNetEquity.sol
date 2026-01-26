// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @notice Pure helpers for net equity and fee base calculations.
import {FeeBaseOverflow, InvalidAssetComparison, NegativeFeeBase} from "./Errors.sol";

library LibNetEquity {
    /// @notice Net equity for same-asset debt scenarios.
    function calculateNetEquity(uint256 principal, uint256 sameAssetDebt) internal pure returns (uint256) {
        if (sameAssetDebt >= principal) {
            return 0;
        }
        return principal - sameAssetDebt;
    }

    /// @notice Fee base for same-asset domains (netted by debt).
    function calculateFeeBaseSameAsset(uint256 principal, uint256 sameAssetDebt) internal pure returns (uint256) {
        return calculateNetEquity(principal, sameAssetDebt);
    }

    /// @notice Validate same-asset fee base and revert if debt exceeds principal.
    function validateFeeBaseSameAsset(uint256 principal, uint256 sameAssetDebt) internal pure returns (uint256) {
        if (sameAssetDebt > principal) {
            revert NegativeFeeBase();
        }
        return principal - sameAssetDebt;
    }

    /// @notice Fee base for cross-asset domains (locked collateral + unlocked principal).
    function calculateFeeBaseCrossAsset(uint256 lockedCollateral, uint256 unlockedPrincipal)
        internal
        pure
        returns (uint256)
    {
        if (lockedCollateral > type(uint256).max - unlockedPrincipal) {
            revert FeeBaseOverflow();
        }
        return lockedCollateral + unlockedPrincipal;
    }

    /// @notice Determine if a P2P loan is same-asset or cross-asset.
    function isSameAssetP2P(address collateralAsset, address lentAsset) internal pure returns (bool) {
        if (collateralAsset == address(0) || lentAsset == address(0)) {
            revert InvalidAssetComparison();
        }
        return collateralAsset == lentAsset;
    }

    /// @notice Fee base for a P2P borrower based on asset relationship.
    function calculateP2PBorrowerFeeBase(
        uint256 lockedCollateral,
        uint256 unlockedPrincipal,
        uint256 sameAssetDebt,
        bool isSameAsset
    ) internal pure returns (uint256 feeBase) {
        if (isSameAsset) {
            uint256 principal = calculateFeeBaseCrossAsset(lockedCollateral, unlockedPrincipal);
            return calculateFeeBaseSameAsset(principal, sameAssetDebt);
        }

        return calculateFeeBaseCrossAsset(lockedCollateral, unlockedPrincipal);
    }
}
