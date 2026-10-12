import { afterEach, assert, clearStore, createMockedFunction, describe, test } from "matchstick-as/assembly/index";
import { Address, BigInt, Bytes, ethereum } from "@graphprotocol/graph-ts";
import {
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
  SubsidyTreasuryUpdated
} from "../generated/ILRM/ILRM";
import {
  handleAcceptanceSignaled,
  handleCounterProposed,
  handleDefaultLicenseApplied,
  handleDisputeInitiated,
  handleDisputeResolved,
  handleHarassmentScoreUpdated,
  handleInitiatorIncentiveCapsUpdated,
  handleInitiatorIncentivePaid,
  handleOracleRequestFailed,
  handleOwnershipTransferStarted,
  handleOwnershipTransferred,
  handlePaused,
  handleProposalSubmitted,
  handleProposalSuperseded,
  handleProposalVoided,
  handleStakeDeposited,
  handleStakeSubsidized,
  handleStakesBurned,
  handleSubsidyReturned,
  handleSubsidyTreasuryUpdated
} from "../src/ilrm";
import { Counter, Proposal, VoluntaryRequest } from "../generated/schema";
import { eventId, keccakUtf8, selector } from "../src/common";
import {
  ALICE,
  BOB,
  CAROL,
  ILRM_ADDRESS,
  TREASURY_ADDRESS,
  beginTx,
  bi,
  mockEvent,
  pAddr,
  pB32,
  pInt,
  pStr,
  pUint,
  setCall,
  wei,
  word
} from "./helpers";

const DISPUTES_SIG =
  "disputes(uint256):((address,address,uint256,uint256,uint256,bytes32,string,bool,bool,bool,uint8,(bytes32,uint256,uint256,bool),uint256))";
const MAX_UINT = "115792089237316195423570985008687907853269984665640564039457584007913129639935";

// -----------------------------------------------------------------------------
// Event builders
// -----------------------------------------------------------------------------

function mockDisputeRead(id: i32, initiator: Address, counterparty: Address, stake: BigInt): void {
  const fallback = new ethereum.Tuple();
  fallback.push(ethereum.Value.fromFixedBytes(word(0xf1)));
  fallback.push(ethereum.Value.fromUnsignedBigInt(bi(86400)));
  fallback.push(ethereum.Value.fromUnsignedBigInt(bi(500)));
  fallback.push(ethereum.Value.fromBoolean(true));

  const d = new ethereum.Tuple();
  d.push(ethereum.Value.fromAddress(initiator));
  d.push(ethereum.Value.fromAddress(counterparty));
  d.push(ethereum.Value.fromUnsignedBigInt(stake));
  d.push(ethereum.Value.fromUnsignedBigInt(BigInt.zero()));
  d.push(ethereum.Value.fromUnsignedBigInt(bi(1000)));
  d.push(ethereum.Value.fromFixedBytes(word(0xe0)));
  d.push(ethereum.Value.fromString(""));
  d.push(ethereum.Value.fromBoolean(false));
  d.push(ethereum.Value.fromBoolean(false));
  d.push(ethereum.Value.fromBoolean(false));
  d.push(ethereum.Value.fromUnsignedBigInt(BigInt.zero()));
  d.push(ethereum.Value.fromTuple(fallback));
  d.push(ethereum.Value.fromUnsignedBigInt(BigInt.zero()));

  createMockedFunction(ILRM_ADDRESS, "disputes", DISPUTES_SIG)
    .withArgs([ethereum.Value.fromUnsignedBigInt(bi(id))])
    .returns([ethereum.Value.fromTuple(d)]);
}

function disputeInitiated(id: BigInt, initiator: Address, counterparty: Address): DisputeInitiated {
  return changetype<DisputeInitiated>(
    mockEvent(ILRM_ADDRESS, [
      pUint("disputeId", id),
      pAddr("initiator", initiator),
      pAddr("counterparty", counterparty),
      pB32("evidenceHash", word(0xe0))
    ])
  );
}

