# Module Encumbrance - Implemented Specification

**Version:** 1.0  
**Status:** Implemented

## Overview

Module encumbrance is live as a reservation system over Position NFT principal. A reservation is tracked per tuple:

- `positionKey`
- `poolId`
- `moduleId`

Reserved principal remains in protocol custody and is non-reusable while encumbered. The system also applies a tuple-scoped AUM fee that accrues in whole-day epochs.

## Contract Surface

### Facets

| Facet | Responsibility | Main Functions |
|---|---|---|
| `ModuleRegistryFacet` | Module registration and governance controls | `registerModule`, `setModuleOwner`, `pauseModule`, `unpauseModule`, `setModuleCreationFee`, `setDefaultModuleAumBps`, `setModuleAumBps`, `setModuleAumBounds`, `setModuleDeactivationGraceEpochs`, `setModuleAciPaused` |
| `ModuleGatewayFacet` | Encumber/unencumber execution and AUM poke | `encumberPosition`, `unencumberPosition`, `pokeModuleAum` |
| `ModuleViewFacet` | Read-only module, encumbrance, and AUM state | `getModule`, `getModuleEncumbrance`, `getModuleEncumbranceForModule`, `getModuleAumState`, `getModuleAumConfig`, `isModuleAciPaused` |

### Core Libraries

| Library | Responsibility |
|---|---|
| `LibModuleRegistry` | Module config storage, tuple AUM state storage, events |
| `LibModuleEncumbrance` | Thin wrapper around module encumbrance getters/mutations |
| `LibModuleAum` | Epoch accrual, principal charging, delinquency and deactivation |
| `LibEncumbrance` | Unified encumbrance storage, includes `moduleEncumbered` and per-module bucket |
| `LibSolvencyChecks` | Available principal calculation used by module encumbering paths |

## Data Model

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

### Global Module Config

```solidity
uint256 moduleCreationFee;
uint16 defaultModuleAumBps;
uint16 minModuleAumBps;
uint16 maxModuleAumBps;
uint16 deactivationGraceEpochs;
bool moduleAciPaused;
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

### Encumbrance Storage Extension

```solidity
struct Encumbrance {
    uint256 directLocked;
    uint256 directLent;
    uint256 directOfferEscrow;
    uint256 indexEncumbered;
    uint256 moduleEncumbered;
}

