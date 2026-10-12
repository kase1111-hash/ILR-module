# ILRM Subgraph

TheGraph subgraph for indexing NatLangChain ILRM Protocol events.

## Overview

The subgraph indexes **every event** the five core contracts emit:

| Data source | Contract (artifact) | Indexed |
|-------------|---------------------|---------|
| `ILRM` | `contracts/ILRM.sol` (`ILRM`) | dispute lifecycle, LLM proposals (incl. `ProposalSuperseded`), counter-proposals, burns, stake subsidies (`StakeSubsidized`, `SubsidyReturned`, `SubsidyTreasuryUpdated`), reserves, harassment scores, ownership, pause |
| `Treasury` | `contracts/Treasury.sol` (`NatLangChainTreasury`) | subsidy grants (`SubsidyFunded`), inflows, harassment scores, caps, ILRM pointer, ownership, pause |
| `Oracle` | `contracts/Oracle.sol` (`NatLangChainOracle`) | requests and cancellations, round fills (`ProposalRoundFilled`), owner resets (`ProposalReset`, `ProposalRoundReopened`), operators, ownership |
| `L3Bridge` | `contracts/scaling/L3Bridge.sol` (`L3Bridge`) | state commitments, finalization, commit-reveal fraud proofs (`FraudProofCommitted/Revealed/Refunded/Forfeited/Validated`), chain rollbacks, dispute bridging and settlement, roles, status, ownership, pause |
| `AssetRegistry` | `contracts/AssetRegistry.sol` (`NatLangChainAssetRegistry`) | assets, dispute freezes, fallback licenses, license grants and revocations, ILRM authorization, ownership |

`npm run check-abis` prints any contract event that subgraph.yaml does not handle, so
newly added events are easy to spot.

## Prerequisites

- Node.js v20.18.1+ (graph-cli 0.98)
- Compiled contracts (`forge build` or `npx hardhat compile` in the repository root) when
  refreshing ABIs

## Setup

```bash
cd subgraph
npm install          # graph-cli, graph-ts and matchstick are local dev dependencies
npm run codegen      # generate types from abis/ and schema.graphql
npm run build        # compile the mappings to WebAssembly
npm test             # matchstick unit tests (tests/*.test.ts); downloads the matchstick binary once
```

## Keeping the ABIs in sync

`abis/*.json` are generated from the compiler artifacts and committed, so the subgraph builds
without compiling the contracts. Which artifact feeds which file is configured in
[`abi-sources.json`](abi-sources.json).

```bash
# from the repository root
forge build                # or: npx hardhat compile
cd subgraph
npm run sync-abis          # rewrite abis/*.json (canonical form: Foundry and Hardhat give identical files)
npm run check-abis         # exit 1 if abis/*.json drifted or a handler names an event the contract no longer emits
```

`node scripts/sync-abis.js --from foundry|hardhat` picks a specific artifact set (default: the
most recently written one).

The repository's Hardhat suite (`test/Subgraph.manifest.test.js`, run by `npm test` in the
repository root and in CI) also fails when a `subgraph.yaml` handler names an event the compiled
contract does not emit, when `abis/` disagrees with the compiled fragment of a handled event, or
when a handler is not exported by its mapping.

## Adding a new event

1. Compile the contracts and run `npm run sync-abis`.
2. Add the event to the data source's `eventHandlers` in `subgraph.yaml`. The signature must
   match the ABI exactly, e.g. `Foo(indexed uint256,address,bytes32[])`; `npm run check-abis`
   lists the exact signatures of events not indexed yet.
3. `npm run codegen`, then export the handler from the data source's mapping in `src/`.
   - Configuration, role, ownership and fund-management events usually need no schema change:
     log them with `newAdminEvent(...)` from `src/common.ts` and, if they carry state worth
     querying, store it on `ProtocolContract`. Role grants use `setRole(...)`.
   - Lifecycle events get their own entity in `schema.graphql`.
4. Add a matchstick test under `tests/` and run `npm run build && npm test`.

## Configuration

Before deployment, update `subgraph.yaml`:

1. Replace the zero addresses with the deployed addresses and set each `startBlock` to the
   deployment block (at or before it, so constructor events such as `OwnershipTransferred` are
   indexed and every lifecycle starts from its first event):
   ```yaml
   source:
     address: "0x..."
     startBlock: 12345
   ```
2. Set the correct network (`optimism`, `optimism-sepolia`, `arbitrum-one`, ...).

## Deployment

### TheGraph Studio (Recommended)

