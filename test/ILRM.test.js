const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("ILRM", function () {
  let ilrm, token, registry;
  let owner, oracle, initiator, counterparty;

  const STAKE_AMOUNT = ethers.parseEther("1");
  const EVIDENCE_HASH = ethers.keccak256(ethers.toUtf8Bytes("test evidence"));

  // Time constants
  const STAKE_WINDOW = 3 * 24 * 60 * 60; // 3 days
  const RESOLUTION_TIMEOUT = 7 * 24 * 60 * 60; // 7 days

  beforeEach(async function () {
    [owner, oracle, initiator, counterparty] = await ethers.getSigners();

    // Deploy mock token
    const MockToken = await ethers.getContractFactory("MockToken");
    token = await MockToken.deploy();

    // Deploy mock registry
    const MockRegistry = await ethers.getContractFactory("MockAssetRegistry");
    registry = await MockRegistry.deploy();

    // Deploy ILRM
    const ILRM = await ethers.getContractFactory("ILRM");
    ilrm = await ILRM.deploy(token.target, oracle.address, registry.target);

    // Fund test accounts
    await token.mint(initiator.address, ethers.parseEther("100"));
    await token.mint(counterparty.address, ethers.parseEther("100"));

    // Approve ILRM
    await token.connect(initiator).approve(ilrm.target, ethers.MaxUint256);
    await token.connect(counterparty).approve(ilrm.target, ethers.MaxUint256);
  });

  describe("Invariant 1: No Unilateral Cost Imposition", function () {
    it("initiator must stake first", async function () {
      const fallback = {
        termsHash: ethers.keccak256(ethers.toUtf8Bytes("fallback")),
        termDuration: 30 * 24 * 60 * 60,
        royaltyCapBps: 500,
        nonExclusive: true
      };

      const balanceBefore = await token.balanceOf(initiator.address);

      await ilrm.connect(initiator).initiateBreachDispute(
        counterparty.address,
        STAKE_AMOUNT,
        EVIDENCE_HASH,
        fallback
      );

      const balanceAfter = await token.balanceOf(initiator.address);
      expect(balanceBefore - balanceAfter).to.equal(STAKE_AMOUNT);
    });
  });

  describe("Invariant 2: Silence Is Always Free", function () {
    it("counterparty can ignore dispute without cost", async function () {
      const fallback = {
        termsHash: ethers.keccak256(ethers.toUtf8Bytes("fallback")),
        termDuration: 30 * 24 * 60 * 60,
        royaltyCapBps: 500,
        nonExclusive: true
      };

      await ilrm.connect(initiator).initiateBreachDispute(
        counterparty.address,
        STAKE_AMOUNT,
        EVIDENCE_HASH,
        fallback
      );

      const balanceBefore = await token.balanceOf(counterparty.address);

      // Warp past stake window
      await time.increase(STAKE_WINDOW + 1);

      // Resolve via timeout
      await ilrm.enforceTimeout(0);

      const balanceAfter = await token.balanceOf(counterparty.address);
      expect(balanceAfter).to.equal(balanceBefore);
    });
  });

  describe("Invariant 4: Bounded Griefing", function () {
    it("max 3 counter-proposals allowed", async function () {
      const fallback = {
        termsHash: ethers.keccak256(ethers.toUtf8Bytes("fallback")),
        termDuration: 30 * 24 * 60 * 60,
        royaltyCapBps: 500,
        nonExclusive: true
      };

      await ilrm.connect(initiator).initiateBreachDispute(
        counterparty.address,
        STAKE_AMOUNT,
        EVIDENCE_HASH,
        fallback
      );

      await ilrm.connect(counterparty).depositStake(0);

      // Submit 3 counters
      for (let i = 0; i < 3; i++) {
        const fee = ethers.parseEther("0.01") * BigInt(1 << i);
        await ilrm.connect(initiator).counterPropose(
          0,
          ethers.keccak256(ethers.toUtf8Bytes(`evidence${i}`)),
          { value: fee }
        );
      }

      // 4th counter should fail
      await expect(
        ilrm.connect(initiator).counterPropose(
          0,
          ethers.keccak256(ethers.toUtf8Bytes("evidence3")),
          { value: ethers.parseEther("0.08") }
        )
      ).to.be.revertedWith("Max counters reached");
    });
  });

  describe("Invariant 8: Economic Symmetry", function () {
    it("counterparty stakes match initiator stakes", async function () {
      const fallback = {
        termsHash: ethers.keccak256(ethers.toUtf8Bytes("fallback")),
        termDuration: 30 * 24 * 60 * 60,
        royaltyCapBps: 500,
        nonExclusive: true
      };

      await ilrm.connect(initiator).initiateBreachDispute(
        counterparty.address,
        STAKE_AMOUNT,
        EVIDENCE_HASH,
        fallback
      );

      await ilrm.connect(counterparty).depositStake(0);

      const dispute = await ilrm.disputes(0);
      expect(dispute.initiatorStake).to.equal(dispute.counterpartyStake);
    });
  });

  describe("Mutual Acceptance", function () {
    it("returns stakes when both parties accept", async function () {
      const fallback = {
        termsHash: ethers.keccak256(ethers.toUtf8Bytes("fallback")),
        termDuration: 30 * 24 * 60 * 60,
        royaltyCapBps: 500,
        nonExclusive: true
      };

      await ilrm.connect(initiator).initiateBreachDispute(
        counterparty.address,
        STAKE_AMOUNT,
        EVIDENCE_HASH,
        fallback
      );

      await ilrm.connect(counterparty).depositStake(0);

      // Oracle submits proposal
      await ilrm.connect(oracle).submitLLMProposal(
        0,
        '{"proposal": "split 50/50"}',
        "0x"
      );

      const initiatorBalanceBefore = await token.balanceOf(initiator.address);
      const counterpartyBalanceBefore = await token.balanceOf(counterparty.address);

      // Both accept
      await ilrm.connect(initiator).acceptProposal(0);
      await ilrm.connect(counterparty).acceptProposal(0);

      const initiatorBalanceAfter = await token.balanceOf(initiator.address);
      const counterpartyBalanceAfter = await token.balanceOf(counterparty.address);

      expect(initiatorBalanceAfter - initiatorBalanceBefore).to.equal(STAKE_AMOUNT);
      expect(counterpartyBalanceAfter - counterpartyBalanceBefore).to.equal(STAKE_AMOUNT);
    });
  });
});
