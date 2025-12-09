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

// ============================================================================
// Type Definitions for BPE Algorithm
// ============================================================================

const NodeIndex = u32;
const InvalidIndex = std.math.maxInt(NodeIndex);

/// Node for linked-list based BPE merging (v2 text-based algorithm)
const Node = struct {
    prev: NodeIndex,
    next: NodeIndex,
    offset: u32, // Start offset in original word
    len: u32, // Length in bytes
    rank: u32, // Best merge rank (maxInt if no merge available)
    gen: u32, // Generation counter for lazy deletion
};

/// Adapter for v2.1 index-based BPE engine.
/// Wraps BpeEngineV2 to provide the `lookup(TokenId, TokenId) -> ?MergeEntry` interface
/// required by bpe_v2_1.encodeLinear.
const TextLookupTable = struct {
    engine: *const BpeEngineV2,

    const MergeEntry = struct {
        id: u32,
        rank: u32,
    };

    /// Lookup merge for two adjacent tokens.
    /// Returns merged token ID and rank, or null if no merge exists.
    pub fn lookup(self: *const TextLookupTable, left: u32, right: u32) ?MergeEntry {
        // Get string representations
        const left_str = self.engine.tokenSlice(left) orelse return null;
        const right_str = self.engine.tokenSlice(right) orelse return null;

        // Concatenate (stack buffer for small merges, heap for large)
        const total_len = left_str.len + right_str.len;
        if (total_len > 256) return null; // Sanity limit

        var buf: [256]u8 = undefined;
        @memcpy(buf[0..left_str.len], left_str);
        @memcpy(buf[left_str.len..][0..right_str.len], right_str);

        const merged = buf[0..total_len];

        // Lookup in rank map
        if (self.engine.rank_map.get(merged)) |rank| {
            return .{ .id = rank, .rank = rank };
        }
        return null;
    }
};

