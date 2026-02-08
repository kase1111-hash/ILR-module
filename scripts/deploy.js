const { ethers, network } = require("hardhat");
const fs = require("fs");
const path = require("path");

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with account:", deployer.address);
  console.log("Network:", network.name);
  console.log("Account balance:", (await ethers.provider.getBalance(deployer.address)).toString());

  // ============ Deploy Token (for testing - use existing in production) ============
  let tokenAddress;
  if (network.name === "hardhat" || network.name === "localhost") {
    console.log("\n1. Deploying MockToken (testnet only)...");
    const MockToken = await ethers.getContractFactory("MockToken");
    const token = await MockToken.deploy();
    await token.waitForDeployment();
    tokenAddress = await token.getAddress();
    console.log("   MockToken deployed to:", tokenAddress);
  } else {
    // For production/testnet: use existing token address
    tokenAddress = process.env.TOKEN_ADDRESS;
    if (!tokenAddress) {
      throw new Error("TOKEN_ADDRESS environment variable required for non-local deployments");
    }
    console.log("\n1. Using existing token:", tokenAddress);
  }

  // ============ Deploy AssetRegistry ============
  console.log("\n2. Deploying AssetRegistry...");
  const AssetRegistry = await ethers.getContractFactory("NatLangChainAssetRegistry");
  const registry = await AssetRegistry.deploy();
  await registry.waitForDeployment();
  const registryAddress = await registry.getAddress();
  console.log("   AssetRegistry deployed to:", registryAddress);

  // ============ Deploy Oracle ============
  console.log("\n3. Deploying Oracle...");
  const Oracle = await ethers.getContractFactory("NatLangChainOracle");
  const oracle = await Oracle.deploy();
  await oracle.waitForDeployment();
  const oracleAddress = await oracle.getAddress();
  console.log("   Oracle deployed to:", oracleAddress);

  // ============ Deploy ILRM ============
  console.log("\n4. Deploying ILRM...");
  const ILRM = await ethers.getContractFactory("ILRM");
  const ilrm = await ILRM.deploy(
    tokenAddress,
    oracleAddress,
    registryAddress
  );
  await ilrm.waitForDeployment();
  const ilrmAddress = await ilrm.getAddress();
  console.log("   ILRM deployed to:", ilrmAddress);

  // ============ Deploy Treasury ============
  console.log("\n5. Deploying Treasury...");
  const maxPerDispute = process.env.MAX_PER_DISPUTE || ethers.parseEther("1");
  const maxPerParticipant = process.env.MAX_PER_PARTICIPANT || ethers.parseEther("10");
  const windowDuration = process.env.WINDOW_DURATION || 30 * 24 * 60 * 60;

  const Treasury = await ethers.getContractFactory("NatLangChainTreasury");
  const treasury = await Treasury.deploy(
    tokenAddress,
    maxPerDispute,
    maxPerParticipant,
    windowDuration
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

  // Register deployer as oracle operator (for testnet)
  if (network.name !== "mainnet") {
    const oracleKeyHash = ethers.keccak256(ethers.toUtf8Bytes("testnet-oracle-key"));
    await oracle.registerOracle(deployer.address, oracleKeyHash);
    console.log("   Oracle: Registered deployer as oracle operator (testnet only)");
  }

  // ============ Summary ============
  const addresses = {
    network: network.name,
    chainId: network.config.chainId,
    deployer: deployer.address,
    token: tokenAddress,
    oracle: oracleAddress,
    registry: registryAddress,
    ilrm: ilrmAddress,
    treasury: treasuryAddress,
    timestamp: new Date().toISOString()
  };

  console.log("\n========================================");
  console.log("Deployment Complete!");
  console.log("========================================");
  console.log("Token:         ", tokenAddress);
  console.log("Oracle:        ", oracleAddress);
  console.log("AssetRegistry: ", registryAddress);
  console.log("ILRM:          ", ilrmAddress);
  console.log("Treasury:      ", treasuryAddress);
  console.log("========================================\n");

  // Save deployment addresses
  const deploymentsDir = path.join(__dirname, "..", "deployments");
  if (!fs.existsSync(deploymentsDir)) {
    fs.mkdirSync(deploymentsDir, { recursive: true });
  }
  const filename = `${network.name}-${Date.now()}.json`;
  fs.writeFileSync(
    path.join(deploymentsDir, filename),
    JSON.stringify(addresses, null, 2)
  );
  console.log(`Addresses saved to deployments/${filename}`);

  // Verification instructions
  if (network.name !== "hardhat" && network.name !== "localhost") {
    console.log("\nTo verify contracts on Etherscan:");
    console.log(`  npx hardhat verify --network ${network.name} ${registryAddress}`);
    console.log(`  npx hardhat verify --network ${network.name} ${oracleAddress}`);
    console.log(`  npx hardhat verify --network ${network.name} ${ilrmAddress} ${tokenAddress} ${oracleAddress} ${registryAddress}`);
    console.log(`  npx hardhat verify --network ${network.name} ${treasuryAddress} ${tokenAddress} ${maxPerDispute} ${maxPerParticipant} ${windowDuration}`);
  }

  return addresses;
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
