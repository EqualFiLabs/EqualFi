# AMM Auction System Design

**Version:** 1.1 (Updated for centralized fee index and encumbrance systems)

This document describes the AMM Auction system, which allows Position NFT holders to create time-bounded automated market maker (AMM) pools using their deposited liquidity. These auctions enable trustless token swaps with constant-product pricing.

## Table of Contents

1. [Overview](#overview)
2. [How It Works](#how-it-works)
3. [Architecture](#architecture)
4. [Auction Lifecycle](#auction-lifecycle)
5. [Swap Mechanics](#swap-mechanics)
6. [Fee Structure](#fee-structure)
7. [Discovery & Indexing](#discovery--indexing)
8. [Integration Guide](#integration-guide)
9. [Worked Examples](#worked-examples)

---

## Overview

The AMM Auction system enables liquidity providers to create temporary AMM pools backed by their Position NFT deposits. Key characteristics:

| Feature | Description |
|---------|-------------|
| **Time-Bounded** | Auctions have explicit start and end times |
| **Constant Product** | Uses x*y=k invariant for pricing |
| **Position-Backed** | Reserves come from maker's deposited principal |
| **Fee Earning** | Makers earn fees on every swap |
| **Cancelable** | Makers can cancel before expiry |
| **Multi-Indexed** | Discoverable by pool, token, or pair |

### System Participants

| Role | Description |
|------|-------------|
| **Maker** | Position NFT holder who creates the auction with reserves |
| **Taker** | Anyone who swaps tokens through the auction |
| **Protocol** | Receives a portion of swap fees |

### High-Level Flow

```
┌─────────────┐                    ┌─────────────┐
│   Maker     │   createAuction    │   Auction   │
│ (Position)  │ ─────────────────► │   (AMM)     │
└─────────────┘                    └──────┬──────┘
      │                                   │
      │ lock reserves                     │ swapExactIn
      ▼                                   ▼
┌─────────────────────────────────────────────────────────────────┐
│                        Diamond Protocol                          │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐          │
│  │    Pool A    │  │    Pool B    │  │   Treasury   │          │
│  │   (TokenA)   │  │   (TokenB)   │  │              │          │
│  └──────────────┘  └──────────────┘  └──────────────┘          │
└─────────────────────────────────────────────────────────────────┘
                            │
                            │ swap
                            ▼
                    ┌─────────────┐
                    │   Taker     │
                    │  (Wallet)   │
                    └─────────────┘
```

---

## How It Works

### Constant Product AMM

The auction uses the classic constant product formula:

```
x × y = k
```

Where:
- `x` = reserve of token A
- `y` = reserve of token B  
- `k` = invariant (product of reserves)

When a swap occurs:
```
newReserveIn × newReserveOut ≥ k
```

The invariant is preserved or increased (due to fees).

### Reserve Locking

When an auction is created:
1. Maker specifies `reserveA` and `reserveB` amounts
2. These amounts are locked from the maker's position principal via `LibEncumbrance`
3. Locked reserves cannot be withdrawn during the auction
4. Reserves are tracked via the centralized encumbrance system:

```solidity
// Encumbrance structure (LibEncumbrance.sol)
struct Encumbrance {
    uint256 directLocked;       // Collateral locked for Direct loans
    uint256 directLent;         // Principal actively lent out (includes auction reserves)
    uint256 directOfferEscrow;  // Principal escrowed for pending offers
    uint256 indexEncumbered;    // Principal encumbered by index positions
}

// Access pattern
LibEncumbrance.position(positionKey, poolId).directLent += reserveAmount;
```

### Time Windows

```
                startTime                    endTime
                    │                           │
────────────────────┼───────────────────────────┼────────────────────►
                    │                           │                 time
    ◄──────────────►│◄─────────────────────────►│◄────────────────►
    Before Start    │      Active Window        │   After Expiry
                    │                           │
    • No swaps      │  • Swaps allowed          │  • No swaps
    • Can cancel    │  • Can cancel             │  • Must finalize
                    │                           │
```

---

## Architecture

### Contract Structure

```
src/EqualX/
└── AmmAuctionFacet.sol     # Main auction logic

src/libraries/
├── DerivativeTypes.sol      # AmmAuction struct
├── LibDerivativeStorage.sol # Storage and indexing
├── LibDerivativeHelpers.sol # Reserve locking utilities
├── LibEncumbrance.sol       # Centralized encumbrance tracking
├── LibFeeIndex.sol          # Centralized fee index accounting
└── LibFeeTreasury.sol       # Treasury fee routing

src/views/
└── DerivativeViewFacet.sol  # Query functions
```

### Data Structure

```solidity
struct AmmAuction {
    bytes32 makerPositionKey;    // Position that created the auction
    uint256 makerPositionId;     // Position NFT token ID
    uint256 poolIdA;             // Pool for token A
    uint256 poolIdB;             // Pool for token B
    address tokenA;              // First token address
    address tokenB;              // Second token address
    uint256 reserveA;            // Current reserve of token A
    uint256 reserveB;            // Current reserve of token B
    uint256 initialReserveA;     // Starting reserve A (for settlement)
    uint256 initialReserveB;     // Starting reserve B (for settlement)
    uint256 invariant;           // k = reserveA × reserveB
    uint64 startTime;            // When swaps become active
    uint64 endTime;              // When swaps stop
    uint16 feeBps;               // Fee in basis points
    FeeAsset feeAsset;           // Fee taken from TokenIn or TokenOut
    uint256 makerFeeAAccrued;    // Accumulated fees in token A
    uint256 makerFeeBAccrued;    // Accumulated fees in token B
    bool active;                 // Whether auction is live
    bool finalized;              // Whether auction has been closed
}

enum FeeAsset {
    TokenIn,   // Fee deducted from input amount
    TokenOut   // Fee deducted from output amount
}
```

### Creation Parameters

```solidity
struct CreateAuctionParams {
    uint256 positionId;      // Maker's Position NFT ID
    uint256 poolIdA;         // Pool containing token A
    uint256 poolIdB;         // Pool containing token B
    uint256 reserveA;        // Initial reserve of token A
    uint256 reserveB;        // Initial reserve of token B
    uint64 startTime;        // Auction start timestamp
    uint64 endTime;          // Auction end timestamp
    uint16 feeBps;           // Fee rate (e.g., 30 = 0.30%)
    FeeAsset feeAsset;       // Where to take fees from
}
```

---

## Auction Lifecycle

### 1. Creation

**Requirements:**
- Caller must own the Position NFT
- Position must be a member of both pools
- Sufficient unlocked principal in both pools
- `endTime > startTime`
- `feeBps ≤ maxFeeBps` (if configured)

**Function:**
```solidity
function createAuction(CreateAuctionParams calldata params)
    external
    returns (uint256 auctionId);
```

**What Happens:**
1. Validates position ownership and pool membership
2. Settles pending fee/credit indexes for both pools
3. Locks `reserveA` from pool A and `reserveB` from pool B
4. Creates auction record with unique `auctionId`
5. Adds auction to all discovery indexes
6. Emits `AuctionCreated` event

### 2. Active Period

During the active window (`startTime ≤ now < endTime`):
- Takers can swap tokens in either direction
- Each swap updates reserves according to constant product formula
- Fees are collected and split between maker, fee index, and treasury
- Maker can cancel at any time

### 3. Finalization

After `endTime`, anyone can finalize:

```solidity
function finalizeAuction(uint256 auctionId) external;
```

**What Happens:**
1. Unlocks remaining reserves back to maker's position
2. Applies principal delta (gain/loss from trading)
3. Removes auction from all indexes
4. Emits `AuctionFinalized` event

### 4. Cancellation

Maker can cancel anytime before finalization:

```solidity
function cancelAuction(uint256 auctionId) external;
```

**What Happens:**
1. Validates caller owns the maker position
2. Unlocks current reserves (may differ from initial)
3. Applies principal delta
4. Removes from indexes
5. Emits `AuctionCancelled` event

---

## Swap Mechanics

### Swap Function

```solidity
function swapExactIn(
    uint256 auctionId,
    address tokenIn,
    uint256 amountIn,
    uint256 minOut,
    address recipient
) external returns (uint256 amountOut);
```

### Swap Calculation

**Fee on TokenOut (default):**
```
rawOut = (reserveOut × amountIn) / (reserveIn + amountIn)
feeAmount = rawOut × feeBps / 10000
amountOut = rawOut - feeAmount
```

**Fee on TokenIn:**
```
amountInWithFee = amountIn × (10000 - feeBps) / 10000
feeAmount = amountIn - amountInWithFee
rawOut = (reserveOut × amountInWithFee) / (reserveIn + amountInWithFee)
amountOut = rawOut
```

### Reserve Updates

After each swap:
```
newReserveIn = reserveIn + actualAmountIn
newReserveOut = reserveOut - amountOut - protocolFees
```

The invariant is preserved or increased:
```
newReserveIn × newReserveOut ≥ initialReserveA × initialReserveB
```

### Slippage Protection

The `minOut` parameter protects against slippage:
```solidity
if (amountOut < minOut) revert AmmAuction_Slippage(minOut, amountOut);
```

### Preview Function

Check expected output before swapping:
```solidity
function previewSwap(uint256 auctionId, address tokenIn, uint256 amountIn)
    external view
    returns (uint256 amountOut, uint256 feeAmount);
```

### Swap-or-Finalize

Convenience function that auto-finalizes expired auctions:
```solidity
function swapExactInOrFinalize(
    uint256 auctionId,
    address tokenIn,
    uint256 amountIn,
    uint256 minOut,
    address recipient
) external returns (uint256 amountOut, bool finalized);
```

---

## Fee Structure

### Fee Split

Every swap fee is split three ways:

| Recipient | Share | Purpose |
|-----------|-------|---------|
| **Maker** | 70% | Reward for providing liquidity |
| **Fee Index** | 20% | Distributed to pool depositors via `LibFeeIndex` |
| **Treasury** | 10% | Protocol revenue via `LibFeeTreasury` |

```solidity
uint16 internal constant FEE_SPLIT_MAKER_BPS = 7000;   // 70%
uint16 internal constant FEE_SPLIT_INDEX_BPS = 2000;   // 20%
uint16 internal constant FEE_SPLIT_TREASURY_BPS = 1000; // 10%
```

### Fee Accrual

**Maker Fees:**
- Tracked per-auction in `makerFeeAAccrued` and `makerFeeBAccrued`
- Automatically credited to maker's position at finalization
- Denominated in the fee asset (TokenIn or TokenOut)

**Fee Index (via LibFeeIndex):**
- Accrued to the pool's fee index using `LibFeeIndex.accrueWithSource()`
- Distributed pro-rata to all pool depositors based on their fee base
- Source tagged as `AMM_AUCTION_FEE`

```solidity
// Fee index accrual
LibFeeIndex.accrueWithSource(poolId, feeIndexShare, "AMM_AUCTION_FEE");
```

**Treasury (via LibFeeTreasury):**
- Routed to protocol treasury via `LibFeeTreasury`
- Requires treasury address to be configured

### Fee Asset Selection

| `feeAsset` | Fee Taken From | Use Case |
|------------|----------------|----------|
| `TokenIn` | Input amount before swap | Predictable input cost |
| `TokenOut` | Output amount after swap | Predictable output |

---

## Discovery & Indexing

Auctions are indexed multiple ways for efficient discovery:

### By Position
```solidity
function getAuctionsByPosition(bytes32 positionKey, uint256 offset, uint256 limit)
    external view returns (uint256[] memory ids, uint256 total);
```

### By Pool
```solidity
function getAuctionsByPool(uint256 poolId, uint256 offset, uint256 limit)
    external view returns (uint256[] memory ids, uint256 total);
```

### By Token
```solidity
function getAuctionsByToken(address token, uint256 offset, uint256 limit)
    external view returns (uint256[] memory ids, uint256 total);
```

### By Token Pair
```solidity
function getAuctionsByPair(address tokenA, address tokenB, uint256 offset, uint256 limit)
    external view returns (uint256[] memory ids, uint256 total);
```

### Global Active List
```solidity
function getActiveAuctions(uint256 offset, uint256 limit)
    external view returns (uint256[] memory ids, uint256 total);
```

### Best Quote Finder
```solidity
function findBestAuctionExactIn(
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 offset,
    uint256 limit
) external view returns (uint256 bestAuctionId, uint256 bestAmountOut, uint256 checked);
```

---

## Integration Guide

### For Developers

#### Creating an Auction

```solidity
// 1. Ensure position has deposited both tokens
// 2. Ensure position is member of both pools

DerivativeTypes.CreateAuctionParams memory params = DerivativeTypes.CreateAuctionParams({
    positionId: myPositionId,
    poolIdA: wethPoolId,
    poolIdB: usdcPoolId,
    reserveA: 10e18,              // 10 WETH
    reserveB: 20000e6,            // 20,000 USDC
    startTime: uint64(block.timestamp),
    endTime: uint64(block.timestamp + 7 days),
    feeBps: 30,                   // 0.30% fee
    feeAsset: DerivativeTypes.FeeAsset.TokenOut
});

uint256 auctionId = ammAuctionFacet.createAuction(params);
```

#### Swapping Tokens

```solidity
// 1. Approve input token
weth.approve(diamond, amountIn);

// 2. Preview the swap
(uint256 expectedOut, uint256 fee) = ammAuctionFacet.previewSwap(
    auctionId,
    address(weth),
    amountIn
);

// 3. Calculate minimum output with slippage
uint256 minOut = expectedOut * 995 / 1000; // 0.5% slippage

// 4. Execute swap
uint256 amountOut = ammAuctionFacet.swapExactIn(
    auctionId,
    address(weth),
    amountIn,
    minOut,
    msg.sender
);
```

#### Finding Best Price

```solidity
// Find best auction for WETH → USDC swap
(uint256 bestAuctionId, uint256 bestOut, uint256 checked) = 
    derivativeViewFacet.findBestAuctionExactIn(
        address(weth),
        address(usdc),
        1e18,      // 1 WETH
        0,         // offset
        100        // limit
    );

if (bestAuctionId != 0) {
    // Execute swap on best auction
    ammAuctionFacet.swapExactIn(bestAuctionId, address(weth), 1e18, bestOut * 99 / 100, msg.sender);
}
```

### For Users

#### Creating an Auction (Maker)

1. **Deposit liquidity** into a Position NFT for both tokens
2. **Join pools** for both token types
3. **Create auction** specifying:
   - Reserve amounts (determines initial price)
   - Time window (start and end)
   - Fee rate (your earnings per swap)
4. **Monitor** your auction for trading activity
5. **Finalize** after expiry to collect reserves + fees

#### Swapping (Taker)

1. **Find auctions** for your desired token pair
2. **Compare prices** across active auctions
3. **Preview swap** to see expected output
4. **Execute swap** with slippage protection
5. **Receive tokens** at the recipient address

#### Price Calculation

The spot price in an AMM auction is:
```
Price of A in terms of B = reserveB / reserveA
```

For example, with 10 WETH and 20,000 USDC:
```
Price = 20,000 / 10 = 2,000 USDC per WETH
```

---

## Worked Examples

### Example 1: Basic Auction Creation and Swap

**Scenario:** Alice creates a WETH/USDC auction, Bob swaps.

**Setup:**
- Alice owns Position NFT #42
- Position has 10 WETH in Pool #1 and 25,000 USDC in Pool #2
- Alice wants to provide liquidity at $2,000/ETH

**Step 1: Alice creates the auction**
```solidity
CreateAuctionParams({
    positionId: 42,
    poolIdA: 1,                    // WETH pool
    poolIdB: 2,                    // USDC pool
    reserveA: 5e18,                // 5 WETH
    reserveB: 10000e6,             // 10,000 USDC
    startTime: block.timestamp,
    endTime: block.timestamp + 3 days,
    feeBps: 30,                    // 0.30%
    feeAsset: FeeAsset.TokenOut
});
// Initial price: 10,000 / 5 = $2,000/ETH
// Invariant k = 5 × 10,000 = 50,000
```

**Step 2: Bob swaps 1 WETH for USDC**
```solidity
// Preview: 
// rawOut = (10000 × 1) / (5 + 1) = 1666.67 USDC
// fee = 1666.67 × 0.003 = 5 USDC
// amountOut = 1661.67 USDC

ammAuctionFacet.swapExactIn(
    auctionId,
    weth,
    1e18,           // 1 WETH
    1650e6,         // min 1650 USDC (slippage protection)
    bob
);
```

**After swap:**
- Bob receives: ~1,661.67 USDC
- New reserves: 6 WETH, 8,333.33 USDC
- New price: 8,333.33 / 6 = $1,388.89/ETH (price impact)
- Fee collected: 5 USDC
  - Alice (maker): 3.5 USDC
  - Fee index: 1 USDC
  - Treasury: 0.5 USDC

**Step 3: After expiry, Alice finalizes**
```solidity
ammAuctionFacet.finalizeAuction(auctionId);
```

**Alice's final position:**
- Started with: 5 WETH + 10,000 USDC
- Ended with: 6 WETH + 8,333.33 USDC + 3.5 USDC fees
- Net: +1 WETH, -1,663.17 USDC (sold ETH at ~$1,663)

### Example 2: Arbitrage Opportunity

**Scenario:** Two auctions with different prices.

**Setup:**
- Auction #1: 10 WETH / 18,000 USDC (price: $1,800/ETH)
- Auction #2: 10 WETH / 22,000 USDC (price: $2,200/ETH)

**Arbitrage:**
1. Buy 1 WETH from Auction #1 for ~1,636 USDC
2. Sell 1 WETH to Auction #2 for ~1,833 USDC
3. Profit: ~197 USDC (minus fees)

```solidity
// Step 1: Buy cheap ETH
ammAuctionFacet.swapExactIn(auction1, usdc, 1636e6, 0.99e18, arbitrageur);

// Step 2: Sell expensive ETH
ammAuctionFacet.swapExactIn(auction2, weth, 1e18, 1800e6, arbitrageur);
```

### Example 3: Fee Comparison

**Scenario:** Compare TokenIn vs TokenOut fee modes.

**Setup:** 
- Reserves: 100 TokenA / 100 TokenB
- Fee: 1% (100 bps)
- Swap: 10 TokenA → TokenB

**Fee on TokenOut:**
```
rawOut = (100 × 10) / (100 + 10) = 9.09 TokenB
fee = 9.09 × 0.01 = 0.09 TokenB
amountOut = 9.00 TokenB
```

**Fee on TokenIn:**
```
amountInWithFee = 10 × 0.99 = 9.9 TokenA
fee = 0.1 TokenA
rawOut = (100 × 9.9) / (100 + 9.9) = 9.01 TokenB
amountOut = 9.01 TokenB
```

Slight difference due to when fee is applied in the calculation.

### Example 4: Multi-Auction Discovery

**Scenario:** Find best price across multiple auctions.

```solidity
// Query all WETH/USDC auctions
(uint256[] memory auctionIds, uint256 total) = 
    derivativeViewFacet.getAuctionsByPair(weth, usdc, 0, 50);

// Find best quote for 5 WETH
(uint256 bestId, uint256 bestOut, ) = 
    derivativeViewFacet.findBestAuctionExactIn(weth, usdc, 5e18, 0, 50);

// Preview with slippage
(uint256 expectedOut, uint256 fee, uint256 minOut) = 
    derivativeViewFacet.previewSwapWithSlippage(bestId, weth, 5e18, 100); // 1% slippage

// Execute on best auction
ammAuctionFacet.swapExactIn(bestId, weth, 5e18, minOut, msg.sender);
```

---

## Error Reference

| Error | Cause |
|-------|-------|
| `AmmAuction_Paused` | AMM system is paused |
| `AmmAuction_InvalidToken` | Token not part of this auction |
| `AmmAuction_InvalidPool` | Same pool for both tokens |
| `AmmAuction_InvalidAmount` | Zero reserve or swap amount |
| `AmmAuction_InvalidFee` | Fee exceeds maximum |
| `AmmAuction_NotActive` | Auction not active or before start |
| `AmmAuction_AlreadyFinalized` | Auction already closed |
| `AmmAuction_NotExpired` | Trying to finalize before end time |
| `AmmAuction_Expired` | Trying to swap after end time |
| `AmmAuction_Slippage` | Output less than minimum |
| `AmmAuction_NotMaker` | Caller not the auction maker |
| `PoolMembershipRequired` | Position not member of required pool |
| `InsufficientPrincipal` | Not enough available principal |

---

## Events

```solidity
event AuctionCreated(
    uint256 indexed auctionId,
    bytes32 indexed makerPositionKey,
    uint256 indexed makerPositionId,
    uint256 poolIdA,
    uint256 poolIdB,
    address tokenA,
    address tokenB,
    uint256 reserveA,
    uint256 reserveB,
    uint64 startTime,
    uint64 endTime,
    uint16 feeBps,
    FeeAsset feeAsset
);

event AuctionSwapped(
    uint256 indexed auctionId,
    address indexed swapper,
    address tokenIn,
    uint256 amountIn,
    uint256 amountOut,
    uint256 feeAmount,
    address recipient
);

event AuctionFinalized(
    uint256 indexed auctionId,
    bytes32 indexed makerPositionKey,
    uint256 reserveA,
    uint256 reserveB,
    uint256 makerFeeA,
    uint256 makerFeeB
);

event AuctionCancelled(
    uint256 indexed auctionId,
    bytes32 indexed makerPositionKey,
    uint256 reserveA,
    uint256 reserveB,
    uint256 makerFeeA,
    uint256 makerFeeB
);

event AmmPausedUpdated(bool paused);
```

---

## Security Considerations

1. **Invariant Preservation**: The constant product invariant is always preserved or increased, preventing value extraction.

2. **Time Window Enforcement**: Swaps are only allowed within the active window, preventing manipulation before/after.

3. **Slippage Protection**: `minOut` parameter protects takers from front-running and price manipulation.

4. **Fee-on-Transfer Support**: The contract measures actual received amounts, handling fee-on-transfer tokens correctly.

5. **Reentrancy Protection**: All state-changing functions use `nonReentrant` modifier.

6. **Position Ownership**: Only the Position NFT owner can create auctions or cancel them.

7. **Reserve Isolation via LibEncumbrance**: Locked reserves are tracked centrally via `LibEncumbrance`, preventing withdrawal or use for other purposes during the auction.

```solidity
// Encumbrance check before withdrawal
uint256 totalEncumbered = LibEncumbrance.total(positionKey, poolId);
require(principal >= totalEncumbered + withdrawAmount, "Insufficient available principal");
```

8. **Flash Accounting Isolation**: Swaps don't affect maker's principal or fee index snapshots during the auction.

9. **Treasury Requirement**: Treasury address must be set for fee distribution to work.

10. **Centralized Fee Index**: Fee distribution uses `LibFeeIndex.accrueWithSource()` for consistent, auditable fee accounting across all protocol features.

---

## Comparison with Traditional AMMs

| Aspect | AMM Auction | Uniswap-style AMM |
|--------|-------------|-------------------|
| **Duration** | Time-bounded | Permanent |
| **Liquidity** | Single maker | Multiple LPs |
| **LP Tokens** | None | ERC-20 LP tokens |
| **Fee Distribution** | Direct to maker | Pro-rata to LPs |
| **Impermanent Loss** | Maker bears fully | Shared among LPs |
| **Capital Efficiency** | Full reserve usage | Spread across price range |
| **Composability** | Position NFT based | Standalone pools |
