## EqualFi Optimistic Bonded Resolution (OBR) Spec v0.2

Integrated AtomicDesks permissionless settlement with `(txid, tau)` claims

### 0. Purpose

Some EqualFi modules require a resolution system for claims that are not fully derivable from on-chain state. Examples:

* AtomicDesks: Maker refuses to settle an ETH escrow after the XMR leg completed
* Public key registry: key removal requests
* Prediction markets: outcome resolution

OBR is an on-chain optimistic bonding system that:

* Lets anyone assert a claim by posting a bond
* Lets anyone dispute by posting a larger bond
* Finalizes automatically if undisputed
* Resolves disputes via an on-chain bonded vote (default v0.x resolver)
* Triggers domain-specific on-chain actions via a callback

### 0.1 AtomicDesks integration summary

AtomicDesks adds a permissionless “request settlement” path that asserts a claim containing `(swapId, txid, tau)`.

* `tau` is not secret and both sides know it before XMR is sent.
* `tau` is used only as the hashlock preimage on the ETH leg.
* The ETH leg remains secure because only Maker or OBR (not the public) can execute settlement.
* The committee is removed. OBR finalization replaces committee action.

Because L1 cannot natively verify Monero inclusion/payment correctness from `(txid, tau)`, the claim remains optimistic and is protected economically (bond and dispute).

---

## 1. Design goals

### 1.1 Goals

* Fully on-chain lifecycle: assert, dispute, resolve, finalize, distribute bonds
* Permissionless participation: anyone can assert, dispute, and vote by bonding
* Domain extensibility: multiple modules register domains with custom parameters
* Supports binary and small enum outcomes (2 to 8)
* Deterministic finalization: no admin discretion in outcomes or payouts
* Gas bounded: no loops over unbounded participant sets during finalize
* Compatible with Position-backed bonding (encumbrance) as an optional bond source

### 1.2 Non-goals

* Proving off-chain truth in all cases. OBR is trust-minimized, not omniscient.
* Domain-specific committees as a requirement. Domains should use OBR and bonded vote by default.

---

## 2. Terminology

* **Domain**: A module namespace (AtomicDesks, KeyRegistry, IPM)
* **Claim**: A unique question instance in a domain identified by `claimId`
* **Outcome**: A small integer (uint8)
* **Assertion**: Proposed outcome for a claim with an assertion bond
* **Dispute**: Challenge to an assertion with a dispute bond
* **Vote session**: Commit/reveal bonded vote used to resolve disputes
* **Finalization**: Outcome becomes canonical and domain callback executes exactly once

---

## 3. Core lifecycle

### 3.1 Claim states

`None -> Asserted -> (Finalized | Disputed -> Finalized)`

* Asserted: assertion bond locked, liveness window running
* Disputed: dispute bond locked, vote session active
* Finalized: outcome recorded, callback executed, bonds distributed

### 3.2 Deterministic finalization rules

* Undisputed assertions finalize after `assertLiveness`
* Disputed assertions finalize after vote `revealEndsAt`, using a deterministic tally rule

---

## 4. Contracts and responsibilities

### 4.1 Core components

* **ResolutionRegistry**

  * Registers domains and domain parameters
* **ResolutionCore**

  * Assert, dispute, finalize, query outcomes
* **BondVault**

  * Locks and releases bonds (direct and optional position-backed)
* **BondedVoteResolver** (default dispute resolver)

  * Commit/reveal voting, tally, reward accounting

### 4.2 Domain callback interface

```solidity
interface IResolutionDomainCallback {
  function onClaimFinalized(
    uint256 domainId,
    bytes32 claimId,
    uint8 outcome,
    bytes calldata data
  ) external;
}
```

Rules:

* Callback is executed exactly once per finalized claim.
* Callback is invoked only by OBR.
* OBR must update claim state before invoking callback.
* Reentrancy protection is mandatory.

---

## 5. Domain model

### 5.1 Domain configuration

```solidity
struct DomainConfig {
  address owner;                 // domain controller (module)
  address callback;              // implements IResolutionDomainCallback

  uint8 outcomeCount;            // 2..8
  uint64 assertLiveness;         // seconds

  address bondAsset;             // ERC20 or address(0) for ETH
  uint256 minAssertBond;
  uint256 minDisputeBond;

  // Dispute resolver: bonded vote params
  uint64 commitDuration;
  uint64 revealDuration;
  uint256 minVoteBond;

  uint16 voterRewardBps;         // from losing pool to winning voters
  uint16 treasuryFeeBps;         // optional skim
  address treasury;              // optional

  bool paused;
}
```

Notes:

* Domains can tune liveness/bonds per risk profile.
* `outcomeCount` is small and explicit.
* Prediction markets use **one domain per market** to allow per-market bond asset and timing controls.

