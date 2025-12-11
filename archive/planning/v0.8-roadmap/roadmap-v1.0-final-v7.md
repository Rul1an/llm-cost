# Roadmap to v1.0: The "Infracost for LLMs"

**Vision**: The industry standard static analysis tool for LLM cost estimation in CI/CD.
**Target Date**: Q2 2026
**Status**: FINAL v7 (Dec 2025)

---

## Strategic Position

The industry shifted from "token counting" to **FinOps & Governance**.

**Adopted:**
- "Infrastructure as Code" philosophy — Infracost for cloud, `llm-cost` for AI
- Calibration loop — static analysis informed by empirical data
- FOCUS as lingua franca — the bridge between estimates and actuals
- Offline-first — no telemetry, no phone-home, enterprise-grade privacy

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

| Concern | Field | Mutability | Purpose |
|---------|-------|------------|---------|
| **Identity** | `prompt_id` | User-defined, never auto-mutate | Cost tracking key, FOCUS ResourceId |
| **Change detection** | `content_hash` | Auto-computed, internal | Diff output, cache invalidation |

**Format**: User-defined stable identifier (e.g., `search`, `api-summarize`)

**Properties:**
- Stable across file renames AND content edits
- User-defined during `init`, never auto-mutated
- Unique within project
- Human-readable

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

```bash
$ llm-cost update-db

Fetching from https://prices.llm-cost.dev/v1/prices.json...
✓ Signature verified (minisign)
✓ Updated 47 models (12 price changes detected)

Notable changes:
  gpt-4-turbo  $10.00 → $8.00/M tokens (-20%)
  claude-3     $15.00 → $12.00/M tokens (-20%)
```

**Security Model:**

| Aspect | Decision |
|--------|----------|
| Signing | minisign (Ed25519) |
| Key pinning | In binary, rotate via release |
| Key rotation | 90-day dual-key overlap (planned) |
| Emergency rotation | Immediate (see procedures) |
| Provenance | Official pricing pages, manually verified |
| Update frequency | Weekly |

**`valid_until` Behavior:**

| Condition | Behavior |
|-----------|----------|
| Current date < `valid_until` | Normal operation |
| Current date > `valid_until` | Warning: "Pricing data expired. Run: llm-cost update-db" |
| Current date > `valid_until` + 30 days | Error (exit 4): "Pricing data too old. Update required." |
| `--force-stale` flag | Bypass expiry check (for airgapped environments) |

**Provider Coverage at Launch (v0.7):**

| Provider | Priority |
|----------|----------|
| OpenAI | P0 (launch) |
| Anthropic | P0 (launch) |
| Google | P0 (launch) |
| Azure OpenAI | P1 (v0.7.1) |
| AWS Bedrock | P1 (v0.7.1) |

### 2.2 Project Manifest (v0.8)

TOML manifest with `prompt_id` as first-class citizen.

**Init Flow:**

```bash
$ llm-cost init

? Where are your prompts located? [./prompts/**/*.txt]
  Found 4 prompt files.

? Assign stable IDs for cost tracking.
  
  prompts/search.txt
  ? Prompt ID: [search] █

✓ Created llm-cost.toml
```

**Manifest:**
```toml
version = 1

[[prompts]]
path = "./prompts/search.txt"
prompt_id = "search"

[defaults]
model = "gpt-4o"

[budget]
limit = 10.00
currency = "USD"

[tags]
team = "platform"
app = "search"
```

### 2.3 Scenarios (v0.8)

Named scenarios. No default cache hit ratio.

```bash
llm-cost estimate prompt.txt --scenario cached --cache-hit-ratio 0.6
```

| Scenario | Required Params |
|----------|-----------------|
| `default` | None |
| `cached` | `--cache-hit-ratio` (no default) |
| `batch` | None |

---

## Phase 3: Governance

### 3.1 Budget Check (v0.9)

```bash
llm-cost check
```

**Exit Codes:**

| Code | Name |
|------|------|
| 0 | `OK` |
| 1 | `BUDGET_EXCEEDED` |
| 2 | `CONFIG_ERROR` |
| 3 | `PARSE_ERROR` |
| 4 | `PRICING_ERROR` |

**Output:**
```
❌ Budget exceeded: $7.23 > $5.00 (limit)

Breakdown:
  search           $4.10  (82%) ← largest
  summarize        $2.80
  classify         $0.33

Exit code: 1 (BUDGET_EXCEEDED)
```

**Tag Cardinality Warning (NEW):**

High-cardinality tags cause performance issues in FinOps tools. Add validation:

```
$ llm-cost check

⚠️  Warning: Tag 'request_id' has high cardinality (>1000 unique values).
    This may cause performance issues in FinOps tools.
    Consider moving to x-request-id extension column.
```

**Implementation:**
- Warn if any tag key has >100 unique values across prompts
- Suggest moving to `x-*` extension column
- Non-blocking (warning only)

