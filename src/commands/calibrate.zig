const std = @import("std");
const calibrate = @import("../calibration/mod.zig");
const report = @import("../calibration/report.zig");
const pricing = @import("../core/pricing/mod.zig");

pub const ExitCode = enum(u8) {
    ok = 0,
    warn = 1,
    @"error" = 2,
    insufficient_data = 3,
    usage_error = 64,
    data_error = 65,
    software_error = 70,

    pub fn int(self: ExitCode) u8 {
        return @intFromEnum(self);
    }
};

pub const FailDrift = enum { never, warn, @"error" };

pub const CliOptions = struct {
    estimates_path: ?[]const u8 = null,
    actuals_path: ?[]const u8 = null,
    format: report.OutputFormat = .table,
    fail_on_drift: FailDrift = .never,
    min_samples: u32 = 100,
    max_unique_resources: u32 = 10000,
    cardinality_policy: isize = 0, // 0=degrade, 1=error (using int to avoid import cycles / duplication, mapped later)
};

pub const Error = error{
    InvalidArg,
    InvalidArgValue,
    HelpShown,
    MissingArg,
    InvalidArgs,
};

pub fn run(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    const opts = parseArgs(args, stderr) catch |err| {
        if (err == error.HelpShown) return ExitCode.ok.int();
        return ExitCode.usage_error.int();
    };

    if (opts.estimates_path == null or opts.actuals_path == null) {
        try stderr.print("Error: --estimates and --actuals are required.\n", .{});
        return ExitCode.usage_error.int();
    }

    // Init Pricing Registry
    var registry = pricing.Registry.init(allocator, .{}) catch |err| {
        try stderr.print("Warning: Failed to load pricing registry: {s}. Recommendations will be limited.\n", .{@errorName(err)});
        // We can continue with a dummy/empty registry or fail.
        // For robustness, maybe we want to fail if it's critical, but here it's enhancement.
        // However, generic `anytype` in `mod.run` means we need a compatible type.
        // If we fail here, we should probably exit (software error).
        return ExitCode.software_error.int();
    };
    defer registry.deinit();

    const run_opts = calibrate.RunOptions{
        .estimates_path = opts.estimates_path.?,
        .actuals_path = opts.actuals_path.?,
        .min_samples = opts.min_samples,
        .max_unique_resources = opts.max_unique_resources,
        .cardinality_policy = if (opts.cardinality_policy == 1) .@"error" else .degrade,
    };

    var interner = @import("../calibration/key_intern.zig").StringInterner.init(allocator);
    defer interner.deinit();

    // run calibration logic
    const result = calibrate.run(allocator, run_opts, &registry, &interner) catch |err| {
        switch (err) {
            error.InsufficientData => {
                try stderr.print("Insufficient Data: {s}\n", .{@errorName(err)});
                return ExitCode.insufficient_data.int();
            },
            error.InvalidEstimates, error.InvalidActuals, error.MissingColumn, error.CardinalityExceeded => {
                try stderr.print("Data Error: {s}\n", .{@errorName(err)});
                return ExitCode.data_error.int();
            },
            error.IoError, error.OutOfMemory, error.SoftwareError, error.Bad => {
                try stderr.print("Software Error: {s}\n", .{@errorName(err)});
                return ExitCode.software_error.int();
            },
        }
    };

    // Output formatting
    try calibrate.formatOutput(result, opts.format, stdout);

    // Business Logic Exit Codes
    if (result.status == .warn) {
        // PR7.0 spec says 1 is WARN ("Exit 1: Warning threshold exceeded").
        return ExitCode.warn.int();
    }
    if (result.status == .@"error") {
        // Always exit 2 on error threshold
        return ExitCode.@"error".int();
    }

    return ExitCode.ok.int();
}

fn parseArgs(args: []const []const u8, stderr: anytype) !CliOptions {
    var opts = CliOptions{
        .estimates_path = null,
        .actuals_path = null,
    };

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printUsage(stderr);
            return error.HelpShown;
        } else if (std.mem.eql(u8, arg, "--estimates")) {
            if (i + 1 >= args.len) return error.MissingArg;
            opts.estimates_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--actuals")) {
            if (i + 1 >= args.len) return error.MissingArg;
            opts.actuals_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, arg, "--format")) {
            if (i + 1 >= args.len) return error.MissingArg;
            const fmt = args[i + 1];
            if (std.mem.eql(u8, fmt, "json")) opts.format = .json else if (std.mem.eql(u8, fmt, "toml")) opts.format = .toml else if (std.mem.eql(u8, fmt, "table")) opts.format = .table else return error.InvalidArgValue;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--min-samples")) {
            if (i + 1 >= args.len) return error.MissingArg;
            const val = args[i + 1];
            opts.min_samples = std.fmt.parseInt(u32, val, 10) catch return error.InvalidArgValue;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--fail-on-drift")) {
            if (i + 1 >= args.len) return error.MissingArg;
            const val = args[i + 1];
            if (std.mem.eql(u8, val, "warn")) opts.fail_on_drift = .warn else if (std.mem.eql(u8, val, "error")) opts.fail_on_drift = .@"error" else if (std.mem.eql(u8, val, "never")) opts.fail_on_drift = .never else return error.InvalidArgValue;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--max-resources")) {
            if (i + 1 >= args.len) return error.MissingArg;
            const val = args[i + 1];
            opts.max_unique_resources = std.fmt.parseInt(u32, val, 10) catch return error.InvalidArgValue;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--cardinality-policy")) {
            if (i + 1 >= args.len) return error.MissingArg;
            const val = args[i + 1];
            if (std.mem.eql(u8, val, "degrade")) opts.cardinality_policy = 0 else if (std.mem.eql(u8, val, "error")) opts.cardinality_policy = 1 else return error.InvalidArgValue;
            i += 1;
        }
    }

    if (opts.estimates_path == null or opts.actuals_path == null) {
        try stderr.print("Error: --estimates and --actuals are required.\n", .{});
        try printUsage(stderr);
        return error.InvalidArgs; // Setup catch in run() handles this as usage_error (64)
    }

    return opts;
}

fn printUsage(w: anytype) !void {
    try w.print(
        \\Usage: llm-cost calibrate --estimates <FILE> --actuals <FILE> [OPTIONS]
        \\
        \\Options:
        \\  --format <json|table|toml>    Output format (default: table)
        \\  --fail-on-drift <warn|error>  Exit 1/2 if drift detected (default: never)
        \\  --min-samples <INT>           Minimum samples required (default: 100)
        \\  --max-resources <INT>         Max unique models limit (default: 10000)
        \\  --cardinality-policy <MODE>   degrade|error (default: degrade)
        \\
    , .{});
}

test "CliOptions defaults to null (Regression)" {
    const opts = CliOptions{};
    try std.testing.expect(opts.estimates_path == null);
    try std.testing.expect(opts.actuals_path == null);
}
