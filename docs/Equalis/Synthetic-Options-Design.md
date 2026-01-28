# Synthetic Options via Direct Lending

This document describes how the EqualLend Direct lending rail can be used to create synthetic call and put option payoffs without requiring dedicated option contracts or price oracles.

## Table of Contents

1. [Overview](#overview)
2. [How It Works](#how-it-works)
3. [Synthetic Call Options](#synthetic-call-options)
4. [Synthetic Put Options](#synthetic-put-options)
5. [Architecture](#architecture)
6. [Agreement Lifecycle](#agreement-lifecycle)
7. [Configuration Options](#configuration-options)
8. [Integration Guide](#integration-guide)
9. [Worked Examples](#worked-examples)
10. [Comparison with Explicit Options](#comparison-with-explicit-options)

---

## Overview

The EqualLend Direct lending rail enables option-like payoffs through a clever use of collateralized lending mechanics. The key insight is that a borrower's terminal choice—**repay** or **exercise/default**—maps directly to the economic decision of whether to exercise an option.

### Key Characteristics

| Feature | Description |
|---------|-------------|
| **No Oracles** | Strike price is implicit in the collateral/principal ratio |
| **Non-Recourse** | Borrower can walk away, forfeiting only locked collateral |
| **Upfront Premium** | Interest paid at loan origination acts as option premium |
| **Physical Settlement** | Assets are exchanged, not cash-settled |
| **Flexible Exercise** | American or European style via `allowEarlyExercise` flag |
| **Centralized Encumbrance** | Collateral tracked via unified `LibEncumbrance` system |
| **Centralized Fee Routing** | Default fees distributed via `LibFeeRouter` (ACI/FI/Treasury) |

### The Core Mechanism

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        BORROWER'S TERMINAL CHOICE                        │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│   REPAY the borrowed asset          EXERCISE/DEFAULT and forfeit         │
│   + unlock collateral               collateral to lender                 │
│            │                                    │                        │
│            ▼                                    ▼                        │
│   ┌─────────────────┐                ┌─────────────────┐                │
│   │  "Don't Exercise │                │    "Exercise"    │                │
│   │   the Option"    │                │   the Option"    │                │
│   └─────────────────┘                └─────────────────┘                │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

The "strike price" is not computed on-chain. It's implied by the fixed quantities the offer sets: `(principal, collateralLockAmount)` and expiry. There's no on-chain LTV check or price conversion—the lender chooses collateral size explicitly.

---

## How It Works

### The Lending Agreement as an Option

A Direct lending agreement has these key parameters:

```solidity
struct DirectAgreement {
    address borrowAsset;           // Asset the borrower receives
    address collateralAsset;       // Asset locked as collateral
    uint256 principal;             // Amount borrowed
    uint256 collateralLockAmount;  // Amount of collateral locked
    uint64 dueTimestamp;           // Expiration date
    uint256 userInterest;          // Premium (paid upfront)
    bool allowEarlyExercise;       // American vs European style
    bool allowEarlyRepay;          // Can repay before expiry
    bool allowLenderCall;          // Lender can accelerate expiry
}
```

### Implied Strike Price

The strike price is implicitly defined by the ratio:

```
Implied Strike = collateralLockAmount / principal
```

For example:
- Borrow 1 ETH, lock 2000 USDC → Implied strike = $2000/ETH
- Borrow 2000 USDC, lock 1 ETH → Implied strike = $2000/ETH

### Payoff at Expiry

The borrower's rational choice at expiry depends on market price:

| Market Price vs Strike | Borrower Action | Economic Outcome |
|------------------------|-----------------|------------------|
| Favorable to exercise | Exercise/Default | Keep borrowed asset, forfeit collateral |
| Unfavorable to exercise | Repay | Return borrowed asset, recover collateral |

---

## Synthetic Call Options

A synthetic call gives the holder (borrower) the right to buy the underlying asset at the strike price.

### Structure

To create a synthetic call on ETH with strike K:

```
┌─────────────────────────────────────────────────────────────────┐
│                     SYNTHETIC CALL SETUP                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   Borrower receives:    Q ETH (the underlying)                  │
│   Borrower locks:       K × Q USDC (strike × size)              │
│   Borrower pays:        Interest upfront (the premium)          │
│   Expiry:               T (the option expiration)               │
│                                                                  │
│   borrowAsset = ETH                                             │
│   collateralAsset = USDC                                        │
│   principal = Q ETH                                             │
│   collateralLockAmount = K × Q USDC                             │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Payoff Analysis

**At expiry, if ETH price > K (in the money):**
- Borrower exercises (defaults): keeps Q ETH, forfeits K×Q USDC
- Net position: Bought ETH at strike K
- Profit: (Market Price - K) × Q - Premium

**At expiry, if ETH price < K (out of the money):**
- Borrower repays: returns Q ETH, recovers K×Q USDC
- Net position: No ETH exposure
- Loss: Premium only

### Payoff Diagram

```
Profit
  │
  │                              ╱
  │                            ╱
  │                          ╱
  │                        ╱
  │──────────────────────●─────────────── ETH Price
  │                      K
  │
  │    Loss = Premium
  │
```

---

## Synthetic Put Options

A synthetic put gives the holder (borrower) the right to sell the underlying asset at the strike price.

### Structure

To create a synthetic put on ETH with strike K:

```
┌─────────────────────────────────────────────────────────────────┐
│                      SYNTHETIC PUT SETUP                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   Borrower receives:    K × Q USDC (strike × size)              │
│   Borrower locks:       Q ETH (the underlying)                  │
│   Borrower pays:        Interest upfront (the premium)          │
│   Expiry:               T (the option expiration)               │
│                                                                  │
│   borrowAsset = USDC                                            │
│   collateralAsset = ETH                                         │
│   principal = K × Q USDC                                        │
│   collateralLockAmount = Q ETH                                  │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Payoff Analysis

**At expiry, if ETH price < K (in the money):**
- Borrower exercises (defaults): keeps K×Q USDC, forfeits Q ETH
- Net position: Sold ETH at strike K
- Profit: (K - Market Price) × Q - Premium

**At expiry, if ETH price > K (out of the money):**
- Borrower repays: returns K×Q USDC, recovers Q ETH
- Net position: Still holds ETH
- Loss: Premium only

### Payoff Diagram

```
Profit
  │
  │  ╲
  │    ╲
  │      ╲
  │        ╲
  │──────────●──────────────────────────── ETH Price
  │          K
  │
  │                    Loss = Premium
  │
```

---

## Architecture

### Contract Structure

```
src/equallend-direct/
├── EqualLendDirectOfferFacet.sol      # Post and cancel offers
├── EqualLendDirectAgreementFacet.sol  # Accept offers, create agreements
├── EqualLendDirectLifecycleFacet.sol  # Repay, exercise, recover
├── LibDirectExercise.sol              # Shared exercise/default logic
└── IDirectOfferEvents.sol             # Event definitions

src/libraries/
├── DirectTypes.sol                    # Data structures
├── LibDirectStorage.sol               # Diamond storage
├── LibDirectHelpers.sol               # Utility functions
├── LibEncumbrance.sol                 # Centralized encumbrance tracking
├── LibFeeRouter.sol                   # Centralized fee routing (ACI/FI/Treasury)
└── LibActiveCreditIndex.sol           # Active credit index accounting
```

### Data Structures

**Offer (Lender-Posted):**
```solidity
struct DirectOffer {
    uint256 offerId;
    address lender;
    uint256 lenderPositionId;
    uint256 lenderPoolId;           // Pool providing borrowed asset
    uint256 collateralPoolId;       // Pool for collateral
    address collateralAsset;
    address borrowAsset;
    uint256 principal;              // Amount to lend
    uint16 aprBps;                  // Interest rate (premium)
    uint64 durationSeconds;         // Time to expiry
    uint256 collateralLockAmount;   // Required collateral (defines strike)
    bool allowEarlyRepay;
    bool allowEarlyExercise;        // American style if true
    bool allowLenderCall;           // Lender can accelerate
    // ... status flags
}
```

**Agreement (Active Position):**
```solidity
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
    uint256 userInterest;           // Premium paid
    uint64 dueTimestamp;            // Expiry
    uint256 collateralLockAmount;   // Locked collateral
    bool allowEarlyRepay;
    bool allowEarlyExercise;
    bool allowLenderCall;
    DirectStatus status;            // Active, Repaid, Defaulted, Exercised
    bool interestRealizedUpfront;   // Whether interest was deducted at acceptance
}
```

### Agreement Status Flow

```
                    ┌─────────┐
                    │  Active │
                    └────┬────┘
                         │
         ┌───────────────┼───────────────┐
         │               │               │
         ▼               ▼               ▼
    ┌─────────┐    ┌──────────┐    ┌───────────┐
    │  Repaid │    │ Exercised│    │ Defaulted │
    └─────────┘    └──────────┘    └───────────┘
    (borrower      (borrower       (anyone after
     repays)        exercises)      grace period)
```

---

## Agreement Lifecycle

### 1. Offer Creation

**Lender posts offer:**
```solidity
function postOffer(DirectOfferParams calldata params) external returns (uint256 offerId);
```

**Borrower posts offer:**
```solidity
function postBorrowerOffer(DirectBorrowerOfferParams calldata params) external returns (uint256 offerId);
```

### 2. Agreement Acceptance

**Borrower accepts lender offer:**
```solidity
function acceptOffer(uint256 offerId, uint256 borrowerPositionId) external returns (uint256 agreementId);
```

**Lender accepts borrower offer:**
```solidity
function acceptBorrowerOffer(uint256 offerId, uint256 lenderPositionId) external returns (uint256 agreementId);
```

**What happens at acceptance:**
1. Borrower's collateral is locked
2. Interest (premium) is deducted from principal
3. Net principal is transferred to borrower
4. Agreement record is created

### 3. During the Agreement

The borrower holds the borrowed asset and can use it freely. The collateral remains locked in the borrower's position.

### 4. At Expiry

**Option A: Repay (Don't Exercise)**
```solidity
function repay(uint256 agreementId) external;
```
- Borrower returns the principal
- Collateral is unlocked
- Agreement status → `Repaid`

**Option B: Exercise**
```solidity
function exerciseDirect(uint256 agreementId) external;
```
- Borrower keeps the borrowed asset
- Collateral is transferred to lender
- Agreement status → `Exercised`

**Option C: Default (After Grace Period)**
```solidity
function recover(uint256 agreementId) external;
```
- Anyone can call after grace period expires
- Collateral is distributed (lender, protocol, fee index)
- Agreement status → `Defaulted`

### 5. Timing Windows

```
                    dueTimestamp              dueTimestamp + 1 day
                         │                           │
─────────────────────────┼───────────────────────────┼─────────────────────►
                         │                           │                  time
     ◄─────────────────► │ ◄───────────────────────► │ ◄──────────────►
     Early Period        │      Grace Period         │   Recovery Period
                         │                           │
     • Early repay       │  • Repay allowed          │  • recover() enabled
       (if allowed)      │  • Exercise allowed       │  • Borrower loses
     • Early exercise    │                           │    collateral
       (if allowed)      │                           │
```

---

## Configuration Options

### Exercise Style

| Flag | Value | Behavior |
|------|-------|----------|
| `allowEarlyExercise` | `true` | American style - exercise anytime before expiry |
| `allowEarlyExercise` | `false` | European style - exercise only at/after expiry |

### Repayment Flexibility

| Flag | Value | Behavior |
|------|-------|----------|
| `allowEarlyRepay` | `true` | Can repay anytime |
| `allowEarlyRepay` | `false` | Can only repay within grace window |

### Lender Call

| Flag | Value | Behavior |
|------|-------|----------|
| `allowLenderCall` | `true` | Lender can accelerate `dueTimestamp` to now |
| `allowLenderCall` | `false` | Expiry is fixed |

The lender call feature allows the option writer to force early expiration, useful for managing risk.

### Platform Configuration

The platform configuration uses a centralized fee routing system:

```solidity
struct DirectConfig {
    uint16 platformFeeBps;        // Platform fee on premium
    uint16 interestLenderBps;     // Lender's share of interest
    uint16 platformFeeLenderBps;  // Lender's share of platform fee
    uint16 defaultLenderBps;      // Lender's share on default/exercise
    uint40 minInterestDuration;   // Minimum duration for interest calc
}
```

### Default/Exercise Fee Distribution

When a borrower exercises or defaults, collateral is distributed using the centralized `LibFeeRouter`:

```solidity
// Calculate shares using LibFeeRouter.previewSplit for protocol portion
lenderShare = collateral × defaultLenderBps / 10_000;
remainder = collateral - lenderShare;

// LibFeeRouter splits remainder between:
// - Treasury (treasurySplitBps)
// - Active Credit Index (activeCreditSplitBps)  
// - Fee Index (remainder)
(protocolShare, activeCreditShare, feeIndexShare) = LibFeeRouter.previewSplit(remainder);
```

| Recipient | Source | Purpose |
|-----------|--------|---------|
| **Lender** | `defaultLenderBps` of collateral | Compensation for exercised option |
| **Treasury** | `treasurySplitBps` of remainder | Protocol revenue |
| **Active Credit Index** | `activeCreditSplitBps` of remainder | Rewards for active borrowers |
| **Fee Index** | Remaining portion | Rewards for pool depositors |

---

## Integration Guide

### For Developers

#### Creating a Synthetic Call Offer (Lender Side)

```solidity
// Lender wants to write a covered call: sell ETH at $2500 strike
DirectTypes.DirectOfferParams memory params = DirectTypes.DirectOfferParams({
    lenderPositionId: myPositionId,
    lenderPoolId: wethPoolId,           // Lender provides ETH
    collateralPoolId: usdcPoolId,       // Borrower locks USDC
    collateralAsset: usdc,
    borrowAsset: weth,
    principal: 1e18,                    // 1 ETH
    aprBps: 500,                        // 5% APR (premium)
    durationSeconds: 30 days,
    collateralLockAmount: 2500e6,       // $2500 USDC (strike × size)
    allowEarlyRepay: true,
    allowEarlyExercise: false,          // European style
    allowLenderCall: false
});

uint256 offerId = directOfferFacet.postOffer(params);
```

#### Accepting a Synthetic Call (Borrower Side)

```solidity
// Borrower accepts the call offer
uint256 agreementId = directAgreementFacet.acceptOffer(offerId, borrowerPositionId);

// Borrower now has:
// - Received ~0.99 ETH (1 ETH minus premium)
// - Locked 2500 USDC as collateral
```

#### Exercising the Option

```solidity
// At expiry, if ETH > $2500, borrower exercises
directLifecycleFacet.exerciseDirect(agreementId);

// Borrower keeps the ETH, forfeits 2500 USDC to lender
```

#### Repaying (Not Exercising)

```solidity
// At expiry, if ETH < $2500, borrower repays
weth.approve(diamond, 1e18);
directLifecycleFacet.repay(agreementId);

// Borrower returns 1 ETH, recovers 2500 USDC
```

### For Users

#### Buying a Synthetic Call

1. **Find an offer** where you borrow the underlying (e.g., ETH) and lock stablecoins
2. **Check the implied strike**: `collateralLockAmount / principal`
3. **Check the premium**: Interest rate × duration
4. **Accept the offer** using your Position NFT
5. **At expiry**:
   - If price > strike: Exercise to keep the asset
   - If price < strike: Repay to recover your stablecoins

#### Buying a Synthetic Put

1. **Find an offer** where you borrow stablecoins and lock the underlying
2. **Check the implied strike**: `principal / collateralLockAmount`
3. **Check the premium**: Interest rate × duration
4. **Accept the offer** using your Position NFT
5. **At expiry**:
   - If price < strike: Exercise to keep the stablecoins
   - If price > strike: Repay to recover your underlying

#### Writing Options (Lender Side)

1. **Deposit liquidity** into a Position NFT
2. **Post an offer** with your desired:
   - Strike price (via collateral/principal ratio)
   - Premium (via APR)
   - Expiry (via duration)
   - Exercise style (via flags)
3. **Wait for acceptance**
4. **At expiry**:
   - If exercised: Receive collateral at strike price
   - If repaid: Receive principal back + keep premium

---

## Worked Examples

### Example 1: Synthetic Call on ETH

**Scenario:** Alice wants to buy a 30-day call on 1 ETH with $2000 strike.

**Setup:**
- Current ETH price: $1800
- Alice has 2000 USDC in her Position NFT
- Bob (lender) has 1 ETH in his Position NFT

**Step 1: Bob posts the offer**
```solidity
DirectOfferParams({
    lenderPositionId: bobPositionId,
    lenderPoolId: wethPoolId,
    collateralPoolId: usdcPoolId,
    collateralAsset: usdc,
    borrowAsset: weth,
    principal: 1e18,              // 1 ETH
    aprBps: 1200,                 // 12% APR
    durationSeconds: 30 days,
    collateralLockAmount: 2000e6, // $2000 USDC
    allowEarlyExercise: false,    // European
    ...
});
```

**Step 2: Alice accepts**
- Premium calculation: 1 ETH × 12% × (30/365) ≈ 0.01 ETH
- Alice receives: ~0.99 ETH
- Alice locks: 2000 USDC

**Step 3a: At expiry, ETH = $2500 (ITM)**
```solidity
// Alice exercises
directLifecycleFacet.exerciseDirect(agreementId);
```
- Alice keeps 0.99 ETH (worth $2475)
- Alice forfeits 2000 USDC
- Alice's profit: $2475 - $2000 = $475 (minus premium value)
- Bob receives: 2000 USDC (sold ETH at $2000)

**Step 3b: At expiry, ETH = $1500 (OTM)**
```solidity
// Alice repays
weth.approve(diamond, 1e18);
directLifecycleFacet.repay(agreementId);
```
- Alice returns 1 ETH
- Alice recovers 2000 USDC
- Alice's loss: Premium only (~0.01 ETH ≈ $15)
- Bob keeps: Premium (~0.01 ETH)

### Example 2: Synthetic Put on ETH

**Scenario:** Charlie wants to buy a 14-day put on 2 ETH with $1800 strike.

**Setup:**
- Current ETH price: $2000
- Charlie has 2 ETH in his Position NFT
- Diana (lender) has 3600 USDC in her Position NFT

**Step 1: Diana posts the offer**
```solidity
DirectOfferParams({
    lenderPositionId: dianaPositionId,
    lenderPoolId: usdcPoolId,
    collateralPoolId: wethPoolId,
    collateralAsset: weth,
    borrowAsset: usdc,
    principal: 3600e6,            // $3600 USDC (2 × $1800)
    aprBps: 2400,                 // 24% APR
    durationSeconds: 14 days,
    collateralLockAmount: 2e18,   // 2 ETH
    allowEarlyExercise: true,     // American
    ...
});
```

**Step 2: Charlie accepts**
- Premium: $3600 × 24% × (14/365) ≈ $33
- Charlie receives: ~$3567 USDC
- Charlie locks: 2 ETH

**Step 3a: ETH drops to $1500 (ITM)**
```solidity
// Charlie exercises early (American style)
directLifecycleFacet.exerciseDirect(agreementId);
```
- Charlie keeps $3567 USDC
- Charlie forfeits 2 ETH (worth $3000)
- Charlie's profit: $3567 - $3000 = $567
- Diana receives: 2 ETH (bought at $1800 each)

**Step 3b: ETH rises to $2200 (OTM)**
```solidity
// Charlie repays
usdc.approve(diamond, 3600e6);
directLifecycleFacet.repay(agreementId);
```
- Charlie returns $3600 USDC
- Charlie recovers 2 ETH (worth $4400)
- Charlie's loss: ~$33 premium
- Diana keeps: ~$33 premium

### Example 3: Lender Call Feature

**Scenario:** Eve writes a call but wants the ability to force early expiration.

**Setup:**
```solidity
DirectOfferParams({
    ...
    allowLenderCall: true,  // Enable lender call
    ...
});
```

**During the agreement:**
If Eve sees the market moving against her, she can call:
```solidity
directLifecycleFacet.callDirect(agreementId);
```

This sets `dueTimestamp = block.timestamp`, forcing the borrower to immediately decide: repay or exercise within the grace period.

---

## Comparison with Explicit Options

| Aspect | Synthetic (Direct) | Explicit (OptionsFacet) |
|--------|-------------------|------------------------|
| **Token Representation** | No token, just agreement | ERC-1155 tokens |
| **Transferability** | Not transferable | Freely tradeable |
| **Strike Price** | Implicit in collateral ratio | Explicit parameter |
| **Premium** | Interest paid upfront | Separate from collateral |
| **Settlement** | Repay vs Exercise choice | Exercise function |
| **Collateral** | Borrower locks collateral | Maker locks collateral |
| **Oracle Dependency** | None | None |
| **Gas Efficiency** | Single agreement | Token minting overhead |
| **Composability** | Limited | High (ERC-1155) |

### When to Use Synthetic Options

- **OTC deals**: Direct negotiation between two parties
- **Simple hedging**: One-off protection without token overhead
- **Privacy**: No public token transfers
- **Gas savings**: Fewer contract interactions

### When to Use Explicit Options

- **Secondary markets**: Need to trade the option
- **Multiple holders**: Split option across parties
- **Standardization**: Want fungible option tokens
- **Integration**: Other protocols can interact with ERC-1155

---

## Error Reference

| Error | Cause |
|-------|-------|
| `DirectError_InvalidOffer` | Offer doesn't exist, cancelled, or filled |
| `DirectError_InvalidAgreementState` | Agreement not active |
| `DirectError_EarlyExerciseNotAllowed` | Trying to exercise before expiry (European) |
| `DirectError_EarlyRepayNotAllowed` | Trying to repay before allowed window |
| `DirectError_GracePeriodActive` | Trying to recover before grace period ends |
| `DirectError_GracePeriodExpired` | Trying to repay/exercise after grace period |
| `DirectError_LenderCallNotAllowed` | Lender call not enabled for this agreement |
| `DirectError_InvalidTimestamp` | Invalid time parameter |
| `DirectError_InvalidConfiguration` | Missing treasury or invalid config |
| `InsufficientPrincipal` | Not enough available principal |

---

## Events

```solidity
// Offer lifecycle
event DirectOfferPosted(uint256 indexed offerId, ...);
event DirectOfferCancelled(uint256 indexed offerId, ...);
event BorrowerOfferPosted(uint256 indexed offerId, ...);
event BorrowerOfferCancelled(uint256 indexed offerId, ...);

// Agreement lifecycle
event DirectOfferAccepted(uint256 indexed offerId, uint256 indexed agreementId, ...);
event BorrowerOfferAccepted(uint256 indexed offerId, uint256 indexed agreementId, ...);
event DirectAgreementRepaid(uint256 indexed agreementId, address indexed borrower, uint256 principalRepaid);
event DirectAgreementExercised(uint256 indexed agreementId, address indexed borrower);
event DirectAgreementRecovered(uint256 indexed agreementId, address indexed executor, ...);
event DirectAgreementCalled(uint256 indexed agreementId, uint256 indexed lenderPositionId, uint64 newDueTimestamp);
```

---

## Security Considerations

1. **Non-Recourse Nature**: Borrowers can always walk away, forfeiting only locked collateral. Lenders must price this risk into the premium.

2. **No Oracle Risk**: Strike prices are fixed at agreement creation. No manipulation possible through price feeds.

3. **Grace Period Protection**: 1-day grace period prevents accidental defaults due to timing issues.

4. **Centralized Encumbrance Tracking**: Collateral is tracked through `LibEncumbrance`, which maintains separate tracking for:
   - `directLocked`: Collateral locked by borrowers
   - `directLent`: Principal lent by lenders
   - `directOfferEscrow`: Principal escrowed for open offers
   - `indexEncumbered`: Principal encumbered for index tokens
   
   This centralized design ensures accurate available principal calculations across all protocol features.

5. **Reentrancy Protection**: All lifecycle functions use `nonReentrant` modifier.

6. **Position NFT Ownership**: Only the Position NFT owner can repay or exercise.

7. **Solvency Checks**: Both lender and borrower positions are checked for solvency before agreement creation.

8. **Active Credit Index Integration**: Both lender P2P exposure and borrower debt are tracked in the Active Credit Index for proper yield distribution.

9. **Centralized Fee Routing**: Default/exercise fees are routed through `LibFeeRouter` ensuring consistent distribution to Treasury, ACI, and Fee Index.

---

**Document Version:** 1.1
**Last Updated:** January 2026

*Changes in 1.1: Updated to reflect centralized encumbrance system (LibEncumbrance), centralized fee routing (LibFeeRouter with ACI/FI/Treasury split), simplified DirectConfig structure, and Active Credit Index integration.*
