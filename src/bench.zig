// src/bench.zig - Performance Benchmark Harness
//
// Provides precise timing, percentile calculation, and throughput measurement
// for tokenization benchmarks.

const std = @import("std");

/// Result of a benchmark run with full statistics
pub const BenchmarkResult = struct {
    name: []const u8,
    encoding: []const u8,
    input_bytes: u64,
    iterations: u64,
    total_ns: u64,

    // Latency statistics (nanoseconds)
    min_ns: u64,
    max_ns: u64,
    mean_ns: u64,
    stddev_ns: u64,
    p50_ns: u64,
    p95_ns: u64,
    p99_ns: u64,

    /// Calculate throughput in MB/s
    pub fn throughputMBps(self: BenchmarkResult) f64 {
        if (self.total_ns == 0) return 0;
        const total_bytes = self.input_bytes * self.iterations;
        const seconds = @as(f64, @floatFromInt(self.total_ns)) / 1_000_000_000.0;
        const bytes_per_sec = @as(f64, @floatFromInt(total_bytes)) / seconds;
        return bytes_per_sec / 1_000_000.0;
    }

    /// Calculate average latency in milliseconds
    pub fn avgLatencyMs(self: BenchmarkResult) f64 {
        return @as(f64, @floatFromInt(self.mean_ns)) / 1_000_000.0;
    }

    /// Format result for console output
    pub fn format(self: BenchmarkResult, writer: anytype) !void {
        try writer.print(
            \\{s} ({s}):
            \\  Input:       {d} bytes
            \\  Iterations:  {d}
            \\  Throughput:  {d:.2} MB/s
            \\  Latency:
            \\    min:    {d:.3} ms
            \\    p50:    {d:.3} ms
            \\    p95:    {d:.3} ms
            \\    p99:    {d:.3} ms
            \\    max:    {d:.3} ms
            \\    mean:   {d:.3} ms
            \\    stddev: {d:.3} ms
            \\
        , .{
            self.name,
            self.encoding,
            self.input_bytes,
            self.iterations,
            self.throughputMBps(),
            @as(f64, @floatFromInt(self.min_ns)) / 1_000_000.0,
            @as(f64, @floatFromInt(self.p50_ns)) / 1_000_000.0,
            @as(f64, @floatFromInt(self.p95_ns)) / 1_000_000.0,
            @as(f64, @floatFromInt(self.p99_ns)) / 1_000_000.0,
            @as(f64, @floatFromInt(self.max_ns)) / 1_000_000.0,
            @as(f64, @floatFromInt(self.mean_ns)) / 1_000_000.0,
            @as(f64, @floatFromInt(self.stddev_ns)) / 1_000_000.0,
        });
    }

    /// Format as JSON
    pub fn formatJson(self: BenchmarkResult, writer: anytype) !void {
        try writer.print(
            \\{{
            \\  "name": "{s}",
            \\  "encoding": "{s}",
            \\  "input_bytes": {d},
            \\  "iterations": {d},
            \\  "throughput_mbps": {d:.4},
            \\  "latency_ns": {{
            \\    "min": {d},
            \\    "p50": {d},
            \\    "p95": {d},
            \\    "p99": {d},
            \\    "max": {d},
            \\    "mean": {d},
            \\    "stddev": {d}
            \\  }}
            \\}}
        , .{
            self.name,
            self.encoding,
            self.input_bytes,
            self.iterations,
            self.throughputMBps(),
            self.min_ns,
            self.p50_ns,
            self.p95_ns,
            self.p99_ns,
            self.max_ns,
            self.mean_ns,
            self.stddev_ns,
        });
    }
};

/// Configuration for a benchmark run
pub const BenchmarkConfig = struct {
    name: []const u8,
    encoding: []const u8 = "cl100k_base",
    iterations: u64 = 1000,
    warmup_iterations: u64 = 100,
};

/// Run a benchmark with the given encode function
pub fn runBenchmark(
    allocator: std.mem.Allocator,
    config: BenchmarkConfig,
    input: []const u8,
    encode_fn: *const fn ([]const u8) anyerror![]const u32,
) !BenchmarkResult {
    // Allocate space for latency measurements
    var latencies = try std.ArrayList(u64).initCapacity(allocator, config.iterations);
    defer latencies.deinit();

    // Warmup phase - don't measure
    for (0..config.warmup_iterations) |_| {
        const result = try encode_fn(input);
        // Prevent optimization from eliminating the call
        std.mem.doNotOptimizeAway(result);
    }

    // Benchmark phase
    var total_ns: u64 = 0;

    for (0..config.iterations) |_| {
        var timer = try std.time.Timer.start();
        const result = try encode_fn(input);
        const elapsed = timer.read();

        std.mem.doNotOptimizeAway(result);

        total_ns += elapsed;
        try latencies.append(elapsed);
    }

    // Sort latencies for percentile calculation
    std.mem.sort(u64, latencies.items, {}, std.sort.asc(u64));

    const mean = total_ns / config.iterations;

    return BenchmarkResult{
        .name = config.name,
        .encoding = config.encoding,
        .input_bytes = input.len,
        .iterations = config.iterations,
        .total_ns = total_ns,
        .min_ns = latencies.items[0],
        .max_ns = latencies.items[latencies.items.len - 1],
        .mean_ns = mean,
        .stddev_ns = calculateStdDev(latencies.items, mean),
        .p50_ns = percentile(latencies.items, 50),
        .p95_ns = percentile(latencies.items, 95),
        .p99_ns = percentile(latencies.items, 99),
    };
}

