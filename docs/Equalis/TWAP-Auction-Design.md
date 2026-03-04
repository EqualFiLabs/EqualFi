# TWAP Auction Mode Specification (Solo + Community)

## Status

Draft (March 2026)

## Purpose

Specify a TWAP execution mode for Equalis auction systems where large swaps are executed as deterministic slices over time against:

* Solo AMM auctions (`AmmAuctionFacet`)
* Community auctions (`CommunityAuctionFacet`)

This is an execution-layer extension, not a replacement for existing invariant math.

---

## 1. Scope

### 1.1 V1 In Scope

* Time-sliced TWAP orders routed to active solo/community auctions.
* Observation ring buffers for auction-level TWAP computation.
* Permissionless keeper execution of due slices.
* User-configurable schedule and slippage controls.
* Deterministic partial-fill + refund behavior at expiry/cancel.

### 1.2 V1 Out of Scope

* Replacing auction spot pricing with TWAP-only settlement.
* Cross-auction smart routing or aggregator logic.
* Using auction TWAP as canonical protocol oracle for liquidations.
* Offchain solver auctions or sealed-bid matching.

---

## 2. Design Goals

* Add TWAP without breaking current `swapExactIn` semantics.
* Keep reserve/fee accounting on existing rails.
* Make large execution less sensitive to single-block price impact.
* Preserve permissionless execution via keepers.
* Keep behavior deterministic and easy to simulate offchain.

---

## 3. TWAP Clarification

TWAP is a price measurement and execution policy:

* **Measurement:** average price over a time window.
* **Execution policy:** split one order into many smaller trades over time.

TWAP is not a new invariant. Existing auction invariants remain:

* `Volatile`: constant product.
* `Stable`: stable-swap solver.

---

## 4. Product Model

Each TWAP order defines:

* target auction (`auctionType`, `auctionId`)
* direction (`tokenIn` -> `tokenOut`)
* total notional in (`totalIn`)
* schedule (`startTime`, `endTime`, `sliceInterval`)
* price guard (`maxSlippageBps` against reference TWAP)
* recipient and refund address

Definitions:

* `numSlices = ceil((endTime - startTime) / sliceInterval)`
* target cumulative by slice `i`: `targetCumIn(i) = floor(totalIn * i / numSlices)`
* current slice amount: `sliceIn = targetCumIn(i) - executedIn`

Last slice consumes residual rounding dust.

---

## 5. Architecture

### 5.1 New Facets

* `TwapAuctionFacet` (new)
  * Create/cancel/execute/finalize TWAP orders.
  * Escrow input assets and distribute outputs/refunds.

* `TwapAuctionViewFacet` (new)
  * Order state, due-slice preview, observation and TWAP diagnostics.

### 5.2 New Libraries

* `LibTwapAuctionStorage` (new)
* `LibTwapObservation` (new)
* `LibTwapExecution` (new)

### 5.3 Existing Facets Touched

* `AmmAuctionFacet` and `CommunityAuctionFacet` record observation updates on:
  * create
  * add/remove liquidity (where applicable)
  * swap
  * finalize/cancel

No invariant math changes required.

---

## 6. Storage Model

Use isolated storage root:

```solidity
bytes32 internal constant TWAP_AUCTION_STORAGE_POSITION =
    keccak256("equalis.derivatives.twap.auction.storage.v1");
```

Key state:

* `nextTwapOrderId`
* `twapPaused`
* global and per-type TWAP config
* `mapping(uint256 => TwapOrder) orders`
* `mapping(bytes32 => TwapObsRing) observations` where key is `(auctionType, auctionId)`

---

## 7. Data Structures

```solidity
enum AuctionType {
    SoloAmm,
    Community
}

enum TwapOrderStatus {
    Pending,
    Active,
    Completed,
    Cancelled,
    Expired
}

struct TwapOrder {
    AuctionType auctionType;
    uint256 auctionId;
    address owner;
    address recipient;
    address refundRecipient;
    address tokenIn;
    address tokenOut;
    uint64 startTime;
    uint64 endTime;
    uint32 sliceIntervalSec;
    uint16 maxSlippageBps;
    uint256 totalIn;
    uint256 executedIn;
    uint256 receivedOut;
    uint32 nextSliceIndex;
    uint32 numSlices;
    TwapOrderStatus status;
}

struct TwapObs {
    uint64 ts;
    uint256 cumulativePriceX18; // Σ(priceX18 * dt)
    uint256 priceX18;           // spot snapshot (tokenOut per tokenIn)
    uint256 reserveIn;          // optional diagnostics
    uint256 reserveOut;         // optional diagnostics
}

struct TwapObsRing {
    uint32 head;
    uint32 count;
    uint32 capacity;
    mapping(uint32 => TwapObs) items;
}

struct TwapConfig {
    uint32 minWindowSec;           // smallest TWAP lookback
    uint32 maxWindowSec;           // largest TWAP lookback
    uint16 maxSlippageBpsCap;      // governance hard cap
    uint16 minObservationCount;    // minimum samples to trust TWAP
    uint32 maxObservationStaleness;
    bool closeOnlyOnDegradedTwap;
}
```

