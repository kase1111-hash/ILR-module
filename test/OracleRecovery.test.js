/**
 * Oracle Recovery and Hash-Bound Acceptance Tests (ethers v6)
 *
 * - ILRM requests an oracle proposal when a dispute becomes fully staked (advisory pending flag).
 * - Oracle.resetProposal voids the proposal in ILRM in the same transaction (ProposalVoided), so a voided
 *   proposal can never resolve a dispute.
 * - acceptProposalWithHash binds an acceptance to the text the party reviewed; the 1-argument acceptProposal
 *   keeps working and stays unambiguous for ethers (the variant is a distinct name, not an overload).
 * - counterPropose and resetProposal are rejected after the resolution deadline.
 */

const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time, loadFixture } = require("@nomicfoundation/hardhat-network-helpers");

const PROPOSAL_TYPES = {
  Proposal: [
    { name: "disputeId", type: "uint256" },
    { name: "round", type: "uint256" },
    { name: "evidenceHash", type: "bytes32" },
    { name: "proposalHash", type: "bytes32" },
    { name: "nonce", type: "uint256" }
  ]
};

const hashOf = (text) => ethers.keccak256(ethers.toUtf8Bytes(text));

describe("Oracle Recovery and Hash-Bound Acceptance", function () {
  const STAKE = ethers.parseEther("10");
  const RESOLUTION_TIMEOUT = 7 * 24 * 60 * 60;
  const EVIDENCE = hashOf("evidence-0");
  const P1 = '{"terms":"P1"}';
  const P2 = '{"terms":"P2"}';

  async function deployFixture() {
    const [owner, operator, initiator, counterparty] = await ethers.getSigners();

    const token = await (await ethers.getContractFactory("MockToken")).deploy();
    const oracle = await (await ethers.getContractFactory("NatLangChainOracle")).deploy();
    const registry = await (await ethers.getContractFactory("MockAssetRegistry")).deploy();
    const ilrm = await (await ethers.getContractFactory("ILRM")).deploy(token.target, oracle.target, registry.target);

    await oracle.setILRM(ilrm.target);
    await oracle.registerOracle(operator.address, ethers.ZeroHash);

    for (const party of [initiator, counterparty]) {
      await token.mint(party.address, ethers.parseEther("1000"));
      await token.connect(party).approve(ilrm.target, ethers.MaxUint256);
    }

    await ilrm.connect(initiator).initiateBreachDispute(
      counterparty.address,
      STAKE,
      EVIDENCE,
      { termsHash: ethers.ZeroHash, termDuration: 86400, royaltyCapBps: 500, nonExclusive: true }
    );

    const { chainId } = await ethers.provider.getNetwork();
    const domain = { name: "NatLangChainOracle", version: "1", chainId, verifyingContract: oracle.target };

    return { token, oracle, ilrm, owner, operator, initiator, counterparty, domain };
  }

  async function stakedFixture() {
    const f = await deployFixture();
    await f.ilrm.connect(f.counterparty).depositStake(0);
    return f;
  }

  async function submit({ oracle, operator, domain }, proposal) {
    const [round, evidenceHash, nonce] = await oracle.proposalContext(0);
    const value = { disputeId: 0, round, evidenceHash, proposalHash: hashOf(proposal), nonce };
    const signature = await operator.signTypedData(domain, PROPOSAL_TYPES, value);
    return oracle.connect(operator).submitProposal(0, proposal, signature);
  }

  it("depositStake requests a proposal from the Oracle", async function () {
    const { oracle, ilrm, counterparty } = await loadFixture(deployFixture);
    expect(await oracle.isPending(0)).to.be.false;

    await expect(ilrm.connect(counterparty).depositStake(0))
      .to.emit(oracle, "ProposalRequested")
      .and.not.to.emit(ilrm, "OracleRequestFailed");
    expect(await oracle.isPending(0)).to.be.true;

    // Cancelling withdraws the advisory flag with a dedicated event, never a zero-valued ProposalRequested
    const cancel = await oracle.cancelPendingRequest(0);
    await expect(cancel).to.emit(oracle, "ProposalRequestCancelled").withArgs(0);
    await expect(cancel).not.to.emit(oracle, "ProposalRequested");
    expect(await oracle.isPending(0)).to.be.false;
  });

  it("reviewer PoC: after a reset the counterparty can no longer resolve the dispute on the voided proposal", async function () {
    const f = await loadFixture(stakedFixture);
    const { oracle, ilrm, initiator, counterparty } = f;

    await submit(f, P1);
    await ilrm.connect(initiator).acceptProposal(0);

    await expect(oracle.resetProposal(0, "incorrect proposal"))
      .to.emit(ilrm, "ProposalVoided").withArgs(0, 0, hashOf(P1));

    const dispute = await ilrm.disputes(0);
    expect(dispute.llmProposal).to.equal("");
    expect(dispute.initiatorAccepted).to.be.false;
    expect(dispute.counterpartyAccepted).to.be.false;

    await expect(ilrm.connect(counterparty).acceptProposal(0)).to.be.revertedWith("No proposal yet");
    expect((await ilrm.disputes(0)).resolved).to.be.false;
  });

  it("acceptProposalWithHash rejects a stale hash and resolves on the live one", async function () {
    const f = await loadFixture(stakedFixture);
    const { oracle, ilrm, initiator, counterparty } = f;

    await submit(f, P1);
    await oracle.resetProposalExact(0, 0, hashOf(P1), "replace P1");
    await submit(f, P2);

    await expect(ilrm.connect(counterparty).acceptProposalWithHash(0, hashOf(P1)))
      .to.be.revertedWith("Proposal changed");

    await expect(ilrm.connect(initiator).acceptProposalWithHash(0, hashOf(P2)))
      .to.emit(ilrm, "AcceptanceSignaled").withArgs(0, initiator.address);
    await expect(ilrm.connect(counterparty).acceptProposalWithHash(0, hashOf(P2)))
      .to.emit(ilrm, "DisputeResolved");

    const dispute = await ilrm.disputes(0);
    expect(dispute.resolved).to.be.true;
    expect(dispute.llmProposal).to.equal(P2);
  });

  it("keeps the legacy 1-argument acceptProposal unambiguous for ethers", async function () {
    const f = await loadFixture(stakedFixture);
    const { ilrm, initiator, counterparty } = f;

    // A distinct name, not an overload: ethers resolves both by name and accepts trailing overrides
    expect(ilrm.interface.getFunction("acceptProposal").inputs.length).to.equal(1);
    expect(ilrm.interface.getFunction("acceptProposalWithHash").inputs.length).to.equal(2);
    expect(ilrm.interface.fragments.filter((frag) => frag.name === "acceptProposal")).to.have.length(1);

    await submit(f, P1);
    await ilrm.connect(initiator).acceptProposal(0, { gasLimit: 300000 });
    await ilrm.connect(counterparty).acceptProposal(0, { gasLimit: 300000 });
    expect((await ilrm.disputes(0)).resolved).to.be.true;
  });

  it("rejects counterPropose and resetProposal after the resolution deadline", async function () {
    const f = await loadFixture(stakedFixture);
    const { oracle, ilrm, initiator } = f;

    await submit(f, P1);
    const deadline = (await ilrm.disputes(0)).startTime + BigInt(RESOLUTION_TIMEOUT);
    const [, , , ctxDeadline] = await ilrm.oracleContext(0);
    expect(ctxDeadline).to.equal(deadline);

    await time.increaseTo(deadline + 1n);

    await expect(
      ilrm.connect(initiator).counterPropose(0, hashOf("late"), { value: ethers.parseEther("0.01") })
    ).to.be.revertedWith("Timeout passed");
    await expect(oracle.resetProposal(0, "too late"))
      .to.be.revertedWithCustomError(oracle, "ResolutionDeadlinePassed").withArgs(0, deadline);

    await expect(ilrm.enforceTimeout(0)).to.emit(ilrm, "DisputeResolved");
    expect((await ilrm.disputes(0)).counterCount).to.equal(0);
  });

  it("resetProposalExact never voids a proposal that landed after it was queued", async function () {
    const f = await loadFixture(stakedFixture);
    const { oracle, ilrm, initiator } = f;

    await submit(f, P1);
    await ilrm.connect(initiator).counterPropose(0, hashOf("evidence-1"), { value: ethers.parseEther("0.01") });
    await submit(f, P2);

    await expect(oracle.resetProposalExact(0, 0, hashOf(P1), "queued for P1"))
      .to.be.revertedWithCustomError(oracle, "ProposalMismatch").withArgs(0, 1, hashOf(P2));
    expect((await ilrm.disputes(0)).llmProposal).to.equal(P2);
  });
});
