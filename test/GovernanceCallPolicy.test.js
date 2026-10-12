/**
 * scripts/deploy-governance.ts call policy, checked against the compiled artifacts:
 * - every policy selector resolves in the CURRENT contracts (catches renamed/removed functions)
 * - the GovernanceTimelock accepts every entry through setCallClass
 * - an unresolvable optional entry (missing or ambiguous artifact, missing function) only warns,
 *   an unresolvable required entry aborts before any class is written (applyCallPolicy) or before
 *   anything is deployed (checkCallPolicy)
 */
const { expect } = require("chai");
const { artifacts, ethers } = require("hardhat");

// The deploy script is TypeScript; load it with ts-node unless another test already registered it
if (!process[Symbol.for("ts-node.register.instance")]) {
  require("ts-node").register({ transpileOnly: true, compilerOptions: { module: "commonjs" } });
}
const policy = require("../scripts/deploy-governance.ts");

const CORE_ILRM = "contracts/ILRM.sol:ILRM";
const COMPLIANCE_COUNCIL = "contracts/modules/ComplianceCouncil.sol:ComplianceCouncil";
const DUMMY_GENERATOR = "contracts/scaling/DummyTransactionGenerator.sol:DummyTransactionGenerator";

/** Artifact reader that serves the real artifacts, minus one entry's function (as if it were renamed) */
function withoutFunction(entry) {
  return async (name) => {
    const artifact = await artifacts.readArtifact(name);
    if (name !== entry.contractName) return artifact;
    const abi = artifact.abi.filter(
      (f) => f.type !== "function" || ethers.FunctionFragment.from(f).format("sighash") !== entry.signature
    );
    return { ...artifact, abi };
  };
}

