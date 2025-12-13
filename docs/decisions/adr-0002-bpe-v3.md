
# ADR-0002 – BPE v3: Index-Based Merge Engine & Evolution Path

**Status:** Proposed
**Date:** 2025-12-09
**Scope:** Internal BPE engine for `llm-cost` v0.4+ (post Phase 1.5)
**Relations:** Builds on ADR-0001 (BPE v2, pricing v2, CLI contract)

This ADR defines the next step in the tokenizer architecture:
*   BPE v3 engine with index-based data structures
*   Correct complexity claims: v2/v3a = O(N log N), v3b = O(N)
*   Evolution path to bucket queue for true O(N) merges
*   Better memory and allocation behaviors (arena, cache-friendly arrays)

BPE v2 remains the reference implementation after Phase 1.5. BPE v3 is an internal improvement behind the same public interface.

---

## 1. Context & Problem

BPE v2 (ADR-0001) has:
*   Pure Zig implementation
*   O(1) rank lookup via `StringHashMap`
*   Heap-based merges: worst-case O(N log N)
*   Strong performance and strict parity with tiktoken data (o200k/cl100k)

**New insights from design/research review:**

1.  **Complexity & Honesty**
    *   Heap-based BPE is worst-case O(N log N), not strictly O(N).
    *   This is practically fine, but we want to structure the data so that O(N) via a bucket queue is a straight upgrade.

2.  **Data Structures**
    *   Pointer-based linked lists have poor cache locality and high allocation overhead.
    *   An index-based buffer (parallel arrays) is:
        *   Cache-friendly.
        *   Easy to debug.
        *   Good to combine with rank-buckets.

3.  **Lazy Deletion & Validation**
    *   Position-based validation (bitfields on original positions) becomes fragile after merges.
    *   We want a 4-point lazy validation based on indices and a `valid[]` array with O(1) check.

---

## 2. Goals

*   **Correct Complexity & Documentation**
    *   **BPE v3a:** Honest O(N log N) via min-heap.
    *   **BPE v3b:** Path to O(N) via bucket queue (rank-buckets).

*   **Better Data Structures**
    *   Index-based `TokenBuffer` with `tokens[]`, `prev[]`, `next[]`, `valid[]`.

*   **Robust Lazy Deletion**
    *   Candidates in the queue may be "stale"; filtered via a 4-step check without UB.

*   **Low-Overhead Allocations**
    *   One `ArenaAllocator` per `encode()` call; no per-node `create()` calls.

*   **Drop-in Replacement**
    *   Same high-level interface as BPE v2 (`init`/`encode`/`deinit`).
    *   Same vocabs, same token-ID output (parity).

---

## 3. Non-Goals

Not in scope for this ADR:
*   BoundlessBPE / merges over regex-pretokenizer boundaries (breaks tiktoken parity).
*   R-BPE caching of frequent merge paths.
*   GPU / BlockBPE CUDA-style kernels.
*   LoPT-style chunking for ultra-large files (maybe later in a `--file`/offline-analysis mode).

---

## 4. High-Level Design

### 4.1 Core Concept

We reformulate BPE merge around three core components:

1.  **TokenBuffer** – Index-based "linked list":
    *   All tokens in parallel arrays (`tokens`, `prev`, `next`, `valid`).
    *   `prev[i]` / `next[i]` refer to indices or `SENTINEL`.
    *   `valid[i]` allows O(1) liveness checks.

2.  **MergeTable** – `(left_id, right_id) -> (merged_id, rank)`:
    *   Hash map or compact table providing rank and merged token.
    *   Rank determines global merge order (lower rank = earlier).

3.  **MergeQueue** – Sorted merge candidates:
    *   **v3a (Phase 1.5):** Min-heap -> O(N log N) worst-case.
    *   **v3b (BPE v3):** Bucket queue (rank-buckets) -> O(N) total.

`OpenAITokenizer` remains a thin layer above this engine.

---

## 5. Data Structures

### 5.1 TokenBuffer – Index-based linked list + valid[]

