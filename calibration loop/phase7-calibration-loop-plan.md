# Phase 7: Calibration Loop — SOTA Design Document

**Version**: 1.0  
**Date**: December 2025  
**Status**: PLANNING  
**Predecessor**: Phase 6/PR3 Metamorphic Testing ✅  

---

## Executive Summary

Phase 7 implements the **Calibration Loop** — a closed-loop feedback system that compares llm-cost estimates against actual billing data, detects systematic drift, and provides actionable recommendations. This transforms llm-cost from a *prediction tool* into a *continuous improvement system*.

**Industry Context (December 2025)**:
- FinOps Foundation launched "FinOps Certified: FinOps for AI" certification
- FOCUS 1.2 now covers SaaS/PaaS with invoice reconciliation fields
- AWS extended forecasting to 18 months with AI-powered explanations
- Microsoft achieved 99% revenue forecast accuracy with FINN framework
- RouteLLM (ICLR 2025) demonstrates 85% cost reduction via intelligent routing

---

## Part 1: Research Foundation

### 1.1 Academic Papers (2024-2025)

| Paper | Venue | Key Insight | Applicability |
|-------|-------|-------------|---------------|
| **RouteLLM** | ICLR 2025 | Preference-based router training, 85% cost reduction | Model recommendations |
| **FrugalGPT** | TMLR 2024 | LLM cascade with scoring function, 98% cost reduction | Tiered routing |
| **Reconditionor** | KDD 2024 | Residual-based drift detection via mutual information | Drift detection |
| **SOLID** | KDD 2024 | Sample-level contextualized adaptation, bias-variance tradeoff | Calibration |
| **PROCEED** | KDD 2025 | Proactive model adaptation for concept drift | Online learning |
| **Confidence Tokens** | ICML 2025 | Self-REF for reliable uncertainty quantification | Quality routing |
| **xRouter** | arXiv 2025 | RL-based cost-aware orchestration | Future extension |

### 1.2 Industry Standards

| Standard | Version | Relevance |
|----------|---------|-----------|
| **FOCUS** | 1.2 (June 2025) | Invoice reconciliation, SaaS/PaaS unified schema |
| **FinOps for AI** | 1.0 (June 2025) | AI cost governance certification requirements |
| **AWS Forecasting** | 18-month (Dec 2025) | AI explanations, confidence intervals |

### 1.3 Key Metrics from Research

```
RouteLLM Performance:
├── MT Bench: 85% cost reduction @ 95% GPT-4 quality
├── MMLU: 45% cost reduction
└── GSM8K: 35% cost reduction

FrugalGPT Cascade:
├── HEADLINES: 80% cost reduction, +1.5% accuracy vs GPT-4
└── MPI (Maximum Performance Improvement): 6% queries where cheap model > expensive

Reconditionor Drift Detection:
├── Metric: Mutual Information between residuals and context
├── Threshold: High score → requires adaptation
└── Overhead: O(1) per sample via streaming
```

---

## Part 2: Architecture

### 2.1 Offline-First Design (Preserving Security Posture)

```
┌─────────────────────────────────────────────────────────────────┐
│                    llm-cost (Core Binary)                        │
│  ✓ Offline        ✓ No credentials      ✓ Air-gapped safe       │
├─────────────────────────────────────────────────────────────────┤
│  llm-cost calibrate --estimates est.json --actuals actuals.csv  │
│  llm-cost calibrate --apply  (auto-update llm-cost.toml)        │
└─────────────────────────────────────────────────────────────────┘
                              ↑
                              │ FOCUS CSV
                              │
┌─────────────────────────────────────────────────────────────────┐
│              llm-cost-fetch (Optional Binary)                    │
│  ✗ Requires network    ✗ Stores API keys    ✗ Calls APIs        │
├─────────────────────────────────────────────────────────────────┤
│  llm-cost-fetch langfuse --output actuals.csv                   │
│  llm-cost-fetch helicone --output actuals.csv                   │
│  llm-cost-fetch openai-usage --output actuals.csv               │
└─────────────────────────────────────────────────────────────────┘
```