---

## 6. Claim model

### 6.1 Claim storage

```solidity
enum ClaimState { None, Asserted, Disputed, Finalized }

struct Claim {
  ClaimState state;

  uint256 domainId;
  bytes32 claimId;

  address asserter;
  uint8 assertedOutcome;
  uint64 assertedAt;
  uint64 livenessEndsAt;
  uint256 assertBond;
  bytes32 assertBondKey;

  address disputer;
  uint64 disputedAt;
  uint256 disputeBond;
  bytes32 disputeBondKey;

  bytes32 voteSessionId;

  uint8 finalOutcome;
  uint64 finalizedAt;

  bytes32 dataHash;
  bytes data;                    // optional, size capped
}
```

### 6.2 ClaimId semantics

OBR is claim-agnostic. Domains define `claimId`.

Recommended: `claimId = keccak256(abi.encode(domainTag, subject...))`

---

## 7. Bonding

### 7.1 Bond sources

OBR supports:

* **Direct bonds**: ERC20/ETH escrowed in BondVault
* **Position-backed bonds** (optional): encumbrance-based lock inside protocol accounting

### 7.2 Bond input

```solidity
struct BondInput {
  bool usePosition;
  address asset;       // direct only
  uint256 amount;

  // position-backed only
  uint256 positionId;
  uint256 poolId;
}
```

### 7.3 Gas-safe payouts

OBR must not loop over all voters on finalize. Voter rewards are claimable per voter.

---

## 8. Public API

### 8.1 Domain registry

* `registerDomain(DomainConfig cfg) -> domainId`
* `updateDomain(domainId, cfg)` (owner only)
* `pauseDomain(domainId, paused)` (owner only)
* `getDomain(domainId)`

### 8.2 Assertions and disputes

* `assertOutcome(domainId, claimId, outcome, dataHash, data, bondInput)`
* `dispute(domainId, claimId, bondInput)`
  (v0.2: dispute does not need to specify an alternative outcome)

### 8.3 Finalization

* `finalize(domainId, claimId)` for undisputed
* `finalizeDispute(domainId, claimId)` for disputed after vote completes

---

## 9. Default dispute resolver: Bonded vote

### 9.1 Phases

* Commit phase: submit commitment and lock `minVoteBond`
* Reveal phase: reveal `(outcome, salt)` to count stake
* Finalize: outcome with highest revealed stake wins
* Tie-break: lowest outcome id wins (deterministic)

### 9.2 Incentives

* Losing pool is composed of:

  * Loser assertion/dispute bond (depending on which side loses)
  * Unrevealed voter stakes (treated as losing)
* Distribution:

  * `treasuryFeeBps` skim (optional)
  * `voterRewardBps` distributed to voters who voted for winning outcome (pro-rata)
  * remainder paid to winning side (asserter or disputer)

Voters claim their bond + reward via `claimVotePayout(domainId, claimId)`.

---

## 10. Domain specifications

### 10.1 KeyRegistry domain (example)

* Outcomes: `0=KEEP`, `1=REMOVE`
* Long liveness and meaningful bonds
* Callback: tombstone key on REMOVE

### 10.2 PredictionMarket domain (example)

* Domain scope: **one domain per market**
* Bond asset: configured per market via the domain config
* Outcomes (3): `0=NO_SETTLE`, `1=YES`, `2=NO`
  * `NO_SETTLE` is used for invalid/ambiguous resolutions and triggers **full refunds**
* Callback:
  * `NO_SETTLE` -> enable refunds; users call refund functions to unlock encumbrance
  * `YES/NO` -> set market outcome and enable settlement

---

## 11. AtomicDesks domain: permissionless settlement with `(txid, tau)`

### 11.1 Problem statement

AtomicDesks involves an ETH escrow leg and an XMR leg. The Maker can settle the ETH leg by providing the hashlock preimage `tau`. Historically, only Maker or a committee could call settlement.

When Maker refuses to settle after the XMR leg completes, the system needs a permissionless mechanism to complete ETH settlement without weakening security.

### 11.2 Security constraint (must hold)

**The ETH leg settlement function remains restricted:**

* Only Maker or OBR may execute settlement logic that unlocks ETH escrow.

Public callers must never be able to directly call the privileged settle path.

### 11.3 Core idea

Add a permissionless function that asserts a claim containing `(swapId, txid, tau)` and bonds it.

If the claim finalizes as SETTLE, OBR calls the AtomicDesks callback which invokes the restricted settle path using `tau`.

This replaces the committee with an economically protected, permissionless enforcement mechanism.

### 11.4 AtomicDesks outcomes

Binary outcomes:

* `0 = NO_SETTLE`
* `1 = SETTLE`

If `NO_SETTLE`, the AtomicDesks callback immediately refunds the maker (no safety window),
since the bond failed and the claim is rejected.

### 11.5 Claim encoding and claimId

Claim data (recommended ABI encoding):

* `swapId: bytes32`
* `txid: bytes32` (Monero txid or canonical digest)
* `tau: bytes32` (preimage used for ETH hashlock)
* Optional: `aux` (block height, mailbox reference, etc.)

`data = abi.encode(swapId, txid, tau, aux)`

`dataHash = keccak256(data)`

ClaimId recommendation:

`claimId = keccak256(abi.encode("ATOMIC_SETTLE", swapId, txid, tau))`

### 11.6 Required on-chain guards in `requestSettleWithProof`

AtomicDesks must include a permissionless entrypoint:

`requestSettleWithProof(swapId, txid, tau, aux, bondInput)`

It must enforce:

1. **Swap phase gating**

   * Swap must be in a phase indicating the XMR leg completed and a final mailbox message was posted.
   * Example: `swap.state == XMR_REPORTED_COMPLETE`
   * This prevents early spam assertions before the protocol itself considers XMR completion plausible.

2. **Hashlock compatibility**

   * Verify `tau` matches the stored hashlock:

     * `require(hash(tau) == swap.hashlock)`
   * This ensures the asserted tau is at least structurally consistent with the ETH leg’s lock.

3. **One active claim per swap (anti-grief)**

   * If a settle-claim is active, either:

     * revert, or
     * allow replacement only with a higher bond (domain policy)
   * v0.2 recommendation: revert while active.

4. **Domain enabled**

   * AtomicDesks domain must not be paused.

Then it calls:

`OBR.assertOutcome(domainId, claimId, SETTLE, dataHash, data, bondInput)`

### 11.7 Finalization and privileged settlement

AtomicDesks implements `onClaimFinalized`:

* Verify `msg.sender == OBR`
* Decode `data` into `(swapId, txid, tau, aux)`
* Check the claim corresponds to that swap (optional: compare to stored active claimId)
* If `outcome == SETTLE`, call the same internal settlement routine the Maker uses:

  * `_settleSwapWithTau(swapId, tau)`
* If `outcome == NO_SETTLE`, immediately refund the maker and clear state
  (OBR-authorized refund path, no safety window)
* Mark the swap settled and clear the active claim reference

This preserves the invariant:

* Maker can still call settle normally
* The public cannot call settle directly
* The public can force settlement only by winning the OBR claim lifecycle

### 11.8 Dispute semantics for AtomicDesks

Because L1 cannot verify Monero inclusion/payment correctness from `(txid, tau)` alone:

* The claim is optimistic
* Disputers (watchers, counterparties, third parties) can dispute by bonding
* If undisputed, settlement proceeds
* If disputed, bonded vote resolves the claim

This removes the committee while keeping an economic backstop.

### 11.9 Incentives for permissionless settlement

Third parties are incentivized to run “settlement keepers” because:

* If correct and undisputed, they recover their bond
* If disputed and correct, they can win the disputer’s bond (plus structured voter rewards)

Optional (domain-specific, not required in v0.2):

* Add a small settlement tip paid on successful settlement to the actor who asserted the successful claim, funded by swap fees.

---

## 12. Events (minimum)

* `OutcomeAsserted(domainId, claimId, asserter, outcome, bond, livenessEndsAt)`
* `Disputed(domainId, claimId, disputer, bond)`
* `ClaimFinalized(domainId, claimId, outcome)`
* AtomicDesks domain-specific:

  * `AtomicSettleRequested(swapId, claimId, txid, tau)`
  * `AtomicSettledByOBR(swapId, claimId)`

---

## 13. Security notes

* Finalize must be reentrancy guarded.
* Domain callbacks must be invoked after claim state is finalized.
* Finalize paths must not iterate over all voters.
* AtomicDesks must keep settlement privileged and only callable by Maker or OBR.
* AtomicDesks must phase-gate `requestSettleWithProof` to prevent early or irrelevant claims.

---

## 14. Open items for iteration (explicit)

1. AtomicDesks phase gating definition

   * What exact on-chain state proves “XMR leg finished” in your mailbox model?

2. Replacement policy for active settle claims

   * Strict revert vs allow replacement with higher bond.

3. Whether disputes should require an asserted alternative outcome

   * Current: dispute is a generic challenge, vote selects outcome.

4. Whether AtomicDesks should include a domain-level “settlement tip”

   * Optional, can be deferred.

5. Exact refund mechanics for `NO_SETTLE` (AtomicDesks + prediction markets)

   * Which escrow/refund function should OBR call, and what events should fire?
