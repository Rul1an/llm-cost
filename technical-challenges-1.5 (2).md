# Technical Challenges: Fase 1.5

**Version:** 2.0
**Status:** Draft
**Author:** [Maintainer]
**Date:** 2025-01
**Last Updated:** 2025-01 (added datastructure analysis, research review, bug fixes)

---

Dit document beschrijft de technische uitdagingen, valkuilen en risico's per epic. Lees dit voordat je begint met implementeren.

> ⚠️ **CRITICAL UPDATE v2.0**: Dit document bevat nu een gedetailleerde analyse van datastructure keuzes, kritieke bugs in reference implementations, en een research review van 2024-2025 BPE papers. Lees vooral de nieuwe secties in Epic 2.

---

## Epic 1: Backend Architecture Refactor

### Challenge 1.1: Comptime Interface Validation

**Probleem:**
Zig's comptime is krachtig maar de foutmeldingen zijn cryptisch. Als een backend niet aan de interface voldoet, krijg je een compile error diep in de generic instantiatie, niet bij de backend definitie.

**Voorbeeld van slechte error:**
```
src/tokenizer/tokenizer.zig:47:23: error: expected type '[]u32', found 'void'
    return Backend.encode(input, self.allocator);
           ~~~~~~^
```

**Oplossing:**
```zig
// Expliciete comptime check met duidelijke error
comptime {
    if (!@hasDecl(Backend, "encode")) {
        @compileError("Backend '" ++ @typeName(Backend) ++ "' missing required function 'encode'");
    }
    // Check signature
    const encode_info = @typeInfo(@TypeOf(Backend.encode));
    if (encode_info != .Fn) {
        @compileError("Backend.encode must be a function");
    }
}
```

**Verwachte tijdverlies:** 0.5-1 dag voor goede error messages

---

### Challenge 1.2: Embedded Data en Comptime

**Probleem:**
`@embedFile` werkt alleen met comptime-known paths. Je kunt niet dynamisch een vocab file laden op basis van runtime model selection.

**Implicatie:**
```zig
// Dit werkt NIET:
pub fn loadVocab(model: []const u8) []const u8 {
    const path = "data/" ++ model ++ ".bin";  // Error: runtime value
    return @embedFile(path);
}

// Dit werkt WEL:
pub const O200kBackend = struct {
    const vocab = @embedFile("data/o200k_base.bin");  // Comptime known
};
```

**Consequentie:**
Elke vocab moet een aparte Backend struct hebben. Je kunt niet één generic BPE backend maken die verschillende vocabs laadt.

**Workaround:**
Accept this limitation. One backend per encoding is fine for 2-3 encodings. If you need 10+ encodings, consider build-time code generation.

---

### Challenge 1.3: Tagged Union Overhead

**Probleem:**
`TokenizerUnion` met switch-dispatch heeft runtime overhead vs direct comptime dispatch. Elke `count()` call gaat door een switch.

**Benchmark verschil:**
Typisch 5-15ns overhead per call. Bij 1M lines = 5-15ms extra. Acceptabel, maar meetbaar.

**Alternatieven overwogen:**

| Approach | Overhead | Flexibility |
|----------|----------|-------------|
| Tagged union + switch | 5-15ns/call | Runtime model selection |
| Function pointers (vtable) | 10-20ns/call | Runtime, maar cache miss |
| Comptime only | 0ns | No runtime flexibility |
| Separate binaries per model | 0ns | Deployment nightmare |

**Beslissing:** Tagged union is de juiste trade-off voor een CLI tool.

---

### Challenge 1.4: Backend State Management

**Probleem:**
Sommige backends zijn stateless (Heuristic), anderen hebben state (BPE met cached merge table). De interface moet beide ondersteunen.

**Valkuil:**
```zig
// Stateless - geen probleem
pub const HeuristicBackend = struct {
    pub fn count(input: []const u8) !usize { ... }
};

// Stateful - hoe init je dit?
pub const O200kBackend = struct {
    merge_table: MergeTable,  // Moet geïnitialiseerd worden

    pub fn count(self: *const O200kBackend, input: []const u8) !usize { ... }
};
```

**Oplossing:**
Maak BPE state implicit via module-level of comptime-initialized data:

```zig
pub const O200kBackend = struct {
    // Comptime initialized, no runtime state needed
    const merge_table = comptime MergeTable.initFromData(@embedFile("merges.bin"));

    pub fn count(input: []const u8) !usize {
        return bpe.countWithTable(merge_table, input);
    }
};
```

**Risico:** Comptime merge table parsing kan build time significant verhogen (10-30 seconden voor grote vocabs).

---

## Epic 2: BPE v2 (Linear Algorithm)

### Challenge 2.1: Het "Naïeve Lineair" Misverstand

**KRITIEK - LEES DIT:**

De code in het implementation plan is **NIET lineair**. Dit is een veelgemaakte fout:

```zig
// FOUT - Dit is O(N²):
while (true) {
    const best_merge = findBestMerge(tokens);  // O(N) scan
    if (best_merge == null) break;
    applyMerge(&tokens, best_merge);           // O(N) shift
}
// Totaal: O(N) merges × O(N) per merge = O(N²)
```

### 2.4 BPE v3: Index-Based Engine & Lazy Validation

**Status**: In Progress / Refined for Phase 1.5.

**Problem**:
- v2 BPE uses pointer-based linked lists (poor cache locality, high alloc overhead).
- Lazy validation using position bitfields is fragile after merges.
- We want a clear path from O(N log N) to valid O(N).

**Solution (BPE v3a/v3b)**:
- **v3a (Phase 1.5)**: Index-based `TokenBuffer` (struct of arrays) + Min-Heap.
  - Complexity: O(N log N).
  - Validation: 4-point lazy check in merge loop (O(1) `valid[]` lookup).
- **v3b (Future)**: Replace Min-Heap with Bucket Queue for true O(N).

**Key Components**:
1.  **TokenBuffer**: Parallel arrays (`tokens`, `prev`, `next`, `valid`) for cache efficiency.
2.  **MergeQueue**: Initially a Min-Heap (v3a).
3.  **Arena Strategy**: Single arena per `encode` call.

**Validation**:
- 100% Parity with Evil Corpus.
- Benchmarks: v3a should match or beat v2.
 waar M ≤ vocab_size
- Totaal: O(N + M log N) ≈ O(N log N) in praktijk, maar met veel betere constants dan heap-based

**Verwachte implementatietijd:** 2 weken ipv 1 week als je dit goed wilt doen.

---

### Challenge 2.2: Datastructure Keuze - BESLISSING

**BESLUIT: Index-Based Linked List (niet pointer-based)**

Na analyse van reference implementations en performance characteristics, kiezen we expliciet voor index-based parallel arrays in plaats van pointer-based linked lists.

#### Vergelijking

