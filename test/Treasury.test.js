/**
 * Treasury Tests
 *
 * Tests the NatLangChain Treasury system from Treasury.md:
 * - Inflows (burns, counter-fees)
 * - Subsidy eligibility and distribution
 * - Anti-Sybil protections
 * - Rolling window caps
 * - Harassment score management
 *
 * CRITICAL: These tests verify that:
 *     1. Only defenders (counterparties) can receive subsidies
 *     2. Harassers cannot drain the treasury
 *     3. Subsidies respect caps and windows
 */

const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time, loadFixture } = require("@nomicfoundation/hardhat-network-helpers");

describe("Treasury Tests", function () {
  const MAX_PER_DISPUTE = ethers.parseEther("5");
  const MAX_PER_PARTICIPANT = ethers.parseEther("20");
  const WINDOW_DURATION = 30 * 24 * 60 * 60; // 30 days

  async function deployFixture() {
    const [owner, oracleAddr, initiator, counterparty, attacker] = await ethers.getSigners();

    const MockToken = await ethers.getContractFactory("MockToken");
    const token = await MockToken.deploy();

    const MockRegistry = await ethers.getContractFactory("MockAssetRegistry");
    const registry = await MockRegistry.deploy();

    // Deploy real ILRM so Treasury can query dispute state
    const ILRM = await ethers.getContractFactory("ILRM");
    const ilrm = await ILRM.deploy(token.target, oracleAddr.address, registry.target);

    const Treasury = await ethers.getContractFactory("NatLangChainTreasury");
    const treasury = await Treasury.deploy(
      token.target,
      MAX_PER_DISPUTE,
      MAX_PER_PARTICIPANT,
      WINDOW_DURATION
    );

    // Set ILRM in Treasury
    await treasury.setILRM(ilrm.target);

    // Fund treasury
    await token.mint(owner.address, ethers.parseEther("1000"));
    await token.approve(treasury.target, ethers.MaxUint256);
    await treasury.deposit(ethers.parseEther("100"), "initial-funding");

    // Fund and approve initiator for dispute creation
    await token.mint(initiator.address, ethers.parseEther("1000"));
    await token.connect(initiator).approve(ilrm.target, ethers.MaxUint256);

    // Approve counterparty for staking
    await token.mint(counterparty.address, ethers.parseEther("1000"));
    await token.connect(counterparty).approve(ilrm.target, ethers.MaxUint256);

    const STAKE = ethers.parseEther("3");
    const EVIDENCE_HASH = ethers.ZeroHash;
    const fallback = {
      termsHash: ethers.ZeroHash,
      termDuration: 365 * 24 * 60 * 60,
      royaltyCapBps: 500,
      nonExclusive: true
    };

    return { treasury, token, ilrm, owner, oracleAddr, initiator, counterparty, attacker, STAKE, EVIDENCE_HASH, fallback };
  }

  // Helper: create a dispute and return its ID
  async function createDispute(ilrm, initiator, counterparty, stake, evidenceHash, fallback) {
    const tx = await ilrm.connect(initiator).initiateBreachDispute(
      counterparty.address, stake, evidenceHash, fallback
    );
    const receipt = await tx.wait();
    // Dispute IDs are sequential starting from 0
    const count = await ilrm.disputeCounter();
    return Number(count) - 1;
  }

  // ============================================================
  // INFLOW TESTS
  // ============================================================
  describe("Treasury Inflows", function () {
    it("should accept deposits with reason", async function () {
      const { treasury, token, owner } = await loadFixture(deployFixture);

      await expect(treasury.deposit(ethers.parseEther("10"), "test-deposit"))
        .to.emit(treasury, "TreasuryReceived")
        .withArgs(owner.address, ethers.parseEther("10"), "test-deposit");
    });

    it("should accept ETH via receive", async function () {
      const { treasury, owner } = await loadFixture(deployFixture);

      await expect(owner.sendTransaction({
        to: treasury.target,
        value: ethers.parseEther("1")
      }))
        .to.emit(treasury, "TreasuryReceived")
        .withArgs(owner.address, ethers.parseEther("1"), "eth");
    });

    it("should only allow ILRM to call depositBurn", async function () {
      const { treasury, token, owner, ilrm } = await loadFixture(deployFixture);

      // Non-ILRM should fail
      await expect(treasury.connect(owner).depositBurn(ethers.parseEther("1")))
        .to.be.revertedWithCustomError(treasury, "NotILRM");
    });

    it("should reject zero deposits", async function () {
      const { treasury } = await loadFixture(deployFixture);

      await expect(treasury.deposit(0, "zero"))
        .to.be.revertedWithCustomError(treasury, "ZeroAmount");
    });
  });

  // ============================================================
  // SUBSIDY TESTS
  // ============================================================
  describe("Subsidy System", function () {
    /**
     * CRITICAL: Only counterparties should receive subsidies
     *     Initiators are attackers and must not be subsidized
     */
    it("should grant subsidy to eligible counterparty", async function () {
      const { treasury, token, ilrm, initiator, counterparty, STAKE, EVIDENCE_HASH, fallback } = await loadFixture(deployFixture);

      const disputeId = await createDispute(ilrm, initiator, counterparty, STAKE, EVIDENCE_HASH, fallback);

      const balanceBefore = await token.balanceOf(counterparty.address);

      await treasury.connect(counterparty).requestSubsidy(disputeId, STAKE, counterparty.address);

      const balanceAfter = await token.balanceOf(counterparty.address);
      expect(balanceAfter - balanceBefore).to.equal(STAKE);
    });

    it("should emit SubsidyFunded event", async function () {
      const { treasury, ilrm, initiator, counterparty, STAKE, EVIDENCE_HASH, fallback } = await loadFixture(deployFixture);

      const disputeId = await createDispute(ilrm, initiator, counterparty, STAKE, EVIDENCE_HASH, fallback);

      await expect(treasury.connect(counterparty).requestSubsidy(disputeId, STAKE, counterparty.address))
        .to.emit(treasury, "SubsidyFunded")
        .withArgs(counterparty.address, disputeId, STAKE);
    });

    /**
     * CRITICAL: Same dispute cannot be subsidized twice
     *     Prevents Sybil attack via multiple addresses
     */
    it("should prevent double-subsidy per dispute", async function () {
      const { treasury, ilrm, initiator, counterparty, attacker, STAKE, EVIDENCE_HASH, fallback } = await loadFixture(deployFixture);

      const disputeId = await createDispute(ilrm, initiator, counterparty, STAKE, EVIDENCE_HASH, fallback);

      await treasury.connect(counterparty).requestSubsidy(disputeId, STAKE, counterparty.address);

      // Same dispute, different address - should fail
      await expect(treasury.connect(attacker).requestSubsidy(disputeId, STAKE, attacker.address))
        .to.be.revertedWithCustomError(treasury, "DisputeAlreadySubsidized");
    });

    it("should cap subsidy at maxPerDispute", async function () {
      const { treasury, token, ilrm, initiator, counterparty, EVIDENCE_HASH, fallback } = await loadFixture(deployFixture);

      const bigStake = ethers.parseEther("100"); // Way above cap
      const disputeId = await createDispute(ilrm, initiator, counterparty, bigStake, EVIDENCE_HASH, fallback);

      const balanceBefore = await token.balanceOf(counterparty.address);
      await treasury.connect(counterparty).requestSubsidy(disputeId, bigStake, counterparty.address);
      const balanceAfter = await token.balanceOf(counterparty.address);

      // Should receive maxPerDispute, not full amount
      expect(balanceAfter - balanceBefore).to.equal(MAX_PER_DISPUTE);
    });

    it("should enforce rolling window cap per participant", async function () {
      const { treasury, token, ilrm, initiator, counterparty, EVIDENCE_HASH, fallback } = await loadFixture(deployFixture);

      const stake = ethers.parseEther("5");

      // Create 4 separate disputes and request subsidies
      for (let i = 0; i < 4; i++) {
        const disputeId = await createDispute(ilrm, initiator, counterparty, stake, EVIDENCE_HASH, fallback);
        await treasury.connect(counterparty).requestSubsidy(disputeId, stake, counterparty.address);
      }

      // 4 * 5 = 20 ETH = MAX_PER_PARTICIPANT, next should fail
      const disputeId5 = await createDispute(ilrm, initiator, counterparty, stake, EVIDENCE_HASH, fallback);
      await expect(treasury.connect(counterparty).requestSubsidy(disputeId5, stake, counterparty.address))
        .to.be.revertedWithCustomError(treasury, "NoSubsidyAvailable");
    });

    it("should reset rolling window after expiry", async function () {
      const { treasury, token, ilrm, initiator, counterparty, EVIDENCE_HASH, fallback } = await loadFixture(deployFixture);

      // Use up allowance
      const disputeId1 = await createDispute(ilrm, initiator, counterparty, MAX_PER_PARTICIPANT, EVIDENCE_HASH, fallback);
      await treasury.connect(counterparty).requestSubsidy(disputeId1, MAX_PER_PARTICIPANT, counterparty.address);

      // Should fail now
      const disputeId2 = await createDispute(ilrm, initiator, counterparty, ethers.parseEther("1"), EVIDENCE_HASH, fallback);
      await expect(treasury.connect(counterparty).requestSubsidy(disputeId2, ethers.parseEther("1"), counterparty.address))
        .to.be.revertedWithCustomError(treasury, "NoSubsidyAvailable");

      // Warp past window
      await time.increase(WINDOW_DURATION + 1);

      // Should work again (new dispute since IDs are used)
      const disputeId3 = await createDispute(ilrm, initiator, counterparty, ethers.parseEther("5"), EVIDENCE_HASH, fallback);
      const balanceBefore = await token.balanceOf(counterparty.address);
      await treasury.connect(counterparty).requestSubsidy(disputeId3, ethers.parseEther("5"), counterparty.address);
      const balanceAfter = await token.balanceOf(counterparty.address);

      expect(balanceAfter - balanceBefore).to.equal(ethers.parseEther("5"));
    });
  });

  // ============================================================
  // HARASSMENT SCORE TESTS
  // ============================================================
  describe("Harassment Score System", function () {
    /**
     * CRITICAL: Flagged participants cannot receive subsidies
     *     This prevents abusers from benefiting
     */
    it("should reject subsidy for flagged participants", async function () {
      const { treasury, ilrm, initiator, attacker, owner, STAKE, EVIDENCE_HASH, fallback } = await loadFixture(deployFixture);

      // Flag the attacker (score >= 50)
      await treasury.connect(owner).setHarassmentScore(attacker.address, 50);

      // Create dispute with attacker as counterparty
      const disputeId = await createDispute(ilrm, initiator, attacker, STAKE, EVIDENCE_HASH, fallback);

      await expect(treasury.connect(attacker).requestSubsidy(disputeId, STAKE, attacker.address))
        .to.be.revertedWithCustomError(treasury, "ParticipantFlaggedForAbuse");
    });

    it("should allow subsidy just below threshold", async function () {
      const { treasury, ilrm, initiator, counterparty, owner, STAKE, EVIDENCE_HASH, fallback } = await loadFixture(deployFixture);

      await treasury.connect(owner).setHarassmentScore(counterparty.address, 49);

      const disputeId = await createDispute(ilrm, initiator, counterparty, STAKE, EVIDENCE_HASH, fallback);

      await expect(treasury.connect(counterparty).requestSubsidy(disputeId, STAKE, counterparty.address))
        .to.emit(treasury, "SubsidyFunded");
    });

    it("should only allow ILRM to update harassment score via updateHarassmentScore", async function () {
      const { treasury, owner, ilrm, counterparty } = await loadFixture(deployFixture);

      await expect(treasury.connect(owner).updateHarassmentScore(counterparty.address, 10))
        .to.be.revertedWithCustomError(treasury, "NotILRM");
    });

    it("should cap harassment score at 100", async function () {
      const { treasury, owner, counterparty } = await loadFixture(deployFixture);

      await treasury.connect(owner).setHarassmentScore(counterparty.address, 150);

      const score = await treasury.harassmentScore(counterparty.address);
      expect(score).to.equal(100);
    });

    it("should allow owner to set harassment score", async function () {
      const { treasury, owner, counterparty, attacker } = await loadFixture(deployFixture);

      await treasury.connect(owner).setHarassmentScore(counterparty.address, 10);
      await treasury.connect(owner).setHarassmentScore(attacker.address, 60);

      expect(await treasury.harassmentScore(counterparty.address)).to.equal(10);
      expect(await treasury.harassmentScore(attacker.address)).to.equal(60);
    });
  });

  // ============================================================
  // VIEW FUNCTIONS
  // ============================================================
  describe("View Functions", function () {
    it("should report correct balance", async function () {
      const { treasury } = await loadFixture(deployFixture);

      expect(await treasury.balance()).to.equal(ethers.parseEther("100"));
    });

    it("should calculate subsidy correctly", async function () {
      const { treasury, counterparty } = await loadFixture(deployFixture);

      const [amount, eligible] = await treasury.calculateSubsidy(
        1,
        ethers.parseEther("3"),
        counterparty.address
      );

      expect(amount).to.equal(ethers.parseEther("3"));
      expect(eligible).to.be.true;
    });

    it("should report remaining allowance", async function () {
      const { treasury, ilrm, initiator, counterparty, STAKE, EVIDENCE_HASH, fallback } = await loadFixture(deployFixture);

      expect(await treasury.getRemainingAllowance(counterparty.address))
        .to.equal(MAX_PER_PARTICIPANT);

      const disputeId = await createDispute(ilrm, initiator, counterparty, STAKE, EVIDENCE_HASH, fallback);
      await treasury.connect(counterparty).requestSubsidy(disputeId, ethers.parseEther("5"), counterparty.address);

      expect(await treasury.getRemainingAllowance(counterparty.address))
        .to.equal(MAX_PER_PARTICIPANT - ethers.parseEther("5"));
    });

    it("should check eligibility based on score", async function () {
      const { treasury, owner, counterparty, attacker } = await loadFixture(deployFixture);

      expect(await treasury.isEligible(counterparty.address)).to.be.true;

      await treasury.connect(owner).setHarassmentScore(attacker.address, 50);
      expect(await treasury.isEligible(attacker.address)).to.be.false;
    });
  });

  // ============================================================
  // ADMIN FUNCTIONS
  // ============================================================
  describe("Admin Functions", function () {
    it("should allow owner to update caps", async function () {
      const { treasury, owner } = await loadFixture(deployFixture);

      await expect(treasury.connect(owner).updateCaps(
        ethers.parseEther("10"),
        ethers.parseEther("50"),
        60 * 24 * 60 * 60
      ))
        .to.emit(treasury, "CapsUpdated")
        .withArgs(
          ethers.parseEther("10"),
          ethers.parseEther("50"),
          60 * 24 * 60 * 60
        );
    });

    it("should allow owner to set min reserve", async function () {
      const { treasury, owner, counterparty } = await loadFixture(deployFixture);

      // Set min reserve to 90 ETH (treasury has 100)
      await treasury.connect(owner).setMinReserve(ethers.parseEther("90"));

      // Should only be able to subsidize up to 10 ETH
      const [amount, ] = await treasury.calculateSubsidy(
        1,
        ethers.parseEther("20"),
        counterparty.address
      );

      expect(amount).to.equal(ethers.parseEther("5")); // Capped by maxPerDispute
    });

    it("should allow emergency withdrawal", async function () {
      const { treasury, token, owner, counterparty } = await loadFixture(deployFixture);

      const balanceBefore = await token.balanceOf(counterparty.address);

      await treasury.connect(owner).emergencyWithdraw(
        counterparty.address,
        ethers.parseEther("10")
      );

      const balanceAfter = await token.balanceOf(counterparty.address);
      expect(balanceAfter - balanceBefore).to.equal(ethers.parseEther("10"));
    });
  });
});
