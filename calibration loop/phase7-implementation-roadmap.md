# Phase 7: Calibration Loop — Implementation Roadmap

**Target Version**: v1.9.0  
**Duration**: 6 weeks  
**Prerequisites**: Phase 6/PR3 Metamorphic Testing ✅  

---

## 🎯 Core Innovation

Transform llm-cost from **prediction tool** → **continuous improvement system** via closed-loop feedback.

```
┌─────────────────────────────────────────────────────────────────┐
│                     THE CALIBRATION LOOP                         │
│                                                                  │
│    estimates.json ──┐                                            │
│                     ├──► llm-cost calibrate ──► drift report     │
│    actuals.csv ─────┘          │                                 │
│                                │                                 │
│                                ▼                                 │
│                     llm-cost calibrate --apply                   │
│                                │                                 │
│                                ▼                                 │
│                     llm-cost.toml (corrected)                    │
│                                │                                 │
│                                ▼                                 │
│                     Better estimates next cycle                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## 📚 SOTA Research Integration

| Innovation | Source | Application |
|------------|--------|-------------|
| **Welford Streaming** | Welford 1962, Knuth TAOCP | O(1) memory statistics |
| **Parallel Variance** | Chan et al. | Multi-file merge |
| **Reconditionor** | KDD 2024 | Residual-based drift detection |
| **SOLID Adaptation** | KDD 2024 | Bias-variance optimal correction |
| **RouteLLM** | ICLR 2025 | Cost-aware model routing |
| **FrugalGPT** | TMLR 2024 | Cascade optimization insights |
| **FOCUS 1.2** | FinOps Foundation 2025 | Industry-standard schema |

---

## 🗓️ Week-by-Week Plan

### Week 1: Streaming Statistics Core

**Goal**: Implement numerically stable, memory-efficient statistics.

```zig
// Key deliverable: WelfordAccumulator
pub const WelfordAccumulator = struct {
    count: u64, mean: f64, m2: f64, min: f64, max: f64,
    
    pub fn update(self: *, value: f64) void { ... }
    pub fn variance(self) f64 { ... }
    pub fn merge(self: *, other: WelfordAccumulator) void { ... }  // Chan et al.
    pub fn ci95(self) [2]f64 { ... }  // 95% confidence interval
};
```

**Tests** (15):
- Mathematical properties: Var(aX) = a² Var(X)
- Parallel merge correctness
- Numerical stability: large mean, small variance

**Metrics**: O(1) memory, exact match to batch computation

---

### Week 2: FOCUS 1.2 Parser

**Goal**: Stream 1M+ records with <50MB memory.

```zig
// Key deliverable: FocusParser
pub const FocusParser = struct {
    // FOCUS 1.2 required columns
    BilledCost: MicroUSD,      // MUST
    UsageQuantity: u64,        // MUST  
    ResourceId: []const u8,    // MUST
    
    // FOCUS 1.2 recommended (new in 1.2)
    InvoiceId: ?[]const u8,    // For reconciliation
    
    // llm-cost extensions
    @"x-llm-model": ?[]const u8,
    @"x-llm-cached-tokens": ?u64,
    
    pub fn next(self: *) !?FocusRecord { ... }  // Streaming
};
```

**Tests** (20):
- Required column validation
- Optional column handling
- Extension column namespace (x-llm-*)
- Memory benchmark: 1M records < 50MB
- Chunking invariant (from metamorphic suite)

---

### Week 3: Drift Detection

**Goal**: Detect and quantify systematic estimation bias.

```zig
// Key deliverable: DriftDetector (Reconditionor-inspired)
pub const DriftDetector = struct {
    pub fn computeDrift(estimates: Estimates, actuals: CalibrationStats) CalibrationResult {
        // Per-parameter drift with confidence intervals
    }
    
    pub fn reconditionorScore(self) f64 {
        // Mutual information between residuals and context
        // High score = vulnerable to context-driven shift
    }
};

pub const CalibrationResult = struct {
    estimated_total: MicroUSD,
    actual_total: MicroUSD,
    drift_bps: i32,            // Basis points
    confidence: ConfidenceLevel,
    parameters: []ParameterDrift,  // Which assumptions were wrong?
};
```

**Tests** (15):
- No drift detection (estimate ≈ actual)
- Systematic bias detection
- Parameter attribution accuracy
- Confidence level thresholds

---

### Week 4: Model Recommendations

**Goal**: Suggest cost-saving model switches (cost-only, no quality scores yet).

```zig
// Key deliverable: ModelRecommender (RouteLLM-inspired)
pub const ModelRecommender = struct {
    pub fn recommendAlternatives(
        current_model: []const u8,
        usage: UsagePattern,
    ) []Recommendation {
        // Find cheaper models in same family
        // Calculate savings in basis points
    }
};

pub const Recommendation = struct {
    model: []const u8,
    savings_bps: i32,           // e.g., 9500 = 95% cheaper
    quality_impact: QualityImpact,  // unknown | same_family | different_family
    rationale: []const u8,
};
```

**Tests** (10):
- Same-family recommendations (gpt-4o → gpt-4o-mini)
- Cross-provider recommendations
- No recommendation when already cheapest
- Savings calculation accuracy

---

### Week 5: CLI Integration

**Goal**: Full command-line interface with CI/CD exit codes.

```bash
# Basic usage
llm-cost calibrate --estimates est.json --actuals act.csv

