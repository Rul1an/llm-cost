# llm-cost

[![CI](https://github.com/Rul1an/llm-cost/actions/workflows/ci.yml/badge.svg)](https://github.com/Rul1an/llm-cost/actions/workflows/ci.yml)
[![License](https://img.shields.io/github/license/Rul1an/llm-cost)](LICENSE)
[![Release](https://img.shields.io/github/v/release/Rul1an/llm-cost)](https://github.com/Rul1an/llm-cost/releases)

**Offline token counter and cost estimator for LLM Engineering.**

`llm-cost` is a statically linked CLI tool written in Zig. It replicates OpenAI's `tiktoken` logic with memory safety and offline capability. Designed for integration into CI/CD pipelines and infrastructure scripts.

## Features

- **Performance**: ~10 MB/s throughput on single core.
- **Offline-First**: No API keys, no telemetry, and **no network calls** during estimation. Only the Pricing DB update requires network (explicit command).
- **Portable**: Static binary distribution for Linux, macOS, and Windows.
- **Parity**: Validated against `tiktoken` using edge-case corpora (Unicode, Whitespace).
- **Control**: Enforce cost limits via pipe mode.
- **FinOps**: Export deterministic cost data (FOCUS 1.0) for Chargeback/Showback.
- **Governance**: Policy and budget enforcement for CI/CD (`llm-cost check`).

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

## Quick Start

### 1. Initialize

```bash
llm-cost init
```

This creates a `llm-cost.toml` manifest discovering your prompt files.

### 2. Configure (Example)

```toml
[defaults]
model = "gpt-4o-mini"
```

## GitHub Action

Integrate `llm-cost` into your CI workflow with zero configuration.

```yaml
steps:
  - uses: actions/checkout@v4
  - uses: Rul1an/llm-cost/.github/actions/llm-cost@v1
    with:
      budget: "10.00"          # Fail if total cost > $10.00
      fail-on-increase: true  # Fail if cost increases vs base branch
```

See [action.yml](action.yml) for all inputs (`manifest`, `github-token`, etc.).

```toml
[[prompts]]
path = "prompts/search.txt"
prompt_id = "search"
tags = { team = "prod" }
```

### 3. CI/CD Integration (GitHub Action)

Add `.github/workflows/llm-cost.yml` to enforce budgets in PRs.

```yaml
name: LLM Cost Check
on: [pull_request]

permissions:
  contents: read
  pull-requests: write # Required for sticky comments

jobs:
  cost:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0 # Required for git history baseline

      # Pin to major version (auto-updates to latest v1.x.x)
      - uses: Rul1an/llm-cost/.github/actions/llm-cost@v1
        with:
          budget: "10.00"
          fail-on-increase: "true"
```

**Security Tip**: For high-security pipelines, pin to the exact commit SHA:
```yaml
- uses: Rul1an/llm-cost/.github/actions/llm-cost@a1b2c3d4... # SHA of v1.1.2
```

See [docs/guides/github-action.md](docs/guides/github-action.md) for full options.

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

**Analyze Corpus (Compression & Costs)**
```bash
llm-cost report --model gpt-4o --json my_corpus.txt
# Output: {"stats":{...}, "metrics":{"bytes_per_token":4.2, "tokens_per_word":1.3}}
```

**Analyze Differences (Git)**
```bash
# Compare cost of local changes vs main branch
llm-cost diff --base main --format markdown
```

**Pipeline Integration**
```bash
# Fail if cost exceeds $1.00
cat logs.jsonl | llm-cost pipe --model gpt-4o --max-cost 1.00

# CI/CD Governance (Check inputs against llm-cost.toml)
llm-cost check prompts/*.txt
```

**Maintenance**
```bash
# Update pricing database securely
llm-cost update-db
```

**FinOps Cost Export**
```bash
# Generate deterministic FOCUS v1.0 CSV for Vantage
llm-cost export --manifest llm-cost.toml > costs.csv
```

## Documentation

Project documentation follows the [Diátaxis](https://diataxis.fr/) structure.

| Type | Content |
|------|---------|
| **Guides** | [GitHub Action](docs/guides/github-action.md), [CI Integration](docs/guides/ci-integration.md), [Release Verification](docs/guides/verification.md) |
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
- **Secure Boot**: Pricing database verified at runtime via Ed25519 Minisign signatures.
- **Artifacts**: Signed with Cosign (Keyless via OIDC).
- **SBOM**: CycloneDX format provided.
- **Reproducibility**: Deterministic builds.

See [docs/guides/verification.md](docs/guides/verification.md) for verification steps.

## License

MIT © [Rul1an](https://github.com/Rul1an)
