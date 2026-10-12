# NatLangChain Treasury

**Version:** 2.0
**Status:** Implemented (flat-cap escrowed subsidies; see the implementation table for what is not implemented)
**Contracts:** `contracts/Treasury.sol` (`NatLangChainTreasury`), subsidy and incentive code in `contracts/ILRM.sol`
**Last Updated:** October 2026

This document describes the code as it is. Every function, variable and event named here exists in the
contracts; features that were designed but are not implemented are listed as such.

---

## 1. Purpose and funds map

The Treasury funds **defensive stake subsidies**: a low-resource counterparty can stake into an ILRM dispute
with part of its stake funded by the Treasury. The subsidy is an escrowed co-stake held by ILRM, never a
payment to the counterparty's wallet, and ILRM repays the Treasury its pro-rata share on resolution.

Protocol value sits in five places. They are separate and none of them feeds another automatically:

| Where | Inflows | Outflows |
|-------|---------|----------|
| `NatLangChainTreasury` token balance | `deposit(amount, reason)` from anyone (counted in `totalInflows`); `depositBurn(amount)` (ILRM-only, and the current ILRM never calls it); subsidy repayments from ILRM (plain ERC20 transfers, **not** counted in `totalInflows`; index `ILRM.SubsidyReturned`) | Subsidy grants pulled by ILRM into dispute escrow; owner `emergencyWithdraw` |
| `NatLangChainTreasury` ETH balance | `receive()` (emits `TreasuryReceived(from, amount, "eth")`) | Owner `emergencyWithdrawETH` |
| `ILRM.treasury` (ETH accounting variable inside ILRM) | Counter-proposal fee excess (`msg.value - fee` in `counterPropose`); ETH sent to `ILRM.receive()` | Owner `ILRM.withdrawTreasury` |
| `ILRM.tokenReserves` (tokens held by ILRM) | `ILRM.depositTokenReserves(amount)` from anyone; **irrevocable** | Only capped initiator incentives on non-participation (section 6) |
| Burn address `0x000000000000000000000000000000000000dEaD` | Token: 50% of the total stake on `TimeoutWithBurn` plus the odd-wei dust. ETH: every counter-proposal fee and every voluntary-request fee | None |

ILRM burns to `0x…dEaD`; it never sends burns or fees to the Treasury.

---

## 2. Implemented vs not implemented

| Feature | Status | Where |
|---------|--------|-------|
| Escrowed defensive co-stake | Implemented | `ILRM.depositStakeWithSubsidy` -> `Treasury.fundStakeSubsidy` |
| Top-up slippage bound (`maxTopUp`) | Implemented | `ILRM.depositStakeWithSubsidy` |
| Pro-rata repayment on resolution | Implemented | `ILRM._payCounterpartySide` |
| Per-dispute cap | Implemented | `maxPerDispute` in `fundStakeSubsidy` |
| Per-participant rolling-window cap | Implemented | `maxPerParticipant` / `windowDuration` in `fundStakeSubsidy` |
| Reserve floor | Implemented | `minReserve` in `fundStakeSubsidy` |
| Harassment-score threshold | Implemented | `HARASSMENT_THRESHOLD` (50) in `fundStakeSubsidy` |
| Single subsidy per (ILRM, dispute) | Implemented | `subsidyRecipientOf` |
| Capped initiator incentive from `ILRM.tokenReserves` | Implemented | `ILRM._takeInitiatorIncentive`, `ILRM.setInitiatorIncentiveCaps` |
| Dynamic caps | Removed in Phase 1 (566242d, REFOCUS_PLAN.md) | - |
| Tiered subsidies | Removed in Phase 1 (566242d, REFOCUS_PLAN.md) | - |
| DID-based subsidies | Removed in Phase 1 (566242d, REFOCUS_PLAN.md) | - |
| Harassment-score decay | Removed in Phase 1 (566242d, REFOCUS_PLAN.md) | - |
| ILRM-fed harassment scores | Removed in Phase 1 (566242d, REFOCUS_PLAN.md): ILRM never calls `Treasury.updateHarassmentScore`; scores are set by the owner with `setHarassmentScore` | - |
| Multi-token support | Removed in Phase 1 (566242d, REFOCUS_PLAN.md); single ERC20 `token` | - |

