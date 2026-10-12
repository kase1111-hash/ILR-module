// =============================================================================
// Subgraph manifest + ABI helpers (dependency-free, CommonJS)
// =============================================================================
// Shared by scripts/sync-abis.js and the repository's Hardhat test
// (test/Subgraph.manifest.test.js), which runs without the subgraph's own
// node_modules installed. Keep this file free of npm dependencies.
// =============================================================================

"use strict";

const fs = require("fs");
const path = require("path");

const SUBGRAPH_DIR = path.resolve(__dirname, "..", "..");
const REPO_ROOT = path.resolve(SUBGRAPH_DIR, "..");

// -----------------------------------------------------------------------------
// Minimal YAML subset parser
// -----------------------------------------------------------------------------
// Supports exactly what subgraph.yaml uses: nested block mappings, block
// sequences (of scalars or of mappings), plain / single- / double-quoted
// scalars and `#` comments. No anchors, flow collections or multi-line scalars.

function stripComment(line) {
  let quote = null;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (quote) {
      if (c === quote) quote = null;
    } else if (c === '"' || c === "'") {
      quote = c;
    } else if (c === "#" && (i === 0 || /\s/.test(line[i - 1]))) {
      return line.slice(0, i);
    }
  }
  return line;
}

function scalar(raw) {
  const s = raw.trim();
  if ((s.startsWith('"') && s.endsWith('"')) || (s.startsWith("'") && s.endsWith("'"))) {
    return s.slice(1, -1);
  }
  return s;
}

function splitKey(content) {
  // "key: value" | "key:" -> [key, value]; null when the content is not a mapping entry
  const m = /^([A-Za-z0-9_$.\-/]+):(?:\s+(.*))?$/.exec(content);
  if (!m) return null;
  return [m[1], m[2] === undefined ? "" : m[2]];
}

function parseYamlSubset(text) {
  const lines = [];
  for (const rawLine of text.split(/\r?\n/)) {
    if (rawLine.includes("\t")) throw new Error(`YAML subset: tabs are not supported: ${JSON.stringify(rawLine)}`);
    const line = stripComment(rawLine).replace(/\s+$/, "");
    if (line.trim() === "") continue;
    const indent = line.length - line.trimStart().length;
    lines.push({ indent, content: line.trim() });
  }

  let pos = 0;

  function parseBlock(indent) {
    if (pos >= lines.length) return null;
    return lines[pos].content.startsWith("-") ? parseSequence(indent) : parseMapping(indent);
  }

  function parseValueAfterKey(parentIndent) {
    // Value of "key:" with nothing after the colon
    if (pos >= lines.length) return null;
    const next = lines[pos];
    if (next.indent > parentIndent) return parseBlock(next.indent);
    // Compact sequence: "key:\n- item" at the same indent as the key
    if (next.indent === parentIndent && next.content.startsWith("- ")) return parseSequence(parentIndent);
    return null;
  }

  function parseMapping(indent) {
    const out = {};
    while (pos < lines.length && lines[pos].indent === indent && !lines[pos].content.startsWith("- ")) {
      const kv = splitKey(lines[pos].content);
      if (!kv) throw new Error(`YAML subset: expected "key: value", got ${JSON.stringify(lines[pos].content)}`);
      pos++;
      out[kv[0]] = kv[1] === "" ? parseValueAfterKey(indent) : scalar(kv[1]);
    }
    if (pos < lines.length && lines[pos].indent > indent) {
      throw new Error(`YAML subset: unexpected indentation at ${JSON.stringify(lines[pos].content)}`);
    }
    return out;
  }

  function parseSequence(indent) {
    const out = [];
    while (pos < lines.length && lines[pos].indent === indent && lines[pos].content.startsWith("-")) {
      const item = lines[pos].content.replace(/^-\s*/, "");
      if (item === "") {
        pos++;
        out.push(parseValueAfterKey(indent));
      } else if (splitKey(item)) {
        // "- key: value" starts a mapping whose keys sit at indent + 2
        lines[pos] = { indent: indent + 2, content: item };
        out.push(parseMapping(indent + 2));
      } else {
        pos++;
        out.push(scalar(item));
      }
    }
    return out;
  }

  const result = parseBlock(lines.length ? lines[0].indent : 0);
  if (pos !== lines.length) throw new Error(`YAML subset: trailing content at ${JSON.stringify(lines[pos].content)}`);
  return result;
}

// -----------------------------------------------------------------------------
// Manifest
// -----------------------------------------------------------------------------

/**
 * Load subgraph.yaml into a flat description of its data sources.
 * @returns {{dataSources: Array<{name, abiName, abiFile, mappingFile, entities, eventHandlers}>, raw}}
 */
