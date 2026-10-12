import { afterEach, assert, clearStore, describe, test } from "matchstick-as/assembly/index";
import { Address, BigInt, Bytes } from "@graphprotocol/graph-ts";
import {
  DisputeProcessed,
  OracleRegistered,
  ProposalRequested,
  ProposalReset,
  ProposalRoundFilled,
  ProposalRoundReopened,
  ProposalSubmittedToILRM
} from "../generated/Oracle/Oracle";
import {
  handleDisputeProcessed,
  handleOracleRegistered,
  handleProposalRequested,
  handleProposalReset,
  handleProposalRoundFilled,
  handleProposalRoundReopened,
  handleProposalSubmittedToILRM
} from "../src/oracle";
import { eventId, keccakUtf8 } from "../src/common";
import {
  OPERATOR,
  ORACLE_ADDRESS,
  RELAYER,
  beginTx,
  mockEvent,
  pAddr,
  pB32,
  pInt,
  pStr,
  setCall,
  word
} from "./helpers";

function requested(id: i32, evidence: Bytes, timestamp: i32): ProposalRequested {
  return changetype<ProposalRequested>(
    mockEvent(ORACLE_ADDRESS, [pInt("disputeId", id), pB32("evidenceHash", evidence), pInt("timestamp", timestamp)])
  );
}

/** submitProposal: ProposalSubmittedToILRM, ProposalRoundFilled, DisputeProcessed */
function submit(id: i32, round: i32, proposalHash: Bytes, nonce: i32, evidence: Bytes): void {
  handleProposalSubmittedToILRM(
    changetype<ProposalSubmittedToILRM>(
      mockEvent(ORACLE_ADDRESS, [pInt("disputeId", id), pB32("proposalHash", proposalHash), pAddr("oracle", OPERATOR)])
    )
  );
  handleProposalRoundFilled(
    changetype<ProposalRoundFilled>(
      mockEvent(ORACLE_ADDRESS, [
        pInt("disputeId", id),
        pInt("round", round),
        pB32("proposalHash", proposalHash),
        pInt("nonce", nonce)
      ])
    )
  );
  handleDisputeProcessed(
    changetype<DisputeProcessed>(
      mockEvent(ORACLE_ADDRESS, [pInt("disputeId", id), pB32("evidenceHash", evidence), pB32("proposalHash", proposalHash)])
    )
  );
}

describe("Oracle rounds", () => {
  afterEach(() => {
    clearStore();
  });

  test("request, fill, owner reset and refill of one round", () => {
    const hashA = keccakUtf8("A");
    const hashB = keccakUtf8("B");

    beginTx(1, 1000);
    handleProposalRequested(requested(5, word(0xe5), 1000));
    assert.fieldEquals("OracleDispute", "5", "pending", "true");
    assert.fieldEquals("OracleDispute", "5", "requestCount", "1");

    // Relayed through another account: the operator comes from ProposalSubmittedToILRM
    beginTx(2, 1600);
    setCall(RELAYER, Address.zero(), Bytes.empty(), BigInt.zero());
    submit(5, 0, hashA, 0, word(0xe5));
    assert.fieldEquals("OracleSubmission", "5-0-0", "operator", OPERATOR.toHexString());
    assert.fieldEquals("OracleSubmission", "5-0-0", "nonce", "0");
    assert.fieldEquals("OracleSubmission", "5-0-0", "responseTime", "600");
    assert.fieldEquals("OracleSubmission", "5-0-0", "evidenceHash", word(0xe5).toHexString());
    assert.fieldEquals("OracleSubmission", "5-0-0", "voided", "false");
    assert.fieldEquals("OracleRound", "5-0", "filled", "true");
    assert.fieldEquals("OracleRound", "5-0", "proposalHash", hashA.toHexString());
    assert.fieldEquals("OracleDispute", "5", "pending", "false");
    assert.fieldEquals("OracleDispute", "5", "nextNonce", "1");
    assert.fieldEquals("OracleDispute", "5", "currentRound", "0");
    assert.fieldEquals("OracleMetric", "0", "avgResponseSeconds", "600");

    // resetProposal: ProposalReset, ProposalRoundReopened
    beginTx(3, 2000);
    const reset = changetype<ProposalReset>(
      mockEvent(ORACLE_ADDRESS, [pInt("disputeId", 5), pB32("oldProposalHash", hashA), pStr("reason", "bad terms")])
    );
    handleProposalReset(reset);
    handleProposalRoundReopened(
      changetype<ProposalRoundReopened>(
        mockEvent(ORACLE_ADDRESS, [pInt("disputeId", 5), pInt("round", 0), pB32("voidedProposalHash", hashA)])
      )
    );
    assert.fieldEquals("OracleReset", eventId(reset), "round", "0");
    assert.fieldEquals("OracleReset", eventId(reset), "reason", "bad terms");
    assert.fieldEquals("OracleSubmission", "5-0-0", "voided", "true");
    assert.fieldEquals("OracleRound", "5-0", "filled", "false");
    assert.fieldEquals("OracleRound", "5-0", "proposalHash", "null");
    assert.fieldEquals("OracleRound", "5-0", "reopenCount", "1");
    assert.fieldEquals("OracleDispute", "5", "pending", "true");
    assert.fieldEquals("OracleDispute", "5", "nextNonce", "2");
    assert.fieldEquals("OracleDispute", "5", "resetCount", "1");

    // The replacement consumes the bumped nonce
    beginTx(4, 2300);
    submit(5, 0, hashB, 1, word(0xe5));
    assert.fieldEquals("OracleSubmission", "5-0-1", "proposalHash", hashB.toHexString());
    assert.fieldEquals("OracleSubmission", "5-0-1", "responseTime", "300");
    assert.fieldEquals("OracleRound", "5-0", "fillCount", "2");
    assert.fieldEquals("OracleRound", "5-0", "currentSubmission", "5-0-1");
    assert.fieldEquals("OracleDispute", "5", "nextNonce", "2");
    assert.fieldEquals("OracleDispute", "5", "submissionCount", "2");
    assert.fieldEquals("OracleMetric", "0", "proposalsSubmitted", "2");
    assert.fieldEquals("OracleMetric", "0", "proposalsReset", "1");
    assert.fieldEquals("OracleMetric", "0", "avgResponseSeconds", "450");
  });

  test("cancelPendingRequest emits a zero request", () => {
    beginTx(10, 1000);
    handleProposalRequested(requested(7, word(0xe7), 1000));
    beginTx(11, 1500);
    handleProposalRequested(requested(7, word(0), 0));
    assert.fieldEquals("OracleDispute", "7", "pending", "false");
    assert.fieldEquals("OracleDispute", "7", "requestCount", "1");
    assert.fieldEquals("OracleDispute", "7", "cancelCount", "1");
    assert.fieldEquals("OracleMetric", "0", "requestsCancelled", "1");
  });

  test("operator registration", () => {
    beginTx(20, 1000);
    handleOracleRegistered(
      changetype<OracleRegistered>(
        mockEvent(ORACLE_ADDRESS, [pAddr("oracle", OPERATOR), pB32("publicKeyHash", word(0x99))])
      )
    );
    const id = ORACLE_ADDRESS.toHexString() + "-ORACLE_OPERATOR-" + OPERATOR.toHexString();
    assert.fieldEquals("RoleMember", id, "active", "true");
    assert.fieldEquals("RoleMember", id, "publicKeyHash", word(0x99).toHexString());
    assert.fieldEquals("ProtocolContract", ORACLE_ADDRESS.toHexString(), "kind", "ORACLE");
    assert.entityCount("AdminEvent", 1);
  });
});
