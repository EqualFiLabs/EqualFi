# EqualX Gas Efficiency Report

_Generated via Foundry gas reports on 2025‑12‑29 (UTC)_
_Status: early-stage research; numbers reflect prototype harnesses_

## Methodology
- Commands:
- `forge test --gas-report --match-test testGas_Erc20ToErc20Swap -vv`
- `forge test --gas-report --match-path test/RouterGas.t.sol`
- `forge test --gas-report --match-path test/RouterEth.t.sol`
- `forge test --gas-report --match-path test/AmmAuctionGas.t.sol`
- `forge test --gas-report --match-contract AuctionHouseTest`
- `forge test --gas-report --match-contract AtomicDeskEntryTest`
- `forge test --gas-report --match-contract AtomicDeskE2ETest`
- Foundry gas tables reflect warm-cache, single-call scenarios inside the harnesses. Router now has only two entrypoints (`executeDirect`, `executeDirectEth`); delegated/trusted paths and tips are removed.

## Router Swaps (Direct Only)

| Scenario (Foundry test) | Entry point(s) | Gas |
| --- | --- | --- |
| ERC20 → ERC20, 0% fee, 1:1 price (`testGas_Erc20ToErc20Swap` log) | `Router.executeDirect` | **148,619** (gasleft diff) |
| ERC20 → ERC20 (gas table) | `Router.executeDirect` | 201,750 (min=avg=max in report) |
| ETH quote → ERC20 out, 1% fee | `Router.executeDirectEth` | 132,687 median (min 101,464, max 166,288 across calls) |
| ERC20 quote → ETH out, 0.5% fee | `Router.executeDirectEth` | ~132–166k (same run) |

_Notes_:
- Router deployment cost: 904,587 gas; size 4,181 bytes (from gas report).
- `executeDirect` rejects any `msg.value`; `executeDirectEth` enforces exact `msg.value` when ETH is quote and rejects value when ETH is base.
- Only token-in maker fees remain; the fee is added to `amountIn` inside the router and credited in DeskVault. No support/tip/slippage/deskScope paths remain.

### Router Function Summary (from gas tables)
| Function | Min | Avg | Max | # Calls | Notes |
| --- | --- | --- | --- | --- | --- |
| `executeDirect` | 201,750 | 201,750 | 201,750 | 1 | ERC20-only entry |
| `executeDirectEth` | 101,464 | 133,281 | 166,288 | 4 | Covers ETH-as-quote/base and revert case |

## AMM Auction Swaps

| Scenario (Foundry test) | Entry point(s) | Gas |
| --- | --- | --- |
| AMM swap tokenA → tokenB (`testGas_SwapTokenAIn` log) | `AmmAuctionManager.swapExactIn` | **135,858** (gasleft diff) |
| AMM swap tokenB → tokenA (`testGas_SwapTokenBIn` log) | `swapExactIn` | **136,368** (gasleft diff) |

_Notes_:
- Gas report table for the same tests shows ~447k per call (includes harness overhead); use the logged `gasleft` diffs above for the swap path itself.
- AMM auctions stay isolated from Router; DeskVault is accessed via `reserveAmmInventory`/`settleAmmInventory`.

## Auction House & Maker Operations

| Scenario (Foundry test) | Entry point(s) | Gas |
| --- | --- | --- |
| Create curve (baseline) (`testCreateCurveStoresDescriptor`) | `AuctionHouse.createCurve` | **654,961** |
| Create for trusted agent (`testCreateCurveForTrustedAgent`) | `createCurveFor` | 663,241 |
| Cancel single curve (`testCancelCurveClearsState`) | `cancelCurve` | 643,846 |
| Cancel mixed batch (`testCancelCurvesBatchClearsAll`) | `cancelCurvesBatch` | 1,199,939 |
| Consume bookkeeping (`testConsumeCurveReducesRemaining`) | `consumeCurve` | 640,581 |
| Batch creation (Sell-A + Sell-B) (`testCreateCurvesBatchAssignsSequentialIds`) | `createCurvesBatch` | **1,197,779** |

### Adaptive Curve Update Costs

| Scenario (Foundry test) | Entry point(s) | Total Gas | Approx. Per Curve |
| --- | --- | --- | --- |
| Single update (`testGasUpdateCurveSingle`) | `updateCurve` | **119,084** | 119,084 |
| Sequential updates ×2 (`testGasUpdateCurveSequentialN2`) | `updateCurve` (2 calls) | 229,152 | 114,576 |
| Sequential updates ×5 (`testGasUpdateCurveSequentialN5`) | `updateCurve` (5 calls) | 559,477 | 111,895 |
| Sequential updates ×10 (`testGasUpdateCurveSequentialN10`) | `updateCurve` (10 calls) | 1,111,025 | 111,102 |
| Batch updates ×2 (`testGasUpdateCurvesBatchN2`) | `updateCurvesBatch` | **153,615** | 76,808 |
| Batch updates ×5 (`testGasUpdateCurvesBatchN5`) | `updateCurvesBatch` | 292,539 | 58,508 |
| Batch updates ×10 (`testGasUpdateCurvesBatchN10`) | `updateCurvesBatch` | 525,848 | 52,585 |

_Notes_:
- Support metadata and token-out fee asset handling were removed; descriptors are now minimal (quote-per-base pricing, token-in fees only).
- Batch updates still amortize maker auth and commitment hashing, saving ~30–55% per curve.

## AtomicDesk Reservations & Escrow

| Scenario (Foundry test) | Entry point(s) | Gas |
| --- | --- | --- |
| Reserve ERC20 collateral (`testReserveAtomicSwapWithErc20AssetLocksCollateral`) | `AtomicDesk.reserveAtomicSwap` | **808,273** |
| Reserve native ETH (`testReserveAtomicSwapRequiresExactEthValue`) | `reserveAtomicSwap` | 1,156,324 |
| Reject maker-as-taker (`testReserveAtomicSwapRejectsMakerAsTaker`) | `reserveAtomicSwap` | 317,385 |
| Hashlock set after refund (`testSetHashlockRevertsWhenReservationInactive`) | `AtomicDesk.setHashlock` | 789,607 |
| Happy-path lifecycle (reserve → mailbox → settle) (`testAtomicDeskHappyPathLifecycle`) | AtomicDesk + `SettlementEscrow.settle` | 880,225 |
| Committee refund path (no presig) (`testCommitteeRefundWhenMakerNeverPublishesPresig`) | AtomicDesk + `SettlementEscrow.refund` | 658,427 |

_Notes_:
- ETH <> XMR Atomic flows remain isolated from the router; costs unchanged by the router simplification.
- Native ETH collateral adds ~350k gas over ERC20 collateral due to value handling.
