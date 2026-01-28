# EqualX Atomic Desks Design Document

**Version:** 1.0

## 1. Overview

Atomic Desks enable trustless cross-chain atomic swaps between EVM-based assets (ETH, ERC-20 tokens) and Monero (XMR). The system uses CLSAG adaptor signatures to cryptographically bind transactions on both chains, ensuring atomicity without requiring trusted intermediaries.

### 1.1 Design Goals

- **Atomicity**: Either both legs of the swap complete, or neither does
- **Privacy**: Monero transaction details remain private through ring signatures
- **Trustlessness**: No trusted third parties required for successful swaps
- **Collateralization**: EVM assets are fully collateralized by Position NFT principal and encumbrance
- **Settlement Authority**: Only authorized parties (desk makers or committee) can settle swaps

### 1.2 Key Components

1. **AtomicDesk**: Main entry point for creating and managing atomic swap reservations
2. **SettlementEscrow**: Holds collateral and manages settlement/refund logic
3. **Position NFT + Encumbrance**: Pool-level principal accounting and collateral locks
4. **Mailbox**: Encrypted communication channel for adaptor signature exchange
5. **CLSAG Adaptor**: Cryptographic protocol binding EVM and Monero transactions

---

## 2. Architecture

### 2.1 System Components

```
┌─────────────────┐    ┌──────────────────┐    ┌───────────────────────┐
│   AtomicDesk    │────│ SettlementEscrow │────│ Position NFT + Pools  │
│   (Entry Point) │    │  (Collateral)    │    │   (Encumbrance)       │
└─────────────────┘    └──────────────────┘    └───────────────────────┘
         │                       │                       │
         │              ┌─────────────────┐              │
         └──────────────│     Mailbox     │──────────────┘
                        │  (Encrypted     │
                        │ Communication)  │
                        └─────────────────┘
                                 │
                        ┌─────────────────┐
                        │ CLSAG Adaptor   │
                        │   Protocol      │
                        └─────────────────┘
```

### 2.2 Data Flow

1. **Reservation**: Maker creates atomic swap reservation, collateral moves to escrow
2. **Context Exchange**: Taker sends encrypted Monero context via mailbox
3. **Presignature**: Maker responds with encrypted CLSAG adaptor presignature
4. **Completion**: Taker completes signature and broadcasts Monero transaction
5. **Settlement**: Authorized party settles EVM side using revealed adaptor secret

---

## 3. Core Contracts

### 3.1 AtomicDesk Contract

The AtomicDesk contract serves as the primary interface for atomic swap operations.

#### Key Functions

```solidity
function registerDesk(
    uint256 positionId,
    uint256 poolIdA,
    uint256 poolIdB,
    bool baseIsA
) external returns (bytes32 deskId)
```
- Registers a new atomic desk for a Position NFT + pool pair
- Requires the Position NFT owner and pool membership
- Returns unique desk identifier

```solidity
function reserveAtomicSwap(
    bytes32 deskId,
    address taker,
    address asset,
    uint256 amount,
    bytes32 settlementDigest,
    uint64 expiry
) external payable returns (bytes32 reservationId)
```
- Creates a new atomic swap reservation
- Locks collateral via encumbrance on the base pool
- Enforces expiry window constraints
- Authorizes a communication slot in the Mailbox contract

```solidity
function setHashlock(bytes32 reservationId, bytes32 hashlock) external
```
- Sets the hashlock (a commitment to the adaptor secret τ)
- Stored in SettlementEscrow reservation storage
- Only callable by the desk maker
- Can only be set once per reservation

#### Access Control

- **Desk Registration**: Position NFT owner with pool membership
- **Reservation Creation**: Only registered desk makers
- **Hashlock Setting**: Only the desk maker for that reservation

#### State Management

```solidity
struct DeskConfig {
    bytes32 positionKey;
    uint256 positionId;
    uint256 poolIdA;
    uint256 poolIdB;
    address tokenA;
    address tokenB;
    bool baseIsA;
    bool active;
    address maker;
}

struct Reservation {
    bytes32 reservationId;
    bytes32 deskId;
    bytes32 positionKey;
    uint256 positionId;
    address desk;
    address taker;
    uint256 poolIdA;
    uint256 poolIdB;
    address tokenA;
    address tokenB;
    bool baseIsA;
    address asset;
    uint256 amount;
    bytes32 settlementDigest;
    bytes32 hashlock;
    uint256 counter;
    uint64 expiry;
    uint64 createdAt;
    ReservationStatus status;
}
```

### 3.2 SettlementEscrow Contract

Manages collateral holding and settlement logic. It is a protocol-wide component used by Atomic Desks and other system components like the Router.