function stakeSubsidized(id: i32, counterparty: Address, amount: BigInt): StakeSubsidized {
  return changetype<StakeSubsidized>(
    mockEvent(ILRM_ADDRESS, [
      pInt("disputeId", id),
      pAddr("counterparty", counterparty),
      pAddr("funder", TREASURY_ADDRESS),
      pUint("amount", amount)
    ])
  );
}

function stakeDeposited(id: i32, depositor: Address, amount: BigInt): StakeDeposited {
  return changetype<StakeDeposited>(
    mockEvent(ILRM_ADDRESS, [pInt("disputeId", id), pAddr("depositor", depositor), pUint("amount", amount)])
  );
}

function proposalSubmitted(id: i32, text: string): ProposalSubmitted {
  return changetype<ProposalSubmitted>(mockEvent(ILRM_ADDRESS, [pInt("disputeId", id), pStr("proposal", text)]));
}

function proposalSuperseded(id: i32, round: i32, previous: string, next: string): ProposalSuperseded {
  return changetype<ProposalSuperseded>(
    mockEvent(ILRM_ADDRESS, [
      pInt("disputeId", id),
      pInt("round", round),
      pB32("previousProposalHash", keccakUtf8(previous)),
      pB32("newProposalHash", keccakUtf8(next))
    ])
  );
}

function accepted(id: i32, party: Address): AcceptanceSignaled {
  return changetype<AcceptanceSignaled>(mockEvent(ILRM_ADDRESS, [pInt("disputeId", id), pAddr("party", party)]));
}

function countered(id: i32, party: Address, n: i32): CounterProposed {
  return changetype<CounterProposed>(
    mockEvent(ILRM_ADDRESS, [pInt("disputeId", id), pAddr("party", party), pInt("counterNumber", n)])
  );
}

function subsidyReturned(id: i32, amount: BigInt): SubsidyReturned {
  return changetype<SubsidyReturned>(
    mockEvent(ILRM_ADDRESS, [pInt("disputeId", id), pAddr("funder", TREASURY_ADDRESS), pUint("amount", amount)])
  );
}

function stakesBurned(id: i32, amount: BigInt): StakesBurned {
  return changetype<StakesBurned>(mockEvent(ILRM_ADDRESS, [pInt("disputeId", id), pUint("burnAmount", amount)]));
}

function resolved(id: i32, outcome: i32): DisputeResolved {
  return changetype<DisputeResolved>(mockEvent(ILRM_ADDRESS, [pInt("disputeId", id), pInt("outcome", outcome)]));
}

function proposalVoided(id: i32, round: i32, text: string): ProposalVoided {
  return changetype<ProposalVoided>(
    mockEvent(ILRM_ADDRESS, [pInt("disputeId", id), pInt("round", round), pB32("proposalHash", keccakUtf8(text))])
  );
}

function oracleRequestFailed(id: i32, round: i32): OracleRequestFailed {
  return changetype<OracleRequestFailed>(mockEvent(ILRM_ADDRESS, [pInt("disputeId", id), pInt("round", round)]));
}

function incentivePaid(id: i32, initiator: Address, amount: BigInt, uncapped: BigInt): InitiatorIncentivePaid {
  return changetype<InitiatorIncentivePaid>(
    mockEvent(ILRM_ADDRESS, [
      pInt("disputeId", id),
      pAddr("initiator", initiator),
      pUint("amount", amount),
      pUint("uncappedAmount", uncapped)
    ])
  );
}

/** enforceTimeout without a counterparty stake: InitiatorIncentivePaid, DefaultLicenseApplied, DisputeResolved */
function resolveNonParticipation(id: i32, initiator: Address, amount: BigInt, uncapped: BigInt): void {
  handleInitiatorIncentivePaid(incentivePaid(id, initiator, amount, uncapped));
  handleDefaultLicenseApplied(changetype<DefaultLicenseApplied>(mockEvent(ILRM_ADDRESS, [pInt("disputeId", id)])));
  handleDisputeResolved(resolved(id, 3));
}

