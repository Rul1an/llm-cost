# CI Integration Guide

`llm-cost` is designed to run in CI pipelines to enforce token budgets or cost guardrails.

## GitHub Actions Example

This workflow counts tokens in all `docs/` Markdown files and fails if the estimated cost of processing them with `gpt-4o` exceeds $0.50.

```yaml
name: Cost Guardrail

on: [push, pull_request]

jobs:
  check-cost:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install llm-cost
        run: |
          VERSION="v0.7.1"
          curl -LO "https://github.com/Rul1an/llm-cost/releases/download/${VERSION}/llm-cost-linux-x86_64"
          chmod +x llm-cost-linux-x86_64
          mv llm-cost-linux-x86_64 /usr/local/bin/llm-cost

      - name: Check Budget
        run: |
          # Count all tokens in docs and pipe to estimate
          cat docs/*.md | llm-cost count -m gpt-4o | \
          llm-cost estimate -m gpt-4o --pipe | \
          llm-cost check --max-cost 0.50
          # Note: 'check' command is planned for v0.8. For now use pipe limits:

          cat docs/*.md | llm-cost pipe -m gpt-4o --max-cost 0.50 --raw --fail-fast
```

## GitLab CI Example

```yaml
cost_check:
  image: alpine:latest
  script:
    - wget https://github.com/Rul1an/llm-cost/releases/download/v0.7.1/llm-cost-linux-static -O /bin/llm-cost
    - chmod +x /bin/llm-cost
    - cat data.jsonl | llm-cost pipe -m gpt-4o --max-cost 5.00
```