---

## 8. Interfaces

```solidity
function setTwapAuctionPaused(bool paused) external;
function setTwapAuctionConfig(TwapConfig calldata cfg) external;

function createTwapOrder(
    AuctionType auctionType,
    uint256 auctionId,
    address tokenIn,
    uint256 totalIn,
    uint64 startTime,
    uint64 endTime,
    uint32 sliceIntervalSec,
    uint16 maxSlippageBps,
    address recipient,
    address refundRecipient
) external payable returns (uint256 orderId);

function executeNextTwapSlice(
    uint256 orderId,
    uint256 minOutOverride
) external returns (uint256 sliceIn, uint256 sliceOut);

function executeTwapSlices(
    uint256 orderId,
    uint256 maxSlices,
    uint256 minOutOverride
) external returns (uint256 executedSlices, uint256 totalInExecuted, uint256 totalOutReceived);

function cancelTwapOrder(uint256 orderId) external;
function finalizeTwapOrder(uint256 orderId) external;

function previewDueSlice(uint256 orderId)
    external
    view
    returns (bool due, uint256 sliceIn, uint256 twapPriceX18, uint256 minOutFromTwap);

function getTwapOrder(uint256 orderId) external view returns (TwapOrder memory);
function getAuctionTwap(AuctionType auctionType, uint256 auctionId, uint32 lookbackSec)
    external
    view
    returns (uint256 twapPriceX18, bool valid);
```

---

## 9. Lifecycle

### 9.1 Create

At `createTwapOrder`:

1. Validate auction exists and is active for requested window.
2. Validate pair direction against auction token pair.
3. Validate schedule:
   * `startTime < endTime`
   * `sliceIntervalSec > 0`
   * `numSlices >= 1`
4. Validate slippage cap against governance max.
5. Pull and escrow `totalIn` from caller.
6. Persist order and emit event.

### 9.2 Execute Slice

At `executeNextTwapSlice`:

1. Require order `Active` and current time >= due slice time.
2. Compute deterministic `sliceIn`.
3. Compute reference TWAP from observation ring.
4. Derive `minOutFromTwap = quote(sliceIn, twapPrice) * (1 - maxSlippageBps)`.
5. Execute one underlying auction swap on behalf of order escrow.
6. Update `executedIn`, `receivedOut`, `nextSliceIndex`.
7. Emit per-slice execution event.

Execution is permissionless, enabling keeper networks.

### 9.3 Finalize

At `finalizeTwapOrder`:

1. Allowed when fully executed, cancelled, or expired.
2. Transfer accumulated `tokenOut` to `recipient`.
3. Refund unexecuted `tokenIn` to `refundRecipient`.
4. Mark terminal status and emit final event.

### 9.4 Cancel

At `cancelTwapOrder`:

1. Only owner.
2. Move status to `Cancelled`.
3. Slices stop executing.
4. Finalization can distribute output/refund immediately.

---

## 10. TWAP Computation

Observation accumulator:

* `cumulativePriceX18(t_i) = cumulativePriceX18(t_{i-1}) + spotPriceX18 * (t_i - t_{i-1})`

Window TWAP:

* `twapPriceX18 = (cumNow - cumPast) / (tNow - tPast)`

Validity checks:

* enough lookback duration
* at least `minObservationCount` points
* newest observation freshness <= `maxObservationStaleness`

If invalid:

* execution reverts, or
* optional degraded mode gates to cancel/finalize only (configurable).

---

## 11. Solo vs Community Behavior

### 11.1 Common

* Same order state machine and schedule logic.
* Same observation framework and TWAP validation.
* Same slippage guard semantics.

### 11.2 Solo AMM Specific

* Reserve source is one maker position.
* No maker-share accounting side effects from TWAP orders beyond normal swap effects.

### 11.3 Community Specific