| Aspect | Pointer-Based | Index-Based |
|--------|---------------|-------------|
| Cache locality | ❌ Scattered heap allocs | ✅ Sequential arrays |
| Allocation overhead | ❌ Per-node malloc | ✅ One block upfront |
| Validity tracking | HashMap lookup O(1) avg | Direct array access O(1) |
| Memory per token | 24+ bytes/node | 12 bytes/node |
| Debugging | Harder (pointer chasing) | Easier (indices visible) |
| Serialization | Complex | Trivial |

#### Gekozen Implementatie

```zig
pub const TokenBuffer = struct {
    // Parallel arrays - maximale cache locality
    tokens: []TokenId,
    prev: []u32,      // prev[i] = index of previous token
    next: []u32,      // next[i] = index of next token
    valid: []bool,    // valid[i] = true if position not merged away

    const SENTINEL: u32 = std.math.maxInt(u32);

    /// Initialize from byte sequence - O(N)
    pub fn initFromBytes(allocator: std.mem.Allocator, text: []const u8) !TokenBuffer {
        const n = text.len;

        var self = TokenBuffer{
            .tokens = try allocator.alloc(TokenId, n),
            .prev = try allocator.alloc(u32, n),
            .next = try allocator.alloc(u32, n),
            .valid = try allocator.alloc(bool, n),
        };

        for (text, 0..) |byte, i| {
            self.tokens[i] = byte;  // Byte-level token
            self.prev[i] = if (i == 0) SENTINEL else @intCast(i - 1);
            self.next[i] = if (i == n - 1) SENTINEL else @intCast(i + 1);
            self.valid[i] = true;   // All positions start valid
        }

        return self;
    }

    /// Merge two adjacent tokens - O(1)
    pub fn merge(self: *TokenBuffer, left_pos: u32, merged_token: TokenId) void {
        const right_pos = self.next[left_pos];
        if (right_pos == SENTINEL) return;  // Safety check

        // Update token at left position
        self.tokens[left_pos] = merged_token;

        // Skip over right node in linked structure
        const next_next = self.next[right_pos];
        self.next[left_pos] = next_next;

        if (next_next != SENTINEL) {
            self.prev[next_next] = left_pos;
        }

        // Mark right position as INVALID (merged away)
        self.valid[right_pos] = false;
        self.next[right_pos] = SENTINEL;
        self.prev[right_pos] = SENTINEL;
    }

    /// Check if position is still valid - O(1)
    pub fn isValid(self: *const TokenBuffer, pos: u32) bool {
        return self.valid[pos];
    }

    /// Extract final token sequence - O(N)
    pub fn extractTokens(self: *const TokenBuffer, allocator: std.mem.Allocator) ![]TokenId {
        var result = std.ArrayList(TokenId).init(allocator);

        // Find head (first valid position with no predecessor)
        var pos: u32 = 0;
        while (pos < self.tokens.len and !self.valid[pos]) : (pos += 1) {}

        // Walk the linked list
        while (pos != SENTINEL and pos < self.tokens.len) {
            if (self.valid[pos]) {
                try result.append(self.tokens[pos]);
            }
            pos = self.next[pos];
        }

        return result.toOwnedSlice();
    }

    pub fn deinit(self: *TokenBuffer, allocator: std.mem.Allocator) void {
        allocator.free(self.tokens);
        allocator.free(self.prev);
        allocator.free(self.next);
        allocator.free(self.valid);
    }
};
```

**Waarom dit beter werkt:**

1. **Cache prefetching**: CPU kan sequential array reads prefetchen
2. **Single allocation**: Arena allocator kan alles in één keer cleanen
3. **No pointer chasing**: Geen cache misses bij node traversal
4. **O(1) validity**: `valid[]` array geeft instant validity check
5. **Bounds checking**: Zig's array bounds checking vangt bugs

**Memory layout (16 bytes per token):**
```
tokens[N]: 4 bytes × N
prev[N]:   4 bytes × N
next[N]:   4 bytes × N
valid[N]:  1 byte × N (+ padding)
─────────────────────────
Total:     ~13-16 bytes per initial byte
```

Vergelijk met pointer-based: ~24+ bytes per node plus allocation overhead.

---

### Challenge 2.3: Priority Queue met Lazy Deletion

**Probleem:**
Je hebt een priority queue nodig die:
1. Snel de beste merge geeft: O(log N)
2. Entries kan invalideren als posities mergen
3. Nieuwe candidates kan toevoegen na merge

**Zig stdlib heeft `std.PriorityQueue` maar:**
- Geen decrease-key operatie
- Geen efficiënte delete-by-value

**BESLUIT: Lazy Deletion Pattern**

```zig
pub const MergeCandidate = struct {
    rank: Rank,
    left_pos: u32,      // Index in TokenBuffer
    // Note: we store left_pos only, right is always buffer.next[left_pos]

    pub fn lessThan(_: void, a: MergeCandidate, b: MergeCandidate) std.math.Order {
        // Min-heap: lowest rank first
        if (a.rank != b.rank) return std.math.order(a.rank, b.rank);
        // Tie-break: leftmost position first (deterministic)
        return std.math.order(a.left_pos, b.left_pos);
    }
};

pub const MergeQueue = struct {
    heap: std.PriorityQueue(MergeCandidate, void, MergeCandidate.lessThan),
    buffer: *TokenBuffer,
    merge_table: *const MergeTable,

    pub fn init(allocator: std.mem.Allocator, buffer: *TokenBuffer, merge_table: *const MergeTable) MergeQueue {
        return .{
            .heap = std.PriorityQueue(MergeCandidate, void, MergeCandidate.lessThan).init(allocator, {}),
            .buffer = buffer,
            .merge_table = merge_table,
        };
    }

    /// Pop next valid merge candidate (4-POINT VALIDATION)
    pub fn popValid(self: *MergeQueue) ?MergeCandidate {
        while (self.heap.removeOrNull()) |candidate| {
            // === LAZY DELETION: 4-POINT VALIDATION ===
            // All 4 checks must pass, in this order

            // 1. Is left position still valid (not merged away)?
            if (!self.buffer.isValid(candidate.left_pos)) continue;

            // 2. Is there still a right neighbor?
            const right_pos = self.buffer.next[candidate.left_pos];
            if (right_pos == TokenBuffer.SENTINEL) continue;

            // 3. Is right position still valid (not merged away)?
            if (!self.buffer.isValid(right_pos)) continue;

            // 4. Do current tokens match expected merge AND rank?
            const left_token = self.buffer.tokens[candidate.left_pos];
            const right_token = self.buffer.tokens[right_pos];

            const current_merge = self.merge_table.lookup(left_token, right_token);
            if (current_merge == null) continue;
            if (current_merge.?.rank != candidate.rank) continue;

            // All 4 checks passed - this is a valid merge
            return candidate;
        }
        return null;
    }

    pub fn add(self: *MergeQueue, candidate: MergeCandidate) !void {
        try self.heap.add(candidate);
    }

    pub fn deinit(self: *MergeQueue) void {
        self.heap.deinit();
    }
};
```