```zig
const std = @import("std");

pub const TokenId = u32;
pub const Index = u32;

pub const TokenBuffer = struct {
    tokens: []TokenId,
    prev:   []Index,
    next:   []Index,
    valid:  []bool, // O(1) validity check

    pub const SENTINEL: Index = std.math.maxInt(Index);

    pub fn initFromBytes(a: std.mem.Allocator, bytes: []const u8) !TokenBuffer {
        const n = bytes.len;
        var tokens = try a.alloc(TokenId, n);
        var prev   = try a.alloc(Index, n);
        var next   = try a.alloc(Index, n);
        var valid  = try a.alloc(bool, n);

        for (bytes, 0..) |b, i| {
            tokens[i] = @as(TokenId, b); // byte-level token
            prev[i]   = if (i == 0) SENTINEL else @intCast(i - 1);
            next[i]   = if (i + 1 == n) SENTINEL else @intCast(i + 1);
            valid[i]  = true;
        }

        return .{
            .tokens = tokens,
            .prev = prev,
            .next = next,
            .valid = valid,
        };
    }

    pub fn isValid(self: *const TokenBuffer, pos: Index) bool {
        return self.valid[pos];
    }

    pub fn merge(self: *TokenBuffer, left: Index, merged_token: TokenId) void {
        const right = self.next[left];
        if (right == SENTINEL) return; // defensive

        const right_next = self.next[right];

        // Update left node
        self.tokens[left] = merged_token;
        self.next[left] = right_next;

        if (right_next != SENTINEL) {
            self.prev[right_next] = left;
        }

        // Mark right as dead
        self.valid[right] = false;
        self.prev[right] = SENTINEL;
        self.next[right] = SENTINEL;
    }
};
```

**Important:** `isValid()` is now a simple array lookup (O(1)), no longer O(N).

### 5.2 MergeTable – pair -> merge entry

```zig
pub const Rank = u32;

pub const MergeEntry = struct {
    merged: TokenId,
    rank: Rank,
};

pub const MergeTable = struct {
    map: std.AutoHashMap(u64, MergeEntry),

    pub fn init(a: std.mem.Allocator, capacity_hint: usize) MergeTable {
        var m = std.AutoHashMap(u64, MergeEntry).init(a);
        m.ensureTotalCapacity(@intCast(capacity_hint)) catch {};
        return .{ .map = m };
    }

    fn key(left: TokenId, right: TokenId) u64 {
        return (@as(u64, left) << 32) | @as(u64, right);
    }

    pub fn put(self: *MergeTable, left: TokenId, right: TokenId, merged: TokenId, rank: Rank) !void {
        try self.map.put(key(left, right), .{ .merged = merged, .rank = rank });
    }

    pub fn lookup(self: *const MergeTable, left: TokenId, right: TokenId) ?MergeEntry {
        return self.map.get(key(left, right));
    }

    pub fn deinit(self: *MergeTable) void {
        self.map.deinit();
    }
};
```

### 5.3 MergeQueue v3a – Min-heap

```zig
const MergeCandidate = struct {
    rank: Rank,
    left: Index, // left index in TokenBuffer

    pub fn lessThan(_: void, a: MergeCandidate, b: MergeCandidate) bool {
        if (a.rank != b.rank) return a.rank < b.rank;
        return a.left < b.left; // tie-break: leftmost
    }
};

pub const MergeQueue = struct {
    heap: std.PriorityQueue(MergeCandidate, void, MergeCandidate.lessThan),

    pub fn init(a: std.mem.Allocator) MergeQueue {
        return .{
            .heap = std.PriorityQueue(MergeCandidate, void, MergeCandidate.lessThan).init(a, {}),
        };
    }

    pub fn add(self: *MergeQueue, cand: MergeCandidate) !void {
        try self.heap.add(cand);
    }

    pub fn pop(self: *MergeQueue) ?MergeCandidate {
        return self.heap.removeOrNull();
    }

    pub fn deinit(self: *MergeQueue) void {
        self.heap.deinit();
    }
};
```

---

## 6. Algorithm – BPE v3a Encode

### 6.1 Lazy Merge Loop with 4-Point Validation

Core of `encodeWord` (pseudo):

