# Equalis Protocol — Complete Product Catalog

**Last updated:** March 2026

This document catalogs every product offered by the Equalis protocol, sourced from both the codebase (`src/`) and design documentation (`docs/`). Each product includes its status, source location, and a description of what it does.

Status legend:
- 🟢 **Shipped** — Implemented in `src/`, tested, production-ready
- 🟡 **In Progress** — Partially implemented or actively being built
- 🔵 **Designed** — Design doc or spec exists, not yet implemented in `src/`

---

## 1. Core Infrastructure

### 1.1 Diamond Proxy Architecture 🟢

**Source:** `src/core/Diamond.sol`, `src/core/DiamondCutFacet.sol`, `src/core/DiamondInit.sol`, `src/core/DiamondLoupeFacet.sol`, `src/core/OwnershipFacet.sol`

Single upgradeable proxy contract implementing EIP-2535. All protocol products are deployed as facets on this diamond. Supports facet introspection (Loupe), ownership transfer, and atomic multi-facet upgrades via DiamondCut.

### 1.2 Position NFT (ERC-721) 🟢

**Source:** `src/nft/PositionNFT.sol`, `src/views/PositionNFTMetadataFacet.sol`

Portable, composable account container. Each Position NFT holds all deposits, loans, encumbrances, and yield entitlements across every protocol venue. Transferring the NFT transfers the entire financial position. Includes on-chain generative cypherpunk SVG art metadata (ERC-8004 compatible `getAgentURI`).

### 1.3 Encumbrance Engine 🟢

**Source:** `src/libraries/LibModuleEncumbrance.sol`, `src/libraries/LibActiveCreditIndex.sol`
**Docs:** `docs/Equalis/Module-Encumbrance-Design.md`

Per-position, per-pool reservation system that isolates risk across concurrent activities. When a module (AMM auction, option, loan, perps market) uses capital from a position, it encumbers that specific amount. Other modules see reduced available principal. Prevents double-spending of collateral without moving tokens between contracts.

### 1.4 Unified Fee System (FeeIndex) 🟢

**Source:** `src/core/FeeFacet.sol`, `src/libraries/LibFeeIndex.sol`, `src/libraries/LibFeeRouter.sol`, `src/libraries/LibFeeTreasury.sol`
**Docs:** `docs/Equalis/FeeSources-Design.md`

Single per-token fee rail aggregating revenue from all protocol activity. Every fee generated anywhere — lending interest, swap fees, option premiums, auction fills, module AUM charges — flows into one index. Passive depositors earn from all activity in their token across every venue. The FeeFacet provides governance-configurable per-pool, per-action fee amounts with global bounds enforcement.

Fee routing splits three ways:
- Fee Index → passive depositors
- Active Credit Index → active participants (borrowers, lenders)
- Treasury → protocol revenue

### 1.5 Pool AUM Fee (Maintenance System) 🟢

**Source:** `src/core/MaintenanceFacet.sol`, `src/libraries/LibMaintenance.sol`
**Docs:** `docs/Equalis/AUM-System-Design.md`

Annualized fee on all pool deposits accruing regardless of activity. Charged in daily epochs against `totalDeposits` (excluding index-encumbered capital). The fee reduces all user principals proportionally via a negative maintenance index — effectively a protocol-wide haircut on deposited capital. Accrued fees accumulate as `pendingMaintenance` and are paid out directly to the `foundationReceiver` (not through LibFeeRouter). Permissionless `pokeMaintenance` triggers accrual; `settleMaintenance` forces immediate payout. Per-pool `currentAumFeeBps` is governance-adjustable within immutable bounds (`aumFeeMinBps`/`aumFeeMaxBps`) set at pool creation.

### 1.6 Module AUM Fee 🟢

**Source:** `src/libraries/LibModuleAum.sol`, `src/modules/ModuleGatewayFacet.sol`
**Docs:** `docs/Equalis/AUM-System-Design.md`