---

## 3. Subsidy escrow flow

The counterparty (defender) of an ILRM dispute, inside the 3-day stake window:

1. **Preview.** `stake = ILRM.disputes(id).initiatorStake`, then
   `(preview, eligible) = treasury.calculateSubsidy(id, min(maxSubsidy, stake), me)`.
   `calculateSubsidy` does not cap by the stake itself, so pass `min(maxSubsidy, stake)`.
2. **Bound the top-up.** `maxTopUp = stake - preview`.
3. **Approve.** `token.approve(ILRM, maxTopUp)` (a larger allowance is fine: `maxTopUp` is what bounds the charge).
4. **Stake.** `ILRM.depositStakeWithSubsidy(id, maxSubsidy, maxTopUp)`.

`ILRM.depositStakeWithSubsidy` (`nonReentrant`, `whenNotPaused`) checks, in order:

| # | Check | Revert |
|---|-------|--------|
| 1 | caller is the dispute's counterparty | `"Not counterparty"` |
| 2 | not staked yet (`counterpartyStake == 0`) | `"Already staked"` |
| 3 | dispute not resolved | `"Dispute resolved"` |
| 4 | inside the stake window (`block.timestamp <= startTime + STAKE_WINDOW`) | `"Stake window closed"` |
| 5 | `subsidyTreasury != address(0)` | `"Subsidies disabled"` |
| 6 | `maxSubsidy > 0` | `"Zero subsidy"` |
| 7 | pre-call bound: `stake - min(maxSubsidy, stake) <= maxTopUp` | `"Top-up exceeds max"` |

It then commits the symmetric stake (`counterpartyStake = initiatorStake`) and calls
`treasury.fundStakeSubsidy(id, caller, min(maxSubsidy, stake))`, which checks:

| Check | Revert |
|-------|--------|
| caller is the wired `ilrm` | `NotILRM(caller)` |
| Treasury not paused | `EnforcedPause()` |
| no subsidy recorded for `(msg.sender, id)` | `DisputeAlreadySubsidized(id)` |
| `maxAmount > 0` | `ZeroAmount()` |
| dispute not resolved (read back from ILRM) | `DisputeAlreadyResolved(id)` |
| participant is the counterparty and not the initiator | `NotCounterparty(participant, counterparty)` |
| participant is not `address(0)` | `InvalidAddress()` |
| ILRM committed the matching stake (`counterpartyStake == initiatorStake != 0`) | `SubsidyNotEscrowed(id)` |
| `harassmentScore[participant] < HARASSMENT_THRESHOLD` (50) | `ParticipantFlaggedForAbuse(participant, score)` |
| grant > 0 | `NoSubsidyAvailable()` |

The grant (the per-participant window is reset first if `block.timestamp > participantWindowStart + windowDuration`):

```
grant = min(
    requested,                                   // min(maxSubsidy, initiatorStake), from ILRM
    initiatorStake,                              // never more than the (escalated) stake owed
    maxPerDispute,
    maxPerParticipant - participantSubsidyUsed[participant],   // rolling-window remainder
    balanceOf(treasury) - minReserve             // 0 if the balance is at or below the floor
)
```

The Treasury records `subsidyRecipientOf[ILRM][id] = participant`, charges `participantSubsidyUsed` and
`totalSubsidiesDistributed`, `forceApprove`s ILRM for **exactly** the grant and emits `SubsidyFunded`.

Back in ILRM: `require(0 < grant <= requested, "Invalid subsidy")`, then the post-call bound
`require(stake - grant <= maxTopUp, "Top-up exceeds max")`, then the record `stakeSubsidy(id) = (treasury, grant)`,
then ILRM pulls the grant from the Treasury and the top-up `stake - grant` from the caller, and emits
`StakeSubsidized` and `StakeDeposited`. All of this is one transaction: any revert undoes the Treasury record,
the rolling-window charge, `totalSubsidiesDistributed`, the approval and the committed stake.

