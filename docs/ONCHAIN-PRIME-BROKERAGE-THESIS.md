# Equalis Protocol: The On-Chain Prime Brokerage

> A unified, self-custodied financial infrastructure that collapses custody, lending, derivatives, execution, and settlement into a single permissionless system — designed for progressive immutability.

---

## Executive Summary

Traditional prime brokerages serve as the backbone of institutional finance. They provide custody, margin lending, trade execution, securities lending, and derivatives clearing under one roof. Access is gated by relationship, jurisdiction, and minimum account size. The economics flow to the broker.

Equalis reimagines this entire stack as a permissionless, on-chain protocol built on the EIP-2535 Diamond standard. Every service a prime broker offers — and several they don't — is available to any participant holding a Position NFT. There are no account minimums, no relationship requirements, and no geographic restrictions. The protocol's fee revenue flows back to active participants through a mechanical distribution system called the Active Credit Index.

The protocol is architected with governance minimization as a core design principle. The base lending, trading, and derivatives infrastructure is designed to operate without ongoing privileged intervention. Where governance is required — such as risk parameter management for pooled lending markets — it is scoped narrowly and cannot affect the rest of the system. The long-term direction is progressive immutability: permanently freezing governance controls one facet at a time as the system matures and parameters stabilize. This is a deliberate, careful process — not a launch-day feature — and it will take time and real-world operational confidence to execute responsibly.

---

## The Prime Brokerage Stack

### What a Traditional Prime Broker Does

A full-service prime broker (Goldman Sachs, Morgan Stanley, JP Morgan) provides six core services to institutional clients:

1. **Custody** — Safekeeping of assets in segregated accounts
2. **Margin Lending** — Overcollateralized loans against deposited assets
3. **Credit Facilities** — Undercollateralized lending based on creditworthiness
4. **Trade Execution** — Access to multiple trading venues and liquidity
5. **Securities Lending** — Lending idle assets to generate yield
6. **Derivatives Clearing** — Options and futures clearing, settlement, and margining

These services are bundled because they share a common dependency: a unified view of the client's positions, collateral, and risk. The prime broker's margin engine cross-references all of these to determine what the client can do. This is why prime brokerage is a natural monopoly at the account level — fragmenting across providers destroys the cross-margining benefit.

### How Equalis Maps to This Stack

| Prime Brokerage Service | Equalis Component | Key Difference |
|---|---|---|
| Custody | Position NFT (ERC-721) + ERC-6551 Token Bound Account | Self-custodied. No counterparty risk. |
| Margin Lending | EqualLend Pools + ILM Markets (Isolated & Pooled) | Permissionless. Mechanical liquidation. |
| Credit Facilities | EqualLend Direct (P2P fixed-term & rolling offers) | Peer-to-peer. No credit committee. |
| Trade Execution | AMM Auctions, Community Auctions, MAM Curves | Multi-venue. On-chain settlement. |
| Securities Lending | Module Encumbrance System | Programmable. Yield via ACI. |
| Derivatives Clearing | Options & Futures Facets + ERC-1155 Tokens | Integrated clearing. Transferable contracts. |
| Cross-Chain Settlement | Atomic Desk + Settlement Escrow + Encrypted Mailbox | Trustless. Cryptographic settlement. |
| Index Products | EqualIndex (create, mint, burn, flash, lend against) | Permissionless ETF-like baskets. |
| Agent Delegation | ERC-6900 Modular Account Skill Modules | Programmable account automation. |
| Revenue Sharing | Active Credit Index (ACI) | Mechanical. Ungovernable. |

---

## Core Architecture

### The Position NFT: A Self-Custodied Prime Brokerage Account

Every participant in Equalis holds a Position NFT — an ERC-721 token that represents an isolated account container. This single NFT holds:

- Deposits across multiple lending pools
- Rolling and fixed-term loans
- Accrued yield and fee distributions
- Encumbrances into modules and ILM markets
- Collateral backing options, futures, and direct lending agreements
- Active Credit Index yield entitlements

All of these are cross-margined against a single principal balance. The protocol's solvency engine evaluates available principal as: `total_deposits - encumbered_amounts - locked_collateral`. This is functionally identical to a prime broker's margin calculation, except it runs on-chain, deterministically, with no human discretion.

