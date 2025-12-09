const std = @import("std");
// Using the 'llm_cost' module exposed in build.zig
const lib = @import("llm_cost");
const OpenAITokenizer = lib.tokenizer.OpenAITokenizer;
const EncodingSpec = lib.tokenizer.EncodingSpec;
const registry = lib.tokenizer.registry;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const stdout = std.io.getStdOut().writer();

    // Setup o200k tokenizer
    const spec = registry.Registry.get("o200k_base") orelse return error.UnknownModel;
    const config = .{ .spec = spec, .approximate_ok = false };

    // Note: OpenAITokenizer initialization might be cheap (pointers), but if it changes
    // to build maps, we'd want to initialize ONCE.
    // For now, it's cheap.
    var tok = try OpenAITokenizer.init(alloc, config);
    defer tok.deinit();

    try stdout.print("Running BPE Microbenchmark (o200k_base)...\n", .{});
    try stdout.print("| Scenario | Logical (N) | Bytes | Time (ns) | Tokens |\n", .{});
    try stdout.print("|---|---|---|---|---|\n", .{});

    // 1. Adversarial: 'a' * N
    var n: usize = 8;
    while (n <= 4096) : (n *= 2) {
        const input = try alloc.alloc(u8, n);
        defer alloc.free(input);
        @memset(input, 'a');

        // n bytes = n codepoints
        try measure(alloc, &tok, n, input, "a * N", stdout);
    }

    // 2. Adversarial: Emoji * N (Multi-byte repeated)
    // "😀" is 4 bytes: F0 9F 98 80
    n = 8;
    while (n <= 4096) : (n *= 2) {
        const emoji = "😀";
        const input = try alloc.alloc(u8, n * emoji.len);
        defer alloc.free(input);

        var i: usize = 0;
        while (i < input.len) : (i += emoji.len) {
            @memcpy(input[i .. i + emoji.len], emoji);
        }

        try measure(alloc, &tok, n, input, "emoji * N", stdout);
    }
}

fn measure(alloc: std.mem.Allocator, tok: *OpenAITokenizer, logical_len: usize, input: []const u8, name: []const u8, writer: anytype) !void {
    // Warmup
    {
        const t = try tok.encode(alloc, input);
        alloc.free(t);
    }

    // Measure: Reduce iterations for large inputs to avoid slow benchmarks
    const iterations: usize = if (input.len > 1024) 20 else 100;

    var total_ns: u64 = 0;
    var token_count: usize = 0;

    var timer = try std.time.Timer.start();
    for (0..iterations) |_| {
        const t = try tok.encode(alloc, input);
        token_count = t.len; // Assume constant per iter
        alloc.free(t);
    }
    total_ns = timer.read();

    const avg_ns = total_ns / iterations;

    // Columns: Scenario | Logical (N) | Bytes | Time (ns) | Tokens
    try writer.print("| {s} (N={d}) | {d} | {d} | {d} | {d} |\n", .{ name, logical_len, logical_len, input.len, avg_ns, token_count });
}
