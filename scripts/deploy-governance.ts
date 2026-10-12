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
 *
 * Policy check (no deployment): resolve every call-policy selector against the compiled artifacts and
 * fail if a required one is missing:
 * GOVERNANCE_POLICY_CHECK=1 npx hardhat run scripts/deploy-governance.ts
 */

import { artifacts, ethers } from "hardhat";

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

/** Addresses the call policy is built from (undefined entries are skipped when applying it) */
export type PolicyAddresses = Partial<
  Pick<
    DeploymentConfig,
    | "ilrmAddress"
    | "treasuryAddress"
    | "oracleAddress"
    | "assetRegistryAddress"
    | "multiPartyILRMAddress"
    | "complianceCouncilAddress"
    | "batchQueueAddress"
    | "dummyGeneratorAddress"
  >
>;

/** Delay class values, mirroring IGovernanceTimelock.CallClass */
export const CallClass = {
  Standard: 0,
  LongDelay: 1,
  Emergency: 2,
} as const;

export interface CallPolicyEntry {
  // Fully qualified Hardhat artifact name ("path/File.sol:Contract"), so a second contract with the
  // same name can never make the lookup ambiguous
  contractName: string;
  // Deployed address (entries with a zero/undefined address are skipped)
  address?: string;
  // Full function signature, e.g. "setILRM(address)"
  signature: string;
  callClass: number;
  // An unresolvable required entry aborts the deployment; an optional one only warns and is skipped
  required: boolean;
}

export interface AppliedCallPolicy {
  contract: string;
  target: string;
  signature: string;
  selector: string;
  callClass: "LongDelay" | "Emergency";
}

/** Outcome of resolving one selector: the selector, or why it could not be resolved */
export type SelectorResolution = { selector: string; error?: undefined } | { selector?: undefined; error: string };

/** Reads an artifact ABI by (fully qualified) contract name; injectable for tests */
export type ArtifactReader = (contractName: string) => Promise<{ abi: any[] }>;

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

const ILRM = "contracts/ILRM.sol:ILRM";
const ORACLE = "contracts/Oracle.sol:NatLangChainOracle";
const TREASURY = "contracts/Treasury.sol:NatLangChainTreasury";
const ASSET_REGISTRY = "contracts/AssetRegistry.sol:NatLangChainAssetRegistry";
const MULTI_PARTY_ILRM = "contracts/modules/MultiPartyILRM.sol:MultiPartyILRM";
const COMPLIANCE_COUNCIL = "contracts/modules/ComplianceCouncil.sol:ComplianceCouncil";
const BATCH_QUEUE = "contracts/scaling/BatchQueue.sol:BatchQueue";
const DUMMY_GENERATOR = "contracts/scaling/DummyTransactionGenerator.sol:DummyTransactionGenerator";

/**
 * Call policy applied while the deployer still holds DEFAULT_ADMIN_ROLE.
 *
 * Ownership/role/upgrade/multicall selectors and every call to the timelock itself are hard-locked to
 * LongDelay by the contract. This list adds protocol-specific privileged setters (LongDelay) and the
 * defensive calls the EMERGENCY_ROLE may queue through executeEmergency (Emergency, default-deny).
 *
 * Not classified on purpose (Standard, minDelay): parameter setters (Treasury.updateCaps/setMinReserve/
 * setHarassmentScore, ILRM.updateHarassmentScore, Oracle.registerOracle/updateOracleKey/resetProposal; the
 * pinned Oracle.resetProposalExact is Emergency because its effect is bounded to the named proposal)
 * and pause()/unpause(). The timelock rejects unpause() as Emergency and binds every queued unpause to
 * the pause epoch it was scheduled in. Treasury.fundStakeSubsidy is onlyILRM (never called by the
 * timelock), so it needs no class.
 */
