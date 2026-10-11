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

| Delay Type | Duration | Applies To |
|------------|----------|------------|
| Standard (minDelay) | 2 days | Default for every call not listed below |
| Long (longDelay) | 4 days | Ownership/role/upgrade/multicall selectors (`transferOwnership`, `renounceOwnership`, `grantRole`, `revokeRole`, `renounceRole`, `beginDefaultAdminTransfer`, `upgradeTo`, `upgradeToAndCall`, `upgradeAndCall`, `upgrade`, `changeAdmin`, `changeProxyAdmin`, `multicall`), **any call whose target is the timelock itself**, and every (target, selector) pair registered as `LongDelay` |
| Emergency (emergencyDelay) | 12 hours | Only `EMERGENCY_ROLE` via `executeEmergency`, and only for single, zero-value calls whose (target, selector) governance registered as `Emergency` (default-deny) |

The required delay is derived from what the call does, on every scheduling path (including the
inherited OpenZeppelin `schedule`/`scheduleBatch`, which revert with `TimelockInsufficientDelay`
below the requirement). The `OperationType` label of `scheduleOperation`/`scheduleBatch` can only
lengthen the delay (`ContractUpgrade` and `OwnershipTransfer` floor at the long delay);
`EmergencyAction` is reserved for `executeEmergency`. Use `getRequiredDelay(target, data)` to read
the floor for a call and `getCallClass(target, selector)` to read its effective class.

Delay bounds: `1h <= minDelay <= 30d`, `15m <= emergencyDelay <= minDelay`,
`minDelay <= longDelay <= 60d`. Changing delays never alters operations that are already scheduled.

#### Call Policy

`scripts/deploy-governance.ts` registers the protocol call policy while the deployer still holds
`DEFAULT_ADMIN_ROLE` (`setCallClass`). After the admin role is renounced, every `setCallClass`
change is a timelock self-call and therefore needs the long delay.

| Class | Contract | Function |
|-------|----------|----------|
| LongDelay | Oracle | `setILRM(address)` |
| LongDelay | Treasury | `setILRM(address)`, `emergencyWithdraw(address,uint256)`, `emergencyWithdrawETH(address,uint256)` |
| LongDelay | ILRM | `withdrawTreasury(address,uint256)` |
| LongDelay | AssetRegistry | `authorizeILRM(address)` |
| LongDelay | ComplianceCouncil (if deployed) | `setGovernanceTimelock(address)` |
| Emergency | Oracle | `revokeOracle(address)`, `cancelPendingRequest(uint256)` |
| Emergency | AssetRegistry | `revokeILRM(address)` |

### Roles Granted

| Role | Address | Purpose |
|------|---------|---------|
| PROPOSER_ROLE | Multi-sig | Can schedule operations |
| EXECUTOR_ROLE | Open (anyone) | Can execute after delay |
| CANCELLER_ROLE | Multi-sig | Can cancel pending ops |
| EMERGENCY_ROLE | Multi-sig (explicit grant; the deployer does not receive it) | `emergencyPauseAll`/`emergencyUnpauseAll`; queue Emergency-classified calls via `executeEmergency` (not a proposer) |
| DEFAULT_ADMIN_ROLE | Renounced | No admin after setup (afterwards only long-delay timelock self-operations) |

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
- Configure the call policy (LongDelay / Emergency classes, see above)
- Grant roles to multi-sig

### Step 4: Transfer Ownership

For each protocol contract:

```bash
# From deployer wallet, initiate transfer
npx hardhat run scripts/transfer-ownership.ts --network optimism
```

Then accept ownership for the timelock, either:
- **Bootstrap admin (before renouncing):** the deployer calls
  `timelock.acceptContractOwnership(contractAddress)`, or
- **Multi-sig proposal:** schedule a call with target = the protocol contract and
  data = `acceptOwnership()` at the standard delay, wait, then execute it.

Any proposal whose target is the timelock itself needs the long delay.

### Step 5: Verify Configuration

```bash
npx hardhat run scripts/verify-governance.ts --network optimism
```

### Step 6: Renounce Admin Role

After all ownership transfers are complete, the deployer itself sends (OpenZeppelin's
`renounceRole` only accepts the caller's own address, so this cannot be done by proposal):

```solidity
// Sent by the deployer (bootstrap admin)
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
   - Create Safe transaction calling `timelock.schedule(...)` with
     `delay >= timelock.getRequiredDelay(target, data)`
   - Collect required signatures
   - Execute Safe transaction

3. **Wait for delay**
   - Standard: 2 days
   - Long: 4 days (ownership/role/upgrade/multicall calls, timelock self-calls, LongDelay pairs)

4. **Execute operation**
   - Anyone can call `timelock.execute(...)` after delay
   - Or execute via multi-sig for extra security

### Emergency Pause

For contracts registered with the timelock, `EMERGENCY_ROLE` pauses instantly:

```solidity
timelock.emergencyPauseAll("reason");
```

### Emergency Defensive Call

For calls governance registered as `Emergency` (for example `AssetRegistry.revokeILRM`):

1. **Queue with the emergency delay** (`EMERGENCY_ROLE`, no `PROPOSER_ROLE` needed)
   ```solidity
   bytes memory data = abi.encodeWithSignature("revokeILRM(address)", compromisedIlrm);
   bytes32 id = timelock.executeEmergency(assetRegistry, data, "reason");
   ```
   `executeEmergency` only **schedules** the call (value 0, predecessor 0) at the 12-hour emergency
   delay; it reverts with `NotEmergencyCall` for anything not classified Emergency.

2. **Veto window**
   - `CANCELLER_ROLE` can cancel it with `timelock.cancel(id)` / `cancelOperation(id)` during the delay

3. **Execute after delay**
   - Read the salt via `timelock.getOperation(id).salt` (or the `CallSalt` event)
   - Call `timelock.execute(assetRegistry, 0, data, bytes32(0), salt)`

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
| Queue emergency call (`executeEmergency`) | ⬜ | | |
| Wait 12-hour delay | ⬜ | | |
| Execute emergency call | ⬜ | | |
| Execute emergency pause (`emergencyPauseAll`) | ⬜ | | |
| Execute emergency unpause (`emergencyUnpauseAll`) | ⬜ | | |
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

There is no emergency ownership transfer: ownership and role changes always need the long delay.

1. **Immediately** call `timelock.emergencyPauseAll(reason)` (EMERGENCY_ROLE)
2. Cancel any hostile pending operations with `CANCELLER_ROLE` (`timelock.cancel(id)`)
3. Rotate the compromised signer out of the Safe (Safe owner management)
4. If a migration to a new Safe or timelock is needed, schedule the role/ownership changes at the
   long delay (4 days) and keep watching for hostile operations to cancel
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