### 2.2 Module Architecture

```
src/calibration/
├── mod.zig                 # Public API
├── types.zig               # MicroUSD, BasisPoints, CalibrationResult
├── stats.zig               # WelfordAccumulator, ParallelVariance
├── focus_import.zig        # FOCUS 1.2 streaming CSV parser
├── drift.zig               # Reconditionor-inspired drift detection
├── recommendations.zig     # RouteLLM-inspired model routing
└── output.zig              # TOML/JSON/Markdown formatters

src/fetch/                  # SEPARATE BINARY (optional)
├── main.zig
├── langfuse.zig
├── helicone.zig
└── openai_usage.zig
```

### 2.3 Data Flow

```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│  estimates   │     │   actuals    │     │  pricing_db  │
│  (JSON)      │     │  (FOCUS CSV) │     │  (JSON)      │
└──────┬───────┘     └──────┬───────┘     └──────┬───────┘
       │                    │                    │
       └────────────┬───────┴────────────────────┘
                    ▼
         ┌──────────────────────┐
         │   Streaming Parser   │  ← O(line_length) memory
         │   + Welford Stats    │  ← O(1) per update
         └──────────┬───────────┘
                    ▼
         ┌──────────────────────┐
         │   Drift Detection    │  ← Reconditionor-inspired
         │   (per-parameter)    │
         └──────────┬───────────┘
                    ▼
         ┌──────────────────────┐
         │   Recommendations    │  ← RouteLLM-inspired
         │   (cost-only v1.8)   │
         └──────────┬───────────┘
                    ▼
         ┌──────────────────────┐
         │   Output Generation  │  ← TOML/JSON/Markdown
         │   (deterministic)    │
         └──────────────────────┘
```

---

## Part 3: Core Algorithms

### 3.1 Streaming Statistics (Welford's Algorithm)

Based on Welford 1962, Knuth TAOCP Vol.2, Chan et al. parallel extension.

```zig
/// Numerically stable online variance computation
/// Memory: O(1), Time: O(n) total, O(1) per update
pub const WelfordAccumulator = struct {
    count: u64 = 0,
    mean: f64 = 0,
    m2: f64 = 0,           // Sum of squared deviations
    min: f64 = std.math.inf(f64),
    max: f64 = -std.math.inf(f64),
    
    /// Update with new value (Welford's recurrence)
    pub fn update(self: *WelfordAccumulator, value: f64) void {
        self.count += 1;
        const delta = value - self.mean;
        self.mean += delta / @as(f64, @floatFromInt(self.count));
        const delta2 = value - self.mean;
        self.m2 += delta * delta2;
        self.min = @min(self.min, value);
        self.max = @max(self.max, value);
    }
    
    /// Sample variance (Bessel's correction)
    pub fn variance(self: WelfordAccumulator) f64 {
        if (self.count < 2) return 0;
        return self.m2 / @as(f64, @floatFromInt(self.count - 1));
    }
    
    /// Standard error of the mean
    pub fn sem(self: WelfordAccumulator) f64 {
        if (self.count < 2) return std.math.inf(f64);
        return @sqrt(self.variance()) / @sqrt(@as(f64, @floatFromInt(self.count)));
    }
    
    /// 95% confidence interval
    pub fn ci95(self: WelfordAccumulator) [2]f64 {
        const z = 1.96;
        const s = self.sem();
        return .{ self.mean - z * s, self.mean + z * s };
    }
    
    /// Parallel merge (Chan et al. algorithm)
    /// Allows splitting work across multiple threads/files
    pub fn merge(self: *WelfordAccumulator, other: WelfordAccumulator) void {
        if (other.count == 0) return;
        
        const n_ab = self.count + other.count;
        const delta = other.mean - self.mean;
        
        self.mean = self.mean + delta * @as(f64, @floatFromInt(other.count)) / 
                    @as(f64, @floatFromInt(n_ab));
        self.m2 = self.m2 + other.m2 + 
                  delta * delta * @as(f64, @floatFromInt(self.count)) * 
                  @as(f64, @floatFromInt(other.count)) / @as(f64, @floatFromInt(n_ab));
        self.count = n_ab;
        self.min = @min(self.min, other.min);
        self.max = @max(self.max, other.max);
    }
};
```

