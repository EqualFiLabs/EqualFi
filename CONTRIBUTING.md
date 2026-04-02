# Contributing to EqualFi

Thank you for your interest in contributing to EqualFi and the Equalis Protocol! This document provides guidelines and instructions for contributing to this unified DeFi infrastructure layer.

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [Development Environment](#development-environment)
- [Project Structure](#project-structure)
- [Contributing Guidelines](#contributing-guidelines)
- [Testing](#testing)
- [Security](#security)
- [Community](#community)

## Code of Conduct

This project and everyone participating in it is governed by our commitment to:

- **Trustlessness**: We build for the right reasons, as inspired by [Vitalik's low-risk DeFi principles](https://vitalik.eth.limo/general/2025/09/21/low_risk_defi.html)
- **Transparency**: All changes should be auditable and well-documented
- **Collaboration**: Respectful, constructive communication with fellow contributors
- **Security First**: Financial infrastructure requires rigorous security practices

## Getting Started

### Prerequisites

Before you begin, ensure you have the following installed:

- **Git** (for submodules)
- **Foundry** (forge, cast, anvil) — `solc` is pinned to **0.8.33** via Foundry config
- **Bash** (for helper scripts under `script/`)

### Install Foundry

If you do not already have Foundry installed:

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

### Fork and Clone

1. Fork the repository on GitHub
2. Clone your fork:

```bash
git clone https://github.com/YOUR_USERNAME/EqualFi.git
cd EqualFi
```

3. Add the upstream remote:

```bash
git remote add upstream https://github.com/EqualFiLabs/EqualFi.git
```

## Development Environment

### Install Dependencies

The repo uses git submodules for core dependencies:

```bash
git submodule update --init --recursive
```

If you prefer to re-install via Foundry (optional):

```bash
forge install foundry-rs/forge-std@v1.7.6
forge install OpenZeppelin/openzeppelin-contracts@v5.5.0
```

### Build

```bash
forge build
```

### Environment Setup

Copy the example environment file and configure as needed:

```bash
cp .env.example .env
```

Edit `.env` with your configuration values.

## Project Structure

```
EqualFi/
├── src/
│   ├── core/           # Core protocol contracts (Diamond proxy, accounting)
│   ├── nft/            # Position NFT implementation
│   ├── equalindex/     # Fee index and distribution logic
│   ├── equallend/      # Lending module
│   ├── equallend-direct/  # Direct lending functionality
│   ├── derivatives/    # Options and derivatives
│   ├── EqualX/         # EqualX module
│   ├── modules/        # Additional protocol modules
│   ├── agent-wallet/   # Agent wallet functionality
│   ├── admin/          # Admin and governance
│   ├── interfaces/     # Contract interfaces
│   ├── libraries/      # Shared libraries
│   ├── views/          # View/pure helper contracts
│   ├── points/         # Points system
│   ├── faucet/         # Testnet faucet
│   └── mocks/          # Test mocks
├── test/               # Test suite
├── script/             # Deployment and helper scripts
├── docs/               # Documentation
│   ├── EQUALIS-PROTOCOL-OVERVIEW.md
│   ├── AGENTIC-FINANCE.md
│   ├── POSITION-AGENT-SYSTEM-DESIGN.md
│   └── ...
├── lib/                # Git submodules
└── foundry.toml        # Foundry configuration
```

## Contributing Guidelines

### Branch Naming

- `feat/description` — New features
- `fix/description` — Bug fixes
- `docs/description` — Documentation updates
- `refactor/description` — Code refactoring
- `test/description` — Test additions/improvements
- `security/description` — Security-related changes

### Making Changes

1. **Create a new branch** from `dev`:

```bash
git checkout dev
git pull upstream dev
git checkout -b feat/your-feature-name
```

2. **Make your changes** following our coding standards

3. **Commit your changes** using conventional commits:

```bash
git add .
git commit -m "feat: add new module for X functionality

Detailed description of what changed and why."
```

### Commit Message Format

We follow [Conventional Commits](https://www.conventionalcommits.org/):

- `feat:` — New feature
- `fix:` — Bug fix
- `docs:` — Documentation only
- `style:` — Formatting, missing semicolons, etc.
- `refactor:` — Code change that neither fixes a bug nor adds a feature
- `perf:` — Performance improvement
- `test:` — Adding or correcting tests
- `chore:` — Build process or auxiliary tool changes
- `security:` — Security-related changes

### Solidity Coding Standards

- **Solidity Version**: Use `^0.8.33` as specified in `foundry.toml`
- **Style**: Follow the existing code style (4-space tabs, 120 char line length)
- **Comments**: Use NatSpec format for all public/external functions
- **Imports**: Use explicit imports, avoid `*` imports
- **Errors**: Use custom errors instead of revert strings

Example:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Example Contract
/// @notice Brief description of the contract
/// @dev Additional details for developers
contract ExampleContract {
    /// @notice Emitted when a deposit is made
    /// @param user The address of the depositor
    /// @param amount The amount deposited
    event Deposit(address indexed user, uint256 amount);
    
    /// @notice Thrown when the deposit amount is zero
    error ZeroDeposit();
    
    /// @notice Deposit tokens into the contract
    /// @param amount The amount to deposit
    /// @dev Emits a Deposit event on success
    function deposit(uint256 amount) external {
        if (amount == 0) revert ZeroDeposit();
        // ... implementation
        emit Deposit(msg.sender, amount);
    }
}
```

### Diamond Pattern Specifics

Equalis uses the Diamond proxy pattern (EIP-2535). When contributing:

- **Facets**: New functionality should be added as facets when appropriate
- **Storage**: Use Diamond storage patterns for state variables
- **Selectors**: Ensure function selectors don't collide
- **Upgrades**: Consider upgrade paths for all changes

## Testing

### Run Tests

Run the full test suite:

```bash
forge test
```

Run with verbosity:

```bash
forge test -vv
```

Run specific test:

```bash
forge test --match-test testFunctionName -vvv
```

### Test Coverage

Generate coverage report:

```bash
forge coverage
```

### Writing Tests

- Place tests in `test/` directory
- Name test files with `Test` suffix (e.g., `CoreTest.t.sol`)
- Name test functions with `test` prefix
- Use `setUp()` function for test initialization
- Test both success and failure cases
- Use fuzzing where appropriate

Example:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../src/core/Core.sol";

contract CoreTest is Test {
    Core core;
    
    function setUp() public {
        core = new Core();
    }
    
    function testDeposit() public {
        // Test implementation
    }
    
    function testDepositRevertZero() public {
        vm.expectRevert(Core.ZeroDeposit.selector);
        core.deposit(0);
    }
}
```

### Invariant Testing

Equalis uses Foundry's invariant testing. Configuration in `foundry.toml`:

```toml
[invariant]
runs = 256
depth = 50
fail_on_revert = false
```

When adding new invariants:
- Document the invariant being tested
- Ensure handlers properly exercise the protocol
- Consider edge cases and boundary conditions

## Security

### Security Checklist

Before submitting a PR, ensure:

- [ ] No compiler warnings
- [ ] All tests pass
- [ ] New code has adequate test coverage
- [ ] No obvious reentrancy vulnerabilities
- [ ] Access controls are properly implemented
- [ ] Integer overflow/underflow protection (built into 0.8.x)
- [ ] External calls are handled safely
- [ ] No hardcoded secrets or private keys

### Reporting Security Issues

**DO NOT** open public issues for security vulnerabilities.

Instead, email security concerns to: security@equalfi.io (or appropriate contact)

Include:
- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if any)

## Pull Request Process

1. **Update documentation** if your changes affect user-facing functionality
2. **Add tests** for new functionality
3. **Ensure CI passes** — all tests and checks must pass
4. **Fill out the PR template** with details about your changes
5. **Link related issues** using keywords (Fixes #123, Closes #456)
6. **Request review** from maintainers

### PR Review Criteria

Maintainers will review for:

- **Correctness**: Does the code do what it claims?
- **Security**: Are there any security concerns?
- **Testing**: Is the code adequately tested?
- **Documentation**: Is the code well-documented?
- **Style**: Does it follow project conventions?
- **Gas Efficiency**: Are there unnecessary gas costs?

## Community

### Discord

Join our community on Discord: [https://discord.gg/brsSMDux4T](https://discord.gg/brsSMDux4T)

Channels:
- `#general` — General discussion
- `#dev` — Development questions
- `#security` — Security discussions

### Resources

- [Equalis Protocol Overview](./docs/EQUALIS-PROTOCOL-OVERVIEW.md)
- [Agentic Finance](./docs/AGENTIC-FINANCE.md)
- [Position Agent System Design](./docs/POSITION-AGENT-SYSTEM-DESIGN.md)
- [Vitalik on Low-Risk DeFi](https://vitalik.eth.limo/general/2025/09/21/low_risk_defi.html)
- [The Trustless Manifesto](https://trustlessness.eth.limo/general/2025/11/11/the-trustless-manifesto.html)

## License

By contributing to EqualFi, you agree that your contributions will be licensed under the project's license (see LICENSE file).

---

**Thank you for contributing to the future of unified DeFi infrastructure!**
