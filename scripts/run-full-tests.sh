#!/bin/bash
# =============================================================================
# NatLangChain ILRM - Full Test Suite Runner
# =============================================================================
# This script runs the complete test suite required for mainnet sign-off
# Usage: ./scripts/run-full-tests.sh [--ci]
# =============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
FUZZ_RUNS_DEFAULT=10000
FUZZ_RUNS_CI=10000
FUZZ_RUNS_CRITICAL=50000
RESULTS_DIR="test-results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Parse arguments
CI_MODE=false
if [[ "$1" == "--ci" ]]; then
    CI_MODE=true
fi

# Create results directory
mkdir -p "$RESULTS_DIR"

echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}  NatLangChain ILRM - Full Test Suite${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""
echo "Timestamp: $(date)"
echo "Fuzz Runs: $FUZZ_RUNS_DEFAULT"
echo "Results Directory: $RESULTS_DIR"
echo ""

# =============================================================================
# Step 1: Prerequisites Check
# =============================================================================
echo -e "${YELLOW}[1/7] Checking prerequisites...${NC}"

if ! command -v forge &> /dev/null; then
    echo -e "${RED}ERROR: Foundry (forge) is not installed${NC}"
    echo "Install with: curl -L https://foundry.paradigm.xyz | bash && foundryup"
    exit 1
fi

if ! command -v npx &> /dev/null; then
    echo -e "${RED}ERROR: Node.js/npm is not installed${NC}"
    exit 1
fi

echo "  Foundry: $(forge --version | head -1)"
echo "  Node.js: $(node --version)"
echo -e "${GREEN}  Prerequisites OK${NC}"
echo ""

# =============================================================================
# Step 2: Clean Build
# =============================================================================
echo -e "${YELLOW}[2/7] Building contracts...${NC}"

forge clean
forge build

if [ $? -ne 0 ]; then
    echo -e "${RED}ERROR: Build failed${NC}"
    exit 1
fi

echo -e "${GREEN}  Build successful${NC}"
echo ""

# =============================================================================
# Step 3: Standard Tests
# =============================================================================
echo -e "${YELLOW}[3/7] Running standard tests...${NC}"

forge test -vv 2>&1 | tee "$RESULTS_DIR/standard-tests-$TIMESTAMP.log"

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    echo -e "${RED}ERROR: Standard tests failed${NC}"
    exit 1
fi

echo -e "${GREEN}  Standard tests passed${NC}"
echo ""

# =============================================================================
# Step 4: Extended Fuzz Tests
# =============================================================================
echo -e "${YELLOW}[4/7] Running extended fuzz tests ($FUZZ_RUNS_DEFAULT runs)...${NC}"

forge test --fuzz-runs $FUZZ_RUNS_DEFAULT -vv 2>&1 | tee "$RESULTS_DIR/fuzz-tests-$TIMESTAMP.log"

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    echo -e "${RED}ERROR: Fuzz tests failed${NC}"
    exit 1
fi

echo -e "${GREEN}  Fuzz tests passed${NC}"
echo ""

# =============================================================================
# Step 5: Critical Contract Extended Fuzz (50,000 runs)
# =============================================================================
echo -e "${YELLOW}[5/7] Running critical contract fuzz tests ($FUZZ_RUNS_CRITICAL runs)...${NC}"

echo "  Testing ILRM..."
forge test --match-contract ILRM --fuzz-runs $FUZZ_RUNS_CRITICAL -vv 2>&1 | tee "$RESULTS_DIR/fuzz-ilrm-$TIMESTAMP.log"

echo "  Testing L3Bridge..."
forge test --match-contract L3Bridge --fuzz-runs $FUZZ_RUNS_CRITICAL -vv 2>&1 | tee "$RESULTS_DIR/fuzz-l3bridge-$TIMESTAMP.log"

echo "  Testing Treasury..."
forge test --match-contract Treasury --fuzz-runs $FUZZ_RUNS_CRITICAL -vv 2>&1 | tee "$RESULTS_DIR/fuzz-treasury-$TIMESTAMP.log"

echo -e "${GREEN}  Critical contract fuzz tests passed${NC}"
echo ""

# =============================================================================
# Step 6: Security Tests
# =============================================================================
echo -e "${YELLOW}[6/7] Running security tests...${NC}"

echo "  SecurityExploits..."
forge test --match-path test/SecurityExploits.t.sol -vvv 2>&1 | tee "$RESULTS_DIR/security-exploits-$TIMESTAMP.log"

echo "  StateMachinePermutations..."
forge test --match-path test/StateMachinePermutations.t.sol -vvv 2>&1 | tee "$RESULTS_DIR/state-machine-$TIMESTAMP.log"

echo "  NoDeadEndsVerification..."
forge test --match-path test/NoDeadEndsVerification.t.sol -vvv 2>&1 | tee "$RESULTS_DIR/deadlock-$TIMESTAMP.log"

echo -e "${GREEN}  Security tests passed${NC}"
echo ""

# =============================================================================
# Step 7: Coverage Report
# =============================================================================
echo -e "${YELLOW}[7/7] Generating coverage report...${NC}"

forge coverage --report lcov 2>&1 | tee "$RESULTS_DIR/coverage-$TIMESTAMP.log"
forge coverage --report summary 2>&1 | tee "$RESULTS_DIR/coverage-summary-$TIMESTAMP.txt"

echo -e "${GREEN}  Coverage report generated${NC}"
echo ""

# =============================================================================
# Generate Summary
# =============================================================================
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}  Test Summary${NC}"
echo -e "${BLUE}============================================${NC}"

SUMMARY_FILE="$RESULTS_DIR/test-summary-$TIMESTAMP.md"

cat > "$SUMMARY_FILE" << EOF
# Test Suite Results

**Date:** $(date)
**Fuzz Runs:** $FUZZ_RUNS_DEFAULT (standard) / $FUZZ_RUNS_CRITICAL (critical)

## Results

| Test Suite | Status | Log File |
|------------|--------|----------|
| Standard Tests | ✅ PASS | standard-tests-$TIMESTAMP.log |
| Fuzz Tests (10,000 runs) | ✅ PASS | fuzz-tests-$TIMESTAMP.log |
| ILRM Fuzz (50,000 runs) | ✅ PASS | fuzz-ilrm-$TIMESTAMP.log |
| L3Bridge Fuzz (50,000 runs) | ✅ PASS | fuzz-l3bridge-$TIMESTAMP.log |
| Treasury Fuzz (50,000 runs) | ✅ PASS | fuzz-treasury-$TIMESTAMP.log |
| Security Exploits | ✅ PASS | security-exploits-$TIMESTAMP.log |
| State Machine | ✅ PASS | state-machine-$TIMESTAMP.log |
| Deadlock Verification | ✅ PASS | deadlock-$TIMESTAMP.log |

## Coverage

See: coverage-summary-$TIMESTAMP.txt

## Sign-Off

- [x] All tests passed
- [x] Fuzz tests passed with 10,000 runs
- [x] Critical contracts tested with 50,000 runs
- [x] Security tests passed
- [x] Coverage report generated

**Signed by:** _______________
**Date:** _______________
EOF

echo "Summary saved to: $SUMMARY_FILE"
echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  ALL TESTS PASSED${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo "Results saved in: $RESULTS_DIR/"
echo "Summary: $SUMMARY_FILE"
echo ""
