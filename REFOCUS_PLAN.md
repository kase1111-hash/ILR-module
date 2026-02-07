# ILRM Refocus Plan

**Date:** 2026-02-07
**Basis:** [EVALUATION_REPORT.md](./EVALUATION_REPORT.md)
**Goal:** Ship the core dispute resolution product. Defer everything else.

---

## Current State

| Category | Files | Lines | Status |
|----------|-------|-------|--------|
| Solidity (contracts + interfaces + mocks) | 31 | 14,336 | Written, untested on-chain |
| SDK TypeScript | 13 | 5,580 | Written, no deployed target |
| Supporting (subgraph, monitoring, scripts, docs) | 31 | 7,714 | Written, no data to process |
| **Total** | **75** | **27,630** | **Zero deployments, zero users** |

The core dispute logic is 573 lines inside a 1,290-line contract. The remaining 717 lines are four bolt-on feature domains (ZK Identity, FIDO2, DID, Viewing Keys) that have no user demand signal.

---

## Phase Overview

| Phase | Name | Focus | Gate to Next Phase |
|-------|------|-------|--------------------|
| **0** | Triage | Organize codebase into core vs deferred | Clean separation exists |
| **1** | Strip & Harden | Slim ILRM.sol, simplify Treasury, fix CI | Core 4 contracts compile and pass tests |
| **2** | Deploy & Validate | Testnet deployment, minimal CLI, external audit | Live on Optimism Sepolia with real disputes |
| **3** | Economic Validation | Adversarial testing, parameter tuning, user feedback | Economic model holds under real conditions |
| **4** | Identity & Privacy | Extract ZK/FIDO/DID as composable modules | Identity modules deployed and integrated |
| **5** | Governance & Compliance | Multi-sig, compliance council, escrow | Governance operational pre-mainnet |
| **6** | Scaling & Observability | L3 bridge, subgraph, monitoring | Only if throughput demands it |

---

## Phase 0: Triage & Organize

**Duration:** 1-2 days
**Objective:** Separate core from deferred code without deleting anything. Preserve git history.

### 0.1 Create directory structure

```
contracts/
  core/           <-- Phase 1 target (4 contracts)
  modules/        <-- Phase 4-5 target (identity, compliance, privacy)
  scaling/        <-- Phase 6 target (L3 bridge)
  legacy/         <-- Current code, untouched, for reference
  interfaces/     <-- Keep as-is (shared)
  mocks/          <-- Keep as-is (shared)
```

### 0.2 Classify every contract

| Contract | Lines | Classification | Destination | Phase |
|----------|-------|----------------|-------------|-------|
| `ILRM.sol` | 1,290 | **Core** (needs stripping) | `core/` (slimmed) | 1 |
| `Oracle.sol` | 367 | **Core** | `core/` | 1 |
| `Treasury.sol` | 1,064 | **Core** (needs simplification) | `core/` (slimmed) | 1 |
| `AssetRegistry.sol` | 390 | **Core** | `core/` | 1 |
| `MultiPartyILRM.sol` | 695 | **Supporting** | `modules/` | 3 |
| `IdentityVerifier.sol` | 396 | **Identity module** | `modules/` | 4 |
| `FIDOVerifier.sol` | 727 | **Identity module** | `modules/` | 4 |
| `DIDRegistry.sol` | 721 | **Identity module** | `modules/` | 4 |
| `ComplianceEscrow.sol` | 444 | **Compliance module** | `modules/` | 5 |
| `ComplianceCouncil.sol` | 920 | **Compliance module** | `modules/` | 5 |
| `GovernanceTimelock.sol` | 601 | **Governance module** | `modules/` | 5 |
| `BatchQueue.sol` | 674 | **Privacy/scaling** | `scaling/` | 6 |
| `DummyTransactionGenerator.sol` | 673 | **Privacy/scaling** | `scaling/` | 6 |
| `L3Bridge.sol` | 937 | **Scaling** | `scaling/` | 6 |
| `L3StateVerifier.sol` | 377 | **Scaling** | `scaling/` | 6 |
| `L3DisputeBatcher.sol` | 365 | **Scaling** | `scaling/` | 6 |

### 0.3 Classify SDK modules

