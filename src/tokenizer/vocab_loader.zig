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
        MissingByteToken, // Specific: Byte not found in vocab
        ByteTokenMismatch, // Specific: Byte token content mismatch
        InvalidMaxTokenLen, // Specific: max_token_len is 0 or wildly invalid
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

        // Sanity check max_token_len
        if (max_token_len == 0) return error.InvalidMaxTokenLen;
        // Optional: warn or fail if max_token_len > blob_size/token_count?
        // Ideally max_token_len shouldn't exceed the total blob size.
        if (max_token_len > blob_size) return error.InvalidMaxTokenLen;

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
            if (length > max_token_len) return error.InvalidTokenTable; // Validation

            const token_bytes = blob[offset .. offset + length];

            // Store in both directions
            token_slices[i] = token_bytes;
            rank_map.putAssumeCapacity(token_bytes, i);
        }

        // 7. Build byte_to_token map (single-byte tokens)
        var byte_to_token: [256]u32 = undefined;
        // Strict check: every byte MUST have a token ID in the vocab.
        for (0..256) |b| {
            const single_byte = [1]u8{@intCast(b)};
            if (rank_map.get(&single_byte)) |rank| {
                byte_to_token[b] = rank;

                // Extra hardening: Verify the mapped token is indeed [b]
                // This protects against logic errors in rank_map construction or corrupted lookup
                const bytes = token_slices[rank];
                if (bytes.len != 1 or bytes[0] != @as(u8, @intCast(b))) {
                    return error.ByteTokenMismatch;
                }
            } else {
                // Critical failure for a complete BPE vocab
                return error.MissingByteToken;
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
    scratch: []u8, // Must be >= vocab.max_token_len

    pub const MergeEntry = struct {
        id: u32,
        rank: u32,
    };

    pub fn lookup(self: *const VocabMergeTable, left: u32, right: u32) ?MergeEntry {
        const a = self.vocab.getBytes(left) orelse return null;
        const b = self.vocab.getBytes(right) orelse return null;

        const total = a.len + b.len;
        if (total > self.scratch.len) return null;

        @memcpy(self.scratch[0..a.len], a);
        @memcpy(self.scratch[a.len..][0..b.len], b);

        if (self.vocab.rank_map.get(self.scratch[0..total])) |merged| {
            return .{ .id = merged, .rank = merged };
        }
        return null;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "VocabLoader: header parsing" {
    // Strict Mode requires all 256 bytes to be present in vocab.
    // We generate a minimal valid vocab where every byte 0..255 maps to rank i.
    const token_count: u32 = 256;
    const blob_size: u32 = 256;
    const header_size: usize = 64;
    const table_size: usize = 256 * 8;
    const total_size = header_size + table_size + blob_size;

    var data = try std.testing.allocator.alloc(u8, total_size);
    defer std.testing.allocator.free(data);
    @memset(data, 0);

    // Magic
    @memcpy(data[0..4], "BPE2");

    // Version = 2
    std.mem.writeInt(u32, data[4..8], 2, .little);
    // Token count
    std.mem.writeInt(u32, data[8..12], token_count, .little);
    // Max token len = 1
    std.mem.writeInt(u32, data[12..16], 1, .little);
    // Blob size
    std.mem.writeInt(u32, data[16..20], blob_size, .little);

    // Write Token Table + Blob
    // For each byte b (rank i):
    // Table Entry: offset = b, length = 1
    // Blob[b] = b
    const table_start = header_size;
    const blob_start = header_size + table_size;

    for (0..256) |i| {
        const offset: u32 = @intCast(i);
        const length: u32 = 1;

        // Table entry at table_start + i*8
        const entry_off = table_start + i * 8;
        std.mem.writeInt(u32, data[entry_off..][0..4], offset, .little);
        std.mem.writeInt(u32, data[entry_off + 4 ..][0..4], length, .little);

        // Blob byte
        data[blob_start + i] = @intCast(i);
    }

    const vocab = try VocabLoader.load(std.testing.allocator, data);
    defer @constCast(&vocab).deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 256), vocab.token_count);

    // Check random byte
    try std.testing.expectEqual(@as(u32, 65), vocab.getByteToken(65)); // 'A' -> rank 65
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

test "VocabLoader: embedded header sanity + reserved zeros" {
    // Only run this test if the file exists (it is gitignored but expected by build)
    // For CI parity, we check cl100k_base.bin if present.
    // If we can't depend on the file existing during unit tests without download, we skip or use @embedFile in a try/catch way?
    // Actually, @embedFile is compile time. If file missing, compile fails.
    // We assume the build system ensures this file exists (via tools/convert_vocab.zig).
    // Let's use @embedFile but we need to assume the path "../vocab/cl100k_base.bin" relative to this file.
    // However, vocab_loader.zig is in src/tokenizer/.
    // The previous code in registry.zig used @embedFile("../vocab/cl100k_base.bin").
    // Duplicating @embedFile here might be redundant but safe for a test.

    // NOTE: This test requires 'src/vocab/cl100k_base.bin' to exist.
    // IF IT DOES NOT EXIST compilation will fail.
    // This is consistent with audit requirements: build fails if assets missing.
    const data = @embedFile("../vocab/cl100k_base.bin");

    // 1. Magic
    try std.testing.expect(std.mem.eql(u8, data[0..4], "BPE2"));

    // 2. Version
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, data[4..8], .little));

    // 3. Reserved zeros (52..64)
    for (data[52..64]) |b| {
        try std.testing.expectEqual(@as(u8, 0), b);
    }

    // 4. Source hash exists
    const h = VocabLoader.getSourceHash(data) orelse return error.MissingHash;
    // We don't check content (requires separate tool), just presence.
    // Hash is [32]u8, unlikely to be all zeros if valid, but check just in case it's not empty slice.
    try std.testing.expect(h.len == 32);
}