### Deployment wiring

```solidity
treasury.setILRM(address(ilrm));            // fundStakeSubsidy only accepts calls from this ILRM
ilrm.setSubsidyTreasury(address(treasury)); // owner-only; address(0) disables depositStakeWithSubsidy
```

`ILRM.setSubsidyTreasury` only affects future subsidized stakes: each dispute repays the funder recorded when
it was staked (`ILRM.stakeSubsidy(id)`).

---

## 4. Slippage bound and repayment

### Why `maxTopUp`

The grant is only known when the transaction executes. Between the caller's preview and inclusion it can shrink:
other subsidized stakes draining the Treasury's available balance (including sybil stakes placed on purpose),
`updateCaps`, `setMinReserve` or `setHarassmentScore`, a Treasury rotation (`ILRM.setSubsidyTreasury`), or the
caller's own per-participant window. Without a bound, a caller with a large allowance would be charged the
difference. `maxTopUp` makes ILRM revert instead:

- Checked twice. Before the Treasury call against the best case (`requested` is an upper bound on any grant), so an
  unsatisfiable bound fails without calling the Treasury; and after the call against the actual grant, before any
  record or transfer. The caller's outflow is therefore always `<= maxTopUp`.
- `maxTopUp = 0`: a full subsidy or a revert. `maxTopUp = type(uint256).max`: no bound.
- The bound only restricts the caller; it cannot be used to take more from the Treasury. ILRM enforces it itself
  and does not trust the Treasury's return value beyond `0 < grant <= requested`.
- A front-runner can force a revert, never an overcharge. A reverted call reserves nothing.

### Repayment

`ILRM._payCounterpartySide` splits whatever the counterparty side receives between the defender (its own share
of the stake, rounded down) and the recorded funder (the remainder). Repayment is a plain ERC20 transfer, so
resolution never runs Treasury code and keeps working while the Treasury is paused or unwired.

| Resolution | Counterparty-side payout `R` | Funder receives | Defender receives |
|------------|------------------------------|-----------------|-------------------|
| Mutual acceptance (`AcceptedProposal`) | the full stake `S` | the full subsidy `s` | its top-up `S - s` |
| Timeout (`TimeoutWithBurn`) | `floor(S / 2)` (50% of `2S` is burned, the rest split per party, dust burned) | `R - floor(R * (S - s) / S)` (bears its share of the burn) | `floor(R * (S - s) / S)` |
| Non-participation (`DefaultLicenseApplied`) | none | not applicable: no subsidy can exist | - |

Counter-proposal rounds do not change the split: counter fees are ETH paid by the caller (burned, excess to
`ILRM.treasury`) and only extend the deadline (1 day per counter, at most 3 days).

Example (timeout): `S = 8`, `s = 5`: 8 burned, initiator 4, funder 2.5, defender 1.5.

---

## 5. Per-(ILRM, dispute) records and `setILRM` migration

Subsidy records are keyed by the ILRM that requested them:

```solidity
mapping(address ilrm => mapping(uint256 disputeId => address participant)) public subsidyRecipientOf;
```

Dispute IDs restart at 0 for every ILRM deployment, so keying by `disputeId` alone made a redeployed ILRM's
disputes collide with the old one's (`DisputeAlreadySubsidized`). A non-zero entry means subsidized; under
`onlyILRM`, `(msg.sender, disputeId)` is globally unique.

- `disputeSubsidized(id)` and `disputeSubsidyRecipient(id)` keep their old selectors and return types and refer to
  the **currently wired** `ilrm`; `subsidyRecipientOf(ilrm, id)` gives the history of any ILRM.
- `calculateSubsidy` checks the currently wired `ilrm`.
- After `setILRM(B)`: disputes still open in the old ILRM A still resolve and repay this Treasury with plain
  transfers; A can no longer draw subsidies (`NotILRM(A)`); B's dispute IDs are independent of A's.
