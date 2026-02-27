# Concentrated Liquidity Community Auction Design

**Version:** 1.0  
**Status:** Draft (new system; no backward compatibility required)

## 1. Overview

This document specifies a **new auction type**: a **protocol-native, Uniswap v3-style concentrated liquidity community auction**.

Key constraints and intent:

- Fully protocol-native accounting and settlement.
- No dependency on external Uniswap/Aerodrome pool contracts for core state.
- Concentrated liquidity behavior (ticks, range positions, fee growth) modeled in-protocol.
- CL position NFTs are minted to and managed by **ERC-6551 TBAs** bound to PositionNFTs.
- Existing `AmmAuction` and `CommunityAuction` contracts/docs are unchanged.
- ABI/API compatibility with old auction types is not required.

## 2. Goals and Non-Goals

### 2.1 Goals

- Implement v3-style CL pool mechanics for auction-local markets.
- Keep liquidity and fees on the same Equalis fee/index rails.
- Support multi-maker community liquidity with per-user range positions.
- Preserve PositionNFT custody model via per-position ERC-6551 TBAs.
- Keep encumbrance/risk checks first-class and synchronous with CL operations.

### 2.2 Non-Goals

- Reusing external periphery contracts (`NonfungiblePositionManager`) as the system of record.
- Backporting behavior to legacy community auction contracts.
- Slipstream-specific behavior in this design.

## 3. High-Level Architecture

### 3.1 Contracts

- `ClCommunityAuctionFacet`
  - Lifecycle, swap, liquidity, settlement entry points.
- `ClCommunityAuctionViewFacet`
  - Read-only views (auction, pool state, ticks, positions, fees, phase).
- `ClCommunityAuctionAdminFacet`
  - Risk params, fee caps, pause controls, governance controls.
- `ClPositionManager` (new ERC-721)
  - Mints CL position NFTs that represent per-range LP claims.
  - Recipient is a PositionNFT TBA (not EOA).
- `ClPositionDescriptor` (optional metadata renderer)
  - Token URI generation for CL position NFTs.

### 3.2 Libraries

- `LibClAuctionStorage`
  - Diamond storage for all CL auction state.
- `LibClMath`
  - Sqrt price, tick math, liquidity/amount conversion, fee growth arithmetic.
- `LibClTickBitmap`
  - Tick initialization and next-tick traversal.
- `LibClSwap`
  - Stepwise swap execution across ticks.
- `LibClPosition`
  - Position accounting (liquidity, fee growth checkpoints, tokens owed).
- `LibClEncumbranceBridge`
  - Lock/unlock and principal delta application against existing encumbrance rails.

## 4. Auction Model

Each CL community auction hosts one CL pool for a token pair over a bounded time window:

- `startTime <= now < endTime`: active trading and liquidity updates.
- `now >= endTime`: no new swaps; positions can be settled/withdrawn.

Unlike legacy shared-reserve auction logic, this model uses:

- Tick-indexed virtual liquidity.
- Position ranges `[tickLower, tickUpper)`.
- Fee growth accumulators per token.

## 5. TBA and Custody Model

### 5.1 Position Identity

- User identity anchor remains the protocol `PositionNFT` token ID (`positionId`).
- `positionKey = keccak256(abi.encodePacked(positionNFT, positionId))` remains canonical for pool accounting.

### 5.2 CL NFT Custody

- For every `positionId`, TBA address is derived from configured ERC-6551 registry + implementation + salt.
- CL position NFTs are minted to that derived TBA.
- If TBA is undeployed at first CL mint/increase, protocol performs **lazy deployment**:
  - detect `tba.code.length == 0`,
  - call canonical registry `createAccount(...)`,
  - verify derived address match and non-empty code,
  - continue CL position mint/update in the same transaction.

### 5.3 Lazy Deployment Semantics

Lazy deployment means the protocol deploys the deterministic ERC-6551 account only when first needed
for CL custody, instead of requiring users to pre-call `deployTBA`.

Tradeoffs:

- Pros:
  - One less user transaction and less integration friction.
  - Eliminates "TBA not deployed" dead-end UX at CL mint time.
  - Keeps custody deterministic (same derived address either way).
- Cons:
  - Adds gas to first CL mint for that `positionId`.
  - Adds an external call failure surface on first mint only.

Policy for this auction type:

- **Mandatory lazy deployment** on first CL mint/increase.
- Revert only if registry deployment fails or address verification fails.

### 5.4 Authority

A caller may mutate CL state for `positionId` only if one of:

- Caller is PositionNFT owner.
- Caller is approved operator for that PositionNFT.
- Caller is the position’s TBA (direct account execution).

This keeps existing borrower-authority semantics while enabling agent automation.

## 6. Core Data Structures