### 3.2 Drift Detection (Reconditionor-Inspired)

Based on KDD 2024 paper: detect context-driven distribution shift via residual analysis.

```zig
/// Drift detector using residual-context mutual information
/// Adapted from Reconditionor (Chen et al., KDD 2024)
pub const DriftDetector = struct {
    /// Per-parameter drift tracking
    parameters: std.StringHashMap(ParameterDrift),
    
    /// Global drift metrics
    total_estimated: MicroUSD = 0,
    total_actual: MicroUSD = 0,
    residual_stats: WelfordAccumulator = .{},
    
    /// Compute drift for a single parameter
    pub fn computeParameterDrift(
        assumed: f64,
        observed: WelfordAccumulator,
    ) ParameterDrift {
        const drift_absolute = observed.mean - assumed;
        const drift_relative = if (assumed != 0) drift_absolute / assumed else 0;
        
        // Confidence based on sample size and variance
        const confidence: ConfidenceLevel = blk: {
            if (observed.count >= 500 and observed.sem() / @abs(observed.mean) < 0.10) {
                break :blk .high;
            } else if (observed.count >= 100) {
                break :blk .medium;
            } else {
                break :blk .low;
            }
        };
        
        const ci = observed.ci95();
        
        return .{
            .assumed = assumed,
            .observed_mean = observed.mean,
            .observed_std = @sqrt(observed.variance()),
            .drift_bps = @intFromFloat(drift_relative * 10000),
            .confidence = confidence,
            .ci_lower = ci[0],
            .ci_upper = ci[1],
            .sample_count = observed.count,
        };
    }
    
    /// Reconditionor score: quantifies model vulnerability to CDS
    /// Higher score = more susceptible to context-driven shift
    pub fn reconditionorScore(self: DriftDetector) f64 {
        // Simplified: use coefficient of variation of residuals
        // Full implementation would use MI estimation
        if (self.residual_stats.count < 10) return 0;
        
        const cv = @sqrt(self.residual_stats.variance()) / 
                   @abs(self.residual_stats.mean + 1e-10);
        return @min(1.0, cv);
    }
};

pub const ParameterDrift = struct {
    name: []const u8,
    assumed: f64,
    observed_mean: f64,
    observed_std: f64,
    drift_bps: i32,          // Basis points
    confidence: ConfidenceLevel,
    ci_lower: f64,
    ci_upper: f64,
    sample_count: u64,
};

pub const ConfidenceLevel = enum {
    high,    // ≥500 samples, CV < 10%
    medium,  // ≥100 samples
    low,     // <100 samples
};
```

### 3.3 Model Recommendations (RouteLLM-Inspired)

Based on RouteLLM (ICLR 2025) and FrugalGPT (TMLR 2024).