```zig
fn encodeWord(
    self: *const BpeEngineV3,
    alloc: std.mem.Allocator,
    word_bytes: []const u8,
    out: *std.ArrayList(TokenId),
) !void {
    if (word_bytes.len == 0) return;

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var buf = try TokenBuffer.initFromBytes(a, word_bytes);
    var queue = MergeQueue.init(a);
    defer queue.deinit();

    // Initial candidates
    var i: Index = 0;
    while (i != TokenBuffer.SENTINEL) : (i = buf.next[i]) {
        const j = buf.next[i];
        if (j == TokenBuffer.SENTINEL) break;

        if (self.merge_table.lookup(buf.tokens[i], buf.tokens[j])) |entry| {
            try queue.add(.{ .rank = entry.rank, .left = i });
        }
    }

    // Merge loop – 4-point validation
    while (queue.pop()) |cand| {
        const left = cand.left;

        // 1. Left position still valid?
        if (!buf.isValid(left)) continue;

        // 2. Right neighbor exists?
        const right = buf.next[left];
        if (right == TokenBuffer.SENTINEL) continue;

        // 3. Right position still valid?
        if (!buf.isValid(right)) continue;

        // 4. Tokens + rank match?
        const maybe = self.merge_table.lookup(buf.tokens[left], buf.tokens[right]) orelse continue;
        if (maybe.rank != cand.rank) continue;

        // Merge
        buf.merge(left, maybe.merged);

        // New candidate (prev, left)
        const prev = buf.prev[left];
        if (prev != TokenBuffer.SENTINEL and buf.isValid(prev)) {
            if (self.merge_table.lookup(buf.tokens[prev], buf.tokens[left])) |m| {
                try queue.add(.{ .rank = m.rank, .left = prev });
            }
        }

        // New candidate (left, next)
        const next = buf.next[left];
        if (next != TokenBuffer.SENTINEL and buf.isValid(next)) {
            if (self.merge_table.lookup(buf.tokens[left], buf.tokens[next])) |m| {
                try queue.add(.{ .rank = m.rank, .left = left });
            }
        }
    }

    // Result collection
    var idx = 0; // Assuming 0 is always the start, or finding the first valid one
    // NOTE: Need to find the actual head if array usage changes, but for now 0 is start if we don't move head.
    // Ideally find first valid:
    // var idx: Index = 0; while (idx < buf.tokens.len and !buf.isValid(idx)) idx += 1;
    // But since we preserve left, 0 is always the start of logic, unless merged into prev?
    // Actually, if we only merge update left, the list head is stable at 0 unless 0 is right-merged.
    // Wait, logical head is always 0.
    var curr: Index = 0;
    while (curr != TokenBuffer.SENTINEL) : (curr = buf.next[curr]) {
         // Valid check implicit by following next pointers from a valid head?
         // Defensive check:
         if (buf.isValid(curr)) {
             try out.append(buf.tokens[curr]);
         }
    }
}
```

This is lazy deletion done right:
*   Old heap entries can linger.
*   4-point check guarantees we only execute merges that are consistent with the current buffer state.

---

## 7. Complexity

Let:
*   N = # initial tokens (bytes per word/segment),
*   M = # actual merges (M <= N - 1).

### 7.1 BPE v3a (Min-Heap)
*   `TokenBuffer.initFromBytes` – O(N)
*   Initial candidate scan – O(N)
*   Heap inserts:
    *   Init: O(N log N)
    *   During merges: worst-case O(M log N)
*   Merge loop: each pop/push O(log N)

**Total:** O((N + M) log N) worst-case -> **O(N log N)**.

### 7.2 Challenge 2.6 – O(N log N) -> O(N) with Bucket Queue

We define a bucket queue:

```zig
pub const BucketQueue = struct {
    bucket_heads: []Index,   // List head per rank
    next_in_bucket: []Index, // Linked list next pointer per candidate
    current_rank: Rank,      // Lowest known non-empty rank

    // add: O(1) – prepend in bucket[rank]
    // popBest: O(1) amortized – scan up from current_rank
};
```

**Comparison:**

