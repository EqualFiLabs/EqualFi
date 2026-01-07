# EqualFi

Deterministic, non-reactive financial primitives for trust-minimized, permissionless systems.

This work is inspired in part by:

https://vitalik.eth.limo/general/2025/09/21/low_risk_defi.html

https://trustlessness.eth.limo/general/2025/11/11/the-trustless-manifesto.html

_**We must build for the right reasons.**_  

> Status: early-stage 

## Start here

1) Agentic finance angle (why determinism matters for autonomous systems):
- [AGENTIC-FINANCE.md](./AGENTIC-FINANCE.md)

2) Sovereign internet infrastructure:
- [SOVEREIGN-INTERNET.md](./SOVEREIGN-INTERNET.md)

3) Core primitives (high level):
- [Equalis](#the-equalis-protocol)
- [EqualIndex](#equalindex)
- [Maker Auction Markets](#maker-auction-markets)

## Repository map

### Core Concepts
- [AGENTIC-FINANCE.md](./AGENTIC-FINANCE.md) - Why determinism matters for autonomous systems
- [SOVEREIGN-INTERNET.md](./SOVEREIGN-INTERNET.md) - Infrastructure for decentralized internet protocols

### Equalis Protocol
- [Equalis-Design.md](./Equalis/Equalis-Design.md) - Complete protocol design document
- [Equalis-Direct.md](./Equalis/Equalis-Direct.md) - Bilateral instruments and P2P lending
- [Equalis-Direct.md#5-yield-bearing-limit-orders-yblo](./Equalis/Equalis-Direct.md#5-yield-bearing-limit-orders-yblo) - Yield-Bearing Limit Orders (YBLOs)
- [EqualIndexV3.md](./Equalis/EqualIndexV3.md) - EqualIndex V3 design document
- [GAS-ESTIMATES-EL.md](./Equalis/GAS-ESTIMATES-EL.md) - Comprehensive gas analysis
- [SYNTHETIC-CALL-PUT.md](./Equalis/SYNTHETIC-CALL-PUT.md) - Options-like instruments

### EqualX Research
- [ATOMICDESKS-DESIGN.md](./EqualX/ATOMICDESKS-DESIGN.md) - Atomic desks design
- [MAILBOX-DESIGN.md](./EqualX/MAILBOX-DESIGN.md) - Encrypted mailbox research documentation
- [CLSAG-ADAPTOR-SPEC.md](./EqualX/CLSAG-ADAPTOR-SPEC.md) - CLSAG adaptor signature specification
- [GAS-ESTIMATES.md](./EqualX/GAS-ESTIMATES.md) - EqualX gas analysis

## Why non-reactive finance (NoRFi)

EqualFi is an attempt to explore a different foundation for on-chain financial systems.
Most decentralized finance today is built around reactive mechanisms. Prices move, utilization shifts, oracles update, and protocols respond in real time through liquidations, rate changes, and auctions. These systems work, but they inherit complexity and failure modes from the markets they track. Outcomes depend on external signals, third-party actors, and timing conditions that are difficult to reason about in worst-case scenarios.
EqualFi is building from an alternative design space using first principles.

The work in this repository focuses on deterministic, non-reactive financial primitives. Instead of relying on continuous price feeds or liquidation races, these systems define outcomes through explicit parameters, time, and local accounting invariants. Risk is expressed at the moment a position is created, not discovered later through emergency response.
This repository collects the core research and designs behind that approach:
  * Equalis, a decentralized financial protocol enabling pooled credit, bilateral options-like instruments, and spot trading via Yield-Bearing Limit Orders (YBLOs) built around time-based settlement, bounded default handling, and account-level isolation rather than price-triggered liquidations which allows for multiple instruments from one primitive
  * EqualIndex, a deterministic index primitive where asset composition, fees, and redemption behavior are fixed and analyzable without oracles.
  * Maker Auction Markets (MAMs), a market structure where liquidity is expressed as explicit, fully collateralized commitments instead of reactive pool pricing.
EqualFi’s goal is to maintain maximum composability and capital efficiency via determinism and user agency. A system that makes on-chain finance easier to reason about under adversarial conditions, easier to verify, and more suitable for long-lived autonomous systems and humans.
If you are a researcher, builder, or potential backer interested in protocol design, risk modeling, or the long-term structure of decentralized finance, this repository is an invitation to examine the assumptions we have normalized and to explore what finance looks like when correctness and determinism come first.

## Agentic finance is a first-class design target

If on-chain agents are going to manage capital and credit continuously, they need substrates with:
- outcomes defined by explicit parameters and time
- bounded enforcement paths (no liquidation races)
- minimal reliance on external signals and third-party execution

In short: agents should be able to plan using provable bounds, not continuously predict and react.
See [AGENTIC-FINANCE.md](./AGENTIC-FINANCE.md) for the argument and design implications.

## The Equalis Protocol

Equalis is a lending and credit primitive designed around a simple constraint: **protocol behavior should be deterministic, locally enforceable, and analyzable at the moment a position is created**.

Most on-chain lending systems today enforce safety through reactivity. Borrower solvency is maintained by continuously repricing collateral, monitoring oracle feeds, and triggering liquidations when thresholds are crossed. This approach works, but it tightly couples user outcomes to market microstructure, oracle availability, and third-party execution. From a systems perspective, it turns lending into an always-on emergency response loop.

Equalis explores a different model.

At its core, Equalis replaces price-triggered enforcement with **time-based settlement and explicit encumbrance accounting**. Credit terms are defined up front. Enforcement paths are known in advance. If obligations are met, positions unwind cleanly. If they are not, settlement follows a bounded, rules-based process rather than a liquidation cascade.

The protocol is built around a few key ideas.

Positions are represented as **transferable account containers** rather than ephemeral balances. A position aggregates deposits, borrows, and obligations while remaining isolated from other users and other pools. This makes risk local and legible, and it allows positions themselves to become composable building blocks rather than opaque internal state.

Pools are **single-asset and isolated**. Depositors are never implicitly backstopping unrelated risk, and failures in one pool cannot contaminate another. Losses are not socialized through bad debt pools or system-wide recapitalization logic.

Equalis supports both pooled credit and bilateral agreements. Pooled credit provides deterministic borrowing against self-secured collateral with fixed rules for repayment, delinquency, and default. The direct agreement layer enables peer-to-peer credit, including cross-asset lending, without relying on price oracles or liquidation auctions. In all cases, obligations are enforced through explicit state transitions and time, not market-driven triggers.

Defaults are handled through **bounded settlement**, not forced liquidation into the market. The maximum downside of a position is knowable at origination. There is no race condition, no auction slippage, and no dependency on external liquidity at the moment enforcement occurs.

Equalis is intentionally conservative in what it assumes and permissive in what it enables. It does not attempt to predict prices, optimize utilization, or dynamically tune risk parameters. Instead, it provides a minimal, deterministic substrate on top of which more expressive financial instruments can be constructed.

The result is a lending primitive that prioritizes predictability over reactivity, correctness over speed, and explicit user agency over implicit protocol intervention. This makes Equalis well-suited not only for human users, but for long-lived autonomous systems that require stable, reasoned interaction with on-chain credit.

For detailed information on Yield-Bearing Limit Orders, see [/Equalis/Equalis-Direct.md#5-yield-bearing-limit-orders-yblo](./Equalis/Equalis-Direct.md#5-yield-bearing-limit-orders-yblo). For comprehensive gas analysis, see [/Equalis/GAS-ESTIMATES-EL.md](./Equalis/GAS-ESTIMATES-EL.md).

## Gas reality

Yield-Bearing Limit Orders (YBLOs) are measured in Foundry tests:

- Post ~550k
- Accept ~347k no-fees, ~419k fees
- Cancel ~58k

These are current measured Foundry tests, not estimates. See [/Equalis/GAS-ESTIMATES-EL.md](./Equalis/GAS-ESTIMATES-EL.md) for complete gas analysis.

## Expressiveness and Emergent Instruments

Equalis is intentionally minimal at the core, but it is **highly expressive by construction**.

Because obligations, enforcement, and settlement are deterministic, Equalis does not encode specific financial products so much as it defines a **credit and settlement grammar**. Once credit is represented as explicit commitments with time-based enforcement, a wide range of instruments emerge naturally without requiring new protocol primitives.

One immediate consequence is that positions can reason in absolutes. A loan is not “healthy” or “at risk” in a continuous sense. It is either within its terms or it is not. This allows higher-level instruments to be expressed as combinations of simple, legible states rather than reactive thresholds.

A clear example is option-like behavior.

A **call-like instrument** emerges when a borrower has the right, but not the obligation, to reclaim collateral by repaying a fixed amount before a known maturity. If the borrower chooses not to act, settlement proceeds along the predefined path. The payoff structure mirrors a call option, but enforcement is handled entirely through time and state transitions rather than price feeds or liquidations.

Conversely, a **put-like instrument** can be expressed by allowing early exercise of default. A borrower may choose to forfeit collateral prior to maturity, effectively capping downside and terminating the obligation early. This resembles a put option, where the holder chooses to exit under known terms, without requiring a market to price or settle the option at exercise time.

These behaviors are not special cases. They fall out of Equalis’s core model:

* Explicit collateral encumbrance
* Fixed repayment terms
* Known maturity and grace periods
* Deterministic settlement paths

Because these rules are enforced locally, the system does not need to observe or react to market prices to remain correct.

The same structure enables a broader set of instruments.

Peer-to-peer term loans can be combined with callable or exercisable features to express structured credit products. Rolling credit lines with deterministic payment schedules can be layered into amortizing instruments. Positions themselves can be transferred, allowing entire portfolios of obligations and rights to move as a single unit. Credit exposure can be sliced, time-gated, or delegated without changing the underlying enforcement model.

Importantly, this expressiveness does not come from complexity. It comes from **removing reactivity**.

By eliminating price-triggered enforcement and liquidation races, Equalis makes financial outcomes programmable in the same way state machines are programmable. Builders can reason about edge cases, failure modes, and worst-case outcomes without simulating market behavior or assuming liquidity at enforcement time.

This is especially important for autonomous systems. Agents can select instruments based on provable bounds, choose whether and when to act, and remain idle without risk of involuntary intervention. The protocol does not force behavior in response to transient conditions.

Equalis does not attempt to enumerate every instrument it enables. Instead, it provides a deterministic substrate on which new forms of credit, optionality, and risk transfer can be constructed without expanding the trusted surface area of the system.

In that sense, Equalis is less a product and more a **toolkit for building financial state machines**.

## Capital Efficiency Redefined

Capital efficiency in Equalis is not achieved by pushing utilization or leverage to the limit. It is achieved by **ensuring capital is never unnecessarily downgraded when it takes on risk or responsibility**.

Equalis distinguishes clearly between passive capital and active capital, and it rewards each according to its role.

Idle depositors earn through the **Fee Index**, a monotone, protocol-wide accounting mechanism that distributes system revenue to passive capital. This index is designed to be conservative, predictable, and suitable for users who prioritize safety and long-term capital preservation. Idle depositors are not diluted by active strategies, and their yield does not depend on timing or market conditions.

Active participants in credit formation earn through a separate mechanism, the **Active Credit Index**.

P2P lenders and pool borrowers earn from this index as compensation for deploying capital into active credit relationships. These rewards are time-gated and dilution-resistant, and they are funded by real system activity rather than token inflation. The Active Credit Index exists to reduce the opportunity cost of participation, not to outcompete passive yield.

The most significant consequence of this design appears on the borrower side.

In Equalis, **P2P borrowers continue to earn the full Fee Index on capital locked as collateral**. Collateral does not become economically inert when it is encumbered. A borrower does not forfeit passive yield simply by securing an obligation. Capital remains productive even while it is constrained by explicit commitments.

This separation of yield streams ensures that:

* Passive capital is rewarded for providing stability
* Active capital is compensated for creating credit
* No role is subsidized by another
* No participant must choose between safety and productivity

Capital efficiency in Equalis is therefore not about extracting more leverage from the system. It is about **wasting less capital by avoiding unnecessary economic penalties for participation**.

Capital earns when it is idle.
It continues to earn when it is locked.
And it earns differently when it is actively at work.

## EqualIndex

EqualIndex is a deterministic index primitive designed to make basketized assets **legible, analyzable, and composable without relying on external price oracles**.

Most on-chain index products inherit their behavior from AMMs or reactive pricing models. Asset weights drift with market prices, fees are implicit in swap curves, and the economic outcome of minting or redeeming depends on timing, liquidity conditions, and external arbitrage. While this can work for speculation, it makes index behavior difficult to reason about precisely, especially under stress.

EqualIndex takes a different approach.

An EqualIndex is defined by a **fixed bundle composition**: explicit asset amounts per index unit, explicit mint and burn fees per asset, and explicit fee distribution rules. Minting and redemption are mechanical processes. There is no price discovery, no rebalancing logic, and no dependency on oracle feeds. If the rules allow an action, the outcome is known in advance.

This determinism has several important consequences.

First, EqualIndex makes the cost of entry and exit explicit. Minting requires providing the exact underlying assets in fixed proportions, plus known fees. Burning returns a proportional share of both the underlying assets and accumulated fee pots, subject to known burn fees. There is no hidden slippage, no curve-dependent pricing, and no reliance on secondary market liquidity to make the index whole.

Second, fees are treated as **first-class state**, not as implicit losses embedded in pricing. Fees accumulate in per-asset fee pots and are distributed proportionally to index holders on redemption. This makes yield transparent, auditable, and directly tied to usage rather than to market volatility.

Third, EqualIndex preserves proportional ownership at all times. Minting and burning adjust supply in a way that maintains each holder’s share of the underlying assets and fee pots. Index tokens are not claims on a fluctuating NAV inferred from prices; they are claims on concrete balances tracked on chain.

EqualIndex is intentionally minimal in scope. It does not rebalance portfolios, optimize weights, or attempt to express market views. Those choices are left to users and to higher-level systems. The index itself is a neutral container with explicit rules.

This makes EqualIndex particularly useful as infrastructure.

Because its behavior is deterministic and oracle-free, an EqualIndex can serve as a building block for other protocols, including lending systems, structured products, and autonomous strategies. It can be held, transferred, lent, or used as collateral without introducing hidden reactive dependencies.

In the context of EqualFi, EqualIndex complements Equalis by providing a **predictable, basketized asset primitive** that aligns with the same design philosophy: explicit parameters, bounded outcomes, and correctness that does not depend on external market conditions.

EqualIndex is not positioned as a replacement for reactive index products. It is a different tool, designed for situations where **knowing exactly what you own and how it behaves matters more than tracking a market benchmark**.

## Maker Auction Markets

Maker Auction Markets (MAMs) explore a different market structure for on-chain exchange, one that treats liquidity as an **explicit, enforceable commitment** rather than as a reactive pool state.

Most decentralized markets today are built around continuously priced pools. Liquidity providers deposit assets, prices are derived from curves, and trades execute by moving the pool along that curve. This model is simple and composable, but it exposes several well-known weaknesses: predictable price impact, susceptibility to MEV extraction, reliance on arbitrage for price correction, and implicit guarantees that are only upheld as long as external liquidity exists.

Maker Auction Markets start from a different premise.

In a MAM, liquidity is expressed as **maker-authored offers** with explicit terms. A maker commits assets up front and defines the price, size, and conditions under which they are willing to trade. Trades execute against these commitments directly, without traversing a pricing curve or relying on pool-wide invariants.

This shifts the market from a reactive model to a **commitment-driven model**.

Because prices are authored by makers and enforced by the protocol, there is no implicit repricing in response to trades. There is no curve to exploit and no predictable slippage path for searchers to extract value from. Execution is discrete and bounded by the maker’s stated terms.

This structure has several promising properties.

First, it reduces MEV surface area. Since trades execute against pre-committed offers rather than against a shared pool state, there is less opportunity for sandwiching or backrunning based on predictable price movement. Makers are not exposed to adverse price shifts caused by the act of trading itself.

Second, it makes liquidity intention explicit. Makers are not passively exposed to all possible trades. They choose exactly what they are willing to offer and under what conditions. This allows liquidity provision to be reasoned about as a series of contracts rather than as exposure to an abstract curve.

Third, settlement is deterministic. A trade either matches an existing offer and executes at known terms, or it does not execute at all. There is no dependence on transient pool state, oracle prices, or arbitrage completion to finalize outcomes.

Maker Auction Markets are still an exploratory design. They depart significantly from the dominant AMM paradigm, and there is limited real-world data on how such markets behave at scale. Questions around liquidity fragmentation, price discovery, and user experience remain open and deserve careful study.

That uncertainty is part of the point.

MAMs are not presented as a replacement for automated market makers, but as a complementary market primitive. They are particularly well-suited for environments where **predictability, bounded execution, and resistance to adversarial extraction** are more important than continuous liquidity or instant price convergence.

Within EqualFi, Maker Auction Markets represent an effort to apply the same core philosophy found in Equalis and EqualIndex to exchange itself: explicit commitments, deterministic execution, and minimized reliance on reactive mechanisms.

They are an open research direction, grounded in first principles, and offered for scrutiny, experimentation, and iteration rather than premature certainty.

## Permissionless and Trust-Minimized Infrastructure

EqualFi is built around a simple premise: **financial infrastructure should work without requiring trust in operators, intermediaries, or ongoing coordination**.

This is treated as a first-principles design constraint rather than a philosophical stance. Systems that rely on privileged actors, discretionary intervention, or informal social processes tend to accumulate complexity over time. As that complexity grows, guarantees become harder to reason about and harder to enforce consistently.

EqualFi aims to avoid that failure mode.

The core primitives in this repository are designed to be **permissionless at the point of use**. Participation does not depend on approval, whitelisting, or off-chain relationships. When constraints exist, they are enforced mechanically through protocol rules, not through human judgment or operational discretion.

Trust minimization is achieved through determinism.

Outcomes are governed by explicit parameters, time, and verifiable on-chain state transitions. There are no emergency pathways, discretionary interventions, or hidden backstops that activate under stress. If an action is allowed, its effects are knowable in advance. If it is not allowed, it fails in a predictable way.

Where administrative control is unavoidable, it is intentionally narrow in scope and slow to change. Configuration exists to support safety and iteration, not to manage behavior dynamically. The long-term goal is to reduce reliance on governance rather than to expand it.

EqualFi also avoids unnecessary external dependencies. Core safety properties do not rely on price oracles, trusted keepers, or off-chain execution guarantees. Market behavior and settlement logic are designed to remain correct even if external actors behave adversarially or simply fail to appear.

This approach prioritizes robustness over convenience.

By minimizing trust assumptions and eliminating hidden dependencies, the system becomes easier to reason about, easier to verify, and harder to quietly change. Users and autonomous systems interact with rules, not with operators.

The result is infrastructure that is intentionally constrained in what it assumes and explicit in what it guarantees. Permissionless access and trust minimization are not treated as optional features, but as foundational requirements for building financial systems that can remain stable over long time horizons.

### Call to action

EqualFi is an early-stage research effort exploring deterministic, non-reactive financial primitives.

We are interested in connecting with:

* Builders who want to experiment with alternative credit and market structures
* Market makers curious about non-reactive exchange design
* Researchers focused on protocol design, risk modeling, and system invariants

This repository contains designs and whitepapers intended to be read, challenged, and extended. Feedback, critique, and collaboration are welcome.

If you are interested in engaging with the work, contributing research, or exploring potential collaboration, you can reach out directly:

Email: mhooft@equalfilabs.com

Twitter: @hooftly

EqualFi Labs Discord: https://discord.gg/6amxag7eBZ

### Discliamer

Some documents were drafted with AI assistance. 
