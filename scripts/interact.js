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
 *   submit-proposal    -- Oracle operator signs and submits the LLM proposal
 *                         (once per round; run again after counter-propose)
 *   reset-proposal     -- Oracle owner voids the current round's proposal (recovery; pinned to its hash,
 *                         voided in ILRM immediately)
 *   accept-proposal    -- Accept the live proposal, bound to its hash (reverts if it changed)
 *   counter-propose    -- Submit counter-proposal (opens a new oracle proposal round)
 *   enforce-timeout    -- Trigger timeout resolution
 *   request-subsidy    -- Counterparty stakes with a Treasury-funded subsidy (escrowed, never paid out)
 *   status             -- View dispute state
 *   treasury-status    -- View treasury state
 *
 * Required env vars:
 *   DEPLOYMENT_FILE  -- Path to deployment JSON (from deploy.js)
 *
 * Optional env vars:
 *   SIGNER_INDEX     -- Index of the configured account to sign with (default 0)
 *   COUNTER_FEE      -- Counter-proposal fee in ETH (default 0.01 * 2^counterCount)
 *   PROPOSAL_HASH    -- keccak256 of the proposal text you reviewed (see `status`). accept-proposal and
 *                       reset-proposal refuse to act if the live proposal no longer matches it
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

// EIP-712 typed data signed by oracle operators (must match NatLangChainOracle.PROPOSAL_TYPEHASH)
const PROPOSAL_TYPES = {
  Proposal: [
    { name: "disputeId", type: "uint256" },
    { name: "round", type: "uint256" },
    { name: "evidenceHash", type: "bytes32" },
    { name: "proposalHash", type: "bytes32" },
    { name: "nonce", type: "uint256" }
  ]
};

async function submitProposal(contracts, signer) {
  const disputeId = process.env.DISPUTE_ID;
  const proposal = process.env.PROPOSAL || '{"proposal": "Default resolution terms"}';
  if (!disputeId) throw new Error("DISPUTE_ID env var required");

  // The Oracle admits one proposal per round (ILRM counterCount); each counter-proposal opens a new round
  const [round, evidenceHash, nonce, open] = await contracts.oracle.proposalContext(disputeId);
  if (!open) {
    throw new Error(
      `Dispute #${disputeId} round ${round}: round already has a proposal; owner must reset-proposal to replace it`
    );
  }

  // ILRM only accepts proposals from the Oracle contract, which requires an EIP-712 signature
  // from a registered oracle operator (the signer here) over the dispute's live round context
  const { chainId } = await ethers.provider.getNetwork();
  const domain = { name: "NatLangChainOracle", version: "1", chainId, verifyingContract: contracts.oracle.target };
  const proposalHash = ethers.keccak256(ethers.toUtf8Bytes(proposal));
  const value = { disputeId, round, evidenceHash, proposalHash, nonce };

  // Never send a signature over a digest the Oracle would not recompute
  const localDigest = ethers.TypedDataEncoder.hash(domain, PROPOSAL_TYPES, value);
  const onChainDigest = await contracts.oracle.proposalDigest(disputeId, proposalHash);
  if (localDigest !== onChainDigest) {
    throw new Error(`EIP-712 digest mismatch (local ${localDigest}, oracle ${onChainDigest}); aborting`);
  }

  console.log(`Signing and submitting proposal for dispute #${disputeId} (round ${round}, nonce ${nonce}) via Oracle...`);
  const signature = await signer.signTypedData(domain, PROPOSAL_TYPES, value);
  const tx = await contracts.oracle.connect(signer).submitProposal(disputeId, proposal, signature);
  const receipt = await tx.wait();
  console.log(`Proposal submitted (tx: ${receipt.hash})`);
  console.log(`  Gas used: ${receipt.gasUsed.toString()}`);
}

