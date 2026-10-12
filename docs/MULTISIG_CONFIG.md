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
| Emergency (emergencyDelay) | 12 hours | Only `EMERGENCY_ROLE` via `executeEmergency`, and only for single, zero-value calls whose (target, selector) governance registered as `Emergency` (default-deny). `unpause()` can never be registered `Emergency` |

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
| LongDelay | ILRM | `withdrawTreasury(address,uint256)`, `setSubsidyTreasury(address)`, `setInitiatorIncentiveCaps(uint256,uint256,uint256)` |
| LongDelay | AssetRegistry | `authorizeILRM(address)` |
| LongDelay | ComplianceCouncil (if deployed) | `setGovernanceTimelock(address)`, `setComplianceEscrow(address)`, `setAuthorizedRequester(address,bool)`, `removeMember(address)` |
| LongDelay | MultiPartyILRM (if deployed) | `withdrawTreasury(address,uint256)` |
| LongDelay | DummyTransactionGenerator (if deployed) | `withdrawTreasury(address,uint256)`, `setTargetContracts(address,address)`, `setKeeper(address)` |
| LongDelay | BatchQueue (if deployed) | `emergencyWithdraw(address,uint256,bool)`, `setRelayEnabled(bool)` |
| Emergency | Oracle | `revokeOracle(address)`, `cancelPendingRequest(uint256)`, `resetProposalExact(uint256,uint256,bytes32,string)` |
| Emergency | AssetRegistry | `revokeILRM(address)` |

Everything else stays Standard (minDelay), including parameter setters, `pause()`/`unpause()` and
`Oracle.registerOracle`/`updateOracleKey`/`resetProposal`. `Treasury.fundStakeSubsidy` is
`onlyILRM` and never called by the timelock, so it needs no class.

Module wiring and module access control get the long delay, like the wiring of the core contracts:

- **Wiring:** `ComplianceCouncil.setGovernanceTimelock`/`setComplianceEscrow`, and
  `DummyTransactionGenerator.setTargetContracts(address,address)`, which repoints the ILRM and
  BatchQueue the generator sends its dummy transactions to.
- **Access control:** `ComplianceCouncil.setAuthorizedRequester(address,bool)` decides who may request
  compliance warrants, and `ComplianceCouncil.removeMember(address)` evicts a council member (and voids
  the partial signatures it already submitted), changing who can reach the signing threshold.
  `DummyTransactionGenerator.setKeeper(address)` decides who may trigger (and spend treasury ETH on)
  dummy generation, and `BatchQueue.setRelayEnabled(bool)` turns on relaying of queued users' actions
  (relaying ships disabled; see docs/KNOWN_LIMITATIONS.md).

These module entries are **optional**: a module is classified only when its address is configured
(`COMPLIANCE_COUNCIL_ADDRESS`, `DUMMY_GENERATOR_ADDRESS`, ...), and an entry that no longer resolves
in the build prints a warning instead of aborting the deployment. Classify a module deployed after
the timelock through a (long-delay) `setCallClass` self-operation.

Entries name contracts by fully qualified artifact name (`contracts/ILRM.sol:ILRM`), so a second
contract with the same name cannot make a lookup ambiguous. If a required (core LongDelay) selector
cannot be resolved, the script aborts before deploying anything; an optional one (modules and every
Emergency entry) prints a warning and is skipped. Check the policy against the current build at any
time (no deployment; `test/GovernanceCallPolicy.test.js` runs the same check in CI):

```bash
GOVERNANCE_POLICY_CHECK=1 npx hardhat run scripts/deploy-governance.ts
```

### Roles Granted