function counterProposeCalldata(id: i32, evidence: Bytes): Bytes {
  const args = new ethereum.Tuple();
  args.push(ethereum.Value.fromUnsignedBigInt(bi(id)));
  args.push(ethereum.Value.fromFixedBytes(evidence));
  const encoded = ethereum.encode(ethereum.Value.fromTuple(args))!;
  return selector("counterPropose(uint256,bytes32)").concat(encoded);
}

// -----------------------------------------------------------------------------

describe("ILRM dispute lifecycle", () => {
  afterEach(() => {
    clearStore();
  });

  test("subsidised stake, superseded proposal and mutual acceptance", () => {
    mockDisputeRead(0, ALICE, BOB, bi(100));

    beginTx(1, 1000);
    handleDisputeInitiated(disputeInitiated(bi(0), ALICE, BOB));
    assert.fieldEquals("Dispute", "0", "initiatorStake", "100");
    assert.fieldEquals("Dispute", "0", "state", "INITIATED");
    assert.fieldEquals("Dispute", "0", "fallbackTermsHash", word(0xf1).toHexString());
    assert.fieldEquals("Dispute", "0", "fallbackDuration", "86400");
    assert.fieldEquals("Party", ALICE.toHexString(), "totalStaked", "100");
    assert.fieldEquals("ProtocolMetric", "protocol", "uniqueParticipants", "2");
    assert.fieldEquals("ProtocolMetric", "protocol", "activeDisputes", "1");

    // depositStakeWithSubsidy: StakeSubsidized, then StakeDeposited for the full matching stake
    beginTx(2, 2000);
    handleStakeSubsidized(stakeSubsidized(0, BOB, bi(40)));
    handleStakeDeposited(stakeDeposited(0, BOB, bi(100)));
    assert.fieldEquals("Dispute", "0", "state", "ACTIVE");
    assert.fieldEquals("Dispute", "0", "counterpartyStake", "100");
    assert.fieldEquals("Dispute", "0", "stakeSubsidy", "0");
    assert.fieldEquals("StakeSubsidy", "0", "amount", "40");
    assert.fieldEquals("StakeSubsidy", "0", "funder", TREASURY_ADDRESS.toHexString());
    assert.fieldEquals("Party", BOB.toHexString(), "totalStaked", "60");
    assert.fieldEquals("Party", BOB.toHexString(), "totalSubsidiesReceived", "40");
    assert.fieldEquals("ProtocolMetric", "protocol", "totalValueStaked", "200");
    assert.fieldEquals("ProtocolMetric", "protocol", "totalSubsidiesDistributed", "40");

    beginTx(3, 3000);
    handleProposalSubmitted(proposalSubmitted(0, "proposal one"));
    assert.fieldEquals("Proposal", "0-0", "status", "LIVE");
    assert.fieldEquals("Proposal", "0-0", "round", "0");
    assert.fieldEquals("Proposal", "0-0", "proposalHash", keccakUtf8("proposal one").toHexString());
    assert.fieldEquals("Dispute", "0", "currentProposal", "0-0");

    beginTx(4, 4000);
    handleAcceptanceSignaled(accepted(0, ALICE));
    assert.fieldEquals("Dispute", "0", "initiatorAccepted", "true");
    assert.fieldEquals("Proposal", "0-0", "initiatorAccepted", "true");

    // Oracle owner recovery replaces the live proposal in the same round
    beginTx(5, 5000);
    handleProposalSuperseded(proposalSuperseded(0, 0, "proposal one", "proposal two"));
    handleProposalSubmitted(proposalSubmitted(0, "proposal two"));
    assert.fieldEquals("Proposal", "0-0", "status", "SUPERSEDED");
    assert.fieldEquals("Proposal", "0-0", "supersededBy", "0-1");
    assert.fieldEquals("Proposal", "0-1", "status", "LIVE");
    assert.fieldEquals("Dispute", "0", "initiatorAccepted", "false");
    assert.fieldEquals("Dispute", "0", "proposalCount", "2");

    beginTx(6, 6000);
    handleAcceptanceSignaled(accepted(0, ALICE));
    handleAcceptanceSignaled(accepted(0, BOB));
    handleSubsidyReturned(subsidyReturned(0, bi(40)));
    handleDisputeResolved(resolved(0, 1));
    assert.fieldEquals("Dispute", "0", "state", "RESOLVED");
    assert.fieldEquals("Dispute", "0", "outcome", "ACCEPTED_PROPOSAL");
    assert.fieldEquals("Dispute", "0", "resolvedAt", "6000");
    assert.fieldEquals("Proposal", "0-1", "status", "ACCEPTED");
    assert.fieldEquals("StakeSubsidy", "0", "amountReturned", "40");
    assert.entityCount("SubsidyReturn", 1);
    assert.fieldEquals("Party", ALICE.toHexString(), "disputesResolved", "1");
    assert.fieldEquals("Party", BOB.toHexString(), "disputesResolved", "1");
    assert.fieldEquals("ProtocolMetric", "protocol", "activeDisputes", "0");
    assert.fieldEquals("ProtocolMetric", "protocol", "resolvedDisputes", "1");
    assert.fieldEquals("ProtocolMetric", "protocol", "totalSubsidiesReturned", "40");
    assert.fieldEquals("ProtocolMetric", "protocol", "avgResolutionBlocks", "5");
  });

  test("counter-proposals void the live proposal and timeout burns are attributed pro rata", () => {
    mockDisputeRead(1, ALICE, BOB, bi(1000));

    beginTx(10, 1000);
    handleDisputeInitiated(disputeInitiated(bi(1), ALICE, BOB));
    beginTx(11, 2000);
    handleStakeSubsidized(stakeSubsidized(1, BOB, bi(500)));
    handleStakeDeposited(stakeDeposited(1, BOB, bi(1000)));
    beginTx(12, 3000);
    handleProposalSubmitted(proposalSubmitted(1, "first"));

    // Direct call: the new evidence hash is recovered from calldata
    beginTx(13, 4000);
    setCall(BOB, ILRM_ADDRESS, counterProposeCalldata(1, word(0xee)), wei("10000000000000000"));
    handleCounterProposed(countered(1, BOB, 1));
    assert.fieldEquals("Counter", "1-1", "evidenceHash", word(0xee).toHexString());
    assert.fieldEquals("Counter", "1-1", "feeBurned", "10000000000000000");
    assert.fieldEquals("Dispute", "1", "evidenceHash", word(0xee).toHexString());
    assert.fieldEquals("Dispute", "1", "counterCount", "1");
    assert.fieldEquals("Proposal", "1-0", "status", "VOIDED_BY_COUNTER");
    assert.fieldEquals("Dispute", "1", "currentProposal", "null");

    // Indirect call (e.g. through a multisig): evidence hash unknown, fee still deterministic
    beginTx(14, 5000);
    handleCounterProposed(countered(1, ALICE, 2));
    assert.assertTrue(Counter.load("1-2")!.evidenceHash === null);
    assert.fieldEquals("Counter", "1-2", "feeBurned", "20000000000000000");
    assert.fieldEquals("Dispute", "1", "counterFeesBurned", "30000000000000000");
    assert.fieldEquals("Dispute", "1", "evidenceHash", word(0xee).toHexString());

    beginTx(15, 6000);
    handleProposalSubmitted(proposalSubmitted(1, "second"));
    assert.fieldEquals("Proposal", "1-1", "round", "2");

    // enforceTimeout: funder repaid net of its burn share, then StakesBurned, DisputeResolved
    beginTx(16, 7000);
    handleSubsidyReturned(subsidyReturned(1, bi(250)));
    handleStakesBurned(stakesBurned(1, bi(1000)));
    handleDisputeResolved(resolved(1, 2));
    assert.fieldEquals("Dispute", "1", "burnAmount", "1000");
    assert.fieldEquals("Dispute", "1", "outcome", "TIMEOUT_WITH_BURN");
    assert.fieldEquals("Proposal", "1-1", "status", "EXPIRED");
    assert.fieldEquals("Party", ALICE.toHexString(), "totalBurned", "500");
    // Counterparty bears its own half of the burn pro rata to its own funds (500 of 1000)
    assert.fieldEquals("Party", BOB.toHexString(), "totalBurned", "250");
    assert.fieldEquals("Party", BOB.toHexString(), "disputesTimedOut", "1");
    assert.fieldEquals("ProtocolMetric", "protocol", "timedOutDisputes", "1");
    assert.fieldEquals("ProtocolMetric", "protocol", "totalValueBurned", "1000");
    assert.entityCount("Burn", 1);
  });

  test("non-participation resolves with the default license", () => {
    createMockedFunction(ILRM_ADDRESS, "disputes", DISPUTES_SIG)
      .withArgs([ethereum.Value.fromUnsignedBigInt(bi(2))])
      .reverts();

    beginTx(20, 1000);
    handleDisputeInitiated(disputeInitiated(bi(2), CAROL, BOB));
    assert.fieldEquals("Dispute", "2", "initiatorStake", "0");

    beginTx(21, 300000);
    handleDefaultLicenseApplied(
      changetype<DefaultLicenseApplied>(mockEvent(ILRM_ADDRESS, [pInt("disputeId", 2)]))
    );
    handleDisputeResolved(resolved(2, 3));
    assert.fieldEquals("Dispute", "2", "outcome", "DEFAULT_LICENSE_APPLIED");
    assert.fieldEquals("Dispute", "2", "state", "RESOLVED");
    assert.fieldEquals("Party", CAROL.toHexString(), "disputesDefaulted", "1");
    assert.fieldEquals("ProtocolMetric", "protocol", "defaultedDisputes", "1");
  });

  test("an Oracle reset voids the live proposal and every acceptance of it", () => {
    mockDisputeRead(3, ALICE, BOB, bi(100));

    beginTx(60, 1000);
    handleDisputeInitiated(disputeInitiated(bi(3), ALICE, BOB));
    handleStakeDeposited(stakeDeposited(3, BOB, bi(100)));
    beginTx(61, 2000);
    handleProposalSubmitted(proposalSubmitted(3, "bad terms"));
    beginTx(62, 3000);
    handleAcceptanceSignaled(accepted(3, ALICE));
    assert.fieldEquals("Dispute", "3", "initiatorAccepted", "true");

    // Oracle.resetProposal -> ILRM.voidLLMProposal: ProposalVoided only, no ProposalSuperseded
    beginTx(63, 4000);
    handleProposalVoided(proposalVoided(3, 0, "bad terms"));
    assert.fieldEquals("Proposal", "3-0", "status", "VOIDED");
    assert.fieldEquals("Dispute", "3", "currentProposal", "null");
    assert.fieldEquals("Dispute", "3", "initiatorAccepted", "false");
    assert.fieldEquals("Dispute", "3", "counterpartyAccepted", "false");
    assert.fieldEquals("Dispute", "3", "counterCount", "0");

    // The replacement of the same round is a plain ProposalSubmitted and does not touch the voided one
    beginTx(64, 5000);
    handleProposalSubmitted(proposalSubmitted(3, "good terms"));
    assert.fieldEquals("Proposal", "3-1", "status", "LIVE");
    assert.fieldEquals("Proposal", "3-1", "round", "0");
    assert.fieldEquals("Proposal", "3-0", "status", "VOIDED");
    assert.assertTrue(Proposal.load("3-0")!.supersededBy === null);
    assert.fieldEquals("Dispute", "3", "currentProposal", "3-1");

    beginTx(65, 6000);
    handleAcceptanceSignaled(accepted(3, ALICE));
    handleAcceptanceSignaled(accepted(3, BOB));
    handleDisputeResolved(resolved(3, 1));
    assert.fieldEquals("Proposal", "3-1", "status", "ACCEPTED");
    assert.fieldEquals("Proposal", "3-0", "status", "VOIDED");
  });

  test("failed advisory Oracle requests are recorded per dispute and round", () => {
    mockDisputeRead(4, ALICE, BOB, bi(100));

    beginTx(70, 1000);
    handleDisputeInitiated(disputeInitiated(bi(4), ALICE, BOB));
    beginTx(71, 2000);
    handleStakeDeposited(stakeDeposited(4, BOB, bi(100)));
    const first = oracleRequestFailed(4, 0);
    handleOracleRequestFailed(first);
    beginTx(72, 3000);
    handleCounterProposed(countered(4, ALICE, 1));
    const second = oracleRequestFailed(4, 1);
    handleOracleRequestFailed(second);

    assert.fieldEquals("OracleRequestFailure", eventId(first), "dispute", "4");
    assert.fieldEquals("OracleRequestFailure", eventId(first), "round", "0");
    assert.fieldEquals("OracleRequestFailure", eventId(second), "round", "1");
    assert.fieldEquals("OracleRequestFailure", eventId(second), "timestamp", "3000");
    assert.fieldEquals("Dispute", "4", "oracleRequestFailureCount", "2");
    assert.fieldEquals("Dispute", "4", "state", "ACTIVE");
    assert.fieldEquals("ProtocolMetric", "protocol", "totalOracleRequestFailures", "2");
  });

  test("non-participation records the capped initiator incentive against the uncapped 10%", () => {
    mockDisputeRead(5, ALICE, BOB, wei("50000000000000000000"));
    mockDisputeRead(6, CAROL, BOB, wei("5000000000000000000"));

    beginTx(80, 1000);
    handleDisputeInitiated(disputeInitiated(bi(5), ALICE, BOB));
    handleDisputeInitiated(disputeInitiated(bi(6), CAROL, BOB));

    // 10% of 50 tokens is 5, capped at maxIncentivePerDispute (1 token)
    beginTx(81, 300000);
    resolveNonParticipation(5, ALICE, wei("1000000000000000000"), wei("5000000000000000000"));
    assert.fieldEquals("Dispute", "5", "initiatorIncentive", "1000000000000000000");
    assert.fieldEquals("Dispute", "5", "initiatorIncentiveUncapped", "5000000000000000000");
    assert.fieldEquals("Dispute", "5", "outcome", "DEFAULT_LICENSE_APPLIED");

    // Below every cap: paid in full
    beginTx(82, 300100);
    resolveNonParticipation(6, CAROL, wei("500000000000000000"), wei("500000000000000000"));
    assert.fieldEquals("Dispute", "6", "initiatorIncentive", "500000000000000000");
    assert.fieldEquals("Dispute", "6", "initiatorIncentiveUncapped", "500000000000000000");

    assert.fieldEquals("ProtocolMetric", "protocol", "totalInitiatorIncentivesPaid", "1500000000000000000");
    assert.fieldEquals("ProtocolMetric", "protocol", "totalInitiatorIncentivesUncapped", "5500000000000000000");
    assert.fieldEquals("ProtocolMetric", "protocol", "cappedInitiatorIncentives", "1");
    assert.fieldEquals("ProtocolMetric", "protocol", "defaultedDisputes", "2");
    assert.fieldEquals("DailyMetric", "259200", "initiatorIncentivesPaid", "1500000000000000000");
    assert.fieldEquals("DailyMetric", "0", "initiatorIncentivesPaid", "0");
  });

  test("the mean resolution time is exact, not a drifting running mean", () => {
    mockDisputeRead(7, ALICE, BOB, bi(10));
    mockDisputeRead(8, ALICE, CAROL, bi(10));
    mockDisputeRead(9, BOB, CAROL, bi(10));

    // Initiated in blocks 100, 200, 300; resolved 1, 2 and 3 blocks later: mean 2 (a running mean
    // of rounded values gives 1, then 1, then 1)
    beginTx(100, 1000);
    handleDisputeInitiated(disputeInitiated(bi(7), ALICE, BOB));
    beginTx(101, 1012);
    handleDisputeResolved(resolved(7, 2));
    assert.fieldEquals("ProtocolMetric", "protocol", "avgResolutionBlocks", "1");

    beginTx(200, 2000);
    handleDisputeInitiated(disputeInitiated(bi(8), ALICE, CAROL));
    beginTx(202, 2024);
    handleDisputeResolved(resolved(8, 2));
    assert.fieldEquals("ProtocolMetric", "protocol", "totalResolutionBlocks", "3");
    assert.fieldEquals("ProtocolMetric", "protocol", "avgResolutionBlocks", "1");

    beginTx(300, 3000);
    handleDisputeInitiated(disputeInitiated(bi(9), BOB, CAROL));
    beginTx(303, 3036);
    handleDisputeResolved(resolved(9, 2));
    assert.fieldEquals("ProtocolMetric", "protocol", "resolvedDisputes", "3");
    assert.fieldEquals("ProtocolMetric", "protocol", "totalResolutionBlocks", "6");
    assert.fieldEquals("ProtocolMetric", "protocol", "avgResolutionBlocks", "2");
  });

  test("voluntary requests do not create disputes", () => {
    beginTx(30, 1000);
    setCall(ALICE, ILRM_ADDRESS, selector("initiateVoluntaryRequest(address,bytes32)"), wei("10000000000000000"));
    const direct = disputeInitiated(BigInt.fromString(MAX_UINT), ALICE, BOB);
    handleDisputeInitiated(direct);
    assert.entityCount("Dispute", 0);
    assert.entityCount("VoluntaryRequest", 1);
    assert.fieldEquals("VoluntaryRequest", eventId(direct), "feeBurned", "10000000000000000");

    // Through another contract the burned msg.value is unknown
    beginTx(31, 2000);
    const indirect = disputeInitiated(BigInt.fromString(MAX_UINT), ALICE, CAROL);
    handleDisputeInitiated(indirect);
    assert.assertTrue(VoluntaryRequest.load(eventId(indirect))!.feeBurned === null);
    assert.fieldEquals("Party", ALICE.toHexString(), "voluntaryRequestsSent", "2");
    assert.fieldEquals("Party", ALICE.toHexString(), "totalDisputes", "0");
    assert.fieldEquals("ProtocolMetric", "protocol", "totalVoluntaryRequests", "2");
    assert.fieldEquals("ProtocolMetric", "protocol", "totalDisputes", "0");
  });
});

