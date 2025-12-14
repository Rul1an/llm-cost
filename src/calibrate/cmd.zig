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
) !u8 {
    _ = registry; // May use later for on-the-fly pricing if needed

    var estimates_path: ?[]const u8 = null;
    var matches_file: ?[]const u8 = null; // CSV file for FOCUS data
    var match_mode: join.IdNormalization = .strict;
    var include_timestamp = false;
    var validate_only = false; // v1.2.1 preparation
    var max_groups: usize = 100_000;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--estimates")) {
            if (i + 1 >= args.len) return error.MissingArgument;
            estimates_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--csv") or std.mem.eql(u8, arg, "--actuals")) { // v1.2.1 alias
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
        } else if (std.mem.eql(u8, arg, "--include-timestamp")) {
            include_timestamp = true;
        } else if (std.mem.eql(u8, arg, "--validate-only")) {
            validate_only = true;
        } else if (std.mem.eql(u8, arg, "--max-groups")) {
            if (i + 1 >= args.len) return error.MissingArgument;
            max_groups = try std.fmt.parseInt(usize, args[i + 1], 10);
            i += 1;
        }
    }

    if (estimates_path == null) {
        try stderr.print("Error: --estimates <FILE> is required.\n", .{});
        return error.MissingArgument;
    }

    // 1. Load Estimates & Calculate Hash
    var perm_arena = std.heap.ArenaAllocator.init(allocator);
    defer perm_arena.deinit();
    const perm = perm_arena.allocator();

    const est_content = try std.fs.cwd().readFileAlloc(allocator, estimates_path.?, 100 * 1024 * 1024);
    defer allocator.free(est_content);

    var est_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(est_content, &est_hash, .{});
    const est_hash_hex = try std.fmt.allocPrint(allocator, "{s}", .{std.fmt.fmtSliceHexLower(&est_hash)});
    defer allocator.free(est_hash_hex);

    var estimates_map = loadEstimatesFromMemory(allocator, perm, est_content, match_mode, stderr) catch |err| {
        switch (err) {
            error.EstimateIdCollision, error.MissingField, error.InvalidCostFormat => return 2, // 2 = Schema/Data Error
            error.DuplicateField => {
                try stderr.print("Error: Duplicate field/ID in JSON estimates.\n", .{});
                return 2;
            },
            error.InvalidEstimatesFormat => {
                try stderr.print("Error: Invalid JSON structure in estimates.\n", .{});
                return 2;
            },
            else => return err, // Use default handler for IO/OOM
        }
    };
    defer estimates_map.deinit(allocator);

    // 2. Setup Streaming Join & Hash Actuals
    var scratch_arena = std.heap.ArenaAllocator.init(allocator);
    defer scratch_arena.deinit();

    const join_opts = join.JoinOptions{
        .id_normalization = match_mode,
        .max_groups = max_groups,
    };

    // Open CSV Input
    const file = if (matches_file) |path|
        try std.fs.cwd().openFile(path, .{})
    else
        std.io.getStdIn();
    defer if (matches_file != null) file.close();

    // Hashing Reader Wrapper
    var hashing_wrapper = try HashingReader(@TypeOf(file.reader())).init(file.reader());

    var buf_reader = std.io.bufferedReader(hashing_wrapper.reader());
    const reader = buf_reader.reader();

    const FocusIter = focus.FocusIterator(@TypeOf(reader));
    var iterator = FocusIter.init(allocator, reader, .{}) catch |err| {
        if (err == error.InvalidColumnMapping) {
            try stderr.print("Error: CSV missing required columns (ResourceId, BilledCost, ChargePeriodStart).\n", .{});
            return 2; // Schema validation failed
        }
        return err;
    };
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

    // Finalize Actuals Hash (after join consumes stream)
    var act_hash: [32]u8 = undefined;
    hashing_wrapper.final(&act_hash);
    const act_hash_hex = try std.fmt.allocPrint(allocator, "{s}", .{std.fmt.fmtSliceHexLower(&act_hash)});
    defer allocator.free(act_hash_hex);

    // 4. Output Results
    // Validation check (v1.2.1)
    if (validate_only) {
        if (result.stats.matched_rows == 0 and estimates_map.count() > 0) {
            try stderr.print("Warning: 0 rows matched during validation.\n", .{});
            // For --validate-only, should 0 matches be an error?
            // User says: "3 (insufficient/joinable te laag)".
            return 3;
        }
        try stdout.print("Validation Complete. Estimates: {d}, Matched: {d}\n", .{ estimates_map.count(), result.stats.matched_rows });
        return 0;
    }

    if (result.stats.matched_rows == 0 and estimates_map.count() > 0) {
        try stderr.print("Warning: 0 rows matched. Factors list is empty.\n", .{});
        // Return 3 for 'insufficient'
        return 3;
    }

    const metadata = factors.Metadata{
        .tool_version = "v1.2.1",
        .estimates_sha256 = est_hash_hex, // Hex string
        .actuals_sha256 = act_hash_hex, // Hex string
        .generated_at = if (include_timestamp) std.time.timestamp() else null,

        // v1.2.1 Extras
        .match_mode = switch (match_mode) {
            .strict => "strict",
            .fuzzy => "fuzzy",
        },
        .matched_rows = result.stats.matched_rows,
        .unmatched_actuals = result.stats.unmatched_actuals,
        .unmatched_estimates = result.stats.unmatched_estimates,
    };

    try factors.writeToml(allocator, stdout, result, metadata);

    // Diagnostics to stderr
    if (result.stats.unmatched_actuals > 0) {
        try stderr.print("\nWarning: {d} rows in CSV did not match any estimate.\n", .{result.stats.unmatched_actuals});
        const samples = result.stats.unmatched_actual_samples.items();
        if (samples.len > 0) {
            try stderr.print("Sample unmatched IDs:\n", .{});
            for (samples) |s| try stderr.print("  - {s}\n", .{s});
        }
    }

    return 0; // Success
}

