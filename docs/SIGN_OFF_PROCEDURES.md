# Sign-Off Procedures for Mainnet Deployment

**Software Version:** 0.1.0-alpha
**Last Updated:** January 2026

This document details the steps required to complete the mainnet sign-off checklist items.

---

## 1. Full Test Suite Passes (`forge test --fuzz-runs 10000`)

### Prerequisites
- [ ] Foundry installed and updated (`foundryup`)
- [ ] All dependencies installed (`forge install`)
- [ ] Clean build (`forge clean && forge build`)

### Execution Steps

#### Step 1.1: Run Standard Tests
```bash
# Run all tests with verbose output
forge test -vvv
```
- [ ] All unit tests pass
- [ ] All integration tests pass
- [ ] No compiler warnings

#### Step 1.2: Run Extended Fuzz Tests
```bash
# Run with 10,000 fuzz iterations (production requirement)
forge test --fuzz-runs 10000 -vv

# For specific high-risk contracts, run even more iterations
forge test --match-contract ILRM --fuzz-runs 50000
forge test --match-contract L3Bridge --fuzz-runs 50000
forge test --match-contract Treasury --fuzz-runs 50000
```
- [ ] No fuzz test failures
- [ ] No invariant violations
- [ ] Execution completes without timeout

#### Step 1.3: Run Invariant Tests
```bash
# Run invariant tests with extended runs
forge test --match-test invariant --fuzz-runs 10000
```
- [ ] All invariants hold
- [ ] No state corruption detected

#### Step 1.4: Run Security-Specific Tests
```bash
# Run exploit tests
forge test --match-path test/SecurityExploits.t.sol -vvv

# Run state machine tests
forge test --match-path test/StateMachinePermutations.t.sol -vvv

# Run deadlock verification
forge test --match-path test/NoDeadEndsVerification.t.sol -vvv
```
- [ ] All security tests pass
- [ ] No reentrancy vulnerabilities
- [ ] No access control bypasses

#### Step 1.5: Generate Test Report
```bash
# Generate coverage report
forge coverage --report lcov

# Generate summary
forge test --summary > test-results.txt
```
- [ ] Coverage meets minimum threshold (>80%)
- [ ] Test results saved for audit trail

### Sign-Off Criteria
- [ ] 0 test failures
- [ ] 0 fuzz failures across 10,000 runs
- [ ] Coverage report generated
- [ ] Results documented in `docs/TEST_RESULTS.md`

---

## 2. Gas Costs Documented and Acceptable

### Prerequisites
- [ ] Foundry gas reporter enabled
- [ ] CoinMarketCap API key configured (optional, for USD costs)

### Execution Steps

#### Step 2.1: Generate Gas Report
```bash
# Run tests with gas reporting
forge test --gas-report > gas-report.txt

# For detailed breakdown
forge test --gas-report --json > gas-report.json
```

#### Step 2.2: Benchmark Critical Functions

| Contract | Function | Expected Gas | Acceptable Max |
|----------|----------|--------------|----------------|
| ILRM | initiateBreachDispute | ~150,000 | 300,000 |
| ILRM | acceptProposal | ~100,000 | 200,000 |
| ILRM | counterPropose | ~120,000 | 250,000 |
| ILRM | enforceTimeout | ~80,000 | 150,000 |
| Treasury | distributeSubsidy | ~60,000 | 120,000 |
| L3Bridge | bridgeDisputeToL3 | ~200,000 | 400,000 |
| L3Bridge | commitFraudProof | ~100,000 | 200,000 |
| L3Bridge | revealFraudProof | ~150,000 | 300,000 |
| Oracle | submitLLMProposal | ~80,000 | 150,000 |

```bash
# Benchmark specific functions
forge test --match-test testGas -vvv --gas-report
```

#### Step 2.3: Calculate USD Costs
```bash
# Set gas price assumptions (update for current market)
# Ethereum L1: ~30 gwei average
# Optimism L2: ~0.001 gwei average
# ETH price: $3,500 (update as needed)

# L1 cost formula: gas * 30 gwei * $3,500 / 1e18
# L2 cost formula: gas * 0.001 gwei * $3,500 / 1e18
```

#### Step 2.4: Document Costs

Create/update `docs/GAS_COSTS.md`:
```markdown
# Gas Costs Analysis

## Summary
- Average dispute lifecycle (L2): ~$X.XX
- Worst case dispute (L2): ~$X.XX
- L3 bridge operation: ~$X.XX

## Detailed Breakdown
[Include full gas report]
```

#### Step 2.5: Optimize if Needed
- [ ] Review any functions exceeding acceptable max
- [ ] Consider optimizations for high-frequency operations
- [ ] Document any trade-offs made

### Sign-Off Criteria
- [ ] All critical functions within acceptable gas limits
- [ ] USD cost estimates documented
- [ ] `docs/GAS_COSTS.md` created and reviewed
- [ ] No functions exceed block gas limit risk