| Operation | Min-Heap | Bucket Queue |
| :--- | :--- | :--- |
| Build | O(N log N) | O(N) |
| Pop | O(log N) | O(1) amortized |
| **Total** | **O(N log N)** | **O(N)** |

For fixed vocabs (rank range bounded) and meaningful maximum rank, this is a true O(N) implementation.

---

## 8. BPE Engine Evolution Path (v1 -> v2 -> v3)

### 8.1 Version Matrix

| Version | Engine | Data Structure | Queue | Complexity |
| :--- | :--- | :--- | :--- | :--- |
| v1 | "legacy" | Simple array/scan | Naive scan | O(N²) worst |
| v2 | BPE v2 | Pointer-based list | Min-heap | O(N log N) |
| v3a | BPE v3 (heap) | Index-based list | Min-heap | O(N log N) |
| v3b | BPE v3 (bq) | Index-based list | Bucket Q | O(N) |

### 8.2 Design Sketch – Core Decisions

*   **Migrate from pointer-based to index-based data structures:**
    *   Better cache behavior.
    *   Fewer allocations (one block, no `create()` spam).
    *   Simple lazy deletion via `valid[]`.
*   **Merge queue starts as min-heap (v3a):**
    *   Simple, easy to test, matches existing mental models.
    *   Correct O(N log N) claim, strictly better than O(N²) variants.
*   **Later switch to Bucket Queue (v3b) without API break:**
    *   Same `MergeCandidate` concept.
    *   Different internal queue implementation.

### 8.3 Exit Criteria for v3 (v3a/v3b)

**BPE v3a (heap)** may replace BPE v2 if:
1.  **Evil Corpus parity tests:** 100% match with tiktoken output.
2.  **Fuzz tests:** UTF-8 random, emoji, CJK, adversarial "aaaa..."; no deviation vs v2.
3.  **Performance:** No regression >10% vs v2 in ns/token on:
    *   Realistic JSONL.
    *   Worst-case `a * N`.
    *   Emoji stress.

**BPE v3b (bucket queue)** gets its own ADR/flag and is enabled if:
1.  Parity remains 100% vs v3a (golden tests).
2.  Measurable speedup (>= 1.2x) on large N (long contexts).
3.  Implementation remains maintainable (no bizarrely complex rank-space management).

---

## 9. Priority Stack (Phase / Complexity)

**Updated Priorities:**

| Prio | Component | Phase | Complexity |
| :--- | :--- | :--- | :--- |
| 1–4 | TokenBuffer + MergeQueue (heap) + Arena + Pre-tokenizer | 1.5 | O(N log N) |
| 5 | SIMD pre-tokenizer scan (whitespace/boundaries) | Optional | O(N) |
| 6 | Bucket Queue (rank-buckets) | v3 | O(N) |
| 7 | LoPT chunking for mega-files | Phase 2+ | O(N) / MT |

**Key Takeaway:**
*   **Phase 1.5:** Implement BPE v3a with min-heap -> O(N log N), correct, simple, fast enough.
*   **BPE v3 (Later):** Upgrade internally to bucket queue -> O(N), but only if benchmarks prove it worthwhile.

---

## 10. Interaction with Existing Code

*   `OpenAITokenizer` API remains unchanged.
*   `BpeEngineV3` replaces `BpeEngineV2` behind the same interface:
    *   `init(alloc, vocab_data)`
    *   `encode(alloc, pre_tokens)`
*   `docs/perf.md` gets benchmarks for:
    *   v2 vs v3a (Phase 1.5).
    *   Later optionally v3a vs v3b.

---

## 11. Risks & Mitigations

| Risk | Impact | Mitigation |
| :--- | :--- | :--- |
| Merge-order / rank edge cases | High | Evil Corpus + fuzzing vs tiktoken/v2/v3a |
| Index overflow (>4B tokens/segment) | Medium | Index = u32, explicit error on oversized input |
| Perf regression vs v2 | Medium | Perf golden tests; keep v2 temporarily |
| Bucket queue complexity | Medium | Separate ADR, implement after stable v3a |
| SIMD portability | Low | Scalar fallback, pre-tokenizer path only |
