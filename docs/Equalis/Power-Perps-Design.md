# Power Perps with Hybrid Oracle/AMM TWAP - Design Specification

## Status

Draft (March 2026)

## Purpose

Specify an Equalis-native power perpetual implementation that:

* Uses a dedicated continuous AMM for on-chain price discovery.
* Uses robust AMM TWAP as primary discovery signal.
* Applies external oracle bounds as manipulation guardrails.
* Integrates with existing Perps account, margin, liquidation, and isolation rails.

This spec is implementation-oriented and designed to be additive to current `src/perps/*` architecture.

---

## 1. Scope

### 1.1 V1 In Scope

* Power perp markets where index is `S^p` (start with `p = 2`).
* New AMM facet for continuous discovery on power-perp pairs.
* New oracle facet that computes bounded hybrid mark from AMM TWAP + external oracle reference.
* Reuse existing perps execution/liquidation flows with market-level funding model switch.
* Deterministic fallback behavior on stale/or-divergent signals.

### 1.2 V1 Out of Scope

* Multi-hop or cross-market price aggregation.
* LP incentives/mining program design.
* Cross-collateral portfolio margining across perps markets.
* Full volatility-surface oracle for dynamic `p` products.

---

## 2. Design Goals

* Keep perps risk engine and isolation accounting unchanged where possible.
* Add discoverability without making AMM price a single point of failure.
* Prevent short-window AMM manipulation from controlling liquidation marks.
* Support graceful degradation: allow risk-reducing actions under degraded price quality.
* Keep market governance knobs explicit and auditable.

---

## 3. Product and Pricing Model

### 3.1 Power Index

For spot oracle price `S_t` (X18) and power parameter `pX18`:

* `index_t = powX18(S_t, pX18)`.

V1 default:

* `pX18 = 2e18` (squared exposure).

### 3.2 Hybrid Mark (Oracle + AMM TWAP)

Inputs:

* `ammTwap_t`: time-weighted AMM discovery price over governance window `W`.
* `oracleRef_t`: external reference price (adapter), with staleness/confidence checks.

Bounded mark:

* `lower = oracleRef_t * (10_000 - maxTwapOracleDivergenceBps) / 10_000`
* `upper = oracleRef_t * (10_000 + maxTwapOracleDivergenceBps) / 10_000`
* `mark_t = clamp(ammTwap_t, lower, upper)`

Fallback policy:

* If AMM TWAP invalid/stale/liquidity-insufficient, use `oracleRef_t`.
* If oracleRef invalid/stale, block increases; allow decreases/close-only.
* If both invalid, freeze trading and require admin/keeper intervention.

### 3.3 Funding for Power Markets

For power markets, use premium-based funding against power index:

* `premiumRatioX18 = (mark_t - index_t) / index_t`
* `velocityX18PerDay = clamp(fundingKX18 * premiumRatioX18, ±maxFundingVelocityX18PerDay)`
* `fundingDeltaX18 = velocityX18PerDay * elapsed / 1 days`

Settlement:

* Long cumulative index increases by `fundingDeltaX18`.
* Short cumulative index decreases by `fundingDeltaX18`.

This preserves existing long/short symmetry used in current cumulative funding settlement.

---

## 4. Architecture

### 4.1 New Facets

* `PowerPerpsAdminFacet` (new)
  * Market creation/config for power markets.
  * Risk, TWAP, oracle-band, and liquidity guard parameters.
  * Pause/circuit-breaker controls specific to discovery path.

* `PowerPerpsAmmFacet` (new)
  * Continuous AMM operations for discovery pair.
  * LP add/remove, swap, and observation updates.
  * Ring-buffered observations for TWAP computation.

* `PowerPerpsOracleFacet` (new)
  * Computes hybrid bounded mark from AMM TWAP + external oracle reference.
  * Implements `getMarkPrice(...)` compatible with existing perps oracle adapter interface.
  * Exposes market mark quality flags.

