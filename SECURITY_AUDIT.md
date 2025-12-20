# NatLangChain Protocol Security Audit Report

**Audit Date:** December 20, 2025
**Auditor:** Claude Security Analysis
**Scope:** ILRM.sol, Treasury.sol, Oracle.sol, AssetRegistry.sol
**Commit:** a15dc70

---

## Executive Summary

| Severity | Count | Status |
|----------|-------|--------|
| 🔴 Critical | 2 | ✅ FIXED |
| 🟠 High | 5 | ⚠️ 2 FIXED, 3 Remaining |
| 🟡 Medium | 8 | Recommended to Fix |
| 🟢 Low | 6 | Consider Fixing |
| ℹ️ Informational | 4 | Best Practices |

**Overall Assessment:** The codebase demonstrates solid understanding of security patterns (ReentrancyGuard, SafeERC20, access control).

### Fixed Issues (December 20, 2025)
- ✅ **C-01:** Initiator incentive now properly transferred from tokenReserves
- ✅ **C-02:** Oracle signature verification is now mandatory
- ✅ **H-02:** Treasury now requires ILRM to be set before subsidies
- ✅ **H-05:** Asset registration now requires msg.sender == owner
- ✅ **M-03:** Added HarassmentScoreUpdated event to ILRM

---

## Critical Findings

### 🔴 C-01: Initiator Incentive Never Transferred (ILRM.sol)

**Location:** `ILRM.sol:393-417` (`_resolveNonParticipation`)

**Severity:** CRITICAL

**Description:**
The initiator incentive (10% of expected counterparty stake) is calculated but never actually transferred. The code decrements `treasury` (which tracks ETH) but the incentive should be paid in ERC20 tokens.

```solidity
// Line 397-409 - BUG: Incentive calculated but not sent
uint256 incentive = (d.initiatorStake * INITIATOR_INCENTIVE_BPS) / 10000;

if (treasury >= incentive) {
    treasury -= incentive;  // Decrements ETH counter
    token.safeTransfer(d.initiator, d.initiatorStake);  // Only returns stake, NOT incentive
    // BUG: incentive is never transferred!
} else {
    token.safeTransfer(d.initiator, d.initiatorStake);
}
```

**Impact:**
- Initiators are promised a 10% incentive but never receive it
- Spec violation (Section 4.2: "Initiator stake is returned, plus a small incentive")
- Economic model is broken

**Recommendation:**
```solidity
// Fixed version:
if (treasury >= incentive) {
    treasury -= incentive;
    token.safeTransfer(d.initiator, d.initiatorStake + incentive);
} else {
    token.safeTransfer(d.initiator, d.initiatorStake);
}
```

**Note:** This also requires the ILRM contract to hold tokens for incentives, not just ETH. Consider integrating with Treasury contract.

---

### 🔴 C-02: Oracle Signature Verification Bypassed (Oracle.sol)

**Location:** `Oracle.sol:140-145` (`submitProposal`)

**Severity:** CRITICAL

**Description:**
Signature verification is optional - if `signature.length == 0`, the proposal is accepted without verification.

```solidity
// Line 140-145 - BUG: Signature check can be skipped
if (signature.length > 0) {
    if (!verifySignature(disputeId, proposalHash, signature)) {
        revert InvalidSignature();
    }
}
// If signature.length == 0, no verification occurs!
```

**Impact:**
- Any registered oracle operator can submit proposals without cryptographic proof
- Defeats the purpose of EIP-712 signature verification
- Malicious oracle could submit forged proposals

**Recommendation:**
```solidity
// Fixed version - require signature
if (signature.length == 0) {
    revert InvalidSignature();
}
if (!verifySignature(disputeId, proposalHash, signature)) {
    revert InvalidSignature();
}
```

---

## High Severity Findings

### 🟠 H-01: LLM Proposal Signature Verification Disabled (ILRM.sol)

**Location:** `ILRM.sol:207-209`

**Severity:** HIGH

**Description:**
The EIP-712 signature verification is marked as TODO and completely disabled.

```solidity
// TODO: Verify EIP-712 signature on evidenceHash + proposal
// require(_verifySignature(_disputeId, keccak256(bytes(_proposal)), _signature), "Invalid signature");
(_signature); // Silence unused parameter warning for now
```

**Impact:**
- Oracle can submit any proposal without proof of LLM generation
- No guarantee proposal came from legitimate LLM engine

**Recommendation:**
Implement signature verification or delegate to Oracle contract.

---

### 🟠 H-02: Treasury ILRM Check Bypass (Treasury.sol)

**Location:** `Treasury.sol:199-213` (`requestSubsidy`)

**Severity:** HIGH

**Description:**
If ILRM address is not set (`address(0)`), the counterparty validation is bypassed entirely.

```solidity
if (ilrm != address(0)) {
    // Validation only happens if ilrm is set
    (address initiator, address counterparty, ...) = IILRM(ilrm).disputes(disputeId);
    if (participant != counterparty) { revert NotCounterparty(...); }
}
// If ilrm == address(0), anyone can request subsidy for any dispute ID
```