**Waarom lazy deletion:**
- Simpeler dan pairing heap of Fibonacci heap
- O(log N) per operation is acceptabel
- Memory overhead van stale entries is bounded (max 2× valid entries)
- Validation is O(1) met onze index-based buffer

---

### Challenge 2.4: KRITIEKE BUGS in Reference Implementations

> ⚠️ **STOP** - Lees dit voordat je code kopieert van tutorials of papers.

We hebben meerdere reference implementations gereviewed en de volgende kritieke bugs gevonden:

#### Bug 1: Position Drift

**Fout in veel tutorials:**
```zig
// FOUT: position als identifier
var pos: Position = 0;
while (curr.next) |next_node| {
    try candidates.add(.{ .position = pos, ... });
    pos += 1;
}

// Later, na merges:
validity.markInvalid(candidate.position + 1);  // WRONG!
```

**Probleem:** Na merges verschuiven logische posities, maar de validity bitfield werkt op initiële posities. Je markeert de verkeerde positie als invalid.

**Fix:** Gebruik buffer indices als stable identity, niet logische posities:

```zig
// CORRECT: buffer index is stable
try candidates.add(.{ .left_pos = @intCast(i), ... });

// Buffer index verandert niet na merge
// Alleen de next/prev links veranderen
```

#### Bug 2: Stale Heap Entries na Token Change

**Fout:**
```zig
// Na merge van (A, B) → C:
// - Oude candidate voor (prev, A) zit nog in heap
// - Maar A is nu C geworden!

// Als oude candidate gepopt wordt:
const merge = merge_table.lookup(prev.token, A);  // A bestaat niet meer!
```

**Fix:** 4-point validation bij pop:

```zig
// 1. Position valid?
if (!buffer.isValid(candidate.left_pos)) continue;

// 2. Right neighbor exists?
const right_pos = buffer.next[candidate.left_pos];
if (right_pos == SENTINEL) continue;

// 3. Current tokens match expected rank?
const current = merge_table.lookup(buffer.tokens[left_pos], buffer.tokens[right_pos]);
if (current == null or current.?.rank != candidate.rank) continue;
```

#### Bug 3: Memory Leak bij Early Return

**Fout:**
```zig
pub fn encode(self: *LinearBPE, text: []const u8) ![]TokenId {
    var head = try self.initializeTokenList(text);
    // defer self.freeTokenList(head);  // MISSING!

    if (text.len == 0) return &[_]TokenId{};  // LEAK!

    // ... rest of function
}
```

**Fix:** Always defer cleanup, of gebruik arena:

```zig
pub fn encode(self: *LinearBPE, text: []const u8) ![]TokenId {
    // Arena voor alle encode allocaties
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();  // Altijd cleanup, ook bij error

    const alloc = arena.allocator();
    // ... rest met alloc
}
```

#### Bug 4: Off-by-One in Boundary Merge

**Fout:**
```zig
// Na merge, nieuwe candidates toevoegen:
if (left_node.prev) |prev| {
    // Check (prev, merged)
    try candidates.add(.{ .position = candidate.position - 1, ... });
                                      // ^ WRONG als prev was at position 0
}
```

**Fix:** Gebruik buffer indices, niet relatieve posities:

```zig
const prev_pos = buffer.prev[left_pos];
if (prev_pos != SENTINEL) {
    if (merge_table.lookup(buffer.tokens[prev_pos], merged_token)) |merge| {
        try candidates.add(.{ .left_pos = prev_pos, .rank = merge.rank });
    }
}
```

---

### Challenge 2.5: Correcte Volledige Implementatie

Hier is de gecorrigeerde volledige BPE encode functie:

```zig
pub const LinearBPE = struct {
    merge_table: MergeTable,
    allocator: std.mem.Allocator,

    /// O(N log N) tokenization - CORRECT implementation
    pub fn encode(self: *const LinearBPE, text: []const u8) ![]TokenId {
        if (text.len == 0) return &[_]TokenId{};

        // Use arena for all temporary allocations
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        // Step 1: Initialize token buffer as byte-level tokens
        var buffer = try TokenBuffer.initFromBytes(alloc, text);

        // Step 2: Initialize merge queue
        var queue = MergeQueue.init(alloc, &buffer, &self.merge_table);

        // Step 3: Add all initial merge candidates
        var pos: u32 = 0;
        while (pos < text.len - 1) : (pos += 1) {
            const left_token = buffer.tokens[pos];
            const right_token = buffer.tokens[pos + 1];

            if (self.merge_table.lookup(left_token, right_token)) |merge| {
                try queue.add(.{ .rank = merge.rank, .left_pos = pos });
            }
        }

        // Step 4: Process merges in rank order
        while (queue.popValid()) |candidate| {
            const left_pos = candidate.left_pos;
            const right_pos = buffer.next[left_pos];

            // Get merge result
            const left_token = buffer.tokens[left_pos];
            const right_token = buffer.tokens[right_pos];
            const merge = self.merge_table.lookup(left_token, right_token).?;

            // Apply merge - O(1)
            buffer.merge(left_pos, merge.merged);

            // Add new merge candidates for adjacent pairs

            // Left neighbor: (prev, merged)
            const prev_pos = buffer.prev[left_pos];
            if (prev_pos != TokenBuffer.SENTINEL) {
                const prev_token = buffer.tokens[prev_pos];
                if (self.merge_table.lookup(prev_token, merge.merged)) |new_merge| {
                    try queue.add(.{ .rank = new_merge.rank, .left_pos = prev_pos });
                }
            }

            // Right neighbor: (merged, next)
            const next_pos = buffer.next[left_pos];
            if (next_pos != TokenBuffer.SENTINEL) {
                const next_token = buffer.tokens[next_pos];
                if (self.merge_table.lookup(merge.merged, next_token)) |new_merge| {
                    try queue.add(.{ .rank = new_merge.rank, .left_pos = left_pos });
                }
            }
        }

        // Step 5: Extract final tokens (allocate from caller's allocator)
        return buffer.extractTokens(self.allocator);
    }
};
```

**Complexity Analysis (Correct):**

| Phase | Operations | Complexity |
|-------|------------|------------|
| Init buffer | N array writes | O(N) |
| Build initial heap | N inserts | O(N log N) |
| Process merges | ≤N pops + ≤2N inserts | O(N log N) |
| Extract tokens | ≤N reads | O(N) |
| **Total** | | **O(N log N)** |

**Vergelijk met naive O(N²):**
- Input: 100K bytes
- Naive: ~10B operations
- This: ~1.7M operations
- **Speedup: ~6000×**

---

### Challenge 2.6: Van O(N log N) naar O(N) - Bucket Queue

> **EVOLUTIEPAD**: De huidige implementatie (heap-based) is O(N log N). Voor echte O(N) moet je naar een bucket-queue per rank.

#### Fase 1: Min-Heap (O(N log N)) - Implementeer dit eerst

