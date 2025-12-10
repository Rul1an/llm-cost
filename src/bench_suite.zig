// src/bench_suite.zig - Performance Benchmark Suite
//
// Comprehensive benchmarks for llm-cost tokenization performance.
// Run with: zig build bench -Doptimize=ReleaseFast
//
// Output formats:
//   --format=text   Console output (default)
//   --format=json   Machine-readable JSON
//   --format=md     Markdown for CI reports

const std = @import("std");
const bench = @import("bench.zig");
const Tokenizer = @import("tokenizer/mod.zig").OpenAITokenizer;
const Registry = @import("tokenizer/registry.zig").Registry;
const OpenAIConfig = @import("tokenizer/openai.zig").Config;

const VERSION = "0.7.0";

const ENCODINGS = [_][]const u8{ "cl100k_base", "o200k_base" };

/// Output format selection
const OutputFormat = enum {
    text,
    json,
    markdown,
    // md is alias for markdown
};

/// CLI arguments
const Args = struct {
    format: OutputFormat = .text,
    encoding: ?[]const u8 = null, // null = all encodings
    quick: bool = false, // Reduced iterations for CI
    include_stress: bool = true,
    output_file: ?[]const u8 = null,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse arguments
    const args = try parseArgs(allocator);

    // Setup output
    const stdout = std.io.getStdOut().writer();
    var output_file: ?std.fs.File = null;
    defer if (output_file) |f| f.close();

    const writer = if (args.output_file) |path| blk: {
        output_file = try std.fs.cwd().createFile(path, .{});
        break :blk output_file.?.writer();
    } else stdout;

    // Load test data
    const test_data = try loadTestData(allocator);
    defer {
        allocator.free(test_data.small);
        allocator.free(test_data.medium);
        allocator.free(test_data.large);
        allocator.free(test_data.pathological);
    }

    // Run benchmarks based on format
    switch (args.format) {
        .text => try runTextBenchmarks(allocator, writer, test_data, args),
        .json => try runJsonBenchmarks(allocator, writer, test_data, args),
        .markdown => try runMarkdownBenchmarks(allocator, writer, test_data, args),
    }
}

const TestData = struct {
    small: []const u8, // ~100 bytes
    medium: []const u8, // ~10 KB
    large: []const u8, // ~1 MB
    pathological: []const u8, // worst-case input
};

fn loadTestData(allocator: std.mem.Allocator) !TestData {
    // Try to load from data/bench/, fallback to generated data
    const small = loadFile(allocator, "data/bench/small.txt") catch
        try generateText(allocator, 100);

    const medium = loadFile(allocator, "data/bench/medium.txt") catch
        try generateText(allocator, 10 * 1024);

    const large = loadFile(allocator, "data/bench/large.txt") catch
        try generateText(allocator, 1024 * 1024);

    // Pathological: repeated single character (worst case for BPE)
    const pathological = try allocator.alloc(u8, 100_000);
    @memset(pathological, 'a');

    return TestData{
        .small = small,
        .medium = medium,
        .large = large,
        .pathological = pathological,
    };
}

fn loadFile(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const file = std.fs.cwd().openFile(path, .{}) catch return error.FileNotFound;
    defer file.close();

    const stat = try file.stat();
    const size = @min(stat.size, 10 * 1024 * 1024); // Max 10MB

    return try file.readToEndAlloc(allocator, size);
}

fn generateText(allocator: std.mem.Allocator, size: usize) ![]u8 {
    const words = [_][]const u8{
        "the",          "quick",       "brown",     "fox",   "jumps",
        "over",         "lazy",        "dog",       "hello", "world",
        "this",         "is",          "a",         "test",  "of",
        "tokenization", "performance", "benchmark", "suite",
    };

    var result = try allocator.alloc(u8, size);
    var pos: usize = 0;

    while (pos < size) {
        const word = words[pos % words.len];
        const remaining = size - pos;

        if (remaining <= word.len) {
            @memcpy(result[pos..size], word[0..remaining]);
            break;
        }

        @memcpy(result[pos .. pos + word.len], word);
        pos += word.len;

        if (pos < size) {
            result[pos] = ' ';
            pos += 1;
        }
    }

    return result;
}

