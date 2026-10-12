/**
 * Subgraph manifest consistency
 *
 * The subgraph (subgraph/) only indexes what its manifest names: a handler whose event signature the
 * contract no longer emits silently never fires, and graph-cli refuses to build. These checks run
 * against the Hardhat artifacts of the current contracts, so a contract change that breaks the
 * subgraph fails here instead of at deployment:
 *   - every subgraph.yaml handler names an event the compiled contract emits (exact signature)
 *   - subgraph/abis holds the same fragment (parameter names included) for every handled event,
 *     so `graph codegen` types match the contract
 *   - every contract function a mapping eth_calls through the generated bindings (ILRM.disputes,
 *     L3Bridge.getChallengeDeadline, AssetRegistry.getLicense) exists in the compiled contract and
 *     subgraph/abis holds exactly its compiled fragment (inputs, outputs and struct component names),
 *     so the call's signature and the decoded fields match the deployed contract
 *   - every handler is exported by its mapping file and no exported handler is unused
 *   - every entity a data source lists exists in schema.graphql
 * New contract events do not fail these checks; `npm run check-abis` (in subgraph/) lists them.
 */

const { expect } = require("chai");
const fs = require("fs");
const path = require("path");
const hre = require("hardhat");
const {
  SUBGRAPH_DIR,
  loadManifest,
  loadAbiSources,
  contractCalls,
  eventSignature,
  abiEvents,
  readAbiFile
} = require("../subgraph/scripts/lib/subgraph-manifest");

