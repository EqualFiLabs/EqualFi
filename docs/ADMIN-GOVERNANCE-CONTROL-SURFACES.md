# Admin & Governance Control Surfaces

> Comprehensive inventory of every privileged function across the Equalis protocol Diamond and satellite contracts.

---

## 1. Access Control Model

The protocol uses a two-tier privilege model anchored in the Diamond pattern:

| Role | Resolution | Scope |
|---|---|---|
| **Owner** | `LibDiamond.diamondStorage().contractOwner` | Diamond-wide. Single EOA/multisig. |
| **Timelock** | `LibAppStorage.s().timelock` | Diamond-wide. Intended for delayed governance. |
| **Owner OR Timelock** | `LibAccess.enforceOwnerOrTimelock()` | Most admin setters use this combined gate. |
| **Governor** (Atomic Escrow) | `LibAtomicStorage.atomicStorage().governor` | Scoped to SettlementEscrow. Falls back to Owner/Timelock if unset. |
| **ILM Isolated Owner** | `LibIlmIsolatedStorage.s().owner` | Scoped to ILM Isolated markets. Independent of Diamond owner. |
| **Pool Manager** | `PoolData.manager` (per managed pool) | Scoped to a single managed pool. Transferable, renounceable. |
| **Module Owner** | `Module.owner` (per module) | Scoped to a single registered module. Transferable. |
| **NFT Owner** (ERC-6900 MSCA) | TBA owner via ERC-6551 bound to Position NFT | Scoped to a single agent wallet skill module instance. |
| **Faucet Owner** | OpenZeppelin `Ownable` | Standalone Faucet contract. |

### Key Library Functions

```
LibAccess.enforceOwner()            → owner only
LibAccess.enforceOwnerOrTimelock()  → owner OR timelock
LibAccess.isOwnerOrTimelock(addr)   → boolean check
```

---

## 2. Diamond Core

### 2.1 OwnershipFacet (ERC-173)

| Function | Access | Effect |
|---|---|---|
| `transferOwnership(address)` | Owner | Transfers Diamond ownership. Single-step, no acceptance required. |

### 2.2 DiamondCutFacet

| Function | Access | Effect |
|---|---|---|
| `diamondCut(FacetCut[], address, bytes)` | Owner | Add/replace/remove facet selectors. Arbitrary code upgrade path. |

### 2.3 AdminGovernanceFacet — `executeDiamondCut`

| Function | Access | Effect |
|---|---|---|
| `executeDiamondCut(FacetCut[], address, bytes)` | Owner OR Timelock | Passthrough to `diamondCut`. Allows timelock-gated upgrades. |

### 2.4 DiamondInit

| Function | Access | Effect |
|---|---|---|
| `init(address timelock_, address positionNFT_)` | Delegatecall during `diamondCut` | Sets timelock address, wires PositionNFT minter/diamond. One-shot initializer. |

---

## 3. AdminFacet — Timelock Management

| Function | Access | Effect |
|---|---|---|
| `setTimelock(address)` | Owner | Replaces the timelock address. |

---

## 4. AdminGovernanceFacet — Protocol Parameters

All functions gated by `enforceOwnerOrTimelock()`.

### 4.1 Treasury & Fee Routing

| Function | Parameters | Effect |
|---|---|---|
| `setTreasury(address)` | Non-zero address | Global fee treasury address. |
| `setTreasuryShareBps(uint16)` | ≤ 10000, sum with ACI share ≤ 10000 | Treasury's share of fee-router splits. |
| `setActiveCreditShareBps(uint16)` | ≤ 10000, sum with treasury share ≤ 10000 | Active Credit Index share of fee-router splits. |
| `setManagedPoolSystemShareBps(uint16)` | ≤ 10000 | System share of managed pool fees routed to base pool. |
| `setFoundationReceiver(address)` | Non-zero address | AUM/maintenance fee receiver. |
| `setProtocolFeeReceiver(address)` | Non-zero address | EqualIndex protocol fee receiver. |

### 4.2 Pool Configuration

