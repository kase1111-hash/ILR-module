# Multi-Sig Configuration Guide

**Software Version:** 0.1.0-alpha
**Last Updated:** [PENDING]
**Status:** Template - Complete after deployment

---

## Overview

The NatLangChain ILRM Protocol uses a multi-signature wallet (Gnosis Safe) combined with a GovernanceTimelock contract for secure protocol administration.

### Architecture

```
                    ┌─────────────────┐
                    │   Multi-Sig     │
                    │  (Gnosis Safe)  │
                    │   2-of-3 min    │
                    └────────┬────────┘
                             │
                             ▼
                    ┌─────────────────┐
                    │  Governance     │
                    │   Timelock      │
                    │ (2-day delay)   │
                    └────────┬────────┘
                             │
            ┌────────────────┼────────────────┐
            ▼                ▼                ▼
     ┌──────────┐     ┌──────────┐     ┌──────────┐
     │   ILRM   │     │ Treasury │     │  Oracle  │
     └──────────┘     └──────────┘     └──────────┘
            │                │                │
            └────────────────┴────────────────┘
                             │
                    ┌────────┴────────┐
                    │ Other Protocol  │
                    │   Contracts     │
                    └─────────────────┘
```

---

## Gnosis Safe Configuration

### Deployment

| Field | Value | Notes |
|-------|-------|-------|
| Network | ⬜ | e.g., Optimism |
| Safe Address | ⬜ | |
| Threshold | ⬜ / ⬜ | Recommended: 2-of-3 or 3-of-5 |
| Creation Date | ⬜ | |
| Creation Tx | ⬜ | |

### Owners

| # | Role | Address | Hardware Wallet | Backup |
|---|------|---------|-----------------|--------|
| 1 | ⬜ | ⬜ | ⬜ | ⬜ |
| 2 | ⬜ | ⬜ | ⬜ | ⬜ |
| 3 | ⬜ | ⬜ | ⬜ | ⬜ |
| 4 | ⬜ | ⬜ | ⬜ | ⬜ |
| 5 | ⬜ | ⬜ | ⬜ | ⬜ |

### Recommended Threshold Matrix

| Total Signers | Min Threshold | Recommended | Max Safe |
|---------------|---------------|-------------|----------|
| 3 | 2 | 2 | 2 |
| 4 | 2 | 3 | 3 |
| 5 | 3 | 3 | 4 |
| 7 | 4 | 4 | 5 |

---

## GovernanceTimelock Configuration

### Deployment

| Field | Value |
|-------|-------|
| Network | ⬜ |
| Timelock Address | ⬜ |
| Deployment Tx | ⬜ |
| Deployment Date | ⬜ |

### Delay Settings

| Delay Type | Duration | Use Case |
|------------|----------|----------|
| Standard (minDelay) | 2 days | Parameter changes, upgrades |
| Emergency | 12 hours | Security fixes, pause/unpause |
| Long | 4 days | Major governance changes |

### Roles Granted

| Role | Address | Purpose |
|------|---------|---------|
| PROPOSER_ROLE | Multi-sig | Can schedule operations |
| EXECUTOR_ROLE | Open (anyone) | Can execute after delay |
| CANCELLER_ROLE | Multi-sig | Can cancel pending ops |
| EMERGENCY_ROLE | Multi-sig | Can use emergency delay |
| DEFAULT_ADMIN_ROLE | Renounced | No admin after setup |

---

## Registered Protocol Contracts

| Contract | Address | Owned by Timelock |
|----------|---------|-------------------|
| ILRM | ⬜ | ⬜ |
| MultiPartyILRM | ⬜ | ⬜ |
| Treasury | ⬜ | ⬜ |
| Oracle | ⬜ | ⬜ |
| AssetRegistry | ⬜ | ⬜ |
| L3Bridge | ⬜ | ⬜ |
| L3StateVerifier | ⬜ | ⬜ |
| L3DisputeBatcher | ⬜ | ⬜ |
| DIDRegistry | ⬜ | ⬜ |
| IdentityVerifier | ⬜ | ⬜ |
| FIDOVerifier | ⬜ | ⬜ |
| ComplianceEscrow | ⬜ | ⬜ |
| ComplianceCouncil | ⬜ | ⬜ |
| BatchQueue | ⬜ | ⬜ |
| DummyTransactionGenerator | ⬜ | ⬜ |

---

## Setup Procedure

### Step 1: Deploy Gnosis Safe

1. Go to https://app.safe.global/
2. Click "Create new Safe"
3. Select target network
4. Add owner addresses
5. Set threshold (recommend 2-of-3 minimum)
6. Review and deploy
7. Record Safe address

### Step 2: Configure Environment

```bash
# .env file
MULTISIG_ADDRESS=0x...  # Gnosis Safe address

# Protocol contract addresses (from initial deployment)
ILRM_ADDRESS=0x...
TREASURY_ADDRESS=0x...
ORACLE_ADDRESS=0x...
ASSET_REGISTRY_ADDRESS=0x...
```

