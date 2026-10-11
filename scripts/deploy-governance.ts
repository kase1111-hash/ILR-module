/**
 * Governance Deployment Script
 *
 * Deploys and configures the NatLangChain governance infrastructure:
 * 1. GovernanceTimelock with multi-sig as proposer
 * 2. Register all protocol contracts
 * 3. Configure the call policy (LongDelay / Emergency call classes)
 * 4. Grant EMERGENCY_ROLE and CANCELLER_ROLE to the multi-sig
 * 5. Print the manual ownership-transfer and admin-renounce steps
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

/** Delay class values, mirroring IGovernanceTimelock.CallClass */
const CallClass = {
  Standard: 0,
  LongDelay: 1,
  Emergency: 2,
} as const;

interface CallPolicyEntry {
  // Hardhat artifact name of the protocol contract
  contractName: string;
  // Deployed address (entries with a zero/undefined address are skipped)
  address?: string;
  // Full function signature, e.g. "setILRM(address)"
  signature: string;
  callClass: number;
  // Missing LongDelay functions abort the deployment; missing Emergency or optional functions only warn
  required: boolean;
}

interface AppliedCallPolicy {
  contract: string;
  target: string;
  signature: string;
  selector: string;
  callClass: "LongDelay" | "Emergency";
}

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

/**
 * Call policy applied while the deployer still holds DEFAULT_ADMIN_ROLE.
 *
 * Ownership/role/upgrade/multicall selectors and every call to the timelock itself are hard-locked to
 * LongDelay by the contract. This list adds protocol-specific privileged setters (LongDelay) and the
 * defensive calls the EMERGENCY_ROLE may queue through executeEmergency (Emergency, default-deny).
 */
function buildCallPolicy(config: DeploymentConfig): CallPolicyEntry[] {
  const longDelay = (
    contractName: string,
    address: string | undefined,
    signature: string,
    required = true
  ): CallPolicyEntry => ({ contractName, address, signature, callClass: CallClass.LongDelay, required });
  const emergency = (contractName: string, address: string | undefined, signature: string): CallPolicyEntry => ({
    contractName,
    address,
    signature,
    callClass: CallClass.Emergency,
    required: false,
  });

  return [
    // LongDelay: wiring and fund movements
    longDelay("NatLangChainOracle", config.oracleAddress, "setILRM(address)"),
    longDelay("NatLangChainTreasury", config.treasuryAddress, "setILRM(address)"),
    longDelay("NatLangChainTreasury", config.treasuryAddress, "emergencyWithdraw(address,uint256)"),
    longDelay("NatLangChainTreasury", config.treasuryAddress, "emergencyWithdrawETH(address,uint256)"),
    longDelay("ILRM", config.ilrmAddress, "withdrawTreasury(address,uint256)"),
    longDelay("NatLangChainAssetRegistry", config.assetRegistryAddress, "authorizeILRM(address)"),
    // Optional module, not hard-locked by the timelock: classify it when deployed (warn if missing)
    longDelay("ComplianceCouncil", config.complianceCouncilAddress, "setGovernanceTimelock(address)", false),

    // Emergency: defensive calls EMERGENCY_ROLE may queue at the emergency delay
    emergency("NatLangChainOracle", config.oracleAddress, "revokeOracle(address)"),
    emergency("NatLangChainOracle", config.oracleAddress, "cancelPendingRequest(uint256)"),
    emergency("NatLangChainAssetRegistry", config.assetRegistryAddress, "revokeILRM(address)"),
  ];
}

/**
 * Resolve a function selector from the compiled artifact, or null when the function does not exist
 */
async function resolveSelector(contractName: string, signature: string): Promise<string | null> {
  const factory = await ethers.getContractFactory(contractName);
  const fragment = factory.interface.getFunction(signature);
  return fragment ? fragment.selector : null;
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

  // Configure call policy (must happen while the deployer still holds DEFAULT_ADMIN_ROLE; afterwards
  // every setCallClass change is a timelock self-call that needs the long delay)
  console.log("\n=== Configuring Call Policy ===");
  const callPolicy: AppliedCallPolicy[] = [];
  for (const entry of buildCallPolicy(config)) {
    if (!entry.address || entry.address === ZERO_ADDRESS) {
      continue;
    }
    const className = entry.callClass === CallClass.LongDelay ? "LongDelay" : "Emergency";
    const selector = await resolveSelector(entry.contractName, entry.signature);
    if (!selector) {
      const message = `${entry.contractName}.${entry.signature} not found in the compiled artifact`;
      if (entry.required) {
        throw new Error(`${message}; cannot classify it ${className}`);
      }
      console.warn(`WARNING: ${message}; skipping ${className} classification`);
      continue;
    }
    const tx = await timelock.setCallClass(entry.address, selector, entry.callClass);
    await tx.wait();
    callPolicy.push({
      contract: entry.contractName,
      target: entry.address,
      signature: entry.signature,
      selector,
      callClass: className,
    });
    console.log(`${className}: ${entry.contractName}.${entry.signature} (${selector}) @ ${entry.address}`);
  }

  // Grant EMERGENCY_ROLE to multi-sig. The deployer (bootstrap admin) is no longer granted
  // EMERGENCY_ROLE by the constructor, so this explicit grant is the only emergency holder.
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

  // For each Ownable2Step contract, we need to:
  // 1. Call transferOwnership(timelockAddress) from deployer
  // 2. Accept ownership on behalf of the timelock (see manual step 2)

  // Print instructions for ownership transfer
  console.log("\n=== Manual Steps Required ===");
  console.log("1. For each protocol contract, call transferOwnership(timelockAddress) from the deployer");
  console.log("2. Accept ownership for the timelock, either:");
  console.log("   a. bootstrap admin (deployer) calls timelock.acceptContractOwnership(contractAddress)");
  console.log("      BEFORE renouncing DEFAULT_ADMIN_ROLE, or");
  console.log("   b. multi-sig proposal: target = the protocol contract, data = acceptOwnership(),");
  console.log("      scheduled at minDelay and executed after the delay.");
  console.log("   Note: any proposal whose target is the timelock itself needs the long delay.");
  console.log("3. After all ownership transfers, the deployer itself sends");
  console.log("   timelock.renounceRole(DEFAULT_ADMIN_ROLE, deployerAddress)");
  console.log("   (renounceRole only accepts the caller's own address)\n");

  // Renounce deployer's admin role (do this after ownership transfers are complete; must be sent by the deployer)
  // const DEFAULT_ADMIN_ROLE = await timelock.DEFAULT_ADMIN_ROLE();
  // await timelock.connect(deployer).renounceRole(DEFAULT_ADMIN_ROLE, deployer.address);

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
    callPolicy,
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
