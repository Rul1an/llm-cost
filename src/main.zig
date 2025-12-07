const std = @import("std");
const cli = @import("cli/commands.zig");

pub fn main() !void {
    // GeneralPurposeAllocator + Arena: één lifetime per run, geen micro-management.
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    try cli.main(arena.allocator());
}
