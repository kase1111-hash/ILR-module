# NatLangChain Treasury

**Version:** 1.5
**Status:** Fully Implemented
**Contract:** `contracts/Treasury.sol`
**Last Updated:** January 2026

---

## Purpose

The NatLangChain Treasury serves three core functions:

1. **Hold Protocol Funds**: Accumulated from burns, counter-fees, and escalated stakes
2. **Subsidize Defensive Stakes**: Provide stake assistance for low-resource participants in ILRM disputes
3. **Maintain Algorithmic Control**: Fully on-chain rules with no discretionary human intervention

---

## Architecture

```
                     +-------------------+
                     |     Treasury      |
                     +-------------------+
                              |
        +---------------------+---------------------+
        |                     |                     |
        v                     v                     v
+---------------+     +---------------+     +---------------+
|    Inflows    |     |   Subsidies   |     | Anti-Abuse    |
+---------------+     +---------------+     +---------------+
| - Burns       |     | - Per-dispute |     | - Harassment  |
| - Counter-fees|     | - Per-user    |     |   scores      |
| - Escalations |     | - Dynamic     |     | - DID sybil   |
+---------------+     | - Tiered      |     | - Single use  |
                      +---------------+     +---------------+
```

---

## Implementation Status

| Feature | Status | Location |
|---------|--------|----------|
| Deposit Burns/Fees | Implemented | `Treasury.sol:151-171` |
| Defensive Subsidies | Implemented | `Treasury.sol:189-273` |
| Per-Dispute Caps | Implemented | `Treasury.sol:242-244` |
| Per-Participant Rolling Caps | Implemented | `Treasury.sol:247-250` |
| Harassment Score Checks | Implemented | `Treasury.sol:228-230` |
| Anti-Sybil (Single Subsidy/Dispute) | Implemented | `Treasury.sol:200-203` |
| Dynamic Caps | Implemented | `Treasury.sol:497-531` |
| Tiered Subsidies | Implemented | `Treasury.sol:617-646` |
| DID-Based Subsidies | Implemented | `Treasury.sol:812-1044` |
| Harassment Score Decay | Implemented | `Treasury.sol` |
| Multi-Token Support | Not Implemented | Future enhancement |

---

## High-Level Flow

### Inflows

| Source | Description | Implementation |
|--------|-------------|----------------|
| Burns | 50% of stakes from unresolved disputes (TimeoutWithBurn) | `depositBurn()` |
| Counter-Fees | Exponential fees from counter-proposals | `depositBurn()` |
| Escalated Stakes | Additional stakes from repeat frivolous initiators | `depositBurn()` |
| ETH Deposits | Direct ETH contributions | `depositETH()` |

### Eligibility Check

A participant qualifies for subsidy if:

1. **Target of Dispute**: Must be counterparty, not initiator
2. **Opt-In Request**: Must explicitly call `requestSubsidy()`
3. **Good History**: Harassment score below threshold (50)
4. **Available Allowance**: Within per-participant rolling window cap
5. **Dispute Not Subsidized**: No prior subsidy for this dispute
6. **DID Verified** (optional): Higher sybil scores unlock bonus subsidies

### Subsidy Calculation

```
baseSubsidy = min(stakeNeeded, maxPerDispute)
availableAllowance = getEffectiveMaxPerParticipant() - participantSubsidyUsed[participant]
subsidyWithCap = min(baseSubsidy, availableAllowance)
subsidyMultiplier = getSubsidyMultiplier(participant)  // Based on harassment tier
finalSubsidy = subsidyWithCap * subsidyMultiplier / 10000
```

### Payout & Safety

- Funds transferred directly from treasury to participant for staking in ILRM
- Max per-dispute limit enforced
- Max per-participant rolling window enforced
- Treasury balance check ensures sustainability

---

## Anti-Sybil / Abuse Protections

