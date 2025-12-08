#!/bin/bash
set -euo pipefail

# Usage: ./estimate-dataset.sh <input.jsonl> <output.jsonl>

if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    echo "Usage: $0 <input.jsonl> <output.jsonl>"
    echo "Example: $0 input.jsonl enriched.jsonl"
    exit 0
fi

INPUT_FILE=$1
OUTPUT_FILE=$2

if [ -z "$INPUT_FILE" ] || [ -z "$OUTPUT_FILE" ]; then
    echo "Usage: $0 <input.jsonl> <output.jsonl>"
    exit 1
fi

echo "Processing $INPUT_FILE using llm-cost..."

# Setup: Download if not present (optional, or assume installed)
if ! command -v llm-cost &> /dev/null; then
    echo "Error: llm-cost not found in PATH."
    exit 1
fi

if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    echo "Usage: $0 <input.jsonl> <output.jsonl>"
    echo "Example: $0 input.jsonl enriched.jsonl"
    exit 0
fi

# Run pipe with summary
# - model: openai/gpt-4o
# - workers: 8 (parallel processing)
cat "$INPUT_FILE" | \
    llm-cost pipe \
    --model openai/gpt-4o \
    --mode price \
    --workers 8 \
    --summary \
    > "$OUTPUT_FILE"

echo "Done. Results saved to $OUTPUT_FILE"
