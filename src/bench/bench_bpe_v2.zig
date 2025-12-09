const std = @import("std");
const lib = @import("llm_cost");
const bpe_v2 = lib.tokenizer.bpe_v2;
const registry = lib.tokenizer.registry;
const pre_tokenizer = lib.tokenizer.pre_tokenizer;
const o200k_scanner = lib.tokenizer.o200k_scanner;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Setup BPE v2 with o200k data
    const spec = registry.Registry.get("o200k_base") orelse return error.UnknownModel;

    // Note: BpeEngineV2 expects allocator for init (to build map)
    var engine = try bpe_v2.BpeEngineV2.init(alloc, spec.vocab_data);
    defer engine.deinit();

    std.debug.print("Running BPE v2 Microbenchmark (o200k_base)...\n", .{});
    std.debug.print("| Scenario | Logical (N) | Bytes | Mode | v2 (ns) | v2.1 (ns) | Speedup |\n", .{});
    std.debug.print("|---|---|---|---|---|---|---|\n", .{});

    // We need the pre-tokenizer scanner for correct segmentation input
    const scanner_interface = o200k_scanner.O200kScanner.interface();

    // 1. Adversarial: 'a' * N
    var n: usize = 8;
    while (n <= 65536) : (n *= 4) {
        const input = try alloc.alloc(u8, n);
        defer alloc.free(input);
        @memset(input, 'a');

        try measureBpeOnly(alloc, &engine, scanner_interface, n, input, "a * N (Pure)");
        try measureE2E(alloc, &engine, scanner_interface, n, input, "a * N (E2E)");
    }

    // 2. Adversarial: Emoji * N
    n = 8;
    while (n <= 65536) : (n *= 4) {
        const emoji = "😀";
        const input = try alloc.alloc(u8, n * emoji.len);
        defer alloc.free(input);

        var i: usize = 0;
        while (i < input.len) : (i += emoji.len) {
            @memcpy(input[i .. i + emoji.len], emoji);
        }

        try measureBpeOnly(alloc, &engine, scanner_interface, n, input, "emoji * N (Pure)");
        try measureE2E(alloc, &engine, scanner_interface, n, input, "emoji * N (E2E)");
    }
}

fn measureBpeOnly(alloc: std.mem.Allocator, engine: *bpe_v2.BpeEngineV2, scanner: pre_tokenizer.PreTokenizer, logical_len: usize, input: []const u8, name: []const u8) !void {
    // Pre-tokenize once
    const pt = try scanner.tokenize(alloc, input);
    defer alloc.free(pt);

    const iterations: usize = if (input.len > 10000) 50 else 200;

    var total_ns_v2: u64 = 0;
    var total_ns_v21: u64 = 0;
    var hash_v2: u64 = 0;
    var hash_v21: u64 = 0;

    // V2
    {
        // Warmup
        const t = try engine.encode(alloc, pt, false);
        alloc.free(t);

        var timer = try std.time.Timer.start();
        for (0..iterations) |_| {
            const t2 = try engine.encode(alloc, pt, false);
            if (hash_v2 == 0) hash_v2 = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(t2));
            alloc.free(t2);
        }
        total_ns_v2 = timer.read();
    }
    const avg_v2 = total_ns_v2 / iterations;

    // V2.1
    {
        // Warmup
        const t = try engine.encode(alloc, pt, true);
        alloc.free(t);

        var timer = try std.time.Timer.start();
        for (0..iterations) |_| {
            const t2 = try engine.encode(alloc, pt, true);
            if (hash_v21 == 0) hash_v21 = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(t2));
            alloc.free(t2);
        }
        total_ns_v21 = timer.read();
    }
    const avg_v21 = total_ns_v21 / iterations;

    if (hash_v2 != hash_v21) {
        std.debug.print("MISMATCH in {s}: v2 hash={x}, v2.1 hash={x}\n", .{name, hash_v2, hash_v21});
    }

    std.debug.print("| {s} (N={d}) | {d} | Pure | {d} | {d} | {d:.2}x |\n", .{ name, logical_len, input.len, avg_v2, avg_v21, @as(f64, @floatFromInt(avg_v2)) / @as(f64, @floatFromInt(avg_v21)) });
}

fn measureE2E(alloc: std.mem.Allocator, engine: *bpe_v2.BpeEngineV2, scanner: pre_tokenizer.PreTokenizer, logical_len: usize, input: []const u8, name: []const u8) !void {
    const iterations: usize = if (input.len > 10000) 10 else 50;

    // Measure v2
    var total_ns_v2: u64 = 0;
    {
        // Warmup
        const pt = try scanner.tokenize(alloc, input);
        defer alloc.free(pt);
        const t = try engine.encode(alloc, pt, false);
        alloc.free(t);

        var timer = try std.time.Timer.start();
        for (0..iterations) |_| {
            const pt2 = try scanner.tokenize(alloc, input);
            defer alloc.free(pt2);
            const t2 = try engine.encode(alloc, pt2, false);
            alloc.free(t2);
        }
        total_ns_v2 = timer.read();
    }
    const avg_v2 = total_ns_v2 / iterations;

    // Measure v2.1
    var total_ns_v21: u64 = 0;
    {
        // Warmup
        const pt = try scanner.tokenize(alloc, input);
        defer alloc.free(pt);
        const t = try engine.encode(alloc, pt, true);
        alloc.free(t);

        var timer = try std.time.Timer.start();
        for (0..iterations) |_| {
            const pt2 = try scanner.tokenize(alloc, input);
            defer alloc.free(pt2);
            const t2 = try engine.encode(alloc, pt2, true);
            alloc.free(t2);
        }
        total_ns_v21 = timer.read();
    }
    const avg_v21 = total_ns_v21 / iterations;

    std.debug.print("| {s} (N={d}) | {d} | E2E | {d} | {d} | {d:.2}x |\n", .{ name, logical_len, input.len, avg_v2, avg_v21, @as(f64, @floatFromInt(avg_v2)) / @as(f64, @floatFromInt(avg_v21)) });
}
