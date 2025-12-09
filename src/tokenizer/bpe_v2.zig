const std = @import("std");
const pre_tokenizer = @import("pre_tokenizer.zig");
const bpe_v2_1 = @import("bpe_v2_1.zig");

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

/// BPE v2 Engine
///
/// Features:
/// - O(1) Rank lookup (using std.StringHashMap).
/// - Heap-based BPE merge (O(N log N) worst-case) with O(1) rank lookup.
///   Observed behavior is near-linear for realistic inputs due to low constant factors.
/// - Precomputed tables built once at init.
pub const BpeEngineV2 = struct {
    // We map string content -> rank.
    // The keys point into `string_blob` which is stable (mmap or embedded).
    rank_map: std.StringHashMap(u32),
    string_blob: []const u8,
    allocator: std.mem.Allocator,

    // v2.1 support tables
    token_slices: [][]const u8,
    byte_to_token: [256]u32,

    pub fn init(allocator: std.mem.Allocator, embedded_data: []const u8) !BpeEngineV2 {
        if (embedded_data.len < @sizeOf(Header)) return error.InvalidData;

        const header = std.mem.bytesToValue(Header, embedded_data[0..@sizeOf(Header)]);
        if (header.magic != 0xAABBCCDD) return error.InvalidMagic;

        const index_start = @sizeOf(Header);
        const index_size = @as(usize, @intCast(header.count)) * @sizeOf(IndexEntry);

        if (embedded_data.len < index_start + index_size) return error.TruncatedData;
        const index_bytes = embedded_data[index_start .. index_start + index_size];

        // Safety: assuming alignment from embedding/tool.
        const index_ptr: [*]const IndexEntry = @ptrCast(@alignCast(index_bytes.ptr));
        const index = index_ptr[0..header.count];

        const strings_start = index_start + index_size;
        if (embedded_data.len < strings_start + header.strings_len) return error.TruncatedStrings;
        const string_blob = embedded_data[strings_start .. strings_start + header.strings_len];

        // Build the Rank Map
        const initial_capacity = header.count;
        var map = std.StringHashMap(u32).init(allocator);
        try map.ensureTotalCapacity(initial_capacity);

        // Also build token_slices for v2.1 inverse lookup
        // Assuming max rank is < header.count (dense), but let's be safe and alloc based on max rank found?
        // Actually, tiktoken counts are vocabulary sizes. Ranks are 0..Count-1 usually.
        var max_rank: u32 = 0;
        for (index) |entry| {
            if (entry.rank > max_rank) max_rank = entry.rank;
        }

        // Inverse table: Rank -> String
        // Initialize with empty slices
        var token_slices = try allocator.alloc([]const u8, max_rank + 1);
        @memset(token_slices, "");

        for (index) |entry| {
            const token_slice = string_blob[entry.offset .. entry.offset + entry.len];
            map.putAssumeCapacity(token_slice, entry.rank);
            if (entry.rank < token_slices.len) {
                token_slices[entry.rank] = token_slice;
            }
        }

        // Build byte_to_token map for v2.1 initial seeding
        var byte_to_token: [256]u32 = undefined;
        // Default to a sentinel or 0? 0 is usually UNK or valid token.
        // Let's assume 0 for now, but usually we should find them.
        @memset(&byte_to_token, 0);

        // Scan for 1-byte tokens corresponding to all 256 bytes.
        // For cl100k, these should exist.
        for (0..256) |b| {
            const byte_val = @as(u8, @intCast(b));
            // const char_slice = string_blob[0..0]; // Dummy removed

            // We search in map. Construct a 1-byte slice on stack?
            const byte_slice = [1]u8{byte_val};
            if (map.get(&byte_slice)) |rank| {
                byte_to_token[b] = rank;
            }
            // If missing, it remains 0. Ideally should not happen for bytes used in text.
        }

        return BpeEngineV2{
            .rank_map = map,
            .string_blob = string_blob,
            .allocator = allocator,
            .token_slices = token_slices,
            .byte_to_token = byte_to_token,
        };
    }

    pub fn deinit(self: *BpeEngineV2) void {
        self.rank_map.deinit();
        self.allocator.free(self.token_slices);
    }

    pub fn getRank(self: BpeEngineV2, token: []const u8) ?u32 {
        return self.rank_map.get(token);
    }

    /// Encode pre-tokenized text segments.
    /// Supports switching between "v2" (text-based heap) and "v2_1" (index-based heap).
    /// `version` arg controls the engine implementation.
    /// Note: engine.zig should propagate the version from config.
    pub fn encode(self: *const BpeEngineV2, alloc: std.mem.Allocator, pre_tokens: []const pre_tokenizer.PreToken, use_v2_1: bool) ![]u32 {
        var tokens = std.ArrayList(u32).initCapacity(alloc, pre_tokens.len) catch return error.OutOfMemory;
        errdefer tokens.deinit(alloc);

        for (pre_tokens) |pt| {
            if (pt.is_special) {
                std.debug.assert(false); // Should not happen in current paths
                try tokens.append(alloc, 0);
            } else {
                if (use_v2_1) {
                    try self.encodeWordV2_1(alloc, pt.text, &tokens);
                } else {
                    try self.encodeWord(alloc, pt.text, &tokens);
                }
            }
        }

        return tokens.toOwnedSlice(alloc);
    }

    /// Lookup table adapter for bpe_v2_1
    const TextLookupTable = struct {
        engine: *const BpeEngineV2,

        pub fn lookup(self: TextLookupTable, left: u32, right: u32) ?struct{id: u32, rank: u32} {
            // Reconstruct the pair string
            // We use a small static buffer optimization if possible, or alloc.
            // But we can't easily alloc here without an allocator passed to lookup.
            // BPeEngineV2 has .allocator but it is not arena-scoped.
            // HOWEVER: We can use the engine's rank_map directly if we have the string.
            // left/right act as indices into token_slices.
            if (left >= self.engine.token_slices.len or right >= self.engine.token_slices.len) return null;

            const s1 = self.engine.token_slices[left];
            const s2 = self.engine.token_slices[right];

            // Fast path for small strings (most BPE pairs)
            var buf: [128]u8 = undefined;
            if (s1.len + s2.len <= buf.len) {
                const total_len = s1.len + s2.len;
                @memcpy(buf[0..s1.len], s1);
                @memcpy(buf[s1.len..total_len], s2);
                if (self.engine.rank_map.get(buf[0..total_len])) |r| {
                    return .{ .id = r, .rank = r };
                }
            } else {
                // Large string fallback (allocating)
                const concat = self.engine.allocator.alloc(u8, s1.len + s2.len) catch return null; // Swallow error? bpe_v2_1 expects ?Entry
                defer self.engine.allocator.free(concat);
                @memcpy(concat[0..s1.len], s1);
                @memcpy(concat[s1.len..], s2);
                if (self.engine.rank_map.get(concat)) |r| {
                    return .{ .id = r, .rank = r };
                }
            }
            return null;
        }
    };

    fn encodeWordV2_1(self: *const BpeEngineV2, alloc: std.mem.Allocator, word: []const u8, output: *std.ArrayList(u32)) !void {
        if (word.len == 0) return;

        // 1. Map bytes to initial tokens
        var initial_tokens = try std.ArrayList(u32).initCapacity(alloc, word.len);
        defer initial_tokens.deinit(alloc);

        for (word) |b| {
            initial_tokens.appendAssumeCapacity(self.byte_to_token[b]);
        }

        // 2. Call v2.1 Engine
        const table = TextLookupTable{ .engine = self };
        const res = try bpe_v2_1.encodeLinear(alloc, initial_tokens.items, &table);
        defer alloc.free(res); // result is owned by alloc (arena from caller)

        // 3. Append to output
        try output.appendSlice(alloc, res);
    }

    /// Core BPE Merge for a single word
    fn encodeWord(self: *const BpeEngineV2, alloc: std.mem.Allocator, word: []const u8, output: *std.ArrayList(u32)) !void {
        // For very short words, just linear scan usage is fine?
        // Actually, let's use a robust implementation for all.
        // We use a linked-list + priority queue approach, but optimized.

        // 1. Initial Tokens (bytes)
        // If word is empty, do nothing.
        if (word.len == 0) return;

        // Optimization: If word length is 1, just return the rank of that byte (if exists) or bytes.
        // Actually BPE rules usually start with characters.

        // Let's implement the standard Heap BPE but with our O(1) map.
        // To be truly linear time for repeated merges (aaaa...), we need to handle updates efficiently.
        // But first, let's just use the O(1) lookup which is the biggest win.
        // The "observed linear time" mainly comes from not doing O(N) scans for every merge.
        // The Heap method is O(N log N) in number of tokens.
        // If N is input bytes, and we merge k times (k < N), it's fast.

        // We reuse the logic from bpe.zig but with rank_map.
        // To strictly meet "pure zig linear scaling", we can use a "lazy" heap or just standard heap + O(1) lookup.

        // TODO: Refactor the Heap logic from bpe.zig into here, adapted for O(1) lookup.
        // For this task, I will implant a clean version of that logic.

        const NodeIndex = u32;
        const InvalidIndex = std.math.maxInt(NodeIndex);

        const Node = struct {
            prev: NodeIndex,
            next: NodeIndex,
            offset: u32,
            len: u32,
            rank: u32, // Cache rank of (this + next)
            gen: u32,
        };

        var nodes = try std.ArrayList(Node).initCapacity(alloc, word.len);
        defer nodes.deinit(alloc);

        // Used to track valid merges
        const Merge = struct {
            rank: u32,
            node_idx: NodeIndex, // The left node index
            gen: u32, // Generation of the left node when added

            fn compare(_: void, a: @This(), b: @This()) std.math.Order {
                if (a.rank < b.rank) return .lt;
                if (a.rank > b.rank) return .gt;
                if (a.node_idx < b.node_idx) return .lt;
                if (a.node_idx > b.node_idx) return .gt;
                return .eq;
            }
        };

        var pq = std.PriorityQueue(Merge, void, Merge.compare).init(alloc, {});
        defer pq.deinit();

        // Initialize nodes
        for (0..word.len) |i| {
            nodes.appendAssumeCapacity(.{
                .prev = if (i > 0) @as(NodeIndex, @intCast(i - 1)) else InvalidIndex,
                .next = if (i < word.len - 1) @as(NodeIndex, @intCast(i + 1)) else InvalidIndex,
                .offset = @as(u32, @intCast(i)),
                .len = 1,
                .rank = std.math.maxInt(u32), // Unknown initially
                .gen = 0,
            });
        }

        // Calculate initial ranks for all pairs
        for (0..nodes.items.len - 1) |i| {
            const idx = @as(NodeIndex, @intCast(i));
            const n = &nodes.items[idx];
            const next_n = &nodes.items[n.next];

            const piece = word[n.offset .. n.offset + n.len + next_n.len];
            if (self.getRank(piece)) |r| {
                n.rank = r;
                try pq.add(.{
                    .rank = r,
                    .node_idx = idx,
                    .gen = n.gen,
                });
            }
        }

        // Processing loop
        while (pq.removeOrNull()) |merge| {
            const l_idx = merge.node_idx;
            // Check validity
            if (l_idx >= nodes.items.len) continue;

            var l_node = &nodes.items[l_idx]; // Pointer might be invalidated if array reallocs? No, array size fixed to word.len?
            // Wait, nodes array does not grow. word.len is max nodes.
            // But pointers Into `nodes.items` are unsafe if we appended. We don't append.

            if (l_node.gen != merge.gen) continue; // Lazy deletion check

            if (l_node.rank != merge.rank) continue; // Rank changed?

            if (l_node.next == InvalidIndex) continue; // Should not happen if rank exists

            const r_idx = l_node.next;
            var r_node = &nodes.items[r_idx];

            // Perform Merge
            // L becomes L+R
            l_node.len += r_node.len;
            l_node.gen += 1; // Invalidate old references to L
            l_node.rank = std.math.maxInt(u32); // Reset rank for new pair (L+R) + Next

            // R is consumed
            // We don't remove R from array, just link around it.
            // But we must invalidate R's outgoing edges if any?
            // R's previous `rank` (for pair R+Next) is now invalid because R is gone.
            // But R is "dead".
            r_node.gen += 1; // Invalidate references to R

            const right_neighbor = r_node.next;
            l_node.next = right_neighbor;

            if (right_neighbor != InvalidIndex) {
                nodes.items[right_neighbor].prev = l_idx;
            }

            // Update Left Neighbor interaction: (Prev + L)
            const left_neighbor = l_node.prev;
            if (left_neighbor != InvalidIndex) {
                var ln_node = &nodes.items[left_neighbor];
                const piece = word[ln_node.offset .. ln_node.offset + ln_node.len + l_node.len];

                if (self.getRank(piece)) |r| {
                    if (r != ln_node.rank or r < ln_node.rank) { // Optimization: only push if rank improved? No, rank changed.
                        ln_node.rank = r;
                        ln_node.gen += 1; // Invalidate old merge for Prev
                        try pq.add(.{
                            .rank = r,
                            .node_idx = left_neighbor,
                            .gen = ln_node.gen,
                        });
                    }
                } else {
                    ln_node.rank = std.math.maxInt(u32);
                    ln_node.gen += 1;
                }
            }

            // Update New L interaction: (L + Next)
            if (l_node.next != InvalidIndex) {
                const n_next = &nodes.items[l_node.next];
                const piece = word[l_node.offset .. l_node.offset + l_node.len + n_next.len];

                if (self.getRank(piece)) |r| {
                    l_node.rank = r;
                    // gen already incremented
                    try pq.add(.{
                        .rank = r,
                        .node_idx = l_idx,
                        .gen = l_node.gen,
                    });
                }
            }
        }

        // Collect result
        var curr: NodeIndex = 0;
        while (curr != InvalidIndex) {
            const n = nodes.items[curr];
            const piece = word[n.offset .. n.offset + n.len];
            if (self.getRank(piece)) |r| {
                try output.append(alloc, r);
            } else {
                // Fallback for bytes that didn't merge into anything?
                // Usually bytes map to ranks. If not, UNK (0).
                // Actually, in Tiktoken vocabs, every byte usually has a rank.
                // If we get here, our vocab definition is incomplete or data corrupted.
                std.debug.assert(false);
                try output.append(alloc, 0);
            }
            curr = n.next;
        }
    }
};
