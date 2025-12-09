# Research Decisions: BPE & Tokenization Literature Review

**Version:** 1.1  
**Date:** 2025-01  
**Status:** FINAL DECISIONS (updated)

Dit document bevat de definitieve beslissingen over alle onderzochte research papers en technieken voor llm-cost.

---

## Executive Summary

Na uitgebreid onderzoek van 15+ papers en implementaties zijn dit de kernbeslissingen:

| Categorie | Beslissing | Fase |
|-----------|------------|------|
| BPE Runtime | Index-based TokenBuffer + min-heap | **1.5** ✅ |
| Testing | Differential fuzzing vs tiktoken | **1.5** ✅ |
| Formal Properties | Injectivity, exactness, context-invariance | **1.5** ✅ |
| Metrics | bytes/token, compression ratio, Gini | **1.5** ✅ |
| Fairness Analysis | Token Tax analyzer command | **2** 🔄 |
| Scenario Planning | `llm-cost plan` command | **2** 🔄 |
| Policy Checker | `llm-cost check-policy` command | **2** 🔄 |
| BPE v3 | Bucket queue (O(N)) | **When needed** ⏸️ |
| SIMD Pre-tokenizer | Vectorized scanning | **When needed** ⏸️ |
| Cost-as-SLO | Formal cost SLO framework | **Phase 3+** 📚 |
| DFA Equivalence | Formal verification | **Research** 📚 |
| SuperBPE/BoundlessBPE/Parity-Aware | Training innovations | **NEVER** ❌ |

---

## 1. BPE Training Innovations (NOT ADOPTING)

### 1.1 SuperBPE (COLM 2025)

**Paper:** "SuperBPE: Space Travel for Language Models" (Liu et al., March 2025)

**What it does:**
- Two-phase pretokenization curriculum: first subwords, then "superwords" (multi-word tokens)
- 33% fewer tokens to represent same text
- +4.0% improvement on downstream tasks
- 27% less inference compute

**Decision:** ❌ NOT ADOPTING

**Rationale:**
- SuperBPE changes how the tokenizer is **trained**, not how it runs
- llm-cost uses **vendor vocabularies** (tiktoken) - we don't train tokenizers
- Adopting SuperBPE would break parity with OpenAI models
- The research is interesting for LLM training, not for cost calculation

**What we CAN use:**
- Metrics from paper: bytes/token, compression ratio, vocab utilization
- These metrics are useful for our tokenizer-report feature

---

### 1.2 BoundlessBPE (2024)

**Paper:** "Boundless Byte Pair Encoding: Breaking the Pre-tokenization Barrier"

**What it does:**
- Allows BPE merges across pre-tokenization boundaries
- 21% increase in Rényi efficiency
- 19.7% increase in bytes per token

**Decision:** ❌ EXPLICITLY REJECTED

**Rationale:**
- **BREAKS TIKTOKEN PARITY** - produces different token sequences
- This directly contradicts our core value proposition: exact match with OpenAI
- Document in "Not Doing" section as explicit exclusion

**Quote from our earlier analysis:**
> "Merges across regex boundaries for better compression. Contradicts core value prop: 'match OpenAI exact'. Decision: Explicitly reject."

---

### 1.3 Binary BPE (Nov 2025)

**Paper:** "Binary BPE: A Family of Cross-Platform Tokenizers for Binary Analysis"

**What it does:**
- BPE tokenizers for executable binaries (ELF/PE/Mach-O)
- 2-3x compression on binaries
- Discovers patterns like instruction prefixes, file headers

**Decision:** ❌ NOT RELEVANT

**Rationale:**
- Wrong domain: llm-cost processes **text**, not binary executables
- Interesting research, but not applicable to our use case
- No action needed

---

### 1.4 MAGNET (NeurIPS 2024)

**Paper:** "MAGNET: Improving the Multilingual Fairness of Language Models with Adaptive Gradient-Based Tokenization"

**What it does:**
- Gradient-based tokenization within model architecture
- Language-script-specific boundary predictors
- Reduces over-segmentation for non-Latin scripts

**Decision:** ❌ NOT ADOPTING (but informs fairness analysis)

**Rationale:**
- Requires model architecture changes, not just tokenizer changes
- We use **vendor tokenizers** - can't change their architecture
- HOWEVER: The fairness metrics and analysis approach is valuable

