const { ethers, network } = require("hardhat");
const fs = require("fs");
const path = require("path");

const UINT256_MAX = (1n << 256n) - 1n;
const DAY = 24n * 60n * 60n;
const TOKEN = 10n ** 18n; // one token of an 18-decimals token

// Mirror of ILRM's initiator-incentive constants (DEFAULT_*, MIN/MAX_INCENTIVE_WINDOW), so the env values can be
// checked against the contract's bounds before anything is deployed. test/DeployConfig.test.js keeps it in sync.
const ILRM_INCENTIVE = {
  DEFAULT_MAX_PER_DISPUTE: 1n * TOKEN,
  DEFAULT_MAX_PER_WINDOW: 10n * TOKEN,
  DEFAULT_WINDOW: 30n * DAY,
  MIN_WINDOW: 1n * DAY,
  MAX_WINDOW: 365n * DAY
};

// Treasury constructor arguments used when MAX_PER_DISPUTE / MAX_PER_PARTICIPANT / WINDOW_DURATION are unset
const TREASURY_DEFAULTS = {
  MAX_PER_DISPUTE: 1n * TOKEN,
  MAX_PER_PARTICIPANT: 10n * TOKEN,
  WINDOW_DURATION: 30n * DAY
};

// Token-denominated env values: their defaults assume an 18-decimals token, so a token with other decimals must
// set every one of them explicitly (INCENTIVE_WINDOW and WINDOW_DURATION are seconds and may stay unset)
const TOKEN_UNIT_VARS = [
  "MAX_PER_DISPUTE",
  "MAX_PER_PARTICIPANT",
  "INCENTIVE_MAX_PER_DISPUTE",
  "INCENTIVE_MAX_PER_WINDOW"
];

const INCENTIVE_VARS = ["INCENTIVE_MAX_PER_DISPUTE", "INCENTIVE_MAX_PER_WINDOW", "INCENTIVE_WINDOW"];

const isSet = (value) => value !== undefined && value !== "";

/**
 * Parse and validate every environment value this script reads, without touching the chain. Throws one Error
 * listing every problem, so a bad value fails before the first transaction instead of leaving a partial
 * deployment. Unset or empty values take the defaults above.
 * - MAX_PER_DISPUTE, MAX_PER_PARTICIPANT, INCENTIVE_MAX_PER_DISPUTE, INCENTIVE_MAX_PER_WINDOW: raw token base
 *   units, decimal digits only, 0 to 2^256-1 (zero incentive caps are ILRM's kill switch)
 * - WINDOW_DURATION: seconds, 0 to 2^256-1 (the Treasury has no bounds)
 * - INCENTIVE_WINDOW: seconds, 1 day to 365 days inclusive (ILRM's bounds)
 * - effective incentive per-dispute cap <= effective per-window cap (ILRM's bound), defaults included
 * - TOKEN_ADDRESS (non-local networks only): required, a non-zero 0x-prefixed address
 * @param {Record<string, string | undefined>} env The environment (process.env)
 * @param {{ localNetwork: boolean }} options localNetwork: hardhat/localhost, where a MockToken is deployed instead
 */
function parseDeployConfig(env, { localNetwork }) {
  const errors = [];
  const explicit = new Set(Object.keys(env).filter((name) => isSet(env[name])));

  const uint = (name, fallback, min = 0n, max = UINT256_MAX) => {
    if (!explicit.has(name)) return fallback;
    const text = String(env[name]).trim();
    if (!/^[0-9]+$/.test(text)) {
      errors.push(`${name} must be an integer in decimal digits (no exponent, sign, point or hex), got "${env[name]}"`);
      return undefined;
    }
    const value = BigInt(text);
    if (value < min || value > max) {
      errors.push(`${name} must be between ${min} and ${max} inclusive, got ${value}`);
      return undefined;
    }
    return value;
  };

  let tokenAddress;
  if (!localNetwork) {
    const raw = explicit.has("TOKEN_ADDRESS") ? String(env.TOKEN_ADDRESS).trim() : "";
    if (raw === "") {
      errors.push("TOKEN_ADDRESS environment variable required for non-local deployments");
    } else if (!/^0x[0-9a-fA-F]{40}$/.test(raw) || !ethers.isAddress(raw) || BigInt(raw) === 0n) {
      errors.push(`TOKEN_ADDRESS must be a non-zero 0x-prefixed address (valid checksum if mixed case), got "${raw}"`);
    } else {
      tokenAddress = ethers.getAddress(raw);
    }
  }

  const treasury = {
    maxPerDispute: uint("MAX_PER_DISPUTE", TREASURY_DEFAULTS.MAX_PER_DISPUTE),
    maxPerParticipant: uint("MAX_PER_PARTICIPANT", TREASURY_DEFAULTS.MAX_PER_PARTICIPANT),
    windowDuration: uint("WINDOW_DURATION", TREASURY_DEFAULTS.WINDOW_DURATION)
  };

  const incentive = {
    set: INCENTIVE_VARS.some((name) => explicit.has(name)),
    maxPerDispute: uint("INCENTIVE_MAX_PER_DISPUTE", ILRM_INCENTIVE.DEFAULT_MAX_PER_DISPUTE),
    maxPerWindow: uint("INCENTIVE_MAX_PER_WINDOW", ILRM_INCENTIVE.DEFAULT_MAX_PER_WINDOW),
    window: uint(
      "INCENTIVE_WINDOW",
      ILRM_INCENTIVE.DEFAULT_WINDOW,
      ILRM_INCENTIVE.MIN_WINDOW,
      ILRM_INCENTIVE.MAX_WINDOW
    )
  };
  if (
    incentive.maxPerDispute !== undefined &&
    incentive.maxPerWindow !== undefined &&
    incentive.maxPerDispute > incentive.maxPerWindow
  ) {
    const source = (name) => (explicit.has(name) ? name : `the default ${name}`);
    errors.push(
      `${source("INCENTIVE_MAX_PER_DISPUTE")} (${incentive.maxPerDispute}) must be <= ` +
        `${source("INCENTIVE_MAX_PER_WINDOW")} (${incentive.maxPerWindow})`
    );
  }

  if (errors.length > 0) {
    throw new Error(`Invalid deployment configuration (nothing was deployed):\n  - ${errors.join("\n  - ")}`);
  }
  return { localNetwork, tokenAddress, explicit, treasury, incentive };
}

