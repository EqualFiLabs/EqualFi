# Public Module Encumbrance - Design Document

**Version:** 0.1

---

## Table of Contents

1. [Overview](#overview)
2. [Goals](#goals)
3. [Non-Goals](#non-goals)
4. [Design Principles](#design-principles)
5. [Architecture](#architecture)
6. [Data Model](#data-model)
7. [Lifecycle](#lifecycle)
8. [Fee Model](#fee-model)
9. [Encumbrance and Write-Down](#encumbrance-and-write-down)
10. [Module Integration Guide](#module-integration-guide)
11. [Events](#events)
12. [Security Considerations](#security-considerations)
13. [Testing and Validation](#testing-and-validation)
14. [Open Questions](#open-questions)

---

## Overview

This document proposes a permissionless module interface that allows external protocols to build standalone products (e.g., prediction markets) while consuming Equalis liquidity through the centralized encumbrance system. The objective is to avoid liquidity fragmentation: deposits remain on-platform, and modules must use encumbered principal rather than withdrawing funds from pools.

Greenfield assumption: this is a new subsystem in local dev, so no backwards compatibility or migrations are required.

## Goals

- Enable permissionless module registration with a configurable creation fee.
- Allow modules to encumber pool principal from a Position NFT without withdrawing liquidity.
- Ensure encumbered principal cannot be double-used and is always reflected in solvency checks.
- Provide a write-down mechanism: if module assets are lost, the position principal is reduced on unencumber.
- Route protocol fees back through the existing fee router (ACI/FI/Treasury).

## Non-Goals

- Guaranteeing module-level profitability or solvency.
- Enforcing any business logic inside modules beyond balance accounting.
- Providing oracle-based pricing or risk controls (modules handle their own logic).

## Design Principles

- Encumbrance is the source of truth for reserved capital.
- Losses are position-local (no socialized losses across a pool).
- Write-downs are deterministic and based on actual on-chain balances at finalization.
- Protocol fees are centralized through `LibFeeRouter` and `LibFeeIndex`.
- Module registration is permissionless but can be disabled by setting a creation fee of zero.

## Architecture

### Contract/Ffacet Layout

```
src/modules/
├── ModuleRegistryFacet.sol     # Permissionless module registration + config
├── ModuleGatewayFacet.sol      # Encumber/unencumber + settlement entry points
├── ModuleViewFacet.sol         # Read-only queries

src/libraries/
├── LibModuleRegistry.sol       # Storage + events for modules
├── LibModuleEncumbrance.sol    # Encumbrance wrapper for modules
├── LibModuleSettlement.sol     # Shared write-down helper
```

### Core Dependencies

- `LibEncumbrance`: central encumbrance storage.
- `LibSolvencyChecks`: available principal calculation.
- `LibActiveCreditIndex`: encumbrance-aware yield accrual.
- `LibFeeIndex` + `LibFeeRouter`: fee routing and yield distribution.

### Encumbrance Tracking

Two approaches are viable:

1) **Generalize existing index encumbrance**
   - Rename `indexEncumbered` and `encumberedByIndex` to module terminology.
   - Use a single `moduleId` namespace for all third-party modules (including EqualIndex).

2) **Add module encumbrance alongside index encumbrance**
   - Keep EqualIndex isolated and introduce `moduleEncumbered` + `encumberedByModule`.
   - Avoids ambiguity but adds storage.

Given greenfield constraints, the recommended approach is (1) for simplicity, with a clear naming update.

### Module Registration

Permissionless module registration mirrors the EqualIndex creation fee pattern:

- `moduleCreationFee` stored in `LibAppStorage` (or a dedicated module config).
- If fee is `0`, permissionless registration is disabled.
- Non-governance registrants must pay exact fee, routed to the treasury.

## Data Model

### Module

```solidity
struct Module {
    address owner;          // Creator or admin
    address adapter;        // Optional external module contract
    bytes32 metadataHash;   // Off-chain metadata reference
    uint16 feeBps;          // Optional protocol fee for module actions
    bool paused;
}
```

### Module Position State

```solidity
struct ModulePositionState {
    uint256 encumbered;     // Principal encumbered by module
    uint256 escrowed;       // Module-held balance (internal escrow or external)
}
```

### Core Mappings

```solidity
mapping(uint256 => Module) modules; // moduleId => module config
mapping(bytes32 => mapping(uint256 => mapping(uint256 => ModulePositionState))) moduleState;
// positionKey => poolId => moduleId => state
```

The encumbered amount should also be stored in `LibEncumbrance` to ensure `LibSolvencyChecks.calculateAvailablePrincipal` reflects module usage.

## Lifecycle

### 1) Module Registration

- Caller provides `metadataHash`, optional `adapter` address, and fee configuration.
- If caller is not governance, `msg.value` must equal `moduleCreationFee`.
- `moduleId` is incremented and stored.

### 2) Encumber (Open Module Position)

Inputs: `positionId`, `poolId`, `moduleId`, `amount`, optional `permit`/signature.

Steps:
- Verify position ownership or valid permit.
- Ensure module not paused.
- Check available principal via `LibSolvencyChecks.calculateAvailablePrincipal`.
- Settle `LibFeeIndex` and `LibActiveCreditIndex` for the position.
- `LibModuleEncumbrance.encumber(positionKey, poolId, moduleId, amount)`.
- Increment `moduleState[positionKey][poolId][moduleId].encumbered` and `escrowed`.
- Apply `LibActiveCreditIndex.applyEncumbranceIncrease` if encumbrance should count toward ACI.

### 3) Module Operations

Module business logic is external to the core. The module may:

- Use internal balances tracked in `moduleState` (no token transfers), or
- Request asset movement to a registered `adapter` contract (external escrow).

In either case, the core maintains the encumbered amount for solvency.

### 4) Finalize (Unencumber + Write-Down)

Inputs: `positionId`, `poolId`, `moduleId`, `expectedEncumbered`.

Steps:
- Settle `LibFeeIndex` and `LibActiveCreditIndex` for the position.
- Determine `currentEscrowed` from the module escrow balance:
  - Internal mode: `moduleState[positionKey][poolId][moduleId].escrowed`.
  - External mode: `IERC20(asset).balanceOf(adapter)` or an adapter-specific accounting method.
- Apply a principal delta using the same pattern as AMM auctions:
  - If `currentEscrowed < expectedEncumbered`, write down principal.
  - If `currentEscrowed > expectedEncumbered`, credit principal.
- Update `pool.totalDeposits` and `pool.trackedBalance` to match the delta.
- `LibModuleEncumbrance.unencumber(positionKey, poolId, moduleId, expectedEncumbered)`.
- Decrease ACI encumbrance using `LibActiveCreditIndex.applyEncumbranceDecrease`.

## Fee Model

### Registration Fee

- `moduleCreationFee` in app config.
- `0` disables permissionless registration.
- Paid to treasury on creation.

### Module Action Fees

Two optional fee layers:

1) **Protocol Fee** (configurable per module)
   - Split through `LibFeeRouter` into Treasury / ACI / FeeIndex.

2) **Module-Specific Fees**
   - Defined by the module and handled within module logic.
   - If fees are paid in underlying assets, they can be routed via `LibFeeRouter` for protocol capture.

## Encumbrance and Write-Down

The write-down behavior follows the AMM Auction model:

- Encumbrance reserves principal while the module is active.
- On finalization, the core compares the actual escrow balance to the encumbered amount.
- The position is adjusted by the delta (gain or loss).

Reference behavior: `AmmAuctionFacet._applyPrincipalDelta`.

Pseudo-flow:

```solidity
LibFeeIndex.settle(pid, positionKey);
LibActiveCreditIndex.settle(pid, positionKey);

uint256 current = moduleEscrowBalance(...);
uint256 initial = moduleState[positionKey][pid][moduleId].encumbered;

_applyPrincipalDelta(pid, pool, positionKey, current, initial);
LibModuleEncumbrance.unencumber(positionKey, pid, moduleId, initial);
```

## Module Integration Guide

### Registration

1) Call `registerModule(metadataHash, adapter, feeBps)` with `msg.value = moduleCreationFee`.
2) Receive a `moduleId` for future calls.

### Encumber

1) Obtain user authorization for the Position NFT (ownership or permit).
2) Call `encumberPosition(positionId, poolId, moduleId, amount, data)`.

### Operate

- Use internal accounting for module balances, or
- Request asset transfers to the registered `adapter` contract if needed.

### Finalize

1) Ensure module state is finalized and balances are returned (if external).
2) Call `finalizePosition(positionId, poolId, moduleId)`.
3) The core applies write-downs and releases encumbrance.

## Events

Suggested events:

- `ModuleRegistered(uint256 moduleId, address owner, address adapter, bytes32 metadataHash)`
- `ModulePaused(uint256 moduleId, bool paused)`
- `ModuleEncumbered(bytes32 positionKey, uint256 poolId, uint256 moduleId, uint256 amount)`
- `ModuleFinalized(bytes32 positionKey, uint256 poolId, uint256 moduleId, uint256 initial, uint256 final)`

## Native ETH Support

The module encumbrance system supports native ETH (represented by `address(0)`) as pool underlying assets, enabling modules to encumber ETH liquidity without WETH wrapping.

### Native ETH Pool Characteristics

Native ETH pools use `address(0)` as the underlying asset. The system maintains a global `nativeTrackedTotal` in AppStorage that tracks the sum of `trackedBalance` across all native ETH pools.

### Currency Operations

All token operations use the `LibCurrency` helper library:

| Operation | Native ETH Behavior | ERC20 Behavior |
|-----------|---------------------|----------------|
| `pull()` | Accounting-only (no transfer), validates against `nativeAvailable`, updates `nativeTrackedTotal` | `safeTransferFrom` with balance delta measurement |
| `transfer()` | Low-level `call{value: amount}("")` | `safeTransfer` |
| `balanceOfSelf()` | Returns `address(this).balance` | Returns `balanceOf(address(this))` |
| `isNative()` | Returns `true` for `address(0)` | Returns `false` |

### Encumbrance with Native ETH

When encumbering principal from a native ETH pool:

1. The module gateway validates available principal via `LibSolvencyChecks.calculateAvailablePrincipal`
2. Encumbrance is recorded in `LibEncumbrance` (asset-agnostic)
3. No token transfer occurs; the ETH remains in the contract
4. `nativeTrackedTotal` is not modified during encumbrance (only on actual ETH movement)

### External Escrow with Native ETH

If a module uses external escrow (adapter contract) with native ETH:

1. ETH is transferred to the adapter via `LibCurrency.transfer`
2. `pool.trackedBalance` is decremented
3. `nativeTrackedTotal` is decremented
4. On finalization, the adapter returns ETH to the core contract
5. Write-down logic compares actual balance to expected encumbered amount

### Finalization with Native ETH

When finalizing a module position with native ETH:

```solidity
// Determine current escrowed balance
uint256 currentEscrowed = moduleEscrowBalance(...);
uint256 initial = moduleState[positionKey][pid][moduleId].encumbered;

// Apply principal delta (gain or loss)
_applyPrincipalDelta(pid, pool, positionKey, currentEscrowed, initial);

// Update native tracking if applicable
if (LibCurrency.isNative(pool.underlying)) {
    // Adjust nativeTrackedTotal based on delta
}

// Release encumbrance
LibModuleEncumbrance.unencumber(positionKey, pid, moduleId, initial);
```

### Flash Accounting Pattern

Native ETH operations follow a flash accounting pattern:

1. All module gateway functions reject nonzero `msg.value` via `LibCurrency.assertZeroMsgValue()`
2. Native ETH must be pre-deposited to the contract before operations
3. `nativeAvailable = address(this).balance - nativeTrackedTotal` represents unallocated ETH
4. Operations consume from `nativeAvailable` and update `nativeTrackedTotal`

---

## Security Considerations

- **Permissionless registration**: mitigate spam with a non-zero creation fee.
- **Module pause**: governance should be able to pause a module in emergencies.
- **Reentrancy**: module gateway methods should be nonReentrant.
- **Balance integrity**: use `trackedBalance` invariants and check actual token balances on external escrow finalization.
- **User consent**: require explicit ownership or signed permit for encumbrance.
- **Native ETH safety**: Native ETH operations include:
  - `nonReentrant` modifier on all functions that send ETH
  - Rejection of unexpected `msg.value` with `UnexpectedMsgValue` error
  - Failed ETH transfers revert with `NativeTransferFailed(address to, uint256 amount)`
  - Global `nativeTrackedTotal` prevents double-spending across native ETH pools
  - Flash accounting pattern ensures ETH is pre-deposited before consumption

## Testing and Validation

- Unit tests for encumber/unencumber behavior across multiple modules.
- Write-down tests where `currentEscrowed < encumbered` and vice versa.
- Fee routing tests ensuring ACI/FI/Treasury splits remain correct.
- Integration test that mirrors the AMM auction close flow for module finalization.

## Open Questions

- Should module encumbrance count toward active credit yield by default?
- Should module registration allow free creation for governance only?
- What is the recommended metadata format (URI vs hash)?
- Are external escrow transfers permitted, or should all modules operate in-core only?

