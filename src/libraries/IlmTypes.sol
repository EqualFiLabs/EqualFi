// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @notice Core pooled ILM types, constants, and custom errors.
library IlmTypes {
    uint256 internal constant RAY = 1e27;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant HF_PRECISION = 1e18;
    uint256 internal constant CLOSE_FACTOR_HF_THRESHOLD = 95e16; // 0.95e18
    uint16 internal constant DEFAULT_CLOSE_FACTOR_BPS = 5_000;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    struct IlmMarket {
        uint256 loanPoolId;
        uint256 collateralPoolId;

        // Risk params
        uint16 ltvBps;
        uint16 liquidationThresholdBps;
        uint16 liquidationBonusBps;
        uint16 liquidationProtocolFeeBps;

        // Rate strategy params
        uint16 reserveFactorBps;
        uint16 optimalUtilizationBps;
        uint32 baseVariableRateRayPerYear;
        uint32 variableSlope1RayPerYear;
        uint32 variableSlope2RayPerYear;

        // Caps & flags
        uint256 supplyCap;
        uint256 borrowCap;
        bool active;
        bool paused;
        bool frozen;

        // Index state (ray-scaled, 1e27)
        uint128 liquidityIndexRay;
        uint128 variableBorrowIndexRay;
        uint128 currentLiquidityRateRay;
        uint128 currentVariableBorrowRateRay;
        uint64 lastUpdate;

        // Aggregate scaled balances
        uint256 scaledSupplyTotal;
        uint256 scaledVariableDebtTotal;

        // ILM ledger totals
        uint256 availableLiquidity;

        // Bad debt tracking
        uint256 badDebt;
    }

    struct IlmPosition {
        uint256 scaledSupply;
        uint256 scaledDebt;
        bool useAsCollateral;
    }

    struct IlmCreateParams {
        uint256 loanPoolId;
        uint256 collateralPoolId;
        uint256 moduleId;
        uint16 ltvBps;
        uint16 liquidationThresholdBps;
        uint16 liquidationBonusBps;
        uint16 liquidationProtocolFeeBps;
        uint16 reserveFactorBps;
        uint16 optimalUtilizationBps;
        uint32 baseVariableRateRayPerYear;
        uint32 variableSlope1RayPerYear;
        uint32 variableSlope2RayPerYear;
        uint256 supplyCap;
        uint256 borrowCap;
    }
}

// Market errors
error IlmMarketNotFound(uint256 marketId);
error IlmReserveInactive(uint256 marketId);
error IlmReservePaused(uint256 marketId);
error IlmReserveFrozen(uint256 marketId);

// Cap errors
error IlmSupplyCapExceeded(uint256 cap, uint256 attemptedTotal);
error IlmBorrowCapExceeded(uint256 cap, uint256 attemptedTotal);

// Liquidity errors
error IlmInsufficientLiquidity(uint256 requested, uint256 available);

// Position safety errors
error IlmUnsafePosition(uint256 healthFactor, uint256 minRequired);
error IlmNotLiquidatable(uint256 healthFactor);

// External gate errors
error IlmSentinelBlocked();

// Governance errors
error IlmInvalidRiskParams();
error IlmNotGovernance();

// Authorization errors
error IlmUnauthorized();