# CI integration
llm-cost calibrate \
  --warn-threshold 500 \   # 5% = warning (exit 1)
  --error-threshold 1000 \ # 10% = error (exit 2)
  --format json

# With recommendations
llm-cost calibrate --recommend --format markdown > pr-comment.md
```

**Exit Codes**:
| Code | Meaning |
|------|---------|
| 0 | Success, acceptable drift |
| 1 | Warning threshold exceeded |
| 2 | Error threshold exceeded |
| 10-13 | Input errors |
| 20-21 | Runtime errors |

**Output Formats**:
- TOML (human-readable, default)
- JSON (machine-readable, RFC 8785 canonical)
- Markdown (for PR comments)

**Tests** (15):
- Exit code correctness
- Format determinism
- Large dataset handling
- Error message clarity

---

### Week 6: Auto-Apply & Documentation

**Goal**: Close the loop with automatic correction.

```bash
# Auto-correct llm-cost.toml
llm-cost calibrate --apply

# Dry-run first
llm-cost calibrate --apply --dry-run
```

**Behavior**:
1. Read current `llm-cost.toml`
2. Update drifted parameters with observed values
3. Add comment with calibration date and source
4. Preserve manual overrides (marked with `# manual`)

**Tests** (10):
- Roundtrip: parse → calibrate → apply → parse
- Preserve existing comments
- Respect `# manual` markers
- Backup before modification

**Documentation**:
- `docs/calibration.md` — User guide
- `docs/focus-schema.md` — FOCUS 1.2 extension spec
- `CHANGELOG.md` — v1.9.0 entry

---

## 📊 Test Summary

| Category | Count | Coverage |
|----------|-------|----------|
| Welford Statistics | 15 | Mathematical properties |
| FOCUS Parser | 20 | Schema compliance |
| Drift Detection | 15 | Accuracy & confidence |
| Recommendations | 10 | Routing logic |
| CLI Integration | 15 | Exit codes & formats |
| Auto-Apply | 10 | Roundtrip & safety |
| **Total** | **85** | |

---

## 🔧 Technical Specifications

### Memory Budget

| Component | Budget | Implementation |
|-----------|--------|----------------|
| FocusParser | O(line_length) | Streaming, no full-file load |
| WelfordAccumulator | O(1) per stat | 5 floats per parameter |
| CalibrationStats | O(models) | HashMap of accumulators |
| Output buffer | O(output_size) | ArrayList writer |
| **Total (1M records)** | **<50 MB** | |

### Integer Money Math

```zig
pub const MicroUSD = i128;  // $0.000001 precision

// FORBIDDEN
const cost: f64 = 1234.56;  // Accumulation drift!

// CORRECT  
const cost: MicroUSD = 1_234_560_000;  // Exact
```

### Deterministic Output

```zig
// All output uses:
// - Sorted map keys
// - RFC 8785 canonical JSON
// - Fixed decimal places
// - No floating point in monetary output
```

---

## 🚀 Go/No-Go Criteria

### Must Have (Week 1-5)
- [x] Metamorphic tests passing (Phase 6)
- [ ] Welford with <1e-10 relative error vs numpy
- [ ] FOCUS 1.2 required columns validated
- [ ] Drift detection within ±0.1% of ground truth
- [ ] Exit codes work in GitHub Actions

### Should Have (Week 6)
- [ ] `--apply` with backup
- [ ] Markdown PR comment format
- [ ] Recommendation rationale text

### Nice to Have (v2.0)
- [ ] Quality-aware routing (RouteLLM full)
- [ ] Confidence tokens (Self-REF)
- [ ] Cascade optimization (FrugalGPT)
- [ ] Proactive drift prediction (PROCEED)

---

## 📋 Files to Create

```
src/calibration/
├── mod.zig                 # Week 5: Public API
├── types.zig               # Week 1: MicroUSD, BasisPoints
├── stats.zig               # Week 1: WelfordAccumulator
├── focus_import.zig        # Week 2: FOCUS 1.2 parser
├── drift.zig               # Week 3: DriftDetector
├── recommendations.zig     # Week 4: ModelRecommender
└── output.zig              # Week 5: Formatters

test/calibration/
├── welford_test.zig        # Week 1
├── focus_parser_test.zig   # Week 2
├── drift_test.zig          # Week 3
├── recommendations_test.zig # Week 4
└── integration/
    ├── cli_test.zig        # Week 5
    └── apply_test.zig      # Week 6

docs/
├── calibration.md          # Week 6
└── focus-schema.md         # Week 6
```

---

## 🎯 Success Metrics

| Metric | Target | Measurement |
|--------|--------|-------------|
| Drift detection accuracy | ±0.1% | vs manual calculation |
| Memory efficiency | <50 MB @ 1M records | valgrind massif |
| Throughput | >100K records/sec | hyperfine benchmark |
| Output determinism | 100% byte-identical | metamorphic test |
| CI integration | Exit codes correct | GitHub Actions matrix |

---

**Status**: Ready to start after Phase 6/PR3 merge.

**Branch**: `feature/calibration-loop`

**First PR**: `feat(calibration): add WelfordAccumulator with parallel merge`