```zig
/// Cost-only model recommendations (quality scoring deferred to v2.0)
/// Inspired by RouteLLM's preference-based routing
pub const ModelRecommender = struct {
    pricing_db: *const PricingDb,
    
    /// Recommend cheaper alternatives for a given model
    pub fn recommendAlternatives(
        self: ModelRecommender,
        current_model: []const u8,
        observed_usage: UsagePattern,
    ) []const Recommendation {
        var recommendations = std.ArrayList(Recommendation).init(self.allocator);
        
        const current_price = self.pricing_db.getPrice(current_model);
        
        // Find models in same family (quality-preserving)
        for (self.pricing_db.models()) |candidate| {
            if (std.mem.eql(u8, candidate.id, current_model)) continue;
            
            const candidate_price = self.pricing_db.getPrice(candidate.id);
            const savings_bps = computeSavings(current_price, candidate_price, observed_usage);
            
            if (savings_bps > 100) { // > 1% savings
                recommendations.append(.{
                    .model = candidate.id,
                    .savings_bps = savings_bps,
                    .quality_impact = classifyQualityImpact(current_model, candidate.id),
                    .rationale = generateRationale(current_model, candidate.id, savings_bps),
                }) catch continue;
            }
        }
        
        // Sort by savings (descending)
        std.sort.sort(Recommendation, recommendations.items, {}, 
            struct { fn cmp(a: Recommendation, b: Recommendation) bool {
                return a.savings_bps > b.savings_bps;
            }}.cmp);
        
        return recommendations.toOwnedSlice();
    }
    
    fn classifyQualityImpact(from: []const u8, to: []const u8) QualityImpact {
        // Simple heuristic: same family = likely similar quality
        // Full implementation would use benchmark data
        if (isSameFamily(from, to)) return .same_family;
        return .unknown;
    }
};

pub const Recommendation = struct {
    model: []const u8,
    savings_bps: i32,        // Basis points savings
    quality_impact: QualityImpact,
    rationale: []const u8,
};

pub const QualityImpact = enum {
    unknown,          // No quality data available
    same_family,      // e.g., gpt-4o → gpt-4o-mini
    different_family, // e.g., gpt-4o → claude-3-haiku
    
    pub fn toString(self: QualityImpact) []const u8 {
        return switch (self) {
            .unknown => "Quality impact unknown - benchmark before switching",
            .same_family => "Same model family - likely similar quality",
            .different_family => "Different family - evaluate on your specific tasks",
        };
    }
};
```

### 3.4 FOCUS 1.2 Import (Streaming)

```zig
/// FOCUS 1.2 compliant streaming CSV parser
/// Memory: O(line_length), handles 1M+ records
pub const FocusParser = struct {
    reader: std.io.AnyReader,
    line_buffer: []u8,           // 64KB buffer
    column_indices: ColumnIndices,
    row_count: u64 = 0,
    
    /// FOCUS 1.2 Required columns (MUST be present)
    pub const Required = struct {
        BilledCost: MicroUSD,
        UsageQuantity: u64,
        ResourceId: []const u8,
    };
    
    /// FOCUS 1.2 Recommended columns (MAY be present)
    pub const Recommended = struct {
        EffectiveCost: ?MicroUSD = null,
        InvoiceId: ?[]const u8 = null,           // NEW in 1.2
        ChargeCategory: ?[]const u8 = null,
        UsageUnit: ?[]const u8 = null,
    };
    
    /// llm-cost extension columns (x-llm-* namespace)
    pub const Extension = struct {
        @"x-llm-model": ?[]const u8 = null,
        @"x-llm-input-tokens": ?u64 = null,
        @"x-llm-output-tokens": ?u64 = null,
        @"x-llm-cached-tokens": ?u64 = null,
        @"x-llm-prompt-id": ?[]const u8 = null,
    };
    
    /// Parse next record (streaming)
    pub fn next(self: *FocusParser) !?FocusRecord {
        const line = self.reader.readUntilDelimiter(self.line_buffer, '\n') 
            catch |err| switch (err) {
                error.EndOfStream => return null,
                else => return err,
            };
        
        self.row_count += 1;
        return try self.parseRow(line);
    }
    
    /// Validate required columns exist
    pub fn validateSchema(self: *FocusParser) !void {
        if (self.column_indices.BilledCost == null)
            return error.MissingRequiredColumn;
        if (self.column_indices.UsageQuantity == null)
            return error.MissingRequiredColumn;
        if (self.column_indices.ResourceId == null)
            return error.MissingRequiredColumn;
    }
};
```

---

## Part 4: CLI Interface

### 4.1 Command Specification

