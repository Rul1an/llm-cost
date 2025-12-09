# Roadmap: Fase 1.5 – OSS Technical Hardening

**Version:** 3.1  
**Status:** Draft  
**Author:** [Maintainer]  
**Date:** 2025-01  
**Last Updated:** 2025-01 (v3.1: added check-policy, Parity-Aware BPE exclusion, expanded fairness metrics)

> **See also:** [`research-decisions.md`](research-decisions.md) for detailed analysis of 15+ papers and definitive adoption decisions.  

---

## Executive Summary

Fase 1.5 brengt llm-cost van "nette OSS-tool" naar "technisch fundament voor enterprise automation". Geen nieuwe eindgebruiker-features; wel de architectuur, contracten en guarantees die nodig zijn voordat teams hierop durven te bouwen.

**Doorlooptijd:** 6-8 weken (solo developer)  
**Blocker voor:** Fase 2 (Internal/Enterprise Tool)

---

## Scope

### In Scope

| ID | Component | Beschrijving |
|----|-----------|--------------|
| R1 | BPE v2 | O(N log N) algoritme met index-based linked list + min-heap |
| R2 | CLI Contract | JSON output, exit codes, quiet mode als stabiele API |
| R3 | Pricing v2 | Input/output split, eerlijke scope-afbakening |
| R4 | SLSA L2 | Provenance attestations, pinned actions, verificatie-docs |
| R5 | Legal/Vocab | NOTICE file, vocab traceability |
| R6 | Golden Tests | CLI contract tests naast parity tests |
| R7 | Backend Arch | Comptime generics voor tokenizer backends |

### Out of Scope (Fase 2+)

- SentencePiece backend implementatie
- C ABI / WASM builds
- Vendor usage log enrichment
- Multi-tenant features
- Pricing voor reasoning/cached/tool tokens

---

## Dependencies

