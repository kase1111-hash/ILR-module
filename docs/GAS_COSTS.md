# Gas Costs Analysis - NatLangChain ILRM Protocol

**Software Version:** 0.1.0-alpha
**Last Updated:** [PENDING]
**Analyzed By:** [PENDING]

---

## Quick Start

Generate gas reports with:

```bash
# Run gas benchmarks
./scripts/run-gas-benchmarks.sh

# Or manually with forge
forge test --gas-report
forge test --match-contract GasBenchmarks --gas-report -vv
```

---

## Network Cost Assumptions

| Network | Gas Price | ETH Price | Notes |
|---------|-----------|-----------|-------|
| Ethereum L1 | 30 gwei | $3,500 | Average, varies 10-100+ |
| Optimism L2 | 0.001 gwei | $3,500 | L2 execution only |
| Arbitrum L2 | 0.1 gwei | $3,500 | L2 execution only |

### Cost Calculation

```
L1 Cost = Gas × 30 gwei × $3,500 / 1e18
L2 Cost = Gas × 0.001 gwei × $3,500 / 1e18

Example: 150,000 gas
- L1: 150,000 × 30 × 3500 / 1e18 = $15.75
- L2: 150,000 × 0.001 × 3500 / 1e18 = $0.000525
```

---

## Critical Function Gas Costs

### ILRM Core Operations

| Function | Gas Used | L1 Cost | L2 Cost | Acceptable Max | Status |
|----------|----------|---------|---------|----------------|--------|
| `initiateBreachDispute()` | ⬜ | ⬜ | ⬜ | 300,000 | ⬜ |
| `matchStake()` | ⬜ | ⬜ | ⬜ | 200,000 | ⬜ |
| `counterPropose()` | ⬜ | ⬜ | ⬜ | 250,000 | ⬜ |
| `acceptProposal()` | ⬜ | ⬜ | ⬜ | 200,000 | ⬜ |
| `enforceTimeout()` | ⬜ | ⬜ | ⬜ | 150,000 | ⬜ |
| `initiateVoluntaryRequest()` | ⬜ | ⬜ | ⬜ | 150,000 | ⬜ |
| `rejectVoluntaryRequest()` | ⬜ | ⬜ | ⬜ | 80,000 | ⬜ |

### Treasury Operations

| Function | Gas Used | L1 Cost | L2 Cost | Acceptable Max | Status |
|----------|----------|---------|---------|----------------|--------|
| `distributeSubsidy()` | ⬜ | ⬜ | ⬜ | 120,000 | ⬜ |
| `recordBurn()` | ⬜ | ⬜ | ⬜ | 50,000 | ⬜ |
| `emergencyWithdraw()` | ⬜ | ⬜ | ⬜ | 100,000 | ⬜ |

### Oracle Operations

| Function | Gas Used | L1 Cost | L2 Cost | Acceptable Max | Status |
|----------|----------|---------|---------|----------------|--------|
| `submitLLMProposal()` | ⬜ | ⬜ | ⬜ | 150,000 | ⬜ |
| `registerOracle()` | ⬜ | ⬜ | ⬜ | 100,000 | ⬜ |

### L3 Bridge Operations

| Function | Gas Used | L1 Cost | L2 Cost | Acceptable Max | Status |
|----------|----------|---------|---------|----------------|--------|
| `bridgeDisputeToL3()` | ⬜ | ⬜ | ⬜ | 400,000 | ⬜ |
| `commitFraudProof()` | ⬜ | ⬜ | ⬜ | 200,000 | ⬜ |
| `revealFraudProof()` | ⬜ | ⬜ | ⬜ | 300,000 | ⬜ |
| `submitStateCommitment()` | ⬜ | ⬜ | ⬜ | 250,000 | ⬜ |
| `processSettlement()` | ⬜ | ⬜ | ⬜ | 200,000 | ⬜ |

### Identity & Compliance

| Function | Gas Used | L1 Cost | L2 Cost | Acceptable Max | Status |
|----------|----------|---------|---------|----------------|--------|
| `registerDID()` | ⬜ | ⬜ | ⬜ | 200,000 | ⬜ |
| `verifyIdentityProof()` | ⬜ | ⬜ | ⬜ | 350,000 | ⬜ |
| `verifyFIDOSignature()` | ⬜ | ⬜ | ⬜ | 300,000 | ⬜ |

### Governance Operations

| Function | Gas Used | L1 Cost | L2 Cost | Acceptable Max | Status |
|----------|----------|---------|---------|----------------|--------|
| `schedule()` | ⬜ | ⬜ | ⬜ | 150,000 | ⬜ |
| `execute()` | ⬜ | ⬜ | ⬜ | 200,000 | ⬜ |
| `cancel()` | ⬜ | ⬜ | ⬜ | 80,000 | ⬜ |

---

## Dispute Lifecycle Total Costs

### Typical Dispute (L2 - Optimism)

