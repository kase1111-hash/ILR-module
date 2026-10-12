// =============================================================================
// ILRM Event Handlers - TheGraph Subgraph
// =============================================================================
// Handles every event of contracts/ILRM.sol (core dispute resolution).
// Event order inside one transaction matters and mirrors the contract:
//   depositStake:            StakeDeposited, [OracleRequestFailed]
//   depositStakeWithSubsidy: StakeSubsidized, StakeDeposited, [OracleRequestFailed]
//   submitLLMProposal:       [ProposalSuperseded], ProposalSubmitted
//   voidLLMProposal:         ProposalVoided (Oracle owner reset; the replacement is a plain ProposalSubmitted)
//   counterPropose:          CounterProposed, [OracleRequestFailed]
//   acceptProposal:          AcceptanceSignaled, [SubsidyReturned], DisputeResolved
//   enforceTimeout (active): [SubsidyReturned], StakesBurned, DisputeResolved
//   enforceTimeout (no counterparty stake): InitiatorIncentivePaid, DefaultLicenseApplied, DisputeResolved
// OracleRequestFailed replaces the Oracle's ProposalRequested when the advisory request fails.
// =============================================================================

import { Address, BigInt, Bytes, ethereum } from "@graphprotocol/graph-ts";
import {
  ILRM,
  AcceptanceSignaled,
  CounterProposed,
  DefaultLicenseApplied,
  DisputeInitiated,
  DisputeResolved,
  HarassmentScoreUpdated,
  InitiatorIncentiveCapsUpdated,
  InitiatorIncentivePaid,
  OracleRequestFailed,
  OwnershipTransferStarted,
  OwnershipTransferred,
  Paused,
  ProposalSubmitted,
  ProposalSuperseded,
  ProposalVoided,
  StakeDeposited,
  StakeSubsidized,
  StakesBurned,
  SubsidyReturned,
  SubsidyTreasuryUpdated,
  TokenReservesDeposited,
  TreasuryWithdrawn,
  Unpaused
} from "../generated/ILRM/ILRM";
import {
  Burn,
  Counter,
  Dispute,
  HarassmentScore,
  OracleRequestFailure,
  Party,
  Proposal,
  StakeSubsidy,
  SubsidyReturn,
  VoluntaryRequest
} from "../generated/schema";
import {
  KIND_ILRM,
  ONE,
  ZERO,
  directCallArgs,
  eventId,
  getOrCreateContract,
  getOrCreateDailyMetric,
  getOrCreateProtocolMetric,
  isZeroAddress,
  keccakUtf8,
  newAdminEvent,
  recordOwnershipTransferStarted,
  recordOwnershipTransferred,
  recordPause,
  touchParty
} from "./common";

// =============================================================================
// Constants (mirroring ILRM.sol)
// =============================================================================

/** initiateVoluntaryRequest emits DisputeInitiated with this id and creates no dispute */
const VOLUNTARY_REQUEST_ID = BigInt.fromUnsignedBytes(
  Bytes.fromHexString("0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff")
);

/** ILRM.COUNTER_FEE_BASE (0.01 ether); counter n burns COUNTER_FEE_BASE * 2^(n-1) */
const COUNTER_FEE_BASE = BigInt.fromString("10000000000000000");

// IILRM.DisputeOutcome
const OUTCOME_ACCEPTED_PROPOSAL = 1;
const OUTCOME_TIMEOUT_WITH_BURN = 2;
const OUTCOME_DEFAULT_LICENSE_APPLIED = 3;

// =============================================================================
// Helpers
// =============================================================================

function outcomeName(value: i32): string {
  if (value == OUTCOME_ACCEPTED_PROPOSAL) return "ACCEPTED_PROPOSAL";
  if (value == OUTCOME_TIMEOUT_WITH_BURN) return "TIMEOUT_WITH_BURN";
  if (value == OUTCOME_DEFAULT_LICENSE_APPLIED) return "DEFAULT_LICENSE_APPLIED";
  return "PENDING";
}

