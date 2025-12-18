#!/bin/bash
set -euo pipefail

# ANSI colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

FAIL=0

echo "🔍 Scanning for unpinned GitHub Actions (mutable tags)..."
echo "--------------------------------------------------------"

# Audit Script Enforcer
FILES=$(find .github/workflows -name "*.yml" -o -name "*.yaml")
ACTIONS=$(find .github/actions -name "action.yml" 2>/dev/null || true)

check_regex() {
    local file="$1"
    local pattern="$2"
    local fail_msg="$3"
    local invert="${4:-0}"

    if [ "$invert" -eq 1 ]; then
        if grep -qE "$pattern" "$file"; then
             echo -e "${RED}FAILURE: $file${NC} -> $fail_msg"
             grep -E "$pattern" "$file" | sed 's/^/    /'
             FAIL=1
        fi
    else
        if ! grep -qE "$pattern" "$file"; then
             echo -e "${RED}FAILURE: $file${NC} -> $fail_msg"
             FAIL=1
        fi
    fi
}

for file in $FILES $ACTIONS; do
    # Skip comments
    # 1. Unpinned Actions (mutable tags)
    # Ignore local paths (./)
    VIOLATIONS=$(grep "uses:" "$file" | grep -v "\./" | grep -vE "@[a-f0-9]{40}" || true)
    if [ -n "$VIOLATIONS" ]; then
        echo -e "${RED}FAILURE: $file${NC} -> Unpinned action found"
        echo "$VIOLATIONS"
        FAIL=1
    fi
done

echo "🔍 Scanning Workflows specific checks..."
for file in $FILES; do
    # 2. Latest Runners (Drift risk)
    check_regex "$file" "runs-on:.*-latest" "Mutable runner version ('-latest') detected. Pin to 'ubuntu-24.04', 'macos-14', etc." 1

    # 3. Permissions Block
    check_regex "$file" "^permissions:" "Missing top-level 'permissions:' block"

    # 4. Timeout Minutes
    # Heuristic: file should match 'timeout-minutes:' at least once
    check_regex "$file" "timeout-minutes:" "Missing 'timeout-minutes:' configuration"

    # 5. Persist Credentials (Checkout)
    if grep -q "actions/checkout" "$file"; then
        # Check if persist-credentials is set to false roughly near checkout
        # This is a weak grep check, but better than nothing.
        # We look for the string "persist-credentials: false" in the file.
        check_regex "$file" "persist-credentials: false" "Missing 'persist-credentials: false' for checkout"
    fi

    # 6. Shell Bash (Consistency)
    # Ideally checking every 'run:' block has 'shell: bash' context or file level defaults
    # For now, just warn if we see 'run:' but no 'shell: bash' in file? No, that's too noisy if defined in defaults.
    # checking for "shell: bash" presence is a basic sanity check
    # check_regex "$file" "shell: bash" "Consider explicit 'shell: bash' for better reproducibility"
done

if [ $FAIL -eq 1 ]; then
    echo "--------------------------------------------------------"
    echo -e "${RED}Audit Failed. Security hardening required.${NC}"
    exit 1
else
    echo "--------------------------------------------------------"
    echo -e "${GREEN}Audit Passed. Supply chain is hardened.${NC}"
    exit 0
fi
