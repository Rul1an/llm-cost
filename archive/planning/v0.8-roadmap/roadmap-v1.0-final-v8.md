# Roadmap to v1.0: The "Infracost for LLMs"

**Vision**: The industry standard static analysis tool for LLM cost estimation in CI/CD.
**Target Date**: Q2 2026
**Status**: DRAFT v8 (Dec 2025) - "The Defensive UX Edition"

---

## Strategic Position

The industry shifted from "token counting" to **FinOps & Governance**.

**Adopted:**
- "Infrastructure as Code" philosophy — Infracost for cloud, `llm-cost` for AI
- Calibration loop — static analysis informed by empirical data
- FOCUS as lingua franca — the bridge between estimates and actuals
- Offline-first — no telemetry, no phone-home, enterprise-grade privacy
- **Defensive UX** — Fail open, warn first, zero-friction adoption

**Rejected:**
- Agentic integration (MCP) — out of scope
- Image/audio file decoding — security risk, binary bloat
- Provider-specific billing parsers — SaaS territory
- Telemetry / usage tracking — violates offline-first contract

**Deferred:**
- WASM distribution — Zig target immature

**Core Principle**: Offline-first, secure-by-default, obvious at 23:00 in CI.

---

## Critical Path

```
v0.7 Pricing DB ──┬──► v0.9 Check ──► v0.10 Diff ──► v1.0 ──► v1.1
                  │                                   │        │
v0.8 Manifest ────┘                                   │        │
     + prompt_id                                      │        │
                                                      ▼        ▼
                                               FOCUS export   Calibrate
                                                              + FOCUS import
```

---

## Attribution Model

### Ownership vs Causation

| Type | When | Question | Tool |
|------|------|----------|------|
| **Ownership** | Build-time | "Who owns this prompt?" | `llm-cost` |
| **Causation** | Runtime | "Which customer triggered this?" | Observability |

### The `prompt_id` Contract

**Identity and change detection are separate concerns:**

**Heuristic Fallback (v8 Change)**:
If no explicit `prompt_id` is defined, `llm-cost` defaults to the **normalized file path** (e.g., `src/prompts/search.txt` -> `search`).
Explicit IDs in `llm-cost.toml` are optional, for stability across renames.

| Concern | Field | Mutability | Purpose |
|---------|-------|------------|---------|
| **Identity** | `prompt_id` | User-defined OR Filepath | Cost tracking key, FOCUS ResourceId |
| **Change detection** | `content_hash` | Auto-computed, internal | Diff output, cache invalidation |

### The Feedback Loop

```
┌─────────────────────────────────────────────────────────────────┐
│  llm-cost (static)              │  Runtime (dynamic)            │
├─────────────────────────────────┼───────────────────────────────┤
│                                 │                               │
│  estimate ──► FOCUS export ─────┼──► FinOps dashboard           │
│                                 │         ▲                     │
│                                 │         │                     │
│  calibrate ◄── FOCUS import ◄───┼─── actuals (FOCUS format)     │
│      │                          │                               │
│      ▼                          │                               │
│  tuned parameters ──► better estimates next cycle               │
│                                 │                               │
└─────────────────────────────────────────────────────────────────┘
```

---

## Phase 2: Foundation

### 2.1 Dynamic Pricing Database (v0.7)

Signed, verifiable pricing updates without recompilation.

**Security Model:**

| Aspect | Decision |
|--------|----------|
| Signing | minisign (Ed25519) |
| Key pinning | In binary, rotate via release |
| Update frequency | Weekly |

**CI/CD "Fail Open" Policy (v8 Change):**

To prevent "Timebomb" scenarios in CI:

| Condition | Local (Interactive) | CI (`CI=true` / `GITHUB_ACTIONS=true`) |
|-----------|---------------------|---------------------------------------|
| Stale (< 30 days) | Warning | Warning |
| **Critical (> 30 days)** | **Error (exit 4)** | **Warning** (Fail Open) |
| `--strict` | Error | Error |

*"We break builds on code correctness, not data freshness, unless you ask us to."*