* Reserve source is pooled liquidity.
* TWAP slices flow through existing fee-index distribution.
* Join/leave remains permissionless and must not break TWAP execution determinism.

---

## 12. Risk Controls

* Global pause for TWAP order creation/execution.
* Per-order max lifetime cap.
* Per-order max notional cap.
* Min-liquidity check per slice (revert on thin books).
* Max single-slice ratio to reserves to avoid severe price jumps.
* Optional close-only degraded mode when TWAP signal quality drops.

---

## 13. Events

```solidity
event TwapAuctionPausedUpdated(bool paused);
event TwapAuctionConfigUpdated(
    uint32 minWindowSec,
    uint32 maxWindowSec,
    uint16 maxSlippageBpsCap,
    uint16 minObservationCount,
    uint32 maxObservationStaleness,
    bool closeOnlyOnDegradedTwap
);

event TwapOrderCreated(
    uint256 indexed orderId,
    uint8 indexed auctionType,
    uint256 indexed auctionId,
    address owner,
    address tokenIn,
    address tokenOut,
    uint256 totalIn,
    uint64 startTime,
    uint64 endTime,
    uint32 sliceIntervalSec
);

event TwapSliceExecuted(
    uint256 indexed orderId,
    uint32 indexed sliceIndex,
    uint256 sliceIn,
    uint256 sliceOut,
    uint256 twapPriceX18
);

event TwapOrderCancelled(uint256 indexed orderId);
event TwapOrderFinalized(
    uint256 indexed orderId,
    uint256 executedIn,
    uint256 receivedOut,
    uint256 refundedIn
);

event TwapObservationPoked(uint8 indexed auctionType, uint256 indexed auctionId, uint64 ts, uint256 priceX18);
```

---

## 14. Invariants

Must always hold:

* `executedIn <= totalIn`.
* `nextSliceIndex <= numSlices`.
* Terminal orders cannot execute further slices.
* Escrow conservation:
  * `totalIn = executedIn + refundedIn`.
* TWAP execution cannot bypass auction-level slippage and time-window checks.
* Community fee-index and solo maker-fee accounting remain balanced with executed swap flow.

---

## 15. Security and Failure Modes

* Reentrancy guard on create/execute/cancel/finalize paths.
* Strict pair validation (`tokenIn/tokenOut` must match auction pair).
* No same-block single-point TWAP trust; minimum window enforced.
* Observation griefing protection via bounded ring size and permissionless poke rules.
* Graceful expiry path: unexecuted notional is refundable.

---

## 16. Test Acceptance Criteria

Minimum required tests:

1. Creation:
* rejects invalid schedules, pairs, and slippage caps.
* escrows exact input amount.

2. Slice execution:
* computes deterministic due slice amount.
* executes one and multiple slices correctly.
* respects TWAP-derived `minOut`.

3. TWAP math:
* accumulator and window TWAP correctness.
* stale/sparse observations invalidate execution.

4. Finalization:
* distributes output and refunds residual input exactly once.
* terminal state blocks re-execution.

5. Cancel/expire:
* owner-only cancel.
* expiry path refunds unfilled notional.

6. Solo/community parity:
* same order behavior over both auction types.
* community fee-index and share accounting remain correct.

7. Edge assets:
* fee-on-transfer behavior.
* native-asset behavior.

Recommended test files:

* `test/derivatives/TwapAuctionSolo.t.sol`
* `test/derivatives/TwapAuctionCommunity.t.sol`
* `test/derivatives/TwapAuctionObservation.t.sol`
* `test/derivatives/TwapAuctionSettlement.t.sol`
* `test/derivatives/TwapAuctionEdgeAssets.t.sol`

---

## 17. Rollout Plan

Phase 1:

* TWAP orders on solo auctions only.
* Conservative caps and keeper-operated execution.

Phase 2:

* Enable community auction routing.
* Add batched keeper endpoints and monitoring views.

Phase 3:

* Optional advanced schedules (front-loaded/back-loaded/randomized).
* Optional oracle-bounded TWAP guard mode.

---

## 18. Open Questions

* Should `executeTwapSlices` permit third-party fee rewards to incentivize keepers?
* Should TWAP orders allow dynamic repricing (editable slippage) or immutable terms only?
* Should finalization auto-trigger after terminal condition, or remain explicit?
* Should we support `exactOut` TWAP orders in V1, or keep `exactIn` only?
* Should TWAP observations be reused for broader analytics or isolated to order execution?
