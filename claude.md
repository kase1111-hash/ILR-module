# Claude Code Context - ILR Module

## Project Overview

The **IP & Licensing Reconciliation Module (ILRM)** is the core dispute resolution and licensing reconciliation component of the NatLangChain Protocol. It provides automated IP arbitration through stake-based economic incentives that compress dispute timelines from months to days.

**Key Philosophy**: "NatLangChain doesn't govern people - it governs the price of conflict."

**Status**: v0.1.0-alpha (Testnet Ready, NOT production-ready)

## Technology Stack

- **Smart Contracts**: Solidity ^0.8.20 with OpenZeppelin v5.4.0
- **Frameworks**: Foundry (primary), Hardhat v2.22.0
- **SDK**: TypeScript with ethers.js v6.16.0
- **ZK Circuits**: Circom
- **Indexing**: TheGraph subgraph
- **Analytics**: Dune SQL queries

## Directory Structure

```
contracts/           # 16 Solidity smart contracts
├── interfaces/      # Contract interfaces (13 files)
├── mocks/          # Test mocks
sdk/                # TypeScript SDK (cryptography, identity, security)
test/               # Foundry (*.t.sol) and Hardhat (*.test.js) tests
circuits/           # ZK circuits (prove_identity.circom)
subgraph/           # TheGraph event indexing
monitoring/         # Alerts and Dune Analytics queries
scripts/            # Deployment and setup scripts
docs/               # Comprehensive documentation
```

## Key Contracts

| Contract | Purpose |
|----------|---------|
| `ILRM.sol` | Core dispute resolution engine |
| `MultiPartyILRM.sol` | 3+ party disputes with quorum |
| `Oracle.sol` | LLM proposal bridge with EIP-712 |
| `Treasury.sol` | Fund management with anti-Sybil protections |
| `AssetRegistry.sol` | IP asset tracking and freeze/unfreeze |
| `ComplianceEscrow.sol` | Viewing key management (Shamir's SS) |
| `ComplianceCouncil.sol` | Legal compliance with BLS signatures |
| `IdentityVerifier.sol` | ZK proof verification (Groth16) |
| `FIDOVerifier.sol` | Hardware auth (P-256/WebAuthn) |
| `DIDRegistry.sol` | Decentralized identity (ERC-725) |
| `GovernanceTimelock.sol` | Multi-sig governance |
| `L3Bridge.sol` | Layer 3 optimistic rollup scaling |

## Development Commands

```bash
# Build
forge build              # Compile with Foundry
npm run compile          # Compile with Hardhat

# Test
forge test               # Run Foundry tests
forge test -vvv          # Verbose output
npm test                 # Run Hardhat tests
npm run coverage         # Generate coverage report

# Security
slither .                # Static analysis

# Deploy
npm run deploy:sepolia   # Deploy to Sepolia testnet
npm run deploy:optimism  # Deploy to Optimism
npm run deploy:arbitrum  # Deploy to Arbitrum
```

## Testing

- **Foundry tests** (`test/*.t.sol`): Unit tests, fuzz tests, gas benchmarks
- **Hardhat tests** (`test/*.test.js`): Integration and lifecycle tests
- **CI runs**: 10,000 fuzz iterations, gas reporting, Slither analysis

Key test files:
- `ILRM.t.sol` - Core dispute lifecycle
- `E2ESimulation.t.sol` - 100+ end-to-end scenarios
- `SecurityExploits.t.sol` - Vulnerability testing
- `GasBenchmarks.t.sol` - Gas profiling

## Protocol Constants

```solidity
STAKE_WINDOW = 3 days           // Time for counterparty to match stake
RESOLUTION_TIMEOUT = 7 days     // Maximum dispute duration
BURN_PERCENTAGE = 50%           // Burned on timeout
MAX_COUNTERS = 3                // Max counter-proposals
COUNTER_FEE_BASE = 0.01 ETH     // Counter fee (exponential)
COOLDOWN_PERIOD = 30 days       // Between same-party disputes
```

## Code Patterns

- **Security**: ReentrancyGuard, Pausable, Ownable2Step, SafeERC20
- **Access Control**: Role-based with multi-sig timelock
- **MEV Protection**: Commit-reveal scheme for fraud proofs
- **Privacy**: ZK proofs, ECIES encryption, Shamir secret sharing

## Configuration Files

| File | Purpose |
|------|---------|
| `foundry.toml` | Foundry config (optimizer: 200 runs, solc 0.8.20) |
| `hardhat.config.js` | Hardhat networks and plugins |
| `.env.example` | Environment variables template |
| `tsconfig.json` | TypeScript configuration |
| `slither.config.json` | Security analysis config |

## Important Documentation

- `README.md` - Project overview and quick start
- `SPEC.md` - Complete protocol specification v1.5
- `Protocol-Safety-Invariants.md` - 10 formal safety guarantees
- `docs/SECURITY_AUDIT_REPORT.md` - Audit findings (all fixed)
- `docs/DEPLOYMENT_GUIDE.md` - Deployment instructions
- `docs/EMERGENCY_PROCEDURES.md` - Incident response runbook

## SDK Components

The TypeScript SDK in `sdk/` provides:
- `ecies.ts` - ECIES encryption
- `shamir.ts` - Shamir secret sharing
- `threshold-bls.ts` - Threshold BLS signatures
- `fido2.ts` - FIDO2/WebAuthn integration
- `identity-proof.ts` - ZK identity proofs
- `viewing-keys.ts` - Encrypted data access
- `security/` - SIEM and daemon integration

## Common Tasks

### Adding a new contract
1. Create contract in `contracts/`
2. Add interface in `contracts/interfaces/`
3. Add tests in both `test/*.t.sol` and `test/*.test.js`
4. Update deployment script in `scripts/`
5. Add subgraph handlers if emitting events

### Running specific tests
```bash
forge test --match-contract ILRM      # Match contract name
forge test --match-test testStake     # Match test name
forge test --gas-report               # With gas reporting
```

### Checking contract sizes
```bash
forge build --sizes                   # Must be under 24KB
```

## Dispute State Flow

```
Inactive -> Initiated -> Active -> [Proposal/Counter/Timeout] -> Resolved
```

## Networks

- Ethereum Mainnet
- Optimism L2
- Arbitrum L2
- Sepolia Testnet (recommended for testing)
