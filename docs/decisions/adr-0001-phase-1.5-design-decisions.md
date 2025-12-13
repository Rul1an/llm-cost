# ADR-0001 – Phase 1.5 Design Decisions

**Status:** Accepted
**Date:** 2025-12-09
**Scope:** Core engine & CLI behavior for `llm-cost` v0.4.x (Phase 1.5 – OSS Technical Hardening)

This ADR captures the key technical decisions for Phase 1.5:
1. BPE engine v2
2. Pricing model v2
3. CLI output & JSON contract
4. Exit codes
5. Vocab embedding & licensing

It is the reference point for future reviews and refactors.

---

## 1. BPE Engine v2 – Pure Zig, Heap-based

### Decision
We implement a new BPE engine (“BPE v2”) in pure Zig, with:

- Precomputed vocab/merge data loaded once per encoding.
- O(1) rank lookup via `std.StringHashMap`.
- Heap-based merge algorithm with worst-case complexity O(N log N) in the number of initial tokens.
- Observed near-linear scaling on realistic text and adversarial inputs (repeated characters, emoji).

We do **not** introduce an FFI layer to Rust or any other language. Existing tiktoken-compatible encodings (`o200k_base`, `cl100k_base`) are migrated to BPE v2.

### Naive design (discarded)

Earlier design notes sketched a `findBestMerge()` style implementation that:

- Scanned all merge candidates linearly per step (O(N) per merge).
- Repeated this scan for each merge, leading to O(N²) worst-case behavior.

This variant was used only as a conceptual sketch and has **never** been part of the shipped code.
The implemented engine uses a priority queue (heap) of merge candidates and lazy invalidation via generation counters.

### Rationale
The project’s value proposition is:

- Single static binary.
- Zero external runtime dependencies.
- Cross-compile to a wide set of targets using Zig only.

Pulling in Rust crates via FFI would:

- Require a separate Rust toolchain in the build.
- Force building/linking per-target static libraries.
- Complicate static linking and cross-platform releases.

Modern BPE implementations (e.g. GitHub’s `bpe` crate, BlockBPE-like designs) show that large speedups come from:

- Efficient data structures (O(1) rank lookup, cache-friendly layouts).
- Avoiding repeated full rescans.

Porting those ideas to Zig is consistent with the project’s goals.

### Future work: BPE v3 (true linear-time)

BPE v2 is “good enough” for Phase 1.5, but it is not truly O(N) in the asymptotic sense.
If we need another major step, we will design a “BPE v3” engine with:

- Global candidate buckets sorted by rank instead of per-position scanning.
- A linked list / gap-buffer for O(1) merge application.
- Bitfield or generation-based validity tracking for positions.

This work is explicitly **out of scope** for Phase 1.5 and will be driven by real-world performance requirements.

---

## 2. Pricing Model v2 – Minimal, Honest Split

### Decision
We formalize pricing as a small, explicit struct:

```zig
pub const CostBreakdown = struct {
    tokens_input: u64,
    tokens_output: u64,        // 0 if not provided/estimated
    cost_input_usd: f64,
    cost_output_usd: f64,      // 0 if not provided/estimated
    cost_total_usd: f64,
    accuracy: Accuracy,        // .exact | .heuristic | .estimate
};
```

The pricing database includes at minimum:
- `input_per_1m`
- `output_per_1m`
- `cached_input_per_1m` (for log-enrichment later)
- `context_window`
- `encoding`

We do **not** attempt to model:
- Reasoning tokens.
- Cached-token hit ratios.
- Tool-call costs.
- Image/audio unit pricing beyond simple scalar fields.

### Rationale
Local tokenization can only see what goes into the prompt and (optionally) a user-provided expected output length.
Reasoning tokens, cache hits, and tool-call usage are server-side behaviors, only known after the API call.
Over-modeling (10+ pricing fields) creates a false sense of accuracy and a brittle API surface.

The tool’s responsibility is:
> “Prompt-side token counting + cost estimates for input/output, based on published per-token rates.”

