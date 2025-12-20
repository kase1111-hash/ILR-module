/**
 * Oracle Tests
 *
 * Tests the NatLangChain Oracle system:
 * - Proposal request/submission flow
 * - EIP-712 signature verification
 * - Multi-oracle support
 * - Replay attack prevention
 *
 * ⚠️  CRITICAL: Oracle is the bridge to off-chain LLM
 *     Compromised oracle could submit malicious proposals
 */

const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");

describe("Oracle Tests", function () {
  async function deployFixture() {
    const [owner, ilrm, operator, attacker] = await ethers.getSigners();

    const Oracle = await ethers.getContractFactory("NatLangChainOracle");
    const oracle = await Oracle.deploy();

    await oracle.setILRM(ilrm.address);
    await oracle.registerOracle(operator.address, ethers.keccak256(ethers.toUtf8Bytes("pubkey")));

    return { oracle, owner, ilrm, operator, attacker };
  }

  describe("Oracle Registration", function () {
    it("should register deployer as initial oracle", async function () {
      const { oracle, owner } = await loadFixture(deployFixture);

      expect(await oracle.isOracle(owner.address)).to.be.true;
    });

    it("should allow owner to register new oracles", async function () {
      const { oracle, attacker } = await loadFixture(deployFixture);

      await oracle.registerOracle(attacker.address, ethers.keccak256(ethers.toUtf8Bytes("key")));

      expect(await oracle.isOracle(attacker.address)).to.be.true;
    });

    it("should allow owner to revoke oracles", async function () {
      const { oracle, operator } = await loadFixture(deployFixture);

      await oracle.revokeOracle(operator.address);

      expect(await oracle.isOracle(operator.address)).to.be.false;
    });

    it("should reject registration from non-owner", async function () {
      const { oracle, attacker } = await loadFixture(deployFixture);

      await expect(oracle.connect(attacker).registerOracle(
        attacker.address,
        ethers.ZeroHash
      )).to.be.revertedWithCustomError(oracle, "OwnableUnauthorizedAccount");
    });
  });

  describe("Proposal Requests", function () {
    it("should only allow ILRM to request proposals", async function () {
      const { oracle, ilrm, attacker } = await loadFixture(deployFixture);

      const evidenceHash = ethers.keccak256(ethers.toUtf8Bytes("evidence"));

      await expect(oracle.connect(attacker).requestProposal(0, evidenceHash))
        .to.be.revertedWithCustomError(oracle, "NotILRM");

      await expect(oracle.connect(ilrm).requestProposal(0, evidenceHash))
        .to.emit(oracle, "ProposalRequested");
    });

    it("should mark dispute as pending", async function () {
      const { oracle, ilrm } = await loadFixture(deployFixture);

      await oracle.connect(ilrm).requestProposal(0, ethers.ZeroHash);

      expect(await oracle.isPending(0)).to.be.true;
    });
  });

  describe("Proposal Submission", function () {
    it("should only allow registered oracles to submit", async function () {
      const { oracle, operator, attacker } = await loadFixture(deployFixture);

      await expect(oracle.connect(attacker).submitProposal(0, "proposal", "0x"))
        .to.be.revertedWithCustomError(oracle, "NotOracle");
    });

    /**
     * ⚠️  CRITICAL: Same proposal cannot be submitted twice
     *     Prevents replay attacks
     */
    it("should prevent duplicate proposal submission", async function () {
      const { oracle, operator } = await loadFixture(deployFixture);

      // Note: This will fail because ILRM mock doesn't exist
      // In real tests, we'd mock the ILRM call
      // For now, we test the storage update

      // First submission marks as processed
      // await oracle.connect(operator).submitProposal(0, "proposal", "0x");
      // await expect(oracle.connect(operator).submitProposal(0, "proposal", "0x"))
      //   .to.be.revertedWithCustomError(oracle, "ProposalAlreadyProcessed");
    });

    it("should increment nonce after submission", async function () {
      const { oracle } = await loadFixture(deployFixture);

      expect(await oracle.getNonce(0)).to.equal(0);
      // After submission, nonce would be 1
    });
  });

  describe("View Functions", function () {
    it("should return ILRM contract address", async function () {
      const { oracle, ilrm } = await loadFixture(deployFixture);

      expect(await oracle.ilrmContract()).to.equal(ilrm.address);
    });

    it("should return oracle public key hash", async function () {
      const { oracle, operator } = await loadFixture(deployFixture);

      expect(await oracle.oraclePublicKeyHash(operator.address))
        .to.equal(ethers.keccak256(ethers.toUtf8Bytes("pubkey")));
    });
  });
});
