# Zero-Coupon Notes Specification (Position NFT Derivatives)

## Status

Draft (March 2026)

## Purpose

Specify an Equalis-native zero-coupon note product where:

* Issuer locks collateral in a Position NFT.
* Buyers purchase ERC-1155 note units at discount during issuance.
* Holders redeem at fixed face value after maturity.

This spec is implementation-oriented and aligned to current Equalis accounting rails.

---

## 1. Scope

### 1.1 V1 In Scope

* Fully collateralized, transferable ERC-1155 zero-coupon notes.
* Single-asset notes:
  * Issuance payment asset == redemption asset == collateral asset.
* Position-key-based collateral locking and settlement.
* Optional create/buy/redeem/reclaim fees routed through existing fee rails.
* Explicit maturity and post-maturity reclaim grace period.
* Deterministic default mode if issuer cannot satisfy redemption.

### 1.2 V1 Out of Scope

* Cross-asset redemption notes.
* Tranche/strip variants.
* Embedded callable/putable features.
* Variable-rate or index-linked payoff.

---

## 2. Design Goals

* Reuse existing patterns from options/futures facets.
* Preserve pool accounting invariants (`userPrincipal`, `totalDeposits`, `trackedBalance`).
* Keep pricing oracle-free (face and issue price fixed at series creation).
* Provide deterministic holder outcomes under stress/default.

---

## 3. Product Model

Each series defines:

* `capUnits`: max units that may be sold.
* `issuePrice`: discounted purchase price per unit.
* `faceValue`: redemption value per unit at/after maturity.
* `issuanceWindow`: `[issueStart, issueEnd]`.
* `maturity`.

Economic requirement:

* `0 < issuePrice < faceValue`.

---

## 4. Architecture

### 4.1 Contracts

* `ZeroCouponFacet` (new)
  * creation, purchase, redemption, reclaim, default recovery.
* `ZeroCouponToken` (new)
  * ERC-1155 claim token, manager-controlled by Diamond.

### 4.2 Storage

Extend `LibDerivativeStorage.DerivativeStorage` with:

* `mapping(uint256 => DerivativeTypes.ZeroCouponSeries) zeroCouponSeries`
* `uint256 nextZeroCouponSeriesId`
* `bool zeroCouponPaused`
* `address zeroCouponToken`
* `mapping(uint256 => uint256) zeroCouponContractUnit` (optional if non-1 unit scaling desired)
* `LibPositionList.List zeroCouponSeriesByPosition`

---

## 5. Data Structures

```solidity
enum ZeroCouponStatus {
    IssuanceOpen,
    IssuanceClosed,
    Matured,
    Defaulted,
    Reclaimed
}

struct ZeroCouponSeries {
    bytes32 makerPositionKey;
    uint256 makerPositionId;
    uint256 poolId;
    address asset;

    uint64 issueStart;
    uint64 issueEnd;
    uint64 maturity;
    uint64 reclaimUnlockTime;

    uint256 issuePrice;        // asset units per note unit
    uint256 faceValue;         // asset units per note unit
    uint256 capUnits;          // max sellable units
    uint256 soldUnits;
    uint256 redeemedUnits;

    uint256 collateralLocked;  // current lock tracked in encumbrance domain
    uint256 maintenanceBuffer; // reserved collateral buffer

    // Fee params (series-local; can be defaulted from DerivativeConfig)
    uint16 createFeeBps;
    uint16 buyFeeBps;
    uint16 redeemFeeBps;
    uint16 reclaimFeeBps;

    // Default accounting remaining state
    uint256 defaultPotRemaining;
    uint256 defaultUnitsRemaining;

    ZeroCouponStatus status;
    bool reclaimed;
}

struct CreateZeroCouponSeriesParams {
    uint256 positionId;
    uint256 poolId;
    uint64 issueStart;
    uint64 issueEnd;
    uint64 maturity;
    uint256 issuePrice;
    uint256 faceValue;
    uint256 capUnits;
    uint16 maintenanceSafetyBps; // extra safety over projected maintenance
    bool useCustomFees;
    uint16 createFeeBps;
    uint16 buyFeeBps;
    uint16 redeemFeeBps;
    uint16 reclaimFeeBps;
}
```

