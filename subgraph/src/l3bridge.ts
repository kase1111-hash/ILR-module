// =============================================================================
// L3Bridge Event Handlers - TheGraph Subgraph
// =============================================================================
// Handles all events from the L3Bridge layer 3 scaling contract
// =============================================================================

import { BigInt, Bytes } from "@graphprotocol/graph-ts";
import {
  BatchSubmitted,
  BatchFinalized,
  ChallengeInitiated,
  ChallengeResolved
} from "../generated/L3Bridge/L3Bridge";
import {
  L3Batch,
  L3Metric,
  FraudProofChallenge,
  ProtocolMetric
} from "../generated/schema";

// =============================================================================
// Helper Functions
// =============================================================================

function getOrCreateL3Metric(timestamp: BigInt): L3Metric {
  // Convert to day (86400 seconds)
  let dayTimestamp = timestamp.div(BigInt.fromI32(86400)).times(BigInt.fromI32(86400));
  let id = dayTimestamp.toString();
  let metric = L3Metric.load(id);

  if (metric == null) {
    metric = new L3Metric(id);
    metric.date = dayTimestamp;
    metric.batchesSubmitted = 0;
    metric.batchesFinalized = 0;
    metric.challengesInitiated = 0;
    metric.challengesSucceeded = 0;
    metric.totalDisputesBatched = 0;
  }

  return metric;
}

function getOrCreateProtocolMetric(): ProtocolMetric {
  let id = "protocol";
  let metric = ProtocolMetric.load(id);

  if (metric == null) {
    metric = new ProtocolMetric(id);
    metric.totalDisputes = BigInt.fromI32(0);
    metric.activeDisputes = BigInt.fromI32(0);
    metric.resolvedDisputes = BigInt.fromI32(0);
    metric.timedOutDisputes = BigInt.fromI32(0);
    metric.totalValueStaked = BigInt.fromI32(0);
    metric.totalValueBurned = BigInt.fromI32(0);
    metric.totalSubsidiesDistributed = BigInt.fromI32(0);
    metric.uniqueParticipants = BigInt.fromI32(0);
    metric.totalCounterProposals = BigInt.fromI32(0);
    metric.totalL3Batches = BigInt.fromI32(0);
    metric.avgResolutionBlocks = BigInt.fromI32(0);
    metric.lastUpdatedBlock = BigInt.fromI32(0);
  }

  return metric;
}

// =============================================================================
// Event Handlers
// =============================================================================

export function handleBatchSubmitted(event: BatchSubmitted): void {
  let batchId = event.params.batchId.toString();
  let timestamp = event.block.timestamp;

  // Create batch record
  let batch = new L3Batch(batchId);
  batch.stateRoot = event.params.stateRoot;
  batch.disputeCount = event.params.disputeCount.toI32();
  batch.submitter = event.params.submitter;
  batch.submittedAt = timestamp;
  batch.challenged = false;
  batch.status = "PENDING";
  batch.save();

  // Update L3 metrics
  let metric = getOrCreateL3Metric(timestamp);
  metric.batchesSubmitted = metric.batchesSubmitted + 1;
  metric.totalDisputesBatched = metric.totalDisputesBatched + batch.disputeCount;
  metric.save();

  // Update protocol metrics
  let protocol = getOrCreateProtocolMetric();
  protocol.totalL3Batches = protocol.totalL3Batches.plus(BigInt.fromI32(1));
  protocol.lastUpdatedBlock = event.block.number;
  protocol.save();
}

export function handleBatchFinalized(event: BatchFinalized): void {
  let batchId = event.params.batchId.toString();
  let timestamp = event.block.timestamp;

  let batch = L3Batch.load(batchId);
  if (batch == null) {
    return;
  }

  batch.finalizedAt = timestamp;
  batch.status = "FINALIZED";
  batch.save();

  // Update L3 metrics
  let metric = getOrCreateL3Metric(timestamp);
  metric.batchesFinalized = metric.batchesFinalized + 1;
  metric.save();
}

export function handleChallengeInitiated(event: ChallengeInitiated): void {
  let batchId = event.params.batchId.toString();
  let timestamp = event.block.timestamp;

  let batch = L3Batch.load(batchId);
  if (batch == null) {
    return;
  }

  batch.challenged = true;
  batch.save();

  // Create challenge record
  let challengeId = batchId + "-" + event.params.challenger.toHexString();
  let challenge = new FraudProofChallenge(challengeId);
  challenge.batch = batchId;
  challenge.challenger = event.params.challenger;
  challenge.initiatedAt = timestamp;
  challenge.txHash = event.transaction.hash;
  challenge.save();

  // Update L3 metrics
  let metric = getOrCreateL3Metric(timestamp);
  metric.challengesInitiated = metric.challengesInitiated + 1;
  metric.save();
}

export function handleChallengeResolved(event: ChallengeResolved): void {
  let batchId = event.params.batchId.toString();
  let timestamp = event.block.timestamp;
  let succeeded = event.params.challengeSucceeded;

  let batch = L3Batch.load(batchId);
  if (batch == null) {
    return;
  }

  batch.challengeSucceeded = succeeded;
  if (succeeded) {
    batch.status = "REVERTED";
  }
  batch.save();

  // Find and update the challenge record
  // We need to iterate through possible challengers - simplified approach
  // In production, you'd track the challenger address in the event or separately

  // Update L3 metrics
  let metric = getOrCreateL3Metric(timestamp);
  if (succeeded) {
    metric.challengesSucceeded = metric.challengesSucceeded + 1;
  }
  metric.save();
}