### 6.1 Storage Root

`bytes32 STORAGE_POSITION = keccak256("equalis.cl.community.auction.storage.v1");`

### 6.2 Auction

```solidity
struct ClCommunityAuction {
    uint256 auctionId;
    uint256 poolIdA;
    uint256 poolIdB;
    address tokenA;
    address tokenB;
    uint24 tickSpacing;
    uint24 swapFee; // in hundredths of a bip style (e.g. 3000 = 0.3%)
    uint160 sqrtPriceX96;
    int24 tick;
    uint128 liquidity; // active in-range liquidity
    uint256 feeGrowthGlobal0X128;
    uint256 feeGrowthGlobal1X128;
    uint128 protocolFees0;
    uint128 protocolFees1;
    uint64 startTime;
    uint64 endTime;
    bool initialized;
    bool finalized;
    bool cancelled;
}
```

### 6.3 Tick

```solidity
struct TickInfo {
    uint128 liquidityGross;
    int128 liquidityNet;
    uint256 feeGrowthOutside0X128;
    uint256 feeGrowthOutside1X128;
    bool initialized;
}
```

### 6.4 Position (CL LP)

```solidity
struct ClPosition {
    uint96 nonce;
    address operator;
    uint256 auctionId;
    uint256 sourcePositionId; // Equalis PositionNFT id
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
    uint256 feeGrowthInside0LastX128;
    uint256 feeGrowthInside1LastX128;
    uint128 tokensOwed0;
    uint128 tokensOwed1;
}
```

### 6.5 Encumbrance Lock State

```solidity
struct EncumbranceLock {
    uint256 lockedA;
    uint256 lockedB;
}
```

Tracked per CL position token to guarantee exact unlock semantics.

## 7. External Interface (New ABI)

```solidity
interface IClCommunityAuction {
    function createClCommunityAuction(CreateClAuctionParams calldata p) external returns (uint256 auctionId);
    function cancelClCommunityAuction(uint256 auctionId) external;
    function finalizeClCommunityAuction(uint256 auctionId) external;

    function mintClPosition(MintClPositionParams calldata p)
        external
        returns (uint256 clPositionId, uint128 liquidity, uint256 amountA, uint256 amountB);

    function increaseClLiquidity(IncreaseClLiquidityParams calldata p)
        external
        returns (uint128 liquidity, uint256 amountA, uint256 amountB);

    function decreaseClLiquidity(DecreaseClLiquidityParams calldata p)
        external
        returns (uint256 amountA, uint256 amountB);

    function collectClFees(CollectClFeesParams calldata p)
        external
        returns (uint256 amountA, uint256 amountB);

    function burnClPosition(uint256 clPositionId) external;

    function swapExactIn(
        uint256 auctionId,
        address tokenIn,
        uint256 amountIn,
        uint256 amountOutMin,
        address recipient
    ) external returns (uint256 amountOut);
}
```

## 8. Lifecycle

### 8.1 Create

- Validate pair pools, fee tier, tick spacing, and time window.
- Validate creator borrower authority for `positionId`.
- Set initial `sqrtPriceX96` and `tick`.
- Mark auction initialized and index it for discovery.

### 8.1.1 Cancel

- `cancelClCommunityAuction` is permitted **only before `startTime`**.
- After `startTime`, cancellation is not allowed; the auction must progress to end-time finalization.
- Cancel marks auction as cancelled/inactive.

### 8.2 Add Liquidity (Mint/Increase)

- Validate authority against source `positionId`.
- Validate `tickLower/tickUpper` and spacing alignment.
- Compute mintable liquidity and consumed `amountA/amountB` from desired token amounts and current price.
- Lock required principal through encumbrance bridge.
- Update ticks, position liquidity, and pool active liquidity.
- Mint/update CL NFT to source position’s TBA.

### 8.3 Swap

- Enforce active phase.
- Execute v3-style step loop:
  - Determine next initialized tick.
  - Compute step amounts and fee.
  - Update `sqrtPriceX96`, in-range liquidity, and fee growth globals.
- Route protocol/index/active-credit fee shares through `LibFeeRouter` on the input-token pool domain:
  - `poolIdA` when `tokenIn == tokenA`
  - `poolIdB` when `tokenIn == tokenB`
- Update auction reserve accounting (derived from virtual pool state and tracked deltas).

### 8.4 Decrease/Collect/Burn

- Recompute fee growth inside position.
- Accrue `tokensOwed`.
- On decrease:
  - reduce position liquidity,
  - realize output amounts,
  - unlock corresponding encumbered principal.
- `burnClPosition` allowed only when liquidity and owed tokens are zero.

### 8.5 Finalize

