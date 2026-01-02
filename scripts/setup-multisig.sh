#!/bin/bash
# =============================================================================
# NatLangChain ILRM - Multi-Sig Setup Script
# =============================================================================
# Guides through multi-sig governance setup process
# Usage: ./scripts/setup-multisig.sh [--network <network>]
# =============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Parse arguments
NETWORK="localhost"
if [[ "$1" == "--network" ]]; then
    NETWORK="$2"
fi

echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}  NatLangChain ILRM - Multi-Sig Setup${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""
echo "Network: $NETWORK"
echo ""

# =============================================================================
# Step 1: Prerequisites Check
# =============================================================================
echo -e "${YELLOW}[Step 1/7] Checking Prerequisites${NC}"

# Check for required tools
if ! command -v npx &> /dev/null; then
    echo -e "${RED}ERROR: npx not found. Install Node.js first.${NC}"
    exit 1
fi

# Check for .env file
if [ ! -f ".env" ]; then
    echo -e "${RED}ERROR: .env file not found.${NC}"
    echo "Copy .env.example to .env and configure it first."
    exit 1
fi

# Load environment
source .env 2>/dev/null || true

echo -e "${GREEN}  ✓ Prerequisites OK${NC}"
echo ""

# =============================================================================
# Step 2: Verify Multi-Sig Address
# =============================================================================
echo -e "${YELLOW}[Step 2/7] Verifying Multi-Sig Configuration${NC}"

if [ -z "$MULTISIG_ADDRESS" ] || [ "$MULTISIG_ADDRESS" == "0x0000000000000000000000000000000000000000" ]; then
    echo -e "${RED}ERROR: MULTISIG_ADDRESS not configured in .env${NC}"
    echo ""
    echo "To create a Gnosis Safe:"
    echo "  1. Go to https://app.safe.global/"
    echo "  2. Connect your wallet"
    echo "  3. Create a new Safe on $NETWORK"
    echo "  4. Add at least 3 owners"
    echo "  5. Set threshold to 2-of-3 minimum"
    echo "  6. Copy the Safe address to .env"
    echo ""
    exit 1
fi

echo "Multi-sig address: $MULTISIG_ADDRESS"
echo -e "${GREEN}  ✓ Multi-sig configured${NC}"
echo ""

# =============================================================================
# Step 3: Verify Protocol Contracts
# =============================================================================
echo -e "${YELLOW}[Step 3/7] Verifying Protocol Contracts${NC}"

REQUIRED_CONTRACTS=("ILRM_ADDRESS" "TREASURY_ADDRESS" "ORACLE_ADDRESS" "ASSET_REGISTRY_ADDRESS")
MISSING=0

for VAR in "${REQUIRED_CONTRACTS[@]}"; do
    VALUE="${!VAR}"
    if [ -z "$VALUE" ] || [ "$VALUE" == "0x0000000000000000000000000000000000000000" ]; then
        echo -e "${RED}  ✗ $VAR not set${NC}"
        MISSING=1
    else
        echo -e "${GREEN}  ✓ $VAR: $VALUE${NC}"
    fi
done

if [ $MISSING -eq 1 ]; then
    echo ""
    echo -e "${RED}ERROR: Some protocol contracts are not deployed.${NC}"
    echo "Run the deployment script first:"
    echo "  npx hardhat run scripts/deploy.js --network $NETWORK"
    exit 1
fi

echo ""

# =============================================================================
# Step 4: Deploy GovernanceTimelock
# =============================================================================
echo -e "${YELLOW}[Step 4/7] Deploying GovernanceTimelock${NC}"

if [ -n "$GOVERNANCE_TIMELOCK_ADDRESS" ] && [ "$GOVERNANCE_TIMELOCK_ADDRESS" != "0x0000000000000000000000000000000000000000" ]; then
    echo "GovernanceTimelock already deployed: $GOVERNANCE_TIMELOCK_ADDRESS"
    echo "Skipping deployment..."
else
    echo "Deploying GovernanceTimelock..."
    npx hardhat run scripts/deploy-governance.ts --network $NETWORK

    echo ""
    echo -e "${CYAN}ACTION REQUIRED:${NC}"
    echo "  1. Copy the GovernanceTimelock address from output above"
    echo "  2. Add it to .env as GOVERNANCE_TIMELOCK_ADDRESS"
    echo "  3. Re-run this script to continue"
    exit 0
fi

echo -e "${GREEN}  ✓ GovernanceTimelock ready${NC}"
echo ""

# =============================================================================
# Step 5: Transfer Ownership
# =============================================================================
echo -e "${YELLOW}[Step 5/7] Ownership Transfer Instructions${NC}"

echo ""
echo "To transfer ownership to the timelock:"
echo ""
echo "For each contract (ILRM, Treasury, Oracle, etc.):"
echo ""
echo "  1. From deployer wallet, call:"
echo "     contract.transferOwnership($GOVERNANCE_TIMELOCK_ADDRESS)"
echo ""
echo "  2. Create multi-sig proposal to accept ownership:"
echo "     timelock.acceptOwnership(contractAddress)"
echo ""
echo "  3. Wait for timelock delay (2 days)"
echo ""
echo "  4. Execute the proposal"
echo ""
echo -e "${CYAN}Contracts to transfer:${NC}"
echo "  - ILRM: $ILRM_ADDRESS"
echo "  - Treasury: $TREASURY_ADDRESS"
echo "  - Oracle: $ORACLE_ADDRESS"
echo "  - AssetRegistry: $ASSET_REGISTRY_ADDRESS"

if [ -n "$MULTI_PARTY_ILRM_ADDRESS" ]; then
    echo "  - MultiPartyILRM: $MULTI_PARTY_ILRM_ADDRESS"
fi

echo ""
echo -e "${GREEN}  ✓ Instructions provided${NC}"
echo ""

# =============================================================================
# Step 6: Test Multi-Sig Operations
# =============================================================================
echo -e "${YELLOW}[Step 6/7] Testing Multi-Sig Operations${NC}"

echo ""
echo "Running multi-sig test suite..."
echo ""

npx hardhat run scripts/test-multisig.ts --network $NETWORK

echo ""
echo -e "${GREEN}  ✓ Tests completed${NC}"
echo ""

# =============================================================================
# Step 7: Generate Configuration Report
# =============================================================================
echo -e "${YELLOW}[Step 7/7] Generating Configuration Report${NC}"

REPORT_FILE="multisig-config-$(date +%Y%m%d_%H%M%S).json"

cat > "$REPORT_FILE" << EOF
{
  "network": "$NETWORK",
  "timestamp": "$(date -Iseconds)",
  "multisig": {
    "address": "$MULTISIG_ADDRESS",
    "type": "Gnosis Safe"
  },
  "timelock": {
    "address": "$GOVERNANCE_TIMELOCK_ADDRESS",
    "minDelay": "2 days",
    "emergencyDelay": "12 hours",
    "longDelay": "4 days"
  },
  "contracts": {
    "ilrm": "$ILRM_ADDRESS",
    "treasury": "$TREASURY_ADDRESS",
    "oracle": "$ORACLE_ADDRESS",
    "assetRegistry": "$ASSET_REGISTRY_ADDRESS"
  },
  "status": {
    "timelockDeployed": true,
    "ownershipTransferred": false,
    "testsCompleted": true
  }
}
EOF

echo "Configuration saved to: $REPORT_FILE"
echo ""

# =============================================================================
# Summary
# =============================================================================
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}  Setup Summary${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""
echo "Multi-sig:  $MULTISIG_ADDRESS"
echo "Timelock:   $GOVERNANCE_TIMELOCK_ADDRESS"
echo ""
echo -e "${YELLOW}Remaining Manual Steps:${NC}"
echo "  1. Complete ownership transfers (see Step 5)"
echo "  2. Test standard operation via multi-sig"
echo "  3. Test emergency pause via multi-sig"
echo "  4. Verify threshold enforcement"
echo "  5. Update docs/MULTISIG_CONFIG.md"
echo "  6. Renounce admin role on timelock"
echo ""
echo "Documentation:"
echo "  - docs/MULTISIG_CONFIG.md"
echo "  - docs/SIGN_OFF_PROCEDURES.md (Section 3)"
echo ""
echo -e "${GREEN}Multi-sig governance setup initiated!${NC}"
echo ""
