# Research Decisions: BPE & Tokenization Literature Review

**Version:** 1.0  
**Date:** 2025-01  
**Status:** FINAL DECISIONS

Dit document bevat de definitieve beslissingen over alle onderzochte research papers en technieken voor llm-cost.

---

## Executive Summary

Na uitgebreid onderzoek van 15+ papers en implementaties zijn dit de kernbeslissingen:

| Categorie | Beslissing | Fase |
|-----------|------------|------|
| BPE Runtime | Index-based TokenBuffer + min-heap | **1.5** ✅ |
| Testing | Differential fuzzing vs tiktoken | **1.5** ✅ |
| Metrics | bytes/token, compression ratio | **1.5** ✅ |
| Fairness Analysis | Token Tax analyzer command | **2** 🔄 |
| Scenario Planning | `llm-cost plan` command | **2** 🔄 |
| BPE v3 | Bucket queue (O(N)) | **When needed** ⏸️ |
| SIMD Pre-tokenizer | Vectorized scanning | **When needed** ⏸️ |
| DFA Equivalence | Formal verification | **Research** 📚 |
| SuperBPE/BoundlessBPE | Alternative tokenizers | **NEVER** ❌ |

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
    "en": { "bytes_per_token": 4.2, "tokens_per_sentence": 12.3, "premium": 1.0 },
    "zh": { "bytes_per_token": 2.1, "tokens_per_sentence": 8.7, "premium": 0.71 },
    "am": { "bytes_per_token": 1.2, "tokens_per_sentence": 45.2, "premium": 3.67 }
  },
  "fairness_metrics": {
    "gini_coefficient": 0.34,
    "max_premium": 3.67,
    "worst_language": "am"
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

**Properties to test:**
1. **Roundtrip:** `decode(encode(text)) == text`
2. **No crash:** Any UTF-8 input should not crash
3. **Deterministic:** Same input always produces same output
4. **Length bounds:** Output length bounded by input length

**Implementation:** Part of existing test suite

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

## 6. Explicit Exclusions

| Item | Reason | Source |
|------|--------|--------|
| SuperBPE | Changes tokenizer training, breaks parity | Liu et al. 2025 |
| BoundlessBPE | Breaks tiktoken parity | Schmidt et al. 2024 |
| Binary BPE | Wrong domain (executables, not text) | Bommarito 2025 |
| MAGNET | Requires model architecture changes | Ahia et al. 2024 |
| R-BPE caching | Premature optimization for streaming | EMNLP 2025 |
| BlockBPE GPU | Out of scope (GPU dependency) | ICML 2025 |
| LoPT chunking | Only for >1MB files, defer | ArXiv 2025 |

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
| 9 | BPE v3 bucket queue | 1-2 weeks | **When needed** | ⏸️ DEFERRED |
| 10 | SIMD pre-tokenizer | 1-2 weeks | **When needed** | ⏸️ DEFERRED |
| 11 | DFA equivalence | 3-4 weeks | **Research** | 📚 BACKLOG |

---

## 8. Research References

### Adopted (informing implementation)
1. GitHub bpe crate - linear BPE implementation patterns
2. Token Tax papers - fairness metrics and analysis approach
3. DFA for BPE - formal properties (exactness, injectivity)
4. Differential fuzzing literature - testing methodology

### Reviewed but not adopted
1. SuperBPE (COLM 2025) - tokenizer training innovation
2. BoundlessBPE (2024) - breaks parity
3. Binary BPE (2025) - wrong domain
4. MAGNET (NeurIPS 2024) - requires model changes
5. BlockBPE (ICML 2025) - GPU-only
6. LoPT (2025) - only for large files

### For future consideration
1. DFA construction - formal verification
2. SIMD optimization - performance
3. Bucket queue - O(N) complexity

---

## 9. Changelog

| Date | Change |
|------|--------|
| 2025-01 | Initial research decisions document |
| 2025-01 | Added Token Tax analysis, fairness features |
| 2025-01 | Explicit rejection of SuperBPE/BoundlessBPE |