```zig
// Wat we nu hebben - correct maar niet optimaal
heap: std.PriorityQueue(MergeCandidate, void, MergeCandidate.lessThan),

// pop_best: O(log N)
// add: O(log N)
// Total: O((N + M) log N)
```

**Dit is goed genoeg voor Phase 1.5.** Real-world performance is acceptabel.

#### Fase 2: Bucket Queue (O(N)) - BPE v3

**Insight:** Ranks zijn bounded integers (0 tot max_rank ≈ 200K). We kunnen een bucket per rank gebruiken.

```zig
pub const BucketQueue = struct {
    /// Head of linked list per rank (SENTINEL = empty)
    bucket_heads: []Index,

    /// Next pointer for candidate linked list (per index)
    next_in_bucket: []Index,

    /// Lowest non-empty rank (for fast iteration)
    current_rank: Rank,

    /// Number of ranks (vocab size)
    max_rank: Rank,

    const SENTINEL: Index = std.math.maxInt(Index);

    pub fn init(allocator: std.mem.Allocator, max_rank: Rank, max_positions: usize) !BucketQueue {
        var bucket_heads = try allocator.alloc(Index, max_rank);
        @memset(bucket_heads, SENTINEL);

        var next_in_bucket = try allocator.alloc(Index, max_positions);
        @memset(next_in_bucket, SENTINEL);

        return .{
            .bucket_heads = bucket_heads,
            .next_in_bucket = next_in_bucket,
            .current_rank = 0,
            .max_rank = max_rank,
        };
    }

    /// Add candidate - O(1) prepend to bucket
    pub fn add(self: *BucketQueue, rank: Rank, left_idx: Index) void {
        // Prepend to linked list for this rank
        self.next_in_bucket[left_idx] = self.bucket_heads[rank];
        self.bucket_heads[rank] = left_idx;
    }

    /// Pop best (lowest rank) - O(1) amortized
    pub fn popBest(self: *BucketQueue) ?struct { rank: Rank, left_idx: Index } {
        // Find first non-empty bucket
        while (self.current_rank < self.max_rank) {
            const head = self.bucket_heads[self.current_rank];
            if (head != SENTINEL) {
                // Pop from this bucket
                self.bucket_heads[self.current_rank] = self.next_in_bucket[head];
                return .{ .rank = self.current_rank, .left_idx = head };
            }
            self.current_rank += 1;
        }
        return null;
    }
};
```

**Complexity met bucket queue:**

| Operation | Heap | Bucket Queue |
|-----------|------|--------------|
| Build initial | O(N log N) | O(N) |
| Pop best | O(log N) | O(1) amortized |
| Add candidate | O(log N) | O(1) |
| **Total** | **O(N log N)** | **O(N + M) = O(N)** |

**Waarom O(1) amortized voor pop:**
- `current_rank` gaat alleen omhoog (nooit terug)
- Totaal max `max_rank` increments over hele run
- Elke candidate wordt exact 1× gepopt
- Amortized: O(max_rank + N) / N = O(1)

#### Trade-offs

| Aspect | Min-Heap | Bucket Queue |
|--------|----------|--------------|
| Memory | O(N) heap | O(max_rank + N) |
| Implementation | Simpler | More complex |
| Cache | Heap array | Two arrays |
| Worst case | O(N log N) | O(N) |
| Practical speedup | Baseline | ~1.5-2× |

**Aanbeveling:**
1. **Phase 1.5**: Implementeer met min-heap (simpeler, correct, fast enough)
2. **BPE v3**: Upgrade naar bucket queue als benchmarks aantonen dat het nodig is

---

### Challenge 2.7: Priority Queue voor Merge Candidates

---

### Challenge 2.4: Pre-tokenizer Regex Parity

**Probleem:**
tiktoken gebruikt een complexe regex voor pre-tokenization:

```python
# tiktoken o200k_base pattern (simplified)
pat = r"""'(?i:[sdmt]|ll|ve|re)|[^\r\n\p{L}\p{N}]?\p{L}+|\p{N}{1,3}| ?[^\s\p{L}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+"""
```

**Uitdagingen:**
1. Zig heeft geen regex engine in stdlib
2. Unicode property escapes (`\p{L}`, `\p{N}`) vereisen Unicode database
3. Exacte match met tiktoken is kritiek voor parity

**Opties:**

| Approach | Parity Risk | Effort | Performance |
|----------|-------------|--------|-------------|
| Hand-coded state machine | High (bugs) | High | Excellent |
| Port tiktoken regex | Medium | Medium | Good |
| Link to PCRE/RE2 | Low | Low | Good |
| Zig regex lib (third-party) | Medium | Low | Variable |

**Aanbeveling:**
Hand-coded state machine. Ja, het is werk. Maar:
- Geen externe dependencies
- Volledige controle over edge cases
- Beste performance
- Parity testbaar per case

**Stappenplan:**
1. Extract alle test cases uit tiktoken voor pre-tokenization
2. Bouw state machine incrementeel, test per case
3. Fuzz tegen tiktoken output

**Verwachte tijd:** 3-5 dagen alleen voor pre-tokenizer

---

### Challenge 2.5: Unicode Handling

**Probleem:**
BPE werkt op bytes, maar pre-tokenization moet Unicode-aware zijn.

**Edge cases:**
```
Input: "Ångström"
- 'Å' = U+00C5 = 2 bytes UTF-8 (C3 85)
- Pre-tokenizer moet dit als één "letter" zien
- BPE ziet bytes [0xC3, 0x85, 0x6E, ...]
```

**Valkuilen:**
1. UTF-8 validation op input
2. Code point boundaries vs byte boundaries
3. Normalization (NFC vs NFD)
4. Combining characters

**Zig UTF-8 helpers:**
```zig
const std = @import("std");

// Iterate code points
var iter = std.unicode.Utf8Iterator{ .bytes = input };
while (iter.nextCodepoint()) |cp| {
    // cp is u21 code point
}

// Check if byte is start of code point
fn isUtf8Start(byte: u8) bool {
    return (byte & 0xC0) != 0x80;
}
```

**Kritieke test cases:**
- Emoji: 🎉 (4 bytes)
- Combining: é vs e + ́ (1 vs 2 code points)
- Zero-width: ​ (ZWS, invisible)
- Invalid UTF-8: [0xFF, 0xFE]
- Overlong encodings

---

### Challenge 2.6: Merge Table Size

**Probleem:**
o200k_base heeft ~200,000 vocabulary entries en ~199,999 merges. Dat is veel data.

**Memory:**
```
Per merge entry: 16 bytes (pair: 8, result: 4, rank: 4)
Total: 200,000 × 16 = 3.2 MB

Hash table overhead: ~2x = 6.4 MB
```

**Build time:**
Als je merge table comptime wilt initialiseren:
```zig
const merges = comptime blk: {
    var table = MergeTable{};
    // 200,000 insertions at compile time...
    break :blk table;
};
// Verwacht: 30-60 seconden compile time
```

**Alternatieven:**