---

## 3. Multi-Sig Configured and Tested

### Prerequisites
- [ ] Gnosis Safe deployed on target network
- [ ] Minimum 3 signers identified
- [ ] Hardware wallets prepared for signers

### Execution Steps

#### Step 3.1: Deploy Gnosis Safe Multi-Sig

**Option A: Via Gnosis Safe UI**
1. Go to https://app.safe.global/
2. Connect wallet
3. Create new Safe
4. Configure:
   - Network: Optimism (or target network)
   - Owners: [List all signer addresses]
   - Threshold: 2-of-3 minimum (recommend 3-of-5 for mainnet)

**Option B: Via Script**
```bash
# Update .env with signer addresses
MULTISIG_OWNERS=0x...,0x...,0x...
MULTISIG_THRESHOLD=2

# Deploy
npx hardhat run scripts/deploy-multisig.ts --network optimism
```

#### Step 3.2: Transfer Contract Ownership

```bash
# Deploy governance with multi-sig as owner
MULTISIG_ADDRESS=0x... npx hardhat run scripts/deploy-governance.ts --network optimism
```

Contracts to transfer:
- [ ] ILRM
- [ ] Treasury
- [ ] Oracle
- [ ] AssetRegistry
- [ ] L3Bridge
- [ ] GovernanceTimelock (set as executor)

#### Step 3.3: Configure GovernanceTimelock

```solidity
// Verify timelock settings
MIN_DELAY = 2 days       // Standard operations
EMERGENCY_DELAY = 12 hours  // Emergency operations
```

- [ ] Timelock deployed with correct delays
- [ ] Multi-sig set as proposer
- [ ] Multi-sig set as executor
- [ ] Multi-sig set as admin

#### Step 3.4: Test Multi-Sig Operations

**Test 1: Standard Parameter Change**
```
1. Propose: Update STAKE_WINDOW from 3 days to 4 days
2. Wait: 2-day timelock
3. Execute: With 2-of-3 signatures
4. Verify: Parameter updated on-chain
```
- [ ] Proposal created successfully
- [ ] Timelock delay enforced
- [ ] Multi-sig signatures collected
- [ ] Execution successful

**Test 2: Emergency Pause**
```
1. Propose: Pause ILRM contract
2. Wait: 12-hour emergency timelock
3. Execute: With 2-of-3 signatures
4. Verify: Contract paused
5. Unpause: Repeat process to unpause
```
- [ ] Emergency pause executed
- [ ] 12-hour delay enforced
- [ ] Unpause successful

**Test 3: Ownership Transfer**
```
1. Propose: Transfer Treasury ownership to new address
2. Wait: 2-day timelock
3. Execute: With 2-of-3 signatures
4. Accept: New owner accepts (Ownable2Step)
```
- [ ] Two-step ownership transfer works
- [ ] Old owner cannot execute after transfer

**Test 4: Signature Threshold**
```
1. Attempt execution with 1-of-3 signatures
2. Verify: Transaction rejected
3. Add second signature
4. Verify: Transaction succeeds
```
- [ ] Threshold enforced correctly
- [ ] Insufficient signatures rejected

#### Step 3.5: Document Multi-Sig Configuration

Create/update `docs/MULTISIG_CONFIG.md`:
```markdown
# Multi-Sig Configuration

## Safe Address
- Network: Optimism
- Address: 0x...
- Threshold: 2-of-3

## Owners
| Role | Address | Hardware Wallet |
|------|---------|-----------------|
| Lead Dev | 0x... | Ledger |
| Security | 0x... | Trezor |
| Operations | 0x... | Ledger |

## Timelock Settings
- Standard delay: 2 days
- Emergency delay: 12 hours

## Test Results
- [x] Standard operation tested on [date]
- [x] Emergency pause tested on [date]
- [x] Threshold enforcement verified
```

### Sign-Off Criteria
- [ ] Gnosis Safe deployed and verified
- [ ] All core contracts owned by multi-sig
- [ ] GovernanceTimelock configured correctly
- [ ] Standard operation tested successfully
- [ ] Emergency pause tested successfully
- [ ] Threshold enforcement verified
- [ ] All signers have tested their keys
- [ ] `docs/MULTISIG_CONFIG.md` documented

---

## Final Sign-Off

Before mainnet deployment, ensure all sections are complete:

| Section | Status | Signed By | Date |
|---------|--------|-----------|------|
| Full Test Suite | ⬜ | | |
| Gas Costs Documented | ⬜ | | |
| Multi-Sig Configured | ⬜ | | |

**Deployment Authorization:**

```
I confirm that all sign-off procedures have been completed
and the protocol is ready for mainnet deployment.

Signature: _________________________
Name: _________________________
Role: _________________________
Date: _________________________
```

---

*This document should be reviewed and signed by at least two team members before mainnet deployment.*
