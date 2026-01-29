# Position NFT - Design Document

**Version:** 1.0  
**Contract:** PositionNFT (ERC-721)

---

## Table of Contents

1. [Overview](#overview)
2. [Core Concepts](#core-concepts)
3. [Architecture](#architecture)
4. [Position Lifecycle](#position-lifecycle)
5. [Position Key Derivation](#position-key-derivation)
6. [ERC-8004 Integration](#erc-8004-integration)
7. [Transfer Behavior](#transfer-behavior)
8. [Data Models](#data-models)
9. [API Reference](#api-reference)
10. [Integration Guide](#integration-guide)
11. [Security Considerations](#security-considerations)

---

## Overview

Position NFTs are ERC-721 tokens that represent isolated account containers within EqualLend pools. Each NFT encapsulates a complete financial position including deposits, loans, yield accruals, and collateral obligations.

### What is a Position NFT?

A Position NFT is a transferable on-chain identity that:

- Holds principal deposits in lending pools
- Accumulates yield from lending activity
- Carries loan obligations (rolling credit, fixed-term, direct)
- Maintains collateral relationships
- Functions as an ERC-8004 agent identity

### Key Characteristics

| Feature | Description |
|---------|-------------|
| **Isolated Accounting** | Each position maintains independent balances, loans, and yield |
| **Transferable** | Full position state transfers with NFT ownership |
| **Multi-Pool** | Single NFT can participate in multiple pools via pool membership |
| **ERC-8004 Compatible** | Positions serve as trustless agent identities |
| **Diamond-Integrated** | Core logic lives in upgradeable Diamond facets |

### System Participants

| Role | Description |
|------|-------------|
| **Position Owner** | NFT holder who controls deposits, withdrawals, and borrowing |
| **Operator** | Approved address that can act on behalf of owner |
| **Pool** | Lending pool where the position holds deposits |
| **Diamond** | Proxy contract containing position management logic |

---

## Core Concepts

### Isolated Account Containers

Each Position NFT creates a logically isolated account within the protocol. Unlike traditional DeFi where user addresses directly map to positions, Position NFTs introduce an abstraction layer:

```
Traditional:     user address → position data
Position NFT:    user address → NFT ownership → position key → position data
```

This abstraction enables:

- **Transferable positions**: Sell or transfer entire positions including obligations
- **Multi-position management**: Single user can hold multiple independent positions
- **Delegation**: Approve operators to manage positions without transferring ownership
- **Agent identity**: Positions become discoverable on-chain agents

### Position Key

Every Position NFT has a deterministic position key derived from the NFT contract address and token ID:

```solidity
positionKey = keccak256(abi.encodePacked(nftContract, tokenId))
```

This key indexes into all pool data mappings, ensuring position data remains associated with the NFT regardless of ownership changes.

### Pool Membership

Positions can participate in multiple pools simultaneously. Pool membership is tracked separately from deposits, allowing positions to:

- Hold deposits in multiple pools
- Maintain loan obligations across pools
- Accumulate yield from different sources
- Clear membership when obligations are settled

---

## Architecture

### Contract Structure

```
src/nft/
└── PositionNFT.sol              # ERC-721 token with Diamond forwarding

src/equallend/
├── PositionManagementFacet.sol  # Mint, deposit, withdraw, yield operations
└── PoolManagementFacet.sol      # Pool initialization and configuration

src/libraries/
├── LibPositionNFT.sol           # Position key derivation and storage
└── LibPositionHelpers.sol       # Common position utilities
```

### Component Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                      Position NFT System                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                    PositionNFT (ERC-721)                  │   │
│  │              Token ownership and transfers                │   │
│  └──────────────────────────────────────────────────────────┘   │
│                              │                                  │
│                              ▼                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                    Diamond Proxy                          │   │
│  │  ┌────────────────┐ ┌──────────────┐                      │   │
│  │  │   Position     │ │    Pool      │                      │   │
│  │  │  Management    │ │  Management  │                      │   │
│  │  └────────────────┘ └──────────────┘                      │   │
│  └──────────────────────────────────────────────────────────┘   │
│                              │                                  │
│                              ▼                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                    Pool Data Storage                      │   │
│  │    userPrincipal │ userAccruedYield │ loans │ collateral │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Facet Responsibilities

| Facet | Responsibility | Key Functions |
|-------|---------------|---------------|
| **PositionManagementFacet** | Position lifecycle | `mintPosition`, `depositToPosition`, `withdrawFromPosition`, `rollYieldToPosition` |
| **PoolManagementFacet** | Pool configuration | `initPool`, `initManagedPool`, whitelist management |

---

## Position Lifecycle

### Minting

New positions are created by minting a Position NFT:

```solidity
// Mint empty position
function mintPosition(uint256 pid) external returns (uint256 tokenId);

// Mint with initial deposit
function mintPositionWithDeposit(uint256 pid, uint256 amount) 
    external returns (uint256 tokenId);
```

**Minting Steps:**

1. Validate pool exists and is initialized
2. Collect mint fee (if configured)
3. Mint ERC-721 token to caller
4. Associate token with pool ID
5. Record creation timestamp
6. (If depositing) Transfer tokens and initialize position state

### Depositing

Add capital to an existing position:

```solidity
function depositToPosition(uint256 tokenId, uint256 pid, uint256 amount) external;
```

**Deposit Flow:**

1. Verify caller owns the NFT
2. Settle any pending fee index updates
3. Transfer tokens from caller to pool
4. Update position principal
5. Update pool totals and tracked balance

### Withdrawing

Remove capital from a position:

```solidity
function withdrawFromPosition(uint256 tokenId, uint256 pid, uint256 principalToWithdraw) external;
```

**Withdrawal Flow:**

1. Verify ownership
2. Settle fee index and active credit index
3. Calculate encumbered amounts (locked, lent, escrowed)
4. Charge withdrawal fee
5. Verify solvency after withdrawal
6. Calculate proportional yield to withdraw
7. Update position and pool state
8. Transfer tokens to owner

### Yield Rolling

Convert accrued yield into principal:

```solidity
function rollYieldToPosition(uint256 tokenId, uint256 pid) external;
```

**Roll Flow:**

1. Verify ownership
2. Settle indexes to calculate current yield
3. Move yield from `userAccruedYield` to `userPrincipal`
4. Update pool totals

### Closing

Withdraw all available capital from a pool position:

```solidity
function closePoolPosition(uint256 tokenId, uint256 pid) external;
```

This withdraws maximum available principal while respecting encumbrances and solvency requirements.

---

## Position Key Derivation

### Algorithm

Position keys are derived deterministically from the NFT contract address and token ID:

```solidity
function getPositionKey(address nftContract, uint256 tokenId) 
    internal pure returns (bytes32) 
{
    return keccak256(abi.encodePacked(nftContract, tokenId));
}
```

### Properties

| Property | Description |
|----------|-------------|
| **Deterministic** | Same inputs always produce same key |
| **Collision-resistant** | Different positions have different keys |
| **Transfer-stable** | Key remains constant across ownership changes |
| **Contract-scoped** | Keys are unique per NFT contract |

### Usage in Pool Data

The position key indexes into all pool data mappings:

```solidity
// Principal balance
mapping(bytes32 => uint256) userPrincipal;

// Accrued yield
mapping(bytes32 => uint256) userAccruedYield;

// Fee index checkpoint
mapping(bytes32 => uint256) userFeeIndex;

// Maintenance index checkpoint
mapping(bytes32 => uint256) userMaintenanceIndex;

// External collateral
mapping(bytes32 => uint256) externalCollateral;

// Rolling credit loans
mapping(bytes32 => RollingLoan) rollingLoans;
```

---

## ERC-8004 Integration

Position NFTs are represented as ERC-8004 agents **via the canonical ERC-8004 Identity Registry and ERC-6551 TBAs**, not via in-protocol facets. Registration and metadata updates are executed directly by the Position NFT owner through the TBA, and the Identity NFT is minted by the canonical registry.

For the current design and call flows, see `.kiro/specs/erc6551-position-agents/design.md`.

---

## Transfer Behavior

### What Transfers

When a Position NFT is transferred, the new owner inherits:

- All principal deposits across pools
- All accrued yield
- All loan obligations (rolling, fixed-term, direct)
- All collateral relationships
- Pool membership status

### What Resets

On transfer, the following are reset:

- Agent wallet (set to `address(0)`)
- Agent nonce (incremented to invalidate pending signatures)

### Transfer Restrictions

Transfers are blocked when:

- Position has open direct offers (prevents offer manipulation)

```solidity
function _update(address to, uint256 tokenId, address auth) 
    internal override returns (address) 
{
    // Block transfers with open offers
    if (from != address(0) && to != address(0) && from != to && diamond != address(0)) {
        bytes32 positionKey = LibPositionNFT.getPositionKey(address(this), tokenId);
        if (IDirectOfferCanceller(diamond).hasOpenOffers(positionKey)) {
            revert PositionNFTHasOpenOffers(positionKey);
        }
        // Reset agent wallet on transfer
        IERC8004Callback(diamond).onAgentTransfer(tokenId);
    }
    return super._update(to, tokenId, auth);
}
```

### Post-Transfer Actions

After receiving a Position NFT, the new owner should:

1. Review inherited obligations (loans, collateral)
2. Set up agent wallet if using ERC-8004 features
3. Update agent URI if needed

---

## Data Models

### PositionNFT Storage

```solidity
// Token ID counter
uint256 public nextTokenId;

// Token to pool association
mapping(uint256 => uint256) public tokenToPool;

// Token creation timestamps
mapping(uint256 => uint40) public tokenCreationTime;

// Authorized minter (PositionManagementFacet)
address public minter;

// Diamond contract for pool queries
address public diamond;
```

### Position Data (in PoolData)

```solidity
// Principal balance per position
mapping(bytes32 => uint256) userPrincipal;

// Accrued yield per position
mapping(bytes32 => uint256) userAccruedYield;

// Fee index checkpoint per position
mapping(bytes32 => uint256) userFeeIndex;

// Maintenance index checkpoint per position
mapping(bytes32 => uint256) userMaintenanceIndex;

// External collateral per position
mapping(bytes32 => uint256) externalCollateral;

// Rolling credit loans per position
mapping(bytes32 => RollingLoan) rollingLoans;

// Fixed-term loan IDs per position
mapping(bytes32 => uint256[]) userFixedLoanIds;
```

---

## API Reference

### PositionNFT Contract

```solidity
// Mint new position
function mint(address to, uint256 poolId) external returns (uint256 tokenId);

// Get position key for token
function getPositionKey(uint256 tokenId) public view returns (bytes32);

// Get associated pool ID
function getPoolId(uint256 tokenId) external view returns (uint256);

// Get creation timestamp
function getCreationTime(uint256 tokenId) external view returns (uint40);

```

### PositionManagementFacet

```solidity
// Mint operations
function mintPosition(uint256 pid) external returns (uint256 tokenId);
function mintPositionWithDeposit(uint256 pid, uint256 amount) external returns (uint256 tokenId);

// Capital operations
function depositToPosition(uint256 tokenId, uint256 pid, uint256 amount) external;
function withdrawFromPosition(uint256 tokenId, uint256 pid, uint256 amount) external;
function closePoolPosition(uint256 tokenId, uint256 pid) external;

// Yield operations
function rollYieldToPosition(uint256 tokenId, uint256 pid) external;

// Membership
function cleanupMembership(uint256 tokenId, uint256 pid) external;
```

---

## Integration Guide

### Minting a Position

```javascript
// Connect to PositionManagementFacet via Diamond
const diamond = new ethers.Contract(diamondAddress, PositionManagementFacetABI, signer);

// Mint empty position
const tx = await diamond.mintPosition(poolId);
const receipt = await tx.wait();
const tokenId = receipt.events.find(e => e.event === 'PositionMinted').args.tokenId;

// Or mint with deposit
const depositAmount = ethers.utils.parseUnits("1000", 18);
await token.approve(diamondAddress, depositAmount);
const tx2 = await diamond.mintPositionWithDeposit(poolId, depositAmount);
```

### Depositing to Position

```javascript
const depositAmount = ethers.utils.parseUnits("500", 18);
await token.approve(diamondAddress, depositAmount);
await diamond.depositToPosition(tokenId, poolId, depositAmount);
```

### Withdrawing from Position

```javascript
const withdrawAmount = ethers.utils.parseUnits("250", 18);
await diamond.withdrawFromPosition(tokenId, poolId, withdrawAmount);
```

### Setting Agent Wallet

```javascript
// Build EIP-712 typed data
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

const nonce = await positionNFT.getAgentNonce(tokenId);
const deadline = Math.floor(Date.now() / 1000) + 3600;

const message = {
    agentId: tokenId,
    newWallet: walletAddress,
    nonce: nonce,
    deadline: deadline
};

// Sign with the wallet being registered
const signature = await wallet._signTypedData(domain, types, message);

// Submit from position owner
await positionNFT.setAgentWallet(tokenId, walletAddress, deadline, signature);
```

### Querying Position Data

```javascript
// Get position key
const positionKey = await positionNFT.getPositionKey(tokenId);

// Get pool ID
const poolId = await positionNFT.getPoolId(tokenId);

// Get agent wallet
const agentWallet = await positionNFT.getAgentWallet(tokenId);

// Get agent URI
const agentURI = await positionNFT.getAgentURI(tokenId);
```

---

## Security Considerations

### Ownership Verification

All position operations verify NFT ownership:

```solidity
function _requireOwnership(uint256 tokenId) internal view {
    PositionNFT nft = PositionNFT(LibPositionNFT.s().positionNFTContract);
    if (nft.ownerOf(tokenId) != msg.sender) {
        revert NotNFTOwner(tokenId, msg.sender);
    }
}
```

### Solvency Checks

Withdrawals enforce solvency requirements:

```solidity
// Calculate total debt
uint256 totalDebt = _calculateTotalDebt(p, positionKey, pid);

// Verify solvency after withdrawal
if (!_checkSolvency(p, positionKey, newPrincipal, totalDebt)) {
    revert SolvencyViolation(newPrincipal, totalDebt, p.poolConfig.depositorLTVBps);
}
```

### Encumbrance Protection

Withdrawals respect locked and escrowed amounts:

```solidity
uint256 totalEncumbered = enc.directLocked + enc.directLent + 
                          enc.directOfferEscrow + enc.indexEncumbered;

if (totalEncumbered > currentPrincipal) {
    revert InsufficientPrincipal(totalEncumbered, currentPrincipal);
}
```

### Transfer Safety

- Agent wallets reset on transfer to prevent payment hijacking
- Nonces increment to invalidate pending signatures
- Open offers block transfers to prevent manipulation

### Reentrancy Protection

All state-modifying functions use reentrancy guards:

```solidity
contract PositionManagementFacet is ReentrancyGuardModifiers {
    function depositToPosition(...) public payable nonReentrant { ... }
    function withdrawFromPosition(...) public payable nonReentrant { ... }
}
```

### Access Control

- Only authorized minter can mint new NFTs
- Only owner or approved operators can modify position state
- Diamond address must be set for pool queries

---

## Events

### Position Events

```solidity
// New position minted
event PositionMinted(uint256 indexed tokenId, address indexed owner, uint256 indexed poolId);

// Capital deposited
event DepositedToPosition(
    uint256 indexed tokenId,
    address indexed owner,
    uint256 indexed poolId,
    uint256 amount,
    uint256 newPrincipal
);

// Capital withdrawn
event WithdrawnFromPosition(
    uint256 indexed tokenId,
    address indexed owner,
    uint256 indexed poolId,
    uint256 principalWithdrawn,
    uint256 yieldWithdrawn,
    uint256 remainingPrincipal
);

// Yield rolled to principal
event YieldRolledToPosition(
    uint256 indexed tokenId,
    address indexed owner,
    uint256 indexed poolId,
    uint256 yieldAmount,
    uint256 newPrincipal
);
```

### Configuration Events

```solidity
// Minter address updated
event MinterUpdated(address indexed oldMinter, address indexed newMinter);

// Diamond address updated
event DiamondUpdated(address indexed oldDiamond, address indexed newDiamond);
```

## Error Reference

### Position Errors

| Error | Description |
|-------|-------------|
| `NotNFTOwner(tokenId, caller)` | Caller does not own the NFT |
| `InvalidTokenId(tokenId)` | Token does not exist |
| `PoolNotInitialized(pid)` | Pool has not been initialized |
| `DepositBelowMinimum(amount, minimum)` | Deposit below pool minimum |
| `InsufficientPrincipal(required, available)` | Not enough principal for operation |
| `SolvencyViolation(principal, debt, ltvBps)` | Operation would violate LTV |
| `InsufficientPoolLiquidity(required, available)` | Pool lacks liquidity |
| `DepositCapExceeded(amount, cap)` | Deposit would exceed pool cap |
| `MaxUserCountExceeded(max)` | Pool at maximum user capacity |

### Transfer Errors

| Error | Description |
|-------|-------------|
| `PositionNFTHasOpenOffers(positionKey)` | Cannot transfer with open offers |
