# Implementation Plan: Fase 1.5

**Version:** 1.0
**Status:** Draft
**Author:** [Maintainer]
**Date:** 2025-01

---

## How to Use This Document

Dit document bevat:
1. **Epics** - grote werkpakketten
2. **Tasks** - concrete implementatietaken
3. **Checklists** - per task wat er af moet zijn
4. **Test criteria** - hoe je weet dat het werkt

Werk top-down: voltooi dependencies eerst. Vink af wat klaar is.

---

## Epic 1: Backend Architecture Refactor

**Goal:** Tokenizer backends als comptime generics, voorbereid op multi-provider
**Duration:** 3-5 dagen
**Dependencies:** Geen
**Blocks:** Epic 2 (BPE v2)

### Task 1.1: Define Backend Interface

**File:** `src/tokenizer/backend.zig`

```zig
// Create this file with the interface definition
pub const Accuracy = enum {
    exact,
    heuristic,
    estimate,
};

/// Compile-time check for backend compliance
pub fn assertValidBackend(comptime T: type) void {
    if (!@hasDecl(T, "encode")) @compileError("Backend must have encode()");
    if (!@hasDecl(T, "count")) @compileError("Backend must have count()");
    if (!@hasDecl(T, "decode")) @compileError("Backend must have decode()");
    if (!@hasDecl(T, "name")) @compileError("Backend must have name constant");
    if (!@hasDecl(T, "accuracy")) @compileError("Backend must have accuracy constant");
}
```

**Checklist:**
- [ ] File created
- [ ] `Accuracy` enum defined
- [ ] `assertValidBackend` comptime function
- [ ] Unit test that invalid backend fails at comptime

---

### Task 1.2: Create Tokenizer Generic

**File:** `src/tokenizer/tokenizer.zig`

```zig
const backend = @import("backend.zig");

pub fn Tokenizer(comptime Backend: type) type {
    comptime backend.assertValidBackend(Backend);

    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn encode(self: *const Self, input: []const u8) ![]u32 {
            return Backend.encode(input, self.allocator);
        }

        pub fn count(_: *const Self, input: []const u8) !usize {
            return Backend.count(input);
        }

        pub fn decode(self: *const Self, tokens: []const u32) ![]u8 {
            return Backend.decode(tokens, self.allocator);
        }

        pub fn getName() []const u8 {
            return Backend.name;
        }

        pub fn getAccuracy() backend.Accuracy {
            return Backend.accuracy;
        }
    };
}
```

**Checklist:**
- [ ] Generic struct compiles
- [ ] Comptime validation works
- [ ] Methods delegate to Backend correctly
- [ ] Unit test with mock backend

---

### Task 1.3: Migrate O200k Backend

**File:** `src/tokenizer/backends/o200k.zig`

Refactor existing O200k implementation to conform to interface.

```zig
const backend = @import("../backend.zig");
const bpe = @import("../bpe.zig");  // Current implementation

pub const O200kBackend = struct {
    pub const name: []const u8 = "o200k_base";
    pub const accuracy: backend.Accuracy = .exact;

    // Embed vocab data
    const vocab_data = @embedFile("../../data/o200k_base.bin");
    const merge_data = @embedFile("../../data/o200k_merges.bin");

    pub fn encode(input: []const u8, allocator: std.mem.Allocator) ![]u32 {
        // Delegate to existing BPE implementation
        return bpe.encode(vocab_data, merge_data, input, allocator);
    }

    pub fn count(input: []const u8) !usize {
        return bpe.countOnly(vocab_data, merge_data, input);
    }

    pub fn decode(tokens: []const u32, allocator: std.mem.Allocator) ![]u8 {
        return bpe.decode(vocab_data, tokens, allocator);
    }
};

// Compile-time check
comptime {
    backend.assertValidBackend(O200kBackend);
}
```

**Checklist:**
- [ ] Backend struct created
- [ ] Comptime validation passes
- [ ] Existing tests still pass
- [ ] No functional changes to encoding

---

### Task 1.4: Migrate Cl100k Backend

**File:** `src/tokenizer/backends/cl100k.zig`

Same pattern as O200k.

**Checklist:**
- [ ] Backend struct created
- [ ] Comptime validation passes
- [ ] Existing tests still pass

---

### Task 1.5: Create Heuristic Backend

**File:** `src/tokenizer/backends/heuristic.zig`

```zig
const backend = @import("../backend.zig");

pub const HeuristicBackend = struct {
    pub const name: []const u8 = "heuristic";
    pub const accuracy: backend.Accuracy = .estimate;

    /// Approximation: ~4 characters per token for English
    const CHARS_PER_TOKEN: usize = 4;

    pub fn encode(_: []const u8, _: std.mem.Allocator) ![]u32 {
        return error.NotSupported;
    }

    pub fn count(input: []const u8) !usize {
        if (input.len == 0) return 0;
        return (input.len + CHARS_PER_TOKEN - 1) / CHARS_PER_TOKEN;
    }

    pub fn decode(_: []const u32, _: std.mem.Allocator) ![]u8 {
        return error.NotSupported;
    }
};
```

**Checklist:**
- [ ] Backend struct created
- [ ] `encode()` returns NotSupported
- [ ] `count()` returns char_count / 4 (rounded up)
- [ ] Unit tests for edge cases (empty, 1 char, 4 chars, 5 chars)

---

### Task 1.6: Create TokenizerUnion for Runtime Dispatch

**File:** `src/tokenizer/dispatch.zig`