export function buildCallPolicy(config: PolicyAddresses): CallPolicyEntry[] {
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
    // LongDelay: wiring and fund movements of the core contracts (required)
    longDelay(ORACLE, config.oracleAddress, "setILRM(address)"),
    longDelay(TREASURY, config.treasuryAddress, "setILRM(address)"),
    longDelay(TREASURY, config.treasuryAddress, "emergencyWithdraw(address,uint256)"),
    longDelay(TREASURY, config.treasuryAddress, "emergencyWithdrawETH(address,uint256)"),
    longDelay(ILRM, config.ilrmAddress, "withdrawTreasury(address,uint256)"),
    longDelay(ILRM, config.ilrmAddress, "setSubsidyTreasury(address)"),
    // Incentive caps bound how much of tokenReserves sybil farming can extract; raising them is a fund movement
    longDelay(ILRM, config.ilrmAddress, "setInitiatorIncentiveCaps(uint256,uint256,uint256)"),
    longDelay(ASSET_REGISTRY, config.assetRegistryAddress, "authorizeILRM(address)"),

    // LongDelay: optional modules, classified when deployed (warn if missing)
    longDelay(COMPLIANCE_COUNCIL, config.complianceCouncilAddress, "setGovernanceTimelock(address)", false),
    longDelay(COMPLIANCE_COUNCIL, config.complianceCouncilAddress, "setComplianceEscrow(address)", false),
    // Access control: who may request warrants, and evicting council members (signers of the threshold set)
    longDelay(COMPLIANCE_COUNCIL, config.complianceCouncilAddress, "setAuthorizedRequester(address,bool)", false),
    longDelay(COMPLIANCE_COUNCIL, config.complianceCouncilAddress, "removeMember(address)", false),
    longDelay(MULTI_PARTY_ILRM, config.multiPartyILRMAddress, "withdrawTreasury(address,uint256)", false),
    longDelay(BATCH_QUEUE, config.batchQueueAddress, "emergencyWithdraw(address,uint256,bool)", false),
    longDelay(DUMMY_GENERATOR, config.dummyGeneratorAddress, "withdrawTreasury(address,uint256)", false),
    // Wiring: the ILRM and BatchQueue the generator submits dummy transactions to
    longDelay(DUMMY_GENERATOR, config.dummyGeneratorAddress, "setTargetContracts(address,address)", false),

    // Emergency: defensive calls EMERGENCY_ROLE may queue at the emergency delay
    emergency(ORACLE, config.oracleAddress, "revokeOracle(address)"),
    emergency(ORACLE, config.oracleAddress, "cancelPendingRequest(uint256)"),
    emergency(ASSET_REGISTRY, config.assetRegistryAddress, "revokeILRM(address)"),
    // Voids only the named (round, proposal hash) and reverts if a later proposal has landed
    emergency(ORACLE, config.oracleAddress, "resetProposalExact(uint256,uint256,bytes32,string)"),
  ];
}

/** First line of an error message (Hardhat errors are multi-line) */
function firstLine(error: unknown): string {
  const message = error instanceof Error ? error.message : String(error);
  return message.split("\n")[0].trim();
}

/**
 * Resolve a function selector from the compiled artifact.
 *
 * Never throws: a missing artifact (HH700), an ambiguous contract name (HH701), an unparsable ABI or
 * a function that does not exist is returned as `{ error }`, so the caller decides whether the entry
 * is fatal (required) or only warns (optional).
 */
export async function resolveSelector(
  contractName: string,
  signature: string,
  readArtifact: ArtifactReader = (name) => artifacts.readArtifact(name)
): Promise<SelectorResolution> {
  try {
    const artifact = await readArtifact(contractName);
    const fragment = new ethers.Interface(artifact.abi).getFunction(signature);
    if (!fragment) {
      return { error: `${contractName}.${signature} not found in the compiled artifact` };
    }
    return { selector: fragment.selector };
  } catch (error) {
    return { error: `${contractName}.${signature} could not be resolved: ${firstLine(error)}` };
  }
}