| Protection | Description | Threshold |
|------------|-------------|-----------|
| Single Subsidy/Dispute | Only one subsidy per dispute | Boolean flag |
| Harassment Score | High scores block subsidies | Score >= 50 |
| Rolling Window Caps | Per-participant limits reset periodically | Configurable period |
| DID Sybil Score | Verifiable credentials boost eligibility | Score 0-100 |
| Tiered Subsidies | Graduated reduction for borderline scores | 4 tiers |

---

## Constants

| Constant | Default Value | Description |
|----------|---------------|-------------|
| `HARASSMENT_THRESHOLD` | 50 | Score at which subsidies are blocked |
| `maxPerDispute` | Configurable | Maximum subsidy per dispute |
| `maxPerParticipant` | Configurable | Rolling window cap per participant |
| `rollingWindowPeriod` | Configurable | Period for cap reset |

---

## Dynamic Caps

Dynamic caps scale `maxPerParticipant` based on current treasury balance to ensure sustainability.

### Configuration

```solidity
// Enable dynamic caps at 10% of treasury with 1 token floor
treasury.setDynamicCapConfig(
    true,           // enabled
    1000,           // 10% (1000 bps)
    1e18            // 1 token floor
);
```

### State Variables

| Variable | Type | Description |
|----------|------|-------------|
| `dynamicCapEnabled` | `bool` | Toggle for dynamic caps |
| `dynamicCapPercentageBps` | `uint256` | Percentage of treasury (basis points) |
| `dynamicCapFloor` | `uint256` | Minimum cap floor |

### Functions

| Function | Description |
|----------|-------------|
| `setDynamicCapConfig()` | Configure dynamic cap settings |
| `calculateDynamicCap()` | Calculate current cap from treasury balance |
| `getEffectiveMaxPerParticipant()` | Get effective cap (considers dynamic when enabled) |

---

## Tiered Subsidies

Tiered subsidies provide graduated reduction based on harassment score - lower scores receive higher subsidies.

### Tier System

| Tier | Harassment Score Range | Default Multiplier |
|------|------------------------|-------------------|
| 0 | 0 - tier1Threshold | 100% (full subsidy) |
| 1 | tier1Threshold - tier2Threshold | tier1MultiplierBps |
| 2 | tier2Threshold - tier3Threshold | tier2MultiplierBps |
| 3 | tier3Threshold - HARASSMENT_THRESHOLD | tier3MultiplierBps |
| Blocked | >= HARASSMENT_THRESHOLD | 0% (no subsidy) |

### Configuration

```solidity
// Enable tiered subsidies with graduated reduction
treasury.setTieredSubsidyConfig(
    true,    // enabled
    10,      // tier1Threshold (score >= 10)
    25,      // tier2Threshold (score >= 25)
    40,      // tier3Threshold (score >= 40)
    7500,    // tier1 = 75%
    5000,    // tier2 = 50%
    2500     // tier3 = 25%
);
```

### State Variables

| Variable | Type | Description |
|----------|------|-------------|
| `tieredSubsidiesEnabled` | `bool` | Toggle for tiered subsidies |
| `tier1Threshold` | `uint256` | Harassment score for tier 1 boundary |
| `tier2Threshold` | `uint256` | Harassment score for tier 2 boundary |
| `tier3Threshold` | `uint256` | Harassment score for tier 3 boundary |
| `tier1MultiplierBps` | `uint256` | Tier 1 subsidy multiplier (basis points) |
| `tier2MultiplierBps` | `uint256` | Tier 2 subsidy multiplier (basis points) |
| `tier3MultiplierBps` | `uint256` | Tier 3 subsidy multiplier (basis points) |

### Functions

| Function | Description |
|----------|-------------|
| `setTieredSubsidyConfig()` | Configure tier thresholds and multipliers |
| `getSubsidyMultiplier()` | Get multiplier and tier for a participant |

---

## DID Integration

The Treasury integrates with the DIDRegistry to provide enhanced subsidy eligibility for verified participants.

### Features

