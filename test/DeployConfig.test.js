/**
 * scripts/deploy.js configuration: every env value is parsed and validated (format, the contracts' bounds, the
 * token's decimals) before the first transaction, so a bad value can no longer leave a partial deployment.
 */
const { expect } = require("chai");
const { ethers } = require("hardhat");

const deploy = require("../scripts/deploy.js");

const { parseDeployConfig, checkTokenDecimals, ILRM_INCENTIVE, TREASURY_DEFAULTS, TOKEN_UNIT_VARS } = deploy;

const DAY = 24n * 60n * 60n;
const UINT256_MAX = (1n << 256n) - 1n;
const LOCAL = { localNetwork: true };
const REMOTE = { localNetwork: false };
const TOKEN_ADDRESS = "0x5FbDB2315678afecb367f032d93F642f64180aa3";

function quietly(fn) {
  return async (...args) => {
    const { log } = console;
    console.log = () => {};
    try {
      return await fn(...args);
    } finally {
      console.log = log;
    }
  };
}

const runMain = quietly((env) => deploy.main(env, { save: false }));

/** Run main() and return its rejection, asserting the deployer sent no transaction at all */
async function expectNothingDeployed(env) {
  const [deployer] = await ethers.getSigners();
  const nonceBefore = await ethers.provider.getTransactionCount(deployer.address);
  let error;
  try {
    await runMain(env);
  } catch (e) {
    error = e;
  }
  expect(error, "main() did not reject").to.be.instanceOf(Error);
  expect(await ethers.provider.getTransactionCount(deployer.address)).to.equal(
    nonceBefore,
    "a transaction was sent before the configuration was rejected"
  );
  return error;
}

function parseError(env, options = LOCAL) {
  try {
    parseDeployConfig(env, options);
  } catch (e) {
    return e.message;
  }
  throw new Error("parseDeployConfig accepted an invalid configuration");
}

