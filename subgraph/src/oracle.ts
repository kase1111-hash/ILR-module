// =============================================================================
// Oracle Event Handlers - TheGraph Subgraph
// =============================================================================
// Handles every event of contracts/Oracle.sol (NatLangChainOracle).
// Event order inside one transaction mirrors the contract:
//   submitProposal:       (ILRM events), ProposalSubmittedToILRM, ProposalRoundFilled, DisputeProcessed
//   resetProposal:        ProposalReset, ProposalRoundReopened
//   requestProposal:      ProposalRequested, DisputeProcessed (proposalHash = 0)
//   cancelPendingRequest: ProposalRequested with zero evidenceHash and timestamp
// =============================================================================

import { BigInt, ethereum } from "@graphprotocol/graph-ts";
import {
  DisputeProcessed,
  OracleRegistered,
  OwnershipTransferStarted,
  OwnershipTransferred,
  ProposalRequested,
  ProposalReset,
  ProposalRoundFilled,
  ProposalRoundReopened,
  ProposalSubmittedToILRM
} from "../generated/Oracle/Oracle";
import { OracleDispute, OracleMetric, OracleReset, OracleRound, OracleSubmission } from "../generated/schema";
import {
  KIND_ORACLE,
  ONE,
  ZERO,
  dayStart,
  eventId,
  isZeroBytes,
  newAdminEvent,
  recordOwnershipTransferStarted,
  recordOwnershipTransferred,
  setRole
} from "./common";

// =============================================================================
// Helpers
// =============================================================================

function getOrCreateOracleDispute(disputeId: BigInt, event: ethereum.Event): OracleDispute {
  const id = disputeId.toString();
  let od = OracleDispute.load(id);
  if (od == null) {
    od = new OracleDispute(id);
    od.dispute = id;
    od.pending = false;
    od.requestCount = 0;
    od.cancelCount = 0;
    od.nextNonce = ZERO;
    od.submissionCount = 0;
    od.resetCount = 0;
  }
  od.updatedAt = event.block.timestamp;
  return od;
}

function getOrCreateRound(od: OracleDispute, round: BigInt): OracleRound {
  const id = od.id + "-" + round.toString();
  let entity = OracleRound.load(id);
  if (entity == null) {
    entity = new OracleRound(id);
    entity.oracleDispute = od.id;
    entity.round = round;
    entity.filled = false;
    entity.fillCount = 0;
    entity.reopenCount = 0;
  }
  return entity;
}

function getOrCreateOracleMetric(timestamp: BigInt): OracleMetric {
  const date = dayStart(timestamp);
  const id = date.toString();
  let metric = OracleMetric.load(id);
  if (metric == null) {
    metric = new OracleMetric(id);
    metric.date = date;
    metric.proposalsRequested = 0;
    metric.requestsCancelled = 0;
    metric.proposalsSubmitted = 0;
    metric.proposalsReset = 0;
    metric.avgResponseSeconds = ZERO;
    metric.responseSamples = 0;
  }
  return metric;
}

// =============================================================================
// Requests
// =============================================================================

export function handleProposalRequested(event: ProposalRequested): void {
  const od = getOrCreateOracleDispute(event.params.disputeId, event);
  const metric = getOrCreateOracleMetric(event.block.timestamp);

  if (event.params.timestamp.equals(ZERO)) {
    // cancelPendingRequest re-uses this event with zero values
    od.pending = false;
    od.openRequestAt = null;
    od.cancelCount = od.cancelCount + 1;
    metric.requestsCancelled = metric.requestsCancelled + 1;
  } else {
    od.pending = true;
    od.requestCount = od.requestCount + 1;
    od.lastRequestedAt = event.params.timestamp;
    od.lastRequestEvidenceHash = event.params.evidenceHash;
    od.openRequestAt = event.params.timestamp;
    metric.proposalsRequested = metric.proposalsRequested + 1;
  }
  od.save();
  metric.save();
}

// =============================================================================
// Submissions
// =============================================================================

export function handleProposalSubmittedToILRM(event: ProposalSubmittedToILRM): void {
  // Bookkeeping only: ProposalRoundFilled (next) records the submission with its round and nonce
  const od = getOrCreateOracleDispute(event.params.disputeId, event);
  od.pending = false;
  od.lastOperator = event.params.oracle;
  od.lastSubmissionTx = event.transaction.hash;
  od.save();
}

