# AUM Fee System - Design Document

**Version:** 1.0

---

## Table of Contents

1. [Overview](#overview)
2. [How It Works](#how-it-works)
3. [Architecture](#architecture)
4. [Pool-Level AUM Configuration](#pool-level-aum-configuration)
5. [Module Encumbrance AUM](#module-encumbrance-aum)
6. [Fee Routing and Distribution](#fee-routing-and-distribution)
7. [Delinquency and Permanent Deactivation](#delinquency-and-permanent-deactivation)
8. [Active Credit Integration](#active-credit-integration)
9. [Managed Pool System Share](#managed-pool-system-share)
10. [Data Models](#data-models)
11. [View Functions](#view-functions)
12. [Integration Guide](#integration-guide)
13. [Worked Examples](#worked-examples)
14. [Error Reference](#error-reference)
15. [Events](#events)
16. [Security Considerations](#security-considerations)

---

## Overview

The AUM (Assets Under Management) fee system is the protocol's mechanism for charging ongoing fees on capital held or reserved within Equalis pools. It operates at two distinct layers:

1. **Pool-Level AUM** — A governance-configurable annual fee rate on pool deposits, bounded by immutable min/max parameters set at pool creation.
2. **Module Encumbrance AUM** — A per-tuple daily-epoch fee charged on principal reserved by external modules, with built-in delinquency detection and permanent deactivation.

Both layers feed into the same centralized fee routing infrastructure (`LibFeeRouter`), which splits charged amounts across three destinations: the fee index (depositor yield), the active credit index (participant yield), and the protocol treasury.

### Key Characteristics

| Feature | Description |
|---------|-------------|
| **Dual-Layer Design** | Pool-level configuration and module-level accrual operate independently |
| **Immutable Bounds** | Pool AUM fee rates are bounded by min/max set at pool creation |
| **Epoch-Based Accrual** | Module AUM accrues in whole-day epochs; no partial-day charges |
| **Three-Way Split** | Charged fees are routed to fee index, active credit index, and treasury |
| **Self-Policing Modules** | Modules that cannot sustain AUM payments are permanently deactivated |
| **Permissionless Poking** | Anyone can trigger module AUM accrual without mutating encumbrance |
| **Managed Pool Awareness** | Managed pools route a configurable system share through the base permissionless pool |

### System Participants

| Role | Description |
|------|-------------|
| **Depositor** | Pool participant who earns yield from AUM fees via the fee index |
| **Active Credit Participant** | Borrower or encumbrer who earns yield via the active credit index |
| **Module Owner** | Address that registered a module; pays AUM fees on encumbered principal |
| **Position Owner** | NFT holder whose principal backs module encumbrance |
| **Governance** | Diamond owner or timelock; configures pool AUM rates and global split parameters |
| **Keeper (Poker)** | Anyone who calls `pokeModuleAum` to trigger accrual |
| **Foundation Receiver** | Recipient of maintenance fees (separate from AUM; see [Maintenance vs AUM](#maintenance-vs-aum)) |

### Why AUM Fees?

AUM fees create a continuous yield stream for pool participants from capital that is held or reserved within the protocol:

- **Depositors** earn passive yield proportional to their fee base (principal minus same-asset debt)
- **Active credit participants** earn yield proportional to their matured active credit weight
- **The protocol** collects treasury revenue for sustainability
- **Modules** pay rent on reserved principal, ensuring capital is not locked without compensation

Without AUM fees, modules could reserve position principal indefinitely at zero cost, creating a free-rider problem where capital is locked but generates no return for the depositor or the protocol.

---

## How It Works

### Pool-Level AUM

Pool-level AUM is a governance-configurable annual fee rate that applies to pool deposits:

1. **At pool creation**, immutable bounds (`aumFeeMinBps`, `aumFeeMaxBps`) are set in the pool config
2. **`currentAumFeeBps`** is initialized to the minimum bound
3. **Governance** can adjust `currentAumFeeBps` within bounds via `setAumFee(pid, feeBps)`
4. The rate is exposed via view functions for off-chain consumption and integration

Pool-level AUM configuration provides the governance knob for adjusting the cost of capital across pools. The bounds are immutable to give depositors certainty about the fee range they are exposed to.

### Module Encumbrance AUM

Module AUM is the active accrual mechanism that charges fees on principal reserved by external modules:

1. **Register** a module via governance (free) or public registration (fee required)
2. **Encumber** position principal against the module for a specific pool
3. **AUM accrues** daily in whole-day epochs, charging fees from the encumbered position's principal
4. **Fees are routed** through `LibFeeRouter` to fee index, active credit index, and treasury
5. **Unencumber** to release reserved principal back to available balance
6. **Poke** to trigger AUM accrual without changing encumbrance (permissionless)

### Maintenance vs AUM

Maintenance fees and AUM fees are distinct systems:

| Aspect | Maintenance Fee | AUM Fee (Module) |
|--------|----------------|------------------|
| **Scope** | Entire pool TVL | Per-tuple module encumbrance |
| **Recipient** | Foundation receiver (100%) | Fee index + active credit + treasury (split) |
| **Mechanism** | Maintenance index reduces principal proportionally | Direct principal charge with fee routing |
| **Accrual** | Daily epochs on pool interactions | Daily epochs on encumber/unencumber/poke |
| **Configuration** | `maintenanceRateBps` per pool | `aumBps` per module (or `defaultModuleAumBps`) |

Both systems use daily epoch granularity and are triggered on pool interactions, but they serve different purposes and route fees to different destinations.

---

## Architecture

### Contract Structure

```
src/admin/
└── AdminGovernanceFacet.sol       # setAumFee(), pool config updates

src/equallend/
└── PoolManagementFacet.sol        # Pool creation with AUM bounds

src/modules/
├── ModuleRegistryFacet.sol        # Module registration, AUM bps configuration
├── ModuleGatewayFacet.sol         # Encumber/unencumber with AUM accrual, poke
└── ModuleViewFacet.sol            # AUM state queries

src/views/
└── ConfigViewFacet.sol            # getAumFeeInfo(), getPoolInfo()

src/libraries/
├── LibModuleAum.sol               # Epoch accrual, principal charging, delinquency
├── LibModuleRegistry.sol          # Module config storage, tuple AUM state
├── LibModuleEncumbrance.sol       # Module encumbrance wrapper
├── LibFeeRouter.sol               # Central fee split: treasury + ACI + fee index
├── LibFeeTreasury.sol             # Convenience wrapper delegating to LibFeeRouter
├── LibFeeIndex.sol                # Pool fee index accrual for depositors
├── LibActiveCreditIndex.sol       # Active credit rewards with 24h time gate
├── LibEncumbrance.sol             # Unified encumbrance storage
├── LibSolvencyChecks.sol          # Available principal calculation
├── LibMaintenance.sol             # Maintenance fee accrual (separate system)
└── LibNetEquity.sol               # Fee base calculations
```

### High-Level Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│                        AUM Fee System                               │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  ┌─────────────────────┐        ┌─────────────────────┐             │
│  │   Pool-Level AUM    │        │  Module-Level AUM   │             │
│  │   Configuration     │        │     Accrual         │             │
│  ├─────────────────────┤        ├─────────────────────┤             │
│  │ aumFeeMinBps (imm)  │        │ LibModuleAum        │             │
│  │ aumFeeMaxBps (imm)  │        │ Daily epoch accrual │             │
│  │ currentAumFeeBps    │        │ Per-tuple state     │             │
│  │ (governance-mutable)│        │ Delinquency tracking│             │
│  └─────────────────────┘        └──────────┬──────────┘             │
│                                            │                        │
│                                   ┌────────▼────────┐               │
│                                   │ _chargeFrom     │               │
│                                   │  Principal      │               │
│                                   └────────┬────────┘               │
│                                            │                        │
│                              ┌─────────────▼─────────────┐          │
│                              │    LibFeeTreasury         │          │
│                              │ accrueWithTreasuryFrom    │          │
│                              │       Principal()         │          │
│                              └─────────────┬─────────────┘          │
│                                            │                        │
│                              ┌─────────────▼─────────────┐          │
│                              │      LibFeeRouter         │          │
│                              │   routeManagedShare()     │          │
│                              └──┬──────────┬──────────┬──┘          │
│                                 │          │          │             │
│                    ┌────────────▼┐  ┌──────▼──────┐  ┌▼───────────┐ │
│                    │  Treasury   │  │Active Credit│  │ Fee Index  │ │
│                    │  Transfer   │  │   Index     │  │  Accrual   │ │
│                    └─────────────┘  └─────────────┘  └────────────┘ │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
         │                    │                    │
         ▼                    ▼                    ▼
   ┌──────────┐        ┌────────────┐        ┌──────────┐
   │ Protocol │        │  Active    │        │   Pool   │
   │ Treasury │        │  Credit    │        │Depositors│
   └──────────┘        │Participants│        └──────────┘
                       └────────────┘
```


---

## Pool-Level AUM Configuration

### Immutable Bounds

Every pool is created with immutable AUM fee bounds that constrain the governance-adjustable rate:

```solidity
struct PoolConfig {
    // ...
    uint16 aumFeeMinBps;    // Minimum AUM fee in basis points (immutable)
    uint16 aumFeeMaxBps;    // Maximum AUM fee in basis points (immutable)
    // ...
}
```

These bounds are set at pool creation and cannot be changed afterward. They give depositors certainty about the fee range they are exposed to when entering a pool.

**Validation at creation:**
- `aumFeeMinBps <= aumFeeMaxBps` (reverts with `InvalidAumFeeBounds` otherwise)
- `aumFeeMaxBps <= 10,000` (reverts with `InvalidParameterRange("aumFeeMaxBps > 100%")` otherwise)

### Current AUM Fee Rate

The mutable rate lives on `PoolData`:

```solidity
struct PoolData {
    // ...
    uint16 currentAumFeeBps;    // Governance-adjustable within bounds
    // ...
}
```

Initialized to `aumFeeMinBps` at pool creation for both permissionless and managed pools.

### Governance Adjustment

```solidity
// AdminGovernanceFacet.sol
function setAumFee(uint256 pid, uint16 feeBps) external {
    // Requires owner or timelock
    // Enforces: aumFeeMinBps <= feeBps <= aumFeeMaxBps
    // Reverts with AumFeeOutOfBounds if out of range
}
```

When pool config is updated via `updatePoolConfig`, if the current AUM fee falls outside the new bounds, it is reset to the new minimum:

```solidity
if (currentAumFeeBps < config.aumFeeMinBps || currentAumFeeBps > config.aumFeeMaxBps) {
    currentAumFeeBps = config.aumFeeMinBps;
}
```

### Special Cases

| Scenario | Behavior |
|----------|----------|
| `aumFeeMinBps == 0 && aumFeeMaxBps == 0` | AUM fee is permanently zero; `setAumFee` only accepts `0` |
| `aumFeeMinBps == aumFeeMaxBps` | AUM fee is effectively immutable at that value |
| `aumFeeMinBps == 0 && aumFeeMaxBps > 0` | Governance can set fee anywhere from 0 to max |

### View Functions

```solidity
// ConfigViewFacet.sol

// Get AUM fee info for a specific pool
function getAumFeeInfo(uint256 pid)
    external view returns (
        uint16 currentFeeBps,
        uint16 minBps,
        uint16 maxBps
    );

// Get comprehensive pool info (includes currentAumFeeBps)
function getPoolInfo(uint256 pid)
    external view returns (
        address underlying,
        PoolConfig memory config,
        uint16 currentAumFeeBps,
        uint256 totalDeposits,
        bool deprecated
    );
```

---

## Module Encumbrance AUM

Module encumbrance AUM is the active fee accrual mechanism. It charges fees on principal reserved by external modules, tracked per tuple of `(positionKey, poolId, moduleId)`.

### Epoch Model

- Epoch length: `1 days` (86,400 seconds)
- Epoch anchor: `currentEpochStart = floor(block.timestamp / 1 days) × 1 days`
- Only whole elapsed days are counted; no partial-day charges

### AUM Rate Resolution

Each module has an `aumBps` field. If it is zero, the system falls back to `defaultModuleAumBps`:

```solidity
function effectiveAumBps(uint256 moduleId) internal view returns (uint16 bps) {
    bps = module.aumBps;
    if (bps == 0) {
        bps = defaultModuleAumBps;
    }
}
```

Governance can set per-module rates or adjust the default, all within configured min/max bounds:

```solidity
registryFacet.setDefaultModuleAumBps(bps);     // Global default
registryFacet.setModuleAumBps(moduleId, bps);   // Per-module override
registryFacet.setModuleAumBounds(minBps, maxBps); // Enforce range
```

### Fee Formula

```
epochs = (currentEpochStart - lastAumEpoch) / 1 days
feeDue = (encumbered × aumBps × epochs) / (365 × 10,000)
```

Where:
- `encumbered` = amount reserved by this specific module for this position in this pool
- `aumBps` = effective AUM rate (per-module or default)
- `epochs` = number of whole days elapsed since last accrual

### First Touch Behavior

If `lastAumEpoch == 0` (first interaction), accrual sets `lastAumEpoch = currentEpochStart` and returns with no fee charged. This prevents retroactive charging from contract deployment time.

### Accrual Triggers

AUM accrual is triggered by three operations:

| Operation | Trigger | Ownership Required |
|-----------|---------|-------------------|
| `encumberPosition` | Before increasing encumbrance | Yes (strict NFT owner) |
| `unencumberPosition` | Before decreasing encumbrance | Yes (strict NFT owner) |
| `pokeModuleAum` | Standalone accrual, no state mutation | No (permissionless) |

All three follow the same accrual path through `LibModuleAum.accrue()`.

### Charging Mechanics

When fees are due, they are charged from the position's principal:

```solidity
chargeablePrincipal = min(userPrincipal[positionKey], encumbered)
charged = min(feeDue, chargeablePrincipal)
```

The charged amount is then:
1. Deducted from `userPrincipal` and `totalDeposits`
2. Routed through `LibFeeTreasury.accrueWithTreasuryFromPrincipal()` → `LibFeeRouter.routeManagedShare()`
3. Split across treasury (transfer out), active credit index (in-pool), and fee index (in-pool)

Only the treasury portion leaves the pool. The fee index and active credit portions remain in-pool as yield backing.

### Accrue-Before-Mutate Pattern

Both `encumberPosition` and `unencumberPosition` accrue tuple AUM before modifying encumbrance. This prevents fee avoidance by rapidly encumbering/unencumbering around epoch boundaries.

Additionally, `encumberPosition` re-checks `module.inactive` after AUM accrual. If accrual triggers deactivation (grace window breached), the encumber call reverts with `ModuleInactive`.

---

## Fee Routing and Distribution

### Centralized Fee Router

All AUM fees flow through `LibFeeRouter`, the protocol's central fee distribution engine. The router splits incoming fee amounts across three destinations using globally configurable basis-point ratios.

### Split Formula

```solidity
toTreasury     = (charged × treasuryShareBps) / 10,000
toActiveCredit = (charged × activeCreditShareBps) / 10,000
toFeeIndex     = charged - toTreasury - toActiveCredit
```

The fee index receives the remainder after treasury and active credit shares, ensuring no dust is lost.

### Default Split Ratios

| Destination | Default Share | Configurable |
|-------------|---------------|--------------|
| Treasury | 10% (1,000 bps) | Yes |
| Active Credit Index | 70% (7,000 bps) | Yes |
| Fee Index | 20% (remainder) | Automatic |

These defaults apply when governance has not set custom split values. The constraint `treasuryShareBps + activeCreditShareBps <= 10,000` is enforced at runtime.

### Routing Path

```
Module AUM Charge
       │
       ▼
LibFeeTreasury.accrueWithTreasuryFromPrincipal()
       │
       ▼
LibFeeRouter.routeManagedShare()
       │
       ├──► Treasury Transfer (leaves pool)
       │    - trackedBalance -= toTreasury
       │    - nativeTrackedTotal -= toTreasury (native pools)
       │    - Low-level ETH transfer or ERC20 transfer
       │
       ├──► LibActiveCreditIndex.accrueWithSource()
       │    - Increases active credit index
       │    - Only matured positions (24h time gate) earn
       │    - Remains in-pool as yield backing
       │
       └──► LibFeeIndex.accrueWithSource()
            - Increases pool fee index
            - All depositors earn proportional to fee base
            - Remains in-pool as yield backing
```

### Fee Index Mechanics

The fee index distributes yield to depositors proportional to their fee base:

```solidity
// Accrual
scaledAmount = amount × 1e18
dividend = scaledAmount + feeIndexRemainder
delta = dividend / totalDeposits
feeIndex += delta
feeIndexRemainder = dividend - (delta × totalDeposits)

// Settlement (per position)
indexDelta = feeIndex - userFeeIndex[positionKey]
feeBase = principal - sameAssetDebt
addedYield = (feeBase × indexDelta) / 1e18
userAccruedYield += addedYield
```

Fee base normalization (`principal - sameAssetDebt`) prevents fee farming via borrow loops. A position that deposits 1,000 and borrows 950 only earns fees on its 50 net equity.

### Active Credit Index Mechanics

The active credit index distributes yield to borrowers and encumbrers with matured active credit weight:

```solidity
// Accrual
delta = (amount × 1e18) / activeCreditMaturedTotal
activeCreditIndex += delta

// Settlement (per position)
indexDelta = activeCreditIndex - state.indexSnapshot
addedYield = (state.principal × indexDelta) / 1e18
```

The 24-hour time gate prevents dust-priming attacks. Positions must maintain active credit weight for 24 hours before earning from this index. Weighted dilution is applied when principal increases to prevent gaming:

```solidity
newTimeCredit = (oldPrincipal × oldTimeCredit + newPrincipal × 0) / totalPrincipal
```

### Balance Invariants

For ERC20 pools:
```
trackedBalance = Σ(userPrincipal) + yieldReserve - pendingMaintenance
```

For native ETH pools:
```
nativeTrackedTotal ≤ address(this).balance
```

Only the treasury portion of AUM fees reduces `trackedBalance` and `nativeTrackedTotal`. The fee index and active credit portions remain in-pool.

---

## Delinquency and Permanent Deactivation

The delinquency system is a self-policing mechanism that ensures modules cannot reserve principal indefinitely without paying AUM fees. It operates at the tuple level but has global consequences.

### Shortfall Detection

If `feeDue > charged` after an accrual, the tuple has shortfall:

```
shortfall = feeDue - charged
```

This occurs when the position's principal (capped at the encumbered amount) is insufficient to cover the full fee.

### Delinquency State Machine

```
                    ┌──────────┐
                    │  Normal  │
                    └────┬─────┘
                         │ shortfall > 0
                         ▼
                    ┌──────────┐
              ┌─────│Delinquent│─────┐
              │     └────┬─────┘     │
              │          │           │
     shortfall == 0      │      grace window
              │          │       breached
              ▼          │           ▼
        ┌──────────┐     │    ┌────────────┐
        │  Normal  │     │    │  Inactive  │
        │ (cleared)│     │    │ (permanent)│
        └──────────┘     │    └────────────┘
                         │
                    continues delinquent
                    within grace window
```

### Delinquency Marking

On first shortfall:
- `delinquent = true`
- `delinquentSince = currentEpochStart`
- `lastShortfall = shortfall`

On subsequent delinquent accruals:
- `lastShortfall` is updated
- Grace window is checked

### Grace Window and Deactivation

```solidity
delinquentEpochCount = (currentEpochStart - delinquentSince) / 1 days;
if (delinquentEpochCount >= deactivationGraceEpochs) {
    module.inactive = true;  // permanent, global
}
```

Key properties:
- `deactivationGraceEpochs` is a global governance parameter
- Deactivation is permanent — no reactivation path exists
- Deactivation is global to the module, not tuple-local
- One delinquent tuple can deactivate the entire module

### Post-Deactivation Behavior

| Operation | Allowed | Notes |
|-----------|---------|-------|
| `encumberPosition` | No | Reverts with `ModuleInactive` |
| `unencumberPosition` | Yes | Always allowed |
| `pokeModuleAum` | Yes | Accrual continues for all tuples |
| `unpauseModule` | No | Reverts with `ModuleInactive` |

Other healthy tuples on the same module continue to accrue AUM normally after deactivation. The module simply cannot accept new encumbrance.

### Delinquency Clearing

If a later accrual has no shortfall (`feeDue <= chargeablePrincipal`), tuple delinquency state is fully cleared:

```solidity
delinquent = false
delinquentSince = 0
lastShortfall = 0
```

This can happen if the position owner deposits additional principal or if the encumbered amount decreases.

---

## Active Credit Integration

Module encumbrance contributes to the Active Credit system, which rewards participants who actively use the protocol (borrowers, encumbrers) with a share of protocol fees.

### How Module Encumbrance Affects Active Credit

When a position encumbers principal against a module, the encumbered amount is added to the position's active credit weight. This weight determines the position's share of active credit index distributions.

```solidity
// On encumber (gated by global pause)
if (!moduleAciPaused) {
    LibActiveCreditIndex.applyEncumbranceIncrease(pool, poolId, positionKey, amount);
}

// On unencumber (always applied)
LibActiveCreditIndex.applyEncumbranceDecrease(pool, poolId, positionKey, amount);
```

### Asymmetric Pause Behavior

The `moduleAciPaused` flag is a global switch (not per-module) that gates only increases:

| ACI Pause State | Encumber | Unencumber |
|-----------------|----------|------------|
| `false` (normal) | Increases active credit weight | Decreases active credit weight |
| `true` (paused) | No active credit change | Decreases active credit weight |

This asymmetry ensures that positions can always reduce their active credit exposure, even when the system is paused. It prevents a scenario where pausing locks positions into an active credit state they cannot exit.

### 24-Hour Time Gate

Active credit weight must mature for 24 hours before the position earns from the active credit index. This prevents flash-encumber attacks where a user encumbers just before a large fee distribution and unencumbers immediately after.

The maturity system uses hourly bucket scheduling for efficient tracking:

```solidity
uint256 public constant TIME_GATE = 24 hours;
uint256 internal constant BUCKET_SIZE = 1 hours;
uint8 internal constant BUCKET_COUNT = 24;
```

### Weighted Dilution

When additional principal is added to an existing active credit position, weighted dilution is applied to prevent gaming:

```solidity
// Existing: 100 units, 20 hours matured
// Adding: 900 units (new, 0 hours)
// New time credit: (100 × 20h + 900 × 0h) / 1000 = 2 hours
// Must wait another 22 hours to mature
```

This prevents dust-priming attacks where a user starts the 24-hour timer on a small amount, then adds a large amount just before maturity.

### Economic Effect

Module AUM fees create a dual yield stream for active credit participants:

1. **Direct AUM yield** — The active credit share of module AUM fees is distributed to all matured active credit positions
2. **Encumbrance weight** — Module encumbrance itself contributes to active credit weight, increasing the position's share of all active credit distributions (not just module AUM)

This creates a positive feedback loop: encumbering principal against a module both generates AUM fees (some of which flow to active credit) and increases the position's active credit weight to capture more of those fees.

---

## Managed Pool System Share

Managed pools have an additional fee routing layer that diverts a configurable portion of protocol fees through the base permissionless pool for the same asset.

### How It Works

When a module AUM fee is charged in a managed pool, `LibFeeRouter.routeManagedShare()` splits the fee into two portions:

```solidity
systemShare  = (amount × managedPoolSystemShareBps) / 10,000
managedShare = amount - systemShare
```

The `systemShare` is routed through the base permissionless pool (same underlying asset), while the `managedShare` stays in the managed pool. Both portions are then split across treasury, active credit, and fee index using the standard `previewSplit()` ratios.

### Configuration

```solidity
// Default: 2000 bps = 20%
uint16 managedPoolSystemShareBps;
```

### Fallback Behavior

If no valid base pool exists for the managed pool's underlying asset, the system share portion falls back to a direct treasury transfer rather than being lost.

### Unmanaged Pools

For unmanaged (permissionless) pools, `routeManagedShare()` is equivalent to `routeSamePool()` — no system share diversion occurs.

---

## Data Models

### Pool-Level AUM State

```solidity
struct PoolConfig {
    // ... other fields ...
    uint16 aumFeeMinBps;    // Immutable lower bound for currentAumFeeBps
    uint16 aumFeeMaxBps;    // Immutable upper bound for currentAumFeeBps
}

struct PoolData {
    // ... other fields ...
    uint16 currentAumFeeBps;    // Governance-adjustable within bounds
}
```

### Module Configuration

```solidity
struct Module {
    address owner;
    bytes32 metadataHash;
    bool paused;
    bool inactive;          // Permanent deactivation flag
    uint16 aumBps;          // Per-module AUM rate (0 = use default)
}
```

### Module Storage

```solidity
struct ModuleStorage {
    uint256 nextModuleId;
    uint256 moduleCreationFee;

    uint16 defaultModuleAumBps;         // Fallback rate when module.aumBps == 0
    uint16 minModuleAumBps;             // Lower bound for setModuleAumBps
    uint16 maxModuleAumBps;             // Upper bound for setModuleAumBps
    uint16 deactivationGraceEpochs;     // Days before delinquent module is deactivated

    bool moduleAciPaused;               // Global pause for module ACI increases

    mapping(uint256 => Module) modules;
    mapping(bytes32 => mapping(uint256 => mapping(uint256 => TupleAumState))) tupleAum;
}
```

### Tuple AUM State

```solidity
struct TupleAumState {
    uint64 lastAumEpoch;        // Last accrued epoch start timestamp
    bool delinquent;            // Whether tuple is currently delinquent
    uint64 delinquentSince;     // Epoch when delinquency began
    uint256 lastShortfall;      // Most recent shortfall amount
}
```

### Accrual Result

```solidity
struct AccrualResult {
    uint256 epochs;         // Number of whole days accrued
    uint256 encumbered;     // Encumbered amount at time of accrual
    uint16 aumBps;          // Effective AUM rate used
    uint256 feeDue;         // Total fee calculated
    uint256 charged;        // Amount actually charged (may be less than feeDue)
    uint256 shortfall;      // feeDue - charged (0 if fully covered)
    bool delinquent;        // Whether tuple is delinquent after accrual
    bool deactivated;       // Whether module was deactivated by this accrual
    uint64 lastAumEpoch;    // Updated last accrued epoch
}
```

### Encumbrance Storage

Module encumbrance is tracked within the unified `LibEncumbrance` system:

```solidity
struct Encumbrance {
    uint256 directLocked;       // Collateral locked for direct loans
    uint256 directLent;         // Principal actively lent out
    uint256 directOfferEscrow;  // Principal escrowed for pending offers
    uint256 indexEncumbered;    // Principal encumbered by index positions
    uint256 moduleEncumbered;   // Principal reserved by module encumbrance (aggregate)
}

struct EncumbranceStorage {
    mapping(bytes32 => mapping(uint256 => Encumbrance)) encumbrance;
    mapping(bytes32 => mapping(uint256 => mapping(uint256 => uint256))) encumberedByIndex;
    mapping(bytes32 => mapping(uint256 => mapping(uint256 => uint256))) encumberedByModule;
}
```

The `moduleEncumbered` field is the aggregate across all modules. The `encumberedByModule` mapping provides the per-module breakdown used for AUM calculations.

### Fee Router State

```solidity
// Global split configuration (in AppStorage)
uint16 treasuryShareBps;           // Treasury share of routed fees
uint16 activeCreditShareBps;       // Active credit share of routed fees
uint16 managedPoolSystemShareBps;  // System share for managed pools
address treasuryAddress;            // Treasury recipient
```

---

## View Functions

### Pool AUM Configuration

```solidity
// Get AUM fee bounds and current rate
function getAumFeeInfo(uint256 pid)
    external view returns (
        uint16 currentFeeBps,
        uint16 minBps,
        uint16 maxBps
    );

// Get comprehensive pool info (includes currentAumFeeBps)
function getPoolInfo(uint256 pid)
    external view returns (
        address underlying,
        PoolConfig memory config,
        uint16 currentAumFeeBps,
        uint256 totalDeposits,
        bool deprecated
    );

// Paginated pool list with AUM info
function getPoolList(uint256 offset, uint256 limit)
    external view returns (PoolInfo[] memory pools, uint256 total);
```

### Module AUM State

```solidity
// Get tuple AUM state with derived fields
function getModuleAumState(uint256 positionId, uint256 poolId, uint256 moduleId)
    external view returns (
        uint64 lastAccruedEpoch,
        uint256 pendingEpochs_,
        bool delinquent,
        uint64 delinquentSince,
        uint256 lastShortfall,
        uint16 graceEpochs,
        uint256 delinquentEpochs_,
        bool graceSatisfied
    );

// Get module AUM configuration
function getModuleAumConfig()
    external view returns (
        uint16 defaultBps,
        uint16 minBps,
        uint16 maxBps,
        uint16 deactivationGraceEpochs
    );

// Check global ACI pause for module encumbrance
function isModuleAciPaused() external view returns (bool);
```

### Module Encumbrance

```solidity
// Total module encumbrance for a position/pool (sum across all modules)
function getModuleEncumbrance(uint256 positionId, uint256 poolId)
    external view returns (uint256 totalModuleEncumbered);

// Per-module encumbrance for a specific tuple
function getModuleEncumbranceForModule(uint256 positionId, uint256 poolId, uint256 moduleId)
    external view returns (uint256 encumbered);
```

---

## Integration Guide

### For Pool Creators

#### Setting AUM Bounds

When creating a pool, choose AUM fee bounds that reflect the expected cost of capital:

```solidity
PoolConfig memory config = PoolConfig({
    // ... other fields ...
    aumFeeMinBps: 50,    // 0.5% minimum annual AUM fee
    aumFeeMaxBps: 500,   // 5.0% maximum annual AUM fee
    // ...
});

poolFacet.initPool{value: creationFee}(poolId, underlying, config);
// currentAumFeeBps initialized to aumFeeMinBps (50 bps)
```

Consider:
- Higher bounds give governance more flexibility but expose depositors to higher potential fees
- Lower bounds provide depositor certainty but limit governance's ability to respond to market conditions
- Setting `aumFeeMinBps == aumFeeMaxBps` makes the rate effectively immutable

#### Querying Pool AUM Info

```solidity
(uint16 currentFee, uint16 minFee, uint16 maxFee) = configView.getAumFeeInfo(poolId);
```

### For Module Developers

#### Registering a Module with AUM

```solidity
// Governance registration (free, uses defaultModuleAumBps)
uint256 moduleId = registryFacet.registerModule(metadataHash);

// Public registration (fee required)
uint256 moduleId = registryFacet.registerModule{value: fee}(metadataHash);
```

New modules initialize with `aumBps = defaultModuleAumBps`. Governance can override per-module:

```solidity
registryFacet.setModuleAumBps(moduleId, 200); // 2% annual
```

#### Monitoring AUM Health

```solidity
// Check tuple AUM state
(
    uint64 lastAccruedEpoch,
    uint256 pendingEpochs_,
    bool delinquent,
    uint64 delinquentSince,
    uint256 lastShortfall,
    uint16 graceEpochs,
    uint256 delinquentEpochs_,
    bool graceSatisfied
) = viewFacet.getModuleAumState(positionId, poolId, moduleId);

// If delinquent, check how close to deactivation
if (delinquent && delinquentEpochs_ > 0) {
    uint256 epochsRemaining = graceEpochs - delinquentEpochs_;
    // Alert: module will be deactivated in epochsRemaining days
}
```

#### Triggering Accrual

```solidity
// Permissionless — anyone can poke to trigger accrual
gatewayFacet.pokeModuleAum(positionId, poolId, moduleId);
```

### For Keepers

Keepers can call `pokeModuleAum` to ensure AUM accrual stays current. This is useful for:
- Triggering delinquency detection on underfunded positions
- Ensuring fee distributions are timely
- Maintaining accurate state for off-chain analytics

No ownership or membership requirements apply to poke calls.

### For Depositors

Depositors earn yield from module AUM fees automatically through the fee index. No action is required beyond depositing into a pool where modules are active.

To check pending yield from all sources (including module AUM):

```solidity
PositionState memory state = positionView.getPositionState(tokenId, poolId);
uint256 pendingYield = state.accruedYield;
```

Yield can be rolled into principal or withdrawn:

```solidity
// Roll yield into principal (increases borrowing capacity)
positionFacet.rollYieldToPosition(tokenId, poolId);

// Or withdraw
positionFacet.withdrawFromPosition(tokenId, poolId, amount, minReceived);
```

---

## Worked Examples

### Example 1: Pool-Level AUM Configuration

**Scenario:** Governance creates a USDC pool with AUM fee bounds and later adjusts the rate.

**Step 1: Pool Creation**
```
aumFeeMinBps = 100 (1.0%)
aumFeeMaxBps = 500 (5.0%)
→ currentAumFeeBps initialized to 100 (1.0%)
```

**Step 2: Governance Adjusts Rate**
```
setAumFee(poolId, 300)
→ currentAumFeeBps = 300 (3.0%) ✓ (within bounds)
```

**Step 3: Governance Attempts Out-of-Bounds**
```
setAumFee(poolId, 600)
→ Reverts: AumFeeOutOfBounds(600, 100, 500)
```

**Step 4: Pool Config Update Resets**
```
updatePoolConfig(poolId, newConfig) where newConfig.aumFeeMinBps = 200
→ currentAumFeeBps was 300, still within [200, 500]
→ currentAumFeeBps remains 300

updatePoolConfig(poolId, newConfig) where newConfig.aumFeeMinBps = 400
→ currentAumFeeBps was 300, now below minimum 400
→ currentAumFeeBps reset to 400
```

### Example 2: Module AUM Accrual and Fee Distribution

**Scenario:** Alice encumbers 365,000 units at 1% AUM (100 bps). Default split: 10% treasury, 70% active credit, 20% fee index.

**Step 1: Encumber**
```
Principal: 1,000,000
Encumbered: 365,000
Available: 635,000
```

**Step 2: First Touch (Day 1)**
```
lastAumEpoch = 0 → set to currentEpochStart
No fee charged (first touch initialization)
```

**Step 3: Day 2 Accrual (1 epoch)**
```
epochs = 1
feeDue = (365,000 × 100 × 1) / (365 × 10,000) = 10
chargeablePrincipal = min(1,000,000, 365,000) = 365,000
charged = min(10, 365,000) = 10
shortfall = 0

Principal deduction:
  userPrincipal: 1,000,000 → 999,990
  totalDeposits: decreased by 10

Fee routing (charged = 10):
  toTreasury     = (10 × 1,000) / 10,000 = 1
  toActiveCredit = (10 × 7,000) / 10,000 = 7
  toFeeIndex     = 10 - 1 - 7 = 2

  Treasury: 1 unit transferred out (trackedBalance -= 1)
  Active Credit Index: 7 units accrued (in-pool)
  Fee Index: 2 units accrued (in-pool)
```

**Step 4: Day 5 Accrual (3 epochs since Day 2)**
```
epochs = 3
feeDue = (365,000 × 100 × 3) / (365 × 10,000) = 30
charged = 30
shortfall = 0

Fee routing (charged = 30):
  toTreasury     = 3
  toActiveCredit = 21
  toFeeIndex     = 6
```

### Example 3: Multi-Epoch Accrual Equivalence

**Scenario:** Demonstrating that accruing N epochs at once equals accruing 1 epoch N times (when no shortfall).

**Single 7-day accrual:**
```
encumbered = 730,000, aumBps = 200 (2%)
feeDue = (730,000 × 200 × 7) / (365 × 10,000) = 280
```

**Seven 1-day accruals:**
```
Day 1: feeDue = (730,000 × 200 × 1) / (365 × 10,000) = 40
Day 2: feeDue = 40 (principal reduced by 40, but encumbered unchanged)
...
Total ≈ 280 (slight variance from principal reduction)
```

In practice, the single-call result is deterministic and avoids compounding effects from intermediate principal reductions.

### Example 4: Delinquency Progression to Deactivation

**Scenario:** Bob has 15 units of principal but 1,095,000 encumbered at 1% AUM. Grace epochs = 3.

**Day 1: First Touch**
```
lastAumEpoch initialized, no charge
```

**Day 2: First Real Accrual**
```
feeDue = (1,095,000 × 100 × 1) / (365 × 10,000) = 30
chargeablePrincipal = min(15, 1,095,000) = 15
charged = 15
shortfall = 15
→ delinquent = true, delinquentSince = Day 2 epoch
→ Principal: 15 → 0
→ Module NOT deactivated (grace just started)
```

**Day 3: Second Delinquent Accrual**
```
feeDue = 30
chargeablePrincipal = min(0, 1,095,000) = 0
charged = 0
shortfall = 30
→ delinquentEpochs = 1 (< 3 grace epochs)
→ Module NOT deactivated
```

**Day 4: Third Delinquent Accrual**
```
feeDue = 30, charged = 0, shortfall = 30
delinquentEpochs = 2 (< 3 grace epochs)
→ Module NOT deactivated
```

**Day 5: Grace Window Breached**
```
feeDue = 30, charged = 0, shortfall = 30
delinquentEpochs = 3 (== graceEpochs)
→ module.inactive = true (PERMANENT, GLOBAL)
→ No new encumbrance on ANY tuple for this module
→ Unencumber and poke remain callable
```

### Example 5: Delinquency Clearing

**Scenario:** Carol's tuple becomes delinquent, but she deposits more principal before the grace window expires.

**Day 1: Delinquent Accrual**
```
feeDue = 50, chargeablePrincipal = 20, charged = 20, shortfall = 30
→ delinquent = true, delinquentSince = Day 1
```

**Day 1 (later): Carol deposits 1,000 more principal**
```
userPrincipal increases by 1,000
```

**Day 2: Next Accrual**
```
feeDue = 50
chargeablePrincipal = min(1,000, encumbered) = sufficient
charged = 50
shortfall = 0
→ delinquent = false, delinquentSince = 0, lastShortfall = 0
→ Delinquency fully cleared
```

### Example 6: Managed Pool AUM Fee Routing

**Scenario:** Module AUM fee of 100 units charged in a managed pool with 20% system share.

```
Total charged: 100

Step 1: Managed pool split
  systemShare  = (100 × 2,000) / 10,000 = 20
  managedShare = 100 - 20 = 80

Step 2: System share routed through base pool
  Base pool treasury:      (20 × 1,000) / 10,000 = 2
  Base pool active credit: (20 × 7,000) / 10,000 = 14
  Base pool fee index:     20 - 2 - 14 = 4

Step 3: Managed share routed in managed pool
  Managed pool treasury:      (80 × 1,000) / 10,000 = 8
  Managed pool active credit: (80 × 7,000) / 10,000 = 56
  Managed pool fee index:     80 - 8 - 56 = 16

Total distribution:
  Treasury:      2 + 8 = 10 (10%)
  Active Credit: 14 + 56 = 70 (70%, split across two pools)
  Fee Index:     4 + 16 = 20 (20%, split across two pools)
```

### Example 7: ACI Pause Asymmetry

**Scenario:** Module ACI is paused globally. Alice encumbers and unencumbers.

```
// Encumber 500 with ACI paused
encumberPosition(tokenId, poolId, moduleId, 500)
→ Module encumbrance: 0 → 500
→ Active credit weight: unchanged (paused, no increase)

// Unencumber 200 with ACI paused
unencumberPosition(tokenId, poolId, moduleId, 200)
→ Module encumbrance: 500 → 300
→ Active credit weight: decreased by 200 (always applied)

// Net effect: active credit weight is -200 relative to before
// This is intentional — positions can always reduce exposure
```

---

## Error Reference

### Pool AUM Errors

| Error | Cause |
|-------|-------|
| `AumFeeOutOfBounds(uint16 attempted, uint16 min, uint16 max)` | `setAumFee` called with rate outside pool's immutable bounds |
| `InvalidAumFeeBounds()` | Pool creation with `aumFeeMinBps > aumFeeMaxBps` |
| `InvalidParameterRange("aumFeeMaxBps > 100%")` | Pool creation with `aumFeeMaxBps > 10,000` |

### Module AUM Errors

| Error | Cause |
|-------|-------|
| `ModuleNotFound(uint256 moduleId)` | Module ID doesn't exist or is zero |
| `ModulePausedError(uint256 moduleId)` | Encumbering against a paused module |
| `ModuleInactive(uint256 moduleId)` | Encumbering or unpausing a permanently deactivated module |
| `ModuleAumOutOfBounds(uint16 bps, uint16 minBps, uint16 maxBps)` | Module AUM bps outside configured min/max bounds |
| `InvalidAumFeeBounds()` | `minBps > maxBps` in `setModuleAumBounds` |

### Fee Routing Errors

| Error | Cause |
|-------|-------|
| `InsufficientPrincipal(uint256 required, uint256 available)` | Treasury transfer exceeds tracked balance during AUM charge |
| `InsufficientPoolLiquidity(uint256 amount, uint256 available)` | Fee index accrual exceeds available pool backing |
| `TreasuryNotSet()` | Treasury address is zero during fee-based operations |

### Encumbrance Errors

| Error | Cause |
|-------|-------|
| `InsufficientUnencumberedPrincipal(uint256 requested, uint256 available)` | Encumber amount exceeds available principal |
| `EncumbranceUnderflow(uint256 amount, uint256 current)` | Unencumber amount exceeds current encumbrance |
| `NotNFTOwner(address caller, uint256 tokenId)` | Caller doesn't own the Position NFT |

---

## Events

### Pool AUM Events

```solidity
event AumFeeUpdated(
    uint256 indexed pid,
    uint16 oldFeeBps,
    uint16 newFeeBps
);
```

### Module AUM Events

```solidity
event ModuleAumAccrued(
    uint256 indexed moduleId,
    bytes32 indexed positionKey,
    uint256 indexed poolId,
    uint256 epochs,
    uint256 feeDue,
    uint256 charged,
    uint256 shortfall,
    uint64 newLastAumEpoch
);

event ModuleAumDelinquent(
    uint256 indexed moduleId,
    bytes32 indexed positionKey,
    uint256 indexed poolId,
    uint256 feeDue,
    uint256 chargeablePrincipal,
    uint256 shortfall
);

event ModulePermanentlyDeactivated(
    uint256 indexed moduleId,
    bytes32 indexed positionKey,
    uint256 indexed poolId,
    uint256 feeDue,
    uint256 chargeablePrincipal,
    uint256 shortfall
);
```

### Fee Routing Events

```solidity
event FeeIndexAccrued(
    uint256 indexed pid,
    uint256 amount,
    uint256 delta,
    uint256 newIndex,
    bytes32 source
);

event ActiveCreditIndexAccrued(
    uint256 indexed pid,
    uint256 amount,
    uint256 delta,
    uint256 newIndex,
    bytes32 source
);

event ManagedPoolSystemShareRouted(
    uint256 indexed managedPid,
    uint256 indexed basePid,
    uint256 amount,
    bytes32 source
);
```

### Encumbrance Events

```solidity
event ModuleEncumbranceIncreased(
    bytes32 indexed positionKey,
    uint256 indexed poolId,
    uint256 indexed moduleId,
    uint256 amount,
    uint256 totalEncumbered,
    uint256 moduleEncumbered
);

event ModuleEncumbranceDecreased(
    bytes32 indexed positionKey,
    uint256 indexed poolId,
    uint256 indexed moduleId,
    uint256 amount,
    uint256 totalEncumbered,
    uint256 moduleEncumbered
);
```

### Active Credit Events

```solidity
event ActiveCreditTimingUpdated(
    uint256 indexed pid,
    bytes32 indexed user,
    bool isDebtState,
    uint40 startTime,
    uint256 principal,
    bool isMature
);

event ActiveCreditSettled(
    uint256 indexed pid,
    bytes32 indexed user,
    uint256 prevIndex,
    uint256 newIndex,
    uint256 addedYield,
    uint256 totalAccruedYield
);
```

---

## Security Considerations

### 1. Immutable Bounds Guarantee

Pool AUM fee bounds are set at creation and cannot be changed. This gives depositors a hard guarantee on the maximum fee they can be charged, regardless of governance actions.

```solidity
// These are immutable after pool creation
aumFeeMinBps = config.aumFeeMinBps;
aumFeeMaxBps = config.aumFeeMaxBps;

// Governance can only adjust within bounds
require(feeBps >= minBps && feeBps <= maxBps);
```

### 2. Accrue-Before-Mutate

Both `encumberPosition` and `unencumberPosition` accrue tuple AUM before modifying encumbrance. This prevents fee avoidance by rapidly encumbering/unencumbering around epoch boundaries.

```solidity
// 1. Accrue AUM (charges fees on current encumbrance)
LibModuleAum.accrue(positionKey, poolId, moduleId);
// 2. Re-check module status (may have been deactivated by accrual)
require(!module.inactive, "ModuleInactive");
// 3. Now mutate encumbrance
```

### 3. Mid-Call Deactivation Guard

`encumberPosition` re-checks `module.inactive` after AUM accrual. If accrual triggers deactivation (grace window breached), the encumber call reverts rather than allowing new encumbrance on a just-deactivated module.

### 4. Chargeable Principal Cap

AUM fees are capped at the lesser of user principal and encumbered amount:

```solidity
chargeablePrincipal = min(userPrincipal, encumbered)
charged = min(feeDue, chargeablePrincipal)
```

This prevents over-charging and ensures fees cannot exceed the capital backing the encumbrance.

### 5. Fee Index Backing Check

`LibFeeIndex.accrueWithSource()` verifies that sufficient backing exists before accruing yield:

```solidity
uint256 backing = trackedBalance + activeCreditPrincipalTotal;
uint256 available = backing > reserved ? backing - reserved : 0;
require(amount <= available, "InsufficientPoolLiquidity");
```

This prevents phantom yield from being accrued without real asset backing.

### 6. Native Pool Balance Invariant

For native ETH pools, `nativeTrackedTotal` is reduced atomically with `trackedBalance` during treasury transfers:

```solidity
pool.trackedBalance -= toTreasury;
nativeTrackedTotal -= toTreasury;
// Invariant: nativeTrackedTotal <= address(this).balance
```

### 7. Reentrancy Protection

All state-changing functions on `ModuleGatewayFacet` use the `nonReentrant` modifier. Treasury transfers (which involve external calls) occur after all state mutations.

### 8. Permissionless Poke Safety

`pokeModuleAum` is permissionless but safe because:
- It only triggers accrual (no encumbrance mutation)
- It requires the module, position token, and pool to exist
- It cannot be used to grief positions (fees would accrue anyway on next interaction)
- It enables timely delinquency detection by keepers

### 9. Split Ratio Constraint

The fee router enforces that treasury and active credit shares cannot exceed 100%:

```solidity
require(treasuryBps + activeBps <= BPS_DENOMINATOR, "FeeRouter: splits>100%");
```

The fee index receives the remainder, ensuring no dust is lost and the full charged amount is distributed.

### 10. Namespace Isolation

Module encumbrance and index encumbrance are tracked independently in `LibEncumbrance`. Mutations to one namespace cannot affect the other:

```solidity
// Module operations touch moduleEncumbered + encumberedByModule
// Index operations touch indexEncumbered + encumberedByIndex
// Neither can corrupt the other's storage
```

### 11. Membership Cleanup Blocking

Pool membership cannot be cleared while `moduleEncumbered > 0`. This prevents orphaned encumbrance state that could lead to accounting inconsistencies.

### 12. Access Control Summary

| Function | Access |
|----------|--------|
| `setAumFee` | Owner or timelock |
| `setDefaultModuleAumBps` | Owner or timelock |
| `setModuleAumBps` | Owner or timelock |
| `setModuleAumBounds` | Owner or timelock |
| `setModuleDeactivationGraceEpochs` | Owner or timelock |
| `setModuleAciPaused` | Owner or timelock |
| `encumberPosition` | Position NFT owner (strict) |
| `unencumberPosition` | Position NFT owner (strict) |
| `pokeModuleAum` | Anyone |

---

## Appendix: Correctness Properties

### Property 1: Pool AUM Bound Invariant
For any pool after any number of governance operations:
```
aumFeeMinBps <= currentAumFeeBps <= aumFeeMaxBps
```

### Property 2: Module AUM Fee Determinism
Fee due depends only on the tuple's encumbered amount, effective rate, and elapsed epochs:
```
feeDue = f(encumberedByModule[positionKey][poolId][moduleId], aumBps, epochs)
```
No external state (oracles, prices, other positions) influences the calculation.

### Property 3: No Retroactive First Touch
First accrual never charges fees regardless of elapsed time:
```
if (lastAumEpoch == 0) → charged = 0
```

### Property 4: Epoch Determinism
Accruing N epochs in one call produces the same fee as the formula predicts:
```
feeDue(N epochs) = (encumbered × aumBps × N) / (365 × 10,000)
```

### Property 5: Fee Distribution Conservation
For any AUM charge, the full amount is distributed:
```
toTreasury + toActiveCredit + toFeeIndex = charged
```

### Property 6: Principal Reduction Conservation
For any AUM charge:
```
userPrincipal_after = userPrincipal_before - charged
totalDeposits_after = totalDeposits_before - charged
```

### Property 7: Chargeable Cap
Charged amount never exceeds the lesser of fee due and available principal:
```
charged <= min(feeDue, min(userPrincipal, encumbered))
```

### Property 8: ACI Pause Asymmetry
When `moduleAciPaused == true`:
```
encumber → activeCreditPrincipalTotal unchanged
unencumber → activeCreditPrincipalTotal decreased
```

### Property 9: Delinquency Monotonicity
Once a module is deactivated, it remains deactivated forever:
```
if (module.inactive == true) → module.inactive == true (invariant)
```

### Property 10: Namespace Isolation
Module AUM mutations do not affect index encumbrance and vice versa:
```
accrueModuleAum(key, pool, mod) → indexEncumbered unchanged
```

### Property 11: Native Tracked Invariant
For native pools after any number of AUM accruals:
```
nativeTrackedTotal ≤ address(this).balance
```

### Property 12: Split Ratio Constraint
Fee router splits never exceed the input amount:
```
toTreasury + toActiveCredit + toFeeIndex == amount
treasuryShareBps + activeCreditShareBps <= 10,000
```

### Property 13: Immutable Bounds Permanence
Pool AUM fee bounds are set once and never change:
```
aumFeeMinBps(t) == aumFeeMinBps(t=0) ∀ t
aumFeeMaxBps(t) == aumFeeMaxBps(t=0) ∀ t
```

---

**Document Version:** 1.0
