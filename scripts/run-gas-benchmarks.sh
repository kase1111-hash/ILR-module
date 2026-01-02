#!/bin/bash
# =============================================================================
# NatLangChain ILRM - Gas Benchmark Runner
# =============================================================================
# Generates comprehensive gas cost reports for protocol operations
# Usage: ./scripts/run-gas-benchmarks.sh
# =============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
RESULTS_DIR="gas-reports"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Create results directory
mkdir -p "$RESULTS_DIR"

echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}  NatLangChain ILRM - Gas Benchmarks${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""
echo "Timestamp: $(date)"
echo "Results Directory: $RESULTS_DIR"
echo ""

# =============================================================================
# Step 1: Check Prerequisites
# =============================================================================
echo -e "${YELLOW}[1/5] Checking prerequisites...${NC}"

if ! command -v forge &> /dev/null; then
    echo -e "${RED}ERROR: Foundry (forge) is not installed${NC}"
    exit 1
fi

echo -e "${GREEN}  Foundry OK${NC}"
echo ""

# =============================================================================
# Step 2: Clean Build
# =============================================================================
echo -e "${YELLOW}[2/5] Building contracts...${NC}"

forge build --sizes 2>&1 | tee "$RESULTS_DIR/contract-sizes-$TIMESTAMP.txt"

echo -e "${GREEN}  Build complete${NC}"
echo ""

# =============================================================================
# Step 3: Run Gas Benchmarks
# =============================================================================
echo -e "${YELLOW}[3/5] Running gas benchmarks...${NC}"

forge test --match-contract GasBenchmarks --gas-report -vv 2>&1 | tee "$RESULTS_DIR/gas-benchmarks-$TIMESTAMP.txt"

echo -e "${GREEN}  Benchmarks complete${NC}"
echo ""

# =============================================================================
# Step 4: Generate Full Gas Report
# =============================================================================
echo -e "${YELLOW}[4/5] Generating full gas report...${NC}"

forge test --gas-report 2>&1 | tee "$RESULTS_DIR/gas-report-full-$TIMESTAMP.txt"

# Extract just the gas table
grep -A 1000 "╭─" "$RESULTS_DIR/gas-report-full-$TIMESTAMP.txt" | head -500 > "$RESULTS_DIR/gas-table-$TIMESTAMP.txt" 2>/dev/null || true

echo -e "${GREEN}  Report generated${NC}"
echo ""

# =============================================================================
# Step 5: Generate Summary
# =============================================================================
echo -e "${YELLOW}[5/5] Generating summary...${NC}"

SUMMARY_FILE="$RESULTS_DIR/gas-summary-$TIMESTAMP.md"

cat > "$SUMMARY_FILE" << 'EOF'
# Gas Benchmark Results

**Generated:** TIMESTAMP_PLACEHOLDER
**Network Assumptions:**
- Ethereum L1: 30 gwei gas price, $3,500 ETH
- Optimism L2: 0.001 gwei gas price, $3,500 ETH

## Critical Function Benchmarks

| Function | Gas Used | L1 Cost (USD) | L2 Cost (USD) | Status |
|----------|----------|---------------|---------------|--------|
| initiateBreachDispute | | | | |
| matchStake | | | | |
| counterPropose | | | | |
| acceptProposal | | | | |
| enforceTimeout | | | | |
| distributeSubsidy | | | | |
| submitProposal | | | | |

## Acceptable Limits

| Function | Max Acceptable Gas | Reason |
|----------|-------------------|--------|
| initiateBreachDispute | 300,000 | User-initiated, should be affordable |
| matchStake | 200,000 | User-initiated, should be affordable |
| counterPropose | 250,000 | Includes fee payment |
| acceptProposal | 200,000 | May trigger settlement |
| enforceTimeout | 150,000 | Automated, gas refundable |
| distributeSubsidy | 120,000 | Treasury operation |
| submitProposal | 150,000 | Oracle operation |

## Contract Sizes

See: contract-sizes-TIMESTAMP_PLACEHOLDER.txt

## Full Report

See: gas-report-full-TIMESTAMP_PLACEHOLDER.txt

## Sign-Off

- [ ] All critical functions within acceptable limits
- [ ] No functions exceed 500,000 gas
- [ ] Batch operations scale linearly
- [ ] USD costs acceptable for target users

**Reviewed by:** _______________
**Date:** _______________
EOF

# Replace timestamp placeholder
sed -i "s/TIMESTAMP_PLACEHOLDER/$TIMESTAMP/g" "$SUMMARY_FILE"

echo -e "${GREEN}  Summary saved: $SUMMARY_FILE${NC}"
echo ""

# =============================================================================
# Final Output
# =============================================================================
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}  Gas Benchmarks Complete${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""
echo "Results saved in: $RESULTS_DIR/"
echo ""
echo "Files generated:"
echo "  - contract-sizes-$TIMESTAMP.txt"
echo "  - gas-benchmarks-$TIMESTAMP.txt"
echo "  - gas-report-full-$TIMESTAMP.txt"
echo "  - gas-table-$TIMESTAMP.txt"
echo "  - gas-summary-$TIMESTAMP.md"
echo ""
echo "Next steps:"
echo "  1. Review gas-summary-$TIMESTAMP.md"
echo "  2. Fill in actual gas values from benchmarks"
echo "  3. Calculate USD costs"
echo "  4. Update docs/GAS_COSTS.md"
echo ""
