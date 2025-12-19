const std = @import("std");
const calibrate = @import("../calibration/mod.zig");
const report = @import("../calibration/report.zig");
const pricing = @import("../core/pricing/mod.zig");
const args_mod = @import("../cli/args.zig");
const progress_mod = @import("../cli/progress.zig");
const logger_mod = @import("../cli/logger.zig");
const Verbosity = @import("../cli/verbosity.zig").Verbosity;

const CalibrateArgs = args_mod.CalibrateArgs;
const Progress = progress_mod.Progress;
const Spinner = progress_mod.Spinner;
const Logger = logger_mod.Logger;

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

    // Init Pricing Registry
    var registry = pricing.Registry.init(allocator, .{}) catch |err| {
        log.warn("Failed to load pricing registry: {s}. Recommendations will be limited.", .{@errorName(err)});
        return 70; // Software Error
    };
    defer registry.deinit();

    const run_opts = calibrate.RunOptions{
        .estimates_path = estimates_path,
        .actuals_path = actuals_path,
        .min_samples = @intCast(cmd_args.min_samples),
        .max_unique_resources = @intCast(cmd_args.max_resources),
        .cardinality_policy = if (cmd_args.cardinality_policy == 1) .@"error" else .degrade,
    };

    var interner = @import("../calibration/key_intern.zig").StringInterner.init(allocator);
    defer interner.deinit();

    const result = calibrate.run(allocator, run_opts, &registry, &interner) catch |err| {
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

    std.fs.cwd().rename(main_path, "llm-cost.toml.new") catch {};
    std.fs.cwd().rename(bak_path, main_path) catch {
        log.err("Failed to restore backup", .{});
        return CalibrateError.IoError;
    };
    std.fs.cwd().rename("llm-cost.toml.new", bak_path) catch {};

    log.info("✓ Rollback complete", .{});
}

fn applyChanges(log: Logger) !void {
    std.fs.cwd().copyFile("llm-cost.toml", std.fs.cwd(), "llm-cost.toml.bak", .{}) catch |e| {
        if (e != error.FileNotFound) {
            log.warn("Failed to create backup: {s}", .{@errorName(e)});
            return e;
        }
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
        \\  --apply                         Apply changes to llm-cost.toml
        \\  --rollback                      Rollback to previous configuration
        \\  --dry-run                       Simulate application (default)
        \\  -v, --verbose                   Enable verbose output
        \\  -q, --quiet                     Suppress non-error output
        \\
    , .{});
}
