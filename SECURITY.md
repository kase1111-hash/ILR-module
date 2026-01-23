# Security Policy

## Supported Versions

The following versions of ILRM are currently being supported with security updates:

| Version | Supported          |
| ------- | ------------------ |
| 0.1.x   | :white_check_mark: |

## Reporting a Vulnerability

We take the security of ILRM seriously. If you believe you have found a security vulnerability, please report it to us as described below.

**Please do not report security vulnerabilities through public GitHub issues.**

### How to Report

1. **Email**: Send details to the maintainers via the repository contact information
2. **Private Disclosure**: Use [GitHub's private vulnerability reporting](https://github.com/kase1111-hash/ILR-module/security/advisories/new) feature

### What to Include

Please include the following information in your report:

- Type of vulnerability (e.g., reentrancy, access control, integer overflow)
- Full paths of source file(s) related to the vulnerability
- Location of the affected source code (tag/branch/commit or direct URL)
- Step-by-step instructions to reproduce the issue
- Proof-of-concept or exploit code (if possible)
- Impact assessment and potential attack scenarios

### Response Timeline

- **Initial Response**: Within 48 hours of receipt
- **Status Update**: Within 7 days with an expected resolution timeline
- **Resolution**: Security patches will be prioritized based on severity

### Severity Classification

We use the following severity levels:

| Severity | Description | Response Time |
|----------|-------------|---------------|
| Critical | Direct fund loss or protocol compromise | Immediate |
| High | Significant impact on protocol operation | 24-48 hours |
| Medium | Limited impact, requires specific conditions | 1 week |
| Low | Minor issues, best practice violations | 2 weeks |

## Security Measures

### Smart Contract Security

- All contracts use OpenZeppelin's battle-tested libraries
- ReentrancyGuard on all state-changing functions
- Pausable for emergency stops
- Ownable2Step for safe ownership transfers
- SafeERC20 for token transfers
- CEI (Checks-Effects-Interactions) pattern enforcement

### Audit Status

This protocol has undergone security review. All identified vulnerabilities have been addressed:

- 3 Critical findings - Fixed
- 4 High findings - Fixed
- 5 Medium findings - Fixed
- 3 Low findings - Fixed

See [docs/SECURITY_AUDIT_REPORT.md](./docs/SECURITY_AUDIT_REPORT.md) for full details.

## Security Best Practices for Users

### Before Interacting with ILRM

1. **Verify Contract Addresses**: Only interact with official contract addresses
2. **Use Hardware Wallets**: For significant transactions, use hardware wallet signing
3. **Review Transactions**: Carefully review all transaction details before signing
4. **Start Small**: Test with small amounts before larger transactions

### For Developers

1. **Use Official SDK**: Use the official TypeScript SDK for integrations
2. **Validate Inputs**: Always validate user inputs before contract calls
3. **Monitor Events**: Subscribe to contract events for real-time updates
4. **Test on Testnet**: Always test integrations on Sepolia first

## Scope

The following are in scope for security reports:

- Smart contracts in `/contracts`
- SDK code in `/sdk`
- Circuits in `/circuits`
- Deployment scripts in `/scripts`

The following are out of scope:

- Third-party dependencies (report to respective projects)
- Issues in test files
- Documentation-only issues
- Issues requiring physical access to user devices

## Acknowledgments

We appreciate responsible disclosure and will acknowledge security researchers who report valid vulnerabilities (with permission) in our security advisories.

## Contact

For security concerns, please use GitHub's private vulnerability reporting feature or contact the maintainers directly through the repository.

---

**Important**: This is an alpha release. Do not deploy to mainnet without completing the [Production Checklist](./PRODUCTION_CHECKLIST.md) and obtaining independent security review.
