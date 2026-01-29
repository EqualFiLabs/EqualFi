# ERC-8004 Implementation - Design Document

**Version:** 1.0  
**Standard:** [ERC-8004: Trustless Agents](https://eips.ethereum.org/EIPS/eip-8004) (Draft)

---

## Table of Contents

1. [Overview](#overview)
2. [How It Works](#how-it-works)
3. [Architecture](#architecture)
4. [Agent Registration](#agent-registration)
5. [Agent URI Management](#agent-uri-management)
6. [Metadata System](#metadata-system)
7. [Agent Wallet Verification](#agent-wallet-verification)
8. [Transfer Behavior](#transfer-behavior)
9. [Data Models](#data-models)
10. [View Functions](#view-functions)
11. [Integration Guide](#integration-guide)
12. [Error Reference](#error-reference)
13. [Events](#events)
14. [Security Considerations](#security-considerations)

---

## Overview

This implementation brings ERC-8004 (Trustless Agents) compliance to Position NFTs using a Diamond-forwarded architecture. Position NFTs serve as the ERC-8004 Identity Registry, enabling each position to function as a discoverable, trustless agent with verifiable payment addresses and extensible metadata.

### What is ERC-8004?

ERC-8004 is a draft Ethereum standard that enables agent discovery and trust establishment across organizational boundaries. It defines three lightweight registries:

- **Identity Registry**: ERC-721-based agent registration with URI resolution to registration files
- **Reputation Registry**: Feedback signals for agent scoring (not implemented in this release)
- **Validation Registry**: Independent validator checks (not implemented in this release)

This implementation focuses on the Identity Registry, extending Position NFTs to serve as agent identities.

### Key Characteristics

| Feature | Description |
|---------|-------------|
| **Diamond-Forwarded** | ERC-8004 logic lives in upgradeable Diamond facets while PositionNFT remains the registry address |
| **ERC-721 Compatible** | Agents are immediately browsable and transferable with NFT-compliant apps |
| **Verified Wallets** | Agent payment addresses require cryptographic proof via EIP-712 or ERC-1271 |
| **Extensible Metadata** | Key-value metadata storage for arbitrary agent attributes |
| **Transfer-Safe** | Agent wallets automatically reset on NFT transfer with nonce invalidation |

### System Participants

| Role | Description |
|------|-------------|
| **Agent Owner** | Position NFT holder who controls the agent identity |
| **Operator** | Approved address that can manage agent metadata on behalf of owner |
| **Agent Wallet** | Verified payment address where the agent receives funds |
| **Indexer** | External service that discovers agents via registry events |

---

## How It Works

### The Agent Identity Model

Each Position NFT represents a unique agent identity in the ERC-8004 ecosystem. The NFT's `tokenId` serves as the `agentId`, and the PositionNFT contract address serves as the Identity Registry.

**Global Agent Identifier:**
```
agentRegistry: eip155:{chainId}:{positionNFTAddress}
agentId: {tokenId}
```

### Registration File Resolution

The `agentURI` stored on-chain resolves to a registration file containing:
- Agent name and description
- Communication endpoints (A2A, MCP, REST, etc.)
- Supported trust models
- Cross-chain registrations

### Wallet Verification Flow

To prevent unauthorized payment address claims, setting an agent wallet requires:
1. The new wallet signs an EIP-712 typed message (EOA) or validates via ERC-1271 (smart contract)
2. The signature includes a nonce for replay protection
3. On successful verification, the wallet is stored as protected metadata

---

## Architecture

### Contract Structure

```
src/erc8004/
├── PositionNFTIdentityFacet.sol    # Registration, URI, and metadata management
├── PositionNFTWalletFacet.sol      # Agent wallet verification with EIP-712/ERC-1271
└── PositionNFTViewFacet.sol        # Read-only query functions

src/libraries/
├── LibERC8004Storage.sol           # Diamond storage for ERC-8004 data
└── ERC8004Errors.sol               # Custom error definitions
```

### High-Level Component Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                    ERC-8004 Implementation                       │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                    PositionNFT (ERC-721)                  │   │
│  │              Identity Registry Address                    │   │
│  │         Forwards ERC-8004 calls to Diamond               │   │
│  └──────────────────────────────────────────────────────────┘   │
│                              │                                  │
│                              ▼                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                    Diamond Proxy                          │   │
│  │  ┌────────────────┐ ┌────────────────┐ ┌──────────────┐  │   │
│  │  │   Identity     │ │    Wallet      │ │    View      │  │   │
│  │  │    Facet       │ │    Facet       │ │    Facet     │  │   │
│  │  └────────────────┘ └────────────────┘ └──────────────┘  │   │
│  └──────────────────────────────────────────────────────────┘   │
│                              │                                  │
│                              ▼                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                 LibERC8004Storage                         │   │
│  │    agentURIs │ metadata │ agentNonces                    │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Facet Responsibilities

| Facet | Responsibility | Key Functions |
|-------|---------------|---------------|
| **PositionNFTIdentityFacet** | Agent registration and metadata | `register`, `setAgentURI`, `getMetadata`, `setMetadata` |
| **PositionNFTWalletFacet** | Wallet verification | `setAgentWallet`, `onAgentTransfer`, `DOMAIN_SEPARATOR` |
| **PositionNFTViewFacet** | Read-only queries | `getAgentWallet`, `getAgentNonce`, `getIdentityRegistry` |

---

## Agent Registration

### Process

New agents are created by minting a Position NFT with optional URI and metadata:

```solidity
// Minimal registration
function register() external returns (uint256 agentId);

// Registration with URI
function register(string calldata agentURI) external returns (uint256 agentId);

// Full registration with metadata
function register(
    string calldata agentURI, 
    MetadataEntry[] calldata metadata
) external returns (uint256 agentId);
```

### Registration Steps

1. Mint a new Position NFT to the caller
2. Store the `agentURI` (if provided)
3. Store each metadata entry (if provided)
4. Emit `Registered` event with agentId, URI, and owner
5. Emit `MetadataSet` events for each metadata entry

**Note:** ERC-8004 allows empty `agentURI` registrations. We track explicit per-agent registration state (`registered[agentId]`) so downstream systems (e.g., reputation gating) can distinguish registered agents from unregistered PNFTs.


### Metadata Entry Structure

```solidity
struct MetadataEntry {
    string metadataKey;    // Arbitrary key (except "agentWallet")
    bytes metadataValue;   // Arbitrary bytes value
}
```

### Reserved Keys

The key `"agentWallet"` is reserved and cannot be set via `setMetadata()` or during registration. It can only be modified through the verified `setAgentWallet()` function.

---

## Agent URI Management

### Setting the Agent URI

```solidity
function setAgentURI(uint256 agentId, string calldata newURI) external;
```

**Requirements:**
- Caller must be owner or approved operator
- Agent must exist (valid tokenId)

**Supported URI Schemes:**
- `https://` - Standard web URLs
- `ipfs://` - IPFS content identifiers
- `data:application/json;base64,` - On-chain base64-encoded JSON

### Reading the Agent URI

```solidity
function getAgentURI(uint256 agentId) external view returns (string memory);
```

Returns the stored URI string, or empty string if not set.

### Registration File Format

The `agentURI` should resolve to a JSON file following the ERC-8004 specification:

```json
{
  "type": "https://eips.ethereum.org/EIPS/eip-8004#registration-v1",
  "name": "position-{tokenId}",
  "description": "Position NFT - Isolated account container",
  "image": "data:image/svg+xml;base64,{svg}",
  "endpoints": [
    { "name": "web", "endpoint": "https://app.example.com/positions/{tokenId}" },
    { "name": "REST", "endpoint": "https://api.example.com/v1/positions/{tokenId}" }
  ],
  "x402Support": false,
  "active": true,
  "registrations": [
    {
      "agentId": "{tokenId}",
      "agentRegistry": "eip155:{chainId}:{positionNFTAddress}"
    }
  ],
  "supportedTrust": []
}
```

---

## Metadata System

### Setting Metadata

```solidity
function setMetadata(
    uint256 agentId, 
    string calldata metadataKey, 
    bytes calldata metadataValue
) external;
```

**Requirements:**
- Caller must be owner or approved operator
- Key must not be `"agentWallet"` (reserved)

### Reading Metadata

```solidity
function getMetadata(
    uint256 agentId, 
    string calldata metadataKey
) external view returns (bytes memory);
```

Returns the stored bytes value, or empty bytes if not set.

### Storage Implementation

Metadata is stored using keccak256 hashing of keys for gas efficiency:

```solidity
// Storage structure
mapping(uint256 => mapping(bytes32 => bytes)) metadata;

// Key derivation
bytes32 keyHash = keccak256(bytes(metadataKey));
```

### Common Metadata Keys

| Key | Value Type | Description |
|-----|------------|-------------|
| `"agentWallet"` | `abi.encode(address)` | Verified payment address (reserved) |
| `"description"` | `bytes(string)` | Agent description |
| `"capabilities"` | `bytes(json)` | Supported capabilities |
| `"version"` | `bytes(string)` | Agent version |

---

## Agent Wallet Verification

### Overview

The agent wallet is a verified payment address that requires cryptographic proof of control. This prevents unauthorized claims and ensures payments reach the intended recipient.

### Setting the Agent Wallet

```solidity
function setAgentWallet(
    uint256 agentId,
    address newWallet,
    uint256 deadline,
    bytes calldata signature
) external;
```

**Parameters:**
- `agentId`: The Position NFT tokenId
- `newWallet`: The address to set as agent wallet
- `deadline`: Unix timestamp after which the signature expires
- `signature`: EIP-712 signature (EOA) or ERC-1271 signature (smart contract)

### EIP-712 Typed Data

For EOA wallets, the signature must be over the following typed data:

```solidity
bytes32 constant SET_AGENT_WALLET_TYPEHASH = keccak256(
    "SetAgentWallet(uint256 agentId,address newWallet,uint256 nonce,uint256 deadline)"
);
```

**Domain Separator:**
```solidity
EIP712Domain {
    name: "PositionNFT",
    version: "1",
    chainId: {chainId},
    verifyingContract: {positionNFTAddress}
}
```

### ERC-1271 Smart Contract Wallets

For smart contract wallets, the signature is validated by calling:

```solidity
function isValidSignature(bytes32 hash, bytes memory signature) 
    external view returns (bytes4 magicValue);
```

The wallet must return `0x1626ba7e` to indicate a valid signature.

### Nonce Management

Each agent maintains a nonce that increments on:
- Successful `setAgentWallet` calls
- NFT transfers (via `onAgentTransfer`)

This prevents signature replay attacks and invalidates pending signatures on transfer.

### Verification Flow

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│  New Wallet │     │   Owner/    │     │   Diamond   │
│             │     │  Operator   │     │             │
└──────┬──────┘     └──────┬──────┘     └──────┬──────┘
       │                   │                   │
       │  Sign EIP-712     │                   │
       │  message          │                   │
       │◄──────────────────│                   │
       │                   │                   │
       │  Return signature │                   │
       │──────────────────►│                   │
       │                   │                   │
       │                   │  setAgentWallet   │
       │                   │  (agentId,        │
       │                   │   newWallet,      │
       │                   │   deadline, sig)  │
       │                   │──────────────────►│
       │                   │                   │
       │                   │                   │ Verify deadline
       │                   │                   │ Verify signature
       │                   │                   │ Store wallet
       │                   │                   │ Increment nonce
       │                   │                   │
       │                   │  emit MetadataSet │
       │                   │◄──────────────────│
       │                   │                   │
```

---

## Transfer Behavior

### Automatic Wallet Reset

When a Position NFT is transferred to a new owner, the agent wallet is automatically reset to prevent the previous owner from receiving payments:

```solidity
function onAgentTransfer(uint256 agentId) external;
```

**Called by:** PositionNFT contract during `_update` hook  
**Effects:**
- Sets `agentWallet` to `address(0)`
- Increments the agent nonce (invalidates pending signatures)
- Emits `MetadataSet` event

### Transfer Scenarios

| Scenario | Wallet Reset | Nonce Increment |
|----------|--------------|-----------------|
| Transfer to new owner | Yes | Yes |
| Transfer to self | No | No |
| Mint (from zero address) | No | No |
| Burn (to zero address) | No | No |

### Post-Transfer Setup

After receiving a Position NFT, the new owner must:
1. Generate a new EIP-712 signature from their wallet
2. Call `setAgentWallet` with the new signature
3. Update the `agentURI` if needed

---

## Data Models

### On-Chain Storage

```solidity
struct ERC8004Storage {
    // Agent URI storage (agentId => URI string)
    mapping(uint256 => string) agentURIs;

    // Registration state (agentId => registered)
    mapping(uint256 => bool) registered;

    // Metadata storage (agentId => keccak256(key) => value)
    mapping(uint256 => mapping(bytes32 => bytes)) metadata;
    
    // Per-agent nonces for replay protection (agentId => nonce)
    mapping(uint256 => uint256) agentNonces;
}
```

### Storage Slot

```solidity
bytes32 constant ERC8004_STORAGE_POSITION = 
    keccak256("equal.lend.position.nft.erc8004.storage");
```

---

## View Functions

### PositionNFTViewFacet

```solidity
// Get the verified agent wallet address
function getAgentWallet(uint256 agentId) external view returns (address);

// Get the current nonce for signature verification
function getAgentNonce(uint256 agentId) external view returns (uint256);

// Get the Identity Registry address (PositionNFT contract)
function getIdentityRegistry() external view returns (address);

// Check whether an agentId has been registered
function isAgent(uint256 agentId) external view returns (bool);
```

### PositionNFTIdentityFacet

```solidity
// Get the agent URI
function getAgentURI(uint256 agentId) external view returns (string memory);

// Get metadata value for a key
function getMetadata(uint256 agentId, string calldata metadataKey) 
    external view returns (bytes memory);
```

### PositionNFTWalletFacet

```solidity
// Get the EIP-712 domain separator
function DOMAIN_SEPARATOR() external view returns (bytes32);

// Get the SetAgentWallet typehash
function SET_AGENT_WALLET_TYPEHASH() external pure returns (bytes32);
```

---

## Integration Guide

### For Developers

#### Registering a New Agent

```solidity
// Simple registration
uint256 agentId = identityFacet.register();

// Registration with URI
uint256 agentId = identityFacet.register("ipfs://QmAgent...");

// Full registration with metadata
PositionNFTIdentityFacet.MetadataEntry[] memory metadata = 
    new PositionNFTIdentityFacet.MetadataEntry[](2);
metadata[0] = PositionNFTIdentityFacet.MetadataEntry({
    metadataKey: "description",
    metadataValue: bytes("My agent description")
});
metadata[1] = PositionNFTIdentityFacet.MetadataEntry({
    metadataKey: "version",
    metadataValue: bytes("1.0.0")
});

uint256 agentId = identityFacet.register("https://example.com/agent.json", metadata);
```

#### Setting Agent Wallet (EOA)

```javascript
// 1. Build the typed data
const domain = {
    name: "PositionNFT",
    version: "1",
    chainId: chainId,
    verifyingContract: positionNFTAddress
};

const types = {
    SetAgentWallet: [
        { name: "agentId", type: "uint256" },
        { name: "newWallet", type: "address" },
        { name: "nonce", type: "uint256" },
        { name: "deadline", type: "uint256" }
    ]
};

const nonce = await viewFacet.getAgentNonce(agentId);
const deadline = Math.floor(Date.now() / 1000) + 3600; // 1 hour

const message = {
    agentId: agentId,
    newWallet: walletAddress,
    nonce: nonce,
    deadline: deadline
};

// 2. Sign with the new wallet
const signature = await wallet._signTypedData(domain, types, message);

// 3. Submit from owner/operator account
await walletFacet.setAgentWallet(agentId, walletAddress, deadline, signature);
```

#### Querying Agent Information

```solidity
// Get agent wallet
address wallet = viewFacet.getAgentWallet(agentId);

// Get agent URI
string memory uri = identityFacet.getAgentURI(agentId);

// Check whether an agentId has been registered
bool isRegistered = viewFacet.isAgent(agentId);

// Get custom metadata
bytes memory description = identityFacet.getMetadata(agentId, "description");
```

### For Indexers

#### Discovering Agents

Listen for `Registered` events to discover new agents:

```solidity
event Registered(
    uint256 indexed agentId, 
    string agentURI, 
    address indexed owner
);
```

#### Tracking URI Updates

Listen for `URIUpdated` events:

```solidity
event URIUpdated(
    uint256 indexed agentId, 
    string newURI, 
    address indexed updatedBy
);
```

#### Tracking Metadata Changes

Listen for `MetadataSet` events:

```solidity
event MetadataSet(
    uint256 indexed agentId,
    string indexed indexedMetadataKey,
    string metadataKey,
    bytes metadataValue
);
```

---

## Error Reference

### Access Control Errors

| Error | Description |
|-------|-------------|
| `ERC8004_Unauthorized(address caller, uint256 agentId)` | Caller is not owner or approved operator |
| `ERC8004_InvalidAgent(uint256 agentId)` | Agent ID does not exist |

### Metadata Errors

| Error | Description |
|-------|-------------|
| `ERC8004_ReservedMetadataKey(string key)` | Attempted to set reserved "agentWallet" key via setMetadata |

### Signature Errors

| Error | Description |
|-------|-------------|
| `ERC8004_DeadlineExpired(uint256 deadline, uint256 currentTime)` | Signature deadline has passed |
| `ERC8004_InvalidSignature()` | Signature verification failed |
| `ERC8004_InvalidSignatureLength(uint256 length)` | EOA signature must be 65 bytes |
| `ERC8004_NonceAlreadyUsed(uint256 agentId, uint256 nonce)` | Signature uses a previously consumed nonce |

### ERC-1271 Errors

| Error | Description |
|-------|-------------|
| `ERC8004_ERC1271ValidationFailed(address wallet)` | Smart contract wallet returned invalid magic value |

---

## Events

### Registration Events

```solidity
// Emitted when a new agent is registered
event Registered(
    uint256 indexed agentId, 
    string agentURI, 
    address indexed owner
);

// Emitted when agent URI is updated
event URIUpdated(
    uint256 indexed agentId, 
    string newURI, 
    address indexed updatedBy
);
```

### Metadata Events

```solidity
// Emitted when any metadata is set (including agentWallet)
event MetadataSet(
    uint256 indexed agentId,
    string indexed indexedMetadataKey,
    string metadataKey,
    bytes metadataValue
);
```

---

## Security Considerations

### Signature Security

- **Deadline Enforcement**: All wallet signatures include a deadline to prevent indefinite validity
- **Nonce Protection**: Per-agent nonces prevent signature replay attacks
- **Transfer Invalidation**: Nonces increment on transfer, invalidating any pending signatures

### Access Control

- **Owner/Operator Model**: Only NFT owner or approved operators can modify agent data
- **Reserved Keys**: The `agentWallet` key cannot be set via generic metadata functions
- **Wallet Verification**: Payment addresses require cryptographic proof of control

### Smart Contract Wallet Support

- **ERC-1271 Validation**: Smart contract wallets are supported via standard interface
- **Magic Value Check**: Strict validation of the `0x1626ba7e` return value
- **Static Call**: Validation uses `staticcall` to prevent state modifications

### Transfer Safety

- **Automatic Reset**: Agent wallets reset to zero on transfer
- **Nonce Increment**: Pending signatures become invalid after transfer
- **No Inherited Permissions**: New owners must re-verify their wallet

### URI Security

- **No On-Chain Validation**: URI content is not validated on-chain
- **Off-Chain Verification**: Consumers should verify registration file integrity
- **Domain Verification**: Optional `.well-known` endpoint verification per ERC-8004

---

## Deployment

### Facet Deployment Order

1. Deploy `PositionNFTIdentityFacet`
2. Deploy `PositionNFTWalletFacet`
3. Deploy `PositionNFTViewFacet`
4. Add facets to Diamond via `diamondCut`
5. Configure PositionNFT to call `onAgentTransfer` during transfers

### Migration Notes

- Existing Position NFTs have empty `agentURI` and no metadata
- Owners can call `setAgentURI` to add registration files
- `agentWallet` starts as `address(0)` for all existing positions
- No data migration required
