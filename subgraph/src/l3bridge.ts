// =============================================================================
// L3Bridge Event Handlers - TheGraph Subgraph
// =============================================================================
// Handles every event of contracts/scaling/L3Bridge.sol.
// L3Bridge has no batch ids: the unit of submission is a state commitment keyed
// by its state root, placed at a 1-based height on a single canonical chain.
// Event order inside one transaction mirrors the contract:
//   revealFraudProof (win): FraudProofRevealed, CommittedChainRolledBack,
//                           FraudProofSubmitted, FraudProofValidated
//   revealFraudProof (else): FraudProofRevealed, FraudProofForfeited | FraudProofRefunded
//   submitFraudProof:       CommittedChainRolledBack, FraudProofSubmitted, FraudProofValidated
//   batchProcessSettlements: per message, DisputeSettledFromL3 | SettlementSkipped
// One transaction can hold several of these calls (e.g. from a contract), so a reveal of the
// same transaction is linked to a success only while its commitment is still PENDING.
// =============================================================================

import { Address, BigInt, Bytes, ethereum } from "@graphprotocol/graph-ts";
import {
  L3Bridge,
  BridgeStatusChanged,
  CommittedChainRolledBack,
  DisputeBridgeSkipped,
  DisputeBridgedToL3,
  DisputeBridgerUpdated,
  DisputeSettledFromL3,
  FeesWithdrawn,
  FraudProofCommitted,
  FraudProofForfeited,
  FraudProofRefunded,
  FraudProofRevealed,
  FraudProofSubmitted,
  FraudProofValidated,
  OwnershipTransferStarted,
  OwnershipTransferred,
  Paused,
  SequencerUpdated,
  SettlementRelayerUpdated,
  SettlementSkipped,
  StateCommitmentFinalized,
  StateCommitmentSubmitted,
  Unpaused
} from "../generated/L3Bridge/L3Bridge";
import {
  FraudProofChallenge,
  FraudProofCommitment,
  L3BridgedDispute,
  L3Chain,
  L3ChainSlot,
  L3Metric,
  L3SettlementSkip,
  L3StateCommitment
} from "../generated/schema";
import {
  KIND_L3_BRIDGE,
  ONE,
  ZERO,
  dayStart,
  eventId,
  getOrCreateContract,
  getOrCreateDailyMetric,
  getOrCreateProtocolMetric,
  isZeroBytes,
  newAdminEvent,
  recordOwnershipTransferStarted,
  recordOwnershipTransferred,
  recordPause,
  setRole
} from "./common";

// =============================================================================
// Enum mirrors (IL3Bridge.sol)
// =============================================================================

function bridgeStatusName(value: i32): string {
  if (value == 1) return "PAUSED";
  if (value == 2) return "DEPRECATED";
  return "ACTIVE";
}

function settlementSkipReasonName(value: i32): string {
  if (value == 1) return "NOT_BRIDGED";
  if (value == 2) return "L3_DISPUTE_ID_MISMATCH";
  if (value == 3) return "ALREADY_SETTLED";
  if (value == 4) return "STATE_ROOT_NOT_FINALIZED";
  return "UNKNOWN"; // 0 = None is never emitted for a skip
}

function l3DisputeStateName(value: i32): string {
  if (value == 1) return "ACTIVE";
  if (value == 2) return "PROPOSAL_SUBMITTED";
  if (value == 3) return "ACCEPTED";
  if (value == 4) return "TIMED_OUT";
  if (value == 5) return "SETTLED";
  return "PENDING";
}

// =============================================================================
// Helpers
// =============================================================================

function getOrCreateChain(bridge: Address): L3Chain {
  const id = bridge.toHexString();
  let chain = L3Chain.load(id);
  if (chain == null) {
    chain = new L3Chain(id);
    chain.latestCommittedHeight = ZERO;
    chain.latestFinalizedHeight = ZERO;
    chain.latestFinalizedL3Block = ZERO;
    chain.totalCommitments = ZERO;
    chain.totalBridgedDisputes = ZERO;
    chain.totalSettlements = ZERO;
  }
  return chain;
}

function slotId(bridge: Address, height: BigInt): string {
  return bridge.toHexString() + "-" + height.toString();
}

function commitmentId(challenger: Address, commitHash: Bytes): string {
  return challenger.toHexString() + "-" + commitHash.toHexString();
}

