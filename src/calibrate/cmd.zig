const std = @import("std");
const Allocator = std.mem.Allocator;
const Pricing = @import("../core/pricing/mod.zig");
const focus = @import("focus_import.zig");
const join = @import("join.zig");
const agg = @import("aggregate.zig");
const stats = @import("stats.zig");
const factors = @import("factors.zig");
const csv = @import("csv.zig");

pub fn run(
    allocator: Allocator,
    args: []const []const u8,
    registry: *Pricing.Registry,
    stdout: anytype,
    stderr: anytype,
) !void {
    _ = registry; // May use later for on-the-fly pricing if needed

    var estimates_path: ?[]const u8 = null;
    var matches_file: ?[]const u8 = null; // CSV file for FOCUS data
    var match_mode: join.IdNormalization = .strict;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--estimates")) {
            if (i + 1 >= args.len) return error.MissingArgument;
            estimates_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--csv")) {
            if (i + 1 >= args.len) return error.MissingArgument;
            matches_file = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--match")) {
            if (i + 1 >= args.len) return error.MissingArgument;
            const mode_str = args[i + 1];
            if (std.mem.eql(u8, mode_str, "fuzzy")) {
                match_mode = .fuzzy;
            } else if (std.mem.eql(u8, mode_str, "strict")) {
                match_mode = .strict;
            } else {
                return error.InvalidMatchMode;
            }
            i += 1;
        }
    }

    if (estimates_path == null) {
        try stderr.print("Error: --estimates <FILE> is required.\n", .{});
        return error.MissingArgument;
    }

    // 1. Load Estimates
    var perm_arena = std.heap.ArenaAllocator.init(allocator);
    defer perm_arena.deinit();
    const perm = perm_arena.allocator();

    var estimates_map = try loadEstimates(allocator, perm, estimates_path.?);
    defer estimates_map.deinit(allocator);

    // 2. Setup Streaming Join
    var scratch_arena = std.heap.ArenaAllocator.init(allocator);
    defer scratch_arena.deinit();

    const join_opts = join.JoinOptions{
        .id_normalization = match_mode,
        .max_groups = 100_000,
    };

    // Open CSV Input
    const file = if (matches_file) |path|
        try std.fs.cwd().openFile(path, .{})
    else
        std.io.getStdIn();
    defer if (matches_file != null) file.close();

    // Use buffered reader
    var buf_reader = std.io.bufferedReader(file.reader());
    const reader = buf_reader.reader();

    const FocusIter = focus.FocusIterator(@TypeOf(reader));
    var iterator = try FocusIter.init(allocator, reader, .{});
    defer iterator.deinit();

    // 3. Run Join
    var result = try join.runJoin(
        FocusIter,
        allocator,
        perm,
        &scratch_arena,
        &estimates_map,
        &iterator,
        join_opts,
    );
    defer result.groups.deinit(allocator);

    // 4. Output Results
    try factors.writeToml(allocator, stdout, result);

    // Diagnostics to stderr
    if (result.stats.unmatched_actuals > 0) {
        try stderr.print("\nWarning: {d} rows in CSV did not match any estimate.\n", .{result.stats.unmatched_actuals});
        const samples = result.stats.unmatched_actual_samples.items();
        if (samples.len > 0) {
            try stderr.print("Sample unmatched IDs:\n", .{});
            for (samples) |s| try stderr.print("  - {s}\n", .{s});
        }
    }
}

fn loadEstimates(gpa: Allocator, perm: Allocator, path: []const u8) !join.EstimateIndex {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(gpa, 100 * 1024 * 1024); // 100MB limit
    defer gpa.free(content);

    var map = join.EstimateIndex{};

    // Simple JSON parser for array of objects or dict of objects
    // Structure expected: { "resource_id": { "cost": 123456, "model": "gpt-4", "scenario": "chat" } }

    const Parsed = try std.json.parseFromSlice(std.json.Value, gpa, content, .{});
    defer Parsed.deinit();

    const root = Parsed.value;
    if (root != .object) return error.InvalidEstimatesFormat;

    var it = root.object.iterator();
    while (it.next()) |entry| {
        const id = entry.key_ptr.*;
        const val = entry.value_ptr.*;

        const cost_val = val.object.get("cost").?;
        const est_micro: i128 = switch (cost_val) {
            .float => |f| @intFromFloat(f),
            .integer => |i| @intCast(i),
            else => return error.InvalidCostFormat,
        };

        const model = val.object.get("model").?.string;
        const scenario = val.object.get("scenario").?.string;

        const key_interned = try perm.dupe(u8, id);
        const meta = join.EstimateMeta{
            .est_micro = est_micro,
            .model = try perm.dupe(u8, model),
            .scenario = try perm.dupe(u8, scenario),
        };

        try map.put(gpa, key_interned, meta);
    }

    return map;
}

test "Calibrate Command E2E" {
    const allocator = std.testing.allocator;

    // Create temp files
    const cwd = std.fs.cwd();
    try cwd.writeFile(.{ .sub_path = "test_estimates.json", .data = 
        \\{
        \\  "req-1": { "cost": 100, "model": "gpt-4", "scenario": "chat" },
        \\  "req-2": { "cost": 200, "model": "gpt-4", "scenario": "chat" }
        \\}
    });
    defer cwd.deleteFile("test_estimates.json") catch {};

    try cwd.writeFile(.{ .sub_path = "test_actuals.csv", .data = 
        \\ResourceId,BilledCost,ChargePeriodStart,Tags
        \\req-1,0.000105,2025-01-01,"{}"
        \\req-2,0.000210,2025-01-01,"{}"
    }); // 0.000105 = 105 micro (vs 100 est) -> +5% drift
    // 0.000210 = 210 micro (vs 200 est) -> +5% drift
    defer cwd.deleteFile("test_actuals.csv") catch {};

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();

    var stderr_buf = std.ArrayList(u8).init(allocator);
    defer stderr_buf.deinit();

    // Mock Registry
    var registry = try Pricing.Registry.init(allocator, .{});
    defer registry.deinit();

    const args = [_][]const u8{ "calibrate", "--estimates", "test_estimates.json", "--csv", "test_actuals.csv" };

    try run(allocator, &args, &registry, stdout_buf.writer(), stderr_buf.writer());

    const out = stdout_buf.items;
    // Expect drift
    try std.testing.expect(std.mem.indexOf(u8, out, "multiplier = 1.0500") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "drift_bps = 500") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "model = \"gpt-4\"") != null);
}
