# design: Fairness Analyzer (Phase 2.2)

**Version:** 2.0 (Refined)
**Date:** 2025-12-10
**Status:** Approved for Implementation

## 1. Objective
Implement `llm-cost analyze-fairness` (Phase 2.2) to quantify **"Token Tax"** disparities across languages using SOTA metrics.
*   **Input**: `corpus.json` (Multi-language dataset definition).
*   **Output**: JSON report with Gini, Parity Ratios, and Fertility scores.

## 2. Terminology & Metrics

### 2.1 Primary Metrics
| Metric | Definition | Purpose |
|---|---|---|
| **Fertility** ($F$) | $\frac{\text{Token Count}}{\text{Word Count}}$ | Efficiency. Lower is better. |
| **Parity Ratio** ($PR$) | $\frac{F_{lang}}{F_{baseline}}$ | "Tax" multiplier. $1.0$ = Perfect. |
| **Gini Coefficient** ($G$) | Dispersion of $PR$. | $0.0$ = Equal Tax, $1.0$ = Max Inequality. |

### 2.2 Word Counting Strategy
Defining "Word" is language-dependent.
*   **Western (whitespace)**: `split(whitespace).len`
*   **CJK (character-based)**: `utf8_codepoint_count` (Proxy) or `utf8_count * 0.6` (Heuristic).
*   **Architecture**: `WordCountMode` enum (`whitespace`, `character`, `heuristic`).

## 3. Architecture

### 3.1 Data Flow
```ascii
[User] -> CLI (analyze-fairness) -> [CorpusLoader] -> [FairnessAnalyzer] -> [MetricsEngine] -> JSON Output
```

### 3.2 Configuration (`corpus.json`)
Using JSON for standard library compatibility.

```json
{
  "meta": {
    "name": "Research-Corpus-v1",
    "version": "1.0",
    "baseline_lang": "en"
  },
  "languages": {
    "en": {
      "name": "English",
      "path": "data/fairness/en.txt",
      "word_count_mode": "whitespace"
    },
    "zh": {
      "name": "Chinese",
      "path": "data/fairness/zh.txt",
      "word_count_mode": "character"
    },
    "ar": {
      "name": "Arabic",
      "path": "data/fairness/ar.txt",
      "word_count_mode": "whitespace"
    }
  }
}
```

## 4. Implementation Details

### 4.1 Module Structure (`src/analytics/`)
*   `mod.zig`: Exports.
*   `metrics.zig`: Pure math (`calculateGini`, `calculateFertility`).
*   `word_count.zig`: Counting strategies.
*   `corpus.zig`: JSON parser and file loader (Streaming line-reader).
*   `fairness.zig`: Orchestrator.

### 4.2 Gini Algorithm
Standard implementation for sorted ratios:
$$G = \frac{2 \sum_{i=1}^n i y_i}{n \sum y_i} - \frac{n+1}{n}$$
*(Where $y_i$ are parities sorted ascending)*

## 5. Output Schema
```json
{
  "meta": {
    "model": "gpt-4o",
    "baseline": "en"
  },
  "summary": {
    "gini_coefficient": 0.23,
    "max_parity_ratio": 1.76,
    "worst_language": "ar"
  },
  "languages": {
    "en": { "fertility": 1.25, "parity_ratio": 1.00, "word_count": 10000, "token_count": 12500 },
    "zh": { "fertility": 1.80, "parity_ratio": 1.44, "word_count": 10000, "token_count": 18000 },
    "ar": { "fertility": 2.20, "parity_ratio": 1.76, "word_count": 10000, "token_count": 22000 }
  }
}
```

## 6. CLI Contract
```bash
# Analyze fairness using corpus config
llm-cost analyze-fairness --corpus corpus.json --model gpt-4o

# (Future) Compare models
llm-cost analyze-fairness --corpus corpus.json --models gpt-4o,cl100k
```
