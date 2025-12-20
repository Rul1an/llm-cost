const std = @import("std");
const calibrate = @import("../calibration/mod.zig");
const report = @import("../calibration/report.zig");
const pricing = @import("../core/pricing/mod.zig");
const breakdown = @import("../calibration/breakdown.zig");
const TagResolver = @import("../calibration/tag_resolver.zig").Resolver;
const manifest = @import("../core/manifest.zig");
const args_mod = @import("../cli/args.zig");
const progress_mod = @import("../cli/progress.zig");
const logger_mod = @import("../cli/logger.zig");
const Verbosity = @import("../cli/verbosity.zig").Verbosity;

const CalibrateArgs = args_mod.CalibrateArgs;
const Progress = progress_mod.Progress;
const Spinner = progress_mod.Spinner;
const Logger = logger_mod.Logger;

fn loadPolicyConfig(allocator: std.mem.Allocator, log: Logger) ?manifest.Policy {
    const f = std.fs.cwd().openFile("llm-cost.toml", .{}) catch return null;
    defer f.close();

    // Read up to 1MB config
    const data = f.readToEndAlloc(allocator, 1024 * 1024) catch |e| {
        log.warn("Failed to read llm-cost.toml: {s}", .{@errorName(e)});
        return null;
    };
    defer allocator.free(data);

    const p = manifest.parse(allocator, data) catch |e| {
        log.warn("Failed to parse llm-cost.toml: {s}", .{@errorName(e)});
        return null;
    };
    return p;
}

pub const CalibrateError = error{
    MissingActuals,
    MissingEstimates,
    ParseError,
    InsufficientData,
    IoError,
    UsageError,
};

pub fn run(
    allocator: std.mem.Allocator,
    cmd_args: CalibrateArgs,
    verbosity: Verbosity,
    stdout_writer: anytype,
) !u8 {
    const log = Logger.init(verbosity);

    if (cmd_args.help) {
        try printUsage(stdout_writer);
        return 0;
    }

    if (cmd_args.rollback) {
        try executeRollback(log);
        return 0;
    }

    if (cmd_args.estimates == null or cmd_args.actuals == null) {
        // Main should handle usage error reporting if possible,
        // but here we just return error and let main handle it or log it ourselves.
        // Let's return error code for consistent handling in main.
        return CalibrateError.UsageError;
    }

    const actuals_path = cmd_args.actuals.?;
    const estimates_path = cmd_args.estimates.?;

    log.debug("Opening actuals file: {s}", .{actuals_path});

    const file = std.fs.cwd().openFile(actuals_path, .{}) catch {
        log.err("Cannot open file: {s}", .{actuals_path});
        return CalibrateError.IoError;
    };
    defer file.close();

    const file_size = file.getEndPos() catch 0;
    log.debug("File size: {d} bytes", .{file_size});

    var spinner = Spinner.init("Calibrating", verbosity);

    // 1. Load Policy Config (for Tag overrides)
    const policy = loadPolicyConfig(allocator, log);
    // Note: policy needs deallocation? manifest.parse uses allocator for internal maps.
    // Ideally we assume policy lifetime covers the run.

    // 2. Init Tag Resolver
    var resolver = TagResolver.init(allocator, if (policy) |p| p.tags else null) catch |e| {
        log.err("Failed to init tag resolver: {s}", .{@errorName(e)});
        spinner.finish();
        return 70;
    };
    defer resolver.deinit();

    // 3. Init Breakdown Aggregator (if requested)
    var aggregator: ?breakdown.Aggregator = null;
    var dims_storage = std.ArrayList([]const u8).init(allocator);
    defer dims_storage.deinit();

    if (cmd_args.group_by) |gb| {
        if (gb.len > 0) {
            var it = std.mem.splitScalar(u8, gb, ',');
            while (it.next()) |dim| {
                const trimmed = std.mem.trim(u8, dim, " ");
                if (trimmed.len > 0) try dims_storage.append(trimmed);
            }
            if (dims_storage.items.len > 0) {
                aggregator = breakdown.Aggregator.init(allocator, resolver, dims_storage.items, @intCast(cmd_args.max_resources));
            }
        }
    }
    defer if (aggregator) |*a| a.deinit();

    // 4. Init Pricing Registry
    var registry = pricing.Registry.init(allocator, .{}) catch |err| {
        log.warn("Failed to load pricing registry: {s}. Recommendations will be limited.", .{@errorName(err)});
        spinner.finish();
        return 70; // Software Error
    };
    defer registry.deinit();

    const run_opts = calibrate.RunOptions{
        .estimates_path = estimates_path,
        .actuals_path = actuals_path,
        .min_samples = @intCast(cmd_args.min_samples),
        .max_unique_resources = @intCast(cmd_args.max_resources),
        .cardinality_policy = if (cmd_args.cardinality_policy == 1) .@"error" else .degrade,
        .breakdown_aggregator = if (aggregator) |*a| a else null,
    };

    var interner = @import("../calibration/key_intern.zig").StringInterner.init(allocator);
    defer interner.deinit();

    var result = calibrate.run(allocator, run_opts, &registry, &interner) catch |err| {
        spinner.finish();
        switch (err) {
            error.InsufficientData => {
                log.err("Insufficient Data: {s}", .{@errorName(err)});
                return 3;
            },
            error.InvalidEstimates, error.InvalidActuals, error.MissingColumn, error.CardinalityExceeded => {
                log.err("Data Error: {s}", .{@errorName(err)});
                return 65;
            },
            else => {
                log.err("Software Error: {s}", .{@errorName(err)});
                return 70;
            },
        }
    };
    defer result.deinit(allocator);
    spinner.finish();

    const fmt: report.OutputFormat = switch (cmd_args.format) {
        .json => .json,
        .table => .table,
        .toml => .toml,
    };

    try calibrate.formatOutput(result, fmt, stdout_writer);

    if (cmd_args.apply) {
        log.info("Applying changes to llm-cost.toml...", .{});
        try applyChanges(log);
        log.info("✓ Changes applied. Backup saved to llm-cost.toml.bak", .{});
    } else if (cmd_args.dry_run) {
        log.info("Dry run complete. Use --apply to update llm-cost.toml", .{});
    }

    if (cmd_args.fail_on_drift != .never) {
        if (result.status == .warn) return 1;
        if (result.status == .@"error") return 2;
    }
    return 0;
}

