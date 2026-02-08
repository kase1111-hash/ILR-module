/**
 * ILRM Interaction Script
 *
 * Minimal CLI for interacting with deployed ILRM contracts.
 * Supports the full dispute lifecycle:
 *
 * Usage:
 *   npx hardhat run scripts/interact.js --network <network> -- <command> [args]
 *
 * Or with environment variables:
 *   COMMAND=status DISPUTE_ID=0 npx hardhat run scripts/interact.js --network optimismSepolia
 *
 * Commands:
 *   initiate-dispute   -- Create a breach dispute
 *   deposit-stake      -- Counterparty matches stake
 *   submit-proposal    -- Oracle submits LLM proposal
 *   accept-proposal    -- Accept current proposal
 *   counter-propose    -- Submit counter-proposal
 *   enforce-timeout    -- Trigger timeout resolution
 *   request-subsidy    -- Request defensive subsidy
 *   status             -- View dispute state
 *   treasury-status    -- View treasury state
 *
 * Required env vars:
 *   DEPLOYMENT_FILE  -- Path to deployment JSON (from deploy.js)
 */

const { ethers } = require("hardhat");
const fs = require("fs");
const path = require("path");

// Load deployment addresses
function loadDeployment() {
  const deploymentFile = process.env.DEPLOYMENT_FILE;
  if (!deploymentFile) {
    // Try to find most recent deployment
    const deploymentsDir = path.join(__dirname, "..", "deployments");
    if (!fs.existsSync(deploymentsDir)) {
      throw new Error("No deployments/ directory found. Run deploy.js first.");
    }
    const files = fs.readdirSync(deploymentsDir).filter(f => f.endsWith(".json")).sort();
    if (files.length === 0) {
      throw new Error("No deployment files found. Run deploy.js first.");
    }
    const latest = files[files.length - 1];
    console.log(`Using deployment: ${latest}`);
    return JSON.parse(fs.readFileSync(path.join(deploymentsDir, latest), "utf8"));
  }
  return JSON.parse(fs.readFileSync(deploymentFile, "utf8"));
}

async function getContracts(deployment) {
  const ilrm = await ethers.getContractAt("ILRM", deployment.ilrm);
  const treasury = await ethers.getContractAt("NatLangChainTreasury", deployment.treasury);
  const oracle = await ethers.getContractAt("NatLangChainOracle", deployment.oracle);
  const token = await ethers.getContractAt("MockToken", deployment.token);
  return { ilrm, treasury, oracle, token };
}

// ============ Commands ============

async function initiateDispute(contracts, signer) {
  const counterparty = process.env.COUNTERPARTY;
  const stakeAmount = process.env.STAKE || "1";
  const evidenceHash = process.env.EVIDENCE_HASH || ethers.keccak256(ethers.toUtf8Bytes("evidence"));

  if (!counterparty) throw new Error("COUNTERPARTY env var required");

  const stake = ethers.parseEther(stakeAmount);

  // Approve token spend
  const allowance = await contracts.token.allowance(signer.address, await contracts.ilrm.getAddress());
  if (allowance < stake) {
    console.log("Approving ILRM for token spend...");
    const tx = await contracts.token.connect(signer).approve(await contracts.ilrm.getAddress(), ethers.MaxUint256);
    await tx.wait();
  }

  console.log(`Initiating dispute against ${counterparty} with stake ${stakeAmount} tokens...`);
  const tx = await contracts.ilrm.connect(signer).initiateBreachDispute(
    counterparty,
    stake,
    evidenceHash,
    {
      termsHash: ethers.keccak256(ethers.toUtf8Bytes("default-fallback")),
      termDuration: 365 * 24 * 60 * 60,
      royaltyCapBps: 500,
      nonExclusive: true
    }
  );
  const receipt = await tx.wait();
  const disputeCount = await contracts.ilrm.disputeCounter();
  const disputeId = Number(disputeCount) - 1;

  console.log(`Dispute #${disputeId} created (tx: ${receipt.hash})`);
  console.log(`  Gas used: ${receipt.gasUsed.toString()}`);
}

