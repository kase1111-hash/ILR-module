#!/usr/bin/env node
// =============================================================================
// Keep subgraph/abis/*.json in sync with the compiled contracts
// =============================================================================
// Usage (from subgraph/):
//   npm run sync-abis              rewrite abis/*.json from the compiler artifacts
//   npm run check-abis             exit 1 if abis/*.json drifted from the artifacts or
//                                  if a subgraph.yaml handler names an event the
//                                  contract no longer emits
//   node scripts/sync-abis.js [--check] [--from foundry|hardhat|auto]
//
// Compile first, from the repository root: `forge build` (artifacts in out/) or
// `npx hardhat compile` (artifacts in artifacts/). "auto" (default) uses the most
// recently written artifact of the two.
//
// Which artifact feeds which ABI file is configured in abi-sources.json
// (ABI name as used in subgraph.yaml -> Solidity source + contract name).
// The check also lists contract events the subgraph does not index yet, so newly
// added events are easy to spot (informational; it does not fail the check).
// =============================================================================

"use strict";

const fs = require("fs");
const path = require("path");
const {
  SUBGRAPH_DIR,
  loadManifest,
  eventSignature,
  abiEvents,
  readAbiFile,
  loadAbiSources,
  findArtifactAbi,
  formatAbi,
} = require("./lib/subgraph-manifest");

function parseArgs(argv) {
  const args = { check: false, from: "auto" };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--check") args.check = true;
    else if (argv[i] === "--from") args.from = argv[++i];
    else if (argv[i].startsWith("--from=")) args.from = argv[i].slice("--from=".length);
    else throw new Error(`Unknown argument: ${argv[i]}`);
  }
  if (!["auto", "foundry", "hardhat"].includes(args.from)) {
    throw new Error(`--from must be foundry, hardhat or auto (got ${args.from})`);
  }
  return args;
}

function describeEventDrift(oldAbi, newAbi) {
  const oldSigs = new Set(abiEvents(oldAbi).map(eventSignature));
  const newSigs = new Set(abiEvents(newAbi).map(eventSignature));
  const lines = [];
  for (const s of newSigs) if (!oldSigs.has(s)) lines.push(`      + event ${s}`);
  for (const s of oldSigs) if (!newSigs.has(s)) lines.push(`      - event ${s}`);
  if (lines.length === 0) lines.push("      (event signatures unchanged; functions, errors or parameter names differ)");
  return lines;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const sources = loadAbiSources();
  const manifest = loadManifest();
  const abiDir = path.join(SUBGRAPH_DIR, "abis");
  fs.mkdirSync(abiDir, { recursive: true });

  let failed = false;
  const compiled = {};

  for (const [name, entry] of Object.entries(sources)) {
    const artifact = findArtifactAbi(entry, args.from);
    if (!artifact) {
      console.error(
        `ERROR ${name}: no compiled artifact for ${entry.source}:${entry.contract}. ` +
          "Run `forge build` or `npx hardhat compile` in the repository root first."
      );
      failed = true;
      continue;
    }
    compiled[name] = artifact.abi;
    const target = path.join(abiDir, `${name}.json`);
    const wanted = formatAbi(artifact.abi);
    const current = fs.existsSync(target) ? fs.readFileSync(target, "utf8") : null;
    const rel = path.relative(SUBGRAPH_DIR, target);

    if (current === wanted) {
      console.log(`ok      ${rel} (${artifact.kind})`);
    } else if (args.check) {
      failed = true;
      console.error(`STALE   ${rel} differs from ${path.relative(process.cwd(), artifact.file)}`);
      const oldAbi = current ? readAbiFile(target) : [];
      for (const line of describeEventDrift(oldAbi, artifact.abi)) console.error(line);
    } else {
      fs.writeFileSync(target, wanted);
      console.log(`wrote   ${rel} (${artifact.kind})`);
    }
  }

  // Every handler must name an event the compiled contract actually emits
  for (const ds of manifest.dataSources) {
    const abi = compiled[ds.abiName];
    if (!abi) {
      if (!sources[ds.abiName]) {
        console.error(`ERROR data source ${ds.name}: ABI "${ds.abiName}" is not listed in abi-sources.json`);
        failed = true;
      }
      continue;
    }
    const emitted = new Set(abiEvents(abi).map(eventSignature));
    const handled = new Set(ds.eventHandlers.map((h) => h.event));
    for (const h of ds.eventHandlers) {
      if (!emitted.has(h.event)) {
        console.error(`ERROR ${ds.name}: handler ${h.handler} listens for ${h.event}, which the contract does not emit`);
        failed = true;
      }
    }
    const unindexed = [...emitted].filter((s) => !handled.has(s));
    if (unindexed.length > 0) {
      console.log(`info    ${ds.name}: events not indexed by subgraph.yaml:`);
      for (const s of unindexed) console.log(`          ${s}`);
    }
  }

  if (failed) {
    console.error(
      args.check
        ? "\nABI check failed. Run `npm run sync-abis` (after compiling) and update subgraph.yaml / src/ as needed."
        : "\nABI sync failed."
    );
    process.exit(1);
  }
}

main();
