# ILM Isolated Lending Markets - Design Document

**Version:** 1.0

---

## Table of Contents

1. [Overview](#overview)
2. [How It Works](#how-it-works)
3. [Architecture](#architecture)
4. [Market System](#market-system)
5. [Lending Operations](#lending-operations)
6. [Borrowing Operations](#borrowing-operations)
7. [Interest Rate System](#interest-rate-system)
8. [Liquidation System](#liquidation-system)
9. [Fee System](#fee-system)
10. [Oracle System](#oracle-system)
11. [Data Models](#data-models)
12. [View Functions](#view-functions)
13. [Integration Guide](#integration-guide)
14. [Worked Examples](#worked-examples)
15. [Error Reference](#error-reference)
16. [Events](#events)
17. [Security Considerations](#security-considerations)

---

## Overview

ILM Isolated is a cross-asset isolated lending module built on top of the Equalis diamond.
Each market pairs a loan pool with a collateral pool, an oracle, an interest-rate model, and a liquidation loan-to-value threshold. Markets are fully isolated: stress in one market cannot propagate to another. All positions live inside Position NFTs, and principal accounting flows through the existing pool and encumbrance infrastructure.

The design draws from Morpho Blue's share-based accounting and adaptive-curve IRM while integrating natively with Equalis pool principal, fee-index settlement, active-credit-index rewards, and module encumbrance.

### Key Characteristics

| Feature | Description |
|---------|-------------|
| **Cross-Asset Borrowing** | Borrow from one pool using collateral deposited in another |
| **Market Isolation** | Each market has independent supply, borrow, and bad-debt accounting |
| **Share-Based Accounting** | Supply and borrow positions tracked via virtual-share math for precision |
| **Pluggable Interest Rates** | Markets reference an IRM adapter; two implementations ship: adaptive curve and managed fixed rate |
| **Oracle-Gated Health** | Collateral valuation uses a pluggable oracle adapter with staleness enforcement |
| **Liquidation Incentive Factor** | Liquidators receive a mathematically derived bonus that increases as LLTV decreases |
| **Protocol Fee on Interest** | A WAD-scaled fee (≤ 25%) is taken from gross interest before it accrues to suppliers |
| **Liquidation Fee** | A per-market BPS fee on seized collateral routed through the fee router |
| **Position NFT Ownership** | All state tied to transferable ERC-721 tokens |
| **Module Encumbrance** | Supply and collateral lock principal via the centralized module-encumbrance system |
| **Active Credit Index** | Encumbered principal participates in the 24-hour time-gated active-credit reward index |

### System Participants

| Role | Description |
|------|-------------|
| **Supplier** | Deposits principal from a loan pool into a market to earn interest |
| **Borrower** | Posts collateral from a collateral pool and borrows from the loan pool |
| **Liquidator** | Repays an unhealthy borrower's debt in exchange for discounted collateral |
| **Market Creator** | Governance owner or managed-pool manager who creates markets |
| **Governance Owner** | Enables IRMs, LLTVs, sets fees, staleness, and ownership |

### Why Isolated Markets?

Traditional pooled lending (Aave, Compound) socializes risk across all assets in a single pool. A single bad oracle or illiquid collateral can cascade into protocol-wide bad debt.

Isolated markets contain risk:
- **Per-market bad debt** → Losses are socialized only among that market's suppliers
- **Independent parameters** → Each market has its own LLTV, IRM, oracle, and fee configuration
- **No global utilization coupling** → Borrowing pressure in one market does not affect rates in another

The tradeoff: capital is fragmented across markets. Suppliers must actively choose which markets to fund.

---

## How It Works

### The Core Model

1. **Create** a market by specifying loan pool, collateral pool, oracle, IRM, and LLTV
2. **Supply** principal from the loan pool into the market (earns interest)
3. **Post collateral** from the collateral pool into the market
4. **Borrow** against posted collateral up to the LLTV threshold
5. **Repay** debt to release collateral
6. **Withdraw** supply when liquidity is available
7. **Liquidate** unhealthy positions for a bonus

### Share-Based Accounting

Supply and borrow balances are tracked as shares rather than raw assets. This allows interest to accrue globally without iterating over individual positions:

```
supplyShares = assets × (totalSupplyShares + VIRTUAL_SHARES) / (totalSupplyAssets + VIRTUAL_ASSETS)
borrowShares = assets × (totalBorrowShares + VIRTUAL_SHARES) / (totalBorrowAssets + VIRTUAL_ASSETS)
```

Virtual shares (`1e6`) and virtual assets (`1`) prevent share-inflation attacks on empty markets.

### Health Check

A position is healthy when:

```
collateralAssets × oraclePrice / ORACLE_PRICE_SCALE × lltv / WAD ≥ borrowedAssets
```

Where:
- `oraclePrice` is scaled to `1e36` (ORACLE_PRICE_SCALE)
- `lltv` is WAD-scaled (e.g., `0.86e18` = 86%)
- `borrowedAssets` is derived from shares: `toAssetsUp(borrowShares, totalBorrowAssets, totalBorrowShares)`

---

## Architecture

### Contract Structure

```
src/ilm-isolated/
├── facets/
│   ├── ILMIsolatedAdminFacet.sol       # Market creation, governance, authorization
│   ├── ILMIsolatedFacet.sol            # Supply, withdraw, collateral, borrow, repay
│   ├── ILMIsolatedLiquidationFacet.sol # Liquidation with LIF-based incentive
│   └── ILMIsolatedViewFacet.sol        # Read-only market and position queries
├── interfaces/
│   ├── IIlmIsolatedIrmAdapter.sol      # Interest-rate model adapter interface
│   └── IIlmIsolatedOracleAdapter.sol   # Oracle adapter interface
├── irm/
│   ├── IlmAdaptiveCurveIrm.sol         # Stateful adaptive-curve IRM
│   └── IlmManagedFixedRateIrm.sol      # Immutable fixed-rate IRM
├── libraries/
│   ├── LibIlmInterestMath.sol          # Taylor-compounded interest accrual
│   ├── LibIlmIsolatedStorage.sol       # Diamond storage layout and market ID derivation
│   ├── LibIlmLiquidationMath.sol       # Health checks and LIF computation
│   └── LibIlmSharesMath.sol            # Virtual-share asset/share conversions
├── errors/
│   └── IlmIsolatedErrors.sol           # Custom error definitions
└── types/
    └── IlmIsolatedTypes.sol            # Core structs and constants
```

### High-Level Flow

```
┌──────────────────────────────────────────────────────────────────────┐
│                    ILM Isolated Lending Module                       │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌───────────────┐  ┌───────────────┐  ┌───────────────────────┐     │
│  │  Admin Facet   │  │  Core Facet   │  │  Liquidation Facet    │     │
│  │  (governance,  │  │  (supply,     │  │  (liquidate,          │     │
│  │   market       │  │   withdraw,   │  │   bad-debt            │     │
│  │   creation)    │  │   borrow,     │  │   socialization)      │     │
│  │               │  │   repay,      │  │                       │     │
│  │               │  │   collateral) │  │                       │     │
│  └───────────────┘  └───────────────┘  └───────────────────────┘     │
│         │                  │                      │                  │
│         └──────────────────┼──────────────────────┘                  │
│                            │                                         │
│                     ┌──────────────┐                                 │
│                     │  View Facet  │                                 │
│                     └──────────────┘                                 │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│                     Per-Market State                                 │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐   │
│  │  Market A         │  │  Market B         │  │  Market N         │  │
│  │  USDC→WETH        │  │  DAI→WBTC         │  │  USDT→stETH       │  │
│  │  (loan→collat)    │  │  (loan→collat)    │  │  (loan→collat)    │  │
│  └──────────────────┘  └──────────────────┘  └──────────────────┘   │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
         │                    │                    │
         ▼                    ▼                    ▼
   ┌──────────┐        ┌──────────┐        ┌──────────┐
   │ Position │        │  Oracle  │        │   IRM    │
   │   NFTs   │        │ Adapters │        │ Adapters │
   └──────────┘        └──────────┘        └──────────┘
         │
         ▼
   ┌──────────────────────────────────────────┐
   │  Equalis Core Infrastructure              │
   │  ┌────────────┐  ┌────────────────────┐  │
   │  │ Pool       │  │ Module Encumbrance │  │
   │  │ Principal  │  │ + Active Credit    │  │
   │  │ + FeeIndex │  │   Index            │  │
   │  └────────────┘  └────────────────────┘  │
   └──────────────────────────────────────────┘
```

---

## Market System

### Market Identity

Each market is uniquely identified by a deterministic `bytes32` hash of its parameters:

```solidity
marketId = keccak256(abi.encode(IlmIsolatedMarketParams({
    loanPoolId,
    collateralPoolId,
    oracle,
    irm,
    lltv
})))
```

This means the same parameter combination always produces the same market ID, and no two markets can share identical parameters.

### Market Parameters

```solidity
struct IlmIsolatedMarketParams {
    uint256 loanPoolId;        // Equalis pool supplying loan assets
    uint256 collateralPoolId;  // Equalis pool supplying collateral assets
    address oracle;            // Oracle adapter contract
    address irm;               // Interest-rate model adapter contract
    uint256 lltv;              // Liquidation loan-to-value, WAD-scaled (< 1e18)
}
```

### Market State

```solidity
struct IlmIsolatedMarket {
    uint128 totalSupplyAssets;   // Total assets supplied by lenders
    uint128 totalSupplyShares;   // Total supply shares outstanding
    uint128 totalBorrowAssets;   // Total assets borrowed (including accrued interest)
    uint128 totalBorrowShares;   // Total borrow shares outstanding
    uint128 lastUpdate;          // Timestamp of last interest accrual
    uint128 fee;                 // Protocol fee on interest, WAD-scaled (≤ 0.25e18)
}
```

### Market Creation

Markets are created via the admin facet. The IRM and LLTV must be pre-enabled by governance.

**Governance Path:**
```solidity
bytes32 marketId = adminFacet.createIlmIsolatedMarket(params, moduleId);
```

**Managed-Pool Path:**

When an IRM is flagged `managedOnly`, only the loan pool's manager (or the governance owner) can create markets using that IRM. This allows managed pools to control which rate models apply to their liquidity:

```solidity
// Manager of the loan pool creates a market with a managed-only IRM
bytes32 marketId = adminFacet.createIlmIsolatedMarket(params, moduleId);
```

**Requirements:**
- `params.irm` must be enabled via `enableIrm()`
- `params.lltv` must be enabled via `enableLltv()` and be < 1e18
- If `params.irm` is managed-only, `params.loanPoolId` must reference an initialized managed pool and `msg.sender` must be its manager or the governance owner
- The derived `marketId` must not already exist

### Module Registration

Each market is associated with a `moduleId` from the Equalis module registry. This module ID:
- Gates operations when the module is paused
- Scopes encumbrance tracking per module
- Enables per-module active-credit-index participation

---

## Lending Operations

### Supply

Suppliers deposit principal from the loan pool into a market. The supplied assets are converted to shares and the principal is encumbered via module encumbrance.

```solidity
(uint256 assets, uint256 shares) = facet.isolatedSupply(marketId, assets, 0, positionId);
// OR specify shares:
(uint256 assets, uint256 shares) = facet.isolatedSupply(marketId, 0, shares, positionId);
```

**Flow:**
1. Accrue interest on the market
2. Convert assets → shares (or shares → assets)
3. Verify the position has sufficient unencumbered principal in the loan pool
4. Encumber principal via `LibModuleEncumbrance` and register with active-credit index
5. Credit supply shares to the position

**Rounding:** Assets → shares rounds down (supplier receives fewer shares). Shares → assets rounds up (supplier pays more assets).

### Withdraw

Suppliers redeem shares for assets. The principal encumbrance is released.

```solidity
(uint256 assets, uint256 shares) = facet.isolatedWithdraw(marketId, assets, 0, positionId);
```

**Flow:**
1. Accrue interest on the market
2. Convert assets → shares (or shares → assets)
3. Verify the position holds enough supply shares
4. Verify sufficient liquidity: `totalBorrowAssets ≤ newTotalSupplyAssets`
5. Burn shares and reduce totals
6. Unencumber principal and update active-credit index

**Rounding:** Assets → shares rounds up (supplier burns more shares). Shares → assets rounds down (supplier receives fewer assets).

---

## Borrowing Operations

### Supply Collateral

Borrowers post collateral from the collateral pool. Collateral is tracked as raw assets (no shares).

```solidity
facet.isolatedSupplyCollateral(marketId, assets, positionId);
```

**Flow:**
1. Verify the position has sufficient unencumbered principal in the collateral pool
2. Encumber collateral principal via module encumbrance + active-credit index
3. Credit `collateralAssets` to the position

### Withdraw Collateral

Borrowers remove collateral, subject to a health check.

```solidity
facet.isolatedWithdrawCollateral(marketId, assets, positionId);
```

**Flow:**
1. Accrue interest
2. Fetch fresh oracle price (staleness enforced)
3. Compute post-withdrawal health: `isHealthy(newCollateral, borrowShares, ...)`
4. If unhealthy, revert with `IlmIsolatedInsufficientCollateral`
5. Reduce collateral and unencumber

### Borrow

Borrowers draw assets from the market's supply pool. Borrowed assets are credited to the borrower's principal in the loan pool.

```solidity
(uint256 assets, uint256 shares) = facet.isolatedBorrow(marketId, assets, 0, positionId);
```

**Flow:**
1. Accrue interest and fetch fresh oracle price
2. Convert assets → shares (or shares → assets)
3. Health check: position must remain healthy after the new borrow
4. Liquidity check: `newTotalBorrowAssets ≤ totalSupplyAssets`
5. Credit borrow shares to position, increase market borrow totals
6. Credit borrowed assets to position's principal in the loan pool
7. Charge action fee via `LibActionFees`

**Rounding:** Assets → shares rounds up (borrower owes more shares). Shares → assets rounds down (borrower receives fewer assets).

### Repay

Borrowers return assets to reduce their debt.

```solidity
(uint256 assets, uint256 shares) = facet.isolatedRepay(marketId, assets, 0, positionId);
```

**Flow:**
1. Accrue interest
2. Convert assets → shares (or shares → assets)
3. Clamp to position's actual borrow shares (prevents overpayment)
4. Debit repaid assets from position's principal in the loan pool
5. Reduce borrow shares and market borrow totals
6. Realize proportional protocol interest fee via fee router
7. Charge action fee via `LibActionFees`

**Rounding:** Assets → shares rounds down (borrower burns fewer shares). Shares → assets rounds up (borrower pays more assets).

---

## Interest Rate System

### IRM Adapter Interface

All interest-rate models implement a single function:

```solidity
interface IIlmIsolatedIrmAdapter {
    function borrowRate(
        IlmIsolatedMarketParams calldata params,
        IlmIsolatedMarket calldata market
    ) external returns (uint256 ratePerSecond);
}
```

The returned `ratePerSecond` is WAD-scaled (1e18 = 100% per second).

### Interest Accrual

Interest is accrued lazily on every state-changing operation via `LibIlmInterestMath.accrueInterest()`:

```solidity
// Taylor-compounded approximation: e^(rate × time) - 1
// Uses first 3 terms: x + x²/2 + x³/6 where x = ratePerSecond × elapsed
function wTaylorCompounded(uint256 ratePerSecond, uint256 elapsed) → uint256

// Accrual flow:
grossInterest = totalBorrowAssets × wTaylorCompounded(rate, elapsed)
protocolFee   = grossInterest × fee / WAD
totalBorrowAssets  += grossInterest
totalSupplyAssets  += grossInterest - protocolFee
```

The protocol fee is deducted from the interest before it reaches suppliers. This means suppliers earn `grossInterest × (1 - fee)` and the protocol accumulates `protocolFee` as a claim against future repayments.

### Protocol Fee Realization

Protocol fees are not immediately withdrawable. They are realized proportionally as borrowers repay:

```solidity
realized = protocolFeeClaim × debtReduction / totalBorrowAssets
```

Realized fees are routed through `LibFeeRouter.routeManagedShare()` into the loan pool's fee distribution infrastructure (treasury, active credit, fee index).

When all debt in a market is repaid (`totalBorrowAssets == 0`), any remaining fee claim is zeroed out.

### Adaptive Curve IRM

`IlmAdaptiveCurveIrm` is a stateful IRM that adjusts rates based on utilization, modeled after Morpho Blue's adaptive curve.

**Parameters (immutable constants):**

| Parameter | Value | Description |
|-----------|-------|-------------|
| `CURVE_STEEPNESS` | 4e18 | Multiplier for rate above target utilization |
| `ADJUSTMENT_SPEED` | 50e18 / 365 days | Speed of rate-at-target adaptation |
| `TARGET_UTILIZATION` | 0.9e18 | 90% target utilization |
| `INITIAL_RATE_AT_TARGET` | 0.04e18 / 365 days | ~4% APY initial rate |
| `MIN_RATE_AT_TARGET` | 0.001e18 / 365 days | ~0.1% APY floor |
| `MAX_RATE_AT_TARGET` | 2e18 / 365 days | ~200% APY ceiling |

**Behavior:**
1. Compute utilization: `totalBorrowAssets / totalSupplyAssets`
2. Compute normalized error: `(utilization - target) / normFactor`
3. Adapt `rateAtTarget` exponentially based on error × speed × elapsed time
4. Apply curve: below target → rate decreases (1/steepness); above target → rate increases (steepness)
5. Return average rate over the period using Simpson's-rule-style approximation

**Access Control:** Only the `protocolCaller` (the diamond) can call `borrowRate()` and update per-market state.

### Managed Fixed Rate IRM

`IlmManagedFixedRateIrm` returns a constant rate set at deployment:

```solidity
constructor(uint256 ratePerSecondWad_)  // Must be ≤ 1e15 (~3,153% APY)
function borrowRate(...) → ratePerSecondWad  // Always returns the immutable rate
```

This IRM is suitable for managed pools where the pool manager wants deterministic, non-adaptive rates.

---

## Liquidation System

### Health Check

A position is liquidatable when:

```
collateralAssets × oraclePrice / 1e36 × lltv / 1e18 < borrowedAssets
```

Where `borrowedAssets = toAssetsUp(borrowShares, totalBorrowAssets, totalBorrowShares)`.

The rounding direction (assets up) is conservative: it slightly overstates debt, making liquidation trigger marginally earlier for safety.

### Liquidation Incentive Factor (LIF)

The LIF determines how much collateral a liquidator receives per unit of debt repaid:

```solidity
LIF = min(MAX_LIF, WAD² / (WAD² - CURSOR × (WAD - lltv)))
```

Where:
- `CURSOR = 0.3e18` (30%)
- `MAX_LIF = 1.15e18` (15% max bonus)

| LLTV | LIF | Liquidator Bonus |
|------|-----|-----------------|
| 50% | 1.15e18 | 15% (capped) |
| 80% | 1.064e18 | ~6.4% |
| 86% | 1.044e18 | ~4.4% |
| 90% | 1.031e18 | ~3.1% |
| 95% | 1.015e18 | ~1.5% |

Higher LLTV → lower bonus, because positions are closer to full collateralization and less risky to liquidate.

### Liquidation Flow

```solidity
(uint256 seized, uint256 repaid) = liquidationFacet.isolatedLiquidate(
    marketId,
    borrowerPositionId,
    seizedAssets,      // specify one
    repaidShares,      // or the other (exactly one must be non-zero)
    liquidatorPositionId
);
```

**Flow:**
1. Accrue interest and fetch fresh oracle price
2. Verify borrower is unhealthy
3. Compute LIF for the market's LLTV
4. If `seizedAssets` specified: compute `repaidShares` from seized collateral value / LIF
5. If `repaidShares` specified: compute `seizedAssets` from repaid value × LIF
6. Deduct per-market liquidation fee (BPS) from gross seized collateral
7. Reduce borrower's borrow shares and market totals
8. Reduce borrower's collateral
9. Handle bad debt: if borrower's collateral reaches zero with remaining borrow shares, socialize the loss by reducing both `totalBorrowAssets` and `totalSupplyAssets`
10. Realize proportional protocol interest fee
11. Debit repaid assets from liquidator's loan-pool principal
12. Debit gross seized collateral from borrower's collateral-pool principal (ignoring encumbrance)
13. Credit net seized collateral to liquidator's collateral-pool principal
14. Route liquidation fee through `LibFeeRouter`
15. Unencumber borrower's collateral from module encumbrance + active-credit index

### Bad Debt Socialization

When a liquidation leaves the borrower with zero collateral but remaining borrow shares:

```solidity
badDebtAssets = min(totalBorrowAssets, toAssetsUp(badDebtShares, totalBorrowAssets, totalBorrowShares))
totalBorrowAssets -= badDebtAssets
totalSupplyAssets -= badDebtAssets   // Suppliers absorb the loss
totalBorrowShares -= badDebtShares
borrower.borrowShares = 0
```

Bad debt is socialized exclusively among the market's suppliers. Other markets are unaffected.

The protocol fee claim is also written down proportionally:

```solidity
writeDown = protocolFeeClaim × badDebtAssets / totalBorrowAssetsBeforeWriteDown
protocolFeeClaim -= writeDown
```

---

## Fee System

### Protocol Interest Fee

A WAD-scaled fee (≤ `MAX_FEE = 0.25e18`, i.e., 25%) is set per market by governance:

```solidity
adminFacet.setFee(marketId, fee);  // Accrues pending interest before updating
```

The fee is applied during interest accrual:
```
protocolFeeAccrued = grossInterest × fee / WAD
supplierInterest   = grossInterest - protocolFeeAccrued
```

### Liquidation Fee

A per-market BPS fee on gross seized collateral during liquidation:

```solidity
adminFacet.setMarketLiquidationFeeBps(marketId, bps);  // ≤ 10,000
```

Applied during liquidation:
```
protocolFeeCollateral = grossSeizedAssets × liquidationFeeBps / 10,000
netSeizedAssets       = grossSeizedAssets - protocolFeeCollateral
```

The liquidation fee is routed through `LibFeeRouter.routeManagedShare()` into the collateral pool's fee distribution.

### Action Fees

Borrow and repay operations charge action fees via `LibActionFees.chargeFromUser()`, using the loan pool's configured action-fee schedule. These are standard Equalis action fees, not specific to the ILM module.

### Fee Routing Summary

| Fee Source | Routing |
|------------|---------|
| Protocol interest fee | Realized on repay/liquidation → `LibFeeRouter.routeManagedShare(loanPoolId, ...)` |
| Liquidation collateral fee | On liquidation → `LibFeeRouter.routeManagedShare(collateralPoolId, ...)` |
| Borrow action fee | On borrow → `LibActionFees.chargeFromUser(loanPool, ...)` |
| Repay action fee | On repay → `LibActionFees.chargeFromUser(loanPool, ...)` |

---

## Oracle System

### Oracle Adapter Interface

```solidity
interface IIlmIsolatedOracleAdapter {
    function getIsolatedPrice(address oracle)
        external view
        returns (uint256 price, uint256 updatedAt);
}
```

- `price` is scaled to `ORACLE_PRICE_SCALE = 1e36`
- `updatedAt` is the timestamp of the last price update

### Staleness Enforcement

Every operation requiring a price (borrow, withdraw collateral, liquidate, health check) enforces:

```solidity
if (updatedAt + maxStaleness < block.timestamp) {
    revert IlmIsolatedOracleStale(updatedAt, maxStaleness);
}
```

`maxStaleness` is a global parameter set by governance:

```solidity
adminFacet.setMaxStaleness(maxStaleness);  // Must be > 0
```

---

## Data Models

### Storage Layout

```solidity
struct IlmIsolatedStorageLayout {
    address owner;                                                          // Governance owner
    bytes32 feeRecipientPositionKey;                                        // Deprecated; retained for compatibility
    uint256 maxStaleness;                                                   // Oracle staleness threshold (seconds)
    mapping(address => bool) isIrmEnabled;                                  // Allowlisted IRM contracts
    mapping(address => bool) isIrmManagedOnly;                              // IRMs restricted to managed-pool creators
    mapping(uint256 => bool) isLltvEnabled;                                 // Allowlisted LLTV values
    mapping(bytes32 => IlmIsolatedMarketParams) marketParams;               // Per-market immutable parameters
    mapping(bytes32 => IlmIsolatedMarket) market;                           // Per-market mutable state
    mapping(bytes32 => mapping(bytes32 => IlmIsolatedPosition)) position;   // Per-market per-position state
    mapping(bytes32 => mapping(address => bool)) isAuthorizedOperator;      // Per-position operator approvals
    mapping(bytes32 => uint256) marketModuleId;                             // Module ID per market
    mapping(bytes32 => uint16) marketLiquidationFeeBps;                     // Liquidation fee per market
    mapping(bytes32 => uint256) marketProtocolFeeAssets;                    // Accrued protocol fee claim per market
}
```

### Position State

```solidity
struct IlmIsolatedPosition {
    uint256 supplyShares;    // Shares of supply in this market
    uint128 borrowShares;    // Shares of borrow debt in this market
    uint128 collateralAssets; // Raw collateral assets posted
}
```

### Constants

```solidity
uint256 constant WAD = 1e18;
uint256 constant ORACLE_PRICE_SCALE = 1e36;
uint256 constant LIQUIDATION_CURSOR = 3e17;              // 0.3e18
uint256 constant MAX_LIQUIDATION_INCENTIVE_FACTOR = 115e16; // 1.15e18
uint256 constant MAX_FEE = 25e16;                         // 0.25e18
uint256 constant VIRTUAL_SHARES = 1e6;
uint256 constant VIRTUAL_ASSETS = 1;
```

### Market ID Derivation

```solidity
function deriveMarketId(IlmIsolatedMarketParams memory params) → bytes32 {
    return keccak256(abi.encode(params));
}
```

---

## View Functions

### Market Queries

```solidity
// Get market state (reverts if not created)
function getIsolatedMarket(bytes32 marketId)
    external view returns (IlmIsolatedMarket memory);

// Get market parameters
function getIsolatedMarketParams(bytes32 marketId)
    external view returns (IlmIsolatedMarketParams memory);

// Get per-market liquidation fee
function getIsolatedMarketLiquidationFeeBps(bytes32 marketId)
    external view returns (uint16 bps);

// Get accrued protocol fee claim
function getIsolatedMarketProtocolFeeAssets(bytes32 marketId)
    external view returns (uint256 feeAssets);

// Check if an IRM is managed-only
function isIlmIrmManagedOnly(address irm)
    external view returns (bool);
```

### Position Queries

```solidity
// Get position state in a market
function getIsolatedPosition(bytes32 marketId, bytes32 positionKey)
    external view returns (IlmIsolatedPosition memory);

// Check if a position is healthy (fetches fresh oracle price)
function isIsolatedHealthy(bytes32 marketId, uint256 positionId)
    external view returns (bool);
```

---

## Integration Guide

### For Suppliers

```solidity
// 1. Ensure position has principal in the loan pool
// (deposit via PositionManagementFacet first)

// 2. Supply to a market
(uint256 assets, uint256 shares) = ilmFacet.isolatedSupply(
    marketId,
    1000e6,   // 1000 USDC
    0,        // specify assets, not shares
    positionId
);

// 3. Withdraw when ready (subject to liquidity)
(uint256 assets, uint256 shares) = ilmFacet.isolatedWithdraw(
    marketId,
    500e6,    // withdraw 500 USDC
    0,
    positionId
);
```

### For Borrowers

```solidity
// 1. Post collateral from the collateral pool
ilmFacet.isolatedSupplyCollateral(marketId, 1e18, positionId); // 1 WETH

// 2. Borrow from the loan pool
(uint256 assets, uint256 shares) = ilmFacet.isolatedBorrow(
    marketId,
    2000e6,   // borrow 2000 USDC
    0,
    positionId
);

// 3. Repay debt
(uint256 assets, uint256 shares) = ilmFacet.isolatedRepay(
    marketId,
    2000e6,   // repay 2000 USDC
    0,
    positionId
);

// 4. Withdraw collateral
ilmFacet.isolatedWithdrawCollateral(marketId, 1e18, positionId);
```

### For Liquidators

```solidity
// 1. Check if a position is liquidatable
bool healthy = viewFacet.isIsolatedHealthy(marketId, borrowerPositionId);

// 2. Liquidate (specify seized collateral amount)
(uint256 seized, uint256 repaid) = liquidationFacet.isolatedLiquidate(
    marketId,
    borrowerPositionId,
    5e17,     // seize 0.5 WETH of collateral
    0,        // let the contract compute repaid shares
    liquidatorPositionId
);

// 3. Or liquidate by specifying repaid shares
(uint256 seized, uint256 repaid) = liquidationFacet.isolatedLiquidate(
    marketId,
    borrowerPositionId,
    0,
    repaidShares,  // specify exact shares to repay
    liquidatorPositionId
);
```

### For Market Creators

```solidity
// 1. Governance enables IRM and LLTV
adminFacet.enableIrm(irmAddress);
adminFacet.enableLltv(0.86e18);  // 86% LLTV

// 2. Create market
bytes32 marketId = adminFacet.createIlmIsolatedMarket(
    IlmIsolatedMarketParams({
        loanPoolId: 1,
        collateralPoolId: 2,
        oracle: oracleAdapter,
        irm: irmAddress,
        lltv: 0.86e18
    }),
    moduleId
);

// 3. Set fees
adminFacet.setFee(marketId, 0.1e18);                    // 10% protocol interest fee
adminFacet.setMarketLiquidationFeeBps(marketId, 500);   // 5% liquidation fee
```

### Operator Delegation

Position owners can authorize operators to act on their behalf:

```solidity
adminFacet.setAuthorization(positionKey, operatorAddress, true);
```

Authorized operators can perform all core operations (supply, withdraw, borrow, repay, collateral, liquidate) on the position.

---

## Worked Examples

### Example 1: Basic Supply and Borrow

**Scenario:** Alice supplies 10,000 USDC. Bob posts 5 WETH as collateral and borrows USDC.

**Market Config:**
- Loan pool: USDC (pool 1)
- Collateral pool: WETH (pool 2)
- LLTV: 86% (0.86e18)
- Oracle price: 1 WETH = 2,000 USDC (price = 2000e36 in ORACLE_PRICE_SCALE)

**Alice Supplies:**
```
isolatedSupply(marketId, 10_000e6, 0, alicePositionId)

totalSupplyAssets: 0 → 10,000e6
totalSupplyShares: 0 → ~10,000e12 (via virtual share math)
Alice supplyShares: ~10,000e12
Alice's USDC pool principal encumbered: 10,000e6
```

**Bob Posts Collateral:**
```
isolatedSupplyCollateral(marketId, 5e18, bobPositionId)

Bob collateralAssets: 0 → 5e18
Bob's WETH pool principal encumbered: 5e18
```

**Bob Borrows:**
```
Collateral value: 5 × 2000 = 10,000 USDC
Max borrow: 10,000 × 86% = 8,600 USDC
Bob borrows: 8,000 USDC

isolatedBorrow(marketId, 8_000e6, 0, bobPositionId)

totalBorrowAssets: 0 → 8,000e6
Bob borrowShares: ~8,000e12
Bob's USDC pool principal credited: +8,000e6
```

**Health Check:**
```
borrowedAssets = 8,000e6
maxBorrow = 5e18 × 2000e36 / 1e36 × 0.86e18 / 1e18 = 8,600e6
8,600e6 ≥ 8,000e6 → healthy ✓
```

### Example 2: Interest Accrual and Fee Realization

**Scenario:** Continuing from Example 1, 30 days pass with the adaptive curve IRM.

**Interest Accrual (30 days later):**
```
Assume ratePerSecond ≈ 1.268e9 (~4% APY at target utilization)
elapsed = 30 × 86400 = 2,592,000 seconds
x = 1.268e9 × 2,592,000 = 3.286e15

Taylor approximation:
interestFactor = x + x²/2 + x³/6 ≈ 3.286e15

grossInterest = 8,000e6 × 3.286e15 / 1e18 ≈ 26.29e6 (~26.29 USDC)

Protocol fee (10%):
protocolFee = 26.29e6 × 0.1e18 / 1e18 ≈ 2.63e6

After accrual:
totalBorrowAssets: 8,000e6 → 8,026.29e6
totalSupplyAssets: 10,000e6 → 10,023.66e6 (interest minus protocol fee)
marketProtocolFeeAssets: +2.63e6
```

**Bob Repays 4,000 USDC:**
```
debtReduction = 4,000e6
borrowAssetsBefore = 8,026.29e6

Protocol fee realized:
realized = 2.63e6 × 4,000e6 / 8,026.29e6 ≈ 1.31e6
→ Routed via LibFeeRouter into loan pool fee distribution

After repay:
totalBorrowAssets: 8,026.29e6 → 4,026.29e6
marketProtocolFeeAssets: 2.63e6 → 1.32e6
```

### Example 3: Liquidation with Bad Debt

**Scenario:** WETH price drops sharply. Bob's position becomes unhealthy.

**Price Drop:**
```
New oracle price: 1 WETH = 1,500 USDC

Bob's state:
  collateralAssets: 5e18
  borrowShares → borrowedAssets ≈ 4,026.29e6

Health check:
  collateralValue = 5 × 1,500 = 7,500 USDC
  maxBorrow = 7,500 × 86% = 6,450 USDC
  6,450 ≥ 4,026.29 → still healthy ✓
```

**Further Price Drop:**
```
New oracle price: 1 WETH = 900 USDC

Health check:
  collateralValue = 5 × 900 = 4,500 USDC
  maxBorrow = 4,500 × 86% = 3,870 USDC
  3,870 < 4,026.29 → UNHEALTHY ✗
```

**Liquidation (liquidation fee = 5%):**
```
LIF at 86% LLTV:
  denom = 1e36 - 0.3e18 × (1e18 - 0.86e18) = 1e36 - 0.042e36 = 0.958e36
  LIF = 1e36 / 0.958e36 ≈ 1.0438e18 (~4.4% bonus)

Liquidator specifies: seize all 5e18 WETH collateral

seizedAssetsQuoted = 5e18 × 900e36 / 1e36 = 4,500e6 USDC-equivalent
repaidAssets = ceil(4,500e6 / 1.0438) ≈ 4,311e6

But Bob only owes ~4,026.29e6, so repaid is clamped to actual debt.

Gross seized collateral (proportional):
  seizedAssets = 4,026.29e6 × 1.0438 × 1e36 / 900e36 ≈ 4.67e18 WETH

Liquidation fee (5%):
  protocolFee = 4.67e18 × 500 / 10,000 = 0.2335e18 WETH
  netSeized = 4.67e18 - 0.2335e18 = 4.4365e18 WETH → liquidator

Remaining collateral: 5e18 - 4.67e18 = 0.33e18 WETH → stays with Bob
Bob's borrow shares → 0 (fully repaid by liquidator)
```

### Example 4: Bad Debt Socialization

**Scenario:** Extreme price crash leaves insufficient collateral.

```
Oracle price: 1 WETH = 500 USDC
Bob's collateral: 5e18 WETH = 2,500 USDC value
Bob's debt: 4,026.29 USDC

Liquidator seizes all 5e18 WETH collateral.
Repaid from collateral value: ~2,500 USDC (after LIF adjustment)
Remaining debt: 4,026.29 - 2,500 ≈ 1,526.29 USDC

Bob's collateral = 0, borrowShares > 0 → bad debt triggered

badDebtAssets = 1,526.29e6
totalBorrowAssets -= 1,526.29e6
totalSupplyAssets -= 1,526.29e6  // Alice absorbs the loss

Alice's shares now redeem for fewer assets:
  Before: 10,023.66e6 backing her shares
  After:  10,023.66e6 - 1,526.29e6 = 8,497.37e6
```

---

## Error Reference

### Market Errors

| Error | Cause |
|-------|-------|
| `IlmIsolatedMarketNotCreated(bytes32)` | Market ID does not exist |
| `IlmIsolatedMarketAlreadyCreated(bytes32)` | Market with same parameters already exists |

### Input Validation Errors

| Error | Cause |
|-------|-------|
| `IlmIsolatedInvalidInput()` | Zero input, both inputs non-zero, overflow, or zero oracle price |
| `IlmIsolatedZeroAddress()` | Zero address provided for owner |

### Access Control Errors

| Error | Cause |
|-------|-------|
| `IlmIsolatedUnauthorized()` | Caller is not position owner, authorized operator, or governance owner |

### Liquidity Errors

| Error | Cause |
|-------|-------|
| `IlmIsolatedInsufficientLiquidity(uint256, uint256)` | Borrow or withdrawal exceeds available supply |

### Position Safety Errors

| Error | Cause |
|-------|-------|
| `IlmIsolatedInsufficientCollateral()` | Post-operation health check fails |
| `IlmIsolatedHealthyPosition()` | Attempted liquidation on a healthy position |

### Governance Errors

| Error | Cause |
|-------|-------|
| `IlmIsolatedIrmNotEnabled(address)` | IRM not allowlisted |
| `IlmIsolatedLltvNotEnabled(uint256)` | LLTV not allowlisted or ≥ 1e18 |
| `IlmIsolatedFeeTooHigh(uint256, uint256)` | Protocol fee exceeds MAX_FEE (0.25e18) |
| `IlmIsolatedManagedLoanPoolRequired(uint256)` | Managed-only IRM used with non-managed pool |
| `IlmIsolatedManagedMarketCreatorUnauthorized(uint256, address, address)` | Caller is not pool manager or governance owner |
| `IlmIsolatedInvalidFeeBps(uint256)` | Liquidation fee BPS exceeds 10,000 |

### Oracle Errors

| Error | Cause |
|-------|-------|
| `IlmIsolatedOracleStale(uint256, uint256)` | Oracle price exceeds staleness threshold |

### Inherited Errors

| Error | Source | Cause |
|-------|--------|-------|
| `InsufficientUnencumberedPrincipal(uint256, uint256)` | Equalis core | Not enough free principal for supply/collateral/repay |
| `InsufficientPrincipal(uint256, uint256)` | Equalis core | Liquidation debit exceeds raw principal |
| `ModuleNotFound(uint256)` | Module registry | Invalid module ID |
| `ModulePausedError(uint256)` | Module registry | Module is paused |

---

## Events

### Admin Events

```solidity
event IlmIsolatedCreateMarket(
    bytes32 indexed marketId,
    uint256 indexed moduleId,
    IlmIsolatedMarketParams params
);

event IlmIsolatedEnableIrm(address indexed irm);
event IlmIsolatedEnableLltv(uint256 indexed lltv);
event IlmIsolatedSetFee(bytes32 indexed marketId, uint256 fee);
event IlmIsolatedSetFeeRecipientPositionKey(bytes32 indexed positionKey);
event IlmIsolatedSetMaxStaleness(uint256 maxStaleness);
event IlmIsolatedSetOwner(address indexed owner);
event IlmIsolatedSetIrmManagedOnly(address indexed irm, bool managedOnly);
event IlmIsolatedSetMarketLiquidationFeeBps(bytes32 indexed marketId, uint16 bps);

event IlmIsolatedSetAuthorization(
    bytes32 indexed positionKey,
    address indexed operator,
    bool authorized
);
```

### Core Operation Events

```solidity
event IlmIsolatedAccrueInterest(
    bytes32 indexed marketId,
    uint256 interest,
    uint256 protocolFeeAccrued
);

event IlmIsolatedSupply(
    bytes32 indexed marketId,
    bytes32 indexed positionKey,
    uint256 assets,
    uint256 shares
);

event IlmIsolatedWithdraw(
    bytes32 indexed marketId,
    bytes32 indexed positionKey,
    uint256 assets,
    uint256 shares
);

event IlmIsolatedSupplyCollateral(
    bytes32 indexed marketId,
    bytes32 indexed positionKey,
    uint256 assets
);

event IlmIsolatedWithdrawCollateral(
    bytes32 indexed marketId,
    bytes32 indexed positionKey,
    uint256 assets
);

event IlmIsolatedBorrow(
    bytes32 indexed marketId,
    bytes32 indexed positionKey,
    uint256 assets,
    uint256 shares
);

event IlmIsolatedRepay(
    bytes32 indexed marketId,
    bytes32 indexed positionKey,
    uint256 assets,
    uint256 shares
);
```

### Liquidation Events

```solidity
event IlmIsolatedLiquidate(
    bytes32 indexed marketId,
    bytes32 indexed borrowerKey,
    bytes32 indexed liquidatorKey,
    uint256 repaidAssets,
    uint256 repaidShares,
    uint256 seizedAssets,
    uint256 badDebtAssets,
    uint256 badDebtShares
);

event IlmIsolatedLiquidationRevenue(
    bytes32 indexed marketId,
    bytes32 indexed borrowerKey,
    bytes32 indexed liquidatorKey,
    uint256 grossSeizedAssets,
    uint256 protocolFeeAssets,
    uint256 netSeizedAssets
);
```

### IRM Events

```solidity
// Adaptive Curve IRM
event IlmAdaptiveCurveIrmBorrowRateUpdate(
    bytes32 indexed marketId,
    uint256 avgBorrowRate,
    int256 rateAtTarget
);
```

---

## Security Considerations

### 1. Market Isolation

Each market maintains independent `totalSupplyAssets`, `totalBorrowAssets`, and `marketProtocolFeeAssets`. Bad debt in one market reduces only that market's `totalSupplyAssets`. No cross-market contagion is possible.

### 2. Share Inflation Protection

Virtual shares (`VIRTUAL_SHARES = 1e6`) and virtual assets (`VIRTUAL_ASSETS = 1`) are added to all share/asset conversions. This prevents the classic ERC-4626 share inflation attack where a first depositor can manipulate the exchange rate.

### 3. Directional Rounding

All conversions use rounding that favors the protocol:

| Operation | Assets → Shares | Shares → Assets |
|-----------|----------------|-----------------|
| Supply | Down (fewer shares) | Up (more assets) |
| Withdraw | Up (more shares burned) | Down (fewer assets) |
| Borrow | Up (more shares owed) | Down (fewer assets received) |
| Repay | Down (fewer shares burned) | Up (more assets paid) |

This ensures the protocol never loses value through rounding.

### 4. Oracle Staleness

Every price-dependent operation enforces `maxStaleness`. If the oracle has not updated within the threshold, the operation reverts. This prevents liquidations or borrows based on stale prices.

### 5. Interest Accrual Atomicity

Interest is accrued at the start of every state-changing operation. The Taylor approximation (`x + x²/2 + x³/6`) provides sufficient precision for typical rate × time products while avoiding the gas cost of full exponentiation.

### 6. Reentrancy Protection

All state-changing functions in `ILMIsolatedFacet` and `ILMIsolatedLiquidationFacet` use the `nonReentrant` modifier from the shared reentrancy guard.

### 7. Access Control

| Function | Access |
|----------|--------|
| Market creation | Governance owner (or managed-pool manager for managed-only IRMs) |
| Enable IRM / LLTV | Governance owner only |
| Set fees, staleness, owner | Governance owner only |
| Supply, withdraw, borrow, repay, collateral | Position NFT owner or authorized operator |
| Liquidation (borrower side) | Anyone can be liquidated when unhealthy |
| Liquidation (liquidator side) | Must own or be authorized on the liquidator position |
| Set authorization | Position NFT owner only |

### 8. Adaptive IRM Caller Restriction

The `IlmAdaptiveCurveIrm` only allows its `protocolCaller` (the diamond contract) to invoke `borrowRate()`. This prevents external actors from manipulating the per-market `rateAtTarget` state.

### 9. Protocol Fee Claim Consistency

Protocol fee claims are realized proportionally on repayment and written down proportionally on bad debt. When `totalBorrowAssets` reaches zero, any residual claim is zeroed out to prevent phantom fee accumulation.

### 10. Encumbrance Integration

Supply and collateral operations flow through `LibModuleEncumbrance`, which ensures:
- Principal cannot be double-spent across modules
- Withdrawal from the underlying pool is blocked while principal is encumbered
- Active-credit-index participation is correctly tracked

### 11. Liquidation Incentive Bounds

The LIF is capped at `MAX_LIQUIDATION_INCENTIVE_FACTOR = 1.15e18` (15% bonus). This prevents excessive liquidator profit at low LLTVs while still providing sufficient incentive.

### 12. Bad Debt Write-Down

When bad debt occurs, the protocol fee claim is written down proportionally. This prevents the protocol from claiming fees on debt that will never be repaid.

### 13. Overflow Protection

All market state fields use `uint128`, and operations check for overflow before casting. The `lastUpdate` timestamp is also checked against `type(uint128).max`.

---

## Appendix: Correctness Properties

### Property 1: Market Uniqueness
For any two markets with different parameters:
```
deriveMarketId(paramsA) ≠ deriveMarketId(paramsB)
```

### Property 2: Share/Asset Monotonicity
For any market with `totalSupplyAssets > 0`:
```
toAssetsDown(toSharesDown(x, ...)) ≤ x
toSharesUp(toAssetsUp(x, ...)) ≥ x
```

### Property 3: Supply/Withdraw Conservation
For any supply followed by immediate withdraw of the same shares:
```
assetsWithdrawn ≤ assetsSupplied
```
(Rounding favors the protocol.)

### Property 4: Health Invariant
For any successful borrow or collateral withdrawal:
```
collateralAssets × oraclePrice / ORACLE_PRICE_SCALE × lltv / WAD ≥ borrowedAssets
```

### Property 5: Interest Monotonicity
After any interest accrual with `elapsed > 0` and `totalBorrowAssets > 0`:
```
newTotalBorrowAssets > oldTotalBorrowAssets
newTotalSupplyAssets ≥ oldTotalSupplyAssets
```

### Property 6: Protocol Fee Bound
For any interest accrual:
```
protocolFeeAccrued ≤ grossInterest × MAX_FEE / WAD
```

### Property 7: Liquidation Prerequisite
For any successful liquidation:
```
isHealthy(borrower) == false
```

### Property 8: LIF Bound
For any LLTV < WAD:
```
WAD ≤ computeLIF(lltv) ≤ MAX_LIQUIDATION_INCENTIVE_FACTOR
```

### Property 9: Bad Debt Isolation
For any bad debt event in market M:
```
∀ market N ≠ M: totalSupplyAssets_N unchanged
```

### Property 10: Encumbrance Consistency
For any position after supply or collateral posting:
```
moduleEncumbrance(positionKey, poolId, moduleId) ≤ userPrincipal(positionKey, poolId)
```

### Property 11: Fee Claim Conservation
For any repayment:
```
newProtocolFeeClaim = oldProtocolFeeClaim - realized
realized = oldProtocolFeeClaim × debtReduction / totalBorrowAssetsBefore
```

### Property 12: Staleness Enforcement
For any operation requiring oracle price:
```
block.timestamp - updatedAt ≤ maxStaleness
```

---

**Document Version:** 1.0
