# Proof of Participation (PoP) - Design Document

**Version:** 1.0

---

## Table of Contents

1. [Overview](#overview)
2. [How It Works](#how-it-works)
3. [Architecture](#architecture)
4. [Points Identity](#points-identity)
5. [Earning Actions](#earning-actions)
6. [Anti-Farming Controls](#anti-farming-controls)
7. [Governance Controls](#governance-controls)
8. [Redemption & Emissions](#redemption--emissions)
9. [Data Models](#data-models)
10. [View Functions](#view-functions)
11. [Integration Guide](#integration-guide)
12. [Worked Examples](#worked-examples)
13. [Error Reference](#error-reference)
14. [Events](#events)
15. [Security Considerations](#security-considerations)

---

## Overview

Proof of Participation (PoP) is Equalis' on-chain participation accounting system. It tracks meaningful protocol usage and converts that usage into points. These points are designed to become the foundation for future token emissions, without requiring a redesign of core lending, derivatives, or index flows.

### Key Characteristics

| Feature | Description |
|---------|-------------|
| **On-Chain** | All accrual, balance, and burn state lives in contract storage |
| **Position-Keyed** | Points credit to Position NFT keys, not raw wallet addresses |
| **Governance-Configurable** | Action weights, cooldowns, caps, and redemption parameters are all owner/timelock controlled |
| **Anti-Farm Guardrails** | Per-action cooldowns, daily caps, and self-match suppression |
| **Emissions-Ready** | Built-in burn-to-mint redemption path with global and epoch mint caps |
| **Silent Non-Accrual** | Ineligible actions proceed normally; points simply do not accrue |

### System Participants

| Role | Description |
|------|-------------|
| **Position Holder** | User who owns a Position NFT and earns points through protocol actions |
| **Swap/Flash Caller** | User who earns points via non-position actions routed to their default Position NFT |
| **Governance** | Owner/timelock that configures action weights, cooldowns, caps, and redemption |
| **Redeemer** | User who burns points to mint emission tokens |

### Why PoP?

Traditional DeFi incentive systems rely on:
- Off-chain point tracking (opaque, trust-dependent)
- Retroactive airdrops (unpredictable, gameable after announcement)
- Inflationary token emissions (dilutive, no participation signal)

PoP eliminates these dependencies:
- **On-chain** → Fully auditable, no trust assumptions
- **Action-weighted** → Rewards participation quality, not raw call frequency
- **Position-keyed** → Ties incentives to the Position NFT system, preventing free-floating wallet farming
- **Governance-tunable** → Weights and caps adapt as behavior evolves

The tradeoff: fixed-per-action scoring does not scale by economic value. This is a deliberate simplicity choice that governance can tune via cooldowns and caps.

---

## How It Works

### The Core Model

1. **Perform** a rewarded protocol action (deposit, borrow, swap, etc.)
2. **Accrue** points to the relevant Position NFT key (or default position for non-position actions)
3. **Accumulate** points over time across multiple action types
4. **Redeem** (future) burn points to mint emission tokens at governance-set rate

### Accrual Flow

```
User Action (e.g., deposit, swap, borrow)
    │
    ▼
Facet calls LibPoints.accrueToKey() or LibPoints.accrueToDefaultPosition()
    │
    ▼
LibPoints._accrueWithGuard(pointsKey, guardKey, actionType)
    │
    ├── Check pointsPerAction[actionType] > 0  ──→ (0 = disabled, return)
    │
    ├── Check cooldown elapsed for guardKey     ──→ (too soon, return)
    │
    ├── Check daily cap for guardKey            ──→ (exceeded, return)
    │
    ▼
Credit points to pointsKey balance
Emit PointsAccrued event
```

### Key Distinction: pointsKey vs guardKey

- **pointsKey**: The credited points ledger key (typically a Position NFT key; can be an account/system key in non-position redemption flows)
- **guardKey**: The account-level key used for cooldown and daily cap enforcement

This separation lets PoP remain position-centric (points credit to NFT keys) while keeping rate limits account-scoped (cooldowns and caps apply per wallet identity).

---

## Architecture

### Contract Structure

```
src/libraries/
└── LibPoints.sol                  # Core points engine: accrual, burn, redemption, storage

src/admin/
└── PointsAdminFacet.sol           # Governance: set weights, cooldowns, caps, redemption config

src/points/
└── PointsRedemptionFacet.sol      # User-facing: burn points → mint emission tokens

src/views/
└── PointsViewFacet.sol            # Read-only: balances, earned/burned totals, config queries

src/nft/
└── PositionNFT.sol                # Default points token ID routing and transfer semantics

src/interfaces/
└── IPointsEmissionToken.sol       # Emission token mint interface

script/
└── InitializePointsConfig.s.sol   # Default action weight configuration
```

### Integration Points (Accrual Call Sites)

Points accrual is embedded directly in protocol facets at the point of action completion:

```
┌─────────────────────────────────────────────────────────────────────┐
│                        PoP Accrual Surface                          │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐   │
│  │  EqualLend       │  │  EqualLend       │  │  Derivatives     │   │
│  │  (Lending +      │  │  Direct          │  │  (Options,       │   │
│  │   Flash Loans)   │  │  (Offers +       │  │   Futures,       │   │
│  │                  │  │   Agreements +   │  │   AMM Auctions)  │   │
│  │  accrueToKey()   │  │   Rolling)       │  │                  │   │
│  └──────────────────┘  │                  │  │  accrueToKey()   │   │
│         │              │  accrueToKey()   │  └──────────────────┘   │
│         │              └──────────────────┘           │             │
│         │                       │                     │             │
│  ┌───────────────────┐  ┌──────────────────┐ ┌──────────────────┐   │
│  │  EqualIndex       │  │  EqualX Swaps    │ │  Flash Loans     │   │
│  │  (Mint/Burn       │  │  (AMM, MAM,      │ │                  │   │
│  │   Position +      │  │   Community)     │ │  accrueTo-       │   │
│  │   Wallet)         │  │                  │ │  DefaultPosition │   │
│  │                   │  │  accrueTo-       │ └──────────────────┘   │
│  │  accrueToKey() /  │  │  DefaultPosition │                        │
│  │  accrueTo-        │  └──────────────────┘                        │
│  │  DefaultPosition  │                                              │
│  └───────────────────┘                                              │
│                                                                     │
├─────────────────────────────────────────────────────────────────────┤
│                    LibPoints._accrueWithGuard()                     │
│              (cooldown check → daily cap → credit → emit)           │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Points Identity

### Position Key Routing

PoP tracks balances by `pointsKey`, a deterministic `bytes32` derived from the Position NFT:

```solidity
bytes32 positionKey = keccak256(abi.encodePacked(nftContract, tokenId));
```

There are two routing modes depending on the action type:

| Routing Mode | Used By | Mechanism |
|-------------|---------|-----------|
| **Position-direct** | Lending, Direct, Derivatives, Index Position | `accrueToKey(account, positionKey, actionType)` — credits the specific position involved in the action |
| **Default-position** | Swaps, Flash Loans, Index Wallet | `accrueToDefaultPosition(account, actionType)` — resolves the caller's default Position NFT and credits that key |

### Default Position Resolver

Each account has a deterministic default points token ID managed by `PositionNFT`:

```solidity
// In PositionNFT.sol
mapping(address => uint256) public defaultPointsTokenId;
```

Resolution logic in `LibPoints.resolveDefaultPositionKey()`:

1. Look up the account's `defaultPointsTokenId`
2. Verify the account still owns that token
3. If valid, return its position key
4. If invalid (transferred away), fall back to `tokenOfOwnerByIndex(account, 0)`
5. If the account holds no Position NFTs, return `(bytes32(0), false)` — no points accrue

**Lifecycle:**
- Set on first mint: when a Position NFT is minted to an account with no existing default
- Updated on transfer: when the default token is transferred away, reassigned to the first remaining token (or cleared to 0)
- Incoming transfers: if the recipient has no default, the incoming token becomes the default

```solidity
// In PositionNFT._update() transfer hook
if (from != address(0) && defaultPointsTokenId[from] == tokenId) {
    defaultPointsTokenId[from] = balanceOf(from) > 0 ? tokenOfOwnerByIndex(from, 0) : 0;
}
if (to != address(0) && defaultPointsTokenId[to] == 0) {
    defaultPointsTokenId[to] = tokenId;
}
```

### Guard Key (Account Identity)

Anti-farming controls (cooldowns, daily caps) use a separate `guardKey` derived from the caller's wallet address:

```solidity
bytes32 guardKey = LibPositionHelpers.systemPositionKey(account);
```

This means:
- A user with 5 Position NFTs still has one shared cooldown/cap identity
- Points credit to individual position keys, but rate limits are per-account
- Prevents circumventing caps by spreading actions across multiple positions

### Transfer Semantics

Points are attached to position keys, not wallet balances. When a Position NFT transfers:
- The position key (`keccak256(nftContract, tokenId)`) does not change
- All associated PoP balance remains with that position key
- The new owner inherits the point balance
- Cooldown/cap state stays with the original account's guard key (does not transfer)

---

## Earning Actions

### Action Types and Default Weights

All 29 action types are defined as `bytes32` constants in `LibPoints.sol`. Default weights from `InitializePointsConfig.s.sol`:

| Category | Action Type | Constant | Default Weight | Routing |
|----------|------------|----------|---------------|---------|
| **Lending** | Deposit to position | `ACTION_DEPOSIT_TO_POSITION` | 2 | Position-direct |
| **Lending** | Mint position with deposit | `ACTION_MINT_POSITION_WITH_DEPOSIT` | 2 | Position-direct |
| **Lending** | Borrow (rolling) | `ACTION_BORROW_ROLLING` | 2 | Position-direct |
| **Lending** | Borrow (fixed) | `ACTION_BORROW_FIXED` | 2 | Position-direct |
| **Lending** | Repay (rolling) | `ACTION_REPAY_ROLLING` | 2 | Position-direct |
| **Lending** | Repay (fixed) | `ACTION_REPAY_FIXED` | 2 | Position-direct |
| **Flash** | Flash loan | `ACTION_FLASH_LOAN` | 1 | Default-position |
| **Derivatives** | Create option | `ACTION_DERIVATIVE_CREATE_OPTION` | 2 | Position-direct |
| **Derivatives** | Create futures | `ACTION_DERIVATIVE_CREATE_FUTURES` | 2 | Position-direct |
| **Derivatives** | Create AMM auction | `ACTION_DERIVATIVE_CREATE_AMM_AUCTION` | 2 | Position-direct |
| **Direct** | Post lender offer | `ACTION_DIRECT_POST_LENDER_OFFER` | 2 | Position-direct |
| **Direct** | Post borrower offer | `ACTION_DIRECT_POST_BORROWER_OFFER` | 2 | Position-direct |
| **Direct** | Post ratio lender offer | `ACTION_DIRECT_POST_RATIO_LENDER_OFFER` | 2 | Position-direct |
| **Direct** | Post ratio borrower offer | `ACTION_DIRECT_POST_RATIO_BORROWER_OFFER` | 2 | Position-direct |
| **Direct** | Post rolling lender offer | `ACTION_DIRECT_POST_ROLLING_LENDER_OFFER` | 2 | Position-direct |
| **Direct** | Post rolling borrower offer | `ACTION_DIRECT_POST_ROLLING_BORROWER_OFFER` | 2 | Position-direct |
| **Direct** | Accept lender offer | `ACTION_DIRECT_ACCEPT_LENDER_OFFER` | 2 | Position-direct |
| **Direct** | Accept borrower offer | `ACTION_DIRECT_ACCEPT_BORROWER_OFFER` | 2 | Position-direct |
| **Direct** | Accept ratio lender offer | `ACTION_DIRECT_ACCEPT_RATIO_LENDER_OFFER` | 2 | Position-direct |
| **Direct** | Accept ratio borrower offer | `ACTION_DIRECT_ACCEPT_RATIO_BORROWER_OFFER` | 2 | Position-direct |
| **Direct** | Accept rolling offer | `ACTION_DIRECT_ACCEPT_ROLLING_OFFER` | 2 | Position-direct |
| **Direct** | Rolling payment | `ACTION_ROLLING_PAYMENT` | 2 | Position-direct |
| **Trading** | AMM auction swap | `ACTION_SWAP_AMM_AUCTION` | 1 | Default-position |
| **Trading** | MAM curve swap | `ACTION_SWAP_MAM_CURVE` | 1 | Default-position |
| **Trading** | Community auction swap | `ACTION_SWAP_COMMUNITY_AUCTION` | 1 | Default-position |
| **EqualIndex** | Wallet mint | `ACTION_INDEX_MINT` | 1 | Default-position |
| **EqualIndex** | Wallet burn | `ACTION_INDEX_BURN` | 1 | Default-position |
| **EqualIndex** | Position mint | `ACTION_INDEX_MINT_POSITION` | 2 | Position-direct |
| **EqualIndex** | Position burn | `ACTION_INDEX_BURN_POSITION` | 2 | Position-direct |

### Weight Tiers

The default configuration uses two tiers:

| Tier | Weight | Actions |
|------|--------|---------|
| **Position-bound (2)** | 2 points | All actions that operate through a specific Position NFT |
| **Non-position (1)** | 1 point | Swaps, flash loans, wallet-level index mint/burn |

Position-bound actions receive higher weight because they require deeper protocol commitment (owning and operating a Position NFT in a specific pool).

### Index Weight Invariant

Governance enforces a strict ordering for EqualIndex actions:

```
INDEX_MINT_POSITION > INDEX_MINT
INDEX_BURN_POSITION > INDEX_BURN
```

This is validated in `PointsAdminFacet._isIndexWeightConfigValid()` and ensures position-based index participation is always more highly weighted than wallet-level participation. Any batch or single update that would violate this invariant reverts with `Points_IndexPositionWeightInvalid()`.

---

## Anti-Farming Controls

PoP includes built-in guardrails to resist low-cost farming loops. All guardrails operate silently: if an action is ineligible, the core transaction still proceeds; points simply do not accrue.

### Per-Action Cooldowns

Each action type can enforce a minimum time between point accruals:

```solidity
// In LibPoints._accrueWithGuard()
uint256 cooldownSecs = ps.accrualCooldownSecs[actionType];
if (cooldownSecs > 0) {
    uint64 lastTs = ps.lastAccrualTs[guardKey][actionType];
    if (lastTs != 0 && block.timestamp < uint256(lastTs) + cooldownSecs) {
        return; // Too soon, silently skip
    }
}
```

- Cooldowns are tracked per `guardKey` (account identity), not per position key
- A user cannot bypass cooldowns by using different Position NFTs
- Cooldown of 0 means no cooldown (default)
- Configurable per action type via `PointsAdminFacet.setAccrualCooldown()`

### Daily Cap

A global daily points cap limits total accrual per guard account per day:

```solidity
// In LibPoints._accrueWithGuard()
uint256 dailyCap = ps.dailyPointsCap;
if (dailyCap > 0) {
    uint64 dayKey = uint64(block.timestamp / 1 days);
    if (ps.lastAccrualDay[guardKey] != dayKey) {
        ps.lastAccrualDay[guardKey] = dayKey;
        ps.accruedOnDay[guardKey] = 0; // Reset at day boundary
    }
    uint256 accrued = ps.accruedOnDay[guardKey];
    if (accrued >= dailyCap) return; // Cap reached, silently skip
    uint256 remaining = dailyCap - accrued;
    if (credited > remaining) {
        credited = remaining; // Partial credit up to cap
    }
    ps.accruedOnDay[guardKey] = accrued + credited;
}
```

- Day boundaries use UTC (Unix day = `block.timestamp / 86400`)
- Cap of 0 means no cap (default)
- Partial credits are allowed: if 3 points remain in the cap and the action awards 5, only 3 are credited
- Configurable via `PointsAdminFacet.setDailyPointsCap()`

### Self-Match Suppression (Direct Lending)

Direct offer acceptance flows suppress points when the caller and counterparty are the same owner:

```solidity
// In EqualLendDirectAgreementFacet / EqualLendDirectAgreementRatioFacet
function _accrueDirectAcceptIfNotSelfMatch(
    address callerOwner,
    bytes32 callerKey,
    address counterpartyOwner,
    bytes32 actionType
) internal {
    if (callerOwner == counterpartyOwner) return; // Self-match, no points
    LibPoints.accrueToKey(callerOwner, callerKey, actionType);
}
```

This prevents a single user from farming accept points by matching their own offers across two positions they control (same wallet). Note: this does not prevent cross-wallet self-matching (Sybil), which is addressed at the policy/snapshot layer.

### Zero-Weight Early Return

If `pointsPerAction[actionType]` is 0, the accrual function returns immediately without any state reads beyond the weight lookup:

```solidity
uint256 points = ps.pointsPerAction[actionType];
if (points == 0) return;
```

This allows governance to fully disable any action type with zero gas overhead.

### No-Position Early Return

For default-position routing, if the caller holds no Position NFTs, accrual silently returns:

```solidity
(bytes32 pointsKey, bool hasPosition) = resolveDefaultPositionKey(account);
if (!hasPosition) return;
```

This ties all PoP accrual to the Position NFT system. Wallets without positions earn nothing.

### Summary of Guard Layers

```
Action triggered
    │
    ├── pointsPerAction == 0?          → return (disabled)
    │
    ├── No Position NFT? (default)     → return (no position)
    │
    ├── Cooldown not elapsed?           → return (too soon)
    │
    ├── Daily cap exceeded?             → return (capped)
    │
    ├── Self-match? (Direct only)       → return (suppressed)
    │
    └── Credit points ✓
```

---

## Governance Controls

All PoP parameters are controlled by `owner` or `timelock` via `PointsAdminFacet`. Every setter enforces `LibAccess.enforceOwnerOrTimelock()`.

### Configuration Parameters

| Parameter | Setter | Description |
|-----------|--------|-------------|
| `pointsPerAction[actionType]` | `setPointsPerAction(bytes32, uint256)` | Points awarded per action (0 = disabled) |
| `pointsPerAction[]` (batch) | `setPointsPerActionBatch(bytes32[], uint256[])` | Batch update with index weight validation |
| `accrualCooldownSecs[actionType]` | `setAccrualCooldown(bytes32, uint256)` | Minimum seconds between accruals per guard account |
| `dailyPointsCap` | `setDailyPointsCap(uint256)` | Max points per guard account per UTC day (0 = no cap) |
| `redemptionToken` | `setRedemptionToken(address)` | Emission token contract address |
| `redemptionEnabled` | `setRedemptionEnabled(bool)` | Enable/disable burn-to-mint redemption |
| `tokensPerPointWad` | `setRedemptionRate(uint256)` | Tokens minted per point burned (1e18 scale) |
| `redemptionGlobalMintCap` | `setRedemptionGlobalMintCap(uint256)` | Lifetime max emission tokens mintable (0 = no cap) |
| `redemptionEpochLengthSecs` | `setRedemptionEpochConfig(uint64, uint256)` | Epoch duration for epoch-level mint cap |
| `redemptionEpochMintCap` | `setRedemptionEpochConfig(uint64, uint256)` | Max tokens mintable per epoch (0 = no epoch cap) |

### Index Weight Validation

When updating index-related action weights (mint, burn, mint-position, burn-position), the admin facet enforces:

```solidity
function _isIndexWeightConfigValid(
    uint256 mintPoints,
    uint256 burnPoints,
    uint256 mintPositionPoints,
    uint256 burnPositionPoints
) internal pure returns (bool) {
    return mintPositionPoints > mintPoints && burnPositionPoints > burnPoints;
}
```

This applies to both single updates (`setPointsPerAction`) and batch updates (`setPointsPerActionBatch`). Non-index action types bypass this check.

---

## Redemption & Emissions

PoP includes a complete on-chain redemption path for converting points into emission tokens. This is designed to be activated by governance when the protocol is ready for token launch.

### Redemption Flow

```
User calls redeem(pointsIn, minTokenOut, to)
    │
    ├── Check redemptionEnabled == true
    ├── Check redemptionToken != address(0)
    │
    ▼
tokenOut = (pointsIn × tokensPerPointWad) / 1e18
    │
    ├── Check tokenOut > 0
    ├── Check globalMintCap not exceeded
    ├── Check epochMintCap not exceeded
    │
    ▼
burn(pointsKey, pointsIn, BURN_REASON_REDEEM)
    │
    ▼
IPointsEmissionToken(token).mint(to, tokenOut)
    │
    ▼
Emit PointsRedeemed event
```

### Two Redemption Paths

```solidity
// Account-based (uses systemPositionKey for the caller)
function redeem(uint256 pointsIn, uint256 minTokenOut, address to)
    external nonReentrant returns (uint256 tokenOut);

// Position-based (uses specific Position NFT key, requires ownership)
function redeemFromPosition(uint256 positionId, uint256 pointsIn, uint256 minTokenOut, address to)
    external nonReentrant returns (uint256 tokenOut);
```

### Rate Calculation

```
tokensPerPointWad = tokens minted per point burned, scaled to 1e18

Example: tokensPerPointWad = 0.5e18
  → 100 points burned → 50 tokens minted
```

### Mint Caps

Two independent caps protect against runaway emissions:

| Cap | Scope | Effect |
|-----|-------|--------|
| **Global mint cap** | Lifetime total | Once `redemptionTotalMinted` reaches `redemptionGlobalMintCap`, all further redemptions revert |
| **Epoch mint cap** | Per time window | Each epoch (defined by `redemptionEpochLengthSecs`) has its own cap tracked in `redemptionMintedByEpoch[epochId]` |

Epoch ID is computed as:
```solidity
uint64 epochId = uint64(block.timestamp / epochLengthSecs);
```

### Emission Token Interface

The emission token must implement `IPointsEmissionToken`:

```solidity
interface IPointsEmissionToken {
    function mint(address to, uint256 amount) external;
}
```

The `PointsRedemptionFacet` calls `mint()` on the configured token after burning points. The token contract must authorize the diamond as a minter.

### Slippage Protection

Both `redeem()` and `redeemFromPosition()` accept a `minTokenOut` parameter. If the computed output is below this threshold, the transaction reverts with `Points_SlippageExceeded()`. This protects against governance rate changes between transaction submission and execution.

---

## Data Models

### Points Storage

All PoP state is stored in a single diamond storage slot managed by `LibPoints`:

```solidity
bytes32 internal constant STORAGE_POSITION = keccak256("equallend.points.storage");

struct PointsStorage {
    // Core balances
    mapping(bytes32 => uint256) balances;           // Current point balance per key
    mapping(bytes32 => uint256) earned;              // Lifetime earned per key
    mapping(bytes32 => uint256) burned;              // Lifetime burned per key
    uint256 totalEarned;                             // Global lifetime earned
    uint256 totalBurned;                             // Global lifetime burned

    // Action configuration
    mapping(bytes32 => uint256) pointsPerAction;     // Points per action type (0 = disabled)
    mapping(bytes32 => uint256) accrualCooldownSecs; // Cooldown per action type

    // Anti-farming state
    uint256 dailyPointsCap;                          // Max points per guard key per day
    mapping(bytes32 => uint64) lastAccrualDay;       // Last accrual day per guard key
    mapping(bytes32 => uint256) accruedOnDay;         // Points accrued today per guard key
    mapping(bytes32 => mapping(bytes32 => uint64)) lastAccrualTs; // Last accrual timestamp per (guardKey, actionType)

    // Redemption configuration
    address redemptionToken;                         // Emission token contract
    bool redemptionEnabled;                          // Whether redemption is active
    uint64 redemptionEpochLengthSecs;                // Epoch duration for epoch cap
    uint256 tokensPerPointWad;                       // Tokens per point (1e18 scale)
    uint256 redemptionGlobalMintCap;                 // Lifetime max tokens mintable
    uint256 redemptionTotalMinted;                   // Lifetime tokens minted
    uint256 redemptionEpochMintCap;                  // Max tokens per epoch
    mapping(uint64 => uint256) redemptionMintedByEpoch; // Tokens minted per epoch ID
}
```

### Key Derivation

| Key Type | Derivation | Used For |
|----------|-----------|----------|
| **Position key** | `keccak256(abi.encodePacked(nftContract, tokenId))` | Point balance credit |
| **Account (guard) key** | `LibPositionHelpers.systemPositionKey(account)` | Cooldown/cap enforcement |
| **Action type** | `keccak256("POINTS_ACTION_NAME")` | Weight/cooldown lookup |

### Default Points Token ID (PositionNFT)

```solidity
// In PositionNFT.sol
mapping(address => uint256) public defaultPointsTokenId;
```

This mapping is maintained automatically by the NFT transfer hook and mint function. It provides O(1) lookup for default-position routing without requiring enumeration.

---

## View Functions

### Balance Queries

```solidity
// Current balance by wallet address (uses systemPositionKey)
function getPoints(address user) external view returns (uint256);

// Current balance by arbitrary points key
function getPointsByKey(bytes32 pointsKey) external view returns (uint256);

// Current balance by Position NFT token ID
function getPointsByPosition(uint256 positionId) external view returns (uint256);

// Batch balance query by addresses
function getPointsBatch(address[] calldata users) external view returns (uint256[] memory);

// Batch balance query by keys
function getPointsBatchByKey(bytes32[] calldata pointsKeys) external view returns (uint256[] memory);
```

### Earned/Burned Totals

```solidity
// Lifetime earned by address
function getPointsEarned(address user) external view returns (uint256);

// Lifetime earned by key
function getPointsEarnedByKey(bytes32 pointsKey) external view returns (uint256);

// Lifetime burned by address
function getPointsBurned(address user) external view returns (uint256);

// Lifetime burned by key
function getPointsBurnedByKey(bytes32 pointsKey) external view returns (uint256);

// Global totals
function getTotalPointsEarned() external view returns (uint256);
function getTotalPointsBurned() external view returns (uint256);
```

### Configuration Queries

```solidity
// Points weight for an action type
function getPointsPerAction(bytes32 actionType) external view returns (uint256);

// Cooldown for an action type
function getAccrualCooldown(bytes32 actionType) external view returns (uint256);

// Daily cap
function getDailyPointsCap() external view returns (uint256);

// Points accrued today by address/key
function getPointsAccruedToday(address user) external view returns (uint256);
function getPointsAccruedTodayByKey(bytes32 pointsKey) external view returns (uint256);
```

### Redemption Queries

```solidity
// Preview token output for a given points input
function previewRedeem(uint256 pointsIn) external view returns (uint256 tokenOut);

// Full redemption configuration
function getRedemptionConfig() external view returns (
    address token,
    bool enabled,
    uint256 tokensPerPointWad,
    uint256 globalMintCap,
    uint256 totalMinted,
    uint64 epochLengthSecs,
    uint256 epochMintCap,
    uint256 epochMintedCurrent
);
```

---

## Integration Guide

### For Facet Developers (Adding PoP to a New Action)

#### Position-Direct Actions

For actions that operate on a specific Position NFT:

```solidity
import {LibPoints} from "../libraries/LibPoints.sol";

// Define a new action constant in LibPoints.sol:
// bytes32 internal constant ACTION_MY_NEW_ACTION = keccak256("POINTS_MY_NEW_ACTION");

// At the end of the action handler, after all state mutations:
LibPoints.accrueToKey(msg.sender, positionKey, LibPoints.ACTION_MY_NEW_ACTION);
```

#### Default-Position Actions

For actions where the caller may not reference a specific position (swaps, flash loans):

```solidity
// At the end of the action handler:
LibPoints.accrueToDefaultPosition(msg.sender, LibPoints.ACTION_MY_NEW_ACTION);
```

This resolves the caller's default Position NFT. If they have none, no points accrue.

#### Self-Match Suppression (Direct Flows)

For bilateral actions where self-matching should be suppressed:

```solidity
function _accrueDirectAcceptIfNotSelfMatch(
    address callerOwner,
    bytes32 callerKey,
    address counterpartyOwner,
    bytes32 actionType
) internal {
    if (callerOwner == counterpartyOwner) return;
    LibPoints.accrueToKey(callerOwner, callerKey, actionType);
}
```

#### Configuration

After adding a new action type:
1. Add the `bytes32` constant to `LibPoints.sol`
2. Add the accrual call in the relevant facet
3. Add the action to `InitializePointsConfig.s.sol` with the appropriate weight tier
4. Configure cooldown via `PointsAdminFacet.setAccrualCooldown()` if needed

### For Frontend/Indexer Integration

#### Indexing Points Events

```solidity
// Accrual
event PointsAccrued(bytes32 indexed pointsKey, bytes32 indexed actionType, uint256 amount);

// Burns
event PointsBurned(bytes32 indexed pointsKey, bytes32 indexed reason, uint256 amount);

// Redemptions
event PointsRedeemed(address indexed user, address indexed to, uint256 pointsIn, uint256 tokenOut);

// Config changes
event PointsPerActionUpdated(bytes32 indexed actionType, uint256 newAmount);
event PointsDailyCapUpdated(uint256 newDailyCap);
event PointsAccrualCooldownUpdated(bytes32 indexed actionType, uint256 cooldownSecs);
```

#### Displaying User Points

```solidity
// For a wallet address
uint256 balance = PointsViewFacet(diamond).getPoints(userAddress);
uint256 earned = PointsViewFacet(diamond).getPointsEarned(userAddress);
uint256 burned = PointsViewFacet(diamond).getPointsBurned(userAddress);
uint256 today = PointsViewFacet(diamond).getPointsAccruedToday(userAddress);

// For a specific Position NFT
uint256 posBalance = PointsViewFacet(diamond).getPointsByPosition(tokenId);
```

### For Users

#### Earning Points

1. **Own a Position NFT** — required for all point accrual
2. **Perform protocol actions** — deposit, borrow, swap, create derivatives, etc.
3. **Points accrue automatically** — no claiming or staking required
4. **Check balance** — via view functions or UI

#### Redeeming Points (When Enabled)

```solidity
// Preview output
uint256 tokenOut = PointsViewFacet(diamond).previewRedeem(pointsAmount);

// Redeem (burns points, mints emission tokens)
PointsRedemptionFacet(diamond).redeem(pointsAmount, minTokenOut, recipientAddress);

// Or redeem from a specific position
PointsRedemptionFacet(diamond).redeemFromPosition(positionId, pointsAmount, minTokenOut, recipientAddress);
```

---

## Worked Examples

### Example 1: Basic Deposit and Borrow Accrual

**Scenario:** Alice deposits into a pool and borrows. Default config: deposit = 2 pts, borrow = 2 pts, no cooldowns, no daily cap.

**Step 1: Mint Position with Deposit**
```
Alice calls mintPositionWithDeposit(poolId, 1000 USDC, ...)
→ Position NFT #7 minted to Alice
→ defaultPointsTokenId[Alice] = 7 (first mint)
→ positionKey = keccak256(nft, 7)
→ LibPoints.accrueToKey(Alice, positionKey, ACTION_MINT_POSITION_WITH_DEPOSIT)
→ pointsPerAction[ACTION_MINT_POSITION_WITH_DEPOSIT] = 2
→ No cooldown, no cap
→ balances[positionKey] += 2
→ earned[positionKey] += 2
→ totalEarned += 2
→ Emit PointsAccrued(positionKey, ACTION_MINT_POSITION_WITH_DEPOSIT, 2)
```

**Step 2: Borrow Rolling**
```
Alice calls openRollingFromPosition(7, poolId, 900 USDC, ...)
→ LibPoints.accrueToKey(Alice, positionKey, ACTION_BORROW_ROLLING)
→ balances[positionKey] += 2
→ Total for position #7: 4 points
```

**Step 3: Repay**
```
Alice calls makePaymentFromPosition(7, poolId, 900 USDC, ...)
→ LibPoints.accrueToKey(Alice, positionKey, ACTION_REPAY_ROLLING)
→ balances[positionKey] += 2
→ Total for position #7: 6 points
```

### Example 2: Swap with Default Position Routing

**Scenario:** Bob owns Position NFT #12 and performs an AMM auction swap. Default config: swap = 1 pt.

```
Bob calls swapAmmAuction(auctionId, amountIn, ...)
→ LibPoints.accrueToDefaultPosition(Bob, ACTION_SWAP_AMM_AUCTION)
→ resolveDefaultPositionKey(Bob):
    → defaultPointsTokenId[Bob] = 12
    → ownerOf(12) == Bob ✓
    → pointsKey = getPositionKey(12)
→ _accrueWithGuard(pointsKey, guardKey=systemKey(Bob), ACTION_SWAP_AMM_AUCTION)
→ balances[positionKey(12)] += 1
```

**If Bob had no Position NFT:**
```
Bob calls swapAmmAuction(...)
→ LibPoints.accrueToDefaultPosition(Bob, ACTION_SWAP_AMM_AUCTION)
→ resolveDefaultPositionKey(Bob):
    → nft.balanceOf(Bob) == 0
    → return (bytes32(0), false)
→ hasPosition == false → return
→ No points accrued, swap still executes normally
```

### Example 3: Cooldown Enforcement

**Scenario:** Carol performs two deposits 30 seconds apart. Cooldown for deposits is set to 60 seconds.

```
Governance: setAccrualCooldown(ACTION_DEPOSIT_TO_POSITION, 60)

T=0: Carol deposits 500 USDC
→ _accrueWithGuard(positionKey, guardKey, ACTION_DEPOSIT_TO_POSITION)
→ cooldownSecs = 60
→ lastAccrualTs[guardKey][ACTION_DEPOSIT] = 0 (first time)
→ Credit 2 points ✓
→ lastAccrualTs[guardKey][ACTION_DEPOSIT] = T

T=30: Carol deposits another 500 USDC
→ _accrueWithGuard(positionKey, guardKey, ACTION_DEPOSIT_TO_POSITION)
→ lastTs = T, block.timestamp = T+30
→ T+30 < T+60 → cooldown not elapsed
→ return (no points, deposit still succeeds)

T=61: Carol deposits again
→ T+61 >= T+60 → cooldown elapsed
→ Credit 2 points ✓
```

### Example 4: Daily Cap with Partial Credit

**Scenario:** Dave has a daily cap of 10 points. He performs many actions in one day.

```
Governance: setDailyPointsCap(10)

Action 1 (deposit, 2 pts): accruedOnDay = 0 + 2 = 2   → credited 2
Action 2 (borrow, 2 pts):  accruedOnDay = 2 + 2 = 4   → credited 2
Action 3 (repay, 2 pts):   accruedOnDay = 4 + 2 = 6   → credited 2
Action 4 (deposit, 2 pts): accruedOnDay = 6 + 2 = 8   → credited 2
Action 5 (borrow, 2 pts):  remaining = 10 - 8 = 2      → credited 2, accruedOnDay = 10
Action 6 (repay, 2 pts):   accruedOnDay = 10 >= 10     → return (capped)
Action 7 (swap, 1 pt):     accruedOnDay = 10 >= 10     → return (capped)

Next UTC day:
Action 8 (deposit, 2 pts): new day detected, accruedOnDay reset to 0
                            accruedOnDay = 0 + 2 = 2   → credited 2
```

### Example 5: Self-Match Suppression in Direct Lending

**Scenario:** Eve owns Position NFTs #20 and #21. She posts a lender offer from #20 and tries to accept it from #21.

```
Eve posts lender offer from position #20:
→ LibPoints.accrueToKey(Eve, positionKey(20), ACTION_DIRECT_POST_LENDER_OFFER)
→ 2 points credited to positionKey(20) ✓

Eve accepts her own offer from position #21:
→ _accrueDirectAcceptIfNotSelfMatch(
    callerOwner = Eve,
    callerKey = positionKey(21),
    counterpartyOwner = Eve,    ← same owner!
    ACTION_DIRECT_ACCEPT_LENDER_OFFER
  )
→ callerOwner == counterpartyOwner → return
→ No points credited (self-match suppressed)
→ Agreement still executes normally
```

### Example 6: Redemption with Epoch Cap

**Scenario:** Governance enables redemption. Rate = 0.5 tokens per point. Epoch = 1 day. Epoch cap = 1000 tokens. Global cap = 100,000 tokens.

```
Governance:
  setRedemptionToken(emissionTokenAddress)
  setRedemptionRate(0.5e18)  // 0.5 tokens per point
  setRedemptionEpochConfig(86400, 1000)  // 1 day epochs, 1000 token cap
  setRedemptionGlobalMintCap(100000)
  setRedemptionEnabled(true)

Frank has 500 points. He redeems 400:
→ tokenOut = (400 × 0.5e18) / 1e18 = 200 tokens
→ globalCap check: 0 + 200 ≤ 100,000 ✓
→ epochCap check: 0 + 200 ≤ 1,000 ✓
→ burn(pointsKey, 400, BURN_REASON_REDEEM)
→ redemptionTotalMinted += 200
→ redemptionMintedByEpoch[epochId] += 200
→ IPointsEmissionToken(token).mint(Frank, 200)
→ Frank's points: 500 - 400 = 100 remaining
→ Frank receives 200 emission tokens

Later same day, Grace tries to redeem 2000 points (= 1000 tokens):
→ epochMintedByEpoch[epochId] = 200 + 1000 = 1200 > 1000
→ revert Points_EpochMintCapExceeded()

Grace waits for next epoch and redeems successfully.
```

### Example 7: Position NFT Transfer and Points

**Scenario:** Henry transfers Position NFT #30 (with 50 accrued points) to Irene.

```
Before transfer:
  positionKey(30) = keccak256(nft, 30)
  balances[positionKey(30)] = 50
  Henry's guardKey cooldown state: lastAccrualTs[guardKey(Henry)][...] = T

Transfer: Henry → Irene
  → positionKey(30) unchanged (derived from contract + tokenId)
  → balances[positionKey(30)] = 50 (unchanged, moves with NFT)
  → defaultPointsTokenId[Henry] reassigned to next token or 0
  → defaultPointsTokenId[Irene] = 30 (if she had no default)

After transfer:
  Irene owns 50 points via positionKey(30)
  Irene's guardKey is fresh (her own cooldown/cap state)
  Henry's cooldown state is unaffected (stays with his guardKey)
```

---

## Error Reference

### Accrual Errors

PoP accrual never reverts. Ineligible actions silently skip point credit. This is by design: protocol actions must never fail due to points configuration.

### Burn Errors

| Error | Cause |
|-------|-------|
| `Points_InsufficientBalance()` | Burn amount exceeds current balance for the points key |

### Redemption Errors

| Error | Cause |
|-------|-------|
| `Points_RedemptionDisabled()` | `redemptionEnabled` is false |
| `Points_RedemptionTokenNotSet()` | `redemptionToken` is `address(0)` |
| `Points_RedemptionOutputZero()` | Computed token output is 0 (points too small or rate too low) |
| `Points_GlobalMintCapExceeded()` | `redemptionTotalMinted + tokenOut` exceeds `redemptionGlobalMintCap` |
| `Points_EpochMintCapExceeded()` | `redemptionMintedByEpoch[epochId] + tokenOut` exceeds `redemptionEpochMintCap` |
| `Points_SlippageExceeded()` | Computed `tokenOut` is less than caller's `minTokenOut` |
| `Points_InvalidRedeemRecipient()` | Recipient address is `address(0)` |

### Admin Errors

| Error | Cause |
|-------|-------|
| `Points_ArrayLengthMismatch()` | `actionTypes` and `amounts` arrays have different lengths in batch update |
| `Points_IndexPositionWeightInvalid()` | Index weight update would violate `MINT_POSITION > MINT` or `BURN_POSITION > BURN` invariant |

---

## Events

### Accrual Events

```solidity
/// @notice Emitted when points are credited to a points ledger key
/// @param pointsKey The points ledger key receiving the credit
/// @param actionType The action type that triggered accrual
/// @param amount The number of points credited (may be less than configured weight if daily cap applies)
event PointsAccrued(bytes32 indexed pointsKey, bytes32 indexed actionType, uint256 amount);
```

### Burn Events

```solidity
/// @notice Emitted when points are burned from a points ledger key
/// @param pointsKey The points ledger key being debited
/// @param reason The burn reason (e.g., BURN_REASON_REDEEM)
/// @param amount The number of points burned
event PointsBurned(bytes32 indexed pointsKey, bytes32 indexed reason, uint256 amount);
```

### Redemption Events

```solidity
/// @notice Emitted when points are redeemed for emission tokens (in LibPoints)
/// @param pointsKey The points ledger key that burned points (position key or account/system key)
/// @param pointsIn The number of points burned
/// @param tokenOut The number of emission tokens to be minted
event PointsRedemptionRecorded(bytes32 indexed pointsKey, uint256 pointsIn, uint256 tokenOut);

/// @notice Emitted when redemption completes (in PointsRedemptionFacet)
/// @param user The wallet address that initiated redemption
/// @param to The recipient of emission tokens
/// @param pointsIn The number of points burned
/// @param tokenOut The number of emission tokens minted
event PointsRedeemed(address indexed user, address indexed to, uint256 pointsIn, uint256 tokenOut);
```

### Configuration Events

```solidity
/// @notice Emitted when points weight for an action type changes
event PointsPerActionUpdated(bytes32 indexed actionType, uint256 newAmount);

/// @notice Emitted when the daily points cap changes
event PointsDailyCapUpdated(uint256 newDailyCap);

/// @notice Emitted when the cooldown for an action type changes
event PointsAccrualCooldownUpdated(bytes32 indexed actionType, uint256 cooldownSecs);

/// @notice Emitted when the redemption token address changes
event PointsRedemptionTokenUpdated(address indexed token);

/// @notice Emitted when redemption is enabled or disabled
event PointsRedemptionEnabledUpdated(bool enabled);

/// @notice Emitted when the redemption rate changes
event PointsRedemptionRateUpdated(uint256 tokensPerPointWad);

/// @notice Emitted when the global mint cap changes
event PointsRedemptionGlobalMintCapUpdated(uint256 newCap);

/// @notice Emitted when epoch configuration changes
event PointsRedemptionEpochConfigUpdated(uint64 epochLengthSecs, uint256 epochMintCap);
```

---

## Security Considerations

### 1. Silent Non-Accrual

All guard checks (cooldown, daily cap, zero weight, no position) result in silent returns, never reverts. This is critical: protocol actions must never fail because of points configuration. A misconfigured cooldown or a disabled action type must not break deposits, borrows, or swaps.

### 2. Position-Key Isolation

Points balances are isolated per position key. A user with multiple Position NFTs has separate balances per position. There is no automatic aggregation. This prevents cross-position balance manipulation and makes accounting deterministic.

### 3. Guard-Key Rate Limiting

Cooldowns and daily caps use the account-level guard key (`systemPositionKey(account)`), not the position key. This prevents a user from circumventing rate limits by spreading actions across multiple positions they own.

### 4. Self-Match Suppression

Direct lending acceptance flows check `callerOwner == counterpartyOwner` and suppress points for same-owner matches. This prevents the simplest form of self-dealing point farming. Cross-wallet Sybil attacks are not addressed at the contract level and are deferred to the redemption/snapshot policy layer.

### 5. Index Weight Invariant

The admin facet enforces `INDEX_MINT_POSITION > INDEX_MINT` and `INDEX_BURN_POSITION > INDEX_BURN` on every weight update. This prevents governance from accidentally making wallet-level index actions more rewarding than position-level actions, which would undermine the position-centric design.

### 6. Redemption Caps

Two independent caps protect against runaway emissions:
- **Global cap**: Lifetime ceiling on total tokens minted via redemption
- **Epoch cap**: Per-time-window ceiling that limits burst redemption

Both caps are checked atomically during `consumeRedemption()`. The burn happens before the mint, so a failed cap check does not leave points in a partially burned state (the entire transaction reverts).

### 7. Reentrancy Protection

`PointsRedemptionFacet.redeem()` and `redeemFromPosition()` use `nonReentrant` modifiers. The emission token `mint()` call is the last external call, but reentrancy protection is applied defensively since the emission token contract is governance-configured and could be arbitrary.

### 8. No Oracle Dependency

All PoP state is derived from on-chain actions and block timestamps. There are no external oracle calls, no off-chain data dependencies, and no keeper requirements. Day boundaries and epoch boundaries use `block.timestamp` division.

### 9. Governance Access Control

All configuration setters in `PointsAdminFacet` enforce `LibAccess.enforceOwnerOrTimelock()`. There is no public configuration surface. Weight changes, cooldown changes, cap changes, and redemption configuration all require governance authorization.

### 10. Known Limitations and Gaming Vectors

The current design uses fixed-per-action scoring (not value-weighted). This creates known farming vectors documented in `POINTS_SYSTEM_GAMING_REVIEW.md`:

| Vector | Severity | Mitigation |
|--------|----------|------------|
| Direct offer post/cancel loops | Critical | Governance can set cooldowns or disable post-action weights |
| Flash loan dust (fee rounds to 0) | High | Governance can set cooldowns; future: gate on `fee > 0` |
| Swap dust loops | High | Governance can set cooldowns and daily caps |
| Borrow/repay loops with tiny amounts | High | Governance can set cooldowns per action |
| Index mint/burn ping-pong | Medium | Index weight invariant + cooldowns |
| Cross-wallet Sybil | Medium | Deferred to redemption/snapshot policy layer |

These are deliberate design tradeoffs: the system prioritizes simplicity and composability over perfect Sybil resistance. Governance has the tools (cooldowns, caps, weight zeroing) to respond to observed farming behavior.

---

## Appendix: Correctness Properties

### Property 1: Balance Conservation
For any points key:
```
balances[key] = earned[key] - burned[key]
```

### Property 2: Global Conservation
```
totalEarned = Σ(earned[key]) for all keys
totalBurned = Σ(burned[key]) for all keys
```

### Property 3: Silent Non-Revert
For any protocol action that includes a `LibPoints.accrue*` call:
```
The action NEVER reverts due to points logic.
All guard failures result in early return, not revert.
```

### Property 4: Cooldown Monotonicity
For any (guardKey, actionType) pair:
```
lastAccrualTs[guardKey][actionType] only increases (or stays 0)
```

### Property 5: Daily Cap Bound
For any guard key on any UTC day:
```
accruedOnDay[guardKey] ≤ dailyPointsCap (when dailyPointsCap > 0)
```

### Property 6: Index Weight Ordering
At all times after configuration:
```
pointsPerAction[INDEX_MINT_POSITION] > pointsPerAction[INDEX_MINT]
pointsPerAction[INDEX_BURN_POSITION] > pointsPerAction[INDEX_BURN]
```

### Property 7: Redemption Cap Enforcement
```
redemptionTotalMinted ≤ redemptionGlobalMintCap (when > 0)
redemptionMintedByEpoch[epochId] ≤ redemptionEpochMintCap (when > 0)
```

### Property 8: Burn Before Mint
In `consumeRedemption()`:
```
burn(pointsKey, pointsIn, ...) executes BEFORE redemptionTotalMinted += tokenOut
If any cap check fails, the entire transaction reverts (no partial state)
```

### Property 9: No-Position Exclusion
For default-position routing:
```
if balanceOf(account) == 0 in PositionNFT → no points accrue
```

### Property 10: Self-Match Exclusion
For Direct acceptance flows:
```
if callerOwner == counterpartyOwner → no points accrue
```

---

**Document Version:** 1.0
