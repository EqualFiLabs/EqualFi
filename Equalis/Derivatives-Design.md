# Derivatives System Design

This document describes the Options and Futures derivatives system built on Position NFTs. These instruments allow liquidity providers to create fully-collateralized derivative contracts that are represented as transferable ERC-1155 tokens.

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Options](#options)
4. [Futures](#futures)
5. [Token Standards](#token-standards)
6. [Collateral Management](#collateral-management)
7. [Integration Guide](#integration-guide)
8. [Worked Examples](#worked-examples)

---

## Overview

The derivatives system enables Position NFT holders to create options and futures contracts backed by their deposited liquidity. Key characteristics:

- **Fully Collateralized**: All contracts are 100% backed by locked principal
- **Physical Settlement**: Contracts settle with actual asset delivery, not cash
- **Transferable Rights**: Derivative rights are ERC-1155 tokens that can be freely traded
- **No Oracles Required**: Strike/forward prices are fixed at creation, no price feeds needed
- **European & American Styles**: Both exercise styles supported for options and futures

### System Participants

| Role | Description |
|------|-------------|
| **Maker** | Position NFT holder who creates derivative series by locking collateral |
| **Holder** | Owner of derivative tokens who can exercise/settle the contract |
| **Protocol** | Diamond contract that manages collateral and settlement |

### Contract Flow

```
┌─────────────┐     create      ┌─────────────┐     transfer    ┌─────────────┐
│   Maker     │ ──────────────► │  ERC-1155   │ ──────────────► │   Holder    │
│ (Position)  │                 │   Tokens    │                 │  (Wallet)   │
└─────────────┘                 └─────────────┘                 └─────────────┘
      │                                                               │
      │ lock collateral                                    exercise/settle
      ▼                                                               ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           Diamond Protocol                                   │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐    │
│  │ OptionsFacet │  │ FuturesFacet │  │ OptionToken  │  │ FuturesToken │    │
│  └──────────────┘  └──────────────┘  └──────────────┘  └──────────────┘    │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Architecture

### Contract Structure

```
src/derivatives/
├── OptionToken.sol      # ERC-1155 for option rights
└── FuturesToken.sol     # ERC-1155 for futures rights

src/equallend-direct/
├── OptionsFacet.sol     # Options creation, exercise, reclaim
└── FuturesFacet.sol     # Futures creation, settlement, reclaim

src/views/
└── DerivativeViewFacet.sol  # Read-only queries

src/libraries/
├── DerivativeTypes.sol       # Data structures
├── LibDerivativeStorage.sol  # Diamond storage
└── LibDerivativeHelpers.sol  # Collateral locking utilities
```

### Storage Layout

The derivative system uses Diamond storage pattern at slot `keccak256("equallend.derivative.storage")`:

```solidity
struct DerivativeStorage {
    DerivativeConfig config;
    
    // Options
    mapping(uint256 => OptionSeries) optionSeries;
    uint256 nextOptionSeriesId;
    bool optionsPaused;
    address optionToken;
    
    // Futures
    mapping(uint256 => FuturesSeries) futuresSeries;
    uint256 nextFuturesSeriesId;
    bool futuresPaused;
    uint64 futuresReclaimGracePeriod;
    address futuresToken;
    
    // Position indexes
    LibPositionList.List optionSeriesByPosition;
    LibPositionList.List futuresSeriesByPosition;
}
```

### Configuration

```solidity
struct DerivativeConfig {
    uint64 europeanToleranceSeconds;    // Window around expiry for European exercise
    uint64 defaultGracePeriodSeconds;   // Default grace period for futures reclaim
    uint16 maxFeeBps;                   // Maximum fee basis points
    bool requirePositionNFT;            // Whether Position NFT is required
}
```

---

## Options

Options give the holder the right (but not obligation) to exchange assets at a predetermined strike price.

### Option Types

| Type | Collateral | Holder Receives | Holder Pays |
|------|------------|-----------------|-------------|
| **Covered Call** | Underlying asset | Underlying | Strike amount |
| **Secured Put** | Strike asset | Strike amount | Underlying |

### Data Structure

```solidity
struct OptionSeries {
    bytes32 makerPositionKey;    // Position that created the series
    uint256 makerPositionId;     // Position NFT token ID
    uint256 underlyingPoolId;    // Pool containing underlying asset
    uint256 strikePoolId;        // Pool containing strike asset
    address underlyingAsset;     // e.g., WETH
    address strikeAsset;         // e.g., USDC
    uint256 strikePrice;         // Price in 1e18 precision
    uint64 expiry;               // Unix timestamp
    uint256 totalSize;           // Total underlying amount
    uint256 remaining;           // Unexercised amount
    uint256 collateralLocked;    // Currently locked collateral
    bool isCall;                 // true = call, false = put
    bool isAmerican;             // true = American, false = European
    bool reclaimed;              // Whether maker has reclaimed
}
```

### Creating an Option Series

**Requirements:**
- Caller must own the Position NFT
- Position must be a member of both underlying and strike pools
- Sufficient unlocked principal in the collateral pool

**Function Signature:**
```solidity
function createOptionSeries(CreateOptionSeriesParams calldata params)
    external
    returns (uint256 seriesId);

struct CreateOptionSeriesParams {
    uint256 positionId;        // Position NFT token ID
    uint256 underlyingPoolId;  // Pool for underlying asset
    uint256 strikePoolId;      // Pool for strike asset
    uint256 strikePrice;       // Strike price (1e18 precision)
    uint64 expiry;             // Expiration timestamp
    uint256 totalSize;         // Size in underlying units
    bool isCall;               // Call or put
    bool isAmerican;           // American or European style
}
```

**What Happens:**
1. Validates position ownership and pool membership
2. Settles any pending fee/credit indexes
3. Locks collateral:
   - Call: locks `totalSize` of underlying
   - Put: locks `strikePrice * totalSize` of strike asset (normalized)
4. Creates series record with unique `seriesId`
5. Mints `totalSize` ERC-1155 tokens to the Position NFT owner

### Exercising Options

**Requirements:**
- Caller must hold (or be approved for) the option tokens
- Must be within exercise window
- Must have sufficient payment tokens approved

**Function Signatures:**
```solidity
// Exercise your own tokens
function exerciseOptions(
    uint256 seriesId,
    uint256 amount,
    address recipient
) external;

// Exercise on behalf of another holder (requires approval)
function exerciseOptionsFor(
    uint256 seriesId,
    uint256 amount,
    address holder,
    address recipient
) external;
```

**Exercise Windows:**

| Style | Exercise Window |
|-------|-----------------|
| American | Anytime before expiry |
| European | `expiry ± europeanToleranceSeconds` |

**Settlement Flow (Call):**
```
Holder pays: strikePrice × amount (in strike asset)
Holder receives: amount (in underlying asset)
Maker receives: strikePrice × amount (credited to position)
```

**Settlement Flow (Put):**
```
Holder pays: amount (in underlying asset)
Holder receives: strikePrice × amount (in strike asset)
Maker receives: amount (credited to position)
```

### Reclaiming Expired Options

After expiry, the maker can reclaim any unexercised collateral.

**Requirements:**
- Series must be expired (`block.timestamp > expiry`)
- Caller must own the Position NFT
- Caller must hold all remaining option tokens

```solidity
function reclaimOptions(uint256 seriesId) external;
```

**What Happens:**
1. Burns remaining option tokens from caller
2. Unlocks remaining collateral back to position
3. Marks series as reclaimed

---

## Futures

Futures are binding agreements to exchange assets at a predetermined forward price on a future date.

### Data Structure

```solidity
struct FuturesSeries {
    bytes32 makerPositionKey;    // Position that created the series
    uint256 makerPositionId;     // Position NFT token ID
    uint256 underlyingPoolId;    // Pool containing underlying asset
    uint256 quotePoolId;         // Pool containing quote asset
    address underlyingAsset;     // e.g., WETH
    address quoteAsset;          // e.g., USDC
    uint256 forwardPrice;        // Forward price in 1e18 precision
    uint64 expiry;               // Settlement date
    uint256 totalSize;           // Total underlying amount
    uint256 remaining;           // Unsettled amount
    uint256 underlyingLocked;    // Currently locked underlying
    uint64 graceUnlockTime;      // When maker can reclaim
    bool isEuropean;             // European or American style
    bool reclaimed;              // Whether maker has reclaimed
}
```

### Creating a Futures Series

**Function Signature:**
```solidity
function createFuturesSeries(CreateFuturesSeriesParams calldata params)
    external
    returns (uint256 seriesId);

struct CreateFuturesSeriesParams {
    uint256 positionId;        // Position NFT token ID
    uint256 underlyingPoolId;  // Pool for underlying asset
    uint256 quotePoolId;       // Pool for quote asset
    uint256 forwardPrice;      // Forward price (1e18 precision)
    uint64 expiry;             // Settlement date
    uint256 totalSize;         // Size in underlying units
    bool isEuropean;           // European or American style
}
```

**What Happens:**
1. Validates position ownership and pool membership
2. Locks `totalSize` of underlying asset
3. Sets `graceUnlockTime = expiry + gracePeriod`
4. Mints `totalSize` ERC-1155 tokens to Position NFT owner

### Settling Futures

Unlike options, futures are obligations. The holder must settle by paying the forward price.

**Function Signatures:**
```solidity
function settleFutures(
    uint256 seriesId,
    uint256 amount,
    address recipient
) external;

function settleFuturesFor(
    uint256 seriesId,
    uint256 amount,
    address holder,
    address recipient
) external;
```

**Settlement Windows:**

| Style | Settlement Window |
|-------|-------------------|
| American | Anytime before `graceUnlockTime` |
| European | `expiry ± europeanToleranceSeconds` |

**Settlement Flow:**
```
Holder pays: forwardPrice × amount (in quote asset)
Holder receives: amount (in underlying asset)
Maker receives: forwardPrice × amount (credited to position)
```

### Reclaiming Unsettled Futures

After the grace period, the maker can reclaim unsettled collateral.

**Requirements:**
- Grace period elapsed (`block.timestamp >= graceUnlockTime`)
- Caller must own the Position NFT
- Caller must hold all remaining futures tokens

```solidity
function reclaimFutures(uint256 seriesId) external;
```

**Grace Period Purpose:**
The grace period gives holders time to settle after expiry. If they fail to settle, the maker keeps both the collateral AND the quote payment they would have received (since no settlement occurred).

---

## Token Standards

Both `OptionToken` and `FuturesToken` are ERC-1155 contracts with identical interfaces.

### Token ID Scheme

Each `seriesId` becomes a unique ERC-1155 token ID. Token balances represent the amount of underlying the holder can exercise/settle.

### Manager Pattern

Tokens use a manager pattern where only the Diamond contract can mint/burn:

```solidity
contract OptionToken is ERC1155, Ownable {
    address public manager;  // The Diamond contract
    
    modifier onlyManager() {
        if (msg.sender != manager) revert DerivativeToken_NotManager(msg.sender);
        _;
    }
    
    function managerMint(address to, uint256 id, uint256 amount, bytes calldata data) 
        external onlyManager;
    
    function managerBurn(address from, uint256 id, uint256 amount) 
        external onlyManager;
    
    function managerBurnBatch(address from, uint256[] calldata ids, uint256[] calldata amounts) 
        external onlyManager;
}
```

### Transfer Freedom

Token holders can freely transfer their derivative rights using standard ERC-1155 transfers:

```solidity
// Single transfer
optionToken.safeTransferFrom(from, to, seriesId, amount, "");

// Batch transfer
optionToken.safeBatchTransferFrom(from, to, seriesIds, amounts, "");
```

### Metadata

Each token contract supports per-series URIs:

```solidity
function setSeriesURI(uint256 seriesId, string calldata uri_) external onlyManager;
function uri(uint256 id) public view returns (string memory);
```

---

## Collateral Management

### Locking Mechanism

Collateral is tracked per-position, per-pool using the `directLockedPrincipal` mapping:

```solidity
// In DirectStorage
mapping(bytes32 => mapping(uint256 => uint256)) directLockedPrincipal;
//       positionKey    poolId         lockedAmount
```

### Available Principal Calculation

```
available = userPrincipal - lockedPrincipal - lentPrincipal
```

A position can only create derivatives if it has sufficient unlocked principal.

### Lock/Unlock Functions

```solidity
// Lock collateral for a derivative
function _lockCollateral(bytes32 positionKey, uint256 poolId, uint256 amount) internal;

// Unlock collateral (on exercise, settlement, or reclaim)
function _unlockCollateral(bytes32 positionKey, uint256 poolId, uint256 amount) internal;
```

### Price Normalization

Strike and forward prices use 1e18 precision. The system normalizes between different token decimals:

```solidity
function _normalizePrice(
    uint256 underlyingAmount,  // Amount of underlying
    uint256 price,             // Price in 1e18
    uint8 underlyingDecimals,  // e.g., 18 for WETH
    uint8 quoteDecimals        // e.g., 6 for USDC
) internal pure returns (uint256 quoteAmount);
```

**Example:** 1 WETH at strike $2000
- `underlyingAmount = 1e18` (1 WETH)
- `price = 2000e18` ($2000 in 1e18)
- `underlyingDecimals = 18`
- `quoteDecimals = 6`
- Result: `2000e6` (2000 USDC)

---

## Integration Guide

### For Developers

#### Reading Option/Futures State

```solidity
// Get full series data
OptionSeries memory series = diamond.getOptionSeries(seriesId);
FuturesSeries memory futures = diamond.getFuturesSeries(seriesId);

// Get collateral info
(uint256 locked, uint256 remaining) = diamond.getOptionSeriesCollateral(seriesId);
(uint256 underlyingLocked, uint256 remaining) = diamond.getFuturesCollateral(seriesId);

// List series by position
(uint256[] memory ids, uint256 total) = diamond.getOptionSeriesByPositionId(
    positionId, 
    offset, 
    limit
);
```

#### Creating a Covered Call

```solidity
// 1. Ensure position has deposited underlying
// 2. Ensure position is member of both pools

DerivativeTypes.CreateOptionSeriesParams memory params = DerivativeTypes.CreateOptionSeriesParams({
    positionId: myPositionId,
    underlyingPoolId: wethPoolId,
    strikePoolId: usdcPoolId,
    strikePrice: 2000e18,        // $2000 strike
    expiry: block.timestamp + 30 days,
    totalSize: 10e18,            // 10 WETH
    isCall: true,
    isAmerican: false            // European style
});

uint256 seriesId = OptionsFacet(diamond).createOptionSeries(params);
```

#### Exercising Options

```solidity
// 1. Approve strike asset to diamond
IERC20(usdc).approve(diamond, type(uint256).max);

// 2. Exercise
OptionsFacet(diamond).exerciseOptions(
    seriesId,
    5e18,           // Exercise 5 options
    msg.sender      // Receive underlying here
);
```

### For Users

#### Creating Options (Maker Flow)

1. **Deposit liquidity** into a Position NFT across relevant pools
2. **Join pools** for both underlying and strike assets
3. **Create option series** specifying:
   - Strike price (the price at which exchange occurs)
   - Expiry date
   - Size (how much underlying)
   - Style (American allows early exercise, European only at expiry)
4. **Receive ERC-1155 tokens** representing the option rights
5. **Sell or transfer tokens** to option buyers
6. **After expiry**, reclaim any unexercised collateral

#### Exercising Options (Holder Flow)

1. **Acquire option tokens** (purchase, transfer, or as maker)
2. **Check exercise window**:
   - American: anytime before expiry
   - European: only around expiry time
3. **Approve payment token** (strike asset for calls, underlying for puts)
4. **Call exercise function** specifying amount and recipient
5. **Receive the exchanged asset**

#### Futures Settlement (Holder Flow)

1. **Acquire futures tokens**
2. **At settlement time**, approve quote asset
3. **Call settle function** to exchange quote for underlying
4. **If you miss settlement**, maker can reclaim after grace period

---

## Worked Examples

### Example 1: Covered Call on ETH

**Scenario:** Alice wants to write 10 covered calls on ETH with a $2500 strike, expiring in 30 days.

**Setup:**
- Alice owns Position NFT #42
- Position has 10 WETH deposited in Pool #1 (WETH pool)
- Position is also a member of Pool #2 (USDC pool)
- Current ETH price: $2000

**Step 1: Create the series**
```solidity
CreateOptionSeriesParams memory params = CreateOptionSeriesParams({
    positionId: 42,
    underlyingPoolId: 1,      // WETH pool
    strikePoolId: 2,          // USDC pool
    strikePrice: 2500e18,     // $2500 strike
    expiry: block.timestamp + 30 days,
    totalSize: 10e18,         // 10 ETH
    isCall: true,
    isAmerican: false
});

uint256 seriesId = optionsFacet.createOptionSeries(params);
// seriesId = 1
```

**Result:**
- 10 WETH locked in Alice's position
- Alice receives 10e18 OptionToken(seriesId=1)
- Alice sells tokens to Bob for 0.5 ETH premium (off-chain)

**Step 2: At expiry, ETH = $3000**

Bob decides to exercise (profitable since $3000 > $2500):

```solidity
// Bob approves USDC
usdc.approve(diamond, 25000e6);  // 10 × $2500 = $25,000

// Bob exercises all 10 options
optionsFacet.exerciseOptions(1, 10e18, bob);
```

**Settlement:**
- Bob pays: 25,000 USDC
- Bob receives: 10 WETH (worth $30,000)
- Bob's profit: $5,000
- Alice receives: 25,000 USDC credited to her position
- Alice's outcome: Sold ETH at $2500 + kept 0.5 ETH premium

### Example 2: Secured Put on ETH

**Scenario:** Charlie writes a put option allowing the holder to sell ETH at $1800.

**Setup:**
- Charlie owns Position NFT #100
- Position has 18,000 USDC in Pool #2
- Strike: $1800, Size: 10 ETH

**Step 1: Create the series**
```solidity
CreateOptionSeriesParams memory params = CreateOptionSeriesParams({
    positionId: 100,
    underlyingPoolId: 1,      // WETH pool
    strikePoolId: 2,          // USDC pool
    strikePrice: 1800e18,     // $1800 strike
    expiry: block.timestamp + 14 days,
    totalSize: 10e18,         // 10 ETH
    isCall: false,            // PUT
    isAmerican: true          // American style
});

uint256 seriesId = optionsFacet.createOptionSeries(params);
```

**Result:**
- 18,000 USDC locked (10 × $1800)
- Charlie receives put tokens, sells to Diana

**Step 2: ETH drops to $1500**

Diana exercises (profitable since $1500 < $1800):

```solidity
// Diana approves WETH
weth.approve(diamond, 10e18);

// Diana exercises
optionsFacet.exerciseOptions(seriesId, 10e18, diana);
```

**Settlement:**
- Diana pays: 10 WETH (worth $15,000)
- Diana receives: 18,000 USDC
- Diana's profit: $3,000
- Charlie receives: 10 WETH credited to position
- Charlie bought ETH at $1800 (above market)

### Example 3: Physical Delivery Futures

**Scenario:** Eve creates a futures contract to sell 5 ETH at $2200 in 60 days.

**Step 1: Create futures series**
```solidity
CreateFuturesSeriesParams memory params = CreateFuturesSeriesParams({
    positionId: 200,
    underlyingPoolId: 1,
    quotePoolId: 2,
    forwardPrice: 2200e18,
    expiry: block.timestamp + 60 days,
    totalSize: 5e18,
    isEuropean: true
});

uint256 seriesId = futuresFacet.createFuturesSeries(params);
```

**Result:**
- 5 WETH locked
- Eve receives futures tokens, transfers to Frank

**Step 2: At expiry**

Frank must settle (futures are obligations):

```solidity
usdc.approve(diamond, 11000e6);  // 5 × $2200

futuresFacet.settleFutures(seriesId, 5e18, frank);
```

**Settlement:**
- Frank pays: 11,000 USDC
- Frank receives: 5 WETH
- Eve receives: 11,000 USDC

**Step 3: If Frank doesn't settle**

After grace period (e.g., 7 days post-expiry):

```solidity
// Eve reclaims
futuresFacet.reclaimFutures(seriesId);
```

- Eve gets her 5 WETH back
- Frank loses his futures tokens (worthless now)
- Frank received nothing, paid nothing

---

## Error Reference

### Options Errors

| Error | Cause |
|-------|-------|
| `Options_Paused` | Options system is paused |
| `Options_InvalidAmount` | Zero or excessive amount |
| `Options_InvalidPrice` | Zero strike price |
| `Options_InvalidExpiry` | Expiry in the past |
| `Options_InvalidPool` | Same pool for underlying and strike |
| `Options_InvalidAssetPair` | Pools have same underlying asset |
| `Options_InvalidSeries` | Series doesn't exist |
| `Options_ExerciseWindowClosed` | Outside exercise window |
| `Options_NotExpired` | Trying to reclaim before expiry |
| `Options_Reclaimed` | Series already reclaimed |
| `Options_NotTokenHolder` | Caller doesn't hold tokens |
| `Options_InsufficientBalance` | Not enough tokens |
| `Options_TokenNotSet` | OptionToken not configured |

### Futures Errors

| Error | Cause |
|-------|-------|
| `Futures_Paused` | Futures system is paused |
| `Futures_InvalidAmount` | Zero or excessive amount |
| `Futures_InvalidPrice` | Zero forward price |
| `Futures_InvalidExpiry` | Expiry in the past |
| `Futures_InvalidPool` | Same pool for underlying and quote |
| `Futures_InvalidAssetPair` | Pools have same underlying asset |
| `Futures_InvalidSeries` | Series doesn't exist |
| `Futures_SettlementWindowClosed` | Outside settlement window |
| `Futures_GracePeriodNotElapsed` | Trying to reclaim too early |
| `Futures_Reclaimed` | Series already reclaimed |
| `Futures_NotTokenHolder` | Caller doesn't hold tokens |
| `Futures_InsufficientBalance` | Not enough tokens |
| `Futures_TokenNotSet` | FuturesToken not configured |

---

## Events

### Options Events

```solidity
event SeriesCreated(
    uint256 indexed seriesId,
    bytes32 indexed makerPositionKey,
    uint256 indexed makerPositionId,
    uint256 underlyingPoolId,
    uint256 strikePoolId,
    address underlyingAsset,
    address strikeAsset,
    uint256 strikePrice,
    uint64 expiry,
    uint256 totalSize,
    uint256 collateralLocked,
    bool isCall,
    bool isAmerican
);

event Exercised(
    uint256 indexed seriesId,
    address indexed holder,
    address indexed recipient,
    uint256 amount,
    uint256 strikeAmount
);

event Reclaimed(
    uint256 indexed seriesId,
    bytes32 indexed makerPositionKey,
    uint256 remainingSize,
    uint256 collateralUnlocked
);
```

### Futures Events

```solidity
event SeriesCreated(
    uint256 indexed seriesId,
    bytes32 indexed makerPositionKey,
    uint256 indexed makerPositionId,
    uint256 underlyingPoolId,
    uint256 quotePoolId,
    address underlyingAsset,
    address quoteAsset,
    uint256 forwardPrice,
    uint64 expiry,
    uint256 totalSize,
    uint256 underlyingLocked,
    uint64 graceUnlockTime,
    bool isEuropean
);

event Settled(
    uint256 indexed seriesId,
    address indexed holder,
    address indexed recipient,
    uint256 amount,
    uint256 quoteAmount
);

event Reclaimed(
    uint256 indexed seriesId,
    bytes32 indexed makerPositionKey,
    uint256 remainingSize,
    uint256 collateralUnlocked
);
```

---

## Security Considerations

1. **Full Collateralization**: All derivatives are 100% backed. No leverage or undercollateralization.

2. **No Oracle Dependency**: Prices are fixed at creation. No manipulation risk from price feeds.

3. **Reentrancy Protection**: All state-changing functions use `nonReentrant` modifier.

4. **Access Control**: Only Position NFT owners can create series and reclaim collateral.

5. **Token Approval**: Exercise/settlement requires explicit token approval from the holder.

6. **Grace Periods**: Futures have mandatory grace periods to prevent premature reclaim.

7. **Pause Functionality**: Owner/timelock can pause options or futures independently.
