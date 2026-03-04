# FUTURE-EXT: Position NFT Financial Product Roadmap

## Status

Draft (Rewritten March 2026)

## Purpose

This document maps realistic expansion products for Equalis using the current shipped custody and accounting rails:

* Position NFT custody (`positionKey`)
* Encumbrance accounting (`directLocked`, `directLent`, `directOfferEscrow`, module encumbrance)
* Unified pool ledgers (`userPrincipal`, `trackedBalance`, `userAccruedYield`)
* `FeeIndex` and `ActiveCreditIndex`

This version focuses on technical feasibility in the current system and gives concrete implementation patterns.

---

## Current Baseline Assumptions

* Pools are asset-generic, including native ETH (`address(0)`), not WETH-only.
* Perps are already shipped in isolated form and currently oracle-driven.
* Existing direct lending rails already support rich bilateral term structures.
* ABI/backward compatibility constraints are intentionally ignored for this roadmap.

---

## Feasibility Legend

* **High**: Mostly orchestration over existing primitives.
* **Medium**: New facet + moderate new storage/accounting semantics.
* **Medium-Hard**: Requires new risk engine components or new accounting dimension.
* **Hard**: Major architecture additions and/or manipulation-sensitive market design.

---

## Product Matrix

| Product | Feasibility | Core Reuse | Primary New Work |
| --- | --- | --- | --- |
| OTC Swaps / Forwards | High | Direct offer/accept lifecycle | New payoff templates |
| Repos | High | Direct + futures-style maturity | Default path semantics |
| Structured Notes | High | Options/Futures/Direct + ERC-1155 | Strategy compiler + settlement router |
| Swing Options | Medium | Collateral lock + periodic exercise | Draw schedule accounting |
| Internal Yield Swaps | Medium | Fee index snapshots | Floating-leg definition and netting |
| Tokenized Credit Lines | Medium | Encumbrance + lending rails | Reservation/underwriting model |
| Guarantor Positions | Medium-Hard | Default allocation helpers | Third-party seizure and premium engine |
| Tranched Cashflow Tokens | Medium-Hard | ERC-1155 claims + fee rails | Source-specific cashflow attribution |
| Oracle-Free Internal Perps | Hard | Existing perps lifecycle | Robust internal mark/twap anti-manipulation |
| Basis Vaults | High | Spot pools + perps + options | Vault policy + rebalancing automation |
| Perps Insurance Vaults | Medium | Perps insurance state + fee routing | Capital admission/exit and impairment logic |
| Rate Caps/Floors | Medium | Fee/active-credit indices | Path-dependent strike payoff engine |
| Zero-Coupon Notes | High | Direct agreements | Discount issuance + maturity claim flow |
| Callable/Putable Credit Notes | Medium | Zero-coupon + direct exercise | Embedded option exercise model |
| Portfolio Margin Accounts | Hard | Position-level custody | Cross-product risk netting engine |
| Auto-Roll Strategy Tokens | Medium | Existing derivatives | Rolling and rollover slippage controls |
| Credit Auction Desk | Medium | MAM/auction design patterns | Borrow capacity orderbook/auction logic |
| Volatility Carry Vaults | Medium-Hard | Options rails | Dynamic hedge and circuit-breaker controls |
| Fee Stream Strips | Medium | Yield claim accounting | Yield principal/time partitioning |

---

## Detailed Product Specs

## 1. Collateralized OTC Swaps and Forwards

### Feasibility

High

### Product Summary

Two Position Keys negotiate a fixed-price future exchange of two assets, fully collateralized.

### Why It Fits Equalis

* Already aligned with direct offer/accept patterns.
* No oracle required for settlement if forward price is fixed at creation.
* Encumbrance and solvency checks are already native.

### Proposed Interface

* `createForwardOffer(positionId, terms)`
* `acceptForwardOffer(positionId, offerId)`
* `settleForward(offerId)`
* `cancelForward(offerId)`

### Storage Sketch

* `ForwardOffer { makerKey, takerKey, poolIdA, poolIdB, notionalA, forwardPrice, maturity, status }`
* `ForwardMargin { makerLocked, takerLocked, lastSettleTs }`

### Settlement Model

* At maturity, compute fixed exchange amounts and perform principal debits/credits.
* If one side cannot deliver, use pre-locked margin waterfall and mark default.

### Key Risks and Controls

* Counterparty failure before maturity:
  * Full collateralization at accept time.
* Time risk:
  * Duration caps and minimum margin ratio by tenor.

---

## 2. On-Chain Repos

### Feasibility

High

### Product Summary

Atomic sale of asset X for cash Y with contractual repurchase at maturity (fixed repurchase price).

### Why It Fits Equalis

* Reuses forward settlement lifecycle.
* Natural mapping to locked collateral and deterministic default logic.

