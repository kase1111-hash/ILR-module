import { afterEach, assert, clearStore, createMockedFunction, describe, test } from "matchstick-as/assembly/index";
import { Address, BigInt, Bytes, ethereum } from "@graphprotocol/graph-ts";
import {
  BridgeStatusChanged,
  CommittedChainRolledBack,
  DisputeBridgeSkipped,
  DisputeBridgedToL3,
  DisputeBridgerUpdated,
  DisputeSettledFromL3,
  FraudProofCommitted,
  FraudProofForfeited,
  FraudProofRefunded,
  FraudProofRevealed,
  FraudProofSubmitted,
  FraudProofValidated,
  SequencerUpdated,
  StateCommitmentFinalized,
  StateCommitmentSubmitted
} from "../generated/L3Bridge/L3Bridge";
import { L3StateCommitment } from "../generated/schema";
import {
  handleBridgeStatusChanged,
  handleCommittedChainRolledBack,
  handleDisputeBridgeSkipped,
  handleDisputeBridgedToL3,
  handleDisputeBridgerUpdated,
  handleDisputeSettledFromL3,
  handleFraudProofCommitted,
  handleFraudProofForfeited,
  handleFraudProofRefunded,
  handleFraudProofRevealed,
  handleFraudProofSubmitted,
  handleFraudProofValidated,
  handleSequencerUpdated,
  handleStateCommitmentFinalized,
  handleStateCommitmentSubmitted
} from "../src/l3bridge";
import {
  ALICE,
  BOB,
  CAROL,
  L3_ADDRESS,
  OPERATOR,
  RELAYER,
  beginTx,
  bi,
  mockEvent,
  pAddr,
  pB32,
  pBool,
  pInt,
  pUint,
  word
} from "./helpers";

const BOND = BigInt.fromString("100000000000000000");
const REWARD = BigInt.fromString("50000000000000000");

function root(n: i32): Bytes {
  return word(0x7700 + n);
}

function commitHash(n: i32): Bytes {
  return word(0xc000 + n);
}

function submitRoot(r: Bytes, l3Block: i32, disputes: i32, deadline: i32): void {
  createMockedFunction(L3_ADDRESS, "getChallengeDeadline", "getChallengeDeadline(bytes32):(uint256)")
    .withArgs([ethereum.Value.fromFixedBytes(r)])
    .returns([ethereum.Value.fromUnsignedBigInt(bi(deadline))]);
  handleStateCommitmentSubmitted(
    changetype<StateCommitmentSubmitted>(
      mockEvent(L3_ADDRESS, [
        pB32("stateRoot", r),
        pInt("blockNumber", l3Block),
        pInt("disputeCount", disputes),
        pAddr("sequencer", OPERATOR)
      ])
    )
  );
}

function commit(hash: Bytes, r: Bytes, challenger: Address): void {
  handleFraudProofCommitted(
    changetype<FraudProofCommitted>(
      mockEvent(L3_ADDRESS, [
        pB32("commitHash", hash),
        pB32("stateRoot", r),
        pAddr("challenger", challenger),
        pUint("bond", BOND)
      ])
    )
  );
}

function reveal(hash: Bytes, r: Bytes, challenger: Address): void {
  handleFraudProofRevealed(
    changetype<FraudProofRevealed>(
      mockEvent(L3_ADDRESS, [pB32("commitHash", hash), pB32("stateRoot", r), pAddr("challenger", challenger)])
    )
  );
}

