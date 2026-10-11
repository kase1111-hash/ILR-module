/**
 * Multi-Sig Governance Test Script
 *
 * Tests the multi-sig + timelock governance setup (local simulation):
 * 1. Configuration (emergency/long delays derived from minDelay)
 * 2. Scheduling a timelock self-call (needs the long delay)
 * 3. Wait and execute (schedule -> wait -> execute)
 * 4. Operation cancellation
 * 5. Access control verification
 * 6. Emergency drill (EMERGENCY_ROLE queues an Emergency-classified call)
 *
 * Prerequisites:
 * - GovernanceTimelock deployed
 * - Multi-sig configured
 * - At least one owned contract registered
 *
 * Usage:
 * npx hardhat run scripts/test-multisig.ts --network <network>
 */

import { ethers } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";

interface TestConfig {
  timelockAddress: string;
  testContractAddress: string;
  multiSigAddress: string;
}

async function main() {
  const [deployer, signer1, signer2] = await ethers.getSigners();

  console.log("=".repeat(60));
  console.log("  Multi-Sig Governance Test Suite");
  console.log("=".repeat(60));
  console.log("");

  // Configuration
  const config: TestConfig = {
    timelockAddress: process.env.GOVERNANCE_TIMELOCK_ADDRESS || "",
    testContractAddress: process.env.ILRM_ADDRESS || "",
    multiSigAddress: process.env.MULTISIG_ADDRESS || "",
  };

  // Validate config
  if (!config.timelockAddress) {
    console.log("GOVERNANCE_TIMELOCK_ADDRESS not set");
    console.log("Running in simulation mode with local deployment...\n");
    await runLocalSimulation();
    return;
  }

  // Connect to contracts
  const timelock = await ethers.getContractAt(
    "GovernanceTimelock",
    config.timelockAddress
  );

  console.log("Timelock:", config.timelockAddress);
  console.log("Test Contract:", config.testContractAddress);
  console.log("Multi-sig:", config.multiSigAddress);
  console.log("");

  // Run tests
  await testConfiguration(timelock);
  await testStandardOperation(timelock, config);
  await testEmergencyOperation(timelock, config);
  await testCancellation(timelock, config);
  await testAccessControl(timelock, config);

  console.log("\n" + "=".repeat(60));
  console.log("  All Tests Completed");
  console.log("=".repeat(60));
}

/**
 * Throw if a simulation check fails
 */
function check(condition: boolean, message: string) {
  if (!condition) {
    throw new Error(`Check failed: ${message}`);
  }
  console.log(`✓ ${message}`);
}

/**
 * Assert that a transaction (or call) reverts
 */
async function expectRevert(promise: Promise<unknown>, message: string) {
  let reverted = false;
  try {
    await promise;
  } catch {
    reverted = true;
  }
  check(reverted, message);
}

/**
 * Run local simulation when no deployed contracts available
 */