export function handleProposalRoundFilled(event: ProposalRoundFilled): void {
  const od = getOrCreateOracleDispute(event.params.disputeId, event);
  const round = getOrCreateRound(od, event.params.round);
  const timestamp = event.block.timestamp;

  const submission = new OracleSubmission(round.id + "-" + event.params.nonce.toString());
  submission.oracleDispute = od.id;
  submission.round = round.id;
  submission.proposalHash = event.params.proposalHash;
  submission.nonce = event.params.nonce;
  const lastTx = od.lastSubmissionTx;
  const lastOperator = od.lastOperator;
  if (lastTx !== null && lastOperator !== null && lastTx.equals(event.transaction.hash)) {
    submission.operator = lastOperator;
  } else {
    submission.operator = event.transaction.from;
  }
  submission.voided = false;
  submission.timestamp = timestamp;
  submission.txHash = event.transaction.hash;

  const metric = getOrCreateOracleMetric(timestamp);
  const openRequestAt = od.openRequestAt;
  if (openRequestAt !== null && timestamp.ge(openRequestAt)) {
    const responseTime = timestamp.minus(openRequestAt);
    submission.responseTime = responseTime;
    const n = BigInt.fromI32(metric.responseSamples + 1);
    metric.avgResponseSeconds = metric.avgResponseSeconds.times(n.minus(ONE)).plus(responseTime).div(n);
    metric.responseSamples = metric.responseSamples + 1;
  }
  submission.save();

  round.proposalHash = event.params.proposalHash;
  round.filled = true;
  round.fillCount = round.fillCount + 1;
  round.lastFilledAt = timestamp;
  round.currentSubmission = submission.id;
  round.save();

  od.pending = false;
  od.openRequestAt = null;
  od.currentRound = event.params.round;
  od.nextNonce = event.params.nonce.plus(ONE); // the signature consumed `nonce`
  od.submissionCount = od.submissionCount + 1;
  od.save();

  metric.proposalsSubmitted = metric.proposalsSubmitted + 1;
  metric.save();
}

export function handleDisputeProcessed(event: DisputeProcessed): void {
  // Emitted on requests (proposalHash = 0) and after each submission; only the latter adds
  // information: the evidence hash the operator signed over.
  if (isZeroBytes(event.params.proposalHash)) return;

  const od = OracleDispute.load(event.params.disputeId.toString());
  if (od == null) return;
  const roundNumber = od.currentRound;
  if (roundNumber === null) return;
  const round = OracleRound.load(od.id + "-" + roundNumber.toString());
  if (round == null) return;
  const submissionId = round.currentSubmission;
  if (submissionId === null) return;
  const submission = OracleSubmission.load(submissionId);
  if (submission == null) return;

  if (submission.txHash.equals(event.transaction.hash) && submission.proposalHash.equals(event.params.proposalHash)) {
    submission.evidenceHash = event.params.evidenceHash;
    submission.save();
  }
}

// =============================================================================
// Owner recovery
// =============================================================================

export function handleProposalReset(event: ProposalReset): void {
  const od = getOrCreateOracleDispute(event.params.disputeId, event);

  const reset = new OracleReset(eventId(event));
  reset.oracleDispute = od.id;
  reset.voidedProposalHash = event.params.oldProposalHash;
  reset.reason = event.params.reason;
  reset.timestamp = event.block.timestamp;
  reset.txHash = event.transaction.hash;
  reset.save();

  // resetProposal re-opens the request and bumps the nonce (every older signature is dead)
  od.pending = true;
  od.openRequestAt = event.block.timestamp;
  od.nextNonce = od.nextNonce.plus(ONE);
  od.resetCount = od.resetCount + 1;
  od.lastReset = reset.id;
  od.lastResetTx = event.transaction.hash;
  od.save();

  const metric = getOrCreateOracleMetric(event.block.timestamp);
  metric.proposalsReset = metric.proposalsReset + 1;
  metric.save();
}

export function handleProposalRoundReopened(event: ProposalRoundReopened): void {
  const od = getOrCreateOracleDispute(event.params.disputeId, event);
  const round = getOrCreateRound(od, event.params.round);

  const submissionId = round.currentSubmission;
  if (submissionId !== null) {
    const submission = OracleSubmission.load(submissionId);
    if (submission != null) {
      submission.voided = true;
      submission.save();
    }
  }

  round.filled = false;
  round.proposalHash = null;
  round.currentSubmission = null;
  round.reopenCount = round.reopenCount + 1;
  round.lastReopenedAt = event.block.timestamp;
  round.save();

  // Complete the OracleReset written by ProposalReset in this transaction
  const resetId = od.lastReset;
  const resetTx = od.lastResetTx;
  if (resetId !== null && resetTx !== null && resetTx.equals(event.transaction.hash)) {
    const reset = OracleReset.load(resetId);
    if (reset != null) {
      reset.round = event.params.round;
      reset.save();
    }
  }
  od.save();
}

// =============================================================================
// Operators and ownership
// =============================================================================

export function handleOracleRegistered(event: OracleRegistered): void {
  // Emitted by registerOracle and updateOracleKey. revokeOracle emits nothing, so a
  // revoked operator still shows as active here.
  const member = setRole(event, KIND_ORACLE, "ORACLE_OPERATOR", event.params.oracle, true);
  member.publicKeyHash = event.params.publicKeyHash;
  member.save();

  const entry = newAdminEvent(event, KIND_ORACLE, "OracleRegistered");
  entry.account = event.params.oracle;
  entry.details = "publicKeyHash=" + event.params.publicKeyHash.toHexString();
  entry.save();
}

export function handleOwnershipTransferStarted(event: OwnershipTransferStarted): void {
  recordOwnershipTransferStarted(event, KIND_ORACLE, event.params.previousOwner, event.params.newOwner);
}

export function handleOwnershipTransferred(event: OwnershipTransferred): void {
  recordOwnershipTransferred(event, KIND_ORACLE, event.params.previousOwner, event.params.newOwner);
}