fn executeRollback(log: Logger) !void {
    const bak_path = "llm-cost.toml.bak";
    const main_path = "llm-cost.toml";

    log.info("Rolling back to previous configuration...", .{});

    std.fs.cwd().access(bak_path, .{}) catch {
        log.err("No backup found: {s}", .{bak_path});
        return CalibrateError.IoError;
    };

    std.fs.cwd().rename(main_path, "llm-cost.toml.new") catch |e| {
        // If current config is missing, we can still restore backup, but warn.
        if (e != error.FileNotFound) {
            log.err("Failed to move current configuration: {s}", .{@errorName(e)});
            return CalibrateError.IoError;
        }
    };
    std.fs.cwd().rename(bak_path, main_path) catch {
        log.err("Failed to restore backup", .{});
        return CalibrateError.IoError;
    };
    std.fs.cwd().rename("llm-cost.toml.new", bak_path) catch |e| {
        // Best effort: keep previous config available
        log.warn("Failed to save previous config as backup: {s}", .{@errorName(e)});
    };

    log.info("✓ Rollback complete", .{});
}

fn applyChanges(log: Logger) !void {
    const cwd = std.fs.cwd();
    const main_path = "llm-cost.toml";
    const bak_path = "llm-cost.toml.bak";
    const new_path = "llm-cost.toml.new";

    // Ensure there is a calibrated configuration ready to apply.
    cwd.access(new_path, .{}) catch {
        log.err("No calibrated configuration to apply: {s}", .{new_path});
        return CalibrateError.UsageError;
    };

    // Create a backup of the current configuration, if it exists.
    cwd.copyFile(main_path, cwd, bak_path, .{}) catch |e| {
        if (e != error.FileNotFound) {
            log.warn("Failed to create backup: {s}", .{@errorName(e)});
            return e;
        }
    };

    // Replace the main configuration with the calibrated one.
    cwd.rename(new_path, main_path) catch |e| {
        log.err("Failed to apply calibrated configuration: {s}", .{@errorName(e)});
        return CalibrateError.IoError;
    };
}

fn printUsage(w: anytype) !void {
    try w.print(
        \\Usage: llm-cost calibrate --estimates <FILE> --actuals <FILE> [OPTIONS]
        \\
        \\Options:
        \\  -f, --format <json|table|toml>  Output format (default: table)
        \\  --fail-on-drift <warn|error>    Exit 1/2 if drift detected (default: never)
        \\  --min-samples <INT>             Minimum samples required (default: 100)
        \\  --max-resources <INT>           Max unique models limit (default: 10000)
        \\  --cardinality-policy <MODE>     degrade|error (default: degrade)
        \\  --group-by <DIMS>               Breakdown by comma-separated tags (e.g. agent,tool)
        \\  --apply                         Apply changes to llm-cost.toml
        \\  --rollback                      Rollback to previous configuration
        \\
    , .{});
}