---

## 6. Interfaces

```solidity
function setZeroCouponToken(address token) external;
function setZeroCouponPaused(bool paused) external;

function createZeroCouponSeries(CreateZeroCouponSeriesParams calldata p)
    external
    returns (uint256 seriesId);

function buyZeroCoupon(
    uint256 seriesId,
    uint256 units,
    address recipient,
    uint256 maxPayment
) external payable;

function redeemZeroCoupon(
    uint256 seriesId,
    uint256 units,
    address recipient,
    uint256 minReceived
) external;

function redeemZeroCouponFor(
    uint256 seriesId,
    uint256 units,
    address holder,
    address recipient,
    uint256 minReceived
) external;

function reclaimZeroCoupon(uint256 seriesId) external;

function claimDefaultRecovery(
    uint256 seriesId,
    uint256 units,
    address recipient,
    uint256 minReceived
) external;

function burnReclaimedZeroCouponClaims(address holder, uint256 seriesId, uint256 units) external;
```

---

## 7. Lifecycle and State Machine

### 7.1 Creation

At `createZeroCouponSeries`:

1. Require Position ownership/operator authority.
2. Validate pool membership and asset consistency.
3. Validate window ordering:
   * `issueStart <= issueEnd < maturity`.
4. Settle `FeeIndex` + `ActiveCreditIndex` for maker.
5. Compute required lock:
   * `baseCollateral = capUnits * faceValue`
   * `maintenanceBuffer = projectedMaintenance(baseCollateral, tenor) + safetyBuffer`
   * `requiredLock = baseCollateral + maintenanceBuffer`
6. Charge create fee (if configured).
7. Lock `requiredLock` via `LibDerivativeHelpers._lockCollateral`.
8. Persist series and index under maker position.
9. Emit `ZeroCouponSeriesCreated`.

### 7.2 Purchase (Issuance Window)

At `buyZeroCoupon`:

1. Require `block.timestamp` in `[issueStart, issueEnd]`.
2. Require `soldUnits + units <= capUnits`.
3. Compute payment:
   * `gross = units * issuePrice`.
4. Pull payment via `LibCurrency.pullAtLeast(asset, payer, gross, maxPayment)`.
5. Add received amount to pool tracked balance.
6. Charge buy fee from payment flow (if enabled).
7. Credit maker principal with net proceeds:
   * `pool.userPrincipal[makerKey] += netProceeds`
   * `pool.totalDeposits += netProceeds`
8. Mint ERC-1155 note units to recipient.
9. Increment `soldUnits`.
10. Emit `ZeroCouponPurchased`.

### 7.3 Redemption (Post-Maturity)

At `redeemZeroCoupon`:

1. Require `block.timestamp >= maturity`.
2. Require series not defaulted and not reclaimed.
3. Compute payout:
   * `grossPayout = units * faceValue`.
4. Check funding sufficiency before any token burn.
5. If insufficient, transition to `Defaulted`, snapshot remaining default state, reserve backing, and return without burning holder units.
6. Settle maker indices.
7. Unlock `grossPayout` from lock.
8. Debit maker principal/deposits:
   * `pool.userPrincipal[makerKey] -= grossPayout`
   * `pool.totalDeposits -= grossPayout`
9. Burn holder units.
10. Debit pool tracked balance by transfer amount.
11. Apply redeem fee (if configured), route fee.
12. Transfer net payout to recipient.
13. Increment `redeemedUnits`.
14. Emit `ZeroCouponRedeemed`.

### 7.4 Default Transition

If redemption cannot satisfy payout due to insufficient maker principal and/or pool tracked liquidity:

1. Transition series to `Defaulted`.
2. Snapshot `defaultPotRemaining` as the reserved deliverable amount.
3. Snapshot `defaultUnitsRemaining = soldUnits - redeemedUnits`.
4. Apply explicit ledger reservation entries so default backing cannot drift.
5. Do not allow normal redemption path thereafter.
6. Holders claim pro-rata from `defaultPotRemaining` via `claimDefaultRecovery`.

