# MAM Full Native ETH Support Design

**Version:** 0.1  
**Status:** Draft  
**Owner:** EqualX / MAM  
**Date:** 2026-02-17

## 1. Overview

This document defines the design for **full native ETH support** in MAM curve creation and execution.

Today MAM rejects native assets at descriptor validation (`tokenA == address(0)` or `tokenB == address(0)`), so all MAM pairs are ERC20/ERC20 only.

Target state:

- MAM supports one native side (`base` or `quote`) with the other side ERC20.
- Over-cap quote handling remains safe (pull up to `maxQuote`, refund excess).
- Accounting and fee routing remain invariant across native and ERC20 paths.

## 2. Goals

- Enable native ETH as either side of a MAM pair.
- Preserve current security and accounting guarantees.
- Keep `previewCurveQuote` and swap math unchanged.
- Maintain compatibility with existing ERC20-only curves.

## 3. Non-Goals

- Supporting both sides native in one curve.
- Changing MAM pricing math.
- Introducing wrapped-native auto-conversion inside MAM.
- Redesigning fee split policy.

## 4. Current Constraints

- `src/EqualX/MamCurveCreationFacet.sol` rejects native token addresses during descriptor validation.
- `src/EqualX/MamCurveExecutionFacet.sol` uses `LibCurrency.pullAtLeast`/`transferWithMin`, which can already handle native transfers.
- For ERC20 quote paths, explicit `msg.value == 0` enforcement is not currently guaranteed inside `executeCurveSwap`.

## 5. Proposed Design

## 5.1 Descriptor Validation

Update descriptor validation to permit native on one side:

- Allow `tokenA == address(0)` or `tokenB == address(0)`.
- Keep `tokenA != tokenB` requirement (this naturally prevents native/native pairs).
- Keep pool-underlying consistency checks:
  - `poolA.underlying == tokenA`
  - `poolB.underlying == tokenB`

No changes to:

- `priceIsQuotePerBase`, `feeAsset`, `generation`, `maxVolume`, duration/start constraints.

## 5.2 Execution `msg.value` Policy

Add explicit value checks in `executeCurveSwap` before quote pull:

- If quote token is native:
  - require `msg.value == maxQuote` (exact over-cap funding model).
- If quote token is ERC20:
  - require `msg.value == 0`.

This avoids silent ETH donation on ERC20 quote swaps.

## 5.3 Quote Pull + Refund Model

Keep current model:

- Pull `maxQuote`.
- Require received >= `totalQuote`.
- Refund `received - totalQuote` to caller.
- Account quote pool with `totalQuote` only.

Apply identically for native and ERC20 quote paths.

## 5.4 Base Payout

Keep current payout model:

- `transferWithMin(baseToken, recipient, baseFill, minOut)` for both native and ERC20 base.
- If recipient rejects native ETH in base-native path, swap reverts.

## 5.5 Accounting Invariants

Invariants must hold regardless of token type:

- `amountOut` depends only on curve state + `amountIn`.
- Maker quote principal increase:
  - `amountIn + makerFee`.
- Quote pool tracked increase:
  - `totalQuote - treasuryOut` (after routing effects).
- Base pool principal decrease:
  - `baseFill`.
- Over-cap input must not alter output/debt accounting (only temporary pull + refund).

## 6. Functional Requirements

- `REQ-MAM-NATIVE-001`: MAM descriptor accepts one-side native token address.
- `REQ-MAM-NATIVE-002`: MAM descriptor rejects native/native pairs.
- `REQ-MAM-NATIVE-003`: Pool/token consistency remains enforced for native pools.
- `REQ-MAM-NATIVE-004`: For native quote, `msg.value == maxQuote` required.
- `REQ-MAM-NATIVE-005`: For ERC20 quote, `msg.value == 0` required.
- `REQ-MAM-NATIVE-006`: Over-cap quote is refunded, output unaffected.
- `REQ-MAM-NATIVE-007`: Base-native payout respects `minOut` and reverts on failed transfer.
- `REQ-MAM-NATIVE-008`: Existing ERC20-only behavior remains unchanged.

