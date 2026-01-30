# Position Agent System: Detailed Design Document

## Executive Summary

The Position Agent System transforms Position NFTs into autonomous, discoverable agents on the Ethereum network. By combining ERC-6551 Token Bound Accounts (TBAs) with ERC-6900 Modular Smart Contract Accounts (MSCAs) and ERC-8004 agent identity, each Position NFT becomes a programmable entity capable of holding assets, executing transactions, and participating in the broader agent ecosystem.

This document provides a comprehensive technical specification for integrators, auditors, and developers working with the Position Agent System.

---

## Table of Contents

1. [System Overview](#1-system-overview)
2. [Architecture](#2-architecture)
3. [Core Components](#3-core-components)
4. [Standards Compliance](#4-standards-compliance)
5. [Data Models](#5-data-models)
6. [Operational Flows](#6-operational-flows)
7. [Module System](#7-module-system)
8. [Security Model](#8-security-model)
9. [Integration Guide](#9-integration-guide)
10. [Deployment & Configuration](#10-deployment--configuration)
11. [Appendices](#11-appendices)

---

## 1. System Overview

### 1.1 Vision

The Position Agent System enables Position NFTs to act as first-class agents in the ERC-8004 ecosystem. Each position becomes:

- **Discoverable**: Registered in the canonical ERC-8004 Identity Registry for global indexing
- **Autonomous**: Capable of holding assets and executing transactions via its TBA
- **Extensible**: Supports third-party modules for custom behaviors (strategies, automation, risk controls)
- **Transferable**: Agent identity automatically follows Position NFT ownership

### 1.2 Key Benefits

| Benefit | Description |
|---------|-------------|
| **Global Discovery** | Agents indexed by standard ERC-8004 tooling without custom configuration |
| **Standards Alignment** | Uses canonical ERC-6551 and ERC-8004 registries |
| **Ownership Binding** | Agent identity follows Position NFT ownership automatically |
| **Modular Extensibility** | Third-party modules extend capabilities without protocol redeployment |
| **ERC-4337 Ready** | Compatible with account abstraction for gas sponsorship and batched operations |

### 1.3 Design Principles

1. **Use Canonical Registries**: Leverage existing ERC-6551 and ERC-8004 infrastructure rather than custom implementations
2. **Clean-Room Implementation**: ERC-6900 MSCA derived solely from published standards (no GPL code)
3. **Permissionless Modules**: No allowlists; any module can be installed with owner authorization
4. **Minimal On-Chain State**: Agent metadata lives off-chain; on-chain stores only essential mappings
5. **Defense in Depth**: Multiple layers of authorization and validation

---

## 2. Architecture

### 2.1 High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           EXTERNAL ECOSYSTEM                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│  ┌──────────────┐    ┌──────────────────┐    ┌────────────────────────┐    │
│  │   ERC-4337   │    │   ERC-8004       │    │   Third-Party          │    │
│  │   Bundlers   │    │   Indexers       │    │   Applications         │    │
│  └──────┬───────┘    └────────┬─────────┘    └───────────┬────────────┘    │
└─────────┼─────────────────────┼──────────────────────────┼──────────────────┘
          │                     │                          │
          ▼                     ▼                          ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         CANONICAL REGISTRIES                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│  ┌────────────────────────┐         ┌─────────────────────────────────┐    │
│  │   ERC-6551 Registry    │         │   ERC-8004 Identity Registry    │    │
│  │   (TBA Factory)        │         │   (Agent Identity)              │    │
│  │   0x0000...6551        │         │   0x8004...                     │    │
│  └───────────┬────────────┘         └──────────────┬──────────────────┘    │
└──────────────┼──────────────────────────────────────┼────────────────────────┘
               │                                      │
               │ creates                              │ mints Identity NFT
               ▼                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         POSITION AGENT LAYER                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌─────────────────┐      controls      ┌─────────────────────────────┐    │
│  │  Position NFT   │ ─────────────────► │  Token Bound Account (TBA)  │    │
│  │  (ERC-721)      │                    │  (ERC-6900 MSCA)            │    │
│  │                 │                    │                             │    │
│  │  tokenId: 42    │                    │  • Holds assets             │    │
│  │  owner: 0xAlice │                    │  • Executes transactions    │    │
│  └─────────────────┘                    │  • Validates signatures     │    │
│                                         │  • Runs modules             │    │
│                                         └──────────────┬──────────────┘    │
│                                                        │                    │
│                                                        │ owns               │
│                                                        ▼                    │
│                                         ┌─────────────────────────────┐    │
│                                         │  ERC-8004 Identity NFT      │    │
│                                         │  (Agent Identity)           │    │
│                                         │                             │    │
│                                         │  agentId: 123               │    │
│                                         │  agentURI: ipfs://...       │    │
│                                         │  agentWallet: TBA address   │    │
│                                         └─────────────────────────────┘    │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 2.2 Ownership Chain

```
┌──────────────┐     owns      ┌──────────────┐    controls    ┌─────────────┐
│   EOA/Wallet │ ────────────► │ Position NFT │ ─────────────► │     TBA     │
│   (0xAlice)  │               │  (tokenId)   │                │   (MSCA)    │
└──────────────┘               └──────────────┘                └──────┬──────┘
                                                                      │
                                                                      │ owns
                                                                      ▼
                                                               ┌─────────────┐
                                                               │ Identity NFT│
                                                               │  (agentId)  │
                                                               └─────────────┘
```

When the Position NFT transfers, the entire ownership chain automatically updates:
- New owner gains control of the TBA (inherent ERC-6551 behavior)
- Identity NFT remains in the TBA
- `agentWallet` remains valid (set to TBA address)

### 2.3 Component Interaction Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           DIAMOND PROXY                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌─────────────────────┐  ┌─────────────────────┐  ┌─────────────────────┐ │
│  │ PositionAgentTBA    │  │ PositionAgentReg    │  │ PositionAgentView   │ │
│  │ Facet               │  │ Facet               │  │ Facet               │ │
│  ├─────────────────────┤  ├─────────────────────┤  ├─────────────────────┤ │
│  │ • computeTBAAddress │  │ • recordAgentReg    │  │ • getTBAAddress     │ │
│  │ • deployTBA         │  │ • getIdentityReg    │  │ • getAgentId        │ │
│  │ • getTBAImpl        │  │                     │  │ • isAgentRegistered │ │
│  │ • getERC6551Reg     │  │                     │  │ • isTBADeployed     │ │
│  └──────────┬──────────┘  └──────────┬──────────┘  │ • getCanonicalRegs  │ │
│             │                        │             │ • getTBAInterface   │ │
│             │                        │             └─────────────────────┘ │
│             │                        │                                      │
│             ▼                        ▼                                      │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                    LibPositionAgentStorage                          │   │
│  ├─────────────────────────────────────────────────────────────────────┤   │
│  │  • erc6551Registry        • positionToAgentId (mapping)             │   │
│  │  • erc6551Implementation  • tbaDeployed (mapping)                   │   │
│  │  • identityRegistry       • tbaSalt                                 │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
│  ┌─────────────────────┐                                                    │
│  │ PositionAgentConfig │  (Admin functions for registry configuration)     │
│  │ Facet               │                                                    │
│  └─────────────────────┘                                                    │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Core Components

### 3.1 Position NFT

The Position NFT is the core protocol asset representing an isolated account container. It serves as the anchor for the entire agent identity system.

**Key Properties:**
- Standard ERC-721 token
- Ownership determines TBA control
- Transferable with full agent identity preservation

### 3.2 Token Bound Account (TBA)

The TBA is an ERC-6551 account implementation using the ERC-6900 Modular Smart Contract Account (MSCA) architecture.

**Contract:** `PositionMSCA` / `PositionMSCAImpl`

**Capabilities:**
- Execute arbitrary calls on behalf of the Position NFT owner
- Hold ERC-20, ERC-721, ERC-1155 tokens and native ETH
- Validate signatures (ERC-1271)
- Support modular validation and execution via ERC-6900
- Compatible with ERC-4337 account abstraction

**Key Interfaces Implemented:**

| Interface | Purpose |
|-----------|---------|
| `IERC6900Account` | Modular account management |
| `IAccount` | ERC-4337 user operation validation |
| `IAccountExecute` | ERC-4337 execution |
| `IERC6551Account` | Token bound account semantics |
| `IERC6551Executable` | TBA execution interface |
| `IERC1271` | Smart contract signature validation |
| `IERC165` | Interface detection |
| `IERC721Receiver` | Safe NFT reception |

### 3.3 ERC-8004 Identity NFT

The Identity NFT is minted by the canonical ERC-8004 Identity Registry and represents the agent's on-chain identity.

**Properties:**
- Owned by the TBA (not the EOA)
- `agentWallet` set to TBA address
- `tokenURI` points to off-chain registration file
- Globally discoverable by ERC-8004 indexers

### 3.4 Diamond Facets

The protocol uses the Diamond pattern (EIP-2535) for upgradeability. Position Agent functionality is implemented across four facets:

| Facet | Responsibility |
|-------|----------------|
| `PositionAgentTBAFacet` | TBA address computation and deployment |
| `PositionAgentRegistryFacet` | Agent registration recording and verification |
| `PositionAgentViewFacet` | Read-only queries for agent state |
| `PositionAgentConfigFacet` | Admin configuration of registry addresses |

---

## 4. Standards Compliance

### 4.1 ERC-6551: Token Bound Accounts

The system uses the canonical ERC-6551 registry for deterministic TBA deployment.

**Registry Address (all EVM chains):** `0x000000006551c19487814612e58FE06813775758`

**TBA Address Derivation:**
```
TBA_Address = CREATE2(
    registry,
    salt,
    keccak256(
        implementation_bytecode ++
        abi.encode(salt, chainId, tokenContract, tokenId)
    )
)
```

**Key Functions:**
- `account(implementation, salt, chainId, tokenContract, tokenId)` - Compute address
- `createAccount(implementation, salt, chainId, tokenContract, tokenId)` - Deploy TBA

### 4.2 ERC-6900: Modular Smart Contract Accounts

The TBA implementation follows ERC-6900 for modular extensibility.

**Core Concepts:**

| Concept | Description |
|---------|-------------|
| **Validation Module** | Authorizes execution (user ops, runtime calls, signatures) |
| **Execution Module** | Adds new callable functions to the account |
| **Validation Hook** | Pre-validation checks (permissions, limits) |
| **Execution Hook** | Pre/post execution checks (policies, logging) |
| **Module Entity** | Packed reference: module address (20 bytes) + entity ID (4 bytes) |

**Module Installation:**
```solidity
// Install validation module
account.installValidation(
    validationConfig,  // Packed: module + entityId + flags
    selectors,         // Which selectors this validation applies to
    installData,       // Data passed to module.onInstall()
    hooks              // Associated validation/execution hooks
);

// Install execution module
account.installExecution(
    module,           // Module contract address
    manifest,         // Execution functions, hooks, interface IDs
    installData       // Data passed to module.onInstall()
);
```

### 4.3 ERC-8004: Agent Identity

The system uses the canonical ERC-8004 Identity Registry for agent registration.

**Registry Addresses:**

| Chain | Address |
|-------|---------|
| Ethereum Mainnet | `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432` |
| Ethereum Sepolia | `0x8004A818BFB912233c491871b3d84c89A494BD9e` |

**Key Functions:**
- `register(agentURI)` - Mint Identity NFT with metadata URI
- `setAgentURI(agentId, newURI)` - Update agent metadata
- `setAgentWallet(agentId, newWallet, deadline, signature)` - Update payment address

### 4.4 ERC-4337: Account Abstraction

The MSCA is compatible with ERC-4337 for bundler-based transaction submission.

**Supported Features:**
- `validateUserOp` for bundler validation
- `executeUserOp` for custom execution routing
- EntryPoint nonce management
- Paymaster compatibility

**EntryPoint Integration:**
```solidity
function validateUserOp(
    PackedUserOperation calldata userOp,
    bytes32 userOpHash,
    uint256 missingAccountFunds
) external returns (uint256 validationData);
```

### 4.5 ERC-1271: Smart Contract Signatures

The TBA validates signatures on behalf of the Position NFT owner.

**Signature Flow:**
1. External contract calls `isValidSignature(hash, signature)`
2. TBA delegates to configured validation module
3. Module verifies EIP-712 signature against Position NFT owner
4. Returns `0x1626ba7e` (valid) or `0xffffffff` (invalid)

---

## 5. Data Models

### 5.1 On-Chain Storage

**LibPositionAgentStorage:**
```solidity
struct AgentStorage {
    // Canonical registry addresses
    address erc6551Registry;        // ERC-6551 TBA factory
    address erc6551Implementation;  // MSCA implementation contract
    address identityRegistry;       // ERC-8004 Identity Registry
    
    // Fixed salt for TBA derivation
    bytes32 tbaSalt;                // Default: bytes32(0)
    
    // Position NFT tokenId => ERC-8004 agentId
    mapping(uint256 => uint256) positionToAgentId;
    
    // Position NFT tokenId => TBA deployed flag
    mapping(uint256 => bool) tbaDeployed;
}
```

**MSCAStorage (ERC-7201 Namespaced):**
```solidity
struct Layout {
    // Selector -> execution module data
    mapping(bytes4 => ExecutionData) executionData;
    
    // Selector -> execution hooks
    mapping(bytes4 => HookConfig[]) selectorExecHooks;
    
    // Validation function -> validation data
    mapping(ModuleEntity => ValidationData) validationData;
    
    // Validation function -> validation hooks
    mapping(ModuleEntity => HookConfig[]) validationHooks;
    
    // Validation function -> execution hooks
    mapping(ModuleEntity => HookConfig[]) validationExecHooks;
    
    // Supported interface IDs (from modules)
    mapping(bytes4 => uint256) supportedInterfaces;
    
    // Installed modules tracking
    mapping(address => bool) installedModules;
    
    // Hook execution guards
    uint256 hookDepth;
    bool hookExecutionActive;
}
```

### 5.2 Type Definitions

```solidity
/// @dev Packed module function reference: module address (20 bytes) + entity ID (4 bytes)
type ModuleEntity is bytes24;

/// @dev Packed validation config: module address (20 bytes) + entity ID (4 bytes) + flags (1 byte)
type ValidationConfig is bytes25;

/// @dev Packed hook config: module address (20 bytes) + entity ID (4 bytes) + flags (1 byte)
type HookConfig is bytes25;

/// @dev Validation flags bit layout:
/// bit 0: isUserOpValidation
/// bit 1: isSignatureValidation
/// bit 2: isGlobal
type ValidationFlags is uint8;

/// @dev Hook flags bit layout:
/// bit 0: hook type (0 = exec, 1 = validation)
/// bit 1: hasPost (exec hooks only)
/// bit 2: hasPre (exec hooks only)
type HookFlags is uint8;
```

### 5.3 Off-Chain Registration File

The agent's registration file is stored off-chain (IPFS/HTTPS) and referenced by the Identity NFT's `tokenURI`.

**Schema:**
```json
{
  "type": "https://eips.ethereum.org/EIPS/eip-8004#registration-v1",
  "name": "EqualLend Position #42",
  "description": "EqualLend Position NFT - Isolated account container with ERC-6551 TBA",
  "image": "ipfs://{cid}/position-42.svg",
  "endpoints": [
    { "name": "web", "endpoint": "https://app.equallend.com/positions/42" },
    { "name": "REST", "endpoint": "https://api.equallend.com/v1/positions/42" }
  ],
  "x402Support": false,
  "active": true,
  "registrations": [
    {
      "agentId": "123",
      "agentRegistry": "eip155:1:0x8004A169FB4a3325136EB29fA0ceB6D2e539a432"
    }
  ],
  "supportedTrust": [],
  "position": {
    "positionKey": "0x...",
    "positionNFT": "0x...",
    "positionTokenId": "42",
    "tbaAddress": "0x...",
    "createdAt": "2025-01-30T12:00:00Z"
  }
}
```

### 5.4 Module Metadata Schema

Modules should publish metadata for discoverability:

```json
{
  "type": "equallend.module.v1",
  "name": "Pool Manager Module",
  "version": "1.0.0",
  "description": "Automated pool management for Position TBAs.",
  "authors": ["Example Labs"],
  "license": "MIT",
  "source": "https://github.com/example/pool-module",
  "audits": [
    { "auditor": "AuditCo", "report": "https://.../report.pdf", "commit": "..." }
  ],
  "interfaces": ["IERC6900ExecutionModule", "IERC165"],
  "selectors": ["0x....", "0x...."],
  "permissions": {
    "canTransferTokens": true,
    "canExecuteArbitraryCalls": false
  },
  "registrations": [
    { "moduleRegistry": "eip155:1:0xRegistry", "moduleId": "123" }
  ],
  "reputation": {
    "registry": "eip155:1:0xReputationRegistry",
    "moduleId": "123"
  }
}
```

---

## 6. Operational Flows

### 6.1 TBA Deployment Flow

```
┌──────────┐                    ┌─────────────┐                    ┌──────────────┐
│  User    │                    │   Diamond   │                    │ ERC-6551 Reg │
│ (Owner)  │                    │   (Facet)   │                    │              │
└────┬─────┘                    └──────┬──────┘                    └──────┬───────┘
     │                                 │                                  │
     │  deployTBA(positionTokenId)     │                                  │
     │────────────────────────────────►│                                  │
     │                                 │                                  │
     │                                 │  Verify caller is Position owner │
     │                                 │◄─────────────────────────────────│
     │                                 │                                  │
     │                                 │  Check if TBA already deployed   │
     │                                 │  (code.length > 0)               │
     │                                 │                                  │
     │                                 │  createAccount(impl, salt,       │
     │                                 │    chainId, positionNFT, tokenId)│
     │                                 │─────────────────────────────────►│
     │                                 │                                  │
     │                                 │◄─────────────────────────────────│
     │                                 │         tbaAddress               │
     │                                 │                                  │
     │                                 │  emit TBADeployed(tokenId, tba)  │
     │                                 │                                  │
     │◄────────────────────────────────│                                  │
     │         tbaAddress              │                                  │
```

### 6.2 Agent Registration Flow

The registration process involves two steps:
1. **External**: User registers via TBA directly with the canonical registry
2. **Internal**: User records the registration in the Diamond for on-chain mapping

```
┌──────────┐          ┌─────────┐          ┌──────────────┐          ┌─────────────┐
│  User    │          │   TBA   │          │ ERC-8004 Reg │          │   Diamond   │
│ (Owner)  │          │ (MSCA)  │          │              │          │   (Facet)   │
└────┬─────┘          └────┬────┘          └──────┬───────┘          └──────┬──────┘
     │                     │                      │                         │
     │  Step 1: Register via TBA                  │                         │
     │                     │                      │                         │
     │  execute(registry,  │                      │                         │
     │    0, register(uri))│                      │                         │
     │────────────────────►│                      │                         │
     │                     │                      │                         │
     │                     │  register(agentURI)  │                         │
     │                     │─────────────────────►│                         │
     │                     │                      │                         │
     │                     │                      │  _safeMint(tba, agentId)│
     │                     │                      │  agentWallet = tba      │
     │                     │                      │                         │
     │                     │◄─────────────────────│                         │
     │                     │      agentId         │                         │
     │◄────────────────────│                      │                         │
     │      agentId        │                      │                         │
     │                     │                      │                         │
     │  Step 2: Record in Diamond                 │                         │
     │                     │                      │                         │
     │  recordAgentRegistration(tokenId, agentId) │                         │
     │────────────────────────────────────────────────────────────────────►│
     │                     │                      │                         │
     │                     │                      │  Verify caller is owner │
     │                     │                      │                         │
     │                     │                      │  ownerOf(agentId)       │
     │                     │                      │◄────────────────────────│
     │                     │                      │                         │
     │                     │                      │  Verify owner == tba    │
     │                     │                      │─────────────────────────│
     │                     │                      │                         │
     │                     │                      │  Store mapping          │
     │                     │                      │  emit AgentRegistered   │
     │◄────────────────────────────────────────────────────────────────────│
```

### 6.3 Position NFT Transfer Flow

When a Position NFT transfers, the agent identity automatically follows:

```
┌───────────┐          ┌───────────┐          ┌─────────────┐          ┌─────────┐
│ Old Owner │          │ New Owner │          │ Position NFT│          │   TBA   │
│  (Alice)  │          │   (Bob)   │          │             │          │         │
└─────┬─────┘          └─────┬─────┘          └──────┬──────┘          └────┬────┘
      │                      │                       │                      │
      │  transferFrom(alice, bob, tokenId)           │                      │
      │─────────────────────────────────────────────►│                      │
      │                      │                       │                      │
      │                      │                       │  emit Transfer       │
      │                      │◄──────────────────────│                      │
      │                      │                       │                      │
      │                      │                       │                      │
      │                      │  TBA.owner() now returns Bob                 │
      │                      │  (inherent ERC-6551 behavior)                │
      │                      │◄─────────────────────────────────────────────│
      │                      │                       │                      │
      │                      │  Bob can now execute via TBA                 │
      │                      │─────────────────────────────────────────────►│
      │                      │                       │                      │
      │                      │  Identity NFT still owned by TBA             │
      │                      │  agentWallet still set to TBA                │
      │                      │  No additional transactions needed           │
```

### 6.4 Module Installation Flow

```
┌──────────┐                    ┌─────────────┐                    ┌──────────────┐
│  User    │                    │     TBA     │                    │    Module    │
│ (Owner)  │                    │   (MSCA)    │                    │              │
└────┬─────┘                    └──────┬──────┘                    └──────┬───────┘
     │                                 │                                  │
     │  installExecution(module,       │                                  │
     │    manifest, installData)       │                                  │
     │────────────────────────────────►│                                  │
     │                                 │                                  │
     │                                 │  Verify caller is owner          │
     │                                 │  Check selector conflicts        │
     │                                 │                                  │
     │                                 │  Store execution data            │
     │                                 │  Store execution hooks           │
     │                                 │  Add interface IDs               │
     │                                 │  Mark module installed           │
     │                                 │                                  │
     │                                 │  onInstall(installData)          │
     │                                 │─────────────────────────────────►│
     │                                 │                                  │
     │                                 │◄─────────────────────────────────│
     │                                 │                                  │
     │                                 │  emit ExecutionInstalled         │
     │                                 │  Increment state                 │
     │◄────────────────────────────────│                                  │
```

### 6.5 Validation Flow (ERC-4337 UserOp)

```
┌──────────────┐     ┌─────────────┐     ┌─────────────┐     ┌──────────────┐     ┌──────────────┐
│  EntryPoint  │     │     TBA     │     │  Val Hooks  │     │  Validation  │     │  Exec Hooks  │
│              │     │   (MSCA)    │     │             │     │   Module     │     │              │
└──────┬───────┘     └──────┬──────┘     └──────┬──────┘     └──────┬───────┘     └──────┬───────┘
       │                    │                   │                   │                    │
       │  validateUserOp    │                   │                   │                    │
       │───────────────────►│                   │                   │                    │
       │                    │                   │                   │                    │
       │                    │  Decode signature │                   │                    │
       │                    │  (validationFunc, │                   │                    │
       │                    │   moduleSig)      │                   │                    │
       │                    │                   │                   │                    │
       │                    │  Ensure selector  │                   │                    │
       │                    │  allowed          │                   │                    │
       │                    │                   │                   │                    │
       │                    │  preUserOpHook    │                   │                    │
       │                    │──────────────────►│                   │                    │
       │                    │◄──────────────────│                   │                    │
       │                    │                   │                   │                    │
       │                    │  validateUserOp   │                   │                    │
       │                    │──────────────────────────────────────►│                    │
       │                    │◄──────────────────────────────────────│                    │
       │                    │                   │                   │                    │
       │                    │  Intersect time   │                   │                    │
       │                    │  bounds           │                   │                    │
       │                    │                   │                   │                    │
       │◄───────────────────│                   │                   │                    │
       │  validationData    │                   │                   │                    │
       │                    │                   │                   │                    │
       │  executeUserOp     │                   │                   │                    │
       │───────────────────►│                   │                   │                    │
       │                    │                   │                   │                    │
       │                    │  preExecutionHook │                   │                    │
       │                    │─────────────────────────────────────────────────────────►│
       │                    │◄─────────────────────────────────────────────────────────│
       │                    │                   │                   │                    │
       │                    │  Execute calldata │                   │                    │
       │                    │                   │                   │                    │
       │                    │  postExecutionHook│                   │                    │
       │                    │─────────────────────────────────────────────────────────►│
       │                    │◄─────────────────────────────────────────────────────────│
       │                    │                   │                   │                    │
       │◄───────────────────│                   │                   │                    │
```

---

## 7. Module System

### 7.1 Module Types

The ERC-6900 module system supports four types of modules:

| Type | Interface | Purpose |
|------|-----------|---------|
| **Validation Module** | `IERC6900ValidationModule` | Authorize execution (user ops, runtime, signatures) |
| **Validation Hook** | `IERC6900ValidationHookModule` | Pre-validation checks (permissions, limits) |
| **Execution Module** | `IERC6900ExecutionModule` | Add new callable functions |
| **Execution Hook** | `IERC6900ExecutionHookModule` | Pre/post execution checks (policies) |

### 7.2 Default Validation Module

The `OwnerValidationModule` is the default validation module that validates signatures against the Position NFT owner.

**Features:**
- EIP-712 typed data signing
- UserOp validation for ERC-4337
- Runtime validation for direct calls
- Signature validation for ERC-1271

**Signature Domain:**
```solidity
EIP712Domain(
    string name,      // "EqualLend Owner Validation"
    string version,   // "1.0.0"
    uint256 chainId,  // Current chain ID
    address verifyingContract  // TBA address
)
```

### 7.3 Bootstrap Mode

New TBAs start in bootstrap mode with native EIP-712 owner validation:

1. **Initial State**: `_bootstrapActive = true`
2. **Bootstrap Validation**: Direct ECDSA signature verification against Position NFT owner
3. **Module Installation**: First validation module installed using bootstrap validation
4. **Post-Bootstrap**: Bootstrap mode may remain as emergency fallback

### 7.4 Module Installation Requirements

**Validation Module Installation:**
```solidity
function installValidation(
    ValidationConfig validationConfig,  // module + entityId + flags
    bytes4[] calldata selectors,        // Selectors this validation applies to
    bytes calldata installData,         // Passed to onInstall()
    bytes[] calldata hooks              // Associated hooks
) external;
```

**Execution Module Installation:**
```solidity
function installExecution(
    address module,
    ExecutionManifest calldata manifest,
    bytes calldata installData
) external;
```

**Manifest Structure:**
```solidity
struct ExecutionManifest {
    ManifestExecutionFunction[] executionFunctions;  // Selectors + flags
    ManifestExecutionHook[] executionHooks;          // Hook configurations
    bytes4[] interfaceIds;                           // ERC-165 interface IDs
}
```

### 7.5 Hook Execution Order

**Pre-Hooks:** First-installed-first-executed
**Post-Hooks:** Reverse order (last-installed-first-executed)

```
Install order: Hook A, Hook B, Hook C

Execution order:
  Pre-Hook A  →  Pre-Hook B  →  Pre-Hook C
       ↓
  [Main Execution]
       ↓
  Post-Hook C  →  Post-Hook B  →  Post-Hook A
```

### 7.6 Hook Safety Limits

| Limit | Value | Purpose |
|-------|-------|---------|
| Max Hook Depth | 8 | Prevent stack overflow |
| Max Hook Gas Budget | 13,000,000 | Leave headroom under 16M block limit |
| Recursive Hooks | Blocked | Prevent infinite loops |

### 7.7 Permissionless Module Policy

- **No Allowlist**: Any module can be installed
- **Owner Authorization**: Only Position NFT owner can install/uninstall
- **Self-Modification Blocked**: Modules cannot modify their own installation
- **Module-to-Module Blocked**: Modules cannot install other modules

---

## 8. Security Model

### 8.1 Authorization Layers

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         AUTHORIZATION STACK                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  Layer 1: Position NFT Ownership                                            │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  • Only Position NFT owner can control TBA                          │   │
│  │  • Ownership verified via IERC721.ownerOf()                         │   │
│  │  • Automatic transfer on NFT transfer                               │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
│  Layer 2: Validation Modules                                                │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  • EIP-712 signature verification                                   │   │
│  │  • Custom validation logic (session keys, multisig, etc.)           │   │
│  │  • Selector-specific or global validation                           │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
│  Layer 3: Validation Hooks                                                  │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  • Pre-validation permission checks                                 │   │
│  │  • Rate limiting, spending limits                                   │   │
│  │  • Time-based restrictions                                          │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
│  Layer 4: Execution Hooks                                                   │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  • Pre-execution policy enforcement                                 │   │
│  │  • Post-execution verification                                      │   │
│  │  • Logging and monitoring                                           │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 8.2 Security Considerations

| Concern | Mitigation |
|---------|------------|
| **Unauthorized Module Install** | Only Position NFT owner can install modules |
| **Selector Collision** | Installation reverts on conflict with existing or native selectors |
| **Module Self-Modification** | Blocked at contract level |
| **Hook Recursion** | Recursion detection and depth limits |
| **Hook Gas Exhaustion** | 13M gas budget per transaction |
| **ERC-721 Receiver Safety** | Minimal implementation, accepts all tokens |
| **Signature Replay** | EIP-712 domain binding to account address and chain ID |
| **Position NFT Burn** | TBA owner becomes address(0), freezing Identity NFT |

### 8.3 ERC-721 Receiver Implementation

The TBA must safely receive ERC-721 tokens (required for Identity NFT minting):

```solidity
function onERC721Received(
    address,    // operator
    address,    // from
    uint256,    // tokenId
    bytes calldata  // data
) external pure returns (bytes4) {
    return IERC721Receiver.onERC721Received.selector;  // 0x150b7a02
}
```

### 8.4 Signature Domain Binding

All signatures are bound to:
- **Account Address**: Prevents cross-account replay
- **Chain ID**: Prevents cross-chain replay
- **Deadline**: Time-limited validity (for `setAgentWallet`)

### 8.5 Position NFT Burn Edge Case

If a Position NFT is burned:
1. TBA owner becomes `address(0)`
2. Identity NFT becomes frozen inside TBA
3. No recovery mechanism (by design)

**Mitigation Options:**
- Prevent burn if agent exists (protocol-level)
- Require transferring Identity NFT first
- Mark position as inactive in off-chain indexer

---

## 9. Integration Guide

### 9.1 For Position NFT Owners

**Step 1: Deploy TBA**
```solidity
// Via Diamond facet
address tba = diamond.deployTBA(positionTokenId);
```

**Step 2: Register Agent**
```solidity
// Prepare registration file and upload to IPFS
string memory agentURI = "ipfs://Qm.../registration.json";

// Call Identity Registry via TBA
bytes memory registerCall = abi.encodeWithSignature(
    "register(string)",
    agentURI
);
uint256 agentId = abi.decode(
    IERC6551Executable(tba).execute(identityRegistry, 0, registerCall, 0),
    (uint256)
);

// Record in Diamond
diamond.recordAgentRegistration(positionTokenId, agentId);
```

**Step 3: Install Modules (Optional)**
```solidity
// Install a custom execution module
IERC6900Account(tba).installExecution(
    moduleAddress,
    manifest,
    installData
);
```

### 9.2 For Module Developers

**Implement Required Interfaces:**

```solidity
// Validation Module
contract MyValidationModule is IERC6900ValidationModule {
    function validateUserOp(uint32 entityId, PackedUserOperation calldata userOp, bytes32 userOpHash)
        external returns (uint256);
    
    function validateRuntime(address account, uint32 entityId, address sender, uint256 value, bytes calldata data, bytes calldata authorization)
        external;
    
    function validateSignature(address account, uint32 entityId, address sender, bytes32 hash, bytes calldata signature)
        external view returns (bytes4);
    
    function onInstall(bytes calldata data) external;
    function onUninstall(bytes calldata data) external;
    function moduleId() external view returns (string memory);
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

// Execution Module
contract MyExecutionModule is IERC6900ExecutionModule {
    function executionManifest() external pure returns (ExecutionManifest memory);
    function onInstall(bytes calldata data) external;
    function onUninstall(bytes calldata data) external;
    function moduleId() external view returns (string memory);
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
    
    // Custom execution functions
    function myCustomFunction(bytes calldata params) external;
}
```

### 9.3 For Indexers

**Discover Position Agents:**

1. **Monitor ERC-8004 Identity Registry** for `Transfer` events to TBA addresses
2. **Query Diamond** for position-to-agent mappings:
   ```solidity
   uint256 agentId = diamond.getAgentId(positionTokenId);
   address tba = diamond.getTBAAddress(positionTokenId);
   bool registered = diamond.isAgentRegistered(positionTokenId);
   ```
3. **Fetch Registration File** from Identity NFT `tokenURI`

### 9.4 For ERC-4337 Bundlers

**UserOperation Structure:**
```solidity
struct PackedUserOperation {
    address sender;           // TBA address
    uint256 nonce;            // EntryPoint nonce
    bytes initCode;           // Empty for existing TBAs
    bytes callData;           // Encoded function call
    bytes32 accountGasLimits; // Packed gas limits
    uint256 preVerificationGas;
    bytes32 gasFees;          // Packed gas fees
    bytes paymasterAndData;   // Optional paymaster
    bytes signature;          // abi.encode(ModuleEntity, moduleSig)
}
```

**Signature Format:**
```solidity
// For module-based validation
bytes memory signature = abi.encode(
    ModuleEntity validationFunction,  // Which validation module to use
    bytes moduleSig                   // Module-specific signature
);

// For bootstrap validation (65 bytes)
bytes memory signature = abi.encodePacked(r, s, v);  // Standard ECDSA
```

---

## 10. Deployment & Configuration

### 10.1 Deployment Order

1. **Deploy MSCA Implementation**
   ```solidity
   PositionMSCAImpl msca = new PositionMSCAImpl(entryPointAddress);
   ```

2. **Deploy Diamond Facets**
   ```solidity
   PositionAgentTBAFacet tbaFacet = new PositionAgentTBAFacet();
   PositionAgentRegistryFacet regFacet = new PositionAgentRegistryFacet();
   PositionAgentViewFacet viewFacet = new PositionAgentViewFacet();
   PositionAgentConfigFacet configFacet = new PositionAgentConfigFacet();
   ```

3. **Add Facets to Diamond**
   ```solidity
   diamond.diamondCut(facetCuts, address(0), "");
   ```

4. **Configure Registry Addresses**
   ```solidity
   configFacet.setERC6551Registry(0x000000006551c19487814612e58FE06813775758);
   configFacet.setERC6551Implementation(address(msca));
   configFacet.setIdentityRegistry(identityRegistryAddress);
   ```

### 10.2 Chain-Specific Configuration

| Chain | ERC-6551 Registry | ERC-8004 Identity Registry | EntryPoint |
|-------|-------------------|---------------------------|------------|
| Ethereum Mainnet | `0x000000006551c19487814612e58FE06813775758` | `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432` | `0x0000000071727De22E5E9d8BAf0edAc6f37da032` |
| Ethereum Sepolia | `0x000000006551c19487814612e58FE06813775758` | `0x8004A818BFB912233c491871b3d84c89A494BD9e` | `0x0000000071727De22E5E9d8BAf0edAc6f37da032` |

### 10.3 Salt Strategy

The system uses a fixed salt (`bytes32(0)`) for TBA derivation:
- **Deterministic**: Same inputs always produce same TBA address
- **Simple**: No salt management required
- **One TBA per Position**: Each Position NFT has exactly one TBA

### 10.4 Upgrade Strategy

**Per-Account UUPS Upgrade:**
- Each TBA can upgrade independently
- Upgrade authorized by Position NFT owner (EIP-712 signature)
- No protocol-wide admin required
- Bootstrap validation serves as emergency fallback

---

## 11. Appendices

### 11.1 Contract Addresses Summary

| Contract | Address | Notes |
|----------|---------|-------|
| ERC-6551 Registry | `0x000000006551c19487814612e58FE06813775758` | Same on all EVM chains |
| ERC-8004 Identity Registry (Mainnet) | `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432` | Chain-specific |
| ERC-8004 Identity Registry (Sepolia) | `0x8004A818BFB912233c491871b3d84c89A494BD9e` | Chain-specific |
| ERC-4337 EntryPoint v0.7 | `0x0000000071727De22E5E9d8BAf0edAc6f37da032` | Same on all EVM chains |

### 11.2 Interface IDs

| Interface | ID | Standard |
|-----------|-----|----------|
| `IERC165` | `0x01ffc9a7` | ERC-165 |
| `IERC721Receiver` | `0x150b7a02` | ERC-721 |
| `IERC1271` | `0x1626ba7e` | ERC-1271 |
| `IERC6551Account` | `0x6faff5f1` | ERC-6551 |
| `IERC6551Executable` | `0x51945447` | ERC-6551 |
| `IAccount` | `0x3a871cdd` | ERC-4337 |

### 11.3 Error Codes

**Position Agent Errors:**
```solidity
error PositionAgent_Unauthorized(address caller, uint256 positionTokenId);
error PositionAgent_NotAdmin(address caller);
error PositionAgent_NotRegistered(uint256 positionTokenId);
error PositionAgent_AlreadyRegistered(uint256 positionTokenId);
error PositionAgent_InvalidAgentOwner(address expected, address actual);
```

**MSCA Errors:**
```solidity
error UnauthorizedCaller(address caller);
error InvalidEntryPoint(address caller);
error ModuleTargetNotAllowed(address target);
error UnsupportedOperation(uint8 operation);
error SelectorNotInstalled(bytes4 selector);
error ModuleSelfModification(address module);
```

**Hook Errors:**
```solidity
error MaxHookDepthExceeded();
error RecursiveHookDetected();
error HookGasBudgetExceeded(uint256 used);
```

### 11.4 Events

**Position Agent Events:**
```solidity
event TBADeployed(uint256 indexed positionTokenId, address indexed tbaAddress);
event AgentRegistered(uint256 indexed positionTokenId, address indexed tbaAddress, uint256 indexed agentId);
event ERC6551RegistryUpdated(address indexed previous, address indexed current);
event ERC6551ImplementationUpdated(address indexed previous, address indexed current);
event IdentityRegistryUpdated(address indexed previous, address indexed current);
```

**MSCA Events:**
```solidity
event ExecutionInstalled(address indexed module, ExecutionManifest manifest);
event ExecutionUninstalled(address indexed module, bool onUninstallSucceeded, ExecutionManifest manifest);
event ValidationInstalled(address indexed module, uint32 indexed entityId);
event ValidationUninstalled(address indexed module, uint32 indexed entityId, bool onUninstallSucceeded);
```

### 11.5 Glossary

| Term | Definition |
|------|------------|
| **Agent** | An ERC-8004 registered entity identified by an `agentId` |
| **Agent ID** | The ERC-721 tokenId minted by the ERC-8004 Identity Registry |
| **Agent URI** | The URI resolving to the agent's registration file |
| **Agent Wallet** | A verified address where the agent receives payments (set to TBA) |
| **Bootstrap Mode** | Initial TBA state with native EIP-712 validation before module installation |
| **Diamond** | The upgradeable proxy contract using EIP-2535 |
| **Entity ID** | A 4-byte identifier for a specific function within a module |
| **Execution Hook** | Pre/post checks around execution functions |
| **Execution Module** | A module that adds new callable functions to the account |
| **Hook Config** | Packed representation of a hook function with flags |
| **Identity NFT** | The ERC-721 token representing an agent in the ERC-8004 registry |
| **Module Entity** | Packed reference: module address (20 bytes) + entity ID (4 bytes) |
| **MSCA** | Modular Smart Contract Account (ERC-6900) |
| **Position NFT** | The ERC-721 token representing an isolated account container |
| **Registration File** | Off-chain JSON document containing agent metadata |
| **Salt** | A bytes32 value used in deterministic TBA address derivation |
| **TBA** | Token Bound Account (ERC-6551) |
| **Validation Config** | Packed representation of a validation function with flags |
| **Validation Hook** | Pre-validation checks for permissions and limits |
| **Validation Module** | A module that validates authorization for execution |

### 11.6 References

**Standards:**
- [ERC-6551: Non-fungible Token Bound Accounts](https://eips.ethereum.org/EIPS/eip-6551)
- [ERC-6900: Modular Smart Contract Accounts](https://eips.ethereum.org/EIPS/eip-6900)
- [ERC-8004: Agent Identity](https://eips.ethereum.org/EIPS/eip-8004)
- [ERC-4337: Account Abstraction](https://eips.ethereum.org/EIPS/eip-4337)
- [ERC-1271: Standard Signature Validation](https://eips.ethereum.org/EIPS/eip-1271)
- [ERC-7201: Namespaced Storage Layout](https://eips.ethereum.org/EIPS/eip-7201)
- [EIP-712: Typed Structured Data Hashing](https://eips.ethereum.org/EIPS/eip-712)
- [EIP-2535: Diamond Standard](https://eips.ethereum.org/EIPS/eip-2535)

**Related Design Documents:**
- `DESIGN-ERC8004-ERC6551-POSITION-AGENTS.md` - Original TBA + Identity design
- `DESIGN-ERC6900-MODULAR-TBA.md` - Modular account design
- `.kiro/specs/erc6551-position-agents/` - ERC-6551 integration spec
- `.kiro/specs/erc6900-modular-tba/` - ERC-6900 MSCA spec

---

## Document History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0.0 | 2026-01-30 | EqualGi Labs | Initial unified design document |

