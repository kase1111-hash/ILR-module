NatLangChain Protocol Safety Invariants

Version 1.0 — Draft

These invariants define properties that must hold at all times across all NatLangChain modules (ILRM, Mediator Nodes, negotiation engines, and future extensions). Any implementation violating these invariants is considered non-compliant, regardless of feature completeness.

NatLangChain does not regulate behavior.
It regulates who pays, when, and how much.

Invariant 1: No Unilateral Cost Imposition

Statement
No participant may impose economic cost on another participant without first incurring an equal or greater economic cost themselves.

Formal Requirement

Any unilateral action that can:

lock funds

trigger timers

force staking

initiate burn risk
must require the initiator to commit a stake or burn before the counterparty is exposed.

Rationale
This prevents harassment, spam, and coercive negotiation by ensuring the attacker always pays first.

Implications

Dispute initiators must stake immediately.

Requests without stake may not trigger timers or obligations.

Ignoring any non-staked action must be free.

Invariant 2: Silence Is Always Free

Statement
A participant must never incur cost, penalty, or disadvantage for declining to respond to a non-mutual request.

Formal Requirement

Any request that does not allege breach of an existing contract:

may be ignored indefinitely

must not trigger timers, defaults, or penalties

Only explicit acceptance may transition a request into a staked negotiation flow.

Rationale
Harassment requires leverage. Silence without cost removes leverage entirely.

Implications

“Knocking” costs the knocker.

No forced engagement paths exist.

Non-response is never treated as fault.

Invariant 3: Initiator Risk Precedence

Statement
In any adversarial or corrective flow, the initiator must always be economically exposed before the counterparty.

Formal Requirement

In breach or drift claims:

initiator stakes first

counterparty exposure occurs only after matching

If the counterparty declines to stake:

the dispute resolves immediately

no re-initiation is allowed until cooldown expires

Rationale
This aligns power with responsibility and deters frivolous claims.

Invariant 4: Bounded Griefing

Statement
The maximum economic damage a single participant can inflict on another through protocol interaction must be strictly bounded and knowable in advance.

Formal Requirement

Counter-proposals must be:

capped in number

exponentially priced

The sum of all possible fees and burns in a flow must be ≤ a known upper bound defined at initiation.

Rationale
Unbounded interaction is indistinguishable from harassment.

Implications

Infinite counters are prohibited.

Griefing becomes a finite, costly choice.

Invariant 5: Harassment Is Net-Negative to the Harasser

Statement
Across all interaction paths, repeated non-resolving initiation must result in strictly increasing net cost to the initiator.

Formal Requirement

Initiation costs must scale with:

recent unresolved disputes

timeout-heavy histories

Timeouts without agreement increase future initiation costs.

These escalations must apply asymmetrically to initiators, not defendants.

Rationale
This ensures harassment collapses under its own economics.

Invariant 6: Mutuality or Exit

Statement
Every protocol flow must resolve into either:

Explicit mutual agreement, or

Automatic, non-escalatory exit.

Formal Requirement

No flow may remain indefinitely unresolved.

Resolution paths must include:

agreement

timeout → fallback license/state

mutual withdrawal

No third-party judgment is required.

Rationale
Deadlock is a failure mode. The protocol must always move forward.

Invariant 7: Outcome Neutrality

Statement
The protocol must not evaluate, rank, or judge the “correctness” of participant claims.

Formal Requirement

The system may:

enforce deadlines

move funds

execute fallback clauses

The system may not:

declare winners or losers

label behavior as malicious

impose moral or legal interpretations

Rationale
NatLangChain prices disagreement; it does not arbitrate truth.

Invariant 8: Economic Symmetry by Default

Statement
Where mutual participation is required, economic exposure must be symmetric by default.

Formal Requirement

Matched stakes

Identical deadlines

Identical burn mechanics

Permitted Exceptions

Reputation-based stake modifiers

Treasury-backed defensive subsidies
These must be:

opt-in

transparent

non-punitive

Invariant 9: Predictable Cost Surfaces

Statement
Participants must be able to calculate their worst-case economic exposure before entering any protocol flow.

Formal Requirement

All fees, burns, caps, and timeouts must be:

explicit

machine-readable

exposed at initiation

Rationale
Unpredictable cost is coercive.

Invariant 10: Protocol Non-Sovereignty

Statement
NatLangChain must not assert authority beyond the execution of its own economic mechanisms.

Formal Requirement

No binding claims about:

legality

enforceability outside the protocol

social or political authority

All outcomes exist solely within protocol-defined states.

Rationale
The protocol is infrastructure, not governance.

Closing Principle

NatLangChain doesn’t govern people — it governs the price of conflict.

Any implementation that violates these invariants makes conflict cheap, harassment profitable, or resolution coercive — and is therefore incompatible with the protocol’s purpose.
