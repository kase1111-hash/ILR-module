/**
 * Contract Verification Script
 *
 * Verifies all deployed contracts on block explorers.
 *
 * Usage:
 *   npx hardhat run scripts/verify-contracts.js --network <network>
 *
 * Prerequisites:
 *   - Contracts deployed
 *   - Contract addresses in .env
 *   - Block explorer API key configured
 */

const hre = require("hardhat");

// Contract addresses from environment or deployment output
const ADDRESSES = {
  token: process.env.PRODUCTION_TOKEN_ADDRESS || "",
  oracle: process.env.ORACLE_ADDRESS || "",
  assetRegistry: process.env.ASSET_REGISTRY_ADDRESS || "",
  ilrm: process.env.ILRM_ADDRESS || "",
  treasury: process.env.TREASURY_ADDRESS || "",
  governanceTimelock: process.env.GOVERNANCE_TIMELOCK_ADDRESS || "",
};

// Treasury constructor args
const TREASURY_ARGS = {
  maxPerDispute: hre.ethers.parseEther("1"),
  maxPerParticipant: hre.ethers.parseEther("10"),
  windowDuration: 30 * 24 * 60 * 60, // 30 days
};

// Governance constructor args
const GOVERNANCE_ARGS = {
  minDelay: 2 * 24 * 60 * 60, // 2 days
  proposers: [process.env.MULTISIG_ADDRESS || ""],
  executors: [], // Open executor
  admin: "", // Will be set during deployment
};

async function verifyContract(name, address, constructorArgs = []) {
  console.log(`\nVerifying ${name} at ${address}...`);

  if (!address || address === "0x0000000000000000000000000000000000000000") {
    console.log(`  Skipping: No address configured for ${name}`);
    return false;
  }

  try {
    await hre.run("verify:verify", {
      address: address,
      constructorArguments: constructorArgs,
    });
    console.log(`  ✅ ${name} verified successfully`);
    return true;
  } catch (error) {
    if (error.message.includes("Already Verified")) {
      console.log(`  ⏭️  ${name} already verified`);
      return true;
    }
    console.error(`  ❌ ${name} verification failed:`, error.message);
    return false;
  }
}

async function main() {
  console.log("=".repeat(60));
  console.log("Contract Verification Script");
  console.log("=".repeat(60));
  console.log(`Network: ${hre.network.name}`);
  console.log(`Chain ID: ${(await hre.ethers.provider.getNetwork()).chainId}`);

  const results = {
    success: [],
    failed: [],
    skipped: [],
  };

  // 1. Verify Oracle (no constructor args)
  if (await verifyContract("Oracle", ADDRESSES.oracle, [])) {
    results.success.push("Oracle");
  } else if (ADDRESSES.oracle) {
    results.failed.push("Oracle");
  } else {
    results.skipped.push("Oracle");
  }

  // 2. Verify AssetRegistry (no constructor args)
  if (await verifyContract("AssetRegistry", ADDRESSES.assetRegistry, [])) {
    results.success.push("AssetRegistry");
  } else if (ADDRESSES.assetRegistry) {
    results.failed.push("AssetRegistry");
  } else {
    results.skipped.push("AssetRegistry");
  }

  // 3. Verify ILRM (token, oracle, registry)
  if (ADDRESSES.ilrm && ADDRESSES.token && ADDRESSES.oracle && ADDRESSES.assetRegistry) {
    if (await verifyContract("ILRM", ADDRESSES.ilrm, [
      ADDRESSES.token,
      ADDRESSES.oracle,
      ADDRESSES.assetRegistry,
    ])) {
      results.success.push("ILRM");
    } else {
      results.failed.push("ILRM");
    }
  } else {
    results.skipped.push("ILRM");
  }

  // 4. Verify Treasury (token, maxPerDispute, maxPerParticipant, windowDuration)
  if (ADDRESSES.treasury && ADDRESSES.token) {
    if (await verifyContract("Treasury", ADDRESSES.treasury, [
      ADDRESSES.token,
      TREASURY_ARGS.maxPerDispute,
      TREASURY_ARGS.maxPerParticipant,
      TREASURY_ARGS.windowDuration,
    ])) {
      results.success.push("Treasury");
    } else {
      results.failed.push("Treasury");
    }
  } else {
    results.skipped.push("Treasury");
  }

  // 5. Verify GovernanceTimelock (minDelay, proposers, executors, admin)
  if (ADDRESSES.governanceTimelock && GOVERNANCE_ARGS.admin) {
    if (await verifyContract("GovernanceTimelock", ADDRESSES.governanceTimelock, [
      GOVERNANCE_ARGS.minDelay,
      GOVERNANCE_ARGS.proposers,
      GOVERNANCE_ARGS.executors,
      GOVERNANCE_ARGS.admin,
    ])) {
      results.success.push("GovernanceTimelock");
    } else {
      results.failed.push("GovernanceTimelock");
    }
  } else {
    results.skipped.push("GovernanceTimelock");
  }

  // Summary
  console.log("\n" + "=".repeat(60));
  console.log("Verification Summary");
  console.log("=".repeat(60));
  console.log(`✅ Verified: ${results.success.length}`);
  results.success.forEach(c => console.log(`   - ${c}`));
  console.log(`❌ Failed: ${results.failed.length}`);
  results.failed.forEach(c => console.log(`   - ${c}`));
  console.log(`⏭️  Skipped: ${results.skipped.length}`);
  results.skipped.forEach(c => console.log(`   - ${c}`));

  if (results.failed.length > 0) {
    console.log("\n⚠️  Some verifications failed. Check constructor arguments.");
    process.exit(1);
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
