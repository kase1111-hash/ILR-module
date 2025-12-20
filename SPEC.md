# NatLangChain ILRM Protocol Specification

**Version:** 1.2
**Last Updated:** December 20, 2025
**Status:** Testnet Ready

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Implementation Status](#implementation-status)
3. [Core Contracts](#core-contracts)
4. [Unimplemented Features](#unimplemented-features)
5. [Implementation Plans](#implementation-plans)
6. [Security Considerations](#security-considerations)
7. [Roadmap Alignment](#roadmap-alignment)

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
| Council Member Management | ✅ | `ComplianceCouncil.sol:115-185` | Add/remove with BLS keys |
| Member Role Types | ✅ | `IComplianceCouncil.sol:35-42` | 5 roles: User, DAO, Auditor, Legal, Regulator |
| Warrant Request Submission | ✅ | `ComplianceCouncil.sol:195-235` | With document hash and jurisdiction |
| Threshold Voting | ✅ | `ComplianceCouncil.sol:240-290` | m-of-n approval/rejection |
| Appeal Mechanism | ✅ | `ComplianceCouncil.sol:310-325` | Before execution delay expires |
| BLS Signature Submission | ✅ | `ComplianceCouncil.sol:335-390` | Per-member signatures |
| Signature Aggregation | ✅ | `ComplianceCouncil.sol:395-415` | Lagrange interpolation |
| Threshold Verification | ✅ | `ComplianceCouncil.sol:420-440` | Aggregated signature check |
| Key Reconstruction | ✅ | `ComplianceCouncil.sol:445-475` | Execute reveal after threshold |
| BLS12-381 Precompiles | ✅ | `ComplianceCouncil.sol:25-35` | EIP-2537 with fallback detection |
| Pausable Operations | ✅ | `ComplianceCouncil.sol:490-500` | Emergency pause support |

### Treasury Contract

| Feature | Status | Location | Notes |
|---------|--------|----------|-------|
| Deposit Burns/Fees | ✅ | `Treasury.sol:151-171` | ERC20 and ETH |
| Defensive Subsidies | ✅ | `Treasury.sol:189-273` | Counterparty-only |
| Per-Dispute Caps | ✅ | `Treasury.sol:242-244` | Configurable |
| Per-Participant Rolling Caps | ✅ | `Treasury.sol:247-250` | With window reset |
| Harassment Score Checks | ✅ | `Treasury.sol:228-230` | Threshold: 50 |
| Anti-Sybil (Single Subsidy/Dispute) | ✅ | `Treasury.sol:200-203` | Prevents double-claiming |
| Dynamic Caps | ✅ | `Treasury.sol:497-531` | Scale caps with treasury size |
| Tiered Subsidies | ✅ | `Treasury.sol:617-646` | Based on harassment score tiers |
| Multi-Token Support | ❌ | - | Currently single ERC20 |

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
**Status:** ❌ Not Implemented
**Source:** `Updated-Mechanics.md:119-144`, `NatLangChain-Roadmap.md:107-113`

**Description:** Scores contract clauses (0-100) based on historical dispute rates, timeouts, and burns. Predicts likelihood of future disputes.

**Contract Skeleton:**
```solidity
contract LicenseEntropyOracle {
    mapping(bytes32 => uint256) public entropyScores;
    function scoreClause(bytes32 clauseHash) external view returns (uint256);
    // Fed via oracle updates from dispute analytics
}
```

#### 3.2 Clause-Pattern Clustering (NatLangChain-Roadmap.md)
**Status:** ❌ Not Implemented
**Source:** `NatLangChain-Roadmap.md:121`

**Description:** ML-based analysis of which contract clause patterns cause disputes. Off-chain analysis with on-chain score exposure.

#### 3.3 Automated Clause Hardening (NatLangChain-Roadmap.md)
**Status:** ❌ Not Implemented
**Source:** `NatLangChain-Roadmap.md:157`

**Description:** During negotiation, automatically suggest improvements to high-entropy clauses based on historical data.

#### 3.4 Predictive Warnings (NatLangChain-Roadmap.md)
**Status:** ❌ Not Implemented
**Source:** `NatLangChain-Roadmap.md:158`

**Description:** Real-time warnings during contract drafting for terms predicted to cause disputes.

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
**Status:** ❌ Not Implemented
**Source:** `NatLangChain-Roadmap.md:105`

**Description:** Sybil-resistant participation via DID standards. Integrate with existing DID frameworks (e.g., ERC-725, Verifiable Credentials).

#### 4.3 L3/App-Specific Rollups (NatLangChain-Roadmap.md)
**Status:** ❌ Not Implemented
**Source:** `NatLangChain-Roadmap.md:162`

**Description:** High-throughput dispute handling via dedicated rollups for IP disputes.

### Category 5: Treasury Enhancements (Low Priority)

#### 5.1 Dynamic Subsidy Caps (Treasury.md)
**Status:** ✅ IMPLEMENTED
**Source:** `Treasury.md:122`

**Description:** Scale `maxPerParticipant` based on current treasury balance to ensure sustainability.

**Implementation:**
- Location: `contracts/Treasury.sol:497-531`
- Configuration: `setDynamicCapConfig(enabled, percentageBps, floor)`
- View functions: `calculateDynamicCap()`, `getEffectiveMaxPerParticipant()`

**Features Implemented:**
- Toggle dynamic caps on/off via `dynamicCapEnabled`
- Configurable percentage of treasury balance (basis points)
- Configurable floor value (minimum cap even when treasury is low)
- Automatic integration with `requestSubsidy()` and `calculateSubsidy()`
- Uses lower of configured cap and dynamic cap when enabled

#### 5.2 Tiered Subsidies (Treasury.md)
**Status:** ✅ IMPLEMENTED
**Source:** `Treasury.md:125`

**Description:** Low harassment score → full subsidy; higher score → partial subsidy (graduated scale).

**Implementation:**
- Location: `contracts/Treasury.sol:617-646`
- Configuration: `setTieredSubsidyConfig(enabled, thresholds, multipliers)`
- View function: `getSubsidyMultiplier(participant)`

**Features Implemented:**
- 4-tier system based on harassment score thresholds
- Tier 0: score < tier1Threshold → 100% subsidy
- Tier 1: tier1Threshold ≤ score < tier2Threshold → tier1MultiplierBps
- Tier 2: tier2Threshold ≤ score < tier3Threshold → tier2MultiplierBps
- Tier 3: tier3Threshold ≤ score < HARASSMENT_THRESHOLD → tier3MultiplierBps
- score ≥ HARASSMENT_THRESHOLD → blocked (0%)
- Configurable thresholds and multipliers via admin function
- Automatic integration with `requestSubsidy()` and `calculateSubsidy()`

#### 5.3 Multi-Token Support (Treasury.md)
**Status:** ❌ Not Implemented
**Source:** `Treasury.md:131`

**Description:** Accept multiple staking tokens or native ETH for stakes and subsidies.

### Category 6: Governance & Security (Low Priority)

#### 6.1 Multi-Sig/Timelock Governance (SECURITY_AUDIT.md)
**Status:** ❌ Not Implemented
**Source:** `SECURITY_AUDIT.md:299-315`

**Description:** Replace single owner with multi-sig and add timelock for admin operations.

#### 6.2 Ownable2Step Migration (SECURITY_AUDIT.md)
**Status:** ❌ Not Implemented
**Source:** `SECURITY_AUDIT.md:473-475`

**Description:** Use OpenZeppelin's `Ownable2Step` for safer ownership transfers.

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
**Estimated Complexity:** Medium
**Dependencies:** Historical dispute data, Chainlink

#### Implementation Steps:

1. **Oracle Contract**
   - Create `contracts/LicenseEntropyOracle.sol`
   - Implement `entropyScores` mapping (bytes32 → uint256)
   - Add `scoreClause()` view function
   - Owner-controlled `updateScores()` for batch updates

2. **Data Pipeline**
   - Index ILRM events via The Graph
   - Aggregate clause hash → outcome data
   - Calculate entropy score formula: `(timeouts / total) * risk_factors`

3. **Integration Points**
   - ILRM emits `ClauseUsed(bytes32 clauseHash)` on initiation
   - Oracle updates scores periodically
   - Optional: Chainlink Automation for score updates

4. **NatLangChain Integration**
   - Query oracle during contract drafting
   - Display warnings for high-entropy (>50) clauses
   - Suggest low-entropy alternatives

#### Files to Create:
- `contracts/LicenseEntropyOracle.sol`
- `subgraph/schema.graphql`
- `scripts/calculate-entropy.ts`

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
**Status:** ✅ COMPLETED
**Dependencies:** None

#### Implemented Changes:

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
| `requestSubsidy()` | Uses `getEffectiveMaxPerParticipant()` instead of `maxPerParticipant` |
| `calculateSubsidy()` | Uses `getEffectiveMaxPerParticipant()` for preview |
| `getRemainingAllowance()` | Uses effective cap for accurate allowance |

**Configuration Example:**
```solidity
// Enable dynamic caps at 10% of treasury with 1 token floor
treasury.setDynamicCapConfig(
    true,           // enabled
    1000,           // 10% (1000 bps)
    1e18            // 1 token floor
);
```

#### Files Modified:
- `contracts/Treasury.sol`

---

### Plan 7: Tiered Subsidies

**Priority:** Low
**Status:** ✅ COMPLETED
**Dependencies:** None

#### Implemented Changes:

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

#### Files Modified:
- `contracts/Treasury.sol`

---

### Plan 8: Governance Upgrade (Multi-Sig + Timelock)

**Priority:** Low
**Estimated Complexity:** Medium
**Dependencies:** OpenZeppelin Governor, Timelock

#### Implementation Steps:

1. **Deploy Governance Infrastructure**
   - Deploy `TimelockController` (2-day delay)
   - Deploy multi-sig (Gnosis Safe recommended)
   - Set multi-sig as Timelock proposer

2. **Transfer Ownership**
   - Transfer ILRM ownership to Timelock
   - Transfer Treasury ownership to Timelock
   - Transfer Oracle ownership to Timelock
   - Transfer AssetRegistry ownership to Timelock

3. **Document Procedures**
   - Governance proposal format
   - Emergency procedures (multi-sig bypass)
   - Key rotation procedures

#### External Dependencies:
- OpenZeppelin `TimelockController`
- Gnosis Safe

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
| `BLSPublicKey` | G1 point coordinates (x, y) |
| `BLSSignature` | G2 point coordinates (Fp2) |
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
| `aggregateSignatures()` | Combine partial signatures |
| `executeReconstruction()` | Reconstruct key after threshold |

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
| `reconstructSecret()` | Reconstruct master secret from shares |
| `decryptViewingKey()` | Decrypt viewing key using reconstructed secret |

#### Remaining Tasks:
- [ ] Integration tests with full council flow
- [ ] Trusted setup for BLS verification
- [ ] Frontend for council member operations
- [ ] Integration with ComplianceEscrow

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
| M-01: Treasury type confusion | Medium | 🔶 Acknowledged |
| M-02: Centralization risk | Medium | ❌ Pending (Plan 8) |
| M-03: Missing harassment score event | Medium | ✅ Fixed |
| M-04: requestSubsidy caller not validated | Medium | ✅ Fixed |
| M-05: Domain separator immutability | Medium | ✅ Fixed |
| M-06: Counter-proposal timing manipulation | Medium | 🔶 Acknowledged |
| M-07: Deployer auto-registered as oracle | Medium | ✅ Fixed |
| M-08: Int256 overflow edge case | Medium | ✅ Fixed |

### Remaining Security Tasks

1. **Professional Third-Party Audit** - Required before mainnet
2. **Formal Verification** - For critical stake/burn logic
3. **Bug Bounty Program** - Post-audit launch

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

## Appendix: Constants Reference

| Constant | Value | Location |
|----------|-------|----------|
| `MAX_COUNTERS` | 3 | `ILRM.sol:34` |
| `BURN_PERCENTAGE` | 50% | `ILRM.sol:37` |
| `STAKE_WINDOW` | 3 days | `ILRM.sol:40` |
| `RESOLUTION_TIMEOUT` | 7 days | `ILRM.sol:43` |
| `COUNTER_FEE_BASE` | 0.01 ETH | `ILRM.sol:46` |
| `INITIATOR_INCENTIVE_BPS` | 1000 (10%) | `ILRM.sol:49` |
| `ESCALATION_MULTIPLIER` | 150 (1.5x) | `ILRM.sol:52` |
| `COOLDOWN_PERIOD` | 30 days | `ILRM.sol:55` |
| `HARASSMENT_THRESHOLD` | 50 | `Treasury.sol:44` |
| `MAX_ASSETS_PER_OWNER` | 100 | `AssetRegistry.sol:23` |

---

*This specification is a living document. Updates should be made as features are implemented or requirements change.*
