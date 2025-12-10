# llm-cost

Offline CLI tool for token counting and cost estimation for LLMs (GPT-4, GPT-4o), ensuring *bit-for-bit* parity with official `tiktoken` tokenizers.

## Status

- **Zig**: 0.14.0
- **Supported Encodings**:
  - `cl100k_base` (e.g. `gpt-4`, `gpt-3.5-turbo`, `text-embedding-3`)
  - `o200k_base` (e.g. `gpt-4o`, `o1`)
- **Verification**: 30 "evil" edge cases verified against `tiktoken` in CI.

## Installation

### From Source

Requirements:
- Zig 0.14.0
- Git

```bash
git clone https://github.com/Rul1an/llm-cost.git
cd llm-cost
zig build -Doptimize=ReleaseFast
# Binary output: zig-out/bin/llm-cost
```

Optional install to system path:
```bash
zig build install -Doptimize=ReleaseFast
```

## Usage

### 1. Token Counting

Count tokens for a string:

```bash
llm-cost count --model gpt-4o --text "Hello, world"
```

Or with explicit encoding:

```bash
llm-cost count --encoding o200k_base --text "Hello, world"
```

JSON output:

```bash
llm-cost count --model gpt-4o --text "Hello" --format json
```

### 2. Stdin / Pipe

Read from stdin:
```bash
echo 'Hello' | llm-cost count --model gpt-4o
```

### 3. Cost Estimation

Estimate cost using embedded pricing DB:

```bash
llm-cost estimate \
  --model gpt-4o \
  --input-tokens 1000 \
  --output-tokens 500
```

## Parity & Verification

Tokenization is guaranteed to be identical to `tiktoken` for supported encodings.

**Guarantees:**
- **Vocab**: Vocabulary and merge tables are exported from `tiktoken` and embedded as binary blobs.
- **Golden Data**: `scripts/generate_golden.py` builds `evil_corpus_v2.jsonl` with 30 edge cases (whitespace, unicode).
- **CI**: `src/golden_test.zig` validates `llm-cost` against this corpus.

**Run checks:**
```bash
zig build test          # Unit tests
zig build test-golden   # Parity verification
zig build fuzz          # Stability fuzzing
```

**Known Limitations**:
- Pricing data is updated as of December 2025.
- Requires Zig 0.14.0 exact version.

## License

See [LICENSE](LICENSE) and [NOTICE](NOTICE).
