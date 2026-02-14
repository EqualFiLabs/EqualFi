# Public Module Encumbrance - Design Document

**Version:** 0.3

---

## Overview

This document defines V1 module encumbrance for Equalis with reservation semantics and mandatory module AUM.

V1 rules:
- Encumbered principal is reserved and non-reusable.
- Encumbrance changes only via `encumber` and `unencumber`.
- No generic escrow mutation path.
- Module AUM accrues on tuple encumbered amount only (`positionKey/poolId/moduleId`).
- AUM routes through standard protocol fee rails (Treasury/ACI/FI split via fee router path).

## Goals

- Permissionless module registration with configurable creation fee.
- Position-scoped module encumbrance that integrates with solvency checks.
- Mandatory module AUM with deterministic 1-day epoch accrual.
- Permissionless poke function for liveness.
- Permanent module deactivation safeguard for catastrophic shortfall.

## Non-Goals

- External adapter escrow in V1.
- Arbitrary module escrow accounting.
- Oracle-based module risk controls.

## Architecture

### Facets/Libraries

```
src/modules/
├── ModuleRegistryFacet.sol
├── ModuleGatewayFacet.sol
├── ModuleViewFacet.sol

src/libraries/
├── LibModuleRegistry.sol
├── LibModuleEncumbrance.sol
├── LibModuleAum.sol
```

### Core Integrations

- `LibEncumbrance`: add `moduleEncumbered` and `encumberedByModule`.
- `LibSolvencyChecks`: include module encumbrance in available principal.
- `LibFeeTreasury`/`LibFeeRouter`: route module AUM with standard splits.
- `LibActiveCreditIndex`: module encumbrance increase/decrease, gated by global ACI pause for increases.
- `LibPoolMembership`: block cleanup while module encumbrance exists.

## Data Model

### Module

```solidity
struct Module {
    address owner;      // EOA or contract
    bytes32 metadataHash;
    bool paused;
    bool inactive;      // terminal
    uint16 aumBps;      // governance-controlled
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

mapping(bytes32 => mapping(uint256 => mapping(uint256 => TupleAumState))) tupleAum;
// positionKey => poolId => moduleId => state
```

### Encumbrance Extension

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

## Lifecycle

### 1) Register Module

- `registerModule(metadataHash)`.
- Non-governance pays exact `moduleCreationFee`; governance bypass allowed.
- Fee routed to treasury.
- Module owner set to caller.

### 2) Encumber

- Validate module exists, not paused, not inactive.
- Validate position authorization.
- Accrue tuple AUM first.
- Validate available principal.
- Increase tuple module encumbrance.
- Apply ACI increase only when `moduleAciPaused == false`.

### 3) Unencumber

- Validate module exists.
- Validate position authorization.
- Accrue tuple AUM first.
- Decrease tuple module encumbrance.
- Apply ACI decrease.

Important: unencumber remains callable even if module is paused or inactive.

### 4) Poke AUM (Permissionless)

- Anyone calls `pokeModuleAum(positionId,poolId,moduleId)`.
- Accrues tuple AUM and updates delinquency/deactivation state.
- No position ownership required.

## Module AUM

### Epoch Model

- Epoch length: `1 days`.
- Triggered on `encumber`, `unencumber`, and `poke`.
- First touch initializes `lastAumEpoch` and does not retro-charge.

### Formula

```solidity
epochs = (block.timestamp - lastAumEpoch) / 1 days;
feeDue = encumbered * aumBps * epochs / (365 * 10_000);
```

where `encumbered = encumberedByModule[positionKey][poolId][moduleId]`.

### Charge + Route

- `chargeablePrincipal = min(userPrincipal[positionKey], encumbered)`.
- If `feeDue <= chargeablePrincipal`:
  - debit `userPrincipal` and `totalDeposits` by `feeDue`.
  - route via `LibFeeTreasury.accrueWithTreasuryFromPrincipal(..., MODULE_AUM_SOURCE)`.
- Advance epoch checkpoint by elapsed full epochs.

## Deactivation Safeguard

If `feeDue > chargeablePrincipal`:

1. Charge up to `chargeablePrincipal` if nonzero.
2. Mark tuple delinquent and emit delinquency event.
3. If delinquency persists for `deactivationGraceEpochs` and shortfall remains on later accrual, set `module.inactive = true` permanently.
4. Emit `ModulePermanentlyDeactivated`.

Inactive module behavior:
- New `encumber` reverts forever.
- No reactivation path.
- `unencumber` and `poke` remain callable.
- No future module-driven ACI increases.

## ACI Policy

- Per-module `aciEligible` is removed.
- Global governance/admin switch: `setModuleAciPaused(bool)`.
- When paused: module encumbrance increases do not add ACI exposure.
- Decreases still apply on unencumber.

## Governance/Admin Knobs

- `setModuleCreationFee(uint256)`
- `setDefaultModuleAumBps(uint16)`
- `setModuleAumBps(uint256 moduleId, uint16)`
- `setModuleAumBounds(uint16 minBps, uint16 maxBps)`
- `setModuleDeactivationGraceEpochs(uint16)`
- `setModuleAciPaused(bool)`

AUM setters must enforce bounds.

## Security Considerations

- Permissionless poke must not become a free deactivation grief vector:
  - deactivation requires persisted delinquency through grace window.
- Pause/inactive states must never trap user exits.
- Namespace isolation between module and index encumbrance is mandatory.
- Native invariant must hold: `nativeTrackedTotal <= address(this).balance`.

## Testing and Validation

- Unit tests:
  - registration and owner/admin controls,
  - AUM bounds and ACI pause control,
  - first-touch no-retro-charge,
  - unencumber allowed while paused/inactive,
  - delinquency and terminal deactivation.
- Property tests:
  - principal availability conservation,
  - deterministic epoch accrual,
  - AUM base isolation to tuple encumbrance,
  - ACI pause gates increases only,
  - module/index namespace isolation,
  - native tracked invariant.

## Open Questions

- Should grace epochs be global-only or allow per-module override?
- Should delinquency view expose cumulative shortfall history or only latest shortfall?
