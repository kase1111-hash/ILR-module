import { afterEach, assert, clearStore, describe, test } from "matchstick-as/assembly/index";
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
import { ALICE, BOB, ILRM_ADDRESS, TREASURY_ADDRESS, beginTx, bi, mockEvent, pAddr, pInt, pStr, pUint } from "./helpers";

function received(amount: i32, reason: string): TreasuryReceived {
  return changetype<TreasuryReceived>(
    mockEvent(TREASURY_ADDRESS, [pAddr("from", ALICE), pInt("amount", amount), pStr("reason", reason)])
  );
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
    handleTreasuryReceived(received(100, "fees"));
    handleTreasuryReceived(received(30, "burn"));
    const eth = received(7, "eth");
    handleTreasuryReceived(eth);
    assert.fieldEquals("TreasuryDeposit", eventId(eth), "isEth", "true");
    assert.fieldEquals("TreasuryMetric", "0", "totalReceived", "130");
    assert.fieldEquals("TreasuryMetric", "0", "totalBurnDeposits", "30");
    assert.fieldEquals("TreasuryMetric", "0", "burnDepositCount", "1");
    assert.fieldEquals("TreasuryMetric", "0", "totalReceivedEth", "7");
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
