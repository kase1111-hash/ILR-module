/**
 * Governance Deployment Script
 *
 * Deploys and configures the NatLangChain governance infrastructure:
 * 1. GovernanceTimelock with multi-sig as proposer
 * 2. Register all protocol contracts
 * 3. Transfer ownership from deployer to timelock
 *
 * Prerequisites:
 * - Multi-sig wallet deployed (Gnosis Safe recommended)
 * - All protocol contracts deployed
 *
 * Usage:
 * npx hardhat run scripts/deploy-governance.ts --network <network>
 */

import { ethers } from "hardhat";

interface DeploymentConfig {
  // Multi-sig address (Gnosis Safe)
  multiSigAddress: string;

  // Timelock delays
  minDelay: number; // seconds (e.g., 2 days = 172800)
  emergencyDelay: number; // seconds (e.g., 12 hours = 43200)
  longDelay: number; // seconds (e.g., 4 days = 345600)

  // Protocol contract addresses
  ilrmAddress: string;
  treasuryAddress: string;
  oracleAddress: string;
  assetRegistryAddress: string;
  multiPartyILRMAddress?: string;
  complianceCouncilAddress?: string;
  batchQueueAddress?: string;
  dummyGeneratorAddress?: string;

  // Whether anyone can execute after delay
  openExecutor: boolean;
}

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying governance with account:", deployer.address);
  console.log("Account balance:", (await ethers.provider.getBalance(deployer.address)).toString());

  // Configuration - UPDATE THESE VALUES FOR YOUR DEPLOYMENT
  const config: DeploymentConfig = {
    // Multi-sig address (Gnosis Safe)
    multiSigAddress: process.env.MULTISIG_ADDRESS || "0x0000000000000000000000000000000000000000",

    // Delays
    minDelay: 2 * 24 * 60 * 60, // 2 days
    emergencyDelay: 12 * 60 * 60, // 12 hours
    longDelay: 4 * 24 * 60 * 60, // 4 days

    // Protocol contracts - UPDATE THESE
    ilrmAddress: process.env.ILRM_ADDRESS || "0x0000000000000000000000000000000000000000",
    treasuryAddress: process.env.TREASURY_ADDRESS || "0x0000000000000000000000000000000000000000",
    oracleAddress: process.env.ORACLE_ADDRESS || "0x0000000000000000000000000000000000000000",
    assetRegistryAddress: process.env.ASSET_REGISTRY_ADDRESS || "0x0000000000000000000000000000000000000000",
    multiPartyILRMAddress: process.env.MULTI_PARTY_ILRM_ADDRESS,
    complianceCouncilAddress: process.env.COMPLIANCE_COUNCIL_ADDRESS,
    batchQueueAddress: process.env.BATCH_QUEUE_ADDRESS,
    dummyGeneratorAddress: process.env.DUMMY_GENERATOR_ADDRESS,

    // Anyone can execute after delay
    openExecutor: true,
  };

  // Validate config
  if (config.multiSigAddress === "0x0000000000000000000000000000000000000000") {
    throw new Error("Multi-sig address not configured");
  }

  console.log("\n=== Deployment Configuration ===");
  console.log("Multi-sig:", config.multiSigAddress);
  console.log("Min delay:", config.minDelay, "seconds");
  console.log("Emergency delay:", config.emergencyDelay, "seconds");
  console.log("Long delay:", config.longDelay, "seconds");
  console.log("Open executor:", config.openExecutor);

  // Deploy GovernanceTimelock
  console.log("\n=== Deploying GovernanceTimelock ===");

  const GovernanceTimelock = await ethers.getContractFactory("GovernanceTimelock");

  // Proposers: multi-sig only
  const proposers = [config.multiSigAddress];

  // Executors: empty array for open executor, or specific addresses
  const executors = config.openExecutor ? [] : [config.multiSigAddress];

  const timelock = await GovernanceTimelock.deploy(
    config.minDelay,
    proposers,
    executors,
    deployer.address // Admin for initial setup
  );

  await timelock.waitForDeployment();
  const timelockAddress = await timelock.getAddress();
  console.log("GovernanceTimelock deployed to:", timelockAddress);

  // Configure delays
  console.log("\n=== Configuring Delays ===");
  const updateDelaysTx = await timelock.updateDelays(
    config.minDelay,
    config.emergencyDelay,
    config.longDelay
  );
  await updateDelaysTx.wait();
  console.log("Delays configured");

  // Register protocol contracts
  console.log("\n=== Registering Protocol Contracts ===");

  const contractsToRegister = [
    { name: "ilrm", address: config.ilrmAddress },
    { name: "treasury", address: config.treasuryAddress },
    { name: "oracle", address: config.oracleAddress },
    { name: "assetRegistry", address: config.assetRegistryAddress },
  ];

  // Add optional contracts if provided
  if (config.multiPartyILRMAddress) {
    contractsToRegister.push({ name: "multiPartyILRM", address: config.multiPartyILRMAddress });
  }
  if (config.complianceCouncilAddress) {
    contractsToRegister.push({ name: "complianceCouncil", address: config.complianceCouncilAddress });
  }
  if (config.batchQueueAddress) {
    contractsToRegister.push({ name: "batchQueue", address: config.batchQueueAddress });
  }
  if (config.dummyGeneratorAddress) {
    contractsToRegister.push({ name: "dummyGenerator", address: config.dummyGeneratorAddress });
  }

  for (const contract of contractsToRegister) {
    if (contract.address !== "0x0000000000000000000000000000000000000000") {
      const tx = await timelock.registerProtocolContract(contract.name, contract.address);
      await tx.wait();
      console.log(`Registered ${contract.name}: ${contract.address}`);
    }
  }

  // Grant EMERGENCY_ROLE to multi-sig
  console.log("\n=== Granting Emergency Role ===");
  const EMERGENCY_ROLE = await timelock.EMERGENCY_ROLE();
  const grantEmergencyTx = await timelock.grantRole(EMERGENCY_ROLE, config.multiSigAddress);
  await grantEmergencyTx.wait();
  console.log("Emergency role granted to multi-sig");

  // Grant CANCELLER_ROLE to multi-sig
  const CANCELLER_ROLE = await timelock.CANCELLER_ROLE();
  const grantCancellerTx = await timelock.grantRole(CANCELLER_ROLE, config.multiSigAddress);
  await grantCancellerTx.wait();
  console.log("Canceller role granted to multi-sig");

  // Transfer ownership of protocol contracts
  console.log("\n=== Transferring Ownership ===");
  console.log("IMPORTANT: After this step, execute ownership transfers via multi-sig");

  // For each Ownable contract, we need to:
  // 1. Call transferOwnership(timelockAddress) from deployer
  // 2. Then call acceptOwnership() from timelock (via multi-sig proposal)

  // Print instructions for ownership transfer
  console.log("\n=== Manual Steps Required ===");
  console.log("1. For each protocol contract, call transferOwnership(timelockAddress)");
  console.log("2. Create multi-sig proposal to call acceptOwnership() on timelock");
  console.log("3. After all ownership transfers, renounce DEFAULT_ADMIN_ROLE on timelock\n");

  // Renounce deployer's admin role (optional, do this after ownership transfers are complete)
  // const DEFAULT_ADMIN_ROLE = await timelock.DEFAULT_ADMIN_ROLE();
  // await timelock.renounceRole(DEFAULT_ADMIN_ROLE, deployer.address);

  console.log("\n=== Deployment Summary ===");
  console.log("GovernanceTimelock:", timelockAddress);
  console.log("Multi-sig (Proposer):", config.multiSigAddress);
  console.log("Min Delay:", config.minDelay, "seconds");
  console.log("Emergency Delay:", config.emergencyDelay, "seconds");
  console.log("Long Delay:", config.longDelay, "seconds");

  // Save deployment info
  const deploymentInfo = {
    network: (await ethers.provider.getNetwork()).name,
    chainId: (await ethers.provider.getNetwork()).chainId.toString(),
    deployer: deployer.address,
    timestamp: new Date().toISOString(),
    contracts: {
      governanceTimelock: timelockAddress,
      multiSig: config.multiSigAddress,
    },
    config: {
      minDelay: config.minDelay,
      emergencyDelay: config.emergencyDelay,
      longDelay: config.longDelay,
      openExecutor: config.openExecutor,
    },
    registeredContracts: contractsToRegister.filter(
      (c) => c.address !== "0x0000000000000000000000000000000000000000"
    ),
  };

  console.log("\n=== Deployment Info ===");
  console.log(JSON.stringify(deploymentInfo, null, 2));

  return deploymentInfo;
}

// Helper function to transfer ownership of a contract
async function transferContractOwnership(
  contractAddress: string,
  newOwner: string,
  contractName: string
) {
  const [deployer] = await ethers.getSigners();

  // Generic Ownable interface
  const ownableAbi = [
    "function transferOwnership(address newOwner)",
    "function owner() view returns (address)",
  ];

  const contract = new ethers.Contract(contractAddress, ownableAbi, deployer);

  const currentOwner = await contract.owner();
  if (currentOwner.toLowerCase() !== deployer.address.toLowerCase()) {
    console.log(`${contractName}: Not owner, skipping`);
    return false;
  }

  const tx = await contract.transferOwnership(newOwner);
  await tx.wait();
  console.log(`${contractName}: Ownership transfer initiated to ${newOwner}`);
  return true;
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
