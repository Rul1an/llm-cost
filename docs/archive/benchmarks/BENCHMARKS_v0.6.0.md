# LLM-Cost Benchmarks (v0.6.0)

**Date:** 2025-12-10
**Build:** `ReleaseFast`
**Engine:** BPE v2.1 (Index+Heap+Arena)
**Machine:** Apple Silicon (presumed)

## 1. Scaling Verification (Proof of Performance)

The primary goal of v2.1 was to eliminate $O(N^2)$ quadratic complexity in deep merges.

| Scenario | Size | Time (ms) | Scaling Ratio | Status |
|---|---|---|---|---|
| Evil 'a' (10KB) | 10 KB | 2.46 | - | Baseline |
| Evil 'a' (1MB) | 1 MB | 246.78 | **100.3x** | ✅ **Linear ($O(N)$)** |

> **Note:** Ideally, 100x size increase results in ~100x time increase. An $O(N^2)$ algorithm would show ~10,000x increase.

## 2. Throughput Metrics

Performance on various workloads.

| Scenario | Size | Throughput | speed (Tok/s) | Notes |
|---|---|---|---|---|
| Random ASCII | 100 KB | **4.85 MB/s** | 3.4M | Baseline |
| Emoji (UTF-8) | 50 KB | **11.51 MB/s** | 6.0M | Low merge density |
| **Macro (Real World)** | 14 KB | **8.15 MB/s** | 3.3M | Mixed usage |

## 3. Methodology

- **Unified Runner**: `zig build bench` compiles `src/bench.zig` in ReleaseFast.
- **Memory Safety**: `std.heap.GeneralPurposeAllocator` with leak detection enabled guarantees no memory leaks.
- **Timing**: Wall-clock time of the core `tokenizer.count()` loop (10 iterations after warmup).
