# Changelog

All notable changes to the NatLangChain ILRM Protocol will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

A correctness and security pass. Before it, no contract compiled, so no test suite had ever run and every CI
job failed. Accepted residual risks are listed in [docs/KNOWN_LIMITATIONS.md](docs/KNOWN_LIMITATIONS.md).

### Security - core contracts (audit scope)
- **Oracle -> ILRM proposals always reverted.** `Oracle.submitProposal` bumped the nonce before ILRM re-verified
  the signature, so every real proposal failed with "Invalid signature". The nonce is now consumed after the call.
- **Stakes could be locked forever.** `AssetRegistry.unfreezeAssets` reverted when a dispute froze no assets
  (initiator had none, or they were frozen by another dispute); ILRM calls it on every resolution path. It is now
  a no-op in that case.
- **Treasury subsidies could be drained.** `requestSubsidy` paid subsidies into the counterparty's wallet. Subsidies
  are now escrowed as part of the counterparty's stake in ILRM (`depositStakeWithSubsidy` ->
  `Treasury.fundStakeSubsidy`, ILRM-only) and the funder is repaid pro rata on resolution. A `maxTopUp` slippage
  bound stops a front-run from overcharging the defender, and Treasury records are keyed by (ILRM, disputeId).
- **Initiator incentive could be farmed.** Non-participation paid 10% of the stake from `tokenReserves` to any
  initiator, including one whose counterparty was its own sybil. Payouts are now capped per dispute and per
  window (`setInitiatorIncentiveCaps`; defaults 1 token per dispute and 10 tokens per 30 days). The initiator
  always gets its full stake back. Farming up to the window cap remains possible (documented).
- **Proposal rounds.** Every counter-proposal round can receive a new oracle proposal without the owner (one per
  round). Signatures bind the round and evidence hash. Storing a proposal clears both acceptances.
- **Owner reset is atomic.** `resetProposal` (and the new pinned `resetProposalExact`) voids the proposal in ILRM in
  the same transaction (`voidLLMProposal`), so a voided proposal can no longer resolve a dispute.
- **Hash-bound acceptance.** `acceptProposalWithHash(id, keccak256(text))` reverts if the live proposal changed.
- **Deadlines.** `counterPropose` and the owner reset revert after the resolution deadline, so a timed-out dispute
  can no longer be revived.
- `ILRM.counterPropose` and `initiateBreachDispute` follow checks-effects-interactions.

### Fixed - deferred modules
- **L3Bridge / L3DisputeBatcher / L3StateVerifier** (not production-ready, must not be deployed): honest fraud-proof
  challengers can no longer be blocked (multiple bonded commitments per root, reveal bound to its root, defined bond
  outcomes); the batcher can bridge (dispute-bridger / settlement-relayer roles); one bad settlement no longer stalls
  a batch, unfinalized-root settlements stay queued, and failed auto-batches back off and reset on fixes.
- **ComplianceCouncil**: BLS12-381 verification works on EIP-2537 chains (final precompile addresses, RFC 9380
  hash-to-G2, correct pairing); STRICT_ONCHAIN interpolates and verifies the threshold signature on chain; only
  current members' votes and partial signatures count; councils with n > 2t can be configured; `updateConfig` no
  longer corrupts the member count; duplicate and infinity points are rejected. The SDK (`threshold-bls`) matches
  the contract encoding and aggregates only current partials.
- **GovernanceTimelock**: OZ v5 compatible without overriding its state views (overriding `getTimestamp` would have
  made executed operations replayable); a working, restricted emergency path (`EMERGENCY_ROLE`, per-selector call
  classes, labels can only lengthen delays); guardian unpauses are queued and bound to the pause epoch; execution can
  no longer be bricked; stale unpauses are reported as `Stale`.
- **MultiPartyILRM**: served by the Oracle again (lean `IOracleConsumer` interface); counter fee burned after state
  updates; deadlines on proposals, counter-proposals and rejections; evidence changes limited per round.