Default recovery payout:

* `recovery = units * defaultPotRemaining / defaultUnitsRemaining`.
* After each claim, decrease both `defaultPotRemaining` and `defaultUnitsRemaining`.

### 7.5 Reclaim

At `reclaimZeroCoupon` (maker only):

1. Require `block.timestamp >= reclaimUnlockTime`.
2. Compute `requiredForOutstandingClaims` and `reclaimable = collateralLocked - requiredForOutstandingClaims`.
3. Revert if `reclaimable == 0`.
4. Unlock only `reclaimable` collateral.
5. Charge reclaim fee (if configured).
6. If obligations are fully settled, mark `reclaimed = true`, set `status = Reclaimed`, and remove series from maker index.
7. Emit `ZeroCouponReclaimed`.

### 7.6 Effective Status Semantics

Status checks should use an effective status derived from persisted status plus time windows:

* Persisted terminal statuses (`Defaulted`, `Reclaimed`) always win.
* Otherwise derive non-terminal phase from timestamps (`issueStart`, `issueEnd`, `maturity`, `reclaimUnlockTime`).
* Mutating functions and view helpers should share the same status derivation logic.

---

## 8. Maintenance Buffer Formula

Locked principal is maintenance-exposed in current pool mechanics. V1 therefore requires explicit maintenance buffer.

Definitions:

* `base = capUnits * faceValue`
* `tenor = maturity - issueEnd`
* `maxRateBps = max(pool.poolConfig.maintenanceRateBps, protocolDefaultOrMaxRateBps)`
* `projected = ceil(base * maxRateBps * tenor / (365 days * 10_000))`
* `safety = ceil(base * maintenanceSafetyBps / 10_000)`
* `maintenanceBuffer = projected + safety`

Required lock:

* `requiredLock = base + maintenanceBuffer`.

Implementation note:

* `protocolDefaultOrMaxRateBps` should come from a governance-controlled config field with bounded setter checks and use a conservative value, not a point-in-time optimistic rate.

---

## 9. Fees

Fee model mirrors options/futures patterns:

* Create fee: charged from maker principal at series creation.
* Buy fee: charged from issuance payment flow.
* Redeem fee: charged from redemption payout flow.
* Reclaim fee: charged from maker principal on reclaim.

All fees route using existing treasury/ACI/FI split infrastructure.

---

## 10. Events

```solidity
event ZeroCouponSeriesCreated(
    uint256 indexed seriesId,
    bytes32 indexed makerPositionKey,
    uint256 indexed makerPositionId,
    uint256 poolId,
    address asset,
    uint256 issuePrice,
    uint256 faceValue,
    uint256 capUnits,
    uint64 issueStart,
    uint64 issueEnd,
    uint64 maturity,
    uint256 collateralLocked,
    uint256 maintenanceBuffer
);

event ZeroCouponPurchased(
    uint256 indexed seriesId,
    address indexed buyer,
    address indexed recipient,
    uint256 units,
    uint256 grossPayment,
    uint256 feePaid,
    uint256 netToMaker
);

event ZeroCouponRedeemed(
    uint256 indexed seriesId,
    address indexed holder,
    address indexed recipient,
    uint256 units,
    uint256 grossPayout,
    uint256 feePaid,
    uint256 netPaid
);

event ZeroCouponDefaulted(
    uint256 indexed seriesId,
    uint256 defaultPotRemaining,
    uint256 defaultUnitsRemaining
);

event ZeroCouponDefaultRecoveryClaimed(
    uint256 indexed seriesId,
    address indexed holder,
    address indexed recipient,
    uint256 units,
    uint256 amountPaid
);

event ZeroCouponReclaimed(
    uint256 indexed seriesId,
    bytes32 indexed makerPositionKey,
    uint256 unlockedCollateral
);
```

---

## 11. Invariants

Must always hold:

