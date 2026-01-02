#!/bin/bash
# =============================================================================
# NatLangChain ILRM - Subgraph Deployment Script
# =============================================================================
# This script helps deploy the ILRM subgraph to TheGraph
# Usage: ./scripts/deploy-subgraph.sh [network] [deploy-key]
# =============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SUBGRAPH_DIR="subgraph"
NETWORK=${1:-"optimism"}
DEPLOY_KEY=${2:-""}

echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}  ILRM Subgraph Deployment${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""
echo "Network: $NETWORK"
echo ""

# =============================================================================
# Step 1: Prerequisites Check
# =============================================================================
echo -e "${YELLOW}[1/6] Checking prerequisites...${NC}"

if ! command -v graph &> /dev/null; then
    echo -e "${RED}ERROR: Graph CLI is not installed${NC}"
    echo "Install with: npm install -g @graphprotocol/graph-cli"
    exit 1
fi

if ! command -v node &> /dev/null; then
    echo -e "${RED}ERROR: Node.js is not installed${NC}"
    exit 1
fi

echo "  Graph CLI: $(graph --version)"
echo "  Node.js: $(node --version)"
echo -e "${GREEN}  Prerequisites OK${NC}"
echo ""

# =============================================================================
# Step 2: Install Dependencies
# =============================================================================
echo -e "${YELLOW}[2/6] Installing dependencies...${NC}"

cd "$SUBGRAPH_DIR"
npm install

echo -e "${GREEN}  Dependencies installed${NC}"
echo ""

# =============================================================================
# Step 3: Generate ABIs
# =============================================================================
echo -e "${YELLOW}[3/6] Copying contract ABIs...${NC}"

mkdir -p abis

# Check if Foundry output exists
if [ -d "../out" ]; then
    # Copy ABIs from Foundry output
    if [ -f "../out/ILRM.sol/ILRM.json" ]; then
        cp ../out/ILRM.sol/ILRM.json abis/
        echo "  Copied ILRM.json"
    fi
    if [ -f "../out/Treasury.sol/Treasury.json" ]; then
        cp ../out/Treasury.sol/Treasury.json abis/
        echo "  Copied Treasury.json"
    fi
    if [ -f "../out/Oracle.sol/Oracle.json" ]; then
        cp ../out/Oracle.sol/Oracle.json abis/
        echo "  Copied Oracle.json"
    fi
    if [ -f "../out/L3Bridge.sol/L3Bridge.json" ]; then
        cp ../out/L3Bridge.sol/L3Bridge.json abis/
        echo "  Copied L3Bridge.json"
    fi
    if [ -f "../out/AssetRegistry.sol/AssetRegistry.json" ]; then
        cp ../out/AssetRegistry.sol/AssetRegistry.json abis/
        echo "  Copied AssetRegistry.json"
    fi
else
    echo -e "${YELLOW}  WARNING: Foundry output not found. Run 'forge build' first.${NC}"
    echo "  Checking for Hardhat artifacts..."

    if [ -d "../artifacts" ]; then
        # Copy ABIs from Hardhat output
        find ../artifacts -name "ILRM.json" -exec cp {} abis/ \; 2>/dev/null || true
        find ../artifacts -name "Treasury.json" -exec cp {} abis/ \; 2>/dev/null || true
        find ../artifacts -name "Oracle.json" -exec cp {} abis/ \; 2>/dev/null || true
        find ../artifacts -name "L3Bridge.json" -exec cp {} abis/ \; 2>/dev/null || true
        find ../artifacts -name "AssetRegistry.json" -exec cp {} abis/ \; 2>/dev/null || true
    fi
fi

# Verify ABIs exist
if [ ! -f "abis/ILRM.json" ]; then
    echo -e "${RED}ERROR: ILRM.json ABI not found${NC}"
    echo "Please run 'forge build' or 'npx hardhat compile' first"
    exit 1
fi

echo -e "${GREEN}  ABIs copied${NC}"
echo ""

# =============================================================================
# Step 4: Generate Types
# =============================================================================
echo -e "${YELLOW}[4/6] Generating TypeScript types...${NC}"

npm run codegen

echo -e "${GREEN}  Types generated${NC}"
echo ""

# =============================================================================
# Step 5: Build Subgraph
# =============================================================================
echo -e "${YELLOW}[5/6] Building subgraph...${NC}"

npm run build

echo -e "${GREEN}  Subgraph built${NC}"
echo ""

# =============================================================================
# Step 6: Deploy
# =============================================================================
echo -e "${YELLOW}[6/6] Deploying subgraph...${NC}"

if [ -z "$DEPLOY_KEY" ]; then
    echo -e "${YELLOW}  No deploy key provided. Skipping deployment.${NC}"
    echo ""
    echo "To deploy, run one of the following:"
    echo ""
    echo "  # TheGraph Studio (recommended)"
    echo "  graph auth --studio YOUR_DEPLOY_KEY"
    echo "  npm run deploy"
    echo ""
    echo "  # Local development"
    echo "  npm run create-local"
    echo "  npm run deploy-local"
    echo ""
else
    echo "  Authenticating with TheGraph Studio..."
    graph auth --studio "$DEPLOY_KEY"

    echo "  Deploying..."
    npm run deploy

    echo -e "${GREEN}  Subgraph deployed!${NC}"
fi

echo ""
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}  Subgraph Build Complete${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""
echo "Next steps:"
echo "  1. Update subgraph.yaml with deployed contract addresses"
echo "  2. Set the correct startBlock for each contract"
echo "  3. Deploy to TheGraph Studio or hosted service"
echo ""
echo "Example queries available in subgraph/README.md"
echo ""

cd ..
