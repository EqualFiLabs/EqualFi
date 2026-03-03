# AMM Auction System Design

**Version:** 2.0 (Expanded stable-swap invariant math, decimal normalization, Newton-Raphson solver, and struct field updates)

This document describes the AMM Auction system, which allows Position NFT holders to create time-bounded automated market maker (AMM) pools using their deposited liquidity. These auctions enable trustless token swaps with selectable invariant pricing — constant-product for volatile pairs or Solidly-style stable-swap for correlated pairs.

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
| **Invariant Modes** | Maker chooses `Volatile` (constant-product x·y=k) or `Stable` (Solidly-style x³y+xy³=k) pricing at creation |
| **Decimal-Aware** | Stable mode normalizes reserves to 18-decimal WAD for cross-decimal pair accuracy |
| **Position-Backed** | Reserves come from maker's deposited principal |
| **Fee Earning** | Makers earn fees on every swap |
| **Cancelable** | Makers can cancel before expiry |
| **Multi-Indexed** | Discoverable by pool, token, or pair |

CL auctions are a separate system and are not modified by this design.

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

### Invariant Modes

Each auction stores an immutable `invariantMode` selected at creation:

| Mode | Invariant | Best For |
|------|-----------|----------|
| `Volatile` | Constant-product `x · y = k` | Uncorrelated pairs (e.g. WETH/USDC) |
| `Stable` | Solidly-style `x³y + xy³ = k` | Correlated/pegged pairs (e.g. USDC/USDT, wstETH/WETH) |

### Volatile Formula

Volatile mode uses the classic constant-product formula:

```
x × y = k
```

Where:
- `x` = reserve of token A
- `y` = reserve of token B  
- `k` = invariant (product of reserves)

When a volatile-mode swap occurs:
```
newReserveIn × newReserveOut ≥ k
```

The volatile invariant is preserved or increased (due to fees).

### Stable Formula

Stable mode uses the Solidly-style invariant, which concentrates liquidity around the 1:1 price ratio. This produces significantly lower slippage for swaps between correlated assets.

**Invariant equation:**

```
x³y + xy³ = k
```

Which can be factored as:

```
xy(x² + y²) = k
```

Where:
- `x` = WAD-normalized reserve of token A
- `y` = WAD-normalized reserve of token B
- `k` = invariant (preserved or increased after each swap)

**Decimal normalization:** Because stable pairs often involve tokens with different decimal precisions (e.g. USDC at 6 decimals, DAI at 18), all reserves are normalized to 18-decimal WAD representation before invariant math is applied. Results are converted back to native decimals for settlement. Supported decimal range: 1–18. Tokens with >18 decimals are rejected at creation.

**Newton-Raphson solver:** Given a new `x` after a swap, the output `y` is found by solving `f(x₀, y) = x₀·y³ + x₀³·y = k` using Newton-Raphson iteration:

```
y_{n+1} = y_n - f(y_n) / f'(y_n)

where:
  f(y)  = x₀·y³ + x₀³·y
  f'(y) = 3·x₀·y² + x₀³
```

The solver runs up to 255 iterations and converges when `|y_{n+1} - y_n| ≤ 1` (1 wei in WAD). If it does not converge, the swap reverts with `LibAuctionSwap_StableNonConvergence`.

**Zero-output guard:** Because the stable curve is very flat near parity, tiny swaps can round to zero output. Stable-mode swaps revert with `AmmAuction_ZeroOutput` if `outputToRecipient == 0` after fee deduction.

