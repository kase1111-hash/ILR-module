#!/usr/bin/env bash
# =============================================================================
# NatLangChain ILRM - Subgraph build and deployment
# =============================================================================
# Verifies the subgraph against the compiled contracts, builds and tests it, and
# optionally deploys it. Uses only the graph-cli pinned in subgraph/package-lock.json
# (0.98.1), run through npm/npx; no global install is needed.
#
# Usage (from anywhere in the repository):
#   scripts/deploy-subgraph.sh [options]                 verify, build and test only
#   GRAPH_DEPLOY_KEY=<key> scripts/deploy-subgraph.sh --studio <slug> --version-label <v>
#   scripts/deploy-subgraph.sh --local [<name>] --version-label <v>
#
# Options:
#   --studio <slug>          Deploy to Subgraph Studio (https://thegraph.com/studio/). The deploy key
#                            is read from GRAPH_DEPLOY_KEY and stored with `graph auth`; without it, a
#                            key saved earlier with `npx graph auth <key>` (in subgraph/) is used.
#   --local [<name>]         Deploy to a local Graph Node (http://localhost:8020, IPFS on
#                            http://localhost:5001); <name> defaults to ilrm-subgraph.
#   --version-label <v>      Version label of the deployment (required to deploy).
#   --sync-abis              Rewrite subgraph/abis from the compiled contracts first (review and commit
#                            the diff; the mappings may need updating too).
#   --skip-tests             Do not run the matchstick unit tests.
#   -h, --help               Show this help.
#
# Prerequisites: Node.js >= 20.18.1 and compiled contracts (`forge build` or
# `npx hardhat compile` in the repository root). Before deploying, replace the zero
# addresses and startBlock values in subgraph/subgraph.yaml with the deployment's.
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

STUDIO_NODE="https://api.studio.thegraph.com/deploy/"
LOCAL_NODE="http://localhost:8020/"
LOCAL_IPFS="http://localhost:5001"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBGRAPH_DIR="$REPO_ROOT/subgraph"

usage() {
    sed -n '/^# Usage/,/^# =====/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'
}

fail() {
    echo -e "${RED}ERROR: $*${NC}" >&2
    exit 1
}

step() {
    echo -e "${YELLOW}$*${NC}"
}

TARGET=""
NAME=""
VERSION_LABEL=""
SYNC_ABIS=false
RUN_TESTS=true

while [ $# -gt 0 ]; do
    case "$1" in
        --studio)
            [ $# -ge 2 ] && [ -n "$2" ] && [ "${2#-}" = "$2" ] || fail "--studio needs the Studio subgraph slug"
            TARGET="studio"
            NAME="$2"
            shift 2
            ;;
        --local)
            TARGET="local"
            if [ $# -ge 2 ] && [ -n "$2" ] && [ "${2#-}" = "$2" ]; then
                NAME="$2"
                shift
            else
                NAME="ilrm-subgraph"
            fi
            shift
            ;;
        --version-label)
            [ $# -ge 2 ] && [ -n "$2" ] || fail "--version-label needs a value"
            VERSION_LABEL="$2"
            shift 2
            ;;
        --sync-abis)
            SYNC_ABIS=true
            shift
            ;;
        --skip-tests)
            RUN_TESTS=false
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            fail "unknown argument: $1"
            ;;
    esac
done

if [ -n "$TARGET" ] && [ -z "$VERSION_LABEL" ]; then
    fail "--version-label is required to deploy (graph deploy would otherwise prompt for it)"
fi
if [ "$TARGET" = "studio" ] && [ -n "${GRAPH_DEPLOY_KEY:-}" ]; then
    # graph auth falls back to an interactive prompt for anything else
    [[ "$GRAPH_DEPLOY_KEY" =~ ^[0-9a-fA-F]{32}$ ]] || fail "GRAPH_DEPLOY_KEY is not a Subgraph Studio deploy key (32 hex characters)"
fi

echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}  ILRM Subgraph${NC}"
echo -e "${BLUE}============================================${NC}"
echo "Target: ${TARGET:-none (verify and build only)}${NAME:+ ($NAME)}"
echo ""

# -----------------------------------------------------------------------------
step "[1/6] Checking prerequisites..."
command -v node > /dev/null 2>&1 || fail "Node.js is not installed (>= 20.18.1 required)"
command -v npm > /dev/null 2>&1 || fail "npm is not installed"
node -e 'const [a, b, c] = process.versions.node.split(".").map(Number); process.exit(a > 20 || (a === 20 && (b > 18 || (b === 18 && c >= 1))) ? 0 : 1)' ||
    fail "Node.js $(node --version) is too old: graph-cli 0.98 needs >= 20.18.1"
echo "  Node.js $(node --version), npm $(npm --version)"
if [ ! -d "$REPO_ROOT/out" ] && [ ! -d "$REPO_ROOT/artifacts" ]; then
    fail "no compiled contracts: run 'forge build' or 'npx hardhat compile' in $REPO_ROOT first"
fi

cd "$SUBGRAPH_DIR"

# -----------------------------------------------------------------------------
step "[2/6] Installing subgraph dependencies (npm ci)..."
npm ci --no-audit --no-fund
echo "  graph-cli $(npx --no-install graph --version)"

# -----------------------------------------------------------------------------
step "[3/6] Checking abis/ against the compiled contracts..."
if [ "$SYNC_ABIS" = true ]; then
    npm run --silent sync-abis
fi
# Fails if abis/*.json drifted from the compiler artifacts or a handler names an event the
# contract does not emit (then run `npm run sync-abis` and update the mappings)
npm run --silent check-abis

# -----------------------------------------------------------------------------
step "[4/6] Generating types (graph codegen)..."
npm run --silent codegen

# -----------------------------------------------------------------------------
step "[5/6] Building (graph build)..."
npm run --silent build
if [ "$RUN_TESTS" = true ]; then
    npm test
else
    echo "  Skipping matchstick tests (--skip-tests)"
fi

# -----------------------------------------------------------------------------
step "[6/6] Deploying..."
if [ -z "$TARGET" ]; then
    echo "  No target given; nothing deployed. To deploy:"
    echo "    GRAPH_DEPLOY_KEY=<key> scripts/deploy-subgraph.sh --studio <slug> --version-label <v>"
    echo "    scripts/deploy-subgraph.sh --local [<name>] --version-label <v>"
    exit 0
fi

# Deploying the placeholder manifest would index nothing
if grep -Eq 'address: "0x0{40}"' subgraph.yaml; then
    fail "subgraph.yaml still has zero contract addresses; set each data source's address and startBlock first"
fi

if [ "$TARGET" = "studio" ]; then
    if [ -n "${GRAPH_DEPLOY_KEY:-}" ]; then
        # graph-cli 0.98: `graph auth <deploy-key>` stores the key for the Studio node
        npx --no-install graph auth "$GRAPH_DEPLOY_KEY"
    fi
    npx --no-install graph deploy "$NAME" --node "$STUDIO_NODE" --version-label "$VERSION_LABEL"
else
    # Creating a name that already exists fails; deploying to it still works
    npx --no-install graph create --node "$LOCAL_NODE" "$NAME" ||
        echo -e "${YELLOW}  graph create failed (the name may already exist); deploying anyway${NC}"
    npx --no-install graph deploy "$NAME" --node "$LOCAL_NODE" --ipfs "$LOCAL_IPFS" --version-label "$VERSION_LABEL"
fi

echo -e "${GREEN}  Subgraph deployed${NC}"
