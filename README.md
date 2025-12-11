# llm-cost

[![CI](https://github.com/Rul1an/llm-cost/actions/workflows/ci.yml/badge.svg)](https://github.com/Rul1an/llm-cost/actions/workflows/ci.yml)
[![License](https://img.shields.io/github/license/Rul1an/llm-cost)](LICENSE)
[![Release](https://img.shields.io/github/v/release/Rul1an/llm-cost)](https://github.com/Rul1an/llm-cost/releases)

**High-performance, zero-dependency token counter & cost estimator for LLM Engineering.**

`llm-cost` is a standalone CLI tool written in Zig. It provides **exact parity** with OpenAI's `tiktoken` but runs significantly faster (~10 MB/s), is memory-safe, and operates entirely offline. Designed for CI/CD pipelines, pre-commit hooks, and cost-control infrastructure.

## Features

- ⚡ **High Performance**: ~10 MB/s throughput (Single-threaded). [See Benchmarks](docs/reference/benchmarks.md).
- 🔒 **Offline & Secure**: No API calls. Embedded pricing & method-verified vocabulary.
- 🏗️ **Zero Dependency**: Static binary distribution (Linux, macOS, Windows).
- ✅ **Parity Guaranteed**: Validated against "Evil Corpus" edge cases (Unicode, Whitespace) for 100% `tiktoken` match.
- 💰 **Cost Guardrails**: Enforce budget limits in CI/CD pipes via `pipe` mode.

## Quick Start

### Installation

**Download Binaries**
Get the latest stable release for your platform from [GitHub Releases](https://github.com/Rul1an/llm-cost/releases/latest).

**Build from Source**
Requires [Zig 0.14.0](https://ziglang.org/download/).
```bash
git clone https://github.com/Rul1an/llm-cost
cd llm-cost
zig build -Doptimize=ReleaseFast
cp zig-out/bin/llm-cost /usr/local/bin/
```

### Usage

**Count Tokens**
```bash
# Direct input
llm-cost count --model gpt-4o --text "Hello world"

# Pipe from file
cat document.txt | llm-cost count --model gpt-4o
```

**Estimate Cost**
```bash
llm-cost estimate --model gpt-4o --input-tokens 5000 --output-tokens 200
```

**CI Guardrail (Pipe Mode)**
```bash
# Block pipeline if cost exceeds $1.00
cat logs.jsonl | llm-cost pipe --model gpt-4o --max-cost 1.00
```

## Documentation

We follow the **[Diátaxis](https://diataxis.fr/)** framework for documentation.

| Type | Content |
|------|---------|
| **📘 Guides** | [CI Integration](docs/guides/ci-integration.md), [Release Verification](docs/guides/verification.md) |
| **📙 Reference** | [CLI Commands](docs/explanation/cli.md), [Benchmarks](docs/reference/benchmarks.md), [Man Page](docs/reference/llm-cost.1) |
| **📗 Explanation** | [Architecture](docs/explanation/architecture.md), [Security Policy](SECURITY.md) |

## Performance

`llm-cost` is engineered for raw throughput to handle large datasets (RAG indexing, log analysis).

| Metric | Result (Apple Silicon) |
|--------|------------------------|
| **Throughput** | ~10.11 MB/s |
| **Latency (P99)** | ~0.13 ms (Small Inputs) |
| **Complexity** | O(N) Linear |

Full detailed report: [**docs/reference/benchmarks.md**](docs/reference/benchmarks.md).

## Security & Verification

This project adheres to **SLSA Level 2** standards.
- **Signed Artifacts**: Release binaries are signed with Cosign (Keyless via OIDC).
- **SBOM**: Software Bill of Materials provided in CycloneDX format.
- **Reproducible**: Builds are deterministic.

Run `docs/guides/verification.md` to verify binary integrity.

## License

MIT © [Rul1an](https://github.com/Rul1an)
