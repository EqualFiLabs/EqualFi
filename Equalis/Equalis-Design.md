# Equalis Protocol - Design Document

**Version:** 6.0  

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
3. **Oracle-Free Cross-Asset Lending**: Equalis Direct enables true P2P lending between any assets without price oracles - lenders set their own cross-asset terms and collateral ratios
4. **Equalis Direct Term Loans**: Peer-to-peer term lending with optional early exercise (American-style settlement), configurable prepayment policies, and borrower-initiated offers
5. **Equalis Direct Rolling Loans**: Peer-to-peer rolling credit with periodic payments, arrears tracking, amortization support, and configurable grace periods
6. **Ratio Tranche Offers**: CLOB-style offers with price ratios for variable-size fills, enabling order book-like trading dynamics for both lenders and borrowers
7. **Auto-Exercise on Fill**: Offers can be configured to immediately exercise upon acceptance, enabling synthetic options use cases
8. **Active Credit Index**: Time-gated fee subsidies for active credit participants (P2P lenders and same-asset borrowers) with weighted dilution anti-gaming protection
9. **Penalty-Based Default Settlement**: Fixed 5% penalty system for loan defaults instead of full liquidation, ensuring proportional and predictable outcomes
10. **Normalized Principal Accounting**: Fee base calculations prevent recursive fee inflation while maintaining lending expressiveness across same-asset and cross-asset domains
11. **EqualIndex Integration**: Multi-asset index token system with deterministic fee structures
12. **Diamond Architecture**: Modular facet-based design enabling upgradability while maintaining storage isolation

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
├─────────────────────────────────────────────────────────────────┤
│                      Shared Libraries                           │
│  LibFeeIndex │ LibMaintenance │ LibLoan │ LibSolvency │ ...     │
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
| **EqualisDirectOfferFacet** | P2P term lending offers | `postOffer`, `postRatioTrancheOffer`, `cancelOffer`, `cancelRatioTrancheOffer` |
| **EqualisDirectAgreementFacet** | P2P term agreement acceptance | `acceptOffer`, `acceptRatioTrancheOffer`, `acceptBorrowerOffer` |
| **EqualisDirectLifecycleFacet** | P2P term lifecycle | `repay`, `recover`, `exerciseDirect`, `callDirect` |
| **EqualisDirectRollingOfferFacet** | P2P rolling offers | `postRollingOffer`, `postBorrowerRollingOffer`, `cancelRollingOffer` |
| **EqualisDirectRollingAgreementFacet** | P2P rolling acceptance | `acceptRollingOffer` |
| **EqualisDirectRollingPaymentFacet** | P2P rolling payments | `makeRollingPayment` |
| **EqualisDirectRollingLifecycleFacet** | P2P rolling lifecycle | `recoverRolling`, `exerciseRolling`, `repayRollingInFull` |
| **EqualIndex Facets (V3)** | Multi-asset index tokens | Admin (`setIndexFees`, `setPaused`), Actions (`mint`, `burn`, `flashLoan`), View (`getIndex`, `getIndexAssets`, etc.) |
| **MaintenanceFacet** | AUM fee management | `pokeMaintenance`, `settleMaintenance` |
| **Admin / Governance** | Protocol governance | `setTimelock`, `setTreasury`, protocol splits |
| **ActiveCreditViewFacet** | Active credit queries | `pendingActiveCredit`, `getActiveCreditState` |
| **ConfigViewFacet** | Protocol configuration queries | `getPoolConfig`, `getDirectConfig` |
| **EnhancedLoanViewFacet** | Detailed loan information | `getLoanDetails`, `getLoanStatus` |
| **LiquidityViewFacet** | Pool liquidity queries | `getPoolLiquidity`, `getAvailableLiquidity` |
| **LoanPreviewFacet** | Loan simulation | `previewLoan`, `previewRepayment` |
| **LoanViewFacet** | Basic loan queries | `getLoan`, `getUserLoans` |
| **MultiPoolPositionViewFacet** | Cross-pool position state | `getPositionAcrossPools` |
| **PoolUtilizationViewFacet** | Utilization metrics | `getPoolUtilization` |
| **PositionViewFacet** | Position state queries | `getPositionState`, `getPositionDebt` |
| **EqualLendDirectViewFacet** | Direct lending queries | `getOffer`, `getAgreement`, `getUserOffers` |
| **EqualLendDirectRollingViewFacet** | Rolling direct queries | `getRollingOffer`, `getRollingAgreement` |

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
- Penalty proceeds distributed to protocol, not other depositors
- Pool isolation prevents cross-pool contagion

