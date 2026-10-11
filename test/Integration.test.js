/**
 * Integration Tests
 *
 * End-to-end tests that verify the full NatLangChain system works together:
 * - ILRM + Oracle + AssetRegistry + Treasury
 *
 * These tests simulate real-world usage scenarios from the documentation.
 */

const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time, loadFixture } = require("@nomicfoundation/hardhat-network-helpers");

describe("Integration Tests", function () {
  const STAKE_WINDOW = 3 * 24 * 60 * 60;
  const RESOLUTION_TIMEOUT = 7 * 24 * 60 * 60;

  /**
   * Sign a proposal as an oracle operator (EIP-712) and submit it through the Oracle contract,
   * which forwards it to ILRM. ILRM only accepts proposals from the Oracle contract.
   */
  async function submitSignedProposal(oracle, operator, disputeId, proposal) {
    const { chainId } = await ethers.provider.getNetwork();
    const domain = { name: "NatLangChainOracle", version: "1", chainId, verifyingContract: oracle.target };
    const types = {
      Proposal: [
        { name: "disputeId", type: "uint256" },
        { name: "proposalHash", type: "bytes32" },
        { name: "nonce", type: "uint256" }
      ]
    };
    const value = {
      disputeId,
      proposalHash: ethers.keccak256(ethers.toUtf8Bytes(proposal)),
      nonce: await oracle.getNonce(disputeId)
    };
    const signature = await operator.signTypedData(domain, types, value);
    return oracle.connect(operator).submitProposal(disputeId, proposal, signature);
  }

  async function deployFullSystem() {
    const [owner, oracleOperator, initiator, counterparty] = await ethers.getSigners();

    // Deploy token
    const MockToken = await ethers.getContractFactory("MockToken");
    const token = await MockToken.deploy();

    // Deploy Oracle
    const Oracle = await ethers.getContractFactory("NatLangChainOracle");
    const oracle = await Oracle.deploy();

    // Deploy AssetRegistry
    const Registry = await ethers.getContractFactory("NatLangChainAssetRegistry");
    const registry = await Registry.deploy();

    // Deploy ILRM (using oracle contract address)
    const ILRM = await ethers.getContractFactory("ILRM");
    const ilrm = await ILRM.deploy(token.target, oracle.target, registry.target);

    // Deploy Treasury
    const Treasury = await ethers.getContractFactory("NatLangChainTreasury");
    const treasury = await Treasury.deploy(
      token.target,
      ethers.parseEther("5"),
      ethers.parseEther("20"),
      30 * 24 * 60 * 60
    );

    // Configure contracts
    await oracle.setILRM(ilrm.target);
    await oracle.registerOracle(oracleOperator.address, ethers.ZeroHash);
    await registry.authorizeILRM(ilrm.target);
    await treasury.setILRM(ilrm.target);

    // Fund accounts
    await token.mint(initiator.address, ethers.parseEther("1000"));
    await token.mint(counterparty.address, ethers.parseEther("1000"));
    await token.mint(treasury.target, ethers.parseEther("100")); // Fund treasury

    // Approvals
    await token.connect(initiator).approve(ilrm.target, ethers.MaxUint256);
    await token.connect(counterparty).approve(ilrm.target, ethers.MaxUint256);

    const STAKE = ethers.parseEther("10");

    return {
      token, oracle, registry, ilrm, treasury,
      owner, oracleOperator, initiator, counterparty,
      STAKE
    };
  }

  describe("Scenario 1: Happy Path - Mutual Agreement", function () {
    /**
     * SCENARIO: Two parties have a licensing dispute. They both stake,
     * receive an LLM proposal, and both accept it. Assets unfrozen,
     * stakes returned.
     */
    it("should complete full dispute resolution with mutual acceptance", async function () {
      const {
        token, oracle, registry, ilrm,
        oracleOperator, initiator, counterparty, STAKE
      } = await loadFixture(deployFullSystem);

      console.log("\n  📋 Step 1: Register IP Asset");
      const assetId = ethers.keccak256(ethers.toUtf8Bytes("my-software-v1"));
      await registry.connect(initiator).registerAsset(assetId, initiator.address, ethers.ZeroHash);
      console.log("     ✓ Asset registered");

      console.log("\n  📋 Step 2: Initiator starts breach dispute");
      const evidenceHash = ethers.keccak256(ethers.toUtf8Bytes("evidence-bundle"));
      const fallback = {
        termsHash: ethers.keccak256(ethers.toUtf8Bytes("fallback-terms")),
        termDuration: 30 * 24 * 60 * 60,
        royaltyCapBps: 500,
        nonExclusive: true
      };

      await ilrm.connect(initiator).initiateBreachDispute(
        counterparty.address, STAKE, evidenceHash, fallback
      );
      console.log("     ✓ Dispute initiated, stake escrowed");

      console.log("\n  📋 Step 3: Counterparty matches stake");
      await ilrm.connect(counterparty).depositStake(0);
      console.log("     ✓ Stakes symmetric");

      console.log("\n  📋 Step 4: Oracle submits LLM proposal");
      const proposal = JSON.stringify({
        type: "license_adjustment",
        terms: {
          scope: "commercial use",
          royalties: "5%",
          duration: "12 months"
        }
      });
      await submitSignedProposal(oracle, oracleOperator, 0, proposal);
      console.log("     ✓ Proposal submitted");

      console.log("\n  📋 Step 5: Both parties accept");
      const initBalBefore = await token.balanceOf(initiator.address);
      const cpBalBefore = await token.balanceOf(counterparty.address);

      await ilrm.connect(initiator).acceptProposal(0);
      await ilrm.connect(counterparty).acceptProposal(0);
      console.log("     ✓ Mutual acceptance achieved");

      console.log("\n  📋 Step 6: Verify resolution");
      const dispute = await ilrm.disputes(0);
      expect(dispute.resolved).to.be.true;
      expect(dispute.outcome).to.equal(1); // AcceptedProposal

      const initBalAfter = await token.balanceOf(initiator.address);
      const cpBalAfter = await token.balanceOf(counterparty.address);

      expect(initBalAfter - initBalBefore).to.equal(STAKE);
      expect(cpBalAfter - cpBalBefore).to.equal(STAKE);
      console.log("     ✓ Stakes returned to both parties");
      console.log("\n  🎉 Dispute resolved successfully!\n");
    });
  });

  describe("Scenario 2: Counterparty Ignores - Default License", function () {
    /**
     * SCENARIO: Initiator starts dispute, counterparty never responds.
     * After stake window, initiator's stake returned and fallback license
     * applied.
     */
    it("should apply default license when counterparty ignores", async function () {
      const {
        token, registry, ilrm,
        initiator, counterparty, STAKE
      } = await loadFixture(deployFullSystem);

      console.log("\n  📋 Step 1: Initiator starts dispute");
      const evidenceHash = ethers.keccak256(ethers.toUtf8Bytes("evidence"));
      const fallback = {
        termsHash: ethers.keccak256(ethers.toUtf8Bytes("default-license")),
        termDuration: 30 * 24 * 60 * 60,
        royaltyCapBps: 500,
        nonExclusive: true
      };

      await ilrm.connect(initiator).initiateBreachDispute(
        counterparty.address, STAKE, evidenceHash, fallback
      );
      console.log("     ✓ Dispute initiated");

      console.log("\n  📋 Step 2: Counterparty ignores (3 days pass)");
      await time.increase(STAKE_WINDOW + 1);
      console.log("     ⏰ Stake window expired");

      console.log("\n  📋 Step 3: Anyone triggers timeout");
      const balBefore = await token.balanceOf(initiator.address);
      await ilrm.enforceTimeout(0);

      const dispute = await ilrm.disputes(0);
      expect(dispute.outcome).to.equal(3); // DefaultLicenseApplied

      const balAfter = await token.balanceOf(initiator.address);
      expect(balAfter).to.be.gte(balBefore + STAKE);
      console.log("     ✓ Initiator stake returned");
      console.log("     ✓ Fallback license applied");
      console.log("\n  🎉 Non-participation handled correctly!\n");
    });
  });

  describe("Scenario 3: Disagreement - Timeout with Burn", function () {
    /**
     * SCENARIO: Both stake, proposal submitted, but neither accepts.
     * After timeout, stakes partially burned as "entropy tax".
     */
    it("should burn stakes on timeout without agreement", async function () {
      const {
        token, oracle, ilrm,
        oracleOperator, initiator, counterparty, STAKE
      } = await loadFixture(deployFullSystem);

      console.log("\n  📋 Step 1: Both parties stake");
      await ilrm.connect(initiator).initiateBreachDispute(
        counterparty.address, STAKE,
        ethers.ZeroHash,
        { termsHash: ethers.ZeroHash, termDuration: 86400, royaltyCapBps: 500, nonExclusive: true }
      );
      await ilrm.connect(counterparty).depositStake(0);
      console.log("     ✓ Both staked 10 ETH each");

      console.log("\n  📋 Step 2: Oracle submits proposal");
      await submitSignedProposal(oracle, oracleOperator, 0, '{"proposal":"test"}');
      console.log("     ✓ Proposal submitted");

      console.log("\n  📋 Step 3: Neither party accepts (7 days pass)");
      await time.increase(RESOLUTION_TIMEOUT + 1);
      console.log("     ⏰ Resolution timeout expired");

      console.log("\n  📋 Step 4: Trigger timeout");
      const initBefore = await token.balanceOf(initiator.address);
      const cpBefore = await token.balanceOf(counterparty.address);

      await ilrm.enforceTimeout(0);

      const initAfter = await token.balanceOf(initiator.address);
      const cpAfter = await token.balanceOf(counterparty.address);

      // Each gets 25% back (50% burned, 50% split)
      const expectedReturn = STAKE / 2n;
      expect(initAfter - initBefore).to.equal(expectedReturn);
      expect(cpAfter - cpBefore).to.equal(expectedReturn);

      console.log("     🔥 50% of stakes burned (entropy tax)");
      console.log("     ✓ Remaining 50% returned equally");
      console.log("\n  ⚠️  Prolonged disagreement cost both parties!\n");
    });
  });

  describe("Scenario 4: Counter-Proposal Negotiation", function () {
    /**
     * SCENARIO: Parties go through multiple rounds of counter-proposals
     * before reaching agreement.
     */
    it("should handle counter-proposal negotiation flow", async function () {
      const {
        token, oracle, ilrm,
        oracleOperator, initiator, counterparty, STAKE
      } = await loadFixture(deployFullSystem);

      console.log("\n  📋 Step 1: Setup dispute with initial proposal");
      await ilrm.connect(initiator).initiateBreachDispute(
        counterparty.address, STAKE,
        ethers.ZeroHash,
        { termsHash: ethers.ZeroHash, termDuration: 86400, royaltyCapBps: 500, nonExclusive: true }
      );
      await ilrm.connect(counterparty).depositStake(0);
      await submitSignedProposal(oracle, oracleOperator, 0, '{"round":1}');
      console.log("     ✓ Initial proposal submitted");

      console.log("\n  📋 Step 2: Initiator counters (fee: 0.01 ETH)");
      await ilrm.connect(initiator).counterPropose(
        0, ethers.keccak256(ethers.toUtf8Bytes("evidence-2")),
        { value: ethers.parseEther("0.01") }
      );
      console.log("     🔥 0.01 ETH counter fee burned");

      console.log("\n  📋 Step 3: Counterparty counters (fee: 0.02 ETH)");
      await ilrm.connect(counterparty).counterPropose(
        0, ethers.keccak256(ethers.toUtf8Bytes("evidence-3")),
        { value: ethers.parseEther("0.02") }
      );
      console.log("     🔥 0.02 ETH counter fee burned");

      console.log("\n  📋 Step 4: Oracle submits new proposal");
      // The Oracle accepts one proposal per dispute; the owner re-opens it for the new round
      await oracle.resetProposal(0, "counter-proposal round");
      await submitSignedProposal(oracle, oracleOperator, 0, '{"round":2,"compromise":true}');

      console.log("\n  📋 Step 5: Both accept compromise");
      await ilrm.connect(initiator).acceptProposal(0);
      await ilrm.connect(counterparty).acceptProposal(0);

      const dispute = await ilrm.disputes(0);
      expect(dispute.resolved).to.be.true;
      expect(dispute.counterCount).to.equal(2);

      console.log("     ✓ Agreement reached after 2 counter-proposals");

      // Each submission consumed a nonce (round 1, reset, round 2)
      expect(await oracle.getNonce(0)).to.equal(3);
      console.log("     💰 Total counter fees: 0.03 ETH burned");
      console.log("\n  🎉 Negotiation successful!\n");
    });
  });

  describe("Scenario 4b: Oracle Signature Replay Protection", function () {
    /**
     * SCENARIO: After the owner re-opens a dispute for a new proposal round,
     * a signature produced for the previous nonce must not be accepted.
     */
    it("should reject a proposal signed for a stale nonce", async function () {
      const {
        oracle, ilrm,
        oracleOperator, initiator, counterparty, STAKE
      } = await loadFixture(deployFullSystem);

      await ilrm.connect(initiator).initiateBreachDispute(
        counterparty.address, STAKE,
        ethers.ZeroHash,
        { termsHash: ethers.ZeroHash, termDuration: 86400, royaltyCapBps: 500, nonExclusive: true }
      );
      await ilrm.connect(counterparty).depositStake(0);

      const proposal = '{"round":1}';
      const { chainId } = await ethers.provider.getNetwork();
      const signature = await oracleOperator.signTypedData(
        { name: "NatLangChainOracle", version: "1", chainId, verifyingContract: oracle.target },
        { Proposal: [
          { name: "disputeId", type: "uint256" },
          { name: "proposalHash", type: "bytes32" },
          { name: "nonce", type: "uint256" }
        ] },
        { disputeId: 0, proposalHash: ethers.keccak256(ethers.toUtf8Bytes(proposal)), nonce: 0 }
      );
      await oracle.connect(oracleOperator).submitProposal(0, proposal, signature);

      await oracle.resetProposal(0, "new round");

      await expect(oracle.connect(oracleOperator).submitProposal(0, proposal, signature))
        .to.be.revertedWithCustomError(oracle, "InvalidSignature");
    });
  });

  describe("Scenario 5: Treasury-Subsidized Defense", function () {
    /**
     * SCENARIO: Low-resource counterparty receives subsidy from treasury
     * to participate in dispute they didn't initiate.
     */
    it("should allow treasury to subsidize defender", async function () {
      const {
        token, oracle, ilrm, treasury,
        oracleOperator, initiator, counterparty, STAKE
      } = await loadFixture(deployFullSystem);
      const SUBSIDY = ethers.parseEther("5"); // maxPerDispute

      // Let ILRM draw defensive stake subsidies from the treasury
      await ilrm.setSubsidyTreasury(treasury.target);

      console.log("\n  📋 Step 1: Counterparty only has half the stake");
      // Simulate low-resource defender: keeps 5 of the 10 tokens needed
      const cpBalance = await token.balanceOf(counterparty.address);
      await token.connect(counterparty).transfer(initiator.address, cpBalance - (STAKE - SUBSIDY));
      expect(await token.balanceOf(counterparty.address)).to.equal(STAKE - SUBSIDY);
      console.log("     ✓ Counterparty balance: 5");

      console.log("\n  📋 Step 2: Initiator starts dispute");
      await ilrm.connect(initiator).initiateBreachDispute(
        counterparty.address, STAKE,
        ethers.ZeroHash,
        { termsHash: ethers.ZeroHash, termDuration: 86400, royaltyCapBps: 500, nonExclusive: true }
      );
      console.log("     ✓ Dispute initiated against low-resource party");

      console.log("\n  📋 Step 3: Counterparty stakes with a treasury subsidy");
      const treasuryBefore = await token.balanceOf(treasury.target);
      await ilrm.connect(counterparty).depositStakeWithSubsidy(0, ethers.MaxUint256);

      const dispute = await ilrm.disputes(0);
      expect(dispute.initiatorStake).to.equal(STAKE);
      expect(dispute.counterpartyStake).to.equal(STAKE);
      const [, subsidy] = await ilrm.stakeSubsidy(0);
      expect(subsidy).to.equal(SUBSIDY);
      expect(await token.balanceOf(counterparty.address)).to.equal(0); // paid only the 5-token top-up
      expect(treasuryBefore - await token.balanceOf(treasury.target)).to.equal(SUBSIDY);
      console.log("     💰 Treasury escrowed 5 of the 10-token stake");

      console.log("\n  📋 Step 4: Proposal accepted by both parties");
      await submitSignedProposal(oracle, oracleOperator, 0, '{"proposal":"cross-license"}');
      await ilrm.connect(initiator).acceptProposal(0);
      await ilrm.connect(counterparty).acceptProposal(0);

      expect(await token.balanceOf(counterparty.address)).to.equal(STAKE - SUBSIDY);
      expect(await token.balanceOf(treasury.target)).to.equal(treasuryBefore);
      console.log("     ✓ Defender got its 5 back, treasury made whole");

      console.log("\n  🎉 Treasury protected low-resource defender!\n");
    });
  });
});