### Step 3: Deploy GovernanceTimelock

```bash
npx hardhat run scripts/deploy-governance.ts --network optimism
```

This will:
- Deploy GovernanceTimelock
- Configure delays (2-day standard, 12-hour emergency, 4-day long)
- Register protocol contracts
- Grant roles to multi-sig

### Step 4: Transfer Ownership

For each protocol contract:

```bash
# From deployer wallet, initiate transfer
npx hardhat run scripts/transfer-ownership.ts --network optimism
```

Then via multi-sig proposal:
1. Create proposal to call `acceptOwnership()` on timelock
2. Wait for timelock delay
3. Execute proposal

### Step 5: Verify Configuration

```bash
npx hardhat run scripts/verify-governance.ts --network optimism
```

### Step 6: Renounce Admin Role

After all ownership transfers are complete:

```solidity
// Via multi-sig proposal
timelock.renounceRole(DEFAULT_ADMIN_ROLE, deployerAddress);
```

---

## Operation Procedures

### Standard Parameter Change

1. **Prepare calldata**
   ```solidity
   bytes memory data = abi.encodeWithSignature(
       "updateParameter(uint256)",
       newValue
   );
   ```

2. **Schedule via multi-sig**
   - Create Safe transaction calling `timelock.schedule(...)`
   - Collect required signatures
   - Execute Safe transaction

3. **Wait for delay**
   - Standard: 2 days
   - Emergency: 12 hours
   - Long: 4 days

4. **Execute operation**
   - Anyone can call `timelock.execute(...)` after delay
   - Or execute via multi-sig for extra security

### Emergency Pause

1. **Create pause calldata**
   ```solidity
   bytes memory data = abi.encodeWithSignature("pause()");
   ```

2. **Schedule with emergency delay**
   - Use `scheduleEmergency(...)` function
   - 12-hour delay applies

3. **Execute after delay**
   - Call `execute(...)` to pause contract

### Cancel Pending Operation

```solidity
// Via multi-sig
timelock.cancel(operationId);
```

---

## Testing Checklist

### Pre-Deployment Tests (Testnet)

- [ ] Safe created with correct threshold
- [ ] All signers can sign transactions
- [ ] Timelock deployed correctly
- [ ] Delays configured correctly
- [ ] Roles granted correctly

### Ownership Transfer Tests

- [ ] Each contract ownership transferred
- [ ] Timelock can execute owner functions
- [ ] Old owner cannot execute owner functions

### Operation Tests

| Test | Status | Tx Hash | Date |
|------|--------|---------|------|
| Schedule standard operation | ⬜ | | |
| Wait 2-day delay | ⬜ | | |
| Execute standard operation | ⬜ | | |
| Schedule emergency operation | ⬜ | | |
| Wait 12-hour delay | ⬜ | | |
| Execute emergency pause | ⬜ | | |
| Execute emergency unpause | ⬜ | | |
| Cancel pending operation | ⬜ | | |
| Attempt with insufficient signatures | ⬜ | | |
| Attempt early execution (should fail) | ⬜ | | |

### Security Tests

- [ ] Cannot execute before delay
- [ ] Cannot execute without proper scheduling
- [ ] Cannot modify threshold without multi-sig
- [ ] Cannot add/remove owners without multi-sig
- [ ] Admin role properly renounced

---

## Emergency Procedures

### If Multi-Sig Key Compromised

1. **Immediately** schedule ownership transfer to backup multi-sig
2. Use emergency delay (12 hours)
3. Remove compromised signer from new Safe
4. Complete ownership transfer
5. Post-incident review

### If Timelock Has Bug

1. Use multi-sig to pause protocol contracts directly (if possible)
2. Deploy new timelock
3. Transfer ownership to new timelock
4. Document incident

### Recovery Keys

| Purpose | Location | Access |
|---------|----------|--------|
| Signer 1 Recovery | ⬜ | ⬜ |
| Signer 2 Recovery | ⬜ | ⬜ |
| Signer 3 Recovery | ⬜ | ⬜ |
| Master Recovery | ⬜ | ⬜ |

---

## Audit Trail

### Configuration Changes

| Date | Change | Proposer | Tx Hash |
|------|--------|----------|---------|
| | Initial setup | | |

### Ownership Transfers

| Date | Contract | From | To | Tx Hash |
|------|----------|------|-----|---------|
| | | | | |

---

## Sign-Off

### Configuration Verified By

| Role | Name | Signature | Date |
|------|------|-----------|------|
| Lead Developer | | | |
| Security Reviewer | | | |
| Operations Lead | | | |

### Testing Completed By

| Role | Name | Signature | Date |
|------|------|-----------|------|
| QA Lead | | | |
| DevOps | | | |

---

*This document should be updated after each configuration change.*
*Last reviewed: [PENDING]*
