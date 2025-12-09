# Performance

## Methodology

Benchmarks are run on **Apple M2 Max (macOS)** and **Linux x86_64 (GitHub Actions Runners)**.
We measure the time to encode standard datasets (e.g., 4KB of English text, random bytes).

### What does "~1ms" mean?
For reference, 1 millisecond per 4KB chunks means `llm-cost` can process approximately **4MB/s** of text per single thread. In parallel mode (`pipe --workers 8`), throughput scales linearly, easily saturating disk I/O before CPU limits on most systems.

## Benchmarks

### BPE Microbenchmark (v0.3 baseline)

## BPE Microbenchmark
**Scenario**: o200k_base encoding.
**Date**: Dec 2025
**Hardware**: Local Dev Machine

### Worst-Case Scaling (Post-fix)
Before optimization, scaling was $O(N^2)$. Now effectively $O(N)$ / $O(N \log N)$ after Heap-Merge implementation.

| Input (N) | Time (ns) | Ratio (vs prev N) | Scaling |
|---|---|---|---|
| a * 1024 | 265,710 (0.26ms) | - | - |
| a * 2048 | 555,614 (0.55ms) | 2.09x | O(N) / O(N log N) |
| a * 4096 | 1,112,658 (1.1ms) | 2.00x | O(N) / O(N log N) |

**Conclusion**: Scaling is now **Linear / Log-Linear**.
- `a * 4096` takes ~1.1ms (vs ~280ms previously). **Speedup: ~254x**.
- The quadratic bottleneck has been strictly eliminated.

### Emoji Scaling (Previously also quadratic)
| Input (N) | Time (ns) | Ratio (vs prev N) | Scaling |
|---|---|---|---|
| emoji * 1024 | 936,637 (0.93ms) | - | - |
| emoji * 2048 | 1,548,297 (1.5ms) | 1.65x | ~Linear |
| emoji * 4096 | 3,047,118 (3.0ms) | 1.96x | ~Linear |

*This confirms that heap-merge solves the O(N^2) issue for multi-byte codepoints as well.*

## Phase 1.5 – BPE v2 (Pure Zig)

**Status**: Implemented (Dec 2025).
**Comparison**: v2 (O(1) rank lookup and improved data structures) vs v0.3 Legacy.

> **Note on earlier design sketches**:
> Some early design notes mentioned a naive `findBestMerge()` implementation that would rescan all pairs on each merge step (O(N²) worst-case). That variant was never shipped. The current BPE v2 engine is explicitly heap-based O(N log N) with O(1) rank lookup and has been validated against the Evil Corpus parity suite.

**Complexity**: Heap-based merge is technically $O(N \log N)$ worst-case, similar to v0.3. However, O(1) rank lookups and improved memory layout result in significantly better constant factors.

| Input (N) | Legacy (ms) | v2 (ms) | Speedup |
|---|---|---|---|
| a * 4096 | ~1.08ms | ~0.80ms | 1.35x |
| a * 8192 | ~2.21ms | ~1.54ms | 1.43x |
| emoji * 4096 | ~2.48ms | ~1.71ms | 1.45x |
| emoji * 8192 | ~5.11ms | ~3.40ms | 1.50x |

**Scaling**: Observed behavior approaches linear ($O(N)$) for these inputs due to efficiency gains, though theoretical worst-case remains $O(N \log N)$.
The new engine provides ~35-50% throughput improvement over the v0.3 optimized engine, while maintaining a pure Zig codebase and simpler memory model (single allocation per encoding).

### End-to-End Pipeline
**Input A (Realistic)**: 50MB JSONL (Synthetic "realistic" sentences).
**Input B (Stress)**: 10MB JSONL (`a*512` repeated).

| Dataset | Workers | Time (Total) | Throughput | notes |
|---|---|---|---|---|
| Realistic | 1 (Single) | 7.07s | 7.4 MB/s | (Baseline v0.3-pre) |
| Realistic | Parallel | 0.71s | ~74 MB/s | Scalable |
| Stress (a*512) | 10 | ~0.3s | ~35 MB/s | was <0.1 MB/s in v0.3-pre |

**Observation**:
- Parallel scaling remains excellent (~10x) for normal text.
- Worst-case scaling ($O(N^2)$) is resolved. The engine is now completely robust against adversarial inputs.

## Next Steps
- **Epic 4 Optimization Complete**: Merged Heap-based algorithm.
- **Verification**: Parity tests (Evil Corpus) and fuzzing re-run post-merge: **GREEN**.
- Proceed to **Epic 4 Phase 3 (Data Structures)** if further optimization is needed (currently low priority as main bottleneck is gone).
