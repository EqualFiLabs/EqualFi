# Module Encumbrance - Design Document

**Version:** 1.1 (Updated for unified encumbrance integration)

---

## Table of Contents

1. [Overview](#overview)
2. [How It Works](#how-it-works)
3. [Architecture](#architecture)
4. [Registration and Administration](#registration-and-administration)
5. [Encumbrance Lifecycle](#encumbrance-lifecycle)
6. [AUM Fee System](#aum-fee-system)
7. [Delinquency and Permanent Deactivation](#delinquency-and-permanent-deactivation)
8. [Active Credit Policy](#active-credit-policy)
9. [Data Models](#data-models)
10. [View Functions](#view-functions)
11. [Integration Guide](#integration-guide)
12. [Worked Examples](#worked-examples)
13. [Error Reference](#error-reference)
14. [Events](#events)
15. [Security Considerations](#security-considerations)

---

## Overview

Module encumbrance is a reservation system over Position NFT principal. A reservation is tracked per tuple:

- `positionKey`
- `poolId`
- `moduleId`

Reserved principal remains in protocol custody and is non-reusable while encumbered. The system also applies a tuple-scoped AUM fee that accrues in whole-day epochs.

### Key Characteristics

| Feature | Description |
|---------|-------------|
| **Reservation-Only** | Encumber/unencumber does not transfer assets |
| **Tuple-Scoped AUM** | Fees accrue per (position, pool, module) tuple |
| **Epoch-Based Accrual** | Whole-day epochs, no partial-day charges |
| **Namespace Isolation** | Module and index encumbrance tracked independently |
| **Delinquency Protection** | Shortfall triggers grace window then permanent deactivation |
| **Active Credit Integration** | Module encumbrance contributes to Active Credit weight |

### System Participants

| Role | Description |
|------|-------------|
| **Module Owner** | Address that registered the module; can pause/unpause and transfer ownership |
| **Position Owner** | NFT holder who encumbers/unencumbers principal against a module |
| **Governance** | Diamond owner or timelock; registers modules for free, configures global AUM parameters |
| **Keeper (Poker)** | Anyone who calls `pokeModuleAum` to trigger AUM accrual without mutating encumbrance |

### Why Module Encumbrance?

Modules are external systems that need to reserve position principal without transferring it. Module encumbrance provides:
- **No asset movement** → Principal stays in pool custody during reservation
- **Independent tracking** → Module reservations don't interfere with index or direct encumbrance
- **Built-in fee collection** → AUM fees are charged automatically and flow back to depositors and active participants as yield
- **Self-policing** → Delinquent modules that cannot sustain AUM payments are permanently deactivated

The tradeoff: reserved principal cannot be used for other encumbrance types (lending, index minting, other modules) while encumbered.

---

## How It Works

### The Core Model

1. **Register** a module via governance (free) or public registration (fee required)
2. **Encumber** position principal against the module for a specific pool
3. **AUM accrues** daily, charging fees from the encumbered position's principal
4. **Unencumber** to release reserved principal back to available balance
5. **Poke** to trigger AUM accrual without changing encumbrance (permissionless)

### Solvency Check

Encumbrance is bounded by available principal:

```
available = principal - (directLocked + directLent + directOfferEscrow + indexEncumbered + moduleEncumbered)
```

New module encumbrance cannot exceed `available`.

### AUM Fee Formula

```
epochs = (currentEpochStart - lastAumEpoch) / 1 days
feeDue = (encumbered × aumBps × epochs) / (365 × 10,000)
```

Fees are charged from position principal and split across the fee index (depositor yield), active credit index (participant yield), and treasury.

---

## Architecture

### Contract Structure

```
src/modules/
├── ModuleRegistryFacet.sol       # Module registration and governance controls
├── ModuleGatewayFacet.sol        # Encumber/unencumber execution and AUM poke
└── ModuleViewFacet.sol           # Read-only module, encumbrance, and AUM state

src/libraries/
├── LibModuleRegistry.sol         # Module config storage, tuple AUM state, events
├── LibModuleEncumbrance.sol      # Thin wrapper around LibEncumbrance module methods
├── LibModuleAum.sol              # Epoch accrual, principal charging, delinquency
├── LibEncumbrance.sol            # Unified encumbrance storage (all types including module)
└── LibSolvencyChecks.sol         # Available principal calculation

src/interfaces/
├── IModuleRegistryFacet.sol      # Registration and governance setter signatures
├── IModuleGatewayFacet.sol       # Encumber, unencumber, poke signatures
└── IModuleViewFacet.sol          # All view function signatures
```

### High-Level Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                   Module Encumbrance System                      │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐           │
│  │   Module      │  │   Module     │  │   Module     │           │
│  │  Registry     │  │   Gateway    │  │    View      │           │
│  │   Facet       │  │    Facet     │  │    Facet     │           │
│  └──────────────┘  └──────────────┘  └──────────────┘           │
│         │                 │                 │                   │
│         └─────────────────┼─────────────────┘                   │
│                           │                                     │
│              ┌────────────┼────────────┐                        │
│              │            │            │                        │
│     ┌────────────┐ ┌────────────┐ ┌────────────┐               │
│     │ LibModule  │ │ LibModule  │ │ LibModule  │               │
│     │ Registry   │ │ Encumbrance│ │    Aum     │               │
│     └────────────┘ └────────────┘ └────────────┘               │
│              │            │            │                        │
│              └────────────┼────────────┘                        │
│                           │                                     │
│                    ┌──────────────┐                             │
│                    │ LibEncumbrance│                             │
│                    │  (unified)   │                             │
│                    └──────────────┘                             │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│                    Per-Tuple AUM State                           │
│  ┌──────────────────────────────────────────────────────┐       │
│  │  (positionKey, poolId, moduleId) → TupleAumState     │       │
│  └──────────────────────────────────────────────────────┘       │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
         │                    │                    │
         ▼                    ▼                    ▼
   ┌──────────┐        ┌──────────┐        ┌──────────┐
   │ Position │        │ Protocol │        │  Active   │
   │   NFTs   │        │ Treasury │        │  Credit   │
   └──────────┘        └──────────┘        └──────────┘
```

---

## Registration and Administration

### `registerModule(metadataHash) → moduleId`

Module IDs are monotonic and start at `1`.

**Governance Path (Free):**
```solidity
// Owner or timelock — must send 0 ETH
uint256 moduleId = registryFacet.registerModule(metadataHash);
```

**Permissionless Path (Fee Required):**
```solidity
// Anyone — must send exactly moduleCreationFee
uint256 moduleId = registryFacet.registerModule{value: fee}(metadataHash);
```

**Rules:**
- Governance callers (`owner` or `timelock`) must send `0` ETH; any value reverts with `ModuleIncorrectFee`
- Non-governance callers must send exactly `moduleCreationFee`; if `moduleCreationFee == 0`, non-governance registration is disabled (`ModuleRegistrationDisabled`)
- Public registration fee is transferred to treasury via low-level call
- New modules initialize with `owner = msg.sender`, `paused = false`, `inactive = false`, `aumBps = defaultModuleAumBps`

### Ownership and Pause Controls

```solidity
// Transfer ownership — only current module owner
registryFacet.setModuleOwner(moduleId, newOwner);

// Pause — module owner or governance
registryFacet.pauseModule(moduleId);

// Unpause — module owner or governance (reverts if module is inactive)
registryFacet.unpauseModule(moduleId);
```

- `setModuleOwner` reverts with `InvalidModuleOwner` if `newOwner == address(0)`
- Inactive modules cannot be unpaused (`ModuleInactive`)

### Governance Knobs

All governance setters require `owner` or `timelock`:

```solidity
registryFacet.setModuleCreationFee(fee);
registryFacet.setDefaultModuleAumBps(bps);
registryFacet.setModuleAumBps(moduleId, bps);
registryFacet.setModuleAumBounds(minBps, maxBps);
registryFacet.setModuleDeactivationGraceEpochs(epochs);
registryFacet.setModuleAciPaused(paused);
```

`setDefaultModuleAumBps` and `setModuleAumBps` enforce configured min/max bounds. `setModuleAumBounds` reverts with `InvalidAumFeeBounds` if `minBps > maxBps`.

---

## Encumbrance Lifecycle

### `encumberPosition(positionId, poolId, moduleId, amount)`

Execution order:

1. Require module exists and is not paused/inactive.
2. Require caller owns `positionId` (strict owner check; ERC721 approvals are not accepted on this path).
3. Require pool is initialized and the position is already a member of the pool.
4. Accrue tuple AUM before mutating encumbrance.
5. Re-check module inactive status (accrual may have auto-deactivated the module mid-call).
6. Check available principal with `LibSolvencyChecks.calculateAvailablePrincipal(...)`.
7. Increase tuple module encumbrance via `LibModuleEncumbrance.encumber(...)`.
8. Increase Active Credit encumbrance weight unless global module ACI pause is enabled.

### `unencumberPosition(positionId, poolId, moduleId, amount)`

Execution order:

1. Require module exists.
2. Require caller owns `positionId` (strict owner check; ERC721 approvals are not accepted on this path).
3. Require pool initialized and position membership.
4. Accrue tuple AUM before mutation.
5. Decrease tuple module encumbrance (underflow-protected via `EncumbranceUnderflow`).
6. Always decrease Active Credit weight (regardless of ACI pause state).

`unencumberPosition` is allowed even if the module is paused or inactive.

### `pokeModuleAum(positionId, poolId, moduleId)`

- Permissionless.
- Requires only: module exists, position token exists, pool initialized.
- No ownership or membership requirement.
- Runs tuple AUM accrual without mutating encumbrance.

---

## AUM Fee System

### Epoching

- Epoch length: `1 days`.
- Epoch anchor: `currentEpochStart = floor(block.timestamp / 1 days) × 1 days`.
- Pending epochs count only whole elapsed days.

### First Touch Behavior

If `lastAumEpoch == 0`, accrual sets `lastAumEpoch = currentEpochStart` and returns with no fee charged. This prevents retroactive charging from contract deployment time.

### Fee Formula

```solidity
epochs = (currentEpochStart - lastAumEpoch) / 1 days;
feeDue = (encumbered × aumBps × epochs) / (365 × 10_000);
```

Where:

- `encumbered = encumberedByModule[positionKey][poolId][moduleId]`
- `aumBps = module.aumBps` unless `module.aumBps == 0`, then `defaultModuleAumBps`

### Charging and Routing

AUM fees are the mechanism by which modules pay back into the system for the privilege of reserving position principal. The charged amount is split across three destinations, ensuring that depositors and active participants are compensated for the capital their principal backs:

For each accrual:

1. `LibFeeIndex.settle(poolId, positionKey)` is called first to checkpoint fee index state.
2. `chargeablePrincipal = min(userPrincipal[positionKey], encumbered)`.
3. `charged = min(feeDue, chargeablePrincipal)`.
4. Principal accounting decreases:
   - `userPrincipal -= charged`
   - `totalDeposits -= charged`
5. Fee routing uses `LibFeeTreasury.accrueWithTreasuryFromPrincipal(...)` with source `MODULE_AUM_FEE`, which delegates to `LibFeeRouter.routeManagedShare(...)`.

### Fee Split Destinations

The charged amount is split according to global basis-point configuration:

| Destination | Mechanism | Beneficiaries |
|-------------|-----------|---------------|
| **Fee Index** | `LibFeeIndex.accrueWithSource(...)` | All depositors in the pool, proportional to fee base |
| **Active Credit Index** | `LibActiveCreditIndex.accrueWithSource(...)` | Borrowers and encumbrers with matured active credit weight |
| **Treasury** | Direct transfer to treasury address | Protocol treasury |

The split is determined by `treasuryShareBps` and `activeCreditShareBps`; the fee index receives the remainder (`amount - treasury - activeCredit`).

```solidity
toTreasury    = (charged × treasuryShareBps) / 10,000
toActiveCredit = (charged × activeCreditShareBps) / 10,000
toFeeIndex    = charged - toTreasury - toActiveCredit
```

Only the `toTreasury` portion leaves the pool. `trackedBalance` and `nativeTrackedTotal` (for native pools) are reduced by the treasury-transfer portion only. The fee index and active credit portions remain in-pool as yield backing for depositors and active participants respectively.

### Economic Effect

Module AUM fees create a continuous yield stream for pool participants:
- **Depositors** earn yield via the fee index from modules reserving principal in their pool
- **Active credit participants** earn yield via the active credit index
- **The protocol** collects its treasury share

This means modules are not just reserving principal — they are paying rent on it. If a module cannot sustain its AUM payments (principal runs out), the delinquency mechanism kicks in and eventually deactivates the module permanently.

---

## Delinquency and Permanent Deactivation

### Shortfall Detection

If `feeDue > charged`, the tuple has shortfall:

- Tuple state is marked delinquent (`delinquent = true`).
- `delinquentSince` is set to `currentEpochStart` on first delinquent accrual.
- `lastShortfall` is updated to the current shortfall amount.

### Grace Window and Deactivation

If shortfall persists on subsequent delinquent accruals:

```solidity
delinquentEpochCount = (currentEpochStart - delinquentSince) / 1 days;
if (delinquentEpochCount >= deactivationGraceEpochs) {
    module.inactive = true;  // permanent, global
}
```

- `module.inactive = true` is a global module flag, not tuple-local.
- No reactivation path exists.
- New encumbrance is blocked forever.
- Unencumber and poke remain callable.
- Other healthy tuples on the same module continue to accrue AUM normally after deactivation.

### Delinquency Clearing

If a later accrual has no shortfall (`feeDue <= chargeablePrincipal`), tuple delinquency state is fully cleared:
- `delinquent = false`
- `delinquentSince = 0`
- `lastShortfall = 0`

---

## Active Credit Policy

- Module encumbrance increases contribute to Active Credit weight only when `moduleAciPaused == false`.
- Module encumbrance decreases always reduce Active Credit weight, regardless of ACI pause state.
- This is a global switch, not per-module.

```solidity
// On encumber (gated)
if (!moduleAciPaused) {
    LibActiveCreditIndex.applyEncumbranceIncrease(pool, poolId, positionKey, amount);
}

// On unencumber (always)
LibActiveCreditIndex.applyEncumbranceDecrease(pool, poolId, positionKey, amount);
```

---

## Data Models

### Module

```solidity
struct Module {
    address owner;
    bytes32 metadataHash;
    bool paused;
    bool inactive;
    uint16 aumBps;
}
```

### Module Storage

```solidity
struct ModuleStorage {
    uint256 nextModuleId;
    uint256 moduleCreationFee;

    uint16 defaultModuleAumBps;
    uint16 minModuleAumBps;
    uint16 maxModuleAumBps;
    uint16 deactivationGraceEpochs;

    bool moduleAciPaused;

    mapping(uint256 => Module) modules;
    mapping(bytes32 => mapping(uint256 => mapping(uint256 => TupleAumState))) tupleAum;
}
```

### Tuple AUM State

```solidity
struct TupleAumState {
    uint64 lastAumEpoch;
    bool delinquent;
    uint64 delinquentSince;
    uint256 lastShortfall;
}
```

### Encumbrance Storage (LibEncumbrance)

Position encumbrance is tracked centrally via `LibEncumbrance.sol`:

```solidity
struct Encumbrance {
    uint256 directLocked;
    uint256 directLent;
    uint256 directOfferEscrow;
    uint256 indexEncumbered;
    uint256 moduleEncumbered;
}

struct EncumbranceStorage {
    mapping(bytes32 => mapping(uint256 => Encumbrance)) encumbrance;
    mapping(bytes32 => mapping(uint256 => mapping(uint256 => uint256))) encumberedByIndex;
    mapping(bytes32 => mapping(uint256 => mapping(uint256 => uint256))) encumberedByModule;
}
```

Module encumbrance occupies the `moduleEncumbered` aggregate field and the `encumberedByModule` per-module breakdown. Both are updated atomically on encumber/unencumber.

### Accrual Result

```solidity
struct AccrualResult {
    uint256 epochs;
    uint256 encumbered;
    uint16 aumBps;
    uint256 feeDue;
    uint256 charged;
    uint256 shortfall;
    bool delinquent;
    bool deactivated;
    uint64 lastAumEpoch;
}
```

---

## View Functions

### Module Metadata

```solidity
// Returns owner, metadataHash, paused, inactive, aumBps
function getModule(uint256 moduleId)
    external view returns (address, bytes32, bool, bool, uint16);
```

### Encumbrance Queries

```solidity
// Total module encumbrance for a position/pool (sum across all modules)
function getModuleEncumbrance(uint256 positionId, uint256 poolId)
    external view returns (uint256 totalModuleEncumbered);

// Per-module encumbrance for a specific tuple
function getModuleEncumbranceForModule(uint256 positionId, uint256 poolId, uint256 moduleId)
    external view returns (uint256 encumbered);
```

### AUM State

```solidity
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
```

### Config

```solidity
// Returns defaultBps, minBps, maxBps, deactivationGraceEpochs
function getModuleAumConfig()
    external view returns (uint16, uint16, uint16, uint16);

// Global ACI pause for module encumbrance increases
function isModuleAciPaused() external view returns (bool);
```

---

## Integration Guide

### For Module Developers

#### Encumbering Principal

```solidity
// 1. Register a module (governance or with fee)
uint256 moduleId = registryFacet.registerModule{value: fee}(metadataHash);

// 2. User encumbers their position principal
gatewayFacet.encumberPosition(positionId, poolId, moduleId, amount);

// 3. Query encumbered amount
uint256 enc = viewFacet.getModuleEncumbranceForModule(positionId, poolId, moduleId);

// 4. Release when done
gatewayFacet.unencumberPosition(positionId, poolId, moduleId, amount);
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

// Trigger accrual permissionlessly
gatewayFacet.pokeModuleAum(positionId, poolId, moduleId);
```

#### Managing Module Lifecycle

```solidity
// Pause to block new encumbrance (existing encumbrance unaffected)
registryFacet.pauseModule(moduleId);

// Unpause to re-enable (fails if module is permanently inactive)
registryFacet.unpauseModule(moduleId);

// Transfer ownership
registryFacet.setModuleOwner(moduleId, newOwner);
```

### Integration Boundary

Module encumbrance is included in the unified `LibEncumbrance.total()` calculation used by all protocol paths:

- `ModuleGatewayFacet.encumberPosition` (via `LibSolvencyChecks.calculateAvailablePrincipal`)
- `EqualIndexPositionFacet.mintFromPosition` (via `LibSolvencyChecks.calculateAvailablePrincipal`)
- `PositionManagementFacet.withdrawFromPosition` (via `LibEncumbrance.total`)
- `LendingFacet` collateral checks (via `LibEncumbrance.total`)
- `PenaltyFacet` collateral checks (via `LibEncumbrance.total`)
- `PositionViewFacet.getPositionEncumbrance` (returns `moduleEncumbered` as a field)
- `EnhancedLoanViewFacet` collateral views (via `LibEncumbrance.total`)

Membership cleanup is blocked while `moduleEncumbered > 0`.

---

## Worked Examples

### Example 1: Basic Encumber and AUM Accrual

**Scenario:** Alice encumbers 365,000 units at 1% AUM (100 bps) and one day elapses.

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

**Step 3: Day 2 Accrual**
```
epochs = 1
feeDue = (365,000 × 100 × 1) / (365 × 10,000) = 10
chargeablePrincipal = min(1,000,000, 365,000) = 365,000
charged = min(10, 365,000) = 10
shortfall = 0

Principal after: 999,990
totalDeposits after: 999,990
Treasury receives: 10 (routed via LibFeeTreasury)
```

### Example 2: Delinquency and Deactivation

**Scenario:** Bob has only 10 units of principal but 1,095,000 encumbered at 1% AUM. Grace epochs = 2.

**Day 1: First Touch**
```
lastAumEpoch initialized, no charge
```

**Day 2: First Real Accrual**
```
feeDue = (1,095,000 × 100 × 1) / (365 × 10,000) = 30
chargeablePrincipal = min(10, 1,095,000) = 10
charged = 10
shortfall = 20
→ Tuple marked delinquent, delinquentSince = Day 2 epoch
→ Module NOT yet deactivated (grace window just started)
```

**Day 3: Second Delinquent Accrual**
```
feeDue = 30
chargeablePrincipal = min(0, 1,095,000) = 0
charged = 0
shortfall = 30
→ Still delinquent, delinquentEpochs = 1
→ Module NOT yet deactivated (1 < 2 grace epochs)
```

**Day 4: Grace Window Breached**
```
feeDue = 30
charged = 0
shortfall = 30
delinquentEpochs = 2 (equals graceEpochs)
→ module.inactive = true (permanent, global)
→ No new encumbrance allowed on ANY tuple for this module
→ Unencumber and poke remain callable for all tuples
```

### Example 3: Cross-User Blast Radius

**Scenario:** Module 1 has two users. User A triggers deactivation. User B is healthy.

**After Deactivation:**
```
User A: delinquent, module globally inactive
User B: healthy, 1,000 principal, 365,000 encumbered

User B cannot call encumberPosition (ModuleInactive)
User B CAN call unencumberPosition (always allowed)
User B CAN call pokeModuleAum (always allowed)
User B's AUM continues to accrue normally after deactivation
```

### Example 4: ACI Pause Behavior

**Scenario:** Module ACI is paused globally.

```
// Encumber with ACI paused → no Active Credit increase
encumberPosition(tokenId, poolId, moduleId, 100);
activeCreditPrincipalTotal = 0  // unchanged

// Unencumber with ACI paused → Active Credit STILL decreases
unencumberPosition(tokenId, poolId, moduleId, 50);
activeCreditPrincipalTotal = -50  // decreased regardless of pause
```

---

## Error Reference

### Module Errors

| Error | Cause |
|-------|-------|
| `ModuleNotFound(uint256 moduleId)` | Module ID doesn't exist or is zero |
| `ModulePausedError(uint256 moduleId)` | Attempting to encumber against a paused module |
| `ModuleInactive(uint256 moduleId)` | Attempting to encumber or unpause a permanently deactivated module |
| `ModuleRegistrationDisabled()` | Non-governance registration when `moduleCreationFee == 0` |
| `ModuleIncorrectFee(uint256 sent, uint256 required)` | ETH value mismatch during registration |
| `NotModuleOwner(uint256 moduleId, address caller)` | Caller is not the module owner (and not governance where applicable) |
| `InvalidModuleOwner(address owner)` | Attempting to set module owner to `address(0)` |
| `ModuleAumOutOfBounds(uint16 bps, uint16 minBps, uint16 maxBps)` | AUM bps outside configured min/max bounds |
| `InvalidAumFeeBounds()` | `minBps > maxBps` in `setModuleAumBounds` |

### Shared Errors

| Error | Cause |
|-------|-------|
| `InsufficientUnencumberedPrincipal(uint256 requested, uint256 available)` | Encumber amount exceeds available principal |
| `EncumbranceUnderflow(uint256 amount, uint256 current)` | Unencumber amount exceeds current encumbrance |
| `NotNFTOwner(address caller, uint256 tokenId)` | Caller doesn't own the Position NFT |
| `TreasuryNotSet()` | Treasury address is zero during fee-based registration |
| `PoolCreationFeeTransferFailed()` | ETH transfer to treasury failed during registration |

---

## Events

### Registry Events

```solidity
event ModuleRegistered(
    uint256 indexed moduleId,
    address indexed owner,
    bytes32 metadataHash,
    uint16 aumBps
);

event ModuleOwnerUpdated(
    uint256 indexed moduleId,
    address indexed oldOwner,
    address indexed newOwner
);

event ModulePauseUpdated(
    uint256 indexed moduleId,
    bool paused
);

event ModuleAciPauseToggled(bool paused);
```

### AUM Events

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

### Encumbrance Events (LibEncumbrance)

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

---

## Security Considerations

### 1. Reservation-Only Model

Encumber/unencumber does not transfer assets. Principal stays in pool custody. This eliminates reentrancy vectors from asset movement during encumbrance operations.

### 2. Namespace Isolation

Module and index encumbrance are tracked independently in `LibEncumbrance`. Mutations to one namespace cannot affect the other:

```solidity
// Module operations touch moduleEncumbered + encumberedByModule
// Index operations touch indexEncumbered + encumberedByIndex
// Neither can corrupt the other's storage
```

### 3. Unified Solvency

All encumbrance types (direct, index, module) are summed in `LibEncumbrance.total()` for solvency checks. No path can over-commit principal by ignoring a namespace.

### 4. Reentrancy Protection

All state-changing functions on `ModuleGatewayFacet` use the `nonReentrant` modifier.

### 5. Accrue-Before-Mutate

Both `encumberPosition` and `unencumberPosition` accrue tuple AUM before modifying encumbrance. This prevents fee avoidance by rapidly encumbering/unencumbering around epoch boundaries.

### 6. Mid-Call Deactivation Guard

`encumberPosition` re-checks `module.inactive` after AUM accrual. If accrual triggers deactivation (grace window breached), the encumber call reverts with `ModuleInactive` rather than allowing new encumbrance on a just-deactivated module.

### 7. Membership Cleanup Blocking

Pool membership cannot be cleared while `moduleEncumbered > 0`. This prevents orphaned encumbrance state.

### 8. Native Pool Balance Invariant

Native pools maintain `nativeTrackedTotal <= address(this).balance` through AUM charging paths. The treasury-transfer portion is deducted from both `trackedBalance` and `nativeTrackedTotal` atomically.

### 9. Access Control

| Function | Access |
|----------|--------|
| Module registration | Governance (free) or public (with fee) |
| Module ownership transfer | Current module owner only |
| Pause/unpause | Module owner or governance |
| Governance knobs | Owner or timelock only |
| Encumber | Position NFT owner only (strict owner check) |
| Unencumber | Position NFT owner only (strict owner check) |
| Poke | Anyone |

---

## Appendix: Correctness Properties

### Property 1: Reservation Availability Conservation
For any position after encumber/unencumber:
```
moduleEncumberedForModule + availablePrincipal ≤ principal
```

### Property 2: AUM Base Isolation
Fee due depends only on the tuple's encumbered amount, not on total principal:
```
feeDue = f(encumberedByModule[positionKey][poolId][moduleId], aumBps, epochs)
```

### Property 3: Epoch Determinism
Accruing N epochs in one call produces the same principal result as accruing 1 epoch N times:
```
accrue(N epochs) ≡ accrue(1 epoch) × N  (when no shortfall)
```

### Property 4: No Retroactive First Touch
First accrual never charges fees regardless of elapsed time:
```
if (lastAumEpoch == 0) → charged = 0
```

### Property 5: ACI Pause Gates Increases Only
When `moduleAciPaused == true`:
```
encumber → activeCreditPrincipalTotal unchanged
unencumber → activeCreditPrincipalTotal decreased
```

### Property 6: Namespace Isolation
Module encumbrance mutations do not affect index encumbrance and vice versa:
```
encumberModule(key, pool, mod, amt) → indexEncumbered unchanged
encumberIndex(key, pool, idx, amt) → moduleEncumbered unchanged
```

### Property 7: Native Tracked Invariant
For native pools after any number of AUM accruals:
```
nativeTrackedTotal ≤ address(this).balance
```

### Property 8: Global Deactivation Blast Radius
One delinquent tuple deactivates the module globally, but other tuples continue accruing:
```
module.inactive = true → encumber blocked for ALL tuples
                       → poke/unencumber/accrual still work for ALL tuples
```

---

## Test Coverage

Module behavior is validated by:

- `test/modules/ModuleRegistryFacet.t.sol`
- `test/modules/ModuleGatewayFacet.t.sol`
- `test/modules/ModuleViewFacet.t.sol`
- `test/modules/ModuleEncumbranceProperty.t.sol`
- `test/libraries/LibModuleAum.t.sol`
- `test/libraries/LibModuleEncumbrance.t.sol`
- `test/libraries/LibEncumbranceModuleNamespace.t.sol`
- `test/root/LibSolvencyChecksProperty.t.sol`

---

**Document Version:** 1.1 (Updated for unified encumbrance integration)