### Consequences
**Pros:**
- Clear scope: no pretending we know what we can’t see.
- Simpler JSON schema for downstream systems.
- Easier to keep in sync with vendor pricing tables.

**Cons:**
- Some users might want “full bill prediction”; they must combine `llm-cost` with vendor usage logs for exact post-hoc billing.

---

## 3. CLI Output & JSON Contract

### Decision
We standardize on machine-readable JSON as a first-class contract:

**Record output**
`llm-cost pipe --format json` emits one JSON object per input line:
```json
{
  "model": "openai/gpt-4o",
  "tokens_input": 123,
  "tokens_output": 0,
  "cost_input_usd": 0.000123,
  "cost_output_usd": 0.0,
  "cost_total_usd": 0.000123,
  "accuracy": "exact"
}
```
Additional fields are allowed but must remain stable or be versioned.

**Summary output**
`llm-cost pipe --summary --summary-format json` writes a single JSON object to stderr:
```json
{
  "version": "1",
  "lines_total": 1000,
  "lines_failed": 3,
  "tokens_input": 120000,
  "tokens_output": 10000,
  "cost_input_usd": 4.21,
  "cost_output_usd": 0.02,
  "cost_total_usd": 4.23,
  "model": "openai/gpt-4o",
  "accuracy": "exact",
  "quota_hit": false
}
```

**Quiet mode**
`--quiet` suppresses human-friendly chatter; JSON records and summary remain unchanged.

### Rationale
CI/CD, agents and ETL-pipelines want JSON, not human-friendly text.
Standard separation:
- stdout → per-record transformed data.
- stderr → summary/diagnostics.
A version field (`"version": "1"`) in the summary makes later schema expansions manageable.

### Consequences
**Pros:**
- Downstream tools (jq, yq) can use standard parsers without reverse engineering.
- Contract is testable via golden tests.

**Cons:**
- We are bound to backward compatibility; schema changes require versioning or new flags.

---

## 4. Exit Codes – BSD Sysexits-Style

### Decision
We reserve and document the following exit codes:
- `0` – `EXIT_OK` – success
- `1` – `EXIT_ERROR` – generic runtime error (I/O, panic, unexpected failure)
- `2` – `EXIT_USAGE` – CLI misuse / invalid arguments
- `64` – `EXIT_QUOTA` – quota exceeded (`--max-cost`, `--max-tokens`)
- `65` – `EXIT_PARTIAL` – stream completed, but some lines failed

This mapping is defined in one central place in the code and displayed in `--help/docs`.

### Rationale
0/1/2 are conventional (POSIX/shell).
BSD `sysexits.h` uses the 64–78 range for application-specific codes.
By using 64 and 65:
- We avoid conflicts with shell builtins.
- Orchestrators and FinOps jobs can easily distinguish quota-exceeded and partial-failure.

### Consequences
**Pros:**
- Clear, script-friendly signals for CI and schedulers.
- No “magic numbers” in docs; everything named and tested.

**Cons:**
- Existing scripts checking only `0`/`!=0` won’t automatically get the nuance of 64/65 (but won’t break).

---

## 5. Vocab Embedding & Licensing

### Decision
- We embed the vocab/merge-tables (tiktoken-like data) in the binary.
- We do **not** download at runtime.
- We explicitly record origin and license in:
  - `NOTICE` (root).
  - `docs/vocab.md` (origin, repo/commit, encodings).

### Rationale
Important USP:
- Offline, air-gapped, “no network” behavior.

Runtime download would:
- Break air-gapped scenarios.
- Add extra failure modes (network, checksum, availability).
The `tiktoken` repo is MIT; without separate restrictions, the vocabs are MIT-licensed data.
Standard OSS practice: reuse under MIT with attribution in NOTICE.

### Consequences
**Pros:**
- Binary is fully self-contained.
- Enterprise legal can easily verify with standard MIT/NOTICE pattern.

**Cons:**
- Binary grows with vocab data (acceptable for CLI tooling).
- For custom vocabs we must provide separate tooling; not “drop a file and go”.

---