### 3.2 GitOps Diff (v0.10)

Stateless. Always requires `--base`.

```bash
llm-cost diff --base main --head HEAD
```

```
📊 Cost Comparison: main → feat/new-prompts

| prompt_id   | Content   | Base    | Head    | Δ Cost     |
|-------------|-----------|---------|---------|------------|
| search      | modified  | $3.60   | $4.10   | +$0.50 ⚠️  |
| summarize   | unchanged | $2.80   | $2.80   | —          |

Total: $6.40 → $6.90 (+8%)
```

### 3.3 GitHub Action (v0.10)

```yaml
- uses: rul1an/llm-cost-action@v1
  with:
    budget: 10.00
    comment: true
    fail-on-increase: 25%
```

---

## Phase 4: Release (v1.0)

### 4.1 FOCUS Export

**Status**: Schema validated ✓ (Dec 2025)

```bash
llm-cost estimate --format focus > estimates.focus.csv
```

**Validated Output Format:**

```csv
BilledCost,EffectiveCost,ListCost,UsageQuantity,UsageUnit,ResourceId,ResourceName,ServiceName,ServiceCategory,Provider,ChargeCategory,Tags,x-token-count-input,x-token-count-output,x-cache-hit-ratio,x-content-hash
0.00,0.0041,0.0052,2370,Tokens,search,prompts/search.txt,LLM Inference,AI and Machine Learning,OpenAI,Usage,"{""llm-cost-type"":""estimate"",""model"":""gpt-4o"",""scenario"":""cached"",""team"":""platform"",""app"":""search""}",1847,523,0.60,a1b2c3
```

**Field Mapping (FOCUS 1.0 Validated):**

| FOCUS Field | Source | Notes |
|-------------|--------|-------|
| `BilledCost` | Always `0.00` | Estimates have no billed cost yet |
| `EffectiveCost` | Calculated estimate | Primary cost value |
| `ListCost` | Pre-discount estimate | May differ for batch scenarios |
| `ResourceId` | `prompt_id` | User-defined, stable |
| `ResourceName` | File path | Human readability |
| `Provider` | Model Registry | "OpenAI", "Anthropic" (case-sensitive) |
| `ServiceName` | Fixed | "LLM Inference" |
| `ServiceCategory` | Fixed | "AI and Machine Learning" |
| `Region` | **Omitted** | LLM APIs are global; FOCUS allows nullable |
| `ChargeCategory` | Fixed | "Usage" |
| `Tags` | Critical metadata | JSON object |

**Tags Structure:**
```json
{
  "llm-cost-type": "estimate",
  "model": "gpt-4o",
  "scenario": "cached",
  "team": "platform",
  "app": "search"
}
```

**Extension Columns (x-*):**

| Column | Purpose | Nullable |
|--------|---------|----------|
| `x-token-count-input` | Input tokens | No |
| `x-token-count-output` | Output tokens | No |
| `x-cache-hit-ratio` | Cache performance | Yes |
| `x-content-hash` | Change detection | No |

### 4.2 BilledCost=0 Documentation (NEW)

**Required in user documentation:**

> **Understanding FOCUS Export for Estimates**
>
> llm-cost exports estimates with `BilledCost=0.00` and the estimate value in `EffectiveCost`. 
> This follows FOCUS spec semantics: BilledCost represents actual charges, which don't exist for predictions.
>
> **FinOps Tool Configuration:**
>
> Some tools filter zero-cost rows by default. To see llm-cost estimates:
>
> | Tool | Configuration |
> |------|---------------|
> | Vantage | Adjust cost filter to include $0 rows |
> | CloudZero | Filter by `llm-cost-type=estimate` tag |
> | Datadog | Use `EffectiveCost` instead of `BilledCost` for grouping |
>
> **Distinguishing Estimates from Actuals:**
>
> Use the `llm-cost-type` tag:
> - `"llm-cost-type": "estimate"` — Predicted cost from static analysis
> - `"llm-cost-type": "actual"` — Real cost from runtime (when calibrating)

### 4.3 x-* Column Documentation (NEW)

**Required in user documentation:**

> **Extension Columns (x-*)**
>
> Extension columns (`x-token-count-input`, `x-cache-hit-ratio`, etc.) contain detail data 
> for debugging and analysis. Per FOCUS spec, these are "best effort":
>
> - ✓ Preserved in FOCUS-native tools (Vantage, CloudZero)
> - ⚠️ May be stripped in generic CSV processors
> - ⚠️ May be ignored in non-FOCUS FinOps tools
>
> **Critical data belongs in Tags**, not x-* columns. Extension columns are for 
> supplementary information only.

### 4.4 Output Schema

JSON Schema for `estimate`, `check`, `diff` outputs.

### 4.5 Documentation