/**
 * ╔═══════════════════════════════════════════════════════════════════════════╗
 * ║                         USAGE INSTRUCTIONS                                 ║
 * ╠═══════════════════════════════════════════════════════════════════════════╣
 * ║                                                                            ║
 * ║  To run all tests:                                                         ║
 * ║    npm test                                                                ║
 * ║                                                                            ║
 * ║  To run specific test file:                                                ║
 * ║    npx hardhat test test/Integration.test.js                               ║
 * ║                                                                            ║
 * ║  To run with gas reporting:                                                ║
 * ║    REPORT_GAS=true npm test                                                ║
 * ║                                                                            ║
 * ║  To run with coverage:                                                     ║
 * ║    npm run coverage                                                        ║
 * ║                                                                            ║
 * ╠═══════════════════════════════════════════════════════════════════════════╣
 * ║                           WARNINGS                                         ║
 * ╠═══════════════════════════════════════════════════════════════════════════╣
 * ║                                                                            ║
 * ║  ⚠️  NEVER deploy to mainnet without:                                      ║
 * ║      1. Full security audit                                                ║
 * ║      2. All tests passing                                                  ║
 * ║      3. Formal verification of invariants                                  ║
 * ║                                                                            ║
 * ║  ⚠️  ALWAYS verify:                                                        ║
 * ║      1. Token addresses are correct                                        ║
 * ║      2. Oracle is trusted and available                                    ║
 * ║      3. Treasury has sufficient funds                                      ║
 * ║      4. All contracts are properly linked                                  ║
 * ║                                                                            ║
 * ║  ⚠️  MONITOR in production:                                                ║
 * ║      1. Disputes approaching timeout                                       ║
 * ║      2. Treasury balance                                                   ║
 * ║      3. Oracle availability                                                ║
 * ║      4. Harassment score anomalies                                         ║
 * ║                                                                            ║
 * ╚═══════════════════════════════════════════════════════════════════════════╝
 */