function getOrCreateL3Metric(timestamp: BigInt): L3Metric {
  const date = dayStart(timestamp);
  const id = date.toString();
  let metric = L3Metric.load(id);
  if (metric == null) {
    metric = new L3Metric(id);
    metric.date = date;
    metric.commitmentsSubmitted = 0;
    metric.commitmentsFinalized = 0;
    metric.commitmentsRejected = 0;
    metric.commitmentsOrphaned = 0;
    metric.totalDisputesCommitted = ZERO;
    metric.fraudProofsCommitted = 0;
    metric.fraudProofsWon = 0;
    metric.fraudProofsRefunded = 0;
    metric.fraudProofsForfeited = 0;
    metric.bondsForfeited = ZERO;
    metric.rewardsPaid = ZERO;
    metric.disputesBridged = 0;
    metric.disputesSettled = 0;
    metric.settlementsSkipped = 0;
  }
  return metric;
}

/** Successful challenge of `root`; the success events fill it in one transaction */
function getOrCreateChallenge(root: Bytes, event: ethereum.Event): FraudProofChallenge {
  const id = root.toHexString();
  let challenge = FraudProofChallenge.load(id);
  if (challenge == null) {
    challenge = new FraudProofChallenge(id);
    challenge.stateCommitment = id;
    // Placeholders until FraudProofSubmitted (same transaction) names the challenger and dispute
    challenge.challenger = Address.zero();
    challenge.disputeId = ZERO;
    challenge.mode = "DIRECT";
    challenge.orphanedCount = 0;
    challenge.timestamp = event.block.timestamp;
    challenge.txHash = event.transaction.hash;
  }
  return challenge;
}

function resolveCommitment(
  event: ethereum.Event,
  challenger: Address,
  commitHash: Bytes,
  status: string
): FraudProofCommitment | null {
  const commitment = FraudProofCommitment.load(commitmentId(challenger, commitHash));
  if (commitment == null) return null;
  commitment.status = status;
  commitment.resolvedAt = event.block.timestamp;
  commitment.resolveTx = event.transaction.hash;
  commitment.save();
  return commitment;
}

// =============================================================================
// State commitments
// =============================================================================

export function handleStateCommitmentSubmitted(event: StateCommitmentSubmitted): void {
  const root = event.params.stateRoot;
  const timestamp = event.block.timestamp;
  const chain = getOrCreateChain(event.address);

  // Mirrors submitStateCommitment: chained to the committed head, or to the finalized head
  // when no commitment is pending; placed one above the committed head
  const height = chain.latestCommittedHeight.plus(ONE);
  const parent = chain.latestCommittedRoot !== null ? chain.latestCommittedRoot : chain.latestFinalizedRoot;

  const commitment = new L3StateCommitment(root.toHexString());
  commitment.bridge = event.address;
  commitment.stateRoot = root;
  commitment.l3BlockNumber = event.params.blockNumber;
  commitment.disputeCount = event.params.disputeCount;
  commitment.sequencer = event.params.sequencer;
  commitment.height = height;
  commitment.previousRoot = parent;
  commitment.status = "PENDING";
  commitment.submittedAt = timestamp;
  commitment.submittedBlock = event.block.number;
  commitment.txHash = event.transaction.hash;
  // Snapshotted at submission and never changed afterwards
  const deadline = L3Bridge.bind(event.address).try_getChallengeDeadline(root);
  if (!deadline.reverted) commitment.challengeDeadline = deadline.value;
  commitment.save();

  const slot = new L3ChainSlot(slotId(event.address, height));
  slot.root = root;
  slot.save();

  chain.latestCommittedRoot = root;
  chain.latestCommittedHeight = height;
  chain.totalCommitments = chain.totalCommitments.plus(ONE);
  chain.save();

  const metric = getOrCreateL3Metric(timestamp);
  metric.commitmentsSubmitted = metric.commitmentsSubmitted + 1;
  metric.totalDisputesCommitted = metric.totalDisputesCommitted.plus(event.params.disputeCount);
  metric.save();

  const daily = getOrCreateDailyMetric(timestamp);
  daily.l3Commitments = daily.l3Commitments + 1;
  daily.save();

  const protocol = getOrCreateProtocolMetric(event.block);
  protocol.totalL3Commitments = protocol.totalL3Commitments.plus(ONE);
  protocol.save();
}

