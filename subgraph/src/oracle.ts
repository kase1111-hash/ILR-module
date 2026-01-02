// =============================================================================
// Oracle Event Handlers - TheGraph Subgraph
// =============================================================================
// Handles all events from the Oracle LLM proposal bridge contract
// =============================================================================

import { BigInt } from "@graphprotocol/graph-ts";
import {
  ProposalRequested,
  ProposalSubmittedToILRM,
  ProposalReset
} from "../generated/Oracle/Oracle";
import { OracleProposal, OracleMetric } from "../generated/schema";

// =============================================================================
// Helper Functions
// =============================================================================

function getOrCreateOracleMetric(timestamp: BigInt): OracleMetric {
  // Convert to day (86400 seconds)
  let dayTimestamp = timestamp.div(BigInt.fromI32(86400)).times(BigInt.fromI32(86400));
  let id = dayTimestamp.toString();
  let metric = OracleMetric.load(id);

  if (metric == null) {
    metric = new OracleMetric(id);
    metric.date = dayTimestamp;
    metric.proposalsRequested = 0;
    metric.proposalsSubmitted = 0;
    metric.proposalsReset = 0;
    metric.avgResponseBlocks = BigInt.fromI32(0);
  }

  return metric;
}

// =============================================================================
// Event Handlers
// =============================================================================

export function handleProposalRequested(event: ProposalRequested): void {
  let disputeId = event.params.disputeId.toString();
  let timestamp = event.block.timestamp;

  // Create or update proposal record
  let proposal = OracleProposal.load(disputeId);
  if (proposal == null) {
    proposal = new OracleProposal(disputeId);
    proposal.wasReset = false;
  }

  proposal.requester = event.params.requester;
  proposal.evidenceHash = event.params.evidenceHash;
  proposal.requestedAt = timestamp;
  proposal.save();

  // Update oracle metrics
  let metric = getOrCreateOracleMetric(timestamp);
  metric.proposalsRequested = metric.proposalsRequested + 1;
  metric.save();
}

export function handleProposalSubmittedToILRM(event: ProposalSubmittedToILRM): void {
  let disputeId = event.params.disputeId.toString();
  let timestamp = event.block.timestamp;

  let proposal = OracleProposal.load(disputeId);
  if (proposal == null) {
    // Shouldn't happen, but create if missing
    proposal = new OracleProposal(disputeId);
    proposal.requestedAt = timestamp;
    proposal.wasReset = false;
  }

  proposal.submittedAt = timestamp;
  proposal.proposal = event.params.proposal;
  proposal.submitter = event.params.submitter;
  proposal.save();

  // Update oracle metrics
  let metric = getOrCreateOracleMetric(timestamp);
  metric.proposalsSubmitted = metric.proposalsSubmitted + 1;

  // Calculate average response time if we have request time
  if (proposal.requestedAt != null && proposal.requestedAt > BigInt.fromI32(0)) {
    let responseTime = timestamp.minus(proposal.requestedAt as BigInt);
    // Simple moving average approximation
    if (metric.avgResponseBlocks.equals(BigInt.fromI32(0))) {
      metric.avgResponseBlocks = responseTime;
    } else {
      metric.avgResponseBlocks = metric.avgResponseBlocks.plus(responseTime).div(BigInt.fromI32(2));
    }
  }
  metric.save();
}

export function handleProposalReset(event: ProposalReset): void {
  let disputeId = event.params.disputeId.toString();
  let timestamp = event.block.timestamp;

  let proposal = OracleProposal.load(disputeId);
  if (proposal == null) {
    proposal = new OracleProposal(disputeId);
    proposal.requestedAt = timestamp;
  }

  proposal.wasReset = true;
  proposal.resetReason = event.params.reason;
  // Clear submission data
  proposal.submittedAt = null;
  proposal.proposal = null;
  proposal.submitter = null;
  proposal.save();

  // Update oracle metrics
  let metric = getOrCreateOracleMetric(timestamp);
  metric.proposalsReset = metric.proposalsReset + 1;
  metric.save();
}
