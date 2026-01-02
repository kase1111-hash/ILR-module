# ILRM Subgraph

TheGraph subgraph for indexing NatLangChain ILRM Protocol events.

## Overview

This subgraph indexes all on-chain events from the ILRM protocol contracts:
- **ILRM** - Core dispute resolution
- **Treasury** - Fund management and subsidies
- **Oracle** - LLM proposal bridge
- **L3Bridge** - Layer 3 scaling
- **AssetRegistry** - IP asset management

## Prerequisites

- Node.js v18+
- Graph CLI: `npm install -g @graphprotocol/graph-cli`
- Access to TheGraph Studio or hosted service

## Setup

```bash
# Install dependencies
cd subgraph
npm install

# Generate types from ABIs and schema
npm run codegen

# Build the subgraph
npm run build
```

## Configuration

Before deployment, update `subgraph.yaml`:

1. Replace contract addresses with deployed addresses:
   ```yaml
   source:
     address: "0x..." # Your deployed ILRM address
     startBlock: 12345 # Block number of deployment
   ```

2. Set the correct network:
   ```yaml
   network: optimism # or optimism-sepolia, arbitrum, etc.
   ```

## Deployment

### TheGraph Studio (Recommended)

1. Create a subgraph at [TheGraph Studio](https://thegraph.com/studio/)
2. Get your deploy key
3. Authenticate and deploy:

```bash
graph auth --studio <DEPLOY_KEY>
npm run deploy
```

### Hosted Service (Legacy)

```bash
graph auth --product hosted-service <ACCESS_TOKEN>
npm run deploy:hosted
```

### Local Development

```bash
# Start local Graph Node (requires Docker)
docker-compose up -d

# Create and deploy locally
npm run create-local
npm run deploy-local
```

## Indexed Entities

### Core Entities

| Entity | Description |
|--------|-------------|
| `Dispute` | Full dispute lifecycle with state tracking |
| `Party` | Protocol participants with stats |
| `Proposal` | LLM-generated proposals |
| `Counter` | Counter-proposal records |

### Financial Entities

| Entity | Description |
|--------|-------------|
| `Subsidy` | Treasury subsidy distributions |
| `Burn` | Token burn records |
| `HarassmentScore` | Score update history |

### L3 Scaling Entities

| Entity | Description |
|--------|-------------|
| `L3Batch` | Batch submissions and status |
| `FraudProofChallenge` | Challenge records |

### Asset Entities

| Entity | Description |
|--------|-------------|
| `Asset` | Registered IP assets |
| `License` | License grants including fallbacks |
| `AssetFreeze` | Freeze/unfreeze history |

### Metrics

| Entity | Description |
|--------|-------------|
| `DailyMetric` | Daily protocol statistics |
| `ProtocolMetric` | Cumulative protocol stats |
| `TreasuryMetric` | Daily treasury stats |
| `OracleMetric` | Daily oracle stats |
| `L3Metric` | Daily L3 stats |

## Example Queries

### Get Active Disputes

```graphql
query ActiveDisputes {
  disputes(
    where: { state: ACTIVE }
    orderBy: startTime
    orderDirection: desc
    first: 10
  ) {
    id
    initiator {
      id
    }
    counterparty {
      id
    }
    initiatorStake
    counterpartyStake
    state
    counterCount
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
    totalStaked
    totalBurned
    harassmentScore
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
  }
}
```

### Get Daily Activity

```graphql
query DailyActivity($date: BigInt!) {
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

### Get L3 Batch Status

```graphql
query L3Batches {
  l3Batches(
    orderBy: submittedAt
    orderDirection: desc
    first: 10
  ) {
    id
    stateRoot
    disputeCount
    status
    challenged
    submittedAt
    finalizedAt
  }
}
```

## Testing

```bash
# Run unit tests
npm run test
```

## Contract ABIs

ABIs should be placed in the `abis/` directory. Generate them from your compiled contracts:

```bash
# From project root
cp out/ILRM.sol/ILRM.json subgraph/abis/
cp out/Treasury.sol/Treasury.json subgraph/abis/
cp out/Oracle.sol/Oracle.json subgraph/abis/
cp out/L3Bridge.sol/L3Bridge.json subgraph/abis/
cp out/AssetRegistry.sol/AssetRegistry.json subgraph/abis/
```

## Support

- [TheGraph Documentation](https://thegraph.com/docs/)
- [ILRM Protocol Docs](../docs/)
