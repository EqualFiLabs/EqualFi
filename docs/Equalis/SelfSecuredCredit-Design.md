# Self-Secured Credit - Design Document

**Version:** 1.1 (Updated for centralized fee index and encumbrance systems)

---

## Table of Contents

1. [Overview](#overview)
2. [How It Works](#how-it-works)
3. [Architecture](#architecture)
4. [Position NFTs](#position-nfts)
5. [Pool System](#pool-system)
6. [Credit Operations](#credit-operations)
7. [Fee System](#fee-system)
8. [Penalty & Default Resolution](#penalty--default-resolution)
9. [Flash Loans](#flash-loans)
10. [Data Models](#data-models)
11. [View Functions](#view-functions)
12. [Integration Guide](#integration-guide)
13. [Worked Examples](#worked-examples)
14. [Error Reference](#error-reference)
15. [Events](#events)
16. [Security Considerations](#security-considerations)

---

## Overview

Self-Secured Credit is a deterministic lending system where users borrow against their own deposits in the same asset. There are no external oracles, no liquidation auctions, and no third-party liquidators. Positions resolve by rules, not by market forces.

### Key Characteristics

| Feature | Description |
|---------|-------------|
| **Same-Asset Collateral** | Borrow the same token you deposited |
| **0% Interest Rate** | No interest accrues on loans |
| **Deterministic LTV** | Fixed loan-to-value ratio set at pool creation |
| **No Oracle Dependency** | All calculations use on-chain state only |
| **No Liquidation Auctions** | Defaults resolve via penalty seizure, not market sales |
| **Fee Base Normalization** | Borrowing reduces fee accrual weight to prevent farming |
| **Position NFT Ownership** | All state tied to transferable ERC-721 tokens |

### System Participants

| Role | Description |
|------|-------------|
| **Depositor** | User who deposits assets into a pool via Position NFT |
| **Borrower** | Depositor who draws credit against their own deposits |
| **Enforcer** | Anyone who triggers penalty resolution on delinquent positions |
| **Pool Creator** | Governance or fee-paying user who initializes pools |
| **Flash Borrower** | Contract that borrows pool liquidity within a single transaction |

### Why Self-Secured Credit?

Traditional DeFi lending relies on:
- External price oracles (manipulation risk)
- Liquidation auctions (cascade risk)
- Third-party liquidators (MEV extraction)

Self-secured credit eliminates these dependencies:
- **No oracle** → No price manipulation attacks
- **No auction** → No liquidation cascades
- **No liquidator** → No MEV extraction on defaults

The tradeoff: you can only borrow what you already have. This creates a leverage primitive, not a capital efficiency primitive.

---

## How It Works

### The Core Model

1. **Deposit** assets into a pool via your Position NFT
2. **Borrow** up to LTV% of your deposit in the same asset
3. **Use** borrowed funds externally (yield strategies, hedging, etc.)
4. **Repay** principal to restore borrowing capacity
5. **Withdraw** remaining deposits after repayment

### Fee Base Normalization

When you borrow, your fee accrual weight is reduced:

```
feeBase = principal - sameAssetDebt
```

This prevents fee farming loops. If you deposit 100 and borrow 95, your fee base is 5, not 100.

### Solvency Check

Positions must maintain:

```
debt ≤ (principal × LTV) / 10,000
```

Where LTV is set per-pool in basis points (e.g., 9500 = 95%).

---

## Architecture

### Contract Structure

```
src/equallend/
├── PositionManagementFacet.sol   # Mint, deposit, withdraw, yield rolling
├── LendingFacet.sol              # Rolling and fixed-term loan operations
├── PenaltyFacet.sol              # Default resolution and penalty distribution
├── FlashLoanFacet.sol            # Flash loan operations
└── PoolManagementFacet.sol       # Pool creation and configuration

src/libraries/
├── LibFeeIndex.sol               # Centralized fee index accounting (1e18 scale)
├── LibActiveCreditIndex.sol      # Active credit rewards with 24h time gate
├── LibEncumbrance.sol            # Centralized encumbrance tracking
├── LibSolvencyChecks.sol         # Deterministic solvency validation
├── LibNetEquity.sol              # Fee base calculations
├── LibLoanHelpers.sol            # Loan state utilities
├── LibMaintenance.sol            # Maintenance fee processing
├── LibFeeTreasury.sol            # Treasury fee routing
└── Types.sol                     # Data structures

src/nft/
└── PositionNFT.sol               # ERC-721 position tokens

src/views/
├── PositionViewFacet.sol         # Position state queries
├── LiquidityViewFacet.sol        # Fee index and yield queries
└── LoanViewFacet.sol             # Loan state queries
```

### High-Level Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                   Self-Secured Credit System                     │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐           │
│  │   Position   │  │   Lending    │  │   Penalty    │           │
│  │  Management  │  │    Facet     │  │    Facet     │           │
│  │    Facet     │  │              │  │              │           │
│  └──────────────┘  └──────────────┘  └──────────────┘           │
│         │                 │                 │                   │
│         └─────────────────┼─────────────────┘                   │
│                           │                                     │
│                    ┌──────────────┐                             │
│                    │  Pool Mgmt   │                             │
│                    │    Facet     │                             │
│                    └──────────────┘                             │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│                      Per-Pool State                             │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐           │
│  │   Pool 1     │  │   Pool 2     │  │   Pool N     │           │
│  │   (USDC)     │  │   (WETH)     │  │   (DAI)      │           │
│  └──────────────┘  └──────────────┘  └──────────────┘           │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
         │                    │                    │
         ▼                    ▼                    ▼
   ┌──────────┐        ┌──────────┐        ┌──────────┐
   │ Position │        │ Protocol │        │ Foundation│
   │   NFTs   │        │ Treasury │        │ Receiver  │
   └──────────┘        └──────────┘        └──────────┘
```

---

## Position NFTs

### Overview

Every user interaction happens through a Position NFT (ERC-721). The NFT represents:
- Ownership of deposited principal
- Accrued yield from fee distributions
- Active loan obligations
- Pool membership

### Lifecycle

```solidity
// 1. Mint a position for a specific pool
uint256 tokenId = positionFacet.mintPosition(poolId);

// 2. Deposit assets
positionFacet.depositToPosition(tokenId, poolId, amount);

// 3. Borrow against deposits
lendingFacet.openRollingFromPosition(tokenId, poolId, borrowAmount);

// 4. Repay loans
lendingFacet.makePaymentFromPosition(tokenId, poolId, repayAmount);

// 5. Withdraw remaining principal
positionFacet.withdrawFromPosition(tokenId, poolId, withdrawAmount);
```

### Position Key

Internally, positions are tracked by a `bytes32` key derived from the NFT:

```solidity
bytes32 positionKey = keccak256(abi.encodePacked(nftContract, tokenId));
```

This key maps to all per-user state in pool storage.

### Transferability

Position NFTs are fully transferable. When transferred:
- All deposits, loans, and yield move with the NFT
- The new owner inherits all obligations
- No approval or settlement required

---

## Pool System

### Pool Configuration

Each pool is initialized with immutable parameters:

```solidity
struct PoolConfig {
    uint16 depositorLTVBps;         // Max LTV for borrowing (e.g., 9500 = 95%)
    uint16 maintenanceRateBps;      // Annual maintenance fee rate
    uint16 flashLoanFeeBps;         // Flash loan fee in basis points
    uint256 minDepositAmount;       // Minimum deposit threshold
    uint256 minLoanAmount;          // Minimum loan threshold
    uint256 minTopupAmount;         // Minimum credit expansion amount
    bool isCapped;                  // Whether deposit cap is enforced
    uint256 depositCap;             // Max principal per user
    uint256 maxUserCount;           // Maximum users (0 = unlimited)
    FixedTermConfig[] fixedTermConfigs;  // Fixed-term loan options
}
```

### Pool Creation

**Governance Path (Free):**
```solidity
poolFacet.initPool(poolId, underlying, config);
```

**Permissionless Path (Fee Required):**
```solidity
poolFacet.initPool{value: creationFee}(underlying);
```

### Managed Pools

Pool managers can create whitelist-gated pools with mutable parameters:

```solidity
poolFacet.initManagedPool{value: managedFee}(poolId, underlying, managedConfig);
```

Managed pools support:
- Whitelist-only access
- Adjustable LTV, fees, and thresholds
- Manager transfer and renunciation

---

## Credit Operations

### Rolling Credit

Rolling credit is an open-ended credit line with periodic payment requirements.

**Open a Rolling Loan:**
```solidity
lendingFacet.openRollingFromPosition(tokenId, poolId, amount);
```

**Requirements:**
- Position must have sufficient unencumbered principal
- Amount must meet minimum loan threshold
- Post-loan debt must satisfy LTV constraint

**Make a Payment:**
```solidity
lendingFacet.makePaymentFromPosition(tokenId, poolId, paymentAmount);
```

Payments reduce principal remaining. With 0% interest, the entire payment goes to principal.

**Expand Credit Line:**
```solidity
lendingFacet.expandRollingFromPosition(tokenId, poolId, additionalAmount);
```

Expansion is blocked if the position is delinquent (missed payments).

**Close Rolling Loan:**
```solidity
lendingFacet.closeRollingCreditFromPosition(tokenId, poolId);
```

Requires full repayment of principal remaining.

### Fixed-Term Loans

Fixed-term loans have a defined expiry date.

**Open a Fixed-Term Loan:**
```solidity
uint256 loanId = lendingFacet.openFixedFromPosition(tokenId, poolId, amount, termIndex);
```

The `termIndex` selects from pre-configured term options (e.g., 30 days, 90 days).

**Repay a Fixed-Term Loan:**
```solidity
lendingFacet.repayFixedFromPosition(tokenId, poolId, loanId, amount);
```

Partial repayments are allowed. The loan closes when principal remaining reaches zero.

### Delinquency States

**Rolling Loans:**
- Payment interval: 30 days
- Delinquent: 2+ missed payments (blocks expansion)
- Penalty eligible: 3+ missed payments

**Fixed-Term Loans:**
- Penalty eligible: After expiry timestamp

---

## Fee System

### Centralized Fee Index (LibFeeIndex)

Pool fees are distributed to depositors via a centralized fee index managed by `LibFeeIndex.sol`:

```solidity
// Accrual (in LibFeeIndex.sol)
function accrueWithSource(uint256 pid, uint256 amount, bytes32 source) internal {
    // Scale amount and add to pool's fee index
    uint256 scaledAmount = Math.mulDiv(amount, INDEX_SCALE, 1);
    uint256 dividend = scaledAmount + p.feeIndexRemainder;
    uint256 delta = dividend / totalDeposits;
    p.feeIndex += delta;
    p.feeIndexRemainder = dividend - (delta * totalDeposits);
    p.yieldReserve += amount;
}
```

Each position tracks its checkpoint:

```solidity
// Settlement (in LibFeeIndex.sol)
function settle(uint256 pid, bytes32 user) internal {
    uint256 delta = p.feeIndex - p.userFeeIndex[user];
    uint256 feeBase = LibNetEquity.calculateFeeBaseSameAsset(principal, sameAssetDebt);
    uint256 added = Math.mulDiv(feeBase, delta, INDEX_SCALE);
    p.userAccruedYield[user] += added;
    p.userFeeIndex[user] = p.feeIndex;
}
```

### Fee Base Normalization

To prevent fee farming via borrow loops:

```solidity
// In LibNetEquity.sol
feeBase = principal - sameAssetDebt
```

If you deposit 100 and borrow 80, your fee base is 20. You only earn fees on your net equity.

### Maintenance Fees

Pools charge an annual maintenance fee that reduces principal over time. Maintenance is processed via `LibMaintenance.sol`:

```solidity
// Maintenance index accrual
maintenanceIndex += (rateBps × elapsed × SCALE) / (365 days × 10,000)

// Applied during settlement in LibFeeIndex.settle()
maintenanceFee = principal × (maintenanceIndex - userMaintenanceIndex) / SCALE
principal -= maintenanceFee  // Reduces principal before yield calculation
```

### Active Credit Index (LibActiveCreditIndex)

Borrowers and active credit participants earn from a parallel index managed by `LibActiveCreditIndex.sol`:

```solidity
// Accrual uses matured principal base
function accrueWithSource(uint256 pid, uint256 amount, bytes32 source) internal {
    uint256 activeBase = p.activeCreditMaturedTotal;
    if (activeBase == 0) return;
    
    uint256 delta = (amount × INDEX_SCALE) / activeBase;
    p.activeCreditIndex += delta;
}
```

**Time Gate (24 hours):** Positions must be active for 24 hours before earning from this index. The system uses hourly bucket scheduling for efficient maturity tracking:

```solidity
// Constants
uint256 public constant TIME_GATE = 24 hours;
uint256 internal constant BUCKET_SIZE = 1 hours;
uint8 internal constant BUCKET_COUNT = 24;

// Only mature positions earn rewards
activeWeight = timeCredit >= 24 hours ? principal : 0
```

**Weighted Dilution:** Prevents dust-priming attacks where users start the timer on small amounts then add large amounts:

```solidity
// When adding new principal (P_new) to existing principal (P_old):
newTimeCredit = (P_old * oldTimeCredit + P_new * 0) / (P_old + P_new)
newStartTime = currentTime - newTimeCredit
```

### Fee Sources

| Source | Distribution |
|--------|--------------|
| Flash loan fees | Fee index via `LibFeeIndex.accrueWithSource()` |
| Penalty seizures | 70% fee index, 20% active credit, 10% protocol |
| Action fees | Protocol treasury via `LibFeeTreasury` |

---

## Penalty & Default Resolution

### How Defaults Work

When a position becomes penalty-eligible:
1. Anyone can call `penalizePosition`
2. Collateral is seized to cover debt + penalty
3. Penalty is distributed to ecosystem participants
4. Position's loan is closed

### Penalty Calculation

```solidity
penalty = principalAtOpen × penaltyBps / 10,000
totalSeized = principalRemaining + min(penalty, principalRemaining)
```

The penalty is capped at the remaining principal to prevent over-seizure.

### Penalty Distribution

| Recipient | Share | Purpose |
|-----------|-------|---------|
| Enforcer | 10% | Incentive to trigger resolution |
| Fee Index | 63% | Distributed to depositors |
| Protocol | 9% | Protocol revenue |
| Active Credit | 18% | Distributed to active borrowers |

### Rolling Loan Penalty

```solidity
penaltyFacet.penalizePositionRolling(tokenId, poolId, enforcerAddress);
```

**Requirements:**
- Loan must be active
- 3+ missed payment epochs

### Fixed-Term Loan Penalty

```solidity
penaltyFacet.penalizePositionFixed(tokenId, poolId, loanId, enforcerAddress);
```

**Requirements:**
- Loan must not be closed
- Current timestamp ≥ loan expiry

### Why This Design?

**No Bad Debt:** Since collateral and debt are the same asset, seizure always covers the debt. There's no price risk.

**No Cascades:** Defaults don't force market sales. The seized collateral stays in the pool, benefiting remaining depositors.

**Contained Losses:** Defaulters lose their equity wedge. Non-defaulters gain from penalty distributions.

---

## Flash Loans

### Overview

Flash loans allow borrowing pool liquidity within a single transaction, provided the loan plus fee is repaid before the transaction ends.

### Usage

```solidity
flashLoanFacet.flashLoan(poolId, receiverContract, amount, data);
```

The receiver must implement:

```solidity
interface IFlashLoanReceiver {
    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        bytes calldata data
    ) external returns (bytes32);
}
```

Return `keccak256("IFlashLoanReceiver.onFlashLoan")` on success.

### Fee Calculation

```
fee = amount × flashLoanFeeBps / 10,000
```

Fees are distributed to depositors via the fee index.

### Anti-Split Protection

Pools can enable anti-split protection to prevent fee arbitrage via multiple small loans in the same block.

---

## Data Models

### Pool Data

```solidity
struct PoolData {
    // Core identity
    address underlying;                              // ERC20 token
    PoolConfig poolConfig;                           // Immutable parameters
    
    // Fee index state (managed by LibFeeIndex)
    uint256 feeIndex;                                // Global fee index (1e18 scale)
    uint256 feeIndexRemainder;                       // Per-pool remainder for precision
    uint256 yieldReserve;                            // Backing reserve for accrued yield
    
    // Maintenance state (managed by LibMaintenance)
    uint256 maintenanceIndex;                        // Cumulative maintenance fee index
    uint64 lastMaintenanceTimestamp;                 // Last maintenance accrual time
    uint256 maintenanceIndexRemainder;               // Per-pool remainder for precision
    
    // Active credit state (managed by LibActiveCreditIndex)
    uint256 activeCreditIndex;                       // Active credit index
    uint256 activeCreditIndexRemainder;              // Remainder for precision
    uint256 activeCreditPrincipalTotal;              // Sum of active credit principal
    uint256 activeCreditMaturedTotal;                // Matured principal base for accruals
    uint64 activeCreditPendingStartHour;             // Start hour for bucket ring
    uint8 activeCreditPendingCursor;                 // Current bucket cursor
    uint256[24] activeCreditPendingBuckets;          // Pending principal by maturity hour
    
    // Pool totals
    uint256 totalDeposits;                           // Sum of all principal
    uint256 trackedBalance;                          // Actual token balance
    uint256 userCount;                               // Total users with deposits
    
    // Per-user ledger
    mapping(bytes32 => uint256) userPrincipal;       // Per-position principal
    mapping(bytes32 => uint256) userFeeIndex;        // Per-position fee checkpoint
    mapping(bytes32 => uint256) userMaintenanceIndex;// Per-position maintenance checkpoint
    mapping(bytes32 => uint256) userAccruedYield;    // Settled yield
    
    // Loan state
    mapping(bytes32 => RollingCreditLoan) rollingLoans;
    mapping(uint256 => FixedTermLoan) fixedTermLoans;
    
    // Active credit per-user state
    mapping(bytes32 => ActiveCreditState) userActiveCreditStateP2P;
    mapping(bytes32 => ActiveCreditState) userActiveCreditStateDebt;
}

struct ActiveCreditState {
    uint256 principal;      // Current exposure amount
    uint40 startTime;       // Weighted dilution timestamp
    uint256 indexSnapshot;  // Last settled activeCreditIndex value
}
```

### Centralized Encumbrance (LibEncumbrance)

Position encumbrance is tracked centrally via `LibEncumbrance.sol`:

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

// Access pattern
LibEncumbrance.position(positionKey, poolId).directLocked
LibEncumbrance.total(positionKey, poolId)  // Sum of all encumbrance types
```

### Rolling Credit Loan

```solidity
struct RollingCreditLoan {
    uint256 principal;              // Original loan amount
    uint256 principalRemaining;     // Outstanding balance
    uint40 openedAt;                // Loan creation timestamp
    uint40 lastPaymentTimestamp;    // Last payment time
    uint16 apyBps;                  // Interest rate (0 for self-secured)
    uint8 missedPayments;           // Tracked missed epochs
    uint32 paymentIntervalSecs;     // Payment period (30 days)
    bool depositBacked;             // Always true for self-secured
    bool active;                    // Loan status
    uint256 principalAtOpen;        // Snapshot for penalty calculation
}
```

### Fixed-Term Loan

```solidity
struct FixedTermLoan {
    uint256 principal;              // Original loan amount
    uint256 principalRemaining;     // Outstanding balance
    uint40 openedAt;                // Loan creation timestamp
    uint40 expiry;                  // Maturity timestamp
    uint16 apyBps;                  // Interest rate (0 for self-secured)
    bytes32 borrower;               // Position key
    bool closed;                    // Loan status
    uint256 principalAtOpen;        // Snapshot for penalty calculation
}
```

### Position State

```solidity
struct PositionState {
    uint256 tokenId;
    uint256 poolId;
    address underlying;
    uint256 principal;
    uint256 accruedYield;
    uint256 feeIndexCheckpoint;
    uint256 maintenanceIndexCheckpoint;
    RollingCreditLoan rollingLoan;
    uint256[] fixedLoanIds;
    uint256 totalDebt;
    uint256 solvencyRatio;          // (principal × 10000) / totalDebt
    bool isDelinquent;
    bool eligibleForPenalty;
}

struct PositionEncumbrance {
    uint256 directLocked;           // From LibEncumbrance
    uint256 directLent;             // From LibEncumbrance
    uint256 directOfferEscrow;      // From LibEncumbrance
    uint256 indexEncumbered;        // From LibEncumbrance
    uint256 totalEncumbered;        // Sum of all types
}
```

---

## View Functions

### Position Queries

```solidity
// Get complete position state
function getPositionState(uint256 tokenId, uint256 poolId) 
    external view returns (PositionState memory);

// Get solvency information
function getPositionSolvency(uint256 tokenId, uint256 poolId)
    external view returns (uint256 principal, uint256 debt, uint256 ratio);

// Get loan summary
function getPositionLoanSummary(uint256 tokenId, uint256 poolId)
    external view returns (
        uint256 totalLoans,
        uint256 activeLoans,
        uint256 totalDebt,
        uint256 nextExpiryTimestamp,
        bool hasDelinquentLoans
    );

// Check delinquency status
function isPositionDelinquent(uint256 tokenId, uint256 poolId) 
    external view returns (bool);
```

### Loan Queries

```solidity
// Get rolling loan details
function getRollingLoan(uint256 poolId, bytes32 borrower) 
    external view returns (RollingCreditLoan memory);

// Get fixed-term loan details
function getFixedLoan(uint256 poolId, uint256 loanId) 
    external view returns (FixedTermLoan memory);

// Preview max borrowable amount
function previewBorrowRolling(uint256 poolId, bytes32 borrower) 
    external view returns (uint256 maxBorrow);
```

---

## Integration Guide

### For Developers

#### Depositing and Borrowing

```solidity
// 1. Mint position with initial deposit
uint256 tokenId = positionFacet.mintPositionWithDeposit(poolId, depositAmount);

// 2. Open rolling credit line
lendingFacet.openRollingFromPosition(tokenId, poolId, borrowAmount);

// 3. Use borrowed funds externally...

// 4. Repay when ready
IERC20(underlying).approve(diamond, repayAmount);
lendingFacet.makePaymentFromPosition(tokenId, poolId, repayAmount);

// 5. Withdraw remaining principal
positionFacet.withdrawFromPosition(tokenId, poolId, withdrawAmount);
```

#### Yield Management

```solidity
// Check pending yield (uses LibFeeIndex)
uint256 pending = LibFeeIndex.pendingYield(poolId, positionKey);

// Roll yield into principal (increases borrowing capacity)
positionFacet.rollYieldToPosition(tokenId, poolId);

// Or withdraw yield with principal
positionFacet.withdrawFromPosition(tokenId, poolId, amount);
// Yield is withdrawn proportionally with principal
```

#### Monitoring Positions

```solidity
// Check if position is at risk
(uint256 principal, uint256 debt, uint256 ratio) = 
    viewFacet.getPositionSolvency(tokenId, poolId);

// Check delinquency
bool delinquent = viewFacet.isPositionDelinquent(tokenId, poolId);

// Get full state
PositionState memory state = viewFacet.getPositionState(tokenId, poolId);

// Get encumbrance breakdown (via LibEncumbrance)
PositionEncumbrance memory enc = viewFacet.getPositionEncumbrance(tokenId, poolId);
```

### For Users

#### Opening a Leveraged Position

1. **Deposit** assets into a pool
2. **Borrow** up to LTV% of your deposit
3. **Deploy** borrowed funds (yield farming, hedging, etc.)
4. **Monitor** your position for payment deadlines
5. **Repay** before becoming delinquent

#### Managing Risk

- Keep debt well below max LTV to avoid delinquency
- Make payments before the 30-day interval expires
- Monitor `isPositionDelinquent` status
- Maintain buffer for fee deductions

#### Closing a Position

1. Repay all outstanding loans
2. Withdraw principal and accrued yield
3. Position NFT remains (can be reused or transferred)

---

## Worked Examples

### Example 1: Basic Deposit and Borrow

**Scenario:** Alice deposits 1000 USDC and borrows 900 USDC at 95% LTV.

**Step 1: Deposit**
```
Alice deposits: 1000 USDC
Principal: 1000 USDC
Fee base: 1000 USDC (no debt yet)
```

**Step 2: Borrow**
```
Max borrowable: 1000 × 95% = 950 USDC
Alice borrows: 900 USDC
Principal: 1000 USDC
Debt: 900 USDC
Fee base: 1000 - 900 = 100 USDC
Solvency ratio: (1000 × 10000) / 900 = 11,111 bps ✓
```

**Step 3: Fee Accrual**
```
Pool earns 10 USDC in flash fees
Fee index increases by: 10 × 1e18 / totalDeposits
Alice's yield: (indexDelta × 100) / 1e18
// Alice only earns on her 100 USDC fee base, not 1000
```

### Example 2: Leverage Loop with Index Tokens

**Scenario:** Bob wants 5x leverage on LST exposure using self-secured credit.

**Setup:**
- iLST-A: Index token backed by stETH, rETH (Pool A)
- iLST-B: Index token backed by stETH, rETH (Pool B, same composition)

**Loop Execution:**

| Step | Action | iLST-A | iLST-B | Net Exposure |
|------|--------|--------|--------|--------------|
| 1 | Mint 100 iLST-A | 100 | 0 | 100 |
| 2 | Deposit iLST-A, borrow 95 | 5 | 0 | 100 |
| 3 | Burn 95 iLST-A → LSTs | 5 | 0 | 100 |
| 4 | Mint 95 iLST-B | 5 | 95 | 195 |
| 5 | Deposit iLST-B, borrow 90 | 5 | 5 | 195 |
| 6 | Burn 90 iLST-B → LSTs | 5 | 5 | 195 |
| 7 | Continue... | ... | ... | ~500 |

**Why Two Index Tokens?**

Fee base normalization: `feeBase = principal - sameAssetDebt`

If Bob used only iLST-A:
- Pool A principal: 100
- Pool A debt: 95
- Pool A fee base: 5 (earns almost nothing)

With iLST-A and iLST-B:
- Pool A: principal 100, debt 95, fee base 5
- Pool B: principal 95, debt 90, fee base 5
- Total fee base: 10 (across both pools)

Each pool's fee base is calculated independently.

### Example 3: Default and Penalty Resolution

**Scenario:** Carol has a rolling loan and misses 3 payment epochs.

**Initial State:**
```
Principal: 1000 USDC
Debt: 800 USDC
Principal at open: 800 USDC
Missed payments: 3 (penalty eligible)
```

**Penalty Calculation:**
```
Penalty rate: 10% (example)
Penalty amount: 800 × 10% = 80 USDC
Total seized: 800 (debt) + 80 (penalty) = 880 USDC
```

**Distribution:**
```
Enforcer (10%): 8 USDC
Fee index (63%): 50.4 USDC
Protocol (9%): 7.2 USDC
Active credit (18%): 14.4 USDC
```

**Final State:**
```
Carol's principal: 1000 - 880 = 120 USDC
Carol's debt: 0 USDC
Loan status: closed
```

Carol lost 880 USDC but retains 120 USDC in her position.

### Example 4: Fixed-Term Loan Lifecycle

**Scenario:** Dave opens a 30-day fixed-term loan.

**Day 0: Open Loan**
```
Deposit: 500 USDC
Borrow: 400 USDC (80% of deposit)
Term: 30 days
Expiry: Day 30
```

**Day 15: Partial Repayment**
```
Repay: 200 USDC
Principal remaining: 200 USDC
```

**Day 30: Full Repayment**
```
Repay: 200 USDC
Principal remaining: 0 USDC
Loan status: closed
```

**Alternative: Day 31 (Missed Expiry)**
```
Anyone can call penalizePositionFixed()
Penalty applied, collateral seized
```

---

## Error Reference

### Position Errors

| Error | Cause |
|-------|-------|
| `NotNFTOwner()` | Caller doesn't own the Position NFT |
| `PoolNotInitialized(uint256)` | Pool ID doesn't exist |
| `InsufficientPrincipal(uint256, uint256)` | Not enough unencumbered principal |
| `DepositBelowMinimum(uint256, uint256)` | Deposit below pool minimum |
| `DepositCapExceeded(uint256, uint256)` | Deposit exceeds per-user cap |

### Loan Errors

| Error | Cause |
|-------|-------|
| `LoanBelowMinimum(uint256, uint256)` | Loan amount below pool minimum |
| `SolvencyViolation(uint256, uint256, uint16)` | LTV constraint violated |
| `ActiveLoansExist()` | Cannot withdraw with active loans |
| `RollingError_MinPayment(uint256, uint256)` | Payment below minimum required |

### Pool Errors

| Error | Cause |
|-------|-------|
| `PoolAlreadyExists(uint256)` | Pool ID already initialized |
| `InvalidLTVRatio()` | LTV outside valid range |
| `InvalidMinimumThreshold(string)` | Zero minimum threshold |
| `TreasuryNotSet()` | Protocol treasury not configured |

---

## Events

### Position Events

```solidity
event PositionMinted(uint256 indexed tokenId, address indexed owner, uint256 indexed poolId);

event DepositedToPosition(
    uint256 indexed tokenId,
    address indexed owner,
    uint256 indexed poolId,
    uint256 amount,
    uint256 newPrincipal
);

event WithdrawnFromPosition(
    uint256 indexed tokenId,
    address indexed owner,
    uint256 indexed poolId,
    uint256 principalWithdrawn,
    uint256 yieldWithdrawn,
    uint256 remainingPrincipal
);

event YieldRolledToPosition(
    uint256 indexed tokenId,
    address indexed owner,
    uint256 indexed poolId,
    uint256 yieldAmount,
    uint256 newPrincipal
);
```

### Loan Events

```solidity
event RollingLoanOpenedFromPosition(
    uint256 indexed tokenId,
    address indexed owner,
    uint256 indexed poolId,
    uint256 principal,
    bool depositBacked
);

event PaymentMadeFromPosition(
    uint256 indexed tokenId,
    address indexed owner,
    uint256 indexed poolId,
    uint256 paymentAmount,
    uint256 principalPaid,
    uint256 interestPaid,
    uint256 remainingPrincipal
);

event RollingLoanExpandedFromPosition(
    uint256 indexed tokenId,
    address indexed owner,
    uint256 indexed poolId,
    uint256 expandedAmount,
    uint256 newPrincipalRemaining
);

event RollingLoanClosedFromPosition(
    uint256 indexed tokenId,
    address indexed owner,
    uint256 indexed poolId,
    uint256 collateralReleased
);

event FixedLoanOpenedFromPosition(
    uint256 indexed tokenId,
    address indexed owner,
    uint256 indexed poolId,
    uint256 loanId,
    uint256 principal,
    uint256 fullInterest,
    uint40 expiry,
    uint16 apyBps,
    bool interestRealizedAtInitiation
);

event FixedLoanRepaidFromPosition(
    uint256 indexed tokenId,
    address indexed owner,
    uint256 indexed poolId,
    uint256 loanId,
    uint256 principalPaid,
    uint256 remainingPrincipal
);
```

### Penalty Events

```solidity
event RollingLoanPenalized(
    uint256 indexed tokenId,
    address indexed enforcer,
    uint256 indexed poolId,
    uint256 enforcerShare,
    uint256 protocolShare,
    uint256 feeIndexShare,
    uint256 activeCreditShare,
    uint256 penaltyApplied,
    uint256 principalAtOpen
);

event TermLoanDefaulted(
    uint256 indexed tokenId,
    address indexed enforcer,
    uint256 indexed poolId,
    uint256 loanId,
    uint256 penaltyApplied,
    uint256 principalAtOpen
);
```

### Fee Events

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

event FlashLoan(
    uint256 indexed pid,
    address indexed receiver,
    uint256 amount,
    uint256 fee,
    uint16 feeBps
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

---

## Security Considerations

### 1. Deterministic Solvency

All solvency checks use only on-chain state via `LibSolvencyChecks.sol`:
- No external oracles
- No price feeds
- No off-chain data

```solidity
// In LibSolvencyChecks.calculateAvailablePrincipal()
uint256 totalEncumbered = LibEncumbrance.total(positionKey, poolId);
available = principal > totalEncumbered ? principal - totalEncumbered : 0;

// Solvency check
isSolvent = debt <= (principal × LTV) / 10,000
```

### 2. Fee Base Normalization

Prevents fee farming via borrow loops (in `LibNetEquity.sol`):
```solidity
feeBase = principal - sameAssetDebt
```

Borrowing reduces your fee accrual weight proportionally.

### 3. Reentrancy Protection

All state-changing functions use `nonReentrant` modifier.

### 4. Access Control

| Function | Access |
|----------|--------|
| Pool creation | Governance (free) or public (with fee) |
| Position operations | NFT owner only |
| Penalty enforcement | Anyone (when eligible) |
| Flash loans | Anyone |

### 5. Same-Asset Guarantee

Since collateral and debt are the same asset:
- No price risk on collateral
- No bad debt possible
- Seizure always covers debt

### 6. Time-Gated Rewards (LibActiveCreditIndex)

Active credit index requires 24-hour maturity with bucket-based scheduling:
- Prevents dust-priming attacks
- Weighted dilution on principal increases
- Hourly bucket ring for efficient maturity tracking

```solidity
// Only mature positions earn rewards
if (timeCredit(state) < TIME_GATE) return 0;
```

### 7. Isolated Pool Balances

Each pool tracks its own `trackedBalance`:
- Prevents cross-pool balance spoofing
- Flash loan repayments verified per-pool

### 8. Centralized Encumbrance Tracking (LibEncumbrance)

All position encumbrance is tracked centrally:
- Unified view of all lock types (direct, lent, escrow, index)
- Consistent solvency calculations across all features
- Events emitted for all encumbrance changes

```solidity
// Total encumbrance check
uint256 total = LibEncumbrance.total(positionKey, poolId);
require(total <= principal, "Insufficient principal");
```

### 9. Minimum Thresholds

Pools enforce minimums to prevent dust attacks:
- `minDepositAmount`: Minimum deposit size
- `minLoanAmount`: Minimum loan size
- `minTopupAmount`: Minimum credit expansion

### 10. Payment Interval Enforcement

Rolling loans track missed payments deterministically:
```solidity
missedEpochs = (now - lastPayment) / paymentInterval
```

No reliance on external triggers or keepers.

---

## Appendix: Correctness Properties

### Property 1: Solvency Invariant
For any position with active loans:
```
debt ≤ (principal × LTV) / 10,000
```

### Property 2: Fee Base Consistency
For any position:
```
feeBase = principal - sameAssetDebt
feeBase ≥ 0
```

### Property 3: No Bad Debt
Since collateral = debt asset:
```
seizure = debt + penalty
seizure ≤ principal (always satisfiable)
```

### Property 4: Index Monotonicity
Fee index and active credit index only increase:
```
newIndex ≥ oldIndex
```

### Property 5: Balance Conservation
For any pool:
```
trackedBalance = Σ(userPrincipal) + Σ(accruedYield) - Σ(debt)
```

### Property 6: Penalty Distribution
For any penalty:
```
enforcerShare + feeIndexShare + protocolShare + activeCreditShare = penaltyAmount
```

### Property 7: Time Gate Enforcement
Active credit yield only accrues after 24 hours (via `LibActiveCreditIndex`):
```
if (elapsed < 24 hours) activeWeight = 0
```

### Property 8: Delinquency Determinism
Delinquency status is fully deterministic from on-chain state:
```
isDelinquent = missedPayments ≥ delinquentThreshold
            || (isFixed && now ≥ expiry)
```

### Property 9: Encumbrance Consistency
Total encumbrance never exceeds principal (via `LibEncumbrance`):
```
LibEncumbrance.total(positionKey, poolId) ≤ userPrincipal[positionKey]
```

---

**Document Version:** 1.1 (Updated for centralized fee index and encumbrance systems)