/** _recordSuccessfulChallenge + FraudProofValidated */
function rejectRoot(r: Bytes, newHead: Bytes, newHeight: i32, disputeId: i32, challenger: Address, reward: BigInt): void {
  handleCommittedChainRolledBack(
    changetype<CommittedChainRolledBack>(
      mockEvent(L3_ADDRESS, [pB32("rejectedRoot", r), pB32("newHead", newHead), pInt("newHeight", newHeight)])
    )
  );
  handleFraudProofSubmitted(
    changetype<FraudProofSubmitted>(
      mockEvent(L3_ADDRESS, [pB32("claimedRoot", r), pInt("disputeId", disputeId), pAddr("challenger", challenger)])
    )
  );
  handleFraudProofValidated(
    changetype<FraudProofValidated>(
      mockEvent(L3_ADDRESS, [pB32("claimedRoot", r), pAddr("challenger", challenger), pUint("reward", reward)])
    )
  );
}

function commitmentKey(challenger: Address, hash: Bytes): string {
  return challenger.toHexString() + "-" + hash.toHexString();
}

describe("L3Bridge state commitments and fraud proofs", () => {
  afterEach(() => {
    clearStore();
  });

  test("commit-reveal win rejects the root, orphans descendants and settles every bond", () => {
    const bridge = L3_ADDRESS.toHexString();

    beginTx(1, 1000);
    submitRoot(root(1), 100, 3, 87400);
    assert.fieldEquals("L3StateCommitment", root(1).toHexString(), "height", "1");
    assert.fieldEquals("L3StateCommitment", root(1).toHexString(), "status", "PENDING");
    assert.fieldEquals("L3StateCommitment", root(1).toHexString(), "challengeDeadline", "87400");
    assert.assertTrue(L3StateCommitment.load(root(1).toHexString())!.previousRoot === null);

    beginTx(2, 90000);
    handleStateCommitmentFinalized(
      changetype<StateCommitmentFinalized>(mockEvent(L3_ADDRESS, [pB32("stateRoot", root(1)), pInt("blockNumber", 100)]))
    );
    assert.fieldEquals("L3StateCommitment", root(1).toHexString(), "status", "FINALIZED");
    assert.fieldEquals("L3Chain", bridge, "latestFinalizedHeight", "1");

    beginTx(3, 91000);
    submitRoot(root(2), 200, 2, 177400);
    beginTx(4, 92000);
    submitRoot(root(3), 300, 1, 178400);
    assert.fieldEquals("L3StateCommitment", root(2).toHexString(), "previousRoot", root(1).toHexString());
    assert.fieldEquals("L3StateCommitment", root(3).toHexString(), "height", "3");
    assert.fieldEquals("L3StateCommitment", root(3).toHexString(), "previousRoot", root(2).toHexString());

    beginTx(5, 93000);
    commit(commitHash(1), root(2), ALICE);
    commit(commitHash(2), root(2), BOB);
    assert.fieldEquals("FraudProofCommitment", commitmentKey(ALICE, commitHash(1)), "status", "PENDING");

    // revealFraudProof win: Revealed, RolledBack, Submitted, Validated
    beginTx(6, 94000);
    reveal(commitHash(1), root(2), ALICE);
    rejectRoot(root(2), root(1), 1, 42, ALICE, REWARD);
    assert.fieldEquals("L3StateCommitment", root(2).toHexString(), "status", "REJECTED");
    assert.fieldEquals("L3StateCommitment", root(2).toHexString(), "challenge", root(2).toHexString());
    assert.fieldEquals("L3StateCommitment", root(3).toHexString(), "status", "ORPHANED");
    assert.fieldEquals("L3StateCommitment", root(1).toHexString(), "status", "FINALIZED");
    assert.fieldEquals("FraudProofChallenge", root(2).toHexString(), "mode", "COMMIT_REVEAL");
    assert.fieldEquals("FraudProofChallenge", root(2).toHexString(), "commitment", commitmentKey(ALICE, commitHash(1)));
    assert.fieldEquals("FraudProofChallenge", root(2).toHexString(), "challenger", ALICE.toHexString());
    assert.fieldEquals("FraudProofChallenge", root(2).toHexString(), "disputeId", "42");
    assert.fieldEquals("FraudProofChallenge", root(2).toHexString(), "reward", REWARD.toString());
    assert.fieldEquals("FraudProofChallenge", root(2).toHexString(), "orphanedCount", "1");
    assert.fieldEquals("FraudProofCommitment", commitmentKey(ALICE, commitHash(1)), "status", "WON");
    assert.fieldEquals("FraudProofCommitment", commitmentKey(ALICE, commitHash(1)), "reward", REWARD.toString());
    assert.fieldEquals("L3Chain", bridge, "latestCommittedRoot", root(1).toHexString());
    assert.fieldEquals("L3Chain", bridge, "latestCommittedHeight", "1");

    // A second valid reveal against the already-rejected root is refunded
    beginTx(7, 95000);
    reveal(commitHash(2), root(2), BOB);
    handleFraudProofRefunded(
      changetype<FraudProofRefunded>(
        mockEvent(L3_ADDRESS, [
          pB32("commitHash", commitHash(2)),
          pB32("stateRoot", root(2)),
          pAddr("challenger", BOB),
          pUint("bond", BOND)
        ])
      )
    );
    assert.fieldEquals("FraudProofCommitment", commitmentKey(BOB, commitHash(2)), "status", "REFUNDED");
    // The refund's reveal did not steal the win
    assert.fieldEquals("FraudProofChallenge", root(2).toHexString(), "commitment", commitmentKey(ALICE, commitHash(1)));

    // The chain continues from the rolled-back head
    beginTx(8, 96000);
    submitRoot(root(4), 400, 5, 182400);
    assert.fieldEquals("L3StateCommitment", root(4).toHexString(), "height", "2");
    assert.fieldEquals("L3StateCommitment", root(4).toHexString(), "previousRoot", root(1).toHexString());

    // A commitment that is never revealed is forfeited after the window
    beginTx(9, 97000);
    commit(commitHash(3), root(4), CAROL);
    beginTx(10, 99000);
    handleFraudProofForfeited(
      changetype<FraudProofForfeited>(
        mockEvent(L3_ADDRESS, [
          pB32("commitHash", commitHash(3)),
          pB32("stateRoot", root(4)),
          pAddr("challenger", CAROL),
          pUint("bond", BOND)
        ])
      )
    );
    assert.fieldEquals("FraudProofCommitment", commitmentKey(CAROL, commitHash(3)), "status", "FORFEITED");
    assert.fieldEquals("FraudProofCommitment", commitmentKey(CAROL, commitHash(3)), "resolvedAt", "99000");
    assert.fieldEquals("L3StateCommitment", root(4).toHexString(), "status", "PENDING");

    assert.fieldEquals("L3Metric", "0", "commitmentsSubmitted", "1");
    assert.fieldEquals("L3Metric", "86400", "commitmentsSubmitted", "3");
    assert.fieldEquals("L3Metric", "86400", "fraudProofsCommitted", "3");
    assert.fieldEquals("L3Metric", "86400", "fraudProofsWon", "1");
    assert.fieldEquals("L3Metric", "86400", "fraudProofsRefunded", "1");
    assert.fieldEquals("L3Metric", "86400", "fraudProofsForfeited", "1");
    assert.fieldEquals("L3Metric", "86400", "bondsForfeited", BOND.toString());
    assert.fieldEquals("L3Metric", "86400", "commitmentsRejected", "1");
    assert.fieldEquals("L3Metric", "86400", "commitmentsOrphaned", "1");
    assert.fieldEquals("ProtocolMetric", "protocol", "totalL3Commitments", "4");
  });

  test("legacy direct fraud proof rejecting the genesis root", () => {
    beginTx(20, 1000);
    submitRoot(root(5), 10, 1, 87400);
    beginTx(21, 2000);
    rejectRoot(root(5), word(0), 0, 7, BOB, BigInt.zero());
    assert.fieldEquals("FraudProofChallenge", root(5).toHexString(), "mode", "DIRECT");
    assert.fieldEquals("FraudProofChallenge", root(5).toHexString(), "challenger", BOB.toHexString());
    assert.fieldEquals("L3StateCommitment", root(5).toHexString(), "status", "REJECTED");
    assert.fieldEquals("L3Chain", L3_ADDRESS.toHexString(), "latestCommittedHeight", "0");

    beginTx(22, 3000);
    submitRoot(root(6), 11, 1, 89400);
    assert.fieldEquals("L3StateCommitment", root(6).toHexString(), "height", "1");
    assert.assertTrue(L3StateCommitment.load(root(6).toHexString())!.previousRoot === null);
  });
});