**Impact:**
- Before ILRM is set, treasury can be drained by requesting subsidies for fake disputes
- Race condition between deployment and configuration

**Recommendation:**
```solidity
// Fixed version - require ILRM to be set
if (ilrm == address(0)) revert InvalidAddress();
```

---

### 🟠 H-03: Oracle-ILRM Architecture Mismatch (Oracle.sol + ILRM.sol)

**Location:** `Oracle.sol:152-153`, `ILRM.sol:200`

**Severity:** HIGH

**Description:**
ILRM expects `msg.sender == oracle` (single address), but Oracle contract calls ILRM on behalf of operators.

```solidity
// ILRM.sol:200
require(msg.sender == oracle, "Only oracle");

// Oracle.sol:152-153
IILRM(ilrmContract).submitLLMProposal(disputeId, proposal, signature);
// msg.sender here is the Oracle CONTRACT, not the operator
```

**Impact:**
- If ILRM.oracle is set to an operator address, Oracle contract calls fail
- If ILRM.oracle is set to Oracle contract address, individual operator signatures are still checked in Oracle but not in ILRM

**Recommendation:**
Choose one architecture:
1. Set ILRM.oracle = Oracle contract address, OR
2. Have operators call ILRM directly and remove Oracle contract intermediary

---

### 🟠 H-04: Unbounded Loop DoS in AssetRegistry (AssetRegistry.sol)

**Location:** `AssetRegistry.sol:215-225`, `233-254`, `259-275`

**Severity:** HIGH

**Description:**
`freezeAssets`, `unfreezeAssets`, and `applyFallbackLicense` iterate over unbounded arrays.

```solidity
// Line 215-225 - DoS if user has many assets
for (uint256 i = 0; i < partyAssets.length; i++) {
    bytes32 assetId = partyAssets[i];
    Asset storage asset = _assets[assetId];
    // ...
}
```

**Impact:**
- If a user registers thousands of assets, freeze/unfreeze exceeds block gas limit
- Dispute resolution becomes impossible for users with many assets
- **Potential softlock** - dispute cannot resolve

**Recommendation:**
- Add maximum assets per owner limit
- Implement pagination for freeze/unfreeze
- Or require explicit asset list instead of all assets

---

### 🟠 H-05: Anyone Can Register Assets for Any Owner (AssetRegistry.sol)

**Location:** `AssetRegistry.sol:84-106` (`registerAsset`)

**Severity:** HIGH

**Description:**
No access control on who can register assets. Anyone can register an asset with any address as owner.

```solidity
function registerAsset(
    bytes32 assetId,
    address owner,  // Anyone can set this to any address
    bytes32 licenseTermsHash
) external override nonReentrant {
    // No check that msg.sender == owner or has authority
}
```

**Impact:**
- Attacker can register fake assets under victim's address
- When dispute is initiated, victim's "assets" are frozen (DoS)
- Spamming attack on storage

**Recommendation:**
```solidity
// Option 1: Only owner can register
require(msg.sender == owner, "Must be owner");

// Option 2: Signature-based registration
require(verifySignature(owner, assetId, signature), "Invalid signature");
```

---

## Medium Severity Findings

### 🟡 M-01: Treasury Type Confusion - ETH vs ERC20 (ILRM.sol)

**Location:** `ILRM.sol:79, 264-266, 475-481`

**Description:**
The `treasury` variable tracks ETH from counter-fees, but initiator incentives are expected to be paid in tokens.

**Impact:**
- Confusion about what treasury holds
- Incentive payment logic is broken (see C-01)

**Recommendation:**
Separate ETH treasury from token treasury, or integrate with Treasury contract.

---

### 🟡 M-02: Centralization Risk - Single Owner (All Contracts)

**Location:** All contracts use `Ownable`

**Description:**
Single owner controls:
- ILRM: Harassment scores, treasury withdrawals
- Treasury: ILRM address, caps, emergency withdrawals
- Oracle: ILRM address, oracle registration
- AssetRegistry: ILRM authorization

**Impact:**
- Owner compromise = total protocol compromise
- No timelock on critical operations

**Recommendation:**
- Implement multi-sig or DAO governance
- Add timelock for admin operations
- Emit events for all admin actions

---

### 🟡 M-03: Missing Event for Harassment Score Update (ILRM.sol)

**Location:** `ILRM.sol:465-467`

**Description:**
`updateHarassmentScore` doesn't emit an event.

**Impact:**
- Off-chain monitoring cannot track score changes
- Reduced transparency

**Recommendation:**
Add event emission.

---

### 🟡 M-04: requestSubsidy Caller Not Validated (Treasury.sol)

**Location:** `Treasury.sol:187-261`

**Description:**
Anyone can call `requestSubsidy` on behalf of a participant. While participant eligibility is checked, the caller is not.

**Impact:**
- Front-running: Attacker can observe pending subsidy request and front-run
- Griefing: Could trigger subsidy at wrong time

**Recommendation:**
Require `msg.sender == participant` or authorized caller.

---

### 🟡 M-05: Domain Separator Immutability Issue (Oracle.sol)