```zig
const tokenizer = @import("tokenizer.zig");
const O200kBackend = @import("backends/o200k.zig").O200kBackend;
const Cl100kBackend = @import("backends/cl100k.zig").Cl100kBackend;
const HeuristicBackend = @import("backends/heuristic.zig").HeuristicBackend;

pub const Encoding = enum {
    o200k_base,
    cl100k_base,
    heuristic,
};

pub const TokenizerUnion = union(Encoding) {
    o200k: tokenizer.Tokenizer(O200kBackend),
    cl100k: tokenizer.Tokenizer(Cl100kBackend),
    heuristic: tokenizer.Tokenizer(HeuristicBackend),

    pub fn init(encoding: Encoding, allocator: std.mem.Allocator) TokenizerUnion {
        return switch (encoding) {
            .o200k_base => .{ .o200k = tokenizer.Tokenizer(O200kBackend).init(allocator) },
            .cl100k_base => .{ .cl100k = tokenizer.Tokenizer(Cl100kBackend).init(allocator) },
            .heuristic => .{ .heuristic = tokenizer.Tokenizer(HeuristicBackend).init(allocator) },
        };
    }

    pub fn count(self: *TokenizerUnion, input: []const u8) !usize {
        return switch (self.*) {
            .o200k => |*t| t.count(input),
            .cl100k => |*t| t.count(input),
            .heuristic => |*t| t.count(input),
        };
    }

    pub fn getAccuracy(self: *const TokenizerUnion) backend.Accuracy {
        return switch (self.*) {
            .o200k => O200kBackend.accuracy,
            .cl100k => Cl100kBackend.accuracy,
            .heuristic => HeuristicBackend.accuracy,
        };
    }
};
```

**Checklist:**
- [ ] Union compiles
- [ ] `init()` creates correct variant
- [ ] `count()` dispatches correctly
- [ ] Integration test with ModelRegistry

---

### Task 1.7: Update ModelRegistry

**File:** `src/model_registry.zig` (modify existing)

Update to use new `Encoding` enum and `TokenizerUnion`.

**Checklist:**
- [ ] Models map to `Encoding` enum
- [ ] `getTokenizer()` returns `TokenizerUnion`
- [ ] All existing model aliases still work
- [ ] `zig build test` passes

---

### Task 1.8: Update Architecture Docs

**File:** `docs/architecture.md`

Add section on Backend architecture:

```markdown
## Tokenizer Backends

llm-cost uses compile-time generics for tokenizer backends:

```
┌─────────────────────────────────────────────────────┐
│                    CLI Layer                        │
├─────────────────────────────────────────────────────┤
│                  ModelRegistry                      │
│         (model name → Encoding mapping)             │
├─────────────────────────────────────────────────────┤
│                 TokenizerUnion                      │
│        (runtime dispatch by Encoding)               │
├──────────┬──────────┬──────────┬───────────────────┤
│ O200k    │ Cl100k   │Heuristic │ (future backends) │
│ Backend  │ Backend  │ Backend  │                   │
├──────────┴──────────┴──────────┴───────────────────┤
│                   BPE Engine                        │
│              (shared implementation)                │
└─────────────────────────────────────────────────────┘
```

### Adding a New Backend

1. Create `src/tokenizer/backends/yourbackend.zig`
2. Implement required interface (encode, count, decode, name, accuracy)
3. Add variant to `TokenizerUnion` in `dispatch.zig`
4. Add encoding to `Encoding` enum
5. Map models to encoding in `ModelRegistry`
6. Add parity tests if accuracy is `.exact`
```

**Checklist:**
- [ ] Architecture diagram added
- [ ] Backend interface documented
- [ ] Extension instructions added

---

### Epic 1 Exit Criteria

- [ ] All backends compile with new interface
- [ ] `zig build test` passes (no regressions)
- [ ] `zig build test-parity` passes
- [ ] `docs/architecture.md` updated
- [ ] No performance regression (benchmark)

---

## Epic 2: BPE v2 (Linear Algorithm)

**Goal:** Replace O(N log N) heap-based BPE with O(N) linear algorithm
**Duration:** 2-3 weken
**Dependencies:** Epic 1 (Backend Architecture)
**Blocks:** Epic 4 (Golden Tests)

### Task 2.1: Research & Document Algorithm

> **NOTE:** Research is DONE. See `docs/technical-challenges-1.5.md` for complete analysis including:
> - Datastructure decisions (index-based linked list vs pointer-based)
> - Critical bugs found in reference implementations
> - Research review of 2024-2025 BPE papers
> - What to adopt vs skip

**File:** `docs/internal/bpe-v2-design.md`

Document the chosen algorithm before implementing:

```markdown
# BPE v2 Algorithm Design

## Overview

Linear BPE using index-based linked list + lazy-delete priority queue.
See `docs/technical-challenges-1.5.md` for detailed rationale.

## Algorithm (Corrected)

1. Pre-tokenize: split on tiktoken-compatible regex pattern
2. For each segment:
   a. Initialize TokenBuffer as index-based linked list
   b. Build MergeQueue with all initial merge candidates
   c. Process merges in RANK order (not position order):
      - Pop from queue with TRIPLE VALIDATION
      - Apply merge in O(1) via linked list pointer update
      - Add new candidates for affected adjacent pairs
   d. Extract final tokens from linked list
3. Concatenate segment results

## Complexity (Corrected)

- Time: O(N log N) - N tokens, log N per heap operation
- Space: O(N) for TokenBuffer arrays + heap
- NOT O(N) pure linear, but much better than O(N²)

## Data Structures (DECIDED)

- `TokenBuffer`: parallel arrays (tokens[], prev[], next[])
  - NOT pointer-based linked list (cache locality)
- `MergeQueue`: std.PriorityQueue with lazy deletion
  - NOT HashMap validity tracking
- `MergeTable`: hash map (u64 key) → MergeEntry

## Critical Implementation Notes

1. Use buffer INDICES as identity, not logical positions
2. Triple validation at every pop: position valid, neighbor exists, rank matches
3. Arena allocator for encode() temporaries
4. Verify O(N log N) scaling with benchmarks

## Research Decisions

| Technology | Decision | Rationale |
|------------|----------|-----------|
| BlockBPE | ❌ Skip | GPU-only |
| LoPT | ⚠️ Fase 2 | Large files only |
| BoundlessBPE | ❌ Never | Breaks parity |
| GitHub bpe style | ✅ Adopt | Production-proven |

## References

- GitHub bpe crate: https://github.com/github/rust-gems/tree/main/crates/bpe
- technical-challenges-1.5.md: Full analysis and corrected code
```