| Module | Lines | Classification | Phase |
|--------|-------|----------------|-------|
| `sdk/ecies.ts` | 487 | Identity/privacy | 4 |
| `sdk/shamir.ts` | 376 | Compliance | 5 |
| `sdk/threshold-bls.ts` | 697 | Compliance | 5 |
| `sdk/identity-proof.ts` | 404 | Identity | 4 |
| `sdk/viewing-keys.ts` | 653 | Compliance | 5 |
| `sdk/fido2.ts` | 493 | Identity | 4 |
| `sdk/security/boundary-siem.ts` | 628 | Agent-OS coupling | 6+ (or separate repo) |
| `sdk/security/boundary-daemon.ts` | 724 | Agent-OS coupling | 6+ (or separate repo) |
| `sdk/security/errors.ts` | 604 | Core (keep) | 1 |
| `sdk/security/config.ts` | 290 | Core (keep) | 1 |
| `sdk/security/index.ts` | 138 | Core (keep) | 1 |

### 0.4 Classify infrastructure

| Component | Classification | Phase |
|-----------|----------------|-------|
| `subgraph/` | Defer | 6 |
| `monitoring/` | Defer | 6 |
| `scripts/deploy.js` | Core (update for 4 contracts) | 2 |
| `scripts/deploy-governance.ts` | Governance | 5 |
| `scripts/setup-multisig.sh` | Governance | 5 |
| `scripts/test-multisig.ts` | Governance | 5 |
| `scripts/deploy-subgraph.sh` | Defer | 6 |
| `.github/workflows/ci.yml` | Core (fix Slither) | 1 |

### Exit Criteria
- [ ] Directory structure created
- [ ] Every file has a phase assignment
- [ ] No code deleted (only organized)

---

## Phase 1: Strip & Harden

**Duration:** 1-2 weeks
**Objective:** Produce 4 clean, auditable core contracts. Fix CI. Ship testable code.

### 1.1 Slim ILRM.sol (1,290 -> ~500 lines)

Remove these sections from the core contract and preserve them as standalone modules:

| Section to Extract | Lines | Target Module |
|--------------------|-------|---------------|
| ZK Identity Functions (lines 610-789) | 180 | `modules/ILRMZKIdentity.sol` |
| Viewing Key Functions (lines 790-921) | 132 | `modules/ILRMViewingKeys.sol` |
| FIDO2/WebAuthn Functions (lines 922-1112) | 191 | `modules/ILRMFido.sol` |
| DID Integration (variables 122-157 + functions 1113-1290) | 214 | `modules/ILRMDid.sol` |
| **Total extracted** | **717** | |

What remains in ILRM.sol (~573 lines):
- Constants and core state variables (lines 33-121)
- Constructor (lines 158-178)
- `initiateBreachDispute()` (lines 186-227)
- `initiateVoluntaryRequest()` (lines 233-248)
- `depositStake()` (lines 254-266)
- `submitLLMProposal()` (lines 273-296)
- `acceptProposal()` (lines 299-321)
- `counterPropose()` (lines 327-370)
- `enforceTimeout()` (lines 376-389)
- View functions (lines 394-435)
- Internal resolution functions (lines 437-544)
- Admin functions (lines 546-608)
- `receive()` (line 606-608)

**Design decision:** The extracted modules should be separate contracts that wrap/extend the core ILRM, not modifications to the core. The core ILRM interface should be stable and minimal. Modules interact via the public interface, not by being embedded.

### 1.2 Simplify Treasury.sol (1,064 -> ~350 lines)

Remove for now, restore in later phases:

| Feature to Remove | Lines (approx) | Phase to Restore |
|-------------------|----------------|------------------|
| Tiered subsidies (tier config, multiplier logic) | ~150 | 3 |
| Dynamic caps (scaling with treasury balance) | ~100 | 3 |
| DID integration (DID registry, bonus multipliers, `requestSubsidyWithDID`) | ~240 | 4 |
| Harassment decay curves | ~80 | 3 |
| Batch score updates | ~30 | 3 |

What remains (~350 lines):
- Token deposit/withdrawal
- Flat-cap subsidy requests (`requestSubsidy` with simple per-dispute and per-participant caps)
- Basic harassment score checks (threshold-based, no tiers)
- Rolling window tracking
- Pause/unpause, ownership
- ILRM authorization

