# Contributing to EqualFi

Thank you for your interest in contributing to EqualFi and The Equalis Protocol! This document provides guidelines and instructions for contributing to our deterministic unified liquidity base layer for DeFi.

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [Development Workflow](#development-workflow)
- [Submitting Changes](#submitting-changes)
- [Style Guidelines](#style-guidelines)
- [Security](#security)
- [Community](#community)

## Code of Conduct

This project and everyone participating in it is governed by our commitment to:

- **Be respectful**: Treat everyone with respect. Healthy debate is encouraged, but harassment is not tolerated.
- **Be constructive**: Provide constructive feedback and be open to receiving it.
- **Focus on what's best for the community**: Prioritize the collective benefit of the protocol and its users.
- **Show empathy**: Understand that we all have different backgrounds and perspectives.

## Getting Started

### Prerequisites

Before you begin, ensure you have the following installed:

- **Git** (for submodules)
- **Foundry** (forge, cast, anvil) — `solc` is pinned to **0.8.33** via Foundry config
- **Bash** (for helper scripts under `script/`)

### Installation

1. **Install Foundry** (if not already installed):
   ```bash
   curl -L https://foundry.paradigm.xyz | bash
   foundryup
   ```

2. **Clone the repository**:
   ```bash
   git clone https://github.com/EqualFiLabs/EqualFi.git
   cd EqualFi
   ```

3. **Install dependencies**:
   The repo uses git submodules for core dependencies.
   ```bash
   forge install
   ```

4. **Verify installation**:
   ```bash
   forge build
   ```

## Development Workflow

### Branching Strategy

- `dev` — Main development branch
- `main` — Production-ready code
- Feature branches — Create from `dev` using the naming convention:
  - `feature/description` for new features
  - `fix/description` for bug fixes
  - `docs/description` for documentation updates
  - `refactor/description` for code refactoring

### Building

Compile the contracts:
```bash
forge build
```

### Testing

Run the test suite:
```bash
forge test
```

Run tests with verbosity:
```bash
forge test -vvv
```

Run specific test:
```bash
forge test --match-test testName
```

### Code Quality

Before submitting changes, ensure:

1. **All tests pass**:
   ```bash
   forge test
   ```

2. **Code is formatted**:
   ```bash
   forge fmt
   ```

3. **Static analysis passes** (if configured):
   ```bash
   forge snapshot
   ```

## Submitting Changes

### Pull Request Process

1. **Fork the repository** and create your branch from `dev`.

2. **Make your changes** following our style guidelines.

3. **Add or update tests** as necessary.

4. **Update documentation** if your changes affect usage or architecture.

5. **Ensure all tests pass** and code is properly formatted.

6. **Fill out the pull request template** with:
   - Clear description of changes
   - Motivation for the changes
   - Any breaking changes
   - Testing performed

7. **Request review** from maintainers.

8. **Address review feedback** promptly.

### Commit Message Guidelines

We follow conventional commits:

- `feat:` — New feature
- `fix:` — Bug fix
- `docs:` — Documentation changes
- `style:` — Code style changes (formatting, no logic change)
- `refactor:` — Code refactoring
- `test:` — Adding or updating tests
- `chore:` — Maintenance tasks

Example:
```
feat: add support for multi-hop swaps

Implements routing through multiple liquidity pools
to optimize swap execution and reduce slippage.
```

## Style Guidelines

### Solidity

- Follow the [Solidity Style Guide](https://docs.soliditylang.org/en/latest/style-guide.html)
- Use `solc` version 0.8.33 as specified in foundry.toml
- Use NatSpec comments for all public functions
- Maximum line length: 120 characters
- Use explicit visibility modifiers
- Follow naming conventions:
  - `PascalCase` for contracts
  - `camelCase` for functions and variables
  - `SCREAMING_SNAKE_CASE` for constants

### Testing

- Write tests using Foundry's testing framework
- Aim for high test coverage on critical paths
- Use descriptive test names: `test_DescriptiveName_StateUnderTest_ExpectedBehavior`
- Include both positive and negative test cases
- Use fuzzing where appropriate for input validation

### Documentation

- Document all public functions with NatSpec
- Include `@notice` for user-facing documentation
- Include `@dev` for developer notes
- Include `@param` and `@return` where applicable
- Update README.md for significant feature changes

## Security

### Reporting Vulnerabilities

**DO NOT** open public issues for security vulnerabilities.

Instead, please report security issues privately:

- Email: security@equalfi.io (if available)
- Or open a private security advisory on GitHub

Include:
- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if any)

We will acknowledge receipt within 48 hours and provide updates on our progress.

### Security Best Practices

When contributing code:

- Follow [Solidity security best practices](https://consensys.github.io/smart-contract-best-practices/)
- Use checks-effects-interactions pattern
- Be mindful of reentrancy vulnerabilities
- Validate all external inputs
- Use established libraries (OpenZeppelin) where possible
- Consider gas optimization without sacrificing security

## Community

### Communication Channels

- **Discord**: [Join our community](https://discord.gg/brrsMNDux4T)
- **GitHub Discussions**: For technical questions and proposals
- **GitHub Issues**: For bug reports and feature requests

### Getting Help

If you need help:

1. Check existing documentation and README
2. Search closed issues and discussions
3. Ask in Discord community channel
4. Open a discussion for complex questions

### Recognition

Contributors will be recognized in our release notes and documentation. Significant contributions may be eligible for additional rewards at the team's discretion.

---

Thank you for helping build the future of deterministic unified liquidity on Base!