**Checklist:**
- [x] Algorithm documented
- [x] Complexity analysis complete
- [x] Data structures defined
- [x] References listed
- [x] Research review complete (see technical-challenges-1.5.md)
- [ ] Internal design doc written

---

### Task 2.2: Implement MergeTable

**File:** `src/tokenizer/merge_table.zig`

```zig
const std = @import("std");

pub const MergeTable = struct {
    const Entry = struct {
        pair: [2]u32,
        result: u32,
        rank: u32,
    };

    // Perfect hash or sorted array - TBD based on vocab size
    entries: std.AutoHashMap([2]u32, Entry),

    pub fn init(allocator: std.mem.Allocator) MergeTable {
        return .{
            .entries = std.AutoHashMap([2]u32, Entry).init(allocator),
        };
    }

    pub fn loadFromData(self: *MergeTable, data: []const u8) !void {
        // Parse binary merge data format
        // Format: [pair_a: u32][pair_b: u32][result: u32][rank: u32]...
    }

    pub fn lookup(self: *const MergeTable, a: u32, b: u32) ?Entry {
        return self.entries.get(.{ a, b });
    }

    pub fn deinit(self: *MergeTable) void {
        self.entries.deinit();
    }
};
```

**Checklist:**
- [ ] Hash map implementation
- [ ] `loadFromData()` parses merge file
- [ ] `lookup()` is O(1) average
- [ ] Unit tests for lookup

---

### Task 2.3: Implement Pretokenizer

**File:** `src/tokenizer/pretokenizer.zig`

```zig
const std = @import("std");

/// Split input into segments for BPE processing
/// Matches tiktoken's regex pattern
pub fn pretokenize(input: []const u8, allocator: std.mem.Allocator) ![]Segment {
    var segments = std.ArrayList(Segment).init(allocator);

    // Pattern: split on whitespace, keep punctuation separate
    // This should match tiktoken's behavior exactly

    var i: usize = 0;
    while (i < input.len) {
        const segment = nextSegment(input, i);
        try segments.append(segment);
        i = segment.end;
    }

    return segments.toOwnedSlice();
}

pub const Segment = struct {
    start: usize,
    end: usize,
    bytes: []const u8,
};

fn nextSegment(input: []const u8, start: usize) Segment {
    // Implement tiktoken-compatible splitting
    // Key patterns:
    // - Contractions: 's, 't, 're, 've, 'm, 'll, 'd
    // - Whitespace + word
    // - Numbers
    // - Punctuation
}
```

**Checklist:**
- [ ] Regex pattern matches tiktoken
- [ ] Handles UTF-8 correctly
- [ ] Edge cases: empty, single char, only whitespace
- [ ] Parity test against tiktoken pretokenization

---

### Task 2.4: Implement Linear BPE Core

> ⚠️ **CRITICAL**: De code hieronder is een **PLACEHOLDER/SKETCH**. De `findBestMerge` + `applyMerge` loop is O(N²), NIET lineair!
>
> **LEES EERST:** `docs/technical-challenges-1.5.md` sectie "Challenge 2.2-2.5" voor de CORRECTE implementatie met:
> - Index-based TokenBuffer (niet ArrayList)
> - Lazy-delete MergeQueue (niet linear scan)
> - Triple validation bij pop
> - Arena allocator pattern

**File:** `src/tokenizer/bpe_v2.zig`

**Correcte Structuur (zie technical-challenges-1.5.md voor volledige code):**

