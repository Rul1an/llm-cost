const std = @import("std");
const cli = @import("cli/commands.zig");

pub fn main() !void {
    // GeneralPurposeAllocator + Arena: één lifetime per run, geen micro-management.
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const gpa_alloc = gpa.allocator();

    var arena = std.heap.ArenaAllocator.init(gpa_alloc);
    defer arena.deinit();
    const alloc = arena.allocator();

    try cli.main(alloc);
}
