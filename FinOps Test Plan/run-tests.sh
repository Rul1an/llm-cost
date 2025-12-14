#!/bin/bash
# ============================================================================
# llm-cost Proof of Value Test Suite Runner
# ============================================================================
#
# Usage:
#   ./run-tests.sh           # Run all tests
#   ./run-tests.sh --p0      # Run P0 tests only
#   ./run-tests.sh --quick   # Run quick smoke tests
#   ./run-tests.sh POV-1     # Run specific test
#
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="${SCRIPT_DIR}/tests"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Test registry
declare -A TESTS=(
    ["POV-1"]="pov-1-regression.sh:P0:Regression Detection"
    ["POV-2"]="pov-2-cache-drift.sh:P0:Cache Drift Detection"
    ["POV-3"]="pov-3-chargeback.sh:P0:Chargeback Report"
    ["POV-4"]="pov-4-fuzzy-match.sh:P0:Fuzzy Matching"
    ["POV-5"]="pov-5-credits.sh:P1:Credits & Negatives"
    ["POV-6"]="pov-6-scale.sh:P1:Scale Test (1M rows)"
    ["POV-7"]="pov-7-unicode.sh:P1:Unicode & Special Chars"
    ["POV-8"]="pov-8-vantage.sh:P0:Vantage Round-Trip"
    ["POV-9"]="pov-9-github.sh:P0:GitHub Actions"
    ["POV-10"]="pov-10-multi-provider.sh:P1:Multi-Provider"
    ["POV-11"]="pov-11-determinism.sh:P0:Determinism"
    ["POV-12"]="pov-12-audit.sh:P1:Audit Trail"
    ["POV-13"]="pov-13-pii.sh:P1:PII Handling"
    ["POV-14"]="pov-14-errors.sh:P0:Error Handling"
    ["POV-15"]="pov-15-extreme-drift.sh:P1:Extreme Drift"
)

# Counters
PASSED=0
FAILED=0
SKIPPED=0

print_header() {
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║         llm-cost v1.2.0 Proof of Value Test Suite              ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Date: $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
    echo "Host: $(uname -s) $(uname -m)"
    echo ""
}

run_test() {
    local test_id=$1
    local test_info=${TESTS[$test_id]}
    
    if [ -z "$test_info" ]; then
        echo -e "${YELLOW}[SKIP]${NC} $test_id - Unknown test"
        ((SKIPPED++))
        return
    fi
    
    local script=$(echo "$test_info" | cut -d: -f1)
    local priority=$(echo "$test_info" | cut -d: -f2)
    local description=$(echo "$test_info" | cut -d: -f3)
    
    local script_path="${TESTS_DIR}/${script}"
    
    if [ ! -f "$script_path" ]; then
        echo -e "${YELLOW}[SKIP]${NC} $test_id ($priority) - $description"
        echo "         Script not found: $script"
        ((SKIPPED++))
        return
    fi
    
    echo -n "[$priority] $test_id - $description... "
    
    if bash "$script_path" > /tmp/test-output-$$.log 2>&1; then
        echo -e "${GREEN}PASS${NC}"
        ((PASSED++))
    else
        echo -e "${RED}FAIL${NC}"
        echo "    Output:"
        tail -5 /tmp/test-output-$$.log | sed 's/^/    /'
        ((FAILED++))
    fi
    
    rm -f /tmp/test-output-$$.log
}

run_p0_tests() {
    echo "Running P0 (Critical) tests..."
    echo ""
    
    for test_id in "${!TESTS[@]}"; do
        local priority=$(echo "${TESTS[$test_id]}" | cut -d: -f2)
        if [ "$priority" == "P0" ]; then
            run_test "$test_id"
        fi
    done
}

run_all_tests() {
    echo "Running all tests..."
    echo ""
    
    # Sort by test ID
    for test_id in $(echo "${!TESTS[@]}" | tr ' ' '\n' | sort); do
        run_test "$test_id"
    done
}

run_quick_tests() {
    echo "Running quick smoke tests..."
    echo ""
    
    run_test "POV-1"
    run_test "POV-4"
    run_test "POV-14"
}

print_summary() {
    local total=$((PASSED + FAILED + SKIPPED))
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "                         TEST SUMMARY"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo -e "  ${GREEN}Passed:${NC}  $PASSED"
    echo -e "  ${RED}Failed:${NC}  $FAILED"
    echo -e "  ${YELLOW}Skipped:${NC} $SKIPPED"
    echo "  ─────────────"
    echo "  Total:   $total"
    echo ""
    
    if [ $FAILED -eq 0 ] && [ $PASSED -gt 0 ]; then
        echo -e "${GREEN}✅ All executed tests passed!${NC}"
        return 0
    elif [ $FAILED -gt 0 ]; then
        echo -e "${RED}❌ $FAILED test(s) failed${NC}"
        return 1
    else
        echo -e "${YELLOW}⚠️  No tests executed${NC}"
        return 1
    fi
}

# Main
print_header

case "${1:-all}" in
    --p0|p0)
        run_p0_tests
        ;;
    --quick|quick)
        run_quick_tests
        ;;
    --all|all)
        run_all_tests
        ;;
    --list)
        echo "Available tests:"
        for test_id in $(echo "${!TESTS[@]}" | tr ' ' '\n' | sort); do
            local info=${TESTS[$test_id]}
            local priority=$(echo "$info" | cut -d: -f2)
            local desc=$(echo "$info" | cut -d: -f3)
            echo "  $test_id ($priority): $desc"
        done
        exit 0
        ;;
    POV-*)
        run_test "$1"
        ;;
    *)
        echo "Usage: $0 [--all|--p0|--quick|--list|POV-N]"
        exit 1
        ;;
esac

print_summary
