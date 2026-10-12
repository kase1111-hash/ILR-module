/**
 * Oracle Proposal Rounds Tests
 *
 * The Oracle admits one proposal per negotiation round (ILRM counterCount). Every round opened by
 * counterPropose takes a new proposal without owner intervention; the owner's resetProposal voids the
 * current round's live proposal (in ILRM too, in the same transaction) and allows exactly one replacement.
 *
 * Signatures use the same EIP-712 typed data as scripts/interact.js, so these tests also guard the
 * off-chain signing format.
 */

const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");

// Must match scripts/interact.js and NatLangChainOracle.PROPOSAL_TYPEHASH
const PROPOSAL_TYPES = {
  Proposal: [
    { name: "disputeId", type: "uint256" },
    { name: "round", type: "uint256" },
    { name: "evidenceHash", type: "bytes32" },
    { name: "proposalHash", type: "bytes32" },
    { name: "nonce", type: "uint256" }
  ]
};

describe("Oracle Proposal Rounds", function () {
  const STAKE = ethers.parseEther("10");
  const COUNTER_FEE_BASE = ethers.parseEther("0.01");

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
      ethers.keccak256(ethers.toUtf8Bytes("evidence-0")),
      { termsHash: ethers.ZeroHash, termDuration: 86400, royaltyCapBps: 500, nonExclusive: true }
    );
    await ilrm.connect(counterparty).depositStake(0);

    const { chainId } = await ethers.provider.getNetwork();
    const domain = { name: "NatLangChainOracle", version: "1", chainId, verifyingContract: oracle.target };

    return { token, oracle, registry, ilrm, owner, operator, initiator, counterparty, domain };
  }

  /** Typed-data value for the dispute's live context */
  async function currentValue(oracle, disputeId, proposal) {
    const [round, evidenceHash, nonce] = await oracle.proposalContext(disputeId);
    return {
      disputeId,
      round,
      evidenceHash,
      proposalHash: ethers.keccak256(ethers.toUtf8Bytes(proposal)),
      nonce
    };
  }

  async function signCurrent(oracle, signer, domain, disputeId, proposal) {
    const value = await currentValue(oracle, disputeId, proposal);
    return signer.signTypedData(domain, PROPOSAL_TYPES, value);
  }

  async function submit(oracle, operator, domain, disputeId, proposal) {
    const signature = await signCurrent(oracle, operator, domain, disputeId, proposal);
    return oracle.connect(operator).submitProposal(disputeId, proposal, signature);
  }

  async function counter(ilrm, party, disputeId, label) {
    const { counterCount } = await ilrm.disputes(disputeId);
    await ilrm.connect(party).counterPropose(
      disputeId,
      ethers.keccak256(ethers.toUtf8Bytes(label)),
      { value: COUNTER_FEE_BASE << counterCount }
    );
  }

  async function expectDigestMatches(oracle, domain, disputeId, proposal) {
    const value = await currentValue(oracle, disputeId, proposal);
    expect(ethers.TypedDataEncoder.hash(domain, PROPOSAL_TYPES, value))
      .to.equal(await oracle.proposalDigest(disputeId, value.proposalHash));
  }

  it("matches ethers TypedDataEncoder with oracle.proposalDigest across rounds and after a reset", async function () {
    const { oracle, ilrm, operator, initiator, counterparty, domain } = await loadFixture(deployFixture);

    expect(await oracle.PROPOSAL_TYPEHASH()).to.equal(
      ethers.id("Proposal(uint256 disputeId,uint256 round,bytes32 evidenceHash,bytes32 proposalHash,uint256 nonce)")
    );
    expect(await oracle.DOMAIN_SEPARATOR()).to.equal(ethers.TypedDataEncoder.hashDomain(domain));

    await expectDigestMatches(oracle, domain, 0, '{"round":0}');
    await submit(oracle, operator, domain, 0, '{"round":0}');

    await counter(ilrm, initiator, 0, "evidence-1");
    await expectDigestMatches(oracle, domain, 0, '{"round":1}');
    await submit(oracle, operator, domain, 0, '{"round":1}');

    await oracle.resetProposal(0, "recovery");
    await expectDigestMatches(oracle, domain, 0, '{"round":1,"fixed":true}');
    await submit(oracle, operator, domain, 0, '{"round":1,"fixed":true}');

    await counter(ilrm, counterparty, 0, "evidence-2");
    await expectDigestMatches(oracle, domain, 0, '{"round":2}');
  });

  it("accepts a new proposal after each of three counters with no admin call", async function () {
    const { oracle, ilrm, operator, initiator, counterparty, domain } = await loadFixture(deployFixture);

    await submit(oracle, operator, domain, 0, '{"round":0}');
    const parties = [initiator, counterparty, initiator];

    for (let round = 1; round <= 3; round++) {
      await counter(ilrm, parties[round - 1], 0, `evidence-${round}`);
      const proposal = `{"round":${round}}`;
      await expect(submit(oracle, operator, domain, 0, proposal))
        .to.emit(oracle, "ProposalRoundFilled")
        .withArgs(0, round, ethers.keccak256(ethers.toUtf8Bytes(proposal)), round);
      expect((await ilrm.disputes(0)).llmProposal).to.equal(proposal);
    }

    expect(await oracle.getNonce(0)).to.equal(4);

    await ilrm.connect(initiator).acceptProposal(0);
    await ilrm.connect(counterparty).acceptProposal(0);
    const dispute = await ilrm.disputes(0);
    expect(dispute.resolved).to.be.true;
    expect(dispute.counterCount).to.equal(3);
    expect(dispute.llmProposal).to.equal('{"round":3}');
  });

  it("reset voids the proposal and its acceptance in ILRM; the replacement lands without superseding", async function () {
    const { oracle, ilrm, operator, initiator, counterparty, domain } = await loadFixture(deployFixture);

    const bad = '{"terms":"bad"}';
    const fixed = '{"terms":"fixed"}';
    const badHash = ethers.keccak256(ethers.toUtf8Bytes(bad));
    const fixedHash = ethers.keccak256(ethers.toUtf8Bytes(fixed));

    await submit(oracle, operator, domain, 0, bad);
    await ilrm.connect(initiator).acceptProposal(0);

    await expect(oracle.resetProposal(0, "incorrect proposal"))
      .to.emit(oracle, "ProposalRoundReopened").withArgs(0, 0, badHash)
      .and.to.emit(oracle, "ProposalReset").withArgs(0, badHash, "incorrect proposal")
      .and.to.emit(ilrm, "ProposalVoided").withArgs(0, 0, badHash);

    let dispute = await ilrm.disputes(0);
    expect(dispute.llmProposal).to.equal("");
    expect(dispute.initiatorAccepted).to.be.false;

    const replacement = await submit(oracle, operator, domain, 0, fixed);
    await expect(replacement).to.emit(oracle, "ProposalRoundFilled").withArgs(0, 0, fixedHash, 2);
    await expect(replacement).not.to.emit(ilrm, "ProposalSuperseded");

    dispute = await ilrm.disputes(0);
    expect(dispute.llmProposal).to.equal(fixed);
    expect(dispute.initiatorAccepted).to.be.false;

    // Exactly one replacement per reset
    await expect(submit(oracle, operator, domain, 0, '{"terms":"third"}'))
      .to.be.revertedWithCustomError(oracle, "ProposalAlreadyProcessed").withArgs(0, 0);

    // The counterparty's acceptance alone no longer resolves the dispute
    await ilrm.connect(counterparty).acceptProposal(0);
    expect((await ilrm.disputes(0)).resolved).to.be.false;

    await ilrm.connect(initiator).acceptProposal(0);
    dispute = await ilrm.disputes(0);
    expect(dispute.resolved).to.be.true;
    expect(dispute.llmProposal).to.equal(fixed);
  });

  it("rejects a signature made for a round that has since closed", async function () {
    const { oracle, ilrm, operator, initiator, domain } = await loadFixture(deployFixture);

    const proposal = '{"terms":"late"}';
    const roundZeroSignature = await signCurrent(oracle, operator, domain, 0, proposal);

    await counter(ilrm, initiator, 0, "evidence-1");

    await expect(oracle.connect(operator).submitProposal(0, proposal, roundZeroSignature))
      .to.be.revertedWithCustomError(oracle, "InvalidSignature");

    // A signature for the open round succeeds
    await submit(oracle, operator, domain, 0, proposal);
    expect(await oracle.roundProposals(0, 1)).to.equal(ethers.keccak256(ethers.toUtf8Bytes(proposal)));
    expect(await oracle.roundProposals(0, 0)).to.equal(ethers.ZeroHash);
  });
});
