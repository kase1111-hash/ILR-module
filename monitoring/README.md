# ILRM Protocol Monitoring

Comprehensive monitoring infrastructure for the NatLangChain ILRM Protocol.

## Overview

This directory contains monitoring configurations and queries for:
- **Dune Analytics** - On-chain data dashboards
- **Alerts** - Real-time event notifications
- **Grafana** - Infrastructure metrics (optional)

## Quick Start

### 1. Dune Analytics Setup

1. Create a Dune account at [dune.com](https://dune.com)
2. Create a new dashboard
3. Import queries from `dune/` directory:
   - `disputes_overview.sql` - Core dispute metrics
   - `financial_metrics.sql` - TVL, burns, subsidies
   - `participant_analytics.sql` - User behavior
   - `l3_bridge_metrics.sql` - L3 scaling metrics

4. Replace placeholder addresses:
   ```sql
   -- Replace with your deployed contract addresses
   contract_address = 0xYOUR_ILRM_ADDRESS
   ```

5. Replace event signatures:
   ```bash
   # Generate event signatures
   cast sig "DisputeInitiated(uint256,address,address,bytes32)"
   # Output: 0x...
   ```

### 2. Alert Configuration

1. Choose an alerting platform:
   - **OpenZeppelin Defender** (recommended for production)
   - **Tenderly**
   - **Custom monitoring service**

2. Configure webhooks in `alerts/alert-config.yaml`:
   ```yaml
   channels:
     slack_critical:
       webhook_url: "${SLACK_CRITICAL_WEBHOOK}"
   ```

3. Set environment variables:
   ```bash
   export SLACK_CRITICAL_WEBHOOK="https://hooks.slack.com/..."
   export PAGERDUTY_SERVICE_KEY="..."
   ```

4. Deploy alerts to your monitoring platform

## Dune Dashboards

### Disputes Overview
Key metrics for dispute resolution:
- Total disputes (all-time, 24h, 7d, 30d)
- Daily dispute trends
- Resolution outcomes breakdown
- Average dispute duration

### Financial Metrics
Protocol economics:
- Total Value Staked (TVL)
- Total Value Burned
- Daily stake/burn volume
- Treasury balance over time
- Counter-proposal fees
- Subsidy distribution

### Participant Analytics
User behavior insights:
- Unique participants over time
- Top participants by activity
- Harassment score distribution
- Repeat dispute pairs
- New vs returning users
- DID and ZK mode adoption

### L3 Bridge Metrics
Layer 3 scaling performance:
- Batch submission rate
- Finalization rate
- Challenge statistics
- Average batch size
- Time to finalization
- Pending batches

## Alert Severity Levels

| Level | Response Time | Examples |
|-------|--------------|----------|
| **Critical (P0)** | Immediate | Contract paused, ownership transfer, large burn |
| **High (P1)** | < 1 hour | Fraud proof challenge, oracle delay, low treasury |
| **Medium (P2)** | < 24 hours | Timeout approaching, unusual volume, delayed finalization |
| **Low (P3)** | Informational | New disputes, resolutions, activity logs |

## Recommended Alert Channels

| Severity | Channels |
|----------|----------|
| Critical | PagerDuty + Slack #critical + Email oncall |
| High | Slack #alerts + Email team |
| Medium | Slack #monitoring |
| Low | Slack #activity |

## Key Metrics to Monitor

### Protocol Health
- [ ] Active disputes count
- [ ] Resolution rate (% resolved within 7 days)
- [ ] Timeout rate (% ending in timeout)
- [ ] Counter-proposal rate
- [ ] Average stakes

### Economic Health
- [ ] Treasury balance
- [ ] Daily burn volume
- [ ] Subsidy utilization
- [ ] Counter fee collection

### Security Indicators
- [ ] Harassment score spikes
- [ ] Repeat dispute pairs
- [ ] Unusual participant behavior
- [ ] Contract pause events

### L3 Performance
- [ ] Batch finalization rate
- [ ] Challenge frequency
- [ ] Average disputes per batch
- [ ] Pending batch queue

## Grafana Setup (Optional)

For infrastructure monitoring:

1. Install Grafana
2. Add data sources:
   - Prometheus (node metrics)
   - PostgreSQL (subgraph data)

3. Import dashboards from `grafana/`:
   ```bash
   # Using Grafana CLI
   grafana-cli dashboards import grafana/ilrm-protocol.json
   ```

## Integration with Subgraph

The monitoring queries complement the [ILRM Subgraph](../subgraph/):

- **Dune**: Real-time on-chain queries
- **Subgraph**: Historical data and complex joins

For complex queries, consider querying the subgraph GraphQL endpoint:

```graphql
query ProtocolMetrics {
  protocolMetric(id: "protocol") {
    totalDisputes
    activeDisputes
    totalValueBurned
  }
  dailyMetrics(first: 30, orderBy: date, orderDirection: desc) {
    date
    disputesInitiated
    totalStaked
  }
}
```

## Runbooks

Alert responses should follow the runbooks in:
- `docs/EMERGENCY_PROCEDURES.md` - Incident response
- `docs/MULTISIG_CONFIG.md` - Governance actions

## Support

- [Dune Documentation](https://docs.dune.com/)
- [OpenZeppelin Defender](https://docs.openzeppelin.com/defender/)
- [Tenderly Alerts](https://docs.tenderly.co/)