- Pointing back to A (`setILRM(A)`) restores A's records, so A's subsidized disputes still cannot be subsidized
  twice.
- `SubsidyFunded(participant, disputeId, amount)` has no ILRM field. Attribute it to the ILRM wired at that point
  (order of `ILRMUpdated` events), or to the `ILRM.StakeSubsidized` event emitted in the same transaction.

---

## 6. ILRM token reserves (initiator incentive)

When the counterparty never stakes, `enforceTimeout` resolves the dispute as `DefaultLicenseApplied` and returns
the initiator's stake plus an incentive from `ILRM.tokenReserves`:

```
uncapped  = initiatorStake * INITIATOR_INCENTIVE_BPS / 10_000          // 10%
incentive = min(uncapped,
                maxIncentivePerDispute,
                maxIncentivePerWindow - incentivePaidInWindow,          // 0 if already at or above the cap
                tokenReserves)
initiator receives initiatorStake + incentive                           // always the full stake
```

**Why capped.** The counterparty can be a sybil of the initiator that simply never stakes, and a fresh
counterparty faces no stake escalation. Uncapped, anyone could farm the reserves at 10% of their stake per 3-day
cycle; one dispute staked at 10x the reserves took all of them at once.

### Caps, defaults and setter

| Parameter | Default | Bounds |
|-----------|---------|--------|
| `maxIncentivePerDispute` | `DEFAULT_MAX_INCENTIVE_PER_DISPUTE` = `1e18` (1 token at 18 decimals) | `<= maxIncentivePerWindow` |
| `maxIncentivePerWindow` | `DEFAULT_MAX_INCENTIVE_PER_WINDOW` = `10e18` | none (owner trust) |
| `incentiveWindow` | `DEFAULT_INCENTIVE_WINDOW` = 30 days | `MIN_INCENTIVE_WINDOW` (1 day) to `MAX_INCENTIVE_WINDOW` (365 days), inclusive |

- `setInitiatorIncentiveCaps(uint256 maxPerDispute, uint256 maxPerWindow, uint256 window)`: owner-only, emits
  `InitiatorIncentiveCapsUpdated`; reverts `"Invalid incentive window"` or `"Per-dispute cap above window cap"`.
- Zero caps are allowed and are the **kill switch**. The setter is not `whenNotPaused`, because `enforceTimeout`
  cannot be paused.
- The defaults assume an 18-decimals token. `scripts/deploy.js` refuses to deploy against a token with other
  decimals unless `INCENTIVE_MAX_PER_DISPUTE` / `INCENTIVE_MAX_PER_WINDOW` / `INCENTIVE_WINDOW` (raw base units;
  seconds) are set.
- There is no absolute ceiling: the owner (intended: `GovernanceTimelock`) can raise the caps up to the deposited
  reserves.

### Window semantics

- Fixed windows, rolled lazily. The first window starts at ILRM deployment (`incentiveWindowStart`). The first
  paying payout at or after `incentiveWindowStart + incentiveWindow` starts a new window at its own timestamp with
  nothing paid in it.
- A zero incentive (a cap or the reserves exhausted, or zero caps) writes no state: it does not roll the window
  and does not touch `tokenReserves`.
- Configuration changes do not reset usage or the window start: a cap lowered below `incentivePaidInWindow` pays 0
  until the window rolls, and a new window length applies to the current window.
- When the reserves are below the cap-limited amount, the remainder of the reserves is paid.
- The mutual-acceptance and timeout-with-burn paths never touch the reserves or the incentive state.

### Preview and events

- `previewInitiatorIncentive(uint256 initiatorStake) returns (uint256)`: what a non-participation resolution would
  pay now, with the same caps. The actual payout can be lower if other payouts land first.
- `InitiatorIncentivePaid(uint256 indexed disputeId, address indexed initiator, uint256 amount, uint256 uncappedAmount)`:
  emitted on every non-participation resolution. `amount < uncappedAmount` (including 0) means a cap or the
  reserves bound the payout. **Monitor these events**: a run of capped payouts is the signature of farming.