Each Position NFT can be extended with an ERC-6551 Token Bound Account, giving the position its own smart contract wallet. This wallet can be equipped with ERC-6900 skill modules that automate trading strategies — creating, managing, and finalizing auctions, rolling yield, and managing positions according to owner-defined policy bounds. This is programmable delegation: the on-chain equivalent of giving your prime broker a limited power of attorney.

The Position NFT is freely transferable. When ownership changes, all deposits, loans, yield, and obligations transfer atomically. There is no account migration, no paperwork, no counterparty approval. This is a property that no traditional prime brokerage account has ever had.

---

## Lending: Three Tiers of Credit

### Tier 1 — Pool Lending (Overcollateralized)

EqualLend pools provide the base lending layer. Depositors supply assets and earn yield from borrowers. Borrowers take rolling or fixed-term loans against their deposited collateral, gated by a loan-to-value ratio. This is the equivalent of a prime broker's margin lending facility.

Pools can be created permissionlessly (using protocol defaults) or as managed pools where a designated manager controls parameters like APY, LTV, deposit caps, and whitelist access. Managed pools enable institutional-grade configurations while remaining on-chain and transparent.

### Tier 2 — ILM Markets (Structured Lending)

Two lending architectures operate on top of the base pools:

**ILM Isolated** — Inspired by the Morpho Blue architecture, adapted for the encumbrance model. Single-collateral, single-loan markets with permissionless creation. Anyone can create a market by selecting from whitelisted interest rate models and liquidation LTV values. No governance required for market creation or operation. This is the most decentralization-compatible lending tier.

**ILM Pooled** — Inspired by the Aave v3 architecture, adapted for encumbrance. Shared-liquidity pools where multiple collateral types back a common lending market. Provides superior capital efficiency for borrowers at the cost of requiring ongoing risk parameter governance.

Both tiers integrate with the encumbrance system: borrowing in an ILM market encumbers the borrower's base pool position, and that encumbrance generates Active Credit Index yield. Borrowers earn while they borrow.

### Tier 3 — Direct P2P Lending (Negotiated Terms)

EqualLend Direct enables peer-to-peer credit agreements with fully negotiable terms. Lenders and borrowers post offers specifying principal, APR, duration, collateral requirements, and exercise rights. The collateral lock amount is a negotiated parameter — not enforced by a protocol-level LTV ratio. This enables undercollateralized lending where the lender makes a credit judgment about the borrower.

The system supports:

- **Fixed-term agreements** with lump-sum repayment
- **Rolling agreements** with periodic payments, delinquency tracking, and amortization
- **Ratio tranche offers** that function as a CLOB-style orderbook with partial fills
- **Borrower-initiated offers** where borrowers post their desired terms and lenders fill them
- **Lender call rights** and **borrower exercise rights** as negotiable contract terms

This is the on-chain equivalent of a prime broker's credit facility — the service traditionally reserved for the largest institutional clients. Equalis makes it permissionless.

---

## Derivatives: Integrated Clearing and Settlement

### ERC-1155 Options

Position holders can create option series — calls or puts, American or European — by locking collateral from their pool position. The protocol mints ERC-1155 tokens representing the option contracts. These tokens are:

- **Freely transferable** — tradeable on any ERC-1155 marketplace or OTC
- **Composable** — usable as building blocks in other protocols or strategies
- **Self-clearing** — exercise and settlement happen atomically against pool positions

The option writer's collateral is locked via the encumbrance system. Exercise transfers value between pool positions. Unexercised options allow the writer to reclaim collateral after expiry. Custom fee schedules (creation, exercise, reclaim) are configurable per series within protocol bounds.

### ERC-1155 Futures

Forward contracts follow the same pattern: ERC-1155 tokens representing futures positions with settlement at expiry. European or American style, with configurable grace periods for reclaim. The underlying collateral is locked from pool positions, and settlement transfers value between the maker's and holder's positions.

### What This Replaces

In traditional finance, options and futures require three separate intermediaries:

1. An **exchange** to match buyers and sellers
2. A **clearing house** (OCC, CME Clearing) to guarantee settlement
3. A **prime broker** to provide margin and custody

Equalis collapses all three into the Diamond. The pool position is the margin account, the encumbrance system is the margin lock, the ERC-1155 tokens are the cleared contracts, and settlement is atomic and on-chain. There is no counterparty risk because the collateral is locked at creation.