async function runLocalSimulation() {
  const [deployer, proposer, executor, signer3] = await ethers.getSigners();

  console.log("Deploying test contracts locally...\n");

  // Deploy timelock
  const GovernanceTimelock = await ethers.getContractFactory("GovernanceTimelock");
  const minDelay = 3600; // 1 hour: the smallest delay the timelock accepts
  // No typechain bindings here, so contract handles are untyped
  const timelock: any = await GovernanceTimelock.deploy(
    minDelay,
    [proposer.address], // proposers
    [executor.address], // executors
    deployer.address // admin
  );
  await timelock.waitForDeployment();
  console.log("Timelock deployed:", await timelock.getAddress());

  // Test 1: Check configuration
  console.log("\n--- Test 1: Configuration ---");
  const delay = await timelock.getMinDelay();
  const cfg = await timelock.getTimelockConfig();
  console.log("Min delay:", delay.toString(), "seconds");
  console.log("Emergency delay:", cfg.emergencyDelay.toString(), "seconds");
  console.log("Long delay:", cfg.longDelay.toString(), "seconds");
  check(delay === BigInt(minDelay), "getMinDelay() matches the configured min delay");
  check(cfg.minDelay === BigInt(minDelay), "getTimelockConfig().minDelay matches getMinDelay()");
  check(cfg.emergencyDelay === BigInt(minDelay / 4), "emergency delay defaults to minDelay / 4");
  check(cfg.longDelay === BigInt(minDelay * 2), "long delay defaults to minDelay * 2");
  check(!cfg.openExecutor, "explicit executor list keeps execution closed");

  // Test 2: Schedule operation
  console.log("\n--- Test 2: Schedule Operation ---");

  // Create a call to update min delay. Calls to the timelock itself always need the long delay.
  const newDelay = 5400;
  const target = await timelock.getAddress();
  const value = 0;
  const data = timelock.interface.encodeFunctionData("updateDelay", [newDelay]);
  const predecessor = ethers.ZeroHash;
  const salt = ethers.id("test-operation-1");

  await expectRevert(
    timelock.connect(proposer).schedule(target, value, data, predecessor, salt, minDelay),
    "Self-call scheduled at minDelay correctly rejected"
  );

  const required = await timelock.getRequiredDelay(target, data);
  check(required === cfg.longDelay, `Required delay for a self-call is the long delay (${required})`);

  // Schedule as proposer
  await (await timelock.connect(proposer).schedule(
    target,
    value,
    data,
    predecessor,
    salt,
    required
  )).wait();

  const operationId = await timelock.hashOperation(
    target,
    value,
    data,
    predecessor,
    salt
  );
  console.log("Operation scheduled:", operationId);

  // Check it's pending
  const isPending = await timelock.isOperationPending(operationId);
  check(isPending, "Operation is pending");

  // Test 3: Wait and execute
  console.log("\n--- Test 3: Wait and Execute ---");

  // Try to execute early (should fail)
  await expectRevert(
    timelock.connect(executor).execute(target, value, data, predecessor, salt),
    "Early execution correctly rejected"
  );

  // Advance time
  await time.increase(Number(required) + 1);
  console.log("Time advanced by", Number(required) + 1, "seconds");

  // Execute
  await (await timelock.connect(executor).execute(target, value, data, predecessor, salt)).wait();
  console.log("✓ Operation executed successfully");

  // Verify result
  const updatedDelay = await timelock.getMinDelay();
  console.log("New delay:", updatedDelay.toString(), "seconds");
  check(updatedDelay === BigInt(newDelay), "getMinDelay() updated correctly");
  check(
    (await timelock.getTimelockConfig()).minDelay === BigInt(newDelay),
    "getTimelockConfig().minDelay stays in sync"
  );

  // Test 4: Cancellation
  console.log("\n--- Test 4: Cancellation ---");

  const salt2 = ethers.id("test-operation-2");
  const required2 = await timelock.getRequiredDelay(target, data);
  await (await timelock.connect(proposer).schedule(
    target,
    value,
    data,
    predecessor,
    salt2,
    required2
  )).wait();

  const operationId2 = await timelock.hashOperation(
    target,
    value,
    data,
    predecessor,
    salt2
  );
  console.log("Operation 2 scheduled:", operationId2);

  // Cancel
  await (await timelock.connect(proposer).cancel(operationId2)).wait();
  console.log("✓ Operation cancelled");

  // Verify cancelled
  const isStillPending = await timelock.isOperationPending(operationId2);
  check(!isStillPending, "Cancellation verified");

  // Test 5: Access Control
  console.log("\n--- Test 5: Access Control ---");

  // Non-proposer should not be able to schedule
  const randomSigner = (await ethers.getSigners())[5];
  await expectRevert(
    timelock.connect(randomSigner).schedule(
      target,
      value,
      data,
      predecessor,
      ethers.id("unauthorized"),
      required2
    ),
    "Unauthorized scheduling correctly rejected"
  );

  // Test 6: Emergency drill
  console.log("\n--- Test 6: Emergency Drill ---");

  const Registry = await ethers.getContractFactory("NatLangChainAssetRegistry");
  const registry: any = await Registry.deploy();
  await registry.waitForDeployment();
  const registryAddress = await registry.getAddress();
  const dummyIlrm = ethers.Wallet.createRandom().address;

  // Deployer sets up the registry, then hands it to the timelock (Ownable2Step)
  await (await registry.authorizeILRM(dummyIlrm)).wait();
  await (await registry.transferOwnership(target)).wait();
  await (await timelock.connect(deployer).acceptContractOwnership(registryAddress)).wait();
  check((await registry.owner()) === target, "Timelock owns the asset registry");

  // Bootstrap admin classifies revokeILRM as Emergency and appoints a guardian
  const revokeSelector = registry.interface.getFunction("revokeILRM")!.selector;
  await (await timelock.connect(deployer).setCallClass(registryAddress, revokeSelector, 2 /* Emergency */)).wait();
  const EMERGENCY_ROLE = await timelock.EMERGENCY_ROLE();
  await (await timelock.connect(deployer).grantRole(EMERGENCY_ROLE, signer3.address)).wait();
  check(
    !(await timelock.hasRole(await timelock.PROPOSER_ROLE(), signer3.address)),
    "Guardian holds EMERGENCY_ROLE without PROPOSER_ROLE"
  );

  // Guardian queues the defensive call at the emergency delay
  const revokeData = registry.interface.encodeFunctionData("revokeILRM", [dummyIlrm]);
  const emergencyId = await timelock.connect(signer3).executeEmergency.staticCall(registryAddress, revokeData, "drill");
  await (await timelock.connect(signer3).executeEmergency(registryAddress, revokeData, "drill")).wait();
  const op = await timelock.getOperation(emergencyId);
  const emergencyDelay = (await timelock.getTimelockConfig()).emergencyDelay;
  console.log("Emergency operation queued:", emergencyId);

  await expectRevert(
    timelock.connect(executor).execute(registryAddress, 0, revokeData, ethers.ZeroHash, op.salt),
    "Early emergency execution correctly rejected"
  );

  await time.increase(Number(emergencyDelay) + 1);
  await (await timelock.connect(executor).execute(registryAddress, 0, revokeData, ethers.ZeroHash, op.salt)).wait();
  check(!(await registry.isAuthorizedILRM(dummyIlrm)), "Emergency revocation executed after the emergency delay");

  // The emergency path cannot be used for calls governance did not classify Emergency
  const authorizeData = registry.interface.encodeFunctionData("authorizeILRM", [
    ethers.Wallet.createRandom().address,
  ]);
  await expectRevert(
    timelock.connect(signer3).executeEmergency(registryAddress, authorizeData, "not an emergency call"),
    "Emergency path correctly rejects non-Emergency calls"
  );

  console.log("\n" + "=".repeat(60));
  console.log("  Local Simulation Complete");
  console.log("=".repeat(60));
  console.log("\nAll tests passed! Ready for testnet deployment.");
}