```zig
const std = @import("std");
const MergeTable = @import("merge_table.zig").MergeTable;
const pretokenizer = @import("pretokenizer.zig");

/// Index-based linked list for O(1) merge operations
pub const TokenBuffer = struct {
    tokens: []u32,
    prev: []u32,
    next: []u32,

    const SENTINEL: u32 = std.math.maxInt(u32);

    pub fn initFromBytes(allocator: std.mem.Allocator, text: []const u8) !TokenBuffer { ... }
    pub fn merge(self: *TokenBuffer, left_pos: u32, merged_token: u32) void { ... }
    pub fn extractTokens(self: *const TokenBuffer, allocator: std.mem.Allocator) ![]u32 { ... }
};

/// Priority queue with lazy deletion
pub const MergeQueue = struct {
    heap: std.PriorityQueue(MergeCandidate, void, MergeCandidate.lessThan),
    buffer: *TokenBuffer,
    merge_table: *const MergeTable,

    /// Pop next VALID merge candidate (triple validation)
    pub fn popValid(self: *MergeQueue) ?MergeCandidate {
        while (self.heap.removeOrNull()) |candidate| {
            // 1. Position still valid?
            if (!self.buffer.isValid(candidate.left_pos)) continue;
            // 2. Right neighbor exists?
            const right_pos = self.buffer.next[candidate.left_pos];
            if (right_pos == TokenBuffer.SENTINEL) continue;
            // 3. Current tokens match expected rank?
            const current = self.merge_table.lookup(
                self.buffer.tokens[candidate.left_pos],
                self.buffer.tokens[right_pos]
            );
            if (current == null or current.?.rank != candidate.rank) continue;

            return candidate;
        }
        return null;
    }
};

pub fn encode(
    merge_table: *const MergeTable,
    input: []const u8,
    allocator: std.mem.Allocator,
) ![]u32 {
    if (input.len == 0) return &[_]u32{};

    // Arena for ALL temporary allocations
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // 1. Pretokenize
    const segments = try pretokenizer.pretokenize(input, alloc);

    // 2. Encode each segment with O(N log N) algorithm
    var result = std.ArrayList(u32).init(allocator);  // From caller's allocator
    for (segments) |segment| {
        const tokens = try encodeSegmentLinear(merge_table, segment.bytes, alloc);
        try result.appendSlice(tokens);
    }

    return result.toOwnedSlice();
}

fn encodeSegmentLinear(
    merge_table: *const MergeTable,
    segment: []const u8,
    allocator: std.mem.Allocator,
) ![]u32 {
    // See technical-challenges-1.5.md Challenge 2.5 for full implementation
    var buffer = try TokenBuffer.initFromBytes(allocator, segment);
    var queue = MergeQueue.init(allocator, &buffer, merge_table);

    // Build initial candidates
    for (0..segment.len - 1) |i| {
        const pos: u32 = @intCast(i);
        if (merge_table.lookup(buffer.tokens[pos], buffer.tokens[pos + 1])) |merge| {
            try queue.add(.{ .rank = merge.rank, .left_pos = pos });
        }
    }

    // Process merges in rank order
    while (queue.popValid()) |candidate| {
        const left_pos = candidate.left_pos;
        const right_pos = buffer.next[left_pos];
        const merge = merge_table.lookup(
            buffer.tokens[left_pos],
            buffer.tokens[right_pos]
        ).?;

        // Apply merge - O(1)
        buffer.merge(left_pos, merge.merged);

        // Add new candidates for adjacent pairs
        const prev_pos = buffer.prev[left_pos];
        if (prev_pos != TokenBuffer.SENTINEL) {
            if (merge_table.lookup(buffer.tokens[prev_pos], merge.merged)) |new_merge| {
                try queue.add(.{ .rank = new_merge.rank, .left_pos = prev_pos });
            }
        }

        const next_pos = buffer.next[left_pos];
        if (next_pos != TokenBuffer.SENTINEL) {
            if (merge_table.lookup(merge.merged, buffer.tokens[next_pos])) |new_merge| {
                try queue.add(.{ .rank = new_merge.rank, .left_pos = left_pos });
            }
        }
    }

    return buffer.extractTokens(allocator);
}
```

**Checklist (UPDATED):**
- [ ] Uses TokenBuffer (index-based), NOT ArrayList
- [ ] Uses MergeQueue with lazy deletion, NOT linear scan
- [ ] Triple validation in popValid()
- [ ] Arena allocator for temporaries
- [ ] `encode()` produces correct tokens
- [ ] `countOnly()` matches `encode().len`
- [ ] `decode(encode(x)) == x` for valid input
- [ ] Handles empty input
- [ ] Handles single character
- [ ] Handles max-length segment
- [ ] **Benchmark confirms O(N log N), NOT O(N²)**

**Verification:**
```bash
# Must show linear-ish scaling, not quadratic
zig build bench -- --size 1000   # ~X ms
zig build bench -- --size 10000  # ~10X ms (linear)
zig build bench -- --size 100000 # ~100X ms (linear)

# If you see ~100X → ~10000X, you have O(N²) bug!
```

---

### Task 2.5: Parity Testing

**Run extensive parity tests against tiktoken**

```bash
# Generate test corpus
python3 -c "
import tiktoken
import json

enc = tiktoken.get_encoding('o200k_base')
test_cases = [
    '',
    'hello',
    'Hello, World!',
    'a' * 10000,
    '🎉' * 100,
    # ... more cases from Evil Corpus
]

for text in test_cases:
    tokens = enc.encode(text)
    print(json.dumps({'text': text, 'tokens': tokens}))
" > testdata/parity/tiktoken_reference.jsonl

# Run parity test
zig build test-parity
```

**Checklist:**
- [ ] All Evil Corpus cases pass
- [ ] 10,000+ random strings pass
- [ ] Edge cases (empty, huge, unicode) pass
- [ ] No off-by-one errors

---

### Task 2.6: Performance Benchmarking

**File:** `src/bench/bpe_compare.zig`

```zig
pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Load test data
    const test_data = try loadTestCorpus(allocator);

    // Benchmark v1 (old heap-based)
    const v1_times = try benchmarkV1(test_data);

    // Benchmark v2 (new linear)
    const v2_times = try benchmarkV2(test_data);

    // Report
    std.debug.print("BPE Performance Comparison\n", .{});
    std.debug.print("==========================\n", .{});
    std.debug.print("Input size: {} bytes\n", .{test_data.len});
    std.debug.print("\n", .{});
    std.debug.print("V1 (heap):   {d:.2} ms\n", .{v1_times.mean});
    std.debug.print("V2 (linear): {d:.2} ms\n", .{v2_times.mean});
    std.debug.print("Speedup:     {d:.2}x\n", .{v1_times.mean / v2_times.mean});
}
```

**Acceptance criteria:**
- [ ] V2 ≥2x faster on worst-case (long repetitions)
- [ ] V2 no regression on typical text
- [ ] V2 scales linearly (2x input → ~2x time)

---

### Task 2.7: Switch Default Engine

**Update backends to use bpe_v2**

```zig
// src/tokenizer/backends/o200k.zig
const bpe = @import("../bpe_v2.zig");  // Changed from bpe.zig
```