function exportedHandlers(source) {
  return [...source.matchAll(/^export function (handle\w+)\s*\(/gm)].map((m) => m[1]);
}

function abiFunctions(abi, name) {
  return abi.filter((f) => f.type === "function" && f.name === name);
}

/** Contract calls of every data source's mapping: { ds, contract, fn } */
function mappingCalls(manifest) {
  return manifest.dataSources.flatMap((ds) =>
    contractCalls(fs.readFileSync(ds.mappingFile, "utf8")).map((c) => ({ ds, ...c }))
  );
}

function schemaEntities() {
  const schema = fs.readFileSync(path.join(SUBGRAPH_DIR, "schema.graphql"), "utf8");
  return new Set([...schema.matchAll(/^type (\w+) @entity/gm)].map((m) => m[1]));
}

describe("Subgraph manifest", function () {
  const manifest = loadManifest();
  const sources = loadAbiSources();
  const compiled = {};

  before(async function () {
    for (const [name, entry] of Object.entries(sources)) {
      const artifact = await hre.artifacts.readArtifact(`${entry.source}:${entry.contract}`);
      compiled[name] = artifact.abi;
    }
  });

  it("indexes the five core contracts", function () {
    expect(manifest.dataSources.map((ds) => ds.name)).to.have.members([
      "ILRM",
      "Treasury",
      "Oracle",
      "L3Bridge",
      "AssetRegistry"
    ]);
  });

  for (const ds of manifest.dataSources) {
    describe(`data source ${ds.name}`, function () {
      it("maps its ABI to a compiled contract in abi-sources.json", function () {
        expect(sources, `abi-sources.json has no entry for ABI ${ds.abiName}`).to.have.property(ds.abiName);
        expect(ds.abiFile, `no abis entry named ${ds.abiName}`).to.be.a("string");
        expect(fs.existsSync(ds.abiFile), `${ds.abiFile} is missing (run npm run sync-abis)`).to.equal(true);
      });

      it("only handles events the compiled contract emits", function () {
        const emitted = abiEvents(compiled[ds.abiName] || []).map(eventSignature);
        const stale = ds.eventHandlers.filter((h) => !emitted.includes(h.event)).map((h) => `${h.handler}: ${h.event}`);
        expect(stale, `stale handlers in subgraph.yaml (${ds.name})`).to.deep.equal([]);
        expect(ds.eventHandlers.length).to.be.greaterThan(0);
      });

      it("ships the compiled fragment of every handled event in subgraph/abis", function () {
        const shipped = readAbiFile(ds.abiFile);
        const bySig = (abi) => new Map(abiEvents(abi).map((f) => [eventSignature(f), f]));
        const shippedEvents = bySig(shipped);
        const compiledEvents = bySig(compiled[ds.abiName] || []);
        for (const h of ds.eventHandlers) {
          const file = path.basename(ds.abiFile);
          expect(shippedEvents.has(h.event), `${file} lacks ${h.event}`).to.equal(true);
          expect(shippedEvents.get(h.event), `${file}: ${h.event} differs from the compiled fragment`).to.deep.equal(
            compiledEvents.get(h.event)
          );
        }
      });

      it("ships the compiled fragment of every contract function its mapping calls", function () {
        for (const { contract, fn } of contractCalls(fs.readFileSync(ds.mappingFile, "utf8"))) {
          const call = `${ds.name} mapping calls ${contract}.${fn}`;
          const abiEntry = ds.abis.find((a) => a.name === contract);
          expect(abiEntry, `${call}, but ${contract} is not in its mapping.abis`).to.not.equal(undefined);
          expect(sources, `${call}, but abi-sources.json has no ${contract}`).to.have.property(contract);

          const compiledFns = abiFunctions(compiled[contract] || [], fn);
          expect(compiledFns.length, `${call}: compiled ${contract} has ${compiledFns.length} functions named ${fn}`).to.equal(
            1
          );
          const shippedFns = abiFunctions(readAbiFile(abiEntry.file), fn);
          const file = path.basename(abiEntry.file);
          expect(shippedFns, `${file}: ${fn} differs from the compiled fragment`).to.deep.equal(compiledFns);
        }
      });

      it("exports every handler from its mapping and none besides", function () {
        expect(fs.existsSync(ds.mappingFile), `${ds.mappingFile} is missing`).to.equal(true);
        const exported = exportedHandlers(fs.readFileSync(ds.mappingFile, "utf8"));
        const named = ds.eventHandlers.map((h) => h.handler);
        expect(named.filter((h) => !exported.includes(h)), "handlers not exported").to.deep.equal([]);
        expect(exported.filter((h) => !named.includes(h)), "exported handlers not in subgraph.yaml").to.deep.equal(
          []
        );
        expect(new Set(named).size, "duplicate handler names").to.equal(named.length);
      });

      it("lists only entities defined in schema.graphql", function () {
        const entities = schemaEntities();
        expect(ds.entities.filter((e) => !entities.has(e))).to.deep.equal([]);
      });
    });
  }

  it("finds the eth_calls the mappings make", function () {
    // Guards the scanner: if it stopped recognising the calls, the fragment check above would pass vacuously
    expect(mappingCalls(manifest).map((c) => `${c.contract}.${c.fn}`)).to.include.members([
      "ILRM.disputes",
      "L3Bridge.getChallengeDeadline",
      "AssetRegistry.getLicense"
    ]);
  });

  it("indexes the proposal-round, subsidy-escrow and fraud-proof lifecycle events", function () {
    const handled = new Set(manifest.dataSources.flatMap((ds) => ds.eventHandlers.map((h) => `${ds.name}.${h.event}`)));
    const required = [
      "ILRM.ProposalSuperseded(indexed uint256,indexed uint256,bytes32,bytes32)",
      "ILRM.StakeSubsidized(indexed uint256,indexed address,indexed address,uint256)",
      "ILRM.SubsidyReturned(indexed uint256,indexed address,uint256)",
      "ILRM.SubsidyTreasuryUpdated(indexed address,indexed address)",
      "ILRM.ProposalVoided(indexed uint256,indexed uint256,bytes32)",
      "ILRM.OracleRequestFailed(indexed uint256,indexed uint256)",
      "ILRM.InitiatorIncentivePaid(indexed uint256,indexed address,uint256,uint256)",
      "ILRM.InitiatorIncentiveCapsUpdated(uint256,uint256,uint256)",
      "Treasury.SubsidyFunded(indexed address,indexed uint256,uint256)",
      "Oracle.ProposalRequestCancelled(indexed uint256)",
      "Oracle.ProposalSubmittedToILRM(indexed uint256,bytes32,indexed address)",
      "Oracle.ProposalRoundFilled(indexed uint256,indexed uint256,bytes32,uint256)",
      "Oracle.ProposalRoundReopened(indexed uint256,indexed uint256,bytes32)",
      "L3Bridge.StateCommitmentSubmitted(indexed bytes32,indexed uint256,uint256,address)",
      "L3Bridge.FraudProofCommitted(indexed bytes32,indexed bytes32,indexed address,uint256)",
      "L3Bridge.FraudProofRevealed(indexed bytes32,indexed bytes32,indexed address)",
      "L3Bridge.FraudProofRefunded(indexed bytes32,indexed bytes32,indexed address,uint256)",
      "L3Bridge.FraudProofForfeited(indexed bytes32,indexed bytes32,indexed address,uint256)",
      "L3Bridge.CommittedChainRolledBack(indexed bytes32,indexed bytes32,uint256)",
      "L3Bridge.SettlementSkipped(indexed uint256,indexed uint256,uint8)",
      "AssetRegistry.AssetsFrozen(indexed uint256,indexed address,bytes32[])"
    ];
    expect(required.filter((r) => !handled.has(r))).to.deep.equal([]);
  });
});
