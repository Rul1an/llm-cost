const std = @import("std");

/// Vocabulary Loader for llm-cost
///
/// Loads binary vocabulary files created by tools/convert_vocab.zig.
/// Uses alignment-safe reads (no pointer casts on embedded data).
///
/// Usage:
///   const cl100k_data = @embedFile("vocab/cl100k_base.bin");
///   var vocab = try VocabLoader.load(allocator, cl100k_data);
///   defer vocab.deinit(allocator);
pub const VocabLoader = struct {
    // Runtime structures (heap-allocated)
    rank_map: std.StringHashMap(u32),
    token_slices: [][]const u8,
    byte_to_token: [256]u32,

    // Metadata
    token_count: u32,
    max_token_len: u32,

    // Reference to embedded blob (no ownership)
    blob: []const u8,

    const MAGIC = "BPE2";
    const VERSION: u32 = 2;
    const HEADER_SIZE: usize = 64;

    pub const LoadError = error{
        InvalidMagic,
        UnsupportedVersion,
        TruncatedData,
        InvalidTokenTable,
        OutOfMemory,
    };

    /// Load vocabulary from embedded binary data
    ///
    /// The `data` parameter should be from @embedFile and will be referenced
    /// (not copied) for token byte strings. The returned VocabLoader is valid
    /// as long as `data` remains valid.
    pub fn load(allocator: std.mem.Allocator, data: []const u8) LoadError!VocabLoader {
        // 1. Validate header
        if (data.len < HEADER_SIZE) return error.TruncatedData;

        // Magic check (alignment-safe)
        if (!std.mem.eql(u8, data[0..4], MAGIC)) return error.InvalidMagic;

        // Version check
        const version = std.mem.readInt(u32, data[4..8], .little);
        if (version != VERSION) return error.UnsupportedVersion;

        // Read header fields
        const token_count = std.mem.readInt(u32, data[8..12], .little);
        const max_token_len = std.mem.readInt(u32, data[12..16], .little);
        const blob_size = std.mem.readInt(u32, data[16..20], .little);
        // source_hash at 20..52 (for verification, not used at runtime)
        // reserved at 52..64

        // 2. Validate data size
        const token_table_size = @as(usize, token_count) * 8; // 2 * u32 per token
        const expected_size = HEADER_SIZE + token_table_size + blob_size;
        if (data.len < expected_size) return error.TruncatedData;

        // 3. Pointers into embedded data
        const token_table_start = HEADER_SIZE;
        const blob_start = HEADER_SIZE + token_table_size;
        const blob = data[blob_start .. blob_start + blob_size];

        // 4. Build rank_map (bytes -> rank)
        var rank_map = std.StringHashMap(u32).init(allocator);
        errdefer rank_map.deinit();
        try rank_map.ensureTotalCapacity(token_count);

        // 5. Build token_slices (rank -> bytes)
        var token_slices = allocator.alloc([]const u8, token_count) catch return error.OutOfMemory;
        errdefer allocator.free(token_slices);
        @memset(token_slices, "");

        // 6. Parse token table
        var i: u32 = 0;
        while (i < token_count) : (i += 1) {
            const entry_offset = token_table_start + @as(usize, i) * 8;
            const offset = std.mem.readInt(u32, data[entry_offset..][0..4], .little);
            const length = std.mem.readInt(u32, data[entry_offset + 4 ..][0..4], .little);

            if (length == 0) {
                // Empty token (gap in rank sequence) - skip
                continue;
            }

            if (offset + length > blob_size) return error.InvalidTokenTable;

            const token_bytes = blob[offset .. offset + length];

            // Store in both directions
            token_slices[i] = token_bytes;
            rank_map.putAssumeCapacity(token_bytes, i);
        }

        // 7. Build byte_to_token map (single-byte tokens)
        var byte_to_token: [256]u32 = undefined;
        @memset(&byte_to_token, 0); // Default to token 0 (usually exists)

        for (0..256) |b| {
            const single_byte = [1]u8{@intCast(b)};
            if (rank_map.get(&single_byte)) |rank| {
                byte_to_token[b] = rank;
            }
        }

        return VocabLoader{
            .rank_map = rank_map,
            .token_slices = token_slices,
            .byte_to_token = byte_to_token,
            .token_count = token_count,
            .max_token_len = max_token_len,
            .blob = blob,
        };
    }

    pub fn deinit(self: *VocabLoader, allocator: std.mem.Allocator) void {
        self.rank_map.deinit();
        allocator.free(self.token_slices);
    }

    /// Get rank for token bytes (for encoding)
    pub fn getRank(self: *const VocabLoader, bytes: []const u8) ?u32 {
        return self.rank_map.get(bytes);
    }

    /// Get bytes for rank (for decoding)
    pub fn getBytes(self: *const VocabLoader, rank: u32) ?[]const u8 {
        if (rank >= self.token_slices.len) return null;
        const slice = self.token_slices[rank];
        if (slice.len == 0) return null;
        return slice;
    }

    /// Get initial token for a single byte (for BPE seeding)
    pub fn getByteToken(self: *const VocabLoader, byte: u8) u32 {
        return self.byte_to_token[byte];
    }

    /// Check if a merge exists (used by BPE algorithm)
    /// Returns the merged token's rank if bytes(left) ++ bytes(right) exists in vocab
    pub fn getMergeRank(self: *const VocabLoader, left: u32, right: u32) ?u32 {
        const left_bytes = self.getBytes(left) orelse return null;
        const right_bytes = self.getBytes(right) orelse return null;

        // Stack buffer for small merges (covers 99%+ of cases)
        var buf: [256]u8 = undefined;
        const total_len = left_bytes.len + right_bytes.len;

        if (total_len > buf.len) {
            // Token too long - can't be in vocab anyway
            return null;
        }

        @memcpy(buf[0..left_bytes.len], left_bytes);
        @memcpy(buf[left_bytes.len..][0..right_bytes.len], right_bytes);

        return self.rank_map.get(buf[0..total_len]);
    }

    /// Get source hash (for verification)
    pub fn getSourceHash(data: []const u8) ?[32]u8 {
        if (data.len < 52) return null;
        var hash: [32]u8 = undefined;
        @memcpy(&hash, data[20..52]);
        return hash;
    }
};

