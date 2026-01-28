# Community Auction System Design

**Version:** 1.1 (Updated for centralized fee index and encumbrance systems)

This document describes the Community Auction system, which extends the AMM Auction model to support multiple makers pooling liquidity into a shared auction. This enables smaller capital holders to participate in market making collectively, sharing maker fees proportionally based on their contribution.

## Table of Contents

1. [Overview](#overview)
2. [How It Works](#how-it-works)
3. [Architecture](#architecture)
4. [Auction Lifecycle](#auction-lifecycle)
5. [Maker Participation](#maker-participation)
6. [Swap Mechanics](#swap-mechanics)
7. [Fee Structure](#fee-structure)
8. [Discovery & Indexing](#discovery--indexing)
9. [Integration Guide](#integration-guide)
10. [Worked Examples](#worked-examples)
11. [Comparison with AMM Auctions](#comparison-with-amm-auctions)

---

## Overview

The Community Auction system enables multiple Position NFT holders to pool their liquidity into a shared constant-product AMM. Unlike single-maker AMM Auctions, Community Auctions allow collective market making where fees are distributed proportionally to all participants.

### Key Characteristics

| Feature | Description |
|---------|-------------|
| **Multi-Maker** | Multiple positions can contribute liquidity to a single auction |
| **Time-Bounded** | Auctions have explicit start and end times |
| **Constant Product** | Uses x*y=k invariant for pricing |
| **Position-Backed** | Reserves come from makers' deposited principal |
| **Pro-Rata Fees** | Maker fees distributed proportionally via fee index |
| **Share-Based** | Contributions tracked via price-neutral liquidity shares |
| **Free Entry/Exit** | Makers can join before end and leave at any time |

### System Participants

| Role | Description |
|------|-------------|
| **Creator** | Position NFT holder who creates the auction with initial reserves |
| **Maker** | Any Position NFT holder who joins with additional liquidity |
| **Taker** | Anyone who swaps tokens through the auction |
| **Protocol** | Receives a portion of swap fees |

### High-Level Flow

```
┌─────────────┐                    ┌─────────────────────┐
│   Creator   │  createCommunity   │   Community         │
│ (Position)  │ ─────────────────► │   Auction           │
└─────────────┘                    │   (Shared AMM)      │
                                   └──────────┬──────────┘
┌─────────────┐                               │
│   Maker 1   │  joinCommunityAuction         │
│ (Position)  │ ─────────────────────────────►│
└─────────────┘                               │
                                              │
┌─────────────┐                               │
│   Maker 2   │  joinCommunityAuction         │
│ (Position)  │ ─────────────────────────────►│
└─────────────┘                               │
                                              │ swapExactIn
                                              ▼
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

Like single-maker AMM Auctions, Community Auctions use the classic constant product formula:

```
x × y = k
```

Where:
- `x` = aggregate reserve of token A (from all makers)
- `y` = aggregate reserve of token B (from all makers)
- `k` = invariant (product of reserves)

The key difference is that reserves are pooled from multiple makers rather than a single position.

### Share-Based Accounting

Each maker's contribution is tracked via **shares** calculated using the geometric mean:

```
shares = √(amountA × amountB)
```

This formula provides price-neutral liquidity units that fairly weight contributions regardless of the current token prices, without requiring oracles.

### Reserve Ratio Enforcement

When joining an existing auction, makers must contribute at the current reserve ratio:

```
requiredB = amountA × reserveB / reserveA
```

A 0.1% tolerance is allowed for rounding. This ensures new makers don't dilute existing makers or shift the price.

### Fee Index Mechanism

Maker fees are distributed using a per-auction fee index system (similar to the protocol's centralized `LibFeeIndex`):

```solidity
// On each swap, fees accrue to the per-auction index
feeIndexA += (makerFeeA × 1e18) / totalShares

// Each maker's pending fees
pendingFees = makerShare × (currentIndex - snapshotIndex) / 1e18
```

This allows makers to enter and exit freely while receiving their fair share of accumulated fees.

**Note:** The per-auction fee index is separate from the pool-level `LibFeeIndex`. The pool fee index portion (20% of swap fees) is distributed to all pool depositors via `LibFeeIndex.accrueWithSource()`.

---

## Architecture

### Contract Structure

```
src/EqualX/
└── CommunityAuctionFacet.sol    # Main auction logic

src/libraries/
├── DerivativeTypes.sol           # CommunityAuction, MakerPosition structs
├── LibDerivativeStorage.sol      # Storage and indexing
├── LibDerivativeHelpers.sol      # Reserve locking utilities
├── LibEncumbrance.sol            # Centralized encumbrance tracking
├── LibCommunityAuctionFeeIndex.sol # Per-auction fee distribution
├── LibFeeIndex.sol               # Pool-level fee index accounting
├── LibFeeTreasury.sol            # Treasury fee routing
└── LibAuctionSwap.sol            # Shared swap math

src/views/
└── DerivativeViewFacet.sol       # Query functions
```

### Data Structures

**Community Auction:**
```solidity
struct CommunityAuction {
    // Creator info
    bytes32 creatorPositionKey;      // Position that created the auction
    uint256 creatorPositionId;       // Creator's Position NFT ID
    
    // Pool configuration
    uint256 poolIdA;                 // Pool for token A
    uint256 poolIdB;                 // Pool for token B
    address tokenA;                  // First token address
    address tokenB;                  // Second token address
    
    // Aggregate reserves (from all makers)
    uint256 reserveA;                // Current reserve of token A
    uint256 reserveB;                // Current reserve of token B
    
    // Fee configuration
    uint16 feeBps;                   // Fee in basis points
    FeeAsset feeAsset;               // Fee taken from TokenIn or TokenOut
    
    // Fee indexes (1e18 scale)
    uint256 feeIndexA;               // Accumulated fee index for token A
    uint256 feeIndexB;               // Accumulated fee index for token B
    uint256 feeIndexRemainderA;      // Remainder for precision
    uint256 feeIndexRemainderB;      // Remainder for precision
    
    // Maker tracking
    uint256 totalShares;             // Sum of all maker shares
    uint256 makerCount;              // Number of active makers
    
    // Timing
    uint64 startTime;                // When swaps become active
    uint64 endTime;                  // When swaps stop
    
    // State
    bool active;                     // Whether auction is live
    bool finalized;                  // Whether auction has been closed
}
```

**Maker Position:**
```solidity
struct MakerPosition {
    uint256 share;                   // Maker's contribution weight
    uint256 feeIndexSnapshotA;       // Index checkpoint for tokenA fees
    uint256 feeIndexSnapshotB;       // Index checkpoint for tokenB fees
    uint256 initialContributionA;    // Original contribution (for IL tracking)
    uint256 initialContributionB;    // Original contribution (for IL tracking)
    bool isParticipant;              // Whether actively participating
}
```

**Creation Parameters:**
```solidity
struct CreateCommunityAuctionParams {
    uint256 positionId;      // Creator's Position NFT ID
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
function createCommunityAuction(CreateCommunityAuctionParams calldata params)
    external
    returns (uint256 auctionId);
```

**What Happens:**
1. Validates position ownership and pool membership
2. Settles pending fee/credit indexes for both pools
3. Locks `reserveA` from pool A and `reserveB` from pool B
4. Creates auction record with unique `auctionId`
5. Initializes creator as first maker with shares = √(reserveA × reserveB)
6. Sets fee indexes to zero
7. Adds auction to all discovery indexes
8. Emits `CommunityAuctionCreated` event

### 2. Joining (Other Makers)

Other Position NFT holders can join before the auction ends:

```solidity
function joinCommunityAuction(
    uint256 auctionId,
    uint256 positionId,
    uint256 amountA,
    uint256 amountB
) external;
```

**Requirements:**
- Auction must be active and not finalized
- `block.timestamp < endTime`
- Position must be member of both pools
- Contribution ratio must match current reserves (±0.1%)
- Position must not already be a participant

**What Happens:**
1. Validates ratio: `amountB ≈ amountA × reserveB / reserveA`
2. Settles maker's fee/credit indexes
3. Locks contributed amounts from maker's position
4. Calculates shares: `√(amountA × amountB)`
5. Snapshots current fee indexes for the maker
6. Updates auction reserves and total shares
7. Increments maker count
8. Emits `MakerJoined` event

### 3. Active Period

During the active window (`startTime ≤ now < endTime`):
- Takers can swap tokens in either direction
- Each swap updates aggregate reserves
- Fees are collected and split (maker portion accrues to fee index)
- Makers can leave at any time
- New makers can join (before endTime)

### 4. Leaving

Makers can exit at any time (even before the auction ends):

```solidity
function leaveCommunityAuction(uint256 auctionId, uint256 positionId)
    external
    returns (uint256 withdrawnA, uint256 withdrawnB, uint256 feesA, uint256 feesB);
```

**What Happens:**
1. Settles pending fees for the maker
2. Calculates proportional reserves:
   - `withdrawnA = reserveA × makerShare / totalShares`
   - `withdrawnB = reserveB × makerShare / totalShares`
3. Unlocks reserves back to maker's position
4. Updates auction reserves and total shares
5. Decrements maker count
6. If last maker leaves, auction is finalized
7. Emits `MakerLeft` event

### 5. Fee Claiming

Makers can claim accumulated fees without leaving:

```solidity
function claimFees(uint256 auctionId, uint256 positionId)
    external
    returns (uint256 feesA, uint256 feesB);
```

**What Happens:**
1. Calculates pending fees from index delta
2. Updates maker's fee index snapshots
3. Credits fees to maker's accrued yield
4. Emits `FeesClaimed` event

### 6. Finalization

After `endTime`, anyone can finalize:

```solidity
function finalizeAuction(uint256 auctionId) external;
```

**What Happens:**
1. Marks auction as finalized (prevents new swaps/joins)
2. Removes from global active indexes
3. Makers must call `leaveCommunityAuction` to withdraw their share
4. Emits `CommunityAuctionFinalized` event

### 7. Cancellation

Creator can cancel before the auction starts:

```solidity
function cancelCommunityAuction(uint256 auctionId) external;
```

**Requirements:**
- Caller must own the creator position
- `block.timestamp < startTime`

**What Happens:**
1. Marks auction as finalized
2. Removes from indexes
3. Makers must call `leaveCommunityAuction` to withdraw
4. Emits `CommunityAuctionCancelled` event

---

## Maker Participation

### Share Calculation

Shares use the geometric mean for price-neutral weighting:

```
shares = √(amountA × amountB)
```

**Why Geometric Mean?**
- Price-neutral: Equal weighting regardless of token prices
- No oracle dependency: Works without external price feeds
- Consistent with Uniswap-style LP token math
- Prevents manipulation via asymmetric contributions

### Proportional Withdrawal

When leaving, makers receive their pro-rata share of current reserves:

```
withdrawA = reserveA × makerShare / totalShares
withdrawB = reserveB × makerShare / totalShares
```

**Impermanent Loss:**
If the price has moved since joining, the withdrawn amounts may differ from the initial contribution. This is the standard impermanent loss experienced by AMM liquidity providers.

### Join-Leave Round Trip

If a maker joins and immediately leaves (with no intervening swaps):
- They receive back exactly their contributed amounts (within 1 wei rounding)
- No fees are earned (no swaps occurred)

### Time Windows

```
                startTime                    endTime
                    │                           │
────────────────────┼───────────────────────────┼────────────────────►
                    │                           │                 time
    ◄──────────────►│◄─────────────────────────►│◄────────────────►
    Before Start    │      Active Window        │   After Expiry
                    │                           │
    • Join allowed  │  • Swaps allowed          │  • No swaps
    • Leave allowed │  • Join allowed           │  • No joins
    • Cancel OK     │  • Leave allowed          │  • Leave allowed
                    │  • No cancel              │  • Must finalize
```

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

Identical to single-maker AMM Auctions:

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

### Slippage Protection

The `minOut` parameter protects against slippage:
```solidity
if (amountOut < minOut) revert CommunityAuction_Slippage(minOut, amountOut);
```

---

## Fee Structure

### Fee Split

Every swap fee is split three ways:

| Recipient | Share | Purpose |
|-----------|-------|---------|
| **Makers** | 70% | Distributed pro-rata to all makers via per-auction fee index |
| **Fee Index** | 20% | Distributed to pool depositors via `LibFeeIndex` |
| **Treasury** | 10% | Protocol revenue via `LibFeeTreasury` |

```solidity
uint16 internal constant FEE_SPLIT_MAKER_BPS = 7000;   // 70%
uint16 internal constant FEE_SPLIT_INDEX_BPS = 2000;   // 20%
uint16 internal constant FEE_SPLIT_TREASURY_BPS = 1000; // 10%
```

### Fee Index Accrual

When a swap generates maker fees, they accrue to the per-auction fee index:

```solidity
// Scale fee for precision
scaledFee = makerFee × 1e18

// Add remainder from previous swaps
dividend = scaledFee + feeIndexRemainder

// Calculate index delta
delta = dividend / totalShares

// Update index and remainder
feeIndex += delta
feeIndexRemainder = dividend - (delta × totalShares)
```

The remainder tracking prevents precision loss across many small swaps.

**Pool Fee Index Distribution:**
The pool depositor portion (20%) is distributed via the centralized `LibFeeIndex`:

```solidity
// Accrue to pool fee index
LibFeeIndex.accrueWithSource(poolId, poolFeeShare, "COMMUNITY_AUCTION_FEE");
```

### Fee Settlement

When a maker leaves or claims fees:

```solidity
// Calculate pending fees from index delta
deltaA = feeIndexA - makerSnapshotA
deltaB = feeIndexB - makerSnapshotB

feesA = (makerShare × deltaA) / 1e18
feesB = (makerShare × deltaB) / 1e18

// Update snapshots
makerSnapshotA = feeIndexA
makerSnapshotB = feeIndexB
```

### Fee Asset Selection

| `feeAsset` | Fee Taken From | Use Case |
|------------|----------------|----------|
| `TokenIn` | Input amount before swap | Predictable input cost |
| `TokenOut` | Output amount after swap | Predictable output |

---

## Discovery & Indexing

Community Auctions are indexed for efficient discovery:

### By Position
```solidity
function getCommunityAuctionsByPosition(bytes32 positionKey, uint256 offset, uint256 limit)
    external view returns (uint256[] memory ids, uint256 total);
```

### By Token Pair
```solidity
function getCommunityAuctionsByPair(address tokenA, address tokenB, uint256 offset, uint256 limit)
    external view returns (uint256[] memory ids, uint256 total);
```

### Global Active List
```solidity
function getActiveCommunityAuctions(uint256 offset, uint256 limit)
    external view returns (uint256[] memory ids, uint256 total);
```

---

## Integration Guide

### For Developers

#### Creating a Community Auction

```solidity
// 1. Ensure position has deposited both tokens
// 2. Ensure position is member of both pools

DerivativeTypes.CreateCommunityAuctionParams memory params = 
    DerivativeTypes.CreateCommunityAuctionParams({
        positionId: myPositionId,
        poolIdA: wethPoolId,
        poolIdB: usdcPoolId,
        reserveA: 5e18,               // 5 WETH
        reserveB: 10000e6,            // 10,000 USDC
        startTime: uint64(block.timestamp + 1 hours),
        endTime: uint64(block.timestamp + 7 days),
        feeBps: 30,                   // 0.30% fee
        feeAsset: DerivativeTypes.FeeAsset.TokenOut
    });

uint256 auctionId = communityAuctionFacet.createCommunityAuction(params);
```

#### Joining an Existing Auction

```solidity
// 1. Preview required amounts
uint256 myAmountA = 2e18; // 2 WETH
uint256 requiredB = communityAuctionFacet.previewJoin(auctionId, myAmountA);
// requiredB ≈ 4000e6 (4,000 USDC at current ratio)

// 2. Join the auction
communityAuctionFacet.joinCommunityAuction(
    auctionId,
    myPositionId,
    myAmountA,
    requiredB
);
```

#### Swapping Tokens

```solidity
// 1. Approve input token
weth.approve(diamond, amountIn);

// 2. Execute swap (same interface as AMM Auctions)
uint256 amountOut = communityAuctionFacet.swapExactIn(
    auctionId,
    address(weth),
    1e18,           // 1 WETH
    1900e6,         // min 1900 USDC (slippage protection)
    msg.sender
);
```

#### Claiming Fees

```solidity
// Claim accumulated fees without leaving
(uint256 feesA, uint256 feesB) = communityAuctionFacet.claimFees(
    auctionId,
    myPositionId
);
```

#### Leaving the Auction

```solidity
// Preview withdrawal
(uint256 withdrawA, uint256 withdrawB, uint256 feesA, uint256 feesB) = 
    communityAuctionFacet.previewLeave(auctionId, myPositionKey);

// Leave and receive reserves + fees
(uint256 actualA, uint256 actualB, uint256 earnedA, uint256 earnedB) = 
    communityAuctionFacet.leaveCommunityAuction(auctionId, myPositionId);
```

### For Users

#### Creating a Community Auction (Creator)

1. **Deposit liquidity** into a Position NFT for both tokens
2. **Join pools** for both token types
3. **Create auction** specifying:
   - Initial reserve amounts (sets the starting price)
   - Time window (start and end)
   - Fee rate (shared among all makers)
4. **Invite others** to join your auction
5. **Monitor** trading activity and fee accumulation
6. **Leave** after expiry to collect your share + fees

#### Joining an Auction (Maker)

1. **Find auctions** for your desired token pair
2. **Check current ratio** via `previewJoin`
3. **Deposit liquidity** into your Position NFT
4. **Join** with amounts matching the current ratio
5. **Earn fees** proportional to your share
6. **Leave** anytime to withdraw your share + fees

#### Swapping (Taker)

Same experience as single-maker AMM Auctions:
1. **Find auctions** for your desired token pair
2. **Compare prices** across active auctions
3. **Execute swap** with slippage protection
4. **Receive tokens** at the recipient address

---

## Worked Examples

### Example 1: Multi-Maker Auction with Fee Distribution

**Scenario:** Alice creates an auction, Bob joins, swaps occur, both exit.

**Step 1: Alice creates the auction**
```solidity
CreateCommunityAuctionParams({
    positionId: 42,
    poolIdA: 1,                    // WETH pool
    poolIdB: 2,                    // USDC pool
    reserveA: 10e18,               // 10 WETH
    reserveB: 20000e6,             // 20,000 USDC
    startTime: block.timestamp,
    endTime: block.timestamp + 7 days,
    feeBps: 30,                    // 0.30%
    feeAsset: FeeAsset.TokenOut
});
// Initial price: 20,000 / 10 = $2,000/ETH
// Alice's shares: √(10 × 20,000) = √200,000 ≈ 447.21
// totalShares: 447.21
```

**Step 2: Bob joins with 5 WETH + 10,000 USDC**
```solidity
// Bob must match the ratio: 5 WETH requires 10,000 USDC
communityAuctionFacet.joinCommunityAuction(auctionId, bobPositionId, 5e18, 10000e6);

// Bob's shares: √(5 × 10,000) = √50,000 ≈ 223.61
// totalShares: 447.21 + 223.61 = 670.82
// New reserves: 15 WETH, 30,000 USDC
// Alice owns: 447.21 / 670.82 = 66.67% of the pool
// Bob owns: 223.61 / 670.82 = 33.33% of the pool
```

**Step 3: Charlie swaps 3 WETH for USDC**
```solidity
// rawOut = (30,000 × 3) / (15 + 3) = 5,000 USDC
// fee = 5,000 × 0.003 = 15 USDC
// amountOut = 4,985 USDC

// Fee distribution:
// - Maker fee (70%): 10.5 USDC → accrues to fee index
// - Pool fee index (20%): 3 USDC
// - Treasury (10%): 1.5 USDC

// Fee index update:
// feeIndexB += (10.5 × 1e18) / 670.82 ≈ 15.65e15

// New reserves: 18 WETH, 25,015 USDC
```

**Step 4: Alice claims fees**
```solidity
// Alice's pending fees:
// feesB = 447.21 × 15.65e15 / 1e18 ≈ 7 USDC (66.67% of maker fees)
```

**Step 5: Bob leaves**
```solidity
// Bob's share of reserves:
// withdrawA = 18 × 223.61 / 670.82 = 6 WETH
// withdrawB = 25,015 × 223.61 / 670.82 = 8,338.33 USDC

// Bob's fees:
// feesB = 223.61 × 15.65e15 / 1e18 ≈ 3.5 USDC (33.33% of maker fees)

// Bob started with: 5 WETH + 10,000 USDC
// Bob ends with: 6 WETH + 8,341.83 USDC
// Net: +1 WETH, -1,658.17 USDC (sold ETH at ~$1,658 + fees)
```

**Step 6: Alice leaves after expiry**
```solidity
// Alice's share of remaining reserves:
// withdrawA = 12 WETH (18 - 6)
// withdrawB = 16,676.67 USDC (25,015 - 8,338.33)

// Alice started with: 10 WETH + 20,000 USDC
// Alice ends with: 12 WETH + 16,683.67 USDC (including 7 USDC fees)
// Net: +2 WETH, -3,316.33 USDC
```

### Example 2: Late Joiner Fee Fairness

**Scenario:** Demonstrates that late joiners only earn fees from swaps after they join.

**Setup:**
- Alice creates auction with 10 WETH / 20,000 USDC
- Multiple swaps occur, generating 100 USDC in maker fees
- Bob joins
- More swaps occur, generating 50 USDC in maker fees
- Both leave

**Fee Distribution:**
```
First 100 USDC fees:
- Alice: 100 USDC (100% - she was the only maker)
- Bob: 0 USDC (hadn't joined yet)

Second 50 USDC fees (assuming equal shares after Bob joins):
- Alice: 33.33 USDC (66.67% share)
- Bob: 16.67 USDC (33.33% share)

Total:
- Alice: 133.33 USDC
- Bob: 16.67 USDC
```

The fee index mechanism ensures Bob's snapshot starts at the current index when he joins, so he only earns fees from subsequent swaps.

### Example 3: Impermanent Loss Scenario

**Scenario:** Price moves significantly during the auction.

**Setup:**
- Alice and Bob each contribute 5 WETH + 10,000 USDC
- Initial price: $2,000/ETH
- Total reserves: 10 WETH + 20,000 USDC
- Each has 50% share

**After price moves to $2,500/ETH (via arbitrage swaps):**
```
New reserves (approximately): 8.94 WETH + 22,361 USDC
(Reserves shift to maintain k = 200,000)

Each maker's withdrawal:
- 4.47 WETH + 11,180.50 USDC

Value comparison at $2,500/ETH:
- Initial: 5 × $2,500 + $10,000 = $22,500
- Final: 4.47 × $2,500 + $11,180.50 = $22,355.50
- IL: $144.50 (0.64%)

Plus accumulated fees from arbitrage swaps!
```

### Example 4: Last Maker Auto-Finalization

**Scenario:** When the last maker leaves, the auction auto-finalizes.

```solidity
// Auction has 3 makers: Alice (50%), Bob (30%), Charlie (20%)

// Charlie leaves first
communityAuctionFacet.leaveCommunityAuction(auctionId, charliePositionId);
// Auction still active, 2 makers remain

// Bob leaves
communityAuctionFacet.leaveCommunityAuction(auctionId, bobPositionId);
// Auction still active, 1 maker remains

// Alice leaves (last maker)
communityAuctionFacet.leaveCommunityAuction(auctionId, alicePositionId);
// Auction auto-finalizes: active = false, finalized = true
// Removed from global indexes
```

---

## Comparison with AMM Auctions

| Aspect | Community Auction | AMM Auction |
|--------|-------------------|-------------|
| **Makers** | Multiple (unlimited) | Single |
| **Liquidity** | Pooled from many positions | Single position |
| **Fee Distribution** | Pro-rata via fee index | Direct to maker |
| **Share Tracking** | √(amountA × amountB) shares | N/A (single owner) |
| **Join/Leave** | Anytime (with ratio matching) | N/A |
| **Impermanent Loss** | Shared among makers | Single maker bears |
| **Capital Efficiency** | Higher (pooled liquidity) | Lower (single source) |
| **Complexity** | Higher (multi-party accounting) | Lower |
| **Use Case** | Collective market making | Individual market making |

### When to Use Community Auctions

- **Smaller capital holders** wanting to participate in market making
- **DAOs or groups** pooling treasury assets
- **Higher liquidity** requirements for a trading pair
- **Risk sharing** for impermanent loss

### When to Use AMM Auctions

- **Single large holder** with sufficient capital
- **Simpler accounting** requirements
- **Full control** over the auction
- **No fee sharing** desired

---

## Error Reference

| Error | Cause |
|-------|-------|
| `CommunityAuction_Paused` | Community auction system is paused |
| `CommunityAuction_InvalidAmount` | Zero reserve or contribution amount |
| `CommunityAuction_InvalidRatio` | Join amounts don't match current reserve ratio |
| `CommunityAuction_InvalidPool` | Same pool for both tokens |
| `CommunityAuction_InvalidFee` | Fee exceeds maximum |
| `CommunityAuction_NotActive` | Auction not active or outside time window |
| `CommunityAuction_AlreadyFinalized` | Auction already closed |
| `CommunityAuction_NotExpired` | Trying to finalize before end time |
| `CommunityAuction_NotCreator` | Non-creator trying to cancel |
| `CommunityAuction_AlreadyStarted` | Trying to cancel after start time |
| `CommunityAuction_AlreadyParticipant` | Position already joined this auction |
| `CommunityAuction_NotParticipant` | Position not a participant |
| `CommunityAuction_InvalidToken` | Token not part of this auction |
| `CommunityAuction_Slippage` | Output less than minimum |
| `PoolMembershipRequired` | Position not member of required pool |
| `InsufficientPrincipal` | Not enough available principal |

---

## Events

```solidity
event CommunityAuctionCreated(
    uint256 indexed auctionId,
    bytes32 indexed creatorPositionKey,
    uint256 indexed creatorPositionId,
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

event MakerJoined(
    uint256 indexed auctionId,
    bytes32 indexed positionKey,
    uint256 positionId,
    uint256 amountA,
    uint256 amountB,
    uint256 share
);

event MakerLeft(
    uint256 indexed auctionId,
    bytes32 indexed positionKey,
    uint256 positionId,
    uint256 withdrawnA,
    uint256 withdrawnB,
    uint256 feesA,
    uint256 feesB
);

event FeesClaimed(
    uint256 indexed auctionId,
    bytes32 indexed positionKey,
    uint256 feesA,
    uint256 feesB
);

event CommunityAuctionSwapped(
    uint256 indexed auctionId,
    address indexed swapper,
    address tokenIn,
    uint256 amountIn,
    uint256 amountOut,
    uint256 feeAmount,
    address recipient
);

event CommunityAuctionFinalized(
    uint256 indexed auctionId,
    bytes32 indexed creatorPositionKey,
    uint256 reserveA,
    uint256 reserveB
);

event CommunityAuctionCancelled(
    uint256 indexed auctionId,
    bytes32 indexed creatorPositionKey,
    uint256 reserveA,
    uint256 reserveB
);
```

---

## Security Considerations

1. **Ratio Enforcement**: Join contributions must match current reserves (±0.1%), preventing price manipulation by new makers.

2. **Fee Index Precision**: Remainder tracking prevents precision loss across many small swaps, ensuring accurate fee distribution.

3. **Share Invariant**: Sum of all maker shares always equals totalShares, verified on every join/leave.

4. **Reserve Invariant**: Sum of proportional withdrawals equals total reserves.

5. **Late Joiner Fairness**: Fee index snapshots ensure makers only earn fees from swaps after they join.

6. **Reentrancy Protection**: All state-changing functions use `nonReentrant` modifier.

7. **Position Ownership**: Only position owners can join, leave, or claim fees.

8. **Cancel Restriction**: Only creator can cancel, and only before start time.

9. **Auto-Finalization**: Last maker leaving auto-finalizes to prevent orphaned auctions.

10. **Flash Accounting Isolation**: Swaps don't affect individual maker principal during the auction.

11. **Treasury Requirement**: Treasury address must be set for fee distribution.

12. **Time Window Enforcement**: Swaps only allowed within active window, joins only before end.

13. **Centralized Encumbrance (LibEncumbrance)**: Maker reserves are tracked via the centralized encumbrance system, ensuring consistent solvency checks across all protocol features:

```solidity
// Reserve locking on join
LibEncumbrance.position(positionKey, poolIdA).directLent += amountA;
LibEncumbrance.position(positionKey, poolIdB).directLent += amountB;

// Reserve unlocking on leave
LibEncumbrance.position(positionKey, poolIdA).directLent -= withdrawnA;
LibEncumbrance.position(positionKey, poolIdB).directLent -= withdrawnB;
```

14. **Centralized Pool Fee Index (LibFeeIndex)**: Pool depositor fees are distributed via `LibFeeIndex.accrueWithSource()` for consistent, auditable fee accounting.

---

## Invariants

The following properties hold for all valid Community Auction states:

1. **Share Conservation**: `Σ(maker.share) == auction.totalShares`

2. **Reserve Conservation**: `Σ(maker.proportionalReserve) == auction.reserves`

3. **Fee Distribution**: `Σ(makerFees) == totalMakerFees` (within rounding)

4. **Monotonic Fee Index**: Fee indexes only increase

5. **Participant Consistency**: `maker.isParticipant == true` iff `maker.share > 0`

6. **Maker Count**: `auction.makerCount == count(makers where isParticipant)`
