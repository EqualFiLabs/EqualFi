# Maker Auction Markets (MAM) Design

This document describes the Maker Auction Markets (MAM) system, which enables Position NFT holders to create time-varying price curves for selling assets. MAM curves implement a linear Dutch auction mechanism where the price changes over time according to a predefined schedule.

## Table of Contents

1. [Overview](#overview)
2. [How It Works](#how-it-works)
3. [Architecture](#architecture)
4. [Curve Lifecycle](#curve-lifecycle)
5. [Pricing Model](#pricing-model)
6. [Fill Mechanics](#fill-mechanics)
7. [Fee Structure](#fee-structure)
8. [Curve Updates](#curve-updates)
9. [Discovery & Indexing](#discovery--indexing)
10. [Integration Guide](#integration-guide)
11. [Worked Examples](#worked-examples)
12. [Comparison with AMM Auctions](#comparison-with-amm-auctions)

---

## Overview

MAM (Maker Auction Markets) allows liquidity providers to create price curves that define how they want to sell a base asset over time. Unlike constant-product AMMs, MAM curves have a predetermined price trajectory that changes linearly from start to end.

### Key Characteristics

| Feature | Description |
|---------|-------------|
| **Linear Dutch Auction** | Price moves linearly from start to end price |
| **Time-Bounded** | Curves have explicit start time and duration |
| **One-Sided Liquidity** | Maker sells base asset, receives quote asset |
| **Volume-Limited** | Maximum volume defined at creation |
| **Updatable Pricing** | Maker can update price parameters while active |
| **Batch Operations** | Create, update, cancel, expire multiple curves at once |

### System Participants

| Role | Description |
|------|-------------|
| **Maker** | Position NFT holder who creates curves to sell base assets |
| **Taker** | Anyone who fills curves by paying quote assets |
| **Protocol** | Receives a portion of fill fees |

### High-Level Flow

```
┌─────────────┐                    ┌─────────────┐
│   Maker     │   createCurve      │    Curve    │
│ (Position)  │ ─────────────────► │  (Dutch)    │
└─────────────┘                    └──────┬──────┘
      │                                   │
      │ lock base asset                   │ executeCurveSwap
      ▼                                   ▼
┌─────────────────────────────────────────────────────────────────┐
│                        Diamond Protocol                          │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐          │
│  │  Base Pool   │  │  Quote Pool  │  │   Treasury   │          │
│  │   (TokenA)   │  │   (TokenB)   │  │              │          │
│  └──────────────┘  └──────────────┘  └──────────────┘          │
└─────────────────────────────────────────────────────────────────┘
                            │
                            │ fill
                            ▼
                    ┌─────────────┐
                    │   Taker     │
                    │  (Wallet)   │
                    └─────────────┘
```

---

## How It Works

### The Dutch Auction Model

A Dutch auction starts at a high price and decreases over time until a buyer accepts. MAM curves generalize this:

- **Descending Curve**: `startPrice > endPrice` (classic Dutch auction)
- **Ascending Curve**: `startPrice < endPrice` (reverse Dutch auction)
- **Flat Curve**: `startPrice == endPrice` (fixed price limit order)

### Base and Quote Assets

Each curve defines:
- **Base Asset**: The asset being sold by the maker
- **Quote Asset**: The asset received by the maker

The `side` parameter determines which token is base:
- `side = false` (SellAForB): TokenA is base, TokenB is quote
- `side = true` (SellBForA): TokenB is base, TokenA is quote

### Price Interpretation

Prices are expressed as **quote per base** with 1e18 precision:

```
price = quote_amount / base_amount × 1e18
```

For example, selling ETH for USDC at $2000:
```
price = 2000e18 (2000 USDC per 1 ETH)
```

---

## Architecture

### Contract Structure

```
src/EqualX/
└── MamCurveFacet.sol        # Main curve logic

src/views/
└── MamCurveViewFacet.sol    # Query functions

src/libraries/
├── MamTypes.sol             # Data structures
├── LibMamMath.sol           # Pricing calculations
├── LibMamCurveHasher.sol    # Commitment hashing
└── LibDerivativeStorage.sol # Storage and indexing
```

### Data Structures

**Curve Descriptor (Creation Input):**
```solidity
struct CurveDescriptor {
    bytes32 makerPositionKey;    // Position key
    uint256 makerPositionId;     // Position NFT ID
    uint256 poolIdA;             // Pool for token A
    uint256 poolIdB;             // Pool for token B
    address tokenA;              // First token
    address tokenB;              // Second token
    bool side;                   // false: sell A, true: sell B
    bool priceIsQuotePerBase;    // Price interpretation (must be true)
    uint128 maxVolume;           // Maximum base to sell
    uint128 startPrice;          // Starting price (1e18)
    uint128 endPrice;            // Ending price (1e18)
    uint64 startTime;            // When curve becomes active
    uint64 duration;             // How long curve runs
    uint32 generation;           // Version number (starts at 1)
    uint16 feeRateBps;           // Fee in basis points
    FeeAsset feeAsset;           // Fee taken from (must be TokenIn)
    uint96 salt;                 // Unique identifier
}
```

**Stored Curve (On-Chain State):**
```solidity
struct StoredCurve {
    bytes32 commitment;      // Hash of curve parameters
    uint128 remainingVolume; // Unfilled base amount
    uint64 endTime;          // When curve expires
    uint32 generation;       // Current version
    bool active;             // Whether curve is live
}
```

**Curve Update Parameters:**
```solidity
struct CurveUpdateParams {
    uint128 startPrice;   // New start price
    uint128 endPrice;     // New end price
    uint64 startTime;     // New start time
    uint64 duration;      // New duration
}
```

### Storage Layout

Curves are stored across multiple mappings for gas efficiency:

```solidity
// Core state
mapping(uint256 => StoredCurve) curves;

// Immutable data (set at creation)
mapping(uint256 => CurveData) curveData;
mapping(uint256 => CurveImmutables) curveImmutables;

// Mutable pricing (can be updated)
mapping(uint256 => CurvePricing) curvePricing;

// Derived data
mapping(uint256 => bytes32) curveImmutableHash;
mapping(uint256 => bool) curveBaseIsA;
```

---

## Curve Lifecycle

### 1. Creation

**Requirements:**
- Caller must own the Position NFT
- Position must be a member of both pools
- Sufficient unlocked principal for base asset
- `startTime >= block.timestamp`
- `duration > 0`
- `generation == 1` (for new curves)

**Function:**
```solidity
function createCurve(CurveDescriptor calldata desc)
    external
    returns (uint256 curveId);
```

**What Happens:**
1. Validates descriptor parameters
2. Settles pending fee/credit indexes
3. Locks `maxVolume` of base asset from maker's position
4. Creates curve record with unique `curveId`
5. Computes and stores commitment hash
6. Adds to discovery indexes
7. Emits `CurveCreated` event

**Batch Creation:**
```solidity
function createCurvesBatch(CurveDescriptor[] calldata descs)
    external
    returns (uint256 firstCurveId);
```

### 2. Active Period

During the active window (`startTime ≤ now ≤ endTime`):
- Takers can fill the curve at the current price
- Price changes linearly over time
- Maker can update pricing parameters
- Maker can cancel at any time

### 3. Filling

Takers execute swaps against the curve:

```solidity
function executeCurveSwap(
    uint256 curveId,
    uint256 amountIn,      // Quote amount to pay
    uint256 minOut,        // Minimum base to receive
    uint64 deadline,       // Transaction deadline
    address recipient      // Where to send base
) external returns (uint256 amountOut);
```

### 4. Expiration

After `endTime`, anyone can expire the curve:

```solidity
function expireCurve(uint256 curveId) external;
```

**What Happens:**
1. Unlocks remaining base volume back to maker
2. Removes from all indexes
3. Marks curve as inactive
4. Emits `CurveExpired` event

### 5. Cancellation

Maker can cancel anytime:

```solidity
function cancelCurve(uint256 curveId) external;
```

**What Happens:**
1. Validates caller owns the maker position
2. Unlocks remaining base volume
3. Removes from indexes
4. Emits `CurveCancelled` event

---

## Pricing Model

### Linear Interpolation

The price at any time `t` is computed as:

```
if t <= startTime:
    price = startPrice
else if t >= endTime:
    price = endPrice
else:
    elapsed = t - startTime
    delta = |endPrice - startPrice|
    adjustment = delta × elapsed / duration
    
    if endPrice >= startPrice:
        price = startPrice + adjustment
    else:
        price = startPrice - adjustment
```

### Price Visualization

**Descending Dutch Auction (startPrice > endPrice):**
```
Price
  │
  │ ●─────────────
  │               ╲
  │                 ╲
  │                   ╲
  │                     ╲
  │                       ●
  │
  └───────────────────────────► Time
    startTime           endTime
```

**Ascending Curve (startPrice < endPrice):**
```
Price
  │
  │                       ●
  │                     ╱
  │                   ╱
  │                 ╱
  │               ╱
  │ ●─────────────
  │
  └───────────────────────────► Time
    startTime           endTime
```

### Price Calculation Example

```solidity
// Curve: sell ETH from $2500 to $2000 over 1 hour
startPrice = 2500e18
endPrice = 2000e18
startTime = 1000
duration = 3600

// At t = 1000 (start)
price = 2500e18  // $2500

// At t = 1900 (25% elapsed)
elapsed = 900
adjustment = 500e18 × 900 / 3600 = 125e18
price = 2500e18 - 125e18 = 2375e18  // $2375

// At t = 2800 (50% elapsed)
elapsed = 1800
adjustment = 500e18 × 1800 / 3600 = 250e18
price = 2500e18 - 250e18 = 2250e18  // $2250

// At t = 4600 (end)
price = 2000e18  // $2000
```

---

## Fill Mechanics

### Fill Calculation

When a taker provides `amountIn` quote tokens:

```solidity
// 1. Compute current price
price = computePrice(startPrice, endPrice, startTime, duration, now)

// 2. Calculate base output
baseFill = amountIn × 1e18 / price

// 3. Calculate fee
feeAmount = amountIn × feeRateBps / 10000

// 4. Total quote required
totalQuote = amountIn + feeAmount
```

### Fill Constraints

- `baseFill > 0` (non-zero output)
- `baseFill <= remainingVolume` (sufficient volume)
- `baseFill >= minOut` (slippage protection)
- `block.timestamp <= deadline` (transaction deadline)

### Asset Flows

```
Taker pays:     amountIn + feeAmount (quote tokens)
Taker receives: baseFill (base tokens)

Maker receives: amountIn + makerFee (credited to position)
Fee Index:      indexFee (distributed to pool)
Treasury:       treasuryFee (transferred out)
```

### Partial Fills

Curves support partial fills:
- Each fill reduces `remainingVolume`
- Multiple takers can fill the same curve
- Curve auto-deactivates when `remainingVolume == 0`

---

## Fee Structure

### Fee Split

Every fill fee is split three ways:

| Recipient | Share | Purpose |
|-----------|-------|---------|
| **Maker** | 70% | Reward for providing liquidity |
| **Fee Index** | 20% | Distributed to pool depositors |
| **Treasury** | 10% | Protocol revenue |

```solidity
uint16 internal constant FEE_SPLIT_MAKER_BPS = 7000;   // 70%
uint16 internal constant FEE_SPLIT_INDEX_BPS = 2000;   // 20%
uint16 internal constant FEE_SPLIT_TREASURY_BPS = 1000; // 10%
```

### Fee Calculation

```solidity
// Total fee from taker
feeAmount = amountIn × feeRateBps / 10000

// Split
makerFee = feeAmount × 7000 / 10000
indexFee = feeAmount × 2000 / 10000
treasuryFee = feeAmount - makerFee - indexFee
```

### Fee Asset

Currently, fees are always taken from `TokenIn` (quote asset):
- Taker pays: `amountIn + feeAmount`
- Fee is denominated in quote tokens

---

## Curve Updates

### Updatable Parameters

Makers can update pricing parameters while a curve is active:

```solidity
struct CurveUpdateParams {
    uint128 startPrice;   // New start price
    uint128 endPrice;     // New end price
    uint64 startTime;     // New start time (must be >= now)
    uint64 duration;      // New duration
}
```

### Update Function

```solidity
function updateCurve(uint256 curveId, CurveUpdateParams calldata params) external;
```

**Constraints:**
- Caller must own the maker position
- Curve must be active
- `startTime >= block.timestamp`
- `duration > 0`
- `startPrice > 0` and `endPrice > 0`

**What Happens:**
1. Validates ownership and parameters
2. Increments `generation` counter
3. Recomputes commitment hash
4. Updates pricing storage
5. Emits `CurveUpdated` event

### Generation Tracking

Each update increments the `generation` counter:
- Initial creation: `generation = 1`
- First update: `generation = 2`
- And so on...

This allows off-chain systems to detect stale quotes.

### Batch Updates

```solidity
function updateCurvesBatch(
    uint256[] calldata curveIds,
    CurveUpdateParams[] calldata params
) external;
```

---

## Discovery & Indexing

### By Position

```solidity
function getCurvesByPosition(bytes32 positionKey, uint256 offset, uint256 limit)
    external view returns (uint256[] memory ids, uint256 total);

function getCurvesByPositionId(uint256 positionId, uint256 offset, uint256 limit)
    external view returns (uint256[] memory ids, uint256 total);
```

### By Token Pair

```solidity
function getCurvesByPair(address tokenA, address tokenB, uint256 offset, uint256 limit)
    external view returns (uint256[] memory ids, uint256 total);
```

### Global Active List

```solidity
function getActiveCurves(uint256 offset, uint256 limit)
    external view returns (uint256[] memory ids, uint256 total);
```

### Curve Status

```solidity
function getCurveStatus(uint256 curveId)
    external view
    returns (
        bool active,
        bool expired,
        uint128 remainingVolume,
        uint256 currentPrice,
        uint64 startTime,
        uint64 endTime,
        bool baseIsA,
        address tokenA,
        address tokenB,
        uint256 timeRemaining
    );
```

### Quote Functions

```solidity
function quoteCurveExactIn(uint256 curveId, uint256 amountIn)
    external view
    returns (
        uint256 amountOut,
        uint256 feeAmount,
        uint256 totalQuote,
        uint128 remainingVolume,
        bool ok
    );

function quoteCurvesExactInBatch(
    uint256[] calldata curveIds,
    uint256[] calldata amountIns
) external view returns (
    uint256[] memory amountOuts,
    uint256[] memory feeAmounts,
    bool[] memory oks
);
```

---

## Integration Guide

### For Developers

#### Creating a Curve

```solidity
// Sell 10 ETH from $2500 to $2000 over 1 hour
MamTypes.CurveDescriptor memory desc = MamTypes.CurveDescriptor({
    makerPositionKey: positionKey,
    makerPositionId: myPositionId,
    poolIdA: wethPoolId,
    poolIdB: usdcPoolId,
    tokenA: weth,
    tokenB: usdc,
    side: false,                    // Sell A (WETH) for B (USDC)
    priceIsQuotePerBase: true,
    maxVolume: 10e18,               // 10 ETH
    startPrice: 2500e18,            // $2500/ETH
    endPrice: 2000e18,              // $2000/ETH
    startTime: uint64(block.timestamp),
    duration: 3600,                 // 1 hour
    generation: 1,
    feeRateBps: 30,                 // 0.30%
    feeAsset: MamTypes.FeeAsset.TokenIn,
    salt: 12345
});

uint256 curveId = mamCurveFacet.createCurve(desc);
```

#### Filling a Curve

```solidity
// 1. Get quote
(uint256 amountOut, uint256 fee, uint256 totalQuote, , bool ok) = 
    mamCurveViewFacet.quoteCurveExactIn(curveId, 2000e6); // 2000 USDC

require(ok, "Quote failed");

// 2. Approve quote tokens
usdc.approve(diamond, totalQuote);

// 3. Execute fill
uint256 received = mamCurveFacet.executeCurveSwap(
    curveId,
    2000e6,                         // amountIn
    amountOut * 99 / 100,           // minOut (1% slippage)
    uint64(block.timestamp + 300),  // 5 min deadline
    msg.sender                      // recipient
);
```

#### Updating a Curve

```solidity
// Adjust price range
MamTypes.CurveUpdateParams memory params = MamTypes.CurveUpdateParams({
    startPrice: 2400e18,            // New start: $2400
    endPrice: 1900e18,              // New end: $1900
    startTime: uint64(block.timestamp),
    duration: 7200                  // 2 hours
});

mamCurveFacet.updateCurve(curveId, params);
```

### For Users

#### Creating a Sell Order (Maker)

1. **Deposit base asset** into a Position NFT
2. **Join pools** for both base and quote assets
3. **Create curve** specifying:
   - Volume (how much to sell)
   - Price range (start and end prices)
   - Duration (how long the auction runs)
   - Fee rate (your earnings per fill)
4. **Monitor** fills and adjust pricing if needed
5. **Expire or cancel** when done

#### Filling Orders (Taker)

1. **Find curves** for your desired pair
2. **Check current price** (changes over time!)
3. **Get quote** to see exact amounts
4. **Execute fill** with slippage protection
5. **Receive base tokens** at recipient address

#### Price Discovery

The current price depends on time:
```
Early in auction → Higher price (for descending)
Late in auction → Lower price (for descending)
```

Takers can wait for better prices, but risk:
- Other takers filling first
- Curve expiring
- Maker updating prices

---

## Worked Examples

### Example 1: Basic Dutch Auction

**Scenario:** Alice wants to sell 5 ETH, starting at $2500 and ending at $2000 over 2 hours.

**Step 1: Alice creates the curve**
```solidity
CurveDescriptor({
    ...
    maxVolume: 5e18,           // 5 ETH
    startPrice: 2500e18,       // $2500
    endPrice: 2000e18,         // $2000
    startTime: 1000,
    duration: 7200,            // 2 hours
    feeRateBps: 50,            // 0.50%
    ...
});
```

**Step 2: Bob fills at t=1000 (start)**
```
Current price: $2500
Bob pays: 2500 USDC + 12.5 USDC fee = 2512.5 USDC
Bob receives: 1 ETH
```

**Step 3: Charlie fills at t=4600 (halfway)**
```
Current price: $2250
Charlie pays: 4500 USDC + 22.5 USDC fee = 4522.5 USDC
Charlie receives: 2 ETH
```

**Step 4: Diana fills at t=8200 (end)**
```
Current price: $2000
Diana pays: 4000 USDC + 20 USDC fee = 4020 USDC
Diana receives: 2 ETH
```

**Final State:**
- Alice sold: 5 ETH for 11,000 USDC + fees
- Remaining volume: 0 (curve auto-deactivated)

### Example 2: Ascending Price Curve

**Scenario:** Eve wants to sell tokens with increasing price (reverse Dutch).

**Setup:**
```solidity
CurveDescriptor({
    ...
    maxVolume: 1000e18,        // 1000 tokens
    startPrice: 1e18,          // $1.00
    endPrice: 2e18,            // $2.00
    duration: 86400,           // 24 hours
    ...
});
```

**Use Case:** Eve expects demand to increase over time, so early buyers get better prices.

**Price at different times:**
- t=0: $1.00
- t=6h: $1.25
- t=12h: $1.50
- t=18h: $1.75
- t=24h: $2.00

### Example 3: Curve Update

**Scenario:** Frank created a curve but market moved against him.

**Initial Curve:**
```
startPrice: 2000e18
endPrice: 1800e18
duration: 3600
```

**After 30 minutes, ETH pumped. Frank updates:**
```solidity
CurveUpdateParams({
    startPrice: 2200e18,       // Higher start
    endPrice: 2000e18,         // Higher end
    startTime: now,            // Reset timing
    duration: 3600             // Fresh 1 hour
});
```

**Result:**
- Generation increments to 2
- Price resets to new range
- Remaining volume unchanged

### Example 4: Flat Price Limit Order

**Scenario:** Frank wants to sell 10 ETH at exactly $2,200 - no more, no less. He uses a flat MAM curve as a limit order.

**Setup:**
```solidity
CurveDescriptor({
    makerPositionKey: frankPositionKey,
    makerPositionId: frankPositionId,
    poolIdA: wethPoolId,
    poolIdB: usdcPoolId,
    tokenA: weth,
    tokenB: usdc,
    side: false,                    // Sell WETH for USDC
    priceIsQuotePerBase: true,
    maxVolume: 10e18,               // 10 ETH
    startPrice: 2200e18,            // $2,200 (FIXED)
    endPrice: 2200e18,              // $2,200 (SAME = FLAT)
    startTime: uint64(block.timestamp),
    duration: 604800,               // 7 days (good-til-cancelled style)
    generation: 1,
    feeRateBps: 10,                 // 0.10% fee
    feeAsset: MamTypes.FeeAsset.TokenIn,
    salt: 99999
});
```

**Key Insight:** When `startPrice == endPrice`, the price never changes:

```
Price
  │
  │ ●─────────────────────────────● $2,200
  │
  │
  │
  └───────────────────────────────────► Time
    startTime                    endTime
```

**Behavior:**
- Price is always $2,200 regardless of when takers fill
- Acts like a traditional limit sell order
- Partial fills allowed (e.g., someone buys 3 ETH, 7 ETH remains)
- Order stays active until fully filled, cancelled, or expired

**Fill Example:**

At any time during the 7-day window:
```solidity
// Alice wants to buy 5 ETH at Frank's limit price
(uint256 amountOut, uint256 fee, uint256 totalQuote, , bool ok) = 
    mamCurveViewFacet.quoteCurveExactIn(curveId, 11000e6); // ~$2,200 × 5

// amountOut ≈ 5e18 (5 ETH)
// fee = 11000e6 × 10 / 10000 = 11e6 (11 USDC)
// totalQuote = 11000e6 + 11e6 = 11011e6

usdc.approve(diamond, totalQuote);
mamCurveFacet.executeCurveSwap(
    curveId,
    11000e6,
    4.9e18,                         // minOut with slippage buffer
    uint64(block.timestamp + 300),
    alice
);
```

**After Fill:**
- Alice receives: 5 ETH
- Alice paid: 11,011 USDC (including fee)
- Frank receives: 11,000 USDC + 7.7 USDC (maker fee share)
- Remaining volume: 5 ETH (order still active)

**Advantages of MAM Limit Orders:**
- No order book infrastructure needed
- Partial fills supported natively
- Maker earns fees on fills
- Can be updated (price, duration) without cancelling
- Discoverable via on-chain indexes

**Comparison with Traditional Limit Orders:**

| Aspect | MAM Flat Curve | CEX Limit Order |
|--------|----------------|-----------------|
| Execution | On-chain | Off-chain matching |
| Partial Fills | Yes | Yes |
| Maker Fees | Earns fees | Pays/earns fees |
| Updateable | Yes (price, time) | Cancel & replace |
| Custody | Self-custody | Exchange custody |
| Discovery | On-chain indexes | Order book |

### Example 5: Batch Operations

**Scenario:** Grace wants to create multiple curves for different price ranges.

```solidity
CurveDescriptor[] memory descs = new CurveDescriptor[](3);

// Curve 1: Premium tier ($2500-$2400)
descs[0] = CurveDescriptor({
    maxVolume: 2e18,
    startPrice: 2500e18,
    endPrice: 2400e18,
    duration: 1800,
    ...
});

// Curve 2: Standard tier ($2400-$2200)
descs[1] = CurveDescriptor({
    maxVolume: 5e18,
    startPrice: 2400e18,
    endPrice: 2200e18,
    duration: 3600,
    ...
});

// Curve 3: Discount tier ($2200-$2000)
descs[2] = CurveDescriptor({
    maxVolume: 10e18,
    startPrice: 2200e18,
    endPrice: 2000e18,
    duration: 7200,
    ...
});

uint256 firstId = mamCurveFacet.createCurvesBatch(descs);
// Creates curves firstId, firstId+1, firstId+2
```

---

## Comparison with AMM Auctions

| Aspect | MAM Curves | AMM Auctions |
|--------|------------|--------------|
| **Pricing Model** | Linear time-based | Constant product (x*y=k) |
| **Price Discovery** | Predetermined trajectory | Market-driven |
| **Liquidity** | One-sided (sell only) | Two-sided (buy and sell) |
| **Price Impact** | None (fixed curve) | Increases with size |
| **Arbitrage** | Time-based | Price-based |
| **Updates** | Pricing can be changed | Reserves change via swaps |
| **Use Case** | Scheduled sales, auctions | General trading |
| **Complexity** | Simpler math | More complex invariant |

### When to Use MAM Curves

- **Token sales**: Selling tokens at decreasing prices
- **Liquidations**: Gradual price reduction to find buyers
- **Scheduled releases**: Time-based price discovery
- **Limit orders**: Flat curves act as limit orders

### When to Use AMM Auctions

- **General trading**: Two-way liquidity
- **Market making**: Continuous price discovery
- **Arbitrage**: Price convergence across venues

---

## Error Reference

| Error | Cause |
|-------|-------|
| `MamCurve_Paused` | MAM system is paused |
| `MamCurve_InvalidAmount` | Zero volume or fill amount |
| `MamCurve_InvalidPool` | Same pool for both tokens |
| `MamCurve_InvalidDescriptor` | Invalid curve parameters |
| `MamCurve_InvalidTime` | Invalid start time or duration |
| `MamCurve_NotActive` | Curve not active |
| `MamCurve_Expired` | Curve has expired or deadline passed |
| `MamCurve_NotExpired` | Trying to expire before end time |
| `MamCurve_InsufficientVolume` | Fill exceeds remaining volume |
| `MamCurve_Slippage` | Output less than minimum |
| `MamCurve_NotMaker` | Caller not the curve maker |
| `PoolMembershipRequired` | Position not member of pool |
| `InsufficientPrincipal` | Not enough available principal |

---

## Events

```solidity
event CurveCreated(
    uint256 indexed curveId,
    bytes32 indexed makerPositionKey,
    uint256 indexed makerPositionId,
    uint256 poolIdA,
    uint256 poolIdB,
    address tokenA,
    address tokenB,
    bool baseIsA,
    uint128 maxVolume,
    uint128 startPrice,
    uint128 endPrice,
    uint64 startTime,
    uint64 duration,
    uint16 feeRateBps
);

event CurveUpdated(
    uint256 indexed curveId,
    bytes32 indexed makerPositionKey,
    uint32 generation,
    CurveUpdateParams params
);

event CurveFilled(
    uint256 indexed curveId,
    address indexed taker,
    address indexed recipient,
    uint256 amountIn,
    uint256 amountOut,
    uint256 feeAmount,
    uint256 remainingVolume
);

event CurveCancelled(
    uint256 indexed curveId,
    bytes32 indexed makerPositionKey,
    uint256 remainingVolume
);

event CurveExpired(
    uint256 indexed curveId,
    bytes32 indexed makerPositionKey,
    uint256 remainingVolume
);

// Batch events
event CurvesBatchCreated(bytes32 indexed makerPositionKey, uint256 indexed firstCurveId, uint256 count);
event CurvesBatchUpdated(bytes32 indexed makerPositionKey, uint256 count);
event CurvesBatchCancelled(bytes32 indexed makerPositionKey, uint256 count);
event CurvesBatchExpired(bytes32 indexed makerPositionKey, uint256 count);

event MamPausedUpdated(bool paused);
```

---

## Security Considerations

1. **Volume Locking**: Base asset is locked at creation, preventing double-spending.

2. **Price Bounds**: Both start and end prices must be non-zero.

3. **Time Validation**: Start time must be in the future (or now), duration must be positive.

4. **Commitment Hashing**: Curve parameters are hashed for integrity verification.

5. **Generation Tracking**: Updates increment generation to detect stale quotes.

6. **Slippage Protection**: `minOut` parameter protects takers from price changes.

7. **Deadline Protection**: Transaction deadline prevents stale fills.

8. **Reentrancy Protection**: All state-changing functions use `nonReentrant`.

9. **Position Ownership**: Only maker can update or cancel their curves.

10. **Treasury Requirement**: Treasury must be set for fee distribution.

11. **Native ETH Support**: MAM curves fully support native ETH as either base or quote asset. The `LibCurrency` library handles all native ETH operations including deposits via `msg.value`, tracked balance accounting, and secure transfers.

---

**Document Version:** 2.0 (Updated for native ETH support)
**Last Updated:** January 2026