/** Count a party's first dispute towards the participant metrics */
function joinDispute(party: Party, event: ethereum.Event): void {
  party.totalDisputes = party.totalDisputes + 1;
  party.save();
  if (party.totalDisputes == 1) {
    const daily = getOrCreateDailyMetric(event.block.timestamp);
    daily.newParticipants = daily.newParticipants + 1;
    daily.save();
    const protocol = getOrCreateProtocolMetric(event.block);
    protocol.uniqueParticipants = protocol.uniqueParticipants.plus(ONE);
    protocol.save();
  }
}

/** Book a stake deposit into the daily and protocol totals */
function recordStake(amount: BigInt, event: ethereum.Event): void {
  const daily = getOrCreateDailyMetric(event.block.timestamp);
  daily.totalStaked = daily.totalStaked.plus(amount);
  daily.save();
  const protocol = getOrCreateProtocolMetric(event.block);
  protocol.totalValueStaked = protocol.totalValueStaked.plus(amount);
  protocol.save();
}

function subsidyAmount(dispute: Dispute): BigInt {
  const id = dispute.stakeSubsidy;
  if (id === null) return ZERO;
  const subsidy = StakeSubsidy.load(id);
  return subsidy == null ? ZERO : subsidy.amount;
}

function setProposalStatus(id: string | null, status: string): void {
  if (id === null) return;
  const proposal = Proposal.load(id);
  if (proposal == null) return;
  proposal.status = status;
  proposal.save();
}

// =============================================================================
// Dispute lifecycle
// =============================================================================

export function handleDisputeInitiated(event: DisputeInitiated): void {
  const timestamp = event.block.timestamp;
  const initiator = touchParty(event.params.initiator, timestamp);
  const counterparty = touchParty(event.params.counterparty, timestamp);

  if (event.params.disputeId.equals(VOLUNTARY_REQUEST_ID)) {
    handleVoluntaryRequest(event, initiator, counterparty);
    return;
  }

  joinDispute(initiator, event);
  joinDispute(counterparty, event);

  const dispute = new Dispute(event.params.disputeId.toString());
  dispute.initiator = initiator.id;
  dispute.counterparty = counterparty.id;
  dispute.initiatorStake = ZERO;
  dispute.counterpartyStake = ZERO;
  dispute.startTime = timestamp;
  dispute.startBlock = event.block.number;
  dispute.initialEvidenceHash = event.params.evidenceHash;
  dispute.evidenceHash = event.params.evidenceHash;
  dispute.state = "INITIATED";
  dispute.outcome = "PENDING";
  dispute.initiatorAccepted = false;
  dispute.counterpartyAccepted = false;
  dispute.counterCount = 0;
  dispute.proposalCount = 0;
  dispute.counterFeesBurned = ZERO;
  dispute.oracleRequestFailureCount = 0;
  dispute.createdAt = timestamp;
  dispute.updatedAt = timestamp;

  // The event carries neither the (possibly escalated) initiator stake nor the fallback
  // terms; both are fixed at initiation, so reading them back is exact.
  const call = ILRM.bind(event.address).try_disputes(event.params.disputeId);
  if (!call.reverted) {
    const stored = call.value;
    dispute.initiatorStake = stored.initiatorStake;
    dispute.fallbackTermsHash = stored.fallbackLicense.termsHash;
    dispute.fallbackDuration = stored.fallbackLicense.termDuration;
    dispute.fallbackRoyaltyCap = stored.fallbackLicense.royaltyCapBps;
  }
  dispute.save();

  if (dispute.initiatorStake.gt(ZERO)) {
    initiator.totalStaked = initiator.totalStaked.plus(dispute.initiatorStake);
    initiator.save();
    recordStake(dispute.initiatorStake, event);
  }

  const daily = getOrCreateDailyMetric(timestamp);
  daily.disputesInitiated = daily.disputesInitiated + 1;
  daily.save();

  const protocol = getOrCreateProtocolMetric(event.block);
  protocol.totalDisputes = protocol.totalDisputes.plus(ONE);
  protocol.activeDisputes = protocol.activeDisputes.plus(ONE);
  protocol.save();
}