- **DIDRegistry / FIDOVerifier**: the sybil score covers every credential and is computed live; per-issuer quota
  (10 of 50 slots) and `revokeIssuerCredentials`; `renewCredential` renews in place; expired issuance rejected;
  the P-256 fallback works and rejects invalid keys; corrected P-256 prime and precompile self-test.
- **BatchQueue / DummyTransactionGenerator**: queue release and execution can no longer be bricked; escrow is
  per transaction and reclaimable; relaying ships disabled (ILRM has no relay entry points yet); a failed dummy
  generation consumes its attempt.

### Breaking changes
- `IILRM.disputes(id)` returns the `Dispute` struct; its `fallback` field is renamed `fallbackLicense`.
- `Treasury.requestSubsidy` is removed; use `ILRM.depositStakeWithSubsidy(id, maxSubsidy, maxTopUp)`. Deployments
  must call `ilrm.setSubsidyTreasury(treasury)` (`scripts/deploy.js` does).
- Oracle EIP-712 type is `Proposal(uint256 disputeId,uint256 round,bytes32 evidenceHash,bytes32 proposalHash,uint256 nonce)`;
  use `Oracle.proposalContext` / `proposalDigest`. `ProposalAlreadyProcessed` carries `(disputeId, round)`.
- `depositStake`, `depositStakeWithSubsidy` and `counterPropose` need about 112k gas left for the advisory oracle
  request (gas floor).
- ComplianceCouncil BLS structs use EIP-2537 encoding; L3Bridge commit-hash formula and commitment struct changed;
  BatchQueue `queueAcceptance(uint256, bytes32)` and non-payable `queueTransaction`; GovernanceTimelock emits
  `EmergencyActionScheduled` and appends `OperationStatus.Stale`.

### Tooling, CI and docs
- Foundry dependencies are git submodules (OpenZeppelin v5.4.0, forge-std v1.11.0); `package-lock.json` is
  committed; `@openzeppelin/contracts` is pinned to 5.4.0; `hardhat-toolbox` v6 fixes the npm peer conflict.
  Node.js 20.19+ is required.
- Foundry pinned to `stable` in CI; `[fmt]` config fixed and the codebase formatted (byte-identical bytecode).
- Slither config fixed and CI gates every contract on Medium/High findings (all resolved or justified inline).
- The SDK typechecks in CI; `scripts/deploy.js` validates its whole configuration before deploying;
  `scripts/interact.js` drives the full lifecycle through the Oracle; the governance call policy classifies every
  new admin function.
- Subgraph rebuilt against the current contracts (ABIs generated from artifacts, every event indexed, metrics
  fixes) with a CI job running ABI checks, codegen, build and matchstick tests.
- Tests: from 0 runnable to 625 Foundry (10,000 fuzz runs) and 276 Hardhat tests, plus 29 subgraph tests.
- New docs: `docs/KNOWN_LIMITATIONS.md`; `AUDIT_SCOPE.md`, `Treasury.md`, `SPEC.md`, `docs/EMERGENCY_PROCEDURES.md`
  and `docs/MULTISIG_CONFIG.md` updated to match the code.

## [0.1.0-alpha] - 2026-01-02

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

#### Monitoring & Indexing
- **TheGraph Subgraph** - Complete indexing infrastructure for all contracts (subgraph/)
- **Dune Analytics Queries** - SQL queries for disputes, financial metrics, participants, L3 bridge
- **Alert Configuration** - P0-P3 severity alerting with PagerDuty/Slack/Discord support
- **Sign-off Procedures** - Detailed mainnet deployment checklist

#### Production Readiness
- Full test suite runner (scripts/run-full-tests.sh)
- Gas benchmarking infrastructure (test/GasBenchmarks.t.sol)
- Multi-sig configuration guide and test scripts
- Dependabot for automated dependency updates

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
- Formal verification for critical paths
- Testnet deployments (Sepolia, Optimism Sepolia)
- Production token configuration
- Deployment address registry
- Mainnet deployment (Optimism, Arbitrum)

---

*For the full protocol specification, see [SPEC.md](./SPEC.md).*
*For security audit details, see [docs/SECURITY_AUDIT_REPORT.md](./docs/SECURITY_AUDIT_REPORT.md).*