| Function | Parameters | Effect |
|---|---|---|
| `setDefaultPoolConfig(PoolConfig)` | Validated config | Global default config for permissionless pool creation. |
| `setPoolConfig(uint256 pid, PoolConfig)` | Validated config | Override any pool's config post-creation. |
| `setAumFee(uint256 pid, uint16 feeBps)` | Within pool's immutable min/max bounds | Adjust a pool's current AUM fee. |
| `setPoolDeprecated(uint256 pid, bool)` | — | UI deprecation flag (no functional effect). |

### 4.3 Lending Parameters

| Function | Parameters | Effect |
|---|---|---|
| `setRollingDelinquencyThresholds(uint8, uint8)` | Both > 0, penalty ≥ delinquent | Global rolling loan delinquency/penalty epoch thresholds. |
| `setRollingMinPaymentBps(uint16)` | ≤ 10000 | Minimum rolling loan payment as % of remaining principal. |

### 4.4 Maintenance Rates

| Function | Parameters | Effect |
|---|---|---|
| `setDefaultMaintenanceRateBps(uint16)` | ≤ maxMaintenanceRateBps | Default maintenance rate for new pools. |
| `setMaxMaintenanceRateBps(uint16)` | > 0 | Global ceiling for maintenance rates. |

### 4.5 Action Fees

| Function | Parameters | Effect |
|---|---|---|
| `setActionFeeBounds(uint128 min, uint128 max)` | min ≤ max, max > 0 | Global min/max bounds for per-action flat fees. |
| `setActionFeeConfig(uint256 pid, bytes32 action, uint128, bool)` | Within bounds if enabled | Per-pool per-action flat fee configuration. |

### 4.6 Creation Fees

| Function | Parameters | Effect |
|---|---|---|
| `setIndexCreationFee(uint256)` | — | Fee for permissionless index creation (0 = disabled). |
| `setPoolCreationFee(uint256)` | — | Fee for permissionless pool creation (0 = disabled). |
| `setPositionMintFee(address token, uint256 amount)` | — | Token + amount charged on position NFT minting. |

### 4.7 Derivative Fee Configuration

| Function | Parameters | Effect |
|---|---|---|
| `setDerivativeFeeConfig(...)` | 11 params: min/max/create/exercise/reclaim bps, maker shares, flat fees | Global derivative fee schedule for options/futures/auctions. |

### 4.8 Direct Lending Configuration

| Function | Parameters | Effect |
|---|---|---|
| `setDirectRollingConfig(DirectRollingConfig)` | Validated config | Rolling direct-offer bounds (payment interval, APY range, penalty, etc.). |

### 4.9 Position NFT

| Function | Parameters | Effect |
|---|---|---|
| `setPositionNFT(address)` | Contract address or zero | Rewires minter + diamond hooks on new PositionNFT. Zero disables NFT mode. |

### 4.10 Stable Mode

| Function | Parameters | Effect |
|---|---|---|
| `setStableModeEnabled(bool)` | — | Enable/disable stable invariant mode for new non-CL auction creation. |

---

## 5. FeeFacet — Per-Pool & Per-Index Action Fees

All functions gated by `enforceOwnerOrTimelock()`.

| Function | Parameters | Effect |
|---|---|---|
| `setPoolActionFee(uint256 pid, bytes32 action, uint128, bool)` | Validated against bounds | Per-pool per-action flat fee. |
| `setIndexActionFee(uint256 indexId, bytes32 action, uint128, bool)` | Validated against bounds | Per-index per-action flat fee. |
| `setActionFeeBounds(uint128 min, uint128 max)` | min ≤ max | Global action fee bounds (duplicate entry point alongside AdminGovernanceFacet). |

---

## 6. PointsAdminFacet — Points System

All functions gated by `enforceOwnerOrTimelock()`.

| Function | Parameters | Effect |
|---|---|---|
| `setPointsPerAction(bytes32 actionType, uint256 amount)` | Index weight invariant enforced | Points awarded per action type. |
| `setPointsPerActionBatch(bytes32[], uint256[])` | Batch variant with cross-validation | Batch update of points-per-action. |
| `setDailyPointsCap(uint256)` | — | Global daily points accrual cap. |
| `setAccrualCooldown(bytes32 actionType, uint256 secs)` | — | Per-action cooldown between accruals. |
| `setRedemptionToken(address)` | — | ERC-20 token used for points redemption. |
| `setRedemptionEnabled(bool)` | — | Toggle points redemption on/off. |
| `setRedemptionRate(uint256 tokensPerPointWad)` | — | Exchange rate for points → tokens. |
| `setRedemptionGlobalMintCap(uint256)` | — | Global cap on redeemed token minting. |
| `setRedemptionEpochConfig(uint64 epochLength, uint256 epochCap)` | — | Per-epoch redemption rate limiting. |