/**
 * Refuse a token whose decimals are not 18 unless every token-denominated value is set explicitly: the defaults
 * (1 and 10 tokens) are 18-decimals base units. Setting only a window does not count.
 * @param {ReturnType<typeof parseDeployConfig>} config The parsed configuration
 * @param {bigint | number} decimals The token's decimals()
 */
function checkTokenDecimals(config, decimals) {
  if (Number(decimals) === 18) return;
  const missing = TOKEN_UNIT_VARS.filter((name) => !config.explicit.has(name));
  if (missing.length > 0) {
    throw new Error(
      `Token has ${decimals} decimals but the defaults assume 18; set ${missing.join(", ")} explicitly ` +
        "in the token's base units"
    );
  }
}

/**
 * Deploy and wire AssetRegistry, Oracle, ILRM and Treasury (plus a MockToken on hardhat/localhost).
 * Every env value is parsed and validated, and the token's decimals are checked, before the first protocol
 * contract is deployed. On non-local networks nothing is sent before those checks; on hardhat/localhost only the
 * 18-decimals MockToken is.
 * @param {Record<string, string | undefined>} env The environment (default process.env)
 * @param {{ save?: boolean }} options save: write deployments/<network>-<time>.json (default true)
 */
async function main(env = process.env, { save = true } = {}) {
  const localNetwork = network.name === "hardhat" || network.name === "localhost";
  const config = parseDeployConfig(env, { localNetwork });
  const { maxPerDispute, maxPerParticipant, windowDuration } = config.treasury;

  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with account:", deployer.address);
  console.log("Network:", network.name);
  console.log("Account balance:", (await ethers.provider.getBalance(deployer.address)).toString());

  // ============ Deploy Token (for testing - use existing in production) ============
  let tokenAddress;
  if (localNetwork) {
    console.log("\n1. Deploying MockToken (testnet only)...");
    const MockToken = await ethers.getContractFactory("MockToken");
    const token = await MockToken.deploy();
    await token.waitForDeployment();
    tokenAddress = await token.getAddress();
    console.log("   MockToken deployed to:", tokenAddress);
  } else {
    // For production/testnet: use existing token address
    tokenAddress = config.tokenAddress;
    console.log("\n1. Using existing token:", tokenAddress);
  }

  // The token-denominated defaults (Treasury caps, ILRM initiator-incentive caps) assume 18 decimals.
  // MAX_PER_DISPUTE / MAX_PER_PARTICIPANT / INCENTIVE_MAX_PER_* are raw base units; the windows are seconds.
  const tokenDecimals = await new ethers.Contract(
    tokenAddress,
    ["function decimals() view returns (uint8)"],
    deployer
  ).decimals();
  console.log("   Token decimals:", tokenDecimals.toString());
  checkTokenDecimals(config, tokenDecimals);

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

  // Let ILRM draw defensive stake subsidies from the Treasury (escrowed co-stakes)
  await (await ilrm.setSubsidyTreasury(treasuryAddress)).wait();
  console.log("   ILRM: Set subsidy treasury");

  // Initiator-incentive caps: override the constructor defaults only when an INCENTIVE_* variable is set; unset
  // values keep the defaults. The values were validated against ILRM's bounds before anything was deployed.
  if (config.incentive.set) {
    const { maxPerDispute: perDispute, maxPerWindow: perWindow, window } = config.incentive;
    await (await ilrm.setInitiatorIncentiveCaps(perDispute, perWindow, window)).wait();
    console.log("   ILRM: Set initiator-incentive caps from INCENTIVE_*");
  }
  const incentiveCaps = {
    maxPerDispute: (await ilrm.maxIncentivePerDispute()).toString(),
    maxPerWindow: (await ilrm.maxIncentivePerWindow()).toString(),
    window: (await ilrm.incentiveWindow()).toString()
  };
  console.log(
    `   ILRM: Initiator-incentive caps: ${incentiveCaps.maxPerDispute} per dispute, ` +
      `${incentiveCaps.maxPerWindow} per ${incentiveCaps.window}s window (raw token units)`
  );

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
    incentiveCaps,
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
  if (save) {
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
  }

  // Verification instructions
  if (!localNetwork) {
    console.log("\nTo verify contracts on Etherscan:");
    console.log(`  npx hardhat verify --network ${network.name} ${registryAddress}`);
    console.log(`  npx hardhat verify --network ${network.name} ${oracleAddress}`);
    console.log(`  npx hardhat verify --network ${network.name} ${ilrmAddress} ${tokenAddress} ${oracleAddress} ${registryAddress}`);
    console.log(`  npx hardhat verify --network ${network.name} ${treasuryAddress} ${tokenAddress} ${maxPerDispute} ${maxPerParticipant} ${windowDuration}`);
  }

  return addresses;
}

module.exports = { main, parseDeployConfig, checkTokenDecimals, ILRM_INCENTIVE, TREASURY_DEFAULTS, TOKEN_UNIT_VARS };

if (require.main === module) {
  main()
    .then(() => process.exit(0))
    .catch((error) => {
      console.error(error);
      process.exit(1);
    });
}
