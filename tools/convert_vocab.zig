const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

/// Vocabulary Binary Format v4 (Zero-Copy Hash Table)
/// See docs/vocab-format-v4.md for specification
const MAGIC = "BPE4".*;
const VERSION: u32 = 4;
const HEADER_SIZE: usize = 64;

/// Entry in the on-disk hash table (16 bytes)
///  key_plus1: u64 (key + 1, 0 = empty)
///  value: u32 (rank)
///  pad: u32 (0)
const HashEntry = struct {
    key_plus1: u64,
    value: u32,
    pad: u32 = 0,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len != 3) {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("Usage: {s} <input.tiktoken> <output.bin>\n", .{args[0]});
        std.process.exit(1);
    }

    const input_path = args[1];
    const output_path = args[2];

    try convertVocab(alloc, input_path, output_path);

    const stdout = std.io.getStdOut().writer();
    try stdout.print("✓ Converted {s} → {s} (v4)\n", .{ input_path, output_path });
}

fn convertVocab(alloc: std.mem.Allocator, input_path: []const u8, output_path: []const u8) !void {
    // 1. Read source file
    const source_bytes = try std.fs.cwd().readFileAlloc(alloc, input_path, 100 * 1024 * 1024);
    defer alloc.free(source_bytes);

    // 2. Compute source hash
    var source_hash: [32]u8 = undefined;
    Sha256.hash(source_bytes, &source_hash, .{});

    // 3. Parse .tiktoken
    var tokens = std.ArrayList(Token).init(alloc);
    defer tokens.deinit();
    defer for (tokens.items) |t| alloc.free(t.bytes);

    var max_rank: u32 = 0;
    var max_token_len: u32 = 0;

    var lines = std.mem.splitScalar(u8, source_bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parts = std.mem.splitScalar(u8, line, ' ');
        const b64_part = parts.next() orelse continue;
        const rank_part = parts.next() orelse continue;
        const rank = try std.fmt.parseInt(u32, rank_part, 10);

        const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(b64_part);
        const decoded = try alloc.alloc(u8, decoded_len);
        errdefer alloc.free(decoded);

        try std.base64.standard.Decoder.decode(decoded, b64_part);

        try tokens.append(.{ .rank = rank, .bytes = decoded });

        if (rank > max_rank) max_rank = rank;
        if (decoded.len > max_token_len) max_token_len = @intCast(decoded.len);
    }

    const stdout = std.io.getStdOut().writer();
    try stdout.print("  Parsed {d} tokens\n", .{tokens.items.len});

    // 4. Sort by rank
    std.mem.sort(Token, tokens.items, {}, struct {
        fn lessThan(_: void, a: Token, b: Token) bool {
            return a.rank < b.rank;
        }
    }.lessThan);

    // 5. Build Rank Map (for pair gen)
    var rank_map = std.StringHashMap(u32).init(alloc);
    defer rank_map.deinit();
    try rank_map.ensureTotalCapacity(@intCast(tokens.items.len));
    for (tokens.items) |t| {
        rank_map.putAssumeCapacity(t.bytes, t.rank);
    }

    // 6. Generate Pairs (Linear Scan)
    var pairs = std.ArrayList(struct { l: u32, r: u32, val: u32 }).init(alloc);
    defer pairs.deinit();

    for (tokens.items) |t| {
        if (t.bytes.len < 2) continue;
        // Optimization: For bytes.len=N, we check pairs for split k.
        // Left=0..k, Right=k..end.
        for (1..t.bytes.len) |split| {
            const part_a = t.bytes[0..split];
            const part_b = t.bytes[split..];
            if (rank_map.get(part_a)) |rank_a| {
                if (rank_map.get(part_b)) |rank_b| {
                    try pairs.append(.{ .l = rank_a, .r = rank_b, .val = t.rank });
                }
            }
        }
    }

    try stdout.print("  Generated {d} pairs\n", .{pairs.items.len});

    // 7. Build Hash Table (In-Memory)
    // Load factor ~0.7
    const target_capacity = @as(u64, pairs.items.len) * 10 / 7;
    const capacity = std.math.ceilPowerOfTwo(u64, target_capacity) catch return error.OutOfMemory;
    if (capacity > std.math.maxInt(u32)) return error.TableTooLarge;
    const cap_u32: u32 = @intCast(capacity);
    const mask = capacity - 1;

    try stdout.print("  Building Hash Table: {d} buckets\n", .{capacity});

    var hash_table = try alloc.alloc(HashEntry, capacity);
    defer alloc.free(hash_table);
    // Init: key_plus1 = 0
    @memset(hash_table, .{ .key_plus1 = 0, .value = 0, .pad = 0 });

    var max_probes: usize = 0;

    for (pairs.items) |p| {
        const key = (@as(u64, p.l) << 32) | p.r;
        const key_plus1 = key + 1;

        // High-quality hash to minimize collisions
        const key_bytes = std.mem.asBytes(&key);
        const hash = std.hash.Wyhash.hash(0, key_bytes);
        var idx = hash & mask;
        var probes: usize = 0;

        while (hash_table[idx].key_plus1 != 0) {
            // Check duplicate?
            if (hash_table[idx].key_plus1 == key_plus1) {
                break;
            }
            idx = (idx + 1) & mask;
            probes += 1;
        }

        if (hash_table[idx].key_plus1 == 0) {
            hash_table[idx] = .{ .key_plus1 = key_plus1, .value = p.val, .pad = 0 };
        }
        if (probes > max_probes) max_probes = probes;
    }

    try stdout.print("  Max probes: {d}\n", .{max_probes});
    if (max_probes > 128) {
        try stdout.print("  ERROR: Hash table clustering too high! (>128 probes)\n", .{});
        return error.TableTooDense;
    }

    // 8. Build Output Binary
    var output = std.ArrayList(u8).init(alloc);
    defer output.deinit();

    // Reserve Header
    try output.appendNTimes(0, HEADER_SIZE);

    // Write Token Table
    const token_count = max_rank + 1;
    // We defer actual table data writing, first append placeholders or data?
    // Let's use 2-buffer approach again for simplicity of offsets.
    var output_payload = std.ArrayList(u8).init(alloc);
    defer output_payload.deinit();

    // Token Table (8 * N)
    try output_payload.appendNTimes(0, token_count * 8);

    var blob = std.ArrayList(u8).init(alloc);
    defer blob.deinit();

    for (tokens.items) |t| {
        const offset: u32 = @intCast(blob.items.len);
        const length: u32 = @intCast(t.bytes.len);

        const entry_pos = @as(usize, t.rank) * 8;
        std.mem.writeInt(u32, output_payload.items[entry_pos..][0..4], offset, .little);
        std.mem.writeInt(u32, output_payload.items[entry_pos + 4 ..][0..4], length, .little);

        try blob.appendSlice(t.bytes);
    }
    const blob_size: u32 = @intCast(blob.items.len);

    try output_payload.appendSlice(blob.items);

    // ALIGNMENT PADDING to 16 bytes
    // Current total = HEADER_SIZE + output_payload.len
    const current_len = HEADER_SIZE + output_payload.items.len;
    const padding_needed = (16 - (current_len % 16)) % 16;
    try output_payload.appendNTimes(0, padding_needed);

    const table_offset = HEADER_SIZE + output_payload.items.len; // Should be aligned 16

    // Write Hash Table (16 bytes per entry)
    for (hash_table) |entry| {
        try output_payload.writer().writeInt(u64, entry.key_plus1, .little);
        try output_payload.writer().writeInt(u32, entry.value, .little);
        try output_payload.writer().writeInt(u32, entry.pad, .little);
    }

    // Combine
    try output.appendSlice(output_payload.items);

    // 9. Finalize Header
    const header = output.items[0..HEADER_SIZE];
    @memcpy(header[0..4], &MAGIC);
    std.mem.writeInt(u32, header[4..8], VERSION, .little);
    std.mem.writeInt(u32, header[8..12], token_count, .little);
    std.mem.writeInt(u32, header[12..16], max_token_len, .little);
    std.mem.writeInt(u32, header[16..20], blob_size, .little);
    @memcpy(header[20..52], &source_hash);

    // Offset 52: Capacity
    std.mem.writeInt(u32, header[52..56], cap_u32, .little);
    // Offset 56: Table Offset
    std.mem.writeInt(u32, header[56..60], @intCast(table_offset), .little);
    // Offset 60: Reserved (0)

    // Write File
    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();
    try file.writeAll(output.items);

    try stdout.print("  Output: {d:.2} MB (Table start: {d})\n", .{
        @as(f64, @floatFromInt(output.items.len)) / (1024.0 * 1024.0),
        table_offset,
    });
}

const Token = struct { rank: u32, bytes: []u8 };

test "header" {
    // Basic test
    try std.testing.expectEqual(@as(usize, 64), HEADER_SIZE);
}