fn parseArgs(allocator: std.mem.Allocator) !Args {
    _ = allocator;
    var args = Args{};

    var arg_iter = std.process.args();
    _ = arg_iter.skip(); // Skip program name

    while (arg_iter.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--format=")) {
            const format_str = arg["--format=".len..];
            if (std.mem.eql(u8, format_str, "json")) {
                args.format = .json;
            } else if (std.mem.eql(u8, format_str, "md") or std.mem.eql(u8, format_str, "markdown")) {
                args.format = .markdown;
            } else {
                args.format = .text;
            }
        } else if (std.mem.startsWith(u8, arg, "--encoding=")) {
            args.encoding = arg["--encoding=".len..];
        } else if (std.mem.eql(u8, arg, "--quick")) {
            args.quick = true;
        } else if (std.mem.eql(u8, arg, "--no-stress")) {
            args.include_stress = false;
        } else if (std.mem.startsWith(u8, arg, "--output=")) {
            args.output_file = arg["--output=".len..];
        }
    }

    return args;
}

// ============================================================================
// Text Format Output
// ============================================================================

fn runTextBenchmarks(
    allocator: std.mem.Allocator,
    writer: anytype,
    data: TestData,
    args: Args,
) !void {
    // Header
    try writer.print(
        \\╔══════════════════════════════════════════════════════════════╗
        \\║             llm-cost Performance Benchmark Suite             ║
        \\║                        v{s}                               ║
        \\╚══════════════════════════════════════════════════════════════╝
        \\
        \\System:  {s}
        \\Date:    {s}
        \\Mode:    {s}
        \\
        \\
    , .{
        VERSION,
        bench.getSystemInfo(),
        getTimestamp(),
        if (args.quick) "Quick (reduced iterations)" else "Full",
    });

    // Determine iteration counts
    const iter_small: u64 = if (args.quick) 1_000 else 100_000;
    const iter_medium: u64 = if (args.quick) 100 else 10_000;
    const iter_large: u64 = if (args.quick) 10 else 100;
    const warmup_ratio: u64 = 10;

    // Run for each encoding
    const encodings = if (args.encoding) |enc|
        &[_][]const u8{enc}
    else
        &ENCODINGS;

    var best_throughput: f64 = 0;
    var best_bench_name: []const u8 = "";

    for (encodings) |encoding| {
        try writer.print("═══ Encoding: {s} ═══\n\n", .{encoding});
        try writer.print("── Micro-Benchmarks ──\n\n", .{});

        // Small input benchmark
        const small_result = try runEncodeBenchmark(
            allocator,
            "encode_small",
            encoding,
            data.small,
            iter_small,
            iter_small / warmup_ratio,
        );
        try small_result.format(writer);
        try writer.writeAll("\n");

        if (small_result.throughputMBps() > best_throughput) {
            best_throughput = small_result.throughputMBps();
            best_bench_name = "encode_small";
        }

        // Medium input benchmark
        const medium_result = try runEncodeBenchmark(
            allocator,
            "encode_medium",
            encoding,
            data.medium,
            iter_medium,
            iter_medium / warmup_ratio,
        );
        try medium_result.format(writer);
        try writer.writeAll("\n");

        if (medium_result.throughputMBps() > best_throughput) {
            best_throughput = medium_result.throughputMBps();
            best_bench_name = "encode_medium";
        }

        // Large input benchmark
        const large_result = try runEncodeBenchmark(
            allocator,
            "encode_large",
            encoding,
            data.large,
            iter_large,
            iter_large / warmup_ratio,
        );
        try large_result.format(writer);
        try writer.writeAll("\n");

        if (large_result.throughputMBps() > best_throughput) {
            best_throughput = large_result.throughputMBps();
            best_bench_name = "encode_large";
        }

        // Summary for this encoding
        try writer.print(
            \\── Summary ({s}) ──
            \\
            \\  Best throughput:  {d:.2} MB/s ({s})
            \\  Small p99:        {d:.3} ms
            \\  Medium p99:       {d:.3} ms
            \\  Large p99:        {d:.3} ms
            \\
            \\
        , .{
            encoding,
            best_throughput,
            best_bench_name,
            @as(f64, @floatFromInt(small_result.p99_ns)) / 1_000_000.0,
            @as(f64, @floatFromInt(medium_result.p99_ns)) / 1_000_000.0,
            @as(f64, @floatFromInt(large_result.p99_ns)) / 1_000_000.0,
        });
    }

    // Memory usage
    try writer.writeAll("═══ Memory Usage ═══\n\n");
    const rss = try bench.getCurrentRSS();
    const formatted = bench.formatBytes(rss);
    try writer.print("  Current RSS: {d:.2} {s}\n\n", .{ formatted.value, formatted.unit });

    // Stress tests
    if (args.include_stress) {
        try writer.writeAll("═══ Stress Tests ═══\n\n");
        try runStressTests(allocator, writer, data.pathological);
    }

    // Final summary
    try writer.print(
        \\═══ Final Results ═══
        \\
        \\  Peak throughput: {d:.2} MB/s
        \\  Status:          {s}
        \\
    , .{
        best_throughput,
        if (best_throughput >= 10.0) "✅ PASS (≥10 MB/s target)" else "⚠️  Below target",
    });
}