```
┌─────────────────────────────────────────────────────────────┐
│                                                             │
│  R7 Backend Arch ◄─────┐                                    │
│        │               │                                    │
│        ▼               │                                    │
│  R1 BPE v2 ────────────┤                                    │
│        │               │                                    │
│        ▼               │                                    │
│  R6 Golden Tests ◄─────┴─── R2 CLI Contract                 │
│        │                          │                         │
│        │                          ▼                         │
│        │                    R3 Pricing v2                   │
│        │                          │                         │
│        ▼                          ▼                         │
│  ┌─────────────────────────────────────┐                    │
│  │         Release Gate                │                    │
│  │  (all tests green, docs complete)   │                    │
│  └─────────────────────────────────────┘                    │
│        │                                                    │
│        ▼                                                    │
│  R4 SLSA L2 ◄──── R5 Legal/Vocab                           │
│        │                                                    │
│        ▼                                                    │
│  ┌─────────────────────────────────────┐                    │
│  │      v0.5.0 Release                 │                    │
│  └─────────────────────────────────────┘                    │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**Critical Path:** R7 → R1 → R6 → Release

---

## Timeline

### Week 1-2: Foundation

| Task | Owner | Deliverable | Exit Criteria |
|------|-------|-------------|---------------|
| R7.1 Define Backend trait | - | `src/tokenizer/backend.zig` | Compiles, no functional change |
| R7.2 Refactor O200k/Cl100k | - | Existing backends use new trait | All tests pass |
| R7.3 Add HeuristicBackend | - | Char-based fallback via same interface | Heuristic mode works |
| R5.1 NOTICE file | - | `NOTICE` in repo root | Legal review pass |
| R5.2 docs/vocab.md | - | Vocab provenance documented | Links to source commits |

### Week 3-4: BPE v2

| Task | Owner | Deliverable | Exit Criteria |
|------|-------|-------------|---------------|
| R1.1 Research linear BPE | - | Internal doc with algorithm choice | Approach documented |
| R1.2 Implement bpe_linear.zig | - | New BPE engine | Compiles |
| R1.3 Parity validation | - | Evil Corpus passes | 100% parity |
| R1.4 Performance benchmark | - | `zig build bench-compare` | ≥2x speedup worst-case |
| R1.5 Switch default engine | - | Linear BPE is default | No regressions |

### Week 5-6: CLI Contract

| Task | Owner | Deliverable | Exit Criteria |
|------|-------|-------------|---------------|
| R2.1 JSON output mode | - | `--format json` flag | Valid JSON per line |
| R2.2 Summary JSON | - | `--summary-format json` | Schema documented |
| R2.3 Exit codes | - | `ExitCode` enum, mapped | Matches spec |
| R2.4 Quiet mode | - | `--quiet` flag | Only JSON output |
| R3.1 Pricing struct v2 | - | `CostBreakdown` with split | Tests pass |
| R3.2 Pricing docs | - | Scope statement in docs | Review approved |

### Week 7: Testing & Hardening

| Task | Owner | Deliverable | Exit Criteria |
|------|-------|-------------|---------------|
| R6.1 Golden test fixtures | - | `testdata/golden/*` | 3+ test sets |
| R6.2 Golden test runner | - | `zig build test-golden` | In CI |
| R6.3 Exit code tests | - | Shell-based CI tests | All codes tested |
| R2.5 CLI docs | - | `docs/cli.md` complete | Schema + codes documented |

### Week 8: Release Prep

| Task | Owner | Deliverable | Exit Criteria |
|------|-------|-------------|---------------|
| R4.1 Pin all actions | - | SHA-pinned workflows | No tag refs |
| R4.2 SLSA provenance | - | `.intoto.jsonl` generation | Verifier passes |
| R4.3 Security docs | - | `docs/security.md` update | SLSA L2 claim explicit |
| R4.4 Release v0.5.0 | - | Tagged release | All artifacts signed |

---

## Milestones

| Milestone | Target | Gate Criteria |
|-----------|--------|---------------|
| M1: Backend Arch | Week 2 | R7 complete, tests green |
| M2: BPE v2 | Week 4 | R1 complete, parity + perf validated |
| M3: CLI Contract | Week 6 | R2 + R3 complete, JSON output stable |
| M4: Test Suite | Week 7 | R6 complete, golden tests in CI |
| M5: Release | Week 8 | R4 + R5 complete, v0.5.0 shipped |

---

## Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Linear BPE breaks parity | Medium | High | Extensive Evil Corpus testing; keep v1 as fallback |
| SLSA generator incompatible | Low | Medium | Generic workflow supports any artifact type |
| Scope creep (new features) | Medium | Medium | Hard freeze on feature requests until M5 |
| Performance regression | Low | High | Automated bench in CI; alert on >10% regression |

---

## Success Criteria

Fase 1.5 is complete wanneer:

1. **Performance:** `zig build bench-bpe` toont O(N log N) scaling (niet O(N²))
2. **Correctness:** `zig build test-parity` 100% groen
3. **Contract:** `zig build test-golden` 100% groen
4. **Security:** `slsa-verifier` valideert release artifacts
5. **Legal:** NOTICE file present, vocab.md complete
6. **Docs:** architecture.md, cli.md, security.md up-to-date

---

## Post-Fase 1.5: Evolutiepad & Future Roadmap

Met de fundatie van Phase 1.5 (BPE v2, CLI contracts, SLSA L2) ontstaan drie duidelijke evolutielijnen:

```
                    Phase 1.5 (nu)
                         │
                         ▼
        ┌────────────────┼────────────────┐
        │                │                │
        ▼                ▼                ▼
   Performance      Analytics &      Enterprise &
   Hardening        Optimization     Governance
        │                │                │
        ▼                ▼                ▼
   • BPE v3          • Efficiency     • Federated
   • Parallel scan     Advisor          Analytics
   • SIMD            • Compression    • Multi-tenant
                       Analysis         Benchmarks
```

---

## Future Roadmap: Top 5 Opportunities

> **Research-backed:** These opportunities are informed by review of 15+ papers. See [`research-decisions.md`](research-decisions.md) for full analysis.

---

### NEW: Phase 2 Commands (Research-Backed)

#### 2.1 `llm-cost tokenizer-report` - Tokenizer Metrics

**Research basis:** SuperBPE, Binary BPE (metrics only, not algorithm)

```bash
llm-cost tokenizer-report --model gpt-4o --corpus corpus.txt --format json
```

**Output metrics:**
| Metric | Description |
|--------|-------------|
| `bytes_per_token` | Average bytes per token (compression efficiency) |
| `tokens_per_word` | Fertility score |
| `compression_ratio` | Input bytes / output tokens |
| `vocab_utilization` | % of vocabulary used on corpus |
| `unique_tokens` | Count of distinct tokens produced |

**Effort:** 1 week

---

#### 2.2 `llm-cost analyze-fairness` - Token Tax Analysis

**Research basis:** "Token Tax" (2025), "Do All Languages Cost the Same?" (EMNLP 2023), MAGNET (metrics)

```bash
llm-cost analyze-fairness \
  --corpus corpus.toml \
  --models gpt-4o,gpt-4o-mini \
  --format json
```

**Output:**
```json
{
  "model": "gpt-4o",
  "languages": {
    "en": { "bytes_per_token": 4.2, "vocab_utilization": 0.82, "premium": 1.0 },
    "zh": { "bytes_per_token": 2.1, "vocab_utilization": 0.34, "premium": 0.71 },
    "am": { "bytes_per_token": 1.2, "vocab_utilization": 0.08, "premium": 3.67 }
  },
  "fairness_metrics": {
    "gini_coefficient": 0.34,
    "max_premium": 3.67,
    "worst_language": "am",
    "parity_ratio_range": [0.71, 3.67]
  }
}
```

**Fairness Metrics (from research):**
| Metric | Definition |
|--------|------------|
| Tokenization Parity (TP) | `tokens(lang_L) / tokens(English)` |
| Gini Coefficient | Distribution inequality (0=equal) |
| MorphScore | Token-morpheme boundary alignment |
| Vocabulary Utilization | Vocab fraction used per language |

**Business value:**
- Quantify multilingual cost disparities
- Support fair pricing discussions
- Identify high-cost language workloads

**Effort:** 2-3 weeks

---

#### 2.3 `llm-cost plan` - Scenario Planner

**Research basis:** Cost optimization literature, FinOps practices

```bash
llm-cost plan --config plan.yaml --format json
```

**Config:**
```yaml
prompt_variants:
  - id: baseline
    file: prompts/baseline.txt
  - id: compressed
    file: prompts/compressed.txt

models:
  - gpt-4o-mini
  - gpt-4o

constraints:
  max_input_tokens: 4000
  max_cost_usd: 0.02
```

**Output:**
```json
{
  "plans": [
    {
      "variant": "compressed",
      "model": "gpt-4o-mini",
      "tokens_in": 1234,
      "cost_usd": 0.0012,
      "within_constraints": true
    }
  ],
  "best_plan": { "variant": "compressed", "model": "gpt-4o-mini" }
}
```

**Effort:** 2 weeks

---

#### 2.4 `llm-cost check-policy` - Policy/SLO Checker

**Research basis:** Cost-as-SLO literature, gateway/routing papers

```bash
llm-cost check-policy \
  --events events.jsonl \
  --policy policy.yaml \
  --format json
```

**Policy config:**
```yaml
rules:
  - name: "no_flagship_for_tier_b"
    match:
      tenant_tier: "B"
    forbid_models: ["gpt-5", "claude-opus"]
    
  - name: "max_tokens_per_call"
    max_tokens_total: 4096
    
  - name: "cost_cap_per_request"
    max_cost_usd: 0.10

slos:
  - name: "cost_parity"
    metric: "cost_per_1k_chars"
    max_variance_pct: 20
```

**Output:**
```json
{
  "total_events": 10000,
  "violations": [
    { "rule": "no_flagship_for_tier_b", "count": 23 },
    { "rule": "max_tokens_per_call", "count": 5, "max_observed": 8192 }
  ],
  "slo_status": {
    "cost_parity": { "status": "BREACHED", "variance_pct": 34.2 }
  }
}
```

**Use cases:**
- Gateway policy enforcement
- FinOps governance & cost attribution
- Fairness SLO monitoring
- Chargeback validation

**Effort:** 2 weeks

---

### 1. BPE v3 – Van O(N log N) naar O(N) (Bucket Queue)

**Status:** Research complete, implementatie gepland  
**Effort:** 1-2 weken  
**Trigger:** Benchmarks tonen BPE als bottleneck

**Wat:**
```
Huidige BPE v2: min-heap → O(N log N)
Toekomstig v3:  bucket queue per rank → O(N)
```

**Waarom interessant:**
- Extra performance headroom voor grote prompts/batches
- Embedded use in latency-gevoelige services
- Marketingpunt: "provably linear-time BPE"

**Wanneer:**
- Nu: BPE v2 is "fast enough" voor CLI use cases
- Later: activeren zodra benchmarks aantonen dat BPE de bottleneck is

**Referentie:** `docs/technical-challenges-1.5.md` → Challenge 2.6

---

### 2. Parallel File-/Repo-Scanning (ripgrep-style)

**Status:** Concept gedocumenteerd  
**Effort:** 2-3 weken  
**Trigger:** Vraag naar batch/repo-level token counting

**Wat:**
```bash
# Toekomstige mode
llm-cost scan ./logs/ --parallel --recursive
llm-cost scan ./repo/ --exclude .git,node_modules
```

**Features:**
- Parallel directory traversal (thread pool)
- Smart filtering (.git, node_modules, __pycache__)
- Memory-mapped I/O voor throughput
- Per-file en totaal summary

**Use case:**
- "Wat kost het als we deze hele dataset prompten?"
- "Hoeveel tokens/€ zitten in al onze logs?"
- FinOps planning op dataset-niveau

**Architectuur:**
```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│ Dir Walker  │────▶│ Thread Pool │────▶│ Aggregator  │
│ (parallel)  │     │ (per-file)  │     │ (summary)   │
└─────────────┘     └─────────────┘     └─────────────┘
      │                   │                   │
      ▼                   ▼                   ▼
   ignore:            mmap + arena        JSON/table
   .git, etc.         per file            output
```

---

### 3. Prompt Efficiency & Besparingsadvies

**Status:** Concept  
**Effort:** 3-4 weken  
**Trigger:** Enterprise vraag naar optimalisatie-inzichten

**Wat:**
```bash
# Toekomstige analyzer mode
llm-cost analyze usage.jsonl --report efficiency
```

**Output:**
```json
{
  "total_tokens": 1234567,
  "total_cost_usd": 45.67,
  "opportunities": {
    "semantic_duplicates": {
      "count": 234,
      "potential_savings_usd": 12.34,
      "recommendation": "Enable prompt caching"
    },
    "verbose_prompts": {
      "count": 89,
      "avg_reduction_possible": "35%",
      "recommendation": "Add 'be concise' instruction"
    },
    "top_expensive_patterns": [
      { "pattern": "system prompt template A", "cost": 15.23 },
      { "pattern": "few-shot examples", "cost": 8.91 }
    ]
  }
}
```

**Business value:**
- Direct kostenbesparingspotentieel zichtbaar
- Actionable recommendations
- ROI meetbaar

---

### 4. Entropy-/Value-based Token Analytics

**Status:** Research/Labs  
**Effort:** 4-6 weken (requires ML integration)  
**Trigger:** Toegang tot logprobs in usage logs

**Wat:**
Analyse van logprobs/entropie per token:
- **Lage entropie:** voorspelbare tokens (boilerplate)
- **Hoge entropie:** reasoning tokens (beslismomenten)

**Inzicht:**
```
"68% van je tokens zijn low-entropy (boilerplate)
 32% zijn high-entropy (actual reasoning)
 
 Je betaalt $45.67 voor reasoning, $95.23 voor filler."
```

**Waarom interessant:**
- Vooruitlopen op value-based pricing trends
- Identificeer waar modellen "hard werken"
- Optimaliseer prompts op basis van "informatieve waarde"

**Blokkerende factor:**
- Vereist logprobs in input data
- Mogelijk extern ML model nodig

---

### 5. Federated & Privacy-Preserving Analytics

**Status:** Concept voor SaaS/Platform layer  
**Effort:** 6-8 weken  
**Trigger:** Enterprise/multi-tenant requirements

**Wat:**
Aggregated benchmarks zonder raw data te delen:
- "Jouw team is in top 25% qua token-efficiency"
- Usage benchmarks per model/team/afdeling
- Differential privacy + secure aggregation

**Architectuur:**
```
┌─────────────────────────────────────────────────────┐
│                   SaaS Platform                      │
├─────────────────────────────────────────────────────┤
│  Secure Aggregation  │  Differential Privacy        │
├─────────────────────────────────────────────────────┤
│         llm-cost CLI (lokaal bij tenant)            │
└─────────────────────────────────────────────────────┘
```

**Enterprise value:**
- GDPR/SOC 2 compliant
- Benchmarking zonder data sharing
- Governance & cost allocation

---

## Roadmap Phases

### Phase 1.5 (NOW) - Technical Hardening
```
✅ BPE v2 (O(N log N), heap-based)
✅ CLI JSON contract + exit codes
✅ Pricing v2 (input/output split)
✅ SLSA L2 provenance
✅ Golden tests
✅ Differential fuzzing vs tiktoken
✅ Property-based tests (roundtrip, no crash)
```
**Release:** v0.5.0

### Phase 2 - Analytics & New Commands (Research-Backed)

**New commands based on literature review:**

```
○ llm-cost tokenizer-report    # Metrics: bytes/token, compression, vocab utilization
○ llm-cost analyze-fairness    # Token Tax analysis per language/script
○ llm-cost plan                # Scenario planner: variant × model × constraints
○ llm-cost check-policy        # Policy/SLO checker for usage events
```

**Supporting features:**
```
○ Load testing (10GB+ workloads)
○ FinOps dashboard integration  
○ Vendor log enrichment
○ Internal deployment playbooks
```

**Research basis:** Token Tax papers (EMNLP 2023, 2025), cost optimization literature
**Target:** v0.6.0 - v0.8.0

### Phase 3 - Performance & Scale
```
○ BPE v3 (bucket queue, O(N))
○ Parallel file scanning
○ SIMD pre-tokenizer
○ LoPT chunking (large files)
○ Memory-mapped I/O
```
**Target:** v1.0.0

### Phase 4 - Analytics & Optimization
```
○ Efficiency analyzer
○ Prompt compression advisor
○ Semantic dedup detection
○ Cost optimization reports
```
**Target:** v1.x

### Phase 5 - Enterprise Platform
```
○ Federated analytics
○ Multi-tenant benchmarks
○ Privacy-preserving aggregation
○ Governance dashboards
```
**Target:** v2.0 / SaaS layer

---

## Technology Decisions (Locked)

| Decision | Status | Rationale |
|----------|--------|-----------|
| Pure Zig, single binary | ✅ Locked | Zero dependencies value prop |
| tiktoken parity | ✅ Locked | Cost accuracy requires exact match |
| No BoundlessBPE | ✅ Locked | Would break parity |
| No runtime downloads | ✅ Locked | Offline capability |
| SLSA L2 minimum | ✅ Locked | Enterprise trust requirement |

## Technology Decisions (Open for Future)

| Decision | Status | When to Revisit |
|----------|--------|-----------------|
| BPE v3 bucket queue | Open | When benchmarks show BPE bottleneck |
| SIMD pre-tokenizer | Open | After BPE v3, if pre-tok is bottleneck |
| LoPT parallel chunking | Open | When --file mode with >1MB files |
| SentencePiece backend | Open | When Llama/Mistral support requested |
| io_uring (Linux) | Open | Extreme perf requirements only |

---

## Activation Triggers

Gebruik deze triggers om te beslissen wanneer een feature te activeren:

### Phase 2 Features (Low barrier - implement when requested)

| Feature | Trigger |
|---------|---------|
| `tokenizer-report` | Any user request for tokenizer metrics |
| `analyze-fairness` | Enterprise/multilingual workload analysis needs |
| `plan` command | FinOps teams ask for scenario planning |
| `check-policy` | Enterprise governance requirements |

### Phase 3+ Features (Benchmark-driven)

| Feature | Trigger |
|---------|---------|
| BPE v3 | Benchmarks tonen BPE >50% of total runtime |
| SIMD pre-tokenizer | Pre-tokenizer >30% of total runtime |
| Parallel scan | User requests for repo/dir scanning |
| Efficiency analyzer | Enterprise/FinOps teams vragen om optimization insights |
| Value-based analytics | Access tot logprobs in production logs |
| Federated analytics | Multi-tenant / enterprise deal requirements |

---

## Not Doing (Explicit Exclusions Based on Research)

| Item | Reason | Source |
|------|--------|--------|
| **SuperBPE** | Changes tokenizer training, breaks parity | Liu et al. COLM 2025 |
| **BoundlessBPE** | Breaks tiktoken parity (merges across boundaries) | Schmidt et al. 2024 |
| **Parity-Aware BPE** | Changes training objective, not runtime. We use vendor vocab. | Bleeding edge 2024-25 |
| **AG-BPE** | Vocab/merge strategies for runtime - still changes training | Research 2025 |
| **Binary BPE** | Wrong domain (executables, not text) | Bommarito Nov 2025 |
| **MAGNET** | Requires model architecture changes | Ahia et al. NeurIPS 2024 |
| **BlockBPE GPU** | Out of scope (GPU/CUDA dependency) | ICML 2025 |
| **R-BPE caching** | Premature optimization for streaming | EMNLP 2025 |
| **LoPT chunking** | Only for >1MB files, defer to Phase 3 | ArXiv 2025 |
| **Preprocessing transducers** | SentencePiece-specific (LLAMA2 space markers) | - |
| **Tenant-specific caching** | SaaS layer, not CLI tool | Gateway papers |
| Cache-oblivious algo | Overkill for workload | - |
| Real-time pricing API | Out of scope (offline tool) | - |
| Training tokenizers | Out of scope (inference only) | - |

> **Note:** All tokenizer training innovations (SuperBPE, BoundlessBPE, Parity-Aware BPE, MAGNET, AG-BPE, etc.) are excluded because llm-cost uses **vendor vocabularies** for parity. We don't train tokenizers; we match existing ones exactly.

**See [`research-decisions.md`](research-decisions.md) for detailed analysis.**