**Guarantees**:
- `userPrincipal[user]` can only decrease via user's own actions (withdrawals, fees, defaults)
- FeeIndex only increases (monotone property)
- MaintenanceIndex applies proportional haircut to all users equally

### 3.3 Deterministic Credit

**Principle**: All credit terms are fixed at origination with no reactive adjustments.

**Implementation**:
- Fixed APY rates set in immutable pool configuration
- Payment schedules determined by time, not utilization
- No oracle-based liquidations
- Upfront interest realization for fixed-term loans

**Loan Types**:
1. **Pool Rolling Credit**: Open-ended lines with periodic payment requirements
   - Payment interval: 30 days (configurable)
   - Delinquency threshold: 2 missed payments
   - Penalty threshold: 3 missed payments

2. **Pool Fixed-Term Loans**: Explicit term with upfront interest payment
   - Interest calculated at origination
   - Repayment only requires principal (interest already paid)
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
- Position key derived deterministically: `address(uint160(uint256(keccak256(abi.encodePacked(nftContract, tokenId)))))`
- Same position key used across all pools for this NFT
- Transferring NFT transfers all deposits, loans, and yield across all pools
- Users can hold multiple NFTs for different account containers

**Multi-Pool Position State**:
```solidity
// Single NFT can have state across multiple pools
struct MultiPoolPositionState {
    uint256 tokenId;
    address positionKey;            // Same key across all pools
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
- Outstanding Direct offers cancelled on transfer
- Tranche-backed Direct offers refund unused tranche escrow on transfer-triggered cancellation
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
mapping(address => mapping(uint256 => bool)) joined; // positionKey => poolId => joined
```

**Membership Operations**:

1. **Auto-Join** (`_ensurePoolMembership`):
   ```solidity
   function _ensurePoolMembership(address positionKey, uint256 pid, bool allowAutoJoin) 
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
   function _leavePool(address positionKey, uint256 pid, bool canClear, string memory reason) {
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
mapping(address => bool) whitelist;  // positionKey => whitelisted

// Adding to whitelist derives positionKey from tokenId
function addToWhitelist(uint256 pid, uint256 tokenId) external {
    address positionKey = nft.getPositionKey(tokenId);
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

**Mechanism**:
```solidity
// Global pool index (1e18 scale)
feeIndex = feeIndex + (feeAmount * 1e18) / totalDeposits

// Active Credit Index (parallel system)
activeCreditIndex = activeCreditIndex + (activeCreditAmount * 1e18) / totalActiveWeight

// Per-user settlement with normalized fee base
feeBase = calculateNormalizedFeeBase(user, poolAsset)
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

The fee base calculation depends on the relationship between assets and debt:

**1. Pool-Native Borrowing (Same Asset)**:
```solidity
function calculateFeeBaseSameAsset(uint256 principal, uint256 sameAssetDebt) 
    returns (uint256 feeBase) 
{
    return principal >= sameAssetDebt ? principal - sameAssetDebt : 0;
}
```

**2. P2P Direct Lending**:

**Same-Asset P2P** (`collateralAsset == lentAsset`):
```solidity
// Borrower fee base netted against P2P debt to prevent recursion
feeBase = max(0, collateralPrincipal - sameAssetP2PDebt)
```

**Cross-Asset P2P** (`collateralAsset != lentAsset`):
```solidity
// No netting required - different asset domains
feeBase = lockedCollateral + unlockedPrincipal
```

**3. Lender Principal Adjustment**:
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
- Interest payments (rolling and fixed-term)
- Flash loan fees
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

### 4.5 Pool Loan Management

#### 4.5.1 Rolling Credit Loans

