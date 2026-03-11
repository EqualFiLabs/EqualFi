# Synthesis ↔ Mailbox Relayer Event Mapping (Phase 1)

Created: 2026-03-11

This document defines how on-chain Synthesis events map to mailbox-relayer ingestion payloads (`POST /events/onchain`).

## Relayer schema reference

Relayer accepts event types:
- `activation`
- `mailbox`
- `breach`
- `default`

Required base fields:
- `chainId`
- `blockNumber`
- `logIndex`
- `agreementId`
- `eventType`

Optional fields used here:
- `provider`
- `traceId`
- `envelope`
- `reason`
- `payload`

---

## Contract events used (Phase 1)

From `AgenticFinancingFacet`:
- `AgreementActivated(uint256 agreementId, uint256 proposalId, uint8 mode, address provider)`
- `AgreementDelinquent(uint256 agreementId, uint256 pastDue, address provider)`
- `AgreementDefaulted(uint256 agreementId, uint256 pastDue, address provider, bytes32 reason)`
- `AgreementTerminated(uint256 agreementId, address provider, bytes32 reason)`

From `AgentMailboxFacet`:
- `BorrowerPayloadPublished(uint256 agreementId, address borrower, address provider, bytes envelope)`
- `ProviderPayloadPublished(uint256 agreementId, address provider, address borrower, bytes envelope)`

---

## Mapping table

| Contract event | Relayer `eventType` | `provider` source | Extra fields |
|---|---|---|---|
| `AgreementActivated` | `activation` | event `provider` | `payload` may include policy/metadata |
| `BorrowerPayloadPublished` | `mailbox` | event `provider` | `envelope` populated by indexer decode step |
| `ProviderPayloadPublished` | `mailbox` | event `provider` | `envelope` populated by indexer decode step |
| `AgreementDelinquent` | `breach` | event `provider` | `reason = "DELINQUENCY"` |
| `AgreementDefaulted` | `default` | event `provider` | `reason = bytes32->string` |
| `AgreementTerminated` | `default` (optional) | event `provider` | `reason = bytes32->string` |

---

## Envelope decode requirement

`mailbox-relayer` currently requires canonical envelope object for mailbox events (`event.envelope`), while Solidity events emit raw `bytes envelope`.

Indexer/bridge requirement:
1. decode `bytes envelope` into canonical envelope JSON (or parse from agreed wire format)
2. submit canonical object in `onchainEvent.envelope`

If raw bytes cannot be decoded, indexer MUST reject and alert rather than submit malformed mailbox events.

---

## Example payloads

### Activation

```json
{
  "chainId": 84532,
  "blockNumber": 123456,
  "logIndex": 3,
  "txHash": "0x...",
  "eventType": "activation",
  "agreementId": "42",
  "provider": "venice",
  "payload": {
    "mode": 1,
    "proposalId": "7"
  }
}
```

### Mailbox

```json
{
  "chainId": 84532,
  "blockNumber": 123457,
  "logIndex": 9,
  "txHash": "0x...",
  "eventType": "mailbox",
  "agreementId": "42",
  "provider": "venice",
  "traceId": "trace-abc",
  "envelope": {
    "version": "equalfi.mailbox.ecies.eth-crypto.v1",
    "recipient": "orchestrator:venice",
    "cipher": {
      "iv": "...",
      "ephemPublicKey": "...",
      "ciphertext": "...",
      "mac": "..."
    },
    "createdAt": "2026-03-11T10:00:00.000Z"
  }
}
```

### Breach

```json
{
  "chainId": 84532,
  "blockNumber": 123458,
  "logIndex": 4,
  "eventType": "breach",
  "agreementId": "42",
  "provider": "venice",
  "reason": "DELINQUENCY"
}
```

### Default

```json
{
  "chainId": 84532,
  "blockNumber": 123459,
  "logIndex": 6,
  "eventType": "default",
  "agreementId": "42",
  "provider": "venice",
  "reason": "COVENANT_BREACH"
}
```

---

## Status

- Phase 1 event surface is sufficient for activation/breach/default routing.
- Mailbox route is sufficient **if** envelope decode/normalization is present in indexer bridge.
