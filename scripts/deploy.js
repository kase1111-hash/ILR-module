const { ethers } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with account:", deployer.address);
  console.log("Account balance:", (await ethers.provider.getBalance(deployer.address)).toString());

  // ============ Deploy Token (for testing - use existing in production) ============
  console.log("\n1. Deploying MockToken...");
  const MockToken = await ethers.getContractFactory("MockToken");
  const token = await MockToken.deploy();
  await token.waitForDeployment();
  console.log("   MockToken deployed to:", await token.getAddress());

  // ============ Deploy Oracle ============
  console.log("\n2. Deploying Oracle...");
  const Oracle = await ethers.getContractFactory("NatLangChainOracle");
  const oracle = await Oracle.deploy();
  await oracle.waitForDeployment();
  const oracleAddress = await oracle.getAddress();
  console.log("   Oracle deployed to:", oracleAddress);

  // ============ Deploy AssetRegistry ============
  console.log("\n3. Deploying AssetRegistry...");
  const AssetRegistry = await ethers.getContractFactory("NatLangChainAssetRegistry");
  const registry = await AssetRegistry.deploy();
  await registry.waitForDeployment();
  const registryAddress = await registry.getAddress();
  console.log("   AssetRegistry deployed to:", registryAddress);

  // ============ Deploy ILRM ============
  console.log("\n4. Deploying ILRM...");
  const ILRM = await ethers.getContractFactory("ILRM");
  const ilrm = await ILRM.deploy(
    await token.getAddress(),
    oracleAddress,
    registryAddress
  );
  await ilrm.waitForDeployment();
  const ilrmAddress = await ilrm.getAddress();
  console.log("   ILRM deployed to:", ilrmAddress);

  // ============ Deploy Treasury ============
  console.log("\n5. Deploying Treasury...");
  const Treasury = await ethers.getContractFactory("NatLangChainTreasury");
  const treasury = await Treasury.deploy(
    await token.getAddress(),
    ethers.parseEther("1"),      // maxPerDispute: 1 token
    ethers.parseEther("10"),     // maxPerParticipant: 10 tokens
    30 * 24 * 60 * 60            // windowDuration: 30 days
  );
  await treasury.waitForDeployment();
  const treasuryAddress = await treasury.getAddress();
  console.log("   Treasury deployed to:", treasuryAddress);

  // ============ Configure Contracts ============
  console.log("\n6. Configuring contracts...");

  // Set ILRM in Oracle
  await oracle.setILRM(ilrmAddress);
  console.log("   Oracle: Set ILRM address");

  // Authorize ILRM in AssetRegistry
  await registry.authorizeILRM(ilrmAddress);
  console.log("   AssetRegistry: Authorized ILRM");

  // Set ILRM in Treasury
  await treasury.setILRM(ilrmAddress);
  console.log("   Treasury: Set ILRM address");

  // ============ Summary ============
  console.log("\n========================================");
  console.log("Deployment Complete!");
  console.log("========================================");
  console.log("Token:         ", await token.getAddress());
  console.log("Oracle:        ", oracleAddress);
  console.log("AssetRegistry: ", registryAddress);
  console.log("ILRM:          ", ilrmAddress);
  console.log("Treasury:      ", treasuryAddress);
  console.log("========================================\n");

  // Return addresses for verification
  return {
    token: await token.getAddress(),
    oracle: oracleAddress,
    registry: registryAddress,
    ilrm: ilrmAddress,
    treasury: treasuryAddress
  };
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