fn runStressTests(
    allocator: std.mem.Allocator,
    writer: anytype,
    pathological: []const u8,
) !void {
    // Pathological input test (detect O(n²) behavior)
    const result = try runEncodeBenchmark(
        allocator,
        "pathological",
        "cl100k_base",
        pathological,
        10,
        2,
    );

    // Expected linear time: ~10ms for 100KB at 10MB/s
    const expected_ms: f64 = 10.0;
    const actual_ms = result.avgLatencyMs();

    if (actual_ms > expected_ms * 10) {
        try writer.print(
            "  ⚠️  Pathological input: {d:.2} ms (potential O(n²) - expected <{d:.0} ms)\n",
            .{ actual_ms, expected_ms * 10 },
        );
    } else {
        try writer.print(
            "  ✓  Pathological input: {d:.2} ms (linear complexity)\n",
            .{actual_ms},
        );
    }
}

// ============================================================================
// JSON Format Output
// ============================================================================

fn runJsonBenchmarks(
    allocator: std.mem.Allocator,
    writer: anytype,
    data: TestData,
    args: Args,
) !void {
    const iter_small: u64 = if (args.quick) 1_000 else 100_000;
    const iter_medium: u64 = if (args.quick) 100 else 10_000;
    const iter_large: u64 = if (args.quick) 10 else 100;
    const warmup_ratio: u64 = 10;

    try writer.writeAll("{\n");
    try writer.print(
        \\  "meta": {{
        \\    "version": "{s}",
        \\    "timestamp": "{s}",
        \\    "system": "{s}",
        \\    "mode": "{s}"
        \\  }},
        \\  "benchmarks": [
    , .{
        VERSION,
        getTimestamp(),
        bench.getSystemInfo(),
        if (args.quick) "quick" else "full",
    });

    const encodings = if (args.encoding) |enc|
        &[_][]const u8{enc}
    else
        &ENCODINGS;

    var first_result = true;

    for (encodings) |encoding| {
        // Small
        const small_result = try runEncodeBenchmark(
            allocator,
            "encode_small",
            encoding,
            data.small,
            iter_small,
            iter_small / warmup_ratio,
        );

        if (!first_result) try writer.writeAll(",");
        first_result = false;
        try writer.writeAll("\n    ");
        try small_result.formatJson(writer);

        // Medium
        const medium_result = try runEncodeBenchmark(
            allocator,
            "encode_medium",
            encoding,
            data.medium,
            iter_medium,
            iter_medium / warmup_ratio,
        );

        try writer.writeAll(",\n    ");
        try medium_result.formatJson(writer);

        // Large
        const large_result = try runEncodeBenchmark(
            allocator,
            "encode_large",
            encoding,
            data.large,
            iter_large,
            iter_large / warmup_ratio,
        );

        try writer.writeAll(",\n    ");
        try large_result.formatJson(writer);
    }

    // Memory
    const rss = try bench.getCurrentRSS();

    try writer.print(
        \\
        \\  ],
        \\  "memory": {{
        \\    "rss_bytes": {d}
        \\  }}
        \\}}
        \\
    , .{rss});
}

// ============================================================================
// Markdown Format Output
// ============================================================================

