# Performance Benchmarks

This document describes how to run performance benchmarks, interpret results,
and use them to make data-driven decisions about optimization investments.

---

## 1. Overview

llm-cost includes several benchmark targets to measure and compare performance:

| Command | Purpose |
|---------|---------|
| `zig build bench` | Quick overall benchmark |
| `zig build bench-bpe` | BPE tokenizer performance |
| `zig build bench-bpe-v2` | BPE v2 (current) engine |
| `zig build bench-legacy` | Legacy/naive implementation (baseline) |

---

## 2. Quick Start

```bash
# Run all benchmarks
zig build bench

# Run BPE-specific benchmark
zig build bench-bpe

# Compare current vs legacy
zig build bench-bpe-v2
zig build bench-legacy
```

---

## 3. Benchmark Targets

### 3.1 `bench` - Overall Performance

```bash
zig build bench
```

Runs a general benchmark covering:
- Tokenization throughput (tokens/sec)
- Pricing calculation speed
- JSON parsing (pipe mode simulation)

**Output:**
```
Overall benchmark results:
  Tokenization: 1,234,567 tokens/sec
  Pricing:      2,345,678 calls/sec
  JSON parse:   456,789 lines/sec
```

### 3.2 `bench-bpe` - BPE Engine Performance

```bash
zig build bench-bpe
```

Focuses specifically on the BPE tokenizer:
- Tests various input sizes (1KB, 10KB, 100KB, 1MB)
- Measures tokens/sec and bytes/sec
- Reports memory allocations

**Output:**
```
BPE Benchmark (O200k encoding):

  Size      Tokens/s     Bytes/s      Allocs    Time
  ─────────────────────────────────────────────────────
  1KB       850,000      1.2 MB/s     12        1.2ms
  10KB      920,000      1.4 MB/s     45        10.8ms
  100KB     890,000      1.3 MB/s     234       112ms
  1MB       875,000      1.3 MB/s     1,892     1.14s

Complexity check:
  10KB/1KB ratio:   9.0x time for 10x input ✓ (linear)
  100KB/10KB ratio: 10.4x time for 10x input ✓ (linear)
  1MB/100KB ratio:  10.2x time for 10x input ✓ (linear)
```

### 3.3 `bench-bpe-v2` - Current Engine

```bash
zig build bench-bpe-v2
```

Benchmarks the current BPE v2 implementation specifically:
- Index-based TokenBuffer
- Min-heap with lazy deletion
- 4-point validation

### 3.4 `bench-legacy` - Baseline Comparison

```bash
zig build bench-legacy
```

Runs the naive O(N²) implementation (if available) for comparison.

---

## 4. Interpreting Results

### 4.1 Complexity Verification

The key metric is **scaling behavior**:

| Scaling | Meaning | Target |
|---------|---------|--------|
| 10x input → 10x time | O(N) linear | ✅ Good |
| 10x input → 10-15x time | O(N log N) | ✅ Acceptable |
| 10x input → 100x time | O(N²) quadratic | ❌ Bug! |

**How to check:**

```
10KB time / 1KB time ≈ 10x → linear ✓
If you see ≈ 100x → you have O(N²) somewhere
```

### 4.2 Bottleneck Identification

Look at where time is spent:

| Component | Typical % | If >50% |
|-----------|-----------|---------|
| BPE merges | 30-40% | Consider BPE v3 |
| Pre-tokenizer | 20-30% | Consider SIMD |
| I/O | 20-30% | Consider mmap |
| JSON parsing | 10-20% | Usually fine |

### 4.3 Memory Analysis

Track allocations:

```
High alloc count + slow → allocation overhead
Low alloc count + slow → algorithm issue
```

---

## 5. Advanced Benchmarking

### 5.1 Custom Input Sizes

```bash
# Test with specific sizes
zig build bench-bpe -- --sizes 1k,10k,100k,1m,10m
```

### 5.2 JSON Output

```bash
# Machine-readable output
zig build bench-bpe -- --format json > bench-results.json
```

**Output format:**
```json
{
  "timestamp": "2025-01-15T10:30:00Z",
  "version": "0.5.0",
  "commit": "abc1234",
  "results": [
    {
      "size_bytes": 1024,
      "tokens_per_sec": 850000,
      "bytes_per_sec": 1200000,
      "allocations": 12,
      "time_ms": 1.2
    }
  ],
  "complexity_check": {
    "10k_1k_ratio": 9.0,
    "100k_10k_ratio": 10.4,
    "verdict": "linear"
  }
}
```