async function depositStake(contracts, signer) {
  const disputeId = process.env.DISPUTE_ID;
  if (!disputeId) throw new Error("DISPUTE_ID env var required");

  // Get dispute details to know stake amount
  const dispute = await contracts.ilrm.disputes(disputeId);
  const stakeNeeded = dispute[2]; // initiatorStake

  // Approve token spend
  const allowance = await contracts.token.allowance(signer.address, await contracts.ilrm.getAddress());
  if (allowance < stakeNeeded) {
    console.log("Approving ILRM for token spend...");
    const tx = await contracts.token.connect(signer).approve(await contracts.ilrm.getAddress(), ethers.MaxUint256);
    await tx.wait();
  }

  console.log(`Depositing stake for dispute #${disputeId}...`);
  const tx = await contracts.ilrm.connect(signer).depositStake(disputeId);
  const receipt = await tx.wait();
  console.log(`Stake deposited (tx: ${receipt.hash})`);
  console.log(`  Gas used: ${receipt.gasUsed.toString()}`);
}

async function submitProposal(contracts, signer) {
  const disputeId = process.env.DISPUTE_ID;
  const proposal = process.env.PROPOSAL || '{"proposal": "Default resolution terms"}';
  if (!disputeId) throw new Error("DISPUTE_ID env var required");

  console.log(`Submitting proposal for dispute #${disputeId}...`);
  const tx = await contracts.ilrm.connect(signer).submitLLMProposal(disputeId, proposal, "0x");
  const receipt = await tx.wait();
  console.log(`Proposal submitted (tx: ${receipt.hash})`);
  console.log(`  Gas used: ${receipt.gasUsed.toString()}`);
}

async function acceptProposal(contracts, signer) {
  const disputeId = process.env.DISPUTE_ID;
  if (!disputeId) throw new Error("DISPUTE_ID env var required");

  console.log(`Accepting proposal for dispute #${disputeId}...`);
  const tx = await contracts.ilrm.connect(signer).acceptProposal(disputeId);
  const receipt = await tx.wait();
  console.log(`Proposal accepted (tx: ${receipt.hash})`);
  console.log(`  Gas used: ${receipt.gasUsed.toString()}`);
}

async function counterPropose(contracts, signer) {
  const disputeId = process.env.DISPUTE_ID;
  const fee = process.env.COUNTER_FEE || "0.01";
  const evidenceHash = process.env.EVIDENCE_HASH || ethers.keccak256(ethers.toUtf8Bytes("counter-evidence"));
  if (!disputeId) throw new Error("DISPUTE_ID env var required");

  console.log(`Submitting counter-proposal for dispute #${disputeId} (fee: ${fee} ETH)...`);
  const tx = await contracts.ilrm.connect(signer).counterPropose(
    disputeId,
    evidenceHash,
    { value: ethers.parseEther(fee) }
  );
  const receipt = await tx.wait();
  console.log(`Counter-proposal submitted (tx: ${receipt.hash})`);
  console.log(`  Gas used: ${receipt.gasUsed.toString()}`);
}

async function enforceTimeout(contracts, signer) {
  const disputeId = process.env.DISPUTE_ID;
  if (!disputeId) throw new Error("DISPUTE_ID env var required");

  console.log(`Enforcing timeout for dispute #${disputeId}...`);
  const tx = await contracts.ilrm.connect(signer).enforceTimeout(disputeId);
  const receipt = await tx.wait();
  console.log(`Timeout enforced (tx: ${receipt.hash})`);
  console.log(`  Gas used: ${receipt.gasUsed.toString()}`);
}

async function requestSubsidy(contracts, signer) {
  const disputeId = process.env.DISPUTE_ID;
  const stakeNeeded = process.env.STAKE || "1";
  if (!disputeId) throw new Error("DISPUTE_ID env var required");

  const amount = ethers.parseEther(stakeNeeded);
  console.log(`Requesting subsidy for dispute #${disputeId} (${stakeNeeded} tokens)...`);
  const tx = await contracts.treasury.connect(signer).requestSubsidy(
    disputeId, amount, signer.address
  );
  const receipt = await tx.wait();
  console.log(`Subsidy granted (tx: ${receipt.hash})`);
  console.log(`  Gas used: ${receipt.gasUsed.toString()}`);
}

