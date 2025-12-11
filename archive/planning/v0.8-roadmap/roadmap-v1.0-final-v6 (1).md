# Roadmap to v1.0: The "Infracost for LLMs"

**Vision**: The industry standard static analysis tool for LLM cost estimation in CI/CD.
**Target Date**: Q2 2026
**Status**: FINAL v6 (Dec 2025)

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

**Why not content-hash for identity:**

| Scenario | Content hash ID | User-defined ID |
|----------|-----------------|-----------------|
| Prompt hernoemen | Same | ✓ Same |
| Prompt editen (typo fix) | **Breaks** | ✓ Same |
| Cost trending over tijd | Broken | ✓ Preserved |

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
| Emergency rotation | Immediate (see procedure below) |
| Provenance | Official pricing pages, manually verified |
| Update frequency | Weekly |

**Key Rotation Procedures:**

*Planned Rotation (90-day cycle):*
```
1. Generate new keypair
2. Announce on GitHub releases + security mailing list
3. Old key signs rotation message: {"rotate_to": "<new_pubkey>", "valid_until": "..."}
4. New pricing DB signed with BOTH keys for 90 days
5. New CLI release pins only new key
6. Old key retired after overlap period
```

*Emergency Rotation (key compromise):*
```
1. Immediately publish signed revocation: {"revoke": "<compromised_pubkey>", "reason": "..."}
2. New keypair generated, announced via GitHub Security Advisory
3. Emergency CLI release with new pinned key (semver PATCH, e.g., 0.7.1)
4. Revocation list checked BEFORE signature validation
5. All pricing DB files signed by compromised key rejected immediately
6. No overlap period — hard cutover
```

**Schema:**
```json
{
  "schema_version": 1,
  "generated_at": "2025-12-01T00:00:00Z",
  "valid_until": "2026-01-15T00:00:00Z",
  "models": {
    "gpt-4o": {
      "provider": "OpenAI",
      "input_price_per_mtok": 2.50,
      "output_price_per_mtok": 10.00,
      "context_window": 128000
    },
    "claude-3-sonnet": {
      "provider": "Anthropic",
      "input_price_per_mtok": 3.00,
      "output_price_per_mtok": 15.00,
      "context_window": 200000
    },
    "gemini-1.5-pro": {
      "provider": "Google",
      "input_price_per_mtok": 1.25,
      "output_price_per_mtok": 5.00,
      "context_window": 1000000
    }
  },
  "revocations": [],
  "signatures": {
    "primary": "...",
    "secondary": "..."
  }
}
```

**`valid_until` Behavior:**

| Condition | Behavior |
|-----------|----------|
| Current date < `valid_until` | Normal operation |
| Current date > `valid_until` | Warning: "Pricing data expired. Run: llm-cost update-db" |
| Current date > `valid_until` + 30 days | Error (exit 4): "Pricing data too old. Update required." |
| `--force-stale` flag | Bypass expiry check (for airgapped environments) |

```bash
# Normal case: expired but within grace period
$ llm-cost estimate prompt.txt

⚠️  Pricing data expired (valid until: 2026-01-15)
    Run: llm-cost update-db
    
Estimated cost: $0.42 (using expired prices)

# Hard expired: beyond grace period
$ llm-cost estimate prompt.txt

❌ Pricing data too old (expired: 2025-11-01, 75 days ago)
   Financial estimates require current pricing.
   
   Run: llm-cost update-db
   Or:  llm-cost estimate --force-stale (not recommended)

Exit code: 4 (PRICING_ERROR)
```

**Provider Coverage at Launch (v0.7):**

| Provider | Models | Priority |
|----------|--------|----------|
| **OpenAI** | gpt-4o, gpt-4o-mini, gpt-4-turbo, o1, o1-mini | P0 (launch) |
| **Anthropic** | claude-3.5-sonnet, claude-3-opus, claude-3-haiku | P0 (launch) |
| **Google** | gemini-1.5-pro, gemini-1.5-flash, gemini-2.0-flash | P0 (launch) |
| Azure OpenAI | Same as OpenAI (pricing differs) | P1 (v0.7.1) |
| AWS Bedrock | Anthropic models via Bedrock | P1 (v0.7.1) |
| Mistral | mistral-large, mistral-medium | P2 (v0.8) |
| Cohere | command-r, command-r-plus | P2 (v0.8) |

