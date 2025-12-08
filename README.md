# llm-cost

**Offline token counting and cost estimation for LLMs.**


`llm-cost` is a high-performance, single-binary CLI written in [Zig](https://ziglang.org). It provides token counting (including GPT-4o `o200k_base` BPE) and pricing estimates from a local snapshot.

## State of LLMs (2025)

OpenAI’s GPT-4o family is now the default choice for many applications: it’s fast, relatively cheap, and uses the `o200k_base` tokenizer. Classic GPT-4 / GPT-3.5 models are still widely used in existing systems and rely on the older `cl100k_base` encoding.

Above that, newer “frontier” models (e.g. GPT-5 and dedicated reasoning models) push quality further, but they don’t replace the huge installed base of 4o/4-class models overnight. In parallel, other vendors (Anthropic Claude, Google Gemini, open-weight Llama variants) keep raising the bar, but they mostly stick to their own BPE-style tokenizers.

`llm-cost` focuses on the practical layer underneath all of this: **exact, offline token counting and cost estimation** for the two OpenAI encodings that currently matter most in production (`o200k_base` for GPT-4o and `cl100k_base` for GPT-4/3.5 and embeddings), with strict parity to `tiktoken` and defenses against worst-case inputs.

> [!IMPORTANT]
> **Requirement**: Zig 0.13.x (0.14+ is not currently supported).

## Quick Start

```bash
# Count tokens for GPT-4o
echo "Hello AI" | llm-cost tokens --model gpt-4o

# Estimate cost for a prompt file
llm-cost price --model gpt-4o prompt.txt
```

## Features

- **Production-Grade Tokenizer**:
  - Full BPE support for `o200k_base` (GPT-4o) and `cl100k_base` (GPT-4/Turbo).
  - Parity-verified against OpenAI's `tiktoken` (using Evil Corpus v2).
  - Fuzz-tested for robustness against chaotic input.
- **Offline & Private**: Runs entirely locally. No data leaves your machine.
  - *Same tokenization as OpenAI's `tiktoken` for `o200k_base` and `cl100k_base`.*
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

### Signature Verification (Recommended)

Every release includes Cosign signatures (keyless).

```bash
cosign verify-blob \
  --certificate llm-cost-linux-x86_64.crt \
  --signature llm-cost-linux-x86_64.sig \
  llm-cost-linux-x86_64
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

### Streaming JSONL (pipe mode)

Efficiently process large datasets. Reads JSONL from stdin, enriches with token/cost fields, and writes to stdout.

```bash
cat data.jsonl \
  | llm-cost pipe \
      --model gpt-4o \
      --field text \
      --mode price \
      --workers 4 \
  > enriched.jsonl
```

- `--field text`: The input JSON key containing text to tokenize.
- **Output Fields**: Adds `tokens_in`, `tokens_out`, and `cost_usd`.
  - *Note: `pipe` uses slightly different keys (`tokens_in`) than `price` (`tokens_input`) for brevity in JSONL.*

## Supported Models

- **GPT-4o** (`o200k_base`): BPE-based tokenizer with embedded vocab.
- **GPT-4 / 3.5** (`cl100k_base`): BPE-based tokenizer with embedded vocab.
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

## Roadmap

**v0.4 – UX & Multi-provider-ready**
- CLI Ergonomics: Normalized model names (e.g. `openai/gpt-4o`), summary outputs, and "accuracy tier" indication.
- Documentation: Guides for adding custom vocabularies/encodings.
- Integration: Official examples for GitHub Actions and GitLab CI.

**v0.5 – Extra Encodings & Scaling**
- Support for additional vendor encodings (depending on ecosystem demand).
- Optimizations for extremely long contexts (GB-scale inputs).

See the full [Technical Spec & Roadmap](docs/v0.3-spec.md) for details.
