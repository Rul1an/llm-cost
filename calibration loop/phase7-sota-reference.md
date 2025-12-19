# Phase 7: SOTA Techniques Reference Card

Quick reference for bleeding-edge techniques applied in v1.9.0 Calibration Loop.

---

## 1. Welford's Algorithm (1962, Knuth TAOCP)

**Problem**: Naive variance computation suffers from catastrophic cancellation.

**Solution**: Single-pass, numerically stable online algorithm.

```python
# Naive (BAD - loses precision)
mean = sum(x) / n
variance = sum((x - mean)**2) / (n-1)  # Requires two passes!

# Welford (GOOD - single pass, stable)
M = 0
S = 0
for k, x in enumerate(data, 1):
    oldM = M
    M = M + (x - M) / k
    S = S + (x - M) * (x - oldM)
variance = S / (n - 1)
```

**Key Properties**:
- O(1) memory per statistic
- O(n) time total, O(1) per update
- Numerically stable for large mean + small variance
- Parallelizable via Chan et al. merge formula

**Our Use**: Streaming cost aggregation for 1M+ records.

---

## 2. Chan's Parallel Merge (1979)

**Problem**: Welford is sequential. How to merge partial results?

**Solution**: Combine statistics from arbitrary sets.

```python
def parallel_merge(n_a, mean_a, m2_a, n_b, mean_b, m2_b):
    n = n_a + n_b
    delta = mean_b - mean_a
    mean = mean_a + delta * n_b / n
    m2 = m2_a + m2_b + delta**2 * n_a * n_b / n
    return n, mean, m2
```

**Key Properties**:
- Merge in any order (associative)
- Exact result as if processed sequentially
- Enables multi-threaded aggregation

**Our Use**: Merge statistics from multiple CSV files.

---

## 3. Reconditionor (KDD 2024)

**Paper**: "Calibration of Time-Series Forecasting: Detecting and Adapting Context-Driven Distribution Shift"

**Problem**: Models produce unbiased estimates globally, but biased within contexts.

**Solution**: Detect bias via mutual information between residuals and context.

```python
# Residual = Actual - Predicted
residuals = actuals - predictions

# Reconditionor score = MI(residuals, context)
# High score = model vulnerable to context-driven shift
score = mutual_information(residuals, context_labels)

if score > threshold:
    needs_adaptation = True
```

**Key Insight**: 
- Global mean residual ≈ 0 (unbiased overall)
- Per-context residual ≠ 0 (biased within segments)

**Our Use**: Detect which parameters (cache ratio, token count) are drifting.

---

## 4. SOLID Adaptation (KDD 2024)

**Paper**: Same as Reconditionor.

**Problem**: How to correct for detected drift?

**Solution**: Sample-level contextualized adapter with bias-variance tradeoff.

```python
# 1. Find samples similar to current context
similar_samples = find_contextually_similar(test_sample, training_data)

# 2. Fine-tune prediction layer (not full model)
adapter = finetune(
    model.prediction_layer,  # Only last layer
    similar_samples,
    steps=few  # Limited steps to avoid variance explosion
)

# 3. Apply correction
corrected_prediction = adapter(test_sample)
```

**Key Insight**:
- Full retraining = high variance, unstable
- No adaptation = high bias, systematic error
- SOLID = optimal tradeoff (few steps, last layer only)

**Our Use**: Correct parameter assumptions based on observed data.

---

## 5. RouteLLM (ICLR 2025)

**Paper**: "RouteLLM: Learning to Route LLMs with Preference Data"

**Problem**: GPT-4 quality but Mixtral price?

**Solution**: Learn when cheap model suffices from preference data.

```python
# Router predicts: P(strong model wins | query)
win_rate = router.predict(query)

if win_rate > threshold:
    response = strong_model(query)  # GPT-4
else:
    response = weak_model(query)    # Mixtral
```

**Key Results**:
- MT Bench: 85% cost reduction @ 95% quality
- MMLU: 45% cost reduction
- GSM8K: 35% cost reduction

**Router Types**:
1. **SW Ranking**: Similarity-weighted Elo
2. **Matrix Factorization**: Learn scoring function
3. **BERT Classifier**: Fine-tuned on preferences
4. **Causal LLM**: LLM-based classifier

**Our Use**: Recommend model switches based on usage patterns.

---

## 6. FrugalGPT Cascade (TMLR 2024)

**Paper**: "FrugalGPT: How to Use Large Language Models While Reducing Cost and Improving Performance"

**Problem**: Even better than routing — use multiple models in sequence.

