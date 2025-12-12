#!/bin/bash
set -euo pipefail

# Determinism Verification Script
# Runs llm-cost commands multiple times and asserts identical output hashes.

BIN="./zig-out/bin/llm-cost"
RUNS=5

# Resolve absolute path to bin
BIN_ABS=$(cd "$(dirname "$BIN")"; pwd)/$(basename "$BIN")

if [ ! -f "$BIN_ABS" ]; then
    echo "Error: llm-cost binary not found at $BIN_ABS"
    exit 1
fi

echo "Verifying determinism over $RUNS runs..."

# 1. Estimate JSON (STDIN)
echo "---------------------------------------------------"
echo "Test 1: estimate --format=json (STDIN)"
INPUT="This is a test prompt to verify determinism."
HASH_1=""

for i in $(seq 1 $RUNS); do
    OUTPUT=$(echo "$INPUT" | "$BIN_ABS" estimate --model gpt-4o --format=json)
    CURRENT_HASH=$(echo "$OUTPUT" | shasum -a 256 | awk '{print $1}')

    if [ -z "$HASH_1" ]; then
        HASH_1="$CURRENT_HASH"
        echo "Run 1 Hash: $HASH_1"
    else
        if [ "$CURRENT_HASH" != "$HASH_1" ]; then
            echo "FAIL: Run $i hash mismatch!"
            echo "Expected: $HASH_1"
            echo "Got:      $CURRENT_HASH"
            exit 1
        fi
    fi
done
echo "PASS: Estimate JSON is deterministic."

# 2. Export FOCUS (Mock Manifest)
echo "---------------------------------------------------"
echo "Test 2: export --format=focus"
# We need a manifest. create temp one.
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/llm-cost.toml" <<EOF
[[prompts]]
path = "prompt.txt"
model = "gpt-4o"
[prompts.tags]
env = "prod"
team = "data"
EOF

echo "Test prompt content" > "$TMP_DIR/prompt.txt"

HASH_2=""
for i in $(seq 1 $RUNS); do
    # Run in tmp dir
    OUTPUT=$(cd "$TMP_DIR" && "$BIN_ABS" export --format=focus)
    CURRENT_HASH=$(echo "$OUTPUT" | shasum -a 256 | awk '{print $1}')

    if [ -z "$HASH_2" ]; then
        HASH_2="$CURRENT_HASH"
        echo "Run 1 Hash: $HASH_2"
    else
        if [ "$CURRENT_HASH" != "$HASH_2" ]; then
            echo "FAIL: Run $i hash mismatch!"
            echo "Expected: $HASH_2"
            echo "Got:      $CURRENT_HASH"
            exit 1
        fi
    fi
done
echo "PASS: Export FOCUS is deterministic."

echo "---------------------------------------------------"
echo "All determinism tests passed."