fn runMarkdownBenchmarks(
    allocator: std.mem.Allocator,
    writer: anytype,
    data: TestData,
    args: Args,
) !void {
    const iter_small: u64 = if (args.quick) 1_000 else 100_000;
    const iter_medium: u64 = if (args.quick) 100 else 10_000;
    const iter_large: u64 = if (args.quick) 10 else 100;
    const warmup_ratio: u64 = 10;

    try writer.print(
        \\## 📊 llm-cost Benchmark Results
        \\
        \\**Version:** v{s}
        \\**Date:** {s}
        \\**Mode:** {s}
        \\
        \\### Throughput
        \\
        \\| Input Size | cl100k_base | o200k_base |
        \\|------------|-------------|------------|
        \\
    , .{
        VERSION,
        getTimestamp(),
        if (args.quick) "Quick" else "Full",
    });

    // Collect results for both encodings
    var results_cl100k: [3]f64 = undefined;
    var results_o200k: [3]f64 = undefined;

    for (ENCODINGS, 0..) |encoding, enc_idx| {
        const small_result = try runEncodeBenchmark(
            allocator,
            "encode_small",
            encoding,
            data.small,
            iter_small,
            iter_small / warmup_ratio,
        );

        const medium_result = try runEncodeBenchmark(
            allocator,
            "encode_medium",
            encoding,
            data.medium,
            iter_medium,
            iter_medium / warmup_ratio,
        );

        const large_result = try runEncodeBenchmark(
            allocator,
            "encode_large",
            encoding,
            data.large,
            iter_large,
            iter_large / warmup_ratio,
        );

        if (enc_idx == 0) {
            results_cl100k[0] = small_result.throughputMBps();
            results_cl100k[1] = medium_result.throughputMBps();
            results_cl100k[2] = large_result.throughputMBps();
        } else {
            results_o200k[0] = small_result.throughputMBps();
            results_o200k[1] = medium_result.throughputMBps();
            results_o200k[2] = large_result.throughputMBps();
        }
    }

    // Output table rows
    const sizes = [_][]const u8{ "100B", "10KB", "1MB" };
    for (sizes, 0..) |size, i| {
        try writer.print(
            "| {s:<10} | {d:>7.2} MB/s | {d:>7.2} MB/s |\n",
            .{ size, results_cl100k[i], results_o200k[i] },
        );
    }

    // Memory
    const rss = try bench.getCurrentRSS();
    const formatted = bench.formatBytes(rss);

    try writer.print(
        \\
        \\### Memory
        \\
        \\- **RSS:** {d:.2} {s}
        \\
        \\### Status
        \\
        \\{s}
        \\
    , .{
        formatted.value,
        formatted.unit,
        if (results_cl100k[2] >= 10.0) "✅ **Performance target met** (≥10 MB/s)" else "⚠️ Below target",
    });
}

// ============================================================================
// Core Benchmark Runner
// ============================================================================

fn runEncodeBenchmark(
    allocator: std.mem.Allocator,
    name: []const u8,
    encoding: []const u8,
    input: []const u8,
    iterations: u64,
    warmup: u64,
) !bench.BenchmarkResult {
    // Instantiate real tokenizer
    const spec = Registry.get(encoding) orelse return error.UnknownEncoding;

    // Config: Allow approximate if vocab loading fails? No, benchmark should be precise.
    // BUT: bench suite assumes bundled vocab data is embedded in registry.
    // Registry.get returns spec with embedded data pointers.
    const config = OpenAIConfig{
        .spec = spec,
        .approximate_ok = false,
        .bpe_version = .v2,
    };

    var tokenizer = try Tokenizer.init(allocator, config);
    defer tokenizer.deinit(allocator);

    var latencies = try std.ArrayList(u64).initCapacity(allocator, iterations);
    defer latencies.deinit();

    // Warmup
    for (0..warmup) |_| {
        const tokens = try tokenizer.encode(allocator, input);
        allocator.free(tokens);
    }

    // Benchmark
    var total_ns: u64 = 0;
    for (0..iterations) |_| {
        var timer = try std.time.Timer.start();
        const tokens = try tokenizer.encode(allocator, input);
        const elapsed = timer.read();

        allocator.free(tokens); // Freeing is part of the cost if not using an arena per run

        total_ns += elapsed;
        try latencies.append(elapsed);
    }

    std.mem.sort(u64, latencies.items, {}, std.sort.asc(u64));

    const mean = if (iterations > 0) total_ns / iterations else 0;

    return bench.BenchmarkResult{
        .name = name,
        .encoding = encoding,
        .input_bytes = input.len,
        .iterations = iterations,
        .total_ns = total_ns,
        .min_ns = if (latencies.items.len > 0) latencies.items[0] else 0,
        .max_ns = if (latencies.items.len > 0) latencies.items[latencies.items.len - 1] else 0,
        .mean_ns = mean,
        .stddev_ns = calculateStdDev(latencies.items, mean),
        .p50_ns = percentile(latencies.items, 50),
        .p95_ns = percentile(latencies.items, 95),
        .p99_ns = percentile(latencies.items, 99),
    };
}

fn percentile(sorted: []const u64, p: u64) u64 {
    if (sorted.len == 0) return 0;
    const idx = (sorted.len * p) / 100;
    const clamped = @min(idx, sorted.len - 1);
    return sorted[clamped];
}

fn calculateStdDev(values: []const u64, mean: u64) u64 {
    if (values.len == 0) return 0;

    var sum_sq: u128 = 0;
    for (values) |v| {
        const diff: i128 = @as(i128, @intCast(v)) - @as(i128, @intCast(mean));
        sum_sq += @intCast(@abs(diff * diff));
    }

    const variance = sum_sq / values.len;
    return std.math.sqrt(variance);
}

fn getTimestamp() []const u8 {
    return "2025-12-10T21:05:00Z";
}