**Governance gate:** Stable mode must be explicitly enabled via `DerivativeConfig.stableModeEnabled`. If disabled, creation with `InvariantMode.Stable` reverts with `AmmAuction_StableModeDisabled`.

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
├── DerivativeTypes.sol      # AmmAuction struct, InvariantMode enum
├── LibAuctionSwap.sol       # Invariant-aware swap math (volatile + stable solver)
├── LibDerivativeStorage.sol # Storage and indexing
├── LibDerivativeHelpers.sol # Reserve locking utilities
├── LibEncumbrance.sol       # Centralized encumbrance tracking
├── LibFeeIndex.sol          # Centralized fee index accounting
└── LibFeeRouter.sol         # Router split (Treasury/ACI/FI)

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
    uint256 invariant;           // k = reserveA × reserveB (volatile) or xy(x²+y²) (stable)
    uint64 startTime;            // When swaps become active
    uint64 endTime;              // When swaps stop
    uint16 feeBps;               // Fee in basis points
    FeeAsset feeAsset;           // Fee taken from TokenIn or TokenOut
    InvariantMode invariantMode; // Volatile or Stable (immutable per-auction)
    uint256 makerFeeAAccrued;    // Accumulated fees in token A
    uint256 makerFeeBAccrued;    // Accumulated fees in token B
    uint256 treasuryFeeAAccrued; // Routed treasury fees in token A
    uint256 treasuryFeeBAccrued; // Routed treasury fees in token B
    bool active;                 // Whether auction is live
    bool finalized;              // Whether auction has been closed
    uint8 tokenADecimals;        // Decimals of token A (used by stable invariant)
    uint8 tokenBDecimals;        // Decimals of token B (used by stable invariant)
}

enum FeeAsset {
    TokenIn,   // Fee deducted from input amount
    TokenOut   // Fee deducted from output amount
}

