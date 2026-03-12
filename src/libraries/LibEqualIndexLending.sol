// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @notice Storage and shared types for EqualIndex lending.
library LibEqualIndexLending {
    bytes32 internal constant STORAGE_POSITION = keccak256("equal.index.lending.storage");

    struct LendingConfig {
        uint16 ltvBps;
        uint16 originationFeeBps; // legacy, not used for basket borrow/repay math
        uint40 minDuration;
        uint40 maxDuration;
    }

    struct BorrowFeeTier {
        uint256 minCollateralUnits;
        uint256 flatFeeNative;
    }

    struct IndexLoan {
        bytes32 positionKey;
        uint256 indexId;
        uint256 collateralUnits;
        uint16 ltvBps;
        uint40 maturity;
    }

    struct LendingStorage {
        mapping(uint256 => IndexLoan) loans;
        uint256 nextLoanId;
        mapping(uint256 => mapping(address => uint256)) outstandingPrincipal;
        mapping(uint256 => uint256) lockedCollateralUnits;
        mapping(uint256 => LendingConfig) lendingConfigs;
        mapping(uint256 => BorrowFeeTier[]) borrowFeeTiers;
    }

    event LoanCreated(
        uint256 indexed loanId,
        bytes32 indexed positionKey,
        uint256 indexed indexId,
        uint256 collateralUnits,
        uint16 ltvBps,
        uint40 maturity
    );
    event LoanAssetDelta(
        uint256 indexed loanId,
        address indexed borrowAsset,
        uint256 principal,
        uint256 fee,
        bool outgoing
    );
    event LoanRepaid(uint256 indexed loanId, uint256 indexed indexId);
    event LoanExtended(uint256 indexed loanId, uint40 newMaturity, uint256 totalFee);
    event LoanRecovered(
        uint256 indexed loanId,
        uint256 indexed indexId,
        uint256 collateralUnits,
        uint256 writtenOffPrincipalTotal
    );
    event LendingConfigured(
        uint256 indexed indexId, uint16 ltvBps, uint16 originationFeeBps, uint40 minDuration, uint40 maxDuration
    );
    event BorrowFeeTiersConfigured(
        uint256 indexed indexId,
        uint256[] minCollateralUnits,
        uint256[] flatFeeNative
    );
    event BorrowFlatFeePaid(
        uint256 indexed loanId,
        uint256 indexed indexId,
        uint256 collateralUnits,
        uint256 feeNative
    );
    event LoanExtendFlatFeePaid(
        uint256 indexed loanId,
        uint256 indexed indexId,
        uint256 collateralUnits,
        uint40 addedDuration,
        uint256 feeNative
    );

    error LendingNotConfigured(uint256 indexId);
    error LoanNotFound(uint256 loanId);
    error LoanNotExpired(uint256 loanId, uint40 maturity);
    error LoanExpired(uint256 loanId, uint40 maturity);
    error RedeemabilityViolation(address asset, uint256 required, uint256 available);
    error InvalidDuration(uint40 duration, uint40 min, uint40 max);
    error InvalidAsset(address asset);
    error MaxDurationExceeded(uint40 newMaturity, uint40 maxAllowed);
    error PositionMismatch(bytes32 loanPositionKey, bytes32 callerPositionKey);
    error FlatFeePaymentMismatch(uint256 required, uint256 provided);
    error FlatFeeTreasuryNotSet();

    function s() internal pure returns (LendingStorage storage ls) {
        bytes32 position = STORAGE_POSITION;
        assembly {
            ls.slot := position
        }
    }

    /// @notice Computes economic balance used by pricing code.
    /// @dev `vaultBalance` is passed in by the caller from EqualIndex storage.
    function getEconomicBalance(uint256 indexId, address asset, uint256 vaultBalance) internal view returns (uint256) {
        return vaultBalance + s().outstandingPrincipal[indexId][asset];
    }
}