#### Key Functions

```solidity
function setHashlock(bytes32 reservationId, bytes32 hashlock) external
function settle(bytes32 reservationId, bytes32 tau) external
```
- Settles reservation by revealing adaptor secret
- Validates hashlock: `keccak256(tau) == hashlock`
- Transfers collateral to taker
- Only callable by desk maker or committee

```solidity
function refund(bytes32 reservationId, bytes32 noSpendEvidence) external
function getReservation(bytes32 reservationId) external view returns (Reservation)
```
- Emergency refund after safety window expires
- Only callable by committee members
- Unlocks collateral without moving assets

#### Security Model

- **Settlement Authority**: Restricted to desk maker or committee members
- **Hashlock Validation**: Cryptographic proof of Monero spend knowledge
- **Time Locks**: Safety window prevents premature refunds
- **Committee Oversight**: Multi-signature committee can intervene

### 3.3 Position NFT + Encumbrance Integration

Atomic Desk integrates with Position NFT collateral and the encumbrance system.

#### Collateral Flow

1. **Reserve**: `reserveAtomicSwap` locks base collateral via encumbrance.
2. **Settle**:
   - Unlock collateral.
   - Settle fee and active credit indexes.
   - Decrease principal/totalDeposits/trackedBalance by `amount`.
   - Transfer base asset to taker.
3. **Refund**: Unlock collateral only (no asset transfer).

---

## 4. Cryptographic Protocol

### 4.1 CLSAG Adaptor Signatures

The system uses CLSAG (Concise Linkable Spontaneous Anonymous Group) adaptor signatures to bind EVM and Monero transactions cryptographically.

#### Key Properties

- **Adaptor Secret (τ)**: Shared value that unlocks both transactions. τ is committed on-chain as a hashlock and becomes extractable from the completed signature; makers/committee should settle only after observing the Monero spend.
- **Hashlock**: `H(τ)` committed on EVM side before Monero spend
- **Signature Binding**: CLSAG signature mathematically linked to settlement digest
- **Privacy Preservation**: No Monero transaction details revealed on EVM

#### Protocol Flow

1. **Setup**: Maker chooses τ, commits `H(τ)` as hashlock
2. **Context**: Taker provides Monero transaction context (encrypted)
3. **Presignature**: Maker creates biased CLSAG signature with τ
4. **Completion**: Taker completes signature, broadcasts Monero transaction
5. **Extraction**: Anyone can extract τ from completed signature
6. **Settlement**: τ used to unlock EVM collateral

### 4.2 Settlement Digest Binding

```solidity
settlementDigest = keccak256(abi.encodePacked(
    counter,        // global reservation counter
    positionKey,    // Position NFT binding
    quoteToken,
    baseToken,
    taker,
    desk,
    chainId
))
```

This digest ensures:
- Unique binding per swap
- Prevention of replay attacks
- Cross-chain context integrity
- Deterministic settlement verification

---

## 5. Communication Layer

### 5.1 Mailbox System

The Mailbox contract provides encrypted, authenticated communication between swap participants.

#### Message Types

1. **Context Message**: Taker → Desk (Monero transaction context)
2. **Presignature Message**: Desk → Taker (CLSAG adaptor presignature)  
3. **TxProof Message**: Taker → Desk (reservationId + Monero txid + optional metadata)

#### Encryption Scheme

- **Algorithm**: ChaCha20-Poly1305
- **Key Exchange**: Secp256k1 ECDH
- **Authentication**: AAD binding to reservation context
- **Replay Protection**: Per-reservation nonces

#### Authorization Model

```solidity
mapping(uint256 => bool) internal slotAuthorized;

function authorizeReservation(bytes32 reservationId) external
function revokeReservation(bytes32 reservationId) external
```

- Slots authorized only during active reservations
- Automatic revocation on settlement/refund
- Prevents unauthorized message posting

### 5.2 Public Key Management

```solidity
function registerPubkey(bytes calldata pubkey) external
```

- Desks register secp256k1 public keys for encryption
- Keys validated on-chain for correctness
- Used for encrypting responses to desk makers

---

## 6. Operational Flows

### 6.1 Happy Path: Successful Swap