/** Class name used in logs and the deployment summary */
function className(callClass: number): "LongDelay" | "Emergency" {
  return callClass === CallClass.LongDelay ? "LongDelay" : "Emergency";
}

/**
 * Apply the call policy on a timelock the caller administers (setCallClass).
 * Entries without an address are skipped. An unresolvable required entry throws before anything
 * else is applied; an unresolvable optional entry only warns.
 */
export async function applyCallPolicy(
  timelock: any,
  entries: CallPolicyEntry[],
  readArtifact?: ArtifactReader
): Promise<AppliedCallPolicy[]> {
  const deployable = entries.filter((entry) => entry.address && entry.address !== ZERO_ADDRESS);

  // Resolve everything first, so a broken required entry aborts before any class is written
  const resolved: { entry: CallPolicyEntry; selector: string }[] = [];
  for (const entry of deployable) {
    const result = await resolveSelector(entry.contractName, entry.signature, readArtifact);
    if (result.error !== undefined) {
      if (entry.required) {
        throw new Error(`${result.error}; cannot classify it ${className(entry.callClass)}`);
      }
      console.warn(`WARNING: ${result.error}; skipping ${className(entry.callClass)} classification`);
      continue;
    }
    resolved.push({ entry, selector: result.selector });
  }

  const applied: AppliedCallPolicy[] = [];
  for (const { entry, selector } of resolved) {
    const tx = await timelock.setCallClass(entry.address, selector, entry.callClass);
    await tx.wait();
    applied.push({
      contract: entry.contractName,
      target: entry.address as string,
      signature: entry.signature,
      selector,
      callClass: className(entry.callClass),
    });
    console.log(`${className(entry.callClass)}: ${entry.contractName}.${entry.signature} (${selector}) @ ${entry.address}`);
  }
  return applied;
}

/**
 * Resolve every policy entry (regardless of addresses) against the compiled artifacts.
 * Throws if a required entry cannot be resolved; optional ones are reported as warnings.
 */
export async function checkCallPolicy(
  readArtifact?: ArtifactReader
): Promise<{ entry: CallPolicyEntry; resolution: SelectorResolution }[]> {
  const report: { entry: CallPolicyEntry; resolution: SelectorResolution }[] = [];
  for (const entry of buildCallPolicy({})) {
    report.push({ entry, resolution: await resolveSelector(entry.contractName, entry.signature, readArtifact) });
  }

  for (const { entry, resolution } of report) {
    const status = resolution.error !== undefined ? (entry.required ? "MISSING" : "WARNING") : resolution.selector;
    console.log(`${className(entry.callClass).padEnd(9)} ${status.padEnd(10)} ${entry.contractName}.${entry.signature}`);
  }

  const missing = report.filter(({ entry, resolution }) => entry.required && resolution.error !== undefined);
  if (missing.length > 0) {
    throw new Error(`Required call-policy entries not resolvable:\n${missing.map((m) => m.resolution.error).join("\n")}`);
  }
  return report;
}

async function main() {
  if (process.env.GOVERNANCE_POLICY_CHECK) {
    console.log("=== Call Policy Check (compiled artifacts) ===");
    await checkCallPolicy();
    return;
  }

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

    // Anyone can execute after delay. With false, the multi-sig is the only executor, and the timelock
    // refuses any role change that would leave EXECUTOR_ROLE without a holder other than itself.
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

  // Fail fast, before deploying anything, if a required call-policy selector no longer exists
  console.log("\n=== Checking Call Policy ===");
  await checkCallPolicy();

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
  const callPolicy = await applyCallPolicy(timelock, buildCallPolicy(config));

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
export async function transferContractOwnership(
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

// Run only when executed as a script (hardhat run), not when imported (policy tests)
if (require.main === module) {
  main()
    .then(() => process.exit(0))
    .catch((error) => {
      console.error(error);
      process.exit(1);
    });
}