---

## 7. EqualIndex Admin (EqualIndexAdminFacetV3)

### 7.1 Timelock-Only Functions

| Function | Access | Effect |
|---|---|---|
| `setIndexFees(uint256 indexId, uint16[], uint16[], uint16)` | Timelock | Per-asset mint/burn fees and flash fee for an index. |
| `setPaused(uint256 indexId, bool)` | Timelock | Pause/unpause an index (blocks mint/burn/flash). |
| `setPoolFeeShareBps(uint16)` | Timelock | Share of flash loan fees routed through pool fee router. |
| `setMintBurnFeeIndexShareBps(uint16)` | Timelock | Share of mint/burn fees routed through pool fee router. |

### 7.2 Index Creation

| Function | Access | Effect |
|---|---|---|
| `createIndex(CreateIndexParams)` | Anyone (fee-gated) / Owner+Timelock (free) | Creates a new index + underlying pool. Governance callers skip creation fee. |

### 7.3 EqualIndex Lending Configuration

| Function | Access | Effect |
|---|---|---|
| `configureLending(uint256 indexId, uint16 ltvBps, uint16 originationFeeBps, uint40 minDuration, uint40 maxDuration)` | Timelock | Configure lending parameters for an index. |

---

## 8. Module Registry (ModuleRegistryFacet)

### 8.1 Owner/Timelock Functions

| Function | Access | Effect |
|---|---|---|
| `setModuleCreationFee(uint256)` | Owner OR Timelock | Fee for permissionless module registration (0 = disabled). |
| `setDefaultModuleAumBps(uint16)` | Owner OR Timelock | Default AUM fee for new modules. |
| `setModuleAumBps(uint256 moduleId, uint16)` | Owner OR Timelock | Override AUM fee for a specific module. |
| `setModuleAumBounds(uint16 min, uint16 max)` | Owner OR Timelock | Global min/max bounds for module AUM fees. |
| `setModuleDeactivationGraceEpochs(uint16)` | Owner OR Timelock | Grace period before module auto-deactivation. |
| `setModuleAciPaused(bool)` | Owner OR Timelock | Pause Active Credit Index updates from module encumbrance. |

### 8.2 Module Owner Functions

| Function | Access | Effect |
|---|---|---|
| `setModuleOwner(uint256 moduleId, address)` | Module Owner | Transfer module ownership. |
| `pauseModule(uint256 moduleId)` | Module Owner OR Governance | Pause a module (blocks new encumbrance). |
| `unpauseModule(uint256 moduleId)` | Module Owner OR Governance | Unpause a module (blocked if inactive). |

### 8.3 Module Registration

| Function | Access | Effect |
|---|---|---|
| `registerModule(bytes32 metadataHash)` | Anyone (fee-gated) / Governance (free) | Register a new module. |

---

## 9. Pool Management (PoolManagementFacet)

### 9.1 Pool Initialization

| Function | Access | Effect |
|---|---|---|
| `initPool(uint256 pid, address, PoolConfig)` | Owner OR Timelock | Initialize pool with explicit config. |
| `initPoolWithActionFees(uint256 pid, address, PoolConfig, ActionFeeSet)` | Owner OR Timelock | Initialize pool with config + action fees. |
| `initPool(address underlying)` | Anyone (fee-gated) | Permissionless pool creation using global defaults. |
| `initManagedPool(uint256 pid, address, PoolConfig)` | Anyone (fee-gated) | Create a managed pool. Caller becomes manager. |

### 9.2 Managed Pool Manager Functions

All gated by `_enforceManager(pid)` — only the pool's designated manager.