**Decision**: OpenAI + Anthropic + Google covers ~90% of production usage. Ship v0.7 with these three, expand in point releases.

### 2.2 Project Manifest (v0.8)

TOML manifest with `prompt_id` as first-class citizen.

**Init Flow:**

```bash
$ llm-cost init

? Where are your prompts located? [./prompts/**/*.txt]
  Found 4 prompt files.

? Assign stable IDs for cost tracking.
  (These IDs persist forever — choose meaningful names)
  
  prompts/search.txt
  ? Prompt ID: [search] █
  
  prompts/summarize.txt
  ? Prompt ID: [summarize] █
  
  prompts/classify.txt
  ? Prompt ID: [classify] █
  
  src/prompts/auth.txt
  ? Prompt ID: [api-auth] █

✓ Created llm-cost.toml

Tip: prompt_id is your cost tracking key.
     Rename files freely, but keep prompt_id stable for trending.
```

**Manifest:**
```toml
version = 1

[[prompts]]
path = "./prompts/search.txt"
prompt_id = "search"

[[prompts]]
path = "./prompts/summarize.txt"
prompt_id = "summarize"

[[prompts]]
path = "./prompts/classify.txt"
prompt_id = "classify"

[[prompts]]
path = "./src/prompts/auth.txt"
prompt_id = "api-auth"

[defaults]
model = "gpt-4o"

[budget]
limit = 10.00
currency = "USD"

[tags]
team = "platform"
app = "search"
cost_center = "CC-1234"
```

**Missing `prompt_id`:** Warning at check, not blocking.

**Rename Command:**

```bash
$ llm-cost rename-prompt --from "old-search" --to "search-v2"

⚠️  This will break cost history continuity.
    FinOps dashboards will see "search-v2" as a new resource.
    
    This is expected behavior, similar to renaming a Terraform resource.
    Previous cost data remains under "old-search".
    
Proceed? [y/N]
```

Note: No telemetry on rename usage. Offline-first is a hard contract. 
Behavioral insights come from `diff` output patterns in CI logs (user-owned).

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

Suggestions:
  • search uses gpt-4, consider gpt-4-turbo (-40%)

Exit code: 1 (BUDGET_EXCEEDED)
```

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
| classify    | new       | —       | $0.33   | +$0.33     |

Total: $6.40 → $7.23 (+13%)
```

The "Content" column uses internal `content_hash` to detect changes.
Identity (`prompt_id`) remains stable.

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

```bash
llm-cost estimate --format focus > estimates.focus.csv
```

**Field Mapping Strategy:**

| FOCUS Field | Source | Notes |
|-------------|--------|-------|
| `ResourceId` | `prompt_id` | User-defined, stable |
| `ResourceName` | File path | For human readability |
| `Provider` | Model Registry lookup | Embedded in pricing DB |
| `ServiceName` | `"LLM Inference"` | Fixed |
| `ServiceCategory` | `"AI and Machine Learning"` | FOCUS standard |
| `Region` | Omitted | LLM APIs are global; field nullable per FOCUS spec |
| `Tags` | Critical metadata (JSON) | Model, scenario, team, app |
| `x-*` columns | Detail data | Token counts, cache ratio, content hash |

**Tags (critical, high cardinality filtering):**
```json
{
  "llm-cost-type": "estimate",
  "model": "gpt-4o",
  "scenario": "cached",
  "team": "platform",
  "app": "search"
}
```

**Extension columns (detail, low cardinality):**
- `x-token-count-input`
- `x-token-count-output`
- `x-cache-hit-ratio`
- `x-content-hash`

**Example Output:**

