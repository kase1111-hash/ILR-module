/**
 * Treasury / initiator-incentive follow-ups (ethers v6 ABI):
 * - depositStakeWithSubsidy(disputeId, maxSubsidy, maxTopUp) slippage bound
 * - capped non-participation initiator incentive (InitiatorIncentivePaid, setInitiatorIncentiveCaps)
 * - Treasury subsidy records keyed per (ILRM, disputeId)
 */

const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time, loadFixture } = require("@nomicfoundation/hardhat-network-helpers");

describe("Treasury follow-ups", function () {
  const MAX_PER_DISPUTE = ethers.parseEther("5");
  const MAX_PER_PARTICIPANT = ethers.parseEther("20");
  const WINDOW_DURATION = 30 * 24 * 60 * 60;
  const STAKE_WINDOW = 3 * 24 * 60 * 60;
  const DAY = 24 * 60 * 60;
  const FALLBACK = {
    termsHash: ethers.ZeroHash,
    termDuration: 365 * DAY,
    royaltyCapBps: 500,
    nonExclusive: true
  };

  async function deployFixture() {
    const [owner, oracleAddr, initiator, counterparty, attacker, other] = await ethers.getSigners();

    const token = await (await ethers.getContractFactory("MockToken")).deploy();
    const registry = await (await ethers.getContractFactory("MockAssetRegistry")).deploy();
    const ILRM = await ethers.getContractFactory("ILRM");
    const ilrm = await ILRM.deploy(token.target, oracleAddr.address, registry.target);
    const treasury = await (await ethers.getContractFactory("NatLangChainTreasury")).deploy(
      token.target,
      MAX_PER_DISPUTE,
      MAX_PER_PARTICIPANT,
      WINDOW_DURATION
    );
    await treasury.setILRM(ilrm.target);
    await ilrm.setSubsidyTreasury(treasury.target);

    await token.mint(treasury.target, ethers.parseEther("100"));
    for (const s of [owner, initiator, counterparty, other]) {
      await token.mint(s.address, ethers.parseEther("10000"));
      await token.connect(s).approve(ilrm.target, ethers.MaxUint256);
    }

    return { ILRM, token, registry, ilrm, treasury, owner, oracleAddr, initiator, counterparty, attacker, other };
  }

  async function openDispute(ilrm, initiator, counterparty, stake) {
    await ilrm.connect(initiator).initiateBreachDispute(counterparty.address, stake, ethers.ZeroHash, FALLBACK);
    return (await ilrm.disputeCounter()) - 1n;
  }

  it("reverts with 'Top-up exceeds max' when the grant shrinks after the preview", async function () {
    const { ilrm, treasury, token, initiator, counterparty } = await loadFixture(deployFixture);
    const stake = ethers.parseEther("5");
    const id = await openDispute(ilrm, initiator, counterparty, stake);

    // Preview: a full subsidy, so the defender bounds its top-up at 0 (it has an unlimited allowance)
    const [preview] = await treasury.calculateSubsidy(id, stake, counterparty.address);
    expect(preview).to.equal(stake);
    const maxTopUp = stake - preview;

    // The grant shrinks before inclusion (here: the owner lowers the per-dispute cap)
    await treasury.updateCaps(ethers.parseEther("1"), MAX_PER_PARTICIPANT, WINDOW_DURATION);

    const walletBefore = await token.balanceOf(counterparty.address);
    await expect(
      ilrm.connect(counterparty).depositStakeWithSubsidy(id, stake, maxTopUp)
    ).to.be.revertedWith("Top-up exceeds max");
    expect(await token.balanceOf(counterparty.address)).to.equal(walletBefore);
    expect(await treasury.disputeSubsidized(id)).to.equal(false);
    expect((await ilrm.disputes(id)).counterpartyStake).to.equal(0n);

    // With a bound that covers the smaller grant it succeeds, charging exactly stake - grant
    await ilrm.connect(counterparty).depositStakeWithSubsidy(id, stake, ethers.parseEther("4"));
    expect(walletBefore - await token.balanceOf(counterparty.address)).to.equal(ethers.parseEther("4"));
  });

  it("caps the non-participation initiator incentive and emits InitiatorIncentivePaid", async function () {
    const { ilrm, token, initiator, counterparty } = await loadFixture(deployFixture);
    await ilrm.depositTokenReserves(ethers.parseEther("1000"));

    // 10% of 50 is 5, capped at the default 1 token per dispute
    const stake = ethers.parseEther("50");
    const id = await openDispute(ilrm, initiator, counterparty, stake);
    await time.increase(STAKE_WINDOW + 1);
    expect(await ilrm.previewInitiatorIncentive(stake)).to.equal(ethers.parseEther("1"));

    const before = await token.balanceOf(initiator.address);
    await expect(ilrm.enforceTimeout(id))
      .to.emit(ilrm, "InitiatorIncentivePaid")
      .withArgs(id, initiator.address, ethers.parseEther("1"), ethers.parseEther("5"));
    expect(await token.balanceOf(initiator.address) - before).to.equal(stake + ethers.parseEther("1"));
    expect(await ilrm.tokenReserves()).to.equal(ethers.parseEther("999"));
    expect(await ilrm.incentivePaidInWindow()).to.equal(ethers.parseEther("1"));
    expect(await token.balanceOf(ilrm.target)).to.equal(await ilrm.tokenReserves());
  });

  it("restricts setInitiatorIncentiveCaps to the owner, bounds it and emits the event", async function () {
    const { ilrm, attacker } = await loadFixture(deployFixture);

    expect(await ilrm.maxIncentivePerDispute()).to.equal(ethers.parseEther("1"));
    expect(await ilrm.maxIncentivePerWindow()).to.equal(ethers.parseEther("10"));
    expect(await ilrm.incentiveWindow()).to.equal(30 * DAY);

    await expect(ilrm.connect(attacker).setInitiatorIncentiveCaps(1, 2, DAY))
      .to.be.revertedWithCustomError(ilrm, "OwnableUnauthorizedAccount")
      .withArgs(attacker.address);
    await expect(ilrm.setInitiatorIncentiveCaps(1, 2, DAY - 1)).to.be.revertedWith("Invalid incentive window");
    await expect(ilrm.setInitiatorIncentiveCaps(1, 2, 365 * DAY + 1)).to.be.revertedWith("Invalid incentive window");
    await expect(ilrm.setInitiatorIncentiveCaps(3, 2, DAY)).to.be.revertedWith("Per-dispute cap above window cap");

    await expect(ilrm.setInitiatorIncentiveCaps(2, 5, 7 * DAY))
      .to.emit(ilrm, "InitiatorIncentiveCapsUpdated")
      .withArgs(2, 5, 7 * DAY);
    expect(await ilrm.maxIncentivePerDispute()).to.equal(2n);
    expect(await ilrm.maxIncentivePerWindow()).to.equal(5n);
    expect(await ilrm.incentiveWindow()).to.equal(7 * DAY);
  });

  it("keys subsidy records by (ILRM, disputeId) so a redeployed ILRM can reuse dispute IDs", async function () {
    const { ILRM, ilrm, treasury, token, registry, oracleAddr, initiator, counterparty, other } =
      await loadFixture(deployFixture);
    const stake = ethers.parseEther("2");

    // ILRM A: dispute 0 subsidized
    const idA = await openDispute(ilrm, initiator, counterparty, stake);
    expect(idA).to.equal(0n);
    await ilrm.connect(counterparty).depositStakeWithSubsidy(idA, stake, 0);

    // Redeploy ILRM B and re-point the Treasury; B's dispute 0 is eligible and can be subsidized
    const ilrmB = await ILRM.deploy(token.target, oracleAddr.address, registry.target);
    await treasury.setILRM(ilrmB.target);
    await ilrmB.setSubsidyTreasury(treasury.target);
    await token.connect(initiator).approve(ilrmB.target, ethers.MaxUint256);
    const idB = await openDispute(ilrmB, initiator, other, stake);
    expect(idB).to.equal(0n);
    const [, eligible] = await treasury.calculateSubsidy(0, stake, other.address);
    expect(eligible).to.equal(true);
    await expect(ilrmB.connect(other).depositStakeWithSubsidy(idB, stake, 0))
      .to.emit(treasury, "SubsidyFunded")
      .withArgs(other.address, 0, stake);

    expect(await treasury.subsidyRecipientOf(ilrm.target, 0)).to.equal(counterparty.address);
    expect(await treasury.subsidyRecipientOf(ilrmB.target, 0)).to.equal(other.address);
    expect(await treasury.disputeSubsidyRecipient(0)).to.equal(other.address);

    // Pointing back to A restores its records
    await treasury.setILRM(ilrm.target);
    expect(await treasury.disputeSubsidyRecipient(0)).to.equal(counterparty.address);
    expect(await treasury.disputeSubsidized(0)).to.equal(true);
  });
});
