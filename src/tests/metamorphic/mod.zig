const std = @import("std");

pub const testing = std.testing;

// Project modules (injected via build.zig)
const calibration = @import("calibration");
const focus_import = calibration.focus;
const types = calibration.types;
const Pricing = @import("pricing");
const key_intern = calibration.key_intern;

const helpers = @import("helpers");
const ChunkedReader = helpers.ChunkedReader;
const TestEnv = helpers.TestEnv;
const withTempCwd = helpers.withTempCwd;

pub const ActualsSummary = struct {
    record_count: u64 = 0,
    total_cost: types.MicroUSD = 0,
    total_quantity: u64 = 0,
};

/// Parse Focus CSV data from an in-memory string and return simple aggregates.
/// `chunk_size` controls how the underlying reader splits input.
pub fn parseActualsFromString(
    allocator: std.mem.Allocator,
    csv: []const u8,
    chunk_size: usize,
) !ActualsSummary {
    var cr = ChunkedReader.init(csv, chunk_size);
    const r = cr.reader(); // keep reader value alive

    var parser = try focus_import.FocusParser.initFromReader(allocator, r, 2 * 1024 * 1024);
    defer parser.deinit();

    var out: ActualsSummary = .{};
    while (try parser.next()) |rec| {
        out.record_count += 1;
        // Prefer EffectiveCost when present; fallback to BilledCost.
        const cost = rec.EffectiveCost;
        out.total_cost += cost;
        out.total_quantity += rec.UsageQuantity;
    }
    return out;
}

/// Run full calibrate pipeline using temp files, returning captured stdout.
/// This calls the calibration engine directly, not the OS process.
pub fn runCalibrateFromStrings(
    allocator: std.mem.Allocator,
    estimates_json: []const u8,
    actuals_csv: []const u8,
    opts: calibration.RunOptions,
    format: calibration.report.OutputFormat, // Fix: use report.OutputFormat
) ![]u8 {
    // Hermetic FS env (same harness used elsewhere in repo)
    var env = TestEnv.init(allocator);
    defer env.deinit();

    try env.write("estimates.json", estimates_json);
    try env.write("actuals.csv", actuals_csv);

    // Real pricing registry + interner
    var registry = try Pricing.Registry.init(allocator, .{});
    defer registry.deinit();

    var interner = key_intern.StringInterner.init(allocator);
    defer interner.deinit();

    const result = try withTempCwd(allocator, env.tmp.dir, calibration.run, .{ allocator, opts, &registry, &interner });
    defer result.deinit(allocator);

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    try calibration.formatOutput(result, format, out.writer().any());
    return try out.toOwnedSlice();
}

/// Deterministic equality helper for "success or same error".
pub const Outcome = union(enum) { ok: ActualsSummary, err: []const u8 };

pub fn parseOutcome(
    allocator: std.mem.Allocator,
    csv: []const u8,
    chunk_size: usize,
) Outcome {
    const res = parseActualsFromString(allocator, csv, chunk_size);
    if (res) |s| {
        return .{ .ok = s };
    } else |err| {
        return .{ .err = @errorName(err) };
    }
}

// Metamorphic tests entrypoint
test {
    _ = @import("determinism_test.zig");
    _ = @import("chunking_test.zig");
    _ = @import("quoting_test.zig");
    _ = @import("permutation_test.zig");
    _ = @import("roundtrip_test.zig");
}