* `soldUnits <= capUnits`
* `redeemedUnits <= soldUnits`
* `status == Reclaimed => reclaimed == true`
* Normal redemption disabled when `status == Defaulted`
* `defaultPotRemaining` decreases monotonically by default claim payouts
* `defaultUnitsRemaining` decreases monotonically by default claim burns
* Collateral lock never negative
* Fee debits cannot exceed payer principal/payment amount

Pool accounting invariants:

* Every external transfer reduces corresponding `trackedBalance` (or is blocked).
* Principal/deposit debits and credits remain balanced with issuance/redemption economics.

---

## 12. Security and Risk Controls

* Product-level pause toggle.
* Maximum tenor cap.
* Maximum capUnits cap.
* Minimum discount and minimum face constraints to avoid dust griefing.
* Reentrancy guard on all state-mutating paths.
* Strict ownership/operator checks for maker-only actions.
* ERC-1155 operator checks for `redeemFor`.

---

## 13. View Functions

```solidity
function getZeroCouponSeries(uint256 seriesId) external view returns (DerivativeTypes.ZeroCouponSeries memory);
function getZeroCouponSeriesByPosition(bytes32 positionKey, uint256 offset, uint256 limit)
    external
    view
    returns (uint256[] memory ids, uint256 total);
function getZeroCouponSeriesByPositionId(uint256 positionId, uint256 offset, uint256 limit)
    external
    view
    returns (uint256[] memory ids, uint256 total);
function previewBuyCost(uint256 seriesId, uint256 units) external view returns (uint256 gross, uint256 fee, uint256 netToMaker);
function previewRedeemPayout(uint256 seriesId, uint256 units) external view returns (uint256 gross, uint256 fee, uint256 netToHolder);
function previewMaintenanceBuffer(uint256 seriesId) external view returns (uint256 projected, uint256 safety, uint256 total);
```

---

## 14. Test Acceptance Criteria

Minimum required tests:

1. `create`:
* rejects invalid windows/prices/cap.
* locks exact required collateral (base + buffer).

2. `buy`:
* only in issuance window.
* cannot exceed cap.
* mints exact units and credits maker principal correctly.

3. `redeem`:
* only post-maturity.
* checks funding sufficiency before burn.
* on insufficient funding, transitions to default without burning the attempted holder claims.
* on sufficient funding, burns claims and pays exact face minus fees.
* updates `soldUnits/redeemedUnits/collateralLocked` consistently.

4. `reclaim`:
* only after grace unlock.
* unlocks only `reclaimable = collateralLocked - requiredForOutstandingClaims`.
* cannot unlock collateral backing outstanding holder claims.

5. `default`:
* triggers deterministically on underfunded redemption.
* default recovery is pro-rata and bounded by `defaultPotRemaining`.
* each claim decreases both default remaining pot and default remaining units.

6. Access and pause:
* non-owner cannot reclaim.
* paused mode blocks create/buy/redeem.

7. Asset edge cases:
* fee-on-transfer token behavior.
* native asset behavior (`address(0)`).

8. Maintenance stress:
* long tenor with high maintenance rate does not break holder redemption when buffer is sufficient.

Recommended test files:

* `test/derivatives/ZeroCouponLifecycle.t.sol`
* `test/derivatives/ZeroCouponFacetProperty.t.sol`
* `test/derivatives/ZeroCouponDefaultRecovery.t.sol`
* `test/derivatives/ZeroCouponFeeOnTransfer.t.sol`
* `test/derivatives/ZeroCouponNativeAsset.t.sol`
* `test/derivatives/ZeroCouponMaintenanceBuffer.t.sol`

---

## 15. Rollout Plan

Phase 1:

* Single-asset series.
* Create/buy/redeem/reclaim.
* No cross-asset and no callable features.

Phase 2:

* Default recovery enhancements.
* Better health views and keeper hooks.

Phase 3:

* Callable/putable variants.
* Cross-asset notes with deterministic conversion rails.

---

## 16. Open Questions

* Should V1 permit managed pools, or only base permissionless pools?
* Should buy/redeem fees default to zero for simplicity at launch?
* Should claim expiry and treasury sweep of stale default claims be enabled in V1 or deferred?
* Should note unit granularity be fixed at `1` or configurable contract-size style?