pub fn HashingReader(comptime ReaderType: type) type {
    return struct {
        child_reader: ReaderType,
        hasher: std.crypto.hash.sha2.Sha256,
        const Self = @This();

        pub fn init(child: ReaderType) !Self {
            return .{
                .child_reader = child,
                .hasher = std.crypto.hash.sha2.Sha256.init(.{}),
            };
        }

        pub fn read(self: *Self, dest: []u8) !usize {
            const n = try self.child_reader.read(dest);
            if (n > 0) {
                self.hasher.update(dest[0..n]);
            }
            return n;
        }

        pub fn reader(self: *Self) std.io.Reader(*Self, ReaderType.Error, read) {
            return .{ .context = self };
        }

        pub fn final(self: *Self, out: *[32]u8) void {
            self.hasher.final(out);
        }
    };
}

fn loadEstimatesFromMemory(gpa: Allocator, perm: Allocator, content: []const u8, match_mode: join.IdNormalization, diagnostic: anytype) !join.EstimateIndex {
    var map = join.EstimateIndex{};
    errdefer map.deinit(gpa);
    errdefer map.deinit(gpa);

    const Parsed = try std.json.parseFromSlice(std.json.Value, gpa, content, .{
        .duplicate_field_behavior = .@"error",
    });
    defer Parsed.deinit();

    const root = Parsed.value;
    if (root != .object) return error.InvalidEstimatesFormat;

    // Detect Schema: "prompts" array vs Legacy Flat Map
    if (root.object.get("prompts")) |prompts_val| {
        // V2 Schema: {"prompts": [{"resource_id": "...", "cost_usd": ...}]}
        if (prompts_val != .array) return error.InvalidEstimatesFormat;

        for (prompts_val.array.items) |item| {
            if (item != .object) continue;

            const id_val = item.object.get("resource_id") orelse continue;
            const id_raw = switch (id_val) {
                .string => |s| s,
                else => continue,
            };

            const id_norm = join.normalizeResourceId(id_raw, match_mode);
            if (map.get(id_norm)) |existing| {
                try diagnostic.print("Error: Estimate ID collision. '{s}' and '{s}' both normalize to '{s}' which is ambiguous.\n", .{ existing.original_id, id_raw, id_norm });
                return error.EstimateIdCollision;
            }

            var est_micro: i128 = 0;

            if (item.object.get("cost_micro")) |cm| {
                est_micro = switch (cm) {
                    .integer => |i| i,
                    else => {
                        try diagnostic.print("Error: 'cost_micro' must be an integer for ID '{s}'\n", .{id_raw});
                        return error.InvalidCostFormat;
                    },
                };
            } else {
                // Support 'cost_usd' (V2) or 'cost' (Legacy/Fallback)
                const cost_val = item.object.get("cost_usd") orelse item.object.get("cost") orelse {
                    try diagnostic.print("Error: Missing 'cost_usd' or 'cost_micro' for ID '{s}'\n", .{id_raw});
                    return error.MissingField;
                };
                est_micro = try parseCost(cost_val, id_raw, diagnostic);
            }

            // Extract required model/scenario (default to "default" if missing? Or error?)
            // Legacy schema required them. We should likely require them or default.
            // For FinOps PoC with `estimate` output, they should be present.
            // Let's error if missing for strictness, or default to "" if practical.
            // Existing types are []const u8.
            const model_val = item.object.get("model") orelse item.object.get("model_id"); // maybe model_id?
            const model = if (model_val) |m| (switch (m) {
                .string => |s| s,
                else => "unknown",
            }) else "unknown";

            const scenario_val = item.object.get("scenario");
            const scenario = if (scenario_val) |s| (switch (s) {
                .string => |v| v,
                else => "default",
            }) else "default";

            // Intern keys and strings into PERM allocator as they must survive this function
            const key_interned = try perm.dupe(u8, id_norm);
            const original_interned = try perm.dupe(u8, id_raw);

            try map.put(gpa, key_interned, .{
                .est_micro = est_micro,
                .model = try perm.dupe(u8, model),
                .scenario = try perm.dupe(u8, scenario),
                .original_id = original_interned,
            });
        }
    } else {
        // Legacy Schema: {"id": {"cost": ...}}
        var it = root.object.iterator();
        while (it.next()) |entry| {
            const id_raw = entry.key_ptr.*;
            const val = entry.value_ptr.*;

            // Skip metadata keys
            if (std.mem.eql(u8, id_raw, "version")) continue;

            if (val != .object) continue;

            const id_norm = join.normalizeResourceId(id_raw, match_mode);

            if (map.get(id_norm)) |existing| {
                try diagnostic.print("Error: Estimate ID collision. '{s}' and '{s}' both normalize to '{s}' which is ambiguous.\n", .{ existing.original_id, id_raw, id_norm });
                return error.EstimateIdCollision;
            }

            const cost_val = val.object.get("cost") orelse {
                try diagnostic.print("Error: Missing 'cost' for ID '{s}'\n", .{id_raw});
                return error.MissingField;
            };
            const est_micro: i128 = try parseCost(cost_val, id_raw, diagnostic);

            const model_val = val.object.get("model") orelse return error.MissingField;
            const scenario_val = val.object.get("scenario") orelse return error.MissingField;

            const model = model_val.string;
            const scenario = scenario_val.string;

            // Intern keys
            const key_interned = try perm.dupe(u8, id_norm);
            const original_interned = try perm.dupe(u8, id_raw);

            try map.put(gpa, key_interned, .{
                .est_micro = est_micro,
                .model = try perm.dupe(u8, model),
                .scenario = try perm.dupe(u8, scenario),
                .original_id = original_interned,
            });
        }
    }

    return map;
}

