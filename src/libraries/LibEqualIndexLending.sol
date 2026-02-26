// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @notice Storage and shared types for EqualIndex lending.
library LibEqualIndexLending {
    bytes32 internal constant STORAGE_POSITION = keccak256("equal.index.lending.storage");

    struct LendingConfig {
        uint16 ltvBps;
        uint16 originationFeeBps;
        uint40 minDuration;
        uint40 maxDuration;
    }

    struct IndexLoan {
        bytes32 positionKey;
        uint256 indexId;
        address borrowAsset;
        uint256 collateralUnits;
        uint256 principal;
        uint40 maturity;
    }

    struct LendingStorage {
        mapping(uint256 => IndexLoan) loans;
        uint256 nextLoanId;
        mapping(uint256 => mapping(address => uint256)) outstandingPrincipal;
        mapping(uint256 => uint256) lockedCollateralUnits;
        mapping(uint256 => LendingConfig) lendingConfigs;
    }

    event LoanCreated(
        uint256 indexed loanId,
        bytes32 indexed positionKey,
        uint256 indexed indexId,
        address borrowAsset,
        uint256 collateralUnits,
        uint256 principal,
        uint40 maturity,
        uint256 fee
    );
    event LoanRepaid(uint256 indexed loanId, uint256 indexed indexId, address borrowAsset, uint256 principal);
    event LoanExtended(uint256 indexed loanId, uint40 newMaturity, uint256 fee);
    event LoanLiquidated(
        uint256 indexed loanId,
        uint256 indexed indexId,
        address borrowAsset,
        uint256 collateralUnits,
        uint256 writtenOffPrincipal
    );
    event LendingConfigured(
        uint256 indexed indexId, uint16 ltvBps, uint16 originationFeeBps, uint40 minDuration, uint40 maxDuration
    );

    error LendingNotConfigured(uint256 indexId);
    error LoanNotFound(uint256 loanId);
    error LoanNotExpired(uint256 loanId, uint40 maturity);
    error LoanExpired(uint256 loanId, uint40 maturity);
    error LtvExceeded(uint256 amount, uint256 maxBorrowable);
    error RedeemabilityViolation(address asset, uint256 required, uint256 available);
    error InvalidDuration(uint40 duration, uint40 min, uint40 max);
    error InvalidAsset(address asset);
    error MaxDurationExceeded(uint40 newMaturity, uint40 maxAllowed);
    error PositionMismatch(bytes32 loanPositionKey, bytes32 callerPositionKey);

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
