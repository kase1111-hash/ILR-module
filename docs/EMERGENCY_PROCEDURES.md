# Emergency Procedures & Incident Response

**Software Version:** 0.1.0-alpha
**Protocol Specification:** v1.5
**Last Updated:** January 2026
**Classification:** Internal Operations

---

## Table of Contents

1. [Emergency Contacts](#emergency-contacts)
2. [Severity Classification](#severity-classification)
3. [Incident Response Flow](#incident-response-flow)
4. [Emergency Actions](#emergency-actions)
5. [Recovery Procedures](#recovery-procedures)
6. [Post-Incident Process](#post-incident-process)

---

## Emergency Contacts

### On-Call Rotation

| Role | Primary | Backup | Contact |
|------|---------|--------|---------|
| Protocol Lead | TBD | TBD | [secure channel] |
| Smart Contract Lead | TBD | TBD | [secure channel] |
| Security Lead | TBD | TBD | [secure channel] |
| DevOps Lead | TBD | TBD | [secure channel] |

### Multi-sig Signers

| Signer | Availability | Hardware Wallet |
|--------|--------------|-----------------|
| Signer 1 | TBD | Ledger |
| Signer 2 | TBD | Ledger |
| Signer 3 | TBD | Trezor |

### External Contacts

| Service | Contact | Purpose |
|---------|---------|---------|
| Audit Firm | TBD | Security consultation |
| Legal Counsel | TBD | Regulatory issues |
| Insurance | TBD | Claims |

---

## Severity Classification

### SEV-1: Critical (Immediate Response)

**Definition:** Active exploitation, funds at risk, protocol unusable

**Examples:**
- Active exploit draining funds
- Critical vulnerability being exploited
- Oracle manipulation attack
- Complete protocol unavailability

**Response Time:** Immediate (< 15 minutes)
**Who to Contact:** All emergency contacts simultaneously

### SEV-2: High (Urgent Response)

**Definition:** Significant vulnerability discovered, potential for exploitation

**Examples:**
- Critical vulnerability reported (not yet exploited)
- Major functionality broken
- Governance attack attempted
- Significant gas griefing

**Response Time:** < 1 hour
**Who to Contact:** Protocol Lead + Security Lead

### SEV-3: Medium (Standard Response)

**Definition:** Non-critical issues requiring attention

**Examples:**
- Minor vulnerability discovered
- Non-critical functionality impacted
- Unusual activity patterns
- Frontend issues

**Response Time:** < 4 hours
**Who to Contact:** Protocol Lead

### SEV-4: Low (Scheduled Response)

**Definition:** Minor issues, improvements needed

**Examples:**
- Documentation gaps
- Minor UX issues
- Non-security bugs
- Performance optimization needed

**Response Time:** Next business day
**Who to Contact:** Standard issue tracking

---

## Incident Response Flow

### Phase 1: Detection & Triage (0-15 min)

```
1. DETECT
   └─ Alert received (monitoring, user report, security researcher)

2. ACKNOWLEDGE
   └─ On-call engineer confirms receipt

3. ASSESS SEVERITY
   └─ Quick triage: Is this SEV-1, 2, 3, or 4?

4. ESCALATE (if needed)
   └─ Page appropriate contacts based on severity
```

### Phase 2: Containment (15-60 min)

```
5. GATHER INFORMATION
   ├─ What contracts are affected?
   ├─ What functions are vulnerable?
   ├─ Is exploitation active?
   └─ What is the potential impact?

6. DECIDE ON ACTION
   ├─ Emergency pause?
   ├─ Parameter update?
   ├─ Wait and monitor?
   └─ Coordinate with affected parties?

7. EXECUTE CONTAINMENT
   └─ See "Emergency Actions" below
```

### Phase 3: Resolution (1-24 hours)

```
8. DEVELOP FIX
   ├─ Identify root cause
   ├─ Develop patch
   ├─ Test thoroughly
   └─ Get review from second engineer

9. DEPLOY FIX
   ├─ Via governance (if time permits)
   └─ Via emergency action (if urgent)

10. VERIFY RESOLUTION
    ├─ Confirm vulnerability mitigated
    ├─ Monitor for new issues
    └─ Check no side effects
```

### Phase 4: Recovery (24-72 hours)

```
11. RESTORE NORMAL OPERATIONS
    ├─ Unpause contracts (if paused; queued, executable after minDelay)
    ├─ Resume normal monitoring
    └─ Communicate resolution

12. POST-INCIDENT REVIEW
    ├─ Root cause analysis
    ├─ Timeline reconstruction
    └─ Process improvements
```

---

## Emergency Actions

### Action 1: Emergency Pause

**When to Use:** Active exploitation, critical vulnerability

**Who Can Execute:** Multi-sig with EMERGENCY_ROLE on the GovernanceTimelock

Once the timelock owns the protocol contracts, the multi-sig can no longer call `pause()` on them
directly (they are `onlyOwner`). Pausing goes through the timelock, which pauses every registered
pausable contract (ILRM, Treasury, MultiPartyILRM, ComplianceCouncil, BatchQueue,
DummyTransactionGenerator) in one instant call. AssetRegistry has no pause function.

Pausing is instant, unpausing is not: it is always queued and can be vetoed (see "Unpausing After
Incident"). Each `emergencyPauseAll` starts a new pause epoch (`timelock.pauseEpoch()`), which makes
every unpause queued before it unexecutable, so pausing again also invalidates pending unpauses.

**Steps:**

1. **Initiate Emergency Meeting**
   ```
   Alert all multi-sig signers immediately
   ```

2. **Prepare Transaction**
   ```solidity
   // Target: GovernanceTimelock
   timelock.emergencyPauseAll("short, non-sensitive reason");
   ```

3. **Execute via Multi-sig**
   - Go to Gnosis Safe
   - Create new transaction
   - Target: GovernanceTimelock address
   - Data: `emergencyPauseAll(string)` with the reason
   - Collect required signatures
   - Execute
   - Check the `ContractPauseResult` events (one per registered contract, with `success`)

4. **Confirm Pause**
   ```bash
   cast call $ILRM_ADDRESS "paused()" --rpc-url $RPC_URL
   # Should return: true
   ```

5. **Communicate**
   - Post status update on official channels
   - Do NOT disclose vulnerability details yet

### Action 2: Emergency Parameter Update

**When to Use:** Mitigate attack without full pause

Parameter changes are ordinary timelock proposals (standard delay, or the long delay for
LongDelay-classified calls). Only calls that governance pre-classified as `Emergency` can use the
short emergency delay, through `executeEmergency` (see "Emergency Defensive Calls" below).

**Example: Raise the Treasury minimum reserve**

```solidity
// A standard proposal by the multi-sig (PROPOSER_ROLE)
bytes memory data = abi.encodeWithSignature("setMinReserve(uint256)", newHigherAmount);
timelock.schedule(treasury, 0, data, bytes32(0), salt, timelock.getRequiredDelay(treasury, data));
```

### Emergency Defensive Calls (executeEmergency)

**When to Use:** A defensive call that cannot wait for the standard delay and that governance
registered as `Emergency` (default deployment: `Oracle.revokeOracle`, `Oracle.cancelPendingRequest`,
`Oracle.resetProposalExact`, `AssetRegistry.revokeILRM`). Check with
`timelock.getCallClass(target, selector)` (2 = Emergency).

**Who Can Execute:** EMERGENCY_ROLE (PROPOSER_ROLE is not needed)

**Steps:**

1. **Queue the call**
   ```solidity
   bytes32 id = timelock.executeEmergency(target, data, "reason");
   ```
   This only **schedules** the call (value 0, predecessor 0) at the emergency delay (12 hours by
   default) and emits `EmergencyActionScheduled`. `EmergencyActionExecuted` is only emitted when an
   action takes effect (a pause, or a queued unpause when it executes). Anything not classified
   Emergency reverts with `NotEmergencyCall`.

2. **Veto window** - during the emergency delay any `CANCELLER_ROLE` holder can stop it:
   ```solidity
   timelock.cancel(id);            // or timelock.cancelOperation(id)
   ```

3. **Execute after the delay**
   ```solidity
   bytes32 salt = timelock.getOperation(id).salt;   // also emitted as OZ CallSalt(id, salt)
   timelock.execute(target, 0, data, bytes32(0), salt);
   ```

### Action 3: Oracle Emergency

**When to Use:** Oracle manipulation detected

**Steps:**

When the Oracle is owned by the GovernanceTimelock (the production setup), its owner-only calls
go through the timelock: `revokeOracle` and `cancelPendingRequest` are Emergency-classified (emergency
path), while `resetProposalExact`, `resetProposal` and `registerOracle` are standard proposals by the
multi-sig unless governance has classified `resetProposalExact` as Emergency. If the oracle must be
stopped immediately, pause the protocol first (Action 1), but see step 4 before pausing ILRM.

1. **Revoke the compromised operator** (always before resetting, so it cannot fill the re-opened slot)
   ```solidity
   timelock.executeEmergency(oracle, abi.encodeWithSignature("revokeOracle(address)", compromisedOperator), "reason");
   ```

2. **Withdraw pending requests** (optional, Emergency-classified)
   ```solidity
   timelock.executeEmergency(oracle, abi.encodeWithSignature("cancelPendingRequest(uint256)", disputeId), "reason");
   ```
   This only withdraws the advisory pending-request flag (event `ProposalRequestCancelled`) that tells
   operators a proposal is wanted. It does **not** block `submitProposal`; revoking the operator
   (step 1) is what stops proposals.

3. **Void its live proposals**
   ```solidity
   // For each unresolved dispute whose CURRENT-round proposal came from the compromised operator.
   // round = Oracle.proposalContext(disputeId).round; proposalHash = Oracle.roundProposals(disputeId, round)
   bytes memory data = abi.encodeWithSignature(
       "resetProposalExact(uint256,uint256,bytes32,string)", disputeId, round, proposalHash, "compromised operator"
   );
   timelock.schedule(oracle, 0, data, bytes32(0), salt, timelock.getRequiredDelay(oracle, data));
   ```
   Use the pinned `resetProposalExact` behind the timelock: it voids only the named proposal of the
   named round. If a counter-proposal or another proposal landed while the call was queued, it reverts
   `ProposalMismatch` instead of voiding a proposal nobody reviewed. (`resetProposal(disputeId, reason)`
   acts on whatever is live when it executes.)

   When it executes, the reset:
   - voids the proposal text **and both acceptances in ILRM in the same transaction** (ILRM emits
     `ProposalVoided(disputeId, round, proposalHash)`). From then on `acceptProposal` reverts
     "No proposal yet", and so does `acceptProposalWithHash` with the old hash;
   - re-opens the current round's proposal slot for exactly one replacement and bumps the
     dispute's nonce, so every signature made before the reset is dead.

   It reverts with:
   - `NoProposalToReset` if the current round has no proposal (earlier rounds were already cleared
     by `counterPropose`);
   - `DisputeAlreadyResolved` for resolved disputes;
   - `ProposalMismatch` if the live round or proposal is not the pinned one;
   - `ResolutionDeadlinePassed` after the dispute's resolution deadline. No replacement could land
     then: let `enforceTimeout` resolve the dispute.

   Confirm the ILRM `ProposalVoided` log for every reset dispute.

4. **Warn the parties**

   The proposal stays acceptable only until the reset **executes** (the standard 2-day timelock delay,
   unless governance classified `resetProposalExact` as Emergency). Tell both parties not to accept it in
   the meantime: an acceptance mined before the reset stands only until the reset executes, when it is
   cleared, but if both parties accept first the dispute resolves on that proposal. Parties should
   accept only with `acceptProposalWithHash(disputeId, proposalHash)`, which reverts "Proposal changed"
   if the text they reviewed is no longer the live one.

   `counterPropose` is `whenNotPaused` while `acceptProposal` is not, so pausing ILRM removes the
   parties' own escape (a counter-proposal opens a new round and clears the proposal) without stopping
   acceptances. Recovery itself (the reset, the void in ILRM and the replacement) works while ILRM is
   paused.

5. **Register the new operator and submit the corrected proposal**
   ```solidity
   bytes memory data = abi.encodeWithSignature("registerOracle(address,bytes32)", newOperator, keyHash);
   timelock.schedule(oracle, 0, data, bytes32(0), salt, timelock.getRequiredDelay(oracle, data));
   Oracle.submitProposal(disputeId, correctedProposal, signature) // from newOperator
   ```
   The replacement is signed at the bumped nonce (`Oracle.proposalContext` / `Oracle.proposalDigest`).
   ILRM emits `ProposalSubmitted` (no `ProposalSuperseded`: the old proposal was already voided). If no
   replacement lands, the parties can still `counterPropose` (new round) or the dispute times out.

### Action 4: Governance Attack Response

**When to Use:** Malicious governance proposal detected

**Steps:**

1. **Cancel Proposal** (within timelock delay, CANCELLER_ROLE)
   ```solidity
   GovernanceTimelock.cancel(proposalId)            // or cancelOperation(proposalId)
   ```
   This also applies to operations queued through `executeEmergency` and `emergencyUnpauseAll`.
   A guardian that queues an unexpected unpause (`EmergencyActionScheduled` with the timelock as
   target) is a governance attack: cancel it and follow "If a Guardian (EMERGENCY_ROLE Holder) Is
   Rogue or Compromised" in `docs/MULTISIG_CONFIG.md`.

2. **If Past Cancellation Window:**
   - Emergency pause all contracts
   - Prepare mitigation for proposal effects
   - Coordinate community response

---

## Recovery Procedures

### Unpausing After Incident

**Prerequisites:**
- [ ] Root cause identified
- [ ] Fix deployed or workaround in place
- [ ] At least 24 hours since last suspicious activity
- [ ] Team consensus on safety

**Steps:**

1. **Final Safety Check**
   ```bash
   # Review recent transactions
   cast logs --from-block $PAUSE_BLOCK --to-block latest --address $ILRM_ADDRESS
   ```

2. **Queue the Unpause** (it does NOT take effect immediately)

   Unpausing through the timelock that owns the contracts is always queued, at the standard delay
   (minDelay, 2 days by default), and cancellers can veto it. Plan for that delay: the contracts stay
   paused until step 4.
   ```solidity
   // EMERGENCY_ROLE: queues the call emergencyUnpauseAll() on the timelock itself and returns its id.
   // Emits EmergencyActionScheduled(id, guardian, timelock, salt, readyAt, "Emergency unpause all").
   bytes32 id = timelock.emergencyUnpauseAll();
   ```
   Governance can queue an unpause through an ordinary proposal instead: `unpause()` on a contract
   (Standard, minDelay) or `emergencyUnpauseAll()` on the timelock (a self-call, longDelay).

3. **Veto Window** - during the delay any `CANCELLER_ROLE` holder can stop it:
   ```solidity
   timelock.cancel(id);            // or timelock.cancelOperation(id)
   ```

4. **Execute the Unpause After the Delay** (any executor)
   ```solidity
   bytes32 salt = timelock.getOperation(id).salt;   // also in EmergencyActionScheduled / OZ CallSalt
   timelock.execute(timelock, 0, abi.encodeCall(IGovernanceTimelock.emergencyUnpauseAll, ()), bytes32(0), salt);
   ```
   The timelock then calls itself and unpauses every registered contract: one `ContractPauseResult`
   event per contract (with `success`) and `EmergencyActionExecuted(..., "Emergency unpause all")`.
   Confirm with `cast call $ILRM_ADDRESS "paused()" --rpc-url $RPC_URL` (should return `false`).

   **If the protocol was paused again in the meantime**, the queued unpause can no longer execute.
   Every operation that unpauses (`unpause()` on any contract, or `emergencyUnpauseAll` on the
   timelock, queued by a guardian or a proposer) is bound to the pause epoch it was scheduled in, and
   each `emergencyPauseAll` starts a new epoch: executing an earlier unpause reverts with
   `StaleUnpause`. OpenZeppelin's views (`isOperationReady`) still report it ready, but
   `timelock.isOperationStale(id)` is true and `getOperation(id).status` is `Stale`; it is left out of
   `getPendingOperations()` and listed by `getStaleOperations()`. Once the new incident is resolved,
   queue a fresh unpause (step 2) and cancel the stale ones (`timelock.cancel(id)`).

5. **Monitor Intensively**
   - Watch for 24 hours post-unpause
   - Lower alert thresholds temporarily

6. **Announce Recovery**
   - Post on official channels
   - Include brief incident summary
   - Share timeline for full post-mortem

### Fund Recovery

If funds were stolen:

1. **Document Everything**
   - Block number of exploit
   - Transaction hashes
   - Addresses involved
   - Amount stolen

2. **Trace Funds**
   - Work with blockchain analytics (Chainalysis, TRM)
   - Monitor attacker addresses
   - Check for CEX deposits

3. **Engage Law Enforcement (if significant)**
   - File FBI IC3 report (US)
   - Contact relevant authorities

4. **Insurance Claim**
   - Document all losses
   - File claim with coverage provider

---

## Post-Incident Process

### Immediate (24-48 hours)

1. **Draft Incident Summary**
   - What happened
   - What was the impact
   - How was it resolved
   - Current status

2. **Internal Debrief**
   - All responders present
   - Walk through timeline
   - Identify gaps

### Short-term (1 week)

3. **Root Cause Analysis**
   - Why did this happen?
   - Why wasn't it caught earlier?
   - What can prevent recurrence?

4. **Process Improvements**
   - Update monitoring
   - Improve tests
   - Enhance documentation

### Long-term (2-4 weeks)

5. **Public Post-Mortem**
   - Detailed technical analysis
   - Lessons learned
   - Changes implemented

6. **Third-Party Review**
   - Consider additional audit
   - Focus on affected areas

---

## Monitoring Alerts

### Critical Alerts (Page Immediately)

| Alert | Condition | Action |
|-------|-----------|--------|
| Large Withdrawal | > $100K in single tx | Investigate immediately |
| Pause Event | Any contract paused | Check if authorized |
| Ownership Change | Owner changed | Verify legitimacy |
| Unusual Gas | 10x normal gas usage | Check for attack |
| Failed Multisig | Multiple failed sigs | Account compromise? |

### Warning Alerts (Notify On-call)

| Alert | Condition | Action |
|-------|-----------|--------|
| High Volume | 5x normal disputes | Monitor closely |
| Oracle Delay | > 30 min since update | Check oracle health |
| Gas Spike | 3x normal gas prices | Delay non-urgent ops |
| New Contract Call | Unknown contract interaction | Review for safety |

### Info Alerts (Log Only)

| Alert | Condition | Notes |
|-------|-----------|-------|
| Dispute Created | Any new dispute | Normal operation |
| Stake Matched | Counterparty staked | Normal operation |
| Resolution | Dispute resolved | Normal operation |

---

## Communication Templates

### Status Update (During Incident)

```
🚨 [PROTOCOL NAME] Status Update

We are aware of [brief description of issue].

Current Status: [Investigating / Mitigating / Resolved]

Impact: [What users should know]

Actions Taken: [What we've done]

Next Update: [Timeframe]

Do NOT [any user warnings, e.g., "interact with X"]
```

### Post-Incident Summary

```
📋 Incident Report: [Title]

Date: [Date]
Duration: [Start - End]
Severity: [SEV-X]

Summary:
[Brief description]

Impact:
- [Bullet points]

Root Cause:
[Technical explanation]

Resolution:
[What was done]

Prevention:
[Future improvements]

Full post-mortem: [Link]
```

---

## Runbook Maintenance

- Review this document quarterly
- Update after every SEV-1 or SEV-2 incident
- Test emergency procedures on testnet monthly
- Rotate on-call duties and verify contacts regularly

---

*This document contains sensitive operational information. Handle appropriately.*
