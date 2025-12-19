const std = @import("std");
pub const types = @import("types.zig");
pub const focus = @import("focus_import.zig");
pub const stats = @import("stats.zig");
pub const report = @import("report.zig");
pub const key_intern = @import("key_intern.zig");
const recs_mod = @import("recommendations.zig");

pub const Status = enum { ok, warn, @"error", insufficient_data };

pub const CalibrationResult = struct {
    estimated_total_micro: types.MicroUSD,
    actual_total_micro: types.MicroUSD,
    drift_absolute_micro: types.MicroUSD,
    drift_bps: types.BasisPoints,

    sample_count: u64,
    days_covered: u32,

    // parameters (optional, add later)
    cache_hit_ratio_bps: ?u16 = null,
    avg_input_tokens: ?u32 = null,
    avg_output_tokens: ?u32 = null,

    status: Status,

    // Cardinality Stats
    cardinality_truncated: bool = false,
    cardinality_unique_seen: u64 = 0,

    recommendations: []recs_mod.Recommendation = &[_]recs_mod.Recommendation{},

    pub fn deinit(self: CalibrationResult, allocator: std.mem.Allocator) void {
        for (self.recommendations) |r| {
            allocator.free(r.rationale);
        }
        allocator.free(self.recommendations);
    }
};

pub const Error = error{
    InvalidEstimates,
    InvalidActuals,
    MissingColumn,
    InsufficientData,
    IoError,
    OutOfMemory,
    SoftwareError,
    Bad,
    CardinalityExceeded,
};

pub const RunOptions = struct {
    estimates_path: []const u8,
    actuals_path: []const u8,

    warning_threshold_bps: u32 = 2000,
    error_threshold_bps: u32 = 5000,
    min_samples: u32 = 100,

    max_line_bytes: usize = 64 * 1024,

    // Cardinality Guardrails
    max_unique_resources: u32 = 10000,
    cardinality_policy: types.CardinalityPolicy = .degrade,
};

pub fn run(allocator: std.mem.Allocator, opts: RunOptions, registry: anytype, interner: *key_intern.StringInterner) Error!CalibrationResult {
    const est = parseEstimatesFile(allocator, opts.estimates_path) catch return error.InvalidEstimates;

    var file = std.fs.cwd().openFile(opts.actuals_path, .{}) catch return error.IoError;
    defer file.close();

    var parser = focus.FocusParser.initFromReader(allocator, file.reader(), opts.max_line_bytes) catch |e| switch (e) {
        error.MissingRequiredColumn => return error.MissingColumn,
        error.InvalidCsv => return error.InvalidActuals,
        error.LineTooLong => return error.InvalidActuals,
        error.IoError => return error.IoError,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer parser.deinit();

    var s = try stats.CalibrationStats.init(allocator, interner, opts.max_unique_resources, opts.cardinality_policy);
    defer s.deinit();

    while (true) {
        const rec_opt = parser.next() catch |e| switch (e) {
            error.InvalidNumber, error.InvalidBoolean => return error.InvalidActuals,
            error.LineTooLong => return error.InvalidActuals,
            error.IoError => return error.IoError,
            error.OutOfMemory => return error.OutOfMemory,
        };
        if (rec_opt == null) break;
        try s.update(rec_opt.?);
    }

    if (s.sample_count < opts.min_samples) return error.InsufficientData;

    const actual_total = s.total_cost_micro;
    const diff = actual_total - est.estimated_total;

    const drift_bps = types.computeDriftBps(diff, est.estimated_total) catch return error.InvalidEstimates;

    const st: Status = if (@abs(drift_bps) >= @as(i32, @intCast(opts.error_threshold_bps)))
        .@"error"
    else if (@abs(drift_bps) >= @as(i32, @intCast(opts.warning_threshold_bps)))
        .warn
    else
        .ok;

    // Generate recommendations
    // Note: 'registry' must support get(name) and iterator()
    const recs = recs_mod.generate(allocator, &s, registry, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
    };

    return .{
        .estimated_total_micro = est.estimated_total,
        .actual_total_micro = actual_total,
        .drift_absolute_micro = diff,
        .drift_bps = drift_bps,
        .sample_count = s.sample_count,
        .days_covered = s.daysCovered(),
        .status = st,
        .cardinality_truncated = s.cardinality_truncated,
        .cardinality_unique_seen = s.unique_resources_seen,
        .recommendations = recs,
    };
}

pub fn formatOutput(result: CalibrationResult, format: report.OutputFormat, writer: anytype) !void {
    try report.format(result, format, writer);
}

/// Minimal estimates parser:
/// - Expects JSON with {"estimated_total_usd":"123.456789"} OR micro-usd int.
/// - Strict: money must be string-decimal or integer micros.
const Estimates = struct {
    estimated_total: types.MicroUSD,
};

fn parseEstimatesFile(allocator: std.mem.Allocator, path: []const u8) !Estimates {
    var f = try std.fs.cwd().openFile(path, .{});
    defer f.close();

    const data = try f.readToEndAlloc(allocator, 64 * 1024 * 1024);
    defer allocator.free(data);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.Bad;

    // Check for "prompts" array (detailed output)
    if (parsed.value.object.get("prompts")) |p| {
        if (p == .array) {
            var total: types.MicroUSD = 0;
            for (p.array.items) |item| {
                if (item != .object) continue;

                // Try micros (int) first
                if (item.object.get("cost_micro_usd")) |micros| {
                    if (micros == .integer) {
                        total += @intCast(micros.integer);
                        continue;
                    }
                }
                // Legacy key
                if (item.object.get("cost_micro")) |micros| {
                    if (micros == .integer) {
                        total += @intCast(micros.integer);
                        continue;
                    }
                }

                // Try USD (float/int)
                if (item.object.get("cost_usd")) |usd| {
                    const val_f: f64 = switch (usd) {
                        .float => |fl| fl,
                        .integer => |i| @floatFromInt(i),
                        else => 0.0,
                    };
                    const m: i128 = @intFromFloat(@round(val_f * 1_000_000.0));
                    total += m;
                }
            }
            return .{ .estimated_total = total };
        }
    }

    if (parsed.value.object.get("estimated_total_micro_usd")) |v| {
        if (v == .integer) return .{ .estimated_total = @intCast(v.integer) };
        return error.Bad;
    }

    // New format (PR7.1)
    if (parsed.value.object.get("estimated_total_micro")) |v| {
        if (v == .integer) return .{ .estimated_total = @intCast(v.integer) };
        return error.Bad;
    }

    if (parsed.value.object.get("estimated_total_usd")) |v| {
        if (v == .string) {
            const micros = try types.parseMicroUSDDecimal(v.string);
            return .{ .estimated_total = micros };
        }
        return error.Bad;
    }

    return error.Bad;
}
