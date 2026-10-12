import { afterEach, assert, clearStore, describe, test } from "matchstick-as/assembly/index";
import { Address } from "@graphprotocol/graph-ts";
import {
  CapsUpdated,
  HarassmentScoreUpdated,
  ILRMUpdated,
  Paused,
  SubsidyFunded,
  TreasuryReceived
} from "../generated/Treasury/Treasury";
import {
  handleCapsUpdated,
  handleHarassmentScoreUpdated,
  handleILRMUpdated,
  handlePaused,
  handleSubsidyFunded,
  handleTreasuryReceived
} from "../src/treasury";
import { eventId } from "../src/common";
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
  pInt,
  pStr,
  pUint
} from "./helpers";

function receivedFrom(from: Address, amount: i32, reason: string): TreasuryReceived {
  return changetype<TreasuryReceived>(
    mockEvent(TREASURY_ADDRESS, [pAddr("from", from), pInt("amount", amount), pStr("reason", reason)])
  );
}

function received(amount: i32, reason: string): TreasuryReceived {
  return receivedFrom(ALICE, amount, reason);
}

function ilrmUpdated(oldIlrm: Address, newIlrm: Address): ILRMUpdated {
  return changetype<ILRMUpdated>(mockEvent(TREASURY_ADDRESS, [pAddr("oldILRM", oldIlrm), pAddr("newILRM", newIlrm)]));
}