| Function | Parameters | Effect |
|---|---|---|
| `setRollingApy(uint256 pid, uint16)` | ≤ 10000 | Pool rolling APY. |
| `setDepositorLTV(uint256 pid, uint16)` | 1–10000 | Pool depositor LTV ratio. |
| `setMinDepositAmount(uint256 pid, uint256)` | > 0 | Minimum deposit. |
| `setMinLoanAmount(uint256 pid, uint256)` | > 0 | Minimum loan. |
| `setMinTopupAmount(uint256 pid, uint256)` | > 0 | Minimum top-up. |
| `setDepositCap(uint256 pid, uint256)` | > 0 | Deposit cap. |
| `setIsCapped(uint256 pid, bool)` | — | Toggle deposit cap enforcement. |
| `setMaxUserCount(uint256 pid, uint256)` | — | Max users in pool. |
| `setMaintenanceRate(uint256 pid, uint16)` | ≤ global max | Pool maintenance rate. |
| `setFlashLoanFee(uint256 pid, uint16)` | ≤ 10000 | Flash loan fee. |
| `setActionFees(uint256 pid, ActionFeeSet)` | Within global bounds | Pool action fees. |
| `addToWhitelist(uint256 pid, uint256 tokenId)` | — | Whitelist a position. |
| `removeFromWhitelist(uint256 pid, uint256 tokenId)` | — | Remove from whitelist. |
| `setWhitelistEnabled(uint256 pid, bool)` | — | Toggle whitelist gating. |
| `transferManager(uint256 pid, address)` | Non-zero | Transfer manager role. |
| `renounceManager(uint256 pid)` | — | Permanently renounce manager role (irreversible). |

---

## 10. EqualX / Derivatives

### 10.1 Pause Controls

| Function | Access | Effect |
|---|---|---|
| `setAmmPaused(bool)` | Owner OR Timelock | Pause/unpause all AMM auction creation + swaps. |
| `setMamPaused(bool)` | Owner OR Timelock | Pause/unpause all MAM curve creation. |
| `setAtomicPaused(bool)` | Owner OR Timelock | Pause/unpause all Atomic Desk operations. |

### 10.2 Atomic Desk

| Function | Access | Effect |
|---|---|---|
| `setTakerTranchePostingFee(uint256 feeWei)` | Owner OR Timelock | Fee for posting taker tranches. |

### 10.3 Settlement Escrow (Governor-Gated)

The `onlyGovernor` modifier falls back to Owner/Timelock if no governor is set.

| Function | Access | Effect |
|---|---|---|
| `setCommittee(address, bool)` | Governor | Add/remove committee members. |
| `configureMailbox(address)` | Governor | Set the Mailbox contract address. |
| `configureAtomicDesk(address)` | Governor | Set the AtomicDesk contract address. |
| `transferGovernor(address)` | Governor | Transfer governor role. |
| `setRefundSafetyWindow(uint64)` | Governor | Refund safety window duration. |

---

## 11. ILM Pooled (ILMPooledAdminFacet)

All functions gated by `_onlyGovernance()` — same Owner/Timelock check as Diamond core but implemented independently.

| Function | Parameters | Effect |
|---|---|---|
| `createPooledMarket(IlmCreateParams)` | Validated risk params | Create a new ILM pooled market. |
| `setPooledMarketFlags(uint256 marketId, bool active, bool paused, bool frozen)` | — | Toggle market active/paused/frozen state. |
| `setPooledMarketCaps(uint256 marketId, uint256 supply, uint256 borrow)` | — | Supply and borrow caps. |
| `setPooledRiskParams(uint256 marketId, uint16 ltv, uint16 liqThreshold, uint16 liqBonus, uint16 liqProtocolFee)` | Validated against global bounds | Risk parameters per market. |
| `setPooledRateStrategy(uint256 marketId, uint16 reserveFactor, uint16 optimalUtil, uint32 base, uint32 slope1, uint32 slope2)` | Validated against global bounds | Interest rate model parameters. |
| `setPooledOracleAdapter(address)` | — | Oracle adapter contract. |
| `setPooledSentinelAdapter(address)` | — | Sentinel adapter contract. |
| `setPooledGlobalBounds(uint16 minLtv, uint16 maxLtv, uint16 minReserveFactor, uint16 maxReserveFactor)` | Validated | Global bounds for LTV and reserve factor. |

---

## 12. ILM Isolated (ILMIsolatedAdminFacet)

Uses its own `owner` field in `LibIlmIsolatedStorage`, independent of Diamond owner.

### 12.1 ILM Isolated Owner Functions