export function handleStateCommitmentFinalized(event: StateCommitmentFinalized): void {
  const commitment = L3StateCommitment.load(event.params.stateRoot.toHexString());
  if (commitment == null) return;

  commitment.status = "FINALIZED";
  commitment.finalizedAt = event.block.timestamp;
  commitment.save();

  const chain = getOrCreateChain(event.address);
  chain.latestFinalizedRoot = event.params.stateRoot;
  chain.latestFinalizedHeight = commitment.height;
  chain.latestFinalizedL3Block = event.params.blockNumber;
  chain.save();

  const metric = getOrCreateL3Metric(event.block.timestamp);
  metric.commitmentsFinalized = metric.commitmentsFinalized + 1;
  metric.save();
}

// =============================================================================
// Fraud proofs (commit-reveal)
// =============================================================================

export function handleFraudProofCommitted(event: FraudProofCommitted): void {
  const commitment = new FraudProofCommitment(commitmentId(event.params.challenger, event.params.commitHash));
  commitment.commitHash = event.params.commitHash;
  commitment.stateCommitment = event.params.stateRoot.toHexString();
  commitment.challenger = event.params.challenger;
  commitment.bond = event.params.bond;
  commitment.status = "PENDING";
  commitment.committedAt = event.block.timestamp;
  commitment.commitTx = event.transaction.hash;
  commitment.save();

  const metric = getOrCreateL3Metric(event.block.timestamp);
  metric.fraudProofsCommitted = metric.fraudProofsCommitted + 1;
  metric.save();
}

export function handleFraudProofRevealed(event: FraudProofRevealed): void {
  const commitment = FraudProofCommitment.load(commitmentId(event.params.challenger, event.params.commitHash));
  if (commitment == null) return;
  commitment.revealedAt = event.block.timestamp;
  commitment.save();

  // Lets FraudProofValidated (same transaction, no commit hash) find the winning commitment
  const stateCommitment = L3StateCommitment.load(event.params.stateRoot.toHexString());
  if (stateCommitment != null) {
    stateCommitment.lastRevealCommitment = commitment.id;
    stateCommitment.lastRevealTx = event.transaction.hash;
    stateCommitment.save();
  }
}

export function handleFraudProofForfeited(event: FraudProofForfeited): void {
  // Invalid or mismatched reveal, or never revealed (forfeitExpiredCommitment)
  resolveCommitment(event, event.params.challenger, event.params.commitHash, "FORFEITED");

  const metric = getOrCreateL3Metric(event.block.timestamp);
  metric.fraudProofsForfeited = metric.fraudProofsForfeited + 1;
  metric.bondsForfeited = metric.bondsForfeited.plus(event.params.bond);
  metric.save();
}

export function handleFraudProofRefunded(event: FraudProofRefunded): void {
  // Valid proof against a root that was already rejected or orphaned
  resolveCommitment(event, event.params.challenger, event.params.commitHash, "REFUNDED");

  const metric = getOrCreateL3Metric(event.block.timestamp);
  metric.fraudProofsRefunded = metric.fraudProofsRefunded + 1;
  metric.save();
}

// =============================================================================
// Successful challenges
// =============================================================================

export function handleCommittedChainRolledBack(event: CommittedChainRolledBack): void {
  const chain = getOrCreateChain(event.address);
  const rejected = event.params.rejectedRoot;
  const newHeight = event.params.newHeight;
  const timestamp = event.block.timestamp;

  // The rejected root and every root above it on the canonical chain are dead
  let orphaned = 0;
  let rejectedSeen = false;
  for (let h = newHeight.plus(ONE); h.le(chain.latestCommittedHeight); h = h.plus(ONE)) {
    const slot = L3ChainSlot.load(slotId(event.address, h));
    if (slot == null) continue;
    const commitment = L3StateCommitment.load(slot.root.toHexString());
    if (commitment == null || commitment.status != "PENDING") continue;
    if (slot.root.equals(rejected)) {
      commitment.status = "REJECTED";
      rejectedSeen = true;
    } else {
      commitment.status = "ORPHANED";
      orphaned++;
    }
    commitment.invalidatedAt = timestamp;
    commitment.save();
  }
  if (!rejectedSeen) {
    const commitment = L3StateCommitment.load(rejected.toHexString());
    if (commitment != null) {
      commitment.status = "REJECTED";
      commitment.invalidatedAt = timestamp;
      commitment.save();
    }
  }

  chain.latestCommittedRoot = isZeroBytes(event.params.newHead) ? null : event.params.newHead;
  chain.latestCommittedHeight = newHeight;
  chain.save();

  const challenge = getOrCreateChallenge(rejected, event);
  challenge.newHead = event.params.newHead;
  challenge.newHeight = newHeight;
  challenge.orphanedCount = orphaned;
  challenge.save();

  const metric = getOrCreateL3Metric(timestamp);
  metric.commitmentsRejected = metric.commitmentsRejected + 1;
  metric.commitmentsOrphaned = metric.commitmentsOrphaned + orphaned;
  metric.save();
}

