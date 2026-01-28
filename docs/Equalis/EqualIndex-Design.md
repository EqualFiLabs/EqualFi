# EqualIndex - Design Document

**Version:** 3.0

---

## Table of Contents

1. [Overview](#overview)
2. [How It Works](#how-it-works)
3. [Architecture](#architecture)
4. [Index Creation](#index-creation)
5. [Minting](#minting)
6. [Burning](#burning)
7. [Flash Loans](#flash-loans)
8. [Position Integration](#position-integration)
9. [Fee System](#fee-system)
10. [IndexToken Contract](#indextoken-contract)
11. [Data Models](#data-models)
12. [View Functions](#view-functions)
13. [Integration Guide](#integration-guide)
14. [Worked Examples](#worked-examples)
15. [Error Reference](#error-reference)
16. [Events](#events)
17. [Security Considerations](#security-considerations)

---

## Overview

EqualIndex is a tokenized asset basket system that enables users to create, manage, and interact with multi-asset index tokens. The system provides deterministic bundle composition, per-asset fee structures, and seamless integration with the Equalis Position NFT system.

### Key Characteristics

| Feature | Description |
|---------|-------------|
| **Deterministic Bundles** | Fixed asset amounts per index unit (1e18 scale) |
| **Per-Asset Fees** | Configurable mint/burn fees for each basket component |
| **Fee Pot Distribution** | Accumulated fees distributed proportionally to holders on redemption |
| **Flash Loan Support** | Borrow proportional basket amounts with fees |
| **Centralized Fee Routing** | Fees split between Fee Index, Fee Pot, and Protocol (ACI/FI/Treasury) |
| **Position Integration** | Mint/burn using Position NFT collateral (centralized encumbrance system) |
| **Pool Fee Routing** | Configurable portion of fees routed to underlying asset pool depositors |
| **No External Oracles** | Deterministic pricing based on bundle composition |


### System Participants

| Role | Description |
|------|-------------|
| **Index Creator** | Governance or fee-paying user who defines basket composition |
| **Minter** | User who deposits basket assets to receive index tokens |
| **Holder** | Owner of index tokens with proportional claim on vault + fee pots |
| **Redeemer** | Holder who burns index tokens to receive underlying assets |
| **Flash Borrower** | Contract that borrows basket assets within a single transaction |
| **Position Holder** | Position NFT owner who can mint/burn using encumbered collateral |

### High-Level Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                    EqualIndex V3 System                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐           │
│  │    Admin     │  │   Actions    │  │    View      │           │
│  │    Facet     │  │    Facet     │  │    Facet     │           │
│  └──────────────┘  └──────────────┘  └──────────────┘           │
│         │                 │                 │                   │
│         └─────────────────┼─────────────────┘                   │
│                           │                                     │
│                    ┌──────────────┐                             │
│                    │  Position    │                             │
│                    │    Facet     │                             │
│                    └──────────────┘                             │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│                      Per-Index Tokens                           │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐           │
│  │ IndexToken 0 │  │ IndexToken 1 │  │ IndexToken N │           │
│  │   (ERC20)    │  │   (ERC20)    │  │   (ERC20)    │           │
│  └──────────────┘  └──────────────┘  └──────────────┘           │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
         │                    │                    │
         ▼                    ▼                    ▼
   ┌──────────┐        ┌──────────┐        ┌──────────┐
   │  ERC20   │        │ Protocol │        │ Position │
   │  Assets  │        │ Treasury │        │   NFTs   │
   └──────────┘        └──────────┘        └──────────┘
```

---

## How It Works

### The Index Token Model

An EqualIndex represents a basket of assets with fixed proportions. Each index unit (1e18) corresponds to specific amounts of each underlying asset defined at creation.

**Example:** An ETH-BTC index might define:
- 1 index unit = 0.5 ETH + 0.01 BTC

### Dual-Balance Architecture

Each index maintains two separate balance types per asset:

1. **Vault Balances**: Core NAV (Net Asset Value) backing index tokens
2. **Fee Pots**: Accumulated fees distributed to holders on redemption

```
Total Redemption Value = Vault Share + Fee Pot Share - Burn Fee
```

### Price Interpretation

Index tokens have no external price oracle. Value is determined entirely by:
- Bundle composition (fixed at creation)
- Current vault balances (may exceed bundle requirements due to fees)
- Fee pot balances (accumulated from operations)

---

## Architecture

### Contract Structure

```
src/equalindex/
├── EqualIndexBaseV3.sol          # Shared storage and helpers
├── EqualIndexAdminFacetV3.sol    # Index creation and configuration
├── EqualIndexActionsFacetV3.sol  # Mint, burn, flash loan operations
├── EqualIndexPositionFacet.sol   # Position NFT integration
├── EqualIndexFacetV3.sol         # Composite facet for testing
└── IndexToken.sol                # Per-index ERC20 token

src/views/
└── EqualIndexViewFacetV3.sol     # Read-only query functions

src/libraries/
├── LibEqualIndex.sol             # Storage, events, constants
├── LibEncumbrance.sol            # Centralized encumbrance tracking (all types)
├── LibIndexEncumbrance.sol       # Index-specific encumbrance wrapper
├── LibEqualIndexFees.sol         # Index action fee configuration
├── LibFeeIndex.sol               # Pool fee index accounting
└── LibFeeRouter.sol              # Centralized fee routing (ACI/FI/Treasury)
```

### Facet Responsibilities

| Facet | Responsibility | Key Functions |
|-------|---------------|---------------|
| **EqualIndexAdminFacetV3** | Index creation and configuration | `createIndex`, `setIndexFees`, `setPaused`, `setPoolFeeShareBps`, `setMintBurnFeeIndexShareBps` |
| **EqualIndexActionsFacetV3** | Core operations with direct transfers | `mint`, `burn`, `flashLoan` |
| **EqualIndexPositionFacet** | Position-based operations | `mintFromPosition`, `burnFromPosition` |
| **EqualIndexViewFacetV3** | Read-only queries | `getIndex`, `getIndexAssets`, `getVaultBalance`, `getFeePot` |


### Storage Architecture

```solidity
struct EqualIndexStorage {
    uint256 indexCount;                                              // Total indexes created
    mapping(uint256 => Index) indexes;                               // Index configurations
    mapping(uint256 => mapping(address => uint256)) vaultBalances;   // NAV per asset
    mapping(uint256 => mapping(address => uint256)) feePots;         // Accumulated fees per asset
    mapping(address => uint256) protocolBalances;                    // Legacy (fees now transfer directly)
    mapping(uint256 => uint256) indexToPoolId;                       // Index token pool mapping
    uint16 poolFeeShareBps;                                          // Share routed to pool fee index (flash loans)
    uint16 mintBurnFeeIndexShareBps;                                 // Share routed to pool fee index (mint/burn)
}
```

### Balance Types

| Type | Purpose | Updated By |
|------|---------|------------|
| **Vault Balances** | Core NAV backing tokens | Mint (increase), Burn (decrease), Flash (temporary) |
| **Fee Pots** | Holder rewards | Mint fees, Burn fees, Flash fees |
| **Protocol Balances** | Legacy tracking | Deprecated - fees transfer directly to treasury |

---

## Index Creation

### Process

```solidity
function createIndex(CreateIndexParams calldata p) 
    external payable returns (uint256 indexId, address token);
```

**Steps:**
1. Validate array lengths match (assets, bundleAmounts, mintFeeBps, burnFeeBps)
2. Validate fee caps (mint ≤ 10%, burn ≤ 10%, flash ≤ 10%, protocol cut ≤ 50%)
3. Validate bundle amounts (all > 0)
4. Validate asset uniqueness (no duplicates)
5. Verify all assets have existing Equalis pools
6. Check access control and collect creation fee if applicable
7. Deploy new IndexToken contract
8. Create pool for the index token itself
9. Store index configuration
10. Emit `IndexCreated` event

### Access Control

| Caller | Fee Required | Behavior |
|--------|--------------|----------|
| **Governance (owner/timelock)** | None (must send 0 ETH) | Free creation |
| **Public users** | `indexCreationFee` | Must pay exact fee to treasury |
| **Public (fee = 0)** | N/A | Creation disabled |

### Parameters

```solidity
struct CreateIndexParams {
    string name;              // Token name (e.g., "DeFi Blue Chip Index")
    string symbol;            // Token symbol (e.g., "DBI")
    address[] assets;         // Basket component addresses
    uint256[] bundleAmounts;  // Amount per 1e18 index units
    uint16[] mintFeeBps;      // Per-asset mint fee (basis points)
    uint16[] burnFeeBps;      // Per-asset burn fee (basis points)
    uint16 flashFeeBps;       // Flash loan fee (basis points)
    uint16 protocolCutBps;    // Protocol share of fees (basis points)
}
```

### Validation Caps

| Parameter | Maximum | Rationale |
|-----------|---------|-----------|
| Mint fee per asset | 1000 bps (10%) | Prevent excessive entry costs |
| Burn fee per asset | 1000 bps (10%) | Prevent excessive exit costs |
| Flash fee | 1000 bps (10%) | Competitive with other flash providers |
| Protocol cut | 5000 bps (50%) | Ensure holders receive majority of fees |

### Pool Requirement

All basket assets must have existing Equalis pools. This ensures:
- Fee routing to pool depositors works correctly
- Position-based minting can encumber collateral
- Consistent accounting across the protocol

---

## Minting

### Direct Minting (Token Transfers)

```solidity
function mint(uint256 indexId, uint256 units, address to) 
    external returns (uint256 minted);
```

**Steps:**
1. Validate units > 0 and multiple of INDEX_SCALE (1e18)
2. Verify index exists and is not paused
3. For each asset:
   - Calculate required amount: `bundleAmount × units / INDEX_SCALE`
   - Calculate mint fee: `required × mintFeeBps / 10_000`
   - Transfer `required + fee` from user
   - Verify received amount ≥ expected (fee-on-transfer protection)
   - Credit `required` to vault balance
   - Split fee between fee pot and protocol
4. Calculate minted units based on proportional NAV increase
5. Mint index tokens to recipient
6. Record mint details on IndexToken
7. Emit `Minted` event

### Proportional Minting

For indexes with existing supply, minted units preserve proportional ownership:

```solidity
// First mint (zero supply)
minted = units;

// Subsequent mints
for each asset:
    mintedForAsset = (vaultCredit × totalSupplyBefore) / vaultBalanceBefore;
    minted = min(minted, mintedForAsset);
```

This ensures no dilution of existing holders.

### Fee Calculation

```
Required Amount = Bundle Amount × Units ÷ INDEX_SCALE
Mint Fee = Required Amount × Mint Fee BPS ÷ 10,000
Total Transfer = Required Amount + Mint Fee
```


---

## Burning

### Direct Burning (Token Redemption)

```solidity
function burn(uint256 indexId, uint256 units, address to) 
    external returns (uint256[] memory assetsOut);
```

**Steps:**
1. Validate units > 0 and multiple of INDEX_SCALE
2. Verify index exists and is not paused
3. Verify caller has sufficient index tokens
4. Verify units ≤ total supply
5. For each asset:
   - Calculate NAV share: `vaultBalance × units / totalSupply`
   - Calculate fee pot share: `feePotBalance × units / totalSupply`
   - Calculate gross redemption: `navShare + potShare`
   - Calculate burn fee: `gross × burnFeeBps / 10_000`
   - Split burn fee between fee pot and protocol
   - Transfer net payout to recipient
6. Reduce total supply
7. Burn index tokens from caller
8. Record burn details on IndexToken
9. Emit `Burned` event

### Redemption Calculation

```
NAV Share = Vault Balance × Units ÷ Total Supply
Fee Pot Share = Fee Pot Balance × Units ÷ Total Supply
Gross Redemption = NAV Share + Fee Pot Share
Burn Fee = Gross Redemption × Burn Fee BPS ÷ 10,000
Net Payout = Gross Redemption - Burn Fee
```

### Fee Pot Distribution

Holders receive their proportional share of accumulated fees on redemption:
- Fee pots grow from mint fees, burn fees, and flash fees
- Each burn distributes `feePot × units / totalSupply` to the redeemer
- Remaining fee pot continues accumulating for other holders

---

## Flash Loans

### Process

```solidity
function flashLoan(uint256 indexId, uint256 units, address receiver, bytes calldata data) external;
```

**Steps:**
1. Validate units > 0 and multiple of INDEX_SCALE
2. Verify index exists and is not paused
3. Verify units ≤ total supply and total supply > 0
4. For each asset:
   - Record contract balance before
   - Calculate loan amount: `vaultBalance × units / totalSupply`
   - Calculate fee: `loanAmount × flashFeeBps / 10_000`
   - Reduce vault balance by loan amount
   - Transfer loan amount to receiver
5. Call receiver callback: `onEqualIndexFlashLoan(...)`
6. For each asset:
   - Verify contract balance ≥ balance before + fee
   - Restore vault balance
   - Split fee between pool fee index, fee pot, and protocol
7. Emit `FlashLoaned` event

### Receiver Interface

```solidity
interface IEqualIndexFlashReceiver {
    function onEqualIndexFlashLoan(
        uint256 indexId,
        uint256 units,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata feeAmounts,
        bytes calldata data
    ) external;
}
```

### Flash Fee Distribution

Flash loan fees are distributed through the centralized fee mechanism:

| Recipient | Share | Purpose |
|-----------|-------|---------|
| **Fee Index (Pool Depositors)** | `poolFeeShareBps` (default 10%) | Rewards underlying pool depositors |
| **Fee Pot** | Remainder after protocol | Distributed to index holders |
| **Protocol (ACI/FI/Treasury)** | `protocolCutBps` of remainder | Protocol revenue via LibFeeRouter |

---

## Position Integration

### Overview

Position NFT holders can mint and burn index tokens using their encumbered collateral, without transferring assets externally. This enables capital-efficient index exposure.

### Encumbrance System

The encumbrance system uses a centralized architecture via `LibEncumbrance`, which tracks all encumbrance types per position and pool. `LibIndexEncumbrance` provides a thin wrapper for index-specific operations:

```solidity
// LibEncumbrance - Centralized storage for all encumbrance types
struct Encumbrance {
    uint256 directLocked;       // Direct lending locked collateral
    uint256 directLent;         // Direct lending lent amounts
    uint256 directOfferEscrow;  // Direct offer escrow amounts
    uint256 indexEncumbered;    // Index-encumbered principal
}

struct EncumbranceStorage {
    // positionKey => poolId => all encumbrance components
    mapping(bytes32 => mapping(uint256 => Encumbrance)) encumbrance;
    
    // positionKey => poolId => indexId => encumbered for specific index
    mapping(bytes32 => mapping(uint256 => mapping(uint256 => uint256))) encumberedByIndex;
}

// Total encumbered = directLocked + directLent + directOfferEscrow + indexEncumbered
```

This centralized design ensures consistent available principal calculations across all protocol features.

### Minting from Position

```solidity
function mintFromPosition(uint256 positionId, uint256 indexId, uint256 units) 
    external returns (uint256 minted);
```

**Requirements:**
- Caller must own the Position NFT
- Position must be a member of all required pools
- Sufficient unencumbered principal for each asset

**Process:**
1. Validate ownership and pool membership
2. For each asset:
   - Calculate required amount + fee
   - Verify available principal ≥ total needed
   - Encumber the amount from position
   - Credit to vault balance
   - Route fees to pool fee index and fee pot
3. Mint index tokens to the diamond (held for position)
4. Credit index tokens to position's principal in the index token pool

### Burning from Position

```solidity
function burnFromPosition(uint256 positionId, uint256 indexId, uint256 units) 
    external returns (uint256[] memory assetsOut);
```

**Process:**
1. Validate ownership and index token balance in position
2. For each asset:
   - Calculate NAV share and fee pot share
   - Unencumber NAV portion back to position
   - Credit fee pot portion as new principal (yield)
   - Route burn fees to pool fee index and fee pot
3. Burn index tokens from diamond
4. Reduce position's index token principal


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

### Position vs Direct Minting

| Aspect | Direct Minting | Position Minting |
|--------|----------------|------------------|
| **Asset Source** | External wallet | Position collateral |
| **Token Recipient** | Any address | Position (in index pool) |
| **Capital Efficiency** | Requires full transfer | Uses existing deposits |
| **Fee Index Share** | `mintBurnFeeIndexShareBps` (40%) | `poolFeeShareBps` (10%) |
| **Fee Routing** | FI + Fee pot + Protocol | FI + Fee pot |
| **Composability** | Standard ERC20 | Integrated with Equalis |

---

## Fee System

### Fee Distribution Architecture

All index fees are distributed through a centralized 3-way split mechanism:

```solidity
function _distributeIndexFee(
    uint256 indexId,
    Index storage idx,
    address asset,
    uint256 fee,
    uint16 feeIndexShareBps
) internal {
    // 1. Fee Index share (to underlying asset pool depositors)
    uint256 poolShare = fee × feeIndexShareBps / 10_000;
    LibFeeIndex.accrueWithSourceUsingBacking(poolId, poolShare, INDEX_FEE_SOURCE, poolShare);
    
    // 2. Split remainder between Fee Pot and Protocol routing
    uint256 remainder = fee - poolShare;
    uint256 potFee = remainder × (10_000 - protocolCutBps) / 10_000;
    uint256 protocolFee = remainder - potFee;
    
    // Fee Pot: distributed to index holders on redemption
    feePots[indexId][asset] += potFee;
    
    // Protocol: routed through LibFeeRouter (ACI/FI/Treasury split)
    LibFeeRouter.routeSamePool(poolId, protocolFee, INDEX_FEE_SOURCE, true, protocolFee);
}
```

### Fee Index Share Parameters

| Parameter | Default | Purpose |
|-----------|---------|---------|
| `poolFeeShareBps` | 1000 (10%) | Fee Index share for flash loan fees |
| `mintBurnFeeIndexShareBps` | 4000 (40%) | Fee Index share for mint/burn fees |

### Protocol Fee Routing

Protocol fees are routed through `LibFeeRouter.routeSamePool`, which splits fees between:

| Recipient | Configuration | Purpose |
|-----------|---------------|---------|
| **Treasury** | `treasurySplitBps` | Protocol revenue |
| **Active Credit Index (ACI)** | `activeCreditSplitBps` | Rewards for active borrowers |
| **Fee Index (FI)** | Remainder | Rewards for pool depositors |

### Fee Sources

| Operation | Fee Basis | Fee Rate | Fee Index Share | Distribution |
|-----------|-----------|----------|-----------------|--------------|
| **Mint** | Required asset amount | Per-asset `mintFeeBps` | 40% (default) | FI + Fee pot + Protocol |
| **Burn** | Gross redemption amount | Per-asset `burnFeeBps` | 40% (default) | FI + Fee pot + Protocol |
| **Flash Loan** | Loan amount (NAV share) | `flashFeeBps` | 10% (default) | FI + Fee pot + Protocol |
| **Position Mint** | Required asset amount | Per-asset `mintFeeBps` | `poolFeeShareBps` | FI + Fee pot |
| **Position Burn** | Gross redemption amount | Per-asset `burnFeeBps` | `poolFeeShareBps` | FI + Fee pot |

### Fee Pot Distribution

Holders receive their proportional share of accumulated fees on redemption:
- Fee pots grow from mint fees, burn fees, and flash fees
- Each burn distributes `feePot × units / totalSupply` to the redeemer
- Remaining fee pot continues accumulating for other holders

### Treasury Behavior

| Treasury State | Behavior |
|----------------|----------|
| **Configured** | Protocol share routed through `LibFeeRouter` (ACI/FI/Treasury split) |
| **Not configured** | Full fee goes to fee pot (no protocol accumulation) |

### Administrative Functions

```solidity
// Update fee parameters (timelock only)
function setIndexFees(
    uint256 indexId,
    uint16[] calldata mintFeeBps,
    uint16[] calldata burnFeeBps,
    uint16 flashFeeBps,
    uint16 protocolCutBps
) external;

// Pause/unpause index (timelock only)
function setPaused(uint256 indexId, bool paused) external;

// Set pool fee share for flash loans (timelock only)
function setPoolFeeShareBps(uint16 shareBps) external;

// Set pool fee share for mint/burn operations (timelock only)
function setMintBurnFeeIndexShareBps(uint16 shareBps) external;
```

---

## IndexToken Contract

Each index has a dedicated ERC20 token deployed at creation with enhanced functionality.

### Token Standards

| Standard | Purpose |
|----------|---------|
| **ERC20** | Standard transfer, approve, balanceOf |
| **ERC20Permit** | Gasless approvals via EIP-2612 signatures |
| **ReentrancyGuard** | Protection against reentrancy attacks |

### Access Control

| Role | Permissions |
|------|-------------|
| **Minter (Diamond)** | `mintIndexUnits`, `burnIndexUnits`, `recordMintDetails`, `recordBurnDetails`, `setFlashFeeBps` |
| **Anyone** | All view functions |

### Bundle Configuration

```solidity
address[] internal _assets;           // Basket component addresses
uint256[] internal _bundleAmounts;    // Amount per 1e18 index units
uint256 public bundleCount;           // Number of assets in bundle
bytes32 public bundleHash;            // keccak256(abi.encode(assets, bundleAmounts))
uint256 public flashFeeBps;           // Flash loan fee (synced from index)
```

### Fee Tracking

```solidity
uint256 public totalMintFeesCollected;  // Tracked in fee units (index units equivalent)
uint256 public totalBurnFeesCollected;  // Tracked in fee units (index units equivalent)
```


### Preview Functions

```solidity
// Preview mint requirements
function previewMint(uint256 units) external view returns (
    address[] memory assets,
    uint256[] memory required,
    uint256[] memory feeAmounts
);

// Preview redemption at current NAV (includes fee pot share)
function previewRedeem(uint256 units) external view returns (
    address[] memory assets,
    uint256[] memory netOut,
    uint256[] memory feeAmounts
);

// Preview flash loan amounts and fees
function previewFlashLoan(uint256 units) external view returns (
    address[] memory assets,
    uint256[] memory loanAmounts,
    uint256[] memory feeAmounts
);
```

### Paginated Functions

For large bundles, paginated versions prevent gas limits:

```solidity
function previewMintPaginated(uint256 units, uint256 offset, uint256 limit) external view;
function previewRedeemPaginated(uint256 units, uint256 offset, uint256 limit) external view;
function previewFlashLoanPaginated(uint256 units, uint256 offset, uint256 limit) external view;
function assetsPaginated(uint256 offset, uint256 limit) external view returns (address[] memory);
function bundleAmountsPaginated(uint256 offset, uint256 limit) external view returns (uint256[] memory);
```

### Introspection Functions

```solidity
// Get all assets
function assets() external view returns (address[] memory);

// Get all bundle amounts
function bundleAmounts() external view returns (uint256[] memory);

// Full snapshot
function snapshot() external view returns (
    address[] memory assets,
    uint256[] memory bundleAmounts,
    uint256 totalUnits,
    uint256 flashFeeBps
);

// Solvency check - returns true if vault covers required bundles
function isSolvent() external view returns (bool);
```

---

## Data Models

### Index Structure (Storage)

```solidity
struct Index {
    address[] assets;         // Basket component addresses
    uint256[] bundleAmounts;  // Amount per 1e18 index units
    uint16[] mintFeeBps;      // Per-asset mint fee
    uint16[] burnFeeBps;      // Per-asset burn fee
    uint16 flashFeeBps;       // Flash loan fee
    uint16 protocolCutBps;    // Protocol share of fees
    uint256 totalUnits;       // Total supply
    address token;            // IndexToken contract address
    bool paused;              // Pause state
}
```

### IndexView Structure (Query Response)

```solidity
struct IndexView {
    address[] assets;
    uint256[] bundleAmounts;
    uint16[] mintFeeBps;
    uint16[] burnFeeBps;
    uint16 flashFeeBps;
    uint16 protocolCutBps;
    uint256 totalUnits;
    address token;
    bool paused;
}
```

### Constants

```solidity
uint256 constant INDEX_SCALE = 1e18;  // Base unit for index tokens
```

---

## View Functions

### EqualIndexViewFacetV3

```solidity
// Get full index configuration
function getIndex(uint256 indexId) external view returns (IndexView memory);

// Get paginated asset configuration
function getIndexAssets(uint256 indexId, uint256 offset, uint256 limit) external view returns (
    address[] memory assets,
    uint256[] memory bundleAmounts,
    uint16[] memory mintFeeBps,
    uint16[] memory burnFeeBps
);

// Get number of assets in index
function getIndexAssetCount(uint256 indexId) external view returns (uint256);

// Get vault balance for specific asset
function getVaultBalance(uint256 indexId, address asset) external view returns (uint256);

// Get fee pot balance for specific asset
function getFeePot(uint256 indexId, address asset) external view returns (uint256);

// Get protocol balance for specific asset (legacy - always zero)
function getProtocolBalance(address asset) external view returns (uint256);
```

---

## Integration Guide

### For Developers

#### Creating an Index (Governance)

```solidity
EqualIndexBaseV3.CreateIndexParams memory params = EqualIndexBaseV3.CreateIndexParams({
    name: "DeFi Blue Chip Index",
    symbol: "DBI",
    assets: [weth, wbtc, link],
    bundleAmounts: [0.5e18, 0.01e8, 10e18],  // 0.5 ETH, 0.01 BTC, 10 LINK per unit
    mintFeeBps: [50, 50, 50],                 // 0.5% mint fee each
    burnFeeBps: [50, 50, 50],                 // 0.5% burn fee each
    flashFeeBps: 30,                          // 0.3% flash fee
    protocolCutBps: 2000                      // 20% to protocol
});

(uint256 indexId, address token) = adminFacet.createIndex(params);
```

#### Minting Index Tokens

```solidity
// 1. Preview requirements
(address[] memory assets, uint256[] memory required, uint256[] memory fees) = 
    IndexToken(token).previewMint(10e18);  // 10 index units

// 2. Approve all assets
for (uint i = 0; i < assets.length; i++) {
    IERC20(assets[i]).approve(diamond, required[i]);
}

// 3. Mint
uint256 minted = actionsFacet.mint(indexId, 10e18, msg.sender);
```


#### Burning Index Tokens

```solidity
// 1. Preview redemption
(address[] memory assets, uint256[] memory netOut, uint256[] memory fees) = 
    IndexToken(token).previewRedeem(5e18);  // 5 index units

// 2. Burn (no approval needed - burns from caller)
uint256[] memory received = actionsFacet.burn(indexId, 5e18, msg.sender);
```

#### Flash Loan

```solidity
contract MyFlashReceiver is IEqualIndexFlashReceiver {
    function executeFlash(uint256 indexId, uint256 units) external {
        // Initiate flash loan
        actionsFacet.flashLoan(indexId, units, address(this), "");
    }
    
    function onEqualIndexFlashLoan(
        uint256 indexId,
        uint256 units,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata feeAmounts,
        bytes calldata data
    ) external {
        // Use borrowed assets...
        
        // Repay: ensure contract has amounts + fees for each asset
        for (uint i = 0; i < assets.length; i++) {
            IERC20(assets[i]).transfer(msg.sender, amounts[i] + feeAmounts[i]);
        }
    }
}
```

#### Position-Based Minting

```solidity
// Requires: Position NFT with sufficient deposits in all basket asset pools

// 1. Mint from position
uint256 minted = positionFacet.mintFromPosition(
    positionId,
    indexId,
    10e18  // 10 index units
);

// Index tokens are credited to position's principal in the index token pool
```

### For Users

#### Buying Index Exposure

1. **Check index composition**: Use `getIndex()` or `IndexToken.snapshot()`
2. **Preview costs**: Use `previewMint()` to see required amounts
3. **Approve assets**: Approve diamond for each basket asset
4. **Mint**: Call `mint()` with desired units
5. **Hold**: Index tokens accrue fee pot share over time

#### Redeeming Index Tokens

1. **Preview redemption**: Use `previewRedeem()` to see expected output
2. **Burn**: Call `burn()` with units to redeem
3. **Receive**: Get proportional share of vault + fee pots minus burn fee

#### Using Position Integration

1. **Deposit to position**: Ensure position has principal in all basket asset pools
2. **Mint from position**: Call `mintFromPosition()` - no external transfers needed
3. **Burn from position**: Call `burnFromPosition()` - assets return to position

---

## Worked Examples

### Example 1: Equity Mining (Single-Pool Yield Amplification)

Equity Mining is the simplest form of Yield Amplification Loop. It works within a single pool and amplifies your share of the Active Credit Index (ACI) yield stream.

#### The Core Concept

In traditional DeFi, "Liquidity Mining" rewards you for passively parking capital. Equity Mining flips this: you get rewarded for *utilizing* the protocol — taking on debt and paying maintenance fees.

Think of it as "Proof of Work" for yield:
- **Input:** You pay MaintenanceIndex fees on your position (your "electricity bill")
- **Output:** You earn a pro-rata share of the protocol's `activeCreditPrincipalTotal` (your "hashrate")
- **Reward:** You claim fees from penalties and platform activity (the "block reward")

#### Why "Equity Mining"?

You are actively working (paying fees, managing debt) to extract a share of the protocol's revenue, rather than just passively parking capital. This frames it as an ownership activity — you're mining your way into protocol equity.

#### The Single-Pool Loop

**Example asset:** stETH and a single-asset Index Token called `istETH`.

| Step | Action | Result |
|------|--------|--------|
| 1 | **Deposit stETH** | Deposit stETH into the Equalis stETH pool |
| 2 | **Mint istETH** | Use deposited stETH to mint the istETH Index Token |
| 3 | **Deposit istETH** | Deposit istETH into the Equalis istETH pool |
| 4 | **Borrow istETH** | Take 0% interest same-asset credit (pay origination fee) |
| 5 | **Burn borrowed istETH** | Releases underlying stETH from the index vault |
| 6 | **Repeat from Step 2** | Loop to amplify your active credit position |

```
┌─────────────────────────────────────────────────────────────────┐
│                    Equity Mining Loop Flow                      │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   ┌──────────┐   deposit   ┌──────────┐    mint    ┌──────────┐ │
│   │  stETH   │ ──────────► │  stETH   │ ─────────► │  istETH  │ │
│   │          │             │   Pool   │            │  Index   │ │
│   └──────────┘             └──────────┘            └────┬─────┘ │
│        ▲                                                │       │
│        │                                          deposit│       │
│        │                                                ▼       │
│        │                   ┌──────────┐            ┌──────────┐ │
│        │       burn        │ Borrowed │   borrow   │  istETH  │ │
│        └───────────────────│  istETH  │◄───────────│   Pool   │ │
│                            └──────────┘            └──────────┘ │
│                                                                 │
│   Each loop iteration increases your Active Credit position     │
│   ACI yield accrues based on your share of total active debt    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

#### Yield Sources in Equity Mining

| Source | Mechanism |
|--------|-----------|
| **ACI Yield** | Pro-rata share of protocol fees based on your active credit principal |
| **Index Token Fee Pot** | When you burn istETH, you receive accumulated fees from other users' mints/burns |
| **Underlying LST Yield** | The stETH continues earning staking rewards while in the index vault |

#### The 24-Hour Time Gate

The Active Credit Index includes a 24-hour time gate. This prevents flash-loan farming:
- You cannot instantly "spin up" your ACI position and capture a snapshot
- New debt takes 24 hours to reach full ACI weight
- If you unwind the loop, you lose your ACI share immediately
- To rebuild, you wait another 24 hours

This makes the liquidity *active and persistent*, not opportunistic.

#### Why Single-Pool Works Here

Unlike the multi-pool Yield Amplification Loop (Example 2), Equity Mining works in a single pool because:
- You're targeting **ACI yield**, not the full FeeIndex
- ACI is calculated on `activeCreditPrincipalTotal` across the protocol
- Fee base normalization affects FeeIndex accrual, but ACI accrual is based on debt, not deposits
- Your looped debt *is* your mining power

#### The Incentive Alignment

Equity Mining creates "sticky" users with aligned incentives:
- Higher utilization → more maintenance fees → more ACI rewards to distribute
- More active debt → higher TVL metrics
- Users competing for ACI share drives protocol activity

You've effectively aligned yield farmers with the metrics that make the protocol successful.

#### Honest Risk Statement

- Maintenance fees are real costs — if ACI yield is lower than fees paid, you lose money
- The 24-hour gate means you can't exit instantly at full value
- Amplified positions amplify losses if the underlying LST depegs or protocol activity drops
- "No liquidations" means no oracle-triggered auctions, not "no losses"

> **Equity Mining:** actively work the protocol to earn your share of its revenue.

---

### Example 2: Yield Amplification Loop (Multi-Pool)

Yield Amplification Loop increases your exposure to platform yield streams, not price exposure.

This example explains how to use LST-backed Index Tokens plus Equalis 0% same-asset credit to amplify yield exposure without oracle-triggered liquidations.

#### The Key Idea

Equalis has a single canonical pool per token, and platform activity routes fees into shared indices like FeeIndex and ACI. Yields are driven by usage across the whole platform, not just by one isolated strategy.

The loop lets a user increase their "active notional" inside the system using same-asset, 0% interest credit (with a known origination fee). That increased active notional can increase the share of protocol yield streams they earn, depending on the fee base rules.

#### How It Differs from Leverage

This is not classic leverage. Classic leverage is cross-asset borrowing that increases directional price exposure. That comes later with P2P cross-asset borrowing.

Yield Amplification Loop is cashflow amplification. It increases how much of the system's fee and incentive streams you're exposed to, while avoiding liquidation auctions and oracle thresholds.

#### What is an Index Token here?

An Index Token is a fully backed wrapper:
- When you mint an Index Token, you deposit the underlying assets (e.g., stETH, rETH, wstETH) into the index contract
- The Index Token supply only exists because the underlying exists in custody
- Burning an Index Token returns the underlying, pro rata, based on the index composition
- Single-asset indexes are allowed for fractionalization or tranching without changing the backing rule

#### What is a 0% same-asset loan?

Equalis offers credit where the collateral and the debt are the same asset (the same Index Token). There is no interest rate. Instead, there is a fixed origination fee, and positions are governed by deterministic rules like payment schedules and fixed penalties.

**Key consequence:**
- There is no third-party liquidation market
- There is no oracle price trigger that forces an auction
- Positions resolve by rules, not by selling collateral into the market
- "No liquidations" means no oracle-triggered auction liquidations, not "no losses"

#### The Loop, Step by Step

**Example assets:** LSTs (stETH, rETH, etc.) and an Index Token called `iLST`.

| Step | Action | Result |
|------|--------|--------|
| 1 | **Mint iLST** | Deposit LST underlyings into the index vault and mint iLST |
| 2 | **Deposit iLST into Equalis pool** | Your iLST becomes collateral |
| 3 | **Borrow iLST at 0% interest** | Pay a fixed origination fee, borrow the same Index Token you deposited |
| 4 | **Burn borrowed iLST** | Burning reduces iLST supply and releases the underlying LSTs from the index vault |
| 5 | **Redeploy withdrawn LSTs** | Use them to increase your active participation across indices |
| 6 | **Repeat** | Loop again by minting additional iLST with redeployed assets |

```
┌─────────────────────────────────────────────────────────────────┐
│                  Yield Amplification Loop Flow                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   ┌──────────┐    mint     ┌──────────┐    deposit   ┌────────┐ │
│   │   LSTs   │ ──────────► │   iLST   │ ───────────► │ Equalis│ │
│   │(stETH,   │             │  Index   │              │  Pool  │ │
│   │ rETH)    │             │  Token   │              │        │ │
│   └──────────┘             └──────────┘              └────┬───┘ │
│        ▲                                                  │     │
│        │                                                  │     │
│        │                                            borrow│     │
│        │                                          (0% int)│     │
│        │                                                  ▼     │
│        │                   ┌──────────┐              ┌────────┐ │
│        │       burn        │ Borrowed │              │ iLST   │ │
│        └───────────────────│   iLST   │◄─────────────│ Credit │ │
│                            └──────────┘              └────────┘ │
│                                                                 │
│   Redeploy LSTs to increase active participation across indices │
│   Repeat loop to scale exposure to protocol yield streams       │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

#### Why This is Different from Classic Leverage

Classic leverage loops rely on oracle-priced collateral and liquidation auctions. In stress, they can cascade.

**Yield Amplification Loop removes that failure mode:**
- No liquidation bots
- No auction slippage
- No oracle wick liquidations
- If a position breaks the rules (e.g., missed payment), it resolves deterministically inside the system

#### The Honest Benefit Statement

Users do this when they believe:
- Platform activity will be high (more fees into FeeIndex)
- ACI incentives will be meaningful
- Deterministic enforcement is preferable to liquidation-based systems

#### The Honest Risk Statement

This can amplify outcomes. If platform activity is low, yields will be lower. Users can also lose value via fees and rule violations. "No liquidations" means no oracle-triggered auction liquidations, not "no losses."

#### Rolling Loans and "Perpetual" Operation

This loop can be run on a rolling loan structure:
- As long as required periodic payments are made, the position remains active
- The loop can be maintained indefinitely, subject to risk limits and system parameters
- The user experience is closer to "servicing a credit line" than "dodging a liquidation price"

#### What Happens if Someone Defaults?

Because collateral and debt are the same asset (iLST), default does not create bad debt.

**Resolution is simple:**
1. The position's collateral is used to net out the debt in the same unit
2. The defaulter loses their equity wedge (and any penalties or forfeited incentives)
3. That loss flows to the pool and benefits non-defaulting participants through the fee and yield distribution logic

**Defaults are contained.** They do not force external market selling.

#### How Much Yield Amplification is Possible?

With repeated looping at high LTV, theoretical max gross exposure approaches significant multiples of the initial deposit.

**In practice, amplification is constrained by:**
- Protocol caps
- Utilization limits
- Origination fees
- Risk haircuts by asset
- Exposure concentration rules

#### Risk: What Diversification Does and Does Not Do

An index with multiple LSTs reduces single-name concentration risk:
- If one LST has an idiosyncratic protocol failure, a basket reduces the damage relative to a single-LST loop
- This is most helpful for "one protocol broke" tails

**Diversification does not eliminate systemic risk:**
- LSTs can become highly correlated during market stress
- Events affecting the ETH staking ecosystem or liquidity can impact many LSTs simultaneously

A basket is a risk reducer, not a risk eraser.

#### Why the Loop Requires a Second Index Token (Different Pool)

A critical implementation detail: **the yield amplification loop must use a different index token for each iteration**, even if the underlying assets are identical.

**The Problem: Fee Base Normalization**

Equalis uses fee base normalization to prevent fee farming loops. When you borrow the same asset you deposited, your fee accrual weight is reduced:

```
feeBase = principal - sameAssetDebt
```

If you deposit iLST, borrow iLST, burn it, re-mint iLST, and redeposit into the **same pool**, your fee base gets netted down by your debt. The looped portion earns zero fees, killing the economic benefit.

**The Solution: Ratio Index Tokens**

Create two index tokens with identical underlying compositions but in separate Equalis pools:

| Token | Pool | Underlyings |
|-------|------|-------------|
| iLST-A | Pool A | stETH, rETH, wstETH |
| iLST-B | Pool B | stETH, rETH, wstETH (same ratios) |

**The Modified Loop:**

| Step | Action | Result |
|------|--------|--------|
| 1 | Mint iLST-A | Deposit LSTs, receive iLST-A |
| 2 | Deposit iLST-A into Pool A | iLST-A becomes collateral |
| 3 | Borrow iLST-A (0% interest, origination fee) | Same-asset credit from Pool A |
| 4 | Burn borrowed iLST-A | Releases underlying LSTs |
| 5 | **Mint iLST-B** (not iLST-A) | Deposit LSTs into different index |
| 6 | Deposit iLST-B into Pool B | iLST-B becomes collateral in Pool B |
| 7 | Borrow iLST-B, burn, repeat | Continue loop with alternating tokens |

**Why This Works:**

- Your debt in Pool A (iLST-A) does not reduce your fee base in Pool B (iLST-B)
- Each pool's fee base calculation is independent
- You earn full fee accrual on your iLST-B position despite having iLST-A debt elsewhere

```
Pool A: feeBase = iLST-A principal - iLST-A debt  (netted)
Pool B: feeBase = iLST-B principal - iLST-B debt  (separate accounting)
```

**Practical Implication:**

To run an effective yield amplification loop, you need at least two index tokens with the same underlying basket. The protocol can pre-deploy "ratio pairs" (e.g., iLST-A / iLST-B) specifically for this use case.

#### Summary

This loop combines:
- Fully backed Index Tokens
- 0% same-asset credit with fixed origination fees
- Deterministic enforcement instead of oracle liquidations
- **Ratio index token pairs to bypass fee base normalization**

The result is a yield amplification primitive designed to scale exposure to protocol yield streams while avoiding liquidation cascades and keeping default losses internalized.

> **Yield Amplification Loop:** a deterministic, no-liquidation way to scale exposure to protocol yield streams.

> **Important note:** This is a mechanism description, not financial advice. Amplified strategies can amplify losses, and users can lose principal if positions resolve against them or if platform activity is lower than expected.

---

### Example 3: Basic Index Creation and Minting

**Scenario:** Create a simple ETH-USDC index and mint 100 units.

**Step 1: Create Index**
```solidity
CreateIndexParams({
    name: "ETH-USDC 50/50",
    symbol: "EU50",
    assets: [weth, usdc],
    bundleAmounts: [0.5e18, 1000e6],  // 0.5 ETH + 1000 USDC per unit
    mintFeeBps: [100, 100],            // 1% mint fee
    burnFeeBps: [100, 100],            // 1% burn fee
    flashFeeBps: 50,                   // 0.5% flash fee
    protocolCutBps: 2000               // 20% to protocol
});
```

**Step 2: First Mint (100 units)**
```
Required ETH: 0.5 × 100 = 50 ETH
ETH Mint Fee: 50 × 1% = 0.5 ETH
Total ETH Transfer: 50.5 ETH

Required USDC: 1000 × 100 = 100,000 USDC
USDC Mint Fee: 100,000 × 1% = 1,000 USDC
Total USDC Transfer: 101,000 USDC

Minted: 100 index units (100e18)
```

**Step 3: Fee Distribution**
```
ETH Fee (0.5 ETH):
  - Fee Pot: 0.5 × 80% = 0.4 ETH
  - Protocol: 0.5 × 20% = 0.1 ETH

USDC Fee (1,000 USDC):
  - Fee Pot: 1,000 × 80% = 800 USDC
  - Protocol: 1,000 × 20% = 200 USDC
```

### Example 4: Redemption with Fee Pot

**Scenario:** Redeem 10 units after fees have accumulated.

**State Before:**
```
Total Supply: 100 units
Vault ETH: 50 ETH
Vault USDC: 100,000 USDC
Fee Pot ETH: 0.4 ETH
Fee Pot USDC: 800 USDC
```

**Redemption Calculation (10 units = 10%):**
```
NAV Share ETH: 50 × 10% = 5 ETH
NAV Share USDC: 100,000 × 10% = 10,000 USDC

Fee Pot Share ETH: 0.4 × 10% = 0.04 ETH
Fee Pot Share USDC: 800 × 10% = 80 USDC

Gross ETH: 5 + 0.04 = 5.04 ETH
Gross USDC: 10,000 + 80 = 10,080 USDC

Burn Fee ETH: 5.04 × 1% = 0.0504 ETH
Burn Fee USDC: 10,080 × 1% = 100.8 USDC

Net Payout ETH: 5.04 - 0.0504 = 4.9896 ETH
Net Payout USDC: 10,080 - 100.8 = 9,979.2 USDC
```

### Example 5: Flash Loan Arbitrage

**Scenario:** Borrow 50 units worth of assets for arbitrage.

**Flash Loan Amounts (50% of supply):**
```
Loan ETH: 50 × 50% = 25 ETH
Loan USDC: 100,000 × 50% = 50,000 USDC

Flash Fee ETH: 25 × 0.5% = 0.125 ETH
Flash Fee USDC: 50,000 × 0.5% = 250 USDC
```

**Fee Distribution (assuming 10% pool share, 20% protocol):**
```
ETH Fee (0.125 ETH):
  - Pool Fee Index: 0.125 × 10% = 0.0125 ETH
  - Remainder: 0.1125 ETH
    - Fee Pot: 0.1125 × 80% = 0.09 ETH
    - Protocol: 0.1125 × 20% = 0.0225 ETH
```


### Example 6: Position-Based Index Exposure

**Scenario:** Alice has a Position NFT with deposits and wants index exposure without external transfers.

**Alice's Position State:**
```
Position ID: 42
ETH Pool Principal: 100 ETH (unencumbered)
USDC Pool Principal: 200,000 USDC (unencumbered)
```

**Step 1: Mint 50 Index Units from Position**
```solidity
positionFacet.mintFromPosition(42, indexId, 50e18);
```

**Calculation:**
```
Required ETH: 0.5 × 50 = 25 ETH
ETH Fee: 25 × 1% = 0.25 ETH
Total ETH Encumbered: 25.25 ETH

Required USDC: 1000 × 50 = 50,000 USDC
USDC Fee: 50,000 × 1% = 500 USDC
Total USDC Encumbered: 50,500 USDC
```

**Position State After:**
```
ETH Pool Principal: 100 ETH (25.25 encumbered, 74.75 available)
USDC Pool Principal: 200,000 USDC (50,500 encumbered, 149,500 available)
Index Token Pool Principal: 50 index units
```

**Step 2: Burn 20 Index Units from Position**
```solidity
positionFacet.burnFromPosition(42, indexId, 20e18);
```

**Result:**
- NAV portion unencumbered back to position
- Fee pot portion credited as new principal (yield)
- Index token principal reduced by 20 units

### Example 7: Multi-Asset Index with Different Fees

**Scenario:** Create a diversified index with asset-specific fee tiers.

**Index Configuration:**
```solidity
CreateIndexParams({
    name: "Tiered Fee Index",
    symbol: "TFI",
    assets: [weth, wbtc, link, uni],
    bundleAmounts: [1e18, 0.05e8, 50e18, 100e18],
    mintFeeBps: [25, 50, 75, 100],   // 0.25%, 0.5%, 0.75%, 1%
    burnFeeBps: [25, 50, 75, 100],   // Same tiers
    flashFeeBps: 30,
    protocolCutBps: 1500             // 15% to protocol
});
```

**Rationale:**
- Lower fees for high-liquidity assets (ETH, BTC)
- Higher fees for smaller-cap assets (LINK, UNI)
- Incentivizes balanced portfolio construction

---

## Error Reference

### Input Validation Errors

| Error | Cause |
|-------|-------|
| `InvalidArrayLength()` | Mismatched array lengths in parameters |
| `InvalidParameterRange(string)` | Fee or protocol cut exceeds limits |
| `InvalidUnits()` | Units not multiple of INDEX_SCALE, exceeds supply, or insufficient balance |
| `InvalidBundleDefinition()` | Zero bundle amounts, duplicate assets, or transfer amount mismatch |

### Access Control Errors

| Error | Cause |
|-------|-------|
| `Unauthorized()` | Non-timelock attempting admin functions |
| `NotMinter()` | Unauthorized mint/burn attempt on IndexToken |
| `InvalidMinter()` | Zero address minter at IndexToken construction |
| `TreasuryNotSet()` | Treasury required but not configured |

### Creation Errors

| Error | Cause |
|-------|-------|
| `InsufficientIndexCreationFee(uint256 required, uint256 provided)` | Wrong fee amount sent |
| `IndexCreationFeeTransferFailed()` | Fee transfer to treasury failed |
| `NoPoolForAsset(address)` | Basket asset has no Equalis pool |
| `DefaultPoolConfigNotSet()` | Default pool config not initialized |
| `PoolAlreadyExists(uint256)` | Pool for index token already exists |

### Operational Errors

| Error | Cause |
|-------|-------|
| `UnknownIndex(uint256 indexId)` | Reference to non-existent index |
| `IndexPaused(uint256 indexId)` | Operation on paused index |
| `FlashLoanUnderpaid(uint256 indexId, address asset, uint256 expected, uint256 actual)` | Insufficient repayment |

### Position Integration Errors

| Error | Cause |
|-------|-------|
| `NotMemberOfRequiredPool(bytes32, uint256)` | Position not member of basket asset pool |
| `InsufficientUnencumberedPrincipal(uint256 required, uint256 available)` | Not enough available collateral |
| `InsufficientIndexTokens(uint256 requested, uint256 available)` | Position lacks index token balance |
| `PoolNotInitialized(uint256)` | Index token pool not created |
| `EncumbranceUnderflow(uint256 amount, uint256 current)` | Unencumber exceeds encumbered amount |

---

## Events

### Index Lifecycle Events

```solidity
event IndexCreated(
    uint256 indexed indexId,
    address indexed token,
    address[] assets,
    uint256[] bundleAmounts,
    uint16 flashFeeBps
);

event Paused(uint256 indexed indexId, bool paused);
```

### Operation Events

```solidity
event Minted(
    uint256 indexed indexId,
    address indexed to,
    uint256 units,
    uint256[] required
);

event Burned(
    uint256 indexed indexId,
    address indexed to,
    uint256 units,
    uint256[] assetsOut
);

event FlashLoaned(
    uint256 indexed indexId,
    address indexed receiver,
    uint256 units,
    uint256[] loanAmounts,
    uint256[] fees
);
```


### IndexToken Events

```solidity
event MintDetails(
    address indexed user,
    uint256 units,
    address[] assets,
    uint256[] assetAmounts,
    uint256[] feeAmounts
);

event BurnDetails(
    address indexed user,
    uint256 units,
    address[] assets,
    uint256[] assetAmounts,
    uint256[] feeAmounts
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

### 1. Proportional Ownership Preservation

Minting calculates units as the minimum proportional increase across all assets, preventing dilution of existing holders.

### 2. Fee-on-Transfer Protection

Mint operations verify received amounts match expected amounts, reverting if fee-on-transfer tokens cause shortfalls.

### 3. Solvency Invariant

The `isSolvent()` function verifies vault balances cover required bundle amounts for total supply. This should always return true under normal operation.

### 4. Reentrancy Protection

All state-changing functions use `nonReentrant` modifier. Flash loan callbacks execute after state updates.

### 5. Access Control

| Function | Access |
|----------|--------|
| `createIndex` | Governance (free) or public (with fee) |
| `setIndexFees`, `setPaused`, `setPoolFeeShareBps`, `setMintBurnFeeIndexShareBps` | Timelock only |
| `mint`, `burn`, `flashLoan` | Anyone (when not paused) |
| `mintFromPosition`, `burnFromPosition` | Position NFT owner only |

### 6. Encumbrance Isolation

Position encumbrance is tracked through the centralized `LibEncumbrance` library, which maintains separate tracking for:
- Direct lending locked collateral
- Direct lending lent amounts  
- Direct offer escrow amounts
- Index-encumbered principal

This centralized design ensures accurate available principal calculations across all protocol features and prevents double-counting.

### 7. Pool Requirement

All basket assets must have existing Equalis pools, ensuring consistent accounting and fee routing.

### 8. Treasury Dependency

Protocol fees only transfer when treasury is configured. Otherwise, full fees go to fee pots.

### 9. Pause Mechanism

Paused indexes reject mint/burn/flash operations while view functions remain accessible for transparency.

### 10. Bundle Immutability

Bundle composition (assets and amounts) is fixed at creation. Only fee parameters can be updated by governance.

---

## Appendix: Correctness Properties

### Property 1: Index Creation Validation
For any creation parameters, a valid index is created iff all parameters meet validation criteria and all assets have pools.

### Property 2: Fee Splitting Consistency
For any fee amount: `feeIndexShare + potShare + protocolShare = totalFee`, where `feeIndexShare = fee × feeIndexShareBps / 10_000` and `protocolShare = (fee - feeIndexShare) × protocolCutBps / 10_000`.

### Property 3: Minting Proportionality
For indexes with existing supply, minting preserves proportional ownership across all holders.

### Property 4: Burning Conservation
Total assets distributed equals proportional share of vault + fee pots minus burn fees.

### Property 5: Flash Loan Round Trip
Contract balance after repayment equals balance before plus fees for each asset.

### Property 6: Encumbrance Consistency
For any position: `LibEncumbrance.total(positionKey, poolId) = directLocked + directLent + directOfferEscrow + indexEncumbered`, and `indexEncumbered = Σ encumberedByIndex[positionKey][poolId][indexId]`.

### Property 7: Solvency Invariant
For any index: `vaultBalance[asset] >= bundleAmount[asset] × totalSupply / INDEX_SCALE`.

### Property 8: Position Balance Consistency
Index tokens minted to position equal position's principal in index token pool.

### Property 9: Fee Pot Monotonicity
Fee pots only increase (from fees) or decrease proportionally (from burns).

### Property 10: Access Control Enforcement
Administrative functions succeed iff caller is timelock.

---

**Document Version:** 3.1
**Last Updated:** January 2026

*Changes in 3.1: Updated to reflect centralized encumbrance system (LibEncumbrance), centralized fee routing (LibFeeRouter with ACI/FI/Treasury split), and new mintBurnFeeIndexShareBps parameter.*