### 1.3 Keep Oracle.sol as-is (367 lines)

Oracle.sol is well-scoped. No changes needed. It handles:
- EIP-712 signature verification
- Chain fork detection
- Multi-oracle registration
- Proposal submission and recovery

### 1.4 Keep AssetRegistry.sol as-is (390 lines)

AssetRegistry.sol is well-scoped. No changes needed. It handles:
- Asset registration and transfer
- Dispute freeze/unfreeze
- Fallback license application
- DoS protection (max assets per owner)

### 1.5 Fix CI pipeline

In `.github/workflows/ci.yml`:

- **Remove `continue-on-error: true` from Slither step** (line 117). Slither findings should block merges or be explicitly suppressed in `slither.config.json`.
- **Add `|| true` removal plan**: Replace decorative steps with actual failure conditions.
- **Update test suite to target core contracts only** for this phase.

### 1.6 Update IILRM.sol interface

Strip the interface to match the slimmed contract. The removed functions (ZK, FIDO, DID, viewing keys) should move to separate interfaces:
- `IILRMZKIdentity.sol`
- `IILRMFido.sol`
- `IILRMDid.sol`
- `IILRMViewingKeys.sol`

### 1.7 Update test suite

- Core tests (`ILRM.t.sol`) should pass against the slimmed contract
- `E2ESimulation.t.sol` scenarios that test ZK/FIDO/DID should be moved to module-specific test files
- `SecurityExploits.t.sol` should be reviewed for core-only relevance
- `CrossContractIntegration.t.sol` should target the 4-contract deployment

### Exit Criteria
- [ ] ILRM.sol is ~500 lines, core functions only
- [ ] Treasury.sol is ~350 lines, flat-cap subsidies only
- [ ] Oracle.sol and AssetRegistry.sol unchanged
- [ ] All 4 core contracts compile with `forge build --sizes`
- [ ] Core test suite passes with `forge test --fuzz-runs 10000`
- [ ] Slither runs without `continue-on-error` and produces no critical findings
- [ ] Extracted module code preserved in `modules/` (compiles separately)

---

## Phase 2: Deploy & Validate

**Duration:** 2-4 weeks
**Objective:** Get real transactions flowing on a testnet. Build minimal interaction tooling.

### 2.1 Deploy to Optimism Sepolia

Deploy the 4 core contracts:

1. Deploy `MockToken` (or use an existing testnet token)
2. Deploy `AssetRegistry`
3. Deploy `Oracle`
4. Deploy `ILRM` (with token, oracle, assetRegistry addresses)
5. Deploy `Treasury` (with token, configure ILRM address)
6. Register oracle operator(s)
7. Verify all contracts on Etherscan

Update `scripts/deploy.js` to deploy only core contracts.
Record deployed addresses in README.md and SPEC.md (replace all "TBD" entries).

### 2.2 Build minimal CLI / interaction script

Create `scripts/interact.ts` or a simple CLI that enables:

- `initiate-dispute` -- Initiate a breach dispute with stake
- `deposit-stake` -- Counterparty matches stake
- `submit-proposal` -- Oracle submits LLM proposal
- `accept-proposal` -- Party accepts proposal
- `counter-propose` -- Submit counter-proposal
- `enforce-timeout` -- Trigger timeout resolution
- `request-subsidy` -- Request defensive subsidy from Treasury
- `status` -- View dispute state

This is the minimum viable UX. Not a frontend. Just a script a developer can run.

### 2.3 Commission external audit

Scope: 4 contracts (~1,600 lines total)
- `ILRM.sol` (~500 lines)
- `Oracle.sol` (367 lines)
- `Treasury.sol` (~350 lines)
- `AssetRegistry.sol` (390 lines)

A 1,600-line audit is substantially cheaper and faster than auditing 10,641 lines.

Audit focus areas:
- Reentrancy in stake/withdrawal flows
- Token accounting correctness (no stuck funds)
- Timeout/cooldown enforcement accuracy
- Oracle signature bypass vectors
- Treasury drain vectors via subsidy manipulation

### 2.4 Run first real disputes