```bash
# Basic calibration
llm-cost calibrate \
  --estimates estimates.json \
  --actuals actuals.csv \
  --format toml

# With thresholds (exit codes for CI)
llm-cost calibrate \
  --estimates estimates.json \
  --actuals actuals.csv \
  --warn-threshold 500 \      # 5% drift = warning
  --error-threshold 1000 \    # 10% drift = error
  --format json

# Auto-apply corrections
llm-cost calibrate \
  --estimates estimates.json \
  --actuals actuals.csv \
  --apply                     # Update llm-cost.toml

# With model recommendations
llm-cost calibrate \
  --estimates estimates.json \
  --actuals actuals.csv \
  --recommend                 # Include cost-saving suggestions
```

### 4.2 Exit Codes

```
0   Success, drift within acceptable range
1   Warning: drift exceeds --warn-threshold
2   Error: drift exceeds --error-threshold
10  Invalid estimates file
11  Invalid actuals file  
12  Missing required FOCUS column
13  Insufficient samples (<10)
20  I/O error
21  Pricing DB error
```

### 4.3 Output Formats

**TOML (default)**:
```toml
[summary]
estimated_total = "$10,000.00"
actual_total = "$15,230.00"
drift_absolute = "$5,230.00"
drift_bps = 5230
confidence = "high"
sample_count = 12847
time_span_days = 30

[parameters.cache_hit_ratio]
assumed = 0.60
observed = 0.28
drift_bps = -5333
confidence = "high"
ci_95 = [0.25, 0.31]
recommendation = "Update cache_hit_ratio to 0.28 in llm-cost.toml"

[parameters.avg_output_tokens]
assumed = 500
observed = 847
drift_bps = 6940
confidence = "high"
ci_95 = [812, 882]
recommendation = "Update avg_output_tokens to 847 in llm-cost.toml"

[[recommendations]]
model = "gpt-4o-mini"
current_model = "gpt-4o"
savings_bps = 9500  # 95% cheaper
quality_impact = "same_family"
rationale = "Same model family, evaluate on your specific tasks"
```

**JSON** (machine-readable):
```json
{
  "version": "1.8.0",
  "timestamp": "2025-12-18T12:00:00Z",
  "summary": {
    "estimated_total_micro": 10000000000,
    "actual_total_micro": 15230000000,
    "drift_absolute_micro": 5230000000,
    "drift_bps": 5230,
    "confidence": "high",
    "sample_count": 12847,
    "time_span_days": 30
  },
  "parameters": [...],
  "recommendations": [...]
}
```

**Markdown** (for PR comments):
```markdown
## 📊 llm-cost Calibration Report

| Metric | Estimated | Actual | Drift |
|--------|-----------|--------|-------|
| Total Cost | $10,000.00 | $15,230.00 | **+52.30%** ⚠️ |

### Parameter Drift Detected

| Parameter | Assumed | Observed | Drift | Confidence |
|-----------|---------|----------|-------|------------|
| cache_hit_ratio | 60% | 28% | **-53.33%** | High |
| avg_output_tokens | 500 | 847 | **+69.40%** | High |

### 💡 Recommendations

1. **Update parameters**: Apply corrections with `llm-cost calibrate --apply`
2. **Consider gpt-4o-mini**: 95% cheaper, same model family
```

---

## Part 5: Implementation Plan

### 5.1 Phase 7 Milestones

| Week | Deliverable | Tests | LOC |
|------|-------------|-------|-----|
| 1 | `WelfordAccumulator` + parallel merge | 15 | 200 |
| 2 | `FocusParser` streaming + FOCUS 1.2 | 20 | 400 |
| 3 | `DriftDetector` + confidence intervals | 15 | 300 |
| 4 | `ModelRecommender` (cost-only) | 10 | 250 |
| 5 | CLI integration + output formats | 15 | 350 |
| 6 | `--apply` auto-update + docs | 10 | 200 |
| **Total** | | **85** | **1700** |

### 5.2 Test Strategy