enum InvariantMode {
    Volatile,  // x*y = k
    Stable     // x³y + xy³ = k (Solidly-style)
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
    InvariantMode invariantMode; // Volatile or Stable
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
- If `invariantMode == Stable`, `stableModeEnabled` must be true in derivative governance config
- If `invariantMode == Stable`, both token decimals must be in range [1, 18] (validated via `LibAuctionSwap.validateStableDecimals`)

**Function:**
```solidity
function createAuction(CreateAuctionParams calldata params)
    external
    returns (uint256 auctionId);
```

**What Happens:**
1. Validates position ownership and pool membership
2. If stable mode: reads and validates token decimals (must be 1–18); stores `tokenADecimals` and `tokenBDecimals` on the auction
3. Settles pending fee/credit indexes for both pools
4. Locks `reserveA` from pool A and `reserveB` from pool B
5. Creates auction record with unique `auctionId`
6. Adds auction to all discovery indexes
7. Emits `AuctionCreated` event

### 2. Active Period

During the active window (`startTime ≤ now < endTime`):
- Takers can swap tokens in either direction
- Each swap updates reserves according to constant product formula
- Fees are split between maker share and protocol-routed share
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
1. Validates caller has borrower authority over the maker position (owner, approved, or operator)
2. Unlocks current reserves (may differ from initial)
3. Applies principal delta
4. Removes from indexes
5. Emits `AuctionCancelled` event

### 5. Add Liquidity

Maker can add liquidity while active:

```solidity
function addLiquidity(uint256 auctionId, uint256 amountA, uint256 amountB) external;
```

**Requirements:**
- Auction active and within `[startTime, endTime)`
- Caller has borrower authority over maker position
- Amounts match current reserve ratio within tolerance

---

## Swap Mechanics

### Swap Function

```solidity
function swapExactIn(
    uint256 auctionId,
    address tokenIn,
    uint256 amountIn,
    uint256 maxIn,
    uint256 minOut,
    address recipient
) external payable returns (uint256 amountOut);
```

### Swap Calculation

Swap math is dispatched by `LibAuctionSwap.computeSwapByInvariant`, which routes to the correct formula based on the auction's `invariantMode`.

#### Volatile Mode

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

#### Stable Mode

Stable swaps follow the same fee-placement logic (TokenIn or TokenOut), but the raw output is computed via the `x³y + xy³ = k` invariant instead of constant-product.

**Steps:**
1. Normalize reserves and input to 18-decimal WAD: `x = toWad(reserveIn)`, `y = toWad(reserveOut)`, `dx = toWad(amountIn)`
2. Compute current invariant: `k = xy(x² + y²)`
3. Set `x' = x + dx`
4. Solve for `y'` such that `x'·y'(x'² + y'²) = k` using Newton-Raphson (up to 255 iterations)
5. Raw output in WAD: `outWad = y - y'`
6. Convert back to native decimals: `rawOut = fromWad(outWad)`
7. Apply fee (same TokenIn/TokenOut logic as volatile)

**Fee on TokenOut:**
```
rawOut = stableOutAmount(reserveIn, reserveOut, amountIn)
feeAmount = rawOut × feeBps / 10000
amountOut = rawOut - feeAmount
```

**Fee on TokenIn:**
```
amountInWithFee = amountIn × (10000 - feeBps) / 10000
feeAmount = amountIn - amountInWithFee
rawOut = stableOutAmount(reserveIn, reserveOut, amountInWithFee)
amountOut = rawOut
```

If `amountOut == 0` after fee deduction, the swap reverts (`AmmAuction_ZeroOutput`).

### Reserve Updates

After each swap:
```
newReserveIn = reserveIn + actualAmountIn
newReserveOut = reserveOut - amountOut - treasuryShareAdjustment
```

**Volatile invariant preservation:**
```
newReserveIn × newReserveOut ≥ initialReserveA × initialReserveB
```

**Stable invariant preservation:**
```
xy(x² + y²) after swap ≥ xy(x² + y²) before swap
```
(where x, y are WAD-normalized reserves)

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
    uint256 maxIn,
    uint256 minOut,
    address recipient
) external payable returns (uint256 amountOut, bool finalized);
```

---

## Fee Structure

### Fee Split

Every swap fee is split in two stages:

1. Maker share: `makerFee = feeAmount × ammMakerShareBps / 10_000`
2. Protocol share: `protocolFee = feeAmount - makerFee`, routed through `LibFeeRouter`

`LibFeeRouter` then splits `protocolFee` into Treasury / Active Credit / Fee Index using global app config.

### Fee Accrual

**Maker Fees:**
- Tracked per-auction in `makerFeeAAccrued` and `makerFeeBAccrued`
- Automatically credited to maker's position at finalization
- Denominated in the fee asset (TokenIn or TokenOut)

**Protocol-routed Fees (via LibFeeRouter):**
- Routed using `LibFeeRouter.routeSamePool(..., "AMM_AUCTION_FEE", ...)`
- Split dynamically into Treasury / ACI / FI via app-level split settings
- Auction tracks treasury accrual in `treasuryFeeAAccrued` / `treasuryFeeBAccrued`

```solidity
uint256 makerFee = feeAmount * ammMakerShareBps / 10_000;
uint256 protocolFee = feeAmount - makerFee;
LibFeeRouter.routeSamePool(poolId, protocolFee, AMM_FEE_SOURCE, false, extraBacking);
```

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
    feeAsset: DerivativeTypes.FeeAsset.TokenOut,
    invariantMode: DerivativeTypes.InvariantMode.Volatile
});

uint256 auctionId = ammAuctionFacet.createAuction(params);
```

#### Creating a Stable-Mode Auction

```solidity
// Stable mode for correlated pairs (e.g. USDC/USDT)
// Requires stableModeEnabled == true in governance config
// Both tokens must have decimals in [1, 18]

DerivativeTypes.CreateAuctionParams memory params = DerivativeTypes.CreateAuctionParams({
    positionId: myPositionId,
    poolIdA: usdcPoolId,
    poolIdB: usdtPoolId,
    reserveA: 500_000e6,          // 500k USDC (6 decimals)
    reserveB: 500_000e6,          // 500k USDT (6 decimals)
    startTime: uint64(block.timestamp),
    endTime: uint64(block.timestamp + 7 days),
    feeBps: 4,                    // 0.04% fee (tight for stables)
    feeAsset: DerivativeTypes.FeeAsset.TokenOut,
    invariantMode: DerivativeTypes.InvariantMode.Stable
});

uint256 auctionId = ammAuctionFacet.createAuction(params);
// Token decimals are read on-chain and stored as tokenADecimals / tokenBDecimals
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
    amountIn,      // maxIn
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
    ammAuctionFacet.swapExactIn(bestAuctionId, address(weth), 1e18, 1e18, bestOut * 99 / 100, msg.sender);
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
    1e18,           // maxIn
    1650e6,         // min 1650 USDC (slippage protection)
    bob
);
```

