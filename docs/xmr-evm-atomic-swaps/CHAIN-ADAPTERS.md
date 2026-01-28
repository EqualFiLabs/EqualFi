# Chain-Agnostic SDK + Starknet Porting Notes

This doc explains how the Rust SDK is being made chain-agnostic so the same
off-chain swap logic can drive both EVM and Starknet deployments. It is written
for future developers and AI assistants so they can extend the system without
breaking protocol compatibility.

## Goals

- Keep the swap protocol logic and wire formats identical across chains.
- Isolate chain-specific concerns behind adapters (transport, call encoding,
  hashing that is enforced on-chain).
- Ensure the encrypted mailbox and secp256k1 pubkey registry behave the same
  on both systems.

## Non-Negotiable Protocol Invariants

These must remain identical across chains:

- **Mailbox envelope format** (see `atomic/crates/presig-envelope`):
  - Envelopes are encrypted with secp256k1 ECDH.
  - Public keys are 33-byte compressed secp256k1 points.
  - HKDF salt: `EqualX v1 presig`.
- **Settlement context** (`chain_tag`, `position_key`, `settle_digest`):
  - Canonical bytes are defined in `atomic/crates/equalx-sdk/src/settlement.rs`.
  - `chain_tag` is a UTF-8 string that names the chain domain
    (example: `evm:8453`, `starknet:SN_MAIN`).
  - `position_key` is a 32-byte binding for the desk/reservation identity.
- **CLSAG adaptor transcript** (see `atomic/docs/CLSAG-ADAPTOR-SPEC.md`):
  - Uses SHA3 for ring/message/settlement hashes.
  - `position_key` is part of the transcript binding.

If you change any of these, you must regenerate vectors and update all
cross-chain verification logic.

## Chain Adapter Surface (Rust SDK)

The SDK now exposes chain-agnostic traits in
`atomic/crates/equalx-sdk/src/chain.rs`:

- `KeyRegistryApi`
- `MailboxApi`
- `SettlementEscrowApi`

There is also a minimal, chain-agnostic `ReservationView` and
`ReservationStatus` type.

### Current Implementations

EVM adapters are already wired:

- `KeyRegistryClient` implements `KeyRegistryApi`.
- `MailboxClient` implements `MailboxApi`.
- `SettlementEscrowClient` implements `SettlementEscrowApi`.

These adapters use the existing EVM ABI bindings and transports under
`atomic/crates/equalx-sdk/src/contracts` and `transport`.

### How to Add a New Chain Adapter

1. **Choose ID and address types**:
   - EVM uses `FixedBytes<32>` for reservation ids and `Address` for accounts.
   - Starknet likely uses `felt252` for reservation ids and `ContractAddress`.
   - The adapter should convert its native types into `ReservationView` while
     preserving the canonical 32-byte fields (`settlement_digest`, `hashlock`).
2. **Implement the traits**:
   - Add a new client (e.g. `StarknetMailboxClient`) and implement `MailboxApi`.
   - Same for `KeyRegistryApi` and `SettlementEscrowApi`.
3. **Keep wire payloads stable**:
   - Envelope bytes are opaque and must remain unchanged.
   - Pubkey encoding remains 33-byte compressed secp256k1.
4. **Decouple hashlocks by chain**:
   - EVM uses `keccak256(tau)` on-chain today.
   - Starknet uses `pedersen(low(tau), high(tau))` (see Cairo escrow).
   - The adapter should compute the chain-specific hashlock; do not bake a
     single hash function into core swap logic.

## On-Chain Components

### EVM

The EVM stack is already implemented in Solidity under `src/EqualX` and is
bound in the SDK via Alloy-generated bindings.

Key contracts:

- `Mailbox.sol`
- `EncPubRegistry.sol`
- `SettlementEscrowFacet.sol`

### Starknet (Cairo 2)

The Starknet contracts live in `starknet/`:

- `starknet/src/enc_pub_registry.cairo`
- `starknet/src/mailbox.cairo`
- `starknet/src/atomic_escrow.cairo`

Current behavior mirrors the EVM flow but with Starknet-native data types.
The escrow uses Pedersen hashing for hashlocks and uses a `felt252` reservation
id computed on-chain.

## Hashing Rules

There are two different hashing contexts in the protocol:

1. **Transcript and settlement context**:
   - Uses SHA3 (see `atomic/crates/adaptor-clsag` and
     `atomic/crates/equalx-sdk/src/settlement.rs`).
   - This is chain-agnostic and must not change.
2. **On-chain hashlocks**:
   - EVM contracts: `keccak256(tau)` (current Solidity behavior).
   - Starknet contracts: `pedersen(low(tau), high(tau))` (current Cairo behavior).

Because the on-chain hashlock function differs, the SDK must compute the
hashlock *through the chain adapter* rather than a single global helper.
This is the required compatibility mechanism.

## Secp256k1 Pubkey Validation

All systems use compressed secp256k1 pubkeys (33 bytes).

Compatibility requirement:

- The SDK and both chains must reject invalid points.
- EVM already validates the full curve equation.
- Starknet currently validates prefix + length only; full curve validation
  must be added to match EVM semantics.

When you implement full validation in Cairo:

- Use `x` in field Fp with `p = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F`.
- Check that `y^2 = x^3 + 7 (mod p)` and that the prefix parity matches `y`.
- Reject `x == 0` or `x >= p`.

Do not change the 33-byte format or any envelope wire formats.

## Reservation IDs and Endianness

Reservation identifiers are chain-native:

- EVM uses `bytes32` (ABI aligned).
- Starknet uses `felt252` (251-bit field).

The SDK should treat reservation IDs as adapter-specific types but expose a
stable 32-byte representation inside `ReservationView` for transcript binding
and logging, if needed. Avoid implicit endianness conversions; if conversion is
required, document it in the adapter.

## Where to Extend Next

If you are adding Starknet support to the SDK:

1. Create Starknet transport and client types under `atomic/crates/equalx-sdk`
   (new module is expected; keep it separate from `transport` which is EVM-only).
2. Implement `KeyRegistryApi`, `MailboxApi`, and `SettlementEscrowApi`.
3. Add a chain-specific hashlock helper (Pedersen for Starknet).
4. Add tests that run the same swap flow against mocked EVM and Starknet
   adapters to ensure identical off-chain behavior.

## Files to Read First

- `atomic/crates/equalx-sdk/src/chain.rs`
- `atomic/crates/equalx-sdk/src/settlement.rs`
- `atomic/crates/presig-envelope/src/lib.rs`
- `atomic/docs/CLSAG-ADAPTOR-SPEC.md`

## Known Gaps (as of now)

- Starknet contracts still need full secp256k1 pubkey validation to match EVM.
- The SDK hashlock helper is still EVM-specific; add a chain-aware hashlock
  function or per-chain helper.
- Starknet SDK transport and clients are not implemented yet.
