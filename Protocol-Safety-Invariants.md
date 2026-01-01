# NatLangChain Protocol Safety Invariants

**Version:** 1.5
**Status:** All Invariants Implemented
**Last Updated:** January 2026

---

These invariants define properties that must hold at all times across all NatLangChain modules (ILRM, Mediator Nodes, negotiation engines, and future extensions). Any implementation violating these invariants is considered non-compliant, regardless of feature completeness.

> **NatLangChain does not regulate behavior. It regulates who pays, when, and how much.**

---

## Implementation Status

| Invariant | Status | Primary Implementation |
|-----------|--------|------------------------|
| 1. No Unilateral Cost Imposition | Implemented | `ILRM.sol:114-155` |
| 2. Silence Is Always Free | Implemented | `ILRM.sol:161-176` |
| 3. Initiator Risk Precedence | Implemented | `ILRM.sol:114-155` |
| 4. Bounded Griefing | Implemented | `ILRM.sol:255-290` |
| 5. Harassment Is Net-Negative | Implemented | `ILRM.sol:366-377, 486-490` |
| 6. Mutuality or Exit | Implemented | `ILRM.sol:296-309` |
| 7. Outcome Neutrality | Implemented | Protocol-wide design |
| 8. Economic Symmetry | Implemented | `ILRM.sol:182-194` |
| 9. Predictable Cost Surfaces | Implemented | All fee constants explicit |
| 10. Protocol Non-Sovereignty | Implemented | Documentation + design |

---

## Invariant 1: No Unilateral Cost Imposition

### Statement
No participant may impose economic cost on another participant without first incurring an equal or greater economic cost themselves.

### Formal Requirement
Any unilateral action that can:
- Lock funds
- Trigger timers
- Force staking
- Initiate burn risk

...must require the initiator to commit a stake or burn before the counterparty is exposed.

### Rationale
This prevents harassment, spam, and coercive negotiation by ensuring the attacker always pays first.

### Implications
- Dispute initiators must stake immediately
- Requests without stake may not trigger timers or obligations
- Ignoring any non-staked action must be free

### Implementation
- **Breach Disputes**: `initiateBreachDispute()` requires upfront stake (`ILRM.sol:114-155`)
- **Voluntary Requests**: `initiateVoluntaryRequest()` requires burn fee (`ILRM.sol:161-176`)
- **Stake Escalation**: Repeat initiators pay 1.5x multiplier (`ILRM.sol:366-377`)

---

## Invariant 2: Silence Is Always Free

### Statement
A participant must never incur cost, penalty, or disadvantage for declining to respond to a non-mutual request.

### Formal Requirement
Any request that does not allege breach of an existing contract:
- May be ignored indefinitely
- Must not trigger timers, defaults, or penalties
- Only explicit acceptance may transition a request into a staked negotiation flow

### Rationale
Harassment requires leverage. Silence without cost removes leverage entirely.

### Implications
- "Knocking" costs the knocker
- No forced engagement paths exist
- Non-response is never treated as fault

### Implementation
- **Voluntary Requests**: Zero cost to ignore (`ILRM.sol:161-176`)
- **Burn Fee**: Initiator pays non-refundable fee, counterparty has no obligation
- **No Auto-Triggers**: No timers start without counterparty action

---

## Invariant 3: Initiator Risk Precedence

### Statement
In any adversarial or corrective flow, the initiator must always be economically exposed before the counterparty.

### Formal Requirement
In breach or drift claims:
- Initiator stakes first
- Counterparty exposure occurs only after matching

If the counterparty declines to stake:
- The dispute resolves immediately
- No re-initiation is allowed until cooldown expires

### Rationale
This aligns power with responsibility and deters frivolous claims.

### Implementation
- **Stake Order**: Initiator stakes in `initiateBreachDispute()`, counterparty in `depositStake()` (`ILRM.sol:182-194`)
- **Cooldown**: 30-day period between disputes with same counterparty (`ILRM.sol:56, 152`)
- **Default License**: Applied if counterparty doesn't stake (`ILRM.sol:296-309`)

---

## Invariant 4: Bounded Griefing

### Statement
The maximum economic damage a single participant can inflict on another through protocol interaction must be strictly bounded and knowable in advance.

### Formal Requirement
Counter-proposals must be:
- Capped in number
- Exponentially priced

The sum of all possible fees and burns in a flow must be less than or equal to a known upper bound defined at initiation.

### Rationale
Unbounded interaction is indistinguishable from harassment.

### Implications
- Infinite counters are prohibited
- Griefing becomes a finite, costly choice

### Implementation
- **Max Counters**: 3 per dispute (`ILRM.sol:34`)
- **Exponential Fees**: Base fee * 2^n (`ILRM.sol:255-290`)
- **Max Time Extension**: 3 days total (`ILRM.sol:MAX_TIME_EXTENSION`)
- **Explicit Constants**: All fees/burns defined at contract level

---

## Invariant 5: Harassment Is Net-Negative to the Harasser

### Statement
Across all interaction paths, repeated non-resolving initiation must result in strictly increasing net cost to the initiator.

### Formal Requirement
Initiation costs must scale with:
- Recent unresolved disputes
- Timeout-heavy histories

Timeouts without agreement increase future initiation costs. These escalations must apply asymmetrically to initiators, not defendants.

### Rationale
This ensures harassment collapses under its own economics.