---

## Trade Execution: Multi-Venue Liquidity

### AMM Auctions

Time-bounded constant-product (or stable-invariant) liquidity pools created by position holders. A maker deposits reserves from two pool positions, sets a fee rate and duration, and the auction accepts swaps until expiry or finalization. Fees accrue to the maker and to the protocol treasury.

### Community Auctions

Pooled market-making where multiple position holders contribute liquidity to a shared auction. Fees are distributed proportionally via a fee-index mechanism. This enables collective liquidity provision without requiring each participant to manage their own auction.

### MAM Curves (Maker Automated Market)

Maker-defined pricing curves with commitment-based execution. A maker specifies start price, end price, duration, and volume. The curve is hashed into a commitment, and takers execute against the deterministic pricing function. Curves can be updated, cancelled, or expired. Batch operations enable portfolio-level curve management.

### Atomic Desk (Cross-Chain)

Trustless cross-chain settlement using encrypted messaging and hash-time-locked escrow. Desk operators register encryption keys, takers reserve liquidity from tranches, and settlement proceeds through an encrypted mailbox protocol. This enables cross-chain swaps (including non-EVM chains) without bridges or wrapped assets.

---

## The Active Credit Index: Revenue Sharing as a Primitive

The Active Credit Index (ACI) is the mechanism that transforms Equalis from a collection of financial tools into a cooperative financial system.

### How It Works

All protocol fee revenue — from lending, trading, derivatives, flash loans, maintenance, and action fees — flows through a fee router that splits revenue between:

- **Treasury** (default 10%) — protocol operational costs
- **Active Credit Index** (default 70%) — distributed to active participants
- **Pool-specific routing** (default 20%) — returned to the pool generating the fees

The ACI share is distributed proportionally to positions with active encumbrances. The more capital a position has actively deployed (in ILM markets, module encumbrances, or other productive uses), the larger its share of protocol revenue.

### Why This Matters

In traditional prime brokerage, the broker captures all fee revenue. Clients pay for services and receive none of the economics of the platform itself.

In most DeFi lending protocols, fee revenue flows to a DAO treasury controlled by token holders who may have no active participation in the protocol. The recent vote where Aave Labs was able to sway a vote their way illustrates the failure mode of this model.

In Equalis, fee revenue flows mechanically to active participants. There is no DAO vote, no treasury committee, no governance proposal required. The distribution is deterministic and on-chain. As the protocol matures and governance controls are progressively frozen, this distribution becomes permanently embedded in the system.

### The Borrower Flywheel

The ACI creates a unique dynamic for borrowers. In every other lending protocol, borrowing is a pure cost: you pay interest, period. In Equalis:

**Net borrowing cost = nominal interest rate − ACI yield**

A borrower in an ILM market has an encumbered position that earns ACI. If the protocol generates sufficient fee volume, the ACI yield partially (or in high-activity scenarios, substantially) offsets the borrowing cost. This creates a flywheel:

More protocol activity → more fees → higher ACI yield → lower effective borrowing cost → more borrowers → more activity

This flywheel is funded by real protocol revenue, not inflationary token emissions. It is sustainable by construction.

---

## Governance: Minimized by Design, Progressive Immutability by Intent

### The Design Principle

Equalis is designed for minimized governance. The core lending, trading, derivatives, and settlement infrastructure requires no ongoing privileged intervention to function. Where governance exists, it is scoped to specific subsystems and cannot affect the broader protocol.

This is a meaningful distinction from most DeFi protocols, which require governance for routine operations. In Equalis, governance is limited to parameter tuning and risk management for specific market types — it does not touch the core financial plumbing.

### The Diamond Advantage

The EIP-2535 Diamond standard provides a unique architectural property: facet selectors (function entry points) can be permanently removed via `diamondCut`. This means that as parameters stabilize and operational confidence grows, governance functions can be stripped from the protocol one facet at a time — a process we call progressive immutability.

This is not theoretical. It is a concrete, tested operation built into the architecture from day one. But it is also not something to rush. Each facet freeze is irreversible, and the protocol needs real-world operational maturity before governance controls are permanently removed.

### Where We Are Today

The governance surface is intentionally organized into tiers:

**Core protocol (governance-free by design).** The base lending pools, derivatives settlement, ACI distribution, trade execution, and position management operate mechanically. No admin intervention is required for these systems to function.

**Configuration parameters (freeze candidates).** Fee schedules, pool defaults, points configuration, maintenance rates, and creation fees are set once during deployment and tuning. These are candidates for permanent freezing as the protocol matures — their admin selectors can be removed when the parameters are battle-tested.

**Risk management (requires ongoing governance).** ILM Pooled markets require active risk parameter management — LTV adjustments, oracle updates, market freezes during volatility events. This is inherent to the shared-liquidity architecture and is an honest governance dependency. It is scoped to a single facet and cannot affect the rest of the protocol.

### The Long-Term Direction

The goal is progressive immutability — freezing governance controls one facet at a time as confidence grows. This is a careful, deliberate process that will take time. The Diamond architecture ensures that each step is available when the protocol is ready, without requiring any architectural changes. The core protocol is already designed to function without governance; the remaining question is when — not whether — the configuration layer joins it.

---

## Market Positioning

### vs. Traditional Prime Brokers

| Dimension | Traditional PB | Equalis |
|---|---|---|
| Access | Institutional only ($1M+ minimums) | Permissionless (any Position NFT holder) |
| Custody | Broker-custodied (counterparty risk) | Self-custodied (no counterparty risk) |
| Cross-margining | Yes (proprietary margin engine) | Yes (on-chain solvency engine) |
| Revenue sharing | None (broker captures all economics) | ACI distributes 70% of fees to participants |
| Derivatives clearing | Via external clearing houses | Integrated (ERC-1155 + pool settlement) |
| Credit facilities | Relationship-based, opaque terms | Permissionless P2P with negotiated terms |
| Account portability | None (multi-month migration process) | Instant (NFT transfer) |
| Operating hours | Market hours only | 24/7/365 |
| Governance | Corporate board | Minimized governance, progressive immutability |

### vs. DeFi Lending Protocols (Aave, Morpho, Compound)

| Dimension | Aave/Compound | Morpho Blue | Equalis |
|---|---|---|---|
| Lending model | Pooled only | Isolated only | Both + P2P direct |
| Derivatives | None | None | Options, futures, auctions, MAM curves |
| Revenue to users | None (DAO treasury) | None (protocol fee) | ACI (70% default to active participants) |
| Governance dependency | Permanent (DAO) | Minimal | Minimized; progressive immutability |
| Cross-margining | No | No | Yes (Position NFT) |
| Undercollateralized lending | No | No | Yes (Direct P2P) |
| Index products | No | No | Yes (EqualIndex) |
| Agent delegation | No | No | Yes (ERC-6551 + ERC-6900) |

### vs. On-Chain Derivatives (Opyn, Lyra, Hegic)

| Dimension | Existing Protocols | Equalis |
|---|---|---|
| Integration with lending | Separate protocols | Unified (same position, same margin) |
| Collateral source | External deposits | Pool positions (cross-margined) |
| Token standard | Various (often non-transferable) | ERC-1155 (composable, tradeable) |
| Clearing model | Protocol-specific | Integrated with lending pools |
| Revenue sharing | Token emissions | ACI (real revenue) |

---

## Summary

Equalis is not a lending protocol with some trading features bolted on. It is a complete financial infrastructure layer — a self-custodied, permissionless prime brokerage that provides:

- **Unified account management** via Position NFTs with cross-margining
- **Three tiers of credit** from overcollateralized pool lending to negotiated P2P facilities
- **Integrated derivatives clearing** with freely transferable ERC-1155 options and futures
- **Multi-venue trade execution** across AMM auctions, community pools, maker curves, and cross-chain atomic swaps
- **Programmable delegation** through token-bound accounts with modular skill modules
- **Mechanical revenue sharing** that distributes protocol fees to active participants without governance
- **Composable index products** with built-in lending capabilities
- **A governance-minimized architecture** designed for progressive immutability — freezing controls one facet at a time as the system matures

Equalis is built with the conviction that financial infrastructure should be transparent, permissionless, and resistant to capture. The core protocol is governance-free by design. The remaining governance surface is scoped, honest about its necessity, and architected to be removable when the time is right. Progressive immutability is the direction — and the Diamond architecture ensures the path is always available.