function handleVoluntaryRequest(event: DisputeInitiated, initiator: Party, counterparty: Party): void {
  initiator.voluntaryRequestsSent = initiator.voluntaryRequestsSent + 1;
  initiator.save();

  const request = new VoluntaryRequest(eventId(event));
  request.initiator = initiator.id;
  request.counterparty = counterparty.id;
  request.evidenceHash = event.params.evidenceHash;
  // The whole msg.value is burned; it equals the transaction value only for a direct call
  if (directCallArgs(event, "initiateVoluntaryRequest(address,bytes32)") !== null) {
    request.feeBurned = event.transaction.value;
  }
  request.timestamp = event.block.timestamp;
  request.blockNumber = event.block.number;
  request.txHash = event.transaction.hash;
  request.save();

  const daily = getOrCreateDailyMetric(event.block.timestamp);
  daily.voluntaryRequests = daily.voluntaryRequests + 1;
  daily.save();

  const protocol = getOrCreateProtocolMetric(event.block);
  protocol.totalVoluntaryRequests = protocol.totalVoluntaryRequests.plus(ONE);
  protocol.save();
}

export function handleStakeSubsidized(event: StakeSubsidized): void {
  const dispute = Dispute.load(event.params.disputeId.toString());
  if (dispute == null) return;

  const amount = event.params.amount;
  const counterparty = touchParty(event.params.counterparty, event.block.timestamp);
  counterparty.totalSubsidiesReceived = counterparty.totalSubsidiesReceived.plus(amount);
  counterparty.save();

  const subsidy = new StakeSubsidy(dispute.id);
  subsidy.dispute = dispute.id;
  subsidy.counterparty = counterparty.id;
  subsidy.funder = event.params.funder;
  subsidy.amount = amount;
  subsidy.amountReturned = ZERO;
  subsidy.timestamp = event.block.timestamp;
  subsidy.txHash = event.transaction.hash;
  subsidy.save();

  dispute.stakeSubsidy = subsidy.id;
  dispute.updatedAt = event.block.timestamp;
  dispute.save();

  const daily = getOrCreateDailyMetric(event.block.timestamp);
  daily.totalSubsidies = daily.totalSubsidies.plus(amount);
  daily.save();

  const protocol = getOrCreateProtocolMetric(event.block);
  protocol.totalSubsidiesDistributed = protocol.totalSubsidiesDistributed.plus(amount);
  protocol.save();
}

export function handleStakeDeposited(event: StakeDeposited): void {
  const dispute = Dispute.load(event.params.disputeId.toString());
  if (dispute == null) return;

  const amount = event.params.amount;
  const timestamp = event.block.timestamp;
  const depositor = touchParty(event.params.depositor, timestamp);

  if (depositor.id == dispute.counterparty) {
    dispute.counterpartyStake = amount;
    dispute.state = "ACTIVE";

    // Stakes are symmetric: backfill the initiator stake if the initiation call failed
    if (dispute.initiatorStake.equals(ZERO)) {
      dispute.initiatorStake = amount;
      const initiator = Party.load(dispute.initiator);
      if (initiator != null) {
        initiator.totalStaked = initiator.totalStaked.plus(amount);
        initiator.save();
      }
      recordStake(amount, event);
    }

    // Own funds only: a subsidy (StakeSubsidized, emitted just before) was paid by the treasury
    depositor.totalStaked = depositor.totalStaked.plus(amount.minus(subsidyAmount(dispute)));
  } else if (depositor.id == dispute.initiator) {
    dispute.initiatorStake = amount;
    depositor.totalStaked = depositor.totalStaked.plus(amount);
  }
  depositor.save();

  dispute.updatedAt = timestamp;
  dispute.save();

  recordStake(amount, event);
}

// =============================================================================
// Proposals and negotiation
// =============================================================================

export function handleProposalSuperseded(event: ProposalSuperseded): void {
  const dispute = Dispute.load(event.params.disputeId.toString());
  if (dispute == null) return;

  // The live proposal is replaced in the same round; ProposalSubmitted (next) links its successor
  setProposalStatus(dispute.currentProposal, "SUPERSEDED");
  dispute.updatedAt = event.block.timestamp;
  dispute.save();
}