async function resetProposal(contracts, signer) {
  const disputeId = process.env.DISPUTE_ID;
  const reason = process.env.REASON;
  if (!disputeId) throw new Error("DISPUTE_ID env var required");
  if (!reason) throw new Error("REASON env var required");

  // Owner recovery: voids the current round's live proposal (in ILRM too, in the same transaction) and
  // allows exactly one replacement. Pinned to (round, hash): if anything else is live when the transaction
  // executes (e.g. behind a timelock), it reverts ProposalMismatch instead of voiding it.
  const [round, , , open] = await contracts.oracle.proposalContext(disputeId);
  if (open) {
    throw new Error(`Dispute #${disputeId} round ${round} has no proposal to reset`);
  }
  const slotHash = await contracts.oracle.roundProposals(disputeId, round);
  const proposalHash = process.env.PROPOSAL_HASH || slotHash;
  if (proposalHash.toLowerCase() !== slotHash.toLowerCase()) {
    throw new Error(
      `Round ${round} holds ${slotHash}, not PROPOSAL_HASH ${proposalHash}; proposal changed, run status again`
    );
  }

  console.log(
    `Resetting proposal ${proposalHash} (round ${round}) of dispute #${disputeId} (reason: ${reason})...`
  );
  const tx = await contracts.oracle.connect(signer).resetProposalExact(disputeId, round, proposalHash, reason);
  const receipt = await tx.wait();
  const [, , nonce] = await contracts.oracle.proposalContext(disputeId);
  console.log(`Proposal reset (tx: ${receipt.hash})`);
  console.log(`  The proposal and its acceptances are voided in ILRM immediately.`);
  console.log(`  Submit the replacement now, signed at the new nonce ${nonce}.`);
  console.log(`  Gas used: ${receipt.gasUsed.toString()}`);
}

async function acceptProposal(contracts, signer) {
  const disputeId = process.env.DISPUTE_ID;
  if (!disputeId) throw new Error("DISPUTE_ID env var required");

  // Bind the acceptance to the text being accepted: if the proposal is voided or replaced before this
  // transaction executes, ILRM reverts "Proposal changed" instead of accepting the new text
  const { llmProposal } = await contracts.ilrm.disputes(disputeId);
  if (!llmProposal) throw new Error(`Dispute #${disputeId} has no live proposal`);
  const liveHash = ethers.keccak256(ethers.toUtf8Bytes(llmProposal));
  const expected = process.env.PROPOSAL_HASH;
  if (expected && expected.toLowerCase() !== liveHash.toLowerCase()) {
    throw new Error(
      `Live proposal hash ${liveHash} != PROPOSAL_HASH ${expected}; proposal changed, run status again`
    );
  }

  console.log(`Accepting proposal for dispute #${disputeId}:`);
  console.log(`  Text: ${llmProposal}`);
  console.log(`  Hash: ${liveHash}`);
  const tx = await contracts.ilrm.connect(signer).acceptProposalWithHash(disputeId, liveHash);
  const receipt = await tx.wait();
  console.log(`Proposal accepted (tx: ${receipt.hash})`);
  console.log(`  Gas used: ${receipt.gasUsed.toString()}`);
}