```
test/calibration/
├── welford_test.zig           # Mathematical properties
│   ├── variance_scaling        # Var(aX) = a² Var(X)
│   ├── parallel_merge          # Split dataset = same result
│   └── numerical_stability     # Large mean, small variance
│
├── focus_parser_test.zig      # FOCUS compliance
│   ├── required_columns        # BilledCost, UsageQuantity, ResourceId
│   ├── optional_columns        # InvoiceId (1.2), EffectiveCost
│   ├── extension_columns       # x-llm-* namespace
│   └── streaming_memory        # <50MB for 1M records
│
├── drift_test.zig             # Drift detection
│   ├── no_drift               # Estimate ≈ Actual
│   ├── systematic_bias        # Consistent under/over-estimation
│   ├── parameter_attribution   # Identify which parameter drifted
│   └── confidence_levels       # Low/Medium/High thresholds
│
├── recommendations_test.zig   # Model routing
│   ├── same_family            # gpt-4o → gpt-4o-mini
│   ├── cross_provider         # OpenAI → Anthropic
│   └── no_recommendation      # Already cheapest
│
└── integration/
    ├── golden_test.zig        # Deterministic output
    ├── large_dataset_test.zig # 100K records
    └── cli_test.zig           # Exit codes, formats
```

### 5.3 Performance Targets

| Metric | Target | Rationale |
|--------|--------|-----------|
| Memory (1M records) | <50 MB | Streaming + Welford |
| Throughput | >100K records/sec | SIMD scanner |
| Startup | <100ms | No lazy loading |
| Output determinism | Byte-identical | RFC 8785 JSON |

### 5.4 Risk Mitigation

| Risk | Mitigation |
|------|------------|
| FOCUS 1.2 schema changes | Strict on MUST, permissive on MAY |
| Float precision in drift | Use BasisPoints (i32) for comparisons |
| HashMap order in output | Sort keys before serialization |
| Quality recommendations | v1.8 is cost-only, quality in v2.0 |

---

## Part 6: Future Extensions (v2.0+)

### 6.1 RouteLLM Integration

```zig
// Future: integrate RouteLLM preference scores
pub const QualityRouter = struct {
    /// RouteLLM-style win rate prediction
    /// Requires: benchmark data or preference labels
    pub fn predictWinRate(
        query_embedding: []const f64,
        strong_model: []const u8,
        weak_model: []const u8,
    ) f64 {
        // Matrix factorization or BERT classifier
        // See: https://github.com/lm-sys/RouteLLM
    }
};
```

### 6.2 Confidence Tokens (Self-REF)

```zig
// Future: confidence token extraction
// Based on: ICML 2025 "Learning to Route LLMs with Confidence Tokens"
pub const ConfidenceExtractor = struct {
    /// Extract confidence score from model's self-reflection token
    pub fn extractConfidence(response: []const u8) f64 {
        // Parse <confidence> token from response
        // Route to stronger model if confidence < threshold
    }
};
```

### 6.3 Cascade Routing

```zig
// Future: FrugalGPT-style cascade
pub const CascadeRouter = struct {
    models: []const ModelConfig,  // Ordered by cost (ascending)
    scorer: AnswerScorer,
    
    /// Query cascade: start cheap, escalate if needed
    pub fn query(prompt: []const u8) Response {
        for (self.models) |model| {
            const response = model.generate(prompt);
            const score = self.scorer.score(prompt, response);
            if (score >= model.threshold) {
                return response;
            }
        }
        // Fallback to most expensive
        return self.models[self.models.len - 1].generate(prompt);
    }
};
```

### 6.4 PROCEED-style Proactive Adaptation

```zig
// Future: proactive drift anticipation
// Based on: KDD 2025 "Proactive Model Adaptation Against Concept Drift"
pub const ProactiveAdapter = struct {
    /// Predict drift before it happens
    /// Uses temporal patterns to anticipate parameter changes
    pub fn predictDrift(
        historical_drifts: []const DriftEvent,
        forecast_horizon: u32,
    ) []const PredictedDrift {
        // Time series forecasting on drift patterns
        // Alert before invoice shock
    }
};
```

