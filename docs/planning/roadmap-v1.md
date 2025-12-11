# Roadmap to v1.0: The "Infracost for LLMs"
**Vision**: To be the industry standard *static analysis* tool for LLM cost estimation in CI/CD.
**Target Date**: Q1 2026
**Status**: DRAFT (Dec 2025)

## Strategic Pivot
In late 2025, the industry shifted from "just counting tokens" to **FinOps & Governance**.
*   **Rejected**: Heavy "Agentic" integration (MCP) — deemed out of scope.
*   **Adopted**: "Infrastructure as Code" philosophy. If Terraform/Infracost manages cloud spend, `llm-cost` manages AI spend.

---

## Phase 2: Cost Intelligence (Realism)
*Goal: Model the complex 2025 pricing landscape accurately.*

### 2.1 Pricing Realism (The "Price War" Features)
Providers now compete on complex dimensions beyond simple token counts.
*   **Context Caching Support**:
    *   Simulate caching benefits (e.g., Anthropic's 5m TTL, OpenAI's prefix matching).
    *   Flags: `--cache-read`, `--cache-write`, `--cache-hit-ratio=0.8`.
*   **Multi-modal Units**:
    *   Support non-text inputs.
    *   Flags: `--image <path> --detail high`, `--audio <path>`.
    *   Logic: `170px * tiles` (Vision), `0.06/min` (Audio).

### 2.2 Dynamic Pricing DB
*   **Problem**: Hardcoded pricing (in binary) is brittle given weekly price changes.
*   **Solution**: `llm-cost update-db`. Fetches signed JSON pricing definition from a hosted upstream (or local path) without recompiling.

---

## Phase 3: Governance & GitOps (Control)
*Goal: Enforce policy in the pipeline (The "Infracost" moment).*

### 3.1 Policy Engine (`check`)
*   **Feature**: Fail builds if costs exceed thresholds.
*   **Usage**: `llm-cost check --budget 5.00 --currency USD --file corpus.json`
*   **Output**: Exit code 1 if budget exceeded.

### 3.2 GitOps Diff (`diff`)
*   **Feature**: Compare cost between two git branches/commits.
*   **Usage**: `llm-cost diff --base main --head feat/new-prompts`
*   **Output**: Markdown table suitable for PR comments ("⚠️ Cost increased by +$120/mo").

### 3.3 FOCUS Spec Alignment
*   **Feature**: Align with **FinOps Open Cost & Usage Specification (FOCUS)**.
*   **Tags**: Support allocation tagging (`--tag app=search --tag team=platform`).
*   **Output**: Export to FOCUS-compatible CSV/JSON for ingestion into Cloud Cost dashboards.

---

## Phase 4: Polish & Ecosystem (Reach)
*Goal: Frictionless adoption.*

### 4.1 WASM / Edge
*   **Feature**: Compile core engine to WebAssembly.
*   **Use Case**: Client-side estimation in playgrounds, React apps, Cloudflare Workers.

### 4.2 Standard Output Formats
*   **Validation**: Formal schema for all JSON outputs.
*   **Integration**: Official GitHub Action (`uses: rul1an/llm-cost-action@v1`).

---

## Summary Timeline
| Phase | Focus | Key Features | SOTA Alignment |
|---|---|---|---|
| **P2** | Realism | Caching, Multi-modal, Update-DB | OpenAI/Anthropic 2025 Pricing |
| **P3** | Control | Check, Diff, Start Policies | FinOps / GitOps Trends |
| **P4** | Reach | WASM, Actions, V1.0 Release | Ecosystem Maturity |