Separate AUM fee charged on capital encumbered by external modules. Accrues in daily epochs proportional to the module's `aumBps` and the amount of encumbered principal. Charged from the position's principal and routed through `LibFeeTreasury` → `LibFeeRouter.routeManagedShare()` (three-way split: fee index, active credit index, treasury). Modules that cannot cover their AUM fee are marked delinquent; persistent delinquency beyond a grace period triggers permanent module deactivation.

### 1.7 Points / Proof of Participation (PoP) 🟢

**Source:** `src/points/PointsRedemptionFacet.sol`, `src/admin/PointsAdminFacet.sol`, `src/views/PointsViewFacet.sol`, `src/libraries/LibPoints.sol`
**Docs:** `docs/Equalis/PoP-Design.md`

On-chain participation accounting for future token emissions. Points accrue to positions and wallets based on protocol actions (flash loans, deposits, borrows, etc.). Redeemable for emission tokens via `redeem` or `redeemFromPosition` with slippage protection. Admin-configurable emission rates and redemption curves.

### 1.8 Action Fee System 🟢

**Source:** `src/core/FeeFacet.sol`

Configurable per-pool, per-action fees with governance-set bounds. Supports both pool-level and index-level action fees. Preview functions allow users to estimate fees before execution. Fees can be enabled/disabled per action type.

---

## 2. Lending Products

### 2.1 EqualLend — Self-Secured Credit 🟢

**Source:** `src/equallend/LendingFacet.sol`, `src/equallend/PenaltyFacet.sol`, `src/equallend/PoolManagementFacet.sol`, `src/equallend/PositionManagementFacet.sol`
**Docs:** `docs/Equalis/SelfSecuredCredit-Design.md`

Oracle-free, deterministic lending where users borrow against their own deposits. No liquidations, no utilization curves. Borrowers can only lose what they deposited. Includes:
- Position minting with optional initial deposit
- Deposit/withdraw with solvency checks
- Pool membership management and cleanup
- Yield roll between pools
- Penalty system for delinquent rolling and fixed-term loans with enforcer rewards
- Configurable pool parameters (LTV, APY, deposit caps, min amounts, user limits)

### 2.2 EqualLend Direct — P2P Term Loans 🟢

**Source:** `src/equallend-direct/EqualLendDirectOfferFacet.sol`, `src/equallend-direct/EqualLendDirectAgreementFacet.sol`, `src/equallend-direct/EqualLendDirectAgreementRatioFacet.sol`, `src/equallend-direct/EqualLendDirectLifecycleFacet.sol`, `src/equallend-direct/LibDirectExercise.sol`
**Docs:** `docs/Equalis/Equalis-Direct.md`

Peer-to-peer fixed-term lending between any assets without price oracles. Lenders set their own terms. Features:
- Offer creation and acceptance
- Ratio tranche offers (CLOB-style partial fills)
- American-style early exercise
- Configurable prepayment terms
- Loan lifecycle management (repay, extend, recover expired)

### 2.3 EqualLend Direct Rolling — P2P Rolling Credit 🟢

**Source:** `src/equallend-direct/EqualLendDirectRollingOfferFacet.sol`, `src/equallend-direct/EqualLendDirectRollingAgreementFacet.sol`, `src/equallend-direct/EqualLendDirectRollingLifecycleFacet.sol`, `src/equallend-direct/EqualLendDirectRollingPaymentFacet.sol`
**Docs:** `docs/Equalis/Equalis-Direct.md`

Peer-to-peer rolling credit with periodic payments, arrears tracking, amortization, and grace periods. Open-ended credit lines that roll forward until closed.

### 2.4 Managed Pools 🟢

**Source:** `src/equallend/PoolManagementFacet.sol` (`initManagedPool`)
**Docs:** `docs/Equalis/ManagedPool-Design.md`

Delegated pool administration for institutions, DAOs, and strategy vaults. Features:
- Manager-controlled pool parameters
- Whitelist gating (position-level access control)
- System-share fee routing from managed pool to base pool
- Manager transfer and renounce
- Configurable fixed-term loan configurations

### 2.5 Flash Loans 🟢

**Source:** `src/equallend/FlashLoanFacet.sol`

