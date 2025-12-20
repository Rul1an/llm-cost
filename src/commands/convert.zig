const std = @import("std");
const args_mod = @import("../cli/args.zig");
const logger_mod = @import("../cli/logger.zig");
const Verbosity = @import("../cli/verbosity.zig").Verbosity;
const otel = @import("../convert/otel.zig");

const ConvertArgs = args_mod.ConvertArgs;
const Logger = logger_mod.Logger;

pub const ConvertError = error{
    MissingInput,
    IoError,
    InvalidFormat,
    UsageError,
    OutOfMemory,
    InvalidJson,
};

pub fn run(
    allocator: std.mem.Allocator,
    cmd_args: ConvertArgs,
    verbosity: Verbosity,
    stdout_writer: anytype,
) !u8 {
    const log = Logger.init(verbosity);

    if (cmd_args.help) {
        try printUsage(std.io.getStdOut().writer());
        return 0;
    }

    if (!std.mem.eql(u8, cmd_args.format, "otel")) {
        log.err("Unknown format: {s}. Supported: otel", .{cmd_args.format});
        return 1;
    }

    if (cmd_args.input == null) {
        log.err("Missing input file (--input)", .{});
        return 1;
    }

    // Read Input
    const input_path = cmd_args.input.?;
    const f = std.fs.cwd().openFile(input_path, .{}) catch |e| {
        log.err("Cannot open input: {s} ({s})", .{ input_path, @errorName(e) });
        return 1;
    };
    defer f.close();

    const input_data = f.readToEndAlloc(allocator, 100 * 1024 * 1024) catch {
        log.err("Input file too large", .{});
        return 1;
    };
    defer allocator.free(input_data);

    // Prepare Output Writer
    // If --stdout, use std output.
    // If --output, open file.
    // If output is file, we can buffer easily.

    if (cmd_args.stdout) {
        // Use injected writer
        try otel.convertJsonToFocusCsv(allocator, input_data, stdout_writer);
    } else if (cmd_args.output) |out_path| {
        const out_f = std.fs.cwd().createFile(out_path, .{}) catch |e| {
            log.err("Cannot create output: {s} ({s})", .{ out_path, @errorName(e) });
            return 1;
        };
        defer out_f.close();

        var buf_writer = std.io.bufferedWriter(out_f.writer());
        try otel.convertJsonToFocusCsv(allocator, input_data, buf_writer.writer());
        try buf_writer.flush();

        log.info("Converted {s} -> {s}", .{ input_path, out_path });
    } else {
        log.err("Must specify --output <FILE> or --stdout", .{});
        return 1;
    }

    return 0;
}

fn printUsage(w: anytype) !void {
    try w.print(
        \\Usage: llm-cost convert <FORMAT> --input <FILE> [OPTIONS]
        \\
        \\Supported Formats:
        \\  otel        OpenTelemetry JSON (GenAI SemConv)
        \\
        \\Options:
        \\  -i, --input <FILE>     Input file path
        \\  -o, --output <FILE>    Output CSV file path
        \\  --stdout               Write CSV to stdout (logs to stderr)
        \\  -v, --verbose          Verbose logging
        \\
    , .{});
}