export function handleProposalSubmitted(event: ProposalSubmitted): void {
  const dispute = Dispute.load(event.params.disputeId.toString());
  if (dispute == null) return;

  const timestamp = event.block.timestamp;
  const index = dispute.proposalCount;
  const proposal = new Proposal(dispute.id + "-" + index.toString());

  const previousId = dispute.currentProposal;
  if (previousId !== null) {
    const previous = Proposal.load(previousId);
    if (previous != null) {
      previous.status = "SUPERSEDED";
      previous.supersededBy = proposal.id;
      previous.save();
    }
  }

  proposal.dispute = dispute.id;
  proposal.index = index;
  proposal.round = dispute.counterCount;
  proposal.content = event.params.proposal;
  proposal.proposalHash = keccakUtf8(event.params.proposal);
  proposal.status = "LIVE";
  proposal.initiatorAccepted = false;
  proposal.counterpartyAccepted = false;
  proposal.submitter = event.transaction.from;
  proposal.timestamp = timestamp;
  proposal.blockNumber = event.block.number;
  proposal.txHash = event.transaction.hash;
  proposal.save();

  // Storing any proposal voids both acceptances
  dispute.currentProposal = proposal.id;
  dispute.proposalCount = index + 1;
  dispute.initiatorAccepted = false;
  dispute.counterpartyAccepted = false;
  dispute.updatedAt = timestamp;
  dispute.save();

  const daily = getOrCreateDailyMetric(timestamp);
  daily.proposals = daily.proposals + 1;
  daily.save();

  const protocol = getOrCreateProtocolMetric(event.block);
  protocol.totalProposals = protocol.totalProposals.plus(ONE);
  protocol.save();
}

export function handleProposalVoided(event: ProposalVoided): void {
  const dispute = Dispute.load(event.params.disputeId.toString());
  if (dispute == null) return;

  // voidLLMProposal (Oracle owner reset) clears the live proposal and both acceptances; the round then
  // admits one replacement, which arrives as a plain ProposalSubmitted. The contract only emits this
  // while a proposal is live and only for its hash (compare-and-clear).
  setProposalStatus(dispute.currentProposal, "VOIDED");
  dispute.currentProposal = null;
  dispute.initiatorAccepted = false;
  dispute.counterpartyAccepted = false;
  dispute.updatedAt = event.block.timestamp;
  dispute.save();
}

export function handleAcceptanceSignaled(event: AcceptanceSignaled): void {
  const dispute = Dispute.load(event.params.disputeId.toString());
  if (dispute == null) return;

  const party = touchParty(event.params.party, event.block.timestamp);
  const isInitiator = party.id == dispute.initiator;
  const isCounterparty = party.id == dispute.counterparty;
  if (isInitiator) dispute.initiatorAccepted = true;
  if (isCounterparty) dispute.counterpartyAccepted = true;

  const proposalId = dispute.currentProposal;
  if (proposalId !== null) {
    const proposal = Proposal.load(proposalId);
    if (proposal != null) {
      if (isInitiator) proposal.initiatorAccepted = true;
      if (isCounterparty) proposal.counterpartyAccepted = true;
      proposal.save();
    }
  }

  dispute.updatedAt = event.block.timestamp;
  dispute.save();
}

export function handleCounterProposed(event: CounterProposed): void {
  const dispute = Dispute.load(event.params.disputeId.toString());
  if (dispute == null) return;

  const timestamp = event.block.timestamp;
  const counterNumber = event.params.counterNumber.toI32();
  const party = touchParty(event.params.party, timestamp);

  let fee = ZERO;
  if (counterNumber >= 1) {
    fee = COUNTER_FEE_BASE.times(BigInt.fromI32(2).pow(u8(counterNumber - 1)));
  }

  const counter = new Counter(dispute.id + "-" + counterNumber.toString());
  counter.dispute = dispute.id;
  counter.party = party.id;
  counter.counterNumber = counterNumber;
  counter.feeBurned = fee;
  counter.timestamp = timestamp;
  counter.blockNumber = event.block.number;
  counter.txHash = event.transaction.hash;

  // The new evidence hash is not in the event; recover it from calldata of a direct call
  const args = directCallArgs(event, "counterPropose(uint256,bytes32)");
  if (args !== null) {
    const decoded = ethereum.decode("(uint256,bytes32)", args);
    if (decoded !== null) {
      const tuple = decoded.toTuple();
      if (tuple[0].toBigInt().equals(event.params.disputeId)) {
        counter.evidenceHash = tuple[1].toBytes();
        dispute.evidenceHash = tuple[1].toBytes();
      }
    }
  }
  counter.save();

  // counterPropose clears the live proposal and both acceptances and opens a new round
  setProposalStatus(dispute.currentProposal, "VOIDED_BY_COUNTER");
  dispute.currentProposal = null;
  dispute.counterCount = counterNumber;
  dispute.initiatorAccepted = false;
  dispute.counterpartyAccepted = false;
  dispute.counterFeesBurned = dispute.counterFeesBurned.plus(fee);
  dispute.updatedAt = timestamp;
  dispute.save();

  const daily = getOrCreateDailyMetric(timestamp);
  daily.counterProposals = daily.counterProposals + 1;
  daily.save();

  const protocol = getOrCreateProtocolMetric(event.block);
  protocol.totalCounterProposals = protocol.totalCounterProposals.plus(ONE);
  protocol.totalCounterFeesBurned = protocol.totalCounterFeesBurned.plus(fee);
  protocol.save();
}

