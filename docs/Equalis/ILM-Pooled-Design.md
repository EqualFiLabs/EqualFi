# Pooled Isolated Lending Markets (Pooled ILM) - Design Document

**Version:** 1.0

---

## Table of Contents

1. [Overview](#overview)
2. [How It Works](#how-it-works)
3. [Architecture](#architecture)
4. [Markets](#markets)
5. [Position Operations](#position-operations)
6. [Interest Rate Model](#interest-rate-model)
7. [Liquidation System](#liquidation-system)
8. [Fee System](#fee-system)
9. [Data Models](#data-models)
10. [View Functions](#view-functions)
11. [Integration Guide](#integration-guide)
12. [Worked Examples](#worked-examples)
13. [Error Reference](#error-reference)
14. [Events](#events)
15. [Security Considerations](#security-considerations)

---

## Overview

Pooled ILM is a cross-asset lending system where suppliers pool liquidity into shared markets and borrowers pledge collateral from a different asset to borrow against it. Unlike the Isolated ILM (which uses per-lender allocations and auction-based liquidation), Pooled ILM aggregates supply into a shared liquidity pool with continuous interest accrual via ray-scaled indexes, similar to Aave V3's variable-rate model.

All positions are bound to Position NFTs and collateral is tracked through the centralized module encumbrance system, ensuring that stress in one market cannot leak into unrelated pools.

### Key Characteristics

| Feature | Description |
|---------|-------------|
| **Cross-Asset Lending** | Borrow one asset against collateral in another |
| **Pooled Liquidity** | Suppliers share a single liquidity pool per market |
| **Variable Interest Rates** | Kinked-rate model driven by utilization |
| **Oracle-Dependent** | Collateral valuation via pluggable oracle adapter |
| **Health Factor Liquidation** | Positions liquidated when HF < 1.0 |
| **Scaled Balances** | Supply and debt tracked as ray-scaled shares (1e27) |
| **Module Encumbrance** | Collateral locked via centralized `LibModuleEncumbrance` |
| **Sentinel Gating** | Optional circuit breaker for borrows and liquidations |
| **Bad Debt Socialization** | Residual debt written off when collateral is exhausted |
| **Position NFT Ownership** | All state tied to transferable ERC-721 tokens |

### System Participants

| Role | Description |
|------|-------------|
| **Supplier** | Deposits loan-asset principal into the market's liquidity pool; earns interest |
| **Borrower** | Pledges collateral-asset principal and borrows loan-asset from the pool |
| **Liquidator** | Repays a borrower's debt and seizes discounted collateral when HF < 1.0 |
| **Governance** | Creates markets, sets risk parameters, rate strategies, caps, and adapters |
| **Sentinel** | Optional external contract that can pause borrows or liquidations |

### Pooled ILM vs Isolated ILM

| Dimension | Pooled ILM | Isolated ILM |
|-----------|-----------|--------------|
| Liquidity model | Shared pool with index-based yield | Per-lender allocations |
| Interest | Continuous variable rate (kinked model) | Fixed or rolling APY per loan |
| Liquidation | Instant bonus-based seizure | Dutch auction engine |
| Collateral tracking | Module encumbrance | Direct encumbrance (directLocked) |
| Bad debt | Socialized across pool | Contained per-lender |
| Complexity | Lower (no auction state) | Higher (auction lifecycle) |


---

## How It Works

### The Core Model

Pooled ILM creates two-sided markets where each market pairs a loan pool with a collateral pool:

1. **Supply** loan-asset principal into the market's shared liquidity pool
2. **Pledge** collateral-asset principal from a different pool as security
3. **Borrow** loan-asset from the pool up to the LTV limit
4. **Accrue** interest continuously via ray-scaled indexes
5. **Repay** debt to free collateral and reduce interest burden
6. **Withdraw** supplied principal plus earned interest

### Dual Collateral Sources

Borrowers can back their debt with two types of collateral simultaneously:

- **Internal supply collateral:** Loan-asset principal supplied directly into the market (earns interest and counts as collateral if `useAsCollateral` is true)
- **External module collateral:** Collateral-asset principal encumbered from a separate pool via `LibModuleEncumbrance`, valued through the oracle adapter

The health factor computation combines both sources:

```
adjustedCollateral = (supplyCollateralValue + externalCollateralValue) × liquidationThresholdBps / 10,000
healthFactor = adjustedCollateral × 1e18 / debtValue
```

### Scaled Balance Accounting

All supply and debt balances are stored as scaled shares rather than raw amounts. This allows interest to accrue globally via index growth without per-user updates:

```
actualSupply = scaledSupply × liquidityIndexRay / RAY
actualDebt   = scaledDebt × variableBorrowIndexRay / RAY
```

When a user supplies 1000 tokens and the liquidity index is 1.05e27, they receive `1000 × 1e27 / 1.05e27 ≈ 952.38` scaled shares. As the index grows, those shares represent more tokens.

---

## Architecture

### Contract Structure

```
src/ilm-pooled/
├── facets/
│   ├── ILMPooledFacet.sol              # Supply, withdraw, collateral, borrow, repay
│   ├── ILMPooledAdminFacet.sol         # Market creation and governance controls
│   ├── ILMPooledLiquidationFacet.sol   # Health-factor liquidation with bonus seizure
│   └── ILMPooledViewFacet.sol          # Read-only queries (HF, balances, market state)
│
├── interfaces/
│   ├── IILMPooledFacet.sol             # Core operations interface
│   ├── IILMPooledAdminFacet.sol        # Admin operations interface
│   ├── IILMPooledLiquidationFacet.sol  # Liquidation interface
│   ├── IILMPooledViewFacet.sol         # View functions interface
│   ├── IILMEvents.sol                  # Event definitions
│   ├── IIlmOracleAdapter.sol           # Oracle price feed interface
│   └── IIlmSentinelAdapter.sol         # Circuit breaker interface
│
└── libraries/
    ├── IlmTypes.sol                    # Data structures, constants, and errors
    ├── LibIlmStorage.sol               # Diamond storage accessor
    ├── LibIlmIndexing.sol              # Index accrual and scaled-balance math
    ├── LibIlmInterestRate.sol          # Kinked variable rate computation
    └── LibIlmLiquidation.sol           # Health factor and seizure math
```

### Integration with Core Protocol

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Equalis Diamond                              │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  ┌────────────────┐  ┌────────────────┐  ┌────────────────────┐     │
│  │  ILMPooled     │  │  ILMPooled     │  │  ILMPooled         │     │
│  │  Facet         │  │  Liquidation   │  │  Admin Facet       │     │
│  │  (core ops)    │  │  Facet         │  │  (governance)      │     │
│  └───────┬────────┘  └───────┬────────┘  └────────┬───────────┘     │
│          │                   │                    │                 │
│          └───────────────────┼────────────────────┘                 │
│                              │                                      │
│          ┌───────────────────┼───────────────────┐                  │
│          ▼                   ▼                   ▼                  │
│  ┌──────────────┐  ┌──────────────────┐  ┌──────────────────┐      │
│  │ LibIlmStorage│  │ LibIlmIndexing   │  │ LibIlmInterest   │      │
│  │ (diamond     │  │ (index accrual,  │  │ Rate (kinked      │      │
│  │  storage)    │  │  scaled math)    │  │  rate model)     │      │
│  └──────────────┘  └──────────────────┘  └──────────────────┘      │
│                                                                     │
│  ┌──────────────────────────────────────────────────────────┐       │
│  │              Shared Core Libraries                        │       │
│  │  LibAppStorage · LibFeeIndex · LibActiveCreditIndex       │       │
│  │  LibModuleEncumbrance · LibSolvencyChecks · LibFeeRouter  │       │
│  │  LibActionFees · LibModuleRegistry                        │       │
│  └──────────────────────────────────────────────────────────┘       │
│                                                                     │
├─────────────────────────────────────────────────────────────────────┤
│                     External Adapters                               │
│  ┌──────────────────┐              ┌──────────────────┐             │
│  │  Oracle Adapter   │              │  Sentinel Adapter │             │
│  │  (price feeds)    │              │  (circuit breaker) │             │
│  └──────────────────┘              └──────────────────┘             │
└─────────────────────────────────────────────────────────────────────┘
         │                    │                    │
         ▼                    ▼                    ▼
   ┌──────────┐        ┌──────────┐        ┌──────────┐
   │ Position │        │ Loan     │        │ Collateral│
   │   NFTs   │        │ Pools    │        │ Pools     │
   └──────────┘        └──────────┘        └──────────┘
```

---

## Markets

### Market Configuration

Each pooled market is defined by a pair of underlying pools and a set of risk/rate parameters:

```solidity
struct IlmCreateParams {
    uint256 loanPoolId;                    // Pool supplying the borrowed asset
    uint256 collateralPoolId;              // Pool holding the collateral asset
    uint256 moduleId;                      // Module registry ID for encumbrance tracking
    uint16 ltvBps;                         // Max loan-to-value (e.g., 8000 = 80%)
    uint16 liquidationThresholdBps;        // HF threshold (must exceed ltvBps)
    uint16 liquidationBonusBps;            // Bonus collateral for liquidators (e.g., 500 = 5%)
    uint16 liquidationProtocolFeeBps;      // Protocol's cut of liquidation bonus
    uint16 reserveFactorBps;              // Protocol's cut of interest income
    uint16 optimalUtilizationBps;          // Utilization kink point (e.g., 8000 = 80%)
    uint32 baseVariableRateRayPerYear;     // Base borrow rate (ray-scaled)
    uint32 variableSlope1RayPerYear;       // Rate slope below optimal utilization
    uint32 variableSlope2RayPerYear;       // Rate slope above optimal utilization (steep)
    uint256 supplyCap;                     // Max total supply (0 = unlimited)
    uint256 borrowCap;                     // Max total borrows (0 = unlimited)
}
```

### Market Lifecycle

**Creation (Governance Only):**
```solidity
uint256 marketId = adminFacet.createPooledMarket(params);
```

Markets are initialized with:
- `liquidityIndexRay = 1e27` (RAY)
- `variableBorrowIndexRay = 1e27` (RAY)
- `active = true`, `paused = false`, `frozen = false`
- `lastUpdate = block.timestamp`

**State Flags:**

| Flag | Effect |
|------|--------|
| `active = false` | All operations blocked |
| `paused = true` | Supply, borrow, withdraw, collateral mutations, and liquidation blocked |
| `frozen = true` | Supply and borrow blocked; withdraw and repay still allowed |

**Governance Controls:**
```solidity
adminFacet.setPooledMarketFlags(marketId, active, paused, frozen);
adminFacet.setPooledMarketCaps(marketId, supplyCap, borrowCap);
adminFacet.setPooledRiskParams(marketId, ltvBps, liqThreshold, liqBonus, liqProtocolFee);
adminFacet.setPooledRateStrategy(marketId, reserveFactor, optimalUtil, baseRate, slope1, slope2);
```

### Global Bounds

Governance sets system-wide bounds that constrain per-market parameters:

```solidity
adminFacet.setPooledGlobalBounds(minLtvBps, maxLtvBps, minReserveFactorBps, maxReserveFactorBps);
```

Market creation and parameter updates validate against these bounds.

---

## Position Operations

All operations require a Position NFT. The caller must be the NFT owner or an authorized operator.

### Supply (Lend into the Pool)

```solidity
pooledFacet.pooledSupply(positionId, marketId, amount);
```

**Flow:**
1. Accrue market indexes
2. Verify the position has sufficient unencumbered principal in the loan pool
3. Encumber the principal via `LibModuleEncumbrance` (with ACI tracking)
4. Mint scaled supply shares: `scaledMinted = amount × RAY / liquidityIndexRay`
5. Enforce supply cap
6. Set `useAsCollateral = true` (auto-enabled on first supply)
7. Increase `availableLiquidity`

**Requirements:**
- Market must be active, not paused, not frozen
- Module must not be paused
- Position must have `amount` of unencumbered principal in the loan pool

### Withdraw (Reclaim Supplied Principal + Interest)

```solidity
uint256 withdrawn = pooledFacet.pooledWithdraw(positionId, marketId, amount);
```

**Flow:**
1. Accrue market indexes
2. Compute scaled shares to burn: `scaledBurned = ceil(amount × RAY / liquidityIndexRay)`
3. Validate sufficient scaled supply and available liquidity
4. If position has debt and uses supply as collateral, verify health factor remains ≥ 1.0 post-withdrawal
5. Burn scaled shares, reduce `availableLiquidity`
6. Unencumber principal from module encumbrance (with ACI tracking)
7. If both `scaledSupply` and `scaledDebt` reach zero, clear `useAsCollateral`

### Add External Collateral

```solidity
pooledFacet.pooledAddCollateral(positionId, marketId, amount);
```

Encumbers `amount` of the position's principal in the collateral pool via `LibModuleEncumbrance`. This collateral is valued through the oracle adapter during health factor checks.

**Note:** No index accrual is needed since external collateral does not participate in the supply/borrow index system.

### Remove External Collateral

```solidity
pooledFacet.pooledRemoveCollateral(positionId, marketId, amount);
```

Unencumbers collateral. If the position has outstanding debt, the health factor is validated post-removal to ensure it remains ≥ 1.0.

### Borrow

```solidity
pooledFacet.pooledBorrow(positionId, marketId, amount);
```

**Flow:**
1. Accrue market indexes
2. Check sentinel allows borrowing
3. Verify sufficient `availableLiquidity`
4. Mint scaled debt shares: `scaledDebtMinted = ceil(amount × RAY / variableBorrowIndexRay)`
5. Enforce borrow cap
6. Validate health factor ≥ 1.0 post-borrow (using both supply and external collateral)
7. Reduce `availableLiquidity`
8. Credit borrowed amount to position's principal in the loan pool
9. Charge action fee via `LibActionFees`

### Repay

```solidity
uint256 repaid = pooledFacet.pooledRepay(positionId, marketId, amount);
```

**Flow:**
1. Accrue market indexes
2. Cap repayment at current debt: `requestedRepay = min(amount, currentDebt)`
3. Compute scaled debt to burn: `scaledDebtBurned = floor(requestedRepay × RAY / variableBorrowIndexRay)`
4. Debit repaid amount from position's principal in the loan pool
5. Increase `availableLiquidity`
6. Realize proportional protocol interest fee via `LibFeeRouter`
7. Charge action fee via `LibActionFees`
8. If both `scaledSupply` and `scaledDebt` reach zero, clear `useAsCollateral`

---

## Interest Rate Model

### Kinked Variable Rate (LibIlmInterestRate)

The borrow rate follows a two-slope kinked model parameterized per market:

```
if utilization ≤ optimalUtilization:
    borrowRate = baseRate + slope1 × (utilization / optimalUtilization)

if utilization > optimalUtilization:
    borrowRate = baseRate + slope1 + slope2 × (utilization - optimalUtilization) / (1 - optimalUtilization)
```

All rates are ray-scaled (1e27) per-year values.

### Utilization

```
utilization = totalDebt / (totalDebt + availableLiquidity)
```

When `totalDebt = 0`, utilization is 0. When `availableLiquidity = 0`, utilization approaches 1.0 (RAY).

### Supplier Liquidity Rate

Suppliers earn a fraction of the borrow rate proportional to utilization, minus the reserve factor:

```
liquidityRate = borrowRate × utilization × (1 - reserveFactorBps / 10,000)
```

### Index Accrual (LibIlmIndexing)

Indexes compound linearly per elapsed time (simple interest per accrual period):

```solidity
liquidityFactor    = RAY + (liquidityRate × elapsed / SECONDS_PER_YEAR)
variableBorrowFactor = RAY + (variableBorrowRate × elapsed / SECONDS_PER_YEAR)

newLiquidityIndex      = liquidityIndex × liquidityFactor / RAY
newVariableBorrowIndex = variableBorrowIndex × variableBorrowFactor / RAY
```

Indexes are stored as `uint128` and accrued lazily on every state-changing operation (`supply`, `withdraw`, `borrow`, `repay`, `liquidation`).

### Protocol Fee Accrual

The reserve factor captures a portion of interest income as a deferred protocol fee claim:

```
debtIncrease = totalDebtAfter - totalDebtBefore
protocolFeeAccrued = debtIncrease × reserveFactorBps / 10,000
```

This claim is stored in `marketProtocolFeeAssets[marketId]` and realized proportionally on each repayment or liquidation via `LibFeeRouter.routeManagedShare`.

### Rate Visualization

```
Borrow Rate
    │
    │                                    ╱ slope2 (steep)
    │                                  ╱
    │                                ╱
    │              slope1          ╱
    │            ╱               ╱
    │          ╱               ╱
    │        ╱               ╱
    │      ╱               ╱
    │    ╱               ╱
    │  ╱               ╱
    │╱───────────────╱──────────────────
    │ baseRate       │
    └────────────────┼──────────────────── Utilization
                     │
              optimalUtilization
```

---

## Liquidation System

### Health Factor

A position's health factor determines its liquidation eligibility:

```solidity
supplyCollateralValue = fromScaledSupply(scaledSupply, liquidityIndexRay)  // if useAsCollateral
externalCollateralValue = externalCollateralAmount × oraclePrice / RAY
adjustedCollateral = (supplyCollateralValue + externalCollateralValue) × liquidationThresholdBps / BPS
healthFactor = adjustedCollateral × HF_PRECISION / debtValue
```

Where `HF_PRECISION = 1e18`. A position with no debt has `healthFactor = type(uint256).max`.

### Liquidation Trigger

Any authorized position holder can liquidate a borrower when `healthFactor < 1e18`:

```solidity
(uint256 debtLiquidated, uint256 collateralSeized) = liquidationFacet.pooledLiquidationCall(
    liquidatorPositionId,
    borrowerPositionId,
    marketId,
    debtToCover
);
```

### Close Factor

The close factor determines how much debt can be liquidated in a single call:

| Health Factor | Close Factor |
|---------------|-------------|
| HF < 0.95 | 100% (full liquidation) |
| 0.95 ≤ HF < 1.0 | 50% (partial liquidation) |

### Liquidation Math (LibIlmLiquidation)

**Step 1: Cap debt to cover**
```
maxDebtByCloseFactor = totalDebt × closeFactorBps / 10,000
cappedDebt = min(debtToCover, maxDebtByCloseFactor)
```

**Step 2: Cap by available collateral**
```
collateralValueInLoanAsset = externalCollateral × oraclePrice / RAY
maxDebtByCollateral = collateralValueInLoanAsset × BPS / (BPS + liquidationBonusBps)
cappedDebt = min(cappedDebt, maxDebtByCollateral)
```

**Step 3: Compute seizure amounts**
```
seizedValueInLoanAsset = cappedDebt × (BPS + liquidationBonusBps) / BPS
grossSeized = seizedValueInLoanAsset × RAY / oraclePrice
protocolFeeCollateral = grossSeized × liquidationProtocolFeeBps / BPS
netSeized = grossSeized - protocolFeeCollateral
```

### Liquidation Flow

1. Accrue market indexes
2. Check sentinel allows liquidation
3. Compute borrower's health factor; revert if HF ≥ 1.0
4. Determine close factor and cap debt to cover
5. Compute gross seized, protocol fee, and net seized collateral
6. Enforce dust rule (no tiny residual positions)
7. Debit loan-asset principal from liquidator (repaying borrower's debt)
8. Burn borrower's scaled debt; increase `availableLiquidity`
9. Handle bad debt: if collateral exhausted but debt remains, write off residual as `badDebt`
10. Transfer collateral: debit from borrower, credit net to liquidator, route protocol fee via `LibFeeRouter`
11. Unencumber borrower's collateral from module encumbrance
12. Realize proportional protocol interest fee

### Bad Debt Handling

When a borrower's external collateral is fully seized but scaled debt remains:

```solidity
if (remainingCollateral == 0 && borrower.scaledDebt > 0) {
    badDebtAdded = fromScaledDebt(borrower.scaledDebt, variableBorrowIndexRay);
    market.badDebt += badDebtAdded;
    // Scaled debt zeroed, protocol fee claim written down proportionally
}
```

Bad debt is socialized across the pool. The `badDebt` counter tracks cumulative losses.

### Dust Rule

After liquidation, the system prevents tiny residual positions:
- Remaining collateral must be > 1 wei (or exactly 0)
- Remaining debt must be > 1 wei if collateral exists (or exactly 0)

This prevents griefing via micro-positions that are uneconomical to liquidate.

---

## Fee System

### Interest Income Distribution

Interest income flows through two channels:

1. **Supplier yield:** Captured automatically via the liquidity index. As the index grows, each scaled supply share represents more tokens. No explicit distribution needed.

2. **Protocol reserve:** The reserve factor skims a percentage of interest income into a deferred claim (`marketProtocolFeeAssets`). This claim is realized on repayment/liquidation and routed via `LibFeeRouter.routeManagedShare` into the protocol's fee distribution system (treasury, active credit index, fee index).

### Protocol Fee Realization

On each repayment or liquidation:

```
realized = protocolFeeClaim × debtReduction / totalDebtBefore
marketProtocolFeeAssets -= realized
LibFeeRouter.routeManagedShare(loanPoolId, realized, ILM_INTEREST_FEE_SOURCE)
```

When all debt is repaid (`scaledVariableDebtTotal = 0`), any residual claim is zeroed.

### Liquidation Protocol Fee

A separate fee is charged on liquidation seizures:

```
protocolFeeCollateral = grossSeized × liquidationProtocolFeeBps / BPS
```

This is routed via `LibFeeRouter.routeManagedShare` with the `ILM_LIQUIDATION_FEE_SOURCE` tag.

### Action Fees

Borrow and repay operations charge action fees via `LibActionFees.chargeFromUser`, which deducts from the position's principal in the loan pool and routes through the standard fee distribution system.

### Fee Source Summary

| Source | Trigger | Distribution |
|--------|---------|-------------|
| Interest reserve factor | Repay / Liquidation | `LibFeeRouter` → treasury, active credit, fee index |
| Liquidation protocol fee | Liquidation | `LibFeeRouter` → treasury, active credit, fee index |
| Borrow action fee | Borrow | `LibActionFees` → standard fee routing |
| Repay action fee | Repay | `LibActionFees` → standard fee routing |

### Integration with Core Fee System

Pooled ILM integrates with the same fee infrastructure as the rest of Equalis:

- **LibFeeIndex:** Supplier principal in the loan pool continues to earn from the pool's fee index (flash loan fees, penalty distributions, etc.)
- **LibActiveCreditIndex:** Encumbered principal participates in active credit rewards with the standard 24-hour time gate
- **LibFeeRouter:** Protocol fees are split according to the global treasury/active-credit/fee-index configuration

---

## Data Models

### ILM Storage (LibIlmStorage)

```solidity
struct IlmStorage {
    uint256 nextMarketId;                                          // Auto-incrementing market ID
    mapping(uint256 => uint256) marketModuleId;                    // Market → module registry ID
    mapping(uint256 => IlmTypes.IlmMarket) markets;               // Market state
    mapping(uint256 => mapping(bytes32 => IlmTypes.IlmPosition)) positions;  // Per-market per-position
    mapping(uint256 => uint256) marketProtocolFeeAssets;           // Deferred protocol fee claim
    mapping(bytes32 => mapping(address => bool)) isAuthorizedOperator;  // Operator delegation
    address oracleAdapter;                                         // Price feed adapter
    address sentinelAdapter;                                       // Circuit breaker adapter
    uint16 minLtvBps;                                              // Global LTV floor
    uint16 maxLtvBps;                                              // Global LTV ceiling
    uint16 minReserveFactorBps;                                    // Global reserve factor floor
    uint16 maxReserveFactorBps;                                    // Global reserve factor ceiling
}
```

### Market State (IlmTypes.IlmMarket)

```solidity
struct IlmMarket {
    // Pool pairing
    uint256 loanPoolId;
    uint256 collateralPoolId;

    // Risk parameters
    uint16 ltvBps;                          // Max LTV for borrowing
    uint16 liquidationThresholdBps;         // HF liquidation threshold (> ltvBps)
    uint16 liquidationBonusBps;             // Liquidator bonus in basis points
    uint16 liquidationProtocolFeeBps;       // Protocol's cut of liquidation bonus

    // Rate strategy
    uint16 reserveFactorBps;               // Protocol interest cut
    uint16 optimalUtilizationBps;           // Utilization kink point
    uint32 baseVariableRateRayPerYear;      // Base borrow rate
    uint32 variableSlope1RayPerYear;        // Slope below kink
    uint32 variableSlope2RayPerYear;        // Slope above kink (steep)

    // Caps & flags
    uint256 supplyCap;                      // Max total supply (0 = unlimited)
    uint256 borrowCap;                      // Max total borrows (0 = unlimited)
    bool active;                            // Market active flag
    bool paused;                            // Market paused flag
    bool frozen;                            // Market frozen flag

    // Index state (ray-scaled, 1e27)
    uint128 liquidityIndexRay;              // Cumulative supply index
    uint128 variableBorrowIndexRay;         // Cumulative borrow index
    uint128 currentLiquidityRateRay;        // Current supply APY (informational)
    uint128 currentVariableBorrowRateRay;   // Current borrow APY (informational)
    uint64 lastUpdate;                      // Last index accrual timestamp

    // Aggregate scaled balances
    uint256 scaledSupplyTotal;              // Sum of all scaled supply shares
    uint256 scaledVariableDebtTotal;        // Sum of all scaled debt shares

    // Liquidity tracking
    uint256 availableLiquidity;             // Tokens available for borrowing

    // Bad debt tracking
    uint256 badDebt;                        // Cumulative socialized losses
}
```

### Position State (IlmTypes.IlmPosition)

```solidity
struct IlmPosition {
    uint256 scaledSupply;       // Scaled supply shares (actual = scaled × liquidityIndex / RAY)
    uint256 scaledDebt;         // Scaled debt shares (actual = scaled × variableBorrowIndex / RAY)
    bool useAsCollateral;       // Whether supply counts as collateral for this position
}
```

### Constants

```solidity
uint256 constant RAY = 1e27;                           // Ray precision for indexes
uint256 constant WAD = 1e18;                            // Wad precision
uint256 constant BPS = 10_000;                          // Basis points denominator
uint256 constant HF_PRECISION = 1e18;                   // Health factor precision
uint256 constant CLOSE_FACTOR_HF_THRESHOLD = 95e16;     // 0.95e18 — full liquidation below this
uint16 constant DEFAULT_CLOSE_FACTOR_BPS = 5_000;       // 50% partial liquidation
uint256 constant SECONDS_PER_YEAR = 365 days;           // Rate annualization
```

---

## View Functions

### Market Queries

```solidity
// Get full market state (indexes, rates, caps, flags, totals)
function getPooledMarket(uint256 marketId) external view returns (IlmTypes.IlmMarket memory);

// Get deferred protocol fee claim for a market
function getPooledMarketProtocolFeeAssets(uint256 marketId) external view returns (uint256 feeAssets);
```

### Position Queries

```solidity
// Get raw position state (scaled balances, collateral flag)
function getPooledPosition(uint256 marketId, uint256 positionId)
    external view returns (IlmTypes.IlmPosition memory);

// Preview health factor with up-to-date index projection
function previewHealthFactor(uint256 marketId, uint256 positionId)
    external view returns (uint256 hf);

// Preview actual supply balance (scaled × projected liquidityIndex)
function previewSupplyBalance(uint256 marketId, uint256 positionId)
    external view returns (uint256 balance);

// Preview actual debt balance (scaled × projected variableBorrowIndex)
function previewDebtBalance(uint256 marketId, uint256 positionId)
    external view returns (uint256 debt);
```

### Preview Index Projection

View functions project indexes forward without writing state:

```solidity
elapsed = block.timestamp - market.lastUpdate
utilizationRay = totalDebt / (totalDebt + availableLiquidity)
variableBorrowRateRay = computeVariableBorrowRate(utilization, params...)
liquidityRateRay = computeLiquidityRate(borrowRate, utilization, reserveFactor)

projectedLiquidityIndex = liquidityIndex × (RAY + liquidityRate × elapsed / SECONDS_PER_YEAR) / RAY
projectedBorrowIndex = borrowIndex × (RAY + borrowRate × elapsed / SECONDS_PER_YEAR) / RAY
```

This ensures view functions return accurate real-time balances without requiring a transaction.

---

## Integration Guide

### For Developers

#### Supplying Liquidity

```solidity
// 1. Ensure position has principal in the loan pool
//    (deposit via PositionManagementFacet first)

// 2. Supply into the pooled market
pooledFacet.pooledSupply(positionId, marketId, supplyAmount);

// 3. Check current supply balance (includes accrued interest)
uint256 balance = viewFacet.previewSupplyBalance(marketId, positionId);

// 4. Withdraw when ready (principal + interest)
uint256 withdrawn = pooledFacet.pooledWithdraw(positionId, marketId, withdrawAmount);
```

#### Borrowing Against Collateral

```solidity
// 1. Ensure position has principal in the collateral pool

// 2. Pledge collateral
pooledFacet.pooledAddCollateral(positionId, marketId, collateralAmount);

// 3. Borrow from the pool
pooledFacet.pooledBorrow(positionId, marketId, borrowAmount);

// 4. Monitor health factor
uint256 hf = viewFacet.previewHealthFactor(marketId, positionId);

// 5. Repay debt
uint256 repaid = pooledFacet.pooledRepay(positionId, marketId, repayAmount);

// 6. Reclaim collateral after full repayment
pooledFacet.pooledRemoveCollateral(positionId, marketId, collateralAmount);
```

#### Combined Supply + Borrow (Self-Leveraging)

A position can supply loan-asset as collateral and borrow against it simultaneously:

```solidity
// Supply USDC into the market (auto-enables useAsCollateral)
pooledFacet.pooledSupply(positionId, marketId, 10_000e6);

// Borrow against the supplied USDC (no external collateral needed)
pooledFacet.pooledBorrow(positionId, marketId, 7_000e6);
// Health factor depends on liquidationThresholdBps
```

#### Liquidation Bot

```solidity
// 1. Monitor borrower health factors
uint256 hf = viewFacet.previewHealthFactor(marketId, borrowerPositionId);

// 2. If HF < 1e18, liquidate
if (hf < 1e18) {
    uint256 debt = viewFacet.previewDebtBalance(marketId, borrowerPositionId);
    // Attempt to cover up to 50% (or 100% if HF < 0.95)
    (uint256 debtLiquidated, uint256 collateralSeized) = liquidationFacet.pooledLiquidationCall(
        liquidatorPositionId,
        borrowerPositionId,
        marketId,
        debt  // system caps automatically
    );
}
```

### For Users

#### Earning Yield as a Supplier

1. Deposit assets into the underlying loan pool via your Position NFT
2. Supply those assets into a pooled market
3. Interest accrues automatically via the liquidity index
4. Withdraw at any time (subject to available liquidity)
5. Your supply also counts as collateral if you want to borrow

#### Borrowing with External Collateral

1. Deposit collateral-asset into the collateral pool via your Position NFT
2. Pledge collateral to the market
3. Borrow loan-asset up to the LTV limit
4. Monitor your health factor — if it drops below 1.0, you can be liquidated
5. Repay debt to free collateral and avoid liquidation

#### Managing Risk

- Keep health factor well above 1.0 (recommended > 1.5 for volatile pairs)
- Monitor oracle price movements between collateral and loan assets
- Repay debt proactively when health factor trends downward
- Consider the steep rate increase above optimal utilization when borrowing

---

## Worked Examples

### Example 1: Basic Supply and Earn

**Scenario:** Alice supplies 10,000 USDC into a USDC/WETH pooled market.

**Day 0: Supply**
```
liquidityIndexRay = 1.0e27
Alice supplies: 10,000 USDC
scaledSupply = 10,000 × 1e27 / 1.0e27 = 10,000
actualBalance = 10,000 USDC
```

**Day 30: Interest Accrued**
```
Market utilization: 75% (7,500 borrowed of 10,000 supplied)
Borrow rate: ~8% APY (example)
Liquidity rate: 8% × 0.75 × (1 - 0.10) = 5.4% APY (10% reserve factor)
liquidityIndexRay ≈ 1.0e27 × (1 + 0.054 × 30/365) ≈ 1.00444e27

Alice's balance = 10,000 × 1.00444e27 / 1e27 = 10,044.4 USDC
Alice earned ≈ 44.4 USDC in 30 days
```

### Example 2: Cross-Asset Borrow

**Scenario:** Bob pledges 5 WETH as collateral to borrow USDC. Market params: LTV 80%, liquidation threshold 85%, liquidation bonus 5%.

**Step 1: Pledge Collateral**
```
Bob's WETH principal in collateral pool: 5 WETH
Bob pledges: 5 WETH via pooledAddCollateral
Module encumbrance: 5 WETH locked
```

**Step 2: Borrow**
```
Oracle price: 1 WETH = 2,000 USDC (priceRay = 2000e27)
Collateral value in USDC: 5 × 2,000 = 10,000 USDC
Max borrow (LTV 80%): 10,000 × 80% = 8,000 USDC
Bob borrows: 6,000 USDC

Health factor = (10,000 × 85% / 10,000) × 1e18 / 6,000 × 1e18
             = 8,500 × 1e18 / 6,000
             = 1.4167e18 ✓ (healthy)
```

**Step 3: Price Drop**
```
Oracle price drops: 1 WETH = 1,500 USDC
Collateral value: 5 × 1,500 = 7,500 USDC
Adjusted collateral: 7,500 × 85% = 6,375 USDC
Health factor = 6,375 × 1e18 / 6,000 = 1.0625e18 ✓ (still healthy, but tight)
```

**Step 4: Further Price Drop → Liquidation**
```
Oracle price drops: 1 WETH = 1,350 USDC
Collateral value: 5 × 1,350 = 6,750 USDC
Adjusted collateral: 6,750 × 85% = 5,737.5 USDC
Health factor = 5,737.5 × 1e18 / 6,000 = 0.9563e18 ✗ (liquidatable)

HF > 0.95 → close factor = 50%
Max debt to liquidate: 6,000 × 50% = 3,000 USDC

Gross seized = 3,000 × (10,000 + 500) / 10,000 / 1,350 × 1e27 / 1e27
            = 3,000 × 1.05 / 1,350 = 2.333 WETH
Protocol fee (10%): 0.2333 WETH
Net to liquidator: 2.1 WETH

Post-liquidation:
  Bob's debt: 3,000 USDC
  Bob's collateral: 5 - 2.333 = 2.667 WETH
  New HF = (2.667 × 1,350 × 0.85) / 3,000 = 1.0204e18 ✓
```

### Example 3: Bad Debt Scenario

**Scenario:** A flash crash exhausts Carol's collateral before liquidators can act.

```
Carol's collateral: 2 WETH (encumbered)
Carol's debt: 4,000 USDC
Oracle price crashes: 1 WETH = 1,000 USDC

HF = (2 × 1,000 × 0.85) / 4,000 = 0.425e18 (HF < 0.95 → 100% close factor)

Max debt by collateral:
  collateralValue = 2 × 1,000 = 2,000 USDC
  maxDebt = 2,000 × 10,000 / 10,500 = 1,904.76 USDC

Liquidator covers 1,904.76 USDC, seizes all 2 WETH
Remaining debt: 4,000 - 1,904.76 = 2,095.24 USDC
Remaining collateral: 0 WETH

→ Bad debt: 2,095.24 USDC written off
→ market.badDebt += 2,095.24
→ Protocol fee claim written down proportionally
```

### Example 4: Interest Rate Dynamics

**Scenario:** Market with optimalUtilization = 80%, baseRate = 2%, slope1 = 4%, slope2 = 75%.

| Utilization | Borrow Rate | Supplier Rate (RF=10%) |
|-------------|-------------|----------------------|
| 0% | 2.0% | 0.0% |
| 40% | 4.0% | 1.44% |
| 80% (kink) | 6.0% | 4.32% |
| 90% | 43.5% | 35.24% |
| 95% | 62.25% | 53.22% |
| 100% | 81.0% | 72.9% |

The steep slope2 above the kink creates strong incentive to repay and restore utilization below optimal.

---

## Error Reference

### Market Errors

| Error | Cause |
|-------|-------|
| `IlmMarketNotFound(uint256)` | Market ID does not exist or has never been initialized |
| `IlmReserveInactive(uint256)` | Market `active` flag is false |
| `IlmReservePaused(uint256)` | Market `paused` flag is true |
| `IlmReserveFrozen(uint256)` | Market `frozen` flag is true (blocks supply/borrow) |

### Cap Errors

| Error | Cause |
|-------|-------|
| `IlmSupplyCapExceeded(uint256, uint256)` | Post-supply total exceeds `supplyCap` |
| `IlmBorrowCapExceeded(uint256, uint256)` | Post-borrow total exceeds `borrowCap` |

### Liquidity Errors

| Error | Cause |
|-------|-------|
| `IlmInsufficientLiquidity(uint256, uint256)` | Requested amount exceeds available liquidity, scaled supply, or encumbered collateral |

### Position Safety Errors

| Error | Cause |
|-------|-------|
| `IlmUnsafePosition(uint256, uint256)` | Post-operation health factor < 1.0 (HF_PRECISION) |
| `IlmNotLiquidatable(uint256)` | Attempted liquidation on a healthy position (HF ≥ 1.0) |

### External Gate Errors

| Error | Cause |
|-------|-------|
| `IlmSentinelBlocked()` | Sentinel adapter rejected the borrow or liquidation |

### Governance Errors

| Error | Cause |
|-------|-------|
| `IlmInvalidRiskParams()` | Invalid parameter combination (LTV ≥ threshold, zero index, overflow, etc.) |
| `IlmNotGovernance()` | Caller is neither diamond owner nor timelock |

### Authorization Errors

| Error | Cause |
|-------|-------|
| `IlmUnauthorized()` | Caller is not the Position NFT owner or authorized operator |

### Module Errors

| Error | Cause |
|-------|-------|
| `ModuleNotFound(uint256)` | Module ID not registered |
| `ModulePausedError(uint256)` | Module is paused |
| `InsufficientUnencumberedPrincipal(uint256, uint256)` | Not enough free principal for the operation |
| `InsufficientPrincipal(uint256, uint256)` | Principal balance too low (used in liquidation seizure) |

---

## Events

### Core Operation Events

```solidity
event IlmSupply(
    uint256 indexed marketId,
    bytes32 indexed positionKey,
    uint256 amount,
    uint256 scaledMinted
);

event IlmWithdraw(
    uint256 indexed marketId,
    bytes32 indexed positionKey,
    uint256 amount,
    uint256 scaledBurned
);

event IlmAddCollateral(
    uint256 indexed marketId,
    bytes32 indexed positionKey,
    uint256 amount
);

event IlmRemoveCollateral(
    uint256 indexed marketId,
    bytes32 indexed positionKey,
    uint256 amount
);

event IlmBorrow(
    uint256 indexed marketId,
    bytes32 indexed positionKey,
    uint256 amount,
    uint256 scaledDebtMinted
);

event IlmRepay(
    uint256 indexed marketId,
    bytes32 indexed positionKey,
    uint256 amount,
    uint256 scaledDebtBurned
);
```

### Liquidation Events

```solidity
event IlmLiquidation(
    uint256 indexed marketId,
    bytes32 indexed borrowerKey,
    bytes32 indexed liquidatorKey,
    uint256 debtLiquidated,
    uint256 scaledDebtBurned,
    uint256 collateralSeized,
    uint256 badDebtAdded
);

event IlmLiquidationRevenue(
    uint256 indexed marketId,
    bytes32 indexed borrowerKey,
    bytes32 indexed liquidatorKey,
    uint256 grossSeized,
    uint256 protocolFeeCollateral,
    uint256 netSeized
);
```

### Admin Events

```solidity
event IlmMarketCreated(
    uint256 indexed marketId,
    uint256 indexed loanPoolId,
    uint256 indexed collateralPoolId
);

event IlmPooledMarketFlagsSet(
    uint256 indexed marketId,
    bool active,
    bool paused,
    bool frozen
);

event IlmPooledMarketCapsSet(
    uint256 indexed marketId,
    uint256 supplyCap,
    uint256 borrowCap
);

event IlmPooledRiskParamsSet(
    uint256 indexed marketId,
    uint16 ltvBps,
    uint16 liquidationThresholdBps,
    uint16 liquidationBonusBps,
    uint16 liquidationProtocolFeeBps
);

event IlmPooledRateStrategySet(
    uint256 indexed marketId,
    uint16 reserveFactorBps,
    uint16 optimalUtilizationBps,
    uint32 baseVariableRateRayPerYear,
    uint32 variableSlope1RayPerYear,
    uint32 variableSlope2RayPerYear
);

event IlmPooledOracleAdapterSet(address indexed oracleAdapter);
event IlmPooledSentinelAdapterSet(address indexed sentinelAdapter);
event IlmPooledGlobalBoundsSet(
    uint16 minLtvBps,
    uint16 maxLtvBps,
    uint16 minReserveFactorBps,
    uint16 maxReserveFactorBps
);
```

---

## Security Considerations

### 1. Oracle Dependency

Unlike self-secured credit, Pooled ILM relies on external price feeds via `IIlmOracleAdapter`:

```solidity
priceRay = IIlmOracleAdapter(oracleAdapter).getPrice(loanPoolId, collateralPoolId);
```

- Oracle adapter is set by governance and can be updated
- Zero price reverts all operations that require pricing (borrow, collateral removal, liquidation)
- Oracle manipulation can lead to under-collateralized borrows or premature liquidations

**Mitigation:** The sentinel adapter provides a circuit breaker that can pause borrows and liquidations during oracle instability.

### 2. Sentinel Circuit Breaker

The optional `IIlmSentinelAdapter` gates borrows and liquidations:

```solidity
interface IIlmSentinelAdapter {
    function isBorrowAllowed() external view returns (bool);
    function isLiquidationAllowed() external view returns (bool);
}
```

- If no sentinel is set (`address(0)`), operations proceed unrestricted
- Sentinel can be used to pause during oracle failures, extreme volatility, or protocol upgrades
- Borrow and liquidation sentinels are independent, allowing selective pausing

### 3. Bad Debt Socialization

When a borrower's collateral is fully seized but debt remains, the residual is written off as bad debt:

```solidity
market.badDebt += badDebtAdded;
```

This loss is socialized across all suppliers in the pool. The `badDebt` counter is cumulative and informational — it does not reduce individual supply balances directly, but represents a permanent reduction in the pool's backing.

**Mitigation:** Conservative LTV/liquidation threshold spreads, supply/borrow caps, and the steep slope2 rate above optimal utilization all reduce bad debt risk.

### 4. Index Overflow Protection

All index values are stored as `uint128` and validated on every accrual:

```solidity
if (newLiquidityIndexRay > type(uint128).max || newVariableBorrowIndexRay > type(uint128).max) {
    revert IlmInvalidRiskParams();
}
```

Rate values are similarly bounded. Timestamp is validated against `uint64` max.

### 5. Reentrancy Protection

All state-changing functions use the `nonReentrant` modifier via `ReentrancyGuardModifiers`.

### 6. Access Control

| Function | Access |
|----------|--------|
| Market creation | Governance (diamond owner or timelock) |
| Parameter updates | Governance |
| Supply / Withdraw | Position NFT owner or authorized operator |
| Borrow / Repay | Position NFT owner or authorized operator |
| Add/Remove Collateral | Position NFT owner or authorized operator |
| Liquidation | Any authorized position holder (liquidator must own a position) |

### 7. Module Encumbrance Isolation

Collateral is tracked via `LibModuleEncumbrance` with a per-module ID:

```solidity
LibModuleEncumbrance.encumber(positionKey, poolId, moduleId, amount);
```

This ensures that collateral locked for one market cannot be double-counted by another market or module. Each market is assigned a unique `moduleId` at creation.

### 8. Dust Prevention

The liquidation dust rule prevents micro-positions that are uneconomical to liquidate:

```solidity
if (collateralAfter > 0 && collateralAfter <= MIN_LIQUIDATION_DUST) revert();
if (debtAfter > 0 && debtAfter <= MIN_LIQUIDATION_DUST && collateralAfter > 0) revert();
```

### 9. Governance Parameter Bounds

Global bounds constrain per-market parameters:
- `ltvBps` must be within `[minLtvBps, maxLtvBps]`
- `reserveFactorBps` must be within `[minReserveFactorBps, maxReserveFactorBps]`
- `liquidationThresholdBps` must exceed `ltvBps`
- `liquidationProtocolFeeBps` and `optimalUtilizationBps` must not exceed `BPS` (10,000)

### 10. Principal Settlement on State Changes

All operations that modify principal (`_creditPrincipal`, `_debitPrincipal`) settle the position's fee index and active credit index first:

```solidity
LibFeeIndex.settle(poolId, positionKey);
LibActiveCreditIndex.settle(poolId, positionKey);
```

This ensures yield accounting is consistent before principal changes.

---

## Appendix: Correctness Properties

### Property 1: Health Factor Invariant
For any position after a non-liquidation operation:
```
healthFactor ≥ HF_PRECISION (1e18)
```

### Property 2: Index Monotonicity
Both indexes only increase over time:
```
newLiquidityIndexRay ≥ liquidityIndexRay
newVariableBorrowIndexRay ≥ variableBorrowIndexRay
```

### Property 3: Scaled Balance Conservation
For any market:
```
Σ(position.scaledSupply) = market.scaledSupplyTotal
Σ(position.scaledDebt) = market.scaledVariableDebtTotal
```

### Property 4: Liquidity Accounting
Available liquidity tracks actual borrowable tokens:
```
availableLiquidity = totalSupplied - totalBorrowed + totalRepaid - totalWithdrawn
```

### Property 5: Utilization Bound
Utilization is always in [0, RAY]:
```
0 ≤ utilizationRay ≤ RAY
```

### Property 6: Close Factor Correctness
Liquidation respects close factor limits:
```
debtLiquidated ≤ totalDebt × closeFactorBps / BPS
```

### Property 7: Seizure Bound
Gross seized collateral never exceeds available collateral:
```
grossSeized ≤ collateralEncumberedBefore
```

### Property 8: Bad Debt Monotonicity
Bad debt counter only increases:
```
newBadDebt ≥ badDebt
```

### Property 9: Encumbrance Consistency
Module encumbrance never exceeds position principal:
```
LibModuleEncumbrance.getEncumberedForModule(key, poolId, moduleId) ≤ userPrincipal[key]
```

### Property 10: Protocol Fee Claim Bound
Deferred protocol fee claim never exceeds total interest accrued:
```
marketProtocolFeeAssets[marketId] ≤ cumulative interest × reserveFactorBps / BPS
```

### Property 11: Rate Model Continuity
The borrow rate is continuous at the kink point:
```
rate(optimalUtilization⁻) = baseRate + slope1 = rate(optimalUtilization⁺)
```

### Property 12: Liquidation Threshold > LTV
Enforced at market creation and parameter updates:
```
liquidationThresholdBps > ltvBps
```

This gap provides a buffer zone where positions are above max borrow capacity but not yet liquidatable.

---

**Document Version:** 1.0
