const std = @import("std");

/// Vocabulary Loader for llm-cost
///
/// Loads binary vocabulary files (Format V4: Zero-Copy Hash Table).
/// Pairs are looked up directly from the embedded binary via linear probing
/// over a 16-byte aligned 128-bit entry table using pure integer reads.
pub const VocabLoader = struct {
    // Runtime structures (View into Blob)
    token_slices: [][]const u8,
    byte_to_token: [256]u32,

    // Hash Table View (Bytes only)
    table_bytes: []const u8,
    table_capacity: u32,

    // Metadata
    token_count: u32,
    max_token_len: u32,

    // Reference to embedded blob
    blob: []const u8,

    const MAGIC = "BPE4";
    const VERSION: u32 = 4;
    const HEADER_SIZE: usize = 64;
    const ENTRY_SIZE: usize = 16;

    pub const LoadError = error{
        InvalidMagic,
        UnsupportedVersion,
        TruncatedData,
        InvalidTokenTable,
        OutOfMemory,
        MissingByteToken,
        InvalidMaxTokenLen,
        InvalidAlignment,
    };

    /// Load vocabulary from embedded binary data
    pub fn load(allocator: std.mem.Allocator, data: []const u8) LoadError!VocabLoader {
        // 1. Validate header
        if (data.len < HEADER_SIZE) return error.TruncatedData;
        if (!std.mem.eql(u8, data[0..4], MAGIC)) return error.InvalidMagic;

        const version = std.mem.readInt(u32, data[4..8], .little);
        if (version != VERSION) return error.UnsupportedVersion;

        const token_count = std.mem.readInt(u32, data[8..12], .little);
        const max_token_len = std.mem.readInt(u32, data[12..16], .little);
        const blob_size = std.mem.readInt(u32, data[16..20], .little);

        // V4 Fields
        const table_capacity = std.mem.readInt(u32, data[52..56], .little);
        const table_offset = std.mem.readInt(u32, data[56..60], .little);

        if (max_token_len == 0 or max_token_len > blob_size) return error.InvalidMaxTokenLen;

        // 2. Validate bounds
        const token_table_size = @as(usize, token_count) * 8;
        const blob_start = HEADER_SIZE + token_table_size;

        // Validate table offset alignment and overlap
        if (table_offset % 16 != 0) return error.InvalidAlignment;
        if (table_offset < blob_start + blob_size) return error.TruncatedData;

        const table_size_bytes = @as(usize, table_capacity) * ENTRY_SIZE;
        if (table_offset + table_size_bytes > data.len) return error.TruncatedData;

        // 3. Setup Views
        const blob = data[blob_start .. blob_start + blob_size];

        // Token Slices (Rank -> Bytes)
        var token_slices = try allocator.alloc([]const u8, token_count);
        errdefer allocator.free(token_slices);

        var byte_to_token: [256]u32 = undefined;
        var found_bytes: usize = 0;

        var i: u32 = 0;
        const token_table_start = HEADER_SIZE;
        while (i < token_count) : (i += 1) {
            const entry_offset = token_table_start + @as(usize, i) * 8;
            const offset = std.mem.readInt(u32, data[entry_offset..][0..4], .little);
            const length = std.mem.readInt(u32, data[entry_offset + 4 ..][0..4], .little);

            if (length == 0) {
                token_slices[i] = "";
                continue;
            }
            if (offset + length > blob_size) return error.InvalidTokenTable;

            const token_bytes = blob[offset .. offset + length];
            token_slices[i] = token_bytes;

            if (length == 1) {
                const b = token_bytes[0];
                byte_to_token[b] = i;
                found_bytes += 1;
            }
        }
        if (found_bytes < 256) return error.MissingByteToken;

        // 4. Setup Hash Table View (Raw Bytes)
        const table_bytes = data[table_offset .. table_offset + table_size_bytes];

        return VocabLoader{
            .token_slices = token_slices,
            .byte_to_token = byte_to_token,
            .table_bytes = table_bytes,
            .table_capacity = table_capacity,
            .token_count = token_count,
            .max_token_len = max_token_len,
            .blob = blob,
        };
    }

    pub fn deinit(self: *VocabLoader, allocator: std.mem.Allocator) void {
        allocator.free(self.token_slices);
    }

    pub fn getBytes(self: *const VocabLoader, rank: u32) ?[]const u8 {
        if (rank >= self.token_slices.len) return null;
        return self.token_slices[rank];
    }

    pub fn getByteToken(self: *const VocabLoader, byte: u8) u32 {
        return self.byte_to_token[byte];
    }

    // Low-level Lookup (Linear Probing with integer reads)
    // Inline candidate
    pub fn lookupPair(self: *const VocabLoader, left: u32, right: u32) ?u32 {
        const capacity = self.table_capacity;
        if (capacity == 0) return null;

        const key = (@as(u64, left) << 32) | right;
        const key_plus1 = key + 1;

        // Must match convert_vocab hash logic (Wyhash seed 0)
        const key_bytes = std.mem.asBytes(&key);
        var idx = std.hash.Wyhash.hash(0, key_bytes) & (capacity - 1);
        const bytes = self.table_bytes;

        while (true) {
            const offset = @as(usize, idx) * 16;
            // Read key_plus1 (first 8 bytes)
            const stored_kp1 = std.mem.readInt(u64, bytes[offset..][0..8], .little);

            if (stored_kp1 == 0) {
                // Sentinel -> Not found
                return null;
            }

            if (stored_kp1 == key_plus1) {
                // Found -> Read val (next 4 bytes)
                return std.mem.readInt(u32, bytes[offset + 8 ..][0..4], .little);
            }

            idx = (idx + 1) & (capacity - 1);
        }
    }

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

pub const VocabMergeTable = struct {
    vocab: *const VocabLoader,

    pub const MergeEntry = struct {
        id: u32,
        rank: u32,
    };

    pub fn lookup(self: *const VocabMergeTable, left: u32, right: u32) ?MergeEntry {
        if (self.vocab.lookupPair(left, right)) |rank| {
            return .{ .id = rank, .rank = rank };
        }
        return null;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "VocabLoader: v4 readInt lookup" {
    // Manually construct a valid V4 blob
    const table_capacity = 4; // Must be power of 2
    const token_count = 256;

    var data = std.ArrayList(u8).init(std.testing.allocator);
    defer data.deinit();

    // Header
    try data.appendSlice("BPE4");
    var buf4: [4]u8 = undefined;

    std.mem.writeInt(u32, &buf4, 4, .little);
    try data.appendSlice(&buf4); // Version
    std.mem.writeInt(u32, &buf4, token_count, .little);
    try data.appendSlice(&buf4); // Count
    std.mem.writeInt(u32, &buf4, 1, .little);
    try data.appendSlice(&buf4); // MaxLen
    std.mem.writeInt(u32, &buf4, 256, .little);
    try data.appendSlice(&buf4); // BlobSize
    try data.appendNTimes(0, 32); // SourceHash
    std.mem.writeInt(u32, &buf4, table_capacity, .little);
    try data.appendSlice(&buf4); // Capacity (Offset 52)
    // Offset 56 will be written later
    try data.appendNTimes(0, 8); // Reserved/Offset place holder

    // Tokens
    for (0..256) |i| {
        std.mem.writeInt(u32, &buf4, @intCast(i), .little);
        try data.appendSlice(&buf4);
        std.mem.writeInt(u32, &buf4, 1, .little);
        try data.appendSlice(&buf4);
    }

    // Blob
    for (0..256) |i| try data.append(@intCast(i));

    // Align to 16
    const cur_len = data.items.len;
    const padding = (16 - (cur_len % 16)) % 16;
    try data.appendNTimes(0, padding);

    const table_offset = data.items.len;

    // Update Header Offset 56
    std.mem.writeInt(u32, data.items[56..][0..4], @intCast(table_offset), .little);

    // Table (4 entries * 16 bytes)
    // Entry 0: Empty
    // Entry 1: Key(A,B) -> Rank 3. Key=(65<<32)|66. Key+1.
    // Entry 2: Empty
    // Entry 3: Empty

    const key: u64 = (@as(u64, 65) << 32) | 66;
    const key_bytes = std.mem.asBytes(&key);
    const hash = std.hash.Wyhash.hash(0, key_bytes); // Updated to Wyhash
    const idx = hash & 3;

    var table_data = try std.testing.allocator.alloc(u8, 4 * 16);
    defer std.testing.allocator.free(table_data);
    @memset(table_data, 0); // 0 means sentinel

    const offset = idx * 16;
    std.mem.writeInt(u64, table_data[offset..][0..8], key + 1, .little);
    std.mem.writeInt(u32, table_data[offset + 8 ..][0..4], 3, .little); // result rank

    try data.appendSlice(table_data);

    // Load
    var vocab = try VocabLoader.load(std.testing.allocator, data.items);
    defer vocab.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 4), vocab.table_capacity);
    try std.testing.expectEqual(vocab.lookupPair(65, 66), 3);
    try std.testing.expectEqual(vocab.lookupPair(65, 67), null);
}
