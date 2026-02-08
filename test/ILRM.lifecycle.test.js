/**
 * ILRM Lifecycle Tests
 *
 * Tests all 7 phases from the Protocol Specification v1.1:
 * 1. Dispute Initiation (Section 4.1)
 * 2. Stake Symmetry Window (Section 4.2)
 * 3. Evidence Canonicalization (Section 4.3) - off-chain, tested via hash
 * 4. Proposal Generation (Section 4.4)
 * 5. Mutual Acceptance (Section 4.5)
 * 6. Counter-Proposals (Section 4.6)
 * 7. Timeout & Entropy Resolution (Section 4.7)
 *
 * ⚠️  CRITICAL: These tests verify protocol safety invariants.
 *     Failing tests indicate potential fund loss or griefing vectors.
 */

const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time, loadFixture } = require("@nomicfoundation/hardhat-network-helpers");

describe("ILRM Lifecycle Tests", function () {
  // ============ Constants from Appendix A ============
  const STAKE_WINDOW = 3 * 24 * 60 * 60;        // T_stake: 72 hours
  const RESOLUTION_TIMEOUT = 7 * 24 * 60 * 60;  // T_resolution: 7 days
  const BURN_PERCENTAGE = 50;                    // 50% burn on timeout
  const MAX_COUNTERS = 3;                        // Max counter-proposals
  const COUNTER_FEE_BASE = ethers.parseEther("0.01");
  const COOLDOWN_PERIOD = 30 * 24 * 60 * 60;    // 30 days

  async function deployFixture() {
    const [owner, oracle, initiator, counterparty, third] = await ethers.getSigners();

    const MockToken = await ethers.getContractFactory("MockToken");
    const token = await MockToken.deploy();

    const MockRegistry = await ethers.getContractFactory("MockAssetRegistry");
    const registry = await MockRegistry.deploy();

    const ILRM = await ethers.getContractFactory("ILRM");
    const ilrm = await ILRM.deploy(token.target, oracle.address, registry.target);

    // Fund accounts
    await token.mint(initiator.address, ethers.parseEther("1000"));
    await token.mint(counterparty.address, ethers.parseEther("1000"));

    // Approve ILRM
    await token.connect(initiator).approve(ilrm.target, ethers.MaxUint256);
    await token.connect(counterparty).approve(ilrm.target, ethers.MaxUint256);

    const STAKE = ethers.parseEther("10");
    const EVIDENCE_HASH = ethers.keccak256(ethers.toUtf8Bytes("evidence"));

    const fallback = {
      termsHash: ethers.keccak256(ethers.toUtf8Bytes("fallback-license")),
      termDuration: 30 * 24 * 60 * 60,
      royaltyCapBps: 500,
      nonExclusive: true
    };

    return { ilrm, token, registry, owner, oracle, initiator, counterparty, third, STAKE, EVIDENCE_HASH, fallback };
  }

  // ============================================================
  // PHASE 1: DISPUTE INITIATION (Section 4.1)
  // ============================================================
  describe("Phase 1: Dispute Initiation", function () {
    /**
     * ⚠️  CRITICAL: Initiator MUST stake before counterparty is exposed
     *     This enforces Invariant 1 (No Unilateral Cost Imposition)
     */
    it("should require initiator to stake immediately", async function () {
      const { ilrm, token, initiator, counterparty, STAKE, EVIDENCE_HASH, fallback } = await loadFixture(deployFixture);

      const balanceBefore = await token.balanceOf(initiator.address);

      await ilrm.connect(initiator).initiateBreachDispute(
        counterparty.address,
        STAKE,
        EVIDENCE_HASH,
        fallback
      );

      const balanceAfter = await token.balanceOf(initiator.address);
      expect(balanceBefore - balanceAfter).to.equal(STAKE);
    });

    it("should emit DisputeInitiated event with correct parameters", async function () {
      const { ilrm, initiator, counterparty, STAKE, EVIDENCE_HASH, fallback } = await loadFixture(deployFixture);

      await expect(ilrm.connect(initiator).initiateBreachDispute(
        counterparty.address,
        STAKE,
        EVIDENCE_HASH,
        fallback
      ))
        .to.emit(ilrm, "DisputeInitiated")
        .withArgs(0, initiator.address, counterparty.address, EVIDENCE_HASH);
    });

    it("should reject zero stake amount", async function () {
      const { ilrm, initiator, counterparty, EVIDENCE_HASH, fallback } = await loadFixture(deployFixture);

      await expect(ilrm.connect(initiator).initiateBreachDispute(
        counterparty.address,
        0,
        EVIDENCE_HASH,
        fallback
      )).to.be.revertedWith("Zero stake");
    });

    it("should reject self-disputes", async function () {
      const { ilrm, initiator, STAKE, EVIDENCE_HASH, fallback } = await loadFixture(deployFixture);

      await expect(ilrm.connect(initiator).initiateBreachDispute(
        initiator.address,
        STAKE,
        EVIDENCE_HASH,
        fallback
      )).to.be.revertedWith("Cannot dispute self");
    });

    /**
     * ⚠️  CRITICAL: Fallback license MUST be non-exclusive per spec
     *     Exclusive fallbacks would grant unilateral control
     */
    it("should reject exclusive fallback licenses", async function () {
      const { ilrm, initiator, counterparty, STAKE, EVIDENCE_HASH } = await loadFixture(deployFixture);

      const exclusiveFallback = {
        termsHash: ethers.keccak256(ethers.toUtf8Bytes("exclusive")),
        termDuration: 30 * 24 * 60 * 60,
        royaltyCapBps: 500,
        nonExclusive: false  // INVALID
      };

      await expect(ilrm.connect(initiator).initiateBreachDispute(
        counterparty.address,
        STAKE,
        EVIDENCE_HASH,
        exclusiveFallback
      )).to.be.revertedWith("Fallback must be non-exclusive");
    });

    /**
     * Invariant 5: Harassment Is Net-Negative
     * Repeat disputes within cooldown should escalate stake
     */
    it("should escalate stake for repeat disputes within cooldown", async function () {
      const { ilrm, token, initiator, counterparty, STAKE, EVIDENCE_HASH, fallback } = await loadFixture(deployFixture);

      // First dispute
      await ilrm.connect(initiator).initiateBreachDispute(
        counterparty.address,
        STAKE,
        EVIDENCE_HASH,
        fallback
      );

      // Warp past stake window to resolve
      await time.increase(STAKE_WINDOW + 1);
      await ilrm.enforceTimeout(0);

      // Second dispute within cooldown should require escalated stake (1.5x)
      const balanceBefore = await token.balanceOf(initiator.address);

      await ilrm.connect(initiator).initiateBreachDispute(
        counterparty.address,
        STAKE,
        EVIDENCE_HASH,
        fallback
      );

      const balanceAfter = await token.balanceOf(initiator.address);
      const escalatedStake = (STAKE * 150n) / 100n;  // 1.5x
      expect(balanceBefore - balanceAfter).to.equal(escalatedStake);
    });
  });

  // ============================================================
  // PHASE 2: STAKE SYMMETRY WINDOW (Section 4.2)
  // ============================================================
  describe("Phase 2: Stake Symmetry Window", function () {
    /**
     * ⚠️  CRITICAL: Counterparty must be able to stake within window
     *     Missing this creates a softlock where dispute hangs
     */
    it("should allow counterparty to stake within window", async function () {
      const { ilrm, token, initiator, counterparty, STAKE, EVIDENCE_HASH, fallback } = await loadFixture(deployFixture);

      await ilrm.connect(initiator).initiateBreachDispute(
        counterparty.address,
        STAKE,
        EVIDENCE_HASH,
        fallback
      );

      const balanceBefore = await token.balanceOf(counterparty.address);
      await ilrm.connect(counterparty).depositStake(0);
      const balanceAfter = await token.balanceOf(counterparty.address);

      expect(balanceBefore - balanceAfter).to.equal(STAKE);
    });

    /**
     * Invariant 8: Economic Symmetry by Default
     * Stakes must match exactly
     */
    it("should require symmetric stakes", async function () {
      const { ilrm, initiator, counterparty, STAKE, EVIDENCE_HASH, fallback } = await loadFixture(deployFixture);

      await ilrm.connect(initiator).initiateBreachDispute(
        counterparty.address,
        STAKE,
        EVIDENCE_HASH,
        fallback
      );

      await ilrm.connect(counterparty).depositStake(0);

      const dispute = await ilrm.disputes(0);
      expect(dispute.initiatorStake).to.equal(dispute.counterpartyStake);
    });

    it("should reject stake after window closes", async function () {
      const { ilrm, initiator, counterparty, STAKE, EVIDENCE_HASH, fallback } = await loadFixture(deployFixture);

      await ilrm.connect(initiator).initiateBreachDispute(
        counterparty.address,
        STAKE,
        EVIDENCE_HASH,
        fallback
      );

      // Warp past stake window
      await time.increase(STAKE_WINDOW + 1);

      await expect(ilrm.connect(counterparty).depositStake(0))
        .to.be.revertedWith("Stake window closed");
    });

    it("should reject duplicate staking", async function () {
      const { ilrm, initiator, counterparty, STAKE, EVIDENCE_HASH, fallback } = await loadFixture(deployFixture);

      await ilrm.connect(initiator).initiateBreachDispute(
        counterparty.address,
        STAKE,
        EVIDENCE_HASH,
        fallback
      );

      await ilrm.connect(counterparty).depositStake(0);

      await expect(ilrm.connect(counterparty).depositStake(0))
        .to.be.revertedWith("Already staked");
    });

    /**
     * Invariant 2: Silence Is Always Free
     * Non-participation must not cost the counterparty
     */
    it("should allow counterparty to ignore without cost", async function () {
      const { ilrm, token, initiator, counterparty, STAKE, EVIDENCE_HASH, fallback } = await loadFixture(deployFixture);

      await ilrm.connect(initiator).initiateBreachDispute(
        counterparty.address,
        STAKE,
        EVIDENCE_HASH,
        fallback
      );

      const balanceBefore = await token.balanceOf(counterparty.address);

      // Warp past window and resolve
      await time.increase(STAKE_WINDOW + 1);
      await ilrm.enforceTimeout(0);

      const balanceAfter = await token.balanceOf(counterparty.address);
      expect(balanceAfter).to.equal(balanceBefore);
    });
  });

  // ============================================================
  // PHASE 4: PROPOSAL GENERATION (Section 4.4)
  // ============================================================
  describe("Phase 4: Proposal Generation", function () {
    it("should allow oracle to submit proposal", async function () {
      const { ilrm, oracle, initiator, counterparty, STAKE, EVIDENCE_HASH, fallback } = await loadFixture(deployFixture);

      await ilrm.connect(initiator).initiateBreachDispute(
        counterparty.address,
        STAKE,
        EVIDENCE_HASH,
        fallback
      );
      await ilrm.connect(counterparty).depositStake(0);

      const proposal = '{"type":"split","ratio":"50/50"}';

      await expect(ilrm.connect(oracle).submitLLMProposal(0, proposal, "0x"))
        .to.emit(ilrm, "ProposalSubmitted")
        .withArgs(0, proposal);
    });

    it("should reject proposal from non-oracle", async function () {
      const { ilrm, initiator, counterparty, STAKE, EVIDENCE_HASH, fallback } = await loadFixture(deployFixture);

      await ilrm.connect(initiator).initiateBreachDispute(
        counterparty.address,
        STAKE,
        EVIDENCE_HASH,
        fallback
      );
      await ilrm.connect(counterparty).depositStake(0);

      await expect(ilrm.connect(initiator).submitLLMProposal(0, "proposal", "0x"))
        .to.be.revertedWith("Only oracle");
    });

    /**
     * ⚠️  CRITICAL: Proposal requires both parties staked
     *     Otherwise oracle could submit before counterparty decides
     */
    it("should reject proposal before counterparty stakes", async function () {
      const { ilrm, oracle, initiator, counterparty, STAKE, EVIDENCE_HASH, fallback } = await loadFixture(deployFixture);

      await ilrm.connect(initiator).initiateBreachDispute(
        counterparty.address,
        STAKE,
        EVIDENCE_HASH,
        fallback
      );

      await expect(ilrm.connect(oracle).submitLLMProposal(0, "proposal", "0x"))
        .to.be.revertedWith("Not fully staked");
    });

    it("should reject empty proposal", async function () {
      const { ilrm, oracle, initiator, counterparty, STAKE, EVIDENCE_HASH, fallback } = await loadFixture(deployFixture);

      await ilrm.connect(initiator).initiateBreachDispute(
        counterparty.address,
        STAKE,
        EVIDENCE_HASH,
        fallback
      );
      await ilrm.connect(counterparty).depositStake(0);

      await expect(ilrm.connect(oracle).submitLLMProposal(0, "", "0x"))
        .to.be.revertedWith("Empty proposal");
    });
  });

  // ============================================================
  // PHASE 5: MUTUAL ACCEPTANCE (Section 4.5)
  // ============================================================
  describe("Phase 5: Mutual Acceptance", function () {
    async function setupWithProposal() {
      const fixture = await loadFixture(deployFixture);
      const { ilrm, oracle, initiator, counterparty, STAKE, EVIDENCE_HASH, fallback } = fixture;

      await ilrm.connect(initiator).initiateBreachDispute(
        counterparty.address,
        STAKE,
        EVIDENCE_HASH,
        fallback
      );
      await ilrm.connect(counterparty).depositStake(0);
      await ilrm.connect(oracle).submitLLMProposal(0, '{"proposal":"test"}', "0x");

      return fixture;
    }

    it("should allow initiator to accept", async function () {
      const { ilrm, initiator } = await setupWithProposal();

      await expect(ilrm.connect(initiator).acceptProposal(0))
        .to.emit(ilrm, "AcceptanceSignaled")
        .withArgs(0, initiator.address);
    });

    it("should allow counterparty to accept", async function () {
      const { ilrm, counterparty } = await setupWithProposal();

      await expect(ilrm.connect(counterparty).acceptProposal(0))
        .to.emit(ilrm, "AcceptanceSignaled")
        .withArgs(0, counterparty.address);
    });

    /**
     * ⚠️  CRITICAL: Both parties must accept for resolution
     *     Single acceptance should NOT resolve dispute
     */
    it("should not resolve with single acceptance", async function () {
      const { ilrm, initiator } = await setupWithProposal();

      await ilrm.connect(initiator).acceptProposal(0);

      const dispute = await ilrm.disputes(0);
      expect(dispute.resolved).to.be.false;
    });

    /**
     * ⚠️  CRITICAL: Mutual acceptance returns ALL stakes
     *     This is the "happy path" - no value should be lost
     */
    it("should return full stakes on mutual acceptance", async function () {
      const { ilrm, token, initiator, counterparty, STAKE } = await setupWithProposal();

      const initBalBefore = await token.balanceOf(initiator.address);
      const cpBalBefore = await token.balanceOf(counterparty.address);

      await ilrm.connect(initiator).acceptProposal(0);
      await ilrm.connect(counterparty).acceptProposal(0);

      const initBalAfter = await token.balanceOf(initiator.address);
      const cpBalAfter = await token.balanceOf(counterparty.address);

      expect(initBalAfter - initBalBefore).to.equal(STAKE);
      expect(cpBalAfter - cpBalBefore).to.equal(STAKE);
    });

    it("should mark dispute as resolved with AcceptedProposal outcome", async function () {
      const { ilrm, initiator, counterparty } = await setupWithProposal();

      await ilrm.connect(initiator).acceptProposal(0);
      await ilrm.connect(counterparty).acceptProposal(0);

      const dispute = await ilrm.disputes(0);
      expect(dispute.resolved).to.be.true;
      expect(dispute.outcome).to.equal(1); // AcceptedProposal
    });

    it("should reject acceptance without proposal", async function () {
      const { ilrm, initiator, counterparty, STAKE, EVIDENCE_HASH, fallback } = await loadFixture(deployFixture);

      await ilrm.connect(initiator).initiateBreachDispute(
        counterparty.address,
        STAKE,
        EVIDENCE_HASH,
        fallback
      );
      await ilrm.connect(counterparty).depositStake(0);

      await expect(ilrm.connect(initiator).acceptProposal(0))
        .to.be.revertedWith("No proposal yet");
    });

    it("should reject acceptance from non-party", async function () {
      const { ilrm, third } = await setupWithProposal();

      await expect(ilrm.connect(third).acceptProposal(0))
        .to.be.revertedWith("Not a party");
    });

    it("should reject duplicate acceptance", async function () {
      const { ilrm, initiator } = await setupWithProposal();

      await ilrm.connect(initiator).acceptProposal(0);

      await expect(ilrm.connect(initiator).acceptProposal(0))
        .to.be.revertedWith("Already accepted");
    });
  });

  // ============================================================
  // PHASE 6: COUNTER-PROPOSALS (Section 4.6)
  // ============================================================
  describe("Phase 6: Counter-Proposals", function () {
    async function setupWithProposal() {
      const fixture = await loadFixture(deployFixture);
      const { ilrm, oracle, initiator, counterparty, STAKE, EVIDENCE_HASH, fallback } = fixture;

      await ilrm.connect(initiator).initiateBreachDispute(
        counterparty.address,
        STAKE,
        EVIDENCE_HASH,
        fallback
      );
      await ilrm.connect(counterparty).depositStake(0);
      await ilrm.connect(oracle).submitLLMProposal(0, '{"proposal":"initial"}', "0x");

      return fixture;
    }

    it("should allow counter-proposal with fee", async function () {
      const { ilrm, initiator, EVIDENCE_HASH } = await setupWithProposal();

      const newEvidence = ethers.keccak256(ethers.toUtf8Bytes("new-evidence"));

      await expect(ilrm.connect(initiator).counterPropose(0, newEvidence, { value: COUNTER_FEE_BASE }))
        .to.emit(ilrm, "CounterProposed")
        .withArgs(0, initiator.address, 1);
    });

    /**
     * Invariant 4: Bounded Griefing
     * Counter fees must increase exponentially
     */
    it("should require exponentially increasing fees", async function () {
      const { ilrm, initiator } = await setupWithProposal();

      // Counter 1: 0.01 ETH
      await ilrm.connect(initiator).counterPropose(
        0,
        ethers.keccak256(ethers.toUtf8Bytes("evidence1")),
        { value: COUNTER_FEE_BASE }
      );

      // Counter 2: 0.02 ETH (2x)
      await ilrm.connect(initiator).counterPropose(
        0,
        ethers.keccak256(ethers.toUtf8Bytes("evidence2")),
        { value: COUNTER_FEE_BASE * 2n }
      );

      // Counter 3: 0.04 ETH (4x)
      await ilrm.connect(initiator).counterPropose(
        0,
        ethers.keccak256(ethers.toUtf8Bytes("evidence3")),
        { value: COUNTER_FEE_BASE * 4n }
      );
    });

    it("should reject insufficient counter fee", async function () {
      const { ilrm, initiator } = await setupWithProposal();

      await expect(ilrm.connect(initiator).counterPropose(
        0,
        ethers.keccak256(ethers.toUtf8Bytes("evidence")),
        { value: COUNTER_FEE_BASE / 2n }
      )).to.be.revertedWith("Insufficient counter fee");
    });

    /**
     * Invariant 4: Bounded Griefing
     * Maximum 3 counters per dispute
     */
    it("should enforce maximum counter limit", async function () {
      const { ilrm, initiator } = await setupWithProposal();

      for (let i = 0; i < MAX_COUNTERS; i++) {
        const fee = COUNTER_FEE_BASE * BigInt(1 << i);
        await ilrm.connect(initiator).counterPropose(
          0,
          ethers.keccak256(ethers.toUtf8Bytes(`evidence${i}`)),
          { value: fee }
        );
      }

      await expect(ilrm.connect(initiator).counterPropose(
        0,
        ethers.keccak256(ethers.toUtf8Bytes("overflow")),
        { value: COUNTER_FEE_BASE * 8n }
      )).to.be.revertedWith("Max counters reached");
    });

    it("should reset acceptance flags on counter", async function () {
      const { ilrm, initiator, counterparty } = await setupWithProposal();

      // Initiator accepts
      await ilrm.connect(initiator).acceptProposal(0);

      // Counterparty counters instead
      await ilrm.connect(counterparty).counterPropose(
        0,
        ethers.keccak256(ethers.toUtf8Bytes("counter")),
        { value: COUNTER_FEE_BASE }
      );

      const dispute = await ilrm.disputes(0);
      expect(dispute.initiatorAccepted).to.be.false;
      expect(dispute.counterpartyAccepted).to.be.false;
    });

    it("should extend timeout on counter", async function () {
      const { ilrm, initiator } = await setupWithProposal();

      const disputeBefore = await ilrm.disputes(0);
      const startTimeBefore = disputeBefore.startTime;

      await ilrm.connect(initiator).counterPropose(
        0,
        ethers.keccak256(ethers.toUtf8Bytes("counter")),
        { value: COUNTER_FEE_BASE }
      );

      const disputeAfter = await ilrm.disputes(0);
      expect(disputeAfter.startTime).to.equal(startTimeBefore + BigInt(24 * 60 * 60));
    });
  });

  // ============================================================
  // PHASE 7: TIMEOUT & ENTROPY RESOLUTION (Section 4.7)
  // ============================================================
  describe("Phase 7: Timeout Resolution", function () {
    /**
     * ⚠️  CRITICAL: Timeout with burn returns partial stakes
     *     This is the "entropy tax" - funds must not be lost entirely
     */
    it("should burn 50% and return remainder symmetrically", async function () {
      const { ilrm, token, oracle, initiator, counterparty, STAKE, EVIDENCE_HASH, fallback } = await loadFixture(deployFixture);

      await ilrm.connect(initiator).initiateBreachDispute(
        counterparty.address,
        STAKE,
        EVIDENCE_HASH,
        fallback
      );
      await ilrm.connect(counterparty).depositStake(0);
      await ilrm.connect(oracle).submitLLMProposal(0, '{"proposal":"test"}', "0x");

      const initBalBefore = await token.balanceOf(initiator.address);
      const cpBalBefore = await token.balanceOf(counterparty.address);

      // Warp past resolution timeout
      await time.increase(RESOLUTION_TIMEOUT + 1);
      await ilrm.enforceTimeout(0);

      const initBalAfter = await token.balanceOf(initiator.address);
      const cpBalAfter = await token.balanceOf(counterparty.address);

      // Each should receive 25% of total (50% burned, 50% split)
      const expectedReturn = STAKE / 2n;
      expect(initBalAfter - initBalBefore).to.equal(expectedReturn);
      expect(cpBalAfter - cpBalBefore).to.equal(expectedReturn);
    });

    it("should emit StakesBurned event", async function () {
      const { ilrm, oracle, initiator, counterparty, STAKE, EVIDENCE_HASH, fallback } = await loadFixture(deployFixture);

      await ilrm.connect(initiator).initiateBreachDispute(
        counterparty.address,
        STAKE,
        EVIDENCE_HASH,
        fallback
      );
      await ilrm.connect(counterparty).depositStake(0);
      await ilrm.connect(oracle).submitLLMProposal(0, '{"proposal":"test"}', "0x");

      await time.increase(RESOLUTION_TIMEOUT + 1);

      const burnAmount = STAKE; // 50% of 2*STAKE
      await expect(ilrm.enforceTimeout(0))
        .to.emit(ilrm, "StakesBurned")
        .withArgs(0, burnAmount);
    });

    it("should apply fallback license on timeout", async function () {
      const { ilrm, registry, oracle, initiator, counterparty, STAKE, EVIDENCE_HASH, fallback } = await loadFixture(deployFixture);

      await ilrm.connect(initiator).initiateBreachDispute(
        counterparty.address,
        STAKE,
        EVIDENCE_HASH,
        fallback
      );
      await ilrm.connect(counterparty).depositStake(0);
      await ilrm.connect(oracle).submitLLMProposal(0, '{"proposal":"test"}', "0x");

      await time.increase(RESOLUTION_TIMEOUT + 1);
      await ilrm.enforceTimeout(0);

      // Verify fallback was applied (mock stores it)
      const appliedFallback = await registry.appliedFallbacks(0);
      expect(appliedFallback).to.equal(fallback.termsHash);
    });

    it("should reject timeout before deadline", async function () {
      const { ilrm, oracle, initiator, counterparty, STAKE, EVIDENCE_HASH, fallback } = await loadFixture(deployFixture);

      await ilrm.connect(initiator).initiateBreachDispute(
        counterparty.address,
        STAKE,
        EVIDENCE_HASH,
        fallback
      );
      await ilrm.connect(counterparty).depositStake(0);
      await ilrm.connect(oracle).submitLLMProposal(0, '{"proposal":"test"}', "0x");

      await expect(ilrm.enforceTimeout(0))
        .to.be.revertedWith("Not timed out");
    });

    /**
     * Non-participation timeout (counterparty never staked)
     */
    it("should handle non-participation timeout correctly", async function () {
      const { ilrm, token, initiator, counterparty, STAKE, EVIDENCE_HASH, fallback } = await loadFixture(deployFixture);

      await ilrm.connect(initiator).initiateBreachDispute(
        counterparty.address,
        STAKE,
        EVIDENCE_HASH,
        fallback
      );

      const balanceBefore = await token.balanceOf(initiator.address);

      // Warp past stake window (not resolution timeout)
      await time.increase(STAKE_WINDOW + 1);
      await ilrm.enforceTimeout(0);

      // Initiator gets stake back
      const balanceAfter = await token.balanceOf(initiator.address);
      expect(balanceAfter).to.be.gte(balanceBefore + STAKE);

      const dispute = await ilrm.disputes(0);
      expect(dispute.outcome).to.equal(3); // DefaultLicenseApplied
    });
  });

  // ============================================================
  // VOLUNTARY REQUESTS (Non-adversarial flow)
  // ============================================================
  describe("Voluntary Requests", function () {
    /**
     * Invariant 2: Silence Is Always Free
     * Voluntary requests burn fee; counterparty ignores for free
     */
    it("should burn fee immediately on voluntary request", async function () {
      const { ilrm, initiator, counterparty, EVIDENCE_HASH } = await loadFixture(deployFixture);

      const balanceBefore = await ethers.provider.getBalance(initiator.address);

      const tx = await ilrm.connect(initiator).initiateVoluntaryRequest(
        counterparty.address,
        EVIDENCE_HASH,
        { value: COUNTER_FEE_BASE }
      );
      const receipt = await tx.wait();
      const gasUsed = receipt.gasUsed * receipt.gasPrice;

      const balanceAfter = await ethers.provider.getBalance(initiator.address);

      // Balance decreased by fee + gas
      expect(balanceBefore - balanceAfter).to.equal(COUNTER_FEE_BASE + gasUsed);
    });

    it("should reject voluntary request with insufficient fee", async function () {
      const { ilrm, initiator, counterparty, EVIDENCE_HASH } = await loadFixture(deployFixture);

      await expect(ilrm.connect(initiator).initiateVoluntaryRequest(
        counterparty.address,
        EVIDENCE_HASH,
        { value: COUNTER_FEE_BASE / 2n }
      )).to.be.revertedWith("Insufficient burn fee");
    });
  });
});