| Function | Access | Effect |
|---|---|---|
| `enableIrm(address)` | ILM Owner | Whitelist an interest rate model. |
| `setIrmManagedOnly(address irm, bool)` | ILM Owner | Restrict an IRM to managed-pool markets only. |
| `enableLltv(uint256)` | ILM Owner | Whitelist a liquidation LTV value. |
| `setFee(bytes32 marketId, uint256)` | ILM Owner | Set protocol fee for a market (accrues interest first). |
| `setFeeRecipientPositionKey(bytes32)` | ILM Owner | Deprecated fee recipient (retained for compatibility). |
| `setMarketLiquidationFeeBps(bytes32 marketId, uint16)` | ILM Owner | Per-market liquidation fee. |
| `setMaxStaleness(uint256)` | ILM Owner | Oracle staleness threshold. |
| `setOwner(address)` | ILM Owner | Transfer ILM Isolated ownership. |

### 12.2 Market Creation

| Function | Access | Effect |
|---|---|---|
| `createIlmIsolatedMarket(MarketParams, uint256 moduleId)` | Anyone (IRM + LLTV must be whitelisted; managed-only IRMs require pool manager or ILM owner) | Create a new isolated market. |

### 12.3 Position-Level Authorization

| Function | Access | Effect |
|---|---|---|
| `setAuthorization(bytes32 positionKey, address operator, bool)` | Position NFT Owner | Authorize an operator for a position in ILM Isolated. |

---

## 13. Position Agent / Agent Wallet

### 13.1 PositionAgentConfigFacet (ERC-6551)

All gated by Owner/Timelock + `_requireMutableConfig()` (config locks after first TBA deployment).

| Function | Access | Effect |
|---|---|---|
| `setERC6551Registry(address)` | Owner OR Timelock | ERC-6551 registry contract. Locked after first TBA deploy. |
| `setERC6551Implementation(address)` | Owner OR Timelock | TBA implementation contract. Locked after first TBA deploy. |
| `setIdentityRegistry(address)` | Owner OR Timelock | ERC-8004 identity registry. Locked after first TBA deploy. |

### 13.2 PositionNFT (Standalone Contract)

| Function | Access | Effect |
|---|---|---|
| `setMinter(address)` | Current minter (or anyone if minter == 0) | Authorize a new minter. |
| `setDiamond(address)` | Current minter (or anyone if diamond == 0) | Set Diamond address for pool data queries + transfer hooks. |

### 13.3 PositionAgentAmmSkillModule (ERC-6900)

All gated by `_requireOwner()` — the MSCA account owner (Position NFT holder).

| Function | Access | Effect |
|---|---|---|
| `setDiamond(address)` | MSCA Owner | Set Diamond address for delegated calls. |
| `setAuctionPolicy(AuctionPolicy)` | MSCA Owner | Configure auction creation/management policy bounds. |
| `setRollPolicy(RollPolicy)` | MSCA Owner | Configure yield-roll policy. |
| `setAllowedPool(uint256 poolId, bool)` | MSCA Owner | Allowlist pools for agent operations. |

---

## 14. Faucet (Standalone Contract)

Gated by OpenZeppelin `onlyOwner`.

| Function | Access | Effect |
|---|---|---|
| `setToken(address, uint256, bool)` | Owner | Add/update token configuration. |
| `setTokenAmount(address, uint256)` | Owner | Update claim amount for existing token. |
| `setTokenEnabled(address, bool)` | Owner | Enable/disable a token. |
| `withdraw(address token, address to, uint256)` | Owner | Withdraw tokens from faucet. |

---

## 15. Summary: Critical Risk Surface

### Highest Impact (Protocol-Wide)

1. **`diamondCut` / `executeDiamondCut`** — Arbitrary code upgrade. Can replace any facet logic.
2. **`transferOwnership`** — Single-step ownership transfer with no acceptance. No timelock.
3. **`setTimelock`** — Owner-only, can remove timelock entirely.
4. **`setDefaultPoolConfig` / `setPoolConfig`** — Can alter lending terms for all existing/future pools.
5. **`setDerivativeFeeConfig`** — Controls all derivative fee parameters globally.

### Medium Impact (Subsystem-Scoped)