### 5.3 Profiling

For detailed profiling:

```bash
# Build with profiling
zig build -Doptimize=ReleaseFast

# Run with perf (Linux)
perf record -g ./zig-out/bin/llm-cost tokens "$(cat large_input.txt)"
perf report

# Run with Instruments (macOS)
xcrun xctrace record --template "Time Profiler" --launch ./zig-out/bin/llm-cost -- tokens "$(cat large_input.txt)"
```

---

## 6. Decision Framework

Use benchmarks to decide which optimization to pursue:

### 6.1 BPE v3 (Bucket Queue)

**Trigger:** BPE takes >50% of total runtime

**How to check:**
```bash
zig build bench-bpe -- --profile
# Look for "BPE merge loop" percentage
```

**Expected gain:** 1.5-2x on large inputs

### 6.2 SIMD Pre-tokenizer

**Trigger:** Pre-tokenizer takes >30% of runtime

**How to check:**
```bash
zig build bench-bpe -- --profile
# Look for "pretokenize" percentage
```

**Expected gain:** 2-3x on pre-tokenization phase

### 6.3 Memory-Mapped I/O

**Trigger:** I/O takes >40% of runtime on large files

**How to check:**
```bash
time ./llm-cost tokens "$(cat 100mb_file.txt)" > /dev/null
# Compare to:
time cat 100mb_file.txt | ./llm-cost tokens > /dev/null
```

**Expected gain:** Significant for files >10MB

### 6.4 Parallel Scanning

**Trigger:** Processing many files sequentially is slow

**How to check:**
```bash
time find . -name "*.jsonl" -exec ./llm-cost pipe {} \;
# vs
time find . -name "*.jsonl" | parallel ./llm-cost pipe {}
```

**Expected gain:** Near-linear with CPU cores

---

## 7. Regression Detection

### 7.1 CI Benchmarks

The release verification pipeline (in `release.yml`) runs `zig build bench-bpe` and fails if:
- Performance degrades >10% from baseline
- Complexity check fails (non-linear scaling detected)

### 7.2 Baseline Management

```bash
# Save current as baseline
zig build bench-bpe -- --format json > benchmarks/baseline.json

# Compare against baseline
zig build bench-bpe -- --compare benchmarks/baseline.json
```

**Output:**
```
Performance comparison vs baseline:

  Metric          Baseline    Current     Change
  ───────────────────────────────────────────────
  tokens/s (1KB)  850,000     862,000     +1.4% ✓
  tokens/s (1MB)  875,000     871,000     -0.5% ✓

  Status: PASS (no regressions >10%)
```

---

## 8. Benchmark Corpus

### 8.1 Standard Test Files

Located in `testdata/bench/`:

| File | Size | Content |
|------|------|---------|
| `ascii_1k.txt` | 1 KB | ASCII text |
| `ascii_100k.txt` | 100 KB | ASCII text |
| `unicode_mixed.txt` | 50 KB | Mixed scripts |
| `code_python.txt` | 30 KB | Python code |
| `json_logs.jsonl` | 100 KB | JSONL log entries |
| `worst_case.txt` | 10 KB | Adversarial patterns |

### 8.2 Worst-Case Patterns

The `worst_case.txt` file contains patterns known to stress BPE:

- Long runs of single character (`aaaaaaa...`)
- Alternating patterns (`ababab...`)
- Emoji sequences
- Mixed byte/unicode boundaries

---

## 9. Historical Performance

Track performance across versions:

| Version | 1KB (tok/s) | 1MB (tok/s) | Complexity |
|---------|-------------|-------------|------------|
| 0.3.0 | 450,000 | 12,000 | O(N²) ❌ |
| 0.4.0 | 650,000 | 580,000 | O(N log N) ✓ |
| 0.5.0 | 850,000 | 875,000 | O(N log N) ✓ |
| 1.0.0 (target) | 1,000,000 | 1,000,000 | O(N) |

---

## 10. Next Steps

After running benchmarks, use this decision tree:

```
Is BPE >50% of runtime?
├── Yes → Implement BPE v3 (bucket queue)
└── No
    ├── Is pre-tokenizer >30%?
    │   ├── Yes → Add SIMD optimization
    │   └── No
    │       ├── Is I/O >40%?
    │       │   ├── Yes → Add mmap support
    │       │   └── No → Performance is good, focus elsewhere
    │       └── ...
```

See `docs/roadmap-1.5.md` → "Activation Triggers" for detailed criteria.
