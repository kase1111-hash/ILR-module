# Changelog

All notable changes to the NatLangChain ILRM Protocol will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0-alpha] - 2026-01-01

### Added

#### Smart Contracts (16 Contracts)
- **ILRM.sol** - Core dispute resolution engine with breach disputes, voluntary requests, ZK mode, FIDO auth, and DID integration
- **MultiPartyILRM.sol** - Multi-party variant supporting 3+ parties with configurable quorum types
- **Oracle.sol** - LLM proposal bridge with EIP-712 signatures and multi-oracle support
- **Treasury.sol** - Protocol fund management with dynamic caps and tiered subsidies
- **AssetRegistry.sol** - IP asset and license tracking with freeze/unfreeze and fallback licenses
- **ComplianceEscrow.sol** - Viewing key threshold cryptography using Shamir's Secret Sharing
- **ComplianceCouncil.sol** - Legal compliance with BLS threshold signatures
- **IdentityVerifier.sol** - ZK proof verification (Groth16) on BN254 curve
- **FIDOVerifier.sol** - Hardware-backed authentication (P-256/WebAuthn, RIP-7212)
- **DIDRegistry.sol** - Decentralized identity management (ERC-725 compatible)
- **GovernanceTimelock.sol** - Multi-sig governance with configurable delays
- **BatchQueue.sol** - Privacy-preserving batch transactions with Fisher-Yates shuffle
- **DummyTransactionGenerator.sol** - Transaction pattern obfuscation
- **L3Bridge.sol** - Layer 3 rollup bridge with commit-reveal fraud proofs
- **L3DisputeBatcher.sol** - Batch dispute handling for L3
- **L3StateVerifier.sol** - Merkle proof verification with sparse tree support

#### Security
- Complete security audit with all 15 findings fixed (3 Critical, 4 High, 5 Medium, 3 Low)
- MEV protection via commit-reveal scheme for fraud proofs (H-02 fix)
- ReentrancyGuard on all state-changing functions
- Pausable emergency stops
- Ownable2Step for safe ownership transfers
- SafeERC20 for token transfers
- CEI pattern enforcement

#### Testing
- Unit tests for core contracts
- Integration tests (CrossContractIntegration.t.sol)
- End-to-end tests with 100+ scenarios (E2ESimulation.t.sol)
- Security exploit tests (SecurityExploits.t.sol)
- State machine permutation tests
- Deadlock-free verification tests
- Fuzz testing (256 runs default, 10,000 in CI)

#### SDK
- Cryptographic utilities (ECIES, Shamir, Threshold BLS)
- Identity proofs and viewing keys
- FIDO2/WebAuthn integration
- Security module with Boundary-SIEM and boundary-daemon integration
- Error handling infrastructure with circuit breaker and retry patterns

#### CI/CD & Infrastructure
- GitHub Actions workflow (.github/workflows/ci.yml)
- Slither static analysis integration
- Test coverage reporting (Codecov)
- Contract verification automation (scripts/verify-contracts.js)
- Multi-network deployment support (Ethereum, Optimism, Arbitrum, Sepolia)

#### Documentation
- Protocol specification (SPEC.md v1.5)
- Protocol safety invariants
- Security audit report
- Simulation results
- Deployment guide
- Emergency procedures runbook
- Contributing guide
- Code of conduct

#### Development Tools
- Windows batch files (assemble.bat, startup.bat)
- Environment configuration template (.env.example)
- Hardhat configuration with network presets
- Governance deployment script

### Security Notes

This is an **alpha release** intended for testnet deployment and security review only.

**Do not deploy to mainnet without:**
- Independent security review of all fixes
- Full test suite passing with extended fuzz runs
- Multi-sig governance configured and tested
- Emergency procedures tested on testnet
- Team trained on incident response

### Protocol Specification

This release implements Protocol Specification v1.5, which defines:
- 10 core safety invariants
- Dual initiation model (breach disputes and voluntary requests)
- Symmetric staking mechanics
- Counter-proposal limits with exponential fees
- Timeout resolution with burns and fallback licenses
- L3 scaling architecture

---

## [Unreleased]

### Planned
- Subgraph indexer (TheGraph integration)
- Monitoring dashboard (Grafana/Dune analytics)
- Formal verification for critical paths
- Testnet deployments (Sepolia, Optimism Sepolia)
- Production token configuration
- Deployment address registry

---

*For the full protocol specification, see [SPEC.md](./SPEC.md).*
*For security audit details, see [docs/SECURITY_AUDIT_REPORT.md](./docs/SECURITY_AUDIT_REPORT.md).*
