const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

/// Vocabulary Binary Format v3
/// See docs/vocab-format-v3.md for specification
const MAGIC = "BPE3".*; // Updated magic for v3
const VERSION: u32 = 3;
const HEADER_SIZE: usize = 64;

/// Convert a .tiktoken file to binary format
///
/// Usage:
///   zig build run-convert-vocab -- cl100k_base.tiktoken cl100k_base.bin
///
/// The .tiktoken format is simply:
///   <base64-token-bytes> <rank>\n
///
/// We convert this to a compact binary format for @embedFile usage.
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
    try stdout.print("✓ Converted {s} → {s}\n", .{ input_path, output_path });
}

fn convertVocab(alloc: std.mem.Allocator, input_path: []const u8, output_path: []const u8) !void {
    // 1. Read source file
    const source_bytes = try std.fs.cwd().readFileAlloc(alloc, input_path, 50 * 1024 * 1024);
    defer alloc.free(source_bytes);

    // 2. Compute source hash for verification
    var source_hash: [32]u8 = undefined;
    Sha256.hash(source_bytes, &source_hash, .{});

    // 3. Parse .tiktoken format
    var tokens = std.ArrayList(Token).init(alloc);
    defer tokens.deinit();
    defer for (tokens.items) |t| alloc.free(t.bytes);

    var max_rank: u32 = 0;
    var max_token_len: u32 = 0;

    var lines = std.mem.splitScalar(u8, source_bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        // Parse: <base64> <rank>
        var parts = std.mem.splitScalar(u8, line, ' ');
        const b64_part = parts.next() orelse continue;
        const rank_part = parts.next() orelse continue;

        const rank = try std.fmt.parseInt(u32, rank_part, 10);

        // Decode base64
        const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(b64_part);
        const decoded = try alloc.alloc(u8, decoded_len);
        errdefer alloc.free(decoded);

        try std.base64.standard.Decoder.decode(decoded, b64_part);

        try tokens.append(.{
            .rank = rank,
            .bytes = decoded,
        });

        if (rank > max_rank) max_rank = rank;
        if (decoded.len > max_token_len) max_token_len = @intCast(decoded.len);
    }

    const stdout = std.io.getStdOut().writer();
    try stdout.print("  Parsed {d} tokens (max rank: {d}, max len: {d})\n", .{
        tokens.items.len,
        max_rank,
        max_token_len,
    });

    // 4. Sort by rank (ensures token_table[rank] = token)
    std.mem.sort(Token, tokens.items, {}, struct {
        fn lessThan(_: void, a: Token, b: Token) bool {
            return a.rank < b.rank;
        }
    }.lessThan);

    // 5. Build Rank Map for pair generation
    var rank_map = std.StringHashMap(u32).init(alloc);
    defer rank_map.deinit();
    try rank_map.ensureTotalCapacity(@intCast(tokens.items.len));
    for (tokens.items) |t| {
        rank_map.putAssumeCapacity(t.bytes, t.rank);
    }

    // 6. Generate Pairs
    // Iterate all tokens, find valid split points to rebuild valid merges.
    var pairs = std.ArrayList(PairEntry).init(alloc);
    defer pairs.deinit();

    for (tokens.items) |t| {
        if (t.bytes.len < 2) continue;

        // Try all splits
        for (1..t.bytes.len) |split| {
            const part_a = t.bytes[0..split];
            const part_b = t.bytes[split..];

            if (rank_map.get(part_a)) |rank_a| {
                if (rank_map.get(part_b)) |rank_b| {
                    try pairs.append(.{
                        .left = rank_a,
                        .right = rank_b,
                        .target = t.rank,
                    });
                }
            }
        }
    }

    try stdout.print("  Generated {d} merge pairs\n", .{pairs.items.len});

    // 7. Verify contiguous ranks
    const token_count: u32 = max_rank + 1;

    // 8. Build output buffer
    var output = std.ArrayList(u8).init(alloc);
    defer output.deinit();

    // Reserve header
    try output.appendNTimes(0, HEADER_SIZE);

    // Build token table and blob
    var token_table = try alloc.alloc(TokenEntry, token_count);
    defer alloc.free(token_table);
    @memset(token_table, .{ .offset = 0, .length = 0 });

    var blob = std.ArrayList(u8).init(alloc);
    defer blob.deinit();

    for (tokens.items) |t| {
        const offset: u32 = @intCast(blob.items.len);
        const length: u32 = @intCast(t.bytes.len);

        token_table[t.rank] = .{
            .offset = offset,
            .length = length,
        };

        try blob.appendSlice(t.bytes);
    }

    const blob_size: u32 = @intCast(blob.items.len);

    // Write token table
    for (token_table) |entry| {
        try output.writer().writeInt(u32, entry.offset, .little);
        try output.writer().writeInt(u32, entry.length, .little);
    }

    // Write blob
    try output.appendSlice(blob.items);

    // Write pair table
    for (pairs.items) |p| {
        try output.writer().writeInt(u32, p.left, .little);
        try output.writer().writeInt(u32, p.right, .little);
        try output.writer().writeInt(u32, p.target, .little);
    }

    // 9. Write header (at position 0)
    var header_buf: [HEADER_SIZE]u8 = undefined;
    @memset(&header_buf, 0);

    // Magic
    @memcpy(header_buf[0..4], &MAGIC);

    // Version (u32 little-endian at offset 4)
    std.mem.writeInt(u32, header_buf[4..8], VERSION, .little);

    // Token count (u32 at offset 8)
    std.mem.writeInt(u32, header_buf[8..12], token_count, .little);

    // Max token length (u32 at offset 12)
    std.mem.writeInt(u32, header_buf[12..16], max_token_len, .little);

    // Blob size (u32 at offset 16)
    std.mem.writeInt(u32, header_buf[16..20], blob_size, .little);

    // Source hash (32 bytes at offset 20)
    @memcpy(header_buf[20..52], &source_hash);

    // Num Pairs (u32 at offset 52)
    std.mem.writeInt(u32, header_buf[52..56], @intCast(pairs.items.len), .little);

    // Reserved (8 bytes at offset 56-63) - already zeroed

    // Overwrite header in output
    @memcpy(output.items[0..HEADER_SIZE], &header_buf);

    // 10. Write to file
    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();
    try file.writeAll(output.items);

    try stdout.print("  Output: {d} bytes ({d:.2} MB)\n", .{
        output.items.len,
        @as(f64, @floatFromInt(output.items.len)) / (1024.0 * 1024.0),
    });

    // 11. Print verification info
    try stdout.print("  Source SHA256: ", .{});
    for (source_hash) |b| {
        try stdout.print("{x:0>2}", .{b});
    }
    try stdout.print("\n", .{});
}

const Token = struct {
    rank: u32,
    bytes: []u8,
};

const TokenEntry = struct {
    offset: u32,
    length: u32,
};

const PairEntry = struct {
    left: u32,
    right: u32,
    target: u32,
};

// =============================================================================
// Tests
// =============================================================================

test "base64 decode" {
    const alloc = std.testing.allocator;

    // "IQ==" decodes to "!"
    const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice("IQ==");
    const decoded = try alloc.alloc(u8, decoded_len);
    defer alloc.free(decoded);

    try std.base64.standard.Decoder.decode(decoded, "IQ==");
    try std.testing.expectEqualStrings("!", decoded);
}

test "header size" {
    try std.testing.expectEqual(@as(usize, 64), HEADER_SIZE);
}