```csv
BilledCost,EffectiveCost,ListCost,UsageQuantity,UsageUnit,ResourceId,ResourceName,ServiceName,ServiceCategory,Provider,ChargeCategory,Tags,x-token-count-input,x-token-count-output,x-cache-hit-ratio,x-content-hash
0.00,0.0041,0.0052,2370,Tokens,search,prompts/search.txt,LLM Inference,AI and Machine Learning,OpenAI,Usage,"{""llm-cost-type"":""estimate"",""model"":""gpt-4o"",""scenario"":""cached"",""team"":""platform"",""app"":""search""}",1847,523,0.60,a1b2c3
0.00,0.0028,0.0028,1650,Tokens,summarize,prompts/summarize.txt,LLM Inference,AI and Machine Learning,OpenAI,Usage,"{""llm-cost-type"":""estimate"",""model"":""gpt-4o"",""scenario"":""default"",""team"":""platform"",""app"":""search""}",1200,450,,d4e5f6
0.00,0.0003,0.0003,890,Tokens,classify,prompts/classify.txt,LLM Inference,AI and Machine Learning,OpenAI,Usage,"{""llm-cost-type"":""estimate"",""model"":""gpt-4o-mini"",""scenario"":""default"",""team"":""ml"",""app"":""triage""}",720,170,,g7h8i9
0.00,0.0120,0.0120,3200,Tokens,api-auth,src/prompts/auth.txt,LLM Inference,AI and Machine Learning,Anthropic,Usage,"{""llm-cost-type"":""estimate"",""model"":""claude-3-sonnet"",""scenario"":""default"",""team"":""security"",""app"":""auth""}",2800,400,,j1k2l3
0.00,0.0085,0.0102,2100,Tokens,onboarding-welcome,prompts/onboarding/welcome.txt,LLM Inference,AI and Machine Learning,OpenAI,Usage,"{""llm-cost-type"":""estimate"",""model"":""gpt-4o"",""scenario"":""cached"",""team"":""growth"",""app"":""onboarding""}",1600,500,0.85,m4n5o6
```

Note: `Region` column omitted — LLM inference APIs are globally distributed. FOCUS spec allows nullable Region.

### 4.2 Output Schema

JSON Schema for `estimate`, `check`, `diff` outputs.

### 4.3 Documentation

- CLI reference
- Integration guides
- Security policy
- FOCUS transformation guides (per provider)

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

**Output with Guardrails:**
```
⚠️  Unit Economic Drift Detected

Sample: 847 requests over 7 days

Parameter          Assumed   Actual    Drift     Confidence
───────────────────────────────────────────────────────────
cache_hit_ratio    60%       28%       -32% ⚠️   ±4% (high)
output_ratio       10%       12%       +2%  ✓    ±1% (high)
avg_input_tokens   1,200     1,450     +21% ⚠️   ±8% (medium)

Recommendations:
  1. cache_hit_ratio: Update to 0.28 (significant drift, high confidence)
  2. avg_input_tokens: Consider updating to 1450 (medium confidence)

⚠️  Warning: cache_hit_ratio drift is large (-32%).
    Before applying, verify this reflects steady-state, not an anomaly.

Apply updates to llm-cost.toml? [y/N]
```

**Calibration Thresholds (Decided):**

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| **Minimum sample size** | 100 requests | Statistical significance for ±10% confidence |
| **Minimum time window** | 24 hours | Avoid intra-day bias |
| **Drift warning threshold** | 20% | Significant but not necessarily actionable |
| **Drift error threshold** | 50% | Almost certainly a config problem |
| **Confidence: high** | Sample > 500, window > 7 days | Reliable for auto-apply |
| **Confidence: medium** | Sample 100-500 | Suggest but don't recommend auto-apply |
| **Confidence: low** | Sample < 100 | Show data but refuse to recommend |

**Behavior by Confidence:**

```bash
# High confidence (>500 samples, >7 days)
Apply updates to llm-cost.toml? [y/N]

# Medium confidence (100-500 samples)
⚠️  Medium confidence. Review recommendations manually.
Apply updates to llm-cost.toml? [y/N]

# Low confidence (<100 samples)
⚠️  Insufficient data for reliable calibration.
    Collect more samples before calibrating.
    
    Current: 47 requests over 2 days
    Required: 100+ requests over 24+ hours
    
Cannot apply updates. Showing drift for reference only.
```

### 5.3 FOCUS Import Schema

Required columns for `calibrate`:

| Column | Required | Maps To |
|--------|----------|---------|
| `ResourceId` | Yes | `prompt_id` |
| `BilledCost` | Yes | Actual cost |
| `UsageQuantity` | Yes | Call count |
| `x-cache-hit-ratio` | No | Observed cache rate |
| `x-avg-output-tokens` | No | Avg output per call |

### 5.4 Provider → FOCUS Guides