**Location:** `Oracle.sol:82-90`

**Description:**
`DOMAIN_SEPARATOR` is computed with `block.chainid` at deployment. If contract is used on a forked chain, signatures become valid cross-chain.

**Impact:**
- Signature replay across forks
- Limited impact if chain ID changes (unlikely)

**Recommendation:**
Consider computing domain separator dynamically or add chain ID validation.

---

### 🟡 M-06: Counter-Proposal Timing Manipulation (ILRM.sol)

**Location:** `ILRM.sol:277`

**Description:**
Each counter-proposal extends timeout by exactly 1 day. With 3 counters, parties can extend by 3 days total.

**Impact:**
- Slightly prolongs disputes beyond expected 7 days
- Economic calculations may be affected
- Limited impact due to MAX_COUNTERS cap

---

### 🟡 M-07: Deployer Auto-Registered as Oracle (Oracle.sol)

**Location:** `Oracle.sol:92-94`

**Description:**
Constructor automatically registers deployer as oracle operator.

**Impact:**
- Deployer address may be a temporary deployment wallet
- If deployer key is compromised, they remain an oracle

**Recommendation:**
Remove auto-registration or add explicit first-oracle setup.

---

### 🟡 M-08: Int256 to Uint256 Conversion Edge Case (Treasury.sol)

**Location:** `Treasury.sol:320-338`

**Description:**
`updateHarassmentScore` accepts `int256 scoreDelta`. The conversion `uint256(-scoreDelta)` with `type(int256).min` would overflow.

```solidity
if (scoreDelta >= 0) {
    newScore = oldScore + uint256(scoreDelta);
} else {
    uint256 decrease = uint256(-scoreDelta);  // Overflow if scoreDelta == type(int256).min
}
```

**Impact:**
- Only callable by ILRM, so limited attack surface
- Unlikely to pass such extreme values

**Recommendation:**
Add bounds check: `require(scoreDelta > type(int256).min, "Invalid delta");`

---

## Low Severity Findings

### 🟢 L-01: Inconsistent Error Handling (Treasury.sol)

**Location:** `Treasury.sol:349`

Uses `require` with string instead of custom error like rest of contract.

---

### 🟢 L-02: Missing Events for Admin Actions

**Locations:**
- `ILRM.sol:465-467` - updateHarassmentScore
- `ILRM.sol:475-481` - withdrawTreasury
- `AssetRegistry.sol:346-357` - authorizeILRM/revokeILRM

---

### 🟢 L-03: Struct Packing Optimization (ILRM.sol)

`Dispute` struct could be packed more efficiently for gas savings.

---

### 🟢 L-04: totalLicenses Underflow Risk (AssetRegistry.sol)

**Location:** `AssetRegistry.sol:198`

If `revokeLicense` is called on already-revoked license, underflow would occur. Mitigated by `!grant.active` check, but redundant decrement should be guarded.

---

### 🟢 L-05: No Pause Mechanism

No contract has emergency pause functionality. In case of exploit, there's no way to halt operations.

---

### 🟢 L-06: ETH Sent to BURN_ADDRESS May Not Be Burnt

**Location:** `ILRM.sol:165, 260`

Sending ETH to 0xdead doesn't guarantee burning - that address could theoretically execute code or be a contract on some chains.

---

## Informational

### ℹ️ I-01: Consider Using OpenZeppelin's Pausable

For emergency situations, adding `Pausable` would allow halting operations.

### ℹ️ I-02: Consider Two-Step Ownership Transfer

Use `Ownable2Step` instead of `Ownable` for safer ownership transfers.

### ℹ️ I-03: Add NatSpec Documentation

Some functions lack complete NatSpec documentation.

### ℹ️ I-04: Consider Upgradability

Contracts are not upgradable. If bugs are found post-deployment, new contracts must be deployed and state migrated.

---

## Recommendations Summary

### Must Fix Before Mainnet

1. **C-01:** Fix initiator incentive transfer logic
2. **C-02:** Require signatures in Oracle.submitProposal
3. **H-02:** Require ILRM to be set in Treasury before subsidies

### Should Fix Before Mainnet

4. **H-01:** Implement or remove signature verification TODO
5. **H-03:** Clarify Oracle-ILRM architecture
6. **H-04:** Add asset limit or pagination in AssetRegistry
7. **H-05:** Add access control to registerAsset

### Recommended

8. Add multi-sig/timelock for admin functions
9. Add missing events
10. Consider adding Pausable pattern
11. Audit gas costs for loops

---

## Files Analyzed

| File | Lines | Issues |
|------|-------|--------|
| ILRM.sol | 488 | C-01, H-01, M-01, M-03, L-02, L-03, L-06 |
| Treasury.sol | 453 | H-02, M-02, M-04, M-08, L-01 |
| Oracle.sol | 292 | C-02, H-03, M-05, M-07 |
| AssetRegistry.sol | 358 | H-04, H-05, L-02, L-04 |

---

*This audit report is provided for informational purposes. A professional third-party audit is recommended before mainnet deployment.*