```mermaid
sequenceDiagram
    participant T as Taker
    participant AD as AtomicDesk
    participant SE as SettlementEscrow
    participant P as Pools/Encumbrance
    participant MB as Mailbox
    participant M as Maker
    participant XMR as Monero Network

    M->>AD: registerDesk(positionId, poolIdA, poolIdB, baseIsA)
    
    M->>AD: reserveAtomicSwap(deskId, taker, asset, amount, digest, expiry)
    Note right of AD: Orchestrates collateral reservation
    AD->>P: lockCollateral(positionKey, basePoolId, amount)
    SE->>MB: authorizeReservation(reservationId)
    
    M->>SE: setHashlock(reservationId, H(τ))
    
    T->>MB: publishContext(reservationId, encryptedContext)
    M->>MB: publishPreSig(reservationId, encryptedPresig)
    T->>MB: publishFinalSig(reservationId, encryptedFinalSig)
    
    T->>XMR: broadcastTransaction(completedCLSAG)
    
    M->>SE: settle(reservationId, τ)
    SE->>P: unlockCollateral(positionKey, basePoolId, amount)
    SE-->>T: transfer(amount)
```

### 6.2 Refund Path: Failed Swap

```mermaid
sequenceDiagram
    participant C as Committee
    participant SE as SettlementEscrow
    participant P as Pools/Encumbrance
    participant M as Maker
    participant XMR as Monero Network

    Note over C: Wait for safety window
    C->>XMR: verifyNoSpend(expectedTxId)
    C->>SE: refund(reservationId, noSpendEvidence)
    SE->>P: unlockCollateral(positionKey, basePoolId, amount)
```

### 6.3 Error Handling

#### Timeout Scenarios
- **Expiry Before Settlement**: Reservation becomes eligible for refund
- **Safety Window**: Committee can refund after verifying no Monero spend
- **Mailbox Timeout**: Messages expire with reservation

#### Cryptographic Failures
- **Invalid Hashlock**: Settlement reverts if `H(τ) ≠ hashlock`
- **Signature Verification**: Off-chain validation before settlement
- **Extraction Mismatch**: Committee can verify τ consistency

#### Access Control Violations
- **Unauthorized Settlement**: Only desk maker or committee can settle
- **Invalid Reservations**: Strict validation of all parameters
- **Mailbox Authorization**: Messages rejected for unauthorized slots

---

## 7. Security Model

### 7.1 Threat Model

#### Assumptions
- EVM blockchain security (finality, censorship resistance)
- Monero network security (ring signature anonymity)
- Committee honesty for refund decisions
- Cryptographic primitives (ECDH, ChaCha20-Poly1305, CLSAG)

#### Attack Vectors

- **Front-running**: Prevented by encrypted mailbox and hashlock commitment
- **Replay Attacks**: Prevented by unique settlement digests and nonces  
- **Collateral Theft**: Prevented by access control and cryptographic proofs
- **Privacy Leakage**: Prevented by encrypted communication and ring signatures
- **Griefing**: Mitigated by expiry windows and committee oversight

### 7.2 Access Control Matrix

| Function | Maker | Taker | Committee | Public |
|----------|-------|-------|-----------|--------|
| Register Desk | ✓ | ✗ | ✗ | ✗ |
| Reserve Swap | ✓ | ✗ | ✗ | ✗ |
| Set Hashlock | ✓ | ✗ | ✗ | ✗ |
| Publish Context | ✗ | ✓ | ✗ | ✗ |
| Publish PreSig | ✓ | ✗ | ✗ | ✗ |
| Publish FinalSig | ✗ | ✓ | ✗ | ✗ |
| Settle | ✓ | ✗ | ✓ | ✗ |
| Refund | ✗ | ✗ | ✓ | ✗ |
| View Reservation | ✓ | ✓ | ✓ | ✓ |

### 7.3 Economic Security

#### Collateralization
- All EVM assets fully collateralized by Position NFT principal and encumbrance
- No fractional reserves or lending
- Atomic settlement prevents partial execution

#### Incentive Alignment
- Makers earn fees for providing liquidity
- Takers get guaranteed execution or refund
- Committee incentivized through governance tokens

#### Risk Management
- Expiry windows limit exposure time
- Safety windows prevent premature refunds
- Committee oversight for edge cases

---

## 8. Integration Patterns

### 8.1 Maker Integration

```solidity
// 1. Setup desk
atomicDesk.registerDesk(positionId, poolIdA, poolIdB, baseIsA);

// 2. Create reservation
bytes32 reservationId = atomicDesk.reserveAtomicSwap(
    deskId, taker, asset, amount, settlementDigest, expiry
);

// 3. Set hashlock
escrow.setHashlock(reservationId, keccak256(abi.encodePacked(tau)));

// 4. Handle mailbox messages
mailbox.publishPreSig(reservationId, encryptedPresig);

// 5. Settle when ready
escrow.settle(reservationId, tau);
```

### 8.2 Taker Integration