export function handleFraudProofSubmitted(event: FraudProofSubmitted): void {
  // Despite its name this is emitted only for a successful challenge, by both proof paths
  const root = event.params.claimedRoot;
  const challenge = getOrCreateChallenge(root, event);
  challenge.challenger = event.params.challenger;
  challenge.disputeId = event.params.disputeId;
  challenge.mode = "DIRECT";

  const stateCommitment = L3StateCommitment.load(root.toHexString());
  if (stateCommitment != null) {
    const revealId = stateCommitment.lastRevealCommitment;
    const revealTx = stateCommitment.lastRevealTx;
    if (revealId !== null && revealTx !== null && revealTx.equals(event.transaction.hash)) {
      // The winning reveal is still PENDING here (FraudProofValidated settles it). A reveal earlier in
      // the same transaction that was already forfeited or refunded is not this challenge's commitment:
      // linking it would relabel its kept bond WON (e.g. a forfeited reveal, then submitFraudProof).
      const commitment = FraudProofCommitment.load(revealId);
      if (
        commitment != null &&
        commitment.status == "PENDING" &&
        commitment.challenger.equals(event.params.challenger)
      ) {
        challenge.mode = "COMMIT_REVEAL";
        challenge.commitment = commitment.id;
      }
    }
    stateCommitment.challenge = challenge.id;
    stateCommitment.save();
  }
  challenge.save();
}

export function handleFraudProofValidated(event: FraudProofValidated): void {
  const challenge = getOrCreateChallenge(event.params.claimedRoot, event);
  challenge.challenger = event.params.challenger;
  challenge.reward = event.params.reward;
  challenge.save();

  const commitmentRef = challenge.commitment;
  if (commitmentRef !== null) {
    const commitment = FraudProofCommitment.load(commitmentRef);
    if (commitment != null) {
      commitment.status = "WON";
      commitment.reward = event.params.reward;
      commitment.resolvedAt = event.block.timestamp;
      commitment.resolveTx = event.transaction.hash;
      commitment.save();
    }
  }

  const metric = getOrCreateL3Metric(event.block.timestamp);
  metric.fraudProofsWon = metric.fraudProofsWon + 1;
  metric.rewardsPaid = metric.rewardsPaid.plus(event.params.reward);
  metric.save();
}

// =============================================================================
// Dispute bridging and settlement
// =============================================================================

export function handleDisputeBridgedToL3(event: DisputeBridgedToL3): void {
  const id = event.params.l2DisputeId.toString();
  const bridged = new L3BridgedDispute(id);
  bridged.dispute = id;
  bridged.l3DisputeId = event.params.l3DisputeId;
  bridged.initiator = event.params.initiator;
  bridged.stakeAmount = event.params.stakeAmount;
  bridged.bridgedAt = event.block.timestamp;
  bridged.bridgeTx = event.transaction.hash;
  bridged.skippedRebridges = 0;
  bridged.skippedSettlements = 0;
  bridged.settled = false;
  bridged.save();

  const chain = getOrCreateChain(event.address);
  chain.totalBridgedDisputes = chain.totalBridgedDisputes.plus(ONE);
  chain.save();

  const metric = getOrCreateL3Metric(event.block.timestamp);
  metric.disputesBridged = metric.disputesBridged + 1;
  metric.save();
}

export function handleDisputeBridgeSkipped(event: DisputeBridgeSkipped): void {
  const bridged = L3BridgedDispute.load(event.params.l2DisputeId.toString());
  if (bridged == null) return;
  bridged.skippedRebridges = bridged.skippedRebridges + 1;
  bridged.save();
}

export function handleDisputeSettledFromL3(event: DisputeSettledFromL3): void {
  const bridged = L3BridgedDispute.load(event.params.l2DisputeId.toString());
  if (bridged == null) return;
  bridged.settled = true;
  bridged.outcome = l3DisputeStateName(event.params.outcome);
  bridged.initiatorReturn = event.params.initiatorReturn;
  bridged.counterpartyReturn = event.params.counterpartyReturn;
  bridged.settledAt = event.block.timestamp;
  bridged.settlementTx = event.transaction.hash;
  bridged.save();

  const chain = getOrCreateChain(event.address);
  chain.totalSettlements = chain.totalSettlements.plus(ONE);
  chain.save();

  const metric = getOrCreateL3Metric(event.block.timestamp);
  metric.disputesSettled = metric.disputesSettled + 1;
  metric.save();
}

