// =============================================================================
// Treasury Event Handlers - TheGraph Subgraph
// =============================================================================
// Handles every event of contracts/Treasury.sol (NatLangChainTreasury).
// Stake subsidies are escrowed in ILRM: the dispute-side view (StakeSubsidy,
// repayments, protocol totals) comes from ILRM.StakeSubsidized/SubsidyReturned;
// SubsidyFunded here feeds only the Treasury-side records and daily metrics, so
// nothing is counted twice.
// =============================================================================

import { BigInt } from "@graphprotocol/graph-ts";
import {
  CapsUpdated,
  HarassmentScoreUpdated,
  ILRMUpdated,
  OwnershipTransferStarted,
  OwnershipTransferred,
  Paused,
  SubsidyFunded,
  TreasuryReceived,
  Unpaused
} from "../generated/Treasury/Treasury";
import {
  HarassmentScore,
  ProtocolContract,
  TreasuryDeposit,
  TreasuryMetric,
  TreasurySubsidy
} from "../generated/schema";
import {
  KIND_TREASURY,
  ZERO,
  dayStart,
  eventId,
  getOrCreateContract,
  newAdminEvent,
  recordOwnershipTransferStarted,
  recordOwnershipTransferred,
  recordPause,
  touchParty
} from "./common";

// Reasons used by the contract itself. deposit() takes free text from any caller, so a reason is only a
// label: "burn" counts as burn proceeds only when sent by the Treasury's ILRM (see isBurnDeposit).
const REASON_BURN = "burn"; // depositBurn() (ILRM-only)
const REASON_ETH = "eth"; // receive()

function getOrCreateTreasuryMetric(timestamp: BigInt): TreasuryMetric {
  const date = dayStart(timestamp);
  const id = date.toString();
  let metric = TreasuryMetric.load(id);
  if (metric == null) {
    metric = new TreasuryMetric(id);
    metric.date = date;
    metric.totalSubsidies = ZERO;
    metric.subsidyCount = 0;
    metric.totalReceived = ZERO;
    metric.totalBurnDeposits = ZERO;
    metric.burnDepositCount = 0;
    metric.totalReceivedEth = ZERO;
  }
  return metric;
}

/**
 * Whether a TreasuryReceived log is burn proceeds. depositBurn() is ILRM-only and labels its inflow "burn",
 * but deposit() lets anyone pick the same label, so the label alone is not trusted: the sender must also
 * be the ILRM the Treasury had at that point (ProtocolContract.ilrm, from ILRMUpdated). Only that ILRM can
 * emit a "burn" inflow from its own address. No ILRM indexed yet means no burn deposits.
 */
function isBurnDeposit(event: TreasuryReceived): boolean {
  if (event.params.reason != REASON_BURN) return false;
  const contract = ProtocolContract.load(event.address.toHexString());
  if (contract == null) return false;
  const ilrm = contract.ilrm;
  return ilrm !== null && ilrm.equals(event.params.from);
}

// =============================================================================
// Subsidies and inflows
// =============================================================================

export function handleSubsidyFunded(event: SubsidyFunded): void {
  const participant = touchParty(event.params.participant, event.block.timestamp);

  const grant = new TreasurySubsidy(eventId(event));
  grant.treasury = event.address;
  grant.participant = participant.id;
  grant.disputeId = event.params.disputeId;
  grant.dispute = event.params.disputeId.toString();
  grant.amount = event.params.amount;
  grant.timestamp = event.block.timestamp;
  grant.txHash = event.transaction.hash;
  grant.save();

  const metric = getOrCreateTreasuryMetric(event.block.timestamp);
  metric.totalSubsidies = metric.totalSubsidies.plus(event.params.amount);
  metric.subsidyCount = metric.subsidyCount + 1;
  metric.save();
}

export function handleTreasuryReceived(event: TreasuryReceived): void {
  const reason = event.params.reason;
  // receive() logs ETH with reason "eth". deposit() takes free text, so a token deposit labelled
  // "eth" is indistinguishable from an ETH transfer in this event.
  const isEth = reason == REASON_ETH;
  const isBurn = isBurnDeposit(event);

  const deposit = new TreasuryDeposit(eventId(event));
  deposit.treasury = event.address;
  deposit.from = event.params.from;
  deposit.amount = event.params.amount;
  deposit.reason = reason;
  deposit.isEth = isEth;
  deposit.isBurn = isBurn;
  deposit.timestamp = event.block.timestamp;
  deposit.txHash = event.transaction.hash;
  deposit.save();

  const metric = getOrCreateTreasuryMetric(event.block.timestamp);
  if (isEth) {
    metric.totalReceivedEth = metric.totalReceivedEth.plus(event.params.amount);
  } else {
    metric.totalReceived = metric.totalReceived.plus(event.params.amount);
    if (isBurn) {
      metric.totalBurnDeposits = metric.totalBurnDeposits.plus(event.params.amount);
      metric.burnDepositCount = metric.burnDepositCount + 1;
    }
  }
  metric.save();
}

export function handleHarassmentScoreUpdated(event: HarassmentScoreUpdated): void {
  // The Treasury keeps its own 0-100 score, separate from ILRM.harassmentScore
  const party = touchParty(event.params.participant, event.block.timestamp);
  party.treasuryHarassmentScore = event.params.newScore;
  party.save();

  const record = new HarassmentScore(eventId(event));
  record.party = party.id;
  record.source = "TREASURY";
  record.oldScore = event.params.oldScore;
  record.newScore = event.params.newScore;
  record.timestamp = event.block.timestamp;
  record.txHash = event.transaction.hash;
  record.save();
}

// =============================================================================
// Configuration
// =============================================================================

export function handleILRMUpdated(event: ILRMUpdated): void {
  const contract = getOrCreateContract(event, KIND_TREASURY);
  contract.ilrm = event.params.newILRM;
  contract.save();

  const entry = newAdminEvent(event, KIND_TREASURY, "ILRMUpdated");
  entry.account = event.params.newILRM;
  entry.previousAccount = event.params.oldILRM;
  entry.save();
}

export function handleCapsUpdated(event: CapsUpdated): void {
  const contract = getOrCreateContract(event, KIND_TREASURY);
  contract.maxSubsidyPerDispute = event.params.maxPerDispute;
  contract.maxSubsidyPerParticipant = event.params.maxPerParticipant;
  contract.subsidyWindowDuration = event.params.windowDuration;
  contract.save();

  const entry = newAdminEvent(event, KIND_TREASURY, "CapsUpdated");
  entry.details =
    "maxPerDispute=" +
    event.params.maxPerDispute.toString() +
    " maxPerParticipant=" +
    event.params.maxPerParticipant.toString() +
    " windowDuration=" +
    event.params.windowDuration.toString();
  entry.save();
}

// =============================================================================
// Ownable2Step / Pausable
// =============================================================================

export function handleOwnershipTransferStarted(event: OwnershipTransferStarted): void {
  recordOwnershipTransferStarted(event, KIND_TREASURY, event.params.previousOwner, event.params.newOwner);
}

export function handleOwnershipTransferred(event: OwnershipTransferred): void {
  recordOwnershipTransferred(event, KIND_TREASURY, event.params.previousOwner, event.params.newOwner);
}

export function handlePaused(event: Paused): void {
  recordPause(event, KIND_TREASURY, event.params.account, true);
}

export function handleUnpaused(event: Unpaused): void {
  recordPause(event, KIND_TREASURY, event.params.account, false);
}