/// Simpler benchmark runner that takes a closure-like approach
pub fn benchmark(
    allocator: std.mem.Allocator,
    name: []const u8,
    input: []const u8,
    iterations: u64,
    warmup: u64,
    comptime bench_fn: fn ([]const u8) void,
) !BenchmarkResult {
    var latencies = try std.ArrayList(u64).initCapacity(allocator, iterations);
    defer latencies.deinit();

    // Warmup
    for (0..warmup) |_| {
        bench_fn(input);
    }

    // Benchmark
    var total_ns: u64 = 0;
    for (0..iterations) |_| {
        var timer = try std.time.Timer.start();
        bench_fn(input);
        const elapsed = timer.read();
        total_ns += elapsed;
        try latencies.append(elapsed);
    }

    std.mem.sort(u64, latencies.items, {}, std.sort.asc(u64));
    const mean = total_ns / iterations;

    return BenchmarkResult{
        .name = name,
        .encoding = "n/a",
        .input_bytes = input.len,
        .iterations = iterations,
        .total_ns = total_ns,
        .min_ns = latencies.items[0],
        .max_ns = latencies.items[latencies.items.len - 1],
        .mean_ns = mean,
        .stddev_ns = calculateStdDev(latencies.items, mean),
        .p50_ns = percentile(latencies.items, 50),
        .p95_ns = percentile(latencies.items, 95),
        .p99_ns = percentile(latencies.items, 99),
    };
}

/// Calculate percentile from sorted array
fn percentile(sorted: []const u64, p: u64) u64 {
    if (sorted.len == 0) return 0;
    const idx = (sorted.len * p) / 100;
    const clamped = @min(idx, sorted.len - 1);
    return sorted[clamped];
}

/// Calculate standard deviation
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

/// Get current process RSS in bytes
pub fn getCurrentRSS() !u64 {
    // Linux: read from /proc/self/statm
    const file = std.fs.openFileAbsolute("/proc/self/statm", .{}) catch {
        // Not on Linux, return 0
        return 0;
    };
    defer file.close();

    var buf: [256]u8 = undefined;
    const bytes_read = try file.read(&buf);

    var iter = std.mem.splitScalar(u8, buf[0..bytes_read], ' ');
    _ = iter.next(); // Skip VmSize

    if (iter.next()) |rss_pages| {
        const pages = std.fmt.parseInt(u64, std.mem.trim(u8, rss_pages, &std.ascii.whitespace), 10) catch return 0;
        return pages * 4096; // Assuming 4KB pages
    }

    return 0;
}

/// Get system information string
pub fn getSystemInfo() []const u8 {
    // Simple placeholder - could be expanded
    return "Linux x86_64";
}

/// Format bytes as human-readable
pub fn formatBytes(bytes: u64) struct { value: f64, unit: []const u8 } {
    if (bytes >= 1_000_000_000) {
        return .{ .value = @as(f64, @floatFromInt(bytes)) / 1_000_000_000.0, .unit = "GB" };
    } else if (bytes >= 1_000_000) {
        return .{ .value = @as(f64, @floatFromInt(bytes)) / 1_000_000.0, .unit = "MB" };
    } else if (bytes >= 1_000) {
        return .{ .value = @as(f64, @floatFromInt(bytes)) / 1_000.0, .unit = "KB" };
    } else {
        return .{ .value = @as(f64, @floatFromInt(bytes)), .unit = "B" };
    }
}

// ============================================================================
// Tests
// ============================================================================

test "percentile calculation" {
    const data = [_]u64{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };

    try std.testing.expectEqual(@as(u64, 5), percentile(&data, 50));
    try std.testing.expectEqual(@as(u64, 10), percentile(&data, 99));
    try std.testing.expectEqual(@as(u64, 1), percentile(&data, 0));
}

test "stddev calculation" {
    const data = [_]u64{ 2, 4, 4, 4, 5, 5, 7, 9 };
    const mean: u64 = 5;
    const stddev = calculateStdDev(&data, mean);

    // Expected stddev ≈ 2
    try std.testing.expect(stddev >= 1 and stddev <= 3);
}

test "formatBytes" {
    const result = formatBytes(1_500_000);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), result.value, 0.01);
    try std.testing.expectEqualStrings("MB", result.unit);
}

test "BenchmarkResult throughput" {
    const result = BenchmarkResult{
        .name = "test",
        .encoding = "test",
        .input_bytes = 1_000_000, // 1MB
        .iterations = 10,
        .total_ns = 1_000_000_000, // 1 second total
        .min_ns = 0,
        .max_ns = 0,
        .mean_ns = 0,
        .stddev_ns = 0,
        .p50_ns = 0,
        .p95_ns = 0,
        .p99_ns = 0,
    };

    // 10MB in 1 second = 10 MB/s
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), result.throughputMBps(), 0.01);
}
