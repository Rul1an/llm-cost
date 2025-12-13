# llm-cost

Static cost analysis for LLM workloads. Estimate spend, enforce budgets, diff costs in CI/CD.

[![CI](https://github.com/Rul1an/llm-cost/actions/workflows/ci.yml/badge.svg)](https://github.com/Rul1an/llm-cost/actions/workflows/ci.yml) [![Release](https://img.shields.io/github/v/release/Rul1an/llm-cost)](https://github.com/Rul1an/llm-cost/releases) [![License](https://img.shields.io/github/license/Rul1an/llm-cost)](LICENSE)

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
```bash
curl -sSfL https://get.llm-cost.dev | sh
```

Or download from [Releases](../../releases).

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

## FinOps Export

Export FOCUS 1.0 CSV for Vantage, CloudZero, or any FOCUS-compliant tool:
```bash
llm-cost export --format focus -o costs.csv
```

Filter and group by `Tags.team`, `Tags.app`, or `Tags.model` in your FinOps dashboard.

## Commands

| Command | Purpose |
|---------|---------|
| `estimate` | Cost estimate for prompt files |
| `count` | Token count only |
| `check` | Budget/policy enforcement |
| `diff` | Cost comparison between git refs |
| `export` | FOCUS CSV for FinOps tools |
| `pipe` | Stream JSON usage → cost output |
| `update-db` | Refresh pricing database |

## How It Works

- **Offline**: No API keys, no telemetry. Network only for explicit `update-db`.
- **Exact**: BPE tokenizer with tiktoken parity (o200k_base, cl100k_base).
- **Signed**: Pricing updates verified via Ed25519/minisign.
- **Fast**: ~10 MB/s throughput, O(N) complexity.

## Security

- SLSA Level 2 build provenance
- Artifact attestations via Sigstore
- Minisign-verified pricing database
- Zero runtime network calls

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