**Characteristics**:
- Open-ended credit lines
- Periodic payment requirements (30 days default)
- Expandable via `expandRollingFromPosition`
- Single rolling loan per position per pool

**Lifecycle**:
1. **Open**: `openRollingFromPosition(tokenId, poolId, amount)`
   - Verify solvency: `newDebt <= collateral * depositorLTVBps / 10000`
   - Charge ACTION_BORROW fee
   - Transfer borrowed funds to NFT owner
   - Initialize loan state

2. **Payment**: `makePaymentFromPosition(tokenId, poolId, paymentAmount)`
   - Calculate minimum payment: accrued interest since last payment
   - Split payment: interest portion + principal portion
   - Route interest to FeeIndex via treasury split
   - Reset missed payment counter

3. **Expand**: `expandRollingFromPosition(tokenId, poolId, amount)`
   - Re-verify solvency with additional debt
   - Increase both `principal` and `principalRemaining`
   - Transfer additional funds

4. **Close**: `closeRollingCreditFromPosition(tokenId, poolId)`
   - Calculate total payoff: remaining principal + accrued interest
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

#### 4.5.2 Fixed-Term Loans

**Characteristics**:
- Explicit term with fixed expiry
- Upfront interest payment
- Multiple fixed-term loans per position
- No payment schedule (lump sum at maturity)

**Lifecycle**:
1. **Open**: `openFixedFromPosition(tokenId, poolId, amount, termIndex)`
   - Select term configuration from pool's `fixedTermConfigs`
   - Calculate upfront interest: `(amount * apyBps * durationSecs) / (365 days * 10_000)`
   - Deduct interest from position principal immediately
   - Route interest to FeeIndex via treasury split
   - Verify solvency after interest deduction
   - Transfer borrowed funds
   - Set expiry: `block.timestamp + durationSecs`

2. **Repay**: `repayFixedFromPosition(tokenId, poolId, loanId, amount)`
   - Transfer principal payment (no interest - already paid)
   - Reduce `principalRemaining`
   - Close loan if fully repaid
   - Charge ACTION_REPAY fee

**Storage**:
```solidity
struct FixedTermLoan {
    uint256 principal;
    uint256 principalRemaining;
    uint256 fullInterest;           // Already paid upfront
    uint256 principalAtOpen;        // Penalty calculation basis
    uint40 openedAt;
    uint40 expiry;
    uint16 apyBps;
    address borrower;               // Position key
    bool closed;
    bool interestRealized;          // Always true
}
```

### 4.6 Penalty-Based Settlement (No Liquidations)

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

### 4.7 Equalis Direct - Term Loans (P2P Lending)

**Overview**: Bilateral term lending between Position NFT holders with upfront fee realization, optional early exercise, and configurable prepayment policies. Both lenders and borrowers can post offers.

**Key Features**:
- Both lender and borrower must be Position NFT holders
- **True cross-asset lending**: Any asset can be lent against any collateral asset
- **Oracle-free cross-asset pricing**: Lenders set their own terms and collateral ratios
- **Borrower Offers**: Borrowers can post offers specifying their desired terms, which lenders can accept
- **Ratio Tranche Offers**: CLOB-style offers with price ratios for variable-size fills (both lender and borrower)
- **Optional Early Exercise**: Lenders can allow borrowers to voluntarily forfeit collateral before maturity (American-style settlement)
- **Configurable Prepayment**: Lenders can control whether borrowers can repay before maturity
- **Auto-Exercise on Fill**: Offers can be configured to immediately exercise upon acceptance (useful for synthetic options)
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
    bool autoExerciseOnFill;        // If true, acceptance immediately exercises the agreement
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
    bool autoExerciseOnFill;
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
    bool autoExerciseOnFill;
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
    bool autoExerciseOnFill;
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
    bool autoExerciseOnFill;
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
   - If `autoExerciseOnFill = true`, requires `allowEarlyExercise = true`
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
   - If `autoExerciseOnFill = true`, immediately execute exercise