* `PowerPerpsViewFacet` (new)
  * Read-only state, TWAP windows, oracle diagnostics, and discovery health.

### 4.2 Existing Facets Reused

* `PerpsExecutionFacet`
* `PerpsLiquidationFacet`
* `PerpsViewFacet` (supplemented by power-specific view facet)

No separate execution path is required in V1; power markets remain first-class perps markets.

### 4.3 Supporting Libraries

* `LibPowerPerpsStorage` (new, isolated namespace)
* `LibPowerPerpsMath` (new: pow/log/twap helpers)
* `LibPowerPerpsDiscovery` (new: observation, TWAP, quality checks)
* `LibPowerPerpsFunding` (new: premium-based funding computation)

---

## 5. Storage Model

V1 uses an isolated storage root to avoid destabilizing current perps layout.

```solidity
library LibPowerPerpsStorage {
    bytes32 internal constant POWER_PERPS_STORAGE_POSITION =
        keccak256("equalis.perps.power.storage.v1");
}
```

Key state:

* Market-level power config (`p`, funding mode, divergence bands).
* AMM state (reserves, liquidity, fee config).
* Observation ring buffer for TWAP.
* Oracle health and last valid hybrid mark.
* Close-only / circuit-breaker flags.

---

## 6. Data Structures

```solidity
enum PowerFundingModel {
    SkewVelocity,      // compatibility mode
    PremiumToIndex     // default for power markets
}

struct PowerMarketConfig {
    bytes32 marketId;                  // ties to existing perps market
    uint256 pX18;                      // power exponent, 2e18 for squared
    uint32 twapWindowSec;              // e.g. 300-1800 sec
    uint16 minObservationCount;        // minimum samples in window
    uint32 maxObservationStaleness;    // max age of newest observation
    uint16 maxTwapOracleDivergenceBps; // clamp band around oracleRef
    uint256 minDiscoveryLiquidity;     // AMM liquidity floor for valid TWAP
    uint256 fundingKX18;               // funding gain factor
    uint256 maxFundingVelocityX18PerDay;
    PowerFundingModel fundingModel;
    bool exists;
    bool closeOnly;
}

struct PowerAmmState {
    uint256 reserveBase;               // index asset reserve
    uint256 reserveQuote;              // collateral quote reserve
    uint256 totalLpShares;
    uint16 swapFeeBps;
    uint64 lastObsTs;
    uint32 obsIndex;
    uint32 obsCount;
    bool paused;
}

struct TwapObservation {
    uint64 ts;
    uint192 priceCumulativeX18;        // cumulative (price * dt), packed
    uint192 liquidityCumulativeX18;    // cumulative liquidity-weight helper
}

struct HybridMarkResult {
    uint256 markPriceX18;              // final bounded mark
    uint256 ammTwapX18;                // raw AMM twap
    uint256 oracleRefX18;              // external ref
    uint256 indexPriceX18;             // S^p index
    uint256 updatedAt;
    uint256 deviationOrConfidenceBps;  // propagated for existing checks
    bool usedFallbackOracleOnly;
    bool isValid;
}
```

---

## 7. Interfaces

### 7.1 PowerPerpsAdminFacet

```solidity
function createPowerMarket(
    bytes32 marketId,
    uint256 pX18,
    uint32 twapWindowSec,
    uint16 minObservationCount
) external;

function setPowerFundingConfig(
    bytes32 marketId,
    uint256 fundingKX18,
    uint256 maxFundingVelocityX18PerDay,
    uint8 fundingModel
) external;

function setPowerDiscoveryGuards(
    bytes32 marketId,
    uint16 maxTwapOracleDivergenceBps,
    uint256 minDiscoveryLiquidity,
    uint32 maxObservationStaleness
) external;

function setPowerCloseOnly(bytes32 marketId, bool closeOnly) external;
function setPowerAmmPaused(bytes32 marketId, bool paused) external;
```

### 7.2 PowerPerpsAmmFacet

