# llm-cost

**Offline token counting and cost estimation for LLMs.**

`llm-cost` is a high-performance, single-binary CLI written in [Zig](https://ziglang.org). It provides token counting (including GPT-4o `o200k_base` BPE) and pricing estimates from a local snapshot.

> [!NOTE]
> Tested with Zig 0.13.0. Newer versions may require build adjustments.

## Features

- **Production-Grade Tokenizer**:
  - BPE support for `o200k_base` (GPT-4o / GPT-4o-mini) via embedded vocabulary.
  - *Note: In v0.1, small deviations from standard `tiktoken` are possible as formal parity tests are ongoing.*
- **Offline & Private**: Runs entirely locally. No data leaves your machine.
- **Fast**: Native binary performance, nearly instant startup.
- **Cross-Platform**: Single binaries (no runtime required) for macOS (ARM64), Linux (x86_64, ARM64, MUSL), and Windows.
- **Pipe-Friendly**: Designed for shell scripting and CI integration.
- **Flexible Output**: Supports `text`, `json`, and `ndjson` formats.

## Installation

Download the latest binary from the [Releases Page](https://github.com/Rul1an/llm-cost/releases).

**Linux / macOS:**
```bash
# Example for Linux x86_64
wget https://github.com/Rul1an/llm-cost/releases/latest/download/llm-cost-linux-x86_64.zip
unzip llm-cost-linux-x86_64.zip
chmod +x llm-cost
sudo mv llm-cost /usr/local/bin/
```

**Windows:**
Download the `.zip`, extract, and add `llm-cost` to your PATH.

### Verifying Downloads

We publish SHA256 checksums with every release.

```bash
shasum -a 256 llm-cost-linux-x86_64
# Compare hash with the GitHub release notes
```

## Usage

### Token Counting

Count tokens in a string or file. Defaults to `o200k_base` (GPT-4o) logic if model implies it.

```bash
# From stdin
echo "Hello AI" | llm-cost tokens --model gpt-4o

# From file
llm-cost tokens --model gpt-4o input.txt
```

### Cost Estimation

Estimate cost based on an embedded pricing snapshot (OpenAI).

```bash
# Calculate price for an input file
llm-cost price --model gpt-4o input.txt

# Manually specifying token counts
llm-cost price --model gpt-4o --tokens-in 5000 --tokens-out 200
```

### JSON Output

Ideal for integration with other tools (e.g., `jq`).

```bash
$ llm-cost price --model gpt-4o --tokens-in 1000 --format json
{
  "model": "gpt-4o",
  "tokens_input": 1000,
  "tokens_output": 0,
  "cost_usd": 0.005,
  "tokenizer": "from_db",
  "approximate": false
}
```

## Supported Models

- **GPT-4o** (`o200k_base`): BPE-based tokenizer with embedded vocab.
- **GPT-4 / 3.5** (`cl100k_base`): Pricing-only. Token counting uses a simple [whitespace fallback](src/core/engine.zig).
- **Generic**: Whitespace-based estimation for unknown models.

*Note: For models without a native tokenizer implementation, `llm-cost` falls back to a heuristic. This is useful for cost estimation but is not exact.*

## Building from Source

Requirements: **Zig 0.13.0**

```bash
git clone https://github.com/Rul1an/llm-cost
cd llm-cost

# Build release binary (zig-out/bin/llm-cost)
zig build -Doptimize=ReleaseFast

# Run tests
zig build test
```

## Cross-compilation

To cross-compile locally:

```bash
zig build -Dtarget=x86_64-linux-gnu
zig build -Dtarget=x86_64-windows-gnu
zig build -Dtarget=aarch64-macos
```

*These targets match the official release binaries built via GitHub Actions.*

## License

MIT