async function counterPropose(contracts, signer) {
  const disputeId = process.env.DISPUTE_ID;
  const evidenceHash = process.env.EVIDENCE_HASH || ethers.keccak256(ethers.toUtf8Bytes("counter-evidence"));
  if (!disputeId) throw new Error("DISPUTE_ID env var required");

  // Fee doubles with each counter: 0.01 ETH * 2^counterCount
  let fee;
  if (process.env.COUNTER_FEE) {
    fee = ethers.parseEther(process.env.COUNTER_FEE);
  } else {
    const { counterCount } = await contracts.ilrm.disputes(disputeId);
    fee = ethers.parseEther("0.01") << counterCount;
  }

  console.log(`Submitting counter-proposal for dispute #${disputeId} (fee: ${ethers.formatEther(fee)} ETH)...`);
  const tx = await contracts.ilrm.connect(signer).counterPropose(
    disputeId,
    evidenceHash,
    { value: fee }
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
  if (!disputeId) throw new Error("DISPUTE_ID env var required");

  // The subsidy funds part (or all) of the counterparty's stake in ILRM escrow; it is never paid
  // to the wallet. The signer (counterparty) pays the rest of the stake as a top-up.
  const d = await contracts.ilrm.disputes(disputeId);
  const stake = d.initiatorStake;
  const maxSubsidy = process.env.MAX_SUBSIDY ? ethers.parseEther(process.env.MAX_SUBSIDY) : ethers.MaxUint256;
  const requested = stake < maxSubsidy ? stake : maxSubsidy;

  const [preview, eligible] = await contracts.treasury.calculateSubsidy(disputeId, requested, signer.address);
  if (!eligible) throw new Error(`No subsidy available for ${signer.address} on dispute #${disputeId}`);

  // Approve ILRM for exactly the top-up (the allowance also bounds what the call can charge)
  const ilrmAddress = await contracts.ilrm.getAddress();
  const topUp = stake - preview;
  if (topUp > 0n) {
    const allowance = await contracts.token.allowance(signer.address, ilrmAddress);
    if (allowance < topUp) {
      console.log(`Approving ILRM for the ${ethers.formatEther(topUp)}-token top-up...`);
      const approveTx = await contracts.token.connect(signer).approve(ilrmAddress, topUp);
      await approveTx.wait();
    }
  }

  console.log(
    `Staking ${ethers.formatEther(stake)} tokens on dispute #${disputeId} ` +
    `with a subsidy of up to ${ethers.formatEther(preview)} tokens...`
  );
  const tx = await contracts.ilrm.connect(signer).depositStakeWithSubsidy(disputeId, maxSubsidy);
  const receipt = await tx.wait();
  const [funder, amount] = await contracts.ilrm.stakeSubsidy(disputeId);
  console.log(`Subsidized stake deposited (tx: ${receipt.hash})`);
  console.log(`  Subsidy:    ${ethers.formatEther(amount)} tokens from ${funder}`);
  console.log(`  Top-up paid: ${ethers.formatEther(stake - amount)} tokens`);
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
  console.log(`  Proposal Hash:      ${d[6] ? ethers.keccak256(ethers.toUtf8Bytes(d[6])) : "(none)"}`);
  console.log(`  Initiator Accepted: ${d[7]}`);
  console.log(`  CP Accepted:        ${d[8]}`);
  console.log(`  Resolved:           ${d[9]}`);
  console.log(`  Outcome:            ${outcomeNames[Number(d[10])]}`);
  console.log(`  Counter Count:      ${d[12]}`);
  const [subsidyFunder, subsidyAmount] = await contracts.ilrm.stakeSubsidy(disputeId);
  if (subsidyAmount > 0n) {
    console.log(`  Subsidized Portion: ${ethers.formatEther(subsidyAmount)} tokens (funded by ${subsidyFunder})`);
  }

  try {
    const [round, , nonce, open] = await contracts.oracle.proposalContext(disputeId);
    console.log(`  Oracle Round:       ${round} (${open ? "open for a proposal" : "proposal submitted"})`);
    console.log(`  Oracle Nonce:       ${nonce}`);
    console.log(`  Oracle Request:     ${(await contracts.oracle.isPending(disputeId)) ? "pending" : "none"}`);
  } catch (err) {
    console.log(`  Oracle Round:       unavailable (${err.shortMessage || err.message})`);
  }
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
  // SIGNER_INDEX selects another configured account (e.g. the counterparty on localhost)
  const signer = (await ethers.getSigners())[Number(process.env.SIGNER_INDEX || 0)];
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
    case "reset-proposal":
      await resetProposal(contracts, signer);
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
      console.log("  submit-proposal    DISPUTE_ID=<id> PROPOSAL=<json>  (once per round; run again after counter-propose)");
      console.log("  reset-proposal     DISPUTE_ID=<id> REASON=<text> [PROPOSAL_HASH=<bytes32>]");
      console.log("                     (oracle owner; voids the current round's proposal in ILRM at once)");
      console.log("  accept-proposal    DISPUTE_ID=<id> [PROPOSAL_HASH=<bytes32>]  (hash-bound; see status)");
      console.log("  counter-propose    DISPUTE_ID=<id> [COUNTER_FEE=<eth>] [EVIDENCE_HASH=<bytes32>]");
      console.log("  enforce-timeout    DISPUTE_ID=<id>");
      console.log("  request-subsidy    DISPUTE_ID=<id> [MAX_SUBSIDY=<amount>]");
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
