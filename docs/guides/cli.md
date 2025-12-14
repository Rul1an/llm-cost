# CLI Reference

`llm-cost` is a statically linked binary for offline cost analysis.


## Installation

```bash
curl -sSfL https://get.llm-cost.dev | sh
```

Or download binaries from [Releases](https://github.com/Rul1an/llm-cost/releases).

## Global Options

| Option | Description |
|--------|-------------|
| `--help`, `-h` | Show help message |
| `--version` | Show version info |

## Commands

### estimate (or price)

Calculate cost for prompts. Supports files or stdin.

```bash
llm-cost estimate [OPTIONS] [FILES...]
```

**Options**

| Option | Description |
|--------|-------------|
| `--model`, `-m` | Model ID (default: `gpt-4o`). See `models` command. |
| `--input-tokens` | Manually specify input token count (overrides counting). |
| `--output-tokens` | Manually specify output token count (default: 0). |
| `--reasoning-tokens` | Manually specify reasoning token count (default: 0). |
| `--manifest` | Path to `llm-cost.toml`. If no files provided, scans prompts in manifest. |
| `--format=json` | Output machine-readable JSON (with detailed breakdown). |

**Examples**

```bash
# Estimate single file
llm-cost estimate prompt.txt

# Estimate from stdin with specific model
echo "Hello" | llm-cost estimate --model gpt-3.5-turbo

# JSON output for all prompts in a manifest (Manifest Scan)
llm-cost estimate --manifest llm-cost.toml --format=json
```

---

### calibrate
Validate and compare estimates against actual billing data (FOCUS CSV).

```bash
llm-cost calibrate [OPTIONS]
```

**Options**

| Option | Description |
|--------|-------------|
| `--estimates` | **Required**. Path to JSON estimates file (from `export`). |
| `--actuals` | **Required**. Path to FOCUS CSV billing data. |
| `--match` | Matching mode: `strict` (default) or `fuzzy`. |
| `--validate-only` | Run validation checks without generating factors. |

**Examples**

```bash
# Standard calibration
llm-cost calibrate --estimates est.json --actuals bill.csv > factors.toml

# Validation check (CI/CD)
llm-cost calibrate --estimates est.json --actuals bill.csv --validate-only
```

---

### check

Validate budget and policy compliance. Returns exit code 0 (Pass), 2 (Budget Exceeded), or 3 (Policy Violation).

```bash
llm-cost check [OPTIONS] [FILES...]
```

**Options**

| Option | Description |
|--------|-------------|
| `--model`, `-m` | Override model for CLI input files. |

**Behavior**
1. Loads `llm-cost.toml` (if present).
2. Checks `allowed_models` policy against all prompts.
3. Checks `max_cost_usd` budget against total cost.

**Examples**

```bash
# Check all prompts defined in llm-cost.toml
llm-cost check

# Check explicit files (ad-hoc)
llm-cost check --model gpt-4o new_prompt.txt
```

---

### diff

Compare costs between two git references or file states.

```bash
llm-cost diff --base <REF> [OPTIONS]
```

**Options**

| Option | Description |
|--------|-------------|
| `--base` | **Required**. Git reference (sha/branch) for baseline. |
| `--head` | Git reference for comparison. Default: Current filesystem (Working Directory). |
| `--manifest` | Path to manifest (default: `llm-cost.toml`). |
| `--format` | Output format: `table` (default), `json`, or `markdown`. |

**Examples**

```bash
# Compare working directory vs main branch
llm-cost diff --base main

# Generate Markdown report for PR (CI usage)
llm-cost diff --base origin/main --format markdown
```

---

### export

Export cost forecast to FinOps formats (FOCUS).

```bash
llm-cost export [OPTIONS]
```

**Options**

| Option | Description |
|--------|-------------|
| `--output`, `-o` | Output file path (default: stdout). |
| `--format` | Export format (currently only `focus` implied). |
| `--manifest` | Path to manifest (default: `llm-cost.toml`). |
| `--cache-hit-ratio` | Apply estimated cache savings (0.0 - 1.0). |
| `--test-date` | Override BillingPeriodStart (ISO 8601). |

**Examples**

```bash
# Generate CSV for Vantage/CloudZero
llm-cost export -o costs.csv

# Export with 50% cache hit assumption
llm-cost export --cache-hit-ratio 0.5
```

---

### init

Initialize a new project. Scans directory for text files and generates `llm-cost.toml`.

```bash
llm-cost init [DIR]
```

---

### ci-action

Specialized command for GitHub Actions integration. Runs check, diff, and sticky comment logic.

```bash
llm-cost ci-action --github-token <TOKEN> --event-path <PATH> [OPTIONS]
```

**Options**

| Option | Description |
|--------|-------------|
| `--github-token` | **Required**. `secrets.GITHUB_TOKEN`. |
| `--event-path` | **Required**. `$GITHUB_EVENT_PATH`. |
| `--budget` | Fail if total cost exceeds this USD amount. |
| `--fail-on-increase` | Fail if cost increased vs base ref. |
| `--comment-threshold` | Only post comment if delta $ > threshold. |
| `--post-comment` | Enable PR commenting (default: true). |
| `--no-comment` | Disable PR commenting. |
| `--base` | Base ref for diff (e.g., `origin/main`). |

---

### models

List supported models and pricing.

```bash
llm-cost models [--json]
```

---

### tokens (or count)

Count tokens using the exact BPE tokenizer (tiktoken compatible).

```bash
llm-cost tokens --model <ID> [FILE]
```

---

### update-db

Update the local pricing database from the upstream signed source.
Verifies Ed25519 signature before applying.

```bash
llm-cost update-db
```
