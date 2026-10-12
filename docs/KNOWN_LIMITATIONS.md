# Known Limitations and Accepted Residual Risks

This file lists behaviour that is known, reviewed, and deliberately left as is. Each item was found
during the 2026-10 correctness and security pass (see `CHANGELOG.md`). Fixed issues are not listed here.
"Deferred" modules (`contracts/modules/`, `contracts/scaling/`) are outside the current audit scope
(`AUDIT_SCOPE.md`).

## Core contracts (ILRM, Oracle, Treasury, AssetRegistry)

### Trust assumptions
- **Oracle operators are trusted.** Registered operators sign proposals. A compromised operator can submit
  any (non-binding) proposal until it is revoked; parties must still accept, and the owner can void it with
  `resetProposal` / `resetProposalExact` (see `docs/EMERGENCY_PROCEDURES.md`).
- **Owner-maintained harassment scores.** Neither ILRM nor the Treasury updates harassment scores
  automatically; the owner must feed them.
- **Plain ERC20 assumed.** A token that can blacklist the Treasury (USDC-style) would make resolution of a
  subsidized dispute revert, because repayment is a push transfer to the recorded funder.

### Economics
- **Initiator incentive is farmable up to its caps.** On non-participation the initiator gets its stake plus
  `min(10% of stake, maxIncentivePerDispute, remaining window budget, tokenReserves)`. A sybil counterparty
  that never stakes still triggers it, so farming up to `maxIncentivePerWindow` per `incentiveWindow` remains
  possible (defaults: 1 token per dispute, 10 tokens per 30 days). A farmer can also consume a fresh window's
  budget right at the window roll, starving honest initiators for that window. The initiator's stake is never
  affected. There is no withdrawal path for `tokenReserves`.
- **Subsidy liquidity can be tied up at no net cost.** An attacker with capital and fresh sybil counterparties
  can lock up to `balance - minReserve` of Treasury tokens in ILRM escrow for the life of each dispute. On
  mutual acceptance everything is returned, so this is griefing, not a drain.
- **A fully subsidized defender has nothing at risk on timeout.** With `subsidy == stake`, refusing every
  proposal costs the defender nothing; the Treasury absorbs the defender's share of the 50% burn. This follows
  from subsidies being stake assistance.
- **Rolling per-participant subsidy allowance is not restored** when a subsidy is repaid.
- **AssetRegistry records are keyed by dispute ID only.** One registry must not serve several ILRM
  deployments.

### Proposals and acceptance
- **Use `acceptProposalWithHash`.** The legacy `acceptProposal(id)` is not bound to the proposal text.
  The hash binding is to the text, not the round: identical text proposed in a later round counts as the
  same terms. Parties cannot withdraw an acceptance.
- **Signatures do not bind the consumer address.** Re-pointing `Oracle.setILRM` to a different consumer whose
  dispute IDs overlap is unsupported.
- **Counter-proposals can invalidate a pending operator signature** (the round changes). This is bounded by
  `MAX_COUNTERS` and the exponential counter fees.
- **`Oracle.requestProposal` is advisory.** `pendingRequests` gates nothing and can stay `true` after a
  timeout.
- **Gas floor.** `depositStake`, `depositStakeWithSubsidy` and `counterPropose` revert "Insufficient gas"
  unless roughly 112k gas remains for the advisory oracle request, so callers with tight hard-coded gas
  limits must raise them.
- **No relayed entry points.** ILRM has no `...For` functions, so `BatchQueue` cannot relay dispute actions
  to it; relaying ships disabled.

## MultiPartyILRM (deferred)
- With `allowLateJoin`, a joiner who never stakes blocks proposals and counter-proposals until the stake
  window ends.
- Custom quorum rounds down; it does not call `Oracle.requestProposal`.
- Clearing votes loops over all parties (up to 255), so an oracle reset or replacement of a large dispute can
  cost over 1M gas.
- Each staked party may change its evidence once per round, which can force one operator re-sign per party
  per round.

## L3 scaling (`L3Bridge`, `L3DisputeBatcher`, `L3StateVerifier`) - must not be deployed
- `_verifyFraudProof` does not check a state transition: anyone who knows a leaf of an honest root can reject
  it and earn the reward.
- There is no sequencer bond; settlements with `stateProof == 0` are not tied to a finalized root; bridged
  disputes are not validated against ILRM.
