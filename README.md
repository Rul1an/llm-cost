# llm-cost

Static cost analysis for LLM workloads. Estimate spend, enforce budgets, diff costs in CI/CD.

[![CI](https://github.com/Rul1an/llm-cost/actions/workflows/ci.yml/badge.svg)](https://github.com/Rul1an/llm-cost/actions/workflows/ci.yml) [![Release](https://img.shields.io/github/v/release/Rul1an/llm-cost)](https://github.com/Rul1an/llm-cost/releases) [![License](https://img.shields.io/github/license/Rul1an/llm-cost)](LICENSE) [![Website](https://img.shields.io/website?url=https%3A%2F%2Fllm-cost.dev&up_message=online&down_message=offline&label=llm-cost.dev)](https://llm-cost.dev/)


## 30 Seconds to Value
```bash
# No config needed
llm-cost estimate prompt.txt --model gpt-4o
```
```
prompt.txt
  Tokens: 1,847 input + 523 output (est.)
  Cost:   $0.0041 (gpt-4o)
```

## See Cache Impact
```bash
llm-cost estimate prompt.txt --model gpt-4o --scenario cached --cache-hit-ratio 0.6
```
```
Scenario    Cost      Savings
default     $0.0052   —
cached@60%  $0.0033   -37%
```

## Installation
### Linux & macOS
```bash
curl -sSfL https://get.llm-cost.dev | sh
```

### Windows
Windows is not currently supported via the install script.

**Options:**
1. **WSL2** (recommended): Use the Linux install method.
2. **Manual**: Download `llm-cost-windows-x86_64.exe` from [Releases](https://github.com/Rul1an/llm-cost/releases).

**CI/CD on Windows:**
```yaml
- name: Install llm-cost
  run: |
    Invoke-WebRequest -Uri "https://github.com/rul1an/llm-cost/releases/latest/download/llm-cost-windows-x86_64.exe" -OutFile "llm-cost.exe"
    .\llm-cost.exe --version
```


## CI/CD Integration

Add budget gates to your PR workflow:
```yaml
name: LLM Cost Check
on: [pull_request]

permissions:
  contents: read
  pull-requests: write

jobs:
  cost:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - uses: Rul1an/llm-cost@v1
        with:
          budget: "10.00"
          fail-on-increase: "true"
```

The action posts a sticky comment with cost breakdown and delta vs base branch.

For high-security pipelines, pin to SHA:
```yaml
- uses: Rul1an/llm-cost@74c902dcf4926ee1ff68d6dce70120db6dc3f26c
```

## Project Setup
```bash
llm-cost init                      # Generate manifest from prompt files
llm-cost check --budget 5.00       # Local budget enforcement
llm-cost diff --base main          # Compare costs vs branch
```

Example `llm-cost.toml`:
```toml
[defaults]
model = "gpt-4o"

[[prompts]]
path = "prompts/search.txt"
prompt_id = "search"
tags = { team = "platform", app = "search" }
```

## Calibration (Drift Analysis)

Close the loop by comparing your estimates against actual billing data (FOCUS v1.0 CSV). Detect "Shadow AI" (unapproved usage) and drift.

```bash
# 1. Generate estimates map
llm-cost export --format=json > estimates.json

# 2. Compare against actuals (with fuzzy matching)
llm-cost calibrate \
  --estimates estimates.json \
  --actuals billing-data.csv \
  --match fuzzy > factors.toml
```

Output `factors.toml` contains drift multipliers (e.g., `1.05` for +5% drift) and confidence scores.

## FinOps Export

Export FOCUS 1.0 CSV for Vantage, CloudZero, or any FOCUS-compliant tool:
```bash
llm-cost export --format focus -o costs.csv
```

Filter and group by `Tags.team`, `Tags.app`, or `Tags.model` in your FinOps dashboard.

## Commands

| Command | Purpose |
|---------|---------|
| `estimate` | Cost estimate for prompt files (alias: `price` is deprecated) |
| `count` | Token count only |
| `check` | Budget/policy enforcement |
| `diff` | Cost comparison between git refs |
| `calibrate` | Drift analysis vs actual billing data |
| `export` | FOCUS CSV for FinOps tools |
| `pipe` | Stream JSON usage → cost output |
| `update-db` | Refresh pricing database |

**Note**: Global flags (`--quiet`, `--verbose`) must precede the subcommand (e.g., `llm-cost --quiet calibrate`).

## How It Works

- **Offline**: No API keys, no telemetry. Network only for explicit `update-db`.
- **Exact**: BPE tokenizer with tiktoken parity (o200k_base, cl100k_base).
- **Signed**: Pricing updates verified via Ed25519/TUF-lite manifest system.
- **Fast**: ~10 MB/s throughput, O(N) complexity.

## Security

- SLSA Level 2 build provenance
- Artifact attestations via Sigstore
- Minisign-verified pricing database
- Zero runtime network calls

### Pricing Database
`src/core/pricing/pricing_db.json` contains standard rates.
> **Note**: For Anthropic prompt caching, we default to the **5-minute cache write** tier.

- **OpenAI**: Updated to 2025 rates (gpt-4o: $2.50/$10.00).
- **Anthropic**: Claude 3.5 Sonnet supports prompt caching rates.

## 🛡️ FinOps Certified (v1.3.0)

`llm-cost` is engineered for **Enterprise FinOps**. It goes beyond simple estimation to provide audit-grade validation.

- **P0/P1 Validation Suite**: Every commit is verified against a rigorous regression test suite covering determinism, schema integrity, and scale (1M+ rows).
- **Cost Integrity Reporting**: Automated "Cost Integrity Cards" in GitHub Pull Requests report drift (BPS), logic hashes, and PII leakage.
- **Fail-Fast Policy**: Strict exit codes (`2`) ensures no "garbage-in/garbage-out" in data pipelines.
- **FOCUS Compliant**: Native support for the FinOps Open Cost & Usage Specification (v1.0).

| Metric | Status |
| :--- | :--- |
| **Schema** | 🟢 PASS |
| **Logic** | 🟢 PASS |
| **Drift** | 🟢 PASS |

Verify releases:
```bash
gh attestation verify llm-cost-linux-amd64 --repo Rul1an/llm-cost
```

See [docs/VERIFICATION.md](https://github.com/Rul1an/llm-cost/blob/main/docs/VERIFICATION.md).

## Documentation

- [CLI Reference](https://github.com/Rul1an/llm-cost/blob/main/docs/guides/cli.md)
- [GitHub Action Guide](https://github.com/Rul1an/llm-cost/blob/main/docs/guides/github-action.md)
- [FOCUS Export](https://github.com/Rul1an/llm-cost/blob/main/docs/focus.md)
- [Security & Verification](https://github.com/Rul1an/llm-cost/blob/main/docs/VERIFICATION.md)

## License

MIT
