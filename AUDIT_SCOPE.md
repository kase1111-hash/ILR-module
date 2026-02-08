# ILRM Core Audit Scope

**Date:** 2026-02-08
**Version:** Post-Phase 1 (Strip & Harden)
**Prepared for:** External auditor engagement

---

## Contracts in Scope

| Contract | File | Lines | Purpose |
|----------|------|-------|---------|
| `ILRM` | `contracts/ILRM.sol` | 538 | Core dispute resolution (stakes, proposals, timeouts) |
| `NatLangChainTreasury` | `contracts/Treasury.sol` | 494 | Burns, fees, defensive subsidies, harassment scores |
| `NatLangChainOracle` | `contracts/Oracle.sol` | 367 | EIP-712 signature verification, LLM proposal relay |
| `NatLangChainAssetRegistry` | `contracts/AssetRegistry.sol` | 390 | IP asset registration, dispute freezes, fallback licenses |
| **Total** | | **~1,789** | |

### Interfaces in Scope

| Interface | File | Lines |
|-----------|------|-------|
| `IILRM` | `contracts/interfaces/IILRM.sol` | 225 |
| `IOracle` | `contracts/interfaces/IOracle.sol` | 89 |
| `IAssetRegistry` | `contracts/interfaces/IAssetRegistry.sol` | ~150 |

### Dependencies

- OpenZeppelin Contracts v5.4: `ReentrancyGuard`, `Pausable`, `Ownable2Step`, `SafeERC20`, `ECDSA`, `MessageHashUtils`, `ERC20`
- Solidity 0.8.20

---

## Out of Scope

The following contracts exist in the codebase but are **deferred to later phases** and should NOT be audited now:

- `contracts/modules/` (7 contracts: identity, compliance, governance)
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
Counterparty -> ILRM.depositStake() [matches stake]
  ILRM -> Oracle.requestProposal() [triggers LLM]
Oracle -> ILRM.submitLLMProposal() [with EIP-712 signature]
Both parties -> ILRM.acceptProposal() [if both accept, dispute resolves]
  or
Party -> ILRM.counterPropose() [burns ETH fee, resets oracle]
  or
Anyone -> ILRM.enforceTimeout() [50% burn + fallback license]

Counterparty -> Treasury.requestSubsidy() [if under-resourced]
  Treasury -> IILRM.disputes() [verifies dispute state]
```

---

## Priority Audit Areas

### Critical (must audit)

1. **Reentrancy in stake/withdrawal flows** (ILRM.sol)
   - `initiateBreachDispute` -> token transfer
   - `depositStake` -> token transfer
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

4. **Treasury drain vectors** (Treasury.sol)
   - Double-subsidy per dispute (one-time flag)
   - Rolling window cap evasion
   - `requestSubsidy` caller spoofing (msg.sender == participant check)
   - Harassment score manipulation

5. **Timeout/cooldown enforcement accuracy** (ILRM.sol)
   - `STAKE_WINDOW` (3 days) enforcement
   - `RESOLUTION_TIMEOUT` (7 days) enforcement
   - `COOLDOWN_PERIOD` (30 days) enforcement
   - `block.timestamp` manipulation bounds

### High Priority

6. **Access control consistency**
   - `onlyOwner` on admin functions (all contracts use `Ownable2Step`)
   - `onlyILRM` on Treasury burn deposits and harassment score updates
   - `onlyOracle` on Oracle proposal submission
   - Oracle `onlyILRM` for proposal requests

7. **Integer overflow/underflow** (Solidity 0.8.20 has built-in checks, but verify edge cases)
   - Escalation multiplier: `stakeAmount * (ESCALATION_MULTIPLIER ** disputes)`
   - Counter fee: `COUNTER_FEE_BASE * (2 ** counterCount)`
   - Harassment score delta arithmetic

8. **Front-running risks**
   - Can an attacker front-run `acceptProposal` to manipulate resolution?
   - Can an attacker front-run `depositStake` to deny counterparty participation?
   - Can an attacker front-run `requestSubsidy` to claim another party's subsidy?

### Medium Priority

9. **AssetRegistry freeze/unfreeze correctness**
   - Assets frozen during dispute must be unfrozen on resolution
   - Fallback license application on timeout
   - DoS via `MAX_ASSETS_PER_OWNER` limit

10. **ETH handling**
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

---

## Known Limitations

1. **No external oracle decentralization** - Single oracle operator can control proposals. Production should use multi-oracle with threshold signatures.
2. **Owner-controlled parameters** - Stake windows, timeouts, fees controlled by single owner. Phase 5 adds governance timelock.
3. **No on-chain evidence verification** - Evidence hashes are opaque; content verification is off-chain.
4. **String-based error messages in ILRM** - ILRM uses `require(condition, "message")` instead of custom errors. Treasury uses custom errors. This is inconsistent but functional.