| Feature | Description |
|---------|-------------|
| DID Bonus Multiplier | Higher sybil scores unlock bonus subsidies |
| Sybil Resistance | Verified credentials prevent abuse |
| Minimum Sybil Score | Optional requirement for subsidy eligibility |

### Configuration

```solidity
treasury.setDIDSubsidyConfig(
    didRegistry,    // DIDRegistry contract address
    true,           // enabled
    20,             // minSybilScore (optional minimum)
    1500            // bonusMultiplierBps (15% bonus for verified DIDs)
);
```

### Subsidy Calculation with DID

```
baseSubsidy = calculateSubsidy(...)
if (didEnabled && participant.hasDID()) {
    sybilScore = didRegistry.calculateSybilScore(participant.did)
    if (sybilScore >= minSybilScore) {
        bonus = baseSubsidy * bonusMultiplierBps / 10000
        finalSubsidy = baseSubsidy + bonus
    }
}
```

---

## Key Functions

### Inflows

```solidity
// Deposit ERC20 tokens (from burns, counter-fees)
function depositBurn(uint256 amount) external;

// Deposit ETH directly
function depositETH() external payable;
```

### Subsidies

```solidity
// Request subsidy for a dispute
function requestSubsidy(
    uint256 disputeId,
    uint256 stakeNeeded,
    address participant
) external returns (uint256 subsidyAmount);

// Preview subsidy without executing
function calculateSubsidy(
    uint256 stakeNeeded,
    address participant
) external view returns (uint256);

// Get remaining allowance for participant
function getRemainingAllowance(
    address participant
) external view returns (uint256);
```

### Administration

```solidity
// Update harassment score (owner only)
function updateHarassmentScore(address participant, uint256 score) external;

// Set maximum per dispute
function setMaxPerDispute(uint256 newMax) external;

// Set maximum per participant
function setMaxPerParticipant(uint256 newMax) external;

// Configure dynamic caps
function setDynamicCapConfig(
    bool enabled,
    uint256 percentageBps,
    uint256 floor
) external;

// Configure tiered subsidies
function setTieredSubsidyConfig(
    bool enabled,
    uint256 t1, uint256 t2, uint256 t3,
    uint256 m1, uint256 m2, uint256 m3
) external;
```

### Emergency

```solidity
// Emergency withdrawal (owner only)
function emergencyWithdrawETH(address to, uint256 amount) external;
function emergencyWithdrawToken(address to, uint256 amount) external;
```

---

## Events

| Event | Description |
|-------|-------------|
| `TreasuryReceived(uint256 amount)` | Funds deposited |
| `SubsidyFunded(address participant, uint256 disputeId, uint256 amount)` | Subsidy granted |
| `HarassmentScoreUpdated(address participant, uint256 oldScore, uint256 newScore)` | Score changed |
| `DynamicCapConfigUpdated(bool enabled, uint256 percentageBps, uint256 floor)` | Dynamic cap config changed |
| `TieredSubsidyConfigUpdated(...)` | Tier config changed |

---

## Security Considerations

| Concern | Mitigation |
|---------|------------|
| Reentrancy | `ReentrancyGuard` on all external calls |
| Sybil Attacks | Single subsidy per dispute, DID verification, harassment scores |
| Treasury Drain | Per-dispute and per-participant caps, dynamic scaling |
| Unauthorized Access | `Ownable2Step` for admin functions |
| Emergency Situations | `Pausable` for emergency stops |

---

## Future Enhancements

| Enhancement | Priority | Description |
|-------------|----------|-------------|
| Multi-Token Support | Medium | Accept multiple staking tokens or native ETH |
| Cross-Chain Treasury | Low | Unified treasury across L2s |
| DAO Governance | Low | Community-controlled parameter changes |

---

## Related Documentation

- [ILRM Specification](./SPEC.md)
- [Safety Invariants](./Protocol-Safety-Invariants.md)
- [Security Audit](./docs/SECURITY_AUDIT_REPORT.md)