// =============================================================================
// Integration with BpeEngineV2
// =============================================================================

/// Adapter for BPE v2.1 merge lookup
/// Implements the interface expected by bpe_v2_1.encodeLinear
pub const VocabMergeTable = struct {
    vocab: *const VocabLoader,

    pub const MergeEntry = struct {
        id: u32,
        rank: u32,
    };

    pub fn lookup(self: *const VocabMergeTable, left: u32, right: u32) ?MergeEntry {
        if (self.vocab.getMergeRank(left, right)) |merged_rank| {
            return .{ .id = merged_rank, .rank = merged_rank };
        }
        return null;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "VocabLoader: header parsing" {
    // Create minimal valid header (Header + 1 Token Entry + 1 Byte Blob)
    var data: [64 + 8 + 1]u8 = undefined;
    @memset(&data, 0);

    // Magic
    @memcpy(data[0..4], "BPE2");

    // Version = 2
    std.mem.writeInt(u32, data[4..8], 2, .little);

    // Token count = 1
    std.mem.writeInt(u32, data[8..12], 1, .little);

    // Max token len = 1
    std.mem.writeInt(u32, data[12..16], 1, .little);

    // Blob size = 1
    std.mem.writeInt(u32, data[16..20], 1, .little);

    // Token table entry: offset=0, length=1
    std.mem.writeInt(u32, data[64..68], 0, .little);
    std.mem.writeInt(u32, data[68..72], 1, .little);

    const vocab = try VocabLoader.load(std.testing.allocator, &data);
    defer @constCast(&vocab).deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 1), vocab.token_count);
}

test "VocabLoader: invalid magic" {
    var data: [64]u8 = undefined;
    @memset(&data, 0);
    @memcpy(data[0..4], "XXXX");

    try std.testing.expectError(
        VocabLoader.LoadError.InvalidMagic,
        VocabLoader.load(std.testing.allocator, &data),
    );
}

test "VocabLoader: truncated data" {
    const data = "BPE2"; // Too short
    try std.testing.expectError(
        VocabLoader.LoadError.TruncatedData,
        VocabLoader.load(std.testing.allocator, data),
    );
}