**Solution**: Query cheap first, escalate if unsatisfactory.

```python
models = [cheap, medium, expensive]  # Sorted by cost

for model in models:
    response = model(query)
    score = scorer.evaluate(query, response)
    
    if score >= model.threshold:
        return response  # Good enough!

return expensive(query)  # Fallback
```

**Key Results**:
- HEADLINES: 80% cost reduction + 1.5% accuracy gain vs GPT-4
- MPI (Maximum Performance Improvement): 6% of queries where cheap > expensive

**Our Use**: Future v2.0 cascade optimization.

---

## 7. FOCUS 1.2 (FinOps Foundation 2025)

**Standard**: FinOps Open Cost and Usage Specification

**Problem**: Every cloud provider has different billing format.

**Solution**: Unified schema for multi-cloud cost analysis.

```
FOCUS 1.2 Required Columns:
├── BilledCost      # What you pay
├── UsageQuantity   # How much used
└── ResourceId      # What resource

FOCUS 1.2 New in 1.2:
├── InvoiceId       # For reconciliation
├── SaaS support    # Not just IaaS
└── PaaS support    # Platform services
```

**llm-cost Extensions** (x-llm-* namespace):
```
x-llm-model         # gpt-4o, claude-3-opus
x-llm-input-tokens  # 1234
x-llm-output-tokens # 567
x-llm-cached-tokens # 890
x-llm-prompt-id     # unique identifier
```

**Our Use**: Import actuals from any FOCUS-compliant source.

---

## 8. Confidence Tokens / Self-REF (ICML 2025)

**Paper**: "Learning to Route LLMs with Confidence Tokens"

**Problem**: How to know if LLM answer is reliable?

**Solution**: Train model to output confidence token.

```python
# Standard LLM
response = model("What is 2+2?")  # "4"

# Self-REF enhanced
response, confidence = model_with_ref("What is 2+2?")
# response = "4"
# confidence = 0.99

if confidence < threshold:
    response = stronger_model(query)
```

**Key Insight**:
- Verbalizing confidence is unreliable
- Token probabilities are poorly calibrated
- Confidence tokens (trained) are reliable

**Our Use**: Future v2.0 quality-aware routing.

---

## Quick Comparison

| Technique | Memory | Time | When to Use |
|-----------|--------|------|-------------|
| Welford | O(1) | O(n) | Streaming stats |
| Chan Merge | O(1) | O(1) | Parallel processing |
| Reconditionor | O(1) | O(n) | Drift detection |
| RouteLLM | O(model) | O(1) | Query routing |
| FrugalGPT | O(models) | O(k) | Cascade routing |
| Confidence | O(model) | O(1) | Quality estimation |

---

## Implementation Priority

| Phase 7 (v1.9) | Phase 8+ (v2.0) |
|----------------|-----------------|
| ✅ Welford | ◻️ RouteLLM full |
| ✅ Chan Merge | ◻️ Confidence tokens |
| ✅ Reconditionor | ◻️ FrugalGPT cascade |
| ✅ FOCUS 1.2 | ◻️ PROCEED proactive |
| ✅ SOLID-inspired | ◻️ Quality benchmarks |

---

## References

```
@inproceedings{welford1962,
  author = {Welford, B. P.},
  title = {Note on a method for calculating corrected sums of squares and products},
  journal = {Technometrics},
  year = {1962}
}

@article{chan1979,
  author = {Chan, Tony F. and Golub, Gene H. and LeVeque, Randall J.},
  title = {Updating Formulae and a Pairwise Algorithm for Computing Sample Variances},
  year = {1979}
}

@inproceedings{chen2024calibration,
  title = {Calibration of Time-Series Forecasting: Detecting and Adapting Context-Driven Distribution Shift},
  author = {Chen, Mouxiang and others},
  booktitle = {KDD},
  year = {2024}
}

@inproceedings{ong2025routellm,
  title = {RouteLLM: Learning to Route LLMs with Preference Data},
  author = {Ong, Isaac and others},
  booktitle = {ICLR},
  year = {2025}
}

@article{chen2024frugalgpt,
  title = {FrugalGPT: How to Use Large Language Models While Reducing Cost and Improving Performance},
  author = {Chen, Lingjiao and Zaharia, Matei and Zou, James},
  journal = {TMLR},
  year = {2024}
}

@inproceedings{chuang2025confidence,
  title = {Learning to Route LLMs with Confidence Tokens},
  author = {Chuang, Yu-Neng and others},
  booktitle = {ICML},
  year = {2025}
}
```
