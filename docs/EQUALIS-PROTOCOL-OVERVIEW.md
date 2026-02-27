# Equalis Protocol Overview

**An On-Chain Financial Operating System**

---

## What Is Equalis?

Equalis is a unified financial infrastructure layer built as a single Diamond proxy contract on Ethereum. It collapses what would normally be 8–10 separate DeFi protocols into one shared custody and accounting substrate.

The core insight: **one deposit, many uses, all isolated by accounting — not by moving tokens between contracts.**

A single Position NFT holder can simultaneously earn passive yield, provide AMM liquidity, write options, back perp traders, lend peer-to-peer, and hold multi-asset index positions — all from the same collateral, governed by the same encumbrance math.

If traditional DeFi is a collection of standalone apps, Equalis is the operating system they should have been built on.

---

## The Two Things That Make This Different

### 1. Unified Fee Rail (FeeIndex)

Every fee generated anywhere in the protocol — lending interest, swap fees, option premiums, auction fills, module AUM charges — flows into a single per-token fee index.

Your USDC earns from **everyone else's USDC activity** across every venue. Not just the pool you're in. Not just the product you're using. Everything.

| Traditional DeFi | Equalis |
|-----------------|---------|
| Aave USDC earns from Aave lending only | Your USDC earns from all USDC activity protocol-wide |
| Uniswap LP earns from that specific pair only | Passive depositors earn from every swap, borrow, option, auction, and module |
| Capital must be moved between protocols to chase yield | One deposit captures yield from every venue simultaneously |

Every new module shipped adds a new fee source to the existing rail. Depositors get richer without doing anything differently.

### 2. Annualized AUM Fee

The protocol charges an ongoing AUM fee on deposited capital — accruing regardless of whether anyone trades, borrows, or does anything at all.

Most DeFi protocols have zero revenue when activity dries up. Equalis always earns.

Two revenue layers stacked:
- **Activity fees** — variable, scales with volume
- **AUM fee** — steady, scales with TVL

This is the same model as traditional asset management (Blackrock clips basis points on AUM daily regardless of trading), but with DeFi activity-fee upside on top.

External modules that encumber capital also pay AUM fees for the privilege. They either stay current or get permanently deactivated. No free rides.

---

## What's Built (Shipped in Code)

### Core Infrastructure
- **Diamond Proxy Architecture** — Single upgradeable contract with modular facets
- **Position NFT (ERC-721)** — Portable, composable account container holding all deposits, loans, and yield across every venue
- **Encumbrance Engine** — Per-position, per-pool reservation system that isolates risk across concurrent activities
- **Unified Fee System (FeeIndex)** — Single per-token fee rail aggregating revenue from all protocol activity
- **AUM Fee System** — Annualized fee on deposited capital with three-way split (depositors, active participants, treasury)
- **Fee Router** — Centralized routing to fee index, active credit index, and treasury
- **Points / Proof of Participation** — On-chain participation accounting for future token emissions

### Lending
- **EqualLend (Self-Secured Credit)** — Oracle-free, deterministic lending where users borrow against their own deposits. No liquidations, no utilization curves. Includes flash loans, penalty system, pool management.
- **EqualLend Direct (P2P Term Loans)** — Peer-to-peer fixed-term lending between any assets without price oracles. Lenders set their own terms. Supports American-style early exercise, ratio tranche offers (CLOB-style), and configurable prepayment.
- **EqualLend Direct Rolling** — Peer-to-peer rolling credit with periodic payments, arrears tracking, amortization, and grace periods.
- **Managed Pools** — Delegated pool administration for institutions, DAOs, and strategy vaults with whitelist gating and system-share fee routing.

### Trading / Exchange
- **AMM Auctions** — Time-bounded automated market maker pools with constant-product (volatile) and stable invariant modes. Position-backed reserves, maker fee earning.
- **MAM Curves (Maker Auction Markets)** — Time-varying Dutch auction price curves for selling assets. Linear price trajectory from start to end.
- **Community Auctions** — Multi-maker community liquidity auctions.