4. **Accept Borrower Offer**: `acceptBorrowerOffer(offerId, lenderPositionId)`
   - Verify lender owns Position NFT
   - Check lender has sufficient available principal
   - Verify borrower's collateral is still locked (from posting)
   - Calculate and collect fees (interest + platform fee)
   - Distribute fees to lender, FeeIndex, protocol, and Active Credit Index
   - Transfer principal from lender pool to borrower (minus fees)
   - Create agreement with status Active
   - If `autoExerciseOnFill = true`, immediately execute exercise

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
- Supports `autoExerciseOnFill` for synthetic options use cases

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
- Supports `autoExerciseOnFill` for synthetic options use cases

**Use Cases**:
- **Synthetic Options**: Borrowers can create put-like positions by posting offers with `autoExerciseOnFill = true`
- **CLOB-Style Trading**: Variable-size fills enable order book-like trading dynamics
- **Price Discovery**: Multiple counterparties can fill at the posted ratio

### 4.8 Equalis Direct - Rolling Loans (P2P Rolling Credit)

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

### 4.9 Direct Lending Configuration

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
```solidity
// Per position key and pool ID
directLockedPrincipal[positionKey][poolId]   // Collateral locked as borrower
directLentPrincipal[positionKey][poolId]     // Principal exposed as lender
directBorrowedPrincipal[positionKey][poolId] // Principal borrowed
directOfferEscrow[positionKey][poolId]       // Escrowed offers
directSameAssetDebt[positionKey][asset]      // Same-asset debt tracking
```

**Invariants**:
- `directLockedPrincipal + directOfferEscrow <= userPrincipal` (per position, per pool)
- `defaultFeeIndexBps + defaultProtocolBps + defaultActiveCreditIndexBps <= 10000`

### 4.10 Flash Loan System

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

### 4.11 EqualIndex (Multi-Asset Index Tokens)

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