1. Create a subgraph at [TheGraph Studio](https://thegraph.com/studio/)
2. Get your deploy key
3. Authenticate and deploy:

```bash
npx graph auth <DEPLOY_KEY>
npm run deploy
```

### Local Development

```bash
# Start a local Graph Node (requires Docker), then
npm run create-local
npm run deploy-local
```

## Indexed Entities

### Disputes (ILRM)

| Entity | Description |
|--------|-------------|
| `Dispute` | Lifecycle, stakes (initiator stake and fallback terms read once via `ILRM.disputes()`), live proposal, outcome |
| `Party` | Participant stats: own funds staked, burn share, ILRM and Treasury harassment scores, subsidies received |
| `Proposal` | Every stored proposal with round, `keccak256` hash and status (`LIVE`, `SUPERSEDED`, `VOIDED_BY_COUNTER`, `ACCEPTED`, `EXPIRED`) |
| `Counter` | Counter-proposals with the burned fee and, for direct calls, the new evidence hash |
| `VoluntaryRequest` | `initiateVoluntaryRequest` logs (no dispute is created) |
| `Burn` | Stake burns on timeout |
| `HarassmentScore` | Score history, tagged `ILRM` or `TREASURY` |

### Subsidies and Treasury

| Entity | Description |
|--------|-------------|
| `StakeSubsidy` | Treasury co-stake escrowed in ILRM, with repayments |
| `SubsidyReturn` | Pro-rata repayment to the funder on resolution |
| `TreasurySubsidy` | Grant as recorded by the Treasury (`SubsidyFunded`) |
| `TreasuryDeposit` | Treasury inflows by reason |

### Oracle

| Entity | Description |
|--------|-------------|
| `OracleDispute` | Per-dispute Oracle state: pending request, next nonce, counts |
| `OracleRound` | One negotiation round (dispute `counterCount`) and its live proposal hash |
| `OracleSubmission` | Admitted proposal with operator, nonce, signed evidence hash, voided flag |
| `OracleReset` | Owner reset with reason and re-opened round |

### L3 Bridge

| Entity | Description |
|--------|-------------|
| `L3StateCommitment` | State root at a chain height: `PENDING`, `FINALIZED`, `REJECTED` or `ORPHANED` |
| `FraudProofCommitment` | Bonded commit-reveal challenge: `PENDING`, `WON`, `REFUNDED` or `FORFEITED` |
| `FraudProofChallenge` | Successful challenge of a root (commit-reveal or legacy direct) |
| `L3BridgedDispute` | Dispute bridged to L3 and its settlement |
| `L3Chain` | Committed and finalized chain heads per bridge |

### Assets

| Entity | Description |
|--------|-------------|
| `Asset` | Registered IP asset, freeze state, current license terms |
| `License` | Grant per licensee (duration, royalty and exclusivity read via `getLicense`) |
| `AssetFreeze` | Freeze/unfreeze history per asset and dispute |
| `FallbackLicenseApplication` | Fallback terms applied to a dispute's frozen assets |

### Contracts, roles and admin log

| Entity | Description |
|--------|-------------|
| `ProtocolContract` | Owner, pending owner, pause state and exposed configuration per contract |
| `RoleMember` | Oracle operators, authorized ILRMs, L3 dispute bridgers and settlement relayers |
| `AdminEvent` | Uniform log of configuration, ownership, pause and fund-management events |

### Metrics

| Entity | Description |
|--------|-------------|
| `DailyMetric` | Daily protocol statistics |
| `ProtocolMetric` | Cumulative protocol stats (singleton `protocol`) |
| `TreasuryMetric` | Daily treasury stats |
| `OracleMetric` | Daily oracle stats |
| `L3Metric` | Daily L3 stats |

## Known limitations

These come from what the contracts emit, not from the subgraph:

- `AssetRegistry.transferAsset`, `Oracle.revokeOracle`, `Oracle.setILRM`, `L3Bridge.setILRM`,
  `L3Bridge.setCommitRevealEnabled`, `Treasury.setMinReserve`, `Treasury.emergencyWithdraw*` and
  `L3Bridge.updateSequencerConfig` (other than a sequencer change) emit no event, so asset
  owners stay the registering owner, revoked operators still show as active, and those settings
  are not indexed.
- Constructor-set configuration (Treasury caps, L3 sequencer) appears only after its first
  update event.
- The initiator incentive paid on non-participation, the excess of a counter-proposal fee
  (credited to the ILRM treasury) and the fee of a voluntary request sent through another
  contract are not in any event.
- `Treasury.deposit()` takes a free-text reason, so a token deposit labelled `"eth"` is
  indistinguishable from an ETH transfer.
- Disputes are keyed by ILRM dispute id; another ILRM sharing the AssetRegistry (for example
  `MultiPartyILRM`) would collide.
- The deferred modules (`contracts/modules/*`, `L3DisputeBatcher`, `BatchQueue`, ...) are not
  indexed.

## Example Queries

### Get Active Disputes

```graphql
query ActiveDisputes {
  disputes(where: { state: ACTIVE }, orderBy: startTime, orderDirection: desc, first: 10) {
    id
    initiator { id }
    counterparty { id }
    initiatorStake
    counterpartyStake
    stakeSubsidy { funder amount amountReturned }
    counterCount
    currentProposal { content status }
  }
}
```

### Get Party Statistics

```graphql
query PartyStats($address: ID!) {
  party(id: $address) {
    totalDisputes
    disputesResolved
    disputesTimedOut
    disputesDefaulted
    totalStaked
    totalBurned
    harassmentScore
    treasuryHarassmentScore
  }
}
```

### Get Protocol Metrics

```graphql
query ProtocolOverview {
  protocolMetric(id: "protocol") {
    totalDisputes
    activeDisputes
    resolvedDisputes
    totalValueStaked
    totalValueBurned
    totalSubsidiesDistributed
    totalSubsidiesReturned
  }
}
```

### Get Daily Activity

```graphql
query DailyActivity($date: ID!) {
  dailyMetric(id: $date) {
    disputesInitiated
    disputesResolved
    totalStaked
    totalBurned
    proposals
    counterProposals
  }
}
```

### Get L3 State Commitments and Challenges

```graphql
query L3Commitments {
  l3StateCommitments(orderBy: submittedAt, orderDirection: desc, first: 10) {
    id
    height
    disputeCount
    status
    challengeDeadline
    finalizedAt
    challenge { challenger mode reward orphanedCount }
    fraudProofCommitments { challenger bond status }
  }
}
```

### Get the Oracle Rounds of a Dispute

```graphql
query OracleRounds($disputeId: ID!) {
  oracleDispute(id: $disputeId) {
    pending
    nextNonce
    rounds { round filled proposalHash reopenCount }
    resets { round reason voidedProposalHash }
  }
}
```

## Support

- [TheGraph Documentation](https://thegraph.com/docs/)
- [ILRM Protocol Docs](../docs/)