Execute at least 10 full dispute lifecycles on testnet:
- 3 happy path (both parties accept proposal)
- 2 timeout (50% burn + fallback license)
- 2 non-participation (counterparty ignores)
- 2 counter-proposal chains (use all 3 counters)
- 1 subsidy-assisted (counterparty uses Treasury)

Document gas costs, timing, and any UX friction.

### Exit Criteria
- [ ] 4 contracts deployed and verified on Optimism Sepolia
- [ ] Contract addresses recorded in README.md
- [ ] CLI script can execute full dispute lifecycle
- [ ] External audit engaged (report pending or complete)
- [ ] 10+ disputes processed on testnet
- [ ] Gas costs documented from real transactions

---

## Phase 3: Economic Validation

**Duration:** 4-8 weeks
**Objective:** Validate the 10 safety invariants under adversarial conditions. Tune parameters.

### 3.1 Adversarial testing campaign

Recruit 5-10 testers to intentionally try to break the economic model:
- Spam dispute initiation (test harassment escalation)
- Grief via maximal counter-proposals (test bounded griefing)
- Attempt treasury drain via subsidy manipulation
- Test cooldown evasion via multiple addresses
- Attempt to force asymmetric outcomes

### 3.2 Parameter sensitivity analysis

Test variant configurations on testnet:

| Parameter | Current | Test Range | Question |
|-----------|---------|------------|----------|
| `STAKE_WINDOW` | 3 days | 1-7 days | Is 3 days too long for fast-moving disputes? |
| `RESOLUTION_TIMEOUT` | 7 days | 3-14 days | Does 7 days compress resolution or frustrate users? |
| `BURN_PERCENTAGE` | 50% | 25-75% | Is 50% enough deterrent? Too punitive? |
| `MAX_COUNTERS` | 3 | 1-5 | Do 3 counters enable gaming or enable negotiation? |
| `COUNTER_FEE_BASE` | 0.01 ETH | 0.001-0.1 ETH | Is the base fee meaningful at current gas prices? |
| `COOLDOWN_PERIOD` | 30 days | 7-90 days | Is 30 days too long to wait between real disputes? |
| `ESCALATION_MULTIPLIER` | 150% | 120-200% | Is 1.5x enough to deter but not prohibit? |

### 3.3 Reintroduce Treasury complexity (if justified)

Based on economic validation data, selectively restore:
- **Tiered subsidies** -- Only if harassment scoring proves insufficient with flat caps
- **Dynamic caps** -- Only if treasury balance volatility affects subsidy availability
- **Harassment decay** -- Only if participants are permanently locked out unfairly