**Checklist:**
- [ ] All backends use bpe_v2
- [ ] All tests pass
- [ ] Performance meets targets
- [ ] Old bpe.zig renamed to bpe_v1.zig (kept for reference)

---

### Task 2.8: Update Performance Docs

**File:** `docs/perf.md`

```markdown
## Performance Characteristics

### Complexity

- **Time:** O(N × M) where N = input length, M = merges applied
- **Space:** O(N) peak memory
- **Throughput:** ≥100 MB/s single-threaded on typical text

### Benchmarks

Measured on [hardware description]:

| Input Type | Size | V1 (old) | V2 (current) | Speedup |
|------------|------|----------|--------------|---------|
| Typical text | 1 MB | X ms | Y ms | Z× |
| Worst-case | 1 MB | X ms | Y ms | Z× |
| Code | 1 MB | X ms | Y ms | Z× |

### Scaling

[Graph showing linear scaling with input size]
```

**Checklist:**
- [ ] Complexity documented
- [ ] Benchmark table filled in
- [ ] Hardware context provided
- [ ] Scaling behavior documented

---

### Epic 2 Exit Criteria

- [ ] BPE v2 passes all parity tests
- [ ] Performance ≥2x improvement on worst-case
- [ ] No regression on typical workloads
- [ ] `docs/perf.md` updated with new benchmarks
- [ ] Old implementation archived (not deleted)

---

## Epic 3: CLI Contract

**Goal:** Machine-readable JSON output, stable exit codes
**Duration:** 1 week
**Dependencies:** None (can parallel with Epic 1-2)
**Blocks:** Epic 4 (Golden Tests)

### Task 3.1: Define Exit Codes

**File:** `src/cli/exit_codes.zig`

```zig
pub const ExitCode = enum(u8) {
    ok = 0,
    err_generic = 1,
    err_usage = 2,
    err_quota = 64,
    err_partial = 65,

    pub fn toInt(self: ExitCode) u8 {
        return @intFromEnum(self);
    }

    pub fn fromInt(code: u8) ?ExitCode {
        return std.meta.intToEnum(ExitCode, code) catch null;
    }
};

test "exit codes are BSD-compatible" {
    // 0-2 are standard
    try std.testing.expect(ExitCode.ok.toInt() == 0);
    try std.testing.expect(ExitCode.err_generic.toInt() == 1);
    try std.testing.expect(ExitCode.err_usage.toInt() == 2);

    // 64+ are application-specific (EX_USAGE range)
    try std.testing.expect(ExitCode.err_quota.toInt() >= 64);
    try std.testing.expect(ExitCode.err_partial.toInt() >= 64);
}
```

**Checklist:**
- [ ] Enum defined
- [ ] Values match spec
- [ ] Unit tests pass

---

### Task 3.2: Implement JSON Output Mode

**File:** `src/cli/output.zig`

```zig
const std = @import("std");

pub const OutputFormat = enum {
    text,
    json,
};

pub const OutputWriter = struct {
    format: OutputFormat,
    writer: std.fs.File.Writer,

    pub fn writeRecord(self: *OutputWriter, record: anytype) !void {
        switch (self.format) {
            .text => try self.writeTextRecord(record),
            .json => try self.writeJsonRecord(record),
        }
    }

    fn writeJsonRecord(self: *OutputWriter, record: anytype) !void {
        try std.json.stringify(record, .{}, self.writer);
        try self.writer.writeByte('\n');
    }

    fn writeTextRecord(self: *OutputWriter, record: anytype) !void {
        // Existing text format
    }
};

pub const SummaryFormat = enum {
    text,
    json,
};

pub fn writeSummary(
    writer: std.fs.File.Writer,
    format: SummaryFormat,
    summary: Summary,
) !void {
    switch (format) {
        .text => try writeTextSummary(writer, summary),
        .json => try writeJsonSummary(writer, summary),
    }
}

fn writeJsonSummary(writer: std.fs.File.Writer, summary: Summary) !void {
    const json_summary = .{
        .version = "1",
        .model = summary.model,
        .lines_total = summary.lines_total,
        .lines_failed = summary.lines_failed,
        .tokens_in = summary.tokens_in,
        .tokens_out = summary.tokens_out,
        .cost_input_usd = summary.cost_input_usd,
        .cost_output_usd = summary.cost_output_usd,
        .cost_usd = summary.cost_total_usd,
        .accuracy = @tagName(summary.accuracy),
        .quota_hit = summary.quota_hit,
    };
    try std.json.stringify(json_summary, .{}, writer);
    try writer.writeByte('\n');
}
```

**Checklist:**
- [ ] `--format json` produces valid JSONL
- [ ] `--summary-format json` produces valid JSON
- [ ] Schema matches TDD spec
- [ ] `jq` can parse output

---

### Task 3.3: Implement Quiet Mode

**File:** `src/cli/main.zig` (modify)

```zig
const Args = struct {
    // ... existing fields
    quiet: bool = false,
    format: OutputFormat = .text,
    summary_format: SummaryFormat = .text,
};

fn run(args: Args) !ExitCode {
    // Suppress non-essential output in quiet mode
    const log_writer = if (args.quiet)
        std.io.null_writer
    else
        std.io.getStdErr().writer();

    // ... rest of implementation
}
```

**Checklist:**
- [ ] `--quiet` suppresses progress messages
- [ ] `--quiet` suppresses warnings
- [ ] JSON output still works with `--quiet`
- [ ] Errors still go to stderr

---

### Task 3.4: Update CLI Argument Parser

Add new flags to argument parser:

```zig
const cli_options = [_]clap.Option{
    // ... existing options
    .{ .long = "format", .arg = "text|json", .desc = "Output format" },
    .{ .long = "summary", .desc = "Print summary after processing" },
    .{ .long = "summary-format", .arg = "text|json", .desc = "Summary format" },
    .{ .long = "quiet", .short = 'q', .desc = "Suppress non-essential output" },
};
```

**Checklist:**
- [ ] `--format` parses correctly
- [ ] `--summary-format` parses correctly
- [ ] `--quiet` / `-q` parses correctly
- [ ] `--help` shows new options
- [ ] Invalid format values error properly

---

### Task 3.5: Integrate Exit Codes

**File:** `src/cli/main.zig` (modify)

```zig
pub fn main() u8 {
    const result = runCli() catch |err| {
        std.debug.print("Error: {}\n", .{err});
        return ExitCode.err_generic.toInt();
    };
    return result.toInt();
}

fn runCli() !ExitCode {
    const args = parseArgs() catch {
        return ExitCode.err_usage;
    };

    var state = PipeState{};

    // Process lines
    while (nextLine()) |line| {
        processLine(line, &state) catch {
            state.lines_failed += 1;
            if (args.fail_on_error) {
                return ExitCode.err_generic;
            }
        };

        if (state.quota_exceeded) {
            return ExitCode.err_quota;
        }
    }

    if (state.lines_failed > 0) {
        return ExitCode.err_partial;
    }

    return ExitCode.ok;
}
```

**Checklist:**
- [ ] Exit 0 on success
- [ ] Exit 1 on unexpected error
- [ ] Exit 2 on bad arguments
- [ ] Exit 64 on quota exceeded
- [ ] Exit 65 on partial failure

---

### Task 3.6: Write CLI Documentation

**File:** `docs/cli.md`

```markdown
# CLI Reference

## Commands

### `llm-cost pipe`

Process JSONL stream, add token counts and costs.

```bash
llm-cost pipe [OPTIONS] < input.jsonl > output.jsonl
```

#### Options

| Flag | Default | Description |
|------|---------|-------------|
| `--model <name>` | required | Model for pricing (e.g., `openai/gpt-4o`) |
| `--mode <tokens\|price>` | `tokens` | Output mode |
| `--format <text\|json>` | `text` | Record output format |
| `--field <name>` | `text` | JSONL field containing text |
| `--summary` | off | Print summary after processing |
| `--summary-format <text\|json>` | `text` | Summary output format |
| `--quiet`, `-q` | off | Suppress progress/warnings |
| `--max-tokens <N>` | none | Stop after N tokens |
| `--max-cost <USD>` | none | Stop after $USD |
| `--fail-on-error` | off | Exit on first line error |

#### Exit Codes

| Code | Name | Meaning |
|------|------|---------|
| 0 | OK | All lines processed successfully |
| 1 | ERROR | Unexpected runtime error |
| 2 | USAGE | Invalid arguments |
| 64 | QUOTA | Token or cost limit reached |
| 65 | PARTIAL | Some lines failed, stream completed |

#### JSON Output Schema

**Record (--format json):**
```json
{
  "tokens_in": 150,
  "tokens_out": 0,
  "cost_input_usd": 0.000375,
  "cost_output_usd": 0,
  "cost_usd": 0.000375,
  "accuracy": "exact",
  "original_field": "preserved"
}
```

**Summary (--summary-format json):**
```json
{
  "version": "1",
  "model": "openai/gpt-4o",
  "lines_total": 1000,
  "lines_failed": 3,
  "tokens_in": 150000,
  "tokens_out": 0,
  "cost_input_usd": 0.375,
  "cost_output_usd": 0,
  "cost_usd": 0.375,
  "accuracy": "exact",
  "quota_hit": false
}
```
```

**Checklist:**
- [ ] All options documented
- [ ] Exit codes table
- [ ] JSON schemas with examples
- [ ] Usage examples

---

### Epic 3 Exit Criteria

- [ ] `--format json` works
- [ ] `--summary-format json` works
- [ ] `--quiet` works
- [ ] All exit codes implemented
- [ ] `docs/cli.md` complete
- [ ] `jq` can parse all JSON output

---

## Epic 4: Golden Tests

**Goal:** CLI contract tests that catch regressions
**Duration:** 3-4 dagen
**Dependencies:** Epic 3 (CLI Contract)
**Blocks:** Release

### Task 4.1: Create Test Fixtures

**Directory:** `testdata/golden/`

```
testdata/golden/
├── README.md
├── chat_sample/
│   ├── input.jsonl
│   ├── expect.tokens.json.jsonl
│   ├── expect.price.json.jsonl
│   └── expect.summary.json
├── adversarial/
│   ├── input.jsonl
│   ├── expect.tokens.json.jsonl
│   └── expect.summary.json
├── large/
│   ├── input.jsonl
│   └── expect.summary.json
└── errors/
    ├── input.jsonl
    ├── expect.partial.jsonl
    └── expect.summary.json
```

**chat_sample/input.jsonl:**
```json
{"id": 1, "text": "Hello, world!"}
{"id": 2, "text": "How are you today?"}
{"id": 3, "text": "The quick brown fox jumps over the lazy dog."}
...
```

**Checklist:**
- [ ] chat_sample: 50+ normal lines
- [ ] adversarial: edge cases from Evil Corpus
- [ ] large: 1000+ lines for perf
- [ ] errors: lines that should fail parsing

---

### Task 4.2: Implement Golden Test Runner

**File:** `src/test/golden.zig`