1. **Runtime init, cached:**
   ```zig
   var global_merge_table: ?MergeTable = null;

   pub fn getMergeTable() *MergeTable {
       if (global_merge_table) |*t| return t;
       global_merge_table = MergeTable.loadFromEmbedded();
       return &global_merge_table.?;
   }
   ```

2. **Binary format optimized for mmap:**
   ```zig
   // Pre-sorted array, binary search
   const merges = @embedFile("merges.bin");

   pub fn lookupMerge(a: u32, b: u32) ?Merge {
       // Binary search in sorted array
       // O(log N) maar cache-friendly
   }
   ```

**Aanbeveling:** Binary format met sorted array. Geen hash table overhead, snelle startup, predictable memory.

---

### Challenge 2.7: Parity Edge Cases

**Probleem:**
tiktoken heeft undocumented gedrag dat je moet reverse-engineeren.

**Bekende edge cases:**

1. **Empty string:**
   ```python
   enc.encode("")  # Returns []
   ```

2. **Whitespace-only:**
   ```python
   enc.encode("   ")  # Returns [220, 220, 220] for spaces
   ```

3. **Special tokens:**
   ```python
   enc.encode("<|endoftext|>", allowed_special="all")  # Returns [199999]
   enc.encode("<|endoftext|>")  # Returns [27, 91, ...]  (encoded as text)
   ```

4. **Invalid UTF-8:**
   ```python
   enc.encode(b"\xff\xfe".decode("utf-8", errors="replace"))
   # Depends on error handling
   ```

5. **Very long tokens:**
   ```python
   enc.encode("a" * 100000)
   # Should not OOM, should complete in reasonable time
   ```

6. **Alternating patterns:**
   ```python
   enc.encode("ababab...")  # Tests merge ordering
   ```

**Strategie:**
Evil Corpus v2 moet al deze cases bevatten. Run parity tests na elke significante change.

---

## Research Review: 2024-2025 BPE Papers

> Dit is een kritische evaluatie van recente BPE research en wat we wel/niet moeten adopteren voor llm-cost.

### Geëvalueerde Papers

| Paper | Year | Key Innovation | Verdict |
|-------|------|----------------|---------|
| BlockBPE (ICML) | 2025 | GPU-parallel BPE | ❌ Skip |
| LoPT | 2025 | Position-aware chunking | ⚠️ Maybe later |
| BoundlessBPE | 2024 | Cross-boundary merges | ❌ Breaks parity |
| R-BPE (EMNLP) | 2025 | Token reuse/caching | ⚠️ Premature opt |
| GitHub bpe crate | 2024 | Linear O(N) algorithm | ✅ Primary reference |

---

### BlockBPE - ❌ NIET Adopteren

**Wat het doet:**
GPU-parallel BPE met CUDA kernels, elimineert regex bottleneck.

**Waarom niet voor llm-cost:**
- GPU-focused (CUDA dependency)
- llm-cost is CPU-only, single static binary
- Overkill voor CLI tool die max 10MB/sec hoeft te verwerken
- Zou dependency graph exploderen

**Wel bruikbaar inzicht:**
```
"Regex pre-tokenization is 75% of runtime" → bevestigt dat pre-tokenizer critical path is
```

**Conclusie:** Interessant voor GPU workloads, irrelevant voor onze use case.

---

### LoPT Position-Aware Merging - ⚠️ Conditionally Useful

**Wat het doet:**
Chunk grote tekst, tokenize chunks parallel, merge overlapping regions via position matching.

**Performance claim:** 5-6× speedup op 64K+ tokens met 100% accuracy.

**Wanneer relevant voor llm-cost:**
- Inputs > 1MB
- Multi-threaded `--file` mode
- Batch processing van grote documents

**Wanneer NIET relevant:**
- Primary use case: JSONL streaming
- Typische line: < 10KB
- Parallel chunking overhead > benefit voor kleine inputs

**Aanbeveling:**

```
IF llm-cost krijgt `--file` mode voor grote single files
THEN implementeer LoPT-style chunking voor files > 1MB
ELSE stick met sequential per-line processing
```

**Implementatie sketch (voor later):**

```zig
pub fn tokenizeParallelChunks(
    text: []const u8,
    chunk_size: usize,
    overlap: usize,
    thread_pool: *std.Thread.Pool
) ![]TokenId {
    const num_chunks = (text.len + chunk_size - 1) / chunk_size;

    // Phase 1: Tokenize chunks in parallel
    var chunk_results = try allocator.alloc([]TokenId, num_chunks);
    for (0..num_chunks) |i| {
        const start = i * chunk_size;
        const end = @min(start + chunk_size + overlap, text.len);

        thread_pool.spawn(tokenizeChunk, .{ text[start..end], &chunk_results[i] });
    }
    thread_pool.wait();

    // Phase 2: Merge overlapping regions (LoPT position matching)
    return mergeChunkResults(chunk_results, chunk_size, overlap);
}
```

**Status:** File under "Fase 2 - Enterprise Features"

---

### BoundlessBPE - ❌ ABSOLUUT NIET

**Wat het doet:**
Laat merges toe *across* regex pre-tokenization boundaries voor betere compression.

**Waarom ABSOLUUT NIET:**

```
⚠️ ⚠️ ⚠️ BREEKT TIKTOKEN PARITY ⚠️ ⚠️ ⚠️

tiktoken:      "Hello World" → [9906, 4435]
BoundlessBPE:  "Hello World" → [mogelijk andere tokens]
```

**Je hele value proposition is:**
> "Match OpenAI's tokenizer exact zodat cost estimates kloppen"

BoundlessBPE is een *fundamenteel ander* algoritme. Het produceert *andere* tokens. Je cost estimates zouden *fout* zijn.

**Conclusie:** Academisch interessant, maar directe contradictie met onze doelen.

---

### R-BPE Token Caching - ⚠️ Premature Optimization

**Wat het doet:**
Cache tokenization van frequent sequences ("the ", "ing", "tion").

**Trade-offs:**

| Pro | Con |
|-----|-----|
| Skip repeated work | Extra memory overhead |
| Faster on repetitive text | Cache invalidation complexity |
| | Startup cost voor cache build |

**Analyse voor llm-cost:**
- Streaming JSONL = elke line is independent request
- Geen cross-line caching benefit
- Intra-line caching: lines zijn typisch kort (< 1KB)
- Cache hit rate zou laag zijn

**Wanneer wel nuttig:**
- Batch processing van documents met veel herhaling
- "Index hele codebase" use case

**Aanbeveling:** File under "premature optimization". Implementeer alleen als benchmarks aantonen dat het nodig is.

---

### Cache-Oblivious Recursion - ❌ Overkill

**Wat het is:**
Recursive divide-and-conquer dat automatisch cache-efficient is, ongeacht cache size.

**Reality check voor llm-cost:**
- BPE merge table: ~6MB → past in L3 cache
- Token sequences: typisch < 100KB → past in L2 cache
- We zijn al cache-friendly door sequential access patterns

