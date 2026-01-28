# Equalis Protocol - Design Document

**Version:** 9.0  

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [System Architecture](#system-architecture)
3. [Core Design Principles](#core-design-principles)
4. [Component Specifications](#component-specifications)
5. [Data Models and Storage](#data-models-and-storage)
6. [Protocol Mechanics](#protocol-mechanics)
7. [Security Model](#security-model)
8. [Integration Points](#integration-points)
9. [Testing Strategy](#testing-strategy)
10. [Deployment and Operations](#deployment-and-operations)
11. [Position NFT Derivatives](#position-nft-derivatives)

---

## 1. Executive Summary

### 1.1 Protocol Overview

Equalis is a deterministic, lossless credit primitive that replaces price-based liquidations and utilization curves with time-based credit and account-level accounting. The protocol implements a lending system where:

- **No liquidations via oracles**: Credit risk is bounded by deterministic rates, terms, and loan-to-value parameters
- **Account-level solvency**: Each account's obligations are always covered by their own locked principal
- **Lossless deposits**: Depositors cannot lose principal due to other users' actions or failures
- **Isolated pools**: Each pool maintains independent accounting with no cross-pool contagion risk

### 1.2 Key Innovations

1. **Position NFT System**: Each user position is represented as an ERC-721 NFT, enabling transferable account containers with all associated deposits, loans, and yield
2. **Dual Index Accounting**: FeeIndex (monotone increasing) for yield distribution and MaintenanceIndex for proportional fee deduction with normalized fee base calculation
3. **Zero-Interest Self-Secured Credit**: Self-secured same-asset borrowing has no interest charges - borrowers repay exactly the principal borrowed, with protocol revenue derived from usage-based fees (flashloans, MAM curves) rather than interest
4. **Oracle-Free Cross-Asset Lending**: Equalis Direct enables true P2P lending between any assets without price oracles - lenders set their own cross-asset terms and collateral ratios
5. **Equalis Direct Term Loans**: Peer-to-peer term lending with optional early exercise (American-style settlement), configurable prepayment policies, and borrower-initiated offers
6. **Equalis Direct Rolling Loans**: Peer-to-peer rolling credit with periodic payments, arrears tracking, amortization support, and configurable grace periods
7. **Ratio Tranche Offers**: CLOB-style offers with price ratios for variable-size fills, enabling order book-like trading dynamics for both lenders and borrowers
8. **Active Credit Index**: Time-gated fee subsidies for active credit participants (P2P lenders and same-asset borrowers) with weighted dilution anti-gaming protection
9. **Penalty-Based Default Settlement**: Fixed 5% penalty system for loan defaults instead of full liquidation, ensuring proportional and predictable outcomes
10. **Normalized Principal Accounting**: Fee base calculations prevent recursive fee inflation while maintaining lending expressiveness across same-asset and cross-asset domains
11. **EqualIndex Integration**: Multi-asset index token system with deterministic fee structures
12. **Diamond Architecture**: Modular facet-based design enabling upgradability while maintaining storage isolation
13. **Position NFT Derivatives**: Oracle-free AMM Auctions, Options, Futures, and Maker Auction Markets using Position NFTs as the universal identity and Pools as unified collateral source

---

## 2. System Architecture

### 2.1 High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Equalis Diamond                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐           │
│  │   Lending    │  │   Penalty    │  │   Position   │           │
│  │    Facet     │  │    Facet     │  │  Management  │           │
│  └──────────────┘  └──────────────┘  └──────────────┘           │
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐           │
│  │  FlashLoan   │  │   Equalis    │  │  EqualIndex  │           │
│  │    Facet     │  │    Direct    │  │   FacetV3    │           │
│  └──────────────┘  └──────────────┘  └──────────────┘           │
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐           │
│  │    Admin     │  │  Maintenance │  │     View     │           │
│  │    Facet     │  │    Facet     │  │   Facets     │           │
│  └──────────────┘  └──────────────┘  └──────────────┘           │
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐           │
│  │  AmmAuction  │  │   Options    │  │   Futures    │           │
│  │    Facet     │  │    Facet     │  │    Facet     │           │
│  └──────────────┘  └──────────────┘  └──────────────┘           │
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐                             │
│  │  MamCurve    │  │  Derivative  │                             │
│  │    Facet     │  │  ViewFacet   │                             │
│  └──────────────┘  └──────────────┘                             │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│                      Shared Libraries                           │
│  LibFeeIndex │ LibNetEquity │ LibEncumbrance │ LibSolvency │... │
├─────────────────────────────────────────────────────────────────┤
│                      Diamond Storage                            │
│  AppStorage │ DirectStorage │ IndexStorage │ NFTStorage         │
└─────────────────────────────────────────────────────────────────┘
         │                    │                    │
         ▼                    ▼                    ▼
   ┌──────────┐        ┌──────────┐        ┌──────────┐
   │ Position │        │   ERC20  │        │  Index   │
   │   NFT    │        │  Tokens  │        │  Tokens  │
   └──────────┘        └──────────┘        └──────────┘
```

### 2.2 Diamond Pattern Implementation

Equalis uses the EIP-2535 Diamond standard for modular contract architecture:

**Core Diamond Components:**
- `Diamond.sol`: Main proxy contract with fallback delegation
- `DiamondCutFacet.sol`: Facet management and upgrade logic
- `DiamondLoupeFacet.sol`: Introspection for facet discovery
- `LibDiamond.sol`: Diamond storage and selector routing

**Storage Isolation:**
- Each facet uses dedicated storage slots via diamond storage pattern
- `LibAppStorage`: Main application state (pools, global config)
- `LibDirectStorage`: Equalis Direct state (offers, agreements)
- `LibDerivativeStorage`: Derivative products state (auctions, options, futures)
- `EqualIndexStorage`: Index token state (vaults, fee pots)
- `LibPositionNFT`: Position NFT configuration

**Benefits:**
- Modular upgrades without full redeployment
- Gas-efficient function routing
- Clear separation of concerns
- Reduced contract size limits

### 2.3 Facet Responsibilities

| Facet | Responsibility | Key Functions |
|-------|---------------|---------------|
| **LendingFacet** | Rolling and fixed-term loan operations | `openRollingFromPosition`, `makePaymentFromPosition`, `openFixedFromPosition`, `repayFixedFromPosition` |
| **PenaltyFacet** | Deterministic default handling | `penalizePositionRolling`, `penalizePositionFixed` |
| **PositionManagementFacet** | Position NFT lifecycle | `mintPositionWithDeposit`, `depositToPosition`, `withdrawFromPosition` |
| **PoolManagementFacet** | Pool creation and managed pool config | `initPool`, `initManagedPool`, `setWhitelistEnabled`, `transferManager` |
| **FlashLoanFacet** | Pool-local flash loans | `flashLoan` |
| **EqualLendDirectOfferFacet** | P2P term lending offers | `postOffer`, `postRatioTrancheOffer`, `postBorrowerOffer`, `cancelOffer` |
| **EqualLendDirectAgreementFacet** | P2P term agreement acceptance | `acceptOffer`, `acceptRatioTrancheOffer`, `acceptBorrowerOffer` |
| **EqualLendDirectLifecycleFacet** | P2P term lifecycle | `repay`, `recover`, `exerciseDirect`, `callDirect` |
| **EqualLendDirectRollingOfferFacet** | P2P rolling offers | `postRollingOffer`, `postBorrowerRollingOffer`, `getRollingOffer`, `cancelRollingOffer` |
| **EqualLendDirectRollingAgreementFacet** | P2P rolling acceptance | `acceptRollingOffer`, `getRollingAgreement` |
| **EqualLendDirectRollingPaymentFacet** | P2P rolling payments | `makeRollingPayment` |
| **EqualLendDirectRollingLifecycleFacet** | P2P rolling lifecycle | `recoverRolling`, `exerciseRolling`, `repayRollingInFull` |
| **EqualIndex Facets (V3)** | Multi-asset index tokens | Admin (`setIndexFees`, `setPaused`), Actions (`mint`, `burn`, `flashLoan`), View (`getIndex`, `getIndexAssets`, etc.) |
| **MaintenanceFacet** | AUM fee management | `pokeMaintenance`, `settleMaintenance` |
| **AdminFacet / AdminGovernanceFacet** | Protocol governance | `setTimelock`, `setTreasury`, fee split configuration |
| **ActiveCreditViewFacet** | Active credit queries | `pendingActiveCredit`, `getActiveCreditState` |
| **ConfigViewFacet** | Protocol configuration queries | `getPoolConfig`, `getDirectConfig` |
| **EnhancedLoanViewFacet** | Detailed loan information | `getLoanDetails`, `getLoanStatus` |
| **LiquidityViewFacet** | Pool liquidity queries | `getPoolLiquidity`, `getAvailableLiquidity` |
| **LoanPreviewFacet** | Loan simulation | `previewLoan`, `previewRepayment` |
| **LoanViewFacet** | Basic loan queries | `getLoan`, `getUserLoans` |
| **MultiPoolPositionViewFacet** | Cross-pool position state | `getPositionAcrossPools` |
| **PoolUtilizationViewFacet** | Utilization metrics | `getPoolUtilization` |
| **PositionViewFacet** | Position state queries | `getPositionState`, `getPositionDebt` |
| **EqualLendDirectViewFacet** | Direct lending queries | `getOffer`, `getBorrowerOffer`, `getAgreement`, `getLenderOffers` |
| **EqualLendDirectRollingViewFacet** | Rolling direct helpers | `getRollingStatus`, `calculateRollingPayment`, `aggregateRollingExposure` |
| **AmmAuctionFacet** | Time-bounded AMM auctions | `createAuction`, `swapExactIn`, `finalizeAuction`, `cancelAuction` |
| **OptionsFacet** | Covered call and secured put options | `createOptionSeries`, `exerciseOptions`, `reclaimOptions` |
| **FuturesFacet** | Physical delivery futures | `createFuturesSeries`, `settleFutures`, `reclaimFutures` |
| **MamCurveFacet** | Dutch auction market making curves | `createCurve`, `createCurvesBatch`, `updateCurve`, `updateCurvesBatch`, `cancelCurve`, `cancelCurvesBatch`, `executeCurveSwap`, `loadCurveForFill`, `setMamPaused` |
| **MamCurveViewFacet** | MAM curve queries | `getCurve`, `getCurvesByPosition`, `getCurvesByPositionId` |
| **DerivativeViewFacet** | Derivative product queries | `getAmmAuction`, `getOptionSeries`, `getFuturesSeries` |

---

## 3. Core Design Principles

### 3.1 Account-Level Solvency

**Principle**: Each account's obligations must always be covered by their own locked principal.

**Implementation**:
- Loan limits calculated based on depositor's principal balance
- LTV (Loan-to-Value) constraints enforced at loan origination
- No cross-account risk transfer
- Solvency checks include all debt types (rolling, fixed, direct term, direct rolling)

**Formula**:
```
totalDebt = rollingPrincipalRemaining + fixedTermPrincipalRemaining + directBorrowedPrincipal
availableCollateral = userPrincipal - directLockedPrincipal[positionKey][poolId]
solvencyRatio = (availableCollateral * 10000) / totalDebt
require(solvencyRatio >= depositorLTVBps)
```

### 3.2 Lossless Deposits

**Principle**: Depositors cannot lose principal due to actions or failures of other users.

**Implementation**:
- Borrower defaults absorbed by borrower's own principal
- No socialized losses across the pool
- Default penalties are funded by the defaulting position and distributed between enforcers, treasury, and protocol indices (FeeIndex / Active Credit Index)
- Pool isolation prevents cross-pool contagion

**Guarantees**:
- `userPrincipal[user]` can only decrease via user's own actions (withdrawals, fees, defaults)
- FeeIndex only increases (monotone property)
- MaintenanceIndex applies proportional haircut to all users equally

### 3.3 Deterministic Credit

**Principle**: All credit terms are fixed at origination with no reactive adjustments.

**Implementation**:
- Zero interest for self-secured same-asset credit
- Fixed APY rates for P2P lending set by lenders
- Payment schedules determined by time, not utilization
- No oracle-based liquidations
- Upfront interest realization for P2P fixed-term loans only

**Loan Types**:
1. **Pool Rolling Credit**: Open-ended lines with periodic payment requirements
   - Payment interval: 30 days (fixed)
   - Delinquency threshold: 2 missed payments
   - Penalty threshold: 3 missed payments
   - **Zero interest** - borrowers repay only principal

2. **Pool Fixed-Term Loans**: Explicit term with no interest
   - **Zero interest** - borrowers repay only principal
   - Repayment only requires principal
   - Penalty after expiry timestamp

3. **Direct Term Loans**: P2P bilateral term loans
   - Upfront interest and platform fee payment
   - Optional early exercise and prepayment
   - 24-hour grace period after due date

4. **Direct Rolling Loans**: P2P bilateral rolling credit
   - Periodic payment intervals with arrears tracking
   - Optional amortization support
   - Configurable grace periods and payment caps

### 3.4 Pool Isolation

**Principle**: Each pool maintains independent accounting with no cross-pool dependencies.

**Implementation**:
- Per-pool `trackedBalance` for token accounting
- Separate FeeIndex and MaintenanceIndex per pool
- Independent liquidity constraints
- No shared reserves or cross-pool borrowing

**Isolation Mechanisms**:
```solidity
// Each pool tracks its own token balance
p.trackedBalance += amount;  // On deposit
p.trackedBalance -= amount;  // On withdrawal/loan

// Maintenance fees paid from pool's tracked balance only
uint256 poolAvailable = p.trackedBalance;
paid = min(outstanding, poolAvailable, contractBalance);
```

---

## 4. Component Specifications

### 4.1 Position NFT System

**Overview**: ERC-721 tokens representing isolated account containers in Equalis pools.

**Key Characteristics**:
- Each NFT can participate in multiple pools simultaneously
- Position key derived deterministically: `keccak256(abi.encodePacked(nftContract, tokenId))` (a `bytes32`)
- Same position key used across all pools for this NFT
- Transferring NFT transfers all deposits, loans, and yield across all pools
- Users can hold multiple NFTs for different account containers

**Multi-Pool Position State**:
```solidity
// Single NFT can have state across multiple pools
struct MultiPoolPositionState {
    uint256 tokenId;
    bytes32 positionKey;            // Same key across all pools
    mapping(uint256 => PoolPositionState) poolStates;
}

struct PoolPositionState {
    uint256 poolId;
    address underlying;
    bool isMember;                  // Pool membership status
    uint256 principal;              // Deposit balance in this pool
    uint256 accruedYield;           // Settled yield in this pool
    uint256 feeIndexCheckpoint;     // Last FeeIndex settlement
    uint256 maintenanceIndexCheckpoint;
    RollingCreditLoan rollingLoan;  // Rolling loan in this pool
    uint256[] fixedLoanIds;         // Fixed-term loans in this pool
    uint256 totalDebt;              // Debt in this pool
}
```

**Position Operations** (all require `poolId` parameter):
- `mintPositionWithDeposit(poolId, amount)`: Create new NFT with initial deposit in specified pool
- `depositToPosition(tokenId, poolId, amount)`: Add principal to position in specified pool
- `withdrawFromPosition(tokenId, poolId, amount)`: Remove principal from specified pool
- `closePoolPosition(tokenId, poolId)`: Withdraw available principal respecting Direct commitments
- `rollYieldToPosition(tokenId, poolId)`: Convert accrued yield to principal in specified pool
- `transferFrom`: Transfer NFT and all associated state across all pools to new owner

**Transfer Behavior**:
- Position key remains unchanged (derived from contract + tokenId)
- All pool memberships transfer with NFT
- All pool data (principal, loans, yield) across all pools transfers
- Transfers are blocked while outstanding Direct offers exist (cancel before transfer)
- New owner inherits deposits and obligations in all pools

**Tranche-Backed Direct Offers**:
- Lenders may post offers with `isTranche=true` and `trancheAmount`, escrowing the full tranche into `directOfferEscrow` at post time
- `trancheRemaining` tracks the unfilled balance
- Acceptances atomically check tranche availability, decrement `trancheRemaining` by `principal`, and convert that slice from escrow to `directLentPrincipal`
- Insufficient tranche auto-cancels the offer
- Optional `enforceFixedSizeFills` flag requires `trancheAmount` to be divisible by `principal` to prevent dust

**Ratio Tranche Offers**:
A second tranche type lets lenders quote a price ratio instead of fixed-size fills:
- Lenders set `principalCap`, `priceNumerator/priceDenominator` (collateral per unit principal), and `minPrincipalPerFill`
- Borrowers draw any amount between `minPrincipalPerFill` and `principalRemaining` at the posted ratio
- Required collateral computed as: `collateral = principal × priceNumerator / priceDenominator`
- Escrowed principal is reserved at post time and decremented per fill
- Accepts convert the filled slice from escrow to active `directLentPrincipal`

### 4.2 Pool Membership System (LibPoolMembership)

**Purpose**: Track which pools each Position NFT participates in, enabling multi-pool account containers.

**Core Concept**: 
- One NFT = One position key across all pools
- Position can join multiple pools independently
- Each pool maintains separate state for the position
- Membership required before pool operations

**Storage**:
```solidity
mapping(bytes32 => mapping(uint256 => bool)) joined; // positionKey => poolId => joined
```

**Membership Operations**:

1. **Auto-Join** (`_ensurePoolMembership`):
   ```solidity
   function _ensurePoolMembership(bytes32 positionKey, uint256 pid, bool allowAutoJoin) 
       returns (bool alreadyMember) 
   {
       if (store.joined[positionKey][pid]) return true;
       if (!allowAutoJoin) revert PoolMembershipRequired(positionKey, pid);
       store.joined[positionKey][pid] = true;
       return false;
   }
   ```

2. **Leave Pool** (`_leavePool`):
   ```solidity
   function _leavePool(bytes32 positionKey, uint256 pid, bool canClear, string memory reason) {
       require(canClear, reason);
       delete store.joined[positionKey][pid];
   }
   ```

3. **Cleanup Eligibility** (`canClearMembership`):
   - No principal balance: `userPrincipal[positionKey] == 0`
   - No active loans: `activeFixedLoanCount[positionKey] == 0`
   - No rolling loan: `!rollingLoans[positionKey].active`
   - No Direct exposure: All direct locked/lent/borrowed principal is zero across all pools

**Pool Membership Lifecycle**:
1. **Auto-Join**: First operation in a pool automatically joins (`allowAutoJoin: true`)
2. **Multi-Pool Operations**: Same NFT can deposit/borrow across multiple pools
3. **Independent State**: Each pool maintains separate principal, loans, yield for the position
4. **Cleanup**: Can leave pool only when all obligations settled

#### Managed Pools and Whitelists

Pools may be initialized as **managed**, designating a manager account and storing mutable parameters in `managedConfig`:

**Managed Pool Features**:
- Mutable configuration: rates, thresholds, caps, action fees, flash fees, maintenance
- Whitelist gating keyed to position keys (derived from Position NFT IDs)
- Auto-join reverts for non-whitelisted positions when whitelist is enabled
- Managers can add/remove whitelist entries, toggle enforcement, transfer or renounce management

**Managed Pool Requirements**:
- `whitelistEnabled` must be `true` at pool creation
- Manager must be `msg.sender` or `address(0)` at creation
- Separate `managedPoolCreationFee` (distinct from unmanaged `poolCreationFee`)
- If `managedPoolCreationFee == 0`, managed pool creation is disabled

**Whitelist Storage**:
```solidity
// Whitelist keyed by positionKey (not tokenId directly)
mapping(bytes32 => bool) whitelist;  // positionKey => whitelisted

// Adding to whitelist derives positionKey from tokenId
function addToWhitelist(uint256 pid, uint256 tokenId) external {
    bytes32 positionKey = nft.getPositionKey(tokenId);
    p.whitelist[positionKey] = true;
}
```

**Manager Operations**:
- `setRollingApy`, `setDepositorLTV`, `setMaintenanceRate`, etc.
- `addToWhitelist(pid, tokenId)`, `removeFromWhitelist(pid, tokenId)`
- `setWhitelistEnabled(pid, enabled)` - toggle whitelist enforcement
- `transferManager(pid, newManager)` - transfer management
- `renounceManager(pid)` - permanently renounce management (irreversible)

Unmanaged pools remain permissionless and immutable after creation.

### 4.3 FeeIndex System with Normalized Fee Base and Active Credit Index

**Purpose**: Distribute protocol fees proportionally to all depositors as yield, with normalized fee base calculation to prevent recursive fee inflation, plus time-gated subsidies for active credit participants.

**Fee Sources**:
- Flashloan execution fees
- MAM curve fill fees
- Penalty fees (63% to FeeIndex after enforcer share)
- Direct lending platform fees
- Action fees (configurable)
- **Note**: Interest is not charged on self-secured same-asset borrowing; protocol revenue derives from usage-based fees

**Core Libraries**:
- `LibFeeIndex`: Fee index accounting and settlement (1e18 scale)
- `LibNetEquity`: Pure helpers for fee base calculations
- `LibActiveCreditIndex`: Time-gated subsidy distribution for active credit participants

**Mechanism**:
```solidity
// Global pool index (1e18 scale)
feeIndex = feeIndex + (feeAmount * 1e18) / totalDeposits

// Active Credit Index (parallel system)
activeCreditIndex = activeCreditIndex + (activeCreditAmount * 1e18) / totalActiveWeight

// Per-user settlement with normalized fee base (LibFeeIndex.settle)
sameAssetDebt = LibSolvencyChecks.calculateSameAssetDebt(p, user, poolAsset)
feeBase = LibNetEquity.calculateFeeBaseSameAsset(principal, sameAssetDebt)
delta = feeIndex - userFeeIndex[user]
yield = (feeBase * delta) / 1e18
userAccruedYield[user] += yield
userFeeIndex[user] = feeIndex

// Active Credit settlement (for eligible participants)
if (isActiveCreditEligible(user, poolId)) {
    activeDelta = activeCreditIndex - userActiveCreditState[user].indexSnapshot
    activeYield = (activeWeight * activeDelta) / 1e18
    userAccruedYield[user] += activeYield
    userActiveCreditState[user].indexSnapshot = activeCreditIndex
}
```

**Active Credit Index System**:

The Active Credit Index provides time-gated subsidies to active credit participants using a weighted dilution mechanism to prevent gaming:

**Participants:**
- **P2P Lenders**: Earn rewards on directLentPrincipal (all asset types)
- **Same-Asset Borrowers**: Earn rewards on same-asset debt only (rolling, fixed, direct P2P)

**Time Gate & Weighted Dilution:**
```solidity
// 24-hour maturity requirement
uint256 public constant TIME_GATE = 24 hours;

timeCredit = min(24 hours, currentTime - startTime)
activeWeight = timeCredit >= 24 hours ? principal : 0

// Weighted dilution on principal increases (prevents dust priming)
newTimeCredit = (oldPrincipal * oldTimeCredit + newPrincipal * 0) / totalPrincipal
newStartTime = currentTime - newTimeCredit
```

**Fee Sources:**
- Platform fees from Direct lending (configurable split)
- Default recovery fees from Direct lending (configurable split)
- Penalty fees from pool loan defaults
- Minimum interest duration enforcement prevents wash trading

**Anti-Gaming Properties:**
- **Dust Priming Prevention**: Adding large amounts to small mature positions dilutes time credit to near zero
- **Legitimate Top-up Preservation**: Adding small amounts to large mature positions preserves most time credit
- **Mathematical Neutralization**: Weighted average ensures attackers cannot bypass the 24-hour requirement

**Normalized Fee Base Calculation**:

The fee base calculation is centralized in `LibNetEquity` and depends on the relationship between assets and debt:

**1. Pool-Native Borrowing (Same Asset)** - `LibNetEquity.calculateFeeBaseSameAsset`:
```solidity
function calculateFeeBaseSameAsset(uint256 principal, uint256 sameAssetDebt) 
    internal pure returns (uint256) 
{
    return principal >= sameAssetDebt ? principal - sameAssetDebt : 0;
}
```

**2. Cross-Asset Domains** - `LibNetEquity.calculateFeeBaseCrossAsset`:
```solidity
function calculateFeeBaseCrossAsset(uint256 lockedCollateral, uint256 unlockedPrincipal)
    internal pure returns (uint256)
{
    return lockedCollateral + unlockedPrincipal;
}
```

**3. P2P Borrower Fee Base** - `LibNetEquity.calculateP2PBorrowerFeeBase`:
```solidity
function calculateP2PBorrowerFeeBase(
    uint256 lockedCollateral,
    uint256 unlockedPrincipal,
    uint256 sameAssetDebt,
    bool isSameAsset
) internal pure returns (uint256 feeBase) {
    if (isSameAsset) {
        // Same-asset P2P: net against debt to prevent recursion
        uint256 principal = calculateFeeBaseCrossAsset(lockedCollateral, unlockedPrincipal);
        return calculateFeeBaseSameAsset(principal, sameAssetDebt);
    }
    // Cross-asset P2P: no netting required
    return calculateFeeBaseCrossAsset(lockedCollateral, unlockedPrincipal);
}
```

**4. Lender Principal Adjustment**:
```solidity
// On P2P offer acceptance
lenderPrincipal -= lentAmount  // Immediate reduction
lenderFeeBase = newLenderPrincipal  // Fee base follows reduced principal

// On P2P repayment  
lenderPrincipal += repaidAmount  // Principal restoration
lenderFeeBase = newLenderPrincipal  // Fee base follows restored principal
```

**Properties**:
- **Monotone**: FeeIndex never decreases
- **Proportional**: Yield distributed based on normalized fee base (not raw principal)
- **Recursive-Safe**: Same-asset borrow-deposit loops cannot inflate fee base
- **Cross-Asset Permissive**: Cross-asset lending maintains full fee accrual (no recursion risk)
- **Lazy**: Settlement only on user interaction
- **Precise**: Remainder tracking prevents rounding loss

**Fee Sources**:
- Flashloan fees
- MAM curve fill fees
- Penalty fees (63% to FeeIndex after enforcer share)
- Direct lending platform fees
- Action fees (configurable)

**Yield Compounding**:

Users can convert accrued yield to principal via `rollYieldToPosition`, enabling compound interest:

```solidity
function rollYieldToPosition(uint256 tokenId, uint256 pid) public {
    LibFeeIndex.settle(pid, positionKey);
    
    uint256 accruedYield = p.userAccruedYield[positionKey];
    require(accruedYield > 0, "No yield to roll");
    
    p.userPrincipal[positionKey] += accruedYield;
    p.userAccruedYield[positionKey] = 0;
    p.totalDeposits += accruedYield;
}
```

### 4.4 MaintenanceIndex System

**Purpose**: Apply proportional AUM fees to all depositors over time.

**Mechanism**:
```solidity
// Calculate maintenance fee
epochs = (block.timestamp - lastMaintenanceTimestamp) / 1 day
maintenanceFee = (totalDeposits * maintenanceRateBps * epochs) / (365 * 10_000)

// Reduce totalDeposits
totalDeposits -= maintenanceFee

// Apply negative index
maintenanceIndex += (maintenanceFee * 1e18) / oldTotalDeposits

// Per-user reduction on settlement
delta = maintenanceIndex - userMaintenanceIndex[user]
reduction = (userPrincipal[user] * delta) / 1e18
userPrincipal[user] -= reduction
```

**Properties**:
- **Proportional**: All users pay same percentage
- **Time-based**: Accrues daily
- **Lazy**: Applied on user interaction
- **Bounded**: Configurable min/max rates

**Configuration**:
- Default rate: 1% annually (100 bps)
- Per-pool override via `immutableConfig.maintenanceRateBps` or `managedConfig.maintenanceRateBps`
- Foundation receiver address for fee collection
- Paid from pool's `trackedBalance`

### 4.5 Centralized Encumbrance System (LibEncumbrance)

**Purpose**: Provide unified storage and API for all encumbrance components per position and pool, replacing scattered direct storage mappings.

**Core Library**: `LibEncumbrance` centralizes all encumbrance tracking:

```solidity
struct Encumbrance {
    uint256 directLocked;       // Collateral locked as borrower (options, futures, MAM, P2P collateral)
    uint256 directLent;         // Principal exposed as lender (AMM reserves)
    uint256 directOfferEscrow;  // Escrowed offers awaiting acceptance
    uint256 indexEncumbered;    // Principal backing index tokens
}

struct EncumbranceStorage {
    mapping(bytes32 => mapping(uint256 => Encumbrance)) encumbrance;
    mapping(bytes32 => mapping(uint256 => mapping(uint256 => uint256))) encumberedByIndex;
}
```

**API Functions**:
```solidity
// Get encumbrance struct (storage reference for modification)
LibEncumbrance.Encumbrance storage enc = LibEncumbrance.position(positionKey, poolId);

// Get encumbrance struct (memory copy for reading)
LibEncumbrance.Encumbrance memory enc = LibEncumbrance.get(positionKey, poolId);

// Get total encumbrance across all components
uint256 totalEncumbered = LibEncumbrance.total(positionKey, poolId);

// Index-specific encumbrance operations
LibEncumbrance.encumberIndex(positionKey, poolId, indexId, amount);
LibEncumbrance.unencumberIndex(positionKey, poolId, indexId, amount);
uint256 indexTotal = LibEncumbrance.getIndexEncumbered(positionKey, poolId);
uint256 forIndex = LibEncumbrance.getIndexEncumberedForIndex(positionKey, poolId, indexId);
```

**Wrapper Libraries**:
- `LibIndexEncumbrance`: Thin wrapper for index-specific encumbrance operations
- `LibDerivativeHelpers`: Uses `LibEncumbrance` for derivative collateral locking

**Integration Points**:
- `LibSolvencyChecks.calculateAvailablePrincipal`: Uses `LibEncumbrance.get()` to compute available principal
- `PositionViewFacet`: Uses `LibEncumbrance.get()` for position state queries
- `MultiPoolPositionViewFacet`: Aggregates encumbrance across pools using `LibEncumbrance`
- Direct lending facets: Use `LibEncumbrance.position()` for offer escrow and collateral locking
- Derivative facets: Use `LibDerivativeHelpers` which delegates to `LibEncumbrance`

**Events**:
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

**Benefits**:
- **Single Source of Truth**: All encumbrance data in one storage location
- **Consistent API**: Uniform access pattern across all facets
- **Gas Efficiency**: Single storage read for all encumbrance components
- **Auditability**: Clear separation of encumbrance types with events

### 4.6 Pool Loan Management

#### 4.6.1 Rolling Credit Loans

**Characteristics**:
- Open-ended credit lines
- **Zero interest** - borrowers repay only principal
- Periodic payment requirements (30 days) for tracking delinquency
- Expandable via `expandRollingFromPosition`
- Single rolling loan per position per pool

**Lifecycle**:
1. **Open**: `openRollingFromPosition(tokenId, poolId, amount)`
   - Verify solvency: `newDebt <= collateral * depositorLTVBps / 10000`
   - Charge ACTION_BORROW fee
   - Transfer borrowed funds to NFT owner
   - Initialize loan state with `apyBps = 0`

2. **Payment**: `makePaymentFromPosition(tokenId, poolId, paymentAmount)`
   - **No minimum payment** - any amount applies directly to principal
   - Entire payment reduces `principalRemaining`
   - Reset missed payment counter

3. **Expand**: `expandRollingFromPosition(tokenId, poolId, amount)`
   - Re-verify solvency with additional debt
   - Increase both `principal` and `principalRemaining`
   - Transfer additional funds

4. **Close**: `closeRollingCreditFromPosition(tokenId, poolId)`
   - Calculate total payoff: remaining principal only (no interest)
   - Transfer payoff from owner
   - Clear loan state
   - Charge ACTION_CLOSE_ROLLING fee

**Delinquency Tracking**:
```solidity
struct RollingCreditLoan {
    uint256 principal;
    uint256 principalRemaining;
    uint256 principalAtOpen;        // Penalty calculation basis
    uint40 openedAt;
    uint40 lastPaymentTimestamp;
    uint40 lastAccrualTs;
    uint16 apyBps;
    uint8 missedPayments;           // Incremented on missed payment epochs
    uint32 paymentIntervalSecs;     // Default: 30 days
    bool depositBacked;             // Only deposit-backed supported
    bool active;
}
```

**Delinquency Thresholds** (configurable via AppStorage):
- `rollingDelinquencyEpochs`: Default 2 missed payments (delinquent status)
- `rollingPenaltyEpochs`: Default 3 missed payments (penalty eligible)

#### 4.6.2 Fixed-Term Loans

**Characteristics**:
- Explicit term with fixed expiry
- **Zero interest** - borrowers repay only principal
- Multiple fixed-term loans per position
- No payment schedule (lump sum at maturity)

**Lifecycle**:
1. **Open**: `openFixedFromPosition(tokenId, poolId, amount, termIndex)`
   - Select term configuration from pool's `fixedTermConfigs`
   - No interest calculation or deduction
   - Verify solvency
   - Transfer borrowed funds
   - Set expiry: `block.timestamp + durationSecs`
   - Set `fullInterest = 0` and `interestRealized = false`

2. **Repay**: `repayFixedFromPosition(tokenId, poolId, loanId, amount)`
   - Transfer principal payment only
   - Reduce `principalRemaining`
   - Close loan if fully repaid
   - Charge ACTION_REPAY fee

**Storage**:
```solidity
struct FixedTermLoan {
    uint256 principal;
    uint256 principalRemaining;
    uint256 fullInterest;           // Always 0 for self-secured pool loans
    uint256 principalAtOpen;        // Penalty calculation basis
    uint40 openedAt;
    uint40 expiry;
    uint16 apyBps;                  // Stored from pool config (not charged for self-secured pool loans)
    bytes32 borrower;               // Position key
    bool closed;
    bool interestRealized;          // Always false for self-secured pool loans
}
```

### 4.7 Penalty-Based Settlement (No Liquidations)

**Trigger Conditions**:
- **Rolling**: 3+ missed payments (configurable via `rollingPenaltyEpochs`)
- **Fixed**: Past expiry timestamp

**Penalty-Based Approach**:
Instead of seizing all collateral, the system applies a **fixed 5% penalty** against the borrower's `principalAtOpen` (recorded at loan creation).

**Penalty Calculation**:
```solidity
function calculatePenalty(uint256 principalAtOpen) internal pure returns (uint256) {
    return (principalAtOpen * 500) / 10_000;  // Fixed 5%
}
```

**Distribution of the penalty** (from `PenaltyFacet`):
- 10% to the enforcer (incentive)
- 63% to the pool FeeIndex (benefits all depositors)
- 9% to protocol treasury
- 18% to the Active Credit Index (time-gated subsidy pool)

**Process**:
1. Verify penalty eligibility (missed payments or expiry)
2. Calculate available collateral: `availableCollateral = userPrincipal - directLockedPrincipal - directOfferEscrow`
3. Calculate 5% penalty: `penalty = principalAtOpen * 500 / 10_000`
4. Apply penalty cap: `penaltyApplied = min(penalty, principalRemaining, availableCollateral)`
5. Reduce user principal by the seized principal + penalty (borrower absorbs both)
6. Calculate distribution shares from penalty amount
7. Transfer enforcer and treasury shares (leave protocol accounting)
8. Accrue FeeIndex and Active Credit shares to their indices (remains in protocol accounting)
9. Close loan (mark as defaulted/closed)

**Key Properties**:
- **Proportional Penalty**: 5% of original principal basis, regardless of utilization level
- **Position Preservation**: Borrower retains remaining collateral after penalty
- **Direct Commitment Protection**: Penalty respects locked collateral and escrowed offers
- **Predictable Loss**: Maximum loss is always 5% of `principalAtOpen`
- **Fairness**: Same penalty percentage whether at 50% or 95% utilization

### 4.8 Equalis Direct - Term Loans (P2P Lending)

**Overview**: Bilateral term lending between Position NFT holders with upfront fee realization, optional early exercise, and configurable prepayment policies. Both lenders and borrowers can post offers.

**Key Features**:
- Both lender and borrower must be Position NFT holders
- **True cross-asset lending**: Any asset can be lent against any collateral asset
- **Oracle-free cross-asset pricing**: Lenders set their own terms and collateral ratios
- **Borrower Offers**: Borrowers can post offers specifying their desired terms, which lenders can accept
- **Ratio Tranche Offers**: CLOB-style offers with price ratios for variable-size fills (both lender and borrower)
- **Optional Early Exercise**: Lenders can allow borrowers to voluntarily forfeit collateral before maturity (American-style settlement)
- **Configurable Prepayment**: Lenders can control whether borrowers can repay before maturity
- **Lender Call**: Lenders can optionally accelerate the due timestamp
- **24-Hour Grace Period**: Repayment allowed for 24 hours after due timestamp before recovery becomes available
- Multiple agreements per position
- Upfront interest and platform fee payment
- Time-based recovery (no oracles needed)
- Bilateral risk isolation (pools never take P2P credit risk)

**Cross-Asset Architecture**:
```
Lender Pool (USDC) ←→ Borrower Pool (WETH)
     ↓                        ↓
Lends USDC              Locks WETH as collateral
     ↓                        ↓
Borrower receives USDC   Lender sets WETH/USDC ratio
```

**Data Structures**:
```solidity
struct DirectOffer {
    uint256 offerId;
    address lender;
    uint256 lenderPositionId;
    uint256 lenderPoolId;           // Pool providing liquidity (any asset)
    uint256 collateralPoolId;       // Pool holding borrower collateral (any asset)
    address borrowAsset;            // Asset being lent (from lenderPool)
    address collateralAsset;        // Asset being used as collateral (from collateralPool)
    uint256 principal;              // Amount of borrowAsset to lend
    uint16 aprBps;                  // Interest rate set by lender
    uint64 durationSeconds;         // Term length set by lender
    uint256 collateralLockAmount;   // Amount of collateralAsset required
    bool allowEarlyRepay;           // Whether borrower can repay before maturity
    bool allowEarlyExercise;        // Whether borrower can exercise early (forfeit collateral)
    bool allowLenderCall;           // Whether lender can accelerate due timestamp
    bool cancelled;
    bool filled;
    bool isTranche;                 // Tranche-backed offer flag
    uint256 trancheAmount;          // Total tranche size for multi-fill offers
}

struct DirectBorrowerOffer {
    uint256 offerId;
    address borrower;
    uint256 borrowerPositionId;
    uint256 lenderPoolId;           // Pool lender will provide liquidity from
    uint256 collateralPoolId;       // Pool holding borrower collateral
    address borrowAsset;
    address collateralAsset;
    uint256 principal;
    uint16 aprBps;
    uint64 durationSeconds;
    uint256 collateralLockAmount;
    bool allowEarlyRepay;
    bool allowEarlyExercise;
    bool allowLenderCall;
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
    uint256 minPrincipalPerFill;
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
    uint256 minCollateralPerFill;
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
    address borrowAsset;
    address collateralAsset;
    uint256 principal;
    uint256 userInterest;           // Paid upfront
    uint64 dueTimestamp;
    uint256 collateralLockAmount;
    bool allowEarlyRepay;
    bool allowEarlyExercise;
    bool allowLenderCall;
    DirectStatus status;            // Active, Repaid, Defaulted, Exercised
    bool interestRealizedUpfront;   // Always true
}

enum DirectStatus {
    Active,
    Repaid,
    Defaulted,
    Exercised                       // Early exercise settlement
}
```

**Lifecycle**:

1. **Post Lender Offer**: `postOffer(DirectOfferParams)`
   - Verify lender owns Position NFT
   - Check lender has sufficient available principal
   - Reserve principal per pool: `directOfferEscrow[lenderKey][lenderPoolId] += principal`
   - Store offer with unique ID
   - Emit `DirectOfferPosted` event

2. **Post Borrower Offer**: `postBorrowerOffer(DirectBorrowerOfferParams)`
   - Verify borrower owns Position NFT
   - Check borrower has sufficient collateral
   - Lock collateral per pool: `directLockedPrincipal[borrowerKey][collateralPoolId] += collateralLockAmount`
   - Store offer with unique ID
   - Emit `BorrowerOfferPosted` event

3. **Accept Lender Offer**: `acceptOffer(offerId, borrowerPositionId)`
   - Verify borrower owns Position NFT
   - Check borrower has sufficient collateral
   - Lock collateral per pool: `directLockedPrincipal[borrowerKey][collateralPoolId] += collateralLockAmount`
   - Calculate and collect fees (interest + platform fee)
   - Distribute fees to lender, FeeIndex, protocol, and Active Credit Index
   - Transfer escrow to active loan
   - Transfer principal from lender pool to borrower
   - Create agreement with status Active

4. **Accept Borrower Offer**: `acceptBorrowerOffer(offerId, lenderPositionId)`
   - Verify lender owns Position NFT
   - Check lender has sufficient available principal
   - Verify borrower's collateral is still locked (from posting)
   - Calculate and collect fees (interest + platform fee)
   - Distribute fees to lender, FeeIndex, protocol, and Active Credit Index
   - Transfer principal from lender pool to borrower (minus fees)
   - Create agreement with status Active

5. **Repay**: `repay(agreementId)`
   - Verify borrower owns agreement
   - Validate timing based on `allowEarlyRepay` flag
   - Transfer principal from borrower to lender pool
   - Restore lender principal and reduce Active Credit base
   - Unlock collateral
   - Update agreement status to Repaid

6. **Exercise Early**: `exerciseDirect(agreementId)`
   - Only callable by borrower position owner
   - Before due: requires `allowEarlyExercise = true`
   - Grace window (due to due + 24h): callable regardless of flag
   - Voluntarily forfeit full `collateralLockAmount` to lender
   - Distribute collateral using same fee splits as default recovery
   - Update agreement status to Exercised

5. **Lender Call**: `callDirect(agreementId)`
   - Only callable by lender position owner
   - Requires `allowLenderCall = true`
   - Must be before current `dueTimestamp`
   - Accelerates `dueTimestamp` to current block timestamp
   - Grace period starts immediately after call

6. **Recover** (Default after Grace Period): `recover(agreementId)`
   - Only callable 24+ hours after due timestamp
   - Seize locked collateral from borrower position
   - Distribute collateral with fee splits
   - Update agreement status to Defaulted

**Timing Rules**:
- **Early Repay Disabled**: Repayment allowed from 24 hours before due until 24 hours after due
- **Early Repay Enabled**: Repayment allowed from acceptance until 24 hours after due  
- **Early Exercise**: Before due requires `allowEarlyExercise = true`; during grace window, always allowed
- **Recovery**: Allowed 24+ hours after due timestamp
- **Lender Call**: If `allowLenderCall = true`, lender can accelerate `dueTimestamp` to current time (before original due)

**Ratio Tranche Offers (Lender)**:

Lenders can post CLOB-style offers with a price ratio for variable-size fills:

```solidity
function postRatioTrancheOffer(DirectRatioTrancheParams calldata params) external returns (uint256 offerId);
function acceptRatioTrancheOffer(uint256 offerId, uint256 borrowerPositionId, uint256 principalAmount) 
    external returns (uint256 agreementId);
```

- Lender escrows `principalCap` at post time
- Borrowers draw any amount between `minPrincipalPerFill` and `principalRemaining`
- Required collateral computed as: `collateral = principal × priceNumerator / priceDenominator`

**Borrower Ratio Tranche Offers**:

Borrowers can post CLOB-style offers specifying collateral they're willing to lock:

```solidity
function postBorrowerRatioTrancheOffer(DirectBorrowerRatioTrancheParams calldata params) 
    external returns (uint256 offerId);
function acceptBorrowerRatioTrancheOffer(uint256 offerId, uint256 lenderPositionId, uint256 collateralAmount) 
    external returns (uint256 agreementId);
```

- Borrower locks `collateralCap` at post time
- Lenders fill any amount between `minCollateralPerFill` and `collateralRemaining`
- Principal computed as: `principal = collateral × priceNumerator / priceDenominator`

**Use Cases**:
- **CLOB-Style Trading**: Variable-size fills enable order book-like trading dynamics
- **Price Discovery**: Multiple counterparties can fill at the posted ratio

### 4.9 Equalis Direct - Rolling Loans (P2P Rolling Credit)

**Overview**: Bilateral rolling credit between Position NFT holders with periodic payments, arrears tracking, and configurable amortization.

**Key Features**:
- Both lender and borrower must be Position NFT holders
- **Cross-asset lending**: Any asset can be lent against any collateral asset
- **Periodic Payments**: Configurable payment intervals with interest accrual
- **Arrears Tracking**: Missed payments accumulate as arrears that must be cleared
- **Optional Amortization**: Lenders can allow principal reduction with payments
- **Grace Periods**: Configurable grace period after due date before recovery
- **Payment Caps**: Maximum number of payment periods before maturity
- **Upfront Premium**: Optional upfront payment from borrower to lender
- Time-based recovery (no oracles needed)
- Bilateral risk isolation

**Data Structures**:
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
    uint16 maxPaymentCount;           // e.g., 520 payments
    uint16 maxUpfrontPremiumBps;      // e.g., 5000 (50%)
    uint16 minRollingApyBps;          // e.g., 1 (0.01%)
    uint16 maxRollingApyBps;          // e.g., 10000 (100%)
    uint16 defaultPenaltyBps;         // Penalty rate for defaults
    uint64 minPaymentWei;             // Minimum accepted payment to avoid dust
}
```

**Lifecycle**:

1. **Post Lender Offer**: `postRollingOffer(DirectRollingOfferParams)`
   - Verify lender owns Position NFT and has sufficient principal
   - Validate parameters against rolling config bounds
   - Escrow principal: `directOfferEscrow[lenderKey][lenderPoolId] += principal`
   - Store offer and emit event

2. **Post Borrower Offer**: `postBorrowerRollingOffer(DirectRollingBorrowerOfferParams)`
   - Verify borrower owns Position NFT and has sufficient collateral
   - Lock collateral: `directLockedPrincipal[borrowerKey][collateralPoolId] += collateralLockAmount`
   - Store offer and emit event

3. **Accept Offer**: `acceptRollingOffer(offerId, callerPositionId)`
   - Works for both lender and borrower offers
   - Verify counterparty has required assets
   - Transfer principal from lender pool to borrower (minus upfront premium)
   - Pay upfront premium to lender
   - Create agreement with `nextDue = block.timestamp + paymentIntervalSeconds`
   - Track in both borrower and lender agreement lists

4. **Make Payment**: `makeRollingPayment(agreementId, amount)`
   - Accrue interest since last accrual to arrears
   - Apply payment in order: arrears → current interest → principal (if amortization allowed)
   - Advance `nextDue` only if arrears cleared and current interest fully paid
   - Increment `paymentCount`
   - Transfer payment to lender

5. **Repay in Full**: `repayRollingInFull(agreementId)`
   - Requires `allowEarlyRepay = true` or at payment cap
   - Accrue final interest to arrears
   - Pay `outstandingPrincipal + arrears` to lender
   - Unlock collateral and clear agreement state
   - Update status to Repaid

6. **Exercise**: `exerciseRolling(agreementId)`
   - Requires `allowEarlyExercise = true`
   - Borrower forfeits collateral without penalty
   - Distribute collateral to cover arrears + principal, refund remainder
   - Update status to Exercised

7. **Recover** (Default): `recoverRolling(agreementId)`
   - Only callable after `nextDue + gracePeriodSeconds`
   - Seize collateral and apply penalty
   - Distribute: penalty to protocol, remainder covers debt, surplus refunded to borrower
   - Update status to Defaulted

**Payment Mechanics**:
```solidity
// Interest calculation (simple interest, ceiling rounding)
interest = (principal * apyBps * durationSeconds) / (365 days * 10_000)

// Payment application order:
1. Clear arrears (accumulated missed interest)
2. Pay current interval interest
3. Reduce principal (only if allowAmortization = true)

// Schedule advancement:
if (arrears == 0 && currentInterestFullyPaid) {
    nextDue += paymentIntervalSeconds;
    paymentCount++;
}
```

**Recovery Distribution**:
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

// Split debt recovery
lenderShare = amountForDebt - protocolShare - feeIndexShare - activeCreditShare
```

### 4.11 Direct Lending Configuration

**Term Loan Configuration**:
```solidity
struct DirectConfig {
    uint16 platformFeeBps;                    // Fee on principal (e.g., 50 = 0.5%)
    uint16 platformSplitLenderBps;            // Share to lender (e.g., 4000 = 40%)
    uint16 platformSplitFeeIndexBps;          // Share to FeeIndex (e.g., 3000 = 30%)
    uint16 platformSplitProtocolBps;          // Share to protocol (calculated as remainder)
    uint16 platformSplitActiveCreditIndexBps; // Share to Active Credit Index (e.g., 1000 = 10%)
    uint16 defaultFeeIndexBps;                // Collateral to FeeIndex on default
    uint16 defaultProtocolBps;                // Collateral to protocol on default
    uint16 defaultActiveCreditIndexBps;       // Collateral to Active Credit Index on default
    uint40 minInterestDuration;               // Minimum interest charge period
    address protocolTreasury;
}
```

**Platform Fee Distribution**:
```solidity
// Protocol share calculated as remainder to ensure exact split
lenderPlatformShare = (platformFee * platformSplitLenderBps) / 10_000;
feeIndexShare = (platformFee * platformSplitFeeIndexBps) / 10_000;
activeCreditIndexShare = (platformFee * platformSplitActiveCreditIndexBps) / 10_000;
protocolShare = platformFee - lenderPlatformShare - feeIndexShare - activeCreditIndexShare;
```

**Rolling Loan Configuration**:
```solidity
struct DirectRollingConfig {
    uint32 minPaymentIntervalSeconds; // Minimum payment interval (e.g., 7 days)
    uint16 maxPaymentCount;           // Maximum payments (e.g., 520 = 10 years weekly)
    uint16 maxUpfrontPremiumBps;      // Maximum upfront premium (e.g., 5000 = 50%)
    uint16 minRollingApyBps;          // Minimum APY (e.g., 1 = 0.01%)
    uint16 maxRollingApyBps;          // Maximum APY (e.g., 10000 = 100%)
    uint16 defaultPenaltyBps;         // Default penalty rate
    uint64 minPaymentWei;             // Minimum payment to avoid dust
}
```

**Position State Extensions**:

Encumbrance tracking is centralized in `LibEncumbrance`, providing a unified storage and API for all encumbrance components per position and pool:

```solidity
// LibEncumbrance.Encumbrance struct (per position key and pool ID)
struct Encumbrance {
    uint256 directLocked;       // Collateral locked as borrower
    uint256 directLent;         // Principal exposed as lender (AMM reserves)
    uint256 directOfferEscrow;  // Escrowed offers
    uint256 indexEncumbered;    // Principal backing index tokens
}

// Access via LibEncumbrance
LibEncumbrance.Encumbrance memory enc = LibEncumbrance.get(positionKey, poolId);
uint256 totalEncumbered = LibEncumbrance.total(positionKey, poolId);

// Per-index tracking for index encumbrance
uint256 indexSpecific = LibEncumbrance.getIndexEncumberedForIndex(positionKey, poolId, indexId);
```

Additional Direct storage mappings:
```solidity
// DirectStorage (LibDirectStorage)
directBorrowedPrincipal[positionKey][poolId]  // Principal borrowed
directSameAssetDebt[positionKey][asset]       // Same-asset debt tracking
```

**Invariants**:
- `LibEncumbrance.total(positionKey, poolId) <= userPrincipal[positionKey]` (per position, per pool)
- `defaultFeeIndexBps + defaultProtocolBps + defaultActiveCreditIndexBps <= 10000`

### 4.12 Flash Loan System

**Pool-Local Flash Loans**:
- Borrow from single pool's `trackedBalance`
- Fixed fee in basis points (configurable per pool)
- Anti-split protection (optional): one flash loan per receiver per block
- Fee routed to FeeIndex via treasury split

**Process**:
```solidity
function flashLoan(uint256 pid, address receiver, uint256 amount, bytes calldata data) {
    require(amount <= p.trackedBalance);
    
    uint256 fee = (amount * p.immutableConfig.flashLoanFeeBps) / 10_000;
    IERC20(p.underlying).safeTransfer(receiver, amount);
    IFlashLoanReceiver(receiver).onFlashLoan(msg.sender, p.underlying, amount, data);
    require(balanceAfter >= balanceBefore + fee);
    
    p.trackedBalance += fee;
    LibFeeTreasury.accrueWithTreasury(p, pid, fee, "flashLoan");
}
```

### 4.13 EqualIndex (Multi-Asset Index Tokens)

**Overview**: Basket tokens holding fixed-weight portfolios of ERC20 assets.

**Key Features**:
- Deterministic bundle composition (fixed asset amounts per unit)
- Per-asset mint/burn fees (basis points)
- Separate fee pots per asset (accumulated fees distributed on burn)
- Flash loans of proportional basket amounts
- Protocol fee split configurable

**Index Structure**:
```solidity
struct Index {
    address[] assets;               // Basket components
    uint256[] bundleAmounts;        // Amount per 1e18 units
    uint16[] mintFeeBps;            // Per-asset mint fee
    uint16[] burnFeeBps;            // Per-asset burn fee
    uint16 flashFeeBps;             // Flash loan fee
    uint16 protocolCutBps;          // Protocol share of fees
    uint256 totalUnits;             // Total supply
    address token;                  // ERC20 token address
    bool paused;
}
```

**Mint Process**:
1. Calculate required amounts: `need = (bundleAmounts[i] * units) / 1e18`
2. Calculate fees: `fee = (need * mintFeeBps[i]) / 10_000`
3. Transfer `need + fee` from user
4. Credit `need` to vault balance
5. Split fee: pot share + protocol share
6. Mint proportional units

**Burn Process**:
1. Calculate NAV share: `(vaultBalance * units) / totalSupply`
2. Calculate pot share: `(feePot * units) / totalSupply`
3. Calculate gross redemption: `navShare + potShare`
4. Calculate burn fee and split
5. Transfer net amount to user
6. Burn units

---

## 5. Data Models and Storage

### 5.1 Pool Configuration

**Pool Configuration** (set at pool creation for unmanaged pools):
```solidity
struct PoolConfig {
    // Interest rates
    uint16 rollingApyBps;           // Deposit-backed rolling APY
    
    // LTV and collateralization
    uint16 depositorLTVBps;         // Max LTV for deposit-backed (e.g., 8000 = 80%)
    
    // Maintenance
    uint16 maintenanceRateBps;      // Annual AUM fee rate
    
    // Flash loans
    uint16 flashLoanFeeBps;         // Flash loan fee
    bool flashLoanAntiSplit;        // Anti-split protection
    
    // Thresholds
    uint256 minDepositAmount;       // Minimum deposit
    uint256 minLoanAmount;          // Minimum loan
    uint256 minTopupAmount;         // Minimum expansion
    
    // Caps
    bool isCapped;                  // Enforce per-user cap
    uint256 depositCap;             // Max principal per user
    uint256 maxUserCount;           // Max users (0 = unlimited)
    
    // AUM fee bounds
    uint16 aumFeeMinBps;            // Minimum AUM fee
    uint16 aumFeeMaxBps;            // Maximum AUM fee
    
    // Fixed term configs
    FixedTermConfig[] fixedTermConfigs;
    
    // Action fees
    ActionFeeConfig borrowFee;
    ActionFeeConfig repayFee;
    ActionFeeConfig withdrawFee;
    ActionFeeConfig flashFee;
    ActionFeeConfig closeRollingFee;
}
```

**Managed Pool Configuration** (mutable by manager):
```solidity
struct ManagedPoolConfig {
    // Interest rates (mutable)
    uint16 rollingApyBps;

    // LTV and collateralization (mutable)
    uint16 depositorLTVBps;

    // Maintenance and flash loan fees (mutable)
    uint16 maintenanceRateBps;
    uint16 flashLoanFeeBps;
    bool flashLoanAntiSplit;

    // Thresholds (mutable)
    uint256 minDepositAmount;
    uint256 minLoanAmount;
    uint256 minTopupAmount;

    // Caps (mutable)
    bool isCapped;
    uint256 depositCap;
    uint256 maxUserCount;

    // AUM fee bounds (immutable after creation)
    uint16 aumFeeMinBps;
    uint16 aumFeeMaxBps;

    // Fixed term configs (immutable after creation)
    FixedTermConfig[] fixedTermConfigs;

    // Action fees (mutable)
    ActionFeeSet actionFees;

    // Management settings
    address manager;
    bool whitelistEnabled;
}
```

**Mutable State**:
```solidity
struct PoolData {
    address underlying;             // ERC20 asset
    PoolConfig poolConfig;
    uint16 currentAumFeeBps;        // Within bounds
    bool deprecated;                // UI flag
    
    // Managed pool state
    bool isManagedPool;
    address manager;
    ManagedPoolConfig managedConfig;
    bool whitelistEnabled;
    mapping(bytes32 => bool) whitelist;  // Keyed by positionKey
    
    // Operational state
    uint256 totalDeposits;          // Sum of all user principals
    uint256 feeIndex;               // Cumulative yield index (1e18 scale)
    uint256 maintenanceIndex;       // Cumulative maintenance index
    uint64 lastMaintenanceTimestamp;
    uint256 pendingMaintenance;     // Accrued but unpaid
    uint256 nextFixedLoanId;
    uint256 userCount;
    uint256 feeIndexRemainder;      // Precision tracking
    uint256 maintenanceIndexRemainder;
    uint256 trackedBalance;         // Pool's token balance
    
    // Active Credit Index state
    uint256 activeCreditIndex;
    uint256 activeCreditIndexRemainder;
    uint256 activeCreditPrincipalTotal;
    
    // Per-user mappings (keyed by position key)
    mapping(bytes32 => uint256) userPrincipal;
    mapping(bytes32 => uint256) userFeeIndex;
    mapping(bytes32 => uint256) userMaintenanceIndex;
    mapping(bytes32 => uint256) userAccruedYield;
    mapping(bytes32 => ActiveCreditState) userActiveCreditStateP2P;
    mapping(bytes32 => ActiveCreditState) userActiveCreditStateDebt;
    
    // Loan mappings
    mapping(bytes32 => RollingCreditLoan) rollingLoans;
    mapping(uint256 => FixedTermLoan) fixedTermLoans;
    mapping(bytes32 => uint256) activeFixedLoanCount;
    mapping(bytes32 => uint256) fixedTermPrincipalRemaining;
    mapping(bytes32 => uint256[]) userFixedLoanIds;
    mapping(bytes32 => mapping(uint256 => uint256)) loanIdToIndex;
}

struct ActiveCreditState {
    uint256 principal;      // Current exposure amount
    uint40 startTime;       // Weighted dilution timestamp
    uint256 indexSnapshot;  // Last settled activeCreditIndex value
}
```

### 5.2 Global Application State

```solidity
struct AppStorage {
    uint256 poolCount;
    mapping(uint256 => PoolData) pools;
    mapping(address => mapping(uint256 => FlashAgg)) flashAgg;
    bool defaultFlashAntiSplit;
    address timelock;
    address treasury;
    uint16 treasuryShareBps;            // Default: 2000 (20%)
    uint16 activeCreditShareBps;        // Share to Active Credit Index
    bool treasuryShareConfigured;
    uint128 actionFeeMin;
    uint128 actionFeeMax;
    bool actionFeeBoundsSet;
    address foundationReceiver;         // Maintenance fee recipient
    uint16 defaultMaintenanceRateBps;
    uint16 maxMaintenanceRateBps;
    uint256 indexCreationFee;
    uint256 poolCreationFee;            // Fee for unmanaged pool creation
    uint256 managedPoolCreationFee;     // Fee for managed pool creation (0 = disabled)
    uint8 rollingDelinquencyEpochs;     // Default: 2
    uint8 rollingPenaltyEpochs;         // Default: 3
}
```

**Treasury Split Configuration**:
```solidity
// Fee distribution from LibFeeTreasury
uint16 shareBps = treasurySplitBps(store);           // Treasury share
uint16 activeShareBps = activeCreditSplitBps(store); // Active Credit share
require(shareBps + activeShareBps <= 10_000);

toTreasury = (amount * shareBps) / 10_000;
toActiveCredit = (amount * activeShareBps) / 10_000;
toFeeIndex = amount - toTreasury - toActiveCredit;
```

### 5.3 Position Key Derivation

**Formula**:
```solidity
// In PositionNFT.sol
function getPositionKey(uint256 tokenId) public view returns (bytes32) {
    return keccak256(abi.encodePacked(address(this), tokenId));
}
```

**Properties**:
- Deterministic: Same NFT always produces same key
- Unique: Different NFTs produce different keys
- Transfer-stable: Key doesn't change when NFT ownership changes
- Collision-resistant: Keccak256 ensures uniqueness

---

## 6. Protocol Mechanics

### 6.1 Solvency Calculation

**Total Debt Calculation** (via `LibSolvencyChecks`):
```solidity
function calculateTotalDebt(
    PoolData storage p,
    bytes32 positionKey,
    uint256 pid
) internal view returns (uint256 totalDebt) {
    // Loan debts (rolling + fixed-term)
    (,, uint256 loanDebt) = calculateLoanDebts(p, positionKey);
    
    // Direct borrowed principal
    DirectStorage storage ds = LibDirectStorage.directStorage();
    uint256 directDebt = ds.directBorrowedPrincipal[positionKey][pid];
    
    totalDebt = loanDebt + directDebt;
}
```

**Available Principal Calculation** (via `LibSolvencyChecks` using centralized `LibEncumbrance`):
```solidity
function calculateAvailablePrincipal(
    PoolData storage p,
    bytes32 positionKey,
    uint256 pid
) internal view returns (uint256 available) {
    uint256 principal = p.userPrincipal[positionKey];
    
    // Get all encumbrance components from centralized storage
    LibEncumbrance.Encumbrance memory enc = LibEncumbrance.get(positionKey, pid);
    uint256 totalEncumbered = 
        enc.directLocked + enc.directLent + enc.directOfferEscrow + enc.indexEncumbered;
    
    if (totalEncumbered >= principal) {
        return 0;
    }
    available = principal - totalEncumbered;
}
```

**Solvency Check** (via `LibSolvencyChecks`):
```solidity
function checkSolvency(
    PoolData storage p,
    bytes32 positionKey,
    uint256 newPrincipal,
    uint256 newDebt
) internal view returns (bool isSolvent) {
    if (newDebt == 0) return true;
    
    // LTV must be set to a non-zero value; zero disables borrowing
    uint16 ltvBps = p.poolConfig.depositorLTVBps;
    if (ltvBps == 0) return false;
    
    uint256 maxBorrowable = (newPrincipal * ltvBps) / 10_000;
    return newDebt <= maxBorrowable;
}
```

### 6.2 Fee Distribution Flow

**Treasury Split Mechanism**:
```solidity
function accrueWithTreasury(
    PoolData storage p,
    uint256 pid,
    uint256 amount,
    bytes32 source
) internal returns (uint256 toTreasury, uint256 toActiveCredit, uint256 toIndex) {
    if (amount == 0) return (0, 0, 0);
    
    uint16 shareBps = LibAppStorage.treasurySplitBps(store);
    uint16 activeShareBps = LibAppStorage.activeCreditSplitBps(store);
    require(shareBps + activeShareBps <= 10_000, "splits>100%");
    
    toTreasury = treasury != address(0) ? (amount * shareBps) / 10_000 : 0;
    toActiveCredit = (amount * activeShareBps) / 10_000;
    toIndex = amount - toTreasury - toActiveCredit;
    
    if (toTreasury > 0) {
        p.trackedBalance -= toTreasury;
        IERC20(p.underlying).safeTransfer(treasury, toTreasury);
    }
    if (toActiveCredit > 0) {
        LibActiveCreditIndex.accrueWithSource(pid, toActiveCredit, source);
    }
    if (toIndex > 0) {
        LibFeeIndex.accrueWithSource(pid, toIndex, source);
    }
}
```

### 6.3 Interest Calculations

**Rolling Interest**:
```solidity
function calculateRollingInterest(
    uint256 principal,
    uint16 apyBps,
    uint256 elapsed
) internal pure returns (uint256) {
    if (apyBps == 0 || elapsed == 0 || principal == 0) return 0;
    return (principal * apyBps * elapsed) / (365 days * 10_000);
}
```

**Fixed-Term Interest**:
```solidity
function calculateFixedInterest(
    uint256 principal,
    uint16 apyBps,
    uint256 durationSecs
) internal pure returns (uint256) {
    return (principal * apyBps * durationSecs) / (365 days * 10_000);
}
```

**Direct Lending Interest**:
```solidity
function calculateDirectInterest(
    uint256 principal,
    uint16 aprBps,
    uint256 durationSeconds
) internal pure returns (uint256) {
    if (aprBps == 0 || durationSeconds == 0 || principal == 0) return 0;
    return Math.mulDiv(principal, uint256(aprBps) * durationSeconds, (365 days) * 10_000);
}
```

---

## 7. Security Model

### 7.1 Threat Model

**In-Scope Threats**:
1. Borrower default (covered by collateral)
2. Reentrancy attacks (mitigated by guards)
3. Integer overflow/underflow (Solidity 0.8+ checks)
4. Precision loss in fee calculations (remainder tracking)
5. Pool isolation violations (tracked balance enforcement)
6. Solvency constraint bypass (comprehensive checks)

**Out-of-Scope**:
1. Oracle manipulation (no oracles used)
2. Governance attacks (timelock-protected)
3. External contract failures (isolated pools)
4. Network-level attacks (L1/L2 security model)

### 7.2 Access Control

**Roles**:
- **Owner**: Diamond owner (via LibDiamond)
  - Can execute diamond cuts (add/remove/replace facets)
  - Can transfer ownership
  
- **Timelock**: Delayed admin operations
  - Set treasury address
  - Configure fee parameters
  - Update maintenance rates
  - Pause/unpause indexes
  
- **Manager** (Managed Pools Only):
  - Modify mutable pool parameters
  - Manage whitelist entries
  - Transfer or renounce management
  
- **Minter**: Position NFT minting authority
  - Typically the PositionManagementFacet
  - Can mint new Position NFTs
  
- **Users**: Position NFT holders
  - Full control over their positions
  - Can deposit, withdraw, borrow, repay
  - Can transfer NFTs (transfers all state)

### 7.3 Reentrancy Protection

**Strategy**: ReentrancyGuard on all state-changing external functions.

**Critical Paths**:
- All lending operations (open, repay, close)
- All Direct operations (accept, repay, recover)
- Flash loans (callback to external receiver)
- Index operations (mint, burn, flash)
- Withdrawals and deposits

### 7.4 Invariants

**Global Invariants**:
1. `sum(userPrincipal[all users]) == totalDeposits` (per pool)
2. `feeIndex` never decreases (monotone)
3. `trackedBalance >= sum(all obligations)` (per pool)
4. `LibEncumbrance.total(positionKey, poolId) <= userPrincipal[positionKey]` (per position, per pool)

**Per-Position Invariants**:
1. `totalDebt <= (availableCollateral * depositorLTVBps) / 10000`
2. `rollingLoan.principalRemaining <= rollingLoan.principal`
3. `fixedLoan.principalRemaining <= fixedLoan.principal`
4. `activeFixedLoanCount == userFixedLoanIds.length`
5. `LibEncumbrance.total(positionKey, poolId) <= userPrincipal[positionKey]` (total encumbrance cannot exceed principal)

**Pool Isolation Invariants**:
1. Operations on pool A never modify pool B state
2. `trackedBalance[poolId]` only changes via pool-specific operations
3. Maintenance fees paid from pool's own `trackedBalance`

---

## 8. Integration Points

### 8.1 External Dependencies

**OpenZeppelin Contracts**:
- `ERC721Enumerable`: Position NFT base
- `ERC20`: Index tokens
- `SafeERC20`: Safe token transfers
- `ReentrancyGuard`: Reentrancy protection
- `Math`: Precision math operations

**No External Oracles**:
- All pricing deterministic
- No Chainlink or other price feeds
- Time-based credit only

### 8.2 Token Standards

**Position NFT (ERC-721)**:
- Standard compliant
- Enumerable extension
- On-chain metadata (SVG + JSON)
- Transfer hooks for Direct offer cancellation

**Index Tokens (ERC-20)**:
- Standard compliant
- Minted/burned by EqualIndexFacetV3
- No direct transfers (must mint/burn)

### 8.3 Event Emissions

**Position Events**:
```solidity
event PositionMinted(uint256 indexed tokenId, address indexed owner, uint256 indexed poolId);
event DepositMade(uint256 indexed tokenId, address indexed owner, uint256 indexed poolId, uint256 amount);
event WithdrawalMade(uint256 indexed tokenId, address indexed owner, uint256 indexed poolId, uint256 amount);
```

**Loan Events**:
```solidity
event RollingLoanOpenedFromPosition(uint256 indexed tokenId, address indexed owner, uint256 indexed poolId, uint256 principal, bool depositBacked);
event PaymentMadeFromPosition(uint256 indexed tokenId, address indexed owner, uint256 indexed poolId, uint256 paymentAmount, uint256 principalPaid, uint256 interestPaid, uint256 remainingPrincipal);
event FixedLoanOpenedFromPosition(uint256 indexed tokenId, address indexed owner, uint256 indexed poolId, uint256 loanId, uint256 principal, uint256 fullInterest, uint40 expiry, uint16 apyBps, bool interestRealizedAtInitiation);
```

**Penalty Events**:
```solidity
event RollingLoanPenalized(uint256 indexed tokenId, address indexed enforcer, uint256 indexed poolId, uint256 enforcerShare, uint256 protocolShare, uint256 feeIndexShare, uint256 activeCreditShare, uint256 penaltyApplied, uint256 principalAtOpen);
event TermLoanDefaulted(uint256 indexed tokenId, address indexed enforcer, uint256 indexed poolId, uint256 loanId, uint256 penaltyApplied, uint256 principalAtOpen);
```

**Direct Term Events**:
```solidity
event DirectOfferPosted(uint256 indexed offerId, address indexed borrowAsset, uint256 indexed collateralPoolId, ...);
event DirectOfferAccepted(uint256 indexed offerId, uint256 indexed agreementId, uint256 indexed borrowerPositionId, uint256 principalFilled, uint256 trancheAmount, uint256 trancheRemainingAfter, uint256 fillsRemaining, bool isDepleted);
event DirectAgreementRepaid(uint256 indexed agreementId, address indexed borrower, uint256 principalRepaid);
event DirectAgreementRecovered(uint256 indexed agreementId, address indexed executor, uint256 lenderShare, uint256 protocolShare, uint256 feeIndexShare);
event DirectAgreementExercised(uint256 indexed agreementId, address indexed borrower);
event DirectAgreementCalled(uint256 indexed agreementId, uint256 indexed lenderPositionId, uint64 newDueTimestamp);
```

**Direct Rolling Events**:
```solidity
event RollingOfferPosted(uint256 indexed offerId, address indexed borrowAsset, uint256 indexed collateralPoolId, ...);
event RollingBorrowerOfferPosted(uint256 indexed offerId, address indexed borrowAsset, uint256 indexed collateralPoolId, ...);
event RollingOfferAccepted(uint256 indexed offerId, uint256 indexed agreementId, address indexed borrower);
event RollingPaymentMade(uint256 indexed agreementId, address indexed payer, uint256 paymentAmount, uint256 arrearsReduction, uint256 interestPaid, uint256 principalReduction, uint64 nextDue, uint16 paymentCount, uint256 newOutstandingPrincipal, uint256 newArrears);
event RollingAgreementRecovered(uint256 indexed agreementId, address indexed executor, uint256 penaltyPaid, uint256 arrearsPaid, uint256 principalRecovered, uint256 borrowerRefund, uint256 protocolShare, uint256 feeIndexShare, uint256 activeCreditShare);
event RollingAgreementExercised(uint256 indexed agreementId, address indexed borrower, uint256 arrearsPaid, uint256 principalRecovered, uint256 borrowerRefund);
event RollingAgreementRepaid(uint256 indexed agreementId, address indexed borrower, uint256 repaymentAmount, uint256 arrearsCleared, uint256 principalCleared);
```

**Active Credit Index Events**:
```solidity
event ActiveCreditIndexAccrued(uint256 indexed pid, uint256 amount, uint256 delta, uint256 newIndex, bytes32 source);
event ActiveCreditSettled(uint256 indexed pid, address indexed user, uint256 prevIndex, uint256 newIndex, uint256 addedYield, uint256 totalAccruedYield);
event ActiveCreditTimingUpdated(uint256 indexed pid, address indexed user, bool isDebtState, uint40 startTime, uint256 principal, bool isMature);
```

**Managed Pool Events**:
```solidity
event PoolInitializedManaged(uint256 indexed pid, address indexed underlying, address indexed manager, ManagedPoolConfig config);
event ManagedConfigUpdated(uint256 indexed pid, string parameter, bytes oldValue, bytes newValue);
event WhitelistUpdated(uint256 indexed pid, address indexed user, bool added);
event WhitelistToggled(uint256 indexed pid, bool enabled);
event ManagerTransferred(uint256 indexed pid, address indexed oldManager, address indexed newManager);
event ManagerRenounced(uint256 indexed pid, address indexed formerManager);
```

---

## 9. Testing Strategy

### 9.1 Test Coverage Overview

**Test Categories**:
1. **Unit Tests**: Specific function behavior and edge cases
2. **Property Tests**: Universal invariants across random inputs (100+ iterations)
3. **Integration Tests**: Cross-facet interactions and workflows
4. **Invariant Tests**: Continuous invariant checking during fuzzing
5. **Gas Benchmarks**: Performance regression tracking

**Coverage Statistics**:
- 60+ test files
- 1000+ individual test cases
- Property-based tests with 100+ iterations each
- Cross-facet integration scenarios
- Edge case and boundary testing

### 9.2 Property-Based Testing

**Key Properties Tested**:

1. **FeeIndex Monotonicity**: `feeIndex` never decreases
2. **Solvency Preservation**: All operations maintain solvency constraints
3. **Pool Isolation**: Operations on one pool don't affect others
4. **Principal Conservation**: `sum(userPrincipal) == totalDeposits`
5. **Encumbrance Capacity**: `LibEncumbrance.total(positionKey, poolId) <= userPrincipal`
6. **Penalty Correctness**: Penalty distribution sums correctly

### 9.3 Critical Test Scenarios

**Scenario 1: Multi-Pool Position with Mixed Debt**
- Position with deposits in Pool A
- Rolling loan in Pool A
- Fixed-term loans in Pool A
- Direct lending exposure to Pool B
- Verify solvency across all obligations

**Scenario 2: Direct Lending Cross-Asset Default**
- Lender in USDC pool
- Borrower in WETH pool
- Default occurs
- Verify collateral redistribution
- Verify pool isolation maintained

**Scenario 3: Rolling P2P with Arrears Accumulation**
- Rolling agreement with missed payments
- Arrears accumulate over multiple intervals
- Partial payment clears arrears first
- Recovery after grace period

**Scenario 4: Position Transfer with Active Loans**
- NFT with active rolling and fixed loans
- Transfer to new owner
- Verify position key unchanged
- Verify new owner can operate loans
- Verify transfer reverts if Direct offers exist

**Scenario 5: Managed Pool Whitelist Enforcement**
- Create managed pool with whitelist enabled
- Attempt auto-join from non-whitelisted position (should revert)
- Add position to whitelist
- Verify auto-join succeeds after whitelisting

---

## 10. Deployment and Operations

### 10.1 Deployment Sequence

1. **Deploy Diamond Infrastructure**:
   - Deploy Diamond.sol
   - Deploy DiamondCutFacet
   - Deploy DiamondLoupeFacet
   - Initialize diamond with facets

2. **Deploy Core Facets**:
   - LendingFacet
   - PenaltyFacet
   - PositionManagementFacet
   - PoolManagementFacet
   - FlashLoanFacet
   - MaintenanceFacet
   - AdminFacet
   - AdminGovernanceFacet
   - FeeFacet
   - OwnershipFacet

3. **Deploy Position NFT**:
   ```solidity
   PositionNFT nft = new PositionNFT();
   // If you are wiring manually, set the diamond reference before setting the minter.
   nft.setDiamond(address(diamond));
   nft.setMinter(address(diamond));
   ```

4. **Deploy Direct Lending Facets**:
   - EqualLendDirectOfferFacet
   - EqualLendDirectAgreementFacet
   - EqualLendDirectLifecycleFacet
   - EqualLendDirectRollingOfferFacet
   - EqualLendDirectRollingAgreementFacet
   - EqualLendDirectRollingPaymentFacet
   - EqualLendDirectRollingLifecycleFacet
   - EqualLendDirectRollingViewFacet
   - EqualLendDirectViewFacet

5. **Deploy View Facets**:
   - ActiveCreditViewFacet
   - ConfigViewFacet
   - EnhancedLoanViewFacet
   - LiquidityViewFacet
   - LoanPreviewFacet
   - LoanViewFacet
   - MultiPoolPositionViewFacet
   - PoolUtilizationViewFacet
   - PositionViewFacet

6. **Deploy Derivative Facets**:
   - AmmAuctionFacet
   - OptionsFacet
   - FuturesFacet
   - MamCurveFacet
   - MamCurveViewFacet
   - DerivativeViewFacet

7. **Deploy Derivative Token Contracts**:
   ```solidity
   OptionToken optionToken = new OptionToken(baseURI, owner, address(diamond));
   FuturesToken futuresToken = new FuturesToken(baseURI, owner, address(diamond));

   OptionsFacet(diamond).setOptionToken(address(optionToken));
   FuturesFacet(diamond).setFuturesToken(address(futuresToken));
   ```

8. **Deploy Optional Facets**:
   - EqualIndexFacetV3
   - EqualIndexAdminFacetV3
   - EqualIndexActionsFacetV3
   - EqualIndexViewFacetV3

9. **Configure Protocol**:
   ```solidity
   AdminFacet(diamond).setTimelock(timelockAddress);
   AdminGovernanceFacet(diamond).setTreasury(treasuryAddress);
   AdminGovernanceFacet(diamond).setFoundationReceiver(receiverAddress);
   ```

### 10.2 Operational Procedures

**Unmanaged Pool Creation**:
```solidity
PoolConfig memory config = PoolConfig({
    // Self-secured pool loans do not charge interest; these fields are currently informational.
    rollingApyBps: 0,
    depositorLTVBps: 8000,            // 80% LTV
    maintenanceRateBps: 100,          // 1% annual
    flashLoanFeeBps: 9,               // 0.09%
    flashLoanAntiSplit: true,
    minDepositAmount: 100e18,
    minLoanAmount: 50e18,
    minTopupAmount: 10e18,
    isCapped: false,
    depositCap: 0,
    maxUserCount: 0,
    aumFeeMinBps: 50,
    aumFeeMaxBps: 500,
    fixedTermConfigs: [
        FixedTermConfig(30 days, 0),
        FixedTermConfig(90 days, 0),
        FixedTermConfig(180 days, 0)
    ],
    borrowFee: ActionFeeConfig({amount: 0, enabled: false}),
    repayFee: ActionFeeConfig({amount: 0, enabled: false}),
    withdrawFee: ActionFeeConfig({amount: 0, enabled: false}),
    flashFee: ActionFeeConfig({amount: 0, enabled: false}),
    closeRollingFee: ActionFeeConfig({amount: 0, enabled: false})
});

uint256 poolId = PoolManagementFacet(diamond).initPool{value: poolCreationFee}(
    pid, 
    address(usdc), 
    config
);
```

**Managed Pool Creation**:
```solidity
ManagedPoolConfig memory config = ManagedPoolConfig({
    rollingApyBps: 0,
    depositorLTVBps: 8000,
    maintenanceRateBps: 100,
    flashLoanFeeBps: 9,
    flashLoanAntiSplit: true,
    minDepositAmount: 100e18,
    minLoanAmount: 50e18,
    minTopupAmount: 10e18,
    isCapped: true,
    depositCap: 1000000e18,
    maxUserCount: 100,
    aumFeeMinBps: 50,
    aumFeeMaxBps: 500,
    fixedTermConfigs: [...],
    actionFees: ActionFeeSet(...),
    manager: msg.sender,           // Must be msg.sender or address(0)
    whitelistEnabled: true         // Must be true at creation
});

uint256 poolId = PoolManagementFacet(diamond).initManagedPool{value: managedPoolCreationFee}(
    pid,
    address(usdc),
    config
);
```

**Direct Lending Configuration**:
```solidity
DirectConfig memory directConfig = DirectConfig({
    platformFeeBps: 50,
    platformSplitLenderBps: 4000,
    platformSplitFeeIndexBps: 3000,
    platformSplitProtocolBps: 2000,
    platformSplitActiveCreditIndexBps: 1000,
    defaultFeeIndexBps: 7000,
    defaultProtocolBps: 2000,
    defaultActiveCreditIndexBps: 1000,
    minInterestDuration: 1 hours,
    protocolTreasury: treasuryAddress
});

DirectRollingConfig memory rollingConfig = DirectRollingConfig({
    minPaymentIntervalSeconds: 7 days,
    maxPaymentCount: 520,
    maxUpfrontPremiumBps: 5000,
    minRollingApyBps: 1,
    maxRollingApyBps: 10000,
    defaultPenaltyBps: 500,
    minPaymentWei: 1e15
});
```

### 10.3 Monitoring

**Key Metrics**:
1. **Pool Health**: totalDeposits, trackedBalance, userCount, pendingMaintenance
2. **Loan Metrics**: Active loans count, delinquency rate, penalty frequency
3. **Direct Lending**: Active offers/agreements, default rate, average APR
4. **Fee Revenue**: FeeIndex growth, treasury accumulation, Active Credit distribution
5. **Managed Pools**: Whitelist size, manager activity, config changes

---

## Appendices

### A.1 Glossary

- **Position NFT**: ERC-721 token representing an isolated account in a pool
- **Position Key**: Deterministic `bytes32` derived from NFT contract and token ID
- **FeeIndex**: Cumulative yield distribution index (1e18 scale)
- **MaintenanceIndex**: Cumulative AUM fee deduction index
- **Active Credit Index**: Time-gated yield distribution for active credit participants
- **Tracked Balance**: Per-pool token balance for isolation
- **Depositor LTV**: Maximum loan-to-value ratio for deposit-backed borrowing
- **Direct Lending**: Peer-to-peer term or rolling loans between Position NFT holders
- **Upfront Realization**: Interest paid at loan origination, not maturity
- **Early Exercise**: Voluntary collateral forfeiture before maturity
- **Penalty Settlement**: Fixed 5% penalty instead of full liquidation
- **Fee Base**: Normalized principal amount used for fee calculations
- **Principal At Open**: Immutable penalty basis recorded at loan creation
- **Grace Period**: Time window after due timestamp for repayment (24 hours for Direct)
- **Arrears**: Accumulated unpaid interest in rolling loans
- **Amortization**: Principal reduction through payments
- **Managed Pool**: Pool with mutable configuration and whitelist gating
- **Whitelist**: Position key-based access control for managed pools
- **Lender Call**: Optional feature allowing lender to accelerate due timestamp
- **Explicit Exercise**: Direct loans require an explicit `exerciseDirect` call (not automatic on acceptance)
- **Borrower Offer**: Direct lending offer posted by borrower specifying desired terms
- **Ratio Tranche Offer**: CLOB-style offer with price ratio for variable-size fills
- **Borrower Ratio Tranche Offer**: Borrower-posted ratio tranche offer with collateral cap
- **AMM Auction**: Time-bounded constant-product liquidity pool created by a Maker using assets from two pools
- **Option Series**: Set of fungible ERC-1155 tokens representing covered call or secured put options
- **Futures Series**: Set of fungible ERC-1155 tokens representing physical delivery futures
- **Option Token**: ERC-1155 contract for option rights, controlled by the Diamond
- **Futures Token**: ERC-1155 contract for futures rights, controlled by the Diamond
- **Strike Price**: Predetermined price at which an option can be exercised (1e18 normalized)
- **Forward Price**: Predetermined price for futures settlement (1e18 normalized)
- **Invariant**: Constant product (k = reserveA × reserveB) maintained by AMM auctions
- **MAM Curve**: Maker Auction Market curve - a time-bounded Dutch auction for selling base assets at linearly interpolated prices
- **Dutch Auction**: Auction mechanism where price decreases (or increases) over time until a buyer accepts
- **Base Asset**: The asset being sold in a MAM curve (locked by maker)
- **Quote Asset**: The asset received by maker in exchange for base asset fills
- **Curve Generation**: Version counter incremented on each curve update, enabling price/timing changes without cancellation
- **Curve Commitment**: Hash of the full curve descriptor, updated on each generation change
- **Flash Accounting**: Deferred ledger update model where userPrincipal and userFeeIndex are not updated during intermediate states
- **Encumbered Balance**: Principal flagged as backing a derivative, preventing withdrawal but continuing to accrue fees
- **LibEncumbrance**: Centralized library for all encumbrance tracking (directLocked, directLent, directOfferEscrow, indexEncumbered) per position and pool
- **LibNetEquity**: Pure helper library for fee base calculations (same-asset, cross-asset, P2P borrower)
- **LibFeeIndex**: Fee index accounting library (1e18 scale) for yield distribution
- **LibSolvencyChecks**: Shared utilities for deterministic solvency and debt calculations
- **LibIndexEncumbrance**: Thin wrapper around LibEncumbrance for index-specific encumbrance operations

### A.2 Formula Reference

**Solvency Ratio**:
```
solvencyRatio = (availableCollateral * 10000) / totalDebt
require(solvencyRatio >= depositorLTVBps)
```

**Simple Interest**:
```
interest = (principal * apyBps * timeSeconds) / (365 days * 10_000)
```

**Penalty Calculation**:
```
penalty = principalAtOpen * 500 / 10_000  // Fixed 5%
penaltyApplied = min(penalty, principalRemaining, availableCollateral)
```

**Penalty Distribution**:
```
enforcerShare = penaltyApplied / 10                           // 10%
remaining = penaltyApplied - enforcerShare
feeIndexShare = (remaining * 70) / 100                        // 63% of total
protocolShare = (remaining * 10) / 100                        // 9% of total
activeCreditShare = remaining - feeIndexShare - protocolShare // 18% of total
```

**Fee Base Calculation**:
```
// Same-asset domains
feeBase = max(0, principal - sameAssetDebt)

// Cross-asset domains  
feeBase = lockedCollateral + unlockedPrincipal
```

**FeeIndex Accrual**:
```
delta = (feeAmount * 1e18) / totalDeposits
feeIndex += delta
```

**Active Credit Time Gate**:
```
TIME_GATE = 24 hours
timeCredit = min(24 hours, currentTime - startTime)
activeWeight = timeCredit >= 24 hours ? principal : 0
```

**Weighted Dilution**:
```
newTimeCredit = (oldPrincipal * oldTimeCredit) / (oldPrincipal + newPrincipal)
newStartTime = currentTime - newTimeCredit
```

**Ratio Tranche Collateral**:
```
collateralRequired = (principalAmount * priceNumerator) / priceDenominator
```

**MAM Curve Linear Price Interpolation**:
```
// At time t within [startTime, startTime + duration]
elapsed = t - startTime
delta = |endPrice - startPrice|
adjustment = (delta * elapsed) / duration

// If endPrice >= startPrice (ascending):
price = startPrice + adjustment

// If endPrice < startPrice (descending):
price = startPrice - adjustment

// Boundary conditions:
// t <= startTime: price = startPrice
// t >= endTime: price = endPrice
```

**MAM Curve Fill Calculation**:
```
// Quote to base conversion (1e18 scaled)
baseFill = (amountIn * 1e18) / price

// Fee calculation
feeAmount = (amountIn * feeRateBps) / 10_000

// Fee distribution
makerFee = (feeAmount * 7000) / 10_000      // 70%
indexFee = (feeAmount * 2000) / 10_000      // 20%
treasuryFee = feeAmount - makerFee - indexFee // 10%
```

### A.3 References

- [EIP-2535: Diamond Standard](https://eips.ethereum.org/EIPS/eip-2535)
- [EIP-721: Non-Fungible Token Standard](https://eips.ethereum.org/EIPS/eip-721)
- [OpenZeppelin Contracts](https://docs.openzeppelin.com/contracts/)
- [Foundry Book](https://book.getfoundry.sh/)

## 11. Position NFT Derivatives

### 11.1 Overview

Equalis includes oracle-free AMM Auctions, Options, Futures, and Maker Auction Markets (MAM) integrated using Position NFTs as the universal identity and Pools as the unified collateral source. This enables users to underwrite derivatives, provide AMM liquidity, and create Dutch auction curves without withdrawing funds from the protocol.

**Key Characteristics**:
- **Oracle-Free**: All products operate without external price oracles
- **Fully Collateralized**: 100% collateralization at the smart contract level
- **Flash Accounting**: Liabilities isolated via `directLockedPrincipal` and `directLentPrincipal`
- **Capital Efficient**: Locked collateral continues earning fee index yield
- **Unified Identity**: Single Position NFT can simultaneously hold deposits, write options, sell futures, market-make AMMs, and create MAM curves

### 11.2 Product Types

#### A. AMM Auctions (Time-Bounded Liquidity)

**Mechanism**: A Maker locks assets from two pools (Pool A + Pool B) to define a constant-product curve (k = x * y). Auctions may be scheduled with a start time in the future.

**Key Features**:
- Deterministic pricing based on invariant (no oracle required)
- Time-bounded with configurable start and end times
- Configurable swap fees with protocol fee split
- Reserves tracked as `directLentPrincipal` so they continue earning fee index

**Data Structure**:
```solidity
struct AmmAuction {
    bytes32 makerPositionKey;
    uint256 makerPositionId;
    uint256 poolIdA;
    uint256 poolIdB;
    address tokenA;
    address tokenB;
    uint256 reserveA;
    uint256 reserveB;
    uint256 invariant;           // k = reserveA * reserveB
    uint64 startTime;
    uint64 endTime;
    uint16 feeBps;
    FeeAsset feeAsset;           // TokenIn or TokenOut
    uint256 makerFeeAAccrued;
    uint256 makerFeeBAccrued;
    bool active;
    bool finalized;
}
```

**Lifecycle**:
1. **Create**: `createAuction(params)` - Lock reserves via `directLentPrincipal`, compute invariant
2. **Swap**: `swapExactIn(auctionId, tokenIn, amountIn, minOut, recipient)` - Execute constant-product swap
3. **Finalize**: `finalizeAuction(auctionId)` - Release locks, apply net reserve changes to maker principal
4. **Cancel**: `cancelAuction(auctionId)` - Maker can cancel before expiry, returning reserves

#### B. Options (Yield-Bearing Covered Derivatives)

**Mechanism**: A Maker locks collateral to mint fungible ERC-1155 Option Tokens.
- **Covered Call**: Maker locks underlying asset (e.g., ETH)
- **Secured Put**: Maker locks strike asset (e.g., USDC)

**Key Features**:
- American or European style exercise
- Strike price uses canonical 1e18 quote-per-1e18-underlying normalization
- Locked funds continue earning passive yield while backing the derivative
- ERC-1155 tokens freely tradeable on secondary markets

**Data Structure**:
```solidity
struct OptionSeries {
    bytes32 makerPositionKey;
    uint256 makerPositionId;
    uint256 underlyingPoolId;
    uint256 strikePoolId;
    address underlyingAsset;
    address strikeAsset;
    uint256 strikePrice;         // 1e18 scaled (strike per underlying)
    uint64 expiry;
    uint256 totalSize;
    uint256 remaining;
    uint256 collateralLocked;
    bool isCall;
    bool isAmerican;
    bool reclaimed;
}
```

**Lifecycle**:
1. **Create**: `createOptionSeries(params)` - Lock collateral via `directLockedPrincipal`, mint ERC-1155 tokens to maker
2. **Exercise**: `exerciseOptions(seriesId, amount, recipient)` - Holder burns tokens, atomic swap of strike for collateral
3. **Reclaim**: `reclaimOptions(seriesId)` - Maker burns remaining supply after expiry to reclaim collateral

#### C. Futures (Physical Delivery)

**Mechanism**: A Maker locks the underlying asset to mint ERC-1155 Futures Tokens.

**Key Features**:
- American (early settlement allowed) or European style
- Forward price uses canonical 1e18 normalization
- Grace period before maker can reclaim unsettled futures
- Physical delivery of underlying on settlement

**Data Structure**:
```solidity
struct FuturesSeries {
    bytes32 makerPositionKey;
    uint256 makerPositionId;
    uint256 underlyingPoolId;
    uint256 quotePoolId;
    address underlyingAsset;
    address quoteAsset;
    uint256 forwardPrice;        // 1e18 scaled
    uint64 expiry;
    uint256 totalSize;
    uint256 remaining;
    uint256 underlyingLocked;
    uint64 graceUnlockTime;
    bool isEuropean;
    bool reclaimed;
}
```

**Lifecycle**:
1. **Create**: `createFuturesSeries(params)` - Lock underlying via `directLockedPrincipal`, mint ERC-1155 tokens
2. **Settle**: `settleFutures(seriesId, amount, recipient)` - Holder burns tokens, pays forward price, receives underlying
3. **Reclaim**: `reclaimFutures(seriesId)` - Maker burns remaining supply after grace period to reclaim underlying

#### D. Maker Auction Markets (MAM Curves)

**Mechanism**: A Maker creates a time-bounded Dutch auction curve that sells a base asset for a quote asset at a linearly interpolated price. The price transitions from `startPrice` to `endPrice` over the curve's duration, enabling price discovery through time-based execution.

**Key Features**:
- Linear Dutch auction pricing (price interpolates between start and end over duration)
- Time-bounded with configurable start time and duration
- Partial fills supported with remaining volume tracking
- Configurable swap fees with 70/20/10 split (maker/FeeIndex/treasury)
- Base collateral locked via `directLockedPrincipal` (continues earning fee index)
- Generation-based updates allow price/timing changes without cancellation
- Batch operations for efficient multi-curve management
- CurveId-only execution path for gas efficiency

**Price Mechanics**:
```solidity
// Linear interpolation: price transitions from startPrice to endPrice over duration
// At t <= startTime: price = startPrice
// At t >= endTime: price = endPrice
// Between: price = startPrice + (endPrice - startPrice) * elapsed / duration

function computePrice(
    uint256 startPrice,
    uint256 endPrice,
    uint256 start,
    uint256 duration,
    uint256 t
) returns (uint256) {
    if (t <= start) return startPrice;
    uint256 end = start + duration;
    if (t >= end) return endPrice;
    uint256 elapsed = t - start;
    uint256 delta = (endPrice > startPrice) 
        ? (endPrice - startPrice) 
        : (startPrice - endPrice);
    uint256 adj = (delta * elapsed) / duration;
    return (endPrice >= startPrice) 
        ? (startPrice + adj) 
        : (startPrice - adj);
}
```

**Data Structures**:
```solidity
/// @notice Execution side relative to tokenA/tokenB
enum Side {
    SellAForB,
    SellBForA
}

/// @notice Fee asset marker
enum FeeAsset {
    TokenIn,
    TokenOut
}

/// @notice Canonical curve descriptor used at creation time
struct CurveDescriptor {
    bytes32 makerPositionKey;
    uint256 makerPositionId;
    uint256 poolIdA;
    uint256 poolIdB;
    address tokenA;
    address tokenB;
    bool side;                   // false: SellAForB, true: SellBForA
    bool priceIsQuotePerBase;    // Price interpretation flag
    uint128 maxVolume;           // Maximum base asset volume
    uint128 startPrice;          // Starting price (1e18 scaled)
    uint128 endPrice;            // Ending price (1e18 scaled)
    uint64 startTime;            // Auction start timestamp
    uint64 duration;             // Auction duration in seconds
    uint32 generation;           // Update counter (starts at 1)
    uint16 feeRateBps;           // Fee rate in basis points
    FeeAsset feeAsset;           // Fee charged on TokenIn
    uint96 salt;                 // Unique identifier for commitment
}

/// @notice Minimal onchain representation for a committed curve
struct StoredCurve {
    bytes32 commitment;          // Hash of full descriptor
    uint128 remainingVolume;     // Unfilled base volume
    uint64 endTime;              // Computed end timestamp
    uint32 generation;           // Current generation number
    bool active;                 // Curve can be filled
}

/// @notice Mutable parameters for curve updates
struct CurveUpdateParams {
    uint128 startPrice;
    uint128 endPrice;
    uint64 startTime;
    uint64 duration;
}

/// @notice View struct for fill operations
struct CurveFillView {
    bytes32 makerPositionKey;
    uint256 makerPositionId;
    uint256 poolIdA;
    uint256 poolIdB;
    address tokenA;
    address tokenB;
    bool baseIsA;
    uint128 startPrice;
    uint128 endPrice;
    uint64 startTime;
    uint64 duration;
    uint16 feeRateBps;
    uint128 remainingVolume;
}
```

**Storage Layout**:
```solidity
// Per-curve storage split for gas optimization
struct CurveData {
    bytes32 makerPositionKey;
    uint256 makerPositionId;
    uint256 poolIdA;
    uint256 poolIdB;
}

struct CurveImmutables {
    address tokenA;
    address tokenB;
    uint128 maxVolume;
    uint96 salt;
    uint16 feeRateBps;
    bool priceIsQuotePerBase;
    FeeAsset feeAsset;
}

struct CurvePricing {
    uint128 startPrice;
    uint128 endPrice;
    uint64 startTime;
    uint64 duration;
}
```

**Lifecycle**:

1. **Create**: `createCurve(CurveDescriptor)` or `createCurvesBatch(CurveDescriptor[])`
   - Verify maker owns Position NFT and has pool membership
   - Validate descriptor parameters (prices, timing, pools)
   - Lock base asset volume via `directLockedPrincipal`
   - Compute commitment hash and store curve data
   - Emit `CurveCreated` event

2. **Update**: `updateCurve(curveId, CurveUpdateParams)` or `updateCurvesBatch(curveIds, params)`
   - Verify caller is curve maker
   - Validate new timing parameters (startTime must be in future)
   - Increment generation counter
   - Recompute commitment hash with new parameters
   - Emit `CurveUpdated` event

3. **Fill**: `executeCurveSwap(curveId, amountIn, minOut, deadline, recipient)`
   - Verify curve is active and within time window
   - Compute current price via linear interpolation
   - Calculate base fill amount from quote input
   - Verify sufficient remaining volume
   - Apply slippage protection (minOut check)
   - Pull quote tokens from taker
   - Distribute fees: 70% maker, 20% FeeIndex, 10% treasury
   - Credit maker with quote amount plus maker fee share
   - Unlock and transfer base tokens to recipient
   - Emit `CurveFilled` event

4. **Cancel**: `cancelCurve(curveId)` or `cancelCurvesBatch(curveIds)`
   - Verify caller is curve maker
   - Unlock remaining base volume
   - Mark curve inactive
   - Emit `CurveCancelled` event

**Fee Distribution**:
```solidity
// Fee split constants
uint16 constant FEE_SPLIT_MAKER_BPS = 7000;     // 70% to maker
uint16 constant FEE_SPLIT_INDEX_BPS = 2000;     // 20% to FeeIndex
uint16 constant FEE_SPLIT_TREASURY_BPS = 1000;  // 10% to treasury

// Fee calculation on fill
feeAmount = (amountIn * feeRateBps) / 10_000;
makerFee = (feeAmount * 7000) / 10_000;
indexFee = (feeAmount * 2000) / 10_000;
treasuryFee = feeAmount - makerFee - indexFee;

// Maker receives: amountIn + makerFee (credited to quote pool principal)
// FeeIndex receives: indexFee (accrued to quote pool FeeIndex)
// Treasury receives: treasuryFee (transferred out)
```

**Collateral Locking** (via centralized `LibEncumbrance`):
```solidity
// On curve creation - lock base asset via LibEncumbrance
LibEncumbrance.Encumbrance storage enc = LibEncumbrance.position(positionKey, basePoolId);
enc.directLocked += maxVolume;

// On fill - unlock filled amount
enc.directLocked -= baseFill;

// On cancel - unlock remaining volume
enc.directLocked -= remainingVolume;
```

**Generation-Based Updates**:
- Each curve starts with `generation = 1`
- Updates increment generation and recompute commitment
- Allows price/timing adjustments without cancellation
- Immutable fields (pools, tokens, maxVolume, salt, feeRate) cannot change
- Only mutable fields (startPrice, endPrice, startTime, duration) can be updated

**Validation Rules**:
- `maxVolume > 0`
- `startPrice > 0` and `endPrice > 0`
- `duration > 0`
- `startTime >= block.timestamp`
- `poolIdA != poolIdB`
- `tokenA != tokenB` and both non-zero
- Pool underlying assets must match descriptor tokens
- Maker must have pool membership in both pools
- `priceIsQuotePerBase` must be `true` (current implementation)
- `feeAsset` must be `TokenIn` (current implementation)
- `generation` must be `1` at creation

### 11.3 Collateral Locking Model

All encumbrance operations are centralized in `LibEncumbrance`, providing a unified storage and API:

**Encumbrance Structure**:
```solidity
struct Encumbrance {
    uint256 directLocked;       // Collateral locked (options, futures, MAM, borrower collateral)
    uint256 directLent;         // AMM reserves (continues earning fee index)
    uint256 directOfferEscrow;  // Escrowed offers
    uint256 indexEncumbered;    // Principal backing index tokens
}
```

**AMM Reserves** (via `LibEncumbrance.directLent`):
```solidity
// Lock - reserves continue earning fee index
LibEncumbrance.Encumbrance storage enc = LibEncumbrance.position(positionKey, poolId);
enc.directLent += amount;

// Unlock on finalization
enc.directLent -= amount;
```

**Options/Futures/MAM Collateral** (via `LibEncumbrance.directLocked`):
```solidity
// Lock - prevents withdrawal, excluded from LTV
LibEncumbrance.Encumbrance storage enc = LibEncumbrance.position(positionKey, poolId);
enc.directLocked += amount;

// Unlock on exercise/settlement/reclaim/fill/cancel
enc.directLocked -= amount;
```

**Index Encumbrance** (via `LibIndexEncumbrance` wrapper):
```solidity
// Lock principal for index token backing
LibIndexEncumbrance.encumber(positionKey, poolId, indexId, amount);

// Unlock on index token burn
LibIndexEncumbrance.unencumber(positionKey, poolId, indexId, amount);

// Query encumbrance
uint256 total = LibIndexEncumbrance.getEncumbered(positionKey, poolId);
uint256 forIndex = LibIndexEncumbrance.getEncumberedForIndex(positionKey, poolId, indexId);
```

**Total Encumbrance Query**:
```solidity
// Get all encumbrance components in a single call
LibEncumbrance.Encumbrance memory enc = LibEncumbrance.get(positionKey, poolId);
uint256 totalEncumbered = enc.directLocked + enc.directLent + enc.directOfferEscrow + enc.indexEncumbered;

// Or use the convenience function
uint256 totalEncumbered = LibEncumbrance.total(positionKey, poolId);
```

**Solvency Integration**:
- All encumbrance components are subtracted from available collateral for LTV calculations
- `directLent` (AMM reserves) continues earning fee index while encumbered
- All encumbrance types prevent withdrawal of the encumbered amount
- MAM curves use `directLocked` for base asset locking

### 11.4 Oracle-Free Solvency Guarantees

**AMM**: Invariant math guarantees reserves cannot be drained below k through swap operations.

**Options/Futures**: 100% collateralization at the smart contract level guarantees the Writer can always fulfill the obligation. No liquidations are possible or necessary.

**MAM Curves**: Full base volume locked at creation guarantees maker can fulfill any fill up to `maxVolume`. Linear price interpolation is deterministic and requires no external price feeds.

### 11.5 ERC-1155 Token Contracts

Two new ERC-1155 contracts controlled by the Diamond:

**OptionToken**:
- Mint/burn callable only by Diamond
- Series-specific metadata URIs
- Freely tradeable

**FuturesToken**:
- Mint/burn callable only by Diamond
- Series-specific metadata URIs
- Freely tradeable

### 11.6 Access Control

- **Creation**: Restricted to Position NFT owners and approved operators
- **Exercise/Settlement**: Restricted to ERC-1155 token holders and their approved operators
- **Reclaim**: Restricted to current Position NFT owner (maker rights follow NFT)
- **Pause**: Governance can pause creation while allowing finalization/exercise/settlement/reclaim

### 11.7 Events

```solidity
// AMM Auctions
event AuctionCreated(uint256 indexed auctionId, bytes32 indexed makerPositionKey, ...);
event AuctionSwapped(uint256 indexed auctionId, address indexed swapper, ...);
event AuctionFinalized(uint256 indexed auctionId, ...);
event AuctionCancelled(uint256 indexed auctionId, ...);

// Options
event SeriesCreated(uint256 indexed seriesId, bytes32 indexed makerPositionKey, bool isCall, ...);
event Exercised(uint256 indexed seriesId, address indexed holder, uint256 amount);
event Reclaimed(uint256 indexed seriesId, uint256 collateralReturned);

// Futures
event FuturesSeriesCreated(uint256 indexed seriesId, bytes32 indexed makerPositionKey, ...);
event Settled(uint256 indexed seriesId, address indexed holder, uint256 amount);
event FuturesReclaimed(uint256 indexed seriesId, uint256 underlyingReturned);

// MAM Curves
event CurveCreated(
    uint256 indexed curveId,
    bytes32 indexed makerPositionKey,
    uint256 indexed makerPositionId,
    uint256 poolIdA,
    uint256 poolIdB,
    address tokenA,
    address tokenB,
    bool baseIsA,
    uint128 maxVolume,
    uint128 startPrice,
    uint128 endPrice,
    uint64 startTime,
    uint64 duration,
    uint16 feeRateBps
);
event CurveUpdated(
    uint256 indexed curveId,
    bytes32 indexed makerPositionKey,
    uint32 generation,
    CurveUpdateParams params
);
event CurveFilled(
    uint256 indexed curveId,
    address indexed taker,
    address indexed recipient,
    uint256 amountIn,
    uint256 amountOut,
    uint256 feeAmount,
    uint256 remainingVolume
);
event CurveCancelled(uint256 indexed curveId, bytes32 indexed makerPositionKey, uint256 remainingVolume);
event CurvesBatchCreated(bytes32 indexed makerPositionKey, uint256 indexed firstCurveId, uint256 count);
event CurvesBatchUpdated(bytes32 indexed makerPositionKey, uint256 count);
event CurvesBatchCancelled(bytes32 indexed makerPositionKey, uint256 count);
event MamPausedUpdated(bool paused);
```

### 11.8 Use Cases

1. **Structured Products**: Bundle complex strategies (e.g., "Yield Enhanced Note" = Buy Bond + Write Put) into a single tradeable Position NFT
2. **Covered Call Writing**: Earn premium on held assets while maintaining yield exposure
3. **Secured Put Writing**: Generate yield on stablecoins while setting buy prices
4. **AMM Market Making**: Provide time-bounded liquidity with deterministic pricing
5. **Physical Delivery Futures**: Lock in forward prices for asset delivery
6. **Dutch Auction Sales**: Time-bounded price discovery for asset sales via MAM curves
7. **Programmatic Market Making**: Create multiple MAM curves with different price ranges for sophisticated trading strategies

---
