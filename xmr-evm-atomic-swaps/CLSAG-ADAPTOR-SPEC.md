# CLSAG Adaptor Signature Specification

**Version:** 1.0

---

## 0. Purpose

EqualX uses a CLSAG "adaptor-style" flow to bind an EVM reservation (`swapId`/`settlementDigest`) to a specific Monero spend, while keeping Monero transaction details off the EVM chain (mailbox ciphertext only).

Core guarantees:

- EVM chain observers do not learn Monero transaction internals (ring, key image, signature) from on-chain calls; mailbox messages are encrypted.
- Settlement on EVM is gated by an authorized caller (desk and/or committee) who verifies the Monero spend off-chain before calling `settle`.
- The adaptor scalar **τ** is used as the escrow hashlock preimage. τ is not secret—it is known to the maker up-front and committed as `hashlock = keccak256(τ)`. τ provides liveness: once the Monero transaction is broadcast, τ can be extracted and used to settle the EVM side.
- Monero privacy properties remain those of standard RingCT/CLSAG.

This document defines:

- Transcript structure
- Deterministic τ and index derivation
- Index selection
- PreSig artifact and mailbox container formats
- Required bindings to `settlementDigest` and `swapId`
- Verification expectations for authorized settlers

---

## 1. Cryptographic Model

### Curve

- Ed25519 (Monero CLSAG / RingCT)
- Order ℓ = 2²⁵² + … − 27742317777372353535851937790883648493

### Signature Form

A CLSAG signature has components:

```
(c1, s[0], s[1], …, s[n-1])
```

One index `j` holds a biased response:

```
ŝ[j] = s[j] + τ  mod ℓ
```

All other responses are standard CLSAG responses.

### Adaptor Completion

Taker completes:

```
s[j] = ŝ[j] - τ mod ℓ
```

### Extraction

Anyone can compute:

```
τ = (ŝ[j] - s[j]) mod ℓ
```

Extraction is possible after the final signature is seen.

---

## 2. Transcript Specification

The transcript binds CLSAG-related artifacts to:

- settlementDigest (EVM-side binding for this reservation)
- swapId (reservationId == swapId)
- Monero message hash m
- ring public keys
- keyImage
- chosen response index j
- backend identifier

### 2.1 Namespace

```
"EqualX/0.0.1/CLSAG-Adaptor"
```

### 2.2 Transcript Fields

Transcript T binds the following:

```
T = Transcript(
    namespace,
    ring_hash,            // Sha3_256(ring public keys)
    key_image,            // 32B
    m,                    // Sha3_256(CLSAG message bytes)
    j,                    // response index
    swapId,               // uint256 reservationId from SettlementEscrow
    chain_tag,            // binding (e.g. "evm:31337")
    position_key,         // binding (bytes32)
    settlementDigest,     // 32B digest built by AtomicDesk/SDK for this reservation
    backendId=0x01        // CLSAG backend
)
```

These fields guarantee:

- Swap cannot be reused across reservations
- Adaptor cannot be replayed across auctions
- Pre/final signatures correspond to the same settlementDigest
- Desk cannot mix contexts to deceive taker
- Signature transcripts match the encrypted mailbox presigContainer

### 2.3 Deterministic Nonces

CLSAG signing nonces are produced by the underlying signing implementation. Some tooling supports a deterministic mode for test vectors.

### 2.4 Adaptor Secret and Settlement Gating

The adaptor scalar **τ** is known before the Monero spend (chosen by the maker and hashed into the escrow as `hashlock = keccak256(τ)`). τ is not treated as sufficient evidence of the Monero spend on its own.

Authorized settlers (desk and/or committee) must:

1. Verify `keccak256(τ) == hashlock` on EVM for the reservation
2. Verify the Monero transaction referenced by the delivered `txid` exists and satisfies swap policy (confirmations, destination/amount rules, etc.)
3. Optionally (recommended) cross-check τ against the on-chain signature material by extracting it from the pre/final signature pair:

```
τ = (ŝ[j] - s[j]) mod ℓ
```

This extraction provides a cryptographic linkage between the presig artifact and the finalized Monero spend, but is not required if the protocol instead relies on off-chain transaction verification plus escrow authorization controls.

---

## 3. Admissible Index j

The index `j` is computed deterministically from bound context:

```
j = HashToInt(
      ring_hash || key_image || mDigest || swapId || settlement_hash
    ) mod n
```

where `settlement_hash = Sha3_256(chain_tag || 0x00 || position_key || settlementDigest)`.

---

## 4. PreSig Container

Tooling constructs a PreSig artifact (often serialized as JSON for debugging/UX) and sends it through the mailbox as an encrypted envelope.

### Fields

```
struct PreSig {
    c1_tilde: scalar                  // CLSAG c1 from the biased pre-signature
    s_tilde[]: [scalar; n]            // CLSAG responses with exactly one biased entry
    D_tilde: point                    // CLSAG D point
    pseudo_out: point                 // pseudo-output commitment for the input
    j: u32                            // biased response index
    settlement_ctx: { chain_tag, position_key, settle_digest }
    pre_hash: bytes32                 // binding hash used for consistency checks
}
```

### Rules

