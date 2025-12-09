# llm-cost

[![Release](https://img.shields.io/github/v/release/Rul1an/llm-cost)](https://github.com/Rul1an/llm-cost/releases)
[![Build Status](https://img.shields.io/github/actions/workflow/status/Rul1an/llm-cost/release.yml?branch=main)](https://github.com/Rul1an/llm-cost/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

**Offline, exact token counting & cost estimation for OpenAI-style LLMs.**

`llm-cost` is a high-performance, single-binary CLI written in [Zig](https://ziglang.org). It provides production-grade token counting (perfect parity with `tiktoken`) and offline cost estimation.

- **Features**: `o200k_base` (GPT-4o) & `cl100k_base` support, 100% offline, cross-platform binaries.
- **Why not just tiktoken?**: Single binary (no Python required), built-in pricing DB, batch processing (`pipe`), and strict memory safety.
- **Privacy & Safety**: **No data leaves your machine.** All tokenization and pricing logic runs 100% locally.
- **Supported Models**: `gpt-4o`, `gpt-4`, `gpt-3.5-turbo`, and accurate pricing for all major OpenAI endpoints.

## Who is this for?

- **ML Engineers**: Estimate costs for evaluation pipelines and RAG prompts.
- **Data Teams**: Process JSONL logs in batch to reconstruct historical token usage.
- **FinOps / Platform**: Add "budget guards" (`--max-cost`) to CI/CD pipelines to prevent accidental overspending.

## Documentation

- **[Installation & Usage](#installation)**: Getting started.
- **[Architecture](docs/architecture.md)**: High-level design and data flow.
- **[Performance](docs/perf.md)**: Benchmarks and O(N log N) BPE implementation.
- **[Verification](docs/evil_corpus.md)**: How we verify parity with OpenAI.

## Installation

Download the latest binary from the [Releases Page](https://github.com/Rul1an/llm-cost/releases).

**Linux / macOS / Windows**:
```bash
# Example for Linux x86_64
wget https://github.com/Rul1an/llm-cost/releases/latest/download/llm-cost-linux-x86_64.zip
unzip llm-cost-linux-x86_64.zip
chmod +x llm-cost
sudo mv llm-cost /usr/local/bin/
```

*See [Releases](https://github.com/Rul1an/llm-cost/releases) for signatures and SHA256 hashes.*

## Usage

### Token Counting & Pricing

```bash
# Count tokens (defaults to o200k_base for gpt-4o)
echo "Hello AI" | llm-cost tokens --model gpt-4o

# Estimate price for a file
llm-cost price --model gpt-4o prompt.txt
```

### Pipe Mode (Batch / Agent)

Process JSONL streams efficiently. Useful for adding token counts to logs or enforcing quotas in agent loops.

```bash
cat data.jsonl | llm-cost pipe --model gpt-4o --summary --max-cost 5.00
```

See `llm-cost help` for full options.

## Contributing

We welcome contributions! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for build instructions and guidelines.

By participating in this project, you agree to abide by the [Code of Conduct](CODE_OF_CONDUCT.md).

## Security & Integrity

`llm-cost` is designed as a single static CLI binary with a strong focus on
supply-chain and output correctness:

- **Reproducible builds**
  All binaries are built via `zig build` / `zig build -Doptimize=ReleaseFast`
  using a fixed Zig toolchain (`0.13.x`).

- **Pinned GitHub Actions**
  CI and release workflows pin GitHub Actions by **commit SHA** instead of
  floating tags (e.g. `actions/checkout@<sha>`), reducing supply-chain risk.

- **Tested before every release**
  Release builds run the full test suite before artifacts are produced:
  - `zig build test` (unit tests)
  - `zig build test-golden` (CLI contract + JSON/exit codes)
  - `zig build fuzz` (tokenizer fuzz harness sanity)
  - `zig build test-parity` (tokenization parity vs reference corpus)
  - `zig build bench-bpe` (BPE microbenchmark smoke test)

- **SBOM & signing**
  For supported targets, the release workflow:
  - Generates a CycloneDX SBOM (`llm-cost-<platform>.cdx.json`)
  - Produces a signed binary plus signature and certificate:
    - `llm-cost-<platform>`
    - `llm-cost-<platform>.sig`
    - `llm-cost-<platform>.crt`

- **Stable CLI contract**
  Golden tests assert **STDOUT**, **STDERR**, and **exit codes** exactly for
  common scenarios (e.g. `tokens`, `price`, `pipe`, bad models, quota errors).
  Breaking changes to the CLI contract must update the golden files.

For details on reporting vulnerabilities, provenance, and hardening practices,
see [`SECURITY.md`](./SECURITY.md).

## License

MIT