| Role | Address | Purpose |
|------|---------|---------|
| PROPOSER_ROLE | Multi-sig | Can schedule operations |
| EXECUTOR_ROLE | Open (anyone) | Can execute after delay. Never left without a live holder: closing open execution (`setOpenExecutor(false)`), `revokeRole` and `renounceRole` revert with `LastExecutor` if no other holder would remain. The timelock's own EXECUTOR_ROLE does not count (it cannot initiate an execution), so granting it never lets the last live executor go |
| CANCELLER_ROLE | Multi-sig | Can cancel pending ops, including everything `EMERGENCY_ROLE` queues |
| EMERGENCY_ROLE | Multi-sig (explicit grant; the deployer does not receive it) | `emergencyPauseAll` (instant); `emergencyUnpauseAll` (only queues the unpause, at minDelay); queue Emergency-classified calls via `executeEmergency` (not a proposer) |
| DEFAULT_ADMIN_ROLE | Renounced | No admin after setup (afterwards only long-delay timelock self-operations) |

---

## Registered Protocol Contracts

> ⚠️ **The L3 contracts (L3Bridge, L3StateVerifier, L3DisputeBatcher) are not production-ready and
> must not be deployed** (see [SPEC.md 4.3](../SPEC.md#43-l3app-specific-rollups-natlangchain-roadmapmd)
> and the contract table in the [README](../README.md)). No deploy script deploys them,
> `scripts/deploy-governance.ts` neither registers nor classifies them, and they must never be
> registered with the timelock or handed to it.

| Contract | Address | Owned by Timelock |
|----------|---------|-------------------|
| ILRM | ⬜ | ⬜ |
| MultiPartyILRM | ⬜ | ⬜ |
| Treasury | ⬜ | ⬜ |
| Oracle | ⬜ | ⬜ |
| AssetRegistry | ⬜ | ⬜ |
| L3Bridge | Must not be deployed | - |
| L3StateVerifier | Must not be deployed | - |
| L3DisputeBatcher | Must not be deployed | - |
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

# Optional modules (registered and classified only when set)
MULTI_PARTY_ILRM_ADDRESS=0x...
COMPLIANCE_COUNCIL_ADDRESS=0x...
BATCH_QUEUE_ADDRESS=0x...
DUMMY_GENERATOR_ADDRESS=0x...
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

### Emergency Pause and Unpause

Pausing is instant; unpausing always waits and can be vetoed.

For contracts registered with the timelock, `EMERGENCY_ROLE` pauses instantly:

```solidity
timelock.emergencyPauseAll("reason");
```

Each `emergencyPauseAll` starts a new pause epoch (`timelock.pauseEpoch()`).

To unpause, `EMERGENCY_ROLE` **queues** the unpause; it does not take effect immediately:

1. `bytes32 id = timelock.emergencyUnpauseAll();` queues the call `emergencyUnpauseAll()` on the
   timelock itself at **minDelay** (2 days), with a salt from the reserved emergency namespace. It
   emits `EmergencyActionScheduled(id, guardian, timelock, salt, readyAt, reason)`.
2. During the delay, `CANCELLER_ROLE` can veto it with `timelock.cancel(id)`.
3. After the delay, any executor runs
   `timelock.execute(timelock, 0, abi.encodeCall(IGovernanceTimelock.emergencyUnpauseAll, ()), bytes32(0), salt)`
   (salt from `getOperation(id).salt` or the event). The timelock then calls itself and unpauses every
   registered contract (`EmergencyActionExecuted` with reason `"Emergency unpause all"`).

Every operation that unpauses (`unpause()` on any target, or `emergencyUnpauseAll` on the timelock,
whether a guardian or a proposer queued it) is bound to the pause epoch it was scheduled in. A later
`emergencyPauseAll` makes it unexecutable (`StaleUnpause`), so an unpause queued before a pause can
never undo it. Queue a new one once the new incident is resolved, and cancel the stale one to clean up.

OpenZeppelin's own views (`isOperationReady`, `getOperationState`) keep reporting a stale unpause
pending, and ready once its delay passed, until it is cancelled. The governance views report it:
`isOperationStale(id)` is true (for raw `schedule` operations too), `getOperation(id).status` is
`Stale` (5), and `getPendingOperations`/`getPendingOperationsCount` leave it out.
`getStaleOperations()` lists the stale operations that carry metadata, which are the ones to cancel.

Governance can also unpause through ordinary proposals: `unpause()` on a contract (Standard,
minDelay) or `emergencyUnpauseAll()` on the timelock (self-call, longDelay).

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
| Queue emergency unpause (`emergencyUnpauseAll`) | ⬜ | | |
| Wait 2-day delay, execute the queued unpause | ⬜ | | |
| Re-pause, confirm an earlier queued unpause reverts (`StaleUnpause`) | ⬜ | | |
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

### If a Guardian (EMERGENCY_ROLE Holder) Is Rogue or Compromised

A guardian can only pause (reversible) and queue operations that cancellers can veto. It cannot
unpause instantly, and nothing it queues runs before its delay.

1. Watch `EmergencyActionScheduled` events and cancel every operation the guardian queues
   (`timelock.cancel(id)`, `CANCELLER_ROLE`)
2. Schedule `revokeRole(EMERGENCY_ROLE, guardian)` on the timelock: it is a self-call, so it needs the
   long delay (4 days). Until it executes, the guardian can keep re-pausing the protocol and can
   invalidate queued unpauses by pausing again (a liveness attack, see Residual Design Limits)
3. After the revocation executes, unpause through a fresh `emergencyUnpauseAll` or a proposal

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

## Residual Design Limits

The call policy and the emergency path have limits that configuration and operations have to cover.

**Per-selector classification**
- Delay classes attach to a (target, selector) pair, not to arguments. An Emergency-classified
  selector can be queued by a guardian with any arguments (`revokeOracle(anyOracle)`), and a
  LongDelay selector needs the long delay even for a harmless argument (for example
  `setSubsidyTreasury(address(0))`, which only disables subsidies).
- Only the 13 locked ownership/role/upgrade/multicall selectors and calls to the timelock itself are
  forced to LongDelay. A privileged function reachable through any other selector (other ownership
  helpers, overloads, a generic `execute(bytes)` or batching entry point, a proxy fallback) is
  Standard until governance classifies it.
- Classes follow addresses: a redeployed contract at a new address starts unclassified, and a proxy
  keeps its classes when its implementation changes (re-check them after every upgrade).
- Pause epochs only recognise `unpause()` and the timelock's `emergencyUnpauseAll()`. A contract with
  a differently named unpause function (for example `setPaused(false)`) is not covered: classify it
  LongDelay and cancel stale proposals by hand. Only `emergencyPauseAll` starts a new epoch; pausing
  a single contract through a proposal or `executeEmergency` does not.
- OpenZeppelin operations never expire: anything that matured stays executable until it runs or is
  cancelled. Cancel every pending or ready operation that is no longer wanted, especially after an
  incident.

**Guardian revocation path**
- `EMERGENCY_ROLE` is revoked with `revokeRole`, a timelock self-call that needs the long delay once
  the bootstrap admin has renounced. There is no fast path: until the revocation executes, a rogue
  guardian can keep the protocol paused (pausing is instant and repeatable), invalidate honest
  unpauses by pausing again, and spam operations that cancellers must cancel one by one. It cannot
  unpause, move funds or change roles.
- Keep the guardian set small, make each guardian a Safe rather than a single key, and have the
  cancellers monitor `EmergencyActionScheduled`. A guardian can step down at once with
  `renounceRole(EMERGENCY_ROLE, self)`.

**Metadata and execution**
- `getOperation` metadata exists only for operations scheduled through `scheduleOperation`,
  `scheduleBatch` (7 arguments), `scheduleLongDelay`, `executeEmergency` and `emergencyUnpauseAll`.
  Raw OZ `schedule`/`scheduleBatch` operations return an empty record (status None), also when the id
  was tracked by an earlier, cancelled scheduling; use `getOperationState` for them. A batch record
  shows only its first call.
- A stale unpause stays in OpenZeppelin's queue (pending, then ready) until a canceller cancels it;
  only the governance views (`isOperationStale`, status `Stale`, `getStaleOperations`) mark it. Raw
  `schedule` operations carry no metadata, so only `isOperationStale(id)` reports them.
- `EXECUTOR_ROLE` always keeps at least one holder other than the timelock itself, but the timelock
  cannot tell whether an explicit executor can still act (a lost key, a dead contract). With closed
  execution, keep at least two live executors.

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