6. **ILM Isolated `setOwner`** — Independent ownership chain; compromise doesn't require Diamond owner.
7. **Settlement Escrow `transferGovernor`** — Independent governor chain for atomic swap escrow.
8. **`setPositionNFT`** — Rewires the entire position identity system.
9. **PositionAgentConfigFacet** — Config locks after first TBA deploy, but before that, can redirect agent wallet infrastructure.
10. **`setPoolDeprecated`** — UI-only flag, but could mislead users.

### Design Observations

- The protocol has **no renounce-ownership** path for the Diamond itself. Ownership can only be transferred, never burned.
- **ILM Isolated** maintains a separate owner from the Diamond, creating two independent privilege chains.
- **Settlement Escrow governor** is a third independent privilege chain that falls back to Diamond owner/timelock.
- **Managed pool managers** have broad config authority within their pool but cannot affect other pools or global state.
- **Module owners** can pause their own modules but governance can also pause any module.
- **PositionNFT `setMinter`** has a bootstrap vulnerability: if `minter == address(0)`, anyone can claim the minter role.
- All EqualIndex admin functions use `onlyTimelock` (not `enforceOwnerOrTimelock`), meaning the Diamond owner alone cannot modify index parameters — only the timelock can.

---

## 16. Walkaway Test Assessment

> *Can the protocol founders disappear and the system continues to function indefinitely without any privileged intervention?*

### 16.1 Ossification Tiers

The governance surface divides into three tiers based on how readily each can be permanently frozen.

**Tier 1 — Freeze-Ready (one-time setup, then remove selectors)**

These are configuration parameters that, once dialed in, never need to change. A final `diamondCut` can remove their selectors entirely.

- `AdminFacet` — `setTimelock`
- `AdminGovernanceFacet` — `setDefaultPoolConfig`, `setDerivativeFeeConfig`, `setDirectRollingConfig`, `setActionFeeBounds`, `setActionFeeConfig`, `setDefaultMaintenanceRateBps`, `setMaxMaintenanceRateBps`, `setTreasury`, `setFoundationReceiver`, `setProtocolFeeReceiver`, `setTreasuryShareBps`, `setActiveCreditShareBps`, `setManagedPoolSystemShareBps`, `setStableModeEnabled`, `setIndexCreationFee`, `setPoolCreationFee`, `setPositionMintFee`, `setPositionNFT`, `setPoolDeprecated`, `setRollingDelinquencyThresholds`, `setRollingMinPaymentBps`
- `PointsAdminFacet` — all functions (set config, then freeze)
- `FeeFacet` — `setPoolActionFee`, `setIndexActionFee`, `setActionFeeBounds`
- `EqualIndexAdminFacetV3` — `setIndexFees`, `setPaused`, `setPoolFeeShareBps`, `setMintBurnFeeIndexShareBps`
- `EqualIndexLendingFacet` — `configureLending`
- `ModuleRegistryFacet` — `setModuleCreationFee`, `setDefaultModuleAumBps`, `setModuleAumBounds`, `setModuleDeactivationGraceEpochs`, `setModuleAciPaused`
- `PositionAgentConfigFacet` — already self-locks via `tbaConfigLocked` after first TBA deploy
- EqualX pause toggles — `setAmmPaused`, `setMamPaused`, `setAtomicPaused` (set to unpaused, then remove)
- `AtomicDeskFacet` — `setTakerTranchePostingFee`

**Tier 2 — Requires a deprecation path, then freezable**

These are structural governance functions that need a planned removal sequence.

- `DiamondCutFacet` / `executeDiamondCut` — the master upgrade path. Removed via a final self-removing `diamondCut` that strips the selector.
- `OwnershipFacet` — `transferOwnership` removed in the same final cut.
- `PositionNFT` — needs a `lockMinter()` function added to permanently freeze the minter/diamond addresses. Currently has a bootstrap vulnerability where `minter == address(0)` allows anyone to claim.
- `SettlementEscrowFacet` governor functions — `transferGovernor`, `setCommittee`, `configureMailbox`, `configureAtomicDesk`, `setRefundSafetyWindow`. These can freeze once the atomic swap infrastructure is stable, but the governor chain needs an explicit renunciation path.
- `ILM Isolated` — `enableIrm`, `enableLltv`, `setMaxStaleness` are finite enumerable sets that can be fully populated then frozen. `setOwner` needs a renunciation path. Per-market `setFee` and `setMarketLiquidationFeeBps` are harder — they're operational, but could be set once per market at creation and then frozen if the admin facet selectors are removed.