Uncollateralized single-transaction loans from any pool. Features:
- Configurable per-pool fee (basis points)
- Anti-split protection (prevents fee splitting across multiple calls in same block)
- Fee-on-transfer token support
- Callback pattern (`IFlashLoanReceiver.onFlashLoan`)
- Fee accrual to pool tracked balance with treasury routing
- Points accrual for flash loan usage

---

## 3. Trading / Exchange Products

### 3.1 AMM Auctions 🟢

**Source:** `src/EqualX/AmmAuctionFacet.sol`, `src/views/AmmAuctionViewFacet.sol`, `src/views/AuctionManagementViewFacet.sol`
**Docs:** `docs/Equalis/AMM-Auction-Design.md`

Time-bounded automated market maker pools with constant-product pricing. Position-backed reserves via encumbrance. Features:
- Auction creation with configurable parameters
- Bidirectional swaps (A↔B)
- Liquidity addition by maker
- Auction finalization and cancellation
- Maker fee earning from swap activity

### 3.2 MAM Curves (Maker Auction Markets) 🟢

**Source:** `src/EqualX/MamCurveCreationFacet.sol`, `src/EqualX/MamCurveExecutionFacet.sol`, `src/EqualX/MamCurveManagementFacet.sol`, `src/EqualX/MamCurveFacet.sol`, `src/views/MamCurveViewFacet.sol`
**Docs:** `docs/Equalis/MAM-Curve-Design.md`

Time-varying Dutch auction price curves for selling assets. Features:
- Curve creation with start/end price and duration
- Pluggable curve profiles (see §3.4)
- Commit-bound swap execution (generation + commitment checks prevent front-running)
- Curve management (update pricing, pause, cancel)
- Batch quote previews
- Packed snapshot events for indexer consumption

### 3.3 Community Auctions 🟢

**Source:** `src/EqualX/CommunityAuctionFacet.sol`, `src/views/CommunityAuctionViewFacet.sol`
**Docs:** `docs/Equalis/Community-Auction-Design.md`

Multi-maker community liquidity auctions. Multiple participants contribute liquidity to a shared auction pool. Supports join mechanics and shared finalization.

### 3.4 MAM Curve Profiles 🟢

**Source:** `src/profiles/DefaultLinearProfile.sol`, `src/interfaces/ICurveProfile.sol`, `src/libraries/LibMamProfile.sol`, `src/libraries/LibMamCurveSnapshot.sol`
**Spec:** `.kiro/specs/mam-curve-profiles/`

Pluggable pricing profile system for MAM curves. Governance-approved external contracts implement `ICurveProfile.computePrice` to define custom price trajectories. Ships with:
- Built-in linear profile (profile ID 1) — delegates to `LibMamMath`
- `DefaultLinearProfile` — standalone contract implementing `ICurveProfile`
- Profile registry (approve/revoke) gated by governance
- Per-curve profile storage with `profileParams` for custom configuration
- Staticcall-based execution for safety

### 3.5 Stable/Volatile Auction Modes 🟢

**Source:** `src/libraries/DerivativeTypes.sol` (`InvariantMode` enum), `src/libraries/LibAuctionSwap.sol` (stable swap math)
**Spec:** `.kiro/specs/stable-volatile-auction-modes/`