fn parseCost(val: std.json.Value, id: []const u8, diagnostic: anytype) !i128 {
    return switch (val) {
        .float => |f| @intFromFloat(f * 1_000_000.0),
        .integer => |i| blk: {
            if (i < 0) {
                try diagnostic.print("Error: Negative 'cost' integer value {d} for ID '{s}'\n", .{ i, id });
                return error.InvalidCostFormat;
            }
            break :blk @intCast(i * 1_000_000);
        },
        .string => |s| blk: {
            const f = std.fmt.parseFloat(f64, s) catch {
                try diagnostic.print("Error: Invalid cost string '{s}' for ID '{s}'\n", .{ s, id });
                return error.InvalidCostFormat;
            };
            break :blk @intFromFloat(f * 1_000_000.0);
        },
        else => return error.InvalidCostFormat,
    };
}

test "Calibrate Command E2E" {
    const allocator = std.testing.allocator;

    // Create temp files

    // 3. Negative Values (Refunds)
    const cwd = std.fs.cwd();

    // Deterministic content for hashing test
    const est_data =
        \\{
        \\  "req-1": { "cost": 0.0001, "model": "gpt-4", "scenario": "chat" },
        \\  "req-2": { "cost": 0.0002, "model": "gpt-4", "scenario": "chat" }
        \\}
    ;
    try cwd.writeFile(.{ .sub_path = "test_estimates.json", .data = est_data });
    defer cwd.deleteFile("test_estimates.json") catch {};

    const act_data =
        \\ResourceId,BilledCost,ChargePeriodStart,Tags
        \\req-1,0.000105,2025-01-01,"{}"
        \\req-2,0.000210,2025-01-01,"{}"
    ;
    try cwd.writeFile(.{ .sub_path = "test_actuals.csv", .data = act_data });
    defer cwd.deleteFile("test_actuals.csv") catch {};

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();

    var stderr_buf = std.ArrayList(u8).init(allocator);
    defer stderr_buf.deinit();

    // Mock Registry
    var registry = try Pricing.Registry.init(allocator, .{});
    defer registry.deinit();

    const args = [_][]const u8{ "calibrate", "--estimates", "test_estimates.json", "--csv", "test_actuals.csv" };

    const exit_code = try run(allocator, &args, &registry, stdout_buf.writer(), stderr_buf.writer());
    try std.testing.expectEqual(@as(u8, 0), exit_code);

    const out = stdout_buf.items;

    // Check Metadata
    try std.testing.expect(std.mem.indexOf(u8, out, "[metadata]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "tool_version = \"v1.2.1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "estimates_sha256 =") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "actuals_sha256 =") != null);

    // Expect drift
    try std.testing.expect(std.mem.indexOf(u8, out, "multiplier = 1.0500") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "drift_bps = 500") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "model = \"gpt-4\"") != null);
}

