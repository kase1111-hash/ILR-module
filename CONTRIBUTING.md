# Contributing to ILRM

Thank you for your interest in contributing to the IP & Licensing Reconciliation Module (ILRM)! This document provides guidelines and information for contributors.

## Getting Started

1. **Read the documentation**: Familiarize yourself with the [Technical Specification](SPEC.md) and the [Protocol Safety Invariants](Protocol-Safety-Invariants.md).
2. **Understand the architecture**: Review the contract architecture in the README and understand how the 16 contracts interact.
3. **Set up your environment**: Follow the installation steps in the [README](README.md#installation).

## Prerequisites

- [Foundry](https://getfoundry.sh/) for Solidity development
- [Node.js](https://nodejs.org/) v18+ for TypeScript SDK
- Solidity ^0.8.20
- Git

## How to Contribute

### Reporting Issues

- Use GitHub Issues to report bugs or suggest features
- Search existing issues before creating a new one
- Use the appropriate issue template (Bug Report or Feature Request)
- For security vulnerabilities, use [private vulnerability reporting](https://github.com/kase1111-hash/ILR-module/security/advisories/new)

### Code Contributions

1. **Fork the repository** and create a feature branch
2. **Follow existing code style** and patterns
3. **Write tests** for new functionality
4. **Update documentation** as needed
5. **Submit a Pull Request** with a clear description

### Documentation Contributions

- Improvements to existing docs are welcome
- New documentation should align with the protocol specification
- Use clear, precise language

## Code Standards

### Solidity

- Follow the [Solidity Style Guide](https://docs.soliditylang.org/en/latest/style-guide.html)
- Use NatSpec comments for public functions
- Follow the CEI (Checks-Effects-Interactions) pattern
- Use OpenZeppelin contracts where applicable
- Add ReentrancyGuard to state-changing functions
- Include comprehensive input validation

```solidity
/// @notice Brief description
/// @param paramName Description of parameter
/// @return Description of return value
function exampleFunction(uint256 paramName) external returns (bool) {
    // Checks
    require(paramName > 0, "Invalid parameter");

    // Effects
    state = newState;

    // Interactions
    externalCall();

    return true;
}
```

### TypeScript (SDK)

- Use TypeScript strict mode
- Write type definitions for all public APIs
- Follow existing patterns in the `sdk/` directory
- Document exported functions and types
- Handle errors appropriately with typed errors

### Testing

- Write unit tests for all new functionality
- Include edge cases and failure scenarios
- Use descriptive test names
- Run the full test suite before submitting

```bash
# Foundry (Solidity tests)
forge test                              # Run all tests
forge test -vvv                         # Run with verbosity
forge test --match-contract ILRM -vvv   # Run specific test
forge test --gas-report                 # Run with gas reporting
forge test --fuzz-runs 10000            # Run fuzz tests with high iterations

# Hardhat (JavaScript tests)
npm test                                # Run all Hardhat tests
npx hardhat coverage                    # Run with coverage
npx hardhat test test/ILRM.test.js      # Run a specific test file

# Full suite (both Foundry + Hardhat)
scripts/run-full-tests.sh
```

## Pull Request Process

1. **Ensure all tests pass** before submitting
2. **Update SPEC.md** if your change affects the specification
3. **Update CHANGELOG.md** for notable changes
4. **Reference related issues** in your PR description
5. **Request review** from maintainers
6. **Address feedback** promptly

### PR Checklist

- [ ] Tests added/updated
- [ ] Documentation updated
- [ ] SPEC.md updated (if applicable)
- [ ] CHANGELOG.md updated (if applicable)
- [ ] No breaking changes (or clearly documented)
- [ ] Gas impact documented (for contract changes)
- [ ] Security considerations addressed

## Development Workflow

### Branch Naming

- `feature/` - New features
- `fix/` - Bug fixes
- `docs/` - Documentation updates
- `refactor/` - Code refactoring
- `test/` - Test improvements

### Commit Messages

Use clear, descriptive commit messages:

```
type(scope): brief description

Longer description if needed.

Refs: #123
```

Types: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`

### Local Development

```bash
# Clone and setup
git clone https://github.com/kase1111-hash/ILR-module.git
cd ILR-module
forge install
npm install

# Build
forge build

# Test
forge test

# Format
forge fmt
```

## Security

- Review the [Security Policy](SECURITY.md) before contributing
- Never commit secrets or private keys
- Report security issues privately
- Consider attack vectors in your changes
- Add appropriate access controls

## Community

- Be respectful and constructive
- Follow the [Code of Conduct](CODE_OF_CONDUCT.md)
- Help others learn and contribute

## License

By contributing, you agree that your contributions will be licensed under the project's [Apache-2.0 license](LICENSE).

---

**Questions?** Open an issue or start a discussion.

**Last Updated:** February 2026
