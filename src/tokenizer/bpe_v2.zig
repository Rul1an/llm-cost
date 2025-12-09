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
        errdefer tokens.deinit();

        for (pre_tokens) |pt| {
            if (pt.is_special) {
                // Should not happen in current paths
                try tokens.append(0);
            } else {
                if (use_v2_1) {
                    try self.encodeWordV2_1(alloc, pt.text, &tokens);
                } else {
                    try self.encodeWord(alloc, pt.text, &tokens);
                }
            }
        }

        return tokens.toOwnedSlice();
    }

// ... (skipping unchanged parts)

    fn encodeWordV2_1(self: *const BpeEngineV2, alloc: std.mem.Allocator, word: []const u8, output: *std.ArrayList(u32)) !void {
        if (word.len == 0) return;

        // 1. Map bytes to initial tokens
        var initial_tokens = try std.ArrayList(u32).initCapacity(alloc, word.len);
        defer initial_tokens.deinit();

        for (word) |b| {
            initial_tokens.appendAssumeCapacity(self.byte_to_token[b]);
        }

        // 2. Call v2.1 Engine
        const table = TextLookupTable{ .engine = self };
        const res = try bpe_v2_1.encodeLinear(alloc, initial_tokens.items, &table);
        defer alloc.free(res); // result is owned by alloc (arena from caller)

        // 3. Append to output
        try output.appendSlice(res);
    }

    /// Core BPE Merge for a single word
    fn encodeWord(self: *const BpeEngineV2, alloc: std.mem.Allocator, word: []const u8, output: *std.ArrayList(u32)) !void {
        // ... (skipping comments)

        // ...

        var nodes = try std.ArrayList(Node).initCapacity(alloc, word.len);
        defer nodes.deinit();

        // Used to track valid merges
        const Merge = struct {
            rank: u32,
            node_idx: NodeIndex, // The left node index
            gen: u32, // Generation of the left node when added

            fn lessThan(_: void, a: @This(), b: @This()) bool {
                if (a.rank < b.rank) return true;
                if (a.rank > b.rank) return false;
                if (a.node_idx < b.node_idx) return true;
                return false;
            }
        };

        var pq = std.PriorityQueue(Merge, void, Merge.lessThan).init(alloc, {});
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
                try output.append(r);
            } else {
                // Fallback for bytes that didn't merge into anything?
                // Usually bytes map to ranks. If not, UNK (0).
                // Actually, in Tiktoken vocabs, every byte usually has a rank.
                // If we get here, our vocab definition is incomplete or data corrupted.
                std.debug.assert(false);
                try output.append(0);
            }
            curr = n.next;
        }
    }
};