function escapeRegExp(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function quietly(fn) {
  return async (...args) => {
    const { log, warn } = console;
    const warnings = [];
    console.log = () => {};
    console.warn = (msg) => warnings.push(String(msg));
    try {
      return { result: await fn(...args), warnings };
    } finally {
      console.log = log;
      console.warn = warn;
    }
  };
}

async function deployTimelock() {
  const [admin] = await ethers.getSigners();
  const Timelock = await ethers.getContractFactory("GovernanceTimelock");
  const timelock = await Timelock.deploy(3600, [admin.address], [], admin.address);
  await timelock.waitForDeployment();
  return timelock;
}

function allAddresses() {
  const addr = (n) => ethers.getAddress(`0x${n.toString(16).padStart(40, "0")}`);
  return {
    ilrmAddress: addr(0x1001),
    treasuryAddress: addr(0x1002),
    oracleAddress: addr(0x1003),
    assetRegistryAddress: addr(0x1004),
    multiPartyILRMAddress: addr(0x1005),
    complianceCouncilAddress: addr(0x1006),
    batchQueueAddress: addr(0x1007),
    dummyGeneratorAddress: addr(0x1008),
  };
}

describe("Governance call policy (scripts/deploy-governance.ts)", function () {
  it("resolves every policy selector against the compiled artifacts", async function () {
    const { result: report } = await quietly(policy.checkCallPolicy)();
    const entries = policy.buildCallPolicy({});
    expect(report).to.have.length(entries.length);

    for (const { entry, resolution } of report) {
      const label = `${entry.contractName}.${entry.signature}`;
      expect(entry.contractName, label).to.match(/^contracts\/.+\.sol:\w+$/);
      expect(resolution.error, label).to.equal(undefined);
      expect(resolution.selector, label).to.equal(ethers.id(entry.signature).slice(0, 10));
    }

    // Wiring added by the subsidy work is covered
    const signatures = entries.map((e) => `${e.contractName}.${e.signature}`);
    expect(signatures).to.include(`${CORE_ILRM}.setSubsidyTreasury(address)`);
  });

  it("classifies module wiring and access-control setters as optional LongDelay entries", async function () {
    const entries = policy.buildCallPolicy(allAddresses());
    const expected = [
      [COMPLIANCE_COUNCIL, "setAuthorizedRequester(address,bool)", allAddresses().complianceCouncilAddress],
      [COMPLIANCE_COUNCIL, "removeMember(address)", allAddresses().complianceCouncilAddress],
      [DUMMY_GENERATOR, "setTargetContracts(address,address)", allAddresses().dummyGeneratorAddress],
    ];
    for (const [contractName, signature, address] of expected) {
      const matches = entries.filter((e) => e.contractName === contractName && e.signature === signature);
      expect(matches, `${contractName}.${signature}`).to.have.length(1);
      expect(matches[0].callClass).to.equal(policy.CallClass.LongDelay);
      expect(matches[0].required).to.equal(false);
      expect(matches[0].address).to.equal(address);
    }
  });

  it("checkCallPolicy aborts when a required entry no longer resolves", async function () {
    const required = policy.buildCallPolicy({}).filter((e) => e.required);
    expect(required).to.not.be.empty;

    for (const entry of required) {
      const label = `${entry.contractName}.${entry.signature}`;
      await expect(quietly(policy.checkCallPolicy)(withoutFunction(entry)), label).to.be.rejectedWith(
        new RegExp(
          `^Required call-policy entries not resolvable:\\n${escapeRegExp(label)} not found in the compiled artifact$`
        )
      );
    }

    // The whole contract missing (HH700) aborts as well
    const missingArtifact = async (name) => {
      if (name === CORE_ILRM) throw new Error(`HH700: Artifact for contract "${name}" not found.`);
      return artifacts.readArtifact(name);
    };
    await expect(quietly(policy.checkCallPolicy)(missingArtifact)).to.be.rejectedWith(
      /Required call-policy entries not resolvable:\ncontracts\/ILRM.sol:ILRM\.\S+ could not be resolved: HH700/
    );
  });

  it("checkCallPolicy reports an unresolvable optional entry without aborting", async function () {
    const entries = policy.buildCallPolicy({});
    const optional = entries.filter((e) => !e.required);
    expect(optional).to.not.be.empty;

    for (const entry of optional) {
      const { result: report } = await quietly(policy.checkCallPolicy)(withoutFunction(entry));
      expect(report).to.have.length(entries.length);
      const broken = report.filter(({ resolution }) => resolution.error !== undefined);
      expect(broken).to.have.length(1);
      expect(broken[0].entry).to.deep.equal(entry);
      expect(broken[0].resolution.error).to.match(/not found in the compiled artifact/);
    }
  });

  it("is accepted by GovernanceTimelock.setCallClass", async function () {
    const timelock = await deployTimelock();
    const entries = policy.buildCallPolicy(allAddresses());
    const { result: applied, warnings } = await quietly(policy.applyCallPolicy)(timelock, entries);

    expect(warnings).to.deep.equal([]);
    expect(applied).to.have.length(entries.length);
    for (let i = 0; i < entries.length; i++) {
      expect(await timelock.getCallClass(entries[i].address, applied[i].selector)).to.equal(entries[i].callClass);
    }
  });

  it("reports missing and ambiguous artifacts and missing functions instead of throwing", async function () {
    const missing = await policy.resolveSelector("contracts/Nope.sol:Nope", "foo()");
    expect(missing.selector).to.equal(undefined);
    expect(missing.error).to.match(/could not be resolved: HH700/);

    const noFunction = await policy.resolveSelector(CORE_ILRM, "renamedAway(uint256)");
    expect(noFunction.error).to.match(/not found in the compiled artifact/);

    const ambiguous = await policy.resolveSelector("ILRM", "pause()", async () => {
      throw new Error('HH701: There are multiple artifacts for contract "ILRM", please use a fully qualified name.');
    });
    expect(ambiguous.error).to.match(/could not be resolved: HH701/);
  });

  it("warns on an unresolvable optional entry and aborts on a required one", async function () {
    const timelock = await deployTimelock();
    const target = allAddresses().ilrmAddress;
    const good = {
      contractName: CORE_ILRM,
      address: target,
      signature: "withdrawTreasury(address,uint256)",
      callClass: policy.CallClass.LongDelay,
      required: true,
    };
    const brokenOptional = { ...good, contractName: "contracts/Gone.sol:Gone", required: false };
    const brokenRequired = { ...good, signature: "renamedAway(uint256)" };
    const selector = ethers.id(good.signature).slice(0, 10);

    // A required entry that cannot be resolved aborts before anything is written
    await expect(quietly(policy.applyCallPolicy)(timelock, [good, brokenRequired])).to.be.rejectedWith(
      /renamedAway\(uint256\) not found in the compiled artifact; cannot classify it LongDelay/
    );
    expect(await timelock.getCallClass(target, selector)).to.equal(policy.CallClass.Standard);

    // An optional one only warns
    const { result: applied, warnings } = await quietly(policy.applyCallPolicy)(timelock, [brokenOptional, good]);
    expect(applied).to.have.length(1);
    expect(warnings).to.have.length(1);
    expect(warnings[0]).to.match(/WARNING: contracts\/Gone.sol:Gone.*HH700.*skipping LongDelay classification/);
    expect(await timelock.getCallClass(target, selector)).to.equal(policy.CallClass.LongDelay);

    // Entries without an address are skipped, even unresolvable required ones
    const { result: none } = await quietly(policy.applyCallPolicy)(timelock, [{ ...brokenRequired, address: undefined }]);
    expect(none).to.deep.equal([]);
  });
});
