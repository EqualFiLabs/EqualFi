# Equalis Direct - P2P Lending Design Document

**Version:** 3.1 (Updated for centralized encumbrance and fee index systems)  

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Term Loans](#term-loans)
4. [Rolling Loans](#rolling-loans)
5. [Active Credit Index System](#active-credit-index-system)
6. [Data Models](#data-models)
7. [Fee Distribution](#fee-distribution)
8. [Error Handling](#error-handling)
9. [Events](#events)
10. [Testing Strategy](#testing-strategy)

---

## 1. Overview

Equalis Direct is a P2P lending system that enables bilateral loans between Position NFT holders. The system supports two loan types:

- **Term Loans**: Fixed-duration loans with upfront interest payment and optional early exercise
- **Rolling Loans**: Periodic payment loans with arrears tracking and optional amortization

### Key Design Principles

- Both lender and borrower must be Equalis depositors (Position NFT holders)
- All risk is bilateral between positions - pools never take P2P credit risk
- **Oracle-free cross-asset lending**: Any asset can be lent against any collateral asset
- **Deterministic settlement**: Time-based recovery without price oracles
- **Per-pool isolation**: Each pool maintains independent Direct exposure tracking
- **Upfront fee realization**: Predictable, fixed-cost lending semantics
- APR-based interest calculation with simple interest model

### Loan Type Comparison

| Feature | Term Loans | Rolling Loans |
|---------|------------|---------------|
| Duration | Fixed term | Open-ended with payment cap |
| Interest | Upfront payment | Periodic accrual |
| Payments | Single repayment | Periodic payments |
| Amortization | No | Optional |
| Early Exercise | Optional | Optional |
| Grace Period | 24 hours after due | Configurable |
| Arrears | N/A | Tracked and accumulated |
| Agreement Created | Yes | Yes |

---

## 2. Architecture

### System Components

```
┌─────────────────────────────────────────────────────────────────┐
│                    Equalis Direct System                        │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │                    Term Loans                           │    │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐   │    │
│  │  │    Offer     │  │  Agreement   │  │  Lifecycle   │   │    │
│  │  │    Facet     │  │    Facet     │  │    Facet     │   │    │
│  │  └──────────────┘  └──────────────┘  └──────────────┘   │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │                   Rolling Loans                         │    │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐   │    │
│  │  │    Offer     │  │  Agreement   │  │   Payment    │   │    │
│  │  │    Facet     │  │    Facet     │  │    Facet     │   │    │
│  │  └──────────────┘  └──────────────┘  └──────────────┘   │    │
│  │  ┌──────────────┐  ┌──────────────┐                     │    │
│  │  │  Lifecycle   │  │    View      │                     │    │
│  │  │    Facet     │  │    Facet     │                     │    │
│  │  └──────────────┘  └──────────────┘                     │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │                   Shared Components                     │    │
│  │  DirectStorage │ DirectTypes │ LibDirectHelpers         │    │
│  │  LibDirectRolling │ LibActiveCreditIndex                │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
         │                    │                    │
         ▼                    ▼                    ▼
   ┌──────────┐        ┌──────────┐        ┌──────────┐
   │ Position │        │ Equalis  │        │  Active  │
   │   NFT    │        │  Pools   │        │  Credit  │
   └──────────┘        └──────────┘        └──────────┘
```

### Integration Points

The system integrates with existing Equalis infrastructure:

1. **Position NFT System**: Validates ownership and retrieves position keys
2. **Solvency Checks**: Uses `LibEncumbrance.total()` to include all encumbered principal as debt-like exposure
3. **Withdrawal Logic**: Enforces encumbrance constraints via `LibSolvencyChecks.calculateAvailablePrincipal()`
4. **FeeIndex System**: Distributes platform fee shares via `LibFeeIndex.accrueWithSource()`
5. **Active Credit Index**: Time-gated subsidies via `LibActiveCreditIndex.accrueWithSource()` for P2P lenders and same-asset borrowers
6. **Treasury System**: Routes protocol fee shares to configured treasury via `LibFeeTreasury`
7. **Liquidation Protection**: Pool liquidations respect locked collateral and escrowed offers via LibEncumbrance
8. **Position Transfer Guard**: NFT transfer hook cancels outstanding Direct offers
9. **Encumbrance System**: Centralized tracking via `LibEncumbrance` for all position locks

### Per-Pool Exposure Isolation

All Direct exposure is tracked **per pool** through the centralized `LibEncumbrance` library, providing enhanced isolation:

```solidity
// Centralized encumbrance storage (LibEncumbrance.sol)
struct Encumbrance {
    uint256 directLocked;       // Collateral locked in specific pool
    uint256 directLent;         // Principal actively lent from specific pool
    uint256 directOfferEscrow;  // Escrowed offers for specific pool
    uint256 indexEncumbered;    // Principal encumbered by index positions
}

// Access pattern
LibEncumbrance.position(positionKey, poolId).directLocked
LibEncumbrance.position(positionKey, poolId).directLent
LibEncumbrance.position(positionKey, poolId).directOfferEscrow
LibEncumbrance.total(positionKey, poolId)  // Sum of all encumbrance types
```

**Benefits**:
- Independent risk management per pool
- Enhanced solvency precision with pool-specific constraints
- Improved liquidity management
- Cross-pool safety (issues in one pool don't affect others)
- Unified encumbrance tracking across Direct lending and Index positions

---

## 3. Term Loans

### Overview

Term loans are fixed-duration bilateral loans with upfront interest payment, optional early exercise (American-style settlement), and configurable prepayment policies. Both lenders and borrowers can post offers.

### Key Features

- **Upfront Interest**: Interest calculated and paid at loan acceptance
- **Optional Early Exercise**: Borrowers can voluntarily forfeit collateral before maturity
- **Configurable Prepayment**: Lenders control whether borrowers can repay early
- **24-Hour Grace Period**: Repayment allowed after due timestamp before recovery
- **Tranche-Backed Offers**: Lenders can escrow a fixed tranche for multiple fills
- **Ratio Tranche Offers**: Lenders or borrowers can post CLOB-style offers with price ratios for variable-size fills
- **Borrower Offers**: Borrowers can post offers specifying their desired terms, which lenders can accept
- **Auto-Exercise on Fill**: Offers can be configured to immediately exercise upon acceptance (useful for synthetic options)
- **Cross-Asset Support**: Any asset can be lent against any collateral asset

### Data Structures

```solidity
struct DirectOffer {
    uint256 offerId;
    address lender;
    uint256 lenderPositionId;
    uint256 lenderPoolId;           // Pool providing liquidity
    uint256 collateralPoolId;       // Pool holding borrower collateral
    address collateralAsset;
    address borrowAsset;
    uint256 principal;
    uint16 aprBps;
    uint64 durationSeconds;
    uint256 collateralLockAmount;
    bool allowEarlyRepay;           // Prepayment control
    bool allowEarlyExercise;        // Early exercise control
    bool allowLenderCall;           // Lender acceleration control
    bool cancelled;
    bool filled;
    bool isTranche;                 // Tranche-backed mode
    uint256 trancheAmount;          // Total tranche escrowed
}

struct DirectBorrowerOffer {
    uint256 offerId;
    address borrower;
    uint256 borrowerPositionId;
    uint256 lenderPoolId;           // Pool lender will provide liquidity from
    uint256 collateralPoolId;       // Pool holding borrower collateral
    address collateralAsset;
    address borrowAsset;
    uint256 principal;
    uint16 aprBps;
    uint64 durationSeconds;
    uint256 collateralLockAmount;
    bool allowEarlyRepay;           // Prepayment control
    bool allowEarlyExercise;        // Early exercise control
    bool allowLenderCall;           // Lender acceleration control
    bool cancelled;
    bool filled;
}

struct DirectRatioTrancheOffer {
    uint256 offerId;
    address lender;
    uint256 lenderPositionId;
    uint256 lenderPoolId;
    uint256 collateralPoolId;
    address collateralAsset;
    address borrowAsset;
    uint256 principalCap;           // Total principal available
    uint256 principalRemaining;     // Unfilled principal
    uint256 priceNumerator;         // collateral = principal * num / denom
    uint256 priceDenominator;
    uint256 minPrincipalPerFill;    // Minimum principal per fill
    uint16 aprBps;
    uint64 durationSeconds;
    bool allowEarlyRepay;
    bool allowEarlyExercise;
    bool allowLenderCall;
    bool cancelled;
    bool filled;
}

struct DirectBorrowerRatioTrancheOffer {
    uint256 offerId;
    address borrower;
    uint256 borrowerPositionId;
    uint256 lenderPoolId;
    uint256 collateralPoolId;
    address collateralAsset;
    address borrowAsset;
    uint256 collateralCap;          // Total collateral available for fills
    uint256 collateralRemaining;    // Unfilled collateral
    uint256 priceNumerator;         // principal = collateral * num / denom
    uint256 priceDenominator;
    uint256 minCollateralPerFill;   // Minimum collateral per fill
    uint16 aprBps;
    uint64 durationSeconds;
    bool allowEarlyRepay;
    bool allowEarlyExercise;
    bool allowLenderCall;
    bool cancelled;
    bool filled;
}

struct DirectAgreement {
    uint256 agreementId;
    address lender;
    address borrower;
    uint256 lenderPositionId;
    uint256 lenderPoolId;
    uint256 borrowerPositionId;
    uint256 collateralPoolId;
    address collateralAsset;
    address borrowAsset;
    uint256 principal;
    uint256 userInterest;           // Paid upfront
    uint64 dueTimestamp;
    uint256 collateralLockAmount;
    bool allowEarlyRepay;
    bool allowEarlyExercise;
    bool allowLenderCall;
    DirectStatus status;
    bool interestRealizedUpfront;   // Always true
}

enum DirectStatus { 
    Active, 
    Repaid, 
    Defaulted,
    Exercised
}
```

### Lifecycle

#### 1. Post Lender Offer
```solidity
function postOffer(DirectOfferParams calldata params) external returns (uint256 offerId);
```
- Validate Position NFT ownership and offer parameters
- Verify lender has sufficient available principal
- Reserve principal via LibEncumbrance: `enc.directOfferEscrow += principal`
- Store offer and emit events

#### 2. Post Borrower Offer
```solidity
function postBorrowerOffer(DirectBorrowerOfferParams calldata params) external returns (uint256 offerId);
```
- Validate Position NFT ownership and offer parameters
- Verify borrower has sufficient collateral
- Lock collateral via LibEncumbrance: `enc.directLocked += collateralLockAmount`
- Store offer and emit events

#### 3. Accept Lender Offer
```solidity
function acceptOffer(uint256 offerId, uint256 borrowerPositionId) external returns (uint256 agreementId);
```
- Validate borrower Position NFT and collateral availability
- Lock collateral via LibEncumbrance: `enc.directLocked += collateralLockAmount`
- Calculate and collect upfront interest and platform fees
- Reduce lender principal immediately: `lenderPrincipal -= lentAmount`
- Transfer principal from pool to borrower
- Distribute fees (lender, FeeIndex, protocol, Active Credit Index)
- Create agreement with copied configuration flags

#### 4. Accept Borrower Offer
```solidity
function acceptBorrowerOffer(uint256 offerId, uint256 lenderPositionId) external returns (uint256 agreementId);
```
- Validate lender Position NFT and principal availability
- Verify borrower's collateral is still locked (from posting)
- Calculate and collect upfront interest and platform fees
- Reduce lender principal immediately: `lenderPrincipal -= lentAmount`
- Transfer principal from pool to borrower (minus fees)
- Distribute fees (lender, FeeIndex, protocol, Active Credit Index)
- Create agreement with copied configuration flags

#### 5. Repay
```solidity
function repay(uint256 agreementId) external;
```
- Validate timing based on `allowEarlyRepay` flag:
  - If disabled: Only allow from 24h before due until 24h after due
  - If enabled: Allow from acceptance until 24h after due
- Collect principal from borrower (interest already paid)
- Restore lender principal: `lenderPrincipal += repaidAmount`
- Unlock collateral and release lender exposure
- Set status to `Repaid`

#### 6. Exercise Early
```solidity
function exerciseDirect(uint256 agreementId) external;
```
- Only callable by borrower
- Before due: requires `allowEarlyExercise = true`
- Grace window (due to due + 24h): callable regardless of flag
- Forfeit full collateral to lender with fee distribution
- Set status to `Exercised`
- Borrower keeps borrowed principal, loses collateral

#### 7. Recover (Default)
```solidity
function recover(uint256 agreementId) external;
```
- Only callable 24+ hours after due timestamp
- Seize locked collateral from borrower
- Distribute collateral with configured fee splits
- Handle shortfall by reducing lender principal
- Set status to `Defaulted`

### Timing Rules

| Scenario | Timing |
|----------|--------|
| Early Repay Disabled | 24h before due → 24h after due |
| Early Repay Enabled | Acceptance → 24h after due |
| Early Exercise | Before due (if allowed) or during grace window |
| Recovery | 24+ hours after due |
| Lender Call | Anytime before due (if allowed) |

### Lender Call (Loan Acceleration)

The `allowLenderCall` flag enables lenders to accelerate the loan's due timestamp, effectively "calling" the loan. This is analogous to a callable bond where the issuer can demand early repayment.

```solidity
function callDirect(uint256 agreementId) external;
```

**Mechanics**:
- Only callable by the lender (owner of `lenderPositionId`)
- Requires `allowLenderCall = true` on the agreement
- Must be called before the current `dueTimestamp`
- Sets `dueTimestamp` to the current block timestamp
- Emits `DirectAgreementCalled(agreementId, lenderPositionId, newDueTimestamp)`

**Effect on Borrower**:
- The 24-hour grace period begins immediately from the new due timestamp
- Borrower must repay within 24 hours or face recovery
- If `allowEarlyRepay = false`, the borrower can still repay during the grace window
- Borrower can exercise (forfeit collateral) during the grace window regardless of `allowEarlyExercise`

**Use Cases**:
- **Risk Management**: Lenders can call loans if they observe deteriorating borrower conditions
- **Liquidity Needs**: Lenders can accelerate repayment when they need funds
- **Market Conditions**: Lenders can respond to changing market dynamics
- **Collateral Concerns**: If collateral value appears at risk, lenders can trigger early settlement

**Borrower Considerations**:
- Loans with `allowLenderCall = true` carry acceleration risk
- Borrowers should factor this into their liquidity planning
- The flag is visible in the offer, allowing informed acceptance decisions

### Tranche-Backed Offers

Lenders can post offers with a fixed tranche that supports multiple fills:

```solidity
struct DirectTrancheOfferParams {
    bool isTranche;
    uint256 trancheAmount;
}
```

**Mechanics**:
- Full tranche escrowed at post time via LibEncumbrance
- `trancheRemaining` tracks unfilled balance
- Acceptances decrement `trancheRemaining` by `principal`
- Insufficient tranche auto-cancels the offer
- Optional `enforceFixedSizeFills` requires `trancheAmount % principal == 0`
- Cancellation returns remaining tranche to lender

### Ratio Tranche Offers (Lender)

Lenders can post CLOB-style offers with a price ratio for variable-size fills:

```solidity
function postRatioTrancheOffer(DirectRatioTrancheParams calldata params) external returns (uint256 offerId);
```

**Parameters**:
- `principalCap`: Total principal available for fills
- `priceNumerator/priceDenominator`: Collateral per unit principal ratio
- `minPrincipalPerFill`: Minimum principal per fill to prevent dust

**Mechanics**:
- Lender escrows `principalCap` at post time
- Borrowers draw any amount between `minPrincipalPerFill` and `principalRemaining`
- Required collateral computed as: `collateral = principal × priceNumerator / priceDenominator`
- `principalRemaining` decremented per fill
- Offer marked filled when `principalRemaining == 0`

**Acceptance**:
```solidity
function acceptRatioTrancheOffer(uint256 offerId, uint256 borrowerPositionId, uint256 principalAmount) 
    external returns (uint256 agreementId);
```

### Borrower Ratio Tranche Offers

Borrowers can post CLOB-style offers specifying collateral they're willing to lock:

```solidity
function postBorrowerRatioTrancheOffer(DirectBorrowerRatioTrancheParams calldata params) 
    external returns (uint256 offerId);
```

**Parameters**:
- `collateralCap`: Total collateral available for fills
- `priceNumerator/priceDenominator`: Principal per unit collateral ratio
- `minCollateralPerFill`: Minimum collateral per fill to prevent dust

**Mechanics**:
- Borrower locks `collateralCap` at post time
- Lenders fill any amount between `minCollateralPerFill` and `collateralRemaining`
- Principal computed as: `principal = collateral × priceNumerator / priceDenominator`
- `collateralRemaining` decremented per fill
- Offer marked filled when `collateralRemaining == 0`

**Acceptance**:
```solidity
function acceptBorrowerRatioTrancheOffer(uint256 offerId, uint256 lenderPositionId, uint256 collateralAmount) 
    external returns (uint256 agreementId);
```

**Use Cases**:
- **CLOB-Style Trading**: Variable-size fills enable order book-like trading dynamics
- **Price Discovery**: Multiple lenders can fill at the borrower's posted ratio

---

## 4. Rolling Loans

### Overview

Rolling loans are periodic payment bilateral loans with arrears tracking, optional amortization, and configurable grace periods. They provide flexible, ongoing credit relationships between Position NFT holders.

### Key Features

- **Periodic Payments**: Configurable payment intervals (e.g., 7 days, 30 days)
- **Arrears Tracking**: Missed payments accumulate as arrears
- **Optional Amortization**: Lenders can allow principal reduction with payments
- **Grace Periods**: Configurable time after due before recovery
- **Payment Caps**: Maximum number of payment periods
- **Upfront Premium**: Optional upfront payment from borrower to lender
- **Cross-Asset Support**: Any asset can be lent against any collateral

### Data Structures

```solidity
struct DirectRollingOffer {
    uint256 offerId;
    bool isRolling;
    address lender;
    uint256 lenderPositionId;
    uint256 lenderPoolId;
    uint256 collateralPoolId;
    address collateralAsset;
    address borrowAsset;
    uint256 principal;
    uint256 collateralLockAmount;
    uint32 paymentIntervalSeconds;  // e.g., 7 days, 30 days
    uint16 rollingApyBps;           // Interest rate
    uint32 gracePeriodSeconds;      // Time after due before recovery
    uint16 maxPaymentCount;         // Maximum payment periods
    uint256 upfrontPremium;         // Optional upfront payment
    bool allowAmortization;         // Allow principal reduction
    bool allowEarlyRepay;           // Allow early full repayment
    bool allowEarlyExercise;        // Allow early collateral forfeiture
    bool cancelled;
    bool filled;
}

struct DirectRollingBorrowerOffer {
    uint256 offerId;
    bool isRolling;
    address borrower;
    uint256 borrowerPositionId;
    uint256 lenderPoolId;
    uint256 collateralPoolId;
    address collateralAsset;
    address borrowAsset;
    uint256 principal;
    uint256 collateralLockAmount;
    uint32 paymentIntervalSeconds;
    uint16 rollingApyBps;
    uint32 gracePeriodSeconds;
    uint16 maxPaymentCount;
    uint256 upfrontPremium;
    bool allowAmortization;
    bool allowEarlyRepay;
    bool allowEarlyExercise;
    bool cancelled;
    bool filled;
}

struct DirectRollingAgreement {
    uint256 agreementId;
    bool isRolling;
    address lender;
    address borrower;
    uint256 lenderPositionId;
    uint256 lenderPoolId;
    uint256 borrowerPositionId;
    uint256 collateralPoolId;
    address collateralAsset;
    address borrowAsset;
    uint256 principal;              // Original principal
    uint256 outstandingPrincipal;   // Current outstanding (reduces with amortization)
    uint256 collateralLockAmount;
    uint256 upfrontPremium;
    uint64 nextDue;                 // Next payment due timestamp
    uint256 arrears;                // Accumulated unpaid interest
    uint16 paymentCount;            // Payments made so far
    uint32 paymentIntervalSeconds;
    uint16 rollingApyBps;
    uint32 gracePeriodSeconds;
    uint16 maxPaymentCount;
    bool allowAmortization;
    bool allowEarlyRepay;
    bool allowEarlyExercise;
    uint64 lastAccrualTimestamp;    // Last interest accrual time
    DirectStatus status;
}

struct DirectRollingConfig {
    uint32 minPaymentIntervalSeconds; // e.g., 604800 (7 days)
    uint16 maxPaymentCount;           // e.g., 520 payments (10 years weekly)
    uint16 maxUpfrontPremiumBps;      // e.g., 5000 (50%)
    uint16 minRollingApyBps;          // e.g., 1 (0.01%)
    uint16 maxRollingApyBps;          // e.g., 10000 (100%)
    uint16 defaultPenaltyBps;         // Penalty rate for defaults
    uint64 minPaymentWei;             // Minimum payment to avoid dust
}
```

### Lifecycle

#### 1. Post Lender Offer
```solidity
function postRollingOffer(DirectRollingOfferParams calldata params) external returns (uint256 offerId);
```
- Validate Position NFT ownership and parameters against config bounds
- Verify lender has sufficient available principal
- Escrow principal via LibEncumbrance: `enc.directOfferEscrow += principal`
- Store offer and emit events

#### 2. Post Borrower Offer
```solidity
function postBorrowerRollingOffer(DirectRollingBorrowerOfferParams calldata params) external returns (uint256 offerId);
```
- Validate Position NFT ownership and collateral availability
- Lock collateral via LibEncumbrance: `enc.directLocked += collateralLockAmount`
- Store offer and emit events

#### 3. Accept Offer
```solidity
function acceptRollingOffer(uint256 offerId, uint256 callerPositionId) external returns (uint256 agreementId);
```
- Works for both lender and borrower offers
- Verify counterparty has required assets
- Transfer principal from lender pool to borrower (minus upfront premium)
- Pay upfront premium to lender
- Create agreement with `nextDue = block.timestamp + paymentIntervalSeconds`
- Track in both borrower and lender agreement lists

#### 4. Make Payment
```solidity
function makeRollingPayment(uint256 agreementId, uint256 amount) external;
```
- Accrue interest since last accrual to arrears
- Apply payment in order:
  1. Clear arrears (accumulated missed interest)
  2. Pay current interval interest
  3. Reduce principal (only if `allowAmortization = true`)
- Advance `nextDue` only if arrears cleared and current interest fully paid
- Increment `paymentCount`
- Transfer payment to lender

#### 5. Repay in Full
```solidity
function repayRollingInFull(uint256 agreementId) external;
```
- Requires `allowEarlyRepay = true` or at payment cap
- Accrue final interest to arrears
- Pay `outstandingPrincipal + arrears` to lender
- Unlock collateral and clear agreement state
- Set status to `Repaid`

#### 6. Exercise
```solidity
function exerciseRolling(uint256 agreementId) external;
```
- Requires `allowEarlyExercise = true`
- Borrower forfeits collateral without penalty
- Distribute collateral to cover arrears + principal
- Refund remainder to borrower
- Set status to `Exercised`

#### 7. Recover (Default)
```solidity
function recoverRolling(uint256 agreementId) external;
```
- Only callable after `nextDue + gracePeriodSeconds`
- Seize collateral and apply penalty
- Distribute: penalty to protocol, remainder covers debt
- Refund surplus to borrower
- Set status to `Defaulted`

### Payment Mechanics

**Interest Calculation** (simple interest, ceiling rounding):
```solidity
interest = (principal * apyBps * durationSeconds) / (365 days * 10_000)
```

**Payment Application Order**:
1. Clear arrears (accumulated missed interest)
2. Pay current interval interest
3. Reduce principal (only if `allowAmortization = true`)

**Schedule Advancement**:
```solidity
if (arrears == 0 && currentInterestFullyPaid) {
    nextDue += paymentIntervalSeconds;
    paymentCount++;
}
```

### Recovery Distribution

```solidity
// Seize collateral
collateralSeized = min(collateralLockAmount, borrowerPrincipal)

// Apply penalty
penaltyBase = outstandingPrincipal + arrears
penalty = (penaltyBase * defaultPenaltyBps) / 10_000
penalty = min(penalty, collateralSeized)

// Distribute remainder
remainingAfterPenalty = collateralSeized - penalty
amountForDebt = min(remainingAfterPenalty, arrears + outstandingPrincipal)
borrowerRefund = remainingAfterPenalty - amountForDebt

// Split debt recovery (4-way split)
protocolShare = (amountForDebt * defaultProtocolBps) / 10_000
feeIndexShare = (amountForDebt * defaultFeeIndexBps) / 10_000
activeCreditShare = (amountForDebt * defaultActiveCreditIndexBps) / 10_000
lenderShare = amountForDebt - protocolShare - feeIndexShare - activeCreditShare
```

### View Functions

```solidity
// Calculate current payment due
function calculateRollingPayment(uint256 agreementId) 
    external view returns (uint256 currentInterestDue, uint256 totalDue);

// Get agreement status flags
function getRollingStatus(uint256 agreementId) 
    external view returns (RollingStatus memory);

// Aggregate borrower exposure
function aggregateRollingExposure(address borrowerKey) 
    external view returns (RollingExposure memory);

struct RollingStatus {
    bool isOverdue;
    bool inGracePeriod;
    bool canRecover;
    bool isAtPaymentCap;
}

struct RollingExposure {
    uint256 totalOutstandingPrincipal;
    uint256 totalArrears;
    uint64 nextPaymentDue;
    uint256 activeAgreementCount;
}
```

---

## 5. Active Credit Index System

### Overview

The Active Credit Index extends the fee index system to provide time-gated subsidies to active credit participants. This creates additional yield for P2P lenders and same-asset borrowers. The system is centralized in `LibActiveCreditIndex.sol` and operates in parallel with the main fee index.

### Participants

- **P2P Lenders**: Earn rewards on `directLent` principal (all asset types)
- **Same-Asset Borrowers**: Earn rewards on same-asset debt (rolling, fixed, direct P2P)

### Time Gate Mechanism

A 24-hour maturity requirement prevents gaming. The system uses hourly bucket scheduling for efficient maturity tracking:

```solidity
// Constants
uint256 public constant TIME_GATE = 24 hours;
uint256 internal constant BUCKET_SIZE = 1 hours;
uint8 internal constant BUCKET_COUNT = 24;

// Time credit calculation
timeCredit = min(24 hours, currentTime - startTime)

// Active weight determination (only mature positions earn rewards)
activeWeight = timeCredit >= 24 hours ? principal : 0
```

### Bucket-Based Maturity Scheduling

The system uses a ring buffer of 24 hourly buckets to efficiently track pending principal:

```solidity
// Pool-level tracking
uint256 activeCreditMaturedTotal;           // Sum of all matured principal
uint64 activeCreditPendingStartHour;        // Start hour for bucket ring
uint8 activeCreditPendingCursor;            // Current bucket cursor
uint256[24] activeCreditPendingBuckets;     // Pending principal by maturity hour
```

When principal is added, it's scheduled into the appropriate future bucket. As time passes, buckets are rolled into `activeCreditMaturedTotal` for reward eligibility.

### Weighted Dilution

Prevents "dust priming" attacks where users start the timer on small amounts then add large amounts:

```solidity
// When adding new principal (P_new) to existing principal (P_old):
newTimeCredit = (P_old * oldTimeCredit + P_new * 0) / (P_old + P_new)
newStartTime = currentTime - newTimeCredit
```

**Anti-Gaming Properties**:
- Adding large amounts to small mature positions dilutes time credit to near zero
- Adding small amounts to large mature positions preserves most time credit
- Mathematical neutralization ensures attackers cannot bypass the 24-hour requirement

### Data Structures

```solidity
struct ActiveCreditState {
    uint256 principal;      // Current exposure amount
    uint40 startTime;       // Weighted dilution timestamp
    uint256 indexSnapshot;  // Last settled activeCreditIndex value
}

// Per-pool tracking in PoolData
uint256 activeCreditIndex;              // Global active credit index
uint256 activeCreditIndexRemainder;     // Remainder for precision
uint256 activeCreditPrincipalTotal;     // Sum of active credit principal
uint256 activeCreditMaturedTotal;       // Matured principal base for accruals

// Per-user state
mapping(bytes32 => ActiveCreditState) userActiveCreditStateP2P;
mapping(bytes32 => ActiveCreditState) userActiveCreditStateDebt;
```

### Fee Sources

Active Credit Index is funded by:
- Platform fees from Direct lending (configurable split)
- Default recovery fees from Direct lending (configurable split)

**Note**: Accrual only produces rewards when the destination pool has non-zero `activeCreditMaturedTotal`.

### Settlement

```solidity
function settle(uint256 pid, bytes32 user) internal {
    // 1. Roll matured buckets into activeCreditMaturedTotal
    _rollMatured(p);
    
    // 2. Settle P2P lender state
    _settleState(p, p.userActiveCreditStateP2P[user], pid, user);
    
    // 3. Settle debt state
    _settleState(p, p.userActiveCreditStateDebt[user], pid, user);
}
```

### Key Events

```solidity
event ActiveCreditIndexAccrued(uint256 indexed pid, uint256 amount, uint256 delta, uint256 newIndex, bytes32 source);
event ActiveCreditSettled(uint256 indexed pid, bytes32 indexed user, uint256 prevIndex, uint256 newIndex, uint256 addedYield, uint256 totalAccruedYield);
event ActiveCreditTimingUpdated(uint256 indexed pid, bytes32 indexed user, bool isDebtState, uint40 startTime, uint256 principal, bool isMature);
```

### Minimum Interest Duration

Protects against short-duration wash trading:

```solidity
// Interest calculation uses max(actualDuration, minInterestDuration)
// Prevents economic gaming through rapid loan cycling
```

---

## 6. Data Models

### Configuration

```solidity
struct DirectConfig {
    uint16 platformFeeBps;                    // Fee on principal (e.g., 50 = 0.5%)
    uint16 platformSplitLenderBps;            // Share to lender
    uint16 platformSplitFeeIndexBps;          // Share to FeeIndex
    uint16 platformSplitProtocolBps;          // Share to protocol
    uint16 platformSplitActiveCreditIndexBps; // Share to Active Credit Index
    uint16 defaultFeeIndexBps;                // Collateral to FeeIndex on default
    uint16 defaultProtocolBps;                // Collateral to protocol on default
    uint16 defaultActiveCreditIndexBps;       // Collateral to Active Credit Index
    uint40 minInterestDuration;               // Minimum interest charge period
    address protocolTreasury;
}

struct DirectRollingConfig {
    uint32 minPaymentIntervalSeconds;
    uint16 maxPaymentCount;
    uint16 maxUpfrontPremiumBps;
    uint16 minRollingApyBps;
    uint16 maxRollingApyBps;
    uint16 defaultPenaltyBps;
    uint64 minPaymentWei;
}
```

### Centralized Encumbrance Storage

All position encumbrance is managed through `LibEncumbrance.sol`:

```solidity
// Storage structure
struct EncumbranceStorage {
    mapping(bytes32 => mapping(uint256 => Encumbrance)) encumbrance;
    mapping(bytes32 => mapping(uint256 => mapping(uint256 => uint256))) encumberedByIndex;
}

struct Encumbrance {
    uint256 directLocked;       // Collateral locked for Direct loans
    uint256 directLent;         // Principal actively lent out
    uint256 directOfferEscrow;  // Principal escrowed for pending offers
    uint256 indexEncumbered;    // Principal encumbered by index positions
}
```

### Centralized Fee Index Storage

Fee index tracking is managed through `LibFeeIndex.sol` with per-pool storage in `PoolData`:

```solidity
// Per-pool fee index state
uint256 feeIndex;                   // Global pool fee index (1e18 scale)
uint256 feeIndexRemainder;          // Per-pool remainder for precision
uint256 yieldReserve;               // Backing reserve for accrued yield claims

// Per-user checkpoints
mapping(bytes32 => uint256) userFeeIndex;       // User's last settled fee index
mapping(bytes32 => uint256) userAccruedYield;   // Accumulated yield ledger
```

### Storage Layout

```solidity
struct DirectStorage {
    // Configuration
    DirectConfig config;
    DirectRollingConfig rollingConfig;
    
    // Term loan tracking
    mapping(uint256 => DirectOffer) offers;
    mapping(uint256 => DirectAgreement) agreements;
    mapping(uint256 => DirectBorrowerOffer) borrowerOffers;
    mapping(uint256 => DirectRatioTrancheOffer) ratioOffers;
    mapping(uint256 => DirectBorrowerRatioTrancheOffer) borrowerRatioOffers;
    uint256 nextOfferId;
    uint256 nextBorrowerOfferId;
    uint256 nextBorrowerRatioOfferId;
    uint256 nextAgreementId;
    
    // Tranche tracking
    mapping(uint256 => uint256) trancheRemaining;
    bool enforceFixedSizeFills;
    
    // Rolling loan tracking
    mapping(uint256 => DirectRollingOffer) rollingOffers;
    mapping(uint256 => DirectRollingAgreement) rollingAgreements;
    mapping(uint256 => DirectRollingBorrowerOffer) rollingBorrowerOffers;
    uint256 nextRollingOfferId;
    uint256 nextRollingBorrowerOfferId;
    uint256 nextRollingAgreementId;
    
    // Position state tracked via LibEncumbrance (centralized)
    // Access: LibEncumbrance.position(positionKey, poolId).directLocked
    // Access: LibEncumbrance.position(positionKey, poolId).directLent
    // Access: LibEncumbrance.position(positionKey, poolId).directOfferEscrow
    
    // Additional Direct-specific tracking
    mapping(bytes32 => mapping(uint256 => uint256)) directBorrowedPrincipal;
    mapping(bytes32 => mapping(address => uint256)) directSameAssetDebt;
    
    // Pool-level tracking
    mapping(uint256 => uint256) activeDirectLentPerPool;
    
    // Linked-list tracking for efficient queries
    LibPositionList.List borrowerAgreements;
    LibPositionList.List lenderAgreements;
    LibPositionList.List lenderOffers;
    LibPositionList.List borrowerOffersByPosition;
    LibPositionList.List ratioLenderOffers;
    LibPositionList.List ratioBorrowerOffers;
    LibPositionList.List rollingBorrowerAgreements;
    LibPositionList.List rollingLenderAgreements;
    LibPositionList.List rollingLenderOffers;
    LibPositionList.List rollingBorrowerOffersByPosition;
}
```

### Position State

Position encumbrance is accessed through the centralized `LibEncumbrance` library:

```solidity
struct PositionDirectState {
    uint256 directLockedPrincipal;   // From LibEncumbrance.directLocked
    uint256 directLentPrincipal;     // From LibEncumbrance.directLent + directOfferEscrow
}

// View function returns per-pool state
function getPositionDirectState(uint256 positionId, uint256 poolId) 
    external view returns (uint256 locked, uint256 lent) {
    bytes32 positionKey = nft.getPositionKey(positionId);
    LibEncumbrance.Encumbrance memory enc = LibEncumbrance.get(positionKey, poolId);
    return (enc.directLocked, enc.directLent + enc.directOfferEscrow);
}
```

---

## 7. Fee Distribution

### Platform Fee Split (4-Way)

Fee distribution uses `LibFeeIndex.accrueWithSource()` for pool-wide yield distribution:

```solidity
function _distributeDirectFees(uint256 platformFee, DirectConfig storage cfg) internal {
    uint256 lenderShare = (platformFee * cfg.platformSplitLenderBps) / 10_000;
    uint256 feeIndexShare = (platformFee * cfg.platformSplitFeeIndexBps) / 10_000;
    uint256 activeCreditShare = (platformFee * cfg.platformSplitActiveCreditIndexBps) / 10_000;
    uint256 protocolShare = platformFee - lenderShare - feeIndexShare - activeCreditShare;
    
    // FeeIndex share distributed via LibFeeIndex.accrueWithSource()
    // Active Credit share distributed via LibActiveCreditIndex.accrueWithSource()
    // Protocol share sent to treasury
    // Lender share added to lender's accrued yield
}
```

### Default Fee Split (4-Way)

```solidity
function _calculateDefaultShares(uint256 collateral, DirectConfig storage cfg) internal {
    uint256 protocolShare = (collateral * cfg.defaultProtocolBps) / 10_000;
    uint256 feeIndexShare = (collateral * cfg.defaultFeeIndexBps) / 10_000;
    uint256 activeCreditShare = (collateral * cfg.defaultActiveCreditIndexBps) / 10_000;
    uint256 lenderShare = collateral - protocolShare - feeIndexShare - activeCreditShare;
}
```

### Interest Calculation

```solidity
function _annualizedInterestAmount(uint256 principal, uint256 aprBps, uint256 durationSeconds) 
    internal pure returns (uint256) 
{
    if (aprBps == 0 || durationSeconds == 0 || principal == 0) return 0;
    uint256 timeScaledRate = aprBps * durationSeconds;
    return Math.mulDiv(principal, timeScaledRate, (365 days) * 10_000);
}
```

### Principal Accounting

**Lender Principal Adjustment**:
- On loan acceptance: `lenderPrincipal -= lentAmount`
- On repayment: `lenderPrincipal += repaidAmount`

**Encumbrance Updates** (via LibEncumbrance):
- Offer posted: `enc.directOfferEscrow += escrowAmount`
- Offer accepted: `enc.directOfferEscrow -= principal; enc.directLent += principal`
- Offer cancelled: `enc.directOfferEscrow -= releaseAmount`
- Loan repaid: `enc.directLent -= principal; enc.directLocked -= collateral`
- Collateral locked: `enc.directLocked += collateralAmount`

**Borrower Fee Base** (normalized to prevent recursive fee inflation):
- Same-Asset P2P: `feeBase = max(0, collateralPrincipal - sameAssetP2PDebt)`
- Cross-Asset P2P: `feeBase = lockedCollateral + unlockedPrincipal`

---

## 8. Error Handling

### Direct-Specific Errors

```solidity
error DirectError_InvalidPositionNFT();
error DirectError_InvalidTimestamp();
error DirectError_ZeroAmount();
error DirectError_InvalidAsset();
error DirectError_InvalidOffer();
error DirectError_InvalidConfiguration();
error DirectError_InvalidAgreementState();
error DirectError_EarlyRepayNotAllowed();
error DirectError_EarlyExerciseNotAllowed();
error DirectError_GracePeriodActive();
error DirectError_GracePeriodExpired();
```

### Rolling-Specific Errors

```solidity
error RollingError_InvalidAPY(uint16 provided, uint16 min, uint16 max);
error RollingError_InvalidGracePeriod(uint32 grace, uint32 interval);
error RollingError_InvalidInterval(uint32 provided, uint32 min);
error RollingError_InvalidPaymentCount(uint16 provided, uint16 max);
error RollingError_ExcessivePremium(uint256 provided, uint256 max);
error RollingError_AmortizationDisabled();
error RollingError_DustPayment(uint256 amount, uint64 min);
error RollingError_RecoveryNotEligible();
```

### Inherited Errors

```solidity
error PoolNotInitialized();
error InsufficientPrincipal(uint256 required, uint256 available);
error NotNFTOwner(address caller, uint256 tokenId);
```

### Fee-on-Transfer Protection

```solidity
function _pullExact(address token, uint256 amount) internal {
    uint256 balanceBefore = IERC20(token).balanceOf(address(this));
    IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
    uint256 received = IERC20(token).balanceOf(address(this)) - balanceBefore;
    require(received == amount, "Direct: insufficient amount received");
}
```

---

## 9. Events

### Term Loan Events

```solidity
event DirectOfferPosted(
    uint256 indexed offerId,
    address indexed borrowAsset,
    uint256 indexed collateralPoolId,
    address lender,
    uint256 lenderPositionId,
    uint256 lenderPoolId,
    address collateralAsset,
    uint256 principal,
    uint16 aprBps,
    uint64 durationSeconds,
    uint256 collateralLockAmount,
    bool isTranche,
    uint256 trancheAmount,
    uint256 trancheRemainingAfter,
    uint256 fillsRemaining,
    uint256 maxFills,
    bool isDepleted
);

event DirectOfferLocator(
    address indexed lender,
    uint256 indexed lenderPositionId,
    uint256 indexed offerId,
    uint256 lenderPoolId,
    uint256 collateralPoolId
);

event DirectOfferCancelled(
    uint256 indexed offerId,
    address indexed lender,
    uint256 indexed lenderPositionId,
    DirectCancelReason reason,
    uint256 trancheAmount,
    uint256 trancheRemainingAfter,
    uint256 amountReturned,
    uint256 fillsRemaining,
    bool isDepleted
);

event DirectOfferAccepted(
    uint256 indexed offerId,
    uint256 indexed agreementId,
    uint256 indexed borrowerPositionId,
    uint256 principalFilled,
    uint256 trancheAmount,
    uint256 trancheRemainingAfter,
    uint256 fillsRemaining,
    bool isDepleted
);

event BorrowerOfferPosted(
    uint256 indexed offerId,
    address indexed borrowAsset,
    uint256 indexed collateralPoolId,
    address borrower,
    uint256 borrowerPositionId,
    uint256 lenderPoolId,
    address collateralAsset,
    uint256 principal,
    uint16 aprBps,
    uint64 durationSeconds,
    uint256 collateralLockAmount
);

event BorrowerOfferLocator(
    address indexed borrower,
    uint256 indexed borrowerPositionId,
    uint256 indexed offerId,
    uint256 lenderPoolId,
    uint256 collateralPoolId
);

event BorrowerOfferCancelled(
    uint256 indexed offerId,
    address indexed borrower,
    uint256 indexed borrowerPositionId
);

event BorrowerOfferAccepted(
    uint256 indexed offerId,
    uint256 indexed agreementId,
    uint256 indexed lenderPositionId
);

event RatioTrancheOfferPosted(
    uint256 indexed offerId,
    address indexed lender,
    uint256 indexed lenderPositionId,
    uint256 lenderPoolId,
    uint256 collateralPoolId,
    address borrowAsset,
    address collateralAsset,
    uint256 principalCap,
    uint256 principalRemainingAfter,
    uint256 priceNumerator,
    uint256 priceDenominator,
    uint256 minPrincipalPerFill,
    uint16 aprBps,
    uint64 durationSeconds
);

event RatioTrancheOfferAccepted(
    uint256 indexed offerId,
    uint256 indexed agreementId,
    uint256 indexed borrowerPositionId,
    uint256 principalFilled,
    uint256 principalRemainingAfter,
    uint256 collateralLocked
);

event RatioTrancheOfferCancelled(
    uint256 indexed offerId,
    address indexed lender,
    uint256 indexed lenderPositionId,
    DirectCancelReason reason,
    uint256 principalReleased
);

event BorrowerRatioTrancheOfferPosted(
    uint256 indexed offerId,
    address indexed borrower,
    uint256 indexed borrowerPositionId,
    uint256 lenderPoolId,
    uint256 collateralPoolId,
    address borrowAsset,
    address collateralAsset,
    uint256 collateralCap,
    uint256 collateralRemainingAfter,
    uint256 priceNumerator,
    uint256 priceDenominator,
    uint256 minCollateralPerFill,
    uint16 aprBps,
    uint64 durationSeconds
);

event BorrowerRatioTrancheOfferAccepted(
    uint256 indexed offerId,
    uint256 indexed agreementId,
    uint256 indexed lenderPositionId,
    uint256 collateralFilled,
    uint256 collateralRemainingAfter,
    uint256 principalAmount
);

event BorrowerRatioTrancheOfferCancelled(
    uint256 indexed offerId,
    address indexed borrower,
    uint256 indexed borrowerPositionId,
    DirectCancelReason reason,
    uint256 collateralReleased
);

event DirectAgreementRepaid(
    uint256 indexed agreementId, 
    address indexed borrower, 
    uint256 principalRepaid
);

event DirectAgreementRecovered(
    uint256 indexed agreementId,
    address indexed executor,
    uint256 lenderShare,
    uint256 protocolShare,
    uint256 feeIndexShare
);

event DirectAgreementExercised(
    uint256 indexed agreementId, 
    address indexed borrower
);

event DirectAgreementCalled(
    uint256 indexed agreementId,
    uint256 indexed lenderPositionId,
    uint64 newDueTimestamp
);
```

### Rolling Loan Events

```solidity
event RollingOfferPosted(
    uint256 indexed offerId,
    address indexed borrowAsset,
    uint256 indexed collateralPoolId,
    address lender,
    uint256 lenderPositionId,
    uint256 lenderPoolId,
    address collateralAsset,
    uint256 principal,
    uint32 paymentIntervalSeconds,
    uint16 rollingApyBps,
    uint32 gracePeriodSeconds,
    uint16 maxPaymentCount,
    uint256 upfrontPremium,
    bool allowAmortization,
    bool allowEarlyRepay,
    bool allowEarlyExercise,
    uint256 collateralLockAmount
);

event RollingOfferLocator(
    address indexed lender,
    uint256 indexed lenderPositionId,
    uint256 indexed offerId,
    uint256 lenderPoolId,
    uint256 collateralPoolId
);

event RollingBorrowerOfferPosted(
    uint256 indexed offerId,
    address indexed borrowAsset,
    uint256 indexed collateralPoolId,
    address borrower,
    uint256 borrowerPositionId,
    uint256 lenderPoolId,
    address collateralAsset,
    uint256 principal,
    uint32 paymentIntervalSeconds,
    uint16 rollingApyBps,
    uint32 gracePeriodSeconds,
    uint16 maxPaymentCount,
    uint256 upfrontPremium,
    bool allowAmortization,
    bool allowEarlyRepay,
    bool allowEarlyExercise,
    uint256 collateralLockAmount
);

event RollingBorrowerOfferLocator(
    address indexed borrower,
    uint256 indexed borrowerPositionId,
    uint256 indexed offerId,
    uint256 lenderPoolId,
    uint256 collateralPoolId
);

event RollingOfferCancelled(
    uint256 indexed offerId, 
    bool indexed isBorrowerOffer, 
    address indexed caller
);

event RollingOfferAccepted(
    uint256 indexed offerId, 
    uint256 indexed agreementId, 
    address indexed borrower
);

event RollingPaymentMade(
    uint256 indexed agreementId,
    address indexed payer,
    uint256 paymentAmount,
    uint256 arrearsReduction,
    uint256 interestPaid,
    uint256 principalReduction,
    uint64 nextDue,
    uint16 paymentCount,
    uint256 newOutstandingPrincipal,
    uint256 newArrears
);

event RollingAgreementRecovered(
    uint256 indexed agreementId,
    address indexed executor,
    uint256 penaltyPaid,
    uint256 arrearsPaid,
    uint256 principalRecovered,
    uint256 borrowerRefund,
    uint256 protocolShare,
    uint256 feeIndexShare,
    uint256 activeCreditShare
);

event RollingAgreementExercised(
    uint256 indexed agreementId,
    address indexed borrower,
    uint256 arrearsPaid,
    uint256 principalRecovered,
    uint256 borrowerRefund
);

event RollingAgreementRepaid(
    uint256 indexed agreementId,
    address indexed borrower,
    uint256 repaymentAmount,
    uint256 arrearsCleared,
    uint256 principalCleared
);
```

### Active Credit Index Events

```solidity
event ActiveCreditIndexAccrued(
    uint256 indexed pid, 
    uint256 amount, 
    uint256 delta, 
    uint256 newIndex, 
    bytes32 source
);

event ActiveCreditSettled(
    uint256 indexed pid, 
    bytes32 indexed user, 
    uint256 prevIndex, 
    uint256 newIndex, 
    uint256 addedYield, 
    uint256 totalAccruedYield
);

event ActiveCreditTimingUpdated(
    uint256 indexed pid,
    bytes32 indexed user,
    bool isDebtState,
    uint40 startTime,
    uint256 principal,
    bool isMature
);
```

### Encumbrance Events

```solidity
event EncumbranceIncreased(
    bytes32 indexed positionKey,
    uint256 indexed poolId,
    uint256 indexed indexId,
    uint256 amount,
    uint256 totalEncumbered,
    uint256 indexEncumbered
);

event EncumbranceDecreased(
    bytes32 indexed positionKey,
    uint256 indexed poolId,
    uint256 indexed indexId,
    uint256 amount,
    uint256 totalEncumbered,
    uint256 indexEncumbered
);
```

### Fee Index Events

```solidity
event FeeIndexAccrued(
    uint256 indexed pid, 
    uint256 amount, 
    uint256 delta, 
    uint256 newIndex, 
    bytes32 source
);

event YieldSettled(
    uint256 indexed pid,
    bytes32 indexed user,
    uint256 prevIndex,
    uint256 newIndex,
    uint256 addedYield,
    uint256 totalAccruedYield
);
```

---

## 10. Testing Strategy

### Unit Testing

Unit tests focus on:
- Specific examples demonstrating correct behavior for each function
- Edge cases around timing (due timestamps, grace periods)
- Integration points with existing Equalis systems
- Error conditions and proper revert messages
- Event emission with correct parameters
- Configuration validation scenarios

**Key Categories**:
- Offer lifecycle tests (post, cancel, accept)
- Agreement lifecycle tests (repay, recover, exercise)
- Payment mechanics tests (arrears, amortization)
- Position state management tests
- Fee calculation and distribution tests
- Solvency integration tests

### Property-Based Testing

Property-based tests verify universal properties across all valid inputs using Foundry's property testing framework with minimum 100 iterations.

**Core Properties**:

1. **Ownership Validation**: All Direct operations require Position NFT ownership
2. **Capacity Management**: `LibEncumbrance.total(positionKey, poolId) <= userPrincipal` per pool
3. **Tranche Conservation**: `trancheRemaining + converted = trancheAmount`
4. **Fee Distribution Accuracy**: Fee splits sum correctly with normalized fee base
5. **State Consistency**: Cumulative exposure accurately reflects all active agreements
6. **Lifecycle Integrity**: State transitions are atomic and update all related state
7. **Timing Controls**: Repayment and exercise respect configured flags
8. **Solvency Integration**: Per-pool encumbrance (via LibEncumbrance) treated as debt-like exposure
9. **Configuration Validation**: Basis point values sum correctly
10. **Event Completeness**: All operations emit appropriate events

### Integration Testing

Integration tests verify:
- Proper interaction with Equalis withdrawal restrictions
- Correct integration with solvency check systems
- FeeIndex and Active Credit Index distribution mechanics
- Position NFT ownership validation
- Cross-pool agreement scenarios
- Position transfer behavior (offer cancellation)

### Test Scenarios

**Term Loan Scenarios**:
- Single and multiple agreement scenarios
- Early exercise with different timing combinations
- Grace period edge cases
- Tranche-backed offer fills and depletion
- Cross-asset default recovery

**Rolling Loan Scenarios**:
- Multi-period payment sequences
- Arrears accumulation and clearing
- Amortization with principal reduction
- Grace period recovery timing
- Payment cap enforcement

**Cross-Cutting Scenarios**:
- Per-pool exposure isolation
- Active Credit Index time gate behavior
- Weighted dilution anti-gaming
- Position transfer with active agreements

---

## Appendix: Correctness Properties

### Property 1: Ownership Validation
For any Direct operation, the caller must own the specified Position NFT.

### Property 2: Capacity Management
For any Position NFT and pool, `LibEncumbrance.total(positionKey, poolId) <= userPrincipal`.

### Property 3: Tranche Conservation
For tranche-backed offers, `trancheRemaining + converted = trancheAmount`.

### Property 4: Fee Distribution Accuracy
Fee calculations follow configured splits exactly with normalized fee base.

### Property 5: State Consistency
Cumulative exposure per pool accurately reflects all active agreements.

### Property 6: Lifecycle Integrity
State transitions are atomic and correctly update all related Position state.

### Property 7: Timing Controls
Repayment and exercise operations respect `allowEarlyRepay` and `allowEarlyExercise` flags.

### Property 8: Solvency Integration
Per-pool `directLent` (from LibEncumbrance) is included as debt-like exposure in solvency checks.

### Property 9: Configuration Validation
Platform splits sum to 10000, default splits sum to ≤10000.

### Property 10: Event Completeness
All operations emit appropriate events with correct parameters.

### Property 11: Recovery Timing
Recovery only callable after grace period; repayment available during grace period.

### Property 12: Principal Accounting
Lender principal immediately reduced on acceptance, restored on repayment.

### Property 13: Per-Pool Isolation
Direct exposure tracked independently per pool via LibEncumbrance with no cross-pool interference.

### Property 14: Rolling Payment Order
Payments apply to arrears first, then current interest, then principal (if allowed).

### Property 15: Active Credit Time Gate
Active Credit rewards only accrue after 24-hour maturity with weighted dilution.

---

**Document Version:** 6.0