- Enforce `now >= endTime`.
- Disable swaps permanently for the auction.
- Keep user withdrawals permissionless post-finalization.
- Finalizer reward (if configured) is paid on protocol fee domain.

## 9. Math and Pricing Rules

- Tick and sqrt price arithmetic mirrors v3 formula domain.
- All swap fee accrual is in input token for each swap step.
- Fee growth uses Q128 fixed-point accumulators.
- Liquidity math:
  - `getLiquidityForAmounts`
  - `getAmount0ForLiquidity`
  - `getAmount1ForLiquidity`
  - exact rounding rules must be fixed and documented in tests.

## 10. Encumbrance and Principal Accounting

For each liquidity action:

- Mint/increase:
  - lock principal from source `positionKey` in `poolIdA/poolIdB`.
- Decrease/burn:
  - unlock principal proportionally to withdrawn liquidity.
- Collected trading fees:
  - settle into source position’s internal accrued yield/principal channels per existing fee/index rails.
  - no direct external payout transfer from `collectClFees`.

Namespace rule:

- CL encumbrance must use a dedicated module namespace (module encumbrance), not EqualIndex `indexId` namespace.

Hard requirement:

- No orphan locks at auction finalization or full position burn.

## 11. Fee Policy

This auction type adopts the same fee-routing behavior class as existing solo/community auctions.

Per-swap fee handling:

- LP share (remains in fee growth for CL positions).
- Protocol share routed by `LibFeeRouter`.
  - Treasury
  - Fee Index
  - Active Credit Index

Configuration constraints:

- No per-auction custom router split weights.
- Governance caps and router split policy follow the existing auction configuration model.
- Swap fee tiers are constrained by governance allowlists/caps and validated at creation.

The split is computed at swap execution time and must be deterministic.

## 12. Access Control and Safety

- Governance:
  - enable/disable creation,
  - set fee caps,
  - set tick spacing allowlist,
  - pause swaps per auction type.
- Reentrancy guard on all mutating entry points.
- Strict callback-free internal accounting (no external pool callback surface).
- TBA registry/implementation immutability policy remains enforced by existing agent config lock rules.

## 13. Invariants

1. Tick spacing: every initialized tick is aligned to auction tick spacing.
2. Liquidity conservation: pool `liquidity` reflects active net across current tick.
3. Fee conservation: total distributed fee equals swap fee charged.
4. Position safety: no negative owed tokens or liquidity underflow.
5. Encumbrance safety: `lockedA/lockedB` never exceed available principal at lock time.
6. Finalization safety: swaps cannot execute after finalize.
7. Burn safety: CL NFT burn only when cleared (`liquidity == 0 && owed == 0`).

## 14. Events

Required events:

- `ClCommunityAuctionCreated`
- `ClCommunityAuctionCancelled`
- `ClCommunityAuctionFinalized`
- `ClPositionMinted`
- `ClLiquidityIncreased`
- `ClLiquidityDecreased`
- `ClFeesCollected`
- `ClPositionBurned`
- `ClSwap`
- `ClTickCrossed`

## 15. Errors

Required explicit errors:

- `ClAuction_NotActive`
- `ClAuction_Expired`
- `ClAuction_InvalidTickRange`
- `ClAuction_InvalidTickSpacing`
- `ClAuction_InvalidSqrtPrice`
- `ClAuction_Slippage`
- `ClAuction_Unauthorized`
- `ClAuction_InsufficientPrincipal`
- `ClAuction_PositionNotClear`
- `ClAuction_Paused`

## 16. Testing Requirements

Minimum test scope for implementation:

- Unit tests:
  - tick math and liquidity amount conversions,
  - fee growth updates and collection.
- Integration tests:
  - create -> mint -> swap -> collect -> decrease -> burn -> finalize flow.
- Authorization tests:
  - owner, approved operator, and TBA execution paths.
- Encumbrance tests:
  - lock/unlock correctness and no orphan state.
- Invariant/property tests:
  - conservation and non-negative accounting across random swap/mint/decrease sequences.
- Fork tests (optional for implementation confidence, not as core correctness source):
  - compare quoted outputs against v3 reference math vectors.

## 17. Rollout Plan

1. Implement new storage + math libraries.
2. Implement CL auction facet + view facet.
3. Implement CL position manager NFT and TBA recipient enforcement.
4. Integrate encumbrance bridge + fee router wiring.
5. Add full unit/integration/invariant suite.
6. Gate behind feature flag until audit completion.

## 18. Design Decisions

Resolved:

1. `cancelClCommunityAuction` is allowed only before `startTime`.
2. Lazy TBA deployment is mandatory on first CL mint/increase.
3. Fee routing behavior follows existing solo/community auction policy (no per-auction router split override).

Open:

1. Whether finalization auto-settles dust fees or leaves all settlement strictly user-initiated.