**Tier 3 — Structurally resistant to ossification**

These require ongoing human judgment and cannot be frozen without a fundamental redesign.

- `ILMPooledAdminFacet` — all 8 functions. The Aave-style shared-liquidity model inherently requires a risk curator. Someone must adjust LTV/liquidation thresholds during market volatility, update oracle adapters when price feeds change, freeze markets during depegs, and tune interest rate strategies. This is not a bug in the implementation — it is intrinsic to pooled lending architecture.

### 16.2 The ILM Pooled Question

ILM Pooled (Aave v3 architecture adapted for encumbrance) is the single largest governance anchor in the protocol. Removing it would make the entire system freezable. Keeping it creates a permanent governance dependency.

**Arguments for keeping ILM Pooled:**

- Shared-liquidity pools attract more TVL — LPs get exposure to multiple borrowing markets from a single deposit position.
- Borrowers in ILM Pooled markets earn Active Credit Index yield, creating a net effective borrowing cost of `nominal_rate - ACI_yield`. This is a structural advantage over Aave where borrowing is a pure cost.
- The governance cost is scoped — ILM Pooled uses its own `_onlyGovernance()` check and its admin surface is contained to a single facet. It does not infect the rest of the protocol.
- The Diamond pattern allows removing ILM Pooled selectors via `diamondCut` at any future point if the governance cost proves unjustifiable.

**Arguments against:**

- It is the only subsystem that prevents full protocol ossification.
- ILM Isolated (Morpho Blue architecture) already provides lending functionality with a permissionless market creation model that requires no ongoing governance.
- Maintaining two lending architectures doubles the audit surface and cognitive overhead.
- The ACI yield advantage applies equally to ILM Isolated borrowers — it is not unique to the pooled model.

**Current decision: keep ILM Pooled.** The market differentiation value (shared liquidity + ACI rebates) justifies the governance cost for now. The Diamond architecture ensures this is a reversible decision — a single `diamondCut` can remove the `ILMPooledAdminFacet` and related selectors if the protocol later decides to fully ossify.

### 16.3 Market Differentiation Through Governance Minimization

The Active Credit Index mechanic is the protocol's core differentiator against both Aave and Morpho:

- **vs. Aave**: Borrowers earn ACI yield, reducing effective borrowing cost. Fee revenue flows mechanically to encumbered positions rather than to a DAO treasury subject to political capture. The Aave Labs treasury incident demonstrates the failure mode that ACI's mechanical distribution avoids.
- **vs. Morpho**: Morpho Blue achieves governance minimization but offers no fee-sharing with borrowers. Equalis matches Morpho's permissionless market creation (via ILM Isolated) while adding ACI yield that Morpho's architecture cannot replicate without a ground-up redesign.

The ACI flywheel: more protocol activity → more fees → higher ACI yield → lower effective borrowing cost → more borrowers → more activity. This is funded by real protocol revenue, not inflationary token emissions.

### 16.4 Ossification Roadmap

The path to maximum walkaway readiness:

1. **Now**: Ship with all governance surfaces active. Tune parameters through mainnet operation.
2. **Stabilization**: Once parameters are battle-tested, add `lockMinter()` to PositionNFT and a governor renunciation path to SettlementEscrow.
3. **Progressive freeze**: Remove Tier 1 selectors via `diamondCut` — `AdminFacet`, `AdminGovernanceFacet`, `PointsAdminFacet`, `FeeFacet` admin functions, EqualIndex admin functions.
4. **Final cut**: Remove `DiamondCutFacet`, `OwnershipFacet`, and `executeDiamondCut` selectors in a single self-removing diamond cut. This is irreversible.
5. **Evaluate ILM Pooled**: If ILM Isolated proves sufficient for market needs, remove ILM Pooled selectors before or during the final cut. If Pooled markets have meaningful adoption, retain them as the sole remaining governed subsystem.

After step 4, the only remaining governance surface (if ILM Pooled is retained) is scoped to pooled market risk management — a single facet with 8 functions, isolated from all other protocol operations.
