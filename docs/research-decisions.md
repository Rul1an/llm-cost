# Research Decisions: BPE & Tokenization Literature Review
Version: 1.2
Date: 2025-01
Status: FINAL DECISIONS (BPE v2.1 VERIFIED)
Dit document bevat de definitieve beslissingen over alle onderzochte research papers en technieken voor llm-cost.

## Executive Summary
Na uitgebreid onderzoek van 15+ papers en implementaties zijn dit de kernbeslissingen:

| Categorie | Beslissing | Fase |
|---|---|---|
| **BPE Runtime** | Index-based TokenBuffer + min-heap | 1.5 ✅ |
| **Testing** | Differential fuzzing vs tiktoken | 1.5 ✅ |
| **Formal Properties** | Injectivity, exactness, context-invariance | 1.5 ✅ |
| **Metrics** | bytes/token, compression ratio, Gini | 1.5 ✅ |
| **Fairness Analysis** | Token Tax analyzer command | 2 🔄 |
| **Scenario Planning** | llm-cost plan command | 2 🔄 |
| **Policy Checker** | llm-cost check-policy command | 2 🔄 |
| **BPE v3** | Bucket queue (O(N)) | When needed ⏸️ |
| **SIMD Pre-tokenizer** | Vectorized scanning | When needed ⏸️ |
| **Cost-as-SLO** | Formal cost SLO framework | Phase 3+ 📚 |
| **DFA Equivalence** | Formal verification | Research 📚 |
| **SuperBPE/BoundlessBPE/Parity-Aware** | Training innovations | NEVER ❌ |

## 1. BPE Training Innovations (NOT ADOPTING)

### 1.1 SuperBPE (COLM 2025)
*Paper: "SuperBPE: Space Travel for Language Models" (Liu et al., March 2025)*

**Decision: ❌ NOT ADOPTING**
Rationale:
*   SuperBPE changes how the tokenizer is trained, not how it runs.
*   llm-cost uses vendor vocabularies (tiktoken) - we don't train tokenizers.
*   Adopting SuperBPE would break parity with OpenAI models.

**What we CAN use:**
*   Metrics from paper: bytes/token, compression ratio, vocab utilization.

### 1.2 BoundlessBPE (2024)
*Paper: "Boundless Byte Pair Encoding: Breaking the Pre-tokenization Barrier"*

**Decision: ❌ EXPLICITLY REJECTED**
Rationale:
*   **BREAKS TIKTOKEN PARITY** - produces different token sequences.
*   Directly contradicts core value prop: exact match with OpenAI.

### 1.3 Binary BPE (Nov 2025)
**Decision: ❌ NOT RELEVANT** (Wrong domain).

### 1.4 MAGNET (NeurIPS 2024)
**Decision: ❌ NOT ADOPTING** (Requires model architecture changes).
**What we CAN use:** Fairness metrics informed our P2 features.

---

## 2. Token Tax & Fairness Analysis (ADOPTING)

### 2.1 Token Tax Papers (2023-2025)
**Key Findings:** Non-English languages require 2-15x more tokens. "A doubling in tokens results in quadrupled training cost."

**Decision: ✅ ADOPT AS ANALYSIS FEATURE**

**Fairness Metrics (from research):**
*   **Tokenization Parity (TP)**: `tokens(lang_L) / tokens(English)`
*   **Gini Coefficient**: Distribution inequality of per-language costs.
*   **Vocabulary Utilization**: Fraction of vocab actually used per language.
*   **UniversalToken Premium**: Cost multiplier vs English baseline.

**Implementation:**
```bash
# New command: llm-cost analyze-fairness
llm-cost analyze-fairness --corpus corpus.toml --models gpt-4o --format json
```

**Phase:** 2 (after Phase 1.5 foundation)
**Effort:** 2-3 weeks

---

## 3. Runtime Optimizations (ADOPTING)

### 3.1 Index-Based TokenBuffer
**Decision: ✅ ADOPT IN PHASE 1.5** (Verified in v0.6.0).

### 3.2 Lazy-Delete MergeQueue
**Decision: ✅ ADOPT IN PHASE 1.5** (Verified in v0.6.0).

### 3.3 BPE v3 Bucket Queue
**Decision: ⏸️ DEFER (trigger-based)**
*   Trigger: Benchmarks show BPE >50% of total runtime.
*   Implementation sketch: `BucketQueue` with O(1) ops.

### 3.4 SIMD Pre-tokenizer
**Decision: ⏸️ DEFER (trigger-based)**
*   Trigger: Pre-tokenizer >30% of total runtime.

---

## 4. Formal Verification & Testing (PARTIALLY ADOPTING)

### 4.0 Formal Properties
**Decision: ✅ INFORM TESTING STRATEGY**
Properties: Roundtrip (Exactness), Injectivity, Determinism.

### 4.1 DFA for BPE (CIAA 2024)
**Decision: 📚 RESEARCH / LONG-TERM**

### 4.2 Differential Fuzzing
**Decision: ✅ ADOPT IN PHASE 1.5** (Done via `test-parity`).

---

## 5. New Features (PHASE 2)

### 5.1 Tokenizer Report
**Phase:** 2 (Completed in v0.6.0).

### 5.2 Scenario Planner
**Command**: `llm-cost plan`
**Phase**: 2
**Effort**: 2 weeks

### 5.3 Fairness Analyzer
**Command**: `llm-cost analyze-fairness`
**Phase**: 2
**Effort**: 2-3 weeks

### 5.4 Policy Checker
**Command**: `llm-cost check-policy`
**Phase**: 2
**Effort**: 2 weeks

---

## 6. Explicit Exclusions
(See Executive Summary table)

## 7. Priority Stack (Updated)

| Priority | Component | Effort | Phase | Decision |
|---|---|---|---|---|
| 1 | Index-based TokenBuffer | 1 dag | 1.5 | ✅ VERIFIED |
| 2 | Lazy-delete MergeQueue | 1 dag | 1.5 | ✅ VERIFIED |
| 3 | Differential fuzzing | 1 dag | 1.5 | ✅ COMMIT |
| 4 | Property-based tests | 0.5 dag | 1.5 | ✅ COMMIT |
| 5 | Hand-coded pre-tokenizer | 3-5 dagen | 1.5 | ✅ COMMIT |
| 6 | Tokenizer-report command | 1 week | 2 | ✅ COMPLETED |
| 7 | **Fairness analyzer** | 2-3 weeks | 2 | 🔄 PLANNED |
| 8 | **Scenario planner** | 2 weeks | 2 | 🔄 PLANNED |
| 9 | **Policy checker** | 2 weeks | 2 | 🔄 PLANNED |
| 10 | BPE v3 bucket queue | 1-2 weeks | When needed | ⏸️ DEFERRED |
| 11 | SIMD pre-tokenizer | 1-2 weeks | When needed | ⏸️ DEFERRED |