describe("L3Bridge dispute bridging and configuration", () => {
  afterEach(() => {
    clearStore();
  });

  test("bridge, skip a re-bridge, settle", () => {
    beginTx(30, 1000);
    handleDisputeBridgedToL3(
      changetype<DisputeBridgedToL3>(
        mockEvent(L3_ADDRESS, [
          pInt("l2DisputeId", 9),
          pInt("l3DisputeId", 1),
          pAddr("initiator", ALICE),
          pInt("stakeAmount", 100)
        ])
      )
    );
    handleDisputeBridgeSkipped(
      changetype<DisputeBridgeSkipped>(mockEvent(L3_ADDRESS, [pInt("l2DisputeId", 9), pInt("existingL3DisputeId", 1)]))
    );
    beginTx(31, 2000);
    handleDisputeSettledFromL3(
      changetype<DisputeSettledFromL3>(
        mockEvent(L3_ADDRESS, [
          pInt("l2DisputeId", 9),
          pInt("l3DisputeId", 1),
          pInt("outcome", 3),
          pInt("initiatorReturn", 100),
          pInt("counterpartyReturn", 90)
        ])
      )
    );
    assert.fieldEquals("L3BridgedDispute", "9", "l3DisputeId", "1");
    assert.fieldEquals("L3BridgedDispute", "9", "dispute", "9");
    assert.fieldEquals("L3BridgedDispute", "9", "skippedRebridges", "1");
    assert.fieldEquals("L3BridgedDispute", "9", "settled", "true");
    assert.fieldEquals("L3BridgedDispute", "9", "outcome", "ACCEPTED");
    assert.fieldEquals("L3BridgedDispute", "9", "counterpartyReturn", "90");
    assert.fieldEquals("L3Chain", L3_ADDRESS.toHexString(), "totalSettlements", "1");
  });

  test("status, sequencer and roles", () => {
    const bridge = L3_ADDRESS.toHexString();
    beginTx(40, 1000);
    handleBridgeStatusChanged(
      changetype<BridgeStatusChanged>(mockEvent(L3_ADDRESS, [pInt("oldStatus", 0), pInt("newStatus", 2)]))
    );
    assert.fieldEquals("ProtocolContract", bridge, "bridgeStatus", "DEPRECATED");

    handleSequencerUpdated(
      changetype<SequencerUpdated>(mockEvent(L3_ADDRESS, [pAddr("oldSequencer", OPERATOR), pAddr("newSequencer", BOB)]))
    );
    assert.fieldEquals("ProtocolContract", bridge, "sequencer", BOB.toHexString());

    handleDisputeBridgerUpdated(
      changetype<DisputeBridgerUpdated>(mockEvent(L3_ADDRESS, [pAddr("account", RELAYER), pBool("authorized", true)]))
    );
    const roleId = bridge + "-L3_DISPUTE_BRIDGER-" + RELAYER.toHexString();
    assert.fieldEquals("RoleMember", roleId, "active", "true");
    handleDisputeBridgerUpdated(
      changetype<DisputeBridgerUpdated>(mockEvent(L3_ADDRESS, [pAddr("account", RELAYER), pBool("authorized", false)]))
    );
    assert.fieldEquals("RoleMember", roleId, "active", "false");
    assert.entityCount("AdminEvent", 4);
  });
});