**What we CAN use:**
- Metrics: segmentation granularity per language/script
- Analysis approach: compare compression rates across languages
- This informs our `analyze-fairness` feature

---

### 1.5 Length-MAX / Other Training Innovations

**Papers:** Various (Fusion Token, PickyBPE, etc.)

**Decision:** ❌ NOT ADOPTING

**Rationale:**
- All change tokenizer training, not runtime
- We use pre-trained vendor vocabularies
- Research informs understanding, not implementation

---

## 2. Token Tax & Fairness Analysis (ADOPTING)

### 2.1 Token Tax Papers (2023-2025)

**Papers:**
- "Do All Languages Cost the Same?" (Ahia et al., EMNLP 2023)
- "The Token Tax: Systematic Bias in Multilingual Tokenization" (2025)
- "Language Model Tokenizers Introduce Unfairness Between Languages"

**Key Findings:**
- Non-English languages require 2-15x more tokens for same content
- Higher fertility (tokens/word) correlates with lower accuracy
- Token-based pricing disadvantages low-resource languages
- "A doubling in tokens results in quadrupled training cost"

**Decision:** ✅ ADOPT AS ANALYSIS FEATURE

**Fairness Metrics (from research):**

| Metric | Definition | Source |
|--------|------------|--------|
| **Tokenization Parity (TP)** | `tokens(lang_L) / tokens(English)` for same content | mBERT studies |
| **Gini Coefficient** | Distribution inequality of per-language costs (0=equal) | Parity-Aware BPE |
| **MorphScore** | Alignment of token boundaries with morpheme boundaries | Fairness papers |
| **Vocabulary Utilization** | Fraction of vocab actually used per language | SuperBPE metrics |
| **Bytes per Token** | Compression efficiency per language | Universal |
| **Token Premium** | Cost multiplier vs English baseline | Token Tax papers |

**Implementation:**

```bash
# New command: llm-cost analyze-fairness
llm-cost analyze-fairness \
  --corpus corpus.toml \
  --models gpt-4o,gpt-4o-mini,claude-3-sonnet \
  --format json
```

**Output:**
```json
{
  "model": "gpt-4o",
  "languages": {
    "en": { 
      "bytes_per_token": 4.2, 
      "tokens_per_sentence": 12.3, 
      "vocab_utilization": 0.82,
      "premium": 1.0 
    },
    "zh": { 
      "bytes_per_token": 2.1, 
      "tokens_per_sentence": 8.7, 
      "vocab_utilization": 0.34,
      "premium": 0.71 
    },
    "am": { 
      "bytes_per_token": 1.2, 
      "tokens_per_sentence": 45.2, 
      "vocab_utilization": 0.08,
      "premium": 3.67 
    }
  },
  "fairness_metrics": {
    "gini_coefficient": 0.34,
    "max_premium": 3.67,
    "worst_language": "am",
    "parity_ratio_range": [0.71, 3.67]
  }
}
```

**Phase:** 2 (after Phase 1.5 foundation)

**Effort:** 2-3 weeks

---

## 3. Runtime Optimizations (ADOPTING)

### 3.1 Index-Based TokenBuffer

**Sources:** GitHub bpe crate, BlockBPE analysis, our own research

**Decision:** ✅ ADOPT IN PHASE 1.5

Already documented in technical-challenges-1.5.md. Key points:
- Parallel arrays instead of pointer chains
- O(1) validity check via `valid[]` array
- Better cache locality
- ~16 bytes per token vs 24+ for pointers

---

### 3.2 Lazy-Delete MergeQueue

**Sources:** GitHub bpe crate, heap optimization literature

**Decision:** ✅ ADOPT IN PHASE 1.5

Already documented. Key points:
- Leave stale entries in heap
- 4-point validation at pop time
- O(N log N) total complexity

---

### 3.3 BPE v3 Bucket Queue

**Sources:** Our own analysis, linear BPE literature

**Decision:** ⏸️ DEFER (trigger-based)

**Trigger:** Benchmarks show BPE >50% of total runtime

**Implementation sketch:**
```zig
pub const BucketQueue = struct {
    bucket_heads: []Index,      // head per rank
    next_in_bucket: []Index,    // linked list per rank
    current_rank: Rank,
    // O(1) add, O(1) amortized pop
};
```

**Phase:** Post-1.5, when benchmarks justify

---