| Stage | Operations | Gas | L2 Cost |
|-------|------------|-----|---------|
| Initiation | initiateBreachDispute | ⬜ | ⬜ |
| Matching | matchStake | ⬜ | ⬜ |
| Proposal | submitLLMProposal | ⬜ | ⬜ |
| Acceptance | acceptProposal × 2 | ⬜ | ⬜ |
| **Total** | | ⬜ | ⬜ |

### Worst Case Dispute (Max Counters + Timeout)

| Stage | Operations | Gas | L2 Cost |
|-------|------------|-----|---------|
| Initiation | initiateBreachDispute | ⬜ | ⬜ |
| Matching | matchStake | ⬜ | ⬜ |
| Proposal 1 | submitLLMProposal | ⬜ | ⬜ |
| Counter 1 | counterPropose | ⬜ | ⬜ |
| Proposal 2 | submitLLMProposal | ⬜ | ⬜ |
| Counter 2 | counterPropose | ⬜ | ⬜ |
| Proposal 3 | submitLLMProposal | ⬜ | ⬜ |
| Counter 3 | counterPropose | ⬜ | ⬜ |
| Timeout | enforceTimeout | ⬜ | ⬜ |
| **Total** | | ⬜ | ⬜ |

---

## Contract Sizes

| Contract | Size (bytes) | Limit (24,576) | % Used |
|----------|--------------|----------------|--------|
| ILRM.sol | ⬜ | 24,576 | ⬜ |
| MultiPartyILRM.sol | ⬜ | 24,576 | ⬜ |
| Treasury.sol | ⬜ | 24,576 | ⬜ |
| Oracle.sol | ⬜ | 24,576 | ⬜ |
| AssetRegistry.sol | ⬜ | 24,576 | ⬜ |
| L3Bridge.sol | ⬜ | 24,576 | ⬜ |
| L3StateVerifier.sol | ⬜ | 24,576 | ⬜ |
| L3DisputeBatcher.sol | ⬜ | 24,576 | ⬜ |
| DIDRegistry.sol | ⬜ | 24,576 | ⬜ |
| IdentityVerifier.sol | ⬜ | 24,576 | ⬜ |
| FIDOVerifier.sol | ⬜ | 24,576 | ⬜ |
| ComplianceEscrow.sol | ⬜ | 24,576 | ⬜ |
| ComplianceCouncil.sol | ⬜ | 24,576 | ⬜ |
| GovernanceTimelock.sol | ⬜ | 24,576 | ⬜ |
| BatchQueue.sol | ⬜ | 24,576 | ⬜ |
| DummyTransactionGenerator.sol | ⬜ | 24,576 | ⬜ |

---

## Optimization Notes

### Completed Optimizations

1. **Struct packing** - Storage slots minimized
2. **Immutable variables** - Constructor-set values marked immutable
3. **Short-circuit evaluation** - Cheaper checks first in requires
4. **Event vs storage** - Events used where on-chain lookup not needed
5. **Batch operations** - Batch functions for repeated operations

### Potential Future Optimizations

1. **Assembly for tight loops** - Where gas savings > code complexity
2. **Custom errors** - Already implemented (cheaper than require strings)
3. **Bitmap storage** - For flags and small enums
4. **Merkle batch verification** - For large credential sets

---

## User Cost Analysis

### Target User: IP Rights Holder

**Assumptions:**
- 1-2 disputes per year
- Uses L2 (Optimism)
- Disputes resolve via acceptance (not timeout)

**Estimated Annual Gas Costs:** ⬜ (L2)

### Target User: Frequent Disputant (Institution)

**Assumptions:**
- 50+ disputes per year
- Uses L2 (Optimism)
- Mix of outcomes

**Estimated Annual Gas Costs:** ⬜ (L2)

---

## Comparison to Alternatives

| Action | ILRM (L2) | Traditional Arbitration | Court Filing |
|--------|-----------|------------------------|--------------|
| Initiate Dispute | ~$0.01 | $2,000-10,000 | $400-1,000 |
| Full Resolution | ~$0.05 | $10,000-100,000+ | $5,000-50,000+ |
| Time to Resolution | 7-14 days | 6-18 months | 1-3+ years |

---

## Sign-Off Checklist

- [ ] All critical functions within acceptable gas limits
- [ ] No contract exceeds 24KB size limit
- [ ] Typical dispute lifecycle affordable (<$1 on L2)
- [ ] Worst case dispute lifecycle affordable (<$5 on L2)
- [ ] No function exceeds block gas limit risk
- [ ] Batch operations scale linearly

### Approval

| Role | Name | Signature | Date |
|------|------|-----------|------|
| Lead Developer | | | |
| Reviewer | | | |

---

## Appendix: Raw Gas Report

```
[Paste forge test --gas-report output here]
```

---

*Generated with: `./scripts/run-gas-benchmarks.sh`*
*Last benchmark run: [PENDING]*