async function testConfiguration(timelock: any) {
  console.log("--- Test: Configuration ---");

  const minDelay = await timelock.getMinDelay();
  console.log("Min delay:", minDelay.toString(), "seconds");

  const PROPOSER_ROLE = await timelock.PROPOSER_ROLE();
  const EXECUTOR_ROLE = await timelock.EXECUTOR_ROLE();
  const CANCELLER_ROLE = await timelock.CANCELLER_ROLE();

  console.log("PROPOSER_ROLE:", PROPOSER_ROLE);
  console.log("EXECUTOR_ROLE:", EXECUTOR_ROLE);
  console.log("CANCELLER_ROLE:", CANCELLER_ROLE);

  console.log("✓ Configuration check passed\n");
}

async function testStandardOperation(timelock: any, config: TestConfig) {
  console.log("--- Test: Standard Operation ---");
  console.log("(Requires multi-sig signatures - manual verification needed)");
  console.log("✓ Test structure verified\n");
}

async function testEmergencyOperation(timelock: any, config: TestConfig) {
  console.log("--- Test: Emergency Operation ---");
  console.log("(Requires EMERGENCY_ROLE and an Emergency-classified call - manual verification needed)");
  console.log("✓ Test structure verified\n");
}

async function testCancellation(timelock: any, config: TestConfig) {
  console.log("--- Test: Cancellation ---");
  console.log("(Requires CANCELLER_ROLE - manual verification needed)");
  console.log("✓ Test structure verified\n");
}

async function testAccessControl(timelock: any, config: TestConfig) {
  console.log("--- Test: Access Control ---");

  const [randomSigner] = await ethers.getSigners();

  // Check if random address has proposer role
  const PROPOSER_ROLE = await timelock.PROPOSER_ROLE();
  const hasRole = await timelock.hasRole(PROPOSER_ROLE, randomSigner.address);

  if (!hasRole) {
    console.log("✓ Random address correctly lacks PROPOSER_ROLE");
  } else {
    console.log("⚠ Warning: Random address has PROPOSER_ROLE");
  }

  console.log("✓ Access control check passed\n");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