## 6. Non-Goals in Phase 1.5
The following are explicitly **not** part of this phase:
- New tokenizers (SentencePiece, Unigram) – we stay with tiktoken-like encodings in v1.5.
- C ABI library interface – focus is CLI; Zig-module/WASM can adhere to a separate ADR.
- Full billing simulation (reasoning, cached tokens, tool-calls) – we limit to prompt-side costs.
- OpenTelemetry/metrics integration – can be built later on top of JSON/exit contracts.

---

## 7. Compatibility Notes
- BPE v2 is a drop-in replacement for the old engine:
  - Same vocab/merge-tables.
  - Same token-ID output (parity tests are the guardrail).
- JSON output:
  - New fields added with care.
  - Existing fields stable; breaking changes require new schema/version.
- Exit codes:
  - Existing “0 = ok, nonzero = error” scripts continue to work.
  - Extra semantics (64/65) are opt-in for those who want them.

---

## 8. Performance Principles

`llm-cost` is a CPU-bound CLI tool. We optimize algorithms and allocation patterns first, micro-optimizations last. This section defines what we do and what we explicitly do not do.

### 1. Algorithms first, tricks later

- BPE v2 uses a heap-based merge algorithm with O(1) rank lookup.
- Pre-tokenizers are simple state machines (one pass, no backtracking).
- JSONL is processed line-by-line; no loading entire files into memory.

**Guideline:** If an optimization improves Big-O complexity or clearly reduces memory usage, it takes precedence. Otherwise, only apply it after profiling.

### 2. Allocation Strategy: Arenas and Slices

- In the hot path (tokenization / `pipe`), we use an `ArenaAllocator` per worker.
- JSON parsing, temporary buffers, and token lists use arena allocations that are freed in bulk after a batch/line.
- Where possible, work with slices into existing memory (input buffers, embedded vocabs) rather than performing new heap allocations.

**Guideline:**
- Heap allocations in tight loops are suspicious.
- If an object is created and destroyed per record, it belongs in an arena, not on the general allocator.

### 3. Permitted Optimizations (Conditional)

These techniques are allowed, but only if profiling proves they are in the hot path:

- **SIMD / `@Vector`**
  For clearly recurring patterns (e.g., ASCII whitespace scanning or newline detection) if they demonstrably consume the majority of time.

- **Branch Cleanup**
  Rare paths (error handling, quota exceeded) may be moved to separate functions and marked with `@setCold(true)`. The "happy path" should remain a straight line without unnecessary branches.

- **Small Comptime Helpers**
  Lookup tables and simple switches on a small, fixed set of models/encodings are acceptable, provided they do not compromise readability.

**Condition:** First run a profiler on a representative 10–50GB workload; only optimize once the bottleneck is identified.

### 4. Explicit Non-Goals (Phase 1.5 / 1.x)

The following techniques are consciously out of scope for this codebase:

- **No `io_uring` in the CLI**
  I/O is usually not the bottleneck; the tool must be portable (Linux, macOS, Windows). Classic blocking I/O + batching is sufficient.

- **No compile-time perfect hashing for model dispatch**
  The number of models/encodings is small. A simple `if`/`switch` is readable and fast enough. We will not build a mini-gperf unless it is clearly in the hot path.

- **No Inline Assembly**
  As long as Zig's optimizer and `@Vector` are sufficient, we do not write hand-asm. Inline assembly is fragile, non-portable, and hard to maintain. It is only considered if we hit a demonstrable compiler limit on a proven hotspot.

- **No Extra Languages / FFI Layers**
  The BPE engine and tokenization remain pure Zig. We do not link Rust/C++ tokenizer libraries as dependencies; that breaks the "single static binary" promise.

### 5. Profiling and Regressions

- Performance changes are measured using existing benchmarks (`bench-bpe`, end-to-end JSONL benchmarks).
- We monitor the following metrics:
  - Throughput (MB/s) for realistic JSONL workloads.
  - Scaling behavior for worst-case input (repetitive patterns, emoji).
  - Memory usage per worker (`pipe --workers N`).

**Guideline:**
- No "blind" optimizations without before/after measurements.
- If an optimization noticeably increases complexity, the gain must be clearly demonstrable (not just theoretical).