**After swap:**
- Bob receives: ~1,661.67 USDC
- New reserves: 6 WETH, 8,333.33 USDC
- New price: 8,333.33 / 6 = $1,388.89/ETH (price impact)
- Fee collected: 5 USDC
  - Maker share: `5 × ammMakerShareBps / 10_000`
  - Remainder routed by `LibFeeRouter` to Treasury/ACI/FI

**Step 3: After expiry, Alice finalizes**
```solidity
ammAuctionFacet.finalizeAuction(auctionId);
```

**Alice's final position:**
- Started with: 5 WETH + 10,000 USDC
- Ended with: 6 WETH + 8,333.33 USDC + maker-fee accrual
- Net: +1 WETH, -1,666.67 USDC + maker-fee accrual

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
ammAuctionFacet.swapExactIn(auction1, usdc, 1636e6, 1636e6, 0.99e18, arbitrageur);

// Step 2: Sell expensive ETH
ammAuctionFacet.swapExactIn(auction2, weth, 1e18, 1e18, 1800e6, arbitrageur);
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
ammAuctionFacet.swapExactIn(bestId, weth, 5e18, 5e18, minOut, msg.sender);
```

### Example 5: Stable-Mode Stablecoin Swap

**Scenario:** Carol creates a USDC/USDT stable auction. Dave swaps 10,000 USDC for USDT.

**Step 1: Carol creates the stable auction**
```solidity
CreateAuctionParams({
    positionId: 99,
    poolIdA: 3,                    // USDC pool
    poolIdB: 4,                    // USDT pool
    reserveA: 500_000e6,          // 500k USDC (6 decimals)
    reserveB: 500_000e6,          // 500k USDT (6 decimals)
    startTime: block.timestamp,
    endTime: block.timestamp + 7 days,
    feeBps: 4,                    // 0.04%
    feeAsset: FeeAsset.TokenOut,
    invariantMode: InvariantMode.Stable
});
// Decimals stored: tokenADecimals = 6, tokenBDecimals = 6
// Reserves normalized to WAD internally: 500_000e18 each
// Stable invariant k = xy(x² + y²) = 500k × 500k × (500k² + 500k²) = 1.25e23 (WAD)
```

**Step 2: Dave swaps 10,000 USDC → USDT**

With the stable invariant, the curve is very flat near 1:1. Compare outputs:

| Invariant | Raw Output | Fee (0.04%) | Net Output | Slippage |
|-----------|-----------|-------------|------------|----------|
| **Stable** (x³y+xy³) | ~9,999.96 USDT | ~4.00 USDT | ~9,995.96 USDT | ~0.0004% |
| Volatile (x·y) | ~9,803.92 USDT | ~3.92 USDT | ~9,800.00 USDT | ~1.96% |

The stable invariant delivers ~196 USDT more on the same trade because it concentrates liquidity around the 1:1 ratio.

**Step 3: Cross-decimal example (wstETH/WETH)**

Stable mode also handles pairs where both tokens are 18-decimal but correlated:
```solidity
CreateAuctionParams({
    positionId: 100,
    poolIdA: 5,                    // wstETH pool
    poolIdB: 6,                    // WETH pool
    reserveA: 100e18,             // 100 wstETH (18 decimals)
    reserveB: 115e18,             // 115 WETH (18 decimals, ~1.15 ratio)
    startTime: block.timestamp,
    endTime: block.timestamp + 7 days,
    feeBps: 10,                   // 0.10%
    feeAsset: FeeAsset.TokenOut,
    invariantMode: InvariantMode.Stable
});
// No decimal normalization needed (both 18), but the stable curve
// still provides lower slippage for swaps near the prevailing ratio.
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
| `AmmAuction_InvalidInvariantMode` | Invariant mode value out of enum range |
| `AmmAuction_NotActive` | Auction not active or before start |
| `AmmAuction_AlreadyFinalized` | Auction already closed |
| `AmmAuction_NotExpired` | Trying to finalize before end time |
| `AmmAuction_Expired` | Trying to swap after end time |
| `AmmAuction_Slippage` | Output less than minimum |
| `AmmAuction_ZeroOutput` | Stable-mode swap rounded to zero output |
| `AmmAuction_NotMaker` | Caller not the auction maker |
| `AmmAuction_StableModeDisabled` | Stable invariant selected but governance flag is off |
| `LibAuctionSwap_InvalidStableInput` | Stable math overflow or zero-reserve input |
| `LibAuctionSwap_StableNonConvergence` | Newton-Raphson solver did not converge in 255 iterations |
| `LibAuctionSwap_UnsupportedDecimals` | Token decimals outside supported range (1–18) |
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
    FeeAsset feeAsset,
    InvariantMode invariantMode
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

