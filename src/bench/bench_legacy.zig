const std = @import("std");
const lib = @import("llm_cost");
// Access internal modules via relative path if not exposed, or exposed via lib
// lib.tokenizer.bpe is NOT exposed as 'bpe' in mod.zig anymore?
// mod.zig has `pub const bpe_v2 ...`. It does NOT export `bpe.zig` anymore.
// So I must import by path.
const bpe = lib.tokenizer.bpe_legacy;
const registry = lib.tokenizer.registry;
const pre_tokenizer = lib.tokenizer.pre_tokenizer;
const o200k_scanner = @import("../tokenizer/o200k_scanner.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const stdout = std.io.getStdOut().writer();

    const spec = registry.Registry.get("o200k_base") orelse return error.UnknownModel;

    // Legacy BPE init
    const engine = try bpe.BpeEngine.init(spec.vocab_data);
    // BpeEngine is struct by value.

    try stdout.print("Running Legacy BPE Microbenchmark (o200k_base)...\n", .{});
    try stdout.print("| Scenario | Logical (N) | Bytes | Time (ns) | Tokens |\n", .{});
    try stdout.print("|---|---|---|---|---|\n", .{});

    const scanner_interface = o200k_scanner.O200kScanner.interface();

    // 1. Adversarial: 'a' * N
    var n: usize = 8;
    while (n <= 8192) : (n *= 2) {
        const input = try alloc.alloc(u8, n);
        defer alloc.free(input);
        @memset(input, 'a');

        try measure(alloc, engine, scanner_interface, n, input, "a * N", stdout);
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
        try measure(alloc, engine, scanner_interface, n, input, "emoji * N", stdout);
    }
}

fn measure(alloc: std.mem.Allocator, engine: bpe.BpeEngine, scanner: pre_tokenizer.PreTokenizer, logical_len: usize, input: []const u8, name: []const u8, writer: anytype) !void {
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
