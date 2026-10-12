# NatLangChain ILRM Protocol Specification

**Version:** 1.5
**Last Updated:** January 2026
**Status:** Testnet Ready

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Implementation Status](#implementation-status)
3. [Core Contracts](#core-contracts)
4. [Unimplemented Features](#unimplemented-features)
5. [Implementation Plans](#implementation-plans)
6. [Trust Model & Execution Modes](#trust-model--execution-modes)
7. [Security Considerations](#security-considerations)
8. [Roadmap Alignment](#roadmap-alignment)
9. [Success Metrics](#success-metrics)
10. [LLM Prompt Template](#llm-prompt-template)
11. [State Transition Diagram](#state-transition-diagram)
12. [Future Modules](#future-modules)
13. [Appendix: Constants Reference](#appendix-constants-reference)

---

## Executive Summary

The IP & Licensing Reconciliation Module (ILRM) is a non-adjudicative coordination protocol for compressing, de-escalating, and economically resolving intellectual property and licensing disputes. This spec sheet documents the current implementation status, identifies features described in documentation but not yet implemented, and outlines implementation plans for each.

### Core Philosophy

> NatLangChain doesn't govern people — it governs the price of conflict.

---

## Implementation Status

### Legend
| Symbol | Meaning |
|--------|---------|
| ✅ | Fully Implemented |
| 🔶 | Partially Implemented |
| ❌ | Not Implemented |
| 🔧 | Requires Fixes |
| 🔮 | Future Module (separate implementation) |

---

### Core ILRM Features

| Feature | Status | Location | Notes |
|---------|--------|----------|-------|
| Breach Dispute Initiation | ✅ | `ILRM.sol:114-155` | Includes stake escrow, evidence hash, fallback license |
| Voluntary Request (Burn-only) | ✅ | `ILRM.sol:161-176` | Zero-cost ignore for counterparty |
| Stake Symmetry Window | ✅ | `ILRM.sol:182-194` | 72-hour window, symmetric stakes |
| LLM Proposal Submission | ✅ | `ILRM.sol:201-224` | Oracle-only, signature verification |
| Mutual Acceptance | ✅ | `ILRM.sol:227-249` | Both parties must accept |
| Counter-Proposals | ✅ | `ILRM.sol:255-290` | Max 3, exponential fees |
| Timeout Resolution | ✅ | `ILRM.sol:296-309` | 50% burn, symmetric return |
| Fallback License Application | ✅ | `ILRM.sol:421` | Via AssetRegistry |
| Cooldown Period | ✅ | `ILRM.sol:56, 152` | 30 days between same party disputes |
| Stake Escalation | ✅ | `ILRM.sol:366-377` | 1.5x for repeat disputes |
| Harassment Score Tracking | ✅ | `ILRM.sol:78, 486-490` | Manual update by owner |
| Pausable (Emergency) | ✅ | `ILRM.sol:513-523` | Owner can pause/unpause |
| ZK Identity Mode | ✅ | `ILRM.sol:540-716` | Optional privacy-preserving disputes |
| ZK Breach Dispute Initiation | ✅ | `ILRM.sol:562-624` | With identity hash registration |
| ZK Proof Acceptance | ✅ | `ILRM.sol:633-676` | Groth16 verification |

### Identity Verifier Contract

| Feature | Status | Location | Notes |
|---------|--------|----------|-------|
| Groth16 Proof Verification | ✅ | `IdentityVerifier.sol:115-140` | BN254 curve |
| Nonce Management | ✅ | `IdentityVerifier.sol:142-180` | Replay protection |
| Proof Replay Detection | ✅ | `IdentityVerifier.sol:175-178` | Hash-based tracking |
| Dispute-Bound Proofs | ✅ | `IdentityVerifier.sol:126-140` | Extended signals |

### Compliance Escrow Contract

| Feature | Status | Location | Notes |
|---------|--------|----------|-------|
| Escrow Creation | ✅ | `ComplianceEscrow.sol:116-160` | With holder registration |
| Share Commitment Submission | ✅ | `ComplianceEscrow.sol:165-178` | Proof of possession |
| Reveal Request Creation | ✅ | `ComplianceEscrow.sol:185-213` | With voting period |
| Threshold Voting | ✅ | `ComplianceEscrow.sol:218-256` | Approve/reject with quorum |
| Share Submission for Reveal | ✅ | `ComplianceEscrow.sol:261-290` | Encrypted to coordinator |
| Reveal Finalization | ✅ | `ComplianceEscrow.sol:295-320` | Records reconstruction |
| Request Expiration | ✅ | `ComplianceEscrow.sol:325-335` | Timeout handling |
| Viewing Key Commitment (ILRM) | ✅ | `ILRM.sol:759-777` | Dispute metadata privacy |

### FIDO Verifier Contract

| Feature | Status | Location | Notes |
|---------|--------|----------|-------|
| P-256 Signature Verification | ✅ | `FIDOVerifier.sol:195-220` | RIP-7212 precompile + fallback |
| Key Registration | ✅ | `FIDOVerifier.sol:106-130` | With curve validation |
| WebAuthn Assertion Verification | ✅ | `FIDOVerifier.sol:135-175` | Full WebAuthn parsing |
| Sign Count Validation | ✅ | `FIDOVerifier.sol:155-160` | Clone detection |
| Challenge Generation | ✅ | `FIDOVerifier.sol:180-192` | Replay protection |
| RP ID Binding | ✅ | `FIDOVerifier.sol:145-148` | Phishing resistance |
| FIDO Accept (ILRM) | ✅ | `ILRM.sol:918-977` | Hardware-backed acceptance |
| FIDO Counter-propose (ILRM) | ✅ | `ILRM.sol:987-1030` | Hardware-backed counters |

### Multi-Party ILRM Contract

| Feature | Status | Location | Notes |
|---------|--------|----------|-------|
| Multi-Party Dispute Creation | ✅ | `MultiPartyILRM.sol:98-185` | 2-255 parties |
| Late Join Support | ✅ | `MultiPartyILRM.sol:190-215` | Optional per dispute |
| Per-Party Stake Tracking | ✅ | `MultiPartyILRM.sol:220-245` | Symmetric stakes |
| Evidence Aggregation | ✅ | `MultiPartyILRM.sol:250-270` | Hash aggregation |
| Quorum-Based Acceptance | ✅ | `MultiPartyILRM.sol:305-340` | 4 quorum types |
| Rejection with Impossibility | ✅ | `MultiPartyILRM.sol:345-365` | Detects failed quorum |
| Multi-Party Timeout | ✅ | `MultiPartyILRM.sol:420-445` | Proportional burns |
| Configurable Quorum | ✅ | `MultiPartyILRM.sol:450-470` | Unanimous/Super/Simple/Custom |

### Batch Queue Contract

| Feature | Status | Location | Notes |
|---------|--------|----------|-------|
| Transaction Queuing | ✅ | `BatchQueue.sol:115-175` | Multiple tx types |
| Batch Release Logic | ✅ | `BatchQueue.sol:195-275` | Time + count based |
| Batch Execution | ✅ | `BatchQueue.sol:280-320` | On target contract |
| Order Randomization | ✅ | `BatchQueue.sol:385-395` | Fisher-Yates shuffle |
| Chainlink Automation | ✅ | `BatchQueue.sol:325-345` | checkUpkeep/performUpkeep |
| Token/ETH Escrow | ✅ | `BatchQueue.sol:350-375` | During queue period |
| Cancellation Support | ✅ | `BatchQueue.sol:180-195` | Configurable |
| Expiration Handling | ✅ | `BatchQueue.sol:245-250` | Auto-refund |

### Dummy Transaction Generator

| Feature | Status | Location | Notes |
|---------|--------|----------|-------|
| Probability-Based Generation | ✅ | `DummyTransactionGenerator.sol:95-140` | Configurable BPS threshold |
| Multiple Dummy Tx Types | ✅ | `DummyTransactionGenerator.sol:285-340` | Voluntary, BatchQueue, ViewingKey |
| Dummy Address Registry | ✅ | `DummyTransactionGenerator.sol:175-220` | Excluded from analytics |
| Treasury Funding | ✅ | `DummyTransactionGenerator.sol:225-260` | Per-period spending limits |
| Chainlink Automation | ✅ | `DummyTransactionGenerator.sol:145-165` | checkUpkeep/performUpkeep |
| Random Interval Logic | ✅ | `DummyTransactionGenerator.sol:345-375` | VRF-compatible with fallback |
| Period-Based Limits | ✅ | `DummyTransactionGenerator.sol:380-400` | Max txs and spend per period |

### Compliance Council Contract

| Feature | Status | Location | Notes |
|---------|--------|----------|-------|
| Council Member Management | ✅ | `ComplianceCouncil.addMember` / `removeMember` / `rotateMemberKey` | BLS G1 key shares at distinct key indices in [1, r); keys unique and kept apart from the group key; removal or rotation voids the member's partial signatures, removal also its votes |
| Member Role Types | ✅ | `IComplianceCouncil.MemberRole` | 5 roles: User, DAO, Auditor, Legal, Regulator |
| Warrant Request Submission | ✅ | `ComplianceCouncil.submitWarrantRequest` | With document hash and jurisdiction |
| Threshold Voting | ✅ | `ComplianceCouncil.castVote` / `concludeVoting` | m-of-n approval/rejection by active members; only votes of members still in the membership they voted in count (a removed member's vote no longer counts; key rotation keeps it) |
| Appeal Mechanism | ✅ | `ComplianceCouncil.fileAppeal` | Before execution delay expires |
| BLS Signature Submission | ✅ | `ComplianceCouncil.submitSignature` | Per-member partial signatures, verified on chain against the member's G1 key share; one per key registration |
| Current Partials | ✅ | `ComplianceCouncil.getCurrentSignatures`, SDK `selectCurrentSubmissions` | Only partials whose signer still holds the key they were made under count; `getSignatures` also lists stale ones |
| Signature Aggregation | ✅ | `ComplianceCouncil.aggregateSignatures` | Plain G2 sum (G2MSM) of validated elements; an infinity sum is rejected. Threshold (Lagrange) aggregation: on chain in `executeReconstruction`, off chain in the SDK (`aggregateWarrantSignature`) |
| Threshold Verification | ✅ | `ComplianceCouncil.verifyThresholdSignature` | Aggregate checked against the admin-set DKG group key; signer indices validated; informational |
| Key Reconstruction | ✅ | `ComplianceCouncil.executeReconstruction` | Needs threshold current partials. STRICT_ONCHAIN Lagrange-interpolates them at zero on chain (`BLS12381.interpolateG2AtZero`) into the group signature f(0)·H(m) and verifies it against the group key; HYBRID_ATTESTED takes the operator's attestation of the same value. Records `decryptedKeyHash` = keccak256 of the 256-byte EIP-2537 encoding of that group signature (SDK `computeDecryptedKeyHash`), which BLS uniqueness makes independent of the signing subset; the partials are public, so it is a public commitment, not a secret |
| BLS12-381 Precompiles | ✅ | `libraries/BLS12381.sol` | Final EIP-2537 addresses, RFC 9380 hash-to-G2, known-answer detection, fails closed without them |
| **Execution Modes** | ✅ | `ComplianceCouncil.ExecutionMode` | DISABLED, STRICT_ONCHAIN, HYBRID_ATTESTED |
| **Mode Governance** | ✅ | `ComplianceCouncil.setExecutionMode` / `governanceOverrideMode` | Admin-controlled (or governance timelock override) with reason logging |
| **Hybrid Attestation** | ✅ | `ComplianceCouncil.attestHybridVerification` | Operator attests the off-chain verified decryptedKeyHash (SDK `aggregateWarrantSignature`) |
| Pausable Operations | ✅ | `ComplianceCouncil.pause` / `unpause` | Emergency pause support |

### Treasury Contract

See [Treasury.md](./Treasury.md) for the full escrow flow, funds map and owner trust model.

| Feature | Status | Location | Notes |
|---------|--------|----------|-------|
| Token and ETH deposits | ✅ | `Treasury.deposit`, `Treasury.receive` | `depositBurn` is ILRM-only and never called: ILRM burns to `0x…dEaD` |
| Escrowed defensive co-stake | ✅ | `ILRM.depositStakeWithSubsidy` -> `Treasury.fundStakeSubsidy` | Counterparty-only, inside the stake window; the subsidy is pulled into ILRM escrow, never paid to a wallet |
| Top-up slippage bound | ✅ | `ILRM.depositStakeWithSubsidy(disputeId, maxSubsidy, maxTopUp)` | Reverts `"Top-up exceeds max"` before and after the Treasury call; a front-run can force a revert, never an overcharge |
| Single subsidy per (ILRM, dispute) | ✅ | `Treasury.subsidyRecipientOf` | Keyed by ILRM so a redeployed ILRM's dispute IDs do not collide; `disputeSubsidized` / `disputeSubsidyRecipient` refer to the wired ILRM |
| Pro-rata repayment | ✅ | `ILRM._payCounterpartySide` | Full subsidy back on mutual acceptance; funder bears its share of the burn on timeout |
| Per-Dispute Caps | ✅ | `Treasury.fundStakeSubsidy` (`maxPerDispute`) | Owner-set via `updateCaps`; grant also capped at the dispute's stake |
| Per-Participant Rolling Caps | ✅ | `Treasury.fundStakeSubsidy` (`maxPerParticipant`, `windowDuration`) | Charged gross, not restored on repayment |
| Reserve floor | ✅ | `Treasury.fundStakeSubsidy` (`minReserve`) | Owner-set via `setMinReserve` |
| Harassment Score Checks | ✅ | `Treasury.fundStakeSubsidy` (`HARASSMENT_THRESHOLD`) | Threshold: 50; scores are owner-set (`setHarassmentScore`) |
| Capped initiator incentive | ✅ | `ILRM._takeInitiatorIncentive`, `ILRM.setInitiatorIncentiveCaps` | Paid from `ILRM.tokenReserves`, see below |
| Dynamic Caps | ❌ | - | Removed in Phase 1 (proposal: Plan 6) |
| Tiered Subsidies | ❌ | - | Removed in Phase 1 (proposal: Plan 7) |
| DID-based subsidies | ❌ | - | Removed in Phase 1 |
| Harassment score decay | ❌ | - | Removed in Phase 1 |
| Multi-Token Support | ❌ | - | Currently single ERC20 |

#### Initiator incentive (ILRM token reserves)

| Parameter | Default | Bounds | Notes |
|-----------|---------|--------|-------|
| Rate (`INITIATOR_INCENTIVE_BPS`) | 10% of the initiator stake | constant | Upper bound, paid only on non-participation |
| `maxIncentivePerDispute` | `1e18` | `<= maxIncentivePerWindow` | Cap on a single payout |
| `maxIncentivePerWindow` | `10e18` | none (owner trust) | Global cap across all disputes per window |
| `incentiveWindow` | 30 days | 1-365 days | Fixed window, rolled lazily by the first payout after expiry |

Each payout is `min(10% of stake, maxIncentivePerDispute, maxIncentivePerWindow - incentivePaidInWindow, tokenReserves)`;
the initiator always gets its full stake back, and the payout never reverts. The owner sets the caps with
`setInitiatorIncentiveCaps` (zero caps are the kill switch, usable while paused). `previewInitiatorIncentive`
quotes a payout and `InitiatorIncentivePaid` reports every one (`amount < uncappedAmount` means a cap bound it).

**Residual risk (accepted):** the counterparty can be a sybil that never stakes, so farming up to the window cap
remains possible: at most `maxIncentivePerWindow` per window, `W * (ceil(t / T) + 1)` over any interval `t`
(`2W` across a window boundary), and never more than the deposited reserves. A per-initiator cap is not used
because sybil initiator addresses are free. `tokenReserves` deposits are irrevocable and leave ILRM only as
capped incentives.

### Governance Timelock Contract

| Feature | Status | Location | Notes |
|---------|--------|----------|-------|
| TimelockController Extension | ✅ | `GovernanceTimelock.sol:35-45` | Extends OpenZeppelin |
| Multi-Sig Proposer | ✅ | `GovernanceTimelock.sol:65-75` | PROPOSER_ROLE for multi-sig |
| Configurable Delays | ✅ | `GovernanceTimelock.sol:80-95` | min, emergency, long delays |
| Operation Scheduling | ✅ | `GovernanceTimelock.sol:100-175` | Single and batch operations |
| Long Delay Scheduling | ✅ | `GovernanceTimelock.sol:180-210` | For critical changes |
| Emergency Actions | ✅ | `GovernanceTimelock.sol:220-280` | Reduced delay bypass |
| Emergency Pause All | ✅ | `GovernanceTimelock.sol:285-330` | Pause all protocol contracts |
| Protocol Contract Registry | ✅ | `GovernanceTimelock.sol:340-400` | Register/manage contracts |
| Ownership Transfer Support | ✅ | `GovernanceTimelock.sol:405-420` | Ownable2Step compatible |
| Operation Cancellation | ✅ | `GovernanceTimelock.sol:190-200` | CANCELLER_ROLE |

### Oracle Contract

| Feature | Status | Location | Notes |
|---------|--------|----------|-------|
| EIP-712 Signature Verification | ✅ | `Oracle.sol:192-212` | Required for all proposals |
| Chain Fork Detection | ✅ | `Oracle.sol:109-123` | Dynamic DOMAIN_SEPARATOR |
| Nonce Management | ✅ | `Oracle.sol:49` | Prevents replay attacks |
| Oracle Registration | ✅ | `Oracle.sol:290-298` | Owner-controlled |
| Multi-Oracle Support | ✅ | `Oracle.sol:43-44` | Multiple operators |

### Asset Registry

| Feature | Status | Location | Notes |
|---------|--------|----------|-------|
| Asset Registration | ✅ | `AssetRegistry.sol:92-121` | Owner-only registration |
| Asset Transfer | ✅ | `AssetRegistry.sol:128-154` | With freeze protection |
| License Grant/Revoke | ✅ | `AssetRegistry.sol:161-216` | Time-limited, royalty-based |
| Dispute Asset Freezing | ✅ | `AssetRegistry.sol:223-243` | ILRM-authorized |
| Dispute Asset Unfreezing | ✅ | `AssetRegistry.sol:248-269` | With outcome data |
| Fallback License Application | ✅ | `AssetRegistry.sol:274-290` | Updates license terms |
| Max Assets Per Owner | ✅ | `AssetRegistry.sol:23` | 100 limit (DoS prevention) |

### DID Registry Contract

| Feature | Status | Location | Notes |
|---------|--------|----------|-------|
| DID Registration | ✅ | `DIDRegistry.sol:95-115` | One DID per address |
| DID Document Management | ✅ | `DIDRegistry.sol:120-145` | ERC-725 compatible |
| Controller Transfer | ✅ | `DIDRegistry.sol:150-165` | Ownership transfer |
| DID Status Management | ✅ | `DIDRegistry.sol:170-200` | Active/Suspended/Revoked |
| Delegate Management | ✅ | `DIDRegistry.sol:210-260` | Max 10 delegates |
| Credential Issuance | ✅ | `DIDRegistry.sol:270-320` | With weight and expiry |
| Credential Revocation | ✅ | `DIDRegistry.sol:325-350` | By issuer or controller |
| Credential Verification | ✅ | `DIDRegistry.sol:355-370` | Checks expiry and revocation |
| Sybil Score Calculation | ✅ | `DIDRegistry.sol:380-420` | Based on credentials and trust |
| Trusted Issuer Framework | ✅ | `DIDRegistry.sol:430-480` | With trust levels and types |
| ILRM Integration | ✅ | `ILRM.sol:1089-1264` | DID-verified disputes |
| Treasury Integration | ❌ | - | DID-based subsidies not implemented (removed from Treasury.sol in Phase 1) |

### L3 Bridge Contracts

> ⚠️ **NOT PRODUCTION-READY - MUST NOT BE DEPLOYED.** "✅" below means the code exists and is tested, not that it
> is safe: the L3 contracts have known-unsound security (see [4.3](#43-l3app-specific-rollups-natlangchain-roadmapmd)).
> No deploy script deploys them.

| Feature | Status | Location | Notes |
|---------|--------|----------|-------|
| Dispute Bridging (L2→L3) | ✅ | `L3Bridge.sol:276-340` | ILRM or owner-authorized bridger; not validated against the ILRM |
| Settlement Processing (L3→L2) | ✅ | `L3Bridge.sol:345-454` | Sequencer-signed; `stateProof == 0` not tied to any root |
| Batch Settlements | ✅ | `L3Bridge.sol:364-388` | Up to 100 per batch; invalid items skipped (`SettlementSkipped`) |
| State Commitment | ✅ | `L3Bridge.sol:461-520` | With challenge period; no sequencer bond |
| State Finalization | ✅ | `L3Bridge.sol:526-566` | After 7-day period |
| Fraud Proof System | ⚠️ | `L3Bridge.sol:596-904` | Bonds/escrow sound; the proof itself checks no state transition |
| Merkle Proof Verification | ✅ | `L3StateVerifier.sol:95-200` | Sparse tree support |
| Batch Verification | ✅ | `L3StateVerifier.sol:149-182` | Gas-efficient |
| Dispute Queue | ✅ | `L3DisputeBatcher.sol:171-244` | Auto-trigger with failure backoff |
| Settlement Queue | ✅ | `L3DisputeBatcher.sol:253-363` | Sequencer-queued, submitter-relayed |

### Protocol Safety Invariants

| Invariant | Status | Implementation |
|-----------|--------|----------------|
| 1. No Unilateral Cost Imposition | ✅ | Initiator stakes first |
| 2. Silence Is Always Free | ✅ | Voluntary requests ignorable |
| 3. Initiator Risk Precedence | ✅ | Initiator exposed before counterparty |
| 4. Bounded Griefing | ✅ | Max 3 counters, exponential fees |
| 5. Harassment Is Net-Negative | ✅ | Escalating stakes, cooldowns |
| 6. Mutuality or Exit | ✅ | Timeout guarantees resolution |
| 7. Outcome Neutrality | ✅ | No winners/losers declared |
| 8. Economic Symmetry | ✅ | Matched stakes, identical timers |
| 9. Predictable Cost Surfaces | ✅ | All fees/burns explicit |
| 10. Protocol Non-Sovereignty | ✅ | No legal authority claims |

---

## Core Contracts

### Deployed Contract Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        NatLangChain Protocol                     │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────────┐  │
│  │    ILRM      │◄───│   Oracle     │    │   Treasury       │  │
│  │  (Core)      │    │  (LLM Bridge)│    │   (Subsidies)    │  │
│  └──────┬───────┘    └──────────────┘    └──────────────────┘  │
│         │                                                        │
│         ▼                                                        │
│  ┌──────────────────┐                                           │
│  │  AssetRegistry   │                                           │
│  │  (IP Management) │                                           │
│  └──────────────────┘                                           │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Contract Addresses (Testnet)

| Contract | Address | Network |
|----------|---------|---------|
| ILRM | TBD | Optimism Sepolia |
| Treasury | TBD | Optimism Sepolia |
| Oracle | TBD | Optimism Sepolia |
| AssetRegistry | TBD | Optimism Sepolia |

---

## Unimplemented Features

The following features are documented in the project documentation but not yet implemented in the smart contracts or supporting infrastructure.

### Category 1: Privacy & Identity (High Priority)

#### 1.1 ZK Proof of Identity (dispute-membership-circuit.md)
**Status:** ✅ IMPLEMENTED
**Source:** `dispute-membership-circuit.md:1-34`

**Description:** Circom circuit using Poseidon hashing to prove identity without revealing addresses. Users can prove they are a party to a dispute without exposing their wallet address on-chain.

**Implementation:**
- Circuit: `circuits/prove_identity.circom`
- Verifier: `contracts/IdentityVerifier.sol`
- Interface: `contracts/interfaces/IIdentityVerifier.sol`
- SDK: `sdk/identity-proof.ts`
- ILRM Integration: `ILRM.sol:540-716`

**Features Implemented:**
- Circom 2.1.6 circuit with Poseidon(1) hash
- Private input: `identitySecret` (user's salt + address)
- Public input: `identityManager` (on-chain hash from Dispute struct)
- Groth16 proof verification on-chain (~200k gas)
- Nonce-based replay protection
- TypeScript SDK for proof generation

#### 1.2 Viewing Key Infrastructure (dispute-membership-circuit.md)
**Status:** ✅ IMPLEMENTED
**Source:** `dispute-membership-circuit.md:35-68`

**Description:** ECIES encryption + Shamir's Secret Sharing for selective de-anonymization. Allows compliance reveals while maintaining default privacy.

**Implementation:**
- Contract: `contracts/ComplianceEscrow.sol`
- Interface: `contracts/interfaces/IComplianceEscrow.sol`
- SDK: `sdk/viewing-keys.ts`, `sdk/shamir.ts`, `sdk/ecies.ts`
- ILRM Integration: `ILRM.sol:728-858`

**Features Implemented:**
- ComplianceEscrow contract with m-of-n threshold voting
- Shamir's Secret Sharing library (GF(2^8) with full test coverage)
- ECIES encryption on secp256k1 (Ethereum-compatible)
- Reveal request management with voting and expiration
- Share submission and reconstruction flow
- ILRM integration for viewing key commitments

#### 1.3 Batch Transaction Queue (dispute-membership-circuit.md)
**Status:** ✅ IMPLEMENTED
**Source:** `dispute-membership-circuit.md:71-75`

**Description:** Buffer submissions and release in batches to prevent timing-based inference attacks.

**Implementation:**
- Contract: `contracts/BatchQueue.sol`
- Interface: `contracts/interfaces/IBatchQueue.sol`

**Features Implemented:**
- Configurable batch size (min/max) and release intervals
- Transaction queuing for disputes, stakes, acceptances, ZK proofs
- Chainlink Automation compatible (checkUpkeep/performUpkeep)
- Optional order randomization within batches
- Token and ETH escrow during queue
- Cancellation support (configurable)
- Commitment hashes for verification
- Expiration handling for stale transactions

#### 1.4 Dummy Transactions (dispute-membership-circuit.md)
**Status:** ✅ IMPLEMENTED
**Source:** `dispute-membership-circuit.md:76-79`

**Description:** Treasury-funded automated "noop" calls at random intervals to obscure real transaction patterns.

**Implementation:**
- Contract: `contracts/DummyTransactionGenerator.sol`
- Interface: `contracts/interfaces/IDummyTransactionGenerator.sol`

**Features Implemented:**
- Configurable probability-based generation (basis points threshold)
- Multiple dummy tx types: VoluntaryRequest, BatchQueueEntry, ViewingKeyCommit
- Dedicated dummy address registry (excluded from analytics)
- Treasury-funded with per-period spending limits
- Chainlink Automation compatible (checkUpkeep/performUpkeep)
- VRF-compatible randomness (with pseudo-random fallback)
- Configurable min/max intervals and per-period limits
- Batch generation for low-activity periods

#### 1.5 Threshold Decryption for Compliance (dispute-membership-circuit.md)
**Status:** ✅ IMPLEMENTED
**Source:** `dispute-membership-circuit.md:83-88`

**Description:** BLS/FROST threshold signatures for decentralized compliance council. Legal warrants require m-of-n signatures to reveal data.

**Implementation:**
- Contract: `contracts/ComplianceCouncil.sol`
- Interface: `contracts/interfaces/IComplianceCouncil.sol`
- SDK: `sdk/threshold-bls.ts`

**Features Implemented:**
- Council member management with 5 role types (User, DAO, Auditor, Legal, Regulator)
- BLS12-381 threshold signatures with m-of-n requirement
- Warrant request and voting system with governance
- Signature aggregation for key reconstruction
- Appeal window and execution delay
- Time-limited signature collection
- BLS precompile support (EIP-2537) with fallback
- Full TypeScript SDK for distributed key generation and signing

### Category 2: Hardware Security (High Priority)

#### 2.1 FIDO2/YubiKey Integration (FIDO-Yubi.md)
**Status:** ✅ IMPLEMENTED
**Source:** `FIDO-Yubi.md:1-31`

**Description:** Hardware-backed authentication for signing acceptances, proposals, and proofs. Enhances anti-harassment through hardware identity binding.

**Implementation:**
- Contract: `contracts/FIDOVerifier.sol` (WebAuthn/P-256 verification)
- Interface: `contracts/interfaces/IFIDOVerifier.sol`
- SDK: `sdk/fido2.ts` (browser WebAuthn integration)
- ILRM Integration: `ILRM.sol:870-1062`

**Features Implemented:**
- P-256 signature verification (RIP-7212 precompile + pure Solidity fallback)
- WebAuthn credential registration and management
- `fidoAcceptProposal()` for hardware-backed acceptance
- `fidoCounterPropose()` for hardware-backed counter-proposals
- User opt-in FIDO requirement via `setFIDORequired()`
- Challenge generation with replay protection
- Sign count validation (cloned authenticator detection)

### Category 3: Analytics & Prediction (Medium Priority)

#### 3.1 License Entropy Oracle (Updated-Mechanics.md, NatLangChain-Roadmap.md)
**Status:** 🔮 Future Module
**Source:** `Updated-Mechanics.md:119-144`, `NatLangChain-Roadmap.md:107-113`

**Description:** Scores contract clauses (0-100) based on historical dispute rates, timeouts, and burns. Predicts likelihood of future disputes.

**Note:** This feature will be implemented as a separate analytics module that can be plugged into the ILRM protocol. The module will include:
- On-chain scoring contract
- Off-chain analytics pipeline
- The Graph subgraph for dispute data indexing
- ML-based entropy calculation

#### 3.2 Clause-Pattern Clustering (NatLangChain-Roadmap.md)
**Status:** 🔮 Future Module
**Source:** `NatLangChain-Roadmap.md:121`

**Description:** ML-based analysis of which contract clause patterns cause disputes. Off-chain analysis with on-chain score exposure.

**Note:** Part of the License Entropy Oracle module.

#### 3.3 Automated Clause Hardening (NatLangChain-Roadmap.md)
**Status:** 🔮 Future Module
**Source:** `NatLangChain-Roadmap.md:157`

**Description:** During negotiation, automatically suggest improvements to high-entropy clauses based on historical data.

**Note:** Part of the License Entropy Oracle module. Requires entropy scoring to be operational.

#### 3.4 Predictive Warnings (NatLangChain-Roadmap.md)
**Status:** 🔮 Future Module
**Source:** `NatLangChain-Roadmap.md:158`

**Description:** Real-time warnings during contract drafting for terms predicted to cause disputes.

**Note:** Part of the License Entropy Oracle module. Requires clause-pattern clustering to be operational.

### Category 4: Multi-Party & Scaling (Medium Priority)

#### 4.1 Multi-Party Reconciliation (NatLangChain-Roadmap.md)
**Status:** ✅ IMPLEMENTED
**Source:** `NatLangChain-Roadmap.md:117`

**Description:** Extend ILRM to handle disputes with more than 2 parties. Requires modified acceptance logic (multisig-style quorum).

**Implementation:**
- Contract: `contracts/MultiPartyILRM.sol`
- Interface: `contracts/interfaces/IMultiPartyILRM.sol`

**Features Implemented:**
- Support for 2-255 parties per dispute
- Configurable quorum types: Unanimous, SuperMajority (2/3), SimpleMajority (51%), Custom
- Per-party stake tracking with symmetric stakes
- Per-party evidence submission and aggregation
- Late-join support (optional per dispute)
- Proportional stake burns on timeout
- Quorum-based acceptance with real-time tracking

#### 4.2 Decentralized Identity (DID) Integration (NatLangChain-Roadmap.md)
**Status:** ✅ IMPLEMENTED
**Source:** `NatLangChain-Roadmap.md:105`

**Description:** Sybil-resistant participation via DID standards. ERC-725 compatible identity management with Verifiable Credentials support.

**Implementation:**
- Contract: `contracts/DIDRegistry.sol`
- Interface: `contracts/interfaces/IDIDRegistry.sol`
- ILRM Integration: `contracts/ILRM.sol:1089-1264`
- Treasury Integration: not implemented (DID-based subsidies were removed from Treasury.sol in Phase 1)

**Features Implemented:**
- DID Format: `did:nlc:<chain-id>:<address>` (ERC-725 compatible)
- One DID per address with controller management
- Delegate support for key rotation (max 10 delegates per DID)
- Verifiable Credentials with trusted issuer framework
- Sybil score calculation based on credential weights and issuer trust levels
- 6 attestation types: Identity, KYC, Reputation, Governance, Professional, Custom
- 5 member role types for issuers: User, DAO, Auditor, Legal, Regulator
- DID-verified dispute initiation (`initiateBreachDisputeWithDID`)
- DID-verified stake deposit (`depositStakeWithDID`)
- ~~DID-based subsidy eligibility with bonus multipliers in Treasury~~ (not implemented: removed in Phase 1)
- Configurable minimum sybil score requirements

#### 4.3 L3/App-Specific Rollups (NatLangChain-Roadmap.md)
**Status:** ⚠️ PROTOTYPE - **NOT PRODUCTION-READY, MUST NOT BE DEPLOYED**
**Source:** `NatLangChain-Roadmap.md:162`

> ⚠️ **The L3 contracts (L3Bridge, L3DisputeBatcher, L3StateVerifier) are not production-ready and must not be
> deployed.** Their optimistic-rollup security rests on parts that do not exist yet. These gaps are known and are
> deliberately not patched, because closing them needs a real fraud-proof system:
> 1. **Fraud proofs prove nothing.** `_verifyFraudProof` only checks a Merkle path from
>    `keccak256(invalidStateData)` to `claimedRoot` (and `claimedRoot != correctRoot`, a value the challenger
>    picks); it never checks a state transition. Anyone who knows a preimage of any node of an *honest* root (a
>    leaf and its siblings, or just the root's two children) can reject it, roll the chain back and collect the
>    reward, so every root can be censored by anyone with a refundable bond.
> 2. **No sequencer bond.** A sequencer that commits a fraudulent root loses nothing.
> 3. **Settlements are not tied to finalized state.** A settlement with `stateProof == bytes32(0)` is accepted
>    on the word of the sequencer or any settlement relayer; a nonzero `stateProof` is only checked to be a
>    finalized root, never that the settlement is included in it.
> 4. **Bridged disputes are not validated against the ILRM.** The ILRM or any dispute bridger can bridge
>    arbitrary messages (IDs, parties, stakes).
>
> The ILRM neither bridges disputes nor consumes settlements, so L3 settlements move no stake. No deploy
> script (`scripts/deploy.js`, `scripts/deploy-governance.ts`) deploys the L3 contracts. `test/L3KnownLimitations.t.sol`
> pins gaps 1-4 as executable evidence.

**Description:** High-throughput dispute handling via dedicated L3 rollup with optimistic state commitments and fraud proofs.

**Implementation:**
- Bridge Interface: `contracts/interfaces/IL3Bridge.sol`
- Bridge Contract: `contracts/scaling/L3Bridge.sol`
- State Verifier: `contracts/scaling/L3StateVerifier.sol`
- Dispute Batcher: `contracts/scaling/L3DisputeBatcher.sol`

**Architecture:**
```
L2 (Arbitrum/Optimism)          L3 (App-Specific Rollup)
┌─────────────────┐             ┌─────────────────┐
│      ILRM       │             │    L3 ILRM      │
│  (Stakes, NFTs) │             │  (High Speed)   │
└────────┬────────┘             └────────▲────────┘
         │                               │
         ▼                               │
┌─────────────────┐             ┌────────┴────────┐
│    L3Bridge     │◄───────────►│   L3 Sequencer  │
│ (State Commits) │             │   (Batching)    │
└─────────────────┘             └─────────────────┘
```

**Features Implemented:**
- Dispute bridging from L2 to L3 (`bridgeDisputeToL3`)
- State commitment with sequencer signatures
- 7-day challenge period (configurable)
- Merkle proof verification for dispute states
- Fraud proof system with challenger bonds
- Batch settlement processing (up to 100 per batch)
- L3DisputeBatcher for queue management with auto-trigger
- Sparse Merkle tree support for efficient updates

**Security Model (intended; see the warning above for what is missing):**
- Optimistic rollup: State assumed valid unless challenged
- Challenger bond: 0.1 ETH minimum to prevent spam
- Fraud reward: fixed 0.05 ETH (50% of the minimum bond) for valid challenges, paid only from free balance
- State chain integrity: Each commitment links to previous root

**Fraud-proof lifecycle:** A challenger commits `computeFraudProofCommitHash(challenger, proof, salt)` (domain-separated and bound to the challenger, chain, bridge and full proof) with a bond against a state root. Any number of commitments may be open per root, so no challenger can block another. The reveal (2 minutes to 62 minutes after the commit) only acts on the root the bond was posted against, and every bond ends in one of three ways: **Won** (valid proof on a canonical, unchallenged root: bond + reward), **Refunded** (valid proof, but the root was already rejected or orphaned: bond only) or **Forfeited** (invalid or mismatched proof, or never revealed, via the permissionless `forfeitExpiredCommitment`). Pending bonds are escrowed and never fund rewards or `withdrawFees`. Each root's challenge deadline is snapshotted at submission, and commits close once a reveal window opened now could still be open at that deadline, so no challenge can be pending when a root becomes finalizable. Roots finalize strictly in chain order; a successful challenge on any canonical root rolls the committed head back to its parent, so that root and all its descendants can never finalize and the sequencer rebuilds from the parent. `pause()` freezes only finalization: commits, reveals, forfeits and legacy submissions are never paused, and bridging and settlements are gated by the bridge status. Disputes are bridged by the ILRM or an owner-authorized dispute bridger (`setDisputeBridger`, e.g. the L3DisputeBatcher), and settlement batches by the sequencer or an owner-authorized settlement relayer (`setSettlementRelayer`).

**Settlement batches:** `processSettlementFromL3` reverts on an invalid settlement (`DisputeNotBridged`, `InvalidSettlement` for an L3 ID mismatch or a repeat, `InvalidStateRoot` for an unfinalized nonzero `stateProof`). `batchProcessSettlements` gives every item exactly those checks, in order and against the state left by the items before it, but skips a failing item with `SettlementSkipped(l2DisputeId, l3DisputeId, reason)` instead of reverting, and returns the number applied. One bad message (never bridged, already settled, duplicated within the batch, wrong L3 ID, unfinalized proof) therefore cannot block the others or get the L3DisputeBatcher settlement queue stuck. A skipped settlement leaves no trace and can be resubmitted once valid. Only batch-level checks (caller, bridge status, `BatchSizeExceeded`) revert the whole batch, in which case the batcher keeps its queue.

**Auto-batch backoff:** a failed auto-batch (bridge revert, missing role, inactive bridge, out of gas) never makes the queue call revert. It also backs the time trigger off (`AutoBatchDeferred`): no time-triggered attempt for 10 minutes, doubling per consecutive failure up to 1 day, so later queue calls do not each pay for a doomed retry. Manual submission is never backed off; any successful submission and `emergencyClearBatches` reset the backoff. The size trigger is not backed off, because only the queue call that fills the batch reaches it.

**Tested invariants** (`test/L3BridgeInvariants.t.sol`, stateful fuzzing): I1 the balance covers the escrowed bonds; I2 `sum(challengerBonds) == totalEscrowedBonds == sum(Pending bonds)`; I3 no reveal window is open at a root's deadline; I4 only canonical, unchallenged roots finalize, and the finalized roots are exactly the canonical prefix; I5 bond outcomes are final and each root is successfully challenged at most once; I6 the finalized head never passes the committed head, never moves back and both heads are canonical; I7 each dispute is bridged and settled at most once and `pendingSettlementsCount == totalBridgedDisputes - totalSettlements`.

### Category 5: Treasury Enhancements (Low Priority)

#### 5.1 Dynamic Subsidy Caps (Treasury.md)
**Status:** ❌ Not implemented (removed in Phase 1)
**Source:** `Treasury.md` (section 10)

**Description:** Scale `maxPerParticipant` based on current treasury balance to ensure sustainability.

**Proposal (not in the code):** see Plan 6 below.

#### 5.2 Tiered Subsidies (Treasury.md)
**Status:** ❌ Not implemented (removed in Phase 1)
**Source:** `Treasury.md` (section 10)

**Description:** Low harassment score → full subsidy; higher score → partial subsidy (graduated scale).

**Proposal (not in the code):** see Plan 7 below. Today the Treasury applies a single threshold
(`HARASSMENT_THRESHOLD` = 50) in `fundStakeSubsidy`.

#### 5.3 Multi-Token Support (Treasury.md)
**Status:** ❌ Not Implemented
**Source:** `Treasury.md` (section 10)

**Description:** Accept multiple staking tokens or native ETH for stakes and subsidies.

#### 5.4 Initiator Incentive Caps
**Status:** ✅ IMPLEMENTED

**Description:** The non-participation initiator incentive (10% of the stake from `ILRM.tokenReserves`) could be
farmed with sybil counterparties that never stake. It is now capped per dispute and across all disputes per
window, with the residual risk documented.

**Implementation:**
- `ILRM._quoteInitiatorIncentive` / `ILRM._takeInitiatorIncentive`: `min(10%, maxIncentivePerDispute, window remainder, tokenReserves)`; never reverts, the initiator always gets its full stake back
- `ILRM.setInitiatorIncentiveCaps(maxPerDispute, maxPerWindow, window)`: owner-only, window 1-365 days, per-dispute <= per-window, zero caps allowed (kill switch), emits `InitiatorIncentiveCapsUpdated`
- `ILRM.previewInitiatorIncentive(initiatorStake)` and the `InitiatorIncentivePaid` event
- Defaults: 1 token per dispute, 10 tokens per 30-day window (18 decimals)

#### 5.5 Subsidy Slippage Bound
**Status:** ✅ IMPLEMENTED

**Description:** The Treasury grant is only known on execution; a front-run (for example sybil subsidized stakes
draining the Treasury) could shrink it and overcharge the defender's allowance.

**Implementation:**
- `ILRM.depositStakeWithSubsidy(disputeId, maxSubsidy, maxTopUp)`: the caller's top-up (`initiatorStake - grant`) is checked against `maxTopUp` before the Treasury call (best case) and after it (actual grant), before any record or transfer
- Reverts `"Top-up exceeds max"`, atomically; `0` means a full subsidy or a revert, `type(uint256).max` means no bound

### Category 6: Governance & Security (Low Priority)

#### 6.1 Multi-Sig/Timelock Governance (SECURITY_AUDIT.md)
**Status:** ✅ IMPLEMENTED
**Source:** `SECURITY_AUDIT.md:299-315`

**Description:** Replace single owner with multi-sig and add timelock for admin operations.

**Implementation:**
- Contract: `contracts/GovernanceTimelock.sol`
- Interface: `contracts/interfaces/IGovernanceTimelock.sol`
- Deployment: `scripts/deploy-governance.ts`

**Features Implemented:**
- Extends OpenZeppelin TimelockController
- Multi-sig as proposer (PROPOSER_ROLE)
- Configurable delays: minDelay, emergencyDelay, longDelay
- Operation scheduling (single and batch)
- Emergency bypass with reduced delay
- Emergency pause/unpause all protocol contracts
- Protocol contract registry
- Ownable2Step compatible ownership transfer
- Operation cancellation support

#### 6.2 Ownable2Step Migration (SECURITY_AUDIT.md)
**Status:** ✅ IMPLEMENTED (via GovernanceTimelock)
**Source:** `SECURITY_AUDIT.md:473-475`

**Description:** Use OpenZeppelin's `Ownable2Step` for safer ownership transfers.

**Implementation:**
- GovernanceTimelock supports `acceptContractOwnership()` for Ownable2Step contracts
- Two-step ownership transfer: current owner initiates, timelock accepts

#### 6.3 Contract Upgradability (SECURITY_AUDIT.md)
**Status:** ❌ Not Implemented
**Source:** `SECURITY_AUDIT.md:481-484`

**Description:** Consider proxy pattern for future upgrades without state migration.

### Category 7: LLM & Explainability (Low Priority)

#### 7.1 Explainability Tooling (NatLangChain-Roadmap.md)
**Status:** ❌ Not Implemented
**Source:** `NatLangChain-Roadmap.md:119`

**Description:** Tooling to explain why LLM generated specific proposal terms. Off-chain with on-chain hash verification.

---

## Implementation Plans

### Plan 1: ZK Proof of Identity

**Priority:** High
**Status:** ✅ COMPLETED
**Dependencies:** Circom, snarkjs, trusted setup

#### Implemented Files:

| File | Description |
|------|-------------|
| `circuits/prove_identity.circom` | Circom circuit with Poseidon hash |
| `circuits/README.md` | Setup and compilation instructions |
| `contracts/IdentityVerifier.sol` | Groth16 verifier contract |
| `contracts/interfaces/IIdentityVerifier.sol` | Verifier interface |
| `sdk/identity-proof.ts` | TypeScript SDK for proof generation |

#### ILRM Integration (ILRM.sol):

| Function | Lines | Description |
|----------|-------|-------------|
| `setIdentityVerifier()` | 547-549 | Configure verifier contract |
| `initiateZKBreachDispute()` | 562-624 | Privacy-preserving dispute initiation |
| `acceptProposalWithZKProof()` | 633-676 | ZK-verified acceptance |
| `registerCounterpartyZKIdentity()` | 684-699 | Register counterparty identity |
| `getZKIdentity()` | 704-708 | Query identity hashes |
| `isZKModeEnabled()` | 714-716 | Check ZK mode status |

#### Extended Circuits:

The ZK identity system includes three circuit templates:

| Circuit | Purpose | Private Inputs | Public Inputs |
|---------|---------|----------------|---------------|
| `ProveIdentity` | Basic identity proof | `identitySecret` | `identityManager` |
| `ProveDisputeParty` | Role-bound identity | `identitySecret`, `role` | `identityManager`, `disputeId`, `expectedRole` |
| `ProveIdentityWithNonce` | Replay-protected actions | `identitySecret` | `identityManager`, `nonce`, `action` + outputs `actionCommitment` |

**ProveDisputeParty Features:**
- Binds proof to specific dispute ID (prevents cross-dispute proof reuse)
- Verifies role (0=initiator, 1=counterparty) matches expected
- Enables role-specific actions without address revelation

**ProveIdentityWithNonce Features:**
- Includes nonce for replay protection (incremented per use)
- Binds to specific action hash (e.g., "accept", "counter")
- Outputs action commitment for on-chain verification

#### Remaining Tasks:
- [ ] Conduct trusted setup ceremony for mainnet
- [ ] Professional security audit of circuit
- [ ] Gas optimization for verifier

---

### Plan 2: Viewing Key Infrastructure

**Priority:** High
**Status:** ✅ COMPLETED
**Dependencies:** ECIES library, Shamir library

#### Implemented Files:

| File | Description |
|------|-------------|
| `contracts/ComplianceEscrow.sol` | Threshold voting and share management |
| `contracts/interfaces/IComplianceEscrow.sol` | Contract interface with types |
| `sdk/shamir.ts` | Shamir's Secret Sharing in GF(2^8) |
| `sdk/ecies.ts` | ECIES encryption on secp256k1 |
| `sdk/viewing-keys.ts` | Complete viewing keys SDK |

#### ILRM Integration (ILRM.sol):

| Function | Lines | Description |
|----------|-------|-------------|
| `setComplianceEscrow()` | 748-750 | Configure escrow contract |
| `registerViewingKeyCommitment()` | 759-777 | Register commitment for dispute |
| `createDisputeEscrow()` | 790-831 | Create escrow with holders |
| `getViewingKeyCommitment()` | 838-840 | Query commitment |
| `getEncryptedDataHash()` | 847-849 | Query encrypted data location |
| `hasViewingKey()` | 856-858 | Check if viewing key exists |

#### ComplianceEscrow Features:

| Feature | Description |
|---------|-------------|
| Threshold Voting | m-of-n approval required for reveals |
| Share Management | Encrypted share submission and storage |
| Request Lifecycle | Pending → Approved/Rejected → Executed/Expired |
| Holder Types | User, DAO, Auditor, LegalCounsel, Regulator |
| Audit Trail | All actions emitted as events |

#### Remaining Tasks:
- [ ] Integration tests with full reveal flow
- [ ] IPFS/Arweave storage integration
- [ ] Frontend for share holders

---

### Plan 3: FIDO2/YubiKey Integration

**Priority:** High
**Status:** ✅ COMPLETED
**Dependencies:** WebAuthn standard, P-256 verification

#### Implemented Files:

| File | Description |
|------|-------------|
| `contracts/FIDOVerifier.sol` | P-256 WebAuthn verifier with RIP-7212 precompile support |
| `contracts/interfaces/IFIDOVerifier.sol` | Interface with structs and events |
| `sdk/fido2.ts` | Browser WebAuthn SDK for key registration and signing |

#### ILRM Integration (ILRM.sol):

| Function | Lines | Description |
|----------|-------|-------------|
| `setFIDOVerifier()` | 890-892 | Configure verifier contract |
| `setFIDORequired()` | 899-908 | User opt-in for mandatory FIDO |
| `fidoAcceptProposal()` | 918-977 | Hardware-backed proposal acceptance |
| `fidoCounterPropose()` | 987-1030 | Hardware-backed counter-proposal |
| `isFIDORequired()` | 1037-1038 | Check if FIDO is required for user |
| `generateFIDOChallenge()` | 1048-1061 | Generate challenge for WebAuthn signing |

#### FIDOVerifier Features:

| Feature | Description |
|---------|-------------|
| P-256 Verification | RIP-7212 precompile with pure Solidity fallback |
| Key Registration | On-chain storage of WebAuthn credentials |
| WebAuthn Parsing | Authenticator data and signature parsing |
| Sign Count | Cloned authenticator detection |
| Challenge Management | Time-limited, replay-protected challenges |
| Curve Validation | Ensure registered keys are on P-256 curve |

#### SDK Features:

| Feature | Description |
|---------|-------------|
| Key Registration | `registerKey()` for credential creation |
| Action Signing | `signAction()` for generic actions |
| Proposal Acceptance | `signAcceptProposal()` helper |
| Counter-proposal | `signCounterProposal()` helper |
| Contract Integration | `formatForContract()` helper |

#### Remaining Tasks:
- [ ] Integration tests with hardware keys
- [ ] Frontend UI for key management
- [ ] Oracle FIDO signing support

---

### Plan 4: License Entropy Oracle

**Priority:** Medium
**Status:** 🔮 FUTURE MODULE
**Dependencies:** Historical dispute data, Chainlink, The Graph

**Note:** The License Entropy Oracle will be developed as a separate pluggable analytics module. This module is not part of the core ILRM implementation.

#### Module Scope:

| Component | Description |
|-----------|-------------|
| LicenseEntropyOracle.sol | On-chain scoring contract |
| Subgraph | The Graph indexer for dispute events |
| Analytics Pipeline | Off-chain ML-based scoring |
| Integration API | Query interface for NatLangChain |

#### Features Planned:

- Clause entropy scoring (0-100)
- Historical dispute rate analysis
- Clause-pattern clustering (ML)
- Automated clause hardening suggestions
- Predictive warnings during drafting

#### Integration Points (Future):

When implemented, the module will integrate with ILRM via:
- `ClauseUsed(bytes32 clauseHash)` event emission on dispute initiation
- Oracle query interface for score lookups
- Optional Chainlink Automation for score updates

#### Timeline:

To be developed after Phase 1 core stabilization is complete.

---

### Plan 5: Multi-Party Reconciliation

**Priority:** Medium
**Status:** ✅ COMPLETED
**Dependencies:** Core ILRM stable

#### Implemented Files:

| File | Description |
|------|-------------|
| `contracts/MultiPartyILRM.sol` | Full multi-party dispute resolution contract |
| `contracts/interfaces/IMultiPartyILRM.sol` | Interface with structs and events |

#### Core Data Structures:

| Struct | Description |
|--------|-------------|
| `MultiPartyDispute` | Full dispute state with dynamic party support |
| `PartyInfo` | Per-party tracking (stake, acceptance, evidence) |
| `DisputeConfig` | Quorum type, windows, party limits |
| `QuorumType` | Unanimous, SuperMajority, SimpleMajority, Custom |

#### Key Functions:

| Function | Description |
|----------|-------------|
| `createMultiPartyDispute()` | Create dispute with initial parties |
| `joinDispute()` | Late-join support (if enabled) |
| `depositStake()` | Per-party stake deposit |
| `submitEvidence()` | Per-party evidence with aggregation |
| `acceptProposal()` | Accept with quorum tracking |
| `rejectProposal()` | Reject with impossibility detection |
| `counterPropose()` | Counter-proposal with exponential fees |
| `enforceTimeout()` | Timeout resolution with proportional burns |

#### Quorum Logic:

| Type | Calculation |
|------|-------------|
| Unanimous | All parties (100%) |
| SuperMajority | 67% of parties (2/3) |
| SimpleMajority | 51% of parties |
| Custom | User-defined BPS (e.g., 7500 = 75%) |

#### Resolution Outcomes:

| Outcome | Description |
|---------|-------------|
| QuorumAccepted | Quorum reached, stakes returned |
| TimeoutWithBurn | Timeout, 50% burned proportionally |
| PartialResolution | Not all staked, fallback applied |
| Cancelled | All parties agree to cancel |

#### Remaining Tasks:
- [ ] Integration tests with 3+ parties
- [ ] LLM prompt template for N-party disputes
- [ ] Frontend for multi-party dispute management

---

### Plan 6: Dynamic Treasury Caps

**Priority:** Low
**Status:** Not implemented (proposal; removed from Treasury.sol in Phase 1)
**Dependencies:** None

#### Proposed Changes:

**New State Variables:**
| Variable | Type | Description |
|----------|------|-------------|
| `dynamicCapEnabled` | `bool` | Toggle for dynamic caps |
| `dynamicCapPercentageBps` | `uint256` | Percentage of treasury (basis points) |
| `dynamicCapFloor` | `uint256` | Minimum cap floor |

**New Functions:**

| Function | Description |
|----------|-------------|
| `setDynamicCapConfig()` | Configure dynamic cap settings |
| `calculateDynamicCap()` | Calculate current dynamic cap from treasury balance |
| `getEffectiveMaxPerParticipant()` | Get effective cap (considers dynamic when enabled) |

**Modified Functions:**

| Function | Change |
|----------|--------|
| `fundStakeSubsidy()` | Would use `getEffectiveMaxPerParticipant()` instead of `maxPerParticipant` |
| `calculateSubsidy()` | Would use `getEffectiveMaxPerParticipant()` for preview |
| `getRemainingAllowance()` | Would use the effective cap for an accurate allowance |

**Configuration Example:**
```solidity
// Enable dynamic caps at 10% of treasury with 1 token floor
treasury.setDynamicCapConfig(
    true,           // enabled
    1000,           // 10% (1000 bps)
    1e18            // 1 token floor
);
```

#### Files to Modify:
- `contracts/Treasury.sol`

---

### Plan 7: Tiered Subsidies

**Priority:** Low
**Status:** Not implemented (proposal; removed from Treasury.sol in Phase 1)
**Dependencies:** None

#### Proposed Changes:

**New State Variables:**
| Variable | Type | Description |
|----------|------|-------------|
| `tieredSubsidiesEnabled` | `bool` | Toggle for tiered subsidies |
| `tier1Threshold` | `uint256` | Harassment score for tier 1 boundary |
| `tier2Threshold` | `uint256` | Harassment score for tier 2 boundary |
| `tier3Threshold` | `uint256` | Harassment score for tier 3 boundary |
| `tier1MultiplierBps` | `uint256` | Tier 1 subsidy multiplier (basis points) |
| `tier2MultiplierBps` | `uint256` | Tier 2 subsidy multiplier (basis points) |
| `tier3MultiplierBps` | `uint256` | Tier 3 subsidy multiplier (basis points) |

**New Functions:**

| Function | Description |
|----------|-------------|
| `setTieredSubsidyConfig()` | Configure tier thresholds and multipliers |
| `getSubsidyMultiplier()` | Get multiplier and tier for a participant |

**Tier System:**

| Tier | Harassment Score Range | Default Multiplier |
|------|----------------------|-------------------|
| 0 | 0 - tier1Threshold | 100% (full subsidy) |
| 1 | tier1Threshold - tier2Threshold | tier1MultiplierBps |
| 2 | tier2Threshold - tier3Threshold | tier2MultiplierBps |
| 3 | tier3Threshold - HARASSMENT_THRESHOLD | tier3MultiplierBps |
| Blocked | ≥ HARASSMENT_THRESHOLD | 0% (no subsidy) |

**Configuration Example:**
```solidity
// Enable tiered subsidies with graduated reduction
treasury.setTieredSubsidyConfig(
    true,    // enabled
    10,      // tier1Threshold (score >= 10)
    25,      // tier2Threshold (score >= 25)
    40,      // tier3Threshold (score >= 40)
    7500,    // tier1 = 75%
    5000,    // tier2 = 50%
    2500     // tier3 = 25%
);
```

#### Files to Modify:
- `contracts/Treasury.sol`

---

### Plan 8: Governance Upgrade (Multi-Sig + Timelock)

**Priority:** Low
**Status:** ✅ COMPLETED
**Dependencies:** OpenZeppelin TimelockController

#### Implemented Files:

| File | Description |
|------|-------------|
| `contracts/GovernanceTimelock.sol` | Timelock controller with protocol-specific features |
| `contracts/interfaces/IGovernanceTimelock.sol` | Interface with types and events |
| `scripts/deploy-governance.ts` | Deployment script for governance infrastructure |

#### Features:

| Feature | Description |
|---------|-------------|
| TimelockController | Extends OpenZeppelin's TimelockController |
| Multi-Sig Proposer | Only multi-sig can propose operations |
| Configurable Delays | minDelay, emergencyDelay, longDelay |
| Operation Types | ParameterChange, ContractUpgrade, OwnershipTransfer, EmergencyAction, etc. |
| Batch Operations | Schedule and execute multiple operations atomically |
| Emergency Bypass | Reduced delay for security emergencies |
| Emergency Pause | Pause all protocol contracts at once |
| Contract Registry | Register and manage protocol contracts |
| Ownership Transfer | Ownable2Step compatible via acceptContractOwnership() |

#### Delay Configuration:

| Delay Type | Default | Use Case |
|------------|---------|----------|
| minDelay | 2 days | Standard parameter changes |
| emergencyDelay | 12 hours | Security emergencies |
| longDelay | 4 days | Contract upgrades, ownership transfers |

#### Governance Flow:

| Step | Actor | Action |
|------|-------|--------|
| 1 | Multi-sig | Propose operation via scheduleOperation() |
| 2 | Community | Review during timelock delay |
| 3 | Anyone* | Execute after delay via executeOperation() |
| 4 | Multi-sig | Cancel if needed via cancelOperation() |

*If openExecutor is enabled

#### Deployment Steps:

1. Deploy Gnosis Safe multi-sig
2. Deploy GovernanceTimelock with multi-sig as proposer
3. Register all protocol contracts
4. Transfer ownership of each contract to timelock
5. Timelock accepts ownership (via multi-sig proposal)
6. Renounce deployer's admin role

#### External Dependencies:
- OpenZeppelin `TimelockController`
- Gnosis Safe (recommended for multi-sig)

---

### Plan 9: Threshold Decryption (Compliance Council)

**Priority:** High
**Status:** ✅ COMPLETED
**Dependencies:** BLS12-381 libraries, AccessControl

#### Implemented Files:

| File | Description |
|------|-------------|
| `contracts/ComplianceCouncil.sol` | Full compliance council with BLS threshold signatures |
| `contracts/interfaces/IComplianceCouncil.sol` | Interface with all types and events |
| `sdk/threshold-bls.ts` | TypeScript SDK for distributed key generation and signing |

#### Core Data Structures:

| Struct | Description |
|--------|-------------|
| `BLSPublicKey` | G1 point, EIP-2537 encoding (each coordinate as two 32-byte words) |
| `BLSSignature` | G2 point, EIP-2537 encoding (each Fp2 coordinate as four 32-byte words) |
| `ThresholdSignature` | Aggregated sig with signer indices |
| `CouncilMember` | Member details with BLS key and role |
| `CouncilConfig` | Threshold, voting period, delays |
| `WarrantRequest` | Legal request with status tracking |

#### Key Functions:

| Function | Description |
|----------|-------------|
| `addMember()` | Add council member with BLS public key |
| `removeMember()` | Remove member (maintains threshold) |
| `submitWarrantRequest()` | Submit legal compliance request |
| `castVote()` | Vote approve/reject on warrant |
| `concludeVoting()` | Finalize voting after period ends |
| `fileAppeal()` | Appeal approved warrant |
| `submitSignature()` | Submit partial BLS signature |
| `getCurrentSignatures()` | Partial signatures that currently count (`getSignatures()` lists every submission) |
| `aggregateSignatures()` | Plain G2 sum of signatures (rejects an infinity sum) |
| `setAggregatedPublicKey()` | Set the DKG group public key (admin) |
| `getSigningMessage()` | Warrant message bound to chain id and council address |
| `verifyThresholdSignature()` | Verify an aggregate against the group key |
| `executeReconstruction()` | Reconstruct the group signature after threshold and record its hash as `decryptedKeyHash` |

#### Member Roles:

| Role | Description |
|------|-------------|
| UserRepresentative | Elected by protocol users |
| ProtocolGovernance | DAO governance multisig |
| IndependentAuditor | Third-party auditor |
| LegalCounsel | Legal advisor |
| RegulatoryLiaison | Regulatory body liaison |

#### Warrant Flow:

| Step | Action | Status |
|------|--------|--------|
| 1 | Authority submits warrant request | Pending |
| 2 | Council members vote (threshold required) | Pending → Approved/Rejected |
| 3 | Execution delay for appeal window | Approved |
| 4 | Council members submit BLS signatures | Executing |
| 5 | Threshold reached, key reconstructed | Executed |

#### SDK Features:

| Feature | Description |
|---------|-------------|
| `generateKeyShares()` | FROST-style DKG with Feldman VSS |
| `verifyShare()` | Verify share against commitments |
| `signPartial()` | Create partial BLS signature |
| `aggregateSignatures()` | Lagrange coefficient aggregation |
| `verifyThresholdSignature()` | Verify aggregated signature |
| `selectCurrentSubmissions()` | Drop stale submissions (removed signer, rotated key) from `getSignatures()` output |
| `aggregateWarrantSignature()` | Read current partials from the council, verify and aggregate them, return `decryptedKeyHash` |
| `computeDecryptedKeyHash()` | `decryptedKeyHash` of a threshold signature |
| `reconstructSecret()` | Reconstruct master secret from shares |
| `decryptViewingKey()` | Decrypt viewing key using reconstructed secret |

#### Remaining Tasks:
- [ ] Integration tests with full council flow
- [ ] Trusted setup for BLS verification
- [ ] Frontend for council member operations
- [ ] Integration with ComplianceEscrow

---

## Trust Model & Execution Modes

### Trust Choke Points

The ILRM protocol is cryptographically sound but contains explicit trust assumptions:

| Component | Trust Type | Mitigation |
|-----------|-----------|------------|
| Oracle | Trusted actor | Bonded stake, slashing, multi-sig rotation |
| ComplianceCouncil | Threshold trust | BLS signatures, quorum voting, execution modes |
| AssetRegistry | Trusted registrar | Ownership verification, freeze controls |
| GovernanceTimelock | Multi-sig | Time delays, emergency bypass with audit trail |

### ComplianceCouncil Execution Modes

The ComplianceCouncil implements explicit execution modes to prevent silent trust degradation:

| Mode | Trust Model | When to Use |
|------|-------------|-------------|
| `DISABLED` | No execution | Pre-deployment, emergency state |
| `STRICT_ONCHAIN` | Cryptographic finality | Mainnet (requires BLS precompiles) |
| `HYBRID_ATTESTED` | Operational trust | L2s without precompiles, with operator attestation |

**Mode Selection Rules:**
- `STRICT_ONCHAIN` auto-enabled if BLS precompiles detected at deployment
- `HYBRID_ATTESTED` requires explicit governance action + reason
- Mode changes emit `ExecutionModeChanged` event for audit trail
- `attestHybridVerification()` required before execution in hybrid mode

### Oracle Governance

The oracle is a **governed actor** with explicit responsibilities:

| Failure Type | Example | Mitigation |
|-------------|---------|------------|
| Byzantine | Malicious data | Signature verification, multi-oracle quorum |
| Silent | No updates | Circuit breaker, timeout fallback |
| Key Compromise | Stolen signer | Emergency rotation via GovernanceTimelock |
| Governance Capture | Oracle collusion | Multi-party approval, appeal window |

**Oracle Events (Transparency Requirements):**
- All oracle payloads emitted via `ProposalSubmitted`
- Signer identity bound to signature verification
- Confidence/quorum metadata in extended proposal format

---

## Security Considerations

### Audit Status

| Finding | Severity | Status |
|---------|----------|--------|
| C-01: Initiator incentive not transferred | Critical | ✅ Fixed |
| C-02: Oracle signature verification bypass | Critical | ✅ Fixed |
| H-01: LLM signature verification disabled | High | ✅ Fixed |
| H-02: Treasury ILRM check bypass | High | ✅ Fixed |
| H-03: Oracle-ILRM architecture mismatch | High | ✅ Fixed |
| H-04: Unbounded loop DoS | High | ✅ Fixed |
| H-05: Anyone can register assets | High | ✅ Fixed |
| H-06: Treasury subsidy for resolved disputes | High | ✅ Fixed |
| H-07: Unverified signature execution | High | ✅ Fixed |
| M-01: Treasury type confusion | Medium | 🔶 Acknowledged |
| M-02: Centralization risk | Medium | ✅ Fixed (Plan 8) |
| M-03: Missing harassment score event | Medium | ✅ Fixed |
| M-04: requestSubsidy caller not validated | Medium | ✅ Fixed (requestSubsidy replaced by the ILRM escrow flow) |
| M-05: Domain separator immutability | Medium | ✅ Fixed |
| M-06: Counter-proposal timing manipulation | Medium | 🔶 Acknowledged |
| M-07: Deployer auto-registered as oracle | Medium | ✅ Fixed |
| M-08: Int256 overflow edge case | Medium | ✅ Fixed |
| M-09: Uninitialized tier threshold | Medium | N/A, feature removed in Phase 1 |
| M-10: Treasury harassment score decay | Medium | N/A, feature removed in Phase 1 |
| M-11: GovernanceTimelock silent pause failures | Medium | ✅ Fixed |
| M-12: ComplianceCouncil DISABLED mode lockout | Medium | ✅ Fixed |
| C-03: ComplianceCouncil public key aggregation placeholder | Critical | ✅ Fixed |
| H-08: FIDOVerifier challenge verification bypass | High | ✅ Fixed |
| H-09: Oracle no recovery for malicious proposals | High | ✅ Fixed |
| H-10: AssetRegistry MAX_ASSETS bypass via transfers | High | ✅ Fixed |
| L-01: GovernanceTimelock infinite recursion | Low | ✅ Fixed |
| L-02: ILRM dust tracking bug | Low | ✅ Fixed |
| L-03: Dead code in FIDO verification | Low | ✅ Fixed |
| Initiator-incentive farming via never-staking sybil counterparties (`tokenReserves` drain) | High | 🔶 Mitigated by per-dispute and per-window caps; farming up to the window cap is a documented residual risk |
| Subsidy grant front-run overcharges the defender's allowance | Medium | ✅ Fixed (`maxTopUp` slippage bound) |
| Treasury subsidy records collide on dispute IDs after `setILRM` to a redeployed ILRM | Medium | ✅ Fixed (records keyed by (ILRM, disputeId)) |

### Remaining Security Tasks

1. **Professional Third-Party Audit** - Required before mainnet
2. **Formal Verification** - For critical stake/burn logic
3. **Bug Bounty Program** - Post-audit launch
4. **Execution Mode Testing** - L2/fork/non-standard EVM coverage

### Suggested Audit Response

> These findings do not represent exploitable vulnerabilities, but rather trust and execution-mode considerations. The protocol explicitly documents when cryptographic enforcement (on-chain BLS, decentralized oracle quorum) is required versus when operational trust is assumed. Execution modes, capability gating, and oracle governance controls are formalized to prevent silent degradation and ensure transparency.

---

## Roadmap Alignment

| Phase | Timeline | Key Features | Status |
|-------|----------|--------------|--------|
| **Phase 1** | 2026 | Core stabilization, L2 deployment, economic validation | 🔶 In Progress |
| **Phase 2** | 2026-2027 | License Entropy Oracle, DID, multi-party, explainability | ❌ Not Started |
| **Phase 3** | 2028-2029 | Clause hardening, ZK evidence, L3 scaling | ❌ Not Started |
| **Phase 4** | 2030+ | Adaptive workflows, real-world bridging, cross-chain | ❌ Not Started |

### Phase 1 Checklist

- [x] ILRM core contract
- [x] Treasury contract
- [x] Oracle contract
- [x] AssetRegistry contract
- [x] Security audit fixes
- [ ] L2 deployment (Optimism/Arbitrum)
- [ ] Economic parameter tuning
- [ ] Pilot programs
- [ ] Open-source release finalization

---

## Success Metrics

The protocol tracks the following metrics to measure effectiveness:

| Metric | Description | Target |
|--------|-------------|--------|
| Resolution Rate | % of conflicts resolved without timeout | > 70% |
| Time-to-Resolution | Average days from initiation to resolution | < 5 days |
| Repeat Usage | % of entities using protocol multiple times | > 40% |
| Counter-Proposal Rate | Average counters per dispute | < 1.5 |
| Burn Rate | % of total stakes burned on timeout | < 30% |
| Subsidy Utilization | % of eligible parties using treasury subsidies | Monitoring |
| Governance Participation | Active voters in warrant requests | > 50% of council |

---

## LLM Prompt Template

The following template constrains LLM outputs to reconciliation-only proposals:

**System Prompt:**
```
You are a neutral reconciliation engine for IP and licensing disputes. Analyze the provided canonicalized evidence (contract clauses, license grants, provenance, usage metrics, negotiation history). Generate 1-3 Pareto-improving proposals that minimize future conflict costs for both parties. Proposals must be forward-looking, executable via smart contract, and include only: license adjustments, royalty splits, retroactive cures, time-limited grants, or mutual releases. Do NOT assign fault, invalidate rights, or make legal conclusions. Output in JSON format: [{proposal_id: 1, description: '...', terms: {scope: '...', royalties: X%, duration: Y months, etc.}}]
```

**User Prompt:**
```
Evidence: [Insert canonicalized data here]
```

**Output Constraints:**
- Maximum 3 proposals
- Each proposal must be Pareto-improving
- Terms must be smart-contract executable
- No fault assignment, rights invalidation, or legal conclusions

---

## State Transition Diagram

```
+-------------+
|   Inactive  |
+-------------+
       |
       v
+-------------+  Initiate (Stake S, Evidence Hash, Fallback)
|  Initiated  |<---------------- Counterparty Stakes within T_stake?
+-------------+                  Yes: Proceed to Active
       |                         No: DefaultLicenseApplied → Resolved
       v
+-------------+
|    Active   |
+-------------+
| Proposal Gen|
| (LLM/Oracle)|
+-------------+
       |
       +--> Mutual Acceptance? Yes: AcceptedProposal → Resolved (Stakes Returned, Terms Executed)
       |
       +--> Counter? (Fee Burned, Window Extended, Max 3) → Back to Proposal Gen
       |
       v
Timeout (T_resolution)? → TimeoutWithBurn (Burn %, Stakes Partial Return) → DefaultLicenseApplied → Resolved
```

---

## Future Modules

### Reconciliation & Rights Agent (RRA)

**Status:** 🔮 Future Module
**Source:** `FIDO-Yubi.md:22-30`

**Description:** An autonomous agent that orchestrates actions across NatLangChain modules. The RRA will:
- Coordinate between negotiation and reconciliation flows
- Trigger automated market matching for rights
- Enable hardware-backed agent control via FIDO2
- Sign delegated commands securely

**Priority:** Medium — Inherits security from ILRM and other modules; implement when handling sensitive automations.

**Integration Points:**
- FIDO2 authentication for user control of agent actions
- On-chain verification of agent-signed executions
- Delegation registry for authorized agent operations

---

## Appendix: Constants Reference

| Constant | Value | Location |
|----------|-------|----------|
| `MAX_COUNTERS` | 3 | `ILRM.sol:34` |
| `BURN_PERCENTAGE` | 50% | `ILRM.sol:37` |
| `STAKE_WINDOW` | 3 days | `ILRM.sol:40` |
| `RESOLUTION_TIMEOUT` | 7 days | `ILRM.sol:43` |
| `COUNTER_FEE_BASE` | 0.01 ETH | `ILRM.sol:46` |
| `INITIATOR_INCENTIVE_BPS` | 1000 (10%, before the incentive caps) | `ILRM.INITIATOR_INCENTIVE_BPS` |
| `MIN_INCENTIVE_WINDOW` | 1 day | `ILRM.MIN_INCENTIVE_WINDOW` |
| `MAX_INCENTIVE_WINDOW` | 365 days | `ILRM.MAX_INCENTIVE_WINDOW` |
| `DEFAULT_MAX_INCENTIVE_PER_DISPUTE` | 1e18 (owner-settable `maxIncentivePerDispute`) | `ILRM.DEFAULT_MAX_INCENTIVE_PER_DISPUTE` |
| `DEFAULT_MAX_INCENTIVE_PER_WINDOW` | 10e18 (owner-settable `maxIncentivePerWindow`) | `ILRM.DEFAULT_MAX_INCENTIVE_PER_WINDOW` |
| `DEFAULT_INCENTIVE_WINDOW` | 30 days (owner-settable `incentiveWindow`) | `ILRM.DEFAULT_INCENTIVE_WINDOW` |
| `ESCALATION_MULTIPLIER` | 150 (1.5x) | `ILRM.sol:52` |
| `COOLDOWN_PERIOD` | 30 days | `ILRM.sol:55` |
| `HARASSMENT_THRESHOLD` | 50 | `NatLangChainTreasury.HARASSMENT_THRESHOLD` |
| `MAX_ASSETS_PER_OWNER` | 100 | `AssetRegistry.sol:23` |

---

*This specification is a living document. Updates should be made as features are implemented or requirements change.*
