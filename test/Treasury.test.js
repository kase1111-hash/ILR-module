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
const { time, loadFixture, setBalance } = require("@nomicfoundation/hardhat-network-helpers");

describe("Treasury Tests", function () {
  const MAX_PER_DISPUTE = ethers.parseEther("5");
  const MAX_PER_PARTICIPANT = ethers.parseEther("20");
  const WINDOW_DURATION = 30 * 24 * 60 * 60; // 30 days
  const RESOLUTION_TIMEOUT = 7 * 24 * 60 * 60;

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

    // Set ILRM in Treasury, and let ILRM draw stake subsidies from the Treasury
    await treasury.setILRM(ilrm.target);
    await ilrm.setSubsidyTreasury(treasury.target);

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

  // Helper: send transactions from the ILRM contract's address (Treasury.fundStakeSubsidy is ILRM-only)
  async function impersonateILRM(ilrm) {
    await setBalance(ilrm.target, ethers.parseEther("10"));
    return ethers.getImpersonatedSigner(ilrm.target);
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
     *     Initiators are attackers and must not be subsidized.
     *     Subsidies are escrowed co-stakes in ILRM - they never reach the counterparty's wallet.
     */
    it("should grant subsidy to eligible counterparty", async function () {
      const { treasury, token, ilrm, initiator, counterparty, STAKE, EVIDENCE_HASH, fallback } = await loadFixture(deployFixture);

      const disputeId = await createDispute(ilrm, initiator, counterparty, STAKE, EVIDENCE_HASH, fallback);

      const walletBefore = await token.balanceOf(counterparty.address);
      const treasuryBefore = await token.balanceOf(treasury.target);

      await ilrm.connect(counterparty).depositStakeWithSubsidy(disputeId, STAKE, ethers.MaxUint256);

      // Fully subsidized: the wallet neither grows nor pays anything
      expect(await token.balanceOf(counterparty.address)).to.equal(walletBefore);
      expect((await ilrm.disputes(disputeId)).counterpartyStake).to.equal(STAKE);
      const [funder, amount] = await ilrm.stakeSubsidy(disputeId);
      expect(funder).to.equal(treasury.target);
      expect(amount).to.equal(STAKE);
      expect(treasuryBefore - await token.balanceOf(treasury.target)).to.equal(STAKE);
    });

    it("should emit SubsidyFunded event", async function () {
      const { treasury, ilrm, initiator, counterparty, STAKE, EVIDENCE_HASH, fallback } = await loadFixture(deployFixture);

      const disputeId = await createDispute(ilrm, initiator, counterparty, STAKE, EVIDENCE_HASH, fallback);

      await expect(ilrm.connect(counterparty).depositStakeWithSubsidy(disputeId, STAKE, ethers.MaxUint256))
        .to.emit(treasury, "SubsidyFunded")
        .withArgs(counterparty.address, disputeId, STAKE)
        .and.to.emit(ilrm, "StakeSubsidized")
        .withArgs(disputeId, counterparty.address, treasury.target, STAKE);
    });

    /**
     * CRITICAL: Same dispute cannot be subsidized twice
     *     Prevents Sybil attack via multiple addresses
     */
    it("should prevent double-subsidy per dispute", async function () {
      const { treasury, ilrm, initiator, counterparty, attacker, STAKE, EVIDENCE_HASH, fallback } = await loadFixture(deployFixture);

      const disputeId = await createDispute(ilrm, initiator, counterparty, STAKE, EVIDENCE_HASH, fallback);

      await ilrm.connect(counterparty).depositStakeWithSubsidy(disputeId, STAKE, ethers.MaxUint256);

      // Second subsidized stake on the same dispute - should fail in ILRM
      await expect(ilrm.connect(counterparty).depositStakeWithSubsidy(disputeId, STAKE, ethers.MaxUint256))
        .to.be.revertedWith("Already staked");

      // Same dispute, different address - should fail
      await expect(ilrm.connect(attacker).depositStakeWithSubsidy(disputeId, STAKE, ethers.MaxUint256))
        .to.be.revertedWith("Not counterparty");

      // Even ILRM itself cannot get a second subsidy for the dispute
      const ilrmSigner = await impersonateILRM(ilrm);
      await expect(treasury.connect(ilrmSigner).fundStakeSubsidy(disputeId, counterparty.address, STAKE))
        .to.be.revertedWithCustomError(treasury, "DisputeAlreadySubsidized");
    });

    it("should cap subsidy at maxPerDispute", async function () {
      const { treasury, token, ilrm, initiator, counterparty, EVIDENCE_HASH, fallback } = await loadFixture(deployFixture);

      const bigStake = ethers.parseEther("100"); // Way above cap
      const disputeId = await createDispute(ilrm, initiator, counterparty, bigStake, EVIDENCE_HASH, fallback);

      const walletBefore = await token.balanceOf(counterparty.address);
      const treasuryBefore = await token.balanceOf(treasury.target);
      await ilrm.connect(counterparty).depositStakeWithSubsidy(disputeId, bigStake, ethers.MaxUint256);

      // Subsidy is maxPerDispute (5); the defender tops up the remaining 95
      const [, amount] = await ilrm.stakeSubsidy(disputeId);
      expect(amount).to.equal(MAX_PER_DISPUTE);
      expect(walletBefore - await token.balanceOf(counterparty.address)).to.equal(bigStake - MAX_PER_DISPUTE);
      expect(treasuryBefore - await token.balanceOf(treasury.target)).to.equal(MAX_PER_DISPUTE);
      expect((await ilrm.disputes(disputeId)).counterpartyStake).to.equal(bigStake);
    });

    it("should enforce rolling window cap per participant", async function () {
      const { treasury, ilrm, initiator, counterparty, EVIDENCE_HASH, fallback } = await loadFixture(deployFixture);

      const stake = ethers.parseEther("5");

      // Create 4 separate disputes and stake each with a subsidy
      for (let i = 0; i < 4; i++) {
        const disputeId = await createDispute(ilrm, initiator, counterparty, stake, EVIDENCE_HASH, fallback);
        await ilrm.connect(counterparty).depositStakeWithSubsidy(disputeId, stake, ethers.MaxUint256);
      }

      // 4 * 5 = 20 ETH = MAX_PER_PARTICIPANT, next should fail (the error bubbles up from the treasury)
      const disputeId5 = await createDispute(ilrm, initiator, counterparty, stake, EVIDENCE_HASH, fallback);
      await expect(ilrm.connect(counterparty).depositStakeWithSubsidy(disputeId5, stake, ethers.MaxUint256))
        .to.be.revertedWithCustomError(treasury, "NoSubsidyAvailable");
    });

    it("should reset rolling window after expiry", async function () {
      const { treasury, token, ilrm, initiator, counterparty, EVIDENCE_HASH, fallback } = await loadFixture(deployFixture);

      // Use up allowance (each subsidy is capped at MAX_PER_DISPUTE, so it takes several disputes)
      for (let i = 0n; i < MAX_PER_PARTICIPANT / MAX_PER_DISPUTE; i++) {
        const disputeId = await createDispute(ilrm, initiator, counterparty, MAX_PER_DISPUTE, EVIDENCE_HASH, fallback);
        await ilrm.connect(counterparty).depositStakeWithSubsidy(disputeId, MAX_PER_DISPUTE, ethers.MaxUint256);
      }

      // Should fail now
      const disputeId2 = await createDispute(ilrm, initiator, counterparty, ethers.parseEther("1"), EVIDENCE_HASH, fallback);
      await expect(ilrm.connect(counterparty).depositStakeWithSubsidy(disputeId2, ethers.parseEther("1"), ethers.MaxUint256))
        .to.be.revertedWithCustomError(treasury, "NoSubsidyAvailable");

      // Warp past window
      await time.increase(WINDOW_DURATION + 1);

      // Should work again (new dispute since IDs are used)
      const disputeId3 = await createDispute(ilrm, initiator, counterparty, ethers.parseEther("5"), EVIDENCE_HASH, fallback);
      const walletBefore = await token.balanceOf(counterparty.address);
      const treasuryBefore = await token.balanceOf(treasury.target);
      await ilrm.connect(counterparty).depositStakeWithSubsidy(disputeId3, ethers.parseEther("5"), ethers.MaxUint256);

      const [, amount] = await ilrm.stakeSubsidy(disputeId3);
      expect(amount).to.equal(ethers.parseEther("5"));
      expect(await token.balanceOf(counterparty.address)).to.equal(walletBefore);
      expect(treasuryBefore - await token.balanceOf(treasury.target)).to.equal(ethers.parseEther("5"));
    });

    it("should revert a direct fundStakeSubsidy call with NotILRM", async function () {
      const { treasury, ilrm, initiator, counterparty, attacker, STAKE, EVIDENCE_HASH, fallback } = await loadFixture(deployFixture);

      const disputeId = await createDispute(ilrm, initiator, counterparty, STAKE, EVIDENCE_HASH, fallback);

      await expect(treasury.connect(counterparty).fundStakeSubsidy(disputeId, counterparty.address, STAKE))
        .to.be.revertedWithCustomError(treasury, "NotILRM")
        .withArgs(counterparty.address);
      await expect(treasury.connect(attacker).fundStakeSubsidy(disputeId, attacker.address, STAKE))
        .to.be.revertedWithCustomError(treasury, "NotILRM")
        .withArgs(attacker.address);
      expect(await treasury.disputeSubsidized(disputeId)).to.be.false;
    });

    it("should return the pro-rata share to the Treasury on timeout", async function () {
      const { treasury, token, ilrm, initiator, counterparty, EVIDENCE_HASH, fallback } = await loadFixture(deployFixture);

      // S = 8, s = 5 (maxPerDispute), defender tops up 3
      const stake = ethers.parseEther("8");
      const disputeId = await createDispute(ilrm, initiator, counterparty, stake, EVIDENCE_HASH, fallback);
      const treasuryBefore = await token.balanceOf(treasury.target);
      await ilrm.connect(counterparty).depositStakeWithSubsidy(disputeId, stake, ethers.MaxUint256);
      const walletAfterStake = await token.balanceOf(counterparty.address);

      await time.increase(RESOLUTION_TIMEOUT + 1);

      // 8 burned, initiator gets 4; the counterparty side's 4 is split 5:3 => treasury 2.5, defender 1.5
      await expect(ilrm.enforceTimeout(disputeId))
        .to.emit(ilrm, "SubsidyReturned")
        .withArgs(disputeId, treasury.target, ethers.parseEther("2.5"));

      expect(await token.balanceOf(treasury.target))
        .to.equal(treasuryBefore - MAX_PER_DISPUTE + ethers.parseEther("2.5"));
      expect(await token.balanceOf(counterparty.address) - walletAfterStake).to.equal(ethers.parseEther("1.5"));
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

      await expect(ilrm.connect(attacker).depositStakeWithSubsidy(disputeId, STAKE, ethers.MaxUint256))
        .to.be.revertedWithCustomError(treasury, "ParticipantFlaggedForAbuse");
    });

    it("should allow subsidy just below threshold", async function () {
      const { treasury, ilrm, initiator, counterparty, owner, STAKE, EVIDENCE_HASH, fallback } = await loadFixture(deployFixture);

      await treasury.connect(owner).setHarassmentScore(counterparty.address, 49);

      const disputeId = await createDispute(ilrm, initiator, counterparty, STAKE, EVIDENCE_HASH, fallback);

      await expect(ilrm.connect(counterparty).depositStakeWithSubsidy(disputeId, STAKE, ethers.MaxUint256))
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
      // Asking for 5 against a stake of 3 now grants (and charges) only 3
      await ilrm.connect(counterparty).depositStakeWithSubsidy(disputeId, ethers.parseEther("5"), ethers.MaxUint256);

      expect(await treasury.getRemainingAllowance(counterparty.address))
        .to.equal(MAX_PER_PARTICIPANT - STAKE);
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
