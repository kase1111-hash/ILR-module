// =============================================================================
// ILRM Event Handlers - TheGraph Subgraph
// =============================================================================
// Handles all events from the ILRM core dispute resolution contract
// =============================================================================

import { BigInt, Bytes, Address } from "@graphprotocol/graph-ts";
import {
  DisputeInitiated,
  StakeDeposited,
  ProposalSubmitted,
  AcceptanceSignaled,
  CounterProposed,
  StakesBurned,
  DefaultLicenseApplied,
  DisputeResolved,
  HarassmentScoreUpdated,
  ZKIdentityRegistered,
  FIDOAcceptance,
  DIDAssociatedWithDispute
} from "../generated/ILRM/ILRM";
import {
  Dispute,
  Party,
  Proposal,
  Counter,
  HarassmentScore,
  DailyMetric,
  ProtocolMetric
} from "../generated/schema";

// =============================================================================
// Helper Functions
// =============================================================================

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
  }

  party.lastActive = timestamp;
  party.save();

  return party;
}

function getOrCreateDailyMetric(timestamp: BigInt): DailyMetric {
  // Convert to day (86400 seconds)
  let dayTimestamp = timestamp.div(BigInt.fromI32(86400)).times(BigInt.fromI32(86400));
  let id = dayTimestamp.toString();
  let metric = DailyMetric.load(id);

  if (metric == null) {
    metric = new DailyMetric(id);
    metric.date = dayTimestamp;
    metric.disputesInitiated = 0;
    metric.disputesResolved = 0;
    metric.disputesTimedOut = 0;
    metric.totalStaked = BigInt.fromI32(0);
    metric.totalBurned = BigInt.fromI32(0);
    metric.totalSubsidies = BigInt.fromI32(0);
    metric.uniqueParticipants = 0;
    metric.counterProposals = 0;
    metric.proposals = 0;
    metric.l3Batches = 0;
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

export function handleDisputeInitiated(event: DisputeInitiated): void {
  let disputeId = event.params.disputeId.toString();
  let timestamp = event.block.timestamp;

  // Create or get parties
  let initiator = getOrCreateParty(event.params.initiator, timestamp);
  initiator.totalDisputes = initiator.totalDisputes + 1;
  initiator.save();

  let counterparty = getOrCreateParty(event.params.counterparty, timestamp);
  counterparty.totalDisputes = counterparty.totalDisputes + 1;
  counterparty.save();

  // Create dispute
  let dispute = new Dispute(disputeId);
  dispute.initiator = initiator.id;
  dispute.counterparty = counterparty.id;
  dispute.initiatorStake = BigInt.fromI32(0); // Will be set by StakeDeposited
  dispute.counterpartyStake = BigInt.fromI32(0);
  dispute.startTime = timestamp;
  dispute.startBlock = event.block.number;
  dispute.evidenceHash = event.params.evidenceHash;
  dispute.state = "INITIATED";
  dispute.initiatorAccepted = false;
  dispute.counterpartyAccepted = false;
  dispute.counterCount = 0;
  dispute.zkModeEnabled = false;
  dispute.fidoUsed = false;
  dispute.createdAt = timestamp;
  dispute.updatedAt = timestamp;
  dispute.save();

  // Update daily metrics
  let daily = getOrCreateDailyMetric(timestamp);
  daily.disputesInitiated = daily.disputesInitiated + 1;
  daily.save();

  // Update protocol metrics
  let protocol = getOrCreateProtocolMetric();
  protocol.totalDisputes = protocol.totalDisputes.plus(BigInt.fromI32(1));
  protocol.activeDisputes = protocol.activeDisputes.plus(BigInt.fromI32(1));
  protocol.lastUpdatedBlock = event.block.number;
  protocol.save();
}

export function handleStakeDeposited(event: StakeDeposited): void {
  let disputeId = event.params.disputeId.toString();
  let dispute = Dispute.load(disputeId);

  if (dispute == null) {
    return;
  }

  let depositorId = event.params.depositor.toHexString();
  let amount = event.params.amount;
  let timestamp = event.block.timestamp;

  // Update stake based on who deposited
  if (depositorId == dispute.initiator) {
    dispute.initiatorStake = amount;
  } else if (depositorId == dispute.counterparty) {
    dispute.counterpartyStake = amount;
    dispute.state = "ACTIVE"; // Counterparty staked, dispute is now active
  }

  dispute.updatedAt = timestamp;
  dispute.save();

  // Update party stats
  let party = Party.load(depositorId);
  if (party != null) {
    party.totalStaked = party.totalStaked.plus(amount);
    party.lastActive = timestamp;
    party.save();
  }

  // Update metrics
  let daily = getOrCreateDailyMetric(timestamp);
  daily.totalStaked = daily.totalStaked.plus(amount);
  daily.save();

  let protocol = getOrCreateProtocolMetric();
  protocol.totalValueStaked = protocol.totalValueStaked.plus(amount);
  protocol.lastUpdatedBlock = event.block.number;
  protocol.save();
}

export function handleProposalSubmitted(event: ProposalSubmitted): void {
  let disputeId = event.params.disputeId.toString();
  let dispute = Dispute.load(disputeId);

  if (dispute == null) {
    return;
  }

  let timestamp = event.block.timestamp;

  // Count existing proposals for this dispute
  let proposalIndex = 0;
  let proposalId = disputeId + "-" + proposalIndex.toString();
  while (Proposal.load(proposalId) != null) {
    proposalIndex++;
    proposalId = disputeId + "-" + proposalIndex.toString();
  }

  // Create proposal
  let proposal = new Proposal(proposalId);
  proposal.dispute = disputeId;
  proposal.content = event.params.proposal;
  proposal.submitter = event.transaction.from;
  proposal.timestamp = timestamp;
  proposal.txHash = event.transaction.hash;
  proposal.index = proposalIndex;
  proposal.save();

  // Reset acceptances on new proposal
  dispute.initiatorAccepted = false;
  dispute.counterpartyAccepted = false;
  dispute.updatedAt = timestamp;
  dispute.save();

  // Update metrics
  let daily = getOrCreateDailyMetric(timestamp);
  daily.proposals = daily.proposals + 1;
  daily.save();
}

export function handleAcceptanceSignaled(event: AcceptanceSignaled): void {
  let disputeId = event.params.disputeId.toString();
  let dispute = Dispute.load(disputeId);

  if (dispute == null) {
    return;
  }

  let partyId = event.params.party.toHexString();
  let timestamp = event.block.timestamp;

  if (partyId == dispute.initiator) {
    dispute.initiatorAccepted = true;
  } else if (partyId == dispute.counterparty) {
    dispute.counterpartyAccepted = true;
  }

  dispute.updatedAt = timestamp;
  dispute.save();

  // Update party last active
  let party = Party.load(partyId);
  if (party != null) {
    party.lastActive = timestamp;
    party.save();
  }
}

export function handleCounterProposed(event: CounterProposed): void {
  let disputeId = event.params.disputeId.toString();
  let dispute = Dispute.load(disputeId);

  if (dispute == null) {
    return;
  }

  let timestamp = event.block.timestamp;
  let counterNumber = event.params.counterNumber.toI32();
  let partyId = event.params.party.toHexString();

  // Create counter record
  let counterId = disputeId + "-" + counterNumber.toString();
  let counter = new Counter(counterId);
  counter.dispute = disputeId;
  counter.party = partyId;
  counter.evidenceHash = Bytes.empty(); // Would need additional event data
  counter.counterNumber = counterNumber;
  counter.feePaid = BigInt.fromI32(0); // Would need additional event data
  counter.timestamp = timestamp;
  counter.txHash = event.transaction.hash;
  counter.save();

  // Update dispute
  dispute.counterCount = counterNumber;
  dispute.initiatorAccepted = false;
  dispute.counterpartyAccepted = false;
  dispute.updatedAt = timestamp;
  dispute.save();

  // Update metrics
  let daily = getOrCreateDailyMetric(timestamp);
  daily.counterProposals = daily.counterProposals + 1;
  daily.save();

  let protocol = getOrCreateProtocolMetric();
  protocol.totalCounterProposals = protocol.totalCounterProposals.plus(BigInt.fromI32(1));
  protocol.lastUpdatedBlock = event.block.number;
  protocol.save();
}

export function handleStakesBurned(event: StakesBurned): void {
  let disputeId = event.params.disputeId.toString();
  let dispute = Dispute.load(disputeId);

  if (dispute == null) {
    return;
  }

  let burnAmount = event.params.burnAmount;
  let timestamp = event.block.timestamp;

  dispute.burnAmount = burnAmount;
  dispute.updatedAt = timestamp;
  dispute.save();

  // Update party burn totals (split evenly)
  let halfBurn = burnAmount.div(BigInt.fromI32(2));

  let initiator = Party.load(dispute.initiator);
  if (initiator != null) {
    initiator.totalBurned = initiator.totalBurned.plus(halfBurn);
    initiator.save();
  }

  let counterparty = Party.load(dispute.counterparty);
  if (counterparty != null) {
    counterparty.totalBurned = counterparty.totalBurned.plus(halfBurn);
    counterparty.save();
  }

  // Update metrics
  let daily = getOrCreateDailyMetric(timestamp);
  daily.totalBurned = daily.totalBurned.plus(burnAmount);
  daily.save();

  let protocol = getOrCreateProtocolMetric();
  protocol.totalValueBurned = protocol.totalValueBurned.plus(burnAmount);
  protocol.lastUpdatedBlock = event.block.number;
  protocol.save();
}

export function handleDefaultLicenseApplied(event: DefaultLicenseApplied): void {
  let disputeId = event.params.disputeId.toString();
  let dispute = Dispute.load(disputeId);

  if (dispute == null) {
    return;
  }

  let timestamp = event.block.timestamp;

  dispute.outcome = "DEFAULT_LICENSE_APPLIED";
  dispute.updatedAt = timestamp;
  dispute.save();
}

export function handleDisputeResolved(event: DisputeResolved): void {
  let disputeId = event.params.disputeId.toString();
  let dispute = Dispute.load(disputeId);

  if (dispute == null) {
    return;
  }

  let timestamp = event.block.timestamp;
  let outcomeValue = event.params.outcome;

  dispute.state = "RESOLVED";
  dispute.resolvedAt = event.block.number;
  dispute.resolvedTx = event.transaction.hash;
  dispute.updatedAt = timestamp;

  // Map outcome enum
  if (outcomeValue == 1) {
    dispute.outcome = "ACCEPTED_PROPOSAL";
  } else if (outcomeValue == 2) {
    dispute.outcome = "TIMEOUT_WITH_BURN";
  } else if (outcomeValue == 3) {
    dispute.outcome = "DEFAULT_LICENSE_APPLIED";
  } else {
    dispute.outcome = "PENDING";
  }

  dispute.save();

  // Update party stats
  let initiator = Party.load(dispute.initiator);
  if (initiator != null) {
    if (dispute.outcome == "ACCEPTED_PROPOSAL") {
      initiator.disputesResolved = initiator.disputesResolved + 1;
    } else if (dispute.outcome == "TIMEOUT_WITH_BURN") {
      initiator.disputesTimedOut = initiator.disputesTimedOut + 1;
    }
    initiator.save();
  }

  let counterparty = Party.load(dispute.counterparty);
  if (counterparty != null) {
    if (dispute.outcome == "ACCEPTED_PROPOSAL") {
      counterparty.disputesResolved = counterparty.disputesResolved + 1;
    } else if (dispute.outcome == "TIMEOUT_WITH_BURN") {
      counterparty.disputesTimedOut = counterparty.disputesTimedOut + 1;
    }
    counterparty.save();
  }

  // Update metrics
  let daily = getOrCreateDailyMetric(timestamp);
  daily.disputesResolved = daily.disputesResolved + 1;
  if (dispute.outcome == "TIMEOUT_WITH_BURN") {
    daily.disputesTimedOut = daily.disputesTimedOut + 1;
  }
  daily.save();

  let protocol = getOrCreateProtocolMetric();
  protocol.activeDisputes = protocol.activeDisputes.minus(BigInt.fromI32(1));
  protocol.resolvedDisputes = protocol.resolvedDisputes.plus(BigInt.fromI32(1));
  if (dispute.outcome == "TIMEOUT_WITH_BURN") {
    protocol.timedOutDisputes = protocol.timedOutDisputes.plus(BigInt.fromI32(1));
  }
  protocol.lastUpdatedBlock = event.block.number;
  protocol.save();
}

export function handleHarassmentScoreUpdated(event: HarassmentScoreUpdated): void {
  let partyId = event.params.participant.toHexString();
  let party = Party.load(partyId);

  if (party == null) {
    return;
  }

  let timestamp = event.block.timestamp;
  let oldScore = event.params.oldScore;
  let newScore = event.params.newScore;

  // Create harassment score record
  let recordId = partyId + "-" + event.block.number.toString();
  let record = new HarassmentScore(recordId);
  record.party = partyId;
  record.oldScore = oldScore;
  record.newScore = newScore;
  record.timestamp = timestamp;
  record.txHash = event.transaction.hash;
  record.save();

  // Update party
  party.harassmentScore = newScore;
  party.lastActive = timestamp;
  party.save();
}

export function handleZKIdentityRegistered(event: ZKIdentityRegistered): void {
  let disputeId = event.params.disputeId.toString();
  let dispute = Dispute.load(disputeId);

  if (dispute == null) {
    return;
  }

  let identityHash = event.params.identityHash;
  let isInitiator = event.params.isInitiator;
  let timestamp = event.block.timestamp;

  dispute.zkModeEnabled = true;
  if (isInitiator) {
    dispute.initiatorZKIdentity = identityHash;
  } else {
    dispute.counterpartyZKIdentity = identityHash;
  }
  dispute.updatedAt = timestamp;
  dispute.save();
}

export function handleFIDOAcceptance(event: FIDOAcceptance): void {
  let disputeId = event.params.disputeId.toString();
  let dispute = Dispute.load(disputeId);

  if (dispute == null) {
    return;
  }

  let timestamp = event.block.timestamp;
  dispute.fidoUsed = true;
  dispute.updatedAt = timestamp;
  dispute.save();
}

export function handleDIDAssociatedWithDispute(event: DIDAssociatedWithDispute): void {
  let disputeId = event.params.disputeId.toString();
  let dispute = Dispute.load(disputeId);

  if (dispute == null) {
    return;
  }

  let did = event.params.did;
  let isInitiator = event.params.isInitiator;
  let timestamp = event.block.timestamp;

  if (isInitiator) {
    dispute.initiatorDID = did;
  } else {
    dispute.counterpartyDID = did;
  }
  dispute.updatedAt = timestamp;
  dispute.save();
}
