// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

// Market errors
error IlmIsolatedMarketNotCreated(bytes32 marketId);
error IlmIsolatedMarketAlreadyCreated(bytes32 marketId);

// Input validation errors
error IlmIsolatedInvalidInput();
error IlmIsolatedZeroAddress();

// Access control errors
error IlmIsolatedUnauthorized();

// Liquidity errors
error IlmIsolatedInsufficientLiquidity(uint256 borrowAssets, uint256 supplyAssets);

// Position safety errors
error IlmIsolatedInsufficientCollateral();
error IlmIsolatedHealthyPosition();

// Governance errors
error IlmIsolatedIrmNotEnabled(address irm);
error IlmIsolatedLltvNotEnabled(uint256 lltv);
error IlmIsolatedFeeTooHigh(uint256 fee, uint256 maxFee);
error IlmIsolatedManagedLoanPoolRequired(uint256 loanPoolId);
error IlmIsolatedManagedMarketCreatorUnauthorized(uint256 loanPoolId, address caller, address manager);
error IlmIsolatedInvalidFeeBps(uint256 bps);

// Oracle errors
error IlmIsolatedOracleStale(uint256 updatedAt, uint256 maxStaleness);