describe("Treasury", () => {
  afterEach(() => {
    clearStore();
  });

  test("subsidy grants feed Treasury records only", () => {
    beginTx(1, 1000);
    const grant = changetype<SubsidyFunded>(
      mockEvent(TREASURY_ADDRESS, [pAddr("participant", BOB), pInt("disputeId", 3), pUint("amount", bi(40))])
    );
    handleSubsidyFunded(grant);
    assert.fieldEquals("TreasurySubsidy", eventId(grant), "participant", BOB.toHexString());
    assert.fieldEquals("TreasurySubsidy", eventId(grant), "disputeId", "3");
    assert.fieldEquals("TreasurySubsidy", eventId(grant), "dispute", "3");
    assert.fieldEquals("TreasuryMetric", "0", "totalSubsidies", "40");
    assert.fieldEquals("TreasuryMetric", "0", "subsidyCount", "1");
    // The escrow-side totals come from ILRM.StakeSubsidized, so nothing is double counted
    assert.fieldEquals("Party", BOB.toHexString(), "totalSubsidiesReceived", "0");
    assert.entityCount("ProtocolMetric", 0);
  });

  test("inflows are split by reason", () => {
    beginTx(2, 1000);
    handleILRMUpdated(ilrmUpdated(Address.zero(), ILRM_ADDRESS));
    handleTreasuryReceived(received(100, "fees"));
    // depositBurn(): ILRM-only, labelled "burn"
    const burn = receivedFrom(ILRM_ADDRESS, 30, "burn");
    handleTreasuryReceived(burn);
    const eth = received(7, "eth");
    handleTreasuryReceived(eth);
    assert.fieldEquals("TreasuryDeposit", eventId(eth), "isEth", "true");
    assert.fieldEquals("TreasuryDeposit", eventId(eth), "isBurn", "false");
    assert.fieldEquals("TreasuryDeposit", eventId(burn), "isBurn", "true");
    assert.fieldEquals("TreasuryMetric", "0", "totalReceived", "130");
    assert.fieldEquals("TreasuryMetric", "0", "totalBurnDeposits", "30");
    assert.fieldEquals("TreasuryMetric", "0", "burnDepositCount", "1");
    assert.fieldEquals("TreasuryMetric", "0", "totalReceivedEth", "7");
  });

  test("a \"burn\" label is only trusted from the Treasury's ILRM", () => {
    // deposit(amount, "burn") is permissionless: anyone can choose the label
    beginTx(4, 1000);
    const spoofed = received(500, "burn");
    handleTreasuryReceived(spoofed);
    assert.fieldEquals("TreasuryDeposit", eventId(spoofed), "reason", "burn");
    assert.fieldEquals("TreasuryDeposit", eventId(spoofed), "isBurn", "false");
    assert.fieldEquals("TreasuryMetric", "0", "totalReceived", "500");
    assert.fieldEquals("TreasuryMetric", "0", "totalBurnDeposits", "0");
    assert.fieldEquals("TreasuryMetric", "0", "burnDepositCount", "0");

    // Not even from the ILRM before the Treasury points at it
    beginTx(5, 2000);
    handleTreasuryReceived(receivedFrom(ILRM_ADDRESS, 40, "burn"));
    assert.fieldEquals("TreasuryMetric", "0", "burnDepositCount", "0");

    // Once ILRMUpdated names it, the ILRM's "burn" inflows count; a spoofed one still does not
    beginTx(6, 3000);
    handleILRMUpdated(ilrmUpdated(Address.zero(), ILRM_ADDRESS));
    handleTreasuryReceived(receivedFrom(ILRM_ADDRESS, 60, "burn"));
    handleTreasuryReceived(receivedFrom(BOB, 70, "burn"));
    assert.fieldEquals("TreasuryMetric", "0", "totalBurnDeposits", "60");
    assert.fieldEquals("TreasuryMetric", "0", "burnDepositCount", "1");

    // A replaced ILRM is no longer trusted
    beginTx(7, 4000);
    handleILRMUpdated(ilrmUpdated(ILRM_ADDRESS, CAROL));
    handleTreasuryReceived(receivedFrom(ILRM_ADDRESS, 80, "burn"));
    handleTreasuryReceived(receivedFrom(CAROL, 90, "burn"));
    assert.fieldEquals("TreasuryMetric", "0", "totalBurnDeposits", "150");
    assert.fieldEquals("TreasuryMetric", "0", "burnDepositCount", "2");
    assert.fieldEquals("TreasuryMetric", "0", "totalReceived", "840");
  });

  test("configuration, pause and the Treasury's own harassment score", () => {
    const treasury = TREASURY_ADDRESS.toHexString();
    beginTx(3, 1000);
    handleCapsUpdated(
      changetype<CapsUpdated>(
        mockEvent(TREASURY_ADDRESS, [
          pInt("maxPerDispute", 50),
          pInt("maxPerParticipant", 200),
          pInt("windowDuration", 86400)
        ])
      )
    );
    handleILRMUpdated(
      changetype<ILRMUpdated>(mockEvent(TREASURY_ADDRESS, [pAddr("oldILRM", ALICE), pAddr("newILRM", ILRM_ADDRESS)]))
    );
    handlePaused(changetype<Paused>(mockEvent(TREASURY_ADDRESS, [pAddr("account", ALICE)])));
    assert.fieldEquals("ProtocolContract", treasury, "kind", "TREASURY");
    assert.fieldEquals("ProtocolContract", treasury, "maxSubsidyPerDispute", "50");
    assert.fieldEquals("ProtocolContract", treasury, "maxSubsidyPerParticipant", "200");
    assert.fieldEquals("ProtocolContract", treasury, "subsidyWindowDuration", "86400");
    assert.fieldEquals("ProtocolContract", treasury, "ilrm", ILRM_ADDRESS.toHexString());
    assert.fieldEquals("ProtocolContract", treasury, "paused", "true");
    assert.entityCount("AdminEvent", 3);

    handleHarassmentScoreUpdated(
      changetype<HarassmentScoreUpdated>(
        mockEvent(TREASURY_ADDRESS, [pAddr("participant", BOB), pInt("oldScore", 0), pInt("newScore", 60)])
      )
    );
    assert.fieldEquals("Party", BOB.toHexString(), "treasuryHarassmentScore", "60");
    assert.fieldEquals("Party", BOB.toHexString(), "harassmentScore", "0");
  });
});