### 3.4 SIMD Pre-tokenizer

**Sources:** BlockBPE, simd_tiktoken blog, "faster BPE" implementations

**What it does:**
- Vectorized scanning for whitespace/boundaries
- ASCII fast-path (16-32 bytes per step)
- Hardware-accelerated character class lookup

**Decision:** ⏸️ DEFER (trigger-based)

**Trigger:** Pre-tokenizer >30% of total runtime

**Rationale:**
- BlockBPE showed regex/pre-tokenization is ~75% of runtime in some cases
- But our workload (JSONL streaming) may be different
- Measure first, optimize second

**Phase:** Post-1.5, if benchmarks show pre-tokenizer is bottleneck

---

## 4. Formal Verification & Testing (PARTIALLY ADOPTING)

### 4.0 Formal Properties (from Category Theory Framework)

**Source:** Stochastic maps category framework for tokenizer representation

**Key Properties:**

| Property | Definition | Why It Matters |
|----------|------------|----------------|
| **Exactness** | `∀b: decode(encode(b)) = b` | Lossless roundtrip |
| **Injectivity** | Encoder may not assign same tokens to different texts | No collision |
| **Surjectivity** | Decoder must map every token sequence to some text | Complete coverage |
| **Context-invariance** | Tokenization independent of surrounding context | Deterministic |
| **Statistical consistency** | Preserves estimator properties | For ML training |

**Inconsistency sources to test:**
- Non-injective encoders (lowercasing, accent stripping)
- UNK token handling creating non-injectivity
- Boundary effects from pre-tokenization

**Decision:** ✅ INFORM TESTING STRATEGY

These properties guide our property-based tests and differential fuzzing.

---

### 4.1 DFA for BPE (CIAA 2024)

**Paper:** "Constructing a BPE Tokenization DFA" (Berglund et al.)

**What it does:**
- Constructs DFA that recognizes "correct" tokenizations
- Enables equivalence checking between tokenization dictionaries
- Pattern matching on tokenized text
- Formal proofs about tokenizer properties

**Decision:** 📚 RESEARCH / LONG-TERM

**Rationale:**
- Intellectually interesting but complex to implement
- Not needed for Phase 1.5 correctness (differential fuzzing is sufficient)
- Could be valuable for:
  - Detecting when vendors update their vocabularies
  - Proving equivalence after refactoring
  - Academic contributions

**Phase:** Research backlog, no commitment

---

### 4.2 Differential Fuzzing

**Sources:** General fuzzing literature, AdaCore differential fuzzing

**Decision:** ✅ ADOPT IN PHASE 1.5

**Implementation:**
```zig
// Fuzz harness pseudo-code
pub fn fuzz_parity(input: []const u8) void {
    // Our implementation
    const our_tokens = our_tokenizer.encode(input);
    
    // Reference (via Python subprocess or WASM)
    const ref_tokens = tiktoken.encode(input);
    
    // Must be EXACTLY equal
    std.testing.expectEqualSlices(u32, ref_tokens, our_tokens);
}
```

**Already planned:** `zig build fuzz` target exists

---

### 4.3 Property-Based Testing

**Decision:** ✅ ADOPT IN PHASE 1.5

**Properties to test (informed by formal framework):**

| Property | Test | Priority |
|----------|------|----------|
| **Roundtrip (Exactness)** | `decode(encode(text)) == text` | P0 |
| **Injectivity** | Different inputs → different outputs | P1 |
| **No crash** | Any UTF-8 input should not crash | P0 |
| **Deterministic** | Same input always produces same output | P0 |
| **Length bounds** | Output length bounded by input length | P1 |
| **Context-invariance** | `encode(a + b)[0..len(encode(a))] == encode(a)` | P2 |

**Extended properties (Phase 2+):**
- **Monotonicity:** Longer input → at least as many tokens
- **Prefix stability:** Tokenization of prefix is prefix of full tokenization
- **Special token isolation:** Special tokens never merged with regular text

**Implementation:** Part of existing test suite + fuzzing harness

---

## 5. New Features (PHASE 2)

### 5.1 Tokenizer Report

**Command:**
```bash
llm-cost tokenizer-report --model gpt-4o --corpus corpus.txt
```