export function handleOracleRequestFailed(event: OracleRequestFailed): void {
  const dispute = Dispute.load(event.params.disputeId.toString());
  if (dispute == null) return;

  // The advisory Oracle.requestProposal call could not be made or reverted; the dispute proceeds
  const failure = new OracleRequestFailure(eventId(event));
  failure.dispute = dispute.id;
  failure.round = event.params.round;
  failure.timestamp = event.block.timestamp;
  failure.blockNumber = event.block.number;
  failure.txHash = event.transaction.hash;
  failure.save();

  dispute.oracleRequestFailureCount = dispute.oracleRequestFailureCount + 1;
  dispute.updatedAt = event.block.timestamp;
  dispute.save();

  const protocol = getOrCreateProtocolMetric(event.block);
  protocol.totalOracleRequestFailures = protocol.totalOracleRequestFailures.plus(ONE);
  protocol.save();
}

// =============================================================================
// Resolution
// =============================================================================

export function handleSubsidyReturned(event: SubsidyReturned): void {
  // Indexing from the ILRM deployment block always sees StakeSubsidized first
  const subsidy = StakeSubsidy.load(event.params.disputeId.toString());
  if (subsidy == null) return;

  const amount = event.params.amount;
  subsidy.amountReturned = subsidy.amountReturned.plus(amount);
  subsidy.save();

  const entry = new SubsidyReturn(eventId(event));
  entry.subsidy = subsidy.id;
  entry.dispute = subsidy.dispute;
  entry.funder = event.params.funder;
  entry.amount = amount;
  entry.timestamp = event.block.timestamp;
  entry.txHash = event.transaction.hash;
  entry.save();

  const daily = getOrCreateDailyMetric(event.block.timestamp);
  daily.totalSubsidiesReturned = daily.totalSubsidiesReturned.plus(amount);
  daily.save();

  const protocol = getOrCreateProtocolMetric(event.block);
  protocol.totalSubsidiesReturned = protocol.totalSubsidiesReturned.plus(amount);
  protocol.save();
}

export function handleStakesBurned(event: StakesBurned): void {
  const dispute = Dispute.load(event.params.disputeId.toString());
  if (dispute == null) return;

  const burnAmount = event.params.burnAmount;
  const timestamp = event.block.timestamp;

  dispute.burnAmount = burnAmount;
  dispute.updatedAt = timestamp;
  dispute.save();

  const burn = new Burn(eventId(event));
  burn.dispute = dispute.id;
  burn.amount = burnAmount;
  burn.timestamp = timestamp;
  burn.txHash = event.transaction.hash;
  burn.save();

  // Stakes are symmetric, so each side bears half of the burn. On the counterparty side a
  // subsidy funder bears its pro-rata share (ILRM._payCounterpartySide).
  const half = burnAmount.div(BigInt.fromI32(2));
  const initiator = Party.load(dispute.initiator);
  if (initiator != null) {
    initiator.totalBurned = initiator.totalBurned.plus(half);
    initiator.save();
  }
  const counterparty = Party.load(dispute.counterparty);
  if (counterparty != null) {
    let ownShare = half;
    const subsidy = subsidyAmount(dispute);
    if (subsidy.gt(ZERO) && dispute.counterpartyStake.gt(ZERO)) {
      ownShare = half.times(dispute.counterpartyStake.minus(subsidy)).div(dispute.counterpartyStake);
    }
    counterparty.totalBurned = counterparty.totalBurned.plus(ownShare);
    counterparty.save();
  }

  const daily = getOrCreateDailyMetric(timestamp);
  daily.totalBurned = daily.totalBurned.plus(burnAmount);
  daily.save();

  const protocol = getOrCreateProtocolMetric(event.block);
  protocol.totalValueBurned = protocol.totalValueBurned.plus(burnAmount);
  protocol.save();
}