**Conclusie:** Voegt complexiteit toe voor theoretische winst die we in praktijk niet zien.

---

### SIMD Optimization - 🟡 Potential Quick Win

**Waar het kan helpen:**

1. **Pre-tokenizer byte scanning** - whitespace/boundary detection
2. **UTF-8 validation** - check valid sequences

**Waar het NIET helpt:**
- Merge ranking (hash lookup is bottleneck, niet comparison)
- Token extraction (memory-bound, niet compute-bound)

**Zig SIMD reality:**

```zig
// Zig's SIMD is experimental
const Vec16 = @Vector(16, u8);

pub fn countSpaces(text: []const u8) usize {
    var count: usize = 0;
    const space: Vec16 = @splat(@as(u8, ' '));

    var i: usize = 0;
    while (i + 16 <= text.len) : (i += 16) {
        const chunk: Vec16 = text[i..][0..16].*;
        const matches = chunk == space;
        count += @popCount(@as(u16, @bitCast(matches)));
    }

    // Scalar remainder
    while (i < text.len) : (i += 1) {
        if (text[i] == ' ') count += 1;
    }

    return count;
}
```

**Caveat:** Needs scalar fallback voor non-SIMD targets (WASM, sommige ARM).

**Aanbeveling:**
- Pre-tokenizer: ja, overweeg SIMD voor whitespace detection
- Elders: nee, hash lookup domineert runtime

---

### GitHub bpe Crate - ✅ Primary Reference

**Wat het is:**
Rust implementatie van lineaire BPE, gebruikt door GitHub Copilot.

**Waarom dit onze primary reference is:**
- Production-proven op massive scale
- O(N log N) met goede constants
- Open source, goed gedocumenteerd
- Correcte handling van edge cases

**Key techniques om over te nemen:**

1. **Index-based linked list** (niet pointer-based)
2. **Lazy deletion in heap** (geen complex decrease-key)
3. **4-point validation bij pop** (left valid, right exists, right valid, rank matches)
4. **Arena allocator** (zero-overhead cleanup)

**Niet over te nemen:**
- Rust-specific idioms (ownership, lifetimes)
- Rayon parallelism (we gebruiken Zig threads)

---

### Implementatie Prioriteit Stack

| Prio | Component | Effort | Impact | Status |
|------|-----------|--------|--------|--------|
| 1 | Index-based TokenBuffer | 1 dag | Foundation | **Do now** |
| 2 | Lazy-delete MergeQueue | 1 dag | O(N log N) | **Do now** |
| 3 | Arena allocator pattern | 0.5 dag | Memory perf | **Do now** |
| 4 | Hand-coded pre-tokenizer | 3-5 dagen | Parity + perf | **Do now** |
| 5 | SIMD pre-tokenizer scan | 1 dag | 2-3× speedup | **Optional** |
| 6 | Bucket queue (O(N)) | 1-2 dagen | True linear | **BPE v3** |
| 7 | LoPT parallel chunking | 2-3 dagen | Large file perf | **Fase 2** |

**Expliciet NIET doen:**
- ❌ BlockBPE GPU kernels
- ❌ BoundlessBPE (breaks parity)
- ❌ R-BPE caching (premature)
- ❌ Cache-oblivious recursion (overkill)

---

## BPE v3 Evolutiepad

> Dit is het pad van Phase 1.5 naar een volwassen linear BPE engine.

### Versie Overzicht

| Version | Complexity | Key Feature | Status |
|---------|------------|-------------|--------|
| BPE v1 | O(N²) | Naive loop | ❌ Deprecated |
| BPE v2 | O(N log N) | Heap + lazy delete | ✅ Phase 1.5 |
| BPE v3 | O(N) | Bucket queue | 📋 Future |

### BPE v3 Design Sketch

**Doel:** O(N + M) complexiteit waar M = #merges applied (bounded door vocab).

**Kernbeslissingen:**

1. **Merge lookup:** `(left_id, right_id) → MergeEntry`
   - Kleine vocab: dense 2D array
   - Grote vocab: perfect hash (precomputed)

2. **Merge sequencing:** Bucket queue per rank
   ```zig
   rank_buckets: []Index,     // head per rank
   next_candidate: []Index,   // linked list per rank
   current_rank: Rank,        // lowest non-empty
   ```

3. **Node structuur:** Behoud index-based TokenBuffer
   - Geen per-node alloc
   - Validatie via `valid[]` array

4. **Parallelisme (optional):** LoPT-style position-aware chunking
   - Alleen voor inputs > 1MB
   - Global positions voor correcte overlap merge

**Exit criteria BPE v3:**
- [ ] Parity tests 100% groen
- [ ] Benchmark: worst-case ≥ 2× sneller dan v2
- [ ] Benchmark: real-world ≥ 1.2-1.5× sneller
- [ ] Memory: geen regressie
- [ ] Complexity: verified O(N) scaling

**ADR Reference:** Zie toekomstige `ADR-000X-bpe-v3.md`

---

### Updated Risk Assessment (Post-Research)

| Risk | Likelihood | Impact | Change | Mitigation |
|------|------------|--------|--------|------------|
| Pre-tokenizer bugs | High | High | — | Evil Corpus + fuzzing |
| Merge order edge cases | Medium | High | — | Golden tests vs tiktoken |
| Position tracking bugs | **High** | **High** | **NEW** | Use buffer indices only |
| Stale heap entries | **High** | **Medium** | **NEW** | 4-point validation |
| Memory leaks | Medium | Low | — | Arena allocator |
| SIMD portability | Medium | Low | — | Scalar fallback |

**Top 3 risico's (updated):**
1. **Position tracking** - Gebruik ALLEEN buffer indices, nooit logische posities
2. **Pre-tokenizer parity** - Hand-coded state machine, test exhaustively
3. **Stale heap entries** - 4-point validation bij elke pop

---

## Epic 3: CLI Contract

### Challenge 3.1: JSON Output Performance

**Probleem:**
`std.json.stringify` is niet de snelste. Bij 100K lines/sec kan JSON serialization een bottleneck worden.

**Benchmark:**
```
std.json.stringify: ~500ns per small object
Manual formatting:  ~50ns per small object
```

**Oplossing:**
Voor de pipe output records, gebruik manual formatting:

```zig
pub fn writeJsonRecord(writer: anytype, record: Record) !void {
    try writer.print(
        \\{{"tokens_in":{d},"tokens_out":{d},"cost_usd":{d:.6},"accuracy":"{s}"}}
        \\
    , .{
        record.tokens_in,
        record.tokens_out,
        record.cost_usd,
        @tagName(record.accuracy),
    });
}
```

**Trade-off:** Minder flexible, maar 10x sneller. Voor een performance-focused tool is dit acceptabel.

---

### Challenge 3.2: Floating Point Formatting

**Probleem:**
Cost values moeten consistent geformatteerd worden. `0.1 + 0.2 ≠ 0.3` in IEEE 754.