```solidity
// 1. Verify reservation exists
AtomicTypes.Reservation memory reservation = atomicDesk.getReservation(reservationId);

// 2. Send Monero context
mailbox.publishContext(reservationId, encryptedContext);

// 3. Wait for presignature
bytes[] memory messages = mailbox.fetch(reservationId);

// 4. Complete signature and broadcast Monero transaction
// (off-chain Monero operations)

// 5. Provide final signature
mailbox.publishFinalSig(reservationId, encryptedFinalSig);
```

### 8.3 Committee Integration

```solidity
// Monitor for stuck reservations
function monitorReservations() external {
    // Check for expired reservations
    // Verify Monero network for spends
    // Execute refunds when appropriate
    
    if (shouldRefund(reservationId)) {
        escrow.refund(reservationId, noSpendEvidence);
    }
}
```

---

## 9. Configuration and Deployment

### 9.1 Contract Dependencies

```solidity
// Deployment order
1. PositionNFT
2. Diamond (AtomicDeskFacet + SettlementEscrowFacet)
3. Mailbox(escrow = diamond)
4. EncPubRegistry

// Configuration
escrow.configureMailbox(mailbox);
escrow.configureAtomicDesk(diamond); // optional override
escrow.setRefundSafetyWindow(3 days);
escrow.setCommittee(member, true);
```

### 9.2 Parameters

```solidity
uint64 public constant MIN_EXPIRY_WINDOW = 5 minutes;  // AtomicDesk
uint64 public refundSafetyWindow = 3 days;             // SettlementEscrow
uint256 public constant MAX_ENVELOPE_BYTES = 4096;     // Mailbox
```

### 9.3 Governance

- **Governor Role**: Can update committee membership, safety windows
- **Committee Members**: Can execute refunds, settle on behalf of makers
- **Wiring Authority**: One-time configuration of contract addresses
- **Makers**: Control their own desks and reservations

---

## 10. Monitoring and Observability

### 10.1 Key Events

```solidity
// AtomicDesk
event ReservationCreated(bytes32 indexed reservationId, bytes32 indexed deskId, ...);
event HashlockSet(bytes32 indexed reservationId, bytes32 hashlock);
event DeskRegistered(bytes32 indexed deskId, address indexed maker, bool baseIsA);

// SettlementEscrow  
event ReservationSettled(bytes32 indexed reservationId, bytes32 tau);
event ReservationRefunded(bytes32 indexed reservationId, bytes32 evidence);

// Mailbox
event ContextPublished(bytes32 indexed reservationId, address indexed taker, bytes envelope);
event PreSigPublished(bytes32 indexed reservationId, address indexed desk, bytes envelope);
event FinalSigPublished(bytes32 indexed reservationId, address indexed poster, bytes envelope);
```

### 10.2 Health Metrics

- **Active Reservations**: Number of pending atomic swaps
- **Settlement Rate**: Percentage of successful vs. refunded swaps
- **Average Settlement Time**: Time from reservation to settlement
- **Collateral Utilization**: Percentage of desk inventory in escrow
- **Committee Response Time**: Time to process refunds

### 10.3 Alerting

- **Stuck Reservations**: Reservations approaching safety window
- **Failed Settlements**: Invalid τ values or hashlock mismatches
- **Committee Actions**: All refund operations
- **Large Reservations**: High-value swaps requiring attention

---

## 11. Future Enhancements

### 11.1 FCMP Integration

- Support for Full-Chain Membership Proofs (FCMP)
- Enhanced privacy through larger anonymity sets
- Backward compatibility with CLSAG-based swaps

### 11.2 Multi-Asset Support

- Atomic swaps involving multiple EVM tokens
- Complex settlement patterns (e.g., token A + token B → XMR)
- Cross-chain routing through multiple atomic desks

### 11.3 Advanced Features

- **Partial Fills**: Support for splitting large orders
- **Time-Locked Settlements**: Delayed settlement for privacy
- **Batch Operations**: Multiple swaps in single transaction
- **Fee Optimization**: Dynamic fee structures based on market conditions

---

## 12. Conclusion

Atomic Desks provide a robust, trustless mechanism for cross-chain atomic swaps between EVM assets and Monero. The system leverages cryptographic adaptor signatures to ensure atomicity while preserving Monero's privacy properties. The modular architecture allows for future enhancements while maintaining security and decentralization.

Key benefits:
- **Trustless Operation**: No intermediaries or custodians required
- **Privacy Preservation**: Monero transaction details remain confidential  
- **Full Collateralization**: All EVM assets backed by real inventory
- **Flexible Integration**: Compatible with Position NFT + encumbrance accounting
- **Committee Oversight**: Safety mechanisms for edge cases
