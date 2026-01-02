# EqualIndex V3 - Design Document

**Version:** 3.0  

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Index Creation](#index-creation)
4. [Minting](#minting)
5. [Burning](#burning)
6. [Flash Loans](#flash-loans)
7. [Fee System](#fee-system)
8. [IndexToken Contract](#indextoken-contract)
9. [Data Models](#data-models)
10. [View Functions](#view-functions)
11. [Error Handling](#error-handling)
12. [Events](#events)
13. [Testing Strategy](#testing-strategy)

---

## 1. Overview

EqualIndex V3 is a tokenized asset basket system that enables users to create, manage, and interact with multi-asset index tokens. The system provides:

- **Deterministic bundle composition**: Fixed asset amounts per index unit
- **Per-asset fee structures**: Configurable mint/burn fees for each asset
- **Fee pot distribution**: Accumulated fees distributed proportionally to holders on redemption
- **Flash loan capabilities**: Borrow proportional basket amounts with fees
- **Protocol revenue sharing**: Configurable split between fee pots and protocol treasury

### Key Design Principles

- **Dual-balance architecture**: Vault balances (NAV) and fee pots (accumulated fees)
- **Proportional ownership**: Minting preserves proportional share across all assets
- **Immediate protocol revenue**: Protocol fees transferred directly to treasury when configured
- **Diamond proxy pattern**: Modular facets for upgradeable functionality
- **No external oracles**: Deterministic pricing based on bundle composition

---

## 2. Architecture

### System Components

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
│                    │  Base V3     │                             │
│                    │  (Storage)   │                             │
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
   │  ERC20   │        │ Protocol │        │  Flash   │
   │  Assets  │        │ Treasury │        │ Receivers│
   └──────────┘        └──────────┘        └──────────┘
```

### Facet Responsibilities

| Facet | Responsibility | Key Functions |
|-------|---------------|---------------|
| **EqualIndexAdminFacetV3** | Index creation and configuration | `createIndex`, `setIndexFees`, `setPaused` |
| **EqualIndexActionsFacetV3** | Core operations | `mint`, `burn`, `flashLoan` |
| **EqualIndexViewFacetV3** | Read-only queries | `getIndex`, `getIndexAssets`, `getIndexAssetCount`, `getVaultBalance`, `getFeePot`, `getProtocolBalance` |

### Storage Architecture

```solidity
struct EqualIndexStorage {
    uint256 indexCount;
    mapping(uint256 => Index) indexes;
    mapping(uint256 => mapping(address => uint256)) vaultBalances;  // NAV per asset
    mapping(uint256 => mapping(address => uint256)) feePots;        // Accumulated fees per asset
}
```

### Balance Types

1. **Vault Balances**: Core NAV assets backing index tokens
2. **Fee Pots**: Accumulated fees distributed proportionally to holders on burn
3. **Protocol Balances**: Protocol share transferred directly to treasury when configured (no on-chain balance tracking)

---

## 3. Index Creation

### Process

```solidity
function createIndex(CreateIndexParams calldata p) 
    external payable returns (uint256 indexId, address token);
```

**Steps**:
1. Validate array lengths match (assets, bundleAmounts, mintFeeBps, burnFeeBps)
2. Validate fee caps (mint ≤ 10%, burn ≤ 10%, flash ≤ 10%, protocol cut ≤ 50%)
3. Validate bundle amounts (all > 0)
4. Validate asset uniqueness (no duplicates)
5. Check access control and collect creation fee if applicable
6. Deploy new IndexToken contract
7. Store index configuration
8. Emit `IndexCreated` event

### Access Control

- **Governance (owner/timelock)**: Free creation, no fee required (must send 0 ETH)
- **Public users**: Must pay `indexCreationFee` if configured
- **Permissionless disabled**: If `indexCreationFee = 0`, public creation is disabled

### Parameters

```solidity
struct CreateIndexParams {
    string name;              // Token name
    string symbol;            // Token symbol
    address[] assets;         // Basket component addresses
    uint256[] bundleAmounts;  // Amount per 1e18 index units
    uint16[] mintFeeBps;      // Per-asset mint fee (basis points)
    uint16[] burnFeeBps;      // Per-asset burn fee (basis points)
    uint16 flashFeeBps;       // Flash loan fee (basis points)
    uint16 protocolCutBps;    // Protocol share of fees (basis points)
}
```

### Validation Caps

| Parameter | Maximum |
|-----------|---------|
| Mint fee per asset | 1000 bps (10%) |
| Burn fee per asset | 1000 bps (10%) |
| Flash fee | 1000 bps (10%) |
| Protocol cut | 5000 bps (50%) |

---

## 4. Minting

### Process

```solidity
function mint(uint256 indexId, uint256 units, address to) 
    external returns (uint256 minted);
```

**Steps**:
1. Validate units > 0 and multiple of INDEX_SCALE (1e18)
2. Verify index exists and is not paused
3. For each asset:
   - Calculate required amount: `bundleAmount × units / INDEX_SCALE`
   - Calculate mint fee: `required × mintFeeBps / 10_000`
   - Transfer `required + fee` from user
   - Verify received amount is at least expected (fee-on-transfer protection; overpayment is not refunded)
   - Credit `required` to vault balance
   - Split fee between fee pot and protocol
4. Calculate minted units based on proportional NAV increase
5. Mint index tokens to recipient
6. Record mint details on IndexToken and emit event

### Proportional Minting

For indexes with existing supply, minted units are calculated as the minimum proportional increase across all assets:

```solidity
// First mint (zero supply)
minted = units;

// Subsequent mints
for each asset:
    mintedForAsset = (vaultCredit × totalSupplyBefore) / vaultBalanceBefore;
    minted = min(minted, mintedForAsset);
```

This ensures proportional ownership is preserved.

### Fee Calculation

```
Required Amount = Bundle Amount × Units ÷ INDEX_SCALE
Mint Fee = Required Amount × Mint Fee BPS ÷ 10,000
Total Transfer = Required Amount + Mint Fee
```

---

## 5. Burning

### Process

```solidity
function burn(uint256 indexId, uint256 units, address to) 
    external returns (uint256[] memory assetsOut);
```

**Steps**:
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
8. Record burn details on IndexToken and emit event

### Redemption Calculation

```
NAV Share = Vault Balance × Units ÷ Total Supply
Fee Pot Share = Fee Pot Balance × Units ÷ Total Supply
Gross Redemption = NAV Share + Fee Pot Share
Burn Fee = Gross Redemption × Burn Fee BPS ÷ 10,000
Net Payout = Gross Redemption - Burn Fee
```

---

## 6. Flash Loans

### Process

```solidity
function flashLoan(uint256 indexId, uint256 units, address receiver, bytes calldata data) external;
```

**Steps**:
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
   - Split fee between fee pot and protocol
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

---

## 7. Fee System

### Fee Split Mechanism

All fees are split between the fee pot (for holders) and protocol treasury:

```solidity
function _splitFee(uint256 fee, uint16 protocolCutBps, bool protocolEnabled)
    internal pure returns (uint256 potShare, uint256 protocolShare)
{
    if (fee == 0) return (0, 0);
    if (!protocolEnabled) {
        return (fee, 0);  // Full fee to pot when treasury unset
    }
    potShare = fee × (10_000 - protocolCutBps) / 10_000;
    protocolShare = fee - potShare;
}
```

### Fee Sources

| Operation | Fee Basis | Fee Rate |
|-----------|-----------|----------|
| Mint | Required asset amount | Per-asset `mintFeeBps` |
| Burn | Gross redemption amount | Per-asset `burnFeeBps` |
| Flash Loan | Loan amount (NAV share) | `flashFeeBps` |

### Fee Distribution

- **Fee Pot Share**: Accumulated in `feePots[indexId][asset]`, distributed to holders on burn
- **Protocol Share**: Transferred directly to treasury when configured

### Treasury Behavior

- **Treasury configured**: Protocol share transferred immediately on fee collection via `_creditProtocol`
- **Treasury not configured**: Full fee goes to fee pot (no protocol accumulation)

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
```

---

## 8. IndexToken Contract

Each index has a dedicated ERC20 token deployed at creation with the following features:

### Token Standards

- **ERC20**: Standard transfer, approve, balanceOf functionality
- **ERC20Permit**: Gasless approvals via EIP-2612 signatures
- **ReentrancyGuard**: Protection against reentrancy attacks

### Access Control

- **Minter**: Only the EqualIndex diamond can mint/burn tokens
- **Immutable**: `minter` and `indexId` are set at construction

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

### Paginated Preview Functions

For large bundles, paginated versions are available:

```solidity
function previewMintPaginated(uint256 units, uint256 offset, uint256 limit) external view;
function previewRedeemPaginated(uint256 units, uint256 offset, uint256 limit) external view;
function previewFlashLoanPaginated(uint256 units, uint256 offset, uint256 limit) external view;
```

### Introspection Functions

```solidity
// Get all assets
function assets() external view returns (address[] memory);

// Get all bundle amounts
function bundleAmounts() external view returns (uint256[] memory);

// Paginated asset list
function assetsPaginated(uint256 offset, uint256 limit) external view returns (address[] memory);

// Paginated bundle amounts
function bundleAmountsPaginated(uint256 offset, uint256 limit) external view returns (uint256[] memory);

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

## 9. Data Models

### Index Structure

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

### IndexView Structure

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

## 10. View Functions

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

// Get protocol balance for specific asset (always zero; protocol fees are transferred directly)
function getProtocolBalance(address asset) external view returns (uint256);
```

---

## 11. Error Handling

### Input Validation Errors

```solidity
error InvalidArrayLength();           // Mismatched array lengths
error InvalidParameterRange(string);  // Fee or protocol cut exceeds limits
error InvalidUnits();                 // Units not multiple of INDEX_SCALE, exceeds supply, or insufficient balance
error InvalidBundleDefinition();      // Zero bundle amounts, duplicate assets, or transfer amount mismatch
```

### Access Control Errors

```solidity
error Unauthorized();                 // Non-timelock attempting admin functions
error NotMinter();                    // Unauthorized mint/burn attempt on IndexToken
error InvalidMinter();                // Zero address minter at IndexToken construction
error TreasuryNotSet();               // Treasury required but not configured
```

### Creation Errors

```solidity
error InsufficientIndexCreationFee(uint256 required, uint256 provided);
error IndexCreationFeeTransferFailed();
```

### Operational Errors

```solidity
error UnknownIndex(uint256 indexId);  // Reference to non-existent index
error IndexPaused(uint256 indexId);   // Operation on paused index
error FlashLoanUnderpaid(uint256 indexId, address asset, uint256 expected, uint256 actual);
```

---

## 12. Events

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

---

## 13. Testing Strategy

### Unit Testing

Unit tests focus on:
- Specific examples demonstrating correct behavior for known inputs
- Edge cases (zero amounts, maximum fees, boundary conditions)
- Integration points between facets and storage
- Error condition handling and revert scenarios
- Fee calculation accuracy

### Property-Based Testing

Property-based tests verify universal properties using Foundry's fuzzing with minimum 100 iterations:

**Core Properties**:

1. **Index Creation Validation**: Valid index created iff all parameters meet criteria
2. **Fee Splitting Consistency**: `potShare + protocolShare = totalFee`
3. **Minting Proportionality**: Minting preserves proportional ownership
4. **Burning Conservation**: Assets distributed equal proportional share minus fees
5. **Flash Loan Round Trip**: Balance after = balance before + fees
6. **Access Control Enforcement**: Admin functions require timelock
7. **Pause State Consistency**: Paused indexes reject operations
8. **Preview Calculation Accuracy**: Preview matches actual execution
9. **Solvency Invariant**: Vault balances cover required bundles
10. **Balance Query Accuracy**: No cross-contamination between balance types
11. **Treasury Transfer Behavior**: Protocol fees route correctly
12. **State Transition Atomicity**: All-or-nothing state changes

### Test Scenarios

**Creation Scenarios**:
- Valid creation with various asset counts
- Invalid parameters (zero bundles, duplicates, fee caps)
- Access control (governance vs public)
- Creation fee handling

**Minting Scenarios**:
- First mint (zero supply)
- Subsequent mints (proportional)
- Fee calculation accuracy
- Multi-asset bundles
- Fee-on-transfer token protection (underpayment reverts; overpayment allowed)

**Burning Scenarios**:
- Full redemption
- Partial redemption
- Fee pot distribution
- Zero supply edge case

**Flash Loan Scenarios**:
- Successful round trip
- Underpayment rejection
- Fee collection accuracy
- Multi-asset loans

---

## Appendix: Correctness Properties

### Property 1: Index Creation Validation
For any creation parameters, a valid index is created iff all parameters meet validation criteria.

### Property 2: Fee Splitting Consistency
For any fee amount: `potShare + protocolShare = totalFee`.

### Property 3: Minting Proportionality
For indexes with existing supply, minting preserves proportional ownership.

### Property 4: Burning Conservation
Total assets distributed equals proportional share of vault + fee pots minus burn fees.

### Property 5: Flash Loan Round Trip
Contract balance after repayment equals balance before plus fees.

### Property 6: Access Control Enforcement
Administrative functions succeed iff caller is timelock.

### Property 7: Pause State Consistency
Paused indexes reject mint/burn/flash while view functions remain accessible.

### Property 8: Preview Calculation Accuracy
Preview values match actual execution under same conditions.

### Property 9: Solvency Invariant
Vault balances always cover required bundle amounts for total supply.

### Property 10: Balance Query Accuracy
No cross-contamination between vault balances, fee pots, and protocol balances.

### Property 11: Treasury Transfer Behavior
Protocol fees transfer to treasury when configured, accumulate in pots otherwise.

### Property 12: State Transition Atomicity
All state changes succeed together or entire transaction reverts.

---

**Document Version:** 3.0