```zig
const std = @import("std");

const TestCase = struct {
    name: []const u8,
    input_file: []const u8,
    expected_file: []const u8,
    args: []const []const u8,
    expected_exit: u8,
};

const test_cases = [_]TestCase{
    .{
        .name = "chat_sample tokens json",
        .input_file = "testdata/golden/chat_sample/input.jsonl",
        .expected_file = "testdata/golden/chat_sample/expect.tokens.json.jsonl",
        .args = &.{ "pipe", "--model", "openai/gpt-4o", "--mode", "tokens", "--format", "json" },
        .expected_exit = 0,
    },
    // ... more cases
};

pub fn main() !void {
    var passed: usize = 0;
    var failed: usize = 0;

    for (test_cases) |tc| {
        const result = runTest(tc) catch |err| {
            std.debug.print("FAIL: {s} - {}\n", .{ tc.name, err });
            failed += 1;
            continue;
        };

        if (result) {
            std.debug.print("PASS: {s}\n", .{tc.name});
            passed += 1;
        } else {
            std.debug.print("FAIL: {s}\n", .{tc.name});
            failed += 1;
        }
    }

    std.debug.print("\n{} passed, {} failed\n", .{ passed, failed });

    if (failed > 0) {
        std.process.exit(1);
    }
}

fn runTest(tc: TestCase) !bool {
    // 1. Run llm-cost with args, input from file
    // 2. Capture stdout
    // 3. Compare with expected (semantic JSON comparison)
    // 4. Check exit code
}

fn compareJsonl(actual: []const u8, expected: []const u8) bool {
    // Parse both as JSONL
    // Compare field by field (ignore order within objects)
    // Allow float tolerance for cost fields
}
```

**Checklist:**
- [ ] Runner executes llm-cost binary
- [ ] Captures stdout and exit code
- [ ] Semantic JSON comparison (not byte-exact)
- [ ] Float tolerance for costs
- [ ] Clear pass/fail output

---

### Task 4.3: Add to Build System

**File:** `build.zig` (modify)

```zig
const golden_test = b.addExecutable(.{
    .name = "test-golden",
    .root_source_file = .{ .path = "src/test/golden.zig" },
    .target = target,
    .optimize = optimize,
});

const run_golden = b.addRunArtifact(golden_test);
run_golden.step.dependOn(b.getInstallStep()); // Needs llm-cost binary

const golden_step = b.step("test-golden", "Run golden tests");
golden_step.dependOn(&run_golden.step);
```

**Checklist:**
- [ ] `zig build test-golden` works
- [ ] Depends on main binary being built
- [ ] Exit code reflects test results

---

### Task 4.4: Add to CI

**File:** `.github/workflows/ci.yml` (modify)

```yaml
- name: Run golden tests
  run: zig build test-golden
```

**Checklist:**
- [ ] Golden tests in CI pipeline
- [ ] Failures block PR merge

---

### Task 4.5: Create Update Script

**File:** `tools/update-golden.sh`

```bash
#!/bin/bash
set -euo pipefail

# Regenerate golden files from current implementation
# Use with caution - only when intentionally changing output format

echo "Regenerating golden files..."

for dir in testdata/golden/*/; do
    name=$(basename "$dir")
    echo "Processing $name..."

    if [[ -f "$dir/input.jsonl" ]]; then
        # Generate tokens output
        ./zig-out/bin/llm-cost pipe \
            --model openai/gpt-4o \
            --mode tokens \
            --format json \
            < "$dir/input.jsonl" \
            > "$dir/expect.tokens.json.jsonl"

        # Generate summary
        ./zig-out/bin/llm-cost pipe \
            --model openai/gpt-4o \
            --mode tokens \
            --format json \
            --summary \
            --summary-format json \
            < "$dir/input.jsonl" \
            > /dev/null \
            2> "$dir/expect.summary.json"
    fi
done

echo "Done. Review changes before committing!"
```

**Checklist:**
- [ ] Script generates all expected files
- [ ] Outputs warning to review before commit
- [ ] Documented in `testdata/golden/README.md`

---

### Epic 4 Exit Criteria

- [ ] All golden test fixtures created
- [ ] `zig build test-golden` passes
- [ ] Golden tests in CI
- [ ] Update script documented

---

## Epic 5: Pricing v2

**Goal:** Input/output cost split, honest scope documentation
**Duration:** 2-3 dagen
**Dependencies:** None
**Blocks:** Epic 4 (needs updated output schema)

### Task 5.1: Update CostBreakdown Struct

See TDD Section 5.1 for implementation.

**Checklist:**
- [ ] Struct has input/output split
- [ ] `calculate()` method works
- [ ] Unit tests pass

---

### Task 5.2: Update Pricing Database

**File:** `data/pricing.json`

Add `input_per_million` and `output_per_million` fields for all models.

**Checklist:**
- [ ] All models have split pricing
- [ ] `cached_input_per_million` where applicable
- [ ] `effective_date` for audit trail
- [ ] Schema version bumped to "2"

---

### Task 5.3: Write Scope Documentation

**File:** `docs/pricing.md`

See TDD Section 5.3 for content.

**Checklist:**
- [ ] "CAN tell you" section
- [ ] "CANNOT tell you" section
- [ ] Recommended workflow

---

### Epic 5 Exit Criteria

- [ ] Cost output includes input/output split
- [ ] Pricing DB updated
- [ ] Scope documented in `docs/pricing.md`
- [ ] README updated with scope statement

---

## Epic 6: Legal & Vocab

**Goal:** NOTICE file, vocab traceability
**Duration:** 1 dag
**Dependencies:** None
**Blocks:** Release

### Task 6.1: Create NOTICE File

**File:** `NOTICE`