- `InitiatorIncentiveCapsUpdated(uint256 maxPerDispute, uint256 maxPerWindow, uint256 window)`: emitted by the
  setter and once in the constructor.

### Residual risk (accepted)

The caps bound farming; they do not prevent it. The window cap is global (not keyed by address), so it holds
against any number of sybils:

- Each payout is `<= min(10% of the stake, maxIncentivePerDispute)`.
- Under a fixed configuration (window `T`, window cap `W`), at most `W` is paid per window and at most
  `W * (ceil(t / T) + 1)` over any interval of length `t`; across a window boundary, `2W` can be paid within
  seconds. The total paid can never exceed the deposited reserves.
- Farming the full window cap needs about 10x the cap in stakes (`10 * W` at the 10% rate, spread over at least
  `W / maxIncentivePerDispute` disputes) locked for the 3-day stake window; all of it is returned.
- First come, first served. Farmers (or any third party, since `enforceTimeout` is permissionless) can time
  resolutions so that an honest initiator's dispute lands in an exhausted window; that initiator then gets its
  stake back but no incentive.
- There is no per-initiator cap: initiator addresses are free, so sybils defeat it and it would only cost gas.
- Reserves have no exit except incentives: there is no withdrawal function, and with zero caps they stay locked.

With the defaults, at most 10 tokens per 30 days (20 across one boundary) can leave the reserves.

---

## 7. Admin and emergency functions

`NatLangChainTreasury` (`Ownable2Step`, `Pausable`; intended owner: `GovernanceTimelock`):

```solidity
function setILRM(address _ilrm) external onlyOwner;                       // emits ILRMUpdated
function updateCaps(uint256 _maxPerDispute, uint256 _maxPerParticipant, uint256 _windowDuration)
    external onlyOwner;                                                   // emits CapsUpdated
function setMinReserve(uint256 _minReserve) external onlyOwner;           // no event
function setHarassmentScore(address participant, uint256 score) external onlyOwner; // capped at 100
function updateHarassmentScore(address participant, int256 scoreDelta) external;    // onlyILRM; never called by ILRM
function emergencyWithdraw(address to, uint256 amount) external onlyOwner;          // any token amount
function emergencyWithdrawETH(address to, uint256 amount) external onlyOwner;       // any ETH amount
function pause() external onlyOwner;    // blocks fundStakeSubsidy only; repayments still arrive
function unpause() external onlyOwner;
function transferOwnership(address newOwner) external onlyOwner;          // Ownable2Step
function acceptOwnership() external;
```

`ILRM` (Treasury- and incentive-related admin):

```solidity
function setSubsidyTreasury(address _treasury) external onlyOwner;        // address(0) disables subsidies
function setInitiatorIncentiveCaps(uint256 _maxPerDispute, uint256 _maxPerWindow, uint256 _window)
    external onlyOwner;                                                   // works while paused
function withdrawTreasury(address _to, uint256 _amount) external onlyOwner; // ILRM.treasury ETH
function pause() external onlyOwner;    // blocks new disputes, stakes (incl. subsidized) and counters;
                                        // acceptProposal and enforceTimeout stay available
function unpause() external onlyOwner;
```

**Owner trust model.** The Treasury is not "fully algorithmic": its owner can change every cap, the reserve floor
and every harassment score, pause subsidies, re-point `ilrm`, and `emergencyWithdraw` the entire token and ETH
balance at any time. Escrowed subsidies are safe from the Treasury owner (they sit in ILRM), but repayments land
in the Treasury and are then under the owner's control. The ILRM owner can raise the incentive caps up to the
deposited reserves and can re-point the subsidy treasury. Both owners are intended to be `GovernanceTimelock`.

---

## 8. Events

`NatLangChainTreasury`:

```solidity
event SubsidyFunded(address indexed participant, uint256 indexed disputeId, uint256 amount);
event TreasuryReceived(address indexed from, uint256 amount, string reason);
event HarassmentScoreUpdated(address indexed participant, uint256 oldScore, uint256 newScore);
event ILRMUpdated(address indexed oldILRM, address indexed newILRM);
event CapsUpdated(uint256 maxPerDispute, uint256 maxPerParticipant, uint256 windowDuration);
// plus OpenZeppelin OwnershipTransferStarted, OwnershipTransferred, Paused, Unpaused
```

`ILRM` (Treasury and incentive related):

```solidity
event SubsidyTreasuryUpdated(address indexed previousTreasury, address indexed newTreasury);
event StakeSubsidized(uint256 indexed disputeId, address indexed counterparty, address indexed funder, uint256 amount);
event SubsidyReturned(uint256 indexed disputeId, address indexed funder, uint256 amount);
event TokenReservesDeposited(address indexed depositor, uint256 amount);
event InitiatorIncentiveCapsUpdated(uint256 maxPerDispute, uint256 maxPerWindow, uint256 window);
event InitiatorIncentivePaid(uint256 indexed disputeId, address indexed initiator, uint256 amount, uint256 uncappedAmount);
event TreasuryWithdrawn(address indexed recipient, uint256 amount);
event StakesBurned(uint256 indexed disputeId, uint256 burnAmount);
```

---

## 9. Known limitations

- **Zero-loss liquidity lock.** A colluding initiator/counterparty pair can take a subsidy and resolve by mutual
  acceptance, which repays the Treasury in full. This costs the pair nothing but gas, yet locks Treasury liquidity
  (up to `maxPerDispute` per dispute and `maxPerParticipant` per sybil defender per window) for up to about 10 days.
  A per-initiator cap on outstanding subsidy, a fee or a DID requirement would address it; that is an open product
  decision.
- **Front-run revert.** Anyone who shrinks the grant before inclusion can make a bounded `depositStakeWithSubsidy`
  revert (never overcharge). The defender can retry with a new preview or fall back to `depositStake`.
- **Rolling allowance not restored.** `participantSubsidyUsed` is charged gross and is not reduced when a subsidy
  is repaid.
- **Blacklisting tokens.** Repayment is a push transfer. With a token that can blacklist the Treasury or the
  counterparty, the transfer in `_payCounterpartySide` would revert and block that dispute's resolution.
- **No token check on rotation.** `ILRM.setSubsidyTreasury` does not check that the new Treasury's `token()` is
  ILRM's token. A mismatched Treasury cannot cause a loss (ILRM's pull of its own token from the Treasury fails and
  the stake reverts), but subsidies stop working.
- **Initiator-incentive farming up to the caps** (section 6).

---

## 10. Not implemented / future enhancements

The proposals for these live in `SPEC.md` (Category 5 and Plans 6/7, all marked as proposals):

| Enhancement | Notes |
|-------------|-------|
| Dynamic caps | Scale `maxPerParticipant` with the Treasury balance (SPEC.md Plan 6) |
| Tiered subsidies | Graduated subsidies by harassment score (SPEC.md Plan 7) |
| DID-based subsidies | Sybil-score bonuses; would need the identity module wired into the Treasury |
| Harassment-score decay; ILRM-fed scores | Scores are owner-set only today |
| Multi-token support | Single ERC20 `token` today (SPEC.md 5.3) |
| Per-initiator cap on outstanding subsidy | Mitigates the zero-loss liquidity lock (product decision) |
| `ILRM.tokenReserves` withdrawal path | Would change the donors' trust model; not added |
| Exclusive initiator grace period for `enforceTimeout` | Would stop third parties from timing incentive starvation; not added |
| Token check in `ILRM.setSubsidyTreasury`; event for `setMinReserve` | Small hardening items |

---

## Related documentation

- [ILRM Specification](./SPEC.md)
- [Safety Invariants](./Protocol-Safety-Invariants.md)
- [Security Audit](./docs/SECURITY_AUDIT_REPORT.md)