Do not restore DID-based subsidy bonuses yet (that's Phase 4).

### 3.4 Reintroduce MultiPartyILRM (if demanded)

If testers or early users request multi-party dispute support, deploy `MultiPartyILRM.sol` (695 lines, already written). Otherwise defer.

### Exit Criteria
- [ ] Adversarial testing report with findings
- [ ] Parameter recommendations backed by testnet data
- [ ] Safety invariants validated or violated (with fixes)
- [ ] Decision made on Treasury complexity (tiered/dynamic/decay)
- [ ] Decision made on MultiPartyILRM deployment timing

---

## Phase 4: Identity & Privacy Modules

**Duration:** 4-6 weeks
**Objective:** Deploy identity features as composable modules. Not embedded in ILRM.

### 4.1 Extract and deploy identity contracts

Each module is a standalone contract that interacts with ILRM via its public interface:

| Module | Source | Lines | Purpose |
|--------|--------|-------|---------|
| `ILRMZKIdentity.sol` | Extracted from ILRM.sol:610-789 | ~180 | ZK dispute participation |
| `ILRMFido.sol` | Extracted from ILRM.sol:922-1112 | ~191 | Hardware-backed auth |
| `ILRMDid.sol` | Extracted from ILRM.sol:1113-1290 | ~214 | Sybil-resistant participation |
| `IdentityVerifier.sol` | Existing (396 lines) | 396 | Groth16 proof verification |
| `FIDOVerifier.sol` | Existing (727 lines) | 727 | P-256 WebAuthn verification |
| `DIDRegistry.sol` | Existing (721 lines) | 721 | Decentralized identity |

**Architecture pattern:** Wrapper contracts that hold a reference to the core ILRM and add identity verification as a pre-condition before calling ILRM functions. Users who want ZK mode interact with `ILRMZKIdentity`; users who don't interact with `ILRM` directly. The core contract stays clean.

### 4.2 Deploy SDK identity modules

Ship these alongside the contracts:
- `sdk/ecies.ts` (487 lines) -- ECIES encryption for evidence
- `sdk/identity-proof.ts` (404 lines) -- ZK proof generation
- `sdk/fido2.ts` (493 lines) -- WebAuthn client-side

### 4.3 Reintroduce DID-based Treasury features

Now that DIDRegistry is deployed:
- Restore `requestSubsidyWithDID()` in Treasury
- Restore DID bonus multipliers
- Restore minimum sybil score checks

### 4.4 Audit identity modules

Scope: ~2,700 lines (the 6 contracts above). Focus on:
- ZK proof replay attacks
- FIDO challenge reuse
- DID sybil score manipulation
- Identity/dispute binding correctness

### Exit Criteria
- [ ] Identity modules deployed as separate contracts on testnet
- [ ] SDK identity modules published
- [ ] At least 5 disputes completed using each identity mode
- [ ] Identity module audit complete
- [ ] DID-enhanced Treasury features restored and tested

---

## Phase 5: Governance & Compliance

**Duration:** 4-6 weeks
**Objective:** Production governance infrastructure. Required before mainnet.

### 5.1 Deploy governance contracts

| Contract | Lines | Purpose |
|----------|-------|---------|
| `GovernanceTimelock.sol` | 601 | Multi-sig with configurable delays |
| `ComplianceCouncil.sol` | 920 | BLS threshold for legal compliance |
| `ComplianceEscrow.sol` | 444 | Viewing key management |

### 5.2 Transfer ownership

Migrate all contract ownership from deployer EOA to GovernanceTimelock:
1. Deploy Gnosis Safe multi-sig
2. Deploy GovernanceTimelock with Safe as proposer
3. Transfer ownership of ILRM, Oracle, Treasury, AssetRegistry
4. Transfer ownership of identity modules (Phase 4 contracts)
5. Test emergency pause through governance flow

### 5.3 Deploy compliance SDK modules

- `sdk/shamir.ts` (376 lines) -- Shamir Secret Sharing for escrow
- `sdk/threshold-bls.ts` (697 lines) -- BLS threshold signatures
- `sdk/viewing-keys.ts` (653 lines) -- Viewing key management

### 5.4 Deploy governance scripts

- `scripts/deploy-governance.ts` (245 lines)
- `scripts/setup-multisig.sh` (240 lines)
- `scripts/test-multisig.ts` (286 lines)

### 5.5 Mainnet sign-off procedures

Execute the full sign-off checklist from `docs/SIGN_OFF_PROCEDURES.md`:
- Full test suite with 10,000 fuzz runs
- Multi-sig governance tested on testnet
- Emergency procedures tested
- Team trained on incident response
- Gas cost estimates documented in USD

### Exit Criteria
- [ ] GovernanceTimelock deployed and tested
- [ ] All contract ownership transferred to multi-sig
- [ ] Emergency pause tested end-to-end through governance
- [ ] ComplianceCouncil and ComplianceEscrow deployed (if regulatory need exists)
- [ ] Mainnet sign-off checklist complete
- [ ] Ready for mainnet deployment decision

---

## Phase 6: Scaling & Observability

**Duration:** Ongoing, demand-driven
**Objective:** Scale infrastructure only when throughput proves it necessary.

### 6.1 Deploy L3 bridge (only if needed)

**Trigger:** Dispute volume exceeds what L2 can handle cost-effectively.

| Contract | Lines | Purpose |
|----------|-------|---------|
| `L3Bridge.sol` | 937 | L2-to-L3 dispute bridging |
| `L3StateVerifier.sol` | 377 | Merkle proof verification |
| `L3DisputeBatcher.sol` | 365 | Batch dispute handling |

Do not deploy these speculatively. The commit-reveal fraud proof system, sequencer infrastructure, and batch settlement logic are significant operational overhead. Only justified when dispute volume or gas costs create real pressure.

### 6.2 Deploy privacy infrastructure (only if needed)

**Trigger:** Transaction analysis reveals meaningful privacy leakage that harms users.

| Contract | Lines | Purpose |
|----------|-------|---------|
| `BatchQueue.sol` | 674 | Transaction batching |
| `DummyTransactionGenerator.sol` | 673 | Pattern obfuscation |

Do not deploy these speculatively. Privacy batching and dummy transactions are meaningless without sufficient real transaction volume to blend into.

### 6.3 Deploy observability infrastructure (only if needed)

**Trigger:** Deployed contracts are processing real disputes and generating data.

| Component | Purpose |
|-----------|---------|
| `subgraph/` | TheGraph indexing for dispute tracking |
| `monitoring/alerts/` | PagerDuty/Slack alerting |
| `monitoring/dune/` | Dune Analytics dashboards |

Deploy subgraph first (most useful for frontends). Monitoring and alerts follow when operational maturity demands it.

### 6.4 Evaluate Agent-OS integration

Decide whether `sdk/security/boundary-siem.ts` and `sdk/security/boundary-daemon.ts` belong in this repo or should live in the Agent-OS ecosystem. If ILRM is a standalone product, decouple. If it's always part of Agent-OS, keep but document the dependency.

### Exit Criteria
- [ ] L3 bridge deployed only when throughput demands it
- [ ] Privacy infrastructure deployed only when analysis shows need
- [ ] Subgraph live and serving frontend queries
- [ ] Monitoring alerts firing for real incidents
- [ ] Agent-OS coupling decision documented

---

## Summary: What Ships When

| Phase | Contracts Deployed | Lines in Scope | Depends On |
|-------|-------------------|----------------|------------|
| **1** | ILRM (slim), Oracle, Treasury (slim), AssetRegistry | ~1,600 | Nothing |
| **2** | Same 4, deployed to Optimism Sepolia | ~1,600 | Phase 1 |
| **3** | + MultiPartyILRM (maybe), Treasury features restored | ~2,300 | Phase 2 data |
| **4** | + IdentityVerifier, FIDOVerifier, DIDRegistry, wrapper contracts | ~5,000 | Phase 2 |
| **5** | + GovernanceTimelock, ComplianceCouncil, ComplianceEscrow | ~7,000 | Phase 4 |
| **6** | + L3Bridge, BatchQueue, DummyTxGen, subgraph, monitoring | ~10,600 | Demand signal |

**Total current codebase:** 10,641 lines of Solidity across 16 contracts.
**Phase 1 target:** 1,600 lines across 4 contracts. That's an 85% reduction in attack surface for the first deployment.

---

## Risk Register

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Extracting modules from ILRM.sol introduces bugs | Medium | High | Comprehensive diff review, all existing tests must pass on slimmed contract |
| Simplifying Treasury removes needed protections | Low | Medium | Flat caps are strictly more conservative than tiered; can always restore |
| External audit finds critical issues in core | Medium | High | Budget time for fixes; 1,600 lines is fast to audit and fix |
| No users show up on testnet | High | High | This is the core product risk. Better to learn this with 4 contracts than 16 |
| Extracted modules don't compose cleanly | Medium | Medium | Design wrapper pattern carefully in Phase 0; prototype before committing |
| Mainnet deployment pressure before Phase 5 | Medium | High | Governance is non-negotiable before mainnet. Do not skip Phase 5 |

---

## Decision Log

Decisions to be made at each phase gate. Record outcomes here as the plan executes.

| Decision | Phase Gate | Options | Outcome |
|----------|-----------|---------|---------|
| Treasury complexity level | Phase 3 | Flat caps vs tiered vs dynamic | TBD |
| MultiPartyILRM timing | Phase 3 | Deploy now vs defer to Phase 4+ | TBD |
| Identity module architecture | Phase 4 | Wrapper contracts vs ILRM upgrade | TBD |
| Agent-OS coupling | Phase 6 | Keep in repo vs separate repo | TBD |
| L3 bridge deployment | Phase 6 | Deploy vs defer indefinitely | TBD |
| Privacy infra deployment | Phase 6 | Deploy vs defer indefinitely | TBD |
| Mainnet target network | Phase 5 | Optimism vs Arbitrum vs both | TBD |