```
llm-cost
Copyright (c) 2024-2025 [Your Name/Organization]

This software is licensed under the MIT License.
See LICENSE file for details.

---

This software includes data derived from the following sources:

tiktoken
https://github.com/openai/tiktoken
Copyright (c) 2022 OpenAI
Licensed under MIT License

Embedded vocabulary files:
- o200k_base tokenizer vocabulary (derived from tiktoken)
- cl100k_base tokenizer vocabulary (derived from tiktoken)

These vocabulary files are used for token encoding/decoding
and are distributed under the same MIT license as tiktoken.
```

**Checklist:**
- [ ] File created
- [ ] Attribution complete
- [ ] License referenced

---

### Task 6.2: Create Vocab Documentation

**File:** `docs/vocab.md`

```markdown
# Vocabulary Files

## Embedded Vocabularies

llm-cost embeds vocabulary data for supported tokenizers.

### o200k_base

- **Source:** tiktoken (OpenAI)
- **Repository:** https://github.com/openai/tiktoken
- **Commit:** [specific commit hash]
- **License:** MIT
- **Used by:** GPT-4o, GPT-4o-mini, GPT-4-turbo (2024+)

### cl100k_base

- **Source:** tiktoken (OpenAI)
- **Repository:** https://github.com/openai/tiktoken
- **Commit:** [specific commit hash]
- **License:** MIT
- **Used by:** GPT-4, GPT-3.5-turbo, text-embedding-ada-002

## Custom Vocabularies

Currently not supported. See [issue #XX] for planned extensibility.

## Updating Vocabularies

To update embedded vocabularies:

1. Download new vocab file from tiktoken releases
2. Convert to llm-cost binary format: `python tools/convert_vocab.py`
3. Update commit reference in this document
4. Run parity tests: `zig build test-parity`
5. Update NOTICE file if license changed
```

**Checklist:**
- [ ] Source commits documented
- [ ] License info for each vocab
- [ ] Update process documented

---

### Epic 6 Exit Criteria

- [ ] NOTICE file present
- [ ] `docs/vocab.md` complete
- [ ] CI checks NOTICE exists

---

## Epic 7: SLSA & Release Hardening

**Goal:** SLSA Level 2 with provenance attestations
**Duration:** 1-2 dagen
**Dependencies:** All other epics
**Blocks:** Release

### Task 7.1: Pin All GitHub Actions

**File:** `.github/workflows/*.yml`

Replace all tag references with SHA:

```yaml
# Before
- uses: actions/checkout@v4

# After
- uses: actions/checkout@b4ffde65f46336ab88eb53be808477a3936bae11 # v4.1.1
```

**Checklist:**
- [ ] All `actions/*` pinned
- [ ] All third-party actions pinned
- [ ] Comments show version for readability

---

### Task 7.2: Add SLSA Provenance

**File:** `.github/workflows/release.yml`

See TDD Section 7.2 for implementation.

**Checklist:**
- [ ] Provenance job added
- [ ] `.intoto.jsonl` generated
- [ ] Published with release

---

### Task 7.3: Update Security Documentation

**File:** `docs/security.md`

```markdown
# Security

## Supply Chain

### SLSA Build Level 2

llm-cost releases conform to [SLSA Build Level 2](https://slsa.dev/spec/v1.0/levels#build-l2):

- ✅ Scripted build (build.zig)
- ✅ Version controlled source
- ✅ Hosted build service (GitHub Actions)
- ✅ Signed provenance attestations

### Verification

Verify a release artifact:

```bash
# Install slsa-verifier
go install github.com/slsa-framework/slsa-verifier/v2/cli/slsa-verifier@latest

# Verify provenance
slsa-verifier verify-artifact llm-cost-x86_64-linux \
  --provenance-path llm-cost-x86_64-linux.intoto.jsonl \
  --source-uri github.com/your-org/llm-cost \
  --source-tag v0.5.0
```

### SBOM

Each release includes a CycloneDX SBOM (`sbom.cdx.json`).

### Cosign Signatures

Binaries are signed with keyless Cosign:

```bash
cosign verify-blob \
  --certificate llm-cost-x86_64-linux.crt \
  --signature llm-cost-x86_64-linux.sig \
  llm-cost-x86_64-linux
```

## Reporting Vulnerabilities

Email security@[your-domain] with:
- Description of vulnerability
- Steps to reproduce
- Impact assessment

Response time: 48 hours for acknowledgment, 7 days for initial assessment.
```

**Checklist:**
- [ ] SLSA claim explicit
- [ ] Verification commands work
- [ ] Reporting process documented

---

### Epic 7 Exit Criteria

- [ ] All actions pinned
- [ ] Provenance in releases
- [ ] `docs/security.md` updated
- [ ] `slsa-verifier` validates release

---

## Master Checklist

### Pre-Release Gate

All must be checked before tagging v0.5.0:

**Tests:**
- [ ] `zig build test` passes
- [ ] `zig build test-parity` passes
- [ ] `zig build test-golden` passes
- [ ] `zig build fuzz` runs without crashes (1 hour)

**Performance:**
- [ ] BPE v2 benchmarks documented
- [ ] No regression on typical workloads
- [ ] Worst-case shows linear scaling

**Documentation:**
- [ ] `docs/architecture.md` current
- [ ] `docs/cli.md` complete
- [ ] `docs/perf.md` updated with v2 numbers
- [ ] `docs/pricing.md` scope statement
- [ ] `docs/security.md` SLSA claim
- [ ] `docs/vocab.md` traceability
- [ ] NOTICE file present
- [ ] CHANGELOG updated

**CI/CD:**
- [ ] All actions pinned
- [ ] Provenance generation works
- [ ] Golden tests in CI

**Release:**
- [ ] Version bumped to 0.5.0
- [ ] Tag signed
- [ ] Artifacts uploaded
- [ ] Provenance published
- [ ] SBOM published
