# llm-cost: From CI Tool to FinOps Platform

`llm-cost` is designed with a unique "Dual Use" architecture. It serves two distinct personas using the exact same binary, ensuring that developers and finance teams look at the same data.

## 1. The Developer's View: "A Small, Fast CI Tool"

For the individual developer or CI pipeline, `llm-cost` acts like a linter. It is small, stateless, and incredibly fast.

### Key Characteristics
*   **Single Binary**: No Python envs, no Node modules. Just `curl` and run.
*   **Zero Latency**: Pricing data works offline: embedded snapshot in the binary, with optional `update-db` for current prices.
*   **Privacy First**: Prompts are tokenized locally. No data ever leaves the CI runner.

### Use Cases
*   **Pre-commit Hook**: Block commits that exceed a token budget ($1.00).
    ```bash
    llm-cost check --budget 1.00
    ```
*   **CI Gate**: Automatic diffs in Pull Requests.
    ```bash
    llm-cost diff --base main >> pr_comment.txt
    ```

## 2. The Enterprise View: "A Centralized FinOps Platform"

For the organization, `llm-cost` becomes a comprehensive FinOps platform by connecting to a centralized control plane.

### Key Characteristics
*   **Unified Truth**: All developers sync pricing from *your* private API, ensuring custom negotiated rates are applied everywhere.
*   **Drift Analysis**: Compare estimates against actual bills to find "Shadow AI" — LLM usage that bypasses approved prompts or models.
*   **Governance**: Enforce policies globally. If checking against a centrally managed `manifest.json`, you control the models and prices allowed.

### Use Cases
*   **Access Control**: Only licensed ("Pro") users get the latest rates or enterprise bundles.
*   **Reporting**: Export usage data to tools like Vantage, CloudZero, or Tableau.
    ```bash
    llm-cost export --format focus > finops_dashboard.csv
    ```
*   **Quality-Cost Tradeoff**: The `analytics` module tracks token efficiency so cost cuts don't silently degrade output quality.

## Why One Tool for Both?

Traditional FinOps creates a gap between "what developers see" (ad-hoc calculators) and "what finance reports" (billing dashboards). `llm-cost` closes this gap:

| Problem | Traditional | llm-cost |
|---------|-------------|----------|
| "My estimate was $5, bill was $50" | Shrug | Calibrate & fix |
| "Which team caused the spike?" | Manual forensics | `prompt_id` tracking |
| "Are we using approved models?" | Honor system | Policy enforcement |
| "What will this PR cost?" | Unknown until bill | `llm-cost diff` |

Same binary. Same math. Same data. Developer and FinOps aligned.

## How They Connect

```mermaid
graph TD
    subgraph Developer Workflow
        P[Prompt Files] -->|llm-cost estimate| G[Gate Pass/Fail]
        L[Local/Embedded Pricing DB] -.->|Read| P
    end

    subgraph Enterprise Workflow
        M[Multiple Repos] -->|llm-cost estimate| F[FOCUS Export]
        F --> V[Vantage / CloudZero]

        API[Enterprise API (Custom Rates)] -->|Internal Net| L
        API -->|Calibration Loop| C[Compare Estimates vs Actuals]
    end
```

The `manifest.json` is the bridge:
1.  **OSS/Public**: Developers pull from the public `cdn.llm-cost.dev`.
2.  **Enterprise**: You deploy your own `llm-cost-api` (or use ours).

### Self-Hosted Deployment
For enterprises that need full control:
1.  Fork the Worker code.
2.  Add your custom pricing to R2.
3.  Sign with your own Ed25519 key.
4.  Configure CLI: `export LLM_COST_ENDPOINT=https://internal.corp/v1/pricing/manifest.json`.

Your CI runners now configure:
```bash
export LLM_COST_ENDPOINT="https://internal.corp/v1/pricing/manifest.json"
export LLM_COST_LICENSE="ent_..."
```
Now, every `llm-cost estimate` run by any developer instantly reflects your organization's custom pricing, forbidden models, and audit requirements.
