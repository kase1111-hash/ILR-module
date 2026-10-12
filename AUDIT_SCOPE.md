# ILRM Core Audit Scope

**Date:** 2026-02-08 (updated 2026-10-12)
**Version:** Post-Phase 1 (Strip & Harden), plus the 2026-10 correctness and security fixes (see CHANGELOG.md)
**Prepared for:** External auditor engagement

---

## Contracts in Scope

| Contract | File | Lines | Purpose |
|----------|------|-------|---------|
| `ILRM` | `contracts/ILRM.sol` | 729 | Core dispute resolution (stakes, proposals, timeouts), oracle consumer |
| `NatLangChainTreasury` | `contracts/Treasury.sol` | 472 | Burns, fees, defensive subsidies, harassment scores |
| `NatLangChainOracle` | `contracts/Oracle.sol` | 496 | EIP-712 signature verification, LLM proposal relay, owner recovery |
| `NatLangChainAssetRegistry` | `contracts/AssetRegistry.sol` | 384 | IP asset registration, dispute freezes, fallback licenses |
| **Total** | | **2,081** | |

### Interfaces in Scope

| Interface | File | Lines |
|-----------|------|-------|
| `IILRM` | `contracts/interfaces/IILRM.sol` | 239 |
| `IOracle`, `IOracleConsumer` | `contracts/interfaces/IOracle.sol` | 125 |
| `IAssetRegistry` | `contracts/interfaces/IAssetRegistry.sol` | 162 |

Line counts are `wc -l` at the commit that last updated this file.

`IOracle.sol` also defines `IOracleConsumer`, the lean interface through which `NatLangChainOracle` reads and
writes the dispute contract it serves (`oracleContext`, `submitLLMProposal`, `voidLLMProposal`). It is
implemented by `ILRM` and by the deferred `MultiPartyILRM`.

### Dependencies

- OpenZeppelin Contracts v5.4: `ReentrancyGuard`, `Pausable`, `Ownable2Step`, `SafeERC20`, `ECDSA`, `MessageHashUtils`, `ERC20`
- Solidity 0.8.20

---

## Out of Scope

The following contracts exist in the codebase but are **deferred to later phases** and should NOT be audited now:

- `contracts/modules/` (7 contracts: identity, compliance, governance; `MultiPartyILRM` implements
  `IOracleConsumer` so the same Oracle can serve it)
- `contracts/scaling/` (5 contracts: L3 bridge, privacy batching)
- `sdk/` (TypeScript SDK modules)
- `subgraph/`, `monitoring/`

---

## Protocol Overview

ILRM is a non-adjudicative dispute resolution protocol for IP licensing. Parties lock symmetric stakes, an LLM oracle proposes resolution terms, and both parties must accept. If they don't agree within a timeout, stakes are partially burned and a fallback license applies.

### Key Economic Invariants

1. **Symmetric Stakes**: Both parties lock equal amounts
2. **Initiator Risk Precedence**: Initiator stakes first, bears more risk
3. **Bounded Griefing**: Counter-proposals cost exponentially increasing fees
4. **50% Burn on Timeout**: Both parties lose equally on failure
5. **Fallback License Always Non-Exclusive**: Prevents IP monopolization
6. **Treasury Cannot Be Drained**: Per-dispute and per-participant caps, rolling windows
7. **Harassment Score Blocks Repeat Abusers**: Score >= 50 blocks subsidies

### Contract Interaction Flow

```
Initiator -> ILRM.initiateBreachDispute() [stakes tokens]
Counterparty -> ILRM.depositStake() / depositStakeWithSubsidy() [matches stake]
  ILRM -> Oracle.requestProposal() [advisory, last statement: code check, gas floor, 100k gas cap,
                                     try/catch; OracleRequestFailed on failure; never blocks staking]
Oracle operator -> Oracle.submitProposal()
  Oracle -> ILRM.oracleContext() [STATICCALL: round, evidenceHash, resolved, deadline]
  Oracle -> ILRM.submitLLMProposal() [EIP-712 signature over (disputeId, round, evidenceHash, proposalHash, nonce); one per round]
    ILRM -> Oracle.verifySignature() [STATICCALL; re-reads ILRM.oracleContext]
Both parties -> ILRM.acceptProposalWithHash(id, keccak256(text)) [or legacy acceptProposal; if both accept, dispute resolves]
  or
Party -> ILRM.counterPropose() [only before the deadline; burns ETH fee, opens a new oracle proposal round,
                               requests a proposal (same advisory call as above)]
  or
Oracle owner -> Oracle.resetProposal() / resetProposalExact()
  Oracle -> ILRM.voidLLMProposal() [last statement; atomic compare-and-clear of the text and both acceptances;
                                    only before the deadline; works while ILRM is paused]
  or
Anyone -> ILRM.enforceTimeout() [50% burn + fallback license]

Counterparty -> ILRM.depositStakeWithSubsidy(id, maxSubsidy, maxTopUp)
  -> Treasury.fundStakeSubsidy() [onlyILRM; records keyed by (ILRM, disputeId); approves ILRM for the grant]
  -> ILRM pulls the subsidy + the counterparty top-up [top-up <= maxTopUp, checked before and after the Treasury call]
  Treasury -> IILRM.disputes() [verifies dispute state and the committed symmetric stake]
  ILRM -> funding Treasury [pro-rata repayment of the counterparty payout on resolution, plain ERC20 transfer]

Anyone -> ILRM.enforceTimeout() on a never-staked dispute (non-participation)
  ILRM -> initiator [full stake + incentive = min(10% of stake, maxIncentivePerDispute,
                     maxIncentivePerWindow - paid this window, tokenReserves); never reverts on a cap]
```