export function handleInitiatorIncentivePaid(event: InitiatorIncentivePaid): void {
  const dispute = Dispute.load(event.params.disputeId.toString());
  if (dispute == null) return;

  // Paid on top of the returned stake: min(uncapped, per-dispute cap, window budget left, reserves)
  const amount = event.params.amount;
  const uncapped = event.params.uncappedAmount;
  dispute.initiatorIncentive = amount;
  dispute.initiatorIncentiveUncapped = uncapped;
  dispute.updatedAt = event.block.timestamp;
  dispute.save();

  const daily = getOrCreateDailyMetric(event.block.timestamp);
  daily.initiatorIncentivesPaid = daily.initiatorIncentivesPaid.plus(amount);
  daily.save();

  const protocol = getOrCreateProtocolMetric(event.block);
  protocol.totalInitiatorIncentivesPaid = protocol.totalInitiatorIncentivesPaid.plus(amount);
  protocol.totalInitiatorIncentivesUncapped = protocol.totalInitiatorIncentivesUncapped.plus(uncapped);
  if (amount.lt(uncapped)) {
    protocol.cappedInitiatorIncentives = protocol.cappedInitiatorIncentives.plus(ONE);
  }
  protocol.save();
}

export function handleDefaultLicenseApplied(event: DefaultLicenseApplied): void {
  const dispute = Dispute.load(event.params.disputeId.toString());
  if (dispute == null) return;

  dispute.outcome = "DEFAULT_LICENSE_APPLIED";
  dispute.updatedAt = event.block.timestamp;
  dispute.save();
}

export function handleDisputeResolved(event: DisputeResolved): void {
  const dispute = Dispute.load(event.params.disputeId.toString());
  if (dispute == null) return;

  const timestamp = event.block.timestamp;
  const outcome = outcomeName(event.params.outcome);

  dispute.state = "RESOLVED";
  dispute.outcome = outcome;
  dispute.resolvedAt = timestamp;
  dispute.resolvedBlock = event.block.number;
  dispute.resolvedTx = event.transaction.hash;
  dispute.updatedAt = timestamp;
  dispute.save();

  // Settle the live proposal
  const proposalId = dispute.currentProposal;
  if (proposalId !== null) {
    const proposal = Proposal.load(proposalId);
    if (proposal != null && proposal.status == "LIVE") {
      proposal.status = outcome == "ACCEPTED_PROPOSAL" ? "ACCEPTED" : "EXPIRED";
      proposal.save();
    }
  }

  const parties: string[] = [dispute.initiator, dispute.counterparty];
  for (let i = 0; i < parties.length; i++) {
    const party = Party.load(parties[i]);
    if (party == null) continue;
    if (outcome == "ACCEPTED_PROPOSAL") party.disputesResolved = party.disputesResolved + 1;
    else if (outcome == "TIMEOUT_WITH_BURN") party.disputesTimedOut = party.disputesTimedOut + 1;
    else if (outcome == "DEFAULT_LICENSE_APPLIED") party.disputesDefaulted = party.disputesDefaulted + 1;
    party.lastActive = timestamp;
    party.save();
  }

  const daily = getOrCreateDailyMetric(timestamp);
  daily.disputesResolved = daily.disputesResolved + 1;
  if (outcome == "TIMEOUT_WITH_BURN") daily.disputesTimedOut = daily.disputesTimedOut + 1;
  if (outcome == "DEFAULT_LICENSE_APPLIED") daily.disputesDefaulted = daily.disputesDefaulted + 1;
  daily.save();

  const protocol = getOrCreateProtocolMetric(event.block);
  if (protocol.activeDisputes.gt(ZERO)) {
    protocol.activeDisputes = protocol.activeDisputes.minus(ONE);
  }
  protocol.resolvedDisputes = protocol.resolvedDisputes.plus(ONE);
  if (outcome == "TIMEOUT_WITH_BURN") protocol.timedOutDisputes = protocol.timedOutDisputes.plus(ONE);
  if (outcome == "DEFAULT_LICENSE_APPLIED") protocol.defaultedDisputes = protocol.defaultedDisputes.plus(ONE);
  // Mean over resolved disputes, derived from the exact sum (a running mean of rounded values drifts down)
  protocol.totalResolutionBlocks = protocol.totalResolutionBlocks.plus(event.block.number.minus(dispute.startBlock));
  protocol.avgResolutionBlocks = protocol.totalResolutionBlocks.div(protocol.resolvedDisputes);
  protocol.save();
}