async function showStatus(contracts) {
  const disputeId = process.env.DISPUTE_ID;
  if (!disputeId) throw new Error("DISPUTE_ID env var required");

  const d = await contracts.ilrm.disputes(disputeId);

  const outcomeNames = ["Pending", "AcceptedProposal", "TimeoutWithBurn", "DefaultLicenseApplied"];

  console.log(`\nDispute #${disputeId}`);
  console.log("─".repeat(50));
  console.log(`  Initiator:          ${d[0]}`);
  console.log(`  Counterparty:       ${d[1]}`);
  console.log(`  Initiator Stake:    ${ethers.formatEther(d[2])} tokens`);
  console.log(`  Counterparty Stake: ${ethers.formatEther(d[3])} tokens`);
  console.log(`  Start Time:         ${new Date(Number(d[4]) * 1000).toISOString()}`);
  console.log(`  Evidence Hash:      ${d[5]}`);
  console.log(`  Proposal:           ${d[6] || "(none)"}`);
  console.log(`  Initiator Accepted: ${d[7]}`);
  console.log(`  CP Accepted:        ${d[8]}`);
  console.log(`  Resolved:           ${d[9]}`);
  console.log(`  Outcome:            ${outcomeNames[Number(d[10])]}`);
  console.log(`  Counter Count:      ${d[12]}`);
  console.log("─".repeat(50));
}

async function showTreasuryStatus(contracts) {
  const balance = await contracts.treasury.balance();
  const available = await contracts.treasury.availableForSubsidies();
  const totalDistributed = await contracts.treasury.totalSubsidiesDistributed();
  const totalInflows = await contracts.treasury.totalInflows();
  const minReserve = await contracts.treasury.minReserve();

  console.log(`\nTreasury Status`);
  console.log("─".repeat(50));
  console.log(`  Balance:              ${ethers.formatEther(balance)} tokens`);
  console.log(`  Available for subsidy:${ethers.formatEther(available)} tokens`);
  console.log(`  Min reserve:          ${ethers.formatEther(minReserve)} tokens`);
  console.log(`  Total distributed:    ${ethers.formatEther(totalDistributed)} tokens`);
  console.log(`  Total inflows:        ${ethers.formatEther(totalInflows)} tokens`);
  console.log("─".repeat(50));
}

// ============ Main ============

async function main() {
  const deployment = loadDeployment();
  const [signer] = await ethers.getSigners();
  const contracts = await getContracts(deployment);

  const command = process.env.COMMAND || process.argv[2];

  console.log(`\nILRM Interaction CLI`);
  console.log(`  Signer: ${signer.address}`);
  console.log(`  ILRM:   ${deployment.ilrm}`);
  console.log(`  Command: ${command || "(none)"}\n`);

  switch (command) {
    case "initiate-dispute":
      await initiateDispute(contracts, signer);
      break;
    case "deposit-stake":
      await depositStake(contracts, signer);
      break;
    case "submit-proposal":
      await submitProposal(contracts, signer);
      break;
    case "accept-proposal":
      await acceptProposal(contracts, signer);
      break;
    case "counter-propose":
      await counterPropose(contracts, signer);
      break;
    case "enforce-timeout":
      await enforceTimeout(contracts, signer);
      break;
    case "request-subsidy":
      await requestSubsidy(contracts, signer);
      break;
    case "status":
      await showStatus(contracts);
      break;
    case "treasury-status":
      await showTreasuryStatus(contracts);
      break;
    default:
      console.log("Available commands:");
      console.log("  initiate-dispute   COUNTERPARTY=<addr> STAKE=<amount>");
      console.log("  deposit-stake      DISPUTE_ID=<id>");
      console.log("  submit-proposal    DISPUTE_ID=<id> PROPOSAL=<json>");
      console.log("  accept-proposal    DISPUTE_ID=<id>");
      console.log("  counter-propose    DISPUTE_ID=<id> COUNTER_FEE=<eth>");
      console.log("  enforce-timeout    DISPUTE_ID=<id>");
      console.log("  request-subsidy    DISPUTE_ID=<id> STAKE=<amount>");
      console.log("  status             DISPUTE_ID=<id>");
      console.log("  treasury-status");
      console.log("\nExample:");
      console.log("  COMMAND=initiate-dispute COUNTERPARTY=0x... STAKE=1 npx hardhat run scripts/interact.js --network optimismSepolia");
      break;
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