### Implementation
- **Harassment Score**: Tracked per participant (`ILRM.sol:78, 486-490`)
- **Stake Escalation**: 1.5x multiplier for repeat disputes (`ILRM.sol:366-377`)
- **Treasury Integration**: High scores block subsidies (`Treasury.sol:228-230`)
- **Tiered Subsidies**: Graduated reduction based on score (`Treasury.sol:617-646`)

---

## Invariant 6: Mutuality or Exit

### Statement
Every protocol flow must resolve into either:
1. Explicit mutual agreement, or
2. Automatic, non-escalatory exit

### Formal Requirement
- No flow may remain indefinitely unresolved
- Resolution paths must include: agreement, timeout with fallback license/state, or mutual withdrawal
- No third-party judgment is required

### Rationale
Deadlock is a failure mode. The protocol must always move forward.

### Implementation
- **Timeout Resolution**: 7-day maximum (`ILRM.sol:43`)
- **Enforced Exit**: `enforceTimeout()` callable by anyone after deadline (`ILRM.sol:296-309`)
- **Fallback License**: Always applied on timeout (`ILRM.sol:421`)
- **No Dead Ends**: Verified by `NoDeadEndsVerification.t.sol`

---

## Invariant 7: Outcome Neutrality

### Statement
The protocol must not evaluate, rank, or judge the "correctness" of participant claims.

### Formal Requirement
The system MAY:
- Enforce deadlines
- Move funds
- Execute fallback clauses

The system MAY NOT:
- Declare winners or losers
- Label behavior as malicious
- Impose moral or legal interpretations

### Rationale
NatLangChain prices disagreement; it does not arbitrate truth.

### Implementation
- **No Fault Assignment**: LLM proposals constrained to reconciliation only
- **Symmetric Burns**: Both parties lose equally on timeout
- **Neutral Terminology**: "Initiator" and "Counterparty" not "Plaintiff/Defendant"
- **Advisory Proposals**: All LLM outputs require voluntary acceptance

---

## Invariant 8: Economic Symmetry by Default

### Statement
Where mutual participation is required, economic exposure must be symmetric by default.

### Formal Requirement
- Matched stakes
- Identical deadlines
- Identical burn mechanics

### Permitted Exceptions
- Reputation-based stake modifiers
- Treasury-backed defensive subsidies

These must be:
- Opt-in
- Transparent
- Non-punitive

### Implementation
- **Matched Stakes**: Counterparty must match initiator stake exactly (`ILRM.sol:182-194`)
- **Symmetric Burn**: 50% of total escrow burned symmetrically (`ILRM.sol:37`)
- **Subsidies**: Optional, counterparty-only, with transparency (`Treasury.sol:189-273`)
- **Tiered Subsidies**: Based on harassment score, not favoritism (`Treasury.sol:617-646`)

---

## Invariant 9: Predictable Cost Surfaces

### Statement
Participants must be able to calculate their worst-case economic exposure before entering any protocol flow.

### Formal Requirement
All fees, burns, caps, and timeouts must be:
- Explicit
- Machine-readable
- Exposed at initiation

### Rationale
Unpredictable cost is coercive.

### Implementation
All constants are public and immutable:

| Constant | Value | Location |
|----------|-------|----------|
| `STAKE_WINDOW` | 3 days | `ILRM.sol:40` |
| `RESOLUTION_TIMEOUT` | 7 days | `ILRM.sol:43` |
| `BURN_PERCENTAGE` | 50% | `ILRM.sol:37` |
| `MAX_COUNTERS` | 3 | `ILRM.sol:34` |
| `COUNTER_FEE_BASE` | 0.01 ETH | `ILRM.sol:46` |
| `INITIATOR_INCENTIVE_BPS` | 1000 (10%) | `ILRM.sol:49` |
| `ESCALATION_MULTIPLIER` | 150 (1.5x) | `ILRM.sol:52` |
| `COOLDOWN_PERIOD` | 30 days | `ILRM.sol:55` |

---

## Invariant 10: Protocol Non-Sovereignty

### Statement
NatLangChain must not assert authority beyond the execution of its own economic mechanisms.

### Formal Requirement
No binding claims about:
- Legality
- Enforceability outside the protocol
- Social or political authority

All outcomes exist solely within protocol-defined states.

### Rationale
The protocol is infrastructure, not governance.

### Implementation
- **LICENSE_APPENDIX.md**: Explicitly disclaims legal authority
- **Non-Binding Proposals**: All LLM outputs are advisory only
- **Voluntary Acceptance**: Resolution requires explicit consent from all parties
- **Documentation**: Clear statements that protocol is "non-adjudicative"

---

## Closing Principle

> **NatLangChain doesn't govern people - it governs the price of conflict.**

Any implementation that violates these invariants makes conflict cheap, harassment profitable, or resolution coercive - and is therefore incompatible with the protocol's purpose.

---

## Verification

The protocol includes automated verification of these invariants:

| Test Suite | Purpose |
|------------|---------|
| `StateMachinePermutations.t.sol` | Exhaustive state transition testing |
| `SecurityExploits.t.sol` | Attack vector validation |
| `NoDeadEndsVerification.t.sol` | Deadlock-free verification |
| `DeadEndDetection.t.sol` | Deadlock scenario detection |

Run verification:
```bash
forge test --match-contract StateMachinePermutations -vvv
forge test --match-contract NoDeadEndsVerification -vvv
```
