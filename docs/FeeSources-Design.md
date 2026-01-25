# Equalis Fee Sources - Design Document

**Version:** 1.1 (Updated for centralized fee index and encumbrance systems)

---

## Table of Contents

1. [Overview](#overview)
2. [Fee Distribution Architecture](#fee-distribution-architecture)
3. [Pool-Level Fees](#pool-level-fees)
4. [Index Token Fees](#index-token-fees)
5. [Derivative Fees](#derivative-fees)
6. [Creation Fees](#creation-fees)
7. [Fee Indices](#fee-indices)
8. [Configuration](#configuration)
9. [Fee Flow Diagrams](#fee-flow-diagrams)

---

## Overview

Equalis generates fees from multiple sources across its protocol modules. Fees serve three purposes:

1. **Depositor Rewards** - Distributed via fee index to pool depositors
2. **Protocol Revenue** - Sent to treasury for protocol sustainability
3. **Active Credit Rewards** - Distributed to active borrowers/lenders

### Fee Source Summary

| Module | Fee Type | Basis | Distribution |
|--------|----------|-------|--------------|
| **Pools** | Flash Loan | % of loan amount | Fee Index + Treasury + Active Credit |
| **Pools** | Maintenance | % of TVL annually | Foundation Receiver |
| **Pools** | Action Fees | Flat amount | Fee Index + Treasury + Active Credit |
| **Index** | Mint Fee | % per asset | Fee Index (40%) + Fee Pot + Protocol |
| **Index** | Burn Fee | % per asset | Fee Index (40%) + Fee Pot + Protocol |
| **Index** | Flash Fee | % of loan | Fee Index (10%) + Fee Pot + Protocol |
| **Derivatives** | Create Fee | % + flat | Fee Index + Treasury + Active Credit |
| **Derivatives** | Exercise Fee | % + flat | Fee Index + Treasury + Active Credit |
| **Derivatives** | Reclaim Fee | % + flat | Fee Index + Treasury + Active Credit |
| **Auctions** | Swap Fee | % of trade | Makers + Fee Index + Treasury |
| **Direct** | Platform Fee | % of principal | Lender + Fee Index + Protocol + Active Credit |
| **Direct** | Default Recovery | % of collateral | Lender + Fee Index + Protocol + Active Credit |
| **Creation** | Pool Creation | ETH flat fee | Treasury |
| **Creation** | Index Creation | ETH flat fee | Treasury |
| **Creation** | Managed Pool | ETH flat fee | Treasury |

---

## Fee Distribution Architecture

### Centralized Fee Routing (LibFeeTreasury & LibFeeIndex)

Fee distribution is managed through centralized libraries:

- **LibFeeTreasury**: Handles treasury splits and routing
- **LibFeeIndex**: Manages pool-level fee index accrual for depositors
- **LibActiveCreditIndex**: Manages active credit rewards with 24h time gate
- **LibFeeRouter**: Coordinates complex fee distributions

### Treasury Split

Most fees are split between multiple recipients via `LibFeeTreasury`:

```solidity
// In LibFeeTreasury.sol
function accrueWithTreasury(pool, pid, amount, source) {
    toTreasury = (amount × treasuryShareBps) / 10,000
    toActiveCredit = (amount × activeCreditShareBps) / 10,000
    toFeeIndex = amount - toTreasury - toActiveCredit
    
    // Transfer treasury share
    transfer(treasury, toTreasury)
    
    // Accrue to active credit index (via LibActiveCreditIndex)
    LibActiveCreditIndex.accrueWithSource(pid, toActiveCredit, source)
    
    // Accrue to fee index (depositors, via LibFeeIndex)
    LibFeeIndex.accrueWithSource(pid, toFeeIndex, source)
}
```

### Default Split Ratios

| Recipient | Default Share | Configurable |
|-----------|---------------|--------------|
| Treasury | 20% (2000 bps) | Yes |
| Active Credit | 0% (disabled) | Yes |
| Fee Index | Remainder | Automatic |

---

## Pool-Level Fees

### Flash Loan Fees

Flash loans charge a percentage fee on the borrowed amount.

**Configuration:**
```solidity
struct PoolConfig {
    uint16 flashLoanFeeBps;      // e.g., 30 = 0.3%
    bool flashLoanAntiSplit;     // Prevent fee arbitrage
}
```

**Calculation:**
```
fee = (loanAmount × flashLoanFeeBps) / 10,000
```

**Distribution:**
```
Treasury Share → Protocol Treasury (via LibFeeTreasury)
Active Credit Share → Active Credit Index (via LibActiveCreditIndex)
Remainder → Fee Index (depositors, via LibFeeIndex)
```

**Example:**
```
Loan: 100,000 USDC
Fee Rate: 30 bps (0.3%)
Fee: 300 USDC

Treasury (20%): 60 USDC
Active Credit (0%): 0 USDC
Fee Index (80%): 240 USDC
```

### Maintenance Fees

Annual maintenance fee charged on pool TVL, paid to the foundation.

**Configuration:**
```solidity
uint16 maintenanceRateBps;      // e.g., 100 = 1% annually
uint16 maxMaintenanceRateBps;   // Protocol-wide cap
```

**Calculation:**
```
dailyFee = (totalDeposits × rateBps × epochs) / (365 × 10,000)
```

**Distribution:**
- 100% to Foundation Receiver
- Reduces depositor principal proportionally via maintenance index

**Accrual:**
- Triggered on any pool interaction
- Accrues in daily epochs
- Pending maintenance paid when liquidity available

### Action Fees

Flat fees charged on specific operations.

**Fee Types:**

| Action | Trigger |
|--------|---------|
| `ACTION_BORROW` | Opening a loan |
| `ACTION_REPAY` | Making a payment |
| `ACTION_WITHDRAW` | Withdrawing principal |
| `ACTION_FLASH` | Flash loan (additional to %) |
| `ACTION_CLOSE_ROLLING` | Closing rolling credit |

**Configuration:**
```solidity
struct ActionFeeConfig {
    uint128 amount;    // Flat fee in underlying token
    bool enabled;      // Whether fee is active
}
```

**Distribution:**
- Deducted from user's principal
- Split via `LibFeeTreasury.accrueWithTreasuryFromPrincipal()`
- Routed to Treasury, Active Credit Index, and Fee Index

---

## Index Token Fees

Index token fees are distributed via a 2-way split:
1. **Pool Share** - configurable via `mintBurnFeeIndexShareBps` (default 40%), routed through the standard fee router (FI/ACI/Treasury)
2. **Fee Pot** (index token holders) - remainder after the pool share

### Mint Fees

Per-asset fee charged when minting index tokens.

**Configuration:**
```solidity
uint16[] mintFeeBps;              // Per-asset mint fee (e.g., [50, 50, 50])
uint16 mintBurnFeeIndexShareBps;  // Fee Index share (default 4000 = 40%)
```

**Calculation:**
```
For each asset:
    required = bundleAmount × units / INDEX_SCALE
    mintFee = required × mintFeeBps[i] / 10,000
    totalTransfer = required + mintFee
```

**Distribution:**
```solidity
// 1. Pool share routed through fee router (FI/ACI/Treasury)
poolShare = fee × mintBurnFeeIndexShareBps / 10,000
LibFeeRouter.routeSamePool(poolId, poolShare, INDEX_FEE_SOURCE, true, 0)

// 2. Fee pot share
potShare = fee - poolShare
feePots[indexId][asset] += potShare      // For index holders
```

### Burn Fees

Per-asset fee charged when redeeming index tokens.

**Calculation:**
```
For each asset:
    navShare = vaultBalance × units / totalSupply
    potShare = feePotBalance × units / totalSupply
    gross = navShare + potShare
    burnFee = gross × burnFeeBps[i] / 10,000
    payout = gross - burnFee
```

**Distribution:**
Same 2-way split as mint fees:
```solidity
// 1. Pool share routed through fee router (FI/ACI/Treasury)
poolShare = burnFee × mintBurnFeeIndexShareBps / 10,000

// 2. Fee pot share
potShare = burnFee - poolShare
feePots[indexId][asset] += potShare
```
Net payout (gross - burnFee) transferred to redeemer.

### Flash Loan Fees (Index)

Fee charged on index flash loans.

**Configuration:**
```solidity
uint16 flashFeeBps;         // e.g., 30 = 0.3%
uint16 poolFeeShareBps;     // Share to underlying pools (default 1000 = 10%)
```

**Distribution:**
Same 2-way split structure, but uses `poolFeeShareBps` (default 10%) instead of `mintBurnFeeIndexShareBps` (default 40%):
```solidity
// 1. Pool share routed through fee router (FI/ACI/Treasury)
poolShare = fee × poolFeeShareBps / 10,000

// 2. Fee pot share
potShare = fee - poolShare
```

---

## Derivative Fees

### Options Fees

Options series charge fees at creation, exercise, and reclaim.

**Configuration:**
```solidity
struct DerivativeConfig {
    uint16 defaultCreateFeeBps;
    uint16 defaultExerciseFeeBps;
    uint16 defaultReclaimFeeBps;
    uint128 defaultCreateFeeFlatWad;     // Flat fee in WAD (1e18)
    uint128 defaultExerciseFeeFlatWad;
    uint128 defaultReclaimFeeFlatWad;
    uint16 minFeeBps;
    uint16 maxFeeBps;
}
```

**Fee Calculation:**
```solidity
feeAmount = (baseAmount × feeBps / 10,000) + flatFeeInTokenDecimals
```

**Create Fee:**
- Charged from maker's collateral pool principal
- Distributed via `LibFeeTreasury.accrueWithTreasuryFromPrincipal()`

**Exercise Fee:**
- Charged from exerciser's payment
- Distributed via `LibFeeTreasury.accrueWithTreasury()`

**Reclaim Fee:**
- Charged from maker's unlocked collateral
- Distributed via `LibFeeTreasury.accrueWithTreasuryFromPrincipal()`

### Futures Fees

Futures series use the same fee structure as options.

| Fee Type | Charged From | Trigger |
|----------|--------------|---------|
| Create | Maker's underlying principal | Series creation |
| Exercise | Taker's quote payment | Settlement |
| Reclaim | Maker's unlocked collateral | Post-expiry reclaim |

### AMM Auction Fees

Single-maker AMM auctions charge swap fees.

**Configuration:**
```solidity
uint16 feeBps;              // Swap fee (e.g., 30 = 0.3%)
FeeAsset feeAsset;          // TokenIn or TokenOut
```

**Distribution:**
- 100% to maker (accrued in `makerFeeAAccrued` / `makerFeeBAccrued`)

### Community Auction Fees

Multi-maker community auctions split fees among participants.

**Fee Split:**
```solidity
uint16 FEE_SPLIT_MAKER_BPS = 7000;     // 70% to makers
uint16 FEE_SPLIT_INDEX_BPS = 2000;     // 20% to fee index
uint16 FEE_SPLIT_TREASURY_BPS = 1000;  // 10% to treasury
```

**Distribution:**
1. Maker share → Community auction fee index (pro-rata to LP shares)
2. Index share → Pool fee index (depositors, via `LibFeeIndex`)
3. Treasury share → Protocol treasury (via `LibFeeTreasury`)

---

## Creation Fees

### Pool Creation Fee

ETH fee for permissionless pool creation.

**Configuration:**
```solidity
uint256 poolCreationFee;    // e.g., 0.5 ether
```

**Rules:**
- Governance: Free (must send 0 ETH)
- Public: Must pay exact fee
- Fee = 0: Permissionless creation disabled

**Distribution:**
- 100% to Protocol Treasury

### Index Creation Fee

ETH fee for permissionless index token creation.

**Configuration:**
```solidity
uint256 indexCreationFee;   // e.g., 0.2 ether
```

**Rules:**
- Same as pool creation fee

### Managed Pool Creation Fee

ETH fee for creating whitelist-gated managed pools.

**Configuration:**
```solidity
uint256 managedPoolCreationFee;
```

**Rules:**
- Always required (no governance bypass)
- Fee = 0: Managed pool creation disabled

---

## Fee Indices

### Fee Index (Depositors) - LibFeeIndex

Distributes pool fees to depositors based on fee base. Managed by the centralized `LibFeeIndex.sol` library.

**Accrual:**
```solidity
// In LibFeeIndex.sol
function accrueWithSource(uint256 pid, uint256 amount, bytes32 source) {
    uint256 scaledAmount = Math.mulDiv(amount, INDEX_SCALE, 1);
    uint256 dividend = scaledAmount + p.feeIndexRemainder;
    uint256 delta = dividend / totalDeposits;
    p.feeIndex += delta;
    p.feeIndexRemainder = dividend - (delta * totalDeposits);
    p.yieldReserve += amount;
}
```

**Settlement:**
```solidity
// In LibFeeIndex.settle()
pendingYield = (feeIndex - userFeeIndex) × feeBase / INDEX_SCALE
feeBase = principal - sameAssetDebt  // Normalized for borrowers
```

**Key Property:** Borrowers earn reduced fees proportional to their debt.

### Active Credit Index - LibActiveCreditIndex

Distributes rewards to active borrowers and P2P lenders. Managed by the centralized `LibActiveCreditIndex.sol` library.

**Accrual:**
```solidity
// In LibActiveCreditIndex.sol
function accrueWithSource(uint256 pid, uint256 amount, bytes32 source) {
    uint256 activeBase = p.activeCreditMaturedTotal;
    if (activeBase == 0) return;
    
    uint256 delta = (amount × INDEX_SCALE) / activeBase;
    p.activeCreditIndex += delta;
}
```

**Time Gate:** 24-hour maturity required before earning. Uses hourly bucket scheduling for efficient maturity tracking.

**Weighted Dilution:** New principal dilutes existing time credit to prevent dust-priming attacks.

### Maintenance Index - LibMaintenance

Tracks cumulative maintenance fee deductions. Managed by `LibMaintenance.sol`.

**Accrual:**
```solidity
// In LibMaintenance.sol
maintenanceIndex += (rateBps × epochs × INDEX_SCALE) / (365 × 10,000)
```

**Effect:** Reduces user principal proportionally on settlement (applied in `LibFeeIndex.settle()`).

### Community Auction Fee Index

Per-auction fee index for LP fee distribution.

**Accrual:**
```solidity
feeIndexA += (makerFeeA × INDEX_SCALE) / totalShares
feeIndexB += (makerFeeB × INDEX_SCALE) / totalShares
```

**Settlement:** Makers claim proportional to their LP shares.

---

## Configuration

### Global Fee Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `treasuryShareBps` | 2000 (20%) | Treasury share of distributed fees |
| `activeCreditShareBps` | 0 (disabled) | Active credit share of fees |
| `defaultMaintenanceRateBps` | 100 (1%) | Default annual maintenance rate |
| `maxMaintenanceRateBps` | 100 (1%) | Maximum allowed maintenance rate |
| `actionFeeMin` | 0 | Minimum action fee amount |
| `actionFeeMax` | type(uint128).max | Maximum action fee amount |

### Pool-Level Parameters

| Parameter | Location | Mutable |
|-----------|----------|---------|
| `flashLoanFeeBps` | PoolConfig | No |
| `maintenanceRateBps` | PoolConfig | No |
| Action fees | PoolConfig | Admin override |

### Index-Level Parameters

| Parameter | Location | Mutable | Default |
|-----------|----------|---------|---------|
| `mintFeeBps[]` | Index struct | Governance only | Per-index |
| `burnFeeBps[]` | Index struct | Governance only | Per-index |
| `flashFeeBps` | Index struct | Governance only | Per-index |
| `poolFeeShareBps` | EqualIndexStorage | Governance only | 1000 (10%) |
| `mintBurnFeeIndexShareBps` | EqualIndexStorage | Governance only | 4000 (40%) |

### Derivative Parameters

| Parameter | Location | Mutable |
|-----------|----------|---------|
| `defaultCreateFeeBps` | DerivativeConfig | Governance |
| `defaultExerciseFeeBps` | DerivativeConfig | Governance |
| `defaultReclaimFeeBps` | DerivativeConfig | Governance |
| `minFeeBps` / `maxFeeBps` | DerivativeConfig | Governance |
| Custom fees per series | Series struct | At creation |

---

## Fee Flow Diagrams

### Flash Loan Fee Flow

```
┌─────────────┐
│ Flash Loan  │
│   100,000   │
└──────┬──────┘
       │ 0.3% fee = 300
       ▼
┌─────────────┐
│  Fee Split  │
└──────┬──────┘
       │
       ├──────────────────┐
       │                  │
       ▼                  ▼
┌─────────────┐    ┌─────────────┐
│  Treasury   │    │  Fee Index  │
│   60 (20%)  │    │  240 (80%)  │
└─────────────┘    └──────┬──────┘
                          │
                          ▼
                   ┌─────────────┐
                   │ Depositors  │
                   │ (pro-rata)  │
                   └─────────────┘
```

### Index Mint Fee Flow

```
┌─────────────┐
│  Mint 10    │
│ Index Units │
└──────┬──────┘
       │
       ▼
┌─────────────────────────────────┐
│ Per Asset Fee Calculation       │
│ Asset A: 100 required, 1% = 1   │
│ Asset B: 50 required, 1% = 0.5  │
└──────┬──────────────────────────┘
       │
       ├──────────────────┬──────────────────┐
       │                  │                  │
       ▼                  ▼                  ▼
┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│  Fee Index  │    │  Fee Pot    │    │  Protocol   │
│   (40%)     │    │   (48%)     │    │   (12%)     │
└──────┬──────┘    └──────┬──────┘    └─────────────┘
       │                  │
       ▼                  ▼
┌─────────────┐    ┌─────────────┐
│   Pool      │    │Index Holders│
│ Depositors  │    │ (on burn)   │
└─────────────┘    └─────────────┘

Note: With 40% Fee Index share and 20% protocol cut on remainder:
- Fee Index: 40%
- Remainder: 60%
  - Protocol (20% of 60%): 12%
  - Fee Pot (80% of 60%): 48%
```

### Penalty Fee Flow

```
┌─────────────┐
│  Default    │
│  Penalty    │
│    100      │
└──────┬──────┘
       │
       ├────────────────────────────────────┐
       │                                    │
       ▼                                    ▼
┌─────────────┐                      ┌─────────────┐
│  Enforcer   │                      │  Remainder  │
│   10 (10%)  │                      │     90      │
└─────────────┘                      └──────┬──────┘
                                            │
              ┌─────────────┬───────────────┼───────────────┐
              │             │               │               │
              ▼             ▼               ▼               ▼
       ┌───────────┐ ┌───────────┐ ┌───────────┐ ┌───────────┐
       │ Fee Index │ │ Protocol  │ │  Active   │ │           │
       │ 63 (70%)  │ │  9 (10%)  │ │  Credit   │ │           │
       └───────────┘ └───────────┘ │ 18 (20%)  │ │           │
                                   └───────────┘ └───────────┘
```

### Community Auction Swap Fee Flow

```
┌─────────────┐
│   Swap      │
│  10,000 In  │
└──────┬──────┘
       │ 0.3% fee = 30
       ▼
┌─────────────┐
│  Fee Split  │
└──────┬──────┘
       │
       ├──────────────────┬──────────────────┐
       │                  │                  │
       ▼                  ▼                  ▼
┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│   Makers    │    │  Fee Index  │    │  Treasury   │
│  21 (70%)   │    │   6 (20%)   │    │   3 (10%)   │
└──────┬──────┘    └─────────────┘    └─────────────┘
       │
       ▼
┌─────────────┐
│ LP Fee Index│
│ (pro-rata)  │
└─────────────┘
```

---

## Appendix: Fee Source Tags

Fees are tagged with source identifiers for tracking:

| Source Tag | Origin |
|------------|--------|
| `flashLoan` | Pool flash loans |
| `penalty` | Default penalties |
| `INDEX_FEE` | Index flash loans |
| `FUTURES_CREATE_FEE` | Futures creation |
| `FUTURES_EXERCISE_FEE` | Futures exercise |
| `OPTIONS_CREATE_FEE` | Options creation |
| `OPTIONS_EXERCISE_FEE` | Options exercise |
| `OPTIONS_RECLAIM_FEE` | Options reclaim |
| `COMMUNITY_AUCTION_FEE` | Community auction swaps |
| `ACTION_BORROW` | Borrow action fee |
| `ACTION_REPAY` | Repay action fee |
| `ACTION_WITHDRAW` | Withdraw action fee |
| `ACTION_FLASH` | Flash action fee |
| `ACTION_CLOSE_ROLLING` | Close rolling action fee |

---

**Document Version:** 1.1 (Updated for centralized fee index and encumbrance systems)