**Metrics:**
| Metric | Description |
|--------|-------------|
| `bytes_per_token` | Average bytes represented per token |
| `tokens_per_word` | Fertility score |
| `compression_ratio` | Input bytes / output tokens |
| `vocab_utilization` | % of vocab used on corpus |
| `unique_tokens` | Count of distinct tokens produced |

**Phase:** 2

**Effort:** 1 week

---

### 5.2 Scenario Planner

**Command:**
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
  "best_plan": { ... }
}
```

**Phase:** 2

**Effort:** 2 weeks

---

### 5.3 Fairness Analyzer

See section 2.1 above.

**Phase:** 2

**Effort:** 2-3 weeks

---

### 5.4 Policy Checker (`llm-cost check-policy`)

**Research basis:** Cost-as-SLO literature, gateway/routing papers

**What it does:**
Validates usage events against declarative policies and SLOs.

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
    
  - name: "max_output_tokens"
    max_output_tokens: 2048
    
  - name: "cost_cap_per_request"
    max_cost_usd: 0.10
    
  - name: "language_routing"
    match:
      detected_language: ["fr", "de", "es"]
    prefer_models: ["gpt-4o-mini"]  # Better non-English tokenization
    
slos:
  - name: "cost_parity"
    metric: "cost_per_1k_chars"
    max_variance_pct: 20  # Max 20% cost difference across languages
```

**Output:**
```json
{
  "total_events": 10000,
  "violations": [
    {
      "rule": "no_flagship_for_tier_b",
      "count": 23,
      "events": ["evt_123", "evt_456"]
    },
    {
      "rule": "max_tokens_per_call",
      "count": 5,
      "max_observed": 8192
    }
  ],
  "slo_status": {
    "cost_parity": {
      "status": "BREACHED",
      "variance_pct": 34.2,
      "worst_language": "am"
    }
  }
}
```

**Use cases:**
- Gateway policy enforcement
- FinOps governance
- Fairness SLO monitoring
- Cost attribution & chargeback

**Phase:** 2

**Effort:** 2 weeks

---

### 5.5 Cost-as-SLO Framework

**Research basis:** Bleeding edge whitespace - no existing tooling

**Concept:**
Formalize cost as a first-class SLO alongside latency and quality.

```yaml
# Formal cost SLO definition
cost_slo:
  name: "enterprise_tier"
  constraints:
    max_cost_per_1k_requests_usd: 50.00
    max_cost_per_1k_chars_usd: 0.01
    quality_floor: 0.85  # Min quality score
    latency_p99_ms: 2000
  fairness:
    max_language_premium: 2.0  # No language pays >2x English
    report_gini: true
```

**Why this matters:**
- Current state: Cost is billing afterthought, not SLO
- Future state: Cost parity as enforceable contract
- Regulatory angle: Demonstrate fairness to auditors

**Phase:** Research / Phase 3+

**Effort:** 4-6 weeks (requires integration with monitoring)

---

### 5.6 Whitespaces Identified (Future Research)

Based on bleeding edge analysis, these are documented whitespaces:

| Whitespace | Description | llm-cost Relevance |
|------------|-------------|-------------------|
| **Cost Compiler** | Auto-synthesize min-cost semantically-equivalent prompts | High - but requires ML |
| **Joint RAG Planning** | Optimize retrieval + tokenization + model together | Medium - extends `plan` |
| **Multi-tokenizer Profiles** | Per-request tokenizer selection for cost | Medium - Phase 3+ |
| **Tenant-specific Tuning** | Auto-generate cached macro-prompts per tenant | Low - SaaS layer |
| **Hardware-aware Vocab** | Vocab optimized for cache-line/SIMD | Low - we use vendor vocab |

**Explicit non-goals for llm-cost core:**
- We don't synthesize prompts (no ML in core)
- We don't route requests (gateway layer)
- We don't cache (stateless CLI)

These whitespaces inform the *analytics* and *policy* features, not the core tokenizer.

---

## 6. Explicit Exclusions