// =============================================================================
// Scores, configuration and funds
// =============================================================================

export function handleHarassmentScoreUpdated(event: HarassmentScoreUpdated): void {
  const party = touchParty(event.params.participant, event.block.timestamp);
  party.harassmentScore = event.params.newScore;
  party.save();

  const record = new HarassmentScore(eventId(event));
  record.party = party.id;
  record.source = "ILRM";
  record.oldScore = event.params.oldScore;
  record.newScore = event.params.newScore;
  record.timestamp = event.block.timestamp;
  record.txHash = event.transaction.hash;
  record.save();
}

export function handleSubsidyTreasuryUpdated(event: SubsidyTreasuryUpdated): void {
  const contract = getOrCreateContract(event, KIND_ILRM);
  const treasury: Address = event.params.newTreasury;
  if (isZeroAddress(treasury)) {
    contract.subsidyTreasury = null; // subsidies disabled
  } else {
    contract.subsidyTreasury = treasury;
  }
  contract.save();

  const entry = newAdminEvent(event, KIND_ILRM, "SubsidyTreasuryUpdated");
  entry.account = event.params.newTreasury;
  entry.previousAccount = event.params.previousTreasury;
  entry.save();
}

export function handleInitiatorIncentiveCapsUpdated(event: InitiatorIncentiveCapsUpdated): void {
  // Emitted by setInitiatorIncentiveCaps and once by the constructor (defaults)
  const contract = getOrCreateContract(event, KIND_ILRM);
  contract.maxIncentivePerDispute = event.params.maxPerDispute;
  contract.maxIncentivePerWindow = event.params.maxPerWindow;
  contract.incentiveWindow = event.params.window;
  contract.save();

  const entry = newAdminEvent(event, KIND_ILRM, "InitiatorIncentiveCapsUpdated");
  entry.details =
    "maxPerDispute=" +
    event.params.maxPerDispute.toString() +
    " maxPerWindow=" +
    event.params.maxPerWindow.toString() +
    " window=" +
    event.params.window.toString();
  entry.save();
}

export function handleTokenReservesDeposited(event: TokenReservesDeposited): void {
  const entry = newAdminEvent(event, KIND_ILRM, "TokenReservesDeposited");
  entry.account = event.params.depositor;
  entry.amount = event.params.amount;
  entry.save();
}

export function handleTreasuryWithdrawn(event: TreasuryWithdrawn): void {
  const entry = newAdminEvent(event, KIND_ILRM, "TreasuryWithdrawn");
  entry.account = event.params.recipient;
  entry.amount = event.params.amount;
  entry.save();
}

// =============================================================================
// Ownable2Step / Pausable
// =============================================================================

export function handleOwnershipTransferStarted(event: OwnershipTransferStarted): void {
  recordOwnershipTransferStarted(event, KIND_ILRM, event.params.previousOwner, event.params.newOwner);
}

export function handleOwnershipTransferred(event: OwnershipTransferred): void {
  recordOwnershipTransferred(event, KIND_ILRM, event.params.previousOwner, event.params.newOwner);
}

export function handlePaused(event: Paused): void {
  recordPause(event, KIND_ILRM, event.params.account, true);
}

export function handleUnpaused(event: Unpaused): void {
  recordPause(event, KIND_ILRM, event.params.account, false);
}