- All scalars mod ℓ
- Points canonical (compressed Ed25519 form)
- `pre_hash` is the Sha3_256 digest of the concatenated preimage: `ring_hash || message_hash || j_bytes || swap_id || settlement_hash`. This deterministically binds the CLSAG pre-signature to the swap context.
- `sTilde_j` = s[j] + τ mod ℓ
- Mailbox payloads are size-constrained; implementations should remain within mailbox limits.

Desk must not include any private information; only public ring data.

---

## 5. FinalSig Container

The taker replaces only one coordinate:

```
s[j] = sTilde[j] - τ mod ℓ
```

FinalSig:

```
struct ClsagFinalSig {
    ring[]: same as PreSig
    keyImage
    mDigest
    j
    swapId
    settlementDigest
    s[]: [s_0, …, s_n-1]
    c1
    pre_hash
}
```

Verification steps use standard CLSAG verification with challenge re-creation.

After constructing `ClsagFinalSig`, the taker finalizes and broadcasts the Monero transaction directly. Instead of shipping the signature through the mailbox, the taker provides only the `(reservationId, moneroTxId)` TxProof envelope so desks and committees know which transaction to inspect when deriving τ.

---

## 6. Verification Rules

Implementations must satisfy:

1. **Signature Validity**
   CLSAG verify(finalSig) = true

2. **Extraction Consistency (Recommended)**
   If τ is extracted from on-chain signature material, `(sTilde[j] - s[j]) mod ℓ` must equal the τ used for settlement.

3. **Binding Consistency**
   `pre_hash` must match the expected binding for the provided context and index selection.

4. **Encoding Canonicality**
   All points canonical; all scalars reduced

5. **Context Equality**
   PreSig and FinalSig must bind the same:
   - `j`
   - `swapId`
   - `settlementDigest` (and any settlement context fields in use)

6. **Index Stability**
   `j` must equal the deterministic index as per §3.

---

## 7. Settlement Context Usage

The taker's Monero context must embed:

```
settlementDigest = H(
    auctionId,
    deskId,
    quoteIn,
    baseOut,
    takerAddr,
    deskAddr,
    chainId
)
```

Identical to what SettlementEscrow stores.

This ensures:

- CLSAG commit cannot be reused for a different reservation
- Collateral can only be unlocked for this exact swap
- Desk cannot replay the adaptor signature to claim funds

---

## 8. Mailbox Integration

The mailbox:

- Encrypts Monero context taker → desk
- Encrypts presig desk → taker
- Encrypts a tx-proof (containing the Monero txid) taker → desk so the maker/committee can verify the spend off-chain
- Enforces authorization from SettlementEscrow
- Binds AAD = `(chainId, SettlementEscrow, swapId, settlementDigest, mDigest, makerAddr, takerAddr, version)`

Failing AAD recovery causes decryption failure.

---

## 9. Extraction Path

Once the Monero tx is broadcast (or the desk receives the encrypted tx-proof with the txid):

- Final CLSAG is visible to the maker and committee
- PreSig is already known to both parties
- Optional extraction can occur:

```
τ = (ŝ[j] - s[j]) mod ℓ
```

This τ is then supplied to:

```
SettlementEscrow.settle(swapId, τ)
```

Contract checks:

```
keccak256(τ) == hashlock
caller ∈ {desk, committee}
```

Collateral is released to the taker.

Executors or third parties cannot settle because:

- `settle` is access-controlled on-chain (authorized callers only)
- Authorized callers are expected to verify the Monero spend off-chain before settling

---

## 10. Conformance Test Matrix

Implementations must include the following tests:

### Positive

- finalSig verifies successfully

### Negative

- Mismatched `swapId` / `settlementDigest` must fail binding checks
- Mismatched `pre_hash` must fail binding checks

### Extraction

- If extraction is performed, `(sTilde[j] - s[j]) mod ℓ == τ`

### Transcript Parity

- Mismatched settlementDigest must cause binding checks (and/or extraction consistency checks) to fail

### Index Tests

- Deterministic `j` derived from bound context

### Encoding

- Invalid points fail
- Non-reduced scalars rejected

---

## 11. Canonical Serialization

All fields serialize as:

- Scalars: 32B LE
- Points: 32B compressed Ed25519
- Arrays: length-prefixed vectors
- swapId: uint256 BE or LE depending on SDK/contract alignment (EqualX uses BE32 for hashing; SDK must match exactly)
- settlementDigest: raw bytes32

Rust and Solidity must reproduce identical bytes ("canonical test vector") before mainnet deployment.

---

## 12. Security Rationale

EqualX's adaptor layer inherits CLSAG's anonymity while restoring deterministic atomicity:

- Desk cannot finalize swap without taker completing the Monero transaction
- Desk cannot front-run
- Desk cannot impersonate taker
- Taker privacy preserved (no ring data on-chain)
- SettlementDigest binds both chains
- τ is a hashlock preimage; authorized settlers verify the XMR spend off-chain before using it on EVM
- No solvency assumptions
- Committee watchers can extract τ post-broadcast as a consistency check if they have the corresponding preSig

---

## 13. Reference Implementations

Rust crates:

- `adaptor-clsag`
- `tx_builder`
- `presig-envelope`
- `monero-oxide` (key management & dalek ops)

All incorporate deterministic transcript derivations and canonical encodings defined here.