**Immutable Configuration** (set at pool creation for unmanaged pools):
```solidity
struct ImmutablePoolConfig {
    // Interest rates
    uint16 rollingApyBps;           // Deposit-backed rolling APY
    uint16 rollingApyBpsExternal;   // External collateral rolling APY
    
    // LTV and collateralization
    uint16 depositorLTVBps;         // Max LTV for deposit-backed (e.g., 8000 = 80%)
    uint16 externalBorrowCRBps;     // External collateral ratio
    
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
    uint16 rollingApyBpsExternal;

    // LTV and collateralization (mutable)
    uint16 depositorLTVBps;
    uint16 externalBorrowCRBps;

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
    ImmutablePoolConfig immutableConfig;
    uint16 currentAumFeeBps;        // Within bounds
    bool deprecated;                // UI flag
    
    // Managed pool state
    bool isManagedPool;
    address manager;
    ManagedPoolConfig managedConfig;
    bool whitelistEnabled;
    mapping(address => bool) whitelist;  // Keyed by positionKey
    
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
    mapping(address => uint256) userPrincipal;
    mapping(address => uint256) userFeeIndex;
    mapping(address => uint256) userMaintenanceIndex;
    mapping(address => uint256) userAccruedYield;
    mapping(address => ActiveCreditState) userActiveCreditStateP2P;
    mapping(address => ActiveCreditState) userActiveCreditStateDebt;
    
    // Loan mappings
    mapping(address => RollingCreditLoan) rollingLoans;
    mapping(uint256 => FixedTermLoan) fixedTermLoans;
    mapping(address => uint256) activeFixedLoanCount;
    mapping(address => uint256) fixedTermPrincipalRemaining;
    mapping(address => uint256[]) userFixedLoanIds;
    mapping(address => mapping(uint256 => uint256)) loanIdToIndex;
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
function getPositionKey(uint256 tokenId) public view returns (address) {
    return address(uint160(uint256(keccak256(abi.encodePacked(address(this), tokenId)))));
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

**Total Debt Calculation**:
```solidity
function calculateTotalDebt(PoolData storage p, address positionKey, uint256 poolId) 
    internal view returns (uint256) 
{
    uint256 debt = 0;
    
    // Rolling loan debt
    if (p.rollingLoans[positionKey].active) {
        debt += p.rollingLoans[positionKey].principalRemaining;
    }
    
    // Fixed-term loan debt (cached)
    debt += p.fixedTermPrincipalRemaining[positionKey];
    
    // Direct lending exposure (treated as debt-like per pool)
    DirectStorage storage ds = LibDirectStorage.directStorage();
    debt += ds.directLentPrincipal[positionKey][poolId];
    
    return debt;
}
```

**Solvency Check**:
```solidity
function checkSolvency(
    PoolData storage p,
    address positionKey,
    uint256 newPrincipal,
    uint256 newDebt
) internal view returns (bool) {
    if (newDebt == 0) return true;
    
    DirectStorage storage ds = LibDirectStorage.directStorage();
    uint256 lockedDirect = ds.directLockedPrincipal[positionKey][poolId];
    
    if (newPrincipal < lockedDirect) return false;
    uint256 availableCollateral = newPrincipal - lockedDirect;
    
    uint256 maxDebt = (availableCollateral * p.immutableConfig.depositorLTVBps) / 10_000;
    return newDebt <= maxDebt;
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
4. `userPrincipal[user] >= sum(directLockedPrincipal + directOfferEscrow)` (per pool)

**Per-Position Invariants**:
1. `totalDebt <= (availableCollateral * depositorLTVBps) / 10000`
2. `rollingLoan.principalRemaining <= rollingLoan.principal`
3. `fixedLoan.principalRemaining <= fixedLoan.principal`
4. `activeFixedLoanCount == userFixedLoanIds.length`

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
5. **Direct Capacity**: `directLocked + directOfferEscrow <= userPrincipal`
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
- Verify Direct offers cancelled

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

3. **Deploy Position NFT**:
   ```solidity
   PositionNFT nft = new PositionNFT();
   nft.setMinter(address(diamond));
   nft.setDiamond(address(diamond));
   ```

4. **Deploy Direct Lending Facets**:
   - EqualisDirectOfferFacet
   - EqualisDirectAgreementFacet
   - EqualisDirectLifecycleFacet
   - EqualisDirectRollingOfferFacet
   - EqualisDirectRollingAgreementFacet
   - EqualisDirectRollingPaymentFacet
   - EqualisDirectRollingLifecycleFacet
   - EqualisDirectRollingViewFacet
   - EqualisDirectViewFacet

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

6. **Deploy Optional Facets**:
   - EqualIndexFacetV3
   - EqualIndexAdminFacetV3
   - EqualIndexActionsFacetV3
   - EqualIndexViewFacetV3

7. **Configure Protocol**:
   ```solidity
   AdminFacet(diamond).setTimelock(timelockAddress);
   AdminFacet(diamond).setTreasury(treasuryAddress);
   MaintenanceFacet(diamond).setFoundationReceiver(receiverAddress);
   ```

### 10.2 Operational Procedures

**Unmanaged Pool Creation**:
```solidity
ImmutablePoolConfig memory config = ImmutablePoolConfig({
    rollingApyBps: 1000,              // 10% APY
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
        FixedTermConfig(30 days, 800),
        FixedTermConfig(90 days, 1000),
        FixedTermConfig(180 days, 1200)
    ],
    // ... action fees
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
    rollingApyBps: 1000,
    rollingApyBpsExternal: 1200,
    depositorLTVBps: 8000,
    externalBorrowCRBps: 15000,
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
- **Position Key**: Deterministic address derived from NFT contract and token ID
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
- **Auto-Exercise on Fill**: Immediate exercise upon offer acceptance
- **Borrower Offer**: Direct lending offer posted by borrower specifying desired terms
- **Ratio Tranche Offer**: CLOB-style offer with price ratio for variable-size fills
- **Borrower Ratio Tranche Offer**: Borrower-posted ratio tranche offer with collateral cap

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

### A.3 References

- [EIP-2535: Diamond Standard](https://eips.ethereum.org/EIPS/eip-2535)
- [EIP-721: Non-Fungible Token Standard](https://eips.ethereum.org/EIPS/eip-721)
- [OpenZeppelin Contracts](https://docs.openzeppelin.com/contracts/)
- [Foundry Book](https://book.getfoundry.sh/)

---

**Document Version:** 6.0