**Valkuilen:**
```zig
const cost: f64 = 0.000001;

// Dit kan "1e-6" of "0.000001" geven afhankelijk van formatter
std.debug.print("{d}", .{cost});

// Scientific notation breekt JSON parsing in sommige tools
// Fixed precision kan precision verliezen
```

**Oplossing:**
```zig
// Altijd fixed precision, 6 decimalen voor USD (sub-cent precision)
try writer.print("{d:.6}", .{cost});  // "0.000001"

// Of: gebruik integers (microdollars)
const cost_micros: u64 = @intFromFloat(cost * 1_000_000);
try writer.print("{d}", .{cost_micros});  // 1
```

**Beslissing:** Fixed 6 decimalen. Consistent, human-readable, geen precision loss voor typical costs.

---

### Challenge 3.3: Exit Code Propagation

**Probleem:**
Zig's `std.process.exit()` doet geen cleanup. Defer blocks runnen niet.

```zig
pub fn main() !void {
    var resource = try allocateResource();
    defer resource.deinit();  // RUNS NIET bij std.process.exit()

    if (error_condition) {
        std.process.exit(1);  // Resource leak!
    }
}
```

**Oplossing:**
```zig
pub fn main() u8 {
    return run() catch |err| {
        std.debug.print("Error: {}\n", .{err});
        return 1;
    };
}

fn run() !u8 {
    var resource = try allocateResource();
    defer resource.deinit();  // RUNS bij normale return

    if (error_condition) {
        return 64;  // Return, niet exit
    }

    return 0;
}
```

---

### Challenge 3.4: Stderr vs Stdout Contention

**Probleem:**
Summary gaat naar stderr, records naar stdout. Bij piping kan dit race conditions geven.

```bash
llm-cost pipe --summary < input.jsonl > output.jsonl 2> summary.txt
# Wat als stderr buffer flusht na stdout?
```

**Oplossing:**
```zig
// Explicit flush before exit
const stdout = std.io.getStdOut().writer();
const stderr = std.io.getStdErr().writer();

// Process all records
for (records) |r| {
    try stdout.print(...);
}
try stdout.context.flush();  // Flush stdout first

// Then summary
try stderr.print(...);
try stderr.context.flush();
```

---

## Epic 4: Golden Tests

### Challenge 4.1: JSON Comparison Semantics

**Probleem:**
JSON object key order is undefined. `{"a":1,"b":2}` en `{"b":2,"a":1}` zijn equivalent.

**Maar:**
- `jq` output is sorted
- `std.json` output is insertion-order
- Byte-exact comparison faalt

**Oplossing:**
```zig
fn compareJson(actual: []const u8, expected: []const u8) bool {
    const actual_parsed = std.json.parseFromSlice(actual);
    const expected_parsed = std.json.parseFromSlice(expected);
    return std.json.eql(actual_parsed, expected_parsed);
}
```

**Extra:** Float comparison met tolerance:
```zig
fn floatEq(a: f64, b: f64) bool {
    const tolerance = 1e-9;
    return @abs(a - b) < tolerance;
}
```

---

### Challenge 4.2: Test Binary Location

**Probleem:**
Golden tests moeten het `llm-cost` binary aanroepen. Maar waar staat dat?

```zig
// Tijdens development:
const binary = "zig-out/bin/llm-cost";

// Tijdens CI:
const binary = "./llm-cost";  // Of ergens anders

// Cross-platform:
const binary = if (builtin.os.tag == .windows) "llm-cost.exe" else "llm-cost";
```

**Oplossing:**
```zig
fn getBinaryPath() []const u8 {
    // Check omgevingsvariabele eerst
    if (std.os.getenv("LLM_COST_BINARY")) |path| {
        return path;
    }
    // Default naar build output
    return "zig-out/bin/llm-cost";
}
```

---

### Challenge 4.3: Test Isolation

**Probleem:**
Tests moeten onafhankelijk van elkaar runnen. Shared state = flaky tests.

**Valkuilen:**
- Global merge table cache
- Temp files niet opgeruimd
- Environment variables

**Oplossing:**
```zig
fn runIsolatedTest(test_fn: fn() anyerror!void) !void {
    // Fresh allocator per test
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    // Clear any global state
    resetGlobalState();

    try test_fn();
}
```

---

## Epic 5: Pricing v2

### Challenge 5.1: Pricing Data Staleness

**Probleem:**
LLM pricing verandert constant. Je embedded pricing DB is per definitie outdated.

**Voorbeelden 2024-2025:**
- GPT-4 Turbo: $30/$60 → $10/$30
- GPT-4o launch: nieuwe price point
- o1/o3 series: reasoning tokens = nieuwe dimensie

**Opties:**

| Approach | Freshness | Offline | Complexity |
|----------|-----------|---------|------------|
| Embedded only | Stale | ✅ | Low |
| Runtime download | Fresh | ❌ | Medium |
| User override file | Flexible | ✅ | Medium |
| API call | Fresh | ❌ | High |

**Aanbeveling:**
Embedded + user override:

```zig
// Check user config first
const pricing = loadPricing: {
    if (std.fs.cwd().openFile("~/.config/llm-cost/pricing.json", .{})) |f| {
        break :loadPricing parsePricingFile(f);
    } else |_| {
        break :loadPricing @embedFile("data/pricing.json");
    }
};
```

**Docs moeten zeggen:**
"Pricing snapshot van [datum]. Override met `~/.config/llm-cost/pricing.json` of `--pricing-file`."

---

### Challenge 5.2: Currency Precision

**Probleem:**
USD costs kunnen heel klein zijn. 100 tokens @ $2.50/1M = $0.00025.

```zig
// f32 precision loss:
const cost_f32: f32 = 0.00025;  // Actual: 0.000250000012...

// f64 is beter maar niet perfect:
const cost_f64: f64 = 0.00025;  // Much better precision
```

**Oplossing:**
Gebruik f64 intern, format naar 6 decimalen in output. Documenteer dat precision ~$0.000001 (1 microdollar) is.

---

## Epic 6: Legal & Vocab

### Challenge 6.1: Vocab File Provenance

**Probleem:**
Waar komen de vocab files precies vandaan? tiktoken haalt ze van Azure blob storage.

```python
# tiktoken source code
ENDOFTEXT = "<|endoftext|>"
ENDOFPROMPT = "<|endofprompt|>"

def o200k_base():
    mergeable_ranks = load_tiktoken_bpe(
        "https://openaipublic.blob.core.windows.net/encodings/o200k_base.tiktoken",
        expected_hash="...",
    )
```

**Uitdaging:**
Die URL is een blob, geen Git repo. Geen duidelijke versioning.

**Oplossing:**
1. Download file met hash check
2. Converteer naar je binary format
3. Documenteer:
   - URL
   - Download datum
   - SHA256 van origineel
   - SHA256 van je converted file

---

### Challenge 6.2: Derived Work vs Copying