mapping(bytes32 => mapping(uint256 => mapping(uint256 => uint256))) encumberedByModule;
```

## Registration and Administration

### `registerModule(metadataHash)`

- Module IDs are monotonic and start at `1`.
- Governance callers (`owner` or `timelock`) must send `0` ETH.
- Non-governance callers must send exactly `moduleCreationFee`.
- If `moduleCreationFee == 0`, non-governance registration is disabled.
- Public registration fee is transferred to treasury.
- New modules initialize with:
  - `owner = msg.sender`
  - `paused = false`
  - `inactive = false`
  - `aumBps = defaultModuleAumBps`

### Ownership and Pause Controls

- `setModuleOwner`: only current module owner.
- `pauseModule` and `unpauseModule`: module owner or governance.
- Inactive modules cannot be unpaused.

### Governance Knobs

- `setModuleCreationFee`
- `setDefaultModuleAumBps`
- `setModuleAumBps`
- `setModuleAumBounds`
- `setModuleDeactivationGraceEpochs`
- `setModuleAciPaused`

`setDefaultModuleAumBps` and `setModuleAumBps` enforce configured min/max bounds.

## Encumbrance Lifecycle

### `encumberPosition(positionId, poolId, moduleId, amount)`

Execution order:

1. Require module exists and is not paused/inactive.
2. Require caller owns `positionId`.
3. Require pool is initialized and the position is already a member of the pool.
4. Accrue tuple AUM before mutating encumbrance.
5. Check available principal with `LibSolvencyChecks.calculateAvailablePrincipal(...)`.
6. Increase tuple module encumbrance.
7. Increase Active Credit encumbrance weight unless global module ACI pause is enabled.

### `unencumberPosition(positionId, poolId, moduleId, amount)`

Execution order:

1. Require module exists.
2. Require caller owns `positionId`.
3. Require pool initialized and position membership.
4. Accrue tuple AUM before mutation.
5. Decrease tuple module encumbrance (underflow-protected).
6. Always apply Active Credit decrease.

`unencumberPosition` is allowed even if the module is paused or inactive.

### `pokeModuleAum(positionId, poolId, moduleId)`

- Permissionless.
- Requires only: module exists, position token exists, pool initialized.
- No ownership or membership requirement.
- Runs tuple AUM accrual without mutating encumbrance.

## AUM Accrual Semantics

### Epoching

- Epoch length: `1 days`.
- Epoch anchor: `currentEpochStart = floor(block.timestamp / 1 days) * 1 days`.
- Pending epochs count only whole elapsed days.

### First Touch Behavior

If `lastAumEpoch == 0`, accrual sets `lastAumEpoch = currentEpochStart` and returns with no fee charged.

### Fee Formula

```solidity
epochs = (currentEpochStart - lastAumEpoch) / 1 days;
feeDue = (encumbered * aumBps * epochs) / (365 * 10_000);
```

Where:

- `encumbered = encumberedByModule[positionKey][poolId][moduleId]`
- `aumBps = module.aumBps` unless `module.aumBps == 0`, then `defaultModuleAumBps`

### Charging and Routing

For each accrual:

1. `LibFeeIndex.settle(poolId, positionKey)` is called first.
2. `chargeablePrincipal = min(userPrincipal[positionKey], encumbered)`.
3. `charged = min(feeDue, chargeablePrincipal)`.
4. Principal accounting decreases:
   - `userPrincipal -= charged`
   - `totalDeposits -= charged`
5. Fee routing uses `LibFeeTreasury.accrueWithTreasuryFromPrincipal(..., MODULE_AUM_FEE)`.
6. `trackedBalance` and `nativeTrackedTotal` are reduced by the treasury-transfer portion only.

## Delinquency and Permanent Deactivation

If `feeDue > charged`, the tuple has shortfall:

- Tuple state is marked delinquent.
- `delinquentSince` is set on first delinquent accrual.
- `lastShortfall` is updated.

If shortfall persists on subsequent delinquent accruals and elapsed delinquent epochs meet `deactivationGraceEpochs`, the module is permanently deactivated:

- `module.inactive = true` (global module flag, not tuple-local).
- No reactivation path exists.
- New encumbrance is blocked forever.
- Unencumber and poke remain callable.

If a later accrual has no shortfall, tuple delinquency state is cleared.

## Active Credit Policy

- Module encumbrance increases contribute to Active Credit only when `moduleAciPaused == false`.
- Module encumbrance decreases always reduce Active Credit principal.
- This is a global switch, not per-module.

## Current Integration Boundary

Module encumbrance is included in available-principal math used by:

- `ModuleGatewayFacet.encumberPosition`
- `EqualIndexPositionFacet.mintFromPosition`
- `LibSolvencyChecks.calculateAvailablePrincipal`

Legacy paths that still compute encumbrance as direct + index (without module) include:

- `PositionManagementFacet.withdrawFromPosition`
- `PositionManagementFacet.closePoolPosition`
- `LendingFacet` collateral checks
- `PenaltyFacet` collateral checks
- `PositionViewFacet.getPositionEncumbrance`
- `EnhancedLoanViewFacet` collateral views

Operationally, module encumbrance is fully tracked and queryable through module-specific views, but those legacy read/withdraw paths do not yet consume the module bucket.

## View APIs

### Module Metadata

- `getModule(moduleId)` -> owner, metadata hash, paused, inactive, AUM bps.

### Encumbrance

- `getModuleEncumbrance(positionId, poolId)` -> total module encumbrance for position/pool.
- `getModuleEncumbranceForModule(positionId, poolId, moduleId)` -> tuple amount.

### AUM State

- `getModuleAumState(...)` returns:
  - `lastAccruedEpoch`
  - `pendingEpochs_`
  - `delinquent`
  - `delinquentSince`
  - `lastShortfall`
  - `graceEpochs`
  - `delinquentEpochs_`
  - `graceSatisfied`

### Config

- `getModuleAumConfig()` -> default/min/max AUM bps and grace epochs.
- `isModuleAciPaused()` -> global ACI pause for module encumbrance increases.

## Events

### Registry and AUM

- `ModuleRegistered`
- `ModuleOwnerUpdated`
- `ModulePauseUpdated`
- `ModuleAumAccrued`
- `ModuleAumDelinquent`
- `ModulePermanentlyDeactivated`
- `ModuleAciPauseToggled`

### Encumbrance

- `ModuleEncumbranceIncreased`
- `ModuleEncumbranceDecreased`

## Key Errors

- `ModuleNotFound`
- `ModulePausedError`
- `ModuleInactive`
- `ModuleRegistrationDisabled`
- `ModuleIncorrectFee`
- `NotModuleOwner`
- `ModuleAumOutOfBounds`
- `InvalidAumFeeBounds`
- `InsufficientUnencumberedPrincipal`
- `EncumbranceUnderflow`

Common shared errors can also bubble from ownership, pool initialization, and membership checks.

## Security and Invariants

- Reservation-only: encumber/unencumber does not transfer assets by itself.
- Namespace isolation: module and index encumbrance are tracked independently.
- Membership cleanup is blocked while `moduleEncumbered > 0`.
- Native pools maintain `nativeTrackedTotal <= address(this).balance` in tested module-AUM paths.

## Test Coverage (Current Suite)

Module behavior is validated by:

- `test/modules/ModuleRegistryFacet.t.sol`
- `test/modules/ModuleGatewayFacet.t.sol`
- `test/modules/ModuleViewFacet.t.sol`
- `test/modules/ModuleEncumbranceProperty.t.sol`
- `test/libraries/LibModuleAum.t.sol`
- `test/libraries/LibModuleEncumbrance.t.sol`
- `test/libraries/LibEncumbranceModuleNamespace.t.sol`
- `test/root/LibSolvencyChecksProperty.t.sol`