## 7. Security Requirements

- `SEC-MAM-NATIVE-001`: No path where extra quote pull changes maker debt or output.
- `SEC-MAM-NATIVE-002`: No path where ETH can be accidentally accepted for ERC20 quote swaps.
- `SEC-MAM-NATIVE-003`: Native tracked accounting (`nativeTrackedTotal`) remains balanced across pull/refund/payout.
- `SEC-MAM-NATIVE-004`: Reentrancy assumptions remain valid under native refund and payout calls.

## 8. File-Level Change Plan

- `src/EqualX/MamCurveCreationFacet.sol`
  - Relax native-address rejection in `_validateDescriptor`.
  - Keep `tokenA != tokenB`.

- `src/EqualX/MamCurveExecutionFacet.sol`
  - Add explicit `msg.value` policy check by quote token type.
  - Keep refund/accounting flow (or reorder if implementation prefers, while preserving invariants).

- Optional shared error handling
  - Reuse `UnexpectedMsgValue` where appropriate for consistency.

## 9. Test Plan

## 9.1 Unit / Property Coverage

- `test/derivatives/MamCurveFacet.t.sol`
  - Native quote + over-cap msg.value:
    - exact assertion: no extra output, excess refunded.
  - Native base payout:
    - successful payout and `minOut` behavior.
  - ERC20 quote + non-zero msg.value:
    - explicit revert.

- `test/derivatives/MamCurveFeeOnTransfer.t.sol`
  - Ensure FoT quote behavior unchanged.
  - Ensure over-cap max still does not change accounting/output.

- Native failure path tests
  - recipient contract rejecting ETH in base-native payout should revert.
  - quote refund recipient rejecting ETH should revert (if quote-native over-cap refund path triggers transfer failure).

## 9.2 Regression Coverage

- Existing MAM tests must pass unchanged.
- Existing AtomicDesk/derivatives test suites should remain green.

## 10. Acceptance Criteria

- All `REQ-*` and `SEC-*` pass via tests.
- Native quote and native base swaps are executable in integration tests.
- ERC20 quote path rejects non-zero `msg.value`.
- No accounting drift in tracked/principal metrics under native paths.

## 11. Rollout Strategy

Phase 1:

- Implement descriptor + execution gating.
- Add core native quote tests + ERC20 msg.value guard tests.

Phase 2:

- Add native base payout tests and rejection edge-cases.
- Run broader derivative and invariant suites.

Phase 3:

- Audit-focused review and gas comparison.
- Document external integration guidance (use `address(0)` for native token in descriptors).

## 12. Task List (Implementation-Oriented)

- `TASK-MAM-NATIVE-001`: Update descriptor validation for one-side native support.
- `TASK-MAM-NATIVE-002`: Add explicit quote-token `msg.value` guard in execution.
- `TASK-MAM-NATIVE-003`: Validate native quote over-cap refund behavior with deterministic assertions.
- `TASK-MAM-NATIVE-004`: Add native base payout tests (`minOut`, success, rejector).
- `TASK-MAM-NATIVE-005`: Add ERC20 quote + non-zero `msg.value` revert tests.
- `TASK-MAM-NATIVE-006`: Re-run and fix regressions in MAM and derivative integration suites.
- `TASK-MAM-NATIVE-007`: Update docs/spec comments where MAM previously stated ERC20-only.

## 13. Open Questions

- `Q1`: Should quote-native over-cap refund failure revert the full swap (recommended: yes, consistent with strict accounting)?
- `Q2`: Should `CurveFilled.actualIn` continue to report gross received (pre-refund) or switch to net quote?
- `Q3`: Any policy preference for requiring native quote only (and deferring native base) despite this full-support design?

## 14. Suggested Requirement Export Format

For easy handoff to another assistant, map:

- `REQ-*` => product requirements checklist.
- `SEC-*` => security acceptance checklist.
- `TASK-*` => implementation sprint tasks.

All IDs are stable and can be copied directly into project tracking.
