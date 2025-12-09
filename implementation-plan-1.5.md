# Implementation Plan - Phase 2: BPE Optimization (v2.1 / v3)

**Goal**: Optimize the BPE engine to achieve state-of-the-art performance (2025 standards) while maintaining strict parity with `tiktoken`.

**Research Validation (Dec 2025)**:
- **Architecture**: The proposed "Index-based Linked List" (`TokenBuffer`) is validated by recent high-performance Rust implementations (e.g., `rs-bpe`, `tokenizers`). It offers O(1) amortized merges with better cache locality than pointer-based lists.
- **Algorithms**:
  - **v2.1 (Min-Heap)**: Verified as the robust standard for O(N log N) scaling.
  - **v3 (Bucket Queue)**: Confirmed as the "bleeding edge" optimization to reach O(N) for large inputs, widely used in advanced compression and tokenization research.
- **Parallelism**: CPU-level parallel BPE (chunked) is complex and requires careful boundary handling; file-level parallelism (already in `pipe`) is the preferred approach for CLIs. GPU offloading (`BlockBPE`) is out of scope for this generic CLI.

---

## User Review Required

- **Feature Flag**: I will add a `BpeVersion` enum to `TokenizerConfig`. Default will remain `v2` (current) until v2.1 is fully verified.
- **Memory**: v2.1 uses an Arena allocator. This increases memory *usage* (no freeing individual nodes) in exchange for speed. This is acceptable for batch processing but worth noting for very low-memory environments.

---

## Proposed Changes

### [NEW] `src/tokenizer/bpe_v2_1.zig`

New module implementing the optimized engine.

- **`TokenBuffer`**: Structure-of-Arrays (SOA) tracking `tokens`, `next`, `prev`, `valid`.
  - `initFromBytes(bytes)`: O(N) linear scan.
  - `merge(pos, id)`: O(1) index manipulation.
- **`MergeQueue`**:
  - Wrapper around `std.PriorityQueue`.
  - Implements the "4-point validation" check before returning a candidate.
- **`encodeLinear`**:
  - Main entry point.
  - Uses `std.heap.ArenaAllocator` for all temporary structures.

### [MODIFY] `src/core/engine.zig`

- Add `bpe_version: enum { legacy, v2, v2_1 } = .v2` to `TokenizerConfig`.
- Switch `estimateTokens` to dispatch to `bpe_v2_1.encodeLinear` when selected.

### [NEW] `src/bench/bench_bpe_v2_1.zig`

- Duplicate `bench_bpe_v2` but targeting the new engine.
- Used for side-by-side comparison.

---

## Verification Plan

### Automated Tests
- **Unit Tests**: `src/tokenizer/bpe_v2_1.zig` will have internal tests (manual merge sequences).
- **Parity Tests**:
  - Run `zig build test-parity` with `LLM_COST_BPE_VERSION=v2.1` (env var or config hardcode).
  - Must perfectly match `evil_corpus_v2.jsonl`.
- **Fuzzing**:
  - Update `src/fuzz_test.zig` to randomly select between `v2` and `v2.1` and assert identical results (differential fuzzing).

### Manual Verification
- **Benchmarks**:
  ```bash
  zig build bench-bpe-v2
  zig build bench-bpe-v2-1 # New target
  ```
  Target: Linear scaling (O(N) / O(N log N)) and > 20% speedup on >100KB files.

### Release Criteria (v2.1)
1. Parity tests pass 100%.
2. Fuzz tests run for >10 min without divergence.
3. No performance regression on small inputs (< 1KB).
4. Measurable gain on large inputs.