---

## Priority Audit Areas

### Critical (must audit)

1. **Reentrancy in stake/withdrawal flows** (ILRM.sol)
   - `initiateBreachDispute` -> token transfer
   - `depositStake` -> token transfer
   - `depositStakeWithSubsidy` -> `Treasury.fundStakeSubsidy` call, then subsidy + top-up pulls
   - `_resolveByAcceptance` -> token refunds
   - `_resolveByTimeout` -> token burns + refunds

2. **Token accounting correctness** (ILRM.sol, Treasury.sol)
   - No tokens should become permanently stuck
   - Burns should go to `address(0xdead)`, not be lost
   - Subsidy amounts should never exceed available balance

3. **Oracle signature bypass vectors** (Oracle.sol)
   - EIP-712 signatures must be non-replayable (nonce per dispute)
   - Chain fork detection must work correctly
   - Empty signatures must revert (FIX C-02 applied)

4. **Oracle recovery and proposal binding** (Oracle.sol, ILRM.sol)
   - Reset/void atomicity: `resetProposal` / `resetProposalExact` call `ILRM.voidLLMProposal` as their last
     statement, so for every unresolved dispute the Oracle's current-round slot is empty iff ILRM holds no
     live proposal (invariant I5); a revert in the hook rolls the whole reset back
   - Compare-and-clear: the hook voids only the named proposal (no-op if nothing is live, revert on mismatch);
     `resetProposalExact` cannot void a proposal that landed after it was queued behind the timelock
   - Hash-bound acceptance: `acceptProposalWithHash` never records an acceptance of text other than the one
     the party named; an acceptance flag always refers to the live proposal
   - `_requestOracleProposal` never blocks staking or countering (no code, revert, gas exhaustion, wrong
     consumer), and its gas floor guarantees a successful stake gave the Oracle its full 100k allowance
   - Deadlines: `counterPropose` and the reset reject calls after `startTime + RESOLUTION_TIMEOUT`, so a late
     counter cannot revive a timed-out dispute or front-run `enforceTimeout`
   - `voidLLMProposal` is deliberately not pausable (recovery while paused); oracle-only and nonReentrant

5. **Treasury drain vectors** (Treasury.sol)
   - Double-subsidy per dispute (one-time flag)
   - Rolling window cap evasion
   - `fundStakeSubsidy` caller restriction (`onlyILRM`; only reachable from `ILRM.depositStakeWithSubsidy`)
   - Subsidy never exceeds the dispute's stake (`subsidy <= initiatorStake`) and is escrowed, never paid to a wallet
   - Pro-rata repayment to the recorded funder on acceptance/timeout (`_payCounterpartySide` rounding) and
     resolution liveness (no Treasury call during resolution; works with the Treasury paused or the pointer rotated)
   - Slippage: a front-run that shrinks the grant can only make `depositStakeWithSubsidy` revert (`maxTopUp`),
     never charge the defender more than the bound they signed
   - Subsidy records keyed by (ILRM, disputeId): re-pointing `Treasury.setILRM` at a redeployed ILRM cannot
     collide with old dispute IDs
   - Harassment score manipulation

6. **Initiator-incentive farming bound** (ILRM.sol)
   - Non-participation pays the initiator an incentive from `tokenReserves`; a sybil counterparty that never
     stakes can farm it. The caps (`maxIncentivePerDispute`, `maxIncentivePerWindow`, `incentiveWindow`,
     owner-set within `MIN_/MAX_INCENTIVE_WINDOW`) must bound total payouts to the per-window cap
   - The lazily rolled window, `incentivePaidInWindow` accounting, and that a cap or empty reserves never
     revert or strand the initiator's stake

7. **Timeout/cooldown enforcement accuracy** (ILRM.sol)
   - `STAKE_WINDOW` (3 days) enforcement
   - `RESOLUTION_TIMEOUT` (7 days) enforcement
   - `COOLDOWN_PERIOD` (30 days) enforcement
   - `block.timestamp` manipulation bounds

### High Priority