// ============================================================================
// BPE Engine v2
// ============================================================================

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
        errdefer map.deinit();
        try map.ensureTotalCapacity(initial_capacity);

        // Find max rank for inverse table sizing
        var max_rank: u32 = 0;
        for (index) |entry| {
            if (entry.rank > max_rank) max_rank = entry.rank;
        }

        // Inverse table: Rank -> String
        var token_slices = try allocator.alloc([]const u8, max_rank + 1);
        errdefer allocator.free(token_slices);
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
        @memset(&byte_to_token, 0);

        // Scan for 1-byte tokens corresponding to all 256 bytes
        for (0..256) |b| {
            const byte_val = @as(u8, @intCast(b));
            const byte_slice = [1]u8{byte_val};
            if (map.get(&byte_slice)) |rank| {
                byte_to_token[b] = rank;
            }
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

    pub fn getRank(self: *const BpeEngineV2, token: []const u8) ?u32 {
        return self.rank_map.get(token);
    }

    /// Get string slice for a token ID (used by TextLookupTable)
    pub fn tokenSlice(self: *const BpeEngineV2, token_id: u32) ?[]const u8 {
        if (token_id >= self.token_slices.len) return null;
        const slice = self.token_slices[token_id];
        if (slice.len == 0) return null;
        return slice;
    }

    /// Encode pre-tokenized text segments.
    /// Supports switching between "v2" (text-based heap) and "v2_1" (index-based heap).
    pub fn encode(self: *const BpeEngineV2, alloc: std.mem.Allocator, pre_tokens: []const pre_tokenizer.PreToken, use_v2_1: bool) ![]u32 {
        var tokens = std.ArrayList(u32).init(alloc);
        errdefer tokens.deinit();

        for (pre_tokens) |pt| {
            if (pt.is_special) {
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

    /// v2.1 encoding: index-based BPE using bpe_v2_1 module
    fn encodeWordV2_1(self: *const BpeEngineV2, alloc: std.mem.Allocator, word: []const u8, output: *std.ArrayList(u32)) !void {
        if (word.len == 0) return;

        // 1. Map bytes to initial tokens
        var initial_tokens = std.ArrayList(u32).init(alloc);
        defer initial_tokens.deinit();
        try initial_tokens.ensureTotalCapacity(word.len);

        for (word) |b| {
            initial_tokens.appendAssumeCapacity(self.byte_to_token[b]);
        }

        // 2. Call v2.1 Engine with TextLookupTable adapter
        const table = TextLookupTable{ .engine = self };
        const res = try bpe_v2_1.encodeLinear(alloc, initial_tokens.items, &table);
        defer alloc.free(res);

        // 3. Append to output
        try output.appendSlice(res);
    }

    /// Core BPE Merge for a single word (v2 text-based algorithm)
    fn encodeWord(self: *const BpeEngineV2, alloc: std.mem.Allocator, word: []const u8, output: *std.ArrayList(u32)) !void {
        if (word.len == 0) return;

        // Single byte optimization
        if (word.len == 1) {
            if (self.getRank(word)) |r| {
                try output.append(r);
            } else {
                try output.append(0);
            }
            return;
        }

        var nodes = std.ArrayList(Node).init(alloc);
        defer nodes.deinit();
        try nodes.ensureTotalCapacity(word.len);

        // Merge tracking struct for priority queue
        const Merge = struct {
            rank: u32,
            node_idx: NodeIndex,
            gen: u32,

            fn lessThan(_: void, a: @This(), b: @This()) std.math.Order {
                if (a.rank < b.rank) return .lt;
                if (a.rank > b.rank) return .gt;
                if (a.node_idx < b.node_idx) return .lt;
                if (a.node_idx > b.node_idx) return .gt;
                return .eq;
            }
        };

        var pq = std.PriorityQueue(Merge, void, Merge.lessThan).init(alloc, {});
        defer pq.deinit();

        // Initialize nodes (one per byte)
        for (0..word.len) |i| {
            nodes.appendAssumeCapacity(.{
                .prev = if (i > 0) @as(NodeIndex, @intCast(i - 1)) else InvalidIndex,
                .next = if (i < word.len - 1) @as(NodeIndex, @intCast(i + 1)) else InvalidIndex,
                .offset = @as(u32, @intCast(i)),
                .len = 1,
                .rank = std.math.maxInt(u32),
                .gen = 0,
            });
        }

        // Calculate initial ranks for all adjacent pairs
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

        // BPE merge loop
        while (pq.removeOrNull()) |merge| {
            const l_idx = merge.node_idx;

            // Validity checks
            if (l_idx >= nodes.items.len) continue;

            var l_node = &nodes.items[l_idx];
            if (l_node.gen != merge.gen) continue;
            if (l_node.rank != merge.rank) continue;
            if (l_node.next == InvalidIndex) continue;

            const r_idx = l_node.next;
            var r_node = &nodes.items[r_idx];

            // Perform merge: L absorbs R
            l_node.len += r_node.len;
            l_node.gen += 1;
            l_node.rank = std.math.maxInt(u32);

            r_node.gen += 1; // Invalidate R

            const right_neighbor = r_node.next;
            l_node.next = right_neighbor;

            if (right_neighbor != InvalidIndex) {
                nodes.items[right_neighbor].prev = l_idx;
            }

            // Re-evaluate left neighbor pair: (Prev + L)
            const left_neighbor = l_node.prev;
            if (left_neighbor != InvalidIndex) {
                var ln_node = &nodes.items[left_neighbor];
                const piece = word[ln_node.offset .. ln_node.offset + ln_node.len + l_node.len];

                if (self.getRank(piece)) |r| {
                    ln_node.rank = r;
                    ln_node.gen += 1;
                    try pq.add(.{
                        .rank = r,
                        .node_idx = left_neighbor,
                        .gen = ln_node.gen,
                    });
                } else {
                    ln_node.rank = std.math.maxInt(u32);
                    ln_node.gen += 1;
                }
            }

            // Re-evaluate new pair: (L + Next)
            if (l_node.next != InvalidIndex) {
                const n_next = &nodes.items[l_node.next];
                const piece = word[l_node.offset .. l_node.offset + l_node.len + n_next.len];

                if (self.getRank(piece)) |r| {
                    l_node.rank = r;
                    try pq.add(.{
                        .rank = r,
                        .node_idx = l_idx,
                        .gen = l_node.gen,
                    });
                }
            }
        }

        // Collect results by traversing linked list
        var curr: NodeIndex = 0;
        while (curr != InvalidIndex) {
            const n = nodes.items[curr];
            const piece = word[n.offset .. n.offset + n.len];
            if (self.getRank(piece)) |r| {
                try output.append(r);
            } else {
                try output.append(0); // Fallback UNK
            }
            curr = n.next;
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "BpeEngineV2: basic init" {
    // Minimal test to ensure types compile
    const allocator = std.testing.allocator;
    _ = allocator;
    // Full init test requires valid embedded_data
}