```solidity
function seedPowerAmm(
    bytes32 marketId,
    uint256 amountBase,
    uint256 amountQuote,
    address recipient
) external;

function addPowerLiquidity(
    bytes32 marketId,
    uint256 amountBaseMax,
    uint256 amountQuoteMax,
    address recipient
) external returns (uint256 sharesMinted);

function removePowerLiquidity(
    bytes32 marketId,
    uint256 shares,
    address recipient
) external returns (uint256 amountBase, uint256 amountQuote);

function swapPowerExactIn(
    bytes32 marketId,
    address tokenIn,
    uint256 amountIn,
    uint256 minOut,
    address recipient
) external returns (uint256 amountOut);

function pokePowerObservation(bytes32 marketId) external;
```

### 7.3 PowerPerpsOracleFacet

```solidity
function setPowerExternalOracleAdapter(bytes32 marketId, address adapter) external;

function getMarkPrice(bytes32 marketId, address indexAsset)
    external
    view
    returns (uint256 priceX18, uint256 updatedAt, uint256 deviationOrConfidenceBps);

function previewHybridMark(bytes32 marketId) external view returns (HybridMarkResult memory);
```

### 7.4 PowerPerpsViewFacet

```solidity
function getPowerMarketConfig(bytes32 marketId) external view returns (PowerMarketConfig memory);
function getPowerAmmState(bytes32 marketId) external view returns (PowerAmmState memory);
function getPowerObservation(bytes32 marketId, uint256 idx) external view returns (TwapObservation memory);
function getPowerMarkQuality(bytes32 marketId) external view returns (bool markValid, bool oracleFallback, bool closeOnly);
```

---

## 8. Lifecycle

### 8.1 Market Bootstrapping

1. Governance creates perps market through existing perps admin.
2. Governance creates power config through `PowerPerpsAdminFacet`.
3. Governance sets external oracle adapter.
4. AMM is seeded with initial balanced reserves.
5. Trading is enabled once observation minimum and liquidity thresholds are met.

### 8.2 Discovery and Mark Updates

1. Every AMM state mutation records/updates observation.
2. `pokePowerObservation` allows permissionless timestamp advancement when idle.
3. Hybrid mark is computed on demand by oracle facet:
   * read AMM TWAP over configured window.
   * read external oracle reference.
   * apply bounds and fallback policy.

### 8.3 Perps Execution/Liquidation

1. Existing execution/liquidation paths request mark through configured adapter.
2. Adapter resolves to `PowerPerpsOracleFacet.getMarkPrice`.
3. If returned mark quality is degraded:
   * increases blocked,
   * decreases/close allowed,
   * liquidations policy follows close-only flag.

### 8.4 Funding Updates

1. On funding sync, compute `index_t = S^p`.
2. Compute premium vs bounded mark.
3. Apply premium-based velocity caps and cumulative updates.
4. Settle per-position funding with existing cumulative-index pattern.

---

## 9. Risk Controls

* **TWAP minimum observations:** reject sparse windows.
* **Liquidity floor:** AMM TWAP invalid if discovery liquidity below threshold.
* **Oracle staleness/confidence gates:** fail closed on stale reference.
* **Divergence clamp:** AMM TWAP cannot exceed bounded distance from oracle reference.
* **Close-only mode:** deterministic emergency state.
* **Per-market pause flags:** independent AMM and perps toggles.
* **Tighter default risk params for power markets:**
  * lower max leverage,
  * stricter IM/MM,
  * tighter OI/skew caps.

---

## 10. Events

