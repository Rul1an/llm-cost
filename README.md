# llm-cost

[![CI](https://github.com/Rul1an/llm-cost/actions/workflows/ci.yml/badge.svg)](https://github.com/Rul1an/llm-cost/actions/workflows/ci.yml)
[![License](https://img.shields.io/github/license/Rul1an/llm-cost)](LICENSE)
[![Release](https://img.shields.io/github/v/release/Rul1an/llm-cost)](https://github.com/Rul1an/llm-cost/releases)

**Offline token counter and cost estimator for LLM Engineering.**

`llm-cost` is a statically linked CLI tool written in Zig. It replicates OpenAI's `tiktoken` logic with memory safety and offline capability. Designed for integration into CI/CD pipelines and infrastructure scripts.

## Features

- **Performance**: ~10 MB/s throughput on single core.
- **Offline**: Embedded pricing and vocabulary; no value is sent over the network.
- **Portable**: Static binary distribution for Linux, macOS, and Windows.
- **Parity**: Validated against `tiktoken` using edge-case corpora (Unicode, Whitespace).
- **Control**: Enforce cost limits via pipe mode.

## Installation

**Binaries**
Stable releases available on [GitHub Releases](https://github.com/Rul1an/llm-cost/releases/latest).

**Source**
Requires [Zig 0.14.0](https://ziglang.org/download/).
```bash
git clone https://github.com/Rul1an/llm-cost
cd llm-cost
zig build -Doptimize=ReleaseFast
cp zig-out/bin/llm-cost /usr/local/bin/
```

## Usage

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

**Pipeline Integration**
```bash
# Fail if cost exceeds $1.00
cat logs.jsonl | llm-cost pipe --model gpt-4o --max-cost 1.00
```

## Documentation

Project documentation follows the [Diátaxis](https://diataxis.fr/) structure.

| Type | Content |
|------|---------|
| **Guides** | [CI Integration](docs/guides/ci-integration.md), [Release Verification](docs/guides/verification.md) |
| **Reference** | [CLI Commands](docs/explanation/cli.md), [Benchmarks](docs/reference/benchmarks.md), [Man Page](docs/reference/llm-cost.1) |
| **Explanation** | [Architecture](docs/explanation/architecture.md), [Security Policy](SECURITY.md) |

## Performance

| Metric | Result (Apple Silicon) |
|--------|------------------------|
| **Throughput** | ~10.11 MB/s |
| **Latency (P99)** | ~0.13 ms (Small Inputs) |
| **Complexity** | O(N) Linear |

See [docs/reference/benchmarks.md](docs/reference/benchmarks.md) for methodology.

## Security

Builds adhere to SLSA Level 2 standards.
- **Artifacts**: Signed with Cosign (Keyless via OIDC).
- **SBOM**: CycloneDX format provided.
- **Reproducibility**: Deterministic builds.

See [docs/guides/verification.md](docs/guides/verification.md) for verification steps.

## License

MIT © [Rul1an](https://github.com/Rul1an)
