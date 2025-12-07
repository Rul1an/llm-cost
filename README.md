# llm-cost

**Offline token counting and cost estimation for LLMs.**

`llm-cost` is a high-performance, single-binary CLI written in [Zig](https://ziglang.org). It provides accurate token counting (including GPT-4o `o200k_base`) and pricing estimates without making any API calls.

> [!NOTE]
> Compatible with Zig 0.13.0+.

## Features

- **Production-Grade Tokenizer**:
  - Full BPE support for `o200k_base` (GPT-4o, GPT-4o-mini).
  - *Note: `cl100k_base` support is currently planned.*
- **Offline & Private**: Runs entirely locally. No data leaves your machine.
- **Fast**: Native binary performance, nearly instant startup.
- **Cross-Platform**: Statically linked binaries for macOS (ARM64), Linux (x86_64, ARM64, MUSL), and Windows.
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

Estimate cost based on current OpenAI pricing (embedded in binary).

```bash
# Calculate price for an input file
llm-cost price --model gpt-4o input.txt

# Manually specifying token counts
llm-cost price --model gpt-4o-2024-05-13 --tokens-in 5000 --tokens-out 200
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

- **GPT-4o** (`o200k_base`): Full BPE support.
- **GPT-4 / 3.5** (`cl100k_base`): *Pricing only* (token counting falls back to simple whitespace approximation currently).
- **Generic**: Whitespace-based estimation for unknown models.

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

## cross-compilation

To cross-compile locally or check available targets:

```bash
zig build -Dtarget=x86_64-linux-gnu
zig build -Dtarget=x86_64-windows-gnu
zig build -Dtarget=aarch64-macos
```

## License

MIT
