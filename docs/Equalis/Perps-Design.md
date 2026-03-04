# Perpetual Futures (Perps) - Design Document

**Version:** 1.0

---

## Table of Contents

1. [Overview](#overview)
2. [How It Works](#how-it-works)
3. [Architecture](#architecture)
4. [Markets](#markets)
5. [Accounts & Positions](#accounts--positions)
6. [Trading Operations](#trading-operations)
7. [Funding Rate System](#funding-rate-system)
8. [Risk & Margin System](#risk--margin-system)
9. [Liquidation System](#liquidation-system)
10. [Fee System](#fee-system)
11. [Intent System (EIP-712)](#intent-system-eip-712)
12. [Domain Isolation](#domain-isolation)
13. [Data Models](#data-models)
14. [View Functions](#view-functions)
15. [Integration Guide](#integration-guide)
16. [Worked Examples](#worked-examples)
17. [Error Reference](#error-reference)
18. [Events](#events)
19. [Security Considerations](#security-considerations)

---

## Overview

Equalis Perps is an on-chain perpetual futures system that enables leveraged long and short exposure to any index asset, collateralized by deposits in an Equalis pool. The system follows a GMX-style isolated market model where each market pairs a collateral pool with an index asset, uses oracle-driven mark prices, and settles PnL in the collateral asset.

All positions are bound to Position NFTs via deterministic account IDs. The perps domain operates in strict isolation from the rest of the protocol, with dedicated accounting that prevents perps losses from leaking into non-perps pool balances.

### Key Characteristics

| Feature | Description |
|---------|-------------|
| **Perpetual Contracts** | No expiry; positions held indefinitely |
| **Isolated Markets** | Each market pairs one collateral pool with one index asset |
| **Oracle-Driven Pricing** | Mark price from pluggable oracle adapter with staleness/deviation checks |
| **Skew-Based Funding** | Continuous funding rate proportional to long/short imbalance |
| **Dual Margin Tiers** | Initial margin for opening, maintenance margin for liquidation |
| **Deterministic Liquidation** | Close factor based on equity severity; permissionless |
| **Insurance Fund** | Per-market insurance absorbs losses before bad debt socialization |
| **Intent-Based Execution** | EIP-712 signed intents for keeper/executor-driven order flow |
| **Domain Isolation** | Perps accounting is fully isolated from non-perps pool balances |
| **Position NFT Ownership** | All state tied to transferable ERC-721 tokens via subaccounts |

### System Participants

| Role | Description |
|------|-------------|
| **Trader** | Opens long/short positions via direct calls or signed intents |
| **Collateral Provider** | Deposits collateral into a perps account to back positions |
| **Liquidator** | Permissionlessly closes unhealthy positions for a reward |
| **Executor** | Submits signed intents on behalf of traders for a fee |
| **Governance** | Creates markets, sets risk/fee/oracle parameters, enables execution |
| **Sentinel (Oracle)** | External oracle adapter providing mark prices with freshness guarantees |

### Why This Design?

Traditional perps protocols face several challenges:
- **Liquidity fragmentation:** Separate contracts per market
- **Composability gaps:** Positions not portable or composable with other DeFi
- **Isolation failures:** Losses in one market can cascade

Equalis Perps addresses these by:
- **Diamond integration:** All markets share the same diamond, composable with lending, credit, and index systems
- **Position NFT binding:** Perps accounts are subaccounts of Position NFTs, enabling unified portfolio management
- **Strict domain isolation:** Perps PnL and fees are tracked in a dedicated accounting domain that cannot drain non-perps pool balances
- **Insurance-first loss absorption:** Per-market insurance funds absorb losses before bad debt is socialized

---

## How It Works

### The Core Model

1. **Create an account** bound to your Position NFT (with optional subaccount nonce)
2. **Add collateral** from the market's collateral pool into your perps account
3. **Open a position** (long or short) specifying size in USD, execution price, and slippage bounds
4. **Funding accrues** continuously based on long/short skew — longs pay shorts (or vice versa)
5. **Close or decrease** your position to realize PnL, which adjusts your collateral balance
6. **Remove collateral** to withdraw profits back to your Position NFT's pool principal

### PnL Calculation

Realized PnL on a decrease/close is computed as:

```
Long PnL  = sizeDelta × (exitPrice - entryPrice) / entryPrice
Short PnL = sizeDelta × (entryPrice - exitPrice) / entryPrice
```

All values are X18-scaled (1e18 precision). PnL is settled against the trader's collateral balance and the isolated domain's tracked balance.

### Equity and Health

A position's equity determines its health:

```
equity = collateral + unrealizedPnL - fundingAccrued - feesAccrued
```

The position must maintain equity above the maintenance margin requirement to avoid liquidation.

### Weighted Average Entry Price

When increasing an existing position, the entry price is updated as a size-weighted average:

```
newEntryPrice = (oldEntryPrice × oldSize + executionPrice × sizeDelta) / (oldSize + sizeDelta)
```

This ensures the position's PnL is always computed against a single blended entry price.

---

## Architecture

### Contract Structure

```
src/perps/
├── PerpsExecutionFacet.sol         # Account lifecycle, collateral, open/increase, decrease/close, intents
├── PerpsLiquidationFacet.sol       # Permissionless liquidation with waterfall loss handling
├── PerpsAdminFacet.sol             # Market creation, risk/fee/oracle config, genesis gating
├── PerpsViewFacet.sol              # Read-only health, settlement, fee audit, isolation proofs
│
├── LibPerpsStorage.sol             # Diamond storage layout and all data structures
├── LibPerpsRisk.sol                # Margin, health, leverage, OI/skew cap enforcement
├── LibPerpsFunding.sol             # Cumulative funding index updates and per-position settlement
├── LibPerpsFees.sol                # Trading fee split (LP/protocol), LP fee index, executor fees
├── LibPerpsDomain.sol              # Isolation accounting, non-perps backing invariant
├── LibPerpsOracle.sol              # Oracle adapter validation (staleness, deviation)
├── LibPerpsIntent.sol              # EIP-712 hashing, signature validation, nonce management
├── LibPerpsIdentity.sol            # Deterministic ID derivation (market, account, position)
├── LibPerpsSync.sol                # Idempotent market/account funding reconciliation
│
├── IPerpsOracleAdapter.sol         # Oracle adapter interface
└── PerpsErrors.sol                 # Custom error definitions
```

### High-Level Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Equalis Diamond                              │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  ┌────────────────┐  ┌────────────────┐  ┌────────────────────┐     │
│  │  Perps          │  │  Perps          │  │  Perps             │     │
│  │  Execution      │  │  Liquidation    │  │  Admin Facet       │     │
│  │  Facet          │  │  Facet          │  │  (governance)      │     │
│  └───────┬────────┘  └───────┬────────┘  └────────┬───────────┘     │
│          │                   │                    │                 │
│          └───────────────────┼────────────────────┘                 │
│                              │                                      │
│  ┌───────────────────────────┼──────────────────────────────┐       │
│  │                    Core Libraries                         │       │
│  │  LibPerpsStorage · LibPerpsRisk · LibPerpsFunding         │       │
│  │  LibPerpsFees · LibPerpsDomain · LibPerpsOracle           │       │
│  │  LibPerpsIntent · LibPerpsIdentity · LibPerpsSync         │       │
│  └───────────────────────────────────────────────────────────┘       │
│                              │                                      │
│  ┌───────────────────────────┼──────────────────────────────┐       │
│  │              Shared Protocol Libraries                     │       │
│  │  LibAppStorage · LibFeeRouter · LibPositionNFT            │       │
│  │  LibModuleEncumbrance · LibCurrency                       │       │
│  └───────────────────────────────────────────────────────────┘       │
│                                                                     │
├─────────────────────────────────────────────────────────────────────┤
│                     External Adapters                               │
│  ┌──────────────────────────┐                                       │
│  │  IPerpsOracleAdapter      │                                       │
│  │  (mark price + staleness) │                                       │
│  └──────────────────────────┘                                       │
└─────────────────────────────────────────────────────────────────────┘
         │                              │
         ▼                              ▼
   ┌──────────┐                  ┌──────────────────┐
   │ Position │                  │ Collateral Pools  │
   │   NFTs   │                  │ (isolated domain) │
   └──────────┘                  └──────────────────┘
```

### Genesis Configuration Gating

Markets cannot be used for trading until all six configuration categories are set:

| Bit | Category | Admin Function |
|-----|----------|---------------|
| 0 | Risk params | `setMarketRisk` |
| 1 | Caps | `setMarketCaps` |
| 2 | Oracle | `setOracleConfig` |
| 3 | Pause flags | `setPauseFlags` |
| 4 | Fee config | `setFeeConfig` |
| 5 | Insurance | `setInsuranceConfig` |

The `CONFIG_REQUIRED_MASK` (all 6 bits set) must be satisfied before `globalExecutionEnabled` or `globalLiquidationEnabled` can be turned on. This prevents trading on partially configured markets.

---

## Markets

### Market Configuration

Each market is defined by a collateral pool, collateral asset, and index asset:

```solidity
struct CreatePerpsMarketParams {
    uint256 collateralPoolId;       // Equalis pool backing collateral
    address collateralAsset;        // ERC-20 token for margin/settlement
    address indexAsset;             // Asset whose price the contract tracks
    bool longEnabled;               // Allow long positions
    bool shortEnabled;              // Allow short positions
}
```

### Market Identity

Market IDs are deterministically derived:

```solidity
marketId = keccak256(abi.encode(MARKET_ID_NAMESPACE, collateralPoolId, collateralAsset, indexAsset))
```

This ensures each unique (pool, collateral, index) triple maps to exactly one market.

### Risk Parameters

```solidity
struct MarketRiskParams {
    uint32 maxLeverageBps;              // Max leverage (e.g., 500_00 = 50x)
    uint32 initialMarginBps;            // Initial margin requirement (e.g., 1000 = 10%)
    uint32 maintenanceMarginBps;        // Maintenance margin (e.g., 500 = 5%)
    uint32 liquidationIncentiveBpsMax;  // Max liquidator reward (e.g., 100 = 1%)
}
```

**Validation rules:**
- `maintenanceMarginBps ≤ initialMarginBps`
- All values > 0 and ≤ 10,000
- `maxLeverageBps > 0`

### Capacity Caps

```solidity
struct MarketCapParams {
    uint256 maxOpenInterest;        // Total OI cap (0 = unlimited)
    uint256 maxLongOpenInterest;    // Long-side OI cap
    uint256 maxShortOpenInterest;   // Short-side OI cap
    uint256 maxSkewAbs;             // Max absolute skew (|longOI - shortOI|)
}
```

Per-side caps cannot exceed the total cap (when total cap is non-zero).

### Oracle Configuration

```solidity
struct OracleConfig {
    address oracleAdapter;      // IPerpsOracleAdapter implementation
    uint32 maxStaleness;        // Max seconds since last oracle update
    uint32 maxDeviationBps;     // Max execution-to-oracle price deviation
}
```

### Fee Configuration

```solidity
struct FeeConfig {
    uint32 takerFeeBps;                     // Trading fee on position size
    uint32 makerFeeBps;                     // Reserved for future maker rebates
    uint32 maxFundingVelocityBpsPerDay;     // Max funding rate velocity
}
```

### Pause Flags

Each market has independent pause controls:

| Flag | Effect |
|------|--------|
| `pauseIncrease` | Blocks opening/increasing positions |
| `pauseDecrease` | Blocks decreasing/closing positions and collateral removal |
| `pauseLiquidation` | Blocks liquidation calls |
| `pauseSync` | Blocks funding sync operations |

---

## Accounts & Positions

### Account Model

Perps accounts are subaccounts of Position NFTs. Each account is deterministically derived:

```solidity
accountId = keccak256(abi.encode(ACCOUNT_ID_NAMESPACE, positionKey, moduleNamespace, subaccountNonce))
```

A single Position NFT can have multiple perps accounts (via different `subaccountNonce` values), enabling isolated risk management across strategies.

### Account State

```solidity
struct PerpsAccount {
    bytes32 accountId;          // Deterministic ID
    bytes32 positionKey;        // Parent Position NFT key
    uint256 positionTokenId;    // Parent Position NFT token ID
    uint64 nonce;               // Sequential nonce for intent replay protection
    bool exists;                // Initialization flag
}
```

### Position State

Each account can hold one long and one short position per market:

```solidity
struct PerpsPosition {
    bool isLong;                // Direction
    uint256 sizeUsdX18;         // Notional size in USD (X18)
    uint256 collateralAmount;   // Snapshot of account collateral at last update
    uint256 entryPriceX18;      // Weighted average entry price (X18)
    int256 entryFundingX18;     // Funding index checkpoint at entry/last settlement
    int256 realizedPnlX18;      // Cumulative realized PnL (X18)
    uint64 lastIncreaseTs;      // Timestamp of last size increase
}
```

### Authorization

Account operations require authorization via the parent Position NFT:
- NFT owner
- Approved operator (`getApproved` / `isApprovedForAll`)
- Canonical ERC-6551 token-bound account (TBA)

For intent-based execution, the signer must be an authorized controller of the account.

---

## Trading Operations

### Add Collateral

```solidity
executionFacet.addCollateral(AddCollateralParams({
    marketId: marketId,
    accountId: accountId,
    collateralAsset: collateralAsset,
    amount: amount
}));
```

Transfers collateral from the position's pool principal into the perps account. The amount is reserved in the isolated domain and tracked as `reservedCollateral` on the market state.

### Remove Collateral

```solidity
uint256 totalOut = executionFacet.removeCollateral(RemoveCollateralParams({
    marketId: marketId,
    accountId: accountId,
    collateralAsset: collateralAsset,
    amount: amount
}));
```

Returns collateral to the position's pool principal. Also claims any settled LP fees. The market must not be decrease-paused.

### Open or Increase Position

```solidity
SettlementDelta memory delta = executionFacet.openOrIncrease(OpenIncreaseParams({
    marketId: marketId,
    accountId: accountId,
    isLong: true,
    sizeDeltaUsdX18: 10_000e18,     // $10,000 notional
    executionPriceX18: 2000e18,     // $2,000 per unit
    limitPriceX18: 2000e18,         // Limit price
    maxSlippageBps: 50,             // 0.5% slippage tolerance
    feePoolId: feePoolId,
    executorFee: 0
}));
```

**Flow:**
1. Validate market is active, not increase-paused, direction enabled
2. Validate execution price against oracle (staleness + deviation)
3. Enforce slippage bounds: `|executionPrice - limitPrice| ≤ limitPrice × maxSlippageBps / 10,000`
4. Update market funding indexes
5. Settle position's accumulated funding
6. Compute trading fee: `sizeDelta × takerFeeBps / 10,000`
7. Compute post-trade health (equity must meet initial margin)
8. Update open interest and enforce OI/skew caps
9. Update position: weighted average entry price, new size
10. Route trading fee (70% LP, 30% protocol)
11. Enforce domain isolation invariant

### Decrease or Close Position

```solidity
SettlementDelta memory delta = executionFacet.decreaseOrClose(DecreaseCloseParams({
    marketId: marketId,
    accountId: accountId,
    isLong: true,
    sizeDeltaUsdX18: 5_000e18,
    executionPriceX18: 2200e18,
    limitPriceX18: 2200e18,
    maxSlippageBps: 50,
    feePoolId: feePoolId,
    executorFee: 0
}));
```

**Flow:**
1. Validate market is active, not decrease-paused
2. Validate execution price against oracle
3. Enforce slippage bounds
4. Update market funding and settle position funding
5. Compute trading fee on the decreased size
6. Compute realized PnL: `sizeDelta × (exitPrice - entryPrice) / entryPrice`
7. Compute net payout: `realizedPnL - funding - fees`
8. Adjust isolated domain tracked balance (credit or debit)
9. Update open interest and skew
10. If full close (`nextSize = 0`), delete position; otherwise reduce size
11. Route trading fee and enforce isolation invariant

### Settlement Delta

Every trade emits a `SettlementDelta` struct capturing the full accounting breakdown:

```solidity
struct SettlementDelta {
    bytes32 marketId;
    bytes32 accountId;
    int256 collateralInOut;         // Net collateral change
    int256 realizedPnl;             // PnL realized on this trade
    int256 fundingPaid;             // Funding settled
    uint256 takerFee;               // Total trading fee
    uint256 lpFee;                  // LP share of trading fee
    uint256 protocolFee;            // Protocol share of trading fee
    uint256 executorFee;            // Executor/keeper reward
    uint256 liquidationProtocolFee; // Protocol fee from liquidation
    uint256 liquidatorReward;       // Liquidator incentive
    uint256 insuranceUsed;          // Insurance fund drawdown
    uint256 badDebtDelta;           // Bad debt socialized
}
```

---

## Funding Rate System

### Overview

Funding rates incentivize balance between long and short open interest. When longs exceed shorts (positive skew), longs pay shorts. When shorts exceed longs (negative skew), shorts pay longs.

### Funding Velocity Model

The funding rate is driven by a velocity model proportional to the market's skew:

```
skewRatio = clamp(skew / maxSkewAbs, -1, 1)
fundingVelocity = skewRatio × maxFundingVelocityBpsPerDay × 1e14
fundingDelta = fundingVelocity × elapsed / 1 day
```

Where:
- `skew = openInterestLong - openInterestShort`
- `maxSkewAbs` is the market's configured maximum absolute skew
- `maxFundingVelocityBpsPerDay` is the maximum daily funding rate in basis points
- `1e14` converts basis points to X18 scale

### Cumulative Funding Indexes

Two cumulative indexes track funding for each side:

```
cumulativeFundingLong  += fundingDelta
cumulativeFundingShort -= fundingDelta
```

When skew is positive (more longs), `fundingDelta > 0`:
- Long index increases → longs pay more
- Short index decreases → shorts receive

### Per-Position Settlement

When a position is touched (open, close, liquidation, sync), its funding is settled:

```
fundingPaid = positionSize × (currentFundingIndex - entryFundingIndex) / 1e18
```

The position's `entryFundingX18` is then updated to the current index.

### Funding Visualization

```
Funding Rate
    │
    │  longs pay ──────────────────── shorts pay
    │                    │
    │              ╱     │     ╲
    │            ╱       │       ╲
    │          ╱         │         ╲
    │        ╱           │           ╲
    │──────╱─────────────┼─────────────╲──────
    │    ╱               │               ╲
    │  ╱                 │                 ╲
    │╱                   │                   ╲
    └────────────────────┼────────────────────── Skew
              -maxSkew   0   +maxSkew
```

---

## Risk & Margin System

### Margin Requirements

Two margin tiers protect the system:

**Initial Margin (opening):**
```
initialMarginRequired = positionNotional × initialMarginBps / 10,000
```

**Maintenance Margin (liquidation threshold):**
```
maintenanceMarginRequired = positionNotional × maintenanceMarginBps / 10,000
```

**Leverage Floor:**
```
minEquityForLeverage = ceil(positionNotional × 10,000 / maxLeverageBps)
```

The opening margin requirement is the maximum of `initialMarginRequired` and `minEquityForLeverage`.

### Health Computation

```solidity
struct HealthResult {
    int256 equityUsdX18;                        // collateral + PnL - funding - fees
    uint256 initialMarginRequiredUsdX18;        // For opening
    uint256 maintenanceMarginRequiredUsdX18;    // For liquidation
    uint256 minEquityForLeverageUsdX18;         // Leverage cap floor
    uint256 openingMarginRequiredUsdX18;        // max(initial, leverage floor)
    uint256 leverageBps;                        // notional × 10,000 / equity
    int256 initialBufferUsdX18;                 // equity - openingMargin
    int256 maintenanceBufferUsdX18;             // equity - maintenanceMargin
    bool meetsInitialMargin;                    // initialBuffer ≥ 0
    bool meetsMaintenanceMargin;                // maintenanceBuffer ≥ 0
}
```

### Open Interest & Skew Caps

Every position change validates against market caps:

- `openInterestTotal ≤ maxOpenInterest` (if non-zero)
- `openInterestLong ≤ maxLongOpenInterest` (if non-zero)
- `openInterestShort ≤ maxShortOpenInterest` (if non-zero)
- `|skew| ≤ maxSkewAbs` (if non-zero)

---

## Liquidation System

### Liquidation Trigger

A position is liquidatable when it fails the maintenance margin check:

```
equity < maintenanceMarginRequired
```

Where equity accounts for unrealized PnL and accumulated funding.

### Liquidation Call

Anyone can liquidate an unhealthy position:

```solidity
(SettlementDelta memory delta, uint256 closeSizeUsdX18) = liquidationFacet.liquidate(LiquidationParams({
    marketId: marketId,
    accountId: accountId,
    isLong: true,
    executionPriceX18: markPrice,
    feePoolId: feePoolId
}));
```

### Close Factor

The close factor determines how much of the position is liquidated:

| Condition | Close Factor |
|-----------|-------------|
| `equity ≤ 0` | 100% (full liquidation) |
| `maintenanceBuffer ≤ -(maintenanceMargin / 2)` | 100% (severe undercollateralization) |
| Otherwise | 50% (partial liquidation) |

### Liquidation Waterfall

The liquidation proceeds through a priority waterfall:

**Step 1: Compute realized PnL**
```
realizedPnL = closeSizeUsdX18 × (exitPrice - entryPrice) / entryPrice
```

**Step 2: Compute liquidation protocol fee**
```
maxProtocolFee = closeSize × takerFeeBps / 10,000
available = max(0, collateral + realizedPnL)
protocolFee = min(maxProtocolFee, available)
```

**Step 3: Compute liquidator reward**
```
maxReward = closeSize × liquidationIncentiveBpsMax / 10,000
afterProtocol = collateral + realizedPnL - funding - protocolFee
reward = min(maxReward, max(0, afterProtocol))
```

**Step 4: Compute final account equity**
```
finalEquity = afterProtocol - liquidatorReward
```

**Step 5: Loss absorption waterfall**
```
if finalEquity < 0:
    deficit = |finalEquity|
    1. Consume remaining account collateral
    2. Draw from insurance fund: min(insuranceBalance, remaining deficit)
    3. Remaining deficit → bad debt (socialized)
```

### Protocol Fee Routing (Liquidation)

The liquidation protocol fee is routed with insurance priority:

1. Fill insurance fund up to its target gap
2. Overflow (if any) is split 70/30 (LP/protocol) via `LibPerpsFees.applyTradingFee`

### Liquidation Flow Diagram

```
Position fails maintenance margin
         │
         ▼
  Determine close factor (50% or 100%)
         │
         ▼
  Compute realized PnL on closed portion
         │
         ▼
  Deduct protocol fee (bounded by available equity)
         │
         ▼
  Deduct liquidator reward (bounded by remaining equity)
         │
         ▼
  Final equity ≥ 0? ──── Yes ──→ Update collateral, done
         │
         No
         │
         ▼
  Consume remaining collateral
         │
         ▼
  Draw from insurance fund
         │
         ▼
  Remaining deficit → bad debt
```

---

## Fee System

### Trading Fee Split

Trading fees are charged on position size changes (open, increase, decrease, close):

```
tradingFee = sizeDeltaUsdX18 × takerFeeBps / 10,000
```

The fee is split into two components:

| Recipient | Share | Mechanism |
|-----------|-------|-----------|
| LP (collateral providers) | 70% | Distributed via per-market LP fee index |
| Protocol | 30% | Routed to global fee rails via `LibFeeRouter` |

### LP Fee Index

LP fees are distributed proportionally to collateral providers via a cumulative index:

```solidity
deltaIndex = distributableFees × 1e18 / totalReservedCollateral
lpFeeIndexX18 += deltaIndex
```

Each account tracks its checkpoint:

```solidity
newlyAccrued = collateralShares × (globalIndex - accountIndex) / 1e18
accountLpFeesAccrued += newlyAccrued
accountLpFeeIndexX18 = globalIndex
```

LP fees are settled on every collateral mutation and can be claimed via `withdrawLpFees` or `removeCollateral`.

If `totalReservedCollateral = 0` when fees arrive, they are buffered in `marketPendingLpFees` and distributed when collateral is next deposited.

### Protocol Fee Routing

Protocol fees are routed from the isolated perps domain to the global fee rails:

1. Debit from `isolatedTrackedBalance` via `LibPerpsDomain.routeOutboundFeeCredit`
2. Credit to the fee pool's `trackedBalance`
3. Route via `LibFeeRouter.routeManagedShare` (treasury, active credit index, fee index)

### Executor Fees

Executors who submit signed intents on behalf of traders receive a fee:

```
executorFee ≤ intent.maxExecutorFee (signer-approved cap)
```

Executor fees are paid from the isolated perps domain balance.

### Fee Source Summary

| Source | Trigger | Split |
|--------|---------|-------|
| Trading fee | Open/Increase/Decrease/Close | 70% LP, 30% protocol |
| Liquidation protocol fee | Liquidation | Insurance-first, overflow 70/30 |
| Executor fee | Intent execution | Paid to executor from domain |
| Liquidator reward | Liquidation | Paid to liquidator from domain |

---

## Intent System (EIP-712)

### Overview

The intent system enables gasless, keeper-executed trading via EIP-712 typed structured data signatures. Traders sign intents off-chain; executors submit them on-chain for a fee.

### Intent Structure

```solidity
struct PerpsIntent {
    bytes32 marketId;           // Target market
    bytes32 accountId;          // Trader's account
    uint8 action;               // 1 = open/increase, 2 = decrease/close
    bool isLong;                // Position direction
    uint256 sizeDeltaUsdX18;    // Size change
    int256 collateralDelta;     // Reserved (must be 0 for current actions)
    uint256 limitPriceX18;      // Limit price for slippage check
    uint256 maxSlippageBps;     // Max slippage tolerance
    uint256 maxExecutorFee;     // Max fee the signer approves for the executor
    uint64 nonce;               // Sequential nonce for replay protection
    uint64 deadline;            // Expiry timestamp
}
```

### EIP-712 Domain

```solidity
EIP712Domain(
    name: "EqualisPerps",
    version: "1",
    chainId: block.chainid,
    verifyingContract: address(this),
    salt: keccak256("equalis.perps.gmxstyle.module.v1")
)
```

### Execution Flow

```solidity
SettlementDelta memory delta = executionFacet.executeIntent(intent, execParams, signature);
```

1. Validate intent fields (non-zero market, account, size)
2. Verify EIP-712 signature against the signer
3. Verify signer is an authorized controller of the account
4. Check intent is not canceled and not expired
5. Validate nonce matches account's current nonce and is above `minValidNonce`
6. Execute the trade (open/increase or decrease/close)
7. Consume the nonce (increment account nonce)

### Replay Protection

**Sequential nonces:** Each account maintains a monotonically increasing nonce. Intents must match the current nonce exactly.

**Intent cancellation:** Individual intents can be canceled by hash:
```solidity
executionFacet.cancelIntent(accountId, intentHash);
```

**Bulk nonce invalidation:** All intents with nonces below a threshold can be invalidated:
```solidity
executionFacet.invalidateNoncesUpTo(accountId, nonceUpperBound);
```

This advances both `minValidNonce` and the account's current nonce (if behind).

---

## Domain Isolation

### Isolation Accounting

The perps system maintains a dedicated accounting domain (`PerpsDomainState`) that is strictly isolated from non-perps pool balances:

```solidity
struct PerpsDomainState {
    uint256 isolatedTrackedBalance;     // Total collateral backing perps positions
    uint256 isolatedLiabilities;        // Total obligations of the perps domain
    uint256 isolatedEncumbered;         // Collateral locked by active accounts
}
```

### Non-Perps Backing Invariant

Every mutating perps operation enforces a critical invariant:

```
nonPerpsTrackedTotal(after) ≥ nonPerpsTrackedTotal(before)
observedIncrease = nonPerpsTrackedTotal(after) - nonPerpsTrackedTotal(before)
observedIncrease == explicitOutboundCredit
```

This means:
- Non-perps pool balances can never decrease due to perps operations
- Any increase must exactly equal explicit outbound fee credits (protocol fees routed to global rails)
- Perps PnL, funding, and liquidation losses are contained within the isolated domain

### Domain Solvency Guard

After liquidations and collateral removals, the system verifies:

```
isolatedTrackedBalance + insuranceBalance + badDebtRecorded ≥ isolatedLiabilities
```

This ensures the perps domain remains solvent (accounting for insurance and recognized bad debt).

### Isolation Proof (View)

The `proveIsolationInvariant` view function provides a verifiable proof of isolation:

```solidity
IsolationProof memory proof = viewFacet.proveIsolationInvariant(marketId);
// proof.marketSolvent: per-market solvency
// proof.globalSolvent: cross-market solvency
```

---

## Data Models

### Storage Layout (LibPerpsStorage.Layout)

```solidity
struct Layout {
    // Market registry
    mapping(bytes32 => PerpsMarket) markets;                    // Market config by ID
    mapping(bytes32 => PerpsMarketState) marketState;           // Market runtime state
    mapping(bytes32 => uint8) marketConfigMask;                 // Genesis config bitmask
    mapping(uint256 => bytes32) marketIds;                      // Index → market ID
    uint256 marketCount;                                        // Total markets created

    // Account registry
    mapping(bytes32 => PerpsAccount) accounts;                  // Account state by ID
    uint256 accountCount;                                       // Total accounts created

    // Per-account per-market state
    mapping(bytes32 => mapping(bytes32 => uint256)) accountCollateral;      // Collateral balances
    mapping(bytes32 => mapping(bytes32 => uint256)) accountLpFeeIndexX18;   // LP fee checkpoints
    mapping(bytes32 => mapping(bytes32 => uint256)) accountLpFeesAccrued;   // Settled LP fees

    // Positions: market → account → isLong → position
    mapping(bytes32 => mapping(bytes32 => mapping(bool => PerpsPosition))) positions;

    // LP fee buffering
    mapping(bytes32 => uint256) marketPendingLpFees;            // Undistributed LP fees

    // Intent replay protection
    mapping(bytes32 => bool) canceledIntents;                   // Canceled intent hashes
    mapping(bytes32 => uint64) minValidNonce;                   // Per-account nonce floor

    // Domain isolation
    PerpsDomainState domainState;                               // Isolated accounting

    // Global flags
    bool globalExecutionEnabled;                                // Master execution switch
    bool globalLiquidationEnabled;                              // Master liquidation switch
}
```

### Market State (PerpsMarketState)

```solidity
struct PerpsMarketState {
    uint256 openInterestLong;               // Total long OI in USD (X18)
    uint256 openInterestShort;              // Total short OI in USD (X18)
    int256 skew;                            // longOI - shortOI

    // Funding
    int256 cumulativeFundingLongX18;        // Cumulative long funding index
    int256 cumulativeFundingShortX18;       // Cumulative short funding index
    uint64 lastFundingTs;                   // Last funding update timestamp

    // Insurance
    uint256 insuranceBalance;               // Current insurance fund balance
    uint256 insuranceTarget;                // Target insurance fund level

    // Loss tracking
    uint256 badDebt;                        // Cumulative socialized bad debt

    // Fee accounting
    uint256 lpFeeIndexX18;                  // Cumulative LP fee index
    uint256 protocolFeesAccrued;            // Total protocol fees routed

    // Collateral tracking
    uint256 reservedCollateral;             // Total collateral across all accounts

    // PnL tracking
    uint256 realizedPnlOut;                 // Cumulative positive PnL paid out
    uint256 realizedPnlIn;                  // Cumulative negative PnL received
}
```

### Constants

```solidity
uint256 constant RAY = 1e27;
uint256 constant WAD = 1e18;                                // X18 precision
uint256 constant BPS = 10_000;                              // Basis points denominator
uint256 constant HF_PRECISION = 1e18;                       // Health factor precision
uint256 constant CLOSE_FACTOR_HF_THRESHOLD = 95e16;         // 0.95 — full close below this
uint16 constant DEFAULT_CLOSE_FACTOR_BPS = 5_000;           // 50% partial close
uint256 constant SECONDS_PER_YEAR = 365 days;
uint256 constant LP_SHARE_BPS = 7_000;                      // 70% LP fee share
uint256 constant PROTOCOL_SHARE_BPS = 3_000;                // 30% protocol fee share
```

---

## View Functions

### Market Queries

```solidity
// Get full market configuration
function getMarket(bytes32 marketId) external view returns (PerpsMarket memory);

// Get market runtime state (OI, skew, funding, insurance, fees)
function getMarketState(bytes32 marketId) external view returns (PerpsMarketState memory);

// Get comprehensive settlement summary including domain isolation state
function getSettlementSummary(bytes32 marketId) external view returns (SettlementSummary memory);

// Get fee routing audit trail
function getFeeRoutingAudit(bytes32 marketId) external view returns (FeeRoutingAudit memory);

// Prove isolation invariant holds
function proveIsolationInvariant(bytes32 marketId) external view returns (IsolationProof memory);
```

### Account & Position Queries

```solidity
// Get account state
function getPerpsAccount(bytes32 accountId) external view returns (PerpsAccount memory);

// Get position state
function getPerpsPosition(bytes32 marketId, bytes32 accountId, bool isLong)
    external view returns (PerpsPosition memory);

// Get account collateral balance
function getPerpsAccountCollateral(bytes32 marketId, bytes32 accountId) external view returns (uint256);

// Get LP fee state (accrued, pending, total claimable)
function getPerpsAccountLpFeeState(bytes32 marketId, bytes32 accountId)
    external view returns (AccountLpFeeState memory);
```

### Health & Risk Queries

```solidity
// Preview current health using live oracle mark price
function previewHealth(bytes32 marketId, bytes32 accountId)
    external view returns (HealthResult memory health, HealthState memory state, uint256 markPriceX18);

// Preview health after hypothetical delta (what-if analysis)
function previewDelta(PreviewParams calldata p) external view returns (PreviewResult memory);
```

The `previewDelta` function is particularly useful for frontends to simulate trades before submission, showing the impact on margin, leverage, and liquidation distance.

### Admin Queries

```solidity
// Get global execution/liquidation flags
function getGlobalConfig() external view returns (GlobalPerpsConfig memory);

// Get genesis configuration bitmask for a market
function getMarketConfigMask(bytes32 marketId) external view returns (uint8);

// Check if a market is fully configured and execution-enabled
function isMarketExecutionEnabled(bytes32 marketId) external view returns (bool);

// Check if a market is fully configured and liquidation-enabled
function isMarketLiquidationEnabled(bytes32 marketId) external view returns (bool);
```

---

## Integration Guide

### For Developers

#### Setting Up a Perps Account

```solidity
// 1. Mint a Position NFT and deposit collateral into the collateral pool
uint256 positionId = positionFacet.mintPositionWithDeposit(collateralPoolId, depositAmount, maxAmount, maxFee);

// 2. Create a perps account bound to the Position NFT
bytes32 accountId = executionFacet.createAccount(positionId, 0); // subaccountNonce = 0

// 3. Add collateral from the pool into the perps account
executionFacet.addCollateral(AddCollateralParams({
    marketId: marketId,
    accountId: accountId,
    collateralAsset: collateralAsset,
    amount: collateralAmount
}));
```

#### Opening a Long Position

```solidity
// 4. Open a 10x leveraged long
uint256 collateral = 1_000e18;  // $1,000 collateral
uint256 size = 10_000e18;       // $10,000 notional (10x leverage)

SettlementDelta memory delta = executionFacet.openOrIncrease(OpenIncreaseParams({
    marketId: marketId,
    accountId: accountId,
    isLong: true,
    sizeDeltaUsdX18: size,
    executionPriceX18: oraclePrice,
    limitPriceX18: oraclePrice,
    maxSlippageBps: 50,         // 0.5% slippage
    feePoolId: feePoolId,
    executorFee: 0
}));
```

#### Monitoring Position Health

```solidity
// 5. Check health factor
(LibPerpsRisk.HealthResult memory health, , uint256 markPrice) =
    viewFacet.previewHealth(marketId, accountId);

// health.equityUsdX18          → current equity
// health.leverageBps           → current leverage in bps
// health.maintenanceBufferUsdX18 → distance to liquidation
// health.meetsMaintenanceMargin → true if healthy
```

#### Closing and Withdrawing

```solidity
// 6. Close the position
executionFacet.decreaseOrClose(DecreaseCloseParams({
    marketId: marketId,
    accountId: accountId,
    isLong: true,
    sizeDeltaUsdX18: position.sizeUsdX18,  // full close
    executionPriceX18: currentPrice,
    limitPriceX18: currentPrice,
    maxSlippageBps: 50,
    feePoolId: feePoolId,
    executorFee: 0
}));

// 7. Remove collateral (includes LP fee claim)
uint256 totalOut = executionFacet.removeCollateral(RemoveCollateralParams({
    marketId: marketId,
    accountId: accountId,
    collateralAsset: collateralAsset,
    amount: accountCollateral
}));
```

#### Intent-Based Trading (Keeper Flow)

```solidity
// Trader signs an intent off-chain
PerpsIntent memory intent = PerpsIntent({
    marketId: marketId,
    accountId: accountId,
    action: 1,                  // open/increase
    isLong: true,
    sizeDeltaUsdX18: 5_000e18,
    collateralDelta: 0,
    limitPriceX18: 2000e18,
    maxSlippageBps: 100,        // 1%
    maxExecutorFee: 1e18,       // max $1 executor fee
    nonce: currentNonce,
    deadline: block.timestamp + 300  // 5 min expiry
});

bytes32 digest = executionFacet.intentDigest(intent);
bytes memory signature = sign(traderPrivateKey, digest);

// Executor submits on-chain
SettlementDelta memory delta = executionFacet.executeIntent(
    intent,
    IntentExecutionParams({
        signer: traderAddress,
        executionPriceX18: currentOraclePrice,
        feePoolId: feePoolId,
        executorFee: 0.5e18     // $0.50 executor fee (within signer cap)
    }),
    signature
);
```

#### Building a Liquidation Bot

```solidity
// 1. Monitor position health
(LibPerpsRisk.HealthResult memory health, , uint256 markPrice) =
    viewFacet.previewHealth(marketId, accountId);

// 2. If unhealthy, liquidate
if (!health.meetsMaintenanceMargin) {
    (SettlementDelta memory delta, uint256 closedSize) = liquidationFacet.liquidate(
        LiquidationParams({
            marketId: marketId,
            accountId: accountId,
            isLong: true,
            executionPriceX18: markPrice,
            feePoolId: feePoolId
        })
    );
    // delta.liquidatorReward → profit for the liquidator
}
```

### For Users

#### Opening a Leveraged Position

1. Deposit assets into the collateral pool via your Position NFT
2. Create a perps account (one-time per Position NFT per subaccount)
3. Add collateral from the pool into your perps account
4. Open a long or short position with your desired leverage
5. Monitor your health factor — if it drops below maintenance margin, you can be liquidated

#### Managing Risk

- Keep leverage well below the maximum to maintain a healthy margin buffer
- Monitor funding rates — being on the majority side costs funding
- Use limit prices and slippage bounds to protect against adverse execution
- Consider using multiple subaccounts to isolate risk across strategies
- Sync your account periodically to settle funding and keep state current

#### Closing a Position

1. Decrease or fully close your position
2. Realized PnL adjusts your collateral balance
3. Remove collateral to withdraw profits (also claims LP fees)
4. Account remains active for future trades

---

## Worked Examples

### Example 1: Basic Long Trade

**Scenario:** Alice opens a 10x long ETH position with $1,000 collateral.

**Setup:**
```
Market: ETH/USDC (collateral = USDC, index = ETH)
initialMarginBps: 1000 (10%)
maintenanceMarginBps: 500 (5%)
maxLeverageBps: 100_000 (100x)
takerFeeBps: 10 (0.1%)
ETH price: $2,000
```

**Step 1: Open Position**
```
Collateral: $1,000 USDC
Size: $10,000 (10x leverage)
Entry price: $2,000
Trading fee: $10,000 × 0.1% = $10

Initial margin required: $10,000 × 10% = $1,000
Equity after fees: $1,000 - $10 = $990
Meets initial margin? $990 ≥ $1,000? No — reverts!

Alice adds $20 more collateral first, then opens:
Equity after fees: $1,020 - $10 = $1,010
Meets initial margin? $1,010 ≥ $1,000? Yes ✓
Leverage: $10,000 / $1,010 = 9.9x
```

**Step 2: Price Moves to $2,200 (+10%)**
```
Unrealized PnL: $10,000 × ($2,200 - $2,000) / $2,000 = $1,000
Equity: $1,010 + $1,000 = $2,010
Leverage: $10,000 / $2,010 = 4.97x
Maintenance buffer: $2,010 - ($10,000 × 5%) = $2,010 - $500 = $1,510 ✓
```

**Step 3: Close Position**
```
Realized PnL: +$1,000
Trading fee: $10,000 × 0.1% = $10
Net payout: $1,000 - $10 = $990 credited to collateral
Final collateral: $1,010 + $990 = $2,000 (before funding)
```

### Example 2: Funding Rate Impact

**Scenario:** Bob holds a long position while the market is skewed long.

**Setup:**
```
openInterestLong: $5,000,000
openInterestShort: $3,000,000
skew: +$2,000,000
maxSkewAbs: $10,000,000
maxFundingVelocityBpsPerDay: 100 (1% per day max)
Bob's position: $50,000 long
```

**Funding Computation (1 hour elapsed):**
```
skewRatio = $2,000,000 / $10,000,000 = 0.2
fundingVelocity = 0.2 × 100 × 1e14 = 2e15 per day
fundingDelta = 2e15 × 3600 / 86400 = 8.33e13

cumulativeFundingLong += 8.33e13
cumulativeFundingShort -= 8.33e13
```

**Bob's Funding Settlement:**
```
fundingPaid = $50,000 × 8.33e13 / 1e18 = $0.00417
```

Bob pays ~$0.004 per hour in funding. Over 24 hours: ~$0.10/day on a $50k position.

### Example 3: Liquidation with Insurance

**Scenario:** Carol's short position becomes undercollateralized after a price spike.

**Setup:**
```
Carol's collateral: $500
Carol's short size: $5,000 (10x leverage)
Entry price: $2,000
maintenanceMarginBps: 500 (5%)
liquidationIncentiveBpsMax: 100 (1%)
takerFeeBps: 10 (0.1%)
Insurance balance: $1,000
```

**Price Spikes to $2,200:**
```
Unrealized PnL: $5,000 × ($2,000 - $2,200) / $2,000 = -$500
Equity: $500 + (-$500) = $0
Maintenance margin: $5,000 × 5% = $250
Meets maintenance? $0 ≥ $250? No → Liquidatable

Equity ≤ 0 → close factor = 100% (full liquidation)
Close size: $5,000
```

**Liquidation Waterfall:**
```
Realized PnL: -$500
Protocol fee: min($5,000 × 0.1%, max(0, $500 + (-$500))) = min($5, $0) = $0
Liquidator reward: min($5,000 × 1%, max(0, $0 - $0)) = min($50, $0) = $0
Final equity: $500 + (-$500) - $0 - $0 = $0

No deficit → no insurance draw, no bad debt
Carol's collateral: $0
Position: deleted
```

### Example 4: Bad Debt Scenario

**Scenario:** Dave's position gaps through his collateral.

**Setup:**
```
Dave's collateral: $200
Dave's long size: $10,000 (50x leverage)
Entry price: $2,000
Insurance balance: $500
```

**Price Crashes to $1,950 (-2.5%):**
```
Unrealized PnL: $10,000 × ($1,950 - $2,000) / $2,000 = -$250
Equity: $200 + (-$250) = -$50
Maintenance margin: $10,000 × 5% = $500
Equity ≤ 0 → full liquidation

Realized PnL: -$250
Protocol fee: min($10, max(0, $200 - $250)) = $0
Liquidator reward: $0
Final equity: $200 - $250 = -$50

Deficit: $50
  1. Consume remaining collateral: $200 → deficit remains $50 - $200 = ... 
     Actually: collateral consumed = min($200, $50) = $50
     Remaining collateral: $150
     Wait — let's recalculate:
     
     finalEquity = $200 + (-$250) - $0 - $0 = -$50
     deficit = $50
     collateralConsumed = min($200, $50) = $50
     accountCollateral = $200 - $50 = $150
     deficit = $50 - $50 = $0
     
No bad debt in this case. Carol keeps $150.
```

**Worse scenario — price crashes to $1,900 (-5%):**
```
Realized PnL: $10,000 × ($1,900 - $2,000) / $2,000 = -$500
Final equity: $200 + (-$500) = -$300
Deficit: $300
  1. Consume collateral: min($200, $300) = $200 → deficit = $100
  2. Insurance: min($500, $100) = $100 → deficit = $0
  
Insurance balance: $500 - $100 = $400
Dave's collateral: $0
Bad debt: $0 (insurance covered it)
```

**Even worse — price crashes to $1,700 (-15%):**
```
Realized PnL: -$1,500
Final equity: $200 + (-$1,500) = -$1,300
Deficit: $1,300
  1. Consume collateral: $200 → deficit = $1,100
  2. Insurance: min($500, $1,100) = $500 → deficit = $600
  3. Bad debt: $600

Insurance balance: $0
Bad debt: $600 (socialized)
```

---

## Error Reference

### Market Errors

| Error | Cause |
|-------|-------|
| `Perps_MarketNotFound(bytes32)` | Market ID does not exist |
| `Perps_MarketAlreadyExists(bytes32)` | Attempted to create a duplicate market |
| `Perps_GenesisConfigIncomplete(bytes32, uint8, uint8)` | Market missing required config categories |

### Account Errors

| Error | Cause |
|-------|-------|
| `Perps_AccountNotFound(bytes32)` | Account ID does not exist |
| `Perps_Unauthorized(bytes32, address)` | Caller is not authorized for the account |

### Intent Errors

| Error | Cause |
|-------|-------|
| `Perps_InvalidIntent()` | Malformed intent (zero fields, max nonce) |
| `Perps_IntentCanceled(bytes32)` | Intent has been explicitly canceled |
| `Perps_IntentExpired(uint64, uint64)` | Intent deadline has passed |
| `Perps_BadSignature()` | EIP-712 signature verification failed |
| `Perps_NonceMismatch(uint64, uint64)` | Intent nonce doesn't match account's current nonce |
| `Perps_NonceInvalidated(uint64, uint64)` | Intent nonce is below the minimum valid nonce |

### Oracle Errors

| Error | Cause |
|-------|-------|
| `Perps_PriceStale(uint256, uint256)` | Oracle price exceeds max staleness |
| `Perps_PriceOutOfBounds()` | Zero price, zero oracle adapter, or execution-to-oracle deviation too large |

### Risk Errors

| Error | Cause |
|-------|-------|
| `Perps_RiskLimitExceeded()` | Generic risk violation (OI cap, skew cap, invalid params, slippage, leverage) |
| `Perps_InsufficientMargin(uint256, uint256)` | Equity below required margin (initial or maintenance) |
| `Perps_InsufficientPerpsLiquidity(uint256, uint256)` | Insufficient isolated domain balance or collateral |
| `Perps_PositionHealthy()` | Attempted liquidation on a healthy position |

### Pause Errors

| Error | Cause |
|-------|-------|
| `Perps_IncreasePaused(bytes32)` | Market increase operations are paused |
| `Perps_DecreasePaused(bytes32)` | Market decrease operations are paused |
| `Perps_LiquidationPaused(bytes32)` | Market liquidation is paused |
| `Perps_SyncPaused(bytes32)` | Market sync operations are paused |

### Governance Errors

| Error | Cause |
|-------|-------|
| `Perps_NotGovernance(address)` | Caller is neither diamond owner nor timelock |

### Isolation Errors

| Error | Cause |
|-------|-------|
| `Perps_IsolationViolation()` | Non-perps backing invariant violated or domain insolvency detected |

---

## Events

### Account & Collateral Events

```solidity
event PerpsAccountCreated(
    bytes32 indexed accountId,
    bytes32 indexed positionKey,
    uint256 indexed positionTokenId
);

event PerpsCollateralAdded(
    bytes32 indexed marketId,
    bytes32 indexed accountId,
    address collateralAsset,
    uint256 amount
);

event PerpsCollateralRemoved(
    bytes32 indexed marketId,
    bytes32 indexed accountId,
    address collateralAsset,
    uint256 amount
);

event PerpsLpFeesClaimed(
    bytes32 indexed marketId,
    bytes32 indexed accountId,
    uint256 feeAmount
);
```

### Trading Events

```solidity
event PositionIncreased(
    bytes32 indexed marketId,
    bytes32 indexed accountId,
    bool isLong,
    uint256 sizeDeltaUsdX18
);

event PositionDecreased(
    bytes32 indexed marketId,
    bytes32 indexed accountId,
    bool isLong,
    uint256 sizeDeltaUsdX18
);

event PositionClosed(
    bytes32 indexed marketId,
    bytes32 indexed accountId,
    bool isLong
);

event SettlementDeltaEmitted(
    bytes32 indexed marketId,
    bytes32 indexed accountId,
    LibPerpsStorage.SettlementDelta delta
);
```

### Intent Events

```solidity
event PerpsIntentExecuted(
    bytes32 indexed marketId,
    bytes32 indexed accountId,
    uint8 action,
    address executor
);

event PerpsIntentCanceled(
    bytes32 indexed accountId,
    bytes32 indexed intentHash,
    address caller
);

event PerpsNonceInvalidated(
    bytes32 indexed accountId,
    uint64 previousMinNonce,
    uint64 newMinNonce,
    address caller
);
```

### Liquidation Events

```solidity
event PositionLiquidated(
    bytes32 indexed marketId,
    bytes32 indexed accountId,
    address liquidator,
    uint256 closeSizeUsdX18
);
```

### Sync Events

```solidity
event AccountSynced(
    bytes32 indexed marketId,
    bytes32 indexed accountId
);

event MarketSynced(
    bytes32 indexed marketId
);
```

### Admin Events

```solidity
event PerpsMarketCreated(
    bytes32 indexed marketId,
    uint256 collateralPoolId,
    address collateralAsset,
    address indexAsset
);

event PerpsMarketRiskUpdated(bytes32 indexed marketId, MarketRiskParams previousConfig, MarketRiskParams newConfig);
event PerpsMarketCapsUpdated(bytes32 indexed marketId, MarketCapParams previousConfig, MarketCapParams newConfig);
event PerpsOracleConfigUpdated(bytes32 indexed marketId, OracleConfig previousConfig, OracleConfig newConfig);
event PerpsPauseFlagsUpdated(bytes32 indexed marketId, PauseFlags previousFlags, PauseFlags newFlags);
event PerpsFeeConfigUpdated(bytes32 indexed marketId, FeeConfig previousConfig, FeeConfig newConfig);
event PerpsInsuranceConfigUpdated(bytes32 indexed marketId, InsuranceConfig previousConfig, InsuranceConfig newConfig);
event PerpsGlobalConfigUpdated(GlobalPerpsConfig previousConfig, GlobalPerpsConfig newConfig);
```

---

## Security Considerations

### 1. Oracle Dependency

All trading, liquidation, and health computations depend on the oracle adapter:

```solidity
interface IPerpsOracleAdapter {
    function getMarkPrice(bytes32 marketId, address indexAsset)
        external view returns (uint256 priceX18, uint256 updatedAt, uint256 deviationOrConfidenceBps);
}
```

**Protections:**
- Staleness check: `block.timestamp - updatedAt ≤ maxStaleness`
- Deviation check: adapter-reported confidence must be within `maxDeviationBps`
- Execution deviation: `|executionPrice - oraclePrice| / oraclePrice ≤ maxDeviationBps`
- Zero price reverts all operations

### 2. Domain Isolation

The perps system operates in a strictly isolated accounting domain:

- `isolatedTrackedBalance` tracks all collateral backing perps positions
- Non-perps pool `trackedBalance` can never decrease due to perps operations
- Any increase in non-perps balances must exactly equal explicit outbound fee credits
- Domain solvency is verified after every liquidation and collateral removal

This is the strongest security property of the system: perps losses cannot drain lending pools, credit pools, or any other non-perps liquidity.

### 3. Genesis Configuration Gating

Markets cannot be used until all six configuration categories are set. This prevents:
- Trading on markets with zero margin requirements
- Liquidation with no oracle configured
- Funding accrual with no velocity cap

The global execution/liquidation switches require all markets to be fully configured before enabling.

### 4. Insurance Fund

Each market maintains an insurance fund that absorbs losses before bad debt socialization:

```
Loss waterfall: Account collateral → Insurance fund → Bad debt
```

Liquidation protocol fees are routed to insurance first (up to the target gap), providing a self-replenishing mechanism.

### 5. Reentrancy Protection

All state-changing functions use the `nonReentrant` modifier via `ReentrancyGuardModifiers`.

### 6. Access Control

| Function | Access |
|----------|--------|
| Market creation | Governance (diamond owner or timelock) |
| Parameter updates | Governance |
| Account creation | Position NFT owner/operator/TBA |
| Trading operations | Account controller (NFT owner/operator/TBA) |
| Intent execution | Anyone (with valid signature from account controller) |
| Liquidation | Anyone (permissionless, when position is unhealthy) |
| Sync | Anyone (permissionless) |

### 7. Intent Replay Protection

Multiple layers prevent intent replay:
- Sequential nonces per account
- Individual intent cancellation by hash
- Bulk nonce invalidation via `invalidateNoncesUpTo`
- Deadline expiry on every intent
- EIP-712 typed structured data with chain ID and contract address binding

### 8. Slippage Protection

Traders specify `limitPriceX18` and `maxSlippageBps`:

```
lower = limitPrice - (limitPrice × maxSlippageBps / 10,000)
upper = limitPrice + (limitPrice × maxSlippageBps / 10,000)
executionPrice must be in [lower, upper]
```

### 9. Pause Granularity

Each market has four independent pause flags, allowing surgical intervention:
- Pause increases only (allow exits but not new risk)
- Pause decreases (emergency freeze)
- Pause liquidation (oracle failure protection)
- Pause sync (funding freeze)

### 10. Open Interest & Skew Caps

Per-market caps prevent excessive concentration:
- Total OI cap limits overall market exposure
- Per-side caps limit directional concentration
- Skew cap limits funding rate extremes and counterparty risk

### 11. Deterministic IDs

All IDs (market, account, position) are deterministically derived via `keccak256`:
- No ID collisions possible for different inputs
- IDs are reproducible off-chain for indexing and verification
- Namespace separation prevents cross-module ID conflicts

### 12. Bad Debt Tracking

Bad debt is tracked cumulatively per market and never decreases:

```solidity
market.badDebt += badDebtDelta;
```

This provides a transparent, auditable record of socialized losses. The `proveIsolationInvariant` view function allows anyone to verify that the domain remains solvent accounting for insurance and recognized bad debt.

---

## Appendix: Correctness Properties

### Property 1: Domain Isolation Invariant
For any mutating perps operation:
```
nonPerpsTrackedTotal(after) ≥ nonPerpsTrackedTotal(before)
nonPerpsTrackedTotal(after) - nonPerpsTrackedTotal(before) == explicitOutboundCredit
```

### Property 2: Domain Solvency
After every liquidation and collateral removal:
```
isolatedTrackedBalance + insuranceBalance + badDebt ≥ isolatedLiabilities
```

### Property 3: Open Interest Conservation
For any trade:
```
openInterestLong(after) + openInterestShort(after) =
    openInterestLong(before) + openInterestShort(before) ± sizeDelta
```

### Property 4: Skew Consistency
At all times:
```
skew = openInterestLong - openInterestShort
```

### Property 5: Funding Symmetry
Funding deltas are equal and opposite for longs and shorts:
```
cumulativeFundingLong(delta) = -cumulativeFundingShort(delta)
```

### Property 6: Fee Split Conservation
For every trading fee:
```
lpFee + protocolFee = totalFee
lpFee = totalFee × 7,000 / 10,000
protocolFee = totalFee - lpFee
```

### Property 7: LP Fee Index Monotonicity
The LP fee index only increases:
```
lpFeeIndexX18(after) ≥ lpFeeIndexX18(before)
```

### Property 8: Nonce Monotonicity
Account nonces only increase:
```
account.nonce(after) ≥ account.nonce(before)
minValidNonce(after) ≥ minValidNonce(before)
```

### Property 9: Insurance Fund Priority
Liquidation protocol fees fill insurance before overflow routing:
```
insuranceFromProtocol = min(protocolFee, insuranceTargetGap)
overflowFee = protocolFee - insuranceFromProtocol
```

### Property 10: Bad Debt Monotonicity
Bad debt counter only increases:
```
badDebt(after) ≥ badDebt(before)
```

### Property 11: Close Factor Bounds
Liquidation close factor is always 50% or 100%:
```
closeFactorBps ∈ {5,000, 10,000}
```

### Property 12: Collateral Reservation Conservation
Total reserved collateral equals sum of all account collateral balances:
```
marketState.reservedCollateral = Σ(accountCollateral[account][market])
```

### Property 13: Genesis Gating
Execution and liquidation are blocked until all config categories are set:
```
executionEnabled → marketConfigMask == CONFIG_REQUIRED_MASK (0x3F)
```

### Property 14: Entry Price Weighted Average
On position increase:
```
newEntryPrice = (oldEntry × oldSize + execPrice × sizeDelta) / (oldSize + sizeDelta)
```

### Property 15: PnL Directionality
```
Long PnL > 0  ⟺  exitPrice > entryPrice
Short PnL > 0 ⟺  exitPrice < entryPrice
```

---

**Document Version:** 1.0