describe("ILRM configuration and ownership", () => {
  afterEach(() => {
    clearStore();
  });

  test("subsidy treasury, ownership and pause state", () => {
    const ilrm = ILRM_ADDRESS.toHexString();

    beginTx(40, 1000);
    handleSubsidyTreasuryUpdated(
      changetype<SubsidyTreasuryUpdated>(
        mockEvent(ILRM_ADDRESS, [pAddr("previousTreasury", Address.zero()), pAddr("newTreasury", TREASURY_ADDRESS)])
      )
    );
    assert.fieldEquals("ProtocolContract", ilrm, "kind", "ILRM");
    assert.fieldEquals("ProtocolContract", ilrm, "subsidyTreasury", TREASURY_ADDRESS.toHexString());

    beginTx(41, 2000);
    handleSubsidyTreasuryUpdated(
      changetype<SubsidyTreasuryUpdated>(
        mockEvent(ILRM_ADDRESS, [pAddr("previousTreasury", TREASURY_ADDRESS), pAddr("newTreasury", Address.zero())])
      )
    );
    assert.fieldEquals("ProtocolContract", ilrm, "subsidyTreasury", "null");

    handleOwnershipTransferStarted(
      changetype<OwnershipTransferStarted>(
        mockEvent(ILRM_ADDRESS, [pAddr("previousOwner", ALICE), pAddr("newOwner", BOB)])
      )
    );
    assert.fieldEquals("ProtocolContract", ilrm, "pendingOwner", BOB.toHexString());
    handleOwnershipTransferred(
      changetype<OwnershipTransferred>(mockEvent(ILRM_ADDRESS, [pAddr("previousOwner", ALICE), pAddr("newOwner", BOB)]))
    );
    assert.fieldEquals("ProtocolContract", ilrm, "owner", BOB.toHexString());
    assert.fieldEquals("ProtocolContract", ilrm, "pendingOwner", "null");

    handlePaused(changetype<Paused>(mockEvent(ILRM_ADDRESS, [pAddr("account", BOB)])));
    assert.fieldEquals("ProtocolContract", ilrm, "paused", "true");
    assert.entityCount("AdminEvent", 5);
  });

  test("initiator-incentive caps, from the constructor and from the owner", () => {
    const ilrm = ILRM_ADDRESS.toHexString();

    // Constructor defaults (1 token per dispute, 10 per 30-day window)
    beginTx(45, 1000);
    handleInitiatorIncentiveCapsUpdated(
      changetype<InitiatorIncentiveCapsUpdated>(
        mockEvent(ILRM_ADDRESS, [
          pUint("maxPerDispute", wei("1000000000000000000")),
          pUint("maxPerWindow", wei("10000000000000000000")),
          pInt("window", 2592000)
        ])
      )
    );
    assert.fieldEquals("ProtocolContract", ilrm, "kind", "ILRM");
    assert.fieldEquals("ProtocolContract", ilrm, "maxIncentivePerDispute", "1000000000000000000");
    assert.fieldEquals("ProtocolContract", ilrm, "maxIncentivePerWindow", "10000000000000000000");
    assert.fieldEquals("ProtocolContract", ilrm, "incentiveWindow", "2592000");

    // Kill switch: zero caps are allowed
    beginTx(46, 2000);
    const update = changetype<InitiatorIncentiveCapsUpdated>(
      mockEvent(ILRM_ADDRESS, [pInt("maxPerDispute", 0), pInt("maxPerWindow", 0), pInt("window", 86400)])
    );
    handleInitiatorIncentiveCapsUpdated(update);
    assert.fieldEquals("ProtocolContract", ilrm, "maxIncentivePerDispute", "0");
    assert.fieldEquals("ProtocolContract", ilrm, "maxIncentivePerWindow", "0");
    assert.fieldEquals("ProtocolContract", ilrm, "incentiveWindow", "86400");
    assert.fieldEquals("AdminEvent", eventId(update), "event", "InitiatorIncentiveCapsUpdated");
    assert.fieldEquals("AdminEvent", eventId(update), "details", "maxPerDispute=0 maxPerWindow=0 window=86400");
    assert.entityCount("AdminEvent", 2);
  });

  test("ILRM harassment score is kept separately", () => {
    beginTx(50, 1000);
    handleHarassmentScoreUpdated(
      changetype<HarassmentScoreUpdated>(
        mockEvent(ILRM_ADDRESS, [pAddr("participant", CAROL), pUint("oldScore", bi(0)), pUint("newScore", bi(7))])
      )
    );
    assert.fieldEquals("Party", CAROL.toHexString(), "harassmentScore", "7");
    assert.fieldEquals("Party", CAROL.toHexString(), "treasuryHarassmentScore", "0");
  });
});
