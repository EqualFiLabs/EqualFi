# Managed Pool System - Design Document

**Version:** 1.0

---

## Table of Contents

1. [Overview](#overview)
2. [How It Works](#how-it-works)
3. [Architecture](#architecture)
4. [Pool Creation](#pool-creation)
5. [Manager Operations](#manager-operations)
6. [Whitelist System](#whitelist-system)
7. [Configuration Management](#configuration-management)
8. [Fee System and System Share](#fee-system-and-system-share)
9. [Manager Transfer and Renunciation](#manager-transfer-and-renunciation)
10. [Data Models](#data-models)
11. [View Functions](#view-functions)
12. [Integration Guide](#integration-guide)
13. [Worked Examples](#worked-examples)
14. [Error Reference](#error-reference)
15. [Events](#events)
16. [Security Considerations](#security-considerations)

---

## Overview

Managed pools extend the Equalis self-secured credit pool system with delegated administration. A pool manager — the address that creates the pool — gains mutable control over pool parameters, whitelist gating, and fee configuration. This enables institutional operators, DAOs, and strategy vaults to run curated lending pools on top of the same deterministic, oracle-free infrastructure used by permissionless pools.

### Key Characteristics

| Feature | Description |
|---------|-------------|
| **Delegated Administration** | A designated manager controls pool parameters post-creation |
| **Whitelist Gating** | Optional position-level access control, enabled by default |
| **Mutable Configuration** | LTV, fees, thresholds, and caps adjustable by manager |
| **System Share Routing** | Configurable portion of fees routed to the base permissionless pool |
| **Auto Base Pool Creation** | Automatically creates a base permissionless pool if one doesn't exist for the underlying asset |
| **Manager Lifecycle** | Manager can be transferred to a new address or permanently renounced |
| **Separate Creation Fee** | Distinct `managedPoolCreationFee` from unmanaged pool creation |
| **Same Core Mechanics** | All self-secured credit, penalty, flash loan, and fee index mechanics apply unchanged |

### System Participants

| Role | Description |
|------|-------------|
| **Manager** | Address that created the pool; controls configuration and whitelist |
| **Whitelisted User** | Position NFT holder approved by the manager for pool access |
| **Depositor** | Whitelisted user who deposits assets into the managed pool |
| **Borrower** | Depositor who draws credit against their own deposits |
| **Governance** | Diamond owner or timelock; sets system share percentage and creation fee |
| **Base Pool Depositors** | Depositors in the permissionless pool for the same asset; receive system share fees |

### Why Managed Pools?

Permissionless pools serve the open DeFi use case, but many operators need:

- **Access control** — Restrict participation to KYC'd users, DAO members, or strategy participants
- **Custom parameters** — Tailor LTV ratios, fee structures, and thresholds to specific strategies
- **Ongoing adjustment** — React to market conditions by adjusting parameters without governance proposals
- **Revenue sharing** — The system share mechanism ensures the base protocol and its depositors benefit from managed pool activity

The tradeoff: managed pools require trust in the manager for parameter changes. The system share ensures the broader protocol always captures value, and manager renunciation provides a path to full immutability.

---

## How It Works

### The Managed Pool Model

1. **Create** a managed pool by paying `managedPoolCreationFee` to the protocol treasury
2. **Whitelist** positions that should have access to the pool
3. **Configure** pool parameters (LTV, fees, thresholds, caps) as needed
4. **Operate** — whitelisted users deposit, borrow, repay, and withdraw using standard self-secured credit mechanics
5. **Earn** — fees generated in the managed pool are split between the managed pool's depositors and the base permissionless pool via the system share

### Relationship to Base Pools

Every managed pool has an underlying asset (e.g., USDC, WETH). The protocol maintains a base permissionless pool for each asset. When a managed pool is created:

- If no base pool exists for the underlying asset, one is automatically created using global default configuration
- A configurable system share (default 20%) of all routed fees flows from the managed pool to the base pool
- This creates a symbiotic relationship: managed pool operators get custom parameters, base pool depositors get additional yield

```
┌─────────────────────────────────────────────────────────────────┐
│                    Managed Pool System                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────────────┐     ┌──────────────────────┐          │
│  │   Managed Pool       │     │   Base Pool          │          │
│  │   (USDC, pid=42)     │     │   (USDC, pid=1)      │          │
│  ├──────────────────────┤     ├──────────────────────┤          │
│  │ Manager: 0xABC...    │     │ Permissionless       │          │
│  │ Whitelist: enabled   │     │ No manager           │          │
│  │ LTV: 90%             │     │ LTV: 95% (immutable) │          │
│  │ Custom fees          │     │ Default fees         │          │
│  └──────────┬───────────┘     └──────────▲───────────┘          │
│             │                            │                      │
│             │    System Share (20%)      │                      │
│             └────────────────────────────┘                      │
│                                                                 │
│  Fee Flow:                                                      │
│  ┌─────────┐  80%   ┌──────────────┐  20%   ┌──────────────┐    │
│  │ Fee     │───────►│ Managed Pool │───────►│  Base Pool   │    │
│  │ Source  │        │ FI/ACI/Treas │        │ FI/ACI/Treas │    │
│  └─────────┘        └──────────────┘        └──────────────┘    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```


---

## Architecture

### Contract Structure

```
src/equallend/
└── PoolManagementFacet.sol        # Managed pool creation, config setters,
                                   # whitelist management, manager lifecycle

src/admin/
└── AdminGovernanceFacet.sol       # setManagedPoolSystemShareBps(),
                                   # setManagedPoolCreationFee()

src/views/
└── ConfigViewFacet.sol            # isManagedPool(), getPoolManager(),
                                   # isWhitelistEnabled(), isWhitelisted(),
                                   # getManagedPoolConfig(),
                                   # getManagedPoolSystemShareBps()

src/libraries/
├── LibAppStorage.sol              # managedPoolCreationFee,
│                                  # managedPoolSystemShareBps storage
├── LibFeeRouter.sol               # routeManagedShare(), system share routing
├── LibPoolMembership.sol          # Whitelist enforcement on pool join
├── Types.sol                      # PoolData managed pool fields
└── Errors.sol                     # Managed pool error definitions
```

### Facet Responsibilities

| Facet | Responsibility | Key Functions |
|-------|---------------|---------------|
| **PoolManagementFacet** | Pool creation, configuration, whitelist, manager lifecycle | `initManagedPool`, `setRollingApy`, `setDepositorLTV`, `addToWhitelist`, `transferManager`, `renounceManager` |
| **AdminGovernanceFacet** | Global managed pool parameters | `setManagedPoolSystemShareBps`, `setManagedPoolCreationFee` |
| **ConfigViewFacet** | Read-only queries | `isManagedPool`, `getPoolManager`, `isWhitelistEnabled`, `isWhitelisted`, `getManagedPoolConfig` |

### High-Level Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                    Managed Pool Lifecycle                       │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐           │
│  │   Pool       │  │  Whitelist   │  │   Config     │           │
│  │  Creation    │  │  Management  │  │  Management  │           │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘           │
│         │                 │                 │                   │
│         └─────────────────┼─────────────────┘                   │
│                           │                                     │
│                    ┌──────────────┐                             │
│                    │   Manager    │                             │
│                    │  Lifecycle   │                             │
│                    └──────────────┘                             │
│                           │                                     │
│              ┌────────────┼────────────┐                        │
│              ▼            ▼            ▼                        │
│        ┌──────────┐ ┌──────────┐ ┌──────────┐                   │
│        │ Transfer │ │ Renounce │ │ Continue │                   │
│        │ Manager  │ │ Manager  │ │ Managing │                   │
│        └──────────┘ └──────────┘ └──────────┘                   │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│                    Fee Routing                                  │
│                                                                 │
│  ┌──────────────┐     ┌──────────────┐     ┌──────────────┐     │
│  │  Fee Source  │────►│ routeManaged │────►│  Base Pool   │     │
│  │ (flash/AUM/  │     │   Share()    │     │  (system     │     │
│  │  penalty)    │     │              │     │   share)     │     │
│  └──────────────┘     └──────┬───────┘     └──────────────┘     │
│                              │                                  │
│                       ┌──────▼───────┐                          │
│                       │ Managed Pool │                          │
│                       │ (remaining)  │                          │
│                       └──────────────┘                          │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Pool Creation

### Process

```solidity
function initManagedPool(
    uint256 pid,
    address underlying,
    Types.PoolConfig calldata config
) external payable;
```

**Steps:**
1. Check if a base permissionless pool exists for the underlying asset; if not, auto-create one using global defaults
2. Validate `managedPoolCreationFee > 0` (creation disabled if fee is zero)
3. Validate `msg.value == managedPoolCreationFee`
4. Transfer creation fee to protocol treasury
5. Validate pool ID is unused (`!p.initialized`)
6. Validate configuration parameters:
   - `minDepositAmount > 0`
   - `minLoanAmount > 0`
   - `depositCap > 0` if `isCapped == true`
   - `aumFeeMinBps <= aumFeeMaxBps <= 10,000`
   - `depositorLTVBps > 0 && depositorLTVBps <= 10,000`
   - `rollingApyBps <= 10,000`
   - `flashLoanFeeBps <= 10,000`
   - Fixed-term configs: `durationSecs > 0`, `apyBps <= 10,000`
   - Maintenance rate within global bounds
7. Store pool configuration with `isManagedPool = true`
8. Set `manager = msg.sender`
9. Set `whitelistEnabled = true`
10. Initialize `currentAumFeeBps = aumFeeMinBps`
11. Initialize `lastMaintenanceTimestamp = block.timestamp`
12. Emit `PoolInitializedManaged` event

### Auto Base Pool Creation

When no base permissionless pool exists for the underlying asset, `initManagedPool` automatically creates one:

```solidity
function _autoCreateBasePool(AppStorage storage store, address underlying)
    private returns (uint256 pid)
{
    pid = _nextPoolId(store);
    (PoolConfig memory config, ActionFeeSet memory fees) = _defaultPoolConfig(store);
    _initPoolInternal(pid, underlying, config, fees, true);
}
```

This ensures the system share routing always has a valid destination pool. The auto-created base pool uses the global default configuration set by governance.

### Access Control

| Caller | Fee Required | Behavior |
|--------|--------------|----------|
| **Anyone** | `managedPoolCreationFee` | Must pay exact fee to treasury |
| **Anyone (fee = 0)** | N/A | Creation disabled (`ManagedPoolCreationDisabled`) |

Unlike permissionless pool creation (which has a governance-free path), managed pool creation always requires a fee. This prevents spam and ensures the protocol captures value from managed pool operators.

### Parameters

The full `PoolConfig` struct is provided at creation:

```solidity
struct PoolConfig {
    uint16 rollingApyBps;           // APY for rolling loans
    uint16 depositorLTVBps;         // Max LTV for borrowing (e.g., 9500 = 95%)
    uint16 maintenanceRateBps;      // Annual maintenance fee rate
    uint16 flashLoanFeeBps;         // Flash loan fee in basis points
    bool flashLoanAntiSplit;        // Anti-split protection toggle
    uint256 minDepositAmount;       // Minimum deposit threshold
    uint256 minLoanAmount;          // Minimum loan threshold
    uint256 minTopupAmount;         // Minimum credit expansion amount
    bool isCapped;                  // Whether deposit cap is enforced
    uint256 depositCap;             // Max principal per user
    uint256 maxUserCount;           // Maximum users (0 = unlimited)
    uint16 aumFeeMinBps;            // Immutable lower bound for AUM fee
    uint16 aumFeeMaxBps;            // Immutable upper bound for AUM fee
    FixedTermConfig[] fixedTermConfigs;  // Fixed-term loan options
    ActionFeeConfig borrowFee;      // Borrow action fee
    ActionFeeConfig repayFee;       // Repay action fee
    ActionFeeConfig withdrawFee;    // Withdraw action fee
    ActionFeeConfig flashFee;       // Flash loan action fee
    ActionFeeConfig closeRollingFee;// Close rolling loan action fee
}
```

### Managed vs Permissionless Pool Creation

| Aspect | Permissionless Pool | Managed Pool |
|--------|-------------------|--------------|
| **Creator** | Governance (free) or public (fee) | Anyone (fee required) |
| **Fee** | `poolCreationFee` | `managedPoolCreationFee` |
| **Manager** | None | `msg.sender` |
| **Whitelist** | None (open access) | Enabled by default |
| **Config Mutability** | Immutable (except action fees via admin) | Fully mutable by manager |
| **Pool ID** | Auto-assigned or governance-specified | Caller-specified |
| **Base Pool Dependency** | None | Auto-creates if needed |


---

## Manager Operations

### Access Control Model

All manager operations use the `_enforceManager` internal helper:

```solidity
function _enforceManager(uint256 pid) internal view returns (PoolData storage p) {
    p = s().pools[pid];
    if (!p.isManagedPool) revert PoolNotManaged(pid);
    address manager = p.manager;
    if (manager == address(0)) revert OnlyManagerAllowed();
    if (manager != msg.sender) revert NotPoolManager(msg.sender, manager);
}
```

This enforces three invariants:
1. The pool must be a managed pool
2. The manager must not have been renounced (not `address(0)`)
3. The caller must be the current manager

### Manager Capabilities

| Operation | Function | Validation |
|-----------|----------|------------|
| Set rolling APY | `setRollingApy(pid, apyBps)` | `apyBps <= 10,000` |
| Set depositor LTV | `setDepositorLTV(pid, ltvBps)` | `0 < ltvBps <= 10,000` |
| Set min deposit | `setMinDepositAmount(pid, amount)` | `amount > 0` |
| Set min loan | `setMinLoanAmount(pid, amount)` | `amount > 0` |
| Set min topup | `setMinTopupAmount(pid, amount)` | `amount > 0` |
| Set deposit cap | `setDepositCap(pid, cap)` | `cap > 0` |
| Toggle capping | `setIsCapped(pid, isCapped)` | If enabling, `depositCap > 0` |
| Set max users | `setMaxUserCount(pid, maxUsers)` | None (0 = unlimited) |
| Set maintenance rate | `setMaintenanceRate(pid, rateBps)` | `0 < rateBps <= maxMaintenanceRateBps` |
| Set flash loan fee | `setFlashLoanFee(pid, feeBps)` | `feeBps <= 10,000` |
| Set action fees | `setActionFees(pid, actionFees)` | Each fee within global bounds |
| Add to whitelist | `addToWhitelist(pid, tokenId)` | Token must belong to pool |
| Remove from whitelist | `removeFromWhitelist(pid, tokenId)` | Token must belong to pool |
| Toggle whitelist | `setWhitelistEnabled(pid, enabled)` | None |
| Transfer manager | `transferManager(pid, newManager)` | `newManager != address(0)` |
| Renounce manager | `renounceManager(pid)` | Manager not already renounced |

### Configuration Update Pattern

All configuration setters follow a consistent pattern:

```solidity
function setRollingApy(uint256 pid, uint16 apyBps) external {
    PoolData storage p = _enforceManager(pid);
    if (apyBps > 10_000) revert InvalidAPYRate("rollingApyBps > 100%");
    uint16 oldVal = p.poolConfig.rollingApyBps;
    p.poolConfig.rollingApyBps = apyBps;
    _emitManagedUpdate(pid, "rollingApyBps", abi.encode(oldVal), abi.encode(apyBps));
}
```

Each setter:
1. Enforces manager access
2. Validates the new value
3. Captures the old value
4. Updates storage
5. Emits a `ManagedConfigUpdated` event with old and new values

### Action Fee Management

Managers can update all five action fees in a single call:

```solidity
struct ActionFeeConfig {
    uint128 amount;     // Fee amount in underlying token units
    bool enabled;       // Whether the fee is active
}

struct ActionFeeSet {
    ActionFeeConfig borrowFee;
    ActionFeeConfig repayFee;
    ActionFeeConfig withdrawFee;
    ActionFeeConfig flashFee;
    ActionFeeConfig closeRollingFee;
}

function setActionFees(uint256 pid, ActionFeeSet calldata actionFees) external;
```

Each fee amount is validated against global bounds (`actionFeeMin`, `actionFeeMax`) if bounds are configured. This prevents managers from setting exploitative fees while allowing flexibility within protocol-defined limits.

---

## Whitelist System

### Overview

The whitelist system provides position-level access control for managed pools. It is keyed by `positionKey` (derived from the Position NFT), not by user address. This means access follows the NFT, not the wallet.

### Whitelist Storage

```solidity
// On PoolData
bool whitelistEnabled;                    // Toggle for enforcement
mapping(bytes32 => bool) whitelist;       // positionKey => whitelisted

// Position key derivation
bytes32 positionKey = keccak256(abi.encodePacked(nftContract, tokenId));
```

### Enforcement Point

Whitelist checks occur at pool membership join time via `LibPoolMembership`:

```solidity
// In LibPoolMembership.ensureMember()
if (alreadyMember) {
    // Existing membership allows continued operations
    // even if later removed from whitelist
    return true;
}

if (p.isManagedPool && p.whitelistEnabled && !p.whitelist[positionKey]) {
    revert WhitelistRequired(positionKey, pid);
}
```

### Key Properties

| Property | Behavior |
|----------|----------|
| **Default state** | Enabled at pool creation |
| **Grandfathering** | Existing members can continue operating even if removed from whitelist |
| **Toggle** | Manager can disable whitelist to open the pool to all |
| **Re-enable** | Manager can re-enable whitelist; only new joins are gated |
| **NFT-bound** | Access follows the Position NFT, not the wallet address |

### Whitelist Operations

```solidity
// Add a position to the whitelist
function addToWhitelist(uint256 pid, uint256 tokenId) external {
    PoolData storage p = _enforceManager(pid);
    bytes32 positionKey = _positionKeyForToken(pid, tokenId);
    p.whitelist[positionKey] = true;
    emit WhitelistUpdated(pid, positionKey, true);
}

// Remove a position from the whitelist
function removeFromWhitelist(uint256 pid, uint256 tokenId) external {
    PoolData storage p = _enforceManager(pid);
    bytes32 positionKey = _positionKeyForToken(pid, tokenId);
    p.whitelist[positionKey] = false;
    emit WhitelistUpdated(pid, positionKey, false);
}

// Toggle whitelist enforcement
function setWhitelistEnabled(uint256 pid, bool enabled) external {
    PoolData storage p = _enforceManager(pid);
    bool old = p.whitelistEnabled;
    p.whitelistEnabled = enabled;
    emit WhitelistToggled(pid, enabled);
    _emitManagedUpdate(pid, "whitelistEnabled", abi.encode(old), abi.encode(enabled));
}
```

### Grandfathering Semantics

The grandfathering rule is a deliberate design choice:

```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│  Whitelisted │────►│   Joined     │────►│   Removed    │
│  (can join)  │     │  (member)    │     │ from WL      │
└──────────────┘     └──────────────┘     └──────┬───────┘
                                                 │
                                          Still a member.
                                          Can deposit, borrow,
                                          repay, withdraw.
                                          Cannot be re-gated
                                          without pool migration.
```

This prevents a manager from trapping user funds by removing whitelist access after deposits. Once a position has joined the pool, it retains full operational access regardless of subsequent whitelist changes.


---

## Configuration Management

### Mutable Parameters

All `PoolConfig` parameters are mutable by the manager after creation. This is the primary distinction from permissionless pools, where configuration is immutable.

### Parameter Categories

#### Interest Rates

```solidity
function setRollingApy(uint256 pid, uint16 apyBps) external;
```

- Controls the APY charged on rolling credit lines
- Range: `0 – 10,000` bps (0% – 100%)
- Affects new loans and existing loan accruals

#### Collateralization

```solidity
function setDepositorLTV(uint256 pid, uint16 ltvBps) external;
```

- Controls the maximum loan-to-value ratio
- Range: `1 – 10,000` bps (0.01% – 100%)
- Reducing LTV does not force-close existing loans but prevents new borrowing that would violate the new ratio

#### Thresholds

```solidity
function setMinDepositAmount(uint256 pid, uint256 minDeposit) external;
function setMinLoanAmount(uint256 pid, uint256 minLoan) external;
function setMinTopupAmount(uint256 pid, uint256 minTopup) external;
```

- All must be `> 0`
- Prevent dust deposits and loans

#### Caps

```solidity
function setDepositCap(uint256 pid, uint256 cap) external;
function setIsCapped(uint256 pid, bool isCapped) external;
function setMaxUserCount(uint256 pid, uint256 maxUsers) external;
```

- `depositCap`: Per-user maximum principal (must be `> 0` when setting)
- `isCapped`: Toggle enforcement; requires `depositCap > 0` when enabling
- `maxUserCount`: Maximum number of positions in the pool (`0` = unlimited)

#### Maintenance

```solidity
function setMaintenanceRate(uint256 pid, uint16 rateBps) external;
```

- Annual maintenance fee rate
- Range: `1 – maxMaintenanceRateBps` (global bound, default 100 bps = 1%)
- Affects ongoing principal reduction for all depositors

#### Flash Loans

```solidity
function setFlashLoanFee(uint256 pid, uint16 feeBps) external;
```

- Flash loan fee in basis points
- Range: `0 – 10,000` bps

#### Action Fees

```solidity
function setActionFees(uint256 pid, ActionFeeSet calldata actionFees) external;
```

- Batch update of all five action fees (borrow, repay, withdraw, flash, close-rolling)
- Each fee validated against global bounds if configured

### Immutable Parameters

Despite the mutable configuration model, two parameters remain immutable after creation:

| Parameter | Why Immutable |
|-----------|---------------|
| `aumFeeMinBps` / `aumFeeMaxBps` | Depositor certainty — users know the AUM fee range before entering |
| `fixedTermConfigs` | Existing fixed-term loans reference these configs; changing them would break loan semantics |

The `currentAumFeeBps` is adjustable by governance (not the manager) within the immutable bounds, consistent with permissionless pool behavior.

---

## Fee System and System Share

### System Share Mechanism

The system share is the core economic link between managed pools and the base protocol. A configurable percentage of all routed fees in a managed pool is diverted to the base permissionless pool for the same underlying asset.

### Configuration

```solidity
// Global default: 2000 bps = 20%
uint16 constant DEFAULT_MANAGED_POOL_SYSTEM_SHARE_BPS = 2000;

// Governance can adjust
function setManagedPoolSystemShareBps(uint16 shareBps) external;
```

The system share is a global parameter (not per-pool), set by governance via `AdminGovernanceFacet`.

### Routing Logic

All fee routing in managed pools flows through `LibFeeRouter.routeManagedShare()`:

```solidity
function routeManagedShare(
    uint256 pid,
    uint256 amount,
    bytes32 source,
    bool pullFromTracked,
    uint256 extraBacking
) internal returns (uint256 toTreasury, uint256 toActiveCredit, uint256 toFeeIndex) {
    if (!pool.isManagedPool) {
        return routeSamePool(pid, amount, source, pullFromTracked, extraBacking);
    }

    uint16 systemShareBps = managedPoolSystemShareBps(store);
    if (systemShareBps == 0) {
        return routeSamePool(pid, amount, source, pullFromTracked, extraBacking);
    }

    uint256 systemShare = (amount * systemShareBps) / 10_000;
    uint256 managedShare = amount - systemShare;

    // System share → base pool (same underlying)
    _routeSystemShare(store, pool, pid, systemShare, source, ...);

    // Managed share → stays in managed pool
    routeSamePool(pid, managedShare, source, ...);
}
```

### Split Flow

```
Fee Amount (100%)
    │
    ├── System Share (20% default)
    │   │
    │   └── Base Pool for same underlying
    │       ├── Treasury (10% of system share)
    │       ├── Active Credit Index (70% of system share)
    │       └── Fee Index (20% of system share)
    │
    └── Managed Share (80% default)
        │
        └── Managed Pool
            ├── Treasury (10% of managed share)
            ├── Active Credit Index (70% of managed share)
            └── Fee Index (20% of managed share)
```

### Fallback Behavior

If no valid base pool exists (e.g., base pool not initialized or has zero deposits), the system share falls back to a direct treasury transfer:

```solidity
if (basePid == 0 || !basePool.initialized || basePool.totalDeposits == 0) {
    _routeSystemShareToTreasury(managedPool, amount, pullFromTracked);
    return (amount, 0, 0);
}
```

This ensures fees are never lost, even in edge cases.

### Fee Sources Affected by System Share

| Fee Source | Routing Function | System Share Applied |
|------------|-----------------|---------------------|
| Flash loan fees | `LibFeeTreasury` → `routeManagedShare` | Yes |
| Penalty distributions | `LibFeeRouter` → `routeManagedShare` | Yes |
| Module AUM fees | `LibFeeTreasury` → `routeManagedShare` | Yes |
| Action fees | `LibFeeTreasury` → `routeManagedShare` | Yes |

### Unmanaged Pool Behavior

For unmanaged (permissionless) pools, `routeManagedShare()` is equivalent to `routeSamePool()` — no system share diversion occurs. The check is a simple `if (!pool.isManagedPool)` early return.


---

## Manager Transfer and Renunciation

### Transfer

```solidity
function transferManager(uint256 pid, address newManager) external {
    PoolData storage p = _enforceManager(pid);
    if (newManager == address(0)) revert InvalidManagerTransfer();
    address oldManager = p.manager;
    p.manager = newManager;
    emit ManagerTransferred(pid, oldManager, newManager);
}
```

- Only the current manager can transfer
- Cannot transfer to `address(0)` (use `renounceManager` instead)
- Immediate effect — the new manager has full control after the transaction
- No two-step acceptance pattern (single-step transfer)

### Renunciation

```solidity
function renounceManager(uint256 pid) external {
    PoolData storage p = s().pools[pid];
    if (!p.isManagedPool) revert PoolNotManaged(pid);
    address currentManager = p.manager;
    if (currentManager == address(0)) revert ManagerAlreadyRenounced();
    if (msg.sender != currentManager) revert NotPoolManager(msg.sender, currentManager);
    p.manager = address(0);
    emit ManagerRenounced(pid, currentManager);
}
```

- Permanent and irreversible — sets manager to `address(0)`
- All configuration setters become permanently disabled
- Whitelist state is frozen (cannot add/remove/toggle)
- The pool continues operating with its current configuration
- Existing whitelist entries remain in effect
- `isManagedPool` remains `true` (system share routing continues)

### State Machine

```
┌──────────────┐  transferManager()  ┌──────────────┐
│   Manager A  │────────────────────►│   Manager B  │
└──────┬───────┘                     └──────┬───────┘
       │                                    │
       │  renounceManager()                 │  renounceManager()
       │                                    │
       ▼                                    ▼
┌──────────────────────────────────────────────────┐
│              Renounced (permanent)                │
│  manager = address(0)                            │
│  All setters revert with OnlyManagerAllowed      │
│  Pool operates with frozen configuration         │
│  System share routing continues                  │
└──────────────────────────────────────────────────┘
```

### Post-Renunciation Behavior

| Operation | Allowed | Notes |
|-----------|---------|-------|
| Deposits | Yes | Subject to frozen whitelist |
| Borrowing | Yes | Subject to frozen LTV |
| Repayment | Yes | Standard mechanics |
| Withdrawal | Yes | Standard mechanics |
| Flash loans | Yes | Subject to frozen fee |
| Config changes | No | All setters revert |
| Whitelist changes | No | Frozen in current state |
| AUM fee adjustment | Yes | Governance-only (not manager) |

---

## Data Models

### Managed Pool State (on PoolData)

```solidity
struct PoolData {
    // ... core pool fields ...

    // Managed pool state (only meaningful when isManagedPool == true)
    bool isManagedPool;                          // Managed pool flag
    address manager;                             // Current manager (address(0) if renounced)
    bool whitelistEnabled;                       // Whether whitelist gating is active
    mapping(bytes32 => bool) whitelist;           // positionKey => whitelisted

    // ... per-user ledger, loan state, etc. ...
}
```

### Pool Configuration (Canonical for Managed Pools)

```solidity
struct PoolConfig {
    // Interest rates
    uint16 rollingApyBps;

    // Collateralization
    uint16 depositorLTVBps;

    // Maintenance
    uint16 maintenanceRateBps;

    // Flash loans
    uint16 flashLoanFeeBps;
    bool flashLoanAntiSplit;

    // Thresholds
    uint256 minDepositAmount;
    uint256 minLoanAmount;
    uint256 minTopupAmount;

    // Caps
    bool isCapped;
    uint256 depositCap;
    uint256 maxUserCount;

    // AUM fee bounds (immutable)
    uint16 aumFeeMinBps;
    uint16 aumFeeMaxBps;

    // Fixed term configs (immutable)
    FixedTermConfig[] fixedTermConfigs;

    // Action fees (manager-mutable)
    ActionFeeConfig borrowFee;
    ActionFeeConfig repayFee;
    ActionFeeConfig withdrawFee;
    ActionFeeConfig flashFee;
    ActionFeeConfig closeRollingFee;
}
```

### Action Fee Types

```solidity
struct ActionFeeConfig {
    uint128 amount;     // Fee amount in underlying token units
    bool enabled;       // Whether the fee is active
}

struct ActionFeeSet {
    ActionFeeConfig borrowFee;
    ActionFeeConfig repayFee;
    ActionFeeConfig withdrawFee;
    ActionFeeConfig flashFee;
    ActionFeeConfig closeRollingFee;
}
```

### Global Managed Pool Configuration (on AppStorage)

```solidity
struct AppStorage {
    // ...
    uint256 managedPoolCreationFee;              // Fee to create a managed pool
    uint16 managedPoolSystemShareBps;            // System share percentage
    bool managedPoolSystemShareConfigured;       // Whether system share has been explicitly set
    // ...
}
```

### Constants

```solidity
uint16 constant DEFAULT_MANAGED_POOL_SYSTEM_SHARE_BPS = 2000;  // 20%
```

---

## View Functions

### ConfigViewFacet

```solidity
// Check if a pool is managed
function isManagedPool(uint256 pid) external view returns (bool);

// Get the current pool manager (address(0) if unmanaged or renounced)
function getPoolManager(uint256 pid) external view returns (address);

// Check if whitelist gating is enabled
// Returns false for unmanaged pools
function isWhitelistEnabled(uint256 pid) external view returns (bool);

// Check whether a specific position is whitelisted
// Returns true for unmanaged pools (backward compatibility)
function isWhitelisted(uint256 pid, uint256 tokenId) external view returns (bool);

// Get the full pool configuration for a managed pool
// Reverts with PoolNotManaged for unmanaged pools
function getManagedPoolConfig(uint256 pid) external view returns (PoolConfig memory);

// Get the current managed pool system share percentage
function getManagedPoolSystemShareBps() external view returns (uint16);
```

### Backward Compatibility

View functions are designed to be safe for callers that don't distinguish between managed and unmanaged pools:

| Function | Unmanaged Pool Return |
|----------|-----------------------|
| `isManagedPool` | `false` |
| `getPoolManager` | `address(0)` |
| `isWhitelistEnabled` | `false` |
| `isWhitelisted` | `true` (always) |
| `getManagedPoolConfig` | Reverts with `PoolNotManaged` |


---

## Integration Guide

### For Developers

#### Creating a Managed Pool

```solidity
// 1. Prepare configuration
Types.PoolConfig memory config = Types.PoolConfig({
    rollingApyBps: 0,              // 0% interest (self-secured)
    depositorLTVBps: 9000,         // 90% LTV
    maintenanceRateBps: 50,        // 0.5% annual maintenance
    flashLoanFeeBps: 30,           // 0.3% flash fee
    flashLoanAntiSplit: true,
    minDepositAmount: 100e6,       // 100 USDC minimum
    minLoanAmount: 50e6,           // 50 USDC minimum
    minTopupAmount: 25e6,          // 25 USDC minimum
    isCapped: true,
    depositCap: 1_000_000e6,       // 1M USDC per user
    maxUserCount: 100,             // 100 positions max
    aumFeeMinBps: 0,
    aumFeeMaxBps: 200,             // Up to 2% AUM fee
    fixedTermConfigs: new Types.FixedTermConfig[](0),
    borrowFee: Types.ActionFeeConfig(1e6, true),     // 1 USDC borrow fee
    repayFee: Types.ActionFeeConfig(0, false),
    withdrawFee: Types.ActionFeeConfig(0, false),
    flashFee: Types.ActionFeeConfig(0, false),
    closeRollingFee: Types.ActionFeeConfig(0, false)
});

// 2. Create the pool (pid chosen by caller)
uint256 pid = 42;
uint256 creationFee = configView.getManagedPoolCreationFee();
poolFacet.initManagedPool{value: creationFee}(pid, usdc, config);
```

#### Managing the Whitelist

```solidity
// Whitelist a position
poolFacet.addToWhitelist(pid, tokenId);

// Batch whitelist (multiple calls)
for (uint i = 0; i < tokenIds.length; i++) {
    poolFacet.addToWhitelist(pid, tokenIds[i]);
}

// Remove from whitelist (existing members keep access)
poolFacet.removeFromWhitelist(pid, tokenId);

// Open pool to everyone
poolFacet.setWhitelistEnabled(pid, false);

// Re-enable whitelist (only gates new joins)
poolFacet.setWhitelistEnabled(pid, true);
```

#### Adjusting Parameters

```solidity
// Tighten LTV during volatile conditions
poolFacet.setDepositorLTV(pid, 8000);  // 80%

// Increase flash loan fee
poolFacet.setFlashLoanFee(pid, 50);  // 0.5%

// Update all action fees at once
Types.ActionFeeSet memory newFees = Types.ActionFeeSet({
    borrowFee: Types.ActionFeeConfig(2e6, true),
    repayFee: Types.ActionFeeConfig(0, false),
    withdrawFee: Types.ActionFeeConfig(1e6, true),
    flashFee: Types.ActionFeeConfig(0, false),
    closeRollingFee: Types.ActionFeeConfig(0, false)
});
poolFacet.setActionFees(pid, newFees);
```

#### Transferring or Renouncing Management

```solidity
// Transfer to a multisig
poolFacet.transferManager(pid, multisigAddress);

// Or permanently renounce (irreversible)
poolFacet.renounceManager(pid);
```

#### Querying Managed Pool State

```solidity
// Check if pool is managed
bool managed = configView.isManagedPool(pid);

// Get manager
address manager = configView.getPoolManager(pid);

// Check whitelist status
bool wlEnabled = configView.isWhitelistEnabled(pid);
bool isWL = configView.isWhitelisted(pid, tokenId);

// Get full config
Types.PoolConfig memory config = configView.getManagedPoolConfig(pid);
```

### For Users

#### Joining a Managed Pool

1. **Get whitelisted** — Contact the pool manager to have your Position NFT added to the whitelist
2. **Mint a position** — Mint a Position NFT for the managed pool's pool ID
3. **Deposit** — Deposit assets into the pool (standard self-secured credit flow)
4. **Borrow** — Draw credit against your deposits up to the pool's LTV ratio
5. **Monitor** — Watch for parameter changes by the manager (emitted as `ManagedConfigUpdated` events)

#### Understanding Risks

- The manager can change LTV, fees, and thresholds at any time
- Reducing LTV won't force-close your loans but may prevent new borrowing
- Increasing fees affects future operations
- If removed from the whitelist after joining, you retain full access
- Manager renunciation freezes all parameters permanently

---

## Worked Examples

### Example 1: DAO Treasury Pool

**Scenario:** A DAO creates a managed pool for its treasury operations with restricted access.

**Step 1: Create Pool**
```
DAO multisig calls initManagedPool:
  pid: 100
  underlying: USDC
  LTV: 90%
  maintenance: 0.25%
  flash fee: 0.1%
  deposit cap: 10M USDC per position
  max users: 50
  
Creation fee: 0.1 ETH → treasury
Manager: DAO multisig
Whitelist: enabled (default)
```

**Step 2: Whitelist Members**
```
DAO multisig whitelists 20 Position NFTs
Each member can now deposit up to 10M USDC
```

**Step 3: Operations**
```
Member A deposits 1M USDC
Member A borrows 900K USDC (90% LTV)
Member A deploys 900K to yield strategy

Flash loan fee generated: 100 USDC
  → 20 USDC system share → base USDC pool
    → 2 USDC treasury
    → 14 USDC active credit
    → 4 USDC fee index (base pool depositors)
  → 80 USDC managed share → managed pool
    → 8 USDC treasury
    → 56 USDC active credit
    → 16 USDC fee index (managed pool depositors)
```

### Example 2: Strategy Vault with Parameter Adjustment

**Scenario:** A strategy operator adjusts parameters in response to market conditions.

**Initial State:**
```
Managed pool: WETH
LTV: 95%
Depositors: 10 positions
Total deposits: 500 ETH
Active loans: 400 ETH
```

**Market Volatility Increases:**
```
Manager calls setDepositorLTV(pid, 8000)  // Reduce to 80%

Effect:
  - Existing loans at 80% LTV: unaffected
  - Existing loans at 90% LTV: cannot expand, but not force-closed
  - New loans: limited to 80% LTV
  - Positions with debt > 80% of principal: cannot borrow more
```

**Market Stabilizes:**
```
Manager calls setDepositorLTV(pid, 9500)  // Restore to 95%

Effect:
  - All positions can borrow up to 95% again
  - No state changes to existing loans
```

### Example 3: Manager Renunciation

**Scenario:** A pool operator decides to make the pool fully immutable.

**Before Renunciation:**
```
Pool pid: 42
Manager: 0xABC...
Whitelist: disabled (open access)
LTV: 90%
Flash fee: 0.3%
```

**Renunciation:**
```
Manager calls renounceManager(42)
  → manager set to address(0)
  → ManagerRenounced event emitted
```

**After Renunciation:**
```
Pool pid: 42
Manager: address(0)
Whitelist: disabled (frozen — cannot be re-enabled)
LTV: 90% (frozen — cannot be changed)
Flash fee: 0.3% (frozen — cannot be changed)
isManagedPool: true (system share routing continues)

All setter calls revert with OnlyManagerAllowed
Governance can still adjust currentAumFeeBps within bounds
```

### Example 4: System Share Routing

**Scenario:** A flash loan generates fees in a managed USDC pool.

**Setup:**
```
Managed pool (pid=42): USDC, 500K deposits
Base pool (pid=1): USDC, 10M deposits
System share: 20% (default)
Treasury split: 10%
Active credit split: 70%
Fee index: 20% (remainder)
```

**Flash loan fee: 1,000 USDC**
```
Step 1: routeManagedShare(42, 1000, ...)
  systemShare = 1000 × 20% = 200 USDC
  managedShare = 1000 - 200 = 800 USDC

Step 2: System share → base pool (pid=1)
  200 USDC transferred from managed pool to base pool
  Base pool routing:
    treasury: 200 × 10% = 20 USDC (transferred out)
    active credit: 200 × 70% = 140 USDC (base pool ACI)
    fee index: 200 × 20% = 40 USDC (base pool depositors)

Step 3: Managed share → managed pool (pid=42)
  800 USDC stays in managed pool
  Managed pool routing:
    treasury: 800 × 10% = 80 USDC (transferred out)
    active credit: 800 × 70% = 560 USDC (managed pool ACI)
    fee index: 800 × 20% = 160 USDC (managed pool depositors)

Total distribution:
  Treasury: 100 USDC (20 + 80)
  Base pool participants: 180 USDC (140 ACI + 40 FI)
  Managed pool participants: 720 USDC (560 ACI + 160 FI)
```


---

## Error Reference

### Creation Errors

| Error | Cause |
|-------|-------|
| `ManagedPoolCreationDisabled()` | `managedPoolCreationFee == 0` (creation disabled by governance) |
| `InsufficientManagedPoolCreationFee(uint256, uint256)` | `msg.value != managedPoolCreationFee` |
| `InvalidTreasuryAddress()` | Protocol treasury not configured |
| `PoolCreationFeeTransferFailed()` | ETH transfer to treasury failed |
| `PoolAlreadyExists(uint256)` | Pool ID already initialized |
| `DefaultPoolConfigNotSet()` | Global defaults not configured (needed for auto base pool creation) |

### Configuration Errors

| Error | Cause |
|-------|-------|
| `InvalidMinimumThreshold(string)` | Zero minimum threshold (deposit, loan, or topup) |
| `InvalidDepositCap()` | Deposit cap is zero when capping is enabled |
| `InvalidAumFeeBounds()` | `aumFeeMinBps > aumFeeMaxBps` |
| `InvalidParameterRange(string)` | Parameter exceeds maximum (e.g., `aumFeeMaxBps > 100%`) |
| `InvalidLTVRatio()` | LTV is zero or exceeds 10,000 bps |
| `InvalidAPYRate(string)` | APY exceeds 10,000 bps |
| `InvalidMaintenanceRate()` | Rate is zero or exceeds global maximum |
| `InvalidFlashLoanFee()` | Flash fee exceeds 10,000 bps |
| `InvalidFixedTermDuration()` | Fixed-term duration is zero |
| `ActionFeeBoundsViolation(uint128, uint128, uint128)` | Action fee outside global bounds |

### Manager Errors

| Error | Cause |
|-------|-------|
| `PoolNotManaged(uint256)` | Operation attempted on a non-managed pool |
| `NotPoolManager(address, address)` | Caller is not the current manager |
| `OnlyManagerAllowed()` | Manager has been renounced (`address(0)`) |
| `InvalidManagerTransfer()` | Attempted transfer to `address(0)` |
| `ManagerAlreadyRenounced()` | Attempted renunciation when already renounced |

### Whitelist Errors

| Error | Cause |
|-------|-------|
| `WhitelistRequired(bytes32, uint256)` | Position not whitelisted for managed pool |
| `InvalidManagedPoolConfig(string)` | Position NFT not set or token pool mismatch |

---

## Events

### Pool Creation

```solidity
event PoolInitializedManaged(
    uint256 indexed pid,
    address indexed underlying,
    address indexed manager,
    Types.PoolConfig config
);
```

### Configuration Updates

```solidity
event ManagedConfigUpdated(
    uint256 indexed pid,
    string parameter,
    bytes oldValue,
    bytes newValue
);
```

Emitted for every parameter change. The `parameter` string identifies which field was changed (e.g., `"rollingApyBps"`, `"depositorLTVBps"`, `"actionFees"`, `"whitelistEnabled"`). Old and new values are ABI-encoded for generic decoding.

### Whitelist Events

```solidity
event WhitelistUpdated(
    uint256 indexed pid,
    bytes32 indexed user,
    bool added
);

event WhitelistToggled(
    uint256 indexed pid,
    bool enabled
);
```

### Manager Lifecycle Events

```solidity
event ManagerTransferred(
    uint256 indexed pid,
    address indexed oldManager,
    address indexed newManager
);

event ManagerRenounced(
    uint256 indexed pid,
    address indexed formerManager
);
```

### System Share Events

```solidity
event ManagedPoolSystemShareRouted(
    uint256 indexed managedPid,
    uint256 indexed basePid,
    uint256 amount,
    bytes32 source
);

event ManagedPoolSystemShareUpdated(
    uint16 oldShare,
    uint16 newShare
);
```

---

## Security Considerations

### 1. Manager Trust Model

Managed pools require trust in the manager. The manager can:
- Change LTV ratios (potentially preventing new borrowing)
- Adjust fees (increasing costs for depositors)
- Modify whitelist access (though grandfathering protects existing members)

Mitigations:
- All changes emit `ManagedConfigUpdated` events for off-chain monitoring
- AUM fee bounds are immutable (depositor certainty)
- Grandfathering prevents fund trapping via whitelist removal
- Manager renunciation provides a path to full immutability

### 2. Grandfathering Protection

The whitelist grandfathering rule prevents a critical attack vector:

```
Attack: Manager whitelists user → user deposits → manager removes from whitelist
Result: User retains full access (deposit, borrow, repay, withdraw)
```

Without grandfathering, a malicious manager could trap funds by removing whitelist access after deposits.

### 3. System Share Integrity

The system share mechanism ensures the base protocol always benefits from managed pool activity:

- System share is a global governance parameter (managers cannot reduce it)
- Fallback to treasury transfer if base pool is unavailable
- `ManagedPoolSystemShareRouted` events provide audit trail

### 4. Renunciation Irreversibility

Manager renunciation is deliberately irreversible:
- Sets manager to `address(0)`
- No recovery path exists
- Prevents social engineering attacks where a renounced manager is "restored"
- `isManagedPool` remains `true` to preserve system share routing

### 5. Single-Step Manager Transfer

Manager transfer is single-step (no acceptance required). This is a deliberate simplicity choice:
- Reduces gas costs and complexity
- The manager is trusted by definition
- If transfer to a wrong address occurs, the pool can still be used by existing members

For high-security scenarios, managers should use a multisig or governance contract as the manager address.

### 6. Parameter Change Impact on Existing Positions

| Parameter Change | Impact on Existing Positions |
|-----------------|------------------------------|
| LTV reduction | Cannot borrow more if over new limit; existing loans unaffected |
| Fee increase | Affects future operations only |
| Threshold increase | Affects future deposits/loans only |
| Cap reduction | Existing deposits above new cap are unaffected |
| Maintenance rate change | Affects ongoing accrual for all positions |

No parameter change can force-close existing loans or seize existing deposits.

### 7. Auto Base Pool Creation

The auto-creation of base pools when a managed pool is created for a new asset ensures:
- System share routing always has a valid destination
- No orphaned managed pools without fee routing
- Base pool uses governance-approved default configuration

### 8. Position Key Binding

Whitelist entries are bound to `positionKey` (derived from NFT contract + token ID), not wallet addresses:
- Access follows the NFT on transfer
- Prevents whitelist bypass via NFT transfer to non-whitelisted wallet (the position key doesn't change)
- Token pool mismatch is validated during whitelist operations

### 9. Action Fee Bounds

Global action fee bounds (`actionFeeMin`, `actionFeeMax`) constrain manager fee-setting:
- Prevents managers from setting zero fees (if minimum is configured)
- Prevents managers from setting exploitative fees (if maximum is configured)
- Bounds are governance-controlled, not manager-controlled

---

## Appendix: Correctness Properties

### Property 1: Manager Exclusivity
Only the current manager can modify managed pool configuration:
```
∀ setter s, pool p: s(p) succeeds ⟹ msg.sender == p.manager ∧ p.manager ≠ address(0)
```

### Property 2: Grandfathering Invariant
Once a position joins a managed pool, it retains access regardless of whitelist changes:
```
∀ position pk, pool p: joined[pk][p] == true ⟹ ensureMember(pk, p) succeeds
```

### Property 3: System Share Conservation
Total fee distribution equals the original fee amount:
```
systemShare + managedShare == originalFee
∀ share: treasury + activeCredit + feeIndex == share
```

### Property 4: Renunciation Permanence
Once renounced, a manager cannot be restored:
```
renounceManager(p) ⟹ ∀ t > now: p.manager == address(0)
```

### Property 5: Base Pool Existence
After managed pool creation, a base pool exists for the underlying asset:
```
initManagedPool(pid, underlying, config) succeeds ⟹ assetToPoolId[underlying] ≠ 0
```

### Property 6: AUM Bound Immutability
AUM fee bounds cannot be changed after pool creation:
```
∀ t > creation: p.poolConfig.aumFeeMinBps == initial ∧ p.poolConfig.aumFeeMaxBps == initial
```

### Property 7: Fallback Safety
System share fees are never lost:
```
routeManagedShare(pid, amount, ...) ⟹ amount is fully distributed
  (to base pool if valid, to treasury otherwise)
```

### Property 8: Backward Compatibility
Unmanaged pools are unaffected by managed pool logic:
```
∀ pool p: !p.isManagedPool ⟹ routeManagedShare(p, ...) == routeSamePool(p, ...)
```

---

**Document Version:** 1.0
