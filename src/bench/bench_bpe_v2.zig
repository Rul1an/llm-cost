const std = @import("std");
const lib = @import("llm_cost");
const bpe_v2 = lib.tokenizer.bpe_v2;
const registry = lib.tokenizer.registry;
const pre_tokenizer = lib.tokenizer.pre_tokenizer;
const o200k_scanner = @import("../tokenizer/o200k_scanner.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const stdout = std.io.getStdOut().writer();

    // Setup BPE v2 with o200k data
    const spec = registry.Registry.get("o200k_base") orelse return error.UnknownModel;

    // Note: BpeEngineV2 expects allocator for init (to build map)
    var engine = try bpe_v2.BpeEngineV2.init(alloc, spec.vocab_data);
    defer engine.deinit();

    try stdout.print("Running BPE v2 Microbenchmark (o200k_base)...\n", .{});
    try stdout.print("| Scenario | Logical (N) | Bytes | Time (ns) | Tokens |\n", .{});
    try stdout.print("|---|---|---|---|---|\n", .{});

    // We need the pre-tokenizer scanner for correct segmentation input
    const scanner_interface = o200k_scanner.O200kScanner.interface();

    // 1. Adversarial: 'a' * N
    var n: usize = 8;
    while (n <= 8192) : (n *= 2) {
        const input = try alloc.alloc(u8, n);
        defer alloc.free(input);
        @memset(input, 'a');

        try measure(alloc, &engine, scanner_interface, n, input, "a * N", stdout);
    }

    // 2. Adversarial: Emoji * N
    n = 8;
    while (n <= 8192) : (n *= 2) {
        const emoji = "😀";
        const input = try alloc.alloc(u8, n * emoji.len);
        defer alloc.free(input);

        var i: usize = 0;
        while (i < input.len) : (i += emoji.len) {
            @memcpy(input[i .. i + emoji.len], emoji);
        }

        try measure(alloc, &engine, scanner_interface, n, input, "emoji * N", stdout);
    }
}

fn measure(alloc: std.mem.Allocator, engine: *bpe_v2.BpeEngineV2, scanner: pre_tokenizer.PreTokenizer, logical_len: usize, input: []const u8, name: []const u8, writer: anytype) !void {
    // Warmup & Pre-tokenize
    // Pre-tokenization is strictly separate from BPE merge performance, but we must include it
    // to match real-world "text -> ids" latency, or exclude it to measrue PURE merge?
    // "bpe_v2" architecture usually assumes pre-tokenized input.
    // The old benchmark measured `tok.encode` which included pre-tokenization.
    // To be fair comparison, we should include pre-tokenization time OR measure both.
    // Let's measure End-to-End time (Pre-tok + Merge) since that's what the user cares about.

    // Warmup
    {
        const pt = try scanner.tokenize(alloc, input);
        defer alloc.free(pt);
        const t = try engine.encode(alloc, pt);
        alloc.free(t);
    }

    const iterations: usize = if (input.len > 4096) 20 else 50;

    var total_ns: u64 = 0;
    var token_count: usize = 0;

    var timer = try std.time.Timer.start();
    for (0..iterations) |_| {
        // Full pipeline
        const pt = try scanner.tokenize(alloc, input);
        defer alloc.free(pt);

        const t = try engine.encode(alloc, pt);
        token_count = t.len;
        alloc.free(t);
    }
    total_ns = timer.read();

    const avg_ns = total_ns / iterations;

    try writer.print("| {s} (N={d}) | {d} | {d} | {d} | {d} |\n", .{ name, logical_len, logical_len, input.len, avg_ns, token_count });
}
