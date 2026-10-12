// =============================================================================
// Shared helpers for all data sources
// =============================================================================
// Adding a new event:
//   1. Compile the contracts and run `npm run sync-abis` (see README.md).
//   2. Add the event signature + handler name to subgraph.yaml (the signature
//      must match the ABI exactly; `npm run check-abis` verifies it).
//   3. `npm run codegen`, then export the handler from the data source's
//      mapping file. Configuration / role / fund-management events usually need
//      no schema change: log them with newAdminEvent(...) and, if they carry
//      state worth querying, store it on ProtocolContract.
// =============================================================================

import { Address, BigInt, ByteArray, Bytes, crypto, ethereum } from "@graphprotocol/graph-ts";
import {
  AdminEvent,
  DailyMetric,
  Party,
  ProtocolContract,
  ProtocolMetric,
  RoleMember
} from "../generated/schema";

// =============================================================================
// Constants
// =============================================================================

export const ZERO = BigInt.zero();
export const ONE = BigInt.fromI32(1);
export const SECONDS_PER_DAY = BigInt.fromI32(86400);
export const PROTOCOL_METRIC_ID = "protocol";

// ContractKind enum values (schema.graphql)
export const KIND_ILRM = "ILRM";
export const KIND_TREASURY = "TREASURY";
export const KIND_ORACLE = "ORACLE";
export const KIND_L3_BRIDGE = "L3_BRIDGE";
export const KIND_ASSET_REGISTRY = "ASSET_REGISTRY";

// =============================================================================
// Ids, time and bytes
// =============================================================================

/** Unique id of a log: "<txHash>-<logIndex>" */
export function eventId(event: ethereum.Event): string {
  return event.transaction.hash.toHexString() + "-" + event.logIndex.toString();
}

/** Start of the UTC day containing `timestamp` */
export function dayStart(timestamp: BigInt): BigInt {
  return timestamp.div(SECONDS_PER_DAY).times(SECONDS_PER_DAY);
}

export function isZeroBytes(value: Bytes): boolean {
  for (let i = 0; i < value.length; i++) {
    if (value[i] != 0) return false;
  }
  return true;
}

export function isZeroAddress(value: Address): boolean {
  return isZeroBytes(value);
}

/** keccak256 of a UTF-8 string, e.g. a proposal text (matches Solidity keccak256(bytes(text))) */
export function keccakUtf8(text: string): Bytes {
  return Bytes.fromByteArray(crypto.keccak256(ByteArray.fromUTF8(text)));
}

/** 4-byte function selector of a canonical signature, e.g. "counterPropose(uint256,bytes32)" */
export function selector(signature: string): Bytes {
  return Bytes.fromUint8Array(keccakUtf8(signature).subarray(0, 4));
}

/**
 * ABI-encoded arguments of the transaction when it called `functionSignature` on the
 * emitting contract directly (not through a multisig, router or other contract); null otherwise.
 */
export function directCallArgs(event: ethereum.Event, functionSignature: string): Bytes | null {
  const to = event.transaction.to;
  if (to === null) return null;
  if (!to.equals(event.address)) return null;
  const input = event.transaction.input;
  if (input.length < 4) return null;
  const sel = selector(functionSignature);
  for (let i = 0; i < 4; i++) {
    if (input[i] != sel[i]) return null;
  }
  return Bytes.fromUint8Array(input.subarray(4));
}

// =============================================================================
// Parties
// =============================================================================

/** Load or create a Party, mark it active and save it */
export function touchParty(address: Address, timestamp: BigInt): Party {
  const id = address.toHexString();
  let party = Party.load(id);
  if (party == null) {
    party = new Party(id);
    party.totalDisputes = 0;
    party.disputesResolved = 0;
    party.disputesTimedOut = 0;
    party.disputesDefaulted = 0;
    party.totalStaked = ZERO;
    party.totalBurned = ZERO;
    party.harassmentScore = ZERO;
    party.treasuryHarassmentScore = ZERO;
    party.totalSubsidiesReceived = ZERO;
    party.voluntaryRequestsSent = 0;
    party.firstSeen = timestamp;
  }
  party.lastActive = timestamp;
  party.save();
  return party;
}

// =============================================================================
// Metrics
// =============================================================================

export function getOrCreateDailyMetric(timestamp: BigInt): DailyMetric {
  const date = dayStart(timestamp);
  const id = date.toString();
  let metric = DailyMetric.load(id);
  if (metric == null) {
    metric = new DailyMetric(id);
    metric.date = date;
    metric.disputesInitiated = 0;
    metric.disputesResolved = 0;
    metric.disputesTimedOut = 0;
    metric.disputesDefaulted = 0;
    metric.totalStaked = ZERO;
    metric.totalBurned = ZERO;
    metric.totalSubsidies = ZERO;
    metric.totalSubsidiesReturned = ZERO;
    metric.initiatorIncentivesPaid = ZERO;
    metric.newParticipants = 0;
    metric.counterProposals = 0;
    metric.proposals = 0;
    metric.voluntaryRequests = 0;
    metric.l3Commitments = 0;
  }
  return metric;
}