function loadManifest(subgraphDir = SUBGRAPH_DIR) {
  const raw = parseYamlSubset(fs.readFileSync(path.join(subgraphDir, "subgraph.yaml"), "utf8"));
  const dataSources = (raw.dataSources || []).map((ds) => {
    const mapping = ds.mapping || {};
    const abiName = ds.source && ds.source.abi;
    const abiEntry = (mapping.abis || []).find((a) => a.name === abiName);
    return {
      name: ds.name,
      abiName,
      abiFile: abiEntry ? path.resolve(subgraphDir, abiEntry.file) : null,
      mappingFile: mapping.file ? path.resolve(subgraphDir, mapping.file) : null,
      entities: mapping.entities || [],
      eventHandlers: (mapping.eventHandlers || []).map((h) => ({ event: h.event, handler: h.handler })),
    };
  });
  return { dataSources, raw };
}

// -----------------------------------------------------------------------------
// ABI helpers
// -----------------------------------------------------------------------------

function abiType(param) {
  if (param.type.startsWith("tuple")) {
    return `(${(param.components || []).map(abiType).join(",")})${param.type.slice("tuple".length)}`;
  }
  return param.type;
}

/** Event signature in the exact form subgraph.yaml uses, e.g. "Foo(indexed uint256,address)" */
function eventSignature(fragment) {
  const params = fragment.inputs.map((i) => `${i.indexed ? "indexed " : ""}${abiType(i)}`);
  return `${fragment.name}(${params.join(",")})`;
}

function abiEvents(abi) {
  return abi.filter((f) => f.type === "event");
}

/** Read an ABI file the way graph-cli does: a bare ABI array or a compiler artifact with an "abi" field */
function readAbiFile(file) {
  const json = JSON.parse(fs.readFileSync(file, "utf8"));
  if (Array.isArray(json)) return json;
  if (json && Array.isArray(json.abi)) return json.abi;
  if (json && json.compilerOutput && Array.isArray(json.compilerOutput.abi)) return json.compilerOutput.abi;
  throw new Error(`${file} holds no ABI`);
}

/** Read abi-sources.json: ABI name -> { source, contract } */
function loadAbiSources(subgraphDir = SUBGRAPH_DIR) {
  return JSON.parse(fs.readFileSync(path.join(subgraphDir, "abi-sources.json"), "utf8"));
}

/** Candidate compiler artifacts for an abi-sources.json entry (Foundry and Hardhat layouts) */
function artifactCandidates(entry, repoRoot = REPO_ROOT) {
  return [
    { kind: "foundry", file: path.join(repoRoot, "out", path.basename(entry.source), `${entry.contract}.json`) },
    { kind: "hardhat", file: path.join(repoRoot, "artifacts", entry.source, `${entry.contract}.json`) },
  ];
}

/**
 * Locate the compiled ABI for an entry.
 * @param preference "foundry" | "hardhat" | "auto" (auto = most recently written artifact)
 * @returns {{kind, file, abi} | null}
 */
function findArtifactAbi(entry, preference = "auto", repoRoot = REPO_ROOT) {
  const found = artifactCandidates(entry, repoRoot)
    .filter((c) => preference === "auto" || c.kind === preference)
    .filter((c) => fs.existsSync(c.file))
    .map((c) => ({ ...c, mtime: fs.statSync(c.file).mtimeMs }))
    .sort((a, b) => b.mtime - a.mtime);
  if (found.length === 0) return null;
  const artifact = JSON.parse(fs.readFileSync(found[0].file, "utf8"));
  if (!Array.isArray(artifact.abi)) throw new Error(`${found[0].file} has no "abi" array`);
  return { kind: found[0].kind, file: found[0].file, abi: artifact.abi };
}

function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map((k) => [k, canonical(value[k])])
    );
  }
  return value;
}

const ENTRY_ORDER = ["constructor", "fallback", "receive", "function", "event", "error"];

function entryKey(entry) {
  const rank = ENTRY_ORDER.indexOf(entry.type);
  return `${String(rank === -1 ? ENTRY_ORDER.length : rank).padStart(2, "0")}|${entry.name || ""}|${JSON.stringify(
    entry.inputs || []
  )}`;
}

/**
 * Canonical on-disk form of an ABI file in subgraph/abis: entries sorted by kind and name, object keys
 * sorted. Foundry and Hardhat emit the same ABI in different orders; this makes both produce the same file.
 */
function formatAbi(abi) {
  const entries = abi.map(canonical).sort((a, b) => (entryKey(a) < entryKey(b) ? -1 : entryKey(a) > entryKey(b) ? 1 : 0));
  return `${JSON.stringify(entries, null, 2)}\n`;
}

module.exports = {
  SUBGRAPH_DIR,
  REPO_ROOT,
  parseYamlSubset,
  loadManifest,
  eventSignature,
  abiEvents,
  readAbiFile,
  loadAbiSources,
  artifactCandidates,
  findArtifactAbi,
  formatAbi,
};
