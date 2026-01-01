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
    ├─ Unpause contracts (if paused)
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

**Who Can Execute:** Multi-sig with EMERGENCY_ROLE

**Steps:**

1. **Initiate Emergency Meeting**
   ```
   Alert all multi-sig signers immediately
   ```

2. **Prepare Transaction**
   ```solidity
   // Target: ILRM contract
   function pause() external onlyOwner

   // Also pause related contracts
   Treasury.pause()
   AssetRegistry.pause()
   ```

3. **Execute via Multi-sig**
   - Go to Gnosis Safe
   - Create new transaction
   - Target: ILRM address
   - Data: `0x8456cb59` (pause() selector)
   - Collect required signatures
   - Execute

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

**Example: Increase stake requirements**

```solidity
// If griefing attack via low stakes
Treasury.setMinStake(newHigherAmount)
```

### Action 3: Oracle Emergency

**When to Use:** Oracle manipulation detected

**Steps:**

1. **Disable Oracle**
   ```solidity
   Oracle.deauthorize(compromisedOracleAddress)
   ```

2. **Block Proposals**
   ```solidity
   // Reject any pending proposals from bad oracle
   ILRM.rejectProposal(disputeId)
   ```

3. **Add New Oracle**
   ```solidity
   Oracle.authorize(newTrustedOracleAddress)
   ```

### Action 4: Governance Attack Response

**When to Use:** Malicious governance proposal detected

**Steps:**

1. **Cancel Proposal** (within timelock delay)
   ```solidity
   GovernanceTimelock.cancel(proposalId)
   ```

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

2. **Unpause Contracts**
   ```solidity
   ILRM.unpause()
   Treasury.unpause()
   AssetRegistry.unpause()
   ```

3. **Monitor Intensively**
   - Watch for 24 hours post-unpause
   - Lower alert thresholds temporarily

4. **Announce Recovery**
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
