// =============================================================================
// Treasury Event Handlers - TheGraph Subgraph
// =============================================================================
// Handles all events from the Treasury fund management contract
// =============================================================================

import { BigInt, Address } from "@graphprotocol/graph-ts";
import {
  SubsidyFunded,
  TreasuryReceived,
  HarassmentScoreUpdated,
  CapsUpdated
} from "../generated/Treasury/Treasury";
import {
  TreasuryMetric,
  Subsidy,
  Burn,
  Party,
  HarassmentScore,
  ProtocolMetric
} from "../generated/schema";

// =============================================================================
// Helper Functions
// =============================================================================

function getOrCreateTreasuryMetric(timestamp: BigInt): TreasuryMetric {
  // Convert to day (86400 seconds)
  let dayTimestamp = timestamp.div(BigInt.fromI32(86400)).times(BigInt.fromI32(86400));
  let id = dayTimestamp.toString();
  let metric = TreasuryMetric.load(id);

  if (metric == null) {
    metric = new TreasuryMetric(id);
    metric.date = dayTimestamp;
    metric.totalSubsidies = BigInt.fromI32(0);
    metric.totalBurns = BigInt.fromI32(0);
    metric.totalReceived = BigInt.fromI32(0);
    metric.subsidyCount = 0;
    metric.burnCount = 0;
    metric.subsidyCap = BigInt.fromI32(0);
    metric.burnCap = BigInt.fromI32(0);
  }

  return metric;
}

function getOrCreateParty(address: Address, timestamp: BigInt): Party {
  let id = address.toHexString();
  let party = Party.load(id);

  if (party == null) {
    party = new Party(id);
    party.totalDisputes = 0;
    party.disputesResolved = 0;
    party.disputesTimedOut = 0;
    party.totalStaked = BigInt.fromI32(0);
    party.totalBurned = BigInt.fromI32(0);
    party.harassmentScore = BigInt.fromI32(0);
    party.totalSubsidiesReceived = BigInt.fromI32(0);
    party.firstSeen = timestamp;
    party.lastActive = timestamp;
    party.save();
  }

  return party;
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

export function handleSubsidyFunded(event: SubsidyFunded): void {
  let timestamp = event.block.timestamp;

  // Get or create recipient party
  let recipient = getOrCreateParty(event.params.recipient, timestamp);
  recipient.totalSubsidiesReceived = recipient.totalSubsidiesReceived.plus(event.params.amount);
  recipient.lastActive = timestamp;
  recipient.save();

  // Create subsidy record
  let subsidyId = event.transaction.hash.toHexString();
  let subsidy = new Subsidy(subsidyId);
  subsidy.recipient = recipient.id;
  subsidy.distributor = event.params.distributor;
  subsidy.amount = event.params.amount;
  subsidy.reason = event.params.reason;
  subsidy.timestamp = timestamp;
  subsidy.txHash = event.transaction.hash;
  subsidy.save();

  // Update treasury metrics
  let treasuryMetric = getOrCreateTreasuryMetric(timestamp);
  treasuryMetric.totalSubsidies = treasuryMetric.totalSubsidies.plus(event.params.amount);
  treasuryMetric.subsidyCount = treasuryMetric.subsidyCount + 1;
  treasuryMetric.save();

  // Update protocol metrics
  let protocol = getOrCreateProtocolMetric();
  protocol.totalSubsidiesDistributed = protocol.totalSubsidiesDistributed.plus(event.params.amount);
  protocol.lastUpdatedBlock = event.block.number;
  protocol.save();
}

export function handleTreasuryReceived(event: TreasuryReceived): void {
  let timestamp = event.block.timestamp;

  // If this is a burn record it
  if (event.params.reason == "burn" || event.params.reason == "timeout_burn") {
    let burnId = event.transaction.hash.toHexString() + "-" + event.logIndex.toString();
    let burn = new Burn(burnId);
    burn.amount = event.params.amount;
    burn.reason = event.params.reason;
    burn.timestamp = timestamp;
    burn.txHash = event.transaction.hash;
    burn.save();

    // Update treasury metrics
    let treasuryMetric = getOrCreateTreasuryMetric(timestamp);
    treasuryMetric.totalBurns = treasuryMetric.totalBurns.plus(event.params.amount);
    treasuryMetric.burnCount = treasuryMetric.burnCount + 1;
    treasuryMetric.save();
  } else {
    // General treasury received
    let treasuryMetric = getOrCreateTreasuryMetric(timestamp);
    treasuryMetric.totalReceived = treasuryMetric.totalReceived.plus(event.params.amount);
    treasuryMetric.save();
  }
}

export function handleTreasuryHarassmentUpdate(event: HarassmentScoreUpdated): void {
  let partyId = event.params.participant.toHexString();
  let party = Party.load(partyId);

  if (party == null) {
    party = getOrCreateParty(event.params.participant, event.block.timestamp);
  }

  let timestamp = event.block.timestamp;

  // Create harassment score record
  let recordId = partyId + "-treasury-" + event.block.number.toString();
  let record = new HarassmentScore(recordId);
  record.party = partyId;
  record.oldScore = event.params.oldScore;
  record.newScore = event.params.newScore;
  record.timestamp = timestamp;
  record.txHash = event.transaction.hash;
  record.save();

  // Update party
  party.harassmentScore = event.params.newScore;
  party.lastActive = timestamp;
  party.save();
}

export function handleCapsUpdated(event: CapsUpdated): void {
  let timestamp = event.block.timestamp;

  let treasuryMetric = getOrCreateTreasuryMetric(timestamp);
  treasuryMetric.subsidyCap = event.params.subsidyCap;
  treasuryMetric.burnCap = event.params.burnCap;
  treasuryMetric.save();
}