Documentation (not code) for transforming provider exports:

| Provider | Guide |
|----------|-------|
| OpenAI | `docs/focus/openai.md` |
| Anthropic | `docs/focus/anthropic.md` |
| Azure OpenAI | `docs/focus/azure.md` |
| Google Vertex | `docs/focus/vertex.md` |

---

## Timeline

| Version | Deliverables | Target |
|---------|--------------|--------|
| **v0.7** | Dynamic Pricing DB (OpenAI, Anthropic, Google) | Feb 2026 |
| **v0.7.1** | Azure OpenAI, AWS Bedrock pricing | Feb 2026 |
| **v0.8** | TOML Manifest, `prompt_id`, Scenarios, `rename-prompt` | Mar 2026 |
| **v0.9** | Check command | Apr 2026 |
| **v0.10** | Diff (with content change detection), GitHub Action | May 2026 |
| **v1.0** | FOCUS export, Schema, Docs | Jun 2026 |
| **v1.1** | Calibrate, FOCUS import | Aug 2026 |

**Go/No-Go Gates:**
- v0.7 → v0.8: Security review complete, key ceremony documented
- v0.9 → v0.10: Check in own CI for 2 weeks
- v0.10 → v1.0: Beta feedback incorporated, FOCUS validated with Vantage
- v1.0 → v1.1: User interviews on prompt_id usage patterns (3-5 teams)

---

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Config format | TOML | YAML footguns |
| `prompt_id` | User-defined, stable | Cost trending requires stable identity |
| `content_hash` | Internal, auto-computed | Change detection separate from identity |
| Cache hit default | None | Prevents false confidence |
| Baseline storage | Stateless | No hidden state |
| Provider resolution | Model Registry lookup | Reliable, embedded in pricing DB |
| FOCUS Region | Omitted (nullable) | LLM APIs are global |
| FOCUS fields | Tags (critical) + x-* (detail) | Balance filtering vs extension |
| Telemetry | None | Offline-first is hard contract |
| Rename behavior | Warn, don't track | Like Terraform — expected behavior |
| Pricing expiry | Warn + 30-day grace, then error | Balance freshness vs offline use |
| Emergency key rotation | Immediate, no overlap | Security trumps convenience |
| Calibrate min sample | 100 requests | Statistical significance |
| Drift warning threshold | 20% | Actionable signal |

---

## Open-Core Model

| OSS (Free) | Enterprise (Paid) |
|------------|-------------------|
| CLI: estimate, check, diff | Cloud dashboard |
| All formats: JSON, FOCUS, MD | Multi-project aggregation |
| GitHub Action (self-hosted) | Hosted pricing DB + SLA |
| Local pricing DB | Team policies & RBAC |
| calibrate | Alerting & notifications |

FOCUS export is free — it's plumbing, not product.

---

## Success Metrics

| Metric | Target |
|--------|--------|
| Time to first PR comment | < 10 minutes |
| `--help` discoverability | 80% findable without docs |
| CI failure diagnosis | < 30 seconds |
| FOCUS export validation | Works with Vantage, CloudZero |
| Calibrate accuracy | Drift < 15% after calibration |

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
1. Pricing DB hosting: CDN (Cloudflare R2) vs self-hosted?
2. Key ceremony: Single maintainer vs threshold signature (2-of-3)?

### Before v1.0
3. FOCUS extensions: Coordinate `x-` fields with FOCUS working group?
4. Vantage import validation: Test account secured?

---

## Resolved Decisions

| Question | Decision | Date |
|----------|----------|------|
| Provider coverage at launch | OpenAI, Anthropic, Google (P0) | Dec 2025 |
| Region field in FOCUS | Omitted (nullable) | Dec 2025 |
| Emergency key rotation | Immediate cutover, no overlap | Dec 2025 |
| `valid_until` behavior | Warn → 30-day grace → Error | Dec 2025 |
| Calibrate sample minimum | 100 requests | Dec 2025 |
| Drift warning threshold | 20% | Dec 2025 |

---

## Related Documents

- `adr-007-focus-mapping.md` — FOCUS field mapping decisions
- `docs/focus/*.md` — Provider transformation guides
- `llm-cost.schema.json` — Output schema definitions
- `SECURITY.md` — Key rotation procedures