### 2.2 Project Manifest (v0.8)

TOML manifest.
**Zero-Config First:** `llm-cost estimate` works immediately without `init`.

**Magic Init Flow:**

```bash
$ llm-cost init

Found 4 prompt files.
Generating heuristics...

✓ Created llm-cost.toml
  - mapped 'prompts/search.txt' -> id: 'search'
  - mapped 'prompts/summary.txt' -> id: 'summary'

Review mapping in llm-cost.toml when ready.
```

### 2.3 Scenarios (v0.8)

Named scenarios. No default cache hit ratio.
...

---

## Phase 3: Governance

### 3.1 Budget Check (v0.9)

```bash
llm-cost check
```

**Tag Cardinality Warning:**
Warn if any tag key has >100 unique values across prompts.

### 3.2 GitOps Diff (v0.10)

Stateless. Always requires `--base`.

### 3.3 GitHub Action (v0.10)

...

---

## Phase 4: Release (v1.0)

### 4.1 FOCUS Export

**Status**: Schema validated ✓ (Dec 2025)

**Defensive Export Options (v8 Change):**

To address "Invisible Costs" in legacy FinOps tools:

1.  **Default Behavior**: `BilledCost = 0.00`, `EffectiveCost = Estimate`. (FOCUS Correct)
2.  **Legacy Escape Hatch**: `--hack-billed-cost`.
    *   Sets `BilledCost = Estimate`.
    *   Adds tag `x-hack-billed-cost: true`.
    *   *For tools that hard-filter 0-cost rows.*

**Validated Output Format:**

```csv
BilledCost,EffectiveCost,ListCost,UsageQuantity,UsageUnit,ResourceId,ResourceName,ServiceName,ServiceCategory,Provider,ChargeCategory,Tags,...
0.00,0.0041,0.0052,2370,Tokens,search,prompts/search.txt,LLM Inference,AI and Machine Learning,OpenAI,Usage,"{""llm-cost-type"":""estimate""}",...
```

### 4.2 BilledCost=0 Documentation

**Required in user documentation:**
(See v7 content - maintained)

### 4.3 x-* Column Documentation

**Required in user documentation:**
(See v7 content - maintained)

---

## Phase 5: Calibration (v1.1)

### 5.1 The Drift Problem
...

### 5.2 `calibrate` Command
...

---

## Timeline

| Version | Deliverables | Target |
|---------|--------------|--------|
| **v0.7** | Pricing DB + **CI Staleness Logic** | Feb 2026 |
| **v0.8** | TOML Manifest, **Heuristic Init**, Scenarios | Mar 2026 |
| **v0.9** | Check command (incl. tag cardinality warning) | Apr 2026 |
| **v0.10** | Diff, GitHub Action | May 2026 |
| **v1.0** | FOCUS export (**incl. legacy flag**), Schema, Docs | Jun 2026 |
| **v1.1** | Calibrate, FOCUS import | Aug 2026 |

**Go/No-Go Gates (Updated):**
- v0.7 → v0.8: Security review complete AND **CI "Timebomb" test passed**
- v0.9 → v0.10: Check in own CI for 2 weeks AND **Dogfooding session with external team**
- v0.10 → v1.0: FOCUS export validated with Vantage ✓
- v1.0 → v1.1: User interviews complete

---

## Design Decisions (Updated)

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Config format | TOML | YAML footguns |
| `prompt_id` | **Heuristic default**, opt-in config | Zero friction for casual users |
| CI Staleness | **Fail Open** (Warning) | Don't break builds on auxiliary data errors |
| BilledCost | 0.00 (Default), **--hack flag (Legacy)** | Compliance + Pragmatism |
| FOCUS Region | Omitted | LLM APIs global |
| Telemetry | None | Offline-first hard contract |

---

## Validation Status

| Artifact | Status | Date |
|----------|--------|------|
| FOCUS schema compliance | ✓ Validated | Dec 2025 |
| **CI Failure Logic** | **Pending Design** | **Jan 2026** |
| Vantage import | Pending | — |