**Probleem:**
Is je vocab embedding "copying" of "derived work"?

**Juridische nuance:**
- tiktoken code: MIT licensed ✅
- Vocab data: Onduidelijk, maar gepubliceerd door OpenAI
- Je binary: Bevat de vocab data

**Praktijk:**
Iedereen embedt deze vocabs (Huggingface, llama.cpp, etc.). OpenAI heeft dit de facto toegestaan door het publiek te maken.

**Safe approach:**
1. NOTICE file met attributie
2. Verwijs naar bron
3. Claim niet ownership van de vocab data
4. Als OpenAI bezwaar maakt: switch naar runtime download

---

## Epic 7: SLSA & Release

### Challenge 7.1: SLSA Generator Compatibility

**Probleem:**
De officiële `slsa-github-generator` is geoptimaliseerd voor Go en npm. Generic workflow is minder gedocumenteerd.

**Bekende issues:**
- Subject digest format moet exact kloppen
- Base64 encoding quirks
- Rekor upload kan falen bij hoge load

**Werkende configuratie:**
```yaml
provenance:
  needs: build
  permissions:
    actions: read
    id-token: write
    contents: write
  uses: slsa-framework/slsa-github-generator/.github/workflows/generator_generic_slsa3.yml@v2.0.0
  with:
    base64-subjects: "${{ needs.build.outputs.hashes }}"
    upload-assets: true
```

**Build job moet outputten:**
```yaml
- name: Generate hashes
  id: hash
  run: |
    sha256sum llm-cost-* > checksums.txt
    echo "hashes=$(base64 -w0 checksums.txt)" >> $GITHUB_OUTPUT
```

---

### Challenge 7.2: Action Pinning Maintenance

**Probleem:**
SHA-pinned actions moeten handmatig geüpdatet worden voor security fixes.

**Tooling:**
```bash
# Dependabot voor actions
# .github/dependabot.yml
version: 2
updates:
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "weekly"
```

**Maar:** Dependabot maakt PRs met tag updates, niet SHA updates. Je moet handmatig naar SHA converteren.

**Alternatief:** Renovate bot heeft betere SHA pinning support.

---

### Challenge 7.3: Cosign Keyless Quirks

**Probleem:**
Keyless signing werkt via OIDC token van GitHub. Kan falen bij:
- Rate limiting
- Fulcio/Rekor downtime
- Token expiration tijdens lange builds

**Mitigatie:**
```yaml
- name: Sign with Cosign (with retry)
  run: |
    for i in 1 2 3; do
      cosign sign-blob --yes llm-cost-* && break
      echo "Attempt $i failed, retrying..."
      sleep 10
    done
```

---

## Cross-Cutting Challenges

### Memory Management

**Zig specifiek:**
Geen garbage collection. Elke allocatie moet gefreed worden.

**Pattern:**
```zig
// GOED: Arena voor request-scoped allocations
var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();

const result = try processLine(&arena.allocator(), line);
// Alles in arena wordt automatisch gefreed

// SLECHT: Manual tracking
var list = std.ArrayList(u8).init(allocator);
// Vergeten: defer list.deinit();
```

---

### Error Handling Propagation

**Probleem:**
Zig errors zijn enums, niet strings. Context gaat verloren.

```zig
// User ziet alleen: "error: InvalidUtf8"
// Niet: "line 42, column 15: invalid UTF-8 byte 0xFF"
```

**Oplossing:**
```zig
const ParseError = error{
    InvalidUtf8,
    UnexpectedEof,
    // ...
};

const ParseResult = union(enum) {
    ok: Value,
    err: struct {
        code: ParseError,
        line: usize,
        column: usize,
        message: []const u8,
    },
};
```

---

### Cross-Platform Gotchas

**Windows:**
- Line endings: \r\n vs \n
- Path separators: \ vs /
- Console encoding: UTF-8 niet default

**macOS:**
- File system case-insensitivity
- Different `stat` structure

**Linux:**
- Glibc vs musl linking
- Different `/proc` layouts

**Test matrix moet alle drie coveren.**

---

## Risk Summary (Updated v2.0)

### Risk Matrix

| Epic | Risk | Likelihood | Impact | Mitigation |
|------|------|------------|--------|------------|
| 1 | Comptime complexity | Medium | Low | Good error messages |
| 2 | **Position tracking bugs** | **High** | **High** | **Use buffer indices ONLY** |
| 2 | **Stale heap entries** | **High** | **Medium** | **4-point validation at pop** |
| 2 | BPE not actually linear | High | High | Proper algorithm, see 2.5 |
| 2 | Pre-tokenizer parity | High | High | Evil Corpus + fuzzing |
| 3 | JSON perf | Low | Medium | Manual formatting |
| 4 | Flaky tests | Medium | Medium | Isolation, determinism |
| 5 | Stale pricing | High | Low | User override, docs |
| 6 | Legal ambiguity | Low | Medium | Clear attribution |
| 7 | SLSA generator issues | Medium | Low | Retry logic |

### NEW: Implementation Bug Risks (from Code Review)

| Bug Type | Where Found | Fix |
|----------|-------------|-----|
| Position drift | Reference implementations | Use stable buffer indices |
| Stale merge candidates | Lazy deletion heap | 4-point validation |
| Memory leak on early return | encode() function | Arena allocator pattern |
| Off-by-one in boundary merge | Candidate insertion | Use buffer.prev/next, not math |

### Top 5 om op te letten (Updated)

1. **Position tracking** - NOOIT logische posities gebruiken, ALLEEN buffer indices
2. **Stale heap entries** - 4-point validation bij ELKE pop: left valid, right exists, right valid, rank matches
3. **Pre-tokenizer regex parity** - Hand-coded state machine, test exhaustief tegen tiktoken
4. **Memory management** - Arena allocator voor encode(), defer cleanup ALTIJD
5. **Algorithm correctness** - Gebruik de gecorrigeerde implementatie uit Challenge 2.5

### Research Decisions

| Technology | Decision | Rationale |
|------------|----------|-----------|
| BlockBPE | ❌ Skip | GPU-only, we need CPU single binary |
| LoPT chunking | ⚠️ Fase 2 | Only relevant for large files |
| BoundlessBPE | ❌ Never | Breaks tiktoken parity |
| R-BPE caching | ⚠️ Defer | Premature optimization |
| SIMD | ⚠️ Optional | Only for pre-tokenizer scanning |
| GitHub bpe style | ✅ Adopt | Production-proven, correct |

### Definition of Done: BPE v2

Before marking Epic 2 complete, verify:

- [ ] All parity tests pass against tiktoken
- [ ] No position tracking (only buffer indices)
- [ ] 4-point validation in popValid()
- [ ] Arena allocator for encode()
- [ ] O(N log N) verified via benchmark (not O(N²))
- [ ] Memory leak check via valgrind/zig test
- [ ] Pre-tokenizer handles all Evil Corpus cases
- [ ] Edge cases: empty string, single char, 100K+ bytes