- An honest root that was wrongly rejected cannot be resubmitted under the same root hash.
- Disabling commit-reveal re-exposes reveals to front-running through the legacy `submitFraudProof`, and the
  owner can withdraw free balance ahead of a winning reveal's reward.

These need a real fraud-proof system. They are pinned by `test/L3KnownLimitations.t.sol`.

## ComplianceCouncil (deferred)
- Member keys are not bound to the group key (no Feldman commitments or proof of possession); the DKG and
  `setAggregatedPublicKey` are admin-trusted.
- STRICT_ONCHAIN execution interpolates the first `threshold` current partials, so a member whose registered
  key is not a share of the group key blocks execution until it is removed. A proactive share refresh that
  mixes old and new partials blocks execution until every member re-signs. Removing or rotating a signer after
  `signatureTimeout` can strand a warrant that could already execute.
- `decryptedKeyHash` is `keccak256(sigma)`, and sigma is public once `threshold` partials are on chain; it is
  not a secret. HYBRID_ATTESTED records the operator's attested hash without recomputing it, and (with no
  precompiles on chain) counts current partials that were never verified on chain; the operator attestation
  is what protects that mode.
- A failing EIP-2537 precompile consumes all gas forwarded to it, so calls with malformed points use most of
  their gas limit before failing closed.
- The SDK's viewing-key reconstruction reveals every share; partial or threshold signatures must never be used
  as decryption material.

## GovernanceTimelock (deferred)
- Call classification is per (target, selector), not per argument.
- A rogue `EMERGENCY_ROLE` holder can queue any Emergency-classified call at the emergency delay (cancellable
  during the delay), keep re-pausing until revoked, and spam the pending queue. Revoking a guardian is a
  long-delay self-call.
- Pause epochs only recognise `unpause()` and `emergencyUnpauseAll()`; indirect unpause routes (multicall,
  `upgradeToAndCall`) are not epoch-bound, but those selectors already require the long delay.
- OpenZeppelin operations never expire, and raw OZ `schedule` records no governance metadata.
- Trust-root setters (`Oracle.registerOracle` / `updateOracleKey`, `ComplianceCouncil.setAggregatedPublicKey`
  / `setExecutionMode`) stay at the standard delay so a compromised oracle can be replaced quickly.

See `docs/MULTISIG_CONFIG.md` ("Residual Design Limits").

## DIDRegistry and FIDOVerifier (deferred)
- Five or more colluding trusted issuers can fill a DID's 50 credential slots, and a still-trusted issuer can
  refill its 10 slots after the controller clears them, until the owner removes it.
- Renewing in place needs `renewCredential`; an issuer that renews through `issueCredential` uses a new slot
  each time and can hit its 10-slot limit until old credentials expire and are pruned.
- A low-trust issuer can lower a DID's score through the weighted average.
- `minSybilScore` is not enforced on chain; the live score views cost up to about 0.6M gas.
- The pure-Solidity P-256 fallback is correct but costs about 38M gas, so the RIP-7212 precompile is
  effectively required. High-s signatures are normalized (malleable; harmless for replay protection).
  `verifyAssertion`'s used-challenge set is global, so a challenge can be front-run and burned.

## BatchQueue and DummyTransactionGenerator (deferred)
- Relaying to ILRM ships disabled (see "No relayed entry points" above).
- There is no VRF or commit-reveal: shuffles and dummy selection use on-chain entropy, so dummies remain
  attributable on chain.
- `minBatchSize` is not an anonymity floor (cancelled padding counts), and FIFO spam of record-only entries
  can push a relayed transaction past `maxQueueTime`.
- A full 100-transaction release costs about 6.5M gas, above common Chainlink Automation limits; `checkUpkeep`
  does not signal a partially executed batch (anyone can call `executeBatch` to finish it). The dummy
  generator's keeper upkeep needs a gas limit of at least 1,000,000.

## Subgraph
- Some contract actions emit no event and are not indexed: `AssetRegistry.transferAsset`,
  `Oracle.revokeOracle`, `Oracle.setILRM`, and several `L3Bridge` configuration setters.
- `Proposal.proposalHash` is computed in AssemblyScript, which re-encodes text as UTF-16, so it can differ
  from the on-chain `keccak256` for non-ASCII or invalid UTF-8 proposals.
- Some links (oracle operator, reset round, commit-reveal mode) are inferred from earlier events in the same
  transaction, and L3 heights are derived rather than read from the contract.
