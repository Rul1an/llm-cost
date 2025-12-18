const std = @import("std");
const calibrate = @import("../calibration/mod.zig");

pub const ExitCode = enum(u8) {
    ok = 0,
    usage_error = 64,
    data_error = 65,
    software_error = 70,
    io_error = 74,

    pub fn int(self: ExitCode) u8 {
        return @intFromEnum(self);
    }
};

pub const CliOptions = struct {
    estimates_path: []const u8,
    actuals_path: []const u8,
    format: OutputFormat = .table,
    fail_on_drift: FailOnDrift = .never,
    warning_threshold_bps: u32 = 2000, // 20%
    error_threshold_bps: u32 = 5000,   // 50%
    min_samples: u32 = 100,

    pub const OutputFormat = enum { table, json, toml };
    pub const FailOnDrift = enum { never, warn, @"error" };
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

    // run calibration logic
    const result = calibrate.run(allocator, opts) catch |err| {
        switch (err) {
            error.InvalidEstimates, error.InvalidActuals, error.MissingColumn, error.InsufficientData => {
                try stderr.print("Data Error: {s}\n", .{@errorName(err)});
                return ExitCode.data_error.int();
            },
            error.IoError => return ExitCode.io_error.int(),
            error.OutOfMemory => return ExitCode.software_error.int(),
            else => {
                try stderr.print("Unexpected Error: {s}\n", .{@errorName(err)});
                return ExitCode.software_error.int();
            },
        }
    };

    // Output formatting
    try calibrate.formatOutput(result, opts.format, stdout);

    // Exit code logic
    if (opts.fail_on_drift == .warn and (result.status == .warn or result.status == .@"error")) {
        return ExitCode.data_error.int();
    }
    if (opts.fail_on_drift == .@"error" and result.status == .@"error") {
        return ExitCode.data_error.int();
    }

    return ExitCode.ok.int();
}

fn parseArgs(args: []const []const u8, stderr: anytype) !CliOptions {
    var opts = CliOptions{
        .estimates_path = "",
        .actuals_path = "",
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
            if (std.mem.eql(u8, fmt, "json")) opts.format = .json
            else if (std.mem.eql(u8, fmt, "toml")) opts.format = .toml
            else opts.format = .table;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--fail-on-drift")) {
            if (i + 1 >= args.len) return error.MissingArg;
            const val = args[i + 1];
            if (std.mem.eql(u8, val, "warn")) opts.fail_on_drift = .warn
            else if (std.mem.eql(u8, val, "error")) opts.fail_on_drift = .@"error"
            else opts.fail_on_drift = .never;
            i += 1;
        }
    }

    if (opts.estimates_path.len == 0 or opts.actuals_path.len == 0) {
        try stderr.print("Error: --estimates and --actuals are required.\n", .{});
        try printUsage(stderr);
        return error.InvalidArgs;
    }

    return opts;
}

fn printUsage(w: anytype) !void {
    try w.print(
        \\Usage: llm-cost calibrate --estimates <FILE> --actuals <FILE> [OPTIONS]
        \\
        \\Options:
        \\  --format <json|table|toml>    Output format (default: table)
        \\  --fail-on-drift <warn|error>  Exit 65 if drift detected (default: never)
        \\
    , .{});
}