- CLI reference
- Integration guides
- Security policy
- FOCUS export guide (including BilledCost=0 handling)
- Provider transformation guides

---

## Phase 5: Calibration (v1.1)

### 5.1 The Drift Problem

| Drift Type | Cause | Responsibility |
|------------|-------|----------------|
| **Traffic** | 1M estimated, 2M actual | Monitoring (not us) |
| **Unit Economic** | 60% cache assumed, 30% actual | **Us** — formula wrong |

### 5.2 `calibrate` Command

```bash
llm-cost calibrate --profile estimates.json --actuals usage.focus.csv
```

**Output:**
```
⚠️  Unit Economic Drift Detected

Sample: 847 requests over 7 days

Parameter          Assumed   Actual    Drift     Confidence
───────────────────────────────────────────────────────────
cache_hit_ratio    60%       28%       -32% ⚠️   ±4% (high)
output_ratio       10%       12%       +2%  ✓    ±1% (high)

Apply updates to llm-cost.toml? [y/N]
```

**Calibration Thresholds:**

| Parameter | Value |
|-----------|-------|
| Minimum sample size | 100 requests |
| Minimum time window | 24 hours |
| Drift warning threshold | 20% |
| Drift error threshold | 50% |

### 5.3 FOCUS Import Schema

Required columns for `calibrate`:

| Column | Required |
|--------|----------|
| `ResourceId` | Yes |
| `BilledCost` | Yes |
| `UsageQuantity` | Yes |
| `x-cache-hit-ratio` | No |

---

## Timeline

| Version | Deliverables | Target |
|---------|--------------|--------|
| **v0.7** | Dynamic Pricing DB | Feb 2026 |
| **v0.8** | TOML Manifest, `prompt_id`, Scenarios | Mar 2026 |
| **v0.9** | Check command (incl. tag cardinality warning) | Apr 2026 |
| **v0.10** | Diff, GitHub Action | May 2026 |
| **v1.0** | FOCUS export (validated), Schema, Docs | Jun 2026 |
| **v1.1** | Calibrate, FOCUS import | Aug 2026 |

**Go/No-Go Gates:**
- v0.7 → v0.8: Security review complete
- v0.9 → v0.10: Check in own CI for 2 weeks
- v0.10 → v1.0: FOCUS export validated with Vantage ✓
- v1.0 → v1.1: User interviews complete

---

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Config format | TOML | YAML footguns |
| `prompt_id` | User-defined, stable | Cost trending requires stable identity |
| Cache hit default | None | Prevents false confidence |
| FOCUS Region | Omitted | LLM APIs global, validated compliant |
| FOCUS BilledCost | Always 0.00 | Estimates have no actual charge |
| Tag cardinality | Warn at >100 unique | FinOps tool performance |
| Telemetry | None | Offline-first hard contract |

---

## Validation Status

| Artifact | Status | Date |
|----------|--------|------|
| FOCUS schema compliance | ✓ Validated | Dec 2025 |
| Region omission | ✓ Confirmed correct | Dec 2025 |
| BilledCost=0 semantics | ✓ Confirmed correct | Dec 2025 |
| Vantage import | Pending | — |
| CloudZero import | Pending | — |

---

## Open-Core Model

| OSS (Free) | Enterprise (Paid) |
|------------|-------------------|
| CLI: estimate, check, diff | Cloud dashboard |
| All formats: JSON, FOCUS, MD | Multi-project aggregation |
| GitHub Action (self-hosted) | Hosted pricing DB + SLA |
| Local pricing DB | Team policies & RBAC |
| calibrate | Alerting & notifications |

---

## Out of Scope (Permanent)

- Agentic / MCP integration
- Real-time cost tracking
- Image/audio decoding
- Provider API keys
- Provider billing parsers
- Runtime attribution
- Telemetry / usage tracking
- Cost alerting (SaaS)

---

## Open Questions

### Before v0.7
1. Pricing DB hosting: CDN vs self-hosted?
2. Key ceremony: Single maintainer vs threshold?

### Before v1.0
3. FOCUS extensions: Coordinate `x-` fields with FOCUS working group?

---

## Resolved Decisions

| Question | Decision | Date |
|----------|----------|------|
| Provider coverage | OpenAI, Anthropic, Google (P0) | Dec 2025 |
| Region field | Omitted (validated) | Dec 2025 |
| BilledCost for estimates | 0.00 (validated) | Dec 2025 |
| Tag cardinality warning | >100 unique values | Dec 2025 |
| Calibrate sample minimum | 100 requests | Dec 2025 |
| Drift warning threshold | 20% | Dec 2025 |

---

## Related Documents

- `adr-007-focus-mapping.md` — FOCUS field mapping decisions
- `FOCUS-VALIDATION-REPORT.md` — Schema validation results
- `focus-output-recommended.csv` — Reference output format
- `pricing-db-spec-v07.md` — Pricing DB implementation spec