---

## Part 7: Success Criteria

### 7.1 Functional Requirements

| Requirement | Verification |
|-------------|--------------|
| Parse FOCUS 1.2 CSV with required columns | Golden test |
| Detect drift >1% with high confidence | Statistical test |
| Generate deterministic output | Metamorphic test |
| Memory <50MB for 1M records | Benchmark |
| Exit code 1 when drift > warn threshold | Integration test |
| Exit code 2 when drift > error threshold | Integration test |
| `--apply` updates llm-cost.toml correctly | Roundtrip test |

### 7.2 Industry Alignment

| Standard | Alignment |
|----------|-----------|
| FOCUS 1.2 | Required columns, extension namespace |
| FinOps for AI | Cost visibility, drift detection |
| RouteLLM | Cost-aware routing recommendations |
| Reconditionor | Residual-based drift quantification |

### 7.3 User Value

```
Before Calibration:
  Estimate: $10,000/month
  Actual:   $15,000/month  
  Drift:    +50% (unknown until invoice shock)

After Calibration:
  Estimate: $10,000/month
  Actual:   $15,000/month
  Alert:    "cache_hit_ratio 28% vs assumed 60%"
  Action:   "Run: llm-cost calibrate --apply"
  Result:   Future estimates accurate within ±5%
```

---

## Appendix A: Research Bibliography

```bibtex
@inproceedings{ong2025routellm,
  title={RouteLLM: Learning to Route LLMs with Preference Data},
  author={Ong, Isaac and Almahairi, Amjad and Wu, Vincent and others},
  booktitle={ICLR},
  year={2025}
}

@article{chen2024frugalgpt,
  title={FrugalGPT: How to Use Large Language Models While Reducing Cost and Improving Performance},
  author={Chen, Lingjiao and Zaharia, Matei and Zou, James},
  journal={TMLR},
  year={2024}
}

@inproceedings{chen2024calibration,
  title={Calibration of Time-Series Forecasting: Detecting and Adapting Context-Driven Distribution Shift},
  author={Chen, Mouxiang and Shen, Lefei and Fu, Han and others},
  booktitle={KDD},
  year={2024}
}

@inproceedings{zhao2025proceed,
  title={Proactive Model Adaptation Against Concept Drift for Online Time Series Forecasting},
  author={Zhao, L and Shen, Y and Sun, Y and others},
  booktitle={KDD},
  year={2025}
}

@inproceedings{chuang2025confidence,
  title={Learning to Route LLMs with Confidence Tokens},
  author={Chuang, Yu-Neng and others},
  booktitle={ICML},
  year={2025}
}

@article{welford1962note,
  title={Note on a method for calculating corrected sums of squares and products},
  author={Welford, B. P.},
  journal={Technometrics},
  year={1962}
}
```

---

## Appendix B: FOCUS 1.2 Column Mapping

| FOCUS Column | Type | llm-cost Usage |
|--------------|------|----------------|
| BilledCost | MUST | Actual cost |
| EffectiveCost | RECOMMENDED | After discounts |
| UsageQuantity | MUST | Token count |
| UsageUnit | RECOMMENDED | "Tokens" |
| ResourceId | MUST | Prompt ID |
| ChargeCategory | RECOMMENDED | "Usage" |
| InvoiceId | RECOMMENDED (1.2) | Reconciliation |
| x-llm-model | EXTENSION | Model identifier |
| x-llm-input-tokens | EXTENSION | Input count |
| x-llm-output-tokens | EXTENSION | Output count |
| x-llm-cached-tokens | EXTENSION | Cache hits |

---

**Status**: Ready for implementation after Phase 6/PR3 merge.

**Next Steps**:
1. Merge metamorphic testing PR
2. Create `feature/calibration-loop` branch
3. Implement Week 1: WelfordAccumulator
4. Continue through 6-week plan
