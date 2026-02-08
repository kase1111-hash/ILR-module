# Phase 0 Manifest: Contract Classification

**Completed:** 2026-02-08
**Reference:** [REFOCUS_PLAN.md](./REFOCUS_PLAN.md)

---

## Directory Structure After Phase 0

```
contracts/
  ILRM.sol              <-- Core (Phase 1: strip to ~500 lines)
  Oracle.sol            <-- Core (keep as-is)
  Treasury.sol          <-- Core (Phase 1: simplify to ~350 lines)
  AssetRegistry.sol     <-- Core (keep as-is)
  interfaces/           <-- Shared (all phases)
  mocks/                <-- Shared (all phases)
  modules/              <-- Deferred to Phase 4-5
    MultiPartyILRM.sol
    IdentityVerifier.sol
    FIDOVerifier.sol
    DIDRegistry.sol
    ComplianceEscrow.sol
    ComplianceCouncil.sol
    GovernanceTimelock.sol
  scaling/              <-- Deferred to Phase 6
    BatchQueue.sol
    DummyTransactionGenerator.sol
    L3Bridge.sol
    L3StateVerifier.sol
    L3DisputeBatcher.sol
```

---

## Contract Classification

### Core (contracts/) -- Ship in Phase 1-2

| Contract | Lines | Phase | Action |
|----------|-------|-------|--------|
| ILRM.sol | 1,290 | 1 | Strip ZK/FIDO/DID/ViewingKey sections (~500 lines target) |
| Oracle.sol | 367 | 1 | Keep as-is |
| Treasury.sol | 1,064 | 1 | Simplify to flat-cap subsidies (~350 lines target) |
| AssetRegistry.sol | 390 | 1 | Keep as-is |

### Modules (contracts/modules/) -- Ship in Phase 3-5

| Contract | Lines | Phase | Category |
|----------|-------|-------|----------|
| MultiPartyILRM.sol | 695 | 3 | Supporting (multi-party disputes) |
| IdentityVerifier.sol | 396 | 4 | Identity (ZK Groth16 proofs) |
| FIDOVerifier.sol | 727 | 4 | Identity (hardware auth) |
| DIDRegistry.sol | 721 | 4 | Identity (decentralized ID) |
| ComplianceEscrow.sol | 444 | 5 | Compliance (viewing keys) |
| ComplianceCouncil.sol | 920 | 5 | Compliance (BLS threshold) |
| GovernanceTimelock.sol | 601 | 5 | Governance (multi-sig) |

### Scaling (contracts/scaling/) -- Ship in Phase 6 (demand-driven)

| Contract | Lines | Phase | Category |
|----------|-------|-------|----------|
| BatchQueue.sol | 674 | 6 | Privacy (tx batching) |
| DummyTransactionGenerator.sol | 673 | 6 | Privacy (pattern obfuscation) |
| L3Bridge.sol | 937 | 6 | Scaling (L3 rollup bridge) |
| L3StateVerifier.sol | 377 | 6 | Scaling (Merkle proofs) |
| L3DisputeBatcher.sol | 365 | 6 | Scaling (batch disputes) |

---

## Changes Made in Phase 0

1. Created `contracts/modules/` directory
2. Created `contracts/scaling/` directory
3. Moved 7 module contracts from `contracts/` to `contracts/modules/`
4. Moved 5 scaling contracts from `contracts/` to `contracts/scaling/`
5. Updated 18 import paths in moved contracts (`./interfaces/` -> `../interfaces/`)
6. Updated 6 import paths in test files to reference new locations
7. Fixed pre-existing broken import in `test/ILRM.t.sol` (`../src/ILRM.sol` -> `../contracts/ILRM.sol`)

**No code was deleted. All contracts are preserved and compilable.**

---

## Verification

- 49 relative import paths verified: all resolve to existing files
- 0 broken imports found
- All 12 moved files exist only in their new locations (no duplicates)
- 4 test files with no relative contract imports are unaffected

---

## What Remains in contracts/ Root

After Phase 0, only the 4 core contracts remain at the top level:

```
$ ls contracts/*.sol
contracts/ILRM.sol
contracts/Oracle.sol
contracts/Treasury.sol
contracts/AssetRegistry.sol
```

This makes the Phase 1 scope immediately visible: these 4 files are the deployment target.
