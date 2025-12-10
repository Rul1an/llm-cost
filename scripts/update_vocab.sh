#!/bin/bash
# scripts/update_vocab.sh
#
# Downloads tiktoken vocabulary files from OpenAI and converts them to binary format.
# Run this whenever tiktoken releases new vocabulary versions.
#
# Usage:
#   ./scripts/update_vocab.sh
#
# Requirements:
#   - curl
#   - zig (for conversion tool)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
VOCAB_DIR="$PROJECT_ROOT/src/vocab"
CACHE_DIR="$PROJECT_ROOT/.vocab-cache"

# Vocabulary definitions
ENCODINGS="cl100k_base o200k_base"

get_url() {
    case "$1" in
        "cl100k_base") echo "https://openaipublic.blob.core.windows.net/encodings/cl100k_base.tiktoken" ;;
        "o200k_base") echo "https://openaipublic.blob.core.windows.net/encodings/o200k_base.tiktoken" ;;
    esac
}

echo "=== llm-cost Vocabulary Update ==="
echo ""

# Ensure directories exist
mkdir -p "$VOCAB_DIR"
mkdir -p "$CACHE_DIR"

# Build the converter tool
echo "Building convert-vocab tool..."
cd "$PROJECT_ROOT"
# Ensure we use local zvm zig if available, else PATH zig
if [ -f ~/.zvm/bin/zig ]; then
    ZIG_EXE=~/.zvm/bin/zig
else
    ZIG_EXE=zig
fi

"$ZIG_EXE" build
CONVERT_TOOL="$PROJECT_ROOT/zig-out/bin/convert-vocab"

if [[ ! -x "$CONVERT_TOOL" ]]; then
    echo "ERROR: Failed to build convert-vocab tool"
    exit 1
fi

# Download and convert each vocabulary
for encoding in $ENCODINGS; do
    url=$(get_url "$encoding")
    tiktoken_file="$CACHE_DIR/$encoding.tiktoken"
    bin_file="$VOCAB_DIR/$encoding.bin"

    echo ""
    echo "Processing $encoding..."

    # Download if not cached or if forced
    if [[ ! -f "$tiktoken_file" ]] || [[ "${FORCE_DOWNLOAD:-}" == "1" ]]; then
        echo "  Downloading from $url..."
        curl -fsSL "$url" -o "$tiktoken_file"
    else
        echo "  Using cached $tiktoken_file"
    fi

    # Checksum (optional, just print)
    actual_hash=$(shasum -a 256 "$tiktoken_file" | cut -d' ' -f1)
    echo "  SHA256: $actual_hash"

    # Convert to binary format
    echo "  Converting to binary format..."
    "$CONVERT_TOOL" "$tiktoken_file" "$bin_file"

    echo "  ✓ Created $bin_file"
done

echo ""
echo "=== Vocabulary Update Complete ==="
echo ""
echo "Files created in $VOCAB_DIR:"
ls -la "$VOCAB_DIR"/*.bin 2>/dev/null || echo "  (none)"
echo ""
echo "To use these in your code:"
echo '  const cl100k_data = @embedFile("vocab/cl100k_base.bin");'
echo '  const o200k_data = @embedFile("vocab/o200k_base.bin");'