Invariant mode selection for AMM and Community auctions. Makers choose `Volatile` (constant-product) or `Stable` (stable-swap `x³y + y³x` invariant with Newton's method iterative solver) at creation time. Mode is immutable per auction. Stable mode uses decimal normalization to 1e18 domain, bounded iteration (max 255), and reverts on non-convergence. Gated by `stableModeEnabled` governance flag on `DerivativeConfig`.

---

## 4. Derivatives

### 4.1 Options (ERC-1155) 🟢

**Source:** `src/derivatives/OptionsFacet.sol`, `src/derivatives/OptionToken.sol`, `src/views/DerivativeViewFacet.sol`
**Docs:** `docs/Equalis/ERC1155-OPTIONS.md`, `docs/Equalis/Derivatives-Design.md`

Fully collateralized options as tokenized ERC-1155 claims on locked collateral. Covered calls, protective puts, spreads. No oracles needed — settlement is deterministic based on collateral ratios.

### 4.2 Futures (ERC-1155) 🟢

**Source:** `src/derivatives/FuturesFacet.sol`, `src/derivatives/FuturesToken.sol`
**Docs:** `docs/Equalis/Derivatives-Design.md`

Fully collateralized futures contracts with the same Position NFT custody model. Tokenized as ERC-1155 for composability.

### 4.3 Synthetic Options via Direct Lending 🟢

**Docs:** `docs/Equalis/Synthetic-Options-Design.md`

Option-like payoffs constructed through the EqualLend Direct rail. Strike price is implicit in the collateral/principal ratio. Uses existing lending mechanics — no separate options engine needed.

---

## 5. Index Products

### 5.1 EqualIndex — Multi-Asset Index Tokens 🟢

**Source:** `src/equalindex/`, `src/views/EqualIndexViewFacetV3.sol`
**Docs:** `docs/Equalis/EqualIndex-Design.md`

Multi-asset index token system. Features:
- Index creation with configurable asset bundles
- Deterministic fee structures and fee pots
- Fee-gated creation
- Index tokens backed by dedicated internal pools
- Mint/burn/rebalance mechanics

### 5.2 EqualIndex Lending (Index Token Lending) 🟢

**Source:** `src/equalindex/EqualIndexLendingFacet.sol`, `src/libraries/LibEqualIndexLending.sol`, `src/libraries/LibLoanManager.sol`
**Spec:** `.kiro/specs/equalindex-lending/`

Lending against index token positions. Borrow single assets using index token units as collateral. Features:
- Configurable lending parameters per index (LTV, interest rate, max duration, min collateral)
- Borrow with automatic collateral locking
- Repay (partial/full) with interest calculation
- Extend loan duration
- Recover expired loans (liquidation of collateral)
- Per-position loan tracking via doubly-linked list (`LibLoanManager`)
- Economic balance and max borrowable previews

---

## 6. Isolated Lending Markets (ILM)

### 6.1 ILM Isolated — Morpho-Behavior Profile 🟢

**Source:** `src/ilm-isolated/facets/ILMIsolatedAdminFacet.sol`, `src/ilm-isolated/facets/ILMIsolatedFacet.sol`, `src/ilm-isolated/facets/ILMIsolatedLiquidationFacet.sol`, `src/ilm-isolated/facets/ILMIsolatedViewFacet.sol`
**Docs:** `docs/Equalis/ILM-Isolated-Design.md`, `docs/ext-mods/ILM-Morpho-Behavior-Design.md`
**Spec:** `.kiro/specs/ilm-morpho-behavior/`

Isolated single-pair lending markets — the shipped implementation of the Morpho-behavior design. Share-based accounting, LLTV health gating, single-oracle price checks, liquidation incentive factor model, market-local bad debt realization. Each market is a single collateral/loan pair with independent risk parameters. Features:
- Market creation with configurable risk params
- Supply, withdraw, borrow, repay operations
- Health factor-based liquidation
- Oracle-based price feeds
- Interest rate models
- Market-local bad debt isolation

### 6.2 ILM Pooled — AAVE-Behavior Profile 🟢

**Source:** `src/ilm-pooled/facets/ILMPooledAdminFacet.sol`, `src/ilm-pooled/facets/ILMPooledFacet.sol`, `src/ilm-pooled/facets/ILMPooledLiquidationFacet.sol`, `src/ilm-pooled/facets/ILMPooledViewFacet.sol`, `src/ilm-pooled/interfaces/`, `src/ilm-pooled/libraries/`
**Docs:** `docs/ext-mods/ILM-AAVE-Behavior-Design.md`
**Spec:** `.kiro/specs/ilm-aave-behavior/`

Aave-behavior pooled lending markets — the shipped implementation of the AAVE-behavior design. Health-factor reactive liquidation, variable interest rates, clean-room implementation using Equalis custody rails. Features:
- Market creation with LTV, liquidation threshold/bonus, rate strategy, supply/borrow caps
- Supply and withdraw with scaled balance (ray-precision index tracking)
- Collateral add/remove with health factor enforcement
- Variable-rate borrowing with utilization-based interest curves (base rate + slope1/slope2)
- Repayment with accrued interest
- Health factor-based liquidation with protocol fee and liquidator bonus
- Oracle adapter and sentinel adapter integration
- Global governance bounds (min/max LTV, min/max reserve factor)
- Reserve factor fee accrual
- Bad debt tracking per market

### 6.3 ILM — MAM-Curve Liquidation Profile 🔵

**Docs:** `docs/ext-mods/ILM-Design.md`

Isolated cross-asset lending with MAM-curve-based liquidation auctions instead of instant liquidation. Stress in one market cannot spread to unrelated liquidity.

---

## 7. Perpetual Trading

### 7.1 GMX-Style Isolated Perps Module 🟢

**Source:** `src/perps/PerpsAdminFacet.sol`, `src/perps/PerpsExecutionFacet.sol`, `src/perps/PerpsLiquidationFacet.sol`, `src/perps/PerpsViewFacet.sol`, `src/perps/LibPerpsStorage.sol`, `src/perps/LibPerpsFunding.sol`, `src/perps/LibPerpsRisk.sol`, `src/perps/LibPerpsIntent.sol`, `src/perps/LibPerpsOracle.sol`, `src/perps/LibPerpsFees.sol`, `src/perps/LibPerpsDomain.sol`, `src/perps/LibPerpsSync.sol`, `src/perps/LibPerpsIdentity.sol`
**Spec:** `.kiro/specs/gmx-perps-module/`

Equalis-native directional perpetual futures with GMX-like UX but accountId-keyed state, permissionless intent execution, and strict perps/non-perps solvency isolation. Features:
- Market creation with configurable risk, caps, oracle, fee, and insurance parameters
- Subaccount creation bound to Position NFTs
- Collateral add/remove
- Open/increase and decrease/close positions (direct auth + intent-based execution)
- Signed intent execution with EIP-712 signatures, nonce replay protection, and deadline enforcement
- On-chain intent cancellation (single + bulk nonce invalidation)
- Skew-proportional funding rate model (cumulative long/short funding indices, per-position settlement)
- Initial margin and maintenance margin enforcement
- Partial and full liquidation with close-factor scaling based on health
- Liquidator rewards bounded by market config
- Insurance fund with target balance and overflow routing
- Bad debt tracking per market
- Deterministic settlement deltas (canonical event payload for every state change)
- Strict isolation: perps operations cannot mutate non-perps pool balances
- Fee routing: 70% LP/maker perps index, 30% protocol fee router
- Account and market sync for idempotent reconciliation
- Isolation invariant proof via `proveIsolationInvariant` view
- Genesis config mask system ensuring all parameters are set before execution is enabled

---

## 8. Cross-Chain Products

### 8.1 Atomic Desks (XMR↔EVM Swaps) 🟢

**Source:** `src/EqualX/AtomicDeskFacet.sol`, `src/EqualX/SettlementEscrowFacet.sol`, `src/EqualX/Mailbox.sol`, `src/EqualX/EncPubRegistry.sol`
**Docs:** `docs/xmr-evm-atomic-swaps/ATOMICDESKS-DESIGN.md`, `docs/xmr-evm-atomic-swaps/ATOMIC-SWAP-LIFECYCLE.md`, `docs/xmr-evm-atomic-swaps/CLSAG-ADAPTOR-SPEC.md`, `docs/xmr-evm-atomic-swaps/MAILBOX-DESIGN.md`, `docs/xmr-evm-atomic-swaps/CHAIN-ADAPTERS.md`

Trustless cross-chain atomic swaps between EVM assets and Monero using CLSAG adaptor signatures. Components:
- **AtomicDeskFacet** — Desk creation, order matching, swap lifecycle
- **SettlementEscrowFacet** — On-chain escrow for the EVM leg of swaps
- **Mailbox** — Encrypted off-chain communication channel for swap participants
- **EncPubRegistry** — Public key registry for encrypted communication

---

## 9. Agent Infrastructure

### 9.1 Position Agent System — ERC-6551 Token Bound Accounts 🟢

**Source:** `src/agent-wallet/erc6551/PositionAgentTBAFacet.sol`, `src/agent-wallet/erc6551/PositionAgentConfigFacet.sol`, `src/agent-wallet/erc6551/PositionAgentRegistryFacet.sol`, `src/agent-wallet/erc6551/PositionAgentViewFacet.sol`
**Docs:** `docs/POSITION-AGENT-SYSTEM-DESIGN.md`, `docs/TBA-SESSION-KEY-DELEGATION.md`

Position NFTs as autonomous, discoverable on-chain agents. Features:
- Deterministic TBA address computation and deployment per Position NFT
- Admin configuration of ERC-6551 registry, implementation, and identity registry (lockable after first TBA deployment)
- Agent registration linking Position NFTs to ERC-8004 identity IDs (verified via identity registry ownership)
- View functions for TBA addresses, agent IDs, and configuration state

### 9.2 Position MSCA — ERC-6900 Modular Smart Contract Accounts 🟢

**Source:** `src/agent-wallet/erc6900/PositionMSCAImpl.sol`
**Lib:** `lib/agent-wallet-core/`

Concrete ERC-6900 MSCA implementation for ERC-6551 registry deployments. Extends `ERC721BoundMSCA` from the agent-wallet-core library. Features:
- ERC-4337 account abstraction compatibility
- Modular validation and execution module installation
- Validation config introspection (`isValidationInstalled`)
- Account ID: `equallend.position-tba.1.0.0`

### 9.3 AMM Skill Module — Autonomous Auction Agent 🟢

**Source:** `src/agent-wallet/erc6900/PositionAgentAmmSkillModule.sol`
**Docs:** `docs/ANVIL-AMM-AUCTION-SESSION-KEY.md`

ERC-6900 execution module enabling Position Agent TBAs to autonomously manage AMM auctions and community auctions. Features:
- Create, cancel, finalize AMM auctions with policy enforcement
- Add liquidity to auctions
- Join and finalize community auctions
- Roll yield to position
- Configurable auction policies (min/max duration, reserve bounds, fee limits, cooldowns)
- Configurable roll policies (min interval between rolls)
- Pool allowlisting
- Owner-only policy management
- Bound to a single Position NFT via ERC-6551 token binding

### 9.4 Standalone Agent Wallet Core (Library) 🟢

**Source:** `lib/agent-wallet-core/`
**Spec:** `.kiro/specs/standalone-nft-agent-wallet/`

Protocol-agnostic, reusable smart contract system extracted from Equalis. Designed as a git submodule for any ERC-721 project. Includes:
- Two account variants: `ERC721BoundMSCA` (standard ownership) and `ResolverBoundMSCA` (resolver-based)
- `OwnerValidationModule` with EIP-712 and ERC-6492 counterfactual signature support
- `SessionKeyValidationModule` with scoped policies, budget tracking, time windows, and replay protection
- `IOwnerResolver` abstraction with reference implementations
- Optional beacon proxy deployment mode
- Optional ERC-8004 identity adapter
- EIP-712 domain serialization utilities
- Bootstrap lifecycle with irreversible disable
- Hook depth enforcement (max 8 levels)
- Timelock-governed upgrade model

---

## 10. Module System

### 10.1 Module Registry & Gateway 🟢

**Source:** `src/modules/ModuleRegistryFacet.sol`, `src/modules/ModuleGatewayFacet.sol`, `src/modules/ModuleViewFacet.sol`
**Docs:** `docs/Equalis/Module-Encumbrance-Design.md`

Framework for plugging in external financial primitives with encumbrance-based isolation. Features:
- Module registration and lifecycle management
- Encumbrance gateway for modules to reserve capital from positions
- AUM fee enforcement on reserved capital
- Self-policing: delinquent modules are permanently deactivated
- Module view functions for introspection

---

## 11. Prediction Markets

### 11.1 Isolated Prediction Markets (IPM) 🔵

**Docs:** `docs/ext-mods/IPM-Design.md`

Binary outcome markets priced via MAM curves, settled via OBR (Optimistic Bonded Resolution). Per-market bonding, stablecoin settlement, no early redemption.

---

## 12. Dispute Resolution

### 12.1 Optimistic Bonded Resolution (OBR) 🔵

**Docs:** `docs/ext-mods/OBR-SPEC.md`

On-chain optimistic dispute resolution: assert → dispute → vote → finalize. Used by AtomicDesks settlement and Prediction Markets. Permissionless participation with bonded stakes.

---

## 13. Advanced Auction Products

### 13.1 Concentrated Liquidity Community Auction 🔵

**Docs:** `docs/Equalis/CL-Community-Auction-Design.md`
**Spec:** `.kiro/specs/cl-community-auction/`

Uniswap v3-style concentrated liquidity auction, fully protocol-native. Range positions managed by ERC-6551 TBAs bound to Position NFTs.

### 13.2 Liquid TNFT AMM Auction v2 🔵

**Spec:** `.kiro/specs/liquid-tnft-amm-auction/`

NFT-prize auction combining escrow, constant-product AMM, and contest-style bundle deposits. Sells an escrowed Sale NFT while sourcing Token A liquidity from a Position NFT via encumbrance. Participants acquire SeriesTokenB through AMM swaps, then deposit bundles of PoolShare + SeriesTokenB during a deposit window. Highest bundle depositor wins the Sale NFT. Features five timestamp-derived phases, principal protection floor, maker-side payout gated behind SeriesTokenB extinction, and 20 bps swap fee routed through LibFeeRouter.

---

## 14. Execution & Integration

### 14.1 MAM Native ETH Full Support 🟢

**Source:** `src/EqualX/MamCurveExecutionFacet.sol`, `src/libraries/LibCurrency.sol`
**Docs:** `docs/EqualX/MAM-Native-ETH-Full-Support-Design.md`
**Spec:** `.kiro/specs/mam-native-eth-support/`

MAM curves fully support native ETH as both base and quote asset. Execution facet functions are `payable`, `LibCurrency.isNative()` handles ETH detection (address(0)), and `nativeTrackedTotal` accounting ensures correct pool isolation for native ETH flows.

### 14.2 Open Intents Framework (OIF) 🔵

**Docs:** `docs/Equalis/OIF-Support-Design.md`

Intent-based execution layer for MAM curves and AMM auctions with module isolation and multi-output orders.

---

## 15. Testnet Infrastructure

### 15.1 Multi-Token Faucet 🟢

**Source:** `src/faucet/Faucet.sol`

Multi-token testnet faucet with per-token configurable amounts and a global 24-hour claim cooldown. Owner-managed token configuration (add, enable/disable, set amounts). Supports bulk claiming of all enabled tokens in a single transaction.

---

## 16. Agentic Finance Vision

**Docs:** `docs/AGENTIC-FINANCE.md`

Philosophical framework for the protocol's direction: Position NFTs as autonomous financial agents with on-chain identity, modular skills, and session-key delegation. The agent infrastructure (§9) is the implementation of this vision.

---

## Summary by Status

| Status | Count | Products |
|--------|-------|----------|
| 🟢 Shipped | 31 | Diamond, Position NFT, Encumbrance, FeeIndex, Pool AUM Fee, Module AUM Fee, Points, Action Fees, EqualLend, Direct Term, Direct Rolling, Managed Pools, Flash Loans, AMM Auctions, MAM Curves, Community Auctions, MAM Profiles, Stable/Volatile Modes, MAM Native ETH, Options, Futures, Synthetic Options, EqualIndex, EqualIndex Lending, ILM Isolated (Morpho), ILM Pooled (AAVE), Perps, Atomic Desks, Agent System (TBA + MSCA + Skill Module + Core Lib), Module System, Faucet |
| 🔵 Designed | 6 | ILM MAM-Curve, IPM, OBR, CL Community Auction, Liquid TNFT v2, OIF |
