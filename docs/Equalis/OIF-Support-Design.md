# Open Intents Framework (OIF) Support Design

**Version:** 0.1  
**Status:** Draft  
**Scope:** Equalis integration with the Open Intents Framework for MAM curves, AMM auctions, and related execution surfaces.

## Table of Contents

1. [Overview](#overview)
2. [Goals](#goals)
3. [Non-Goals](#non-goals)
4. [Design Decision](#design-decision)
5. [High-Level Architecture](#high-level-architecture)
6. [Intent Types and Payloads](#intent-types-and-payloads)
7. [Module Isolation Model](#module-isolation-model)
8. [Multi-Output Orders](#multi-output-orders)
9. [Dedicated On-Chain Registry](#dedicated-on-chain-registry)
10. [Settlement Flows](#settlement-flows)
11. [Security Requirements](#security-requirements)
12. [Data Retention Policy](#data-retention-policy)
13. [Compatibility and Migration](#compatibility-and-migration)
14. [Implementation Plan](#implementation-plan)
15. [Testing Plan](#testing-plan)
16. [Operational Plan](#operational-plan)
17. [Open Questions](#open-questions)

---

## Overview

OIF is becoming a default interoperability layer for cross-chain intent execution. Supporting OIF positions Equalis to:

- receive solver flow from existing OIF solver networks,
- expose MAM and AMM execution as standardized fill targets,
- reuse existing OIF validation/oracle/input-settlement infrastructure.

This design proposes a **strict Equalis-specific OIF output settlement path** rather than a generic callback/multicall integration.

---

## Goals

- Add production-grade OIF support for:
  - MAM curve execution (`executeCurveSwap`)
  - AMM auction execution (`swapExactIn`)
  - Community auction execution (`swapExactIn`)
- Preserve ecosystem interoperability with OIF solver tooling.
- Ensure deterministic and auditable execution semantics.
- Eliminate soft-fail execution paths for settlement-critical flows.
- Allow internal ABI/API refactors where beneficial.

---

## Non-Goals

- Redesigning Equalis pricing models (MAM/AMM mechanics stay unchanged).
- Building a new off-chain solver network.
- Supporting every Equalis module in V1 (Atomic Desk and other later-stage modules are out of scope).

---

## Design Decision

### Decision Summary

Implement **module-isolated OIF output settlers** with typed payloads and strict execution guarantees.

### Why this approach

- Generic callback handlers are too permissive for critical settlement.
- Typed payloads enable deterministic validation and safer upgrades.
- Solver UX remains aligned with OIF while Equalis enforces venue-specific invariants on-chain.

### Compatibility stance

- **External OIF-facing interface:** remain compatible with OIF expectations.
- **Internal Equalis API/ABI:** may change where needed (backward compatibility not required).

---

## High-Level Architecture

### Components

- **OIF-MAM Settler (new):**
  - OIF-compatible fill and attestation behavior for MAM only.
  - Executes `executeCurveSwap` atomically.

- **OIF-AMM Settler (new):**
  - OIF-compatible fill and attestation behavior for solo AMM auctions only.
  - Executes `swapExactIn` atomically.

- **OIF-Community Settler (new):**
  - OIF-compatible fill and attestation behavior for Community Auctions only.
  - Executes `swapExactIn` atomically.

- **Optional Registry (new):**
  - Small governance-controlled mapping of enabled module settlers and target facet addresses.

- **OIF Input Settler (existing OIF contracts):**
  - Finalizes origin-side input release after proof verification.

- **OIF Oracle/Validation Layer (existing OIF contracts):**
  - Carries output fill attestations across chains.

### Integration boundary

- Equalis remains the execution engine.
- OIF remains the cross-chain intent and proof transport standard.

---

## Intent Types and Payloads

Use explicit typed payloads in `MandateOutput.context` for venue execution.

### Type IDs

- `0x10`: `MAM_EXACT_IN`
- `0x11`: `AMM_AUCTION_EXACT_IN`
- `0x12`: `COMMUNITY_AUCTION_EXACT_IN`

### V1 payload schemas

```solidity
struct MamExactInPayload {
    uint8 payloadType;      // 0x10
    uint256 curveId;
    uint256 amountIn;       // quote token in
    uint256 maxQuote;       // anti-overpull bound
    uint256 minOut;         // base token out bound
    uint64 deadline;
    address recipient;
}

struct AmmAuctionExactInPayload {
    uint8 payloadType;      // 0x11
    uint256 auctionId;
    address tokenIn;
    uint256 amountIn;
    uint256 maxIn;          // anti-overpull bound
    uint256 minOut;
    uint64 deadline;
    address recipient;
}

struct CommunityAuctionExactInPayload {
    uint8 payloadType;      // 0x12
    uint256 auctionId;
    address tokenIn;
    uint256 amountIn;
    uint256 maxIn;          // anti-overpull bound
    uint256 minOut;
    uint64 deadline;
    address recipient;
}
```

### Constraints

- Payload type must match route.
- Token expectations must match `MandateOutput.token`.
- Deadline must be enforced by settler before venue call.
- Recipient cannot be zero address.

---

## Module Isolation Model

- Deploy separate settler contracts per module (`MAM`, `AMM`, `COMMUNITY`).
- Each settler accepts only its payload type and only its module call.
- No mixed-module dispatch in a single settler.
- Atomic Desk integration is explicitly deferred to a later version.

Rationale:
- Smaller attack surface per settler.
- Cleaner audits and permissioning.
- Easier incident containment and pausing per module.

---

## Multi-Output Orders

### What they are in OIF

A single order can include multiple outputs. Each output must be proven filled for finalization.

### Why they are tricky

- OIF ownership semantics are tied to the first output fill in standard flows.
- Time-dependent outputs can be strategically delayed in multi-output contexts.
- Operational complexity increases sharply across chains and modules.

### V1 policy

- **Single-output only** for all Equalis OIF module settlers.
- Enforce `outputs.length == 1` on the Equalis route.

### Why single-output in V1

- Removes first-output ownership ambiguity for Equalis intents.
- Keeps MAM/AMM/community fill guarantees simple and auditable.
- Reduces solver and user error during ecosystem onboarding.

---

## Dedicated On-Chain Registry

The registry is optional but useful for controlled upgrades and route safety.

### Purpose

- Whitelist active module settlers.
- Bind each module to its authorized Equalis target facet.
- Support per-module pause and versioning.

### Minimal schema

```solidity
struct ModuleRoute {
    bool enabled;
    address settler;        // OIF module settler
    address targetFacet;    // Equalis facet target for execution
    bytes4 selector;        // expected execution selector
}

mapping(uint8 => ModuleRoute) public moduleRoutes;
```

### Minimal operations

- `setModuleRoute(moduleId, route)` (timelock/governance only)
- `setModuleEnabled(moduleId, enabled)` (timelock/governance only)
- read-only getters

No order-level state should be stored in this registry.

---

## Settlement Flows

### Flow A: OIF -> Equalis MAM fill

1. Sponsor signs OIF order on origin chain.
2. Solver fills output on destination chain through `OIF-MAM-Settler`.
3. Settler executes `executeCurveSwap` with typed MAM payload.
4. If execution succeeds, settler records fill and emits attestation-compatible payload.
5. OIF oracle validates and relays proof.
6. Input settler finalizes and releases origin-side inputs to solver.

### Flow B: OIF -> Equalis AMM auction fill

Same flow, with venue dispatch to `swapExactIn`.

### Flow C: OIF -> Equalis Community Auction fill

Same flow, with venue dispatch to Community Auction `swapExactIn`.

### Failure behavior

- Venue execution failure must revert full fill transaction.
- No soft-fail mode.
- No partial settlement on failed execution.

---

## Security Requirements

### 1. Strict execution semantics

- Remove or avoid fallback/soft-success behavior in settlement path.
- If venue call fails, output fill must fail.

### 2. Unique output enforcement

- Reject orders with duplicate `MandateOutput` hashes for the same order.
- Prevent under-delivery ambiguity for repeated outputs.

### 3. Solver identity binding

- Bind solver identity to attested fill source.
- Do not accept unconstrained solver identity inputs when determining ownership-sensitive outcomes.

### 4. Purchase ownership correctness

- If underwriting/purchase is used, validate solver identity against proved fill before accepting transfer of rights.

### 5. Deadline and slippage propagation

- Enforce deadline in output settler and venue layer.
- Ensure `minOut`/`maxIn`/`maxQuote` are carried and enforced exactly.

### 6. Reentrancy and approvals

- Settler path must be non-reentrant.
- Avoid standing approvals to arbitrary contracts.
- If approvals are required, set exact amount and clear when possible.

---

## Data Retention Policy

Minimum required data retention should be the default.

### On-chain (required)

- OIF-required fill records/attestation state.
- Module route config (if registry is used).
- No extra per-order analytics state.

### On-chain (avoid)

- Do not persist full payload blobs beyond what OIF fill proofs already require.
- Do not maintain long-lived solver profile storage in settlement contracts.

### Events (minimal)

Emit only what is needed for reconciliation and debugging:

- `orderId`
- `moduleId`
- `venueId` (`curveId`/`auctionId`)
- `solver` identifier
- `amountIn` / `amountOut`
- `status` (success path emits; failures revert)

All richer analytics should remain off-chain.

---

## Compatibility and Migration

### External compatibility (required)

- Keep OIF-standard payload attestation model and relevant interfaces compatible for solver ecosystem adoption.

### Internal compatibility (optional)

- We may refactor Equalis internal routes and helper interfaces for clarity and safety.
- Legacy integration adapters can be deprecated after migration.
- Module-specific settlers can be upgraded independently.

### Versioning

- Introduce `OIF_EQUALIS_V1` payload domain tag in docs/events.
- Future payload schema changes must use new type IDs.

---

## Implementation Plan

### Phase 1: MVP (MAM + AMM + Community output execution)

- Implement isolated settlers:
  - `OIF-MAM-Settler`
  - `OIF-AMM-Settler`
  - `OIF-Community-Settler`
- Implement typed payload decoder/validator in each settler.
- Enforce single-output-only Equalis orders.
- Optionally deploy minimal module-route registry.
- Emit OIF-compatible fill descriptions.

### Phase 2: Hardening

- Add duplicate output rejection.
- Add solver identity binding checks in ownership-sensitive paths.
- Add strict underwriting/purchase solver verification.
- Add gas and invariant profiling.

### Phase 3: Ecosystem Launch

- Publish integration docs for external solvers.
- Add reference order-builder payload encoders.
- Add monitoring dashboards for fills/proofs/finalizations.

---

## Testing Plan

### Unit tests

- Payload decode and schema rejection tests.
- Deadline/slippage/amount bounds tests.
- Duplicate output rejection tests.
- Revert-on-venue-failure tests.
- Registry enable/disable and target binding tests (if registry enabled).

### Integration tests

- End-to-end OIF flow for MAM, AMM, and Community:
  - fill -> attestation -> proof relay -> input finalization.
- Solver competition behavior for first-output ownership semantics.
- Underwriting/purchase correctness with verified solver identity.

### Security tests

- Reentrancy attempts across settler + venue path.
- Callback/approval abuse attempts.
- Malformed payload fuzzing.

---

## Operational Plan

### Deployment model

- Deploy per chain where Equalis execution surfaces exist.
- Register canonical settler/oracle addresses in deployment manifests.

### Monitoring

- Track:
  - fill success/failure rate by payload type,
  - proof relay latency,
  - finalization success rate,
  - revert reason distribution.

### Runbooks

- Oracle congestion fallback procedures.
- Pausing policy for OIF route-level issues.
- Incident triage for mismatched payload/token constraints.

---

## Open Questions

### Must Decide Before Implementation

1. Which chains are in V1 scope, and which OIF oracle path is used per chain?
2. Do we require permissionless solver access from day one, or a guarded launch mode first?
3. What is the canonical payload encoding/versioning rule for future upgrades?
4. Do we support partial fills in V1, or require exact-fill only for simplicity?
5. How do we handle native token routes vs wrapped token-only routes?
6. Do we allow fee-on-transfer/rebasing tokens in OIF routes, or explicitly block them?
7. What finality threshold is required before origin-chain input release on each chain pair?
8. How do we handle timing drift between order deadlines and destination-chain execution windows?
9. What is the exact replay-protection policy across chainId, settler address, and module type?
10. What is the pause/governance model for isolated settlers (who can pause, how fast, how resumed)?
11. Is module-route registry mandatory in V1 or optional guardrail for controlled deployments?
12. Should single-output enforcement live only in settler, or also in off-chain order-builder guardrails?

### Can Decide Post-MVP

1. What are the minimum operational SLOs (proof latency, finalization latency, failure-rate thresholds)?
2. What is the deprecation/migration process when a settler is replaced (old orders, new orders, solver cutover)?
3. Which exact event fields are mandatory for operations vs optional for analytics?
4. What governance latency is acceptable for per-module route updates and pause actions?
5. When Atomic Desk matures, should it get a fourth isolated settler or a separate intent class?

---

## Recommended V1 Policy

- Support MAM, solo AMM, and Community Auction routes.
- Enforce single-output Equalis route orders.
- Enforce strict revert-on-failure execution.
- Isolate OIF support per module with separate settlers.
- Keep on-chain data retention minimal.
- Preserve OIF external compatibility while refactoring internal interfaces freely.
