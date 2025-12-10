const std = @import("std");
// Import the tokenizer module via relative path
const Core = @import("tokenizer/mod.zig");
const Tokenizer = Core.OpenAITokenizer; // BPE v2.1 compatible tokenizer interface
const Registry = Core.registry.Registry;

const WARMUP_ITERS = 3;
const MEASURE_ITERS = 10;

pub fn main() !void {
    // 1. Leak Detection Allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) @panic("Memory leak detected in benchmark!");
    }
    const allocator = gpa.allocator();
    const stdout = std.io.getStdOut().writer();

    try stdout.print("\n🚀 LLM-Cost Benchmark Suite (v0.6.0)\n", .{});
    try stdout.print("========================================\n", .{});
    try stdout.print("Build: ReleaseFast | Engine: BPE v2.1 (Index+Heap)\n\n", .{});

    // 2. Init Engine: Use gpt-4o (o200k_base)
    // We need to fetch the spec first
    const spec = Registry.getEncodingForModel("gpt-4o") orelse return error.UnknownModel;

    // Initialize tokenizer with defaults (v2.1)
    // Note: OpenAITokenizer.init signature: init(alloc, Config)
    var tokenizer = try Tokenizer.init(allocator, .{
        .spec = spec,
        .approximate_ok = false,
        .bpe_version = .v2_1,
    });
    defer tokenizer.deinit(allocator);

    // Header
    try stdout.print("{s:<25} {s:<10} {s:<12} {s:<12} {s:<12} {s:<10}\n",
        .{ "Scenario", "Size", "Time(ms)", "MB/s", "Tok/s", "Ratio" });
    try stdout.print("{s}\n", .{ "-" ** 90 });

    // 3. Micro Benchmarks (Synthetic)

    // Baseline: Random ASCII
    {
        const input = try generateRandom(allocator, 100 * 1024);
        defer allocator.free(input);
        _ = try runScenario(allocator, stdout, tokenizer, "Random ASCII (100KB)", input, null);
    }

    // Scaling Check: 'a' * N
    var time_10k: u64 = 0;
    {
        const input = try generateRepeatedA(allocator, 10 * 1024);
        defer allocator.free(input);
        time_10k = try runScenario(allocator, stdout, tokenizer, "Evil 'a' (10KB)", input, null);
    }

    {
        const input = try generateRepeatedA(allocator, 1 * 1024 * 1024);
        defer allocator.free(input);
        _ = try runScenario(allocator, stdout, tokenizer, "Evil 'a' (1MB)", input, time_10k);
    }

    // Multibyte Overhead
    {
        const input = try generateEmoji(allocator, 50 * 1024);
        defer allocator.free(input);
        _ = try runScenario(allocator, stdout, tokenizer, "Emoji (50KB)", input, null);
    }

    // 4. Macro Benchmark (Real World)
    // We load the file into memory to exclude I/O from measurement (we test CPU/BPE)
    try stdout.print("\n[Macro] evil_corpus_v2.jsonl\n", .{});
    const corpus_path = "testdata/evil_corpus_v2.jsonl";
    if (loadFile(allocator, corpus_path)) |corpus_data| {
        defer allocator.free(corpus_data);
        _ = try runScenario(allocator, stdout, tokenizer, "Full Corpus", corpus_data, null);
    } else |_| {
        try stdout.print("Skipped: {s} not found.\n", .{corpus_path});
        try stdout.print("Run 'python scripts/generate_golden.py' (if it generates corpus) to create it.\n", .{});
    }
}

// --- Runner Logic ---

fn runScenario(
    alloc: std.mem.Allocator,
    writer: anytype,
    tok: Tokenizer,
    name: []const u8,
    input: []const u8,
    baseline_ns: ?u64
) !u64 { // Returns avg_ns for ratio calc
    // Warmup
    for (0..WARMUP_ITERS) |_| {
        // count function might need allocator?
        // OpenAITokenizer.count signature: count(self, alloc, text)
        // bench_bpe_v2 used tok.encode(alloc, ...). count uses alloc internally for pre-tokenization.
        // We must pass allocator.
        const res = try tok.count(alloc, input);
        std.mem.doNotOptimizeAway(res);
    }

    // Measure
    var total_ns: u64 = 0;
    var total_tokens: u64 = 0;
    var timer = try std.time.Timer.start();

    for (0..MEASURE_ITERS) |_| {
        timer.reset();
        const res = try tok.count(alloc, input);
        total_ns += timer.read();
        total_tokens += res.tokens;
    }

    // Stats
    const avg_ns = total_ns / MEASURE_ITERS;
    const avg_ms = @as(f64, @floatFromInt(avg_ns)) / 1_000_000.0;
    const bytes_per_sec = @as(f64, @floatFromInt(input.len)) / (@as(f64, @floatFromInt(avg_ns)) / 1_000_000_000.0);
    const mb_per_sec = bytes_per_sec / (1024.0 * 1024.0);
    const tokens_per_sec = @as(f64, @floatFromInt(total_tokens)) / MEASURE_ITERS / (@as(f64, @floatFromInt(avg_ns)) / 1_000_000_000.0);

    // Scaling Ratio Display
    var ratio_buf: [16]u8 = undefined;
    var ratio_slice: []const u8 = "-";
    if (baseline_ns) |base| {
        const r = @as(f64, @floatFromInt(avg_ns)) / @as(f64, @floatFromInt(base));
        ratio_slice = try std.fmt.bufPrint(&ratio_buf, "{d:.1}x", .{r});
    }

    try writer.print("{s:<25} {d:<10} {d:<12.3} {d:<12.2} {d:<12.0} {s:<10}\n",
        .{ name, input.len, avg_ms, mb_per_sec, tokens_per_sec, ratio_slice });

    return avg_ns;
}

// --- Generators ---

fn generateRandom(alloc: std.mem.Allocator, size: usize) ![]u8 {
    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();
    const charset = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ";
    const buf = try alloc.alloc(u8, size);
    for (buf) |*b| b.* = charset[random.uintLessThan(usize, charset.len)];
    return buf;
}

fn generateRepeatedA(alloc: std.mem.Allocator, size: usize) ![]u8 {
    const buf = try alloc.alloc(u8, size);
    @memset(buf, 'a');
    return buf;
}

fn generateEmoji(alloc: std.mem.Allocator, size: usize) ![]u8 {
    const emoji = "\xF0\x9F\x99\x96"; // 🤖 (4 bytes)
    const buf = try alloc.alloc(u8, size);
    var i: usize = 0;
    while (i + 4 <= size) : (i += 4) @memcpy(buf[i..i+4], emoji);
    if (i < size) @memset(buf[i..], ' ');
    return buf;
}

fn loadFile(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    const f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    return f.readToEndAlloc(alloc, 100 * 1024 * 1024); // Max 100MB corpus
}