### Derivatives
- **Options (ERC-1155)** — Fully collateralized options as tokenized claims on locked collateral. Covered calls, protective puts, spreads. No oracles needed.
- **Futures (ERC-1155)** — Fully collateralized futures contracts with the same Position NFT custody model.
- **Synthetic Options via Direct Lending** — Option-like payoffs through the EqualLend Direct rail using collateralized lending mechanics. Strike price implicit in collateral/principal ratio.

### Index Products
- **EqualIndex** — Multi-asset index token system with deterministic fee structures, fee pots, and fee-gated creation. Index tokens have dedicated pools for internal accounting.
- **EqualIndex Lending** — Lending against index positions (in progress).

### Cross-Chain
- **Atomic Desks (XMR↔EVM)** — Trustless cross-chain atomic swaps between EVM assets and Monero using CLSAG adaptor signatures. Includes settlement escrow, encrypted mailbox, and public key registry.

### Agent Infrastructure
- **Position Agent System** — Position NFTs as autonomous, discoverable agents:
  - ERC-6551 Token Bound Accounts for on-chain execution
  - ERC-6900 Modular Smart Contract Accounts for extensible behaviors
  - ERC-8004 Agent Identity for global discovery and indexing
  - Skill modules (e.g., AMM auction automation)
  - ERC-4337 compatible for gas sponsorship and batched operations

### Module System
- **Module Registry & Gateway** — Framework for plugging in external financial primitives with encumbrance-based isolation. Modules pay AUM fees on reserved capital. Self-policing: delinquent modules are permanently deactivated.

---

## What's Coming (Designed, Not Yet Implemented)

### Isolated Lending Markets (ILM) — Three Profiles

The module system enables permissionless, isolated cross-asset lending markets. Three distinct behavior profiles are designed:

1. **ILM — MAM-Curve Liquidation Profile**
   Isolated cross-asset lending with MAM-curve-based liquidation auctions. Stress in one market cannot spread to unrelated liquidity.

2. **ILM — AAVE-Behavior Profile**
   Health-factor reactive liquidation model matching AAVE core behavior (supply, withdraw, borrow, repay, health checks, liquidation) — clean-room implementation using Equalis custody.

3. **ILM — Morpho-Behavior Profile**
   Share-based accounting, LLTV health gating, single-oracle price checks, liquidation incentive factor model, market-local bad debt realization. Permissionless market creation with bounded governance controls.

### Perpetual Trading
- **Isolated Perpetual Pools (IPERPM)** — Oracle-based perps as an isolated spoke drawing capacity from single-asset pools. LPs explicitly underwrite trader PnL. Deterministic liquidation at oracle mark price.

### Prediction Markets
- **Isolated Prediction Markets (IPM)** — Binary outcome markets priced via MAM curves, settled via OBR. Per-market bonding, stablecoin settlement, no early redemption.

### Dispute Resolution
- **Optimistic Bonded Resolution (OBR)** — On-chain optimistic dispute resolution: assert → dispute → vote → finalize. Used by AtomicDesks settlement and Prediction Markets. Permissionless participation.

### Advanced Auctions
- **Concentrated Liquidity Community Auction** — Uniswap v3-style concentrated liquidity auction, fully protocol-native. Range positions managed by ERC-6551 TBAs bound to Position NFTs.
- **Liquid TNFT AMM Auction v2** — NFT-prize auction with encumbrance-sourced reserves and contest token mechanics.

### Execution & Integration
- **Open Intents Framework (OIF)** — Intent-based execution layer for MAM curves and AMM auctions with module isolation and multi-output orders.
- **MAM Native ETH Full Support** — Extending MAM curves to fully support native ETH as base and quote asset.

---

## Revenue Model

Equalis generates revenue from two complementary layers:

