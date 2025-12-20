const std = @import("std");

pub const InitError = error{
    FileExists,
};

pub fn run(allocator: std.mem.Allocator, args: []const []const u8, cwd: std.fs.Dir, out_writer: anytype, err_writer: anytype) !void {
    _ = allocator;
    var force = false;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--force")) {
            force = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try out_writer.print(
                \\Usage: llm-cost init [--force]
                \\
                \\Initialize a new llm-cost.toml configuration file.
                \\
                \\Options:
                \\  --force    Overwrite existing file
                \\
            , .{});
            return;
        }
    }

    const flags = std.fs.File.CreateFlags{
        .exclusive = !force,
        .truncate = force,
    };

    const f = cwd.createFile("llm-cost.toml", flags) catch |err| switch (err) {
        error.PathAlreadyExists => {
            try err_writer.print("Error: File 'llm-cost.toml' already exists. Use --force to overwrite.\n", .{});
            return InitError.FileExists;
        },
        else => return err,
    };
    defer f.close();

    try f.writeAll(default_template);
    try f.sync();

    try out_writer.print("Initialized llm-cost.toml\n", .{});
}

const default_template =
    \\[budget]
    \\# Monthly budget in USD.
    \\limit = 500.0
    \\
    \\[models]
    \\# Allowed models regex.
    \\allow = [
    \\    "^gpt-4o",
    \\    "^claude-3-5"
    \\]
    \\
    \\# Deny expensive legacy models
    \\deny = [
    \\    "gpt-4-32k"
    \\]
    \\
    \\# [governance.agentic]
    \\# max_cost_per_run = 5.0
    \\# max_tool_retries = 3
    \\# max_tokens_per_step = 100000
    \\# max_unknown_model_pct = 10.0
    \\
;