1. **Invariant Preservation**: The invariant (constant-product for volatile, Solidly-style for stable) is always preserved or increased, preventing value extraction.

2. **Stable Solver Bounds**: The Newton-Raphson solver is capped at 255 iterations. Non-convergence reverts the transaction rather than producing incorrect output.

3. **Decimal Normalization Safety**: Stable mode validates token decimals at creation (must be 1–18). All math is performed in WAD (1e18) space with overflow-checked scaling, preventing precision loss from mismatched decimals.

4. **Zero-Output Guard**: Stable-mode swaps revert if the output rounds to zero after fee deduction, preventing dust-extraction attacks on the flat region of the curve.

5. **Time Window Enforcement**: Swaps are only allowed within the active window, preventing manipulation before/after.

6. **Slippage Protection**: `minOut` parameter protects takers from front-running and price manipulation.

7. **Fee-on-Transfer Support**: The contract measures actual received amounts, handling fee-on-transfer tokens correctly.

8. **Reentrancy Protection**: All state-changing functions use `nonReentrant` modifier.

9. **Position Authority**: Create/cancel/add-liquidity require borrower authority (owner, approved, or operator) on the maker position.

10. **Reserve Isolation via LibEncumbrance**: Locked reserves are tracked centrally via `LibEncumbrance`, preventing withdrawal or use for other purposes during the auction.

```solidity
// Encumbrance check before withdrawal
uint256 totalEncumbered = LibEncumbrance.total(positionKey, poolId);
require(principal >= totalEncumbered + withdrawAmount, "Insufficient available principal");
```

11. **Flash Accounting Isolation**: Swaps don't affect maker's principal or fee index snapshots during the auction.

12. **Treasury Optionality**: If treasury is unset, the router treasury leg becomes zero and more flow remains in ACI/FI.

13. **Centralized Router + Indexes**: Fee distribution routes through `LibFeeRouter`, which coordinates Treasury/ACI/FI accounting consistently across features.

14. **Governance-Gated Stable Mode**: Stable mode requires explicit governance enablement (`stableModeEnabled`), allowing the protocol to disable it if issues are discovered.

---

## Comparison with Traditional AMMs

| Aspect | AMM Auction (Volatile) | AMM Auction (Stable) | Uniswap-style AMM |
|--------|------------------------|----------------------|-------------------|
| **Invariant** | x·y = k | x³y + xy³ = k | x·y = k |
| **Best For** | Uncorrelated pairs | Correlated/pegged pairs | General trading |
| **Duration** | Time-bounded | Time-bounded | Permanent |
| **Liquidity** | Single maker | Single maker | Multiple LPs |
| **LP Tokens** | None | None | ERC-20 LP tokens |
| **Fee Distribution** | Direct to maker | Direct to maker | Pro-rata to LPs |
| **Impermanent Loss** | Maker bears fully | Lower (flat curve) | Shared among LPs |
| **Capital Efficiency** | Full reserve usage | Concentrated near parity | Spread across price range |
| **Decimal Handling** | Native | WAD-normalized | Native |
| **Composability** | Position NFT based | Position NFT based | Standalone pools |