### Layer 1: Activity Fees (Variable — Scales with Volume)

| Source | Fee Type |
|--------|----------|
| Pool lending | Flash loan fees, action fees |
| AMM Auctions | Swap fees per trade |
| MAM Curves | Fill fees per quote input |
| Direct Lending | Platform fee on principal, default recovery |
| Derivatives | Create, exercise, and reclaim fees |
| Atomic Swaps | Settlement fees |
| Index Products | Mint, burn, and flash fees |
| Pool/Index Creation | Flat ETH creation fees |

### Layer 2: AUM Fees (Steady — Scales with TVL)

| Source | Mechanism |
|--------|-----------|
| Pool deposits | Annualized fee on all deposited capital |
| Module encumbrance | Daily-epoch fee on capital reserved by external modules |
| Managed pools | System share routed from managed pool fees to base pool |

### Fee Distribution

All fees flow through a centralized router and split three ways:

1. **Fee Index** → Passive depositors (yield on deposits)
2. **Active Credit Index** → Active participants (borrowers, lenders)
3. **Treasury** → Protocol revenue

---

## Architecture at a Glance

```
┌──────────────────────────────────────────────────────────────┐
│                     Diamond Proxy                            │
│                                                              │
│  ┌───────── ┐  ┌──────────┐  ┌───────────┐  ┌────────────┐   │
│  │ EqualLend│  │ EqualLend│  │Derivatives│  │ EqualIndex │   │
│  │ (Pools)  │  │ Direct   │  │ Opt + Fut │  │ (Indices)  │   │
│  └────┬─────┘  └────┬─────┘  └─────┬─────┘  └─────┬──────┘   │
│       │             │              │              │          │
│  ┌────┴─────────────┴──────────────┴──────────────┴───────┐  │
│  │              Position NFT + Encumbrance                │  │
│  │           (Unified Custody & Risk Layer)               │  │
│  └────┬──────────────┬──────────────┬─────────────────────┘  │
│       │              │              │                        │
│  ┌────┴─────┐  ┌─────┴─────┐  ┌─────┴─────┐                  │
│  │ AMM      │  │ MAM       │  │ Community │                  │
│  │ Auctions │  │ Curves    │  │ Auctions  │                  │
│  └────┬─────┘  └─────┬─────┘  └─────┬─────┘                  │
│       │              │              │                        │
│  ┌────┴──────────────┴──────────────┴─────────────────────┐  │
│  │           Unified Fee Rail (FeeIndex per Token)        │  │
│  │         + AUM Fee System + Fee Router + Treasury       │  │
│  └────────────────────────────────────────────────────────┘  │
│                                                              │
│  ┌──────────┐  ┌───────────┐  ┌────────────┐                 │
│  │ Module   │  │ Agent     │  │ Atomic     │                 │
│  │ System   │  │ Wallets   │  │ Desks      │                 │
│  │ (ILM,    │  │ (6551 +   │  │ (XMR↔EVM)  │                 │
│  │ Perps,   │  │  6900 +   │  │            │                 │
│  │ Predict) │  │  8004)    │  │            │                 │
│  └──────────┘  └───────────┘  └────────────┘                 │
└──────────────────────────────────────────────────────────────┘
```

---

## The Flywheel

More venues → higher passive yield → more deposits → deeper liquidity → better execution → more volume → more fees → repeat.

Each module strengthens every other module through the shared fee layer. Capital efficiency compounds across every venue simultaneously because they all share the same custody and risk infrastructure.

---

## Why This Matters

**For depositors:** Deposit once, earn from everything. No active management required.

**For builders:** Ship new financial primitives as modules without forking. Tap into existing liquidity and custody infrastructure.

**For the protocol:** Revenue accrues on TVL (AUM) and activity (fees). The floor is never zero.

Equalis isn't a lending app. It isn't a DEX. It's the infrastructure layer that makes both — and everything else — possible from a single position.
