const std = @import("std");
const openai = @import("llm_cost").tokenizer.openai;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const stdout = std.io.getStdOut().writer();

    try stdout.print("Initializing Tokenizer (o200k_base)...\n", .{});

    // Init tokenizer
    var tok = try openai.OpenAITokenizer.init(.{
        .spec = openai.resolveEncoding("gpt-4o").?,
        .approximate_ok = false
    });

    if (tok.engine == null) {
        try stdout.print("Error: o200k_base engine not loaded via embedFile!\n", .{});
        return;
    }

    try stdout.print("Generating test data (10MB)...\n", .{});
    const total_size = 10 * 1024 * 1024;
    const sample_text = "The quick brown fox jumps over the lazy dog. 1234567890. \n";

    var buffer = try alloc.alloc(u8, total_size);
    defer alloc.free(buffer);

    var pos: usize = 0;
    while (pos < total_size) {
        const remaining = total_size - pos;
        const copy_len = @min(remaining, sample_text.len);
        @memcpy(buffer[pos..][0..copy_len], sample_text[0..copy_len]);
        pos += copy_len;
    }

    try stdout.print("Benchmarking...\n", .{});

    const start = std.time.nanoTimestamp();
    const res = try tok.count(alloc, buffer);
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(f64, @floatFromInt(end - start));
    const duration_s = duration_ns / 1_000_000_000.0;

    const tokens_per_sec = @as(f64, @floatFromInt(res.tokens)) / duration_s;
    const mb_per_sec = (@as(f64, @floatFromInt(total_size)) / 1024.0 / 1024.0) / duration_s;

    try stdout.print("\nResults:\n", .{});
    try stdout.print("  Tokens: {d}\n", .{res.tokens});
    try stdout.print("  Time:   {d:.4} s\n", .{duration_s});
    try stdout.print("  Speed:  {d:.2} tokens/sec\n", .{tokens_per_sec});
    try stdout.print("  Speed:  {d:.2} MB/sec\n", .{mb_per_sec});
}