### Proposed Interface

* `openRepo(positionId, params)`
* `acceptRepo(positionId, repoId)`
* `settleRepo(repoId)` (repurchase or default)
* `cancelRepo(repoId)`

### Storage Sketch

* `Repo { sellerKey, buyerKey, soldPoolId, cashPoolId, soldAmount, cashReceived, repurchaseAmount, maturity, status }`

### Settlement Model

* Open: transfer sold asset to buyer, cash to seller.
* Maturity:
  * If seller repays, reverse asset transfer.
  * Else default finalizes buyer ownership.

### Key Risks and Controls

* Gap risk at maturity:
  * Haircuts by asset class.
* Maturity abuse:
  * Grace windows and deterministic default trigger.

---

## 3. Structured Notes (Composable Strategy Wrappers)

### Feasibility

High

### Product Summary

ERC-1155 notes represent claims on a packaged strategy (options + futures + lending + AMM legs).

### Why It Fits Equalis

* Execution legs already exist.
* Position NFT can own and operate all legs without external vaults.

### Proposed Interface

* `createStructuredNote(positionId, strategyBlob, issuance, maturity)`
* `subscribe(noteId, amount)`
* `settleStructuredNote(noteId)`
* `redeem(noteId, amount)`

### Storage Sketch

* `StructuredNote { makerKey, strategyHash, maturity, notionalIssued, status }`
* `NoteLeg { kind, refId, direction, size }`
* `NoteAccounting { navIndex, feeBps, lastMarkTs }`

### Settlement Model

* Deterministic leg unwind at maturity.
* Net proceeds routed pro-rata to note holders.

### Key Risks and Controls

* Strategy misconfiguration:
  * Strategy schema validation at creation.
* Hidden leverage:
  * Per-note leverage and drawdown guards.

---

## 4. Swing Options (Streaming Claims)

### Feasibility

Medium

### Product Summary

Buyer obtains periodic draw rights (daily/weekly) against locked maker capacity at fixed strike/rate.

### Why It Fits Equalis

* Encumbrance can reserve max capacity upfront.
* Exercise resembles repeated partial settlement calls.

### Proposed Interface

* `createSwing(positionId, params)`
* `exerciseSwing(swingId, amount)`
* `closeSwing(swingId)`

### Storage Sketch

* `Swing { makerKey, taker, poolIdIn, poolIdOut, totalCapacity, usedCapacity, periodLimit, currentPeriodDrawn, periodStart, strike, maturity, status }`

### Settlement Model

* On each exercise:
  * enforce period quota
  * transfer payout vs payment
  * increment `usedCapacity`

### Key Risks and Controls

* Draw-burst risk:
  * strict period windows + per-call cap.
* Settlement griefing:
  * keeper-settle fallback and auto-expiry.

---

## 5. Internal Yield Swaps (Fixed vs Floating)

### Feasibility

Medium

### Product Summary

Two parties swap fixed rate versus floating protocol yield derived from index deltas.

### Why It Fits Equalis

* Index rails already track cumulative yield.
* Position-level principal/accounting already in place.

### Proposed Interface

* `openYieldSwap(positionId, counterpartyKey, params)`
* `settleYieldSwap(swapId)`
* `closeYieldSwap(swapId)`

### Storage Sketch

* `YieldSwap { payerKey, receiverKey, poolId, notional, fixedRateBps, start, maturity, lastSettle, feeIndexStart, aciIndexStart, status }`

### Floating Leg Choices

* **FeeIndex only**: cleaner passive-yield leg.
* **FeeIndex + ActiveCreditIndex**: broader activity-linked float.

### Key Risks and Controls

* Index definition ambiguity:
  * lock leg definition per series.
* Payment shock:
  * margin calls + termination threshold.

---

## 6. Tokenized Credit Lines (Transferable Draw Rights)

### Feasibility

Medium

### Product Summary

Position owner mints rights tokens that permit holders to draw up to a reserved facility limit.

### Why It Fits Equalis

* Draw/repay behavior can reuse lending mechanics.
* Rights can be ERC-1155 for transferability.

### Proposed Interface

* `createCreditLine(positionId, poolId, facility, expiry)`
* `mintDrawRights(lineId, amount, receiver)`
* `drawWithRights(lineId, rightsAmount)`
* `repayCreditLine(lineId, amount)`

### Storage Sketch

* `CreditLine { providerKey, poolId, facilityCap, reservedCap, drawn, expiry, status }`
* `RightsSeries { lineId, totalSupply, burned }`

### Critical Design Decision

Reserve capacity at issuance (encumber `facilityCap`) so rights remain reliably exercisable.

### Key Risks and Controls

* Under-backed rights:
  * hard reservation at mint time.
* Utilization spiral:
  * draw throttles and line-level health checks.

---

## 7. Guarantor Positions (Credit Protection)

