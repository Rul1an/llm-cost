# GitHub Action Guide

This guide explains how to use the `llm-cost` GitHub Action to enforce budgets and track AI spending in your Pull Requests.

## Quick Start

### 1. Initialize your project

Run this locally to generate a manifest:

```bash
llm-cost init
```

### 2. Configure `llm-cost.toml`

Ensure your manifest covers the prompts you want to track:

```toml
[defaults]
model = "gpt-4o-mini"

[[prompts]]
path = "prompts/search.txt"
prompt_id = "search"
tags = { team = "finops", env = "prod" }
```

### 3. Add Workflow

Create `.github/workflows/llm-cost.yml`:

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
          fetch-depth: 0  # Required for git history baseline

      - uses: llm-cost/action@v1
        with:
          budget: "10.00"
```

## Options Reference

```yaml
- uses: llm-cost/action@v1
  with:
    # Path to manifest (default: llm-cost.toml)
    manifest: "llm-cost.toml"

    # Fail if total cost > budget (USD)
    budget: "10.00"

    # Fail if cost increases compared to base branch
    fail-on-increase: "true"

    # Comment behavior: auto | true | false
    # auto: Skips comments on fork PRs (safe)
    post-comment: "auto"

    # Minimum absolute delta (USD) to trigger a comment
    comment-threshold: "0.01"
```

## Security & Privacy

### Offline-First
`llm-cost` estimates costs **offline**. It uses an embedded pricing database and a local tokenizer. No prompt content is ever sent to an external API during estimation.

### Supply Chain Security
The action downloads a pre-compiled binary release.
*   **Verification**: All downloads are verified against a SHA256 checksum.
*   **Strong Pinning**: You can strictly pin the binary hash:
    ```yaml
    with:
      version: "v1.1.0"
      sha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    ```

### Permissions
*   `contents: read`: To read the prompt files.
*   `pull-requests: write`: To post/update the sticky PR comment. If disabled, set `post-comment: false`.

## Maintainers: Release Assets

This action expects release assets with the following naming convention:
*   `llm-cost-linux-x86_64`
*   `llm-cost-linux-arm64`
*   `llm-cost-darwin-x86_64`
*   `llm-cost-darwin-arm64`
*   `checksums.txt` (Format: `<sha256>  <filename>`)
