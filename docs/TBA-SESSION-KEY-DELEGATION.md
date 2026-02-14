# TBA Agent Delegation with ERC-6551, ERC-6900, and ERC-4337

## 1. Purpose

This document defines how Equalis delegates onchain execution to bots/agents without exposing the user's EOA private key.

The model combines:

- ERC-6551 Token Bound Accounts (TBAs) for NFT-bound account ownership
- ERC-6900 modular account permissions for action scoping
- ERC-4337 UserOperation flow for relayed/account-abstraction execution
- Session-key style validation modules for bounded delegation

## 2. Scope

This document covers:

- How control of a TBA is derived from Position NFT ownership
- How execution is authorized in direct and ERC-4337 flows
- How modules restrict what an agent can do
- How to implement safe session-key delegation on top of current contracts

This document does not define a full UI/UX or key-management product.

## 3. Architecture

### 3.1 Core Components

- `PositionAgentTBAFacet`: computes/deploys deterministic ERC-6551 account address per Position NFT
- `PositionMSCA` / `PositionMSCAImpl`: ERC-6900 modular smart account implementation used by TBA
- `OwnerValidationModule`: default owner-signature validation module
- ERC-4337 `EntryPoint`: validates and executes UserOperations

### 3.2 Ownership and Control Root

The control root is NFT ownership:

- TBA `owner()` resolves to `ownerOf(positionTokenId)` of the bound Position NFT
- When Position NFT transfers, TBA control follows automatically

Result: account control is NFT-native, not hardcoded to a single EOA forever.

## 4. Execution Paths

### 4.1 Direct Owner Execution

Owner can call:

- `execute(address target, uint256 value, bytes data)`
- `executeBatch(Call[] calls)`
- `execute(address to, uint256 value, bytes data, uint8 operation)`

Authorization: caller must be current NFT owner (`_requireOwner()`).

### 4.2 ERC-4337 UserOperation Execution

Flow:

1. Bundler submits UserOp to `EntryPoint`
2. `EntryPoint` calls TBA `validateUserOp(...)`
3. TBA verifies signature via bootstrap logic or installed validation module
4. `EntryPoint` calls `executeUserOp(...)`
5. TBA executes `userOp.callData`

Important: relayer/bundler does not need private keys; only valid authorization payloads.

### 4.3 Runtime-Validated Delegated Calls

TBA also supports:

- `executeWithRuntimeValidation(bytes data, bytes authorization)`

This allows module-based delegated execution without owner being `msg.sender`, as long as runtime validation passes.

## 5. ERC-6900 Permission Surfaces

### 5.1 Execution Modules

Execution modules expose specific callable selectors and hook behavior via manifest:

- `executionSelector`
- `skipRuntimeValidation`
- `allowGlobalValidation`

Installed selectors route through TBA fallback to module delegatecall.

### 5.2 Validation Modules

Validation modules authorize:

- UserOps
- Runtime calls
- ERC-1271 signatures

Validation can be:

- selector-scoped (recommended for delegation)
- global (powerful; use carefully)

### 5.3 Selector Scoping

Selector applicability is enforced before validation dispatch. This is the core mechanism that lets you constrain an agent to only approved actions.

## 6. Session Key Delegation Model

### 6.1 What Session Keys Mean Here

A session key is a delegated signer validated by a custom ERC-6900 validation module with bounded policy.

Typical bounds:

- allowed selectors
- allowed target contracts
- per-call value limits
- token/pool allowlists
- validity window (`validAfter`, `validUntil`)
- replay protection (nonce lane or digest tracking)
- spending/budget limits

### 6.2 Implemented vs Custom

Implemented now:

- Owner-based validation (`OwnerValidationModule`)
- Selector-based module routing and validation framework
- Dedicated session-key validation module (`SessionKeyValidationModule`) with:
  - owner-controlled policy registration/revocation per `(account, entityId, sessionKey)`
  - selector allowlist
  - target allowlist for `execute` / `executeBatch`
  - per-target inner-selector constraints for `execute` / `executeBatch`
  - per-call value cap for `execute` / `executeBatch`
  - cumulative value budget limits
  - validity windows (`validAfter`, `validUntil`)
  - UserOp, runtime, and ERC-1271 validation paths

Custom extensions still planned:

- richer replay lanes / nonce partitioning
- interval-based budgets and spend decay models
- protocol-specific policy constraints

## 7. Recommended Delegation Flow

1. Deploy/resolve TBA for Position NFT
2. Install execution module(s) that expose only the actions intended for automation
3. Install session-key validation module bound to those selectors
4. Register session key policy (expiry, limits, allowlists, replay rules)
5. Agent submits UserOps signed by session key
6. Validation module checks policy and authorizes/rejects
7. Revoke by removing key, expiring policy, or uninstalling validation module

## 8. Security Requirements

Use these as hard requirements for production:

- Keep `skipRuntimeValidation = false` unless module has strict internal auth and bounded call graph
- Avoid global validation for agent keys unless absolutely required
- Enforce explicit selector + target allowlists in session module
- Preserve call-graph guardrails (for example, do not bypass protections such as `executeBatch` rejecting installed module targets)
- Include expiry and replay controls in every delegated authorization
- Add spend caps and cumulative budget tracking
- Ensure uninstall/revocation paths are always owner-controlled and quick
- Log policy changes and delegated executions for monitoring and incident response

## 9. Threat Model Notes

Primary risks in delegated mode:

- Over-broad selector scope
- Missing replay protection
- Unlimited target/value permissions
- Long-lived keys without revocation
- Misconfigured runtime-validation flags

The model is safe only if module policy is narrow, explicit, and revocable.

## 10. Reference Contracts

- `src/erc6551/PositionAgentTBAFacet.sol`
- `src/libraries/LibPositionAgentStorage.sol`
- `src/erc6900/PositionMSCA.sol`
- `src/erc6900/PositionMSCAImpl.sol`
- `src/erc6900/OwnerValidationModule.sol`
- `src/erc6900/SessionKeyValidationModule.sol`
- `src/erc6900/ValidationFlowLib.sol`
- `src/erc6900/ExecutionManagementLib.sol`
- `src/erc6900/ValidationManagementLib.sol`
- `src/erc6900/ModuleTypes.sol`

## 11. Implementation Summary

Accurate system statement:

Equalis uses Position NFTs with ERC-6551 TBAs and ERC-6900 modular smart accounts (ERC-4337-compatible). Agents can execute through the TBA using delegated session keys, while validation and execution modules enforce exactly which actions are permitted, so users can delegate automation without sharing EOA private keys.

Condition:

This holds when session-key validation policy is configured narrowly (selector/target/value/time bounds) and module flags are configured correctly.