export function getOrCreateProtocolMetric(block: ethereum.Block): ProtocolMetric {
  let metric = ProtocolMetric.load(PROTOCOL_METRIC_ID);
  if (metric == null) {
    metric = new ProtocolMetric(PROTOCOL_METRIC_ID);
    metric.totalDisputes = ZERO;
    metric.activeDisputes = ZERO;
    metric.resolvedDisputes = ZERO;
    metric.timedOutDisputes = ZERO;
    metric.defaultedDisputes = ZERO;
    metric.totalValueStaked = ZERO;
    metric.totalValueBurned = ZERO;
    metric.totalSubsidiesDistributed = ZERO;
    metric.totalSubsidiesReturned = ZERO;
    metric.totalInitiatorIncentivesPaid = ZERO;
    metric.totalInitiatorIncentivesUncapped = ZERO;
    metric.cappedInitiatorIncentives = ZERO;
    metric.totalOracleRequestFailures = ZERO;
    metric.uniqueParticipants = ZERO;
    metric.totalProposals = ZERO;
    metric.totalCounterProposals = ZERO;
    metric.totalCounterFeesBurned = ZERO;
    metric.totalVoluntaryRequests = ZERO;
    metric.totalL3Commitments = ZERO;
    metric.totalResolutionBlocks = ZERO;
    metric.avgResolutionBlocks = ZERO;
  }
  metric.lastUpdatedBlock = block.number;
  return metric;
}

// =============================================================================
// Contracts, admin log, roles
// =============================================================================

/** Load or create the ProtocolContract for the emitting contract (not saved) */
export function getOrCreateContract(event: ethereum.Event, kind: string): ProtocolContract {
  const id = event.address.toHexString();
  let contract = ProtocolContract.load(id);
  if (contract == null) {
    contract = new ProtocolContract(id);
    contract.kind = kind;
    contract.paused = false;
    if (kind == KIND_L3_BRIDGE) {
      // L3Bridge constructor default; later changes emit BridgeStatusChanged
      contract.bridgeStatus = "ACTIVE";
    }
    contract.createdAt = event.block.timestamp;
  }
  contract.updatedAt = event.block.timestamp;
  return contract;
}

/**
 * Start an AdminEvent row for `event` (creates the ProtocolContract if needed).
 * Set the optional fields (account, previousAccount, flag, amount, details) and save.
 */
export function newAdminEvent(event: ethereum.Event, kind: string, name: string): AdminEvent {
  const contract = getOrCreateContract(event, kind);
  contract.save();

  const entry = new AdminEvent(eventId(event));
  entry.contract = contract.id;
  entry.event = name;
  entry.blockNumber = event.block.number;
  entry.timestamp = event.block.timestamp;
  entry.txHash = event.transaction.hash;
  return entry;
}

/** Grant (active = true) or revoke a role on the emitting contract (saved) */
export function setRole(event: ethereum.Event, kind: string, role: string, account: Address, active: boolean): RoleMember {
  const contract = getOrCreateContract(event, kind);
  contract.save();

  const id = contract.id + "-" + role + "-" + account.toHexString();
  let member = RoleMember.load(id);
  if (member == null) {
    member = new RoleMember(id);
    member.contract = contract.id;
    member.role = role;
    member.account = account;
  }
  member.active = active;
  member.updatedAt = event.block.timestamp;
  member.updatedTx = event.transaction.hash;
  member.save();
  return member;
}

// =============================================================================
// Ownable2Step / Pausable (shared by every data source)
// =============================================================================

export function recordOwnershipTransferStarted(
  event: ethereum.Event,
  kind: string,
  previousOwner: Address,
  newOwner: Address
): void {
  const contract = getOrCreateContract(event, kind);
  contract.pendingOwner = newOwner;
  contract.save();

  const entry = newAdminEvent(event, kind, "OwnershipTransferStarted");
  entry.account = newOwner;
  entry.previousAccount = previousOwner;
  entry.save();
}

export function recordOwnershipTransferred(
  event: ethereum.Event,
  kind: string,
  previousOwner: Address,
  newOwner: Address
): void {
  const contract = getOrCreateContract(event, kind);
  contract.owner = newOwner;
  contract.pendingOwner = null;
  contract.save();

  const entry = newAdminEvent(event, kind, "OwnershipTransferred");
  entry.account = newOwner;
  entry.previousAccount = previousOwner;
  entry.save();
}

export function recordPause(event: ethereum.Event, kind: string, account: Address, paused: boolean): void {
  const contract = getOrCreateContract(event, kind);
  contract.paused = paused;
  contract.save();

  const entry = newAdminEvent(event, kind, paused ? "Paused" : "Unpaused");
  entry.account = account;
  entry.flag = paused;
  entry.save();
}