export function handleSettlementSkipped(event: SettlementSkipped): void {
  // batchProcessSettlements skips a message that fails a check instead of reverting the batch
  const id = event.params.l2DisputeId.toString();
  const skip = new L3SettlementSkip(eventId(event));
  skip.bridge = event.address;
  skip.l2DisputeId = event.params.l2DisputeId;
  skip.l3DisputeId = event.params.l3DisputeId;
  skip.reason = settlementSkipReasonName(event.params.reason);
  skip.reasonCode = event.params.reason;
  skip.dispute = id;
  const bridged = L3BridgedDispute.load(id);
  if (bridged != null) {
    skip.bridgedDispute = bridged.id;
    bridged.skippedSettlements = bridged.skippedSettlements + 1;
    bridged.save();
  }
  skip.timestamp = event.block.timestamp;
  skip.blockNumber = event.block.number;
  skip.txHash = event.transaction.hash;
  skip.save();

  const metric = getOrCreateL3Metric(event.block.timestamp);
  metric.settlementsSkipped = metric.settlementsSkipped + 1;
  metric.save();
}

// =============================================================================
// Configuration and roles
// =============================================================================

export function handleSequencerUpdated(event: SequencerUpdated): void {
  const contract = getOrCreateContract(event, KIND_L3_BRIDGE);
  contract.sequencer = event.params.newSequencer;
  contract.save();

  const entry = newAdminEvent(event, KIND_L3_BRIDGE, "SequencerUpdated");
  entry.account = event.params.newSequencer;
  entry.previousAccount = event.params.oldSequencer;
  entry.save();
}

export function handleBridgeStatusChanged(event: BridgeStatusChanged): void {
  const status = bridgeStatusName(event.params.newStatus);
  const contract = getOrCreateContract(event, KIND_L3_BRIDGE);
  contract.bridgeStatus = status;
  contract.save();

  const entry = newAdminEvent(event, KIND_L3_BRIDGE, "BridgeStatusChanged");
  entry.details = bridgeStatusName(event.params.oldStatus) + " -> " + status;
  entry.save();
}

export function handleDisputeBridgerUpdated(event: DisputeBridgerUpdated): void {
  setRole(event, KIND_L3_BRIDGE, "L3_DISPUTE_BRIDGER", event.params.account, event.params.authorized);

  const entry = newAdminEvent(event, KIND_L3_BRIDGE, "DisputeBridgerUpdated");
  entry.account = event.params.account;
  entry.flag = event.params.authorized;
  entry.save();
}

export function handleSettlementRelayerUpdated(event: SettlementRelayerUpdated): void {
  setRole(event, KIND_L3_BRIDGE, "L3_SETTLEMENT_RELAYER", event.params.account, event.params.authorized);

  const entry = newAdminEvent(event, KIND_L3_BRIDGE, "SettlementRelayerUpdated");
  entry.account = event.params.account;
  entry.flag = event.params.authorized;
  entry.save();
}

export function handleFeesWithdrawn(event: FeesWithdrawn): void {
  const entry = newAdminEvent(event, KIND_L3_BRIDGE, "FeesWithdrawn");
  entry.account = event.params.to;
  entry.amount = event.params.amount;
  entry.save();
}

// =============================================================================
// Ownable2Step / Pausable
// =============================================================================

export function handleOwnershipTransferStarted(event: OwnershipTransferStarted): void {
  recordOwnershipTransferStarted(event, KIND_L3_BRIDGE, event.params.previousOwner, event.params.newOwner);
}

export function handleOwnershipTransferred(event: OwnershipTransferred): void {
  recordOwnershipTransferred(event, KIND_L3_BRIDGE, event.params.previousOwner, event.params.newOwner);
}

export function handlePaused(event: Paused): void {
  // L3Bridge pause freezes finalization only; bridging and settlements follow bridgeStatus
  recordPause(event, KIND_L3_BRIDGE, event.params.account, true);
}

export function handleUnpaused(event: Unpaused): void {
  recordPause(event, KIND_L3_BRIDGE, event.params.account, false);
}