### Feasibility

Medium-Hard

### Product Summary

Third-party guarantor stakes collateral to back borrower obligations in exchange for premium.

### Why It Fits Equalis

* Default allocation helpers already exist in direct lending exercise flows.
* Encumbrance supports locked third-party backing.

### Proposed Interface

* `openGuaranty(guarantorPositionId, borrowerKey, params)`
* `attachGuarantyToLoan(loanId, guarantyId)`
* `payGuarantyPremium(guarantyId)`
* `settleGuaranty(guarantyId)`

### Storage Sketch

* `Guaranty { guarantorKey, borrowerKey, lenderPoolId, collateralPoolId, notionalCovered, collateralLocked, premiumRateBps, maturity, status }`

### Settlement Model

* On healthy close: release guarantor collateral.
* On borrower default: seize guarantor collateral by waterfall before protocol absorbs loss.

### Key Risks and Controls

* Correlated defaults:
  * guarantor concentration limits.
* Premium underpricing:
  * governance floor curves by tenor/coverage ratio.

---

## 8. Tranched Cashflow Tokens

### Feasibility

Medium-Hard

### Product Summary

Split a position cashflow stream into senior and junior ERC-1155 tranches.

### Why It Fits Equalis

* Tokenized claims are a natural extension.
* Position-level cashflow is already tracked, but currently aggregated.

### Required New Infrastructure

Source-specific yield attribution per stream, not just aggregate `userAccruedYield`.

### Proposed Interface

* `createTrancheSeries(positionId, streamConfig, terms)`
* `subscribeTranche(seriesId, side, amount)`
* `claimTrancheCashflow(seriesId, holder)`
* `settleTrancheSeries(seriesId)`

### Storage Sketch

* `TrancheSeries { makerKey, streamId, seniorTarget, juniorShareBps, maturity, paidSenior, paidJunior, status }`
* `StreamCheckpoint { feeIndexSnapshot, aciSnapshot, principalSnapshot }`

### Key Risks and Controls

* Waterfall mismatch:
  * deterministic claim order and tested rounding policy.
* Stream dilution:
  * lock stream scope and prevent overlap conflicts.

---

## 9. Oracle-Free Internal Perps

### Feasibility

Hard

### Product Summary

Perps marked from internal protocol markets without external oracle adapters.

### Why It Is Hard

Internal mark is manipulation-sensitive near funding and liquidation boundaries.

### Minimum Viable Safety Stack

* Time-windowed mark (multi-block TWAP)
* Trade-size-adjusted impact price
* Cooldown between large position update and liquidation eligibility
* Circuit breaker when mark deviates from robust internal median

### Proposed Interface

* `createInternalPerpMarket(params)`
* `openInternalPerp(accountId, size, side, limitPrice)`
* `updateInternalFunding(marketId)`
* `liquidateInternalPerp(accountId)`

### Key Risks and Controls

* Manipulative self-trades:
  * exclusion lists for self-trade mark inputs.
* Liquidity drought:
  * max leverage compression under low depth.

---

## 10. Basis Vaults (Cash-and-Carry)

### Feasibility

High

### Product Summary

Vault runs spot/perp basis trades and tokenizes strategy shares.

### Core Strategy

* Long spot inventory (pool principal)
* Short perp notional
* Collect funding + basis convergence

### Proposed Interface

* `createBasisVault(positionId, params)`
* `depositBasis(vaultId, amount)`
* `rebalanceBasis(vaultId)`
* `withdrawBasis(vaultId, shares)`

### Key Risks and Controls

* Basis inversion:
  * auto-delever thresholds.
* Funding regime shifts:
  * rolling expected funding guards.

---

## 11. Perps Insurance Vaults

### Feasibility

Medium

### Product Summary

LP capital underwrites perps insolvency and earns premium share.

### Proposed Interface

* `createInsuranceVault(marketId, params)`
* `depositInsurance(vaultId, amount)`
* `withdrawInsurance(vaultId, shares)`
* `applyInsuranceLoss(vaultId, amount)`

### Storage Sketch

* `InsuranceVault { marketId, assetPoolId, totalShares, nav, lockedForClaims, impairmentIndex }`

### Key Risks and Controls

* Sudden loss events:
  * withdrawal cooldown + claim-first accounting.

---

## 12. Rate Caps and Floors (Index-Linked)

### Feasibility

Medium

### Product Summary

Options on realized index accrual over a term (cap/floor on floating rate).

### Payoff

* Cap buyer receives `max(realizedRate - strike, 0) * notional`.
* Floor buyer receives `max(strike - realizedRate, 0) * notional`.

### Proposed Interface

* `createRateOption(positionId, params)`
* `exerciseRateOption(seriesId, amount)`
* `settleRateOption(seriesId)`

### Key Risks and Controls