describe("scripts/deploy.js configuration", function () {
  describe("main() rejects a bad value before deploying anything", function () {
    // REGRESSION: "Cannot convert 2e18 to a BigInt" was thrown after every contract was deployed and wired
    it("INCENTIVE_MAX_PER_DISPUTE=2e18", async function () {
      const error = await expectNothingDeployed({ INCENTIVE_MAX_PER_DISPUTE: "2e18" });
      expect(error.message).to.match(/INCENTIVE_MAX_PER_DISPUTE must be an integer in decimal digits/);
      expect(error.message).to.contain("nothing was deployed");
    });

    // REGRESSION: everything was deployed, then setInitiatorIncentiveCaps reverted "Invalid incentive window"
    it("INCENTIVE_WINDOW=100", async function () {
      const error = await expectNothingDeployed({ INCENTIVE_WINDOW: "100" });
      expect(error.message).to.match(/INCENTIVE_WINDOW must be between 86400 and 31536000 inclusive, got 100/);
    });

    // The Treasury caps were passed through unparsed: the Treasury deployment threw after three contracts
    it("MAX_PER_DISPUTE=2e18", async function () {
      const error = await expectNothingDeployed({ MAX_PER_DISPUTE: "2e18" });
      expect(error.message).to.match(/MAX_PER_DISPUTE must be an integer in decimal digits/);
    });

    it("a per-dispute incentive cap above the default window cap", async function () {
      const error = await expectNothingDeployed({ INCENTIVE_MAX_PER_DISPUTE: (10n ** 19n + 1n).toString() });
      expect(error.message).to.contain("must be <= the default INCENTIVE_MAX_PER_WINDOW");
    });
  });

  describe("main() applies a valid configuration", function () {
    it("sets the incentive caps from INCENTIVE_* and keeps the defaults for unset values", async function () {
      const addresses = await runMain({
        INCENTIVE_MAX_PER_DISPUTE: "2000000000000000000",
        INCENTIVE_WINDOW: " 86400 ",
        MAX_PER_PARTICIPANT: "7"
      });
      const ilrm = await ethers.getContractAt("ILRM", addresses.ilrm);
      expect(await ilrm.maxIncentivePerDispute()).to.equal(2n * 10n ** 18n);
      expect(await ilrm.maxIncentivePerWindow()).to.equal(await ilrm.DEFAULT_MAX_INCENTIVE_PER_WINDOW());
      expect(await ilrm.incentiveWindow()).to.equal(DAY);
      expect(addresses.incentiveCaps).to.deep.equal({
        maxPerDispute: "2000000000000000000",
        maxPerWindow: "10000000000000000000",
        window: "86400"
      });

      const treasury = await ethers.getContractAt("NatLangChainTreasury", addresses.treasury);
      expect(await treasury.maxPerDispute()).to.equal(TREASURY_DEFAULTS.MAX_PER_DISPUTE);
      expect(await treasury.maxPerParticipant()).to.equal(7n);
      expect(await treasury.windowDuration()).to.equal(TREASURY_DEFAULTS.WINDOW_DURATION);
    });

    it("deploys with the defaults when nothing is set", async function () {
      const addresses = await runMain({});
      const ilrm = await ethers.getContractAt("ILRM", addresses.ilrm);
      expect(await ilrm.maxIncentivePerDispute()).to.equal(ILRM_INCENTIVE.DEFAULT_MAX_PER_DISPUTE);
      expect(await ilrm.maxIncentivePerWindow()).to.equal(ILRM_INCENTIVE.DEFAULT_MAX_PER_WINDOW);
      expect(await ilrm.incentiveWindow()).to.equal(ILRM_INCENTIVE.DEFAULT_WINDOW);
    });
  });

  describe("parseDeployConfig", function () {
    it("mirrors ILRM's incentive defaults and window bounds", async function () {
      const [owner] = await ethers.getSigners();
      const ilrm = await (await ethers.getContractFactory("ILRM")).deploy(owner.address, owner.address, owner.address);
      expect(await ilrm.DEFAULT_MAX_INCENTIVE_PER_DISPUTE()).to.equal(ILRM_INCENTIVE.DEFAULT_MAX_PER_DISPUTE);
      expect(await ilrm.DEFAULT_MAX_INCENTIVE_PER_WINDOW()).to.equal(ILRM_INCENTIVE.DEFAULT_MAX_PER_WINDOW);
      expect(await ilrm.DEFAULT_INCENTIVE_WINDOW()).to.equal(ILRM_INCENTIVE.DEFAULT_WINDOW);
      expect(await ilrm.MIN_INCENTIVE_WINDOW()).to.equal(ILRM_INCENTIVE.MIN_WINDOW);
      expect(await ilrm.MAX_INCENTIVE_WINDOW()).to.equal(ILRM_INCENTIVE.MAX_WINDOW);
    });

    it("accepts exactly the incentive caps ILRM.setInitiatorIncentiveCaps accepts", async function () {
      const [owner] = await ethers.getSigners();
      const ilrm = await (await ethers.getContractFactory("ILRM")).deploy(owner.address, owner.address, owner.address);
      const { MIN_WINDOW, MAX_WINDOW, DEFAULT_MAX_PER_WINDOW } = ILRM_INCENTIVE;
      const cases = [
        { INCENTIVE_WINDOW: MIN_WINDOW - 1n },
        { INCENTIVE_WINDOW: MIN_WINDOW },
        { INCENTIVE_WINDOW: MAX_WINDOW },
        { INCENTIVE_WINDOW: MAX_WINDOW + 1n },
        { INCENTIVE_MAX_PER_DISPUTE: DEFAULT_MAX_PER_WINDOW },
        { INCENTIVE_MAX_PER_DISPUTE: DEFAULT_MAX_PER_WINDOW + 1n },
        { INCENTIVE_MAX_PER_DISPUTE: 0n, INCENTIVE_MAX_PER_WINDOW: 0n },
        { INCENTIVE_MAX_PER_WINDOW: 0n },
        { INCENTIVE_MAX_PER_DISPUTE: UINT256_MAX, INCENTIVE_MAX_PER_WINDOW: UINT256_MAX }
      ];
      for (const values of cases) {
        const env = Object.fromEntries(Object.entries(values).map(([k, v]) => [k, v.toString()]));
        let config;
        try {
          config = parseDeployConfig(env, LOCAL);
        } catch (e) {
          config = undefined;
        }
        const effective = {
          maxPerDispute: values.INCENTIVE_MAX_PER_DISPUTE ?? ILRM_INCENTIVE.DEFAULT_MAX_PER_DISPUTE,
          maxPerWindow: values.INCENTIVE_MAX_PER_WINDOW ?? ILRM_INCENTIVE.DEFAULT_MAX_PER_WINDOW,
          window: values.INCENTIVE_WINDOW ?? ILRM_INCENTIVE.DEFAULT_WINDOW
        };
        let contractAccepts = true;
        try {
          await ilrm.setInitiatorIncentiveCaps.staticCall(
            effective.maxPerDispute,
            effective.maxPerWindow,
            effective.window
          );
        } catch (e) {
          contractAccepts = false;
        }
        expect(config !== undefined, `script and contract disagree on ${JSON.stringify(env)}`).to.equal(
          contractAccepts
        );
        if (config) {
          expect(config.incentive).to.deep.equal({ set: true, ...effective });
        }
      }
    });

    it("rejects anything but decimal digits for the uint values", function () {
      for (const name of [...TOKEN_UNIT_VARS, "INCENTIVE_WINDOW", "WINDOW_DURATION"]) {
        for (const bad of ["2e18", "1.5", "-1", "+1", "0x10", "1_000", "ten", " ", "86400s"]) {
          expect(parseError({ [name]: bad })).to.contain(`${name} must be an integer in decimal digits`);
        }
      }
    });

    it("rejects values above 2^256-1", function () {
      for (const name of ["MAX_PER_DISPUTE", "MAX_PER_PARTICIPANT", "WINDOW_DURATION", "INCENTIVE_MAX_PER_WINDOW"]) {
        expect(parseError({ [name]: (UINT256_MAX + 1n).toString() })).to.contain(`${name} must be between 0 and`);
        expect(() => parseDeployConfig({ [name]: UINT256_MAX.toString() }, LOCAL)).to.not.throw();
      }
    });

    it("parses the Treasury values and treats empty values as unset", function () {
      const config = parseDeployConfig(
        { MAX_PER_DISPUTE: "5", MAX_PER_PARTICIPANT: "", WINDOW_DURATION: "0", INCENTIVE_WINDOW: "" },
        LOCAL
      );
      expect(config.treasury).to.deep.equal({
        maxPerDispute: 5n,
        maxPerParticipant: TREASURY_DEFAULTS.MAX_PER_PARTICIPANT,
        windowDuration: 0n
      });
      expect(config.incentive.set).to.equal(false);
    });

    it("reports every invalid value at once", function () {
      const message = parseError({ INCENTIVE_MAX_PER_DISPUTE: "2e18", INCENTIVE_WINDOW: "100", MAX_PER_DISPUTE: "x" });
      expect(message).to.contain("INCENTIVE_MAX_PER_DISPUTE");
      expect(message).to.contain("INCENTIVE_WINDOW");
      expect(message).to.contain("MAX_PER_DISPUTE must");
    });

    it("validates TOKEN_ADDRESS on non-local networks only", function () {
      expect(parseError({}, REMOTE)).to.contain("TOKEN_ADDRESS environment variable required");
      for (const bad of ["0x1234", "5FbDB2315678afecb367f032d93F642f64180aa3", ethers.ZeroAddress]) {
        expect(parseError({ TOKEN_ADDRESS: bad }, REMOTE)).to.contain("TOKEN_ADDRESS must be");
      }
      // Bad mixed-case checksum
      expect(parseError({ TOKEN_ADDRESS: "0x5fbDB2315678afecb367f032d93F642f64180aa3" }, REMOTE)).to.contain(
        "TOKEN_ADDRESS must be"
      );
      expect(parseDeployConfig({ TOKEN_ADDRESS: TOKEN_ADDRESS.toLowerCase() }, REMOTE).tokenAddress).to.equal(
        TOKEN_ADDRESS
      );
      expect(parseDeployConfig({ TOKEN_ADDRESS: "not-used-locally" }, LOCAL).tokenAddress).to.equal(undefined);
    });
  });

  describe("checkTokenDecimals", function () {
    const remote = (env) => parseDeployConfig({ TOKEN_ADDRESS, ...env }, REMOTE);

    // REGRESSION: setting only INCENTIVE_WINDOW bypassed the 18-decimals guard
    it("does not accept INCENTIVE_WINDOW alone on a non-18-decimals token", function () {
      expect(() => checkTokenDecimals(remote({ INCENTIVE_WINDOW: "86400" }), 6)).to.throw(
        "Token has 6 decimals but the defaults assume 18; set MAX_PER_DISPUTE, MAX_PER_PARTICIPANT, " +
          "INCENTIVE_MAX_PER_DISPUTE, INCENTIVE_MAX_PER_WINDOW explicitly"
      );
    });

    it("names every token-denominated value left at its 18-decimals default", function () {
      const config = remote({ INCENTIVE_MAX_PER_DISPUTE: "1000000", INCENTIVE_MAX_PER_WINDOW: "10000000" });
      expect(() => checkTokenDecimals(config, 6n)).to.throw(/set MAX_PER_DISPUTE, MAX_PER_PARTICIPANT explicitly/);
      expect(() => checkTokenDecimals(remote({ MAX_PER_DISPUTE: "1", MAX_PER_PARTICIPANT: "1" }), 8)).to.throw(
        /set INCENTIVE_MAX_PER_DISPUTE, INCENTIVE_MAX_PER_WINDOW explicitly/
      );
    });

    it("accepts a non-18-decimals token once every token-denominated value is set", function () {
      const config = remote({
        MAX_PER_DISPUTE: "1000000",
        MAX_PER_PARTICIPANT: "10000000",
        INCENTIVE_MAX_PER_DISPUTE: "1000000",
        INCENTIVE_MAX_PER_WINDOW: "10000000"
      });
      expect(() => checkTokenDecimals(config, 6n)).to.not.throw();
    });

    it("accepts an 18-decimals token with the defaults", function () {
      expect(() => checkTokenDecimals(remote({}), 18n)).to.not.throw();
    });
  });
});