8. **Access control consistency**
   - `onlyOwner` on admin functions (all contracts use `Ownable2Step`)
   - `onlyILRM` on Treasury burn deposits and harassment score updates
   - `onlyOracle` on Oracle proposal submission
   - Oracle `onlyILRM` for proposal requests
   - ILRM `voidLLMProposal` and `submitLLMProposal` callable only by the oracle

9. **Integer overflow/underflow** (Solidity 0.8.20 has built-in checks, but verify edge cases)
   - Escalation multiplier: `stakeAmount * (ESCALATION_MULTIPLIER ** disputes)`
   - Counter fee: `COUNTER_FEE_BASE * (2 ** counterCount)`
   - Harassment score delta arithmetic

10. **Front-running risks**
   - Can an attacker front-run `acceptProposal` to manipulate resolution?
   - Can an acceptance land on a proposal other than the one the party reviewed (reset, replacement, new round)?
     `acceptProposalWithHash` must revert "Proposal changed" in every such case
   - Can an attacker front-run `depositStake` to deny counterparty participation?
   - Can anyone but the counterparty reach the subsidy? (`depositStakeWithSubsidy` is counterparty-only; `fundStakeSubsidy` is `onlyILRM`)
   - Is `subsidy <= stake` always enforced, and is the pro-rata repayment correct and live on every resolution path?

### Medium Priority

11. **AssetRegistry freeze/unfreeze correctness**
   - Assets frozen during dispute must be unfrozen on resolution
   - Fallback license application on timeout
   - DoS via `MAX_ASSETS_PER_OWNER` limit

12. **ETH handling**
    - `receive()` on ILRM and Treasury
    - Counter-proposal ETH fee burns to `0xdead`
    - `emergencyWithdrawETH` in Treasury

---

## Test Coverage

| Test File | Framework | Tests | Status |
|-----------|-----------|-------|--------|
| `test/Treasury.test.js` | Hardhat | 16 | Updated for Phase 1 |
| `test/EndToEnd.security.test.js` | Hardhat | 22 | Updated for Phase 1 |
| `test/Integration.test.js` | Hardhat | ~15 | Updated field names |
| `test/ILRM.test.js` | Hardhat | ~10 | Updated field names |
| `test/ILRM.lifecycle.test.js` | Hardhat | ~8 | Updated field names |
| `test/Softlock.critical.test.js` | Hardhat | ~6 | Updated field names |
| `test/SecurityExploits.t.sol` | Foundry | ~15 | Updated for Phase 1 |
| `test/E2ESimulation.t.sol` | Foundry | ~20 | Module tests included |
| `test/GasBenchmarks.t.sol` | Foundry | 8 | Rewritten for Phase 2 |
| `test/OracleRounds.t.sol` | Foundry | 30 | One proposal per round, signature binding, invariants I1-I4 |
| `test/OracleRecovery.t.sol` | Foundry | 21 | Atomic reset/void, pinned reset, deadlines, pending lifecycle, invariant I5 |
| `test/AcceptProposalHash.t.sol` | Foundry | 9 | Hash-bound acceptance |
| `test/OracleRequestWiring.t.sol` | Foundry | 10 | Advisory proposal requests never block; gas floor |
| `test/OracleMultiParty.t.sol` | Foundry | 17 | Oracle serving MultiPartyILRM (deferred module) |
| `test/OracleRecovery.test.js` | Hardhat | 6 | Reviewer PoC, hash-bound acceptance via ethers v6 |
| `test/TreasurySubsidy.t.sol`, `test/TreasurySubsidyRegression.t.sol` | Foundry | 41 | Escrowed subsidies, pro-rata repayment, collusion fuzz |
| `test/TreasurySubsidyFollowups.t.sol`, `test/TreasuryFollowupsRegression.t.sol` | Foundry | - | maxTopUp slippage bound, incentive caps and farming bound, (ILRM, disputeId) keys |
| `test/ILRMProposalReplacement.t.sol` | Foundry | 10 | Storing a proposal voids acceptances |

Run `forge test` and `npx hardhat test` for current counts; every suite above passes in CI.

---

## Known Limitations

1. **No external oracle decentralization** - Single oracle operator can control proposals. Production should use multi-oracle with threshold signatures.
2. **Owner-controlled parameters** - Stake windows, timeouts, fees controlled by single owner. Phase 5 adds governance timelock.
3. **No on-chain evidence verification** - Evidence hashes are opaque; content verification is off-chain.
4. **String-based error messages in ILRM** - ILRM uses `require(condition, "message")` instead of custom errors. Treasury uses custom errors. This is inconsistent but functional.
5. **Initiator incentive is farmable up to its caps** - a sybil counterparty that never stakes still lets the
   initiator collect the incentive; the caps bound this to `maxIncentivePerWindow` per window (see 6 above).

The full list of accepted residual risks, including the deferred modules, is in
[docs/KNOWN_LIMITATIONS.md](docs/KNOWN_LIMITATIONS.md).