* Rate measurement ambiguity:
  * lock formula and index source at series creation.

---

## 13. Zero-Coupon Notes

### Feasibility

High

### Product Summary

Issue discounted claims now for fixed redemption at maturity.

### Proposed Interface

* `issueZeroCoupon(positionId, faceValue, discountBps, maturity)`
* `buyZeroCoupon(noteId, amount)`
* `redeemZeroCoupon(noteId, amount)`

### Key Risks and Controls

* Redemption shortfall:
  * full collateral lock against face value.

---

## 14. Callable / Putable Credit Notes

### Feasibility

Medium

### Product Summary

Zero-coupon style notes with embedded issuer call and holder put windows.

### Proposed Interface

* `issueCallableNote(positionId, terms)`
* `callNote(noteId)`
* `putNote(noteId, amount)`
* `settleCallableNote(noteId)`

### Key Risks and Controls

* Exercise gaming:
  * deterministic exercise windows and notice periods.

---

## 15. Portfolio Margin Accounts

### Feasibility

Hard

### Product Summary

Cross-margin netting across options, futures, perps, and direct exposures inside one account mode.

### Why It Is Hard

Requires unified risk model and real-time net exposure haircuting across currently isolated domains.

### Required Components

* Exposure graph per position
* Shock scenario engine
* Concentration and correlation limits

### Key Risks and Controls

* Model risk:
  * conservative initial haircuts and governance-tunable factors.

---

## 16. Auto-Roll Strategy Tokens

### Feasibility

Medium

### Product Summary

Tokenized strategies that automatically roll short-dated futures/options exposures.

### Proposed Interface

* `createRollStrategy(positionId, policy)`
* `depositRollStrategy(strategyId, amount)`
* `rollStrategy(strategyId)` (keeper callable)
* `withdrawRollStrategy(strategyId, shares)`

### Key Risks and Controls

* Bad roll execution:
  * slippage bounds and fallback pause.

---

## 17. Credit Auction Desk

### Feasibility

Medium

### Product Summary

Auction venue for borrowing capacity where lenders compete on rate/tenor/collateral terms.

### Proposed Interface

* `createCreditAuction(positionId, request)`
* `bidCreditAuction(auctionId, quote)`
* `finalizeCreditAuction(auctionId)`

### Key Risks and Controls

* Winner selection gaming:
  * deterministic scoring function published pre-bid.

---

## 18. Volatility Carry Vaults

### Feasibility

Medium-Hard

### Product Summary

Vault harvests option risk premium using systematic short-vol strategies with hard risk limits.

### Proposed Interface

* `createVolCarryVault(positionId, policy)`
* `rebalanceVolCarry(vaultId)`
* `emergencyDeRisk(vaultId)`

### Key Risks and Controls

* Tail events:
  * mandatory hedge budget and max short-gamma thresholds.

---

## 19. Fee Stream Strips (Principal/Yield Separation)

### Feasibility

Medium

### Product Summary

Split deposit exposure into:

* principal claim token
* forward yield claim token for a fixed horizon

### Proposed Interface

* `stripFeeStream(positionId, poolId, amount, maturity)`
* `claimYieldStrip(stripId)`
* `recombineStrip(stripId, amount)`

### Key Risks and Controls

* Double-claim risk:
  * strict burn-on-claim and recombination invariants.

---

## Common Implementation Standards

### Permissions

* Creation/modification restricted to Position owner or approved operator.
* ERC-1155 holder/operator permissions allowed only for claim/exercise paths where ownership of underlying position is not required.

### Accounting Rules

* Always settle `FeeIndex` and `ActiveCreditIndex` before solvency/availability checks.
* Always mutate encumbrance before downstream transfers when creating obligations.
* Maintain tracked balance invariants for any external transfer.

### Required Events

Each product should emit lifecycle events:

* `Created`
* `Accepted`
* `Updated`
* `Settled`
* `Cancelled`
* `Defaulted`
* `Exercised`

### Risk Controls Baseline

* Product-level pause switch.
* Max duration and max notional constraints.
* Per-position concentration caps.
* Deterministic default waterfall for every bilateral product.
* Explicit rounding policy for all split/cashflow math.

---

## Suggested Build Order

1. OTC Swaps / Forwards
2. Repos
3. Structured Notes
4. Yield Swaps
5. Tokenized Credit Lines
6. Guarantor Positions
7. Tranche Cashflow Tokens
8. Basis + Insurance Vaults
9. Portfolio Margin
10. Oracle-Free Internal Perps

---

## Summary

Equalis can support a very broad product surface because custody, encumbrance, and yield rails are already unified. The fastest path is to ship bilateral fixed-payoff products first, then layered strategy wrappers, then capital-structure products (tranches/guarantees), and finally model-heavy systems (portfolio margin and oracle-free perps).
