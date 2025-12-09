const std = @import("std");

/// The binary file layout (Must match tools/convert_vocab.zig)
const Header = extern struct {
    magic: u32,
    count: u32,
    strings_len: u32,
};

const IndexEntry = extern struct {
    offset: u32,
    rank: u32,
    len: u32,
};

const NodeIndex = u32;
const InvalidIndex: NodeIndex = std.math.maxInt(NodeIndex);
const HeapThreshold = 128; // Tuning based on bench_bpe (ReleaseFast)

/// Zero-copy BPE Tokenizer Engine
pub const BpeEngine = struct {
    index: []const IndexEntry,
    string_blob: []const u8,

    /// Initialize from raw embedded bytes
    pub fn init(embedded_data: []const u8) !BpeEngine {
        if (embedded_data.len < @sizeOf(Header)) return error.InvalidData;

        // Read header
        const header = std.mem.bytesToValue(Header, embedded_data[0..@sizeOf(Header)]);

        if (header.magic != 0xAABBCCDD) return error.InvalidMagic;

        const index_start = @sizeOf(Header);
        // Cast header.count to avoid overflow risk in calculation, though typically safe
        const index_size = @as(usize, @intCast(header.count)) * @sizeOf(IndexEntry);

        if (embedded_data.len < index_start + index_size) return error.TruncatedData;

        const index_bytes = embedded_data[index_start .. index_start + index_size];

        // Assumption: embedded_data is produced by tools/convert_vocab.zig
        // and has at least align(4), so alignCast is safe here.
        // NOTE: This relies on @embedFile providing aligned data or the allocator being well-behaved.
        // If loading from unknown runtime buffer: use @alignCast but handle potential error or copy.
        const index_ptr: [*]const IndexEntry = @ptrCast(@alignCast(index_bytes.ptr));
        const index = index_ptr[0..header.count];

        const strings_start = index_start + index_size;
        if (embedded_data.len < strings_start + header.strings_len) return error.TruncatedStrings;

        const string_blob = embedded_data[strings_start .. strings_start + header.strings_len];

        return BpeEngine{
            .index = index,
            .string_blob = string_blob,
        };
    }

    /// O(log N) lookup. Returns Rank.
    pub fn getRank(self: BpeEngine, token: []const u8) ?u32 {
        const Context = struct {
            blob: []const u8,

            pub fn compare(ctx: @This(), key: []const u8, entry: IndexEntry) std.math.Order {
                const entry_str = ctx.blob[entry.offset .. entry.offset + entry.len];
                return std.mem.order(u8, key, entry_str);
            }
        };

        const ctx = Context{ .blob = self.string_blob };

        // Zero-allocation binary search
        const idx = std.sort.binarySearch(IndexEntry, token, self.index, ctx, Context.compare);

        if (idx) |i| {
            return self.index[i].rank;
        }
        return null;
    }

    /// Helper to find token by rank (O(N) - slow, for debugging)
    /// Not strictly needed for encoding, usually needed for decoding.
    pub fn getToken(self: BpeEngine, rank: u32) ?[]const u8 {
        // Since we sort by Token, we can't binary search by Rank.
        // If we need fast decode, we need a second index (Rank -> Token).
        // For 'llm-cost', we only need encoding (count).
        // If debug printing is needed, linear scan is acceptable for v0.1.
        for (self.index) |entry| {
            if (entry.rank == rank) {
                return self.string_blob[entry.offset .. entry.offset + entry.len];
            }
        }
        return null;
    }

    // --- Encoding Logic ---

    /// Encode pre-tokenized text segments.
    /// Caller owns result slice.
    pub fn encode(self: BpeEngine, alloc: std.mem.Allocator, pre_tokens: []const @import("pre_tokenizer.zig").PreToken) ![]u32 {
        var tokens = std.ArrayList(u32).init(alloc);
        errdefer tokens.deinit();

        for (pre_tokens) |pt| {
            if (pt.is_special) {
                // Special tokens bypass BPE split/merge.
                // Depending on upstream logic, they might already have IDs assigned or need lookup.
                // For `llm-cost` counting, we typically handle them before BPE or assume 1 token.
                // Here we append 0 (UNK) or a specific ID if we had a special_map.
                // TODO: Wire up real special token ID lookup if needed for full encoding parity.
                try tokens.append(0);
            } else {
                try self.encodeWord(pt.text, &tokens);
            }
        }

        return tokens.toOwnedSlice();
    }

    /// Core BPE Merge for a single word
    fn encodeWord(self: BpeEngine, word: []const u8, output: *std.ArrayList(u32)) !void {
        // Optimization heuristic: for short words, simple O(N^2) is faster (lower constant overhead).
        // For long words (e.g. repeated characters), O(N log N) is critical.
        if (word.len < HeapThreshold) {
            try self.encodeWordNaive(word, output);
        } else {
            try self.encodeWordHeap(word, output);
        }
    }

    /// O(N^2) Naive implementation (faster for small N)
    /// Renamed from 'simple' to 'naive' as per plan.
    fn encodeWordNaive(self: BpeEngine, word: []const u8, output: *std.ArrayList(u32)) !void {
        var parts = std.ArrayList([]const u8).init(output.allocator);
        defer parts.deinit();

        for (0..word.len) |i| {
            try parts.append(word[i .. i + 1]);
        }

        // BPE Loop
        while (parts.items.len > 1) {
            var min_rank: u32 = std.math.maxInt(u32);
            var best_idx: ?usize = null;

            for (0..parts.items.len - 1) |i| {
                const p1 = parts.items[i];
                const p2 = parts.items[i + 1];

                // Safety invariant: ps are adjacent slices of the original word.
                std.debug.assert(@intFromPtr(p1.ptr) + p1.len == @intFromPtr(p2.ptr));

                const merged = p1.ptr[0 .. p1.len + p2.len];

                if (self.getRank(merged)) |r| {
                    if (r < min_rank) {
                        min_rank = r;
                        best_idx = i;
                    }
                }
            }

            if (best_idx) |idx| {
                const p1 = parts.items[idx];
                const p2 = parts.items[idx + 1];
                parts.items[idx] = p1.ptr[0 .. p1.len + p2.len];
                _ = parts.orderedRemove(idx + 1);
            } else {
                break;
            }
        }

        // Output
        for (parts.items) |part| {
            if (self.getRank(part)) |r| {
                try output.append(r);
            } else {
                try output.append(0);
            }
        }
    }

    /// O(N log N) Heap-based implementation (Robust for large N)
    /// Uses lazy invalidation with generation counters to ensure correctness.
    fn encodeWordHeap(self: BpeEngine, word: []const u8, output: *std.ArrayList(u32)) !void {
        const alloc = output.allocator;

        // Doubly-Linked List Node
        const Node = struct {
            prev: NodeIndex,
            next: NodeIndex,

            // Slice info
            offset: u32,
            len: u32,

            // State
            alive: bool,
            gen: u32,
        };

        // Edge candidate for merging
        const Edge = struct {
            rank: u32,
            left: NodeIndex,
            right: NodeIndex,
            left_pos: NodeIndex, // Tie-breaker for determinism (left-most first)

            // Validation
            left_gen: u32,
            right_gen: u32,

            fn compare(_: void, a: @This(), b: @This()) std.math.Order {
                // PriorityQueue pops the "smaller" item first.
                // We want min rank.
                if (a.rank < b.rank) return .lt;
                if (a.rank > b.rank) return .gt;
                // If ranks equal, we want left-most (smaller left_pos).
                if (a.left_pos < b.left_pos) return .lt;
                if (a.left_pos > b.left_pos) return .gt;
                return .eq;
            }
        };

        var nodes = try std.ArrayList(Node).initCapacity(alloc, word.len);
        defer nodes.deinit();

        // 1. Initialize nodes
        for (0..word.len) |i| {
            nodes.appendAssumeCapacity(.{
                .prev = if (i > 0) @as(NodeIndex, @intCast(i - 1)) else InvalidIndex,
                .next = if (i < word.len - 1) @as(NodeIndex, @intCast(i + 1)) else InvalidIndex,
                .offset = @as(u32, @intCast(i)),
                .len = 1,
                .alive = true,
                .gen = 0,
            });
        }

        // 2. Priority Queue
        var pq = std.PriorityQueue(Edge, void, Edge.compare).init(alloc, {});
        defer pq.deinit();

        // Fill initial edges
        var i: usize = 0;
        while (i < nodes.items.len - 1) : (i += 1) {
            const l_idx = @as(NodeIndex, @intCast(i));
            const r_idx = @as(NodeIndex, @intCast(i + 1));
            const n_left = &nodes.items[l_idx];
            const n_right = &nodes.items[r_idx];
            const merged_slice = word[n_left.offset .. n_left.offset + n_left.len + n_right.len];

            if (self.getRank(merged_slice)) |rank| {
                try pq.add(.{ .rank = rank, .left = l_idx, .right = r_idx, .left_pos = l_idx, .left_gen = n_left.gen, .right_gen = n_right.gen });
            }
        }

        // 3. Merge Loop
        while (pq.removeOrNull()) |edge| {
            const l_idx = edge.left;
            const r_idx = edge.right;

            if (l_idx >= nodes.items.len or r_idx >= nodes.items.len) continue;

            const l_node = &nodes.items[l_idx];
            const r_node = &nodes.items[r_idx];

            // Validation
            if (!l_node.alive or !r_node.alive) continue;
            if (l_node.gen != edge.left_gen or r_node.gen != edge.right_gen) continue;
            if (l_node.next != r_idx or r_node.prev != l_idx) continue;

            // Merge
            l_node.len += r_node.len;
            l_node.gen += 1;

            r_node.alive = false;

            const right_neighbor_idx = r_node.next;
            l_node.next = right_neighbor_idx;

            if (right_neighbor_idx != InvalidIndex) {
                nodes.items[right_neighbor_idx].prev = l_idx;
            }

            // New Edges
            const left_neighbor_idx = l_node.prev;
            if (left_neighbor_idx != InvalidIndex) {
                const ln_node = &nodes.items[left_neighbor_idx];
                if (ln_node.alive) {
                    const slice = word[ln_node.offset .. ln_node.offset + ln_node.len + l_node.len];
                    if (self.getRank(slice)) |r| {
                        try pq.add(.{ .rank = r, .left = left_neighbor_idx, .right = l_idx, .left_pos = left_neighbor_idx, .left_gen = ln_node.gen, .right_gen = l_node.gen });
                    }
                }
            }

            if (right_neighbor_idx != InvalidIndex) {
                const rn_node = &nodes.items[right_neighbor_idx];
                if (rn_node.alive) {
                    const slice = word[l_node.offset .. l_node.offset + l_node.len + rn_node.len];
                    if (self.getRank(slice)) |r| {
                        try pq.add(.{ .rank = r, .left = l_idx, .right = right_neighbor_idx, .left_pos = l_idx, .left_gen = l_node.gen, .right_gen = rn_node.gen });
                    }
                }
            }
        }

        // 4. Extract
        var curr: NodeIndex = 0;
        while (curr != InvalidIndex) {
            const n = nodes.items[curr];
            if (n.alive) {
                const part = word[n.offset .. n.offset + n.len];
                if (self.getRank(part)) |r| {
                    try output.append(r);
                } else {
                    try output.append(0);
                }
            }
            curr = n.next;
        }
    }
};
