const std = @import("std");
const updater = @import("../core/pricing/updater.zig");

pub const UpdateDbArgs = struct {
    endpoint: ?[]const u8 = null,
    license: ?[]const u8 = null,
    force: bool = false,
    allow_downgrade: bool = false,
};

pub fn run(allocator: std.mem.Allocator, args: UpdateDbArgs) !u8 {
    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    const token = resolveToken(args.license);

    const result = updater.checkAndUpdate(allocator, .{
        .endpoint = args.endpoint orelse "https://api.llm-cost.dev/v1",
        .auth_token = token,
        .force = args.force,
        .allow_downgrade = args.allow_downgrade,
    }, stdout) catch |err| {
        try stderr.print("Fatal error: {any}\n", .{err});
        return 1;
    };

    switch (result) {
        .success => |_| return 0,
        .already_current => return 0,
        .failure => |err| {
            try stderr.print("Error: ", .{});
            switch (err) {
                error.RateLimited => try stderr.writeAll("Rate limit exceeded. Please try again later.\n"),
                error.NetworkUnreachable => try stderr.writeAll("Network unreachable. Using cached database.\n"),
                error.SignatureInvalid => try stderr.writeAll("Security Warning: Manifest signature invalid!\n"),
                error.ManifestRollback => try stderr.writeAll("Security Warning: Version rollback detected (use --allow-downgrade to override)\n"),
                else => try stderr.print("{any}\n", .{err}),
            }

            return switch (err) {
                error.NetworkUnreachable => 1,
                error.Timeout => 2,
                error.ServerError => 3,
                error.RateLimited => 4,
                error.ManifestInvalid, error.SignatureInvalid, error.HashMismatch => 10,
                error.ManifestExpired, error.ManifestRollback, error.SchemaVersionMismatch => 11,
                else => 20,
            };
        },
    }
}

fn resolveToken(cli_arg: ?[]const u8) ?[]const u8 {
    if (cli_arg) |t| return t;
    if (std.posix.getenv("LLM_COST_LICENSE")) |env| return env;
    return null;
}