| Item | Reason | Source |
|------|--------|--------|
| SuperBPE | Changes tokenizer training, breaks parity | Liu et al. 2025 |
| BoundlessBPE | Breaks tiktoken parity | Schmidt et al. 2024 |
| **Parity-Aware BPE** | **Changes training objective, not runtime. We use vendor vocab.** | Bleeding edge 2024-25 |
| **AG-BPE** | **Vocab/merge strategies for runtime - still changes training** | Research 2025 |
| Binary BPE | Wrong domain (executables, not text) | Bommarito 2025 |
| MAGNET | Requires model architecture changes | Ahia et al. 2024 |
| R-BPE caching | Premature optimization for streaming | EMNLP 2025 |
| BlockBPE GPU | Out of scope (GPU dependency) | ICML 2025 |
| LoPT chunking | Only for >1MB files, defer | ArXiv 2025 |
| **Preprocessing transducers** | **SentencePiece-specific (LLAMA2 space markers)** | - |
| **Tenant-specific caching** | **SaaS layer, not CLI tool** | Gateway papers |

**Key insight:**
> Alle tokenizer training innovations (SuperBPE, BoundlessBPE, Parity-Aware BPE, MAGNET, AG-BPE) zijn uitgesloten omdat llm-cost vendor vocabularies gebruikt voor parity. We trainen geen tokenizers; we matchen bestaande exact.

---

## 7. Priority Stack (Updated)

| Priority | Component | Effort | Phase | Decision |
|----------|-----------|--------|-------|----------|
| 1 | Index-based TokenBuffer | 1 dag | **1.5** | ✅ COMMIT |
| 2 | Lazy-delete MergeQueue | 1 dag | **1.5** | ✅ COMMIT |
| 3 | Differential fuzzing | 1 dag | **1.5** | ✅ COMMIT |
| 4 | Property-based tests | 0.5 dag | **1.5** | ✅ COMMIT |
| 5 | Hand-coded pre-tokenizer | 3-5 dagen | **1.5** | ✅ COMMIT |
| 6 | Tokenizer-report command | 1 week | **2** | 🔄 PLANNED |
| 7 | Fairness analyzer | 2-3 weeks | **2** | 🔄 PLANNED |
| 8 | Scenario planner | 2 weeks | **2** | 🔄 PLANNED |
| 9 | **Policy checker** | **2 weeks** | **2** | 🔄 PLANNED |
| 10 | BPE v3 bucket queue | 1-2 weeks | **When needed** | ⏸️ DEFERRED |
| 11 | SIMD pre-tokenizer | 1-2 weeks | **When needed** | ⏸️ DEFERRED |
| 12 | DFA equivalence | 3-4 weeks | **Research** | 📚 BACKLOG |
| 13 | **Cost-as-SLO framework** | **4-6 weeks** | **Phase 3+** | 📚 RESEARCH |

---

## 8. Research References

### Adopted (informing implementation)
1. GitHub bpe crate - linear BPE implementation patterns
2. Token Tax papers - fairness metrics and analysis approach
3. DFA for BPE - formal properties (exactness, injectivity)
4. Differential fuzzing literature - testing methodology
5. **Stochastic maps category framework** - formal tokenizer properties
6. **Parity-Aware BPE** - Gini coefficient, fairness metrics (analysis only)

### Reviewed but not adopted
1. SuperBPE (COLM 2025) - tokenizer training innovation
2. BoundlessBPE (2024) - breaks parity
3. Binary BPE (2025) - wrong domain
4. MAGNET (NeurIPS 2024) - requires model changes
5. BlockBPE (ICML 2025) - GPU-only
6. LoPT (2025) - only for large files
7. **Parity-Aware BPE** - training, not runtime
8. **AG-BPE** - training, not runtime
9. **Preprocessing transducers** - SentencePiece-specific

### For future consideration
1. DFA construction - formal verification
2. SIMD optimization - performance
3. Bucket queue - O(N) complexity
4. **Cost compiler** - requires ML, whitespace
5. **Joint RAG planning** - extends `plan` command

---

## 9. Changelog

| Date | Change |
|------|--------|
| 2025-01 | Initial research decisions document |
| 2025-01 | Added Token Tax analysis, fairness features |
| 2025-01 | Explicit rejection of SuperBPE/BoundlessBPE |
| 2025-01 | **v1.1:** Added check-policy command |
| 2025-01 | **v1.1:** Added Cost-as-SLO framework (research) |
| 2025-01 | **v1.1:** Added Parity-Aware BPE, AG-BPE to exclusions |
| 2025-01 | **v1.1:** Expanded fairness metrics (Gini, MorphScore, Vocab Util) |
| 2025-01 | **v1.1:** Added formal properties section (injectivity, surjectivity) |
| 2025-01 | **v1.1:** Added whitespaces section (cost compiler, joint RAG) |