test "Calibrate - Validation Rules" {
    const allocator = std.testing.allocator;
    const cwd = std.fs.cwd();
    var registry = try Pricing.Registry.init(allocator, .{});
    defer registry.deinit();

    // Create independent actuals file to avoid race conditions/dependencies
    const val_act_data = "ResourceId,BilledCost,ChargePeriodStart,Tags\nreq-1,0.000105,2025-01-01,\"{}\"";
    try cwd.writeFile(.{ .sub_path = "val_actuals.csv", .data = val_act_data });
    defer cwd.deleteFile("val_actuals.csv") catch {};

    // 1. Duplicate Estimates ID (Fatal)
    const dup_est =
        \\{
        \\  "req-1": { "cost": 0.0001, "model": "gpt-4", "scenario": "chat" },
        \\  "req-1": { "cost": 0.0002, "model": "gpt-4", "scenario": "chat" }
        \\}
    ;
    try cwd.writeFile(.{ .sub_path = "dup_estimates.json", .data = dup_est });
    defer cwd.deleteFile("dup_estimates.json") catch {};

    const args_dup = [_][]const u8{ "calibrate", "--estimates", "dup_estimates.json", "--csv", "val_actuals.csv", "--validate-only" };

    // We expect run() to return error due to json parser
    var stdout = std.ArrayList(u8).init(allocator);
    defer stdout.deinit();
    var stderr = std.ArrayList(u8).init(allocator);
    defer stderr.deinit();

    const exit_code = try run(allocator, &args_dup, &registry, stdout.writer(), stderr.writer());
    try std.testing.expectEqual(@as(u8, 2), exit_code);
    // DuplicateField error handling now returns 2, doesn't throw
}

test "Calibrate - Fuzzy Collision" {
    const allocator = std.testing.allocator;
    const cwd = std.fs.cwd();
    var reg = try Pricing.Registry.init(allocator, .{});
    defer reg.deinit();
    var stdout = std.ArrayList(u8).init(allocator);
    defer stdout.deinit();
    var stderr = std.ArrayList(u8).init(allocator);
    defer stderr.deinit();

    const col_est =
        \\{
        \\  "req-1": { "cost": 0.0001, "model": "gpt-4", "scenario": "chat" },
        \\  "custom-req-1": { "cost": 0.0002, "model": "gpt-4", "scenario": "chat" }
        \\}
    ;
    try cwd.writeFile(.{ .sub_path = "test_collision.json", .data = col_est });
    defer cwd.deleteFile("test_collision.json") catch {};

    // Create independent actuals
    try cwd.writeFile(.{ .sub_path = "col_actuals.csv", .data = "ResourceId,BilledCost,ChargePeriodStart,Tags\nreq-1,0.000105,2025-01-01,\"{}\"" });
    defer cwd.deleteFile("col_actuals.csv") catch {};

    const args = [_][]const u8{ "calibrate", "--estimates", "test_collision.json", "--csv", "col_actuals.csv", "--match", "fuzzy" };

    const exit_code = try run(allocator, &args, &reg, stdout.writer(), stderr.writer());
    try std.testing.expectEqual(@as(u8, 2), exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stderr.items, "Estimate ID collision") != null);
}