```solidity
event PowerMarketCreated(bytes32 indexed marketId, uint256 pX18, uint32 twapWindowSec);
event PowerFundingConfigUpdated(bytes32 indexed marketId, uint256 fundingKX18, uint256 maxVelocityX18PerDay, uint8 model);
event PowerDiscoveryGuardsUpdated(bytes32 indexed marketId, uint16 maxDivergenceBps, uint256 minLiquidity, uint32 maxObsStaleness);
event PowerExternalOracleSet(bytes32 indexed marketId, address indexed adapter);
event PowerCloseOnlyUpdated(bytes32 indexed marketId, bool closeOnly);
event PowerAmmPausedUpdated(bytes32 indexed marketId, bool paused);

event PowerAmmSeeded(bytes32 indexed marketId, uint256 amountBase, uint256 amountQuote, uint256 sharesMinted);
event PowerLiquidityAdded(bytes32 indexed marketId, address indexed provider, uint256 shares, uint256 amountBase, uint256 amountQuote);
event PowerLiquidityRemoved(bytes32 indexed marketId, address indexed provider, uint256 shares, uint256 amountBase, uint256 amountQuote);
event PowerSwap(bytes32 indexed marketId, address indexed trader, address tokenIn, uint256 amountIn, uint256 amountOut);
event PowerObservationUpdated(bytes32 indexed marketId, uint64 ts, uint256 priceX18);

event PowerHybridMarkComputed(bytes32 indexed marketId, uint256 markX18, uint256 ammTwapX18, uint256 oracleRefX18, bool fallbackOracleOnly);
```

---

## 11. Invariants

Must always hold:

* `markPriceX18 > 0` when market is trade-enabled.
* If AMM TWAP is used, it is computed from observations meeting count + staleness requirements.
* `markPriceX18` respects oracle clamp band unless operating in explicit fallback mode.
* Funding cumulative indices remain symmetric (`long += d`, `short -= d`).
* AMM reserve and LP share accounting conserve value across add/remove/swap (minus fees).
* Close-only mode blocks net risk increases.

Domain safety invariants (unchanged):

* Perps isolation backing and solvency checks remain enforced.
* Non-perps tracked balances are never consumed by perps losses.

---

## 12. Test Acceptance Criteria

Minimum required tests:

1. Hybrid mark composition:
* uses AMM TWAP in healthy mode.
* clamps to oracle band when TWAP diverges.
* falls back to oracle when TWAP quality fails.

2. Observation/TWAP:
* ring buffer windows compute deterministic TWAP.
* sparse windows or stale observations invalidate TWAP.

3. AMM discovery:
* add/remove liquidity preserves share invariants.
* swaps update observations and enforce slippage.

4. Execution coupling:
* perps execution reads hybrid mark via adapter.
* close-only mode blocks open/increase but allows decrease/close.

5. Funding:
* premium-based funding uses `mark - index`.
* velocity caps bound cumulative updates.
* long/short funding symmetry holds.

6. Risk controls:
* oracle stale/deviation failures trigger deterministic protection behavior.
* min-liquidity guard invalidates manipulated low-liquidity TWAP.

7. Security:
* pause/access checks across new facets.
* reentrancy-resistant AMM state mutations.

Recommended test files:

* `test/perps/PowerPerpsHybridOracleTwap.t.sol`
* `test/perps/PowerPerpsAmmFacet.t.sol`
* `test/perps/PowerPerpsFunding.t.sol`
* `test/perps/PowerPerpsCloseOnly.t.sol`
* `test/perps/PowerPerpsOracleFallback.t.sol`

---

## 13. Rollout Plan

Phase 1:

* Single power market (`p=2`) on one liquid index asset.
* Conservative leverage and OI caps.
* Governance/keeper monitoring dashboards.

Phase 2:

* Additional assets and configurable `p` values.
* Adaptive divergence bands by volatility regime.
* Keeper-driven automated close-only triggers.

Phase 3:

* Multi-source reference aggregation.
* Optional dynamic fair-value overlay (rate/vol aware).
* Cross-module integrations (e.g., structured products).

---

## 14. Open Questions

* Should `getMarkPrice` hard-fail on degraded quality, or always return price plus flags and let execution decide?
* Should AMM liquidity be permissionless from day one, or staged with approved LPs?
* Should close-only also pause liquidations, or keep liquidations always-on for safety?
* Should funding use pure premium-to-index only, or blend with skew-velocity for better inventory control?
* Should V1 keep `p` immutable per market to simplify risk and UX?
