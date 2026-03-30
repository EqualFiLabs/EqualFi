# Contributing to EqualFi

Thank you for your interest in contributing to EqualFi! This document provides guidelines for contributing to the Equalis Protocol.

## Code of Conduct

This project adheres to a standard of professional conduct. By participating, you agree to:
- Be respectful and constructive in all interactions
- Focus on technical merit and protocol improvement
- Maintain confidentiality of non-public security issues

## How to Contribute

### Reporting Issues

If you find a bug or have a suggestion:
1. Check existing issues to avoid duplicates
2. Provide a clear description with steps to reproduce (for bugs)
3. Include relevant code snippets, transaction hashes, or logs
4. Tag the issue appropriately (bug, enhancement, documentation, etc.)

### Security Issues

**Do not report security vulnerabilities publicly.**

For security-related issues, please follow responsible disclosure practices:
- Contact the maintainers privately
- Allow reasonable time for fixes before public disclosure
- Do not exploit vulnerabilities for personal gain

### Pull Request Process

1. **Fork and Branch**: Create a feature branch from `dev`
   ```bash
   git checkout -b feature/your-feature-name
   ```

2. **Development Setup**:
   ```bash
   # Install Foundry
   curl -L https://foundry.paradigm.xyz | bash
   foundryup
   
   # Clone and setup
   git submodule update --init --recursive
   forge build
   ```

3. **Make Changes**:
   - Follow existing code style and patterns
   - Add tests for new functionality
   - Update documentation as needed
   - Ensure all tests pass: `forge test`

4. **Commit Guidelines**:
   - Use clear, descriptive commit messages
   - Reference issues where applicable
   - Keep commits focused and atomic

5. **Submit PR**:
   - Target the `dev` branch
   - Provide a clear description of changes
   - Link related issues
   - Respond to review feedback promptly

## Development Guidelines

### Code Style

- **Solidity**: Follow the [Solidity Style Guide](https://docs.soliditylang.org/en/latest/style-guide.html)
- **Naming**: Use descriptive names; prefix internal functions with underscore
- **Comments**: Document complex logic; use NatSpec for public functions
- **Gas Optimization**: Consider gas costs for on-chain operations

### Testing

All contributions must include appropriate tests:
- Unit tests for new functions
- Integration tests for cross-contract interactions
- Edge case coverage
- Gas usage benchmarks where relevant

Run tests before submitting:
```bash
forge test
```

### Documentation

- Update relevant docs in the `/docs` directory
- Keep README.md current with setup instructions
- Document architectural decisions in appropriate `.md` files

## Areas for Contribution

We welcome contributions in these areas:

- **Core Protocol**: Lending, borrowing, and index mechanics
- **Agent Wallet**: ERC-6551 and ERC-6900 implementations
- **Documentation**: Clarifications, examples, and tutorials
- **Testing**: Additional test coverage and edge cases
- **Tooling**: Developer tools and integrations

## Questions?

- Join our [Discord](https://discord.gg/brsMNDux4T) for real-time discussion
- Open a GitHub Discussion for architectural questions
- Review existing documentation in `/docs`

## License

By contributing, you agree that your contributions will be licensed under the Business Source License 1.1 as specified in [LICENSE](./LICENSE).

---

**Thank you for helping build the sovereign financial internet!**
